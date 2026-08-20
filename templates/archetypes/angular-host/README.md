# angular-host archetype

Renders the HugMesh **native-federation HOST shell** class. Exemplar member =
the site shell that mounts every angular-mfe remote — published as
`hugmesh-host-shell` (the same tree the site was historically clonable as
`hugmesh.net`). One-member class today, but a class by design: a
multi-domain tenant can grow sibling shells.

## Resolving the exemplar base

`repos[].name` must be a **DNS label**, and the host shell's published repo name
(`hugmesh-host-shell`) is one — so the manifest row `host-shell` resolves
through `pull-repo-base.sh`'s normal `hugmesh-<name>` lookup like any other
member. No override is required:

```
scripts/validate-repo-templates.sh --archetype angular-host
```

For an offline or pinned run, the usual escape hatches still apply — either
point `<NAME>_BASE_DIR` at a local read-only clone or pass `--base`:

```
HOST_SHELL_BASE_DIR=/path/to/a/host-shell/clone \
  scripts/validate-repo-templates.sh --archetype angular-host
```

The same resolution drives an overlay render (`render-repo-tree.sh --repo
host-shell` / the tenant-set driver).

## What is / isn't templated

- **Class-B anchored edits (`recipe.yaml` on the base's OWN files):**
  - `federation.config.js`: the host's federation name
    (`hugmeshHost({ name: 'hugmesh-host' })` -> the derived `HOST_NAME`).
  - `src/index.html`: the browser-tab title — the WHOLE title (`BRAND_TITLE`),
    unlike the angular-mfe per-UI `TITLE_WORD` split (the host IS the site).
  - `.gitlab-ci.yml`: only the `include: project:` org/group.
- **Left literal (code identity):** views/guards/session logic, the per-tenant
  remote SET (that is the RUNTIME manifest surface — assets floor + the
  DB-driven `/api/federation/manifest` union — not a source edit; see
  docs/FEDERATION-EXAMPLES.md).

## Per-repo identity (repos[].identity)

- `app_slug` — the EXAMPLE REMOTE the `_skeleton` wires (floor key, mount path,
  menu slug). Overlay-on-base renders ignore it (the base carries its own
  remote set).
- `title_word` — the skeleton's menu label for that remote.

## Files

- `recipe.yaml`, `_identity.env` (drift oracle, host-shell upstream
  values), `_skeleton/` — a RUNNABLE minimal HOST: `hugmeshHost` federation
  config + the shared `federation-base.js` contract, static
  `src/assets/federation.manifest.json` floor pointing at the example remote,
  the exemplar's dynamic-union federation-bootstrap + `main.ts`, a
  `REMOTE_ROUTES` spec table, a menu keyed off a capabilities stub, BOTH
  palette tiers (SCSS tokens + `--sd-*` runtime contract), nonce-CSP
  `nginx.conf`, nginx-unprivileged Dockerfile, fleet CI.
  `npm ci && npm run build` in a rendered tree is a real
  `@angular-architects/native-federation:build`.

## Honest package-lock regeneration (procedure)

Same procedure as the angular-mfe archetype README, with this identity:

1. `OFFLINE=1 scripts/render-repo-tree.sh brands/example.conf --enable-repo-tree \
      --repo host-shell --archetype angular-host --out-dir /tmp/lockgen \
      --set APP_SLUG=hello --set TITLE_WORD=Hello`
2. `npm install` in the rendered tree, then prove it: `npm ci && npm run build`.
3. Copy `package-lock.json` back to `_skeleton/package-lock.json.hbs`,
   re-tokenizing ONLY the top-level `"name"` and `packages[""].name` values to
   `@<NPM_SCOPE-token>/<HOST_NAME-token>` (the two mustaches
   package.json.hbs carries; integrity hashes stay byte-exact — the `sha512-`
   SRI prefix keeps the secret-scan entropy gate green).
4. Re-render + `npm ci && npm run build` once more to prove the round-trip.
