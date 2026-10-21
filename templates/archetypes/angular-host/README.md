# angular-host archetype

Renders the HugMesh **native-federation HOST shell** class. The one member today
is the site shell that mounts every angular-mfe remote. It is published as
`hugmesh-host-shell` (the same tree was once clonable as `hugmesh.net`). The class
has one member, but a multi-domain tenant can add sibling shells.

## Resolving the exemplar base

`repos[].name` must be a **DNS label**. The published name `hugmesh-host-shell`
is one, so the manifest row `host-shell` resolves through the normal
`hugmesh-<name>` lookup in `pull-repo-base.sh`. No override is needed:

```
scripts/validate-repo-templates.sh --archetype angular-host
```

For an offline or pinned run, point `<NAME>_BASE_DIR` at a local read-only clone
or pass `--base`:

```
HOST_SHELL_BASE_DIR=/path/to/a/host-shell/clone \
  scripts/validate-repo-templates.sh --archetype angular-host
```

The same resolution drives an overlay render (`render-repo-tree.sh --repo
host-shell` or the tenant-set driver).

## What is / isn't templated

- **Class-B anchored edits (`recipe.yaml` on the base's OWN files):**
  - `federation.config.js`: the host's federation name, the `name:` property
    of the `hugmeshHost({ ... })` call (`name: 'hugmesh-host'` -> the derived
    `HOST_NAME`). The call also passes `extraSkip`, which stays literal.
  - `src/index.html`: the browser-tab title. The WHOLE title is the token
    `BRAND_TITLE`, unlike the angular-mfe per-UI `TITLE_WORD` split, because the
    host is the site.
  - `.gitlab-ci.yml`: only the `include: project:` org/group.
- **Left literal (code identity):** views, guards and session logic. Also the
  per-tenant remote SET. That set is a runtime manifest surface (the assets floor
  plus the DB-driven `/api/federation/manifest` union), not a source edit; see
  docs/FEDERATION-EXAMPLES.md.

## Per-repo identity (repos[].identity)

- `app_slug` — the EXAMPLE REMOTE the `_skeleton` wires (floor key, mount path,
  menu slug). Overlay-on-base renders ignore it, because the base carries its own
  remote set.
- `title_word` — the skeleton's menu label for that remote.

## Files

- `recipe.yaml`, `_identity.env` (drift oracle, host-shell upstream values), and
  `_skeleton/`, a RUNNABLE minimal HOST:
  - the `hugmeshHost` federation config and the shared `federation-base.js` contract;
  - the static `src/assets/federation.manifest.json` floor, pointing at the example
    remote;
  - the exemplar's dynamic-union federation-bootstrap and `main.ts`;
  - a `REMOTE_ROUTES` spec table;
  - a menu keyed off a capabilities stub;
  - BOTH palette tiers (SCSS tokens and the `--hug-*` runtime contract);
  - a nonce-CSP `nginx.conf`, an nginx-unprivileged Dockerfile, and fleet CI.

  `npm ci && npm run build` in a rendered tree is a real
  `@angular-architects/native-federation:build`.

## Honest package-lock regeneration (procedure)

Same procedure as the angular-mfe archetype README, with this identity:

1. `OFFLINE=1 scripts/render-repo-tree.sh brands/example.conf --enable-repo-tree \
      --repo host-shell --archetype angular-host --out-dir /tmp/lockgen \
      --set APP_SLUG=hello --set TITLE_WORD=Hello`
2. `npm install` in the rendered tree, then prove it: `npm ci && npm run build`.
3. Copy `package-lock.json` back to `_skeleton/package-lock.json.hbs`. Re-tokenize
   ONLY the top-level `"name"` and `packages[""].name` values to
   `@<NPM_SCOPE-token>/<HOST_NAME-token>` (the two mustaches `package.json.hbs`
   carries). Leave integrity hashes byte-exact; the `sha512-` SRI prefix keeps the
   secret-scan entropy gate green.
4. Re-render and run `npm ci && npm run build` once more to prove the round-trip.
