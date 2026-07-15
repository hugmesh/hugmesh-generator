# angular-mfe archetype

Renders any Snapdragon **Angular native-federation micro-frontend** from ONE
recipe + one class-A shared file, parameterized by the per-repo `repos[].identity`
row. Seeded from the Phase-2 `login-ui` exemplar; proven on `user-ui` with only
manifest identity (no new hand overlay).

Class members: login / admin / user / mod / matrix / mastodon / owncast / tube /
wiki / forum-ui + api-docs + character-studio-ui + superadmin-service-catalog-ui.

## What is / isn't templated

- **Class-A shared whole-file (`federation-base.js.hbs`):** byte-identical across
  the class except the `HOST_NAME` federation-host default — safe wholesale
  overlay, single source of truth. (Verified identical across login-ui/user-ui.)
- **Class-B anchored edits (`recipe.yaml` on the base's OWN files):**
  - `package.json`: npm scope only (`@snapdragon/<slug>` -> `@<NPM_SCOPE>/<slug>`);
    the `<slug>` == `ng build <slug>` target is preserved.
  - `src/index.html`: tab title leading brand word (`BRAND_TITLE`) + per-UI
    `TITLE_WORD`; the `<snap-<slug>-root>` bootstrap selector is left literal.
  - `.gitlab-ci.yml`: only the `include: project:` org/group.
- **Left literal (repo identity):** the `<slug>` npm segment / ng project name /
  root selector, `package.json` description.

## Per-repo identity (repos[].identity)

- `app_slug` — npm segment / ng target / `<snap-<slug>-root>` selector word.
- `title_word` — per-UI tab-title role differentiator.

## Files

- `recipe.yaml`, `federation-base.js.hbs` (class-A), `_identity.env` (drift oracle,
  login-ui upstream values), `_skeleton/` — a BOOTABLE zero-dep static holding page
  (`npm ci && npm run build` works OFFLINE; unlike spring-bff, the MFE skeleton is
  genuinely bootable).
