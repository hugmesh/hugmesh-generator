# Mesh repo-templating — current state (Phase 1 + Phase 2 pilot)

This documents the additive Handlebars render engine + guardrails landed for the
mesh repo-templating pilot. **Nothing about the existing single-brand behavior
changes:** `sed` remains the default renderer and the default cluster-manifest
path is untouched. Phase 1 = the engine + guardrails + parity gate (below).
Phase 2 = the **login-ui overlay pilot** (see "Phase 2" at the end).

## ⚠️ CRITICAL CONSTRAINT — Node must never run as root on the mesh-node cron path

The Handlebars renderer (and the YAML schema loader) require **Node**. In this
pilot they run on the **BUILD HOST only**, which is fine.

On the mesh node, the brand profile is reconciled by a **fail-closed root cron**
(`snapdragon-domain-reconcile`) that writes to the filesystem as **root**.
**Node must NEVER be invoked as root on that path.** When Phase 6 wires rendering
onto the mesh node, the reconcile path MUST either:

1. run this renderer as a **constrained, network-less, NON-ROOT helper** (dropped
   privileges, no outbound network, read-only base), **or**
2. consume **pre-rendered** output produced off the root path (render on the build
   host / a non-root sidecar; the root cron only copies the already-rendered tree).

It must **not** call `node` as root. This is a **known deferred reconciliation**,
not solved in Phase 1 — but it is a hard gate for Phase 6. Every entry point
(`scripts/tooling/render-handlebars.{js,sh}`, `load-brand-schema.js`) carries a
header repeating this. The emit-time secret scanner (`scripts/secret-scan.sh`) is
deliberately **node-free** (pure bash + awk) so it can run on the constrained path.

## Renderers

| Engine | Command | Status |
|--------|---------|--------|
| `sed` (default) | `./generate-brand-repos.sh brands/example.conf` | unchanged, no external tools |
| Handlebars (opt-in) | `./generate-brand-repos.sh brands/example.conf --engine=handlebars` | real `handlebars` npm engine |
| Handlebars (direct) | `scripts/tooling/render-handlebars.sh brands/example.conf` | same, standalone wrapper |

The Handlebars renderer compiles the existing `templates/apps/*.hbs` with
`{ noEscape: true }`, so a bare `{{TOKEN}}` is a raw substitution — **byte-for-byte
identical to sed** (no HTML-entity escaping). The `{{TOKEN}}` syntax already in the
templates is valid Handlebars, so the real engine renders them directly.

### Tooling install (build host)

```
cd scripts/tooling && npm install    # installs handlebars + js-yaml locally
```

`scripts/tooling/node_modules/` is gitignored — never committed. Nothing is
installed at the repo root.

## Tokens — 4 of 7 are live

`generate-brand-repos.sh` registers **7** tokens; only **4** actually appear in the
13 templates:

* **Live (4):** `BRAND`, `BRAND_TITLE`, `CLUSTER_DOMAIN`, `HARBOR_PROJECT`
* **Registered-but-dead (3):** `ORG`, `HEADSCALE_URL`, `MESH_TAG` (in none of the
  13 `templates/apps/*.hbs`)

Both renderers register all 7 for compatibility; the dead 3 have no output effect.
`HARBOR_PROJECT` is **derived** from `ORG` by the shell (single source of the slug
rule) in both the sed script and the Handlebars wrapper.

## Guardrails

### Token classifier — `scripts/tooling/tokens.json` (+ `token-classifier.js`)

* **allowlist** — git-safe brand-delta tokens that may be substituted/emitted
  (the 7 live/dead tokens + the reserved pilot tokens `HOST_NAME`,
  `GENERATOR_ORG_GROUP`, `NPM_SCOPE`). The Handlebars renderer **fails closed on
  unknown tokens too**: a `{{token}}` that is neither allow- nor deny-listed
  aborts the render (with `strict:false` it would otherwise silently emit an empty
  string, diverging from the literal sed leaves — see the render path below).
* **denylist** — secret-bearing keys derived from `brands/example.conf` /
  `brand.conf.example` (`ROOT_PASS`, `DEFAULT_USER_PASS`,
  `CASDOOR_ADMIN_CLIENT_SECRET`, `ROUTE_ACCESS_DB_PASSWORD`,
  `APP_REGISTRY_SIGNING_KEY`, `VAULT_ADDR`/`VAULT_TOKEN`, `CA_KEY*`, `MAIL_*`,
  `CLOUDFLARE_TUNNEL_TOKEN`, OAuth client secrets, …) **plus** a catch-all
  key-name regex. The Handlebars renderer **fails closed**: any template that
  references a denylisted token aborts the whole render, and only allowlisted
  tokens are placed in the render context.
* **frozen protocol constants** — `snapdragon.systems/*` label KEYS and the
  `X-Snapdragon-Local` wire header are **out-of-scope-for-tokenization**: they are
  protocol/wire identity (not tenant brand) and must stay literal in every emitted
  repo. A blind reverse-substitution that rebrands the literal `snapdragon` would
  corrupt these — do not tokenize them.

### Emit-time secret scanner — `scripts/secret-scan.sh` (fail-closed)

Gitleaks-style scan (regex + Shannon entropy) over a candidate output tree; exits
non-zero if any secret-looking value is present. It gates Phase 2 repo emission
(`render-repo-tree.sh` refuses to emit a flagged tree). **Node-free** by design
(see the constraint above). **Both pillars are live and self-tested:**

* **High-signal regex** — PEM/OpenSSH keys, AWS AKIDs, GitHub PATs, Slack tokens,
  and a **secret-key assignment** rule mirroring the `tokens.json` denylist.
* **Shannon-entropy** — a keyless opaque-token detector for bare base64/token
  credentials that carry no denylisted key name (e.g. a `Bearer <blob>`). It runs
  over WHOLE emitted repos, so it uses a stricter threshold (4.5 bits/char vs 4.0
  for the keyed rule) and suppresses subresource-integrity / content hashes
  (`sha512-…` npm lockfile entries) — **zero false positives** on the 477-file
  login-ui overlay tree, while still catching a planted keyless credential.
  (Self-test case [3] exercises this pillar directly.)

```
scripts/secret-scan.sh out/example-gitops     # scan a tree
scripts/secret-scan.sh --self-test            # clean=>0, planted-secret=>1, keyless-entropy=>1
```

> Backstop scope (known): a **weak/default** credential (short or low-entropy)
> assigned to a denylisted key still passes the entropy floor. The **primary**
> guarantee is upstream — the renderer only substitutes allowlisted tokens and
> refuses denylisted ones — so a secret is never *emittable* via the render path;
> this scanner is a defense-in-depth backstop over the final tree.

## Parity gate — the Phase 1 exit criterion

`scripts/parity-gate.sh` renders the 13 CRDs **both** ways (sed + Handlebars) for
`brands/example.conf` **and** `brands/local.conf` and asserts the output trees are
byte-identical. This must pass before anything else builds on the engine.

```
scripts/parity-gate.sh
```

(`local.conf` is local-first and leaves `HEADSCALE_URL` empty, which the default
sed script's prod-oriented field check rejects; since `HEADSCALE_URL`/`MESH_TAG`
are dead tokens absent from all 13 templates, the gate feeds **both** renderers the
same normalized conf so the byte comparison stays honest.)

## Structured brand schema — `brands/<name>.yaml`

`brands/example.yaml` is the forward-looking structured shape
(`services[]{installed}`, `domains[]` as a list, `repos[]` manifest). It is
**additive** and **degrades cleanly** to today's 7 scalars via
`scripts/tooling/load-brand-schema.js`, which prints shell `KEY=VALUE` lines the
existing `.conf` path can `source`:

```
eval "$(node scripts/tooling/load-brand-schema.js brands/example.yaml)"
```

The `.conf` path is **not** removed; the two shapes stay compatible.

---

# Phase 2 — the login-ui overlay pilot

Phase 1 templated only ArgoCD `Application` CRDs (thin pointer repos). Phase 2
proves the **overlay-primary, skeleton-fallback** model on a real app repo:
`snapdragon-login-ui`. It is **additive and opt-in** — no default path changes.

## Two-tier maintenance model (fork-and-tokenize is BANNED)

* **Tier-2 base** = the fuller RUNNING code, pulled **READ-ONLY**
  (`scripts/pull-repo-base.sh`, `GIT_BASE` knob defaulting to GitHub). It is
  **never copied/vendored/committed** into the generator. The base clone lives in
  a gitignored cache (`/.repo-base/`) or an out-of-tree path.
  > **Base integrity is intentionally UNVERIFIED in this pilot** — the base is
  > cloned over TLS with no commit-signature / content-digest / provenance / SBOM
  > check. Acceptable ONLY because the pilot base is **first-party** (same mesh,
  > over TLS): trusted-transport, **not** trusted-and-verified. A compromised
  > upstream could inject non-secret code (`Dockerfile`, `src/**`) that neither the
  > secret scanner (secrets only) nor the drift validator (overlaid files only)
  > would catch. Signature/provenance/SBOM/vuln gating of **foreign** mesh-code
  > bases is scoped to **Phase 8**. (Noted at the pull site in `pull-repo-base.sh`.)
* **Tier-1 overlay** = the thin brand delta shipped in the generator at
  `templates/repos/login-ui/`. It contains **ONLY the 4 brand-coupled files**,
  never the whole repo:

  | Overlay template | Token | Rebrands |
  |---|---|---|
  | `src/index.html.hbs` | `{{BRAND_TITLE}}` | the `<title>` tag |
  | `package.json.hbs` | `{{NPM_SCOPE}}` (ORG-derived, lowercased slug) | the `@snapdragon/*` npm scope |
  | `federation-base.js.hbs` | `{{HOST_NAME}}` (`<brand>-host`) | the federation host name |
  | `.gitlab-ci.yml.hbs` | `{{GENERATOR_ORG_GROUP}}` (`<org-slug>/snapdragon-generator`) | the CI `include:` project org/group |

  Deliberately **left untemplated** (grounding): `nginx.conf` (brand-neutral),
  `docker-entrypoint.d/*` (runtime env-injected), the `X-Snapdragon-Local` wire
  header (frozen protocol constant), the `snap-login-root` element, and every
  `snapdragon` in `src/**` / comments / groupId — that is **upstream code
  identity**, not tenant brand. Tier-1 is deliberately narrow.

`NPM_SCOPE` / `HOST_NAME` / `GENERATOR_ORG_GROUP` are registered in the token
classifier allowlist (`scripts/tooling/tokens.json`, `reserved_pilot`) — all
ORG/BRAND-derived, none secret-bearing.

## `render_repo_tree()` — `scripts/render-repo-tree.sh` (opt-in)

Behind the **required** `--enable-repo-tree` flag:

1. pulls the Tier-2 base READ-ONLY;
2. copies it into a gitignored OUT dir (`out/<BRAND>-login-ui/`) — base untouched;
3. overlays the 4 brand-coupled files via the **Phase-1 real-Handlebars path**
   (`render-handlebars.js --extra-tokens NPM_SCOPE,HOST_NAME,GENERATOR_ORG_GROUP`)
   — rendering is **not** reimplemented;
4. gates the emitted tree with the **Phase-1 fail-closed secret scanner**
   (`scripts/secret-scan.sh`) — a planted secret **refuses the emit**;
5. **falls back** to `templates/repos/login-ui/_skeleton/` when the base is absent
   (a minimal, zero-dep, bootable login-ui that `npm ci && npm run build`s fully
   OFFLINE) — **never refuses**.

> **Offline-build proof scope:** the `npm ci && npm run build` **offline** guarantee
> covers the **skeleton** path only (pure Node stdlib, zero deps). The **overlay**
> tree is the full Angular base + 4 rebranded files; building it needs the Angular
> toolchain and the npm registry and is **not** offline-buildable. The overlay's
> rendered `package.json` / `*.hbs` are byte-faithful to the working base, so the
> overlay build is proven by the base's own CI, not re-proven here.

```
LOGIN_UI_BASE_DIR=/path/to/read-only/base \
  scripts/render-repo-tree.sh brands/example.conf --enable-repo-tree --repo login-ui
```

> The app-CRD sweep (`generate-brand-repos.sh` + `render-handlebars.js`) now skips
> the `templates/repos/**` overlay subtree, so the parity gate stays byte-identical.

## Drift validator — `scripts/validate-repo-templates.sh`

Sibling to `validate-reserved-prefixes.sh`. Re-applies the overlay against a
**freshly-pulled base** using the **upstream-identity** token values
(`templates/repos/login-ui/_identity.env` — the base's OWN original literals) and
asserts byte-equality. Any divergence fails loudly with a **patch-reject** (unified
diff) **and** an **overlayed-region checksum** mismatch. GREEN on an in-sync base,
RED on any injected drift. Wire it into CI beside the reserved-prefix guard.

## ⚠️ Node-not-root still applies (harder for Phase 2)

`render-repo-tree.sh` and `validate-repo-templates.sh` invoke `node`. **BUILD-HOST
ONLY.** On the mesh-node fail-closed root-cron path (Phase 6) the reconcile MUST
run this as a constrained, network-less, NON-ROOT helper **or** consume
pre-rendered output — it must **not** `node`-as-root. The base-puller's network
fetch is likewise off the root path (use a pre-populated `/.repo-base/` cache or a
`*_BASE_DIR` override on the node). Deferred reconciliation, not solved here.

---

## Phase 4 — archetype-based rendering + full tenant-set instantiation

Phase 4 generalizes the two proven EXEMPLAR overlays into archetype **classes** and
instantiates the whole N-repo tenant set from a manifest. The anti-goal was 21 hand
overlays; the win is: any BFF renders from the spring-bff archetype, any UI from the
angular-mfe archetype, parameterized only by a `repos[]` identity row.

### Structure — `templates/archetypes/<archetype>/`
`templates/repos/<name>/` is **gone** (folded in). The repo→archetype map lives in
the brand YAML's `repos[]`, not a second overlay dir. Each archetype ships:
- `recipe.yaml` — **class-B** anchored, presence-tolerant edits (find = upstream
  literal, replace = brand-token form) applied to each repo's **OWN** base file.
  This is the change that generalizes: a whole-file overlay carries the exemplar's
  identity (emit user-bff as admin, break `ng build user`); an anchor edits only the
  brand-coupled substring, and an anchor absent in a given repo no-ops.
- optional **class-A** whole-file `.hbs` — byte-identical across the class bar one
  brand token (angular-mfe `federation-base.js`; gateway `deploy/*` env overlay).
- `_identity.env` — the drift **oracle** for the exemplar member.
- `_skeleton/` — base-absent fallback.

### Per-archetype skeleton (two-tier fallback)
- **angular-mfe**: BOOTABLE — a zero-dep static holding page; `npm ci && npm run
  build` works fully OFFLINE and emits a titled bundle.
- **spring-bff / gateway**: NON-buildable placeholder README. A compiled Spring
  service has no faithful minimal boot, so **"never refuses"** holds but
  **"bootable"** does not. Documented, not a bug.

### Manifest + security boundary
`repos[]` in `brands/<name>.yaml` = `{name, archetype, installed, identity}`. It is
read as **structured data** by the Node driver (`render-tenant-set.js`) ONLY and is
**never** degraded to shell / eval'd on the signed-export path (only the 7 scalars
are, via `load-brand-schema.js`; `--repos-json` emits the manifest as a JSON
sidecar). Every identity token NAME is fail-closed through the classifier and every
VALUE is screened for a secret/frozen constant before it can reach a render.
`installed:false` drops exactly that repo from the render (optional-service toggle).

### One command
```
scripts/render-tenant-set.sh brands/<brand>.yaml --enable-repo-tree --out-dir out
```
Renders every installed repo (repo→archetype→overlay+identity), two-tier skeleton
fallback for unpullable bases, then a residual-`{{TOKEN}}` sweep. Zero residual or
it refuses.

### Drift validator (generalized)
`validate-repo-templates.sh --archetype <name>` now does an **anchored-region**
compare (recipe find@upstream still present + replace@upstream==find round-trip;
class-A whole-file byte-identical), because a 2nd class member legitimately differs
from the exemplar outside the anchored regions. GREEN on a fresh base, RED on drift.

### Node-not-root
Unchanged, now applied per-repo across the full set: `render-recipe.js`,
`render-tenant-set.js`, `validate-archetype.js` are BUILD-HOST ONLY.

# Phase 6 — hardening the ROOT mesh-node reconcile RENDER path

The root cron `specs/usr/sbin/snapdragon-domain-reconcile` fetches a SIGNED
(#118, Ed25519 + strict-monotonic) cross-domain export, synthesises a transient
brand profile per entry, and drives the generator **as root**. The signature
proves AUTHENTICITY, **not CONTENT** — a malicious-but-authentic export is the
primary threat. Phase 6 makes the render path fail closed.

## Fail-closed emit gate (quarantine → scan → promote)
`render_brand_repos()` no longer writes into the published `OUT_DIR`. Each entry:
1. renders into a per-run **QUARANTINE** `OUT_DIR/.staging/<brand>-gitops`
   (still inside the root-owned `CACHE_DIR` containment; nothing durable yet);
2. is gated by the node-free **emit-time secret scanner**
   (`scripts/secret-scan.sh`, seam `DR_SECRET_SCAN`) — a **HARD** gate: a finding
   OR a missing scanner OR a generator non-zero **purges** the staging tree and
   sets the run-level `_DR_EMIT_FAILED`;
3. only a scanned-**clean** tree is atomically **promoted** (`mv`) to
   `OUT_DIR/<brand>-gitops`.

`main()` then reads `_DR_EMIT_FAILED` **before** the ack writeback and **before**
the durable marker: on any content failure it skips `writeback_acks` entirely,
`report_state quarantined`, and exits non-zero — so **no ack POST fires** and
`ack_generation()` is unreachable on the failure branch.

## Marker ordering
`commit_cache()` now swaps ONLY `export.json` (the keep-last-good bytes). The
`last-good-generation` **FLOOR bump** (the durable monotonic rollback MARKER) is
split into `commit_generation_floor()` and **deferred** to AFTER a clean emit+scan
of all entries. A malicious-but-authentic export that fails the content gate
therefore raises **no** durable marker; the admin-bff can re-issue a corrected
export at the same or a higher generation.

## Every export field is hostile
`entry_fields_ok()` (reconcile) + the generator's own DNS-label/DNS-name/URL/
single-line/length guards + the token classifier (denylist + frozen
`snapdragon.systems/*` / `X-Snapdragon-Local` constants) validate every field.
`BRAND_TITLE` now also **rejects braces** (`{` `}`) to kill second-order
`{{TOKEN}}` template re-expansion. A DoS cap (`DR_MAX_ENTRIES`, default 256)
refuses a huge `entries[]` before the render loop can fork.

## Containment
`generate-brand-repos.sh` anchors `<brand>-gitops` under `OUT_DIR` via
`realpath -m` prefix-match before any `rm -rf`/`mkdir`; the Phase 6 quarantine dir
and the promote `mv` reuse the same idiom (`_dr_realpath_under`). `gen-keystores.sh`
gains the **matching** realpath containment for `OUT/certs/<brand>` and
`OUT/keystores/<brand>` (previously DNS-label validation only). **Invariant:**
`OUT_DIR` is root-owned and must not be group/other-writable — `realpath -m`
follows existing symlinks, so the containment depends on the attacker not being
able to plant a symlink under the root-owned base. Real filesystem-perms /
UID-0-cron enforcement is a **deferred-to-real-root** check.

## HARD RULE — no network during render
The root-cron render must **never** pull/clone. The only network op is
`fetch_export()` (curl over mTLS), strictly BEFORE any render. **Tier-2 bases are
pre-staged offline at provision time.** Enforcement:
* the render is pinned to **ENGINE=sed** — `render_brand_repos` invokes
  `generate-brand-repos.sh` **without** `--engine` (the `handlebars` path execs
  Node, which must never run as root here); the synthesised profile never sets
  `ENGINE`;
* `OFFLINE=1` is exported for the render subshell so any future/refactored base
  resolution (`pull-repo-base.sh` honours `OFFLINE=1`) **fails closed** instead of
  fetching;
* **belt-and-suspenders / deferred:** a real network jail on the render subprocess
  (`unshare -rn`, or systemd `PrivateNetwork=yes` / `IPAddressDeny=any` on the cron
  unit) is a **deferred-to-real-root** hardening — the offline pins above are the
  build-host-verifiable half.

## Adversarial-export fuzz suite (the exit gate)
`tests/domain-registry/test-domain-reconcile-fuzz.sh` — build-host runnable (no
root, no network, scratch containment dir). Feeds malicious-but-well-formed
profiles/exports (metachar/injection, traversal, secret-in-field, protocol
override, oversized/loop, YAML-splice) and asserts EACH: exit!=0 / fail-closed, no
file outside the scratch dir, and **zero** ack POSTs (a `curl` recorder stub in
PATH). A LEGIT export is the positive control — it renders/scans/promotes clean
and the writeback DOES fire (no false-positive lockout).

## Deferred to real-root / real-cluster (never faked)
1. execution as UID 0 under the actual root cron;
2. a genuine Ed25519-signed #118 export from a live admin-bff over in-cluster mTLS;
3. real `gen-keystores.sh` CA/keystore generation (`DR_SKIP_CA=1` scopes it out on
   the build host);
4. the real writeback POST — the admin-bff reconcile-ack **setter endpoint does not
   exist yet** (band-190 dark), so "no ack on failure" is provable today only via
   the local curl-stub recorder;
5. real network-namespace / `PrivateNetwork` isolation of the render subprocess;
6. OPTIONAL-SERVICE selection + non-placeholder registry-pub key gating (the three
   ship-dark gates).

# Phase 7 — cross-mesh decentralization (foreign-base ingestion + outbound exposure)

Phase 7 opens the templating pipeline across MESH boundaries in both directions,
under one rule: **a foreign mesh's code is fully hostile even when validly
signed**. A valid signature proves WHO produced the attestation, never that the
on-disk tree is safe — so every inbound foreign base goes through a fail-closed
supply-chain gate, and a rejected base is **admitted nowhere and pushed onward
never**.

## The INBOUND gate — `scripts/ingest-foreign-base.sh`

Build-host only. Everything runs inside a per-run **quarantine snapshot**; only a
tree that passes EVERY gate is atomically promoted (its verified path printed on
stdout). ANY failure purges the snapshot, prints nothing, exits non-zero. Gate
order (each fail-closed; a missing tool is a REJECT, never a skip):

1. **[DoS] pre-flight caps** on the SOURCE (file count / total bytes / path
   depth) BEFORE any copy — a zip-bomb or deep-nest tree never exhausts the host;
2. **[SNAP] quarantine snapshot** — closes TOCTOU: every later gate AND the
   eventual overlay copy read the SAME frozen bytes, never the mutable source;
3. **[g] containment (hoisted)** — escaping/absolute/`..`-traversal symlinks and
   hardlinks rejected BEFORE the content gates, so a planted link can never
   subvert a later gate into reading a trusted file outside the tree;
4. **[a] digest pin** — the base MUST be requested by an IMMUTABLE 40/64-hex
   digest (mutable refs like `main`/`HEAD` are refused); the SIGNED manifest's
   `base.commitSha` must equal the pin, `base.meshId` the declared mesh, and a
   recomputed canonical **tree digest** must equal `base.treeSha256` — binding
   the signature to the actual bytes (root-anchored: a file merely NAMED like the
   envelope in a subdir is ordinary content, digest-covered);
5. **[b] provenance / Ed25519 signature** — verified with `provenance.sh` against
   the PINNED pubkey from the trust store (base64 SPKI DER, validated to be an
   Ed25519 PUBLIC key) — never against any key the envelope advertises. Plus the
   **replay floor**: `base.generation >= minGeneration` rejects an
   old-but-genuinely-signed (known-vuln / rolled-back) base;
6. **[c] SBOM** — present, parseable, non-empty (CycloneDX components / SPDX
   packages);
7. **[d] vuln** — SBOM components screened against the PINNED OFFLINE advisory
   floor (`templates/mesh-trust/advisory-floor.txt`); any CRITICAL match rejects;
8. **[e] secret scan** — `secret-scan.sh` over the ENTIRE tree with NO excludes
   (the render emit-scan's first-party carve-outs do NOT apply to foreign code);
9. **[f] frozen/denylist** — foreign code must not carry OUR frozen protocol
   identity (`snapdragon.systems/*` label keys, the `X-Snapdragon-Local` &
   friends wire headers, the step-up subprotocol prefix); declared origin fields
   are screened through the same token classifier the render path uses. Only the
   ROOT-level attestation envelope is exempt from the tree grep — a same-named
   subdir file IS screened (laundering vector otherwise);
10. **atomic promote** — the fully-passed snapshot is `mv`'d into place with an
    admit stamp; a half-verified tree is never observable at the returned path.

The canonical **tree digest** binds more than file content: per path it also binds
the **symlink target** (links were previously outside the digest entirely) and the
**exec bit** (0111), so a base re-signed and then mutated to repoint a link or flip
a mode no longer slips past the binding (R5).

## Re-checked on EVERY consume — not just at pull

The gate is a consume path in its own right, so it (and `render-repo-tree.sh`) now
independently re-consult the registry via `--registry`, closing the window where a
mesh **disabled or revoked after its base was cached** could still be ingested or
rendered from that cache (R2). Because the whole gate re-runs on every consume, the
current **advisory floor** and **registry state** are re-evaluated each time: a base
that became known-vulnerable (raise the floor / bump `minGeneration`) or whose mesh
was revoked after admission is refused, not silently reused (R4 freshness).

**Revocation (R4), build-host scoped.** To stop cached bases from a compromised
foreign mesh WITHOUT a live CRL/OCSP feed: set the mesh row `"revoked": true`, and/or
list the compromised signing key's fingerprint (`base64 -d <pubkey> | sha256sum`)
under `revokedKeys` (per-mesh or top-level) — the gate fingerprints the pinned key
after the signature verifies and refuses a revoked key despite a valid signature.
Deleting the staged pubkey also fails closed. **Honest deferral:** an ONLINE CRL /
OCSP-style revocation service is out of build-host scope and deferred to the cluster;
the registry `revoked` / `revokedKeys` flags + advisory-floor re-check are the
build-host half.

**Override content anchor (R3).** On the `*_BASE_DIR` override and render `--base`
paths there is no git commit→tree binding, so the operator's pin would otherwise
collapse to the signer's self-declared `treeSha256`. Those paths therefore REQUIRE an
operator `pinnedTreeSha256` (registry field or `--pinned-tree-sha256` /
`FOREIGN_PINNED_TREE_SHA256`); the gate enforces `recomputed == pinnedTreeSha256 ==
manifest.base.treeSha256`, binding the pin to the ACTUAL bytes — a mismatch fails
closed.

**Fetch-time DoS bound (R6).** The clone/fetch in `pull-repo-base.sh` is `--depth 1`
AND wrapped in a byte watchdog that aborts an unbounded hostile clone mid-transfer,
plus a post-fetch / pre-gate inode+byte cap that fires ahead of the ingestion gate —
so a hostile `--url` clone is capped before it can exhaust build-host disk, mirroring
the gate's hoisted DoS-cap pattern.

## Explicit trust — NO trust-on-first-use

Admission policy is two deliberate, independent additions per foreign mesh:

* a row in `templates/mesh-trust/registry.json` — `enabled`, the foreign forge
  `gitBase`, the `pinnedDigest` of the exact vouched base tree, the operator's
  `pinnedTreeSha256` content anchor (R3), the `minGeneration` rollback floor (raise
  it after a CVE to lock out an old-but-signed base), and the `revoked` /
  `revokedKeys` revocation signals (R4);
* the mesh's provenance-signing PUBLIC key staged **out-of-band** at
  `keys-template/mesh-trust/<mesh-id>/foreign-provenance-pub.ed25519`
  (pubkeys-only; git-ignored; same custody model as `registry-pub.ed25519`).

An unknown mesh (no row / no key), a disabled row, or a rotated-but-not-restaged
key all fail CLOSED. `<mesh-id>` is a strict DNS label so the trust path can
never traverse.

## Enforcement wire-ins (a rejected base can never be used or pushed)

* **`scripts/pull-repo-base.sh --foreign --mesh <id>`** (or `FOREIGN_MESH` env,
  with `--pinned-digest/--trust-store/--min-generation` overriding the registry
  row): resolves the RAW foreign tree (a `<NAME>_BASE_DIR` override, the foreign
  cache, or a pinned-digest fetch from the mesh's forge — never a moving ref),
  then REQUIRES the ingestion gate to pass and prints ONLY the gate's **admitted
  quarantine snapshot** — never the raw tree. `OFFLINE=1` is honored (no fetch;
  the gate still runs). The trusted-own-mesh default path is byte-for-byte
  unchanged.
* **`scripts/render-repo-tree.sh --foreign-mesh <id> --pinned-digest SHA`**: the
  gate runs BEFORE any copy and the overlay reads the admitted snapshot (the
  exact verified bytes — TOCTOU-closed). A REJECT is fatal: **no skeleton
  fallback** (that would mask the rejection), `BRAND_OUT` is never created, so
  the publish tail has nothing to sign with our key or push to Forgejo. The
  foreign attestation envelope + gate markers are stripped from the emitted tree
  (we attest what WE emit with a fresh Phase-5 provenance; the inbound envelope
  never rides through).

## The exit gate — `tests/domain-registry/test-foreign-ingest-fuzz.sh`

Build-host runnable (no root, no network). Drives the REAL gate + BOTH wire-ins
with a hostile corpus — unsigned / unknown-mesh (no-TOFU) / wrong-key /
tampered-after-sign / digest-swap / mutable-ref / pin-mismatch / post-sign
subdir-envelope plant / signed-in subdir-envelope frozen carrier / smuggled
secret / keyless high-entropy credential / frozen-namespace + wire-header
injection / SBOM absent-malformed-empty / CRITICAL-vuln dep / symlink escape-
absolute-traversal / file-count-bytes-depth DoS / replay / pull-wiring refusals —
plus the residual-medium hardenings: disabled/revoked mesh at the gate AND render
(R2), override content-drift caught by the operator anchor with an explicit
OLD-vs-NEW admit-without-anchor proof (R3), revoked-key / revoke-by-deletion /
raised-floor freshness (R4), post-sign mode-flip + symlink-repoint with OLD-vs-NEW
content-only-digest proofs (R5), and the pre-gate inode cap + fetch-time byte
watchdog (R6) — asserting for EACH: (1) exit != 0, (2) NOT admitted (no snapshot,
no stdout path), (3) NOTHING pushed onward (BRAND_OUT never written). A clean,
signed, digest-pinned base from a trusted mesh is the positive control: admitted
AND rendered (0 residual tokens, markers stripped) — the gate is not a blanket
lockout.

## OUTBOUND — letting a foreign mesh pull from US

* **`specs/cluster/manifests/mesh-forge/`** — exposes our tailnet-internal
  Forgejo for foreign pulls. SHIP-DARK: inert until the operator flips
  `MESH_FORGE_EXPOSED` to `"true"`. Even then: **tailnet-only** (NetworkPolicy
  admits only the tailnet CIDR; ClusterIP stays, no public Ingress) and **mTLS
  client-cert required** (issuer must be in the cross-mesh CA trust bundle;
  anonymous/bearer pulls refused).
* **`specs/cluster/manifests/mesh-harbor/`** — the cross-mesh domain-creation
  publish Action: per-tenant Harbor project (`snapdragon-<brand>`), a pull-only
  project-scoped robot for the foreign mesh (secret written once into Vault),
  a push-only robot for the tenant build. Extends the Phase-5 provision job's
  idempotent reconcile; the foreign mesh never receives admin or cross-project
  scope.

## Deferred to real-cluster (never faked)

1. the LIVE tailnet bind + LIVE mTLS client-cert verification of the forge
   exposure, including the CROSS-CA trust bundle (a foreign mesh chains to a
   different CA than our pki_int — the bundle mount + gateway TLS termination
   are cluster-only);
2. a LIVE vulnerability database — Trivy ships `enabled:false` in
   `apps/03a-harbor.yaml`; flipping it on gives foreign pulls a cluster-side
   vuln gate. The build-host half is the PINNED offline advisory floor (honest:
   a floor, not a feed);
3. a LIVE run of the Harbor mesh Action (needs booted Harbor + Vault + the
   cluster-CA copy the Phase-5 job documents);
4. a REAL cross-mesh git pull over the tailnet (build-host proof drives the gate
   via a local RAW-source override; the pinned-digest fetch path needs a
   reachable foreign forge);
5. cross-mesh IMAGE provenance (cosign/notation over the per-tenant Harbor
   project) — source-tree provenance is Phase 5 + this gate; image signing is a
   cluster concern;
6. an ONLINE key-revocation service (CRL / OCSP-style) — the build-host half is the
   registry `revoked` / `revokedKeys` flags + the advisory-floor re-check at every
   consume (R4); a live revocation feed that reflects a compromise WITHOUT an
   operator registry edit is a cluster/PKI concern.
