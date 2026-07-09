# Mesh repo-templating — current state (Phase 1 pilot)

This documents the additive Handlebars render engine + guardrails landed for the
mesh repo-templating pilot. **Nothing about the existing single-brand behavior
changes:** `sed` remains the default renderer and the default cluster-manifest
path is untouched.

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
  `GENERATOR_ORG_GROUP`).
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
non-zero if any secret-looking value is present. It will gate Phase 2 repo
emission. **Node-free** by design (see the constraint above).

```
scripts/secret-scan.sh out/example-gitops     # scan a tree
scripts/secret-scan.sh --self-test            # clean=>0, planted-secret=>1
```

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
