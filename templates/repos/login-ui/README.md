# login-ui Tier-1 overlay (mesh repo-templating pilot, Phase 2)

**Overlay-primary, skeleton-fallback. Fork-and-tokenize is BANNED.** This
directory is the *thin brand delta* for `snapdragon-login-ui` — it contains ONLY
the 4 brand-coupled files, never the whole repo. The fuller running code (the
Tier-2 base) is pulled **READ-ONLY** and never copied/vendored/committed into the
generator.

## The 4 brand-coupled files (Tier-1)

| Overlay template | Base file | Token | What it rebrands |
|---|---|---|---|
| `src/index.html.hbs` | `src/index.html` | `{{BRAND_TITLE}}` | the `<title>` tag |
| `package.json.hbs` | `package.json` | `{{NPM_SCOPE}}` (ORG-derived) | the `@snapdragon/*` npm scope |
| `federation-base.js.hbs` | `federation-base.js` | `{{HOST_NAME}}` | the federation host name |
| `.gitlab-ci.yml.hbs` | `.gitlab-ci.yml` | `{{GENERATOR_ORG_GROUP}}` | the CI `include:` project org/group |

## Deliberately LEFT UNTEMPLATED (grounding)

* `nginx.conf` — brand-neutral.
* `docker-entrypoint.d/*` — runtime config is env-injected at container start.
* the `X-Snapdragon-Local` wire header — a frozen protocol constant, not brand.
* the `snap-login-root` custom element and `snap-config.js` — bootstrap/wire
  identity coordinated with the host shell; renaming breaks federation.
* every `snapdragon` in `src/**/*.ts`, comments, imports, groupId, etc. — that is
  **upstream code identity**, not tenant brand. A blind reverse-substitution that
  rebranded it would corrupt the frozen protocol namespace. Tier-1 is deliberately
  narrow.

## Rendering

Rendered by `render_repo_tree()` (`scripts/render-repo-tree.sh`) which pulls the
read-only base, overlays these 4 files via the **Phase-1 real-Handlebars path**
(`scripts/tooling/render-handlebars.js`, `--extra-tokens`), and runs the Phase-1
emit-time secret scanner over the result. Falls back to `_skeleton/` when no base
is pullable (never refuses). See `docs/MESH-TEMPLATING.md`.

`_identity.env` is the drift oracle for `scripts/validate-repo-templates.sh` — the
upstream reverse-map used to prove the overlay still faithfully represents the
current base. `_skeleton/` is the base-absent minimal bootable fallback.

> **Node-not-root constraint:** the Handlebars renderer needs Node and is
> **BUILD-HOST ONLY**. It must NEVER run as root on the mesh-node fail-closed
> root-cron path (Phase 6). See `docs/MESH-TEMPLATING.md`.
