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
