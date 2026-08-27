# What this repo CANNOT land for the Service Catalog console

The Deployment, Service, ServiceAccount, NetworkPolicy, Application, gateway route and
push credential in this PR make the console **servable**. Two things still stand between
that and a superadmin actually seeing it, and **neither is landable in this repo**. They
are written out here in full rather than half-done, because a half-applied cross-repo
change is how the original chain came to have four of its five links.

Precedent for a file like this: `manifests/character-forge/FEDERATION-REGISTRATION-TODO.md`.

---

## 1. The host-shell mount (repo: `hugmesh/hugmesh-host-shell`) — REQUIRED

**Why a `federation_modules` row is not enough.** `src/app/app.routes.ts` in the host
shell is a **static array**. Every federated remote is mounted by a literal
`RemoteRouteSpec` entry in it:

```ts
{ path: 'character-forge', remoteName: 'character-forge', exposed: './routes',
  routesConst: 'CHARACTER_FORGE_ROUTES', canActivate: [registeredGuard] },
```

`remoteRoute()` turns each spec into an Angular `Route` whose `loadChildren` calls
`federationLoader.load(remoteName, exposed)`. The DB registry supplies the remote's
**URL** at runtime (the dynamic manifest); it does not create a route. A row with no
matching spec mounts nothing at all — the path falls through to the `'**'` redirect,
which is precisely how the `forum` launcher card was a dead link until its spec was
added.

**The exact change.**

1. New guard `src/app/guards/superadmin.guard.ts`, built from the existing
   `roleGuard` factory exactly like `tube.guard.ts`:

   ```ts
   export const superadminGuard: CanActivateFn = roleGuard(
     (session) => session.isSuperadmin(),
   );
   ```

   `SessionService.isSuperadmin()` already exists (`tube.guard.ts` calls it). Note the
   factory's two destinations: not-signed-in → `/login`, signed-in-without-the-role →
   `DENIED_PATH` with `?denied=`. Do not hand-roll a redirect.

2. One entry in the `REMOTE_ROUTES` array of `src/app/app.routes.ts`:

   ```ts
   { path: 'superadmin/service-catalog', remoteName: 'service-catalog',
     exposed: './ServiceCatalog', routesConst: 'SERVICE_CATALOG_ROUTES',
     canActivate: [superadminGuard] },
   ```

   Three of those four values are **not free** — they are read off artefacts that
   already exist and must match byte-for-byte:

   | field | must equal | source of truth |
   | --- | --- | --- |
   | `path` | `superadmin/service-catalog` | `spec.mountAt` of `manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml`, minus the leading `/` |
   | `remoteName` | `service-catalog` | the `name:` in the UI repo's `federation.config.js` — **not** the manifest key |
   | `exposed` | `./ServiceCatalog` | the `exposes:` key in that same file, and `spec.exposedModule` in the descriptor |
   | `routesConst` | `SERVICE_CATALOG_ROUTES` | the exported const in the UI repo's `src/app/service-catalog.routes.ts` |

   ⚠ `remoteName` is the trap the character-* entries already paid for, and the comment
   above them in `app.routes.ts` records it: native-federation registers a remote under
   the `name` declared **inside its own remoteEntry.json**, not under the key used in
   the manifest. A camelCase key (`serviceCatalog`) registers fine and then throws
   *"Remote 'serviceCatalog' is not initialized"* at `loadRemoteModule` time, with **no
   failed network request to point at**, because the entry was already fetched under its
   real name. Use the kebab-case `service-catalog`.

**This mount does nothing until the superadmin gateway serves the shell.**
`apps/22-gateway-superadmin.yaml` has no `hugmesh-host-shell` route, no `login-ui` route
and no `/bff/login` route, so over the tailnet there is no shell to mount anything into
and no way to authenticate. That is a separate, known gap (the superadmin-gateway
shell/login wave), not something this file's change substitutes for.

---

## 2. The in-remote absolute redirect (repo: `hugmesh/hugmesh-superadmin-service-catalog-ui`) — REQUIRED

`src/app/service-catalog.routes.ts` documents its own mount as `/service-catalog` and its
`superadminGuard` `false`-path routes to **`/service-catalog/forbidden`** — an absolute
router URL.

Under the host shell the remote's routes are mounted at the host's path, so an absolute
`/service-catalog/forbidden` navigates to a URL the host has no route for and the user
lands on the `'**'` redirect instead of the forbidden screen. This is broken for **any**
host mount that is not literally `/service-catalog`, so it is not a consequence of the
path this PR settled on — reconciling to `/service-catalog` would not fix it either,
because the shell would still own the URL space.

The fix is to make the denial **relative** (a `RouterStateSnapshot`-derived redirect, or
a child `forbidden` route reached with `relativeTo`), never a hardcoded absolute path.
Same class as the standing repo note that a `routerLink` written absolutely works
standalone and breaks under the shell.

---

## Why the mount path is `/superadmin/service-catalog`

Three in-tree artefacts disagreed. The decision and its reasons are in the commit
message; the short version is that `specs/cluster/reserved-prefixes.yaml` already
**reserves the first path segment `superadmin`** with the stated justification
"the TAILNET superadmin Service Catalog console remote is served at
`/superadmin/service-catalog/**` on the superadmin-gateway". Picking `/service-catalog`
would have left that reservation's rationale dangling and required reserving a **new**
apex segment. `docs/ARCHITECTURE.md`'s `/appstore` was the odd one out and is corrected
in this PR. The UI repo's `/service-catalog` is item 2 above.
