# angular-mfe archetype

Renders any HugMesh **Angular native-federation micro-frontend** from ONE
recipe and one class-A shared file, parameterized by the per-repo
`repos[].identity` row. It was seeded from the Phase-2 `login-ui` exemplar and
proven on `user-ui` with only manifest identity (no new hand overlay).

Class members: login / admin / user / mod / matrix / mastodon / owncast / tube /
wiki / forum-ui + api-docs + character-studio-ui + superadmin-service-catalog-ui.

## What is / isn't templated

- **Class-A shared whole-file (`federation-base.js.hbs`):** the same code in
  every class member except the `HOST_NAME` federation-host default. It goes in
  as a wholesale overlay, so there is one source of truth. The copies are not
  byte-identical: comment lines differ in login-ui (a note on `@angular/localize`),
  api-docs, character-studio-ui and superadmin-service-catalog-ui. The drift check
  compares the template with login-ui; run against another member, it reports this
  file as drift.
- **Class-B anchored edits (`recipe.yaml` on the base's OWN files):**
  - `package.json`: npm scope only (`@hugmesh/<slug>` -> `@<NPM_SCOPE>/<slug>`).
    The `<slug>` == `ng build <slug>` target stays.
  - `src/index.html`: the leading brand word of the tab title (`BRAND_TITLE`) plus
    the per-UI `TITLE_WORD`. The `<hug-<slug>-root>` bootstrap selector stays literal.
  - `.gitlab-ci.yml`: only the `include: project:` org/group.
- **Left literal (repo identity):** the `<slug>` npm segment, ng project name and
  root selector, and the `package.json` description.

## Per-repo identity (repos[].identity)

- `app_slug` — npm segment / ng target / `<hug-<slug>-root>` selector word.
- `title_word` — per-UI tab-title role differentiator.

## Files

- `recipe.yaml`, `federation-base.js.hbs` (class-A), `_identity.env` (drift oracle,
  login-ui upstream values), and `_skeleton/`, a RUNNABLE minimal Angular 22
  native-federation remote in the house shape:
  - dependency majors pinned to user-ui's;
  - a `hugmeshRemote` federation config exposing `./routes`;
  - a standalone, signals-based component with `[textContent]` bindings (Angular's
    double-curly interpolation would trip the renderer's fail-closed brand-token
    scan);
  - the `--hug-*` palette floor;
  - a CORS `nginx.conf` on 8080, an nginx-unprivileged Dockerfile, fleet CI, and a
    karma/jasmine spec.

  `npm ci && npm run build` in a rendered tree is a real
  `@angular-architects/native-federation:build`. It needs registry access; the old
  zero-dependency holding page is gone.

## Honest package-lock regeneration (procedure)

`_skeleton/package-lock.json.hbs` is a REAL `npm install`-resolved lockfile with
ONLY the two name fields re-tokenized. Never hand-edit dependency entries. To
regenerate it (dependency bump, Angular major move):

1. Render the skeleton with a throwaway identity, e.g.
   `OFFLINE=1 scripts/render-repo-tree.sh brands/example.conf --enable-repo-tree \
      --repo hello-ui --archetype angular-mfe --out-dir /tmp/lockgen \
      --set APP_SLUG=hello --set TITLE_WORD=Hello`
2. In the rendered tree run `npm install` (a full resolve against the registry),
   then prove it: `npm ci && npm run build`.
3. Copy the produced `package-lock.json` back to
   `_skeleton/package-lock.json.hbs`. Replace ONLY the top-level `"name"` and the
   `packages[""].name` values with `@<NPM_SCOPE-token>/<APP_SLUG-token>` (the same
   two mustache tokens `package.json.hbs` carries). Tokenize nothing else. Leave
   integrity hashes byte-exact; the `sha512-` SRI prefix keeps the secret-scan
   entropy gate green.
4. Re-render and run `npm ci && npm run build` once more to prove the tokenized
   lockfile still round-trips.
