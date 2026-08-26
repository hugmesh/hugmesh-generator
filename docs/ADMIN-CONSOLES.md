# Admin consoles — where they are, who can open them, what actually works

Every URL, role and status below was **probed live** against a running local mesh on
2026-08-14. Where a console renders but its backend is dark, this document says so
rather than listing it as available — a console that looks like it worked and changed
nothing is worse than one you knew to avoid.

Front door: **https://localhost:8488** (self-signed certificate; accept the browser
warning). If the browser refuses the page outright with no "proceed" option, see
[HSTS](#appendix-if-the-browser-refuses-to-open-the-mesh) at the end.

---

## 1. Sign in with an account that holds the roles

Every console is role-gated, and the `e2e-*` personas are deliberately narrow — they
are test fixtures, so they will open a console and then 403 half of its calls. On a
Studio-bootstrapped mesh the account that holds everything is **`mesh-operator`**:

```
roles: admin, fleet_admin, forum, games, mastodon, matrix, mod, superadmin, user, wiki
```

Sign in at **https://localhost:8488/login**.

If `mesh-operator` does not exist, the stack was seeded without registration stage 2.
Re-seed with `SEED_COMPLETE_REGISTRATION=1` (a plain `make stack-seed` omits it, and
then every platform action 403s). The Studio's local-mesh page does this for you.

The `superadmin` account's password is in your own minted secrets bundle
(`keys-out/vault/secrets.json`) — it is generated per mesh and never displayed in the
UI. You only need it for the `/admin/routes` panel below.

Narrow test personas, all with the shared e2e password: `e2e-admin` (admin, user),
`e2e-mod` (mod), `e2e-matrix` (matrix, user), `e2e-mastodon` (mastodon, user),
`e2e-user` (user).

### Granting a role

Two ways today:

* **Studio → Local mesh → "Add user…"** — creates an account with chosen roles by
  re-running the idempotent seeder. This is the supported path.
* `POST /bff/admin/roles/{roleName}/{user}` (ROLE_ADMIN) — the API exists; see the
  Roles panel note in §2.

---

## 2. Cross-platform (mesh) consoles

| Console | URL | Role | State |
|---|---|---|---|
| Admin console | `/admin` | `ROLE_ADMIN` | works |
| Usage analytics | `/admin/usage` | `ROLE_ADMIN` | works, live data |
| Delegation & access roles | `/admin/delegation` | `ROLE_ADMIN` | works |
| Account-ban appeals | `/admin/account-appeals` | `ROLE_ADMIN` | works |
| Moderation console | `/mod/console` | `ROLE_MOD` or `ROLE_ADMIN` | works (2 panels dark, below) |
| System findings triage | `/mod/findings` | `ROLE_MOD` or `ROLE_ADMIN` | works |
| Route access rules | `/admin/route-access` | `ROLE_ADMIN` | **dark — reads the wrong database** |
| Route definitions | `/admin/routes` | `ROLE_SUPERADMIN` | partial — an ADMIN sees an empty table, not a denial |
| ArgoCD applications | `/admin/argocd` | `ROLE_ADMIN` | **dark — no backend controller exists in any repo** |

**Route access is the one to be careful with.** `GET /bff/admin/route-access` returns
`{"rules":[]}` even for a superadmin, while the gateways are enforcing 129 seeded rules
from a different database. Anything you add through that console lands in a table no
gateway reads. Treat the panel as non-functional until the binding is fixed; the
enforced rules live in `route-access-db`.

**The ArgoCD dashboard is worse than dark — it renders as if it succeeded.**
`hugmesh-admin-ui`'s `bff.service.ts` calls `/bff/admin/argocd/applications`,
`/{name}` and `/{name}/sync`. **No controller serves any of those paths in any repo
in the org.** Verified by a comment-stripped scan of every `@RestController` /
`@RequestMapping` class: the only ArgoCD code in `hugmesh-admin-bff-api` is the
App-Store effector's `ArgoCdClient` (create/delete an `Application`, ships dark
behind `NoopArgoCdClient`), which has **no HTTP surface at all**. The controller was
planned on a branch named `feat/argocd-admin-module` — named in
`admin-bff-api/src/main/resources/db/changelog/007-data-constraints.xml` — and that
branch no longer exists on any remote.

Why this reads as success rather than as an outage:

* The gateway is **not** the blocker. There is no `/bff/admin/argocd/**` row, but the
  seeded `('hugmesh-fe-gateway', '/bff/admin/**', 'ROLE_ADMIN', true)` floor already
  covers the prefix, so an admin's request is authorized and forwarded — and then the
  admin BFF answers **404**, because nothing is mapped.
* The UI only treats **503** as "ArgoCD not connected"
  (`if (r.status === 503) return { items: [], unavailable: true }`). A 404 falls to
  `r.ok ? … : { items: [], unavailable: false }`, so `unavailable` stays false.
* The capability gate does not save it either: `argocdPresent` is satisfied by the
  cluster-scoped `applications.argoproj.io` CRD, which really is installed, so the
  gate passes and the live dashboard renders.

Net effect: an admin opens `/admin/argocd` and sees an **empty application grid with
no warning** — "ArgoCD is connected and manages zero applications" — on a mesh where
ArgoCD is in fact managing the entire platform.

**Decision: remove the page rather than add the row.** Adding a route-access row
would be a no-op (the floor already covers the prefix) and adding a *narrower*
`/bff/admin/argocd/**` row would be actively harmful — longest-pattern-wins means it
would shadow the floor, and it would create the appearance of wiring where the only
missing piece is a controller nobody has written. A row that authorizes a 404 is the
"green surface that proves nothing" pattern in route form.

The edit is **CROSS-REPO — not landable from `hugmesh-generator`**. Exact change,
two repos:

1. **`hugmesh-admin-ui`**
   * `src/app/admin.routes.ts` — delete the `{ path: 'argocd', component:
     ArgocdDashboardComponent }` entry (line ~119) and its import (line ~8), and drop
     `/admin/argocd` from the route-list doc comment (line ~53).
   * Delete `src/app/argocd-dashboard.component.ts` and
     `src/app/argocd-dashboard.component.spec.ts`.
   * `src/app/bff.service.ts` — delete `argoApplications()`, `argoApplication()` and
     `argoSync()` (~lines 405–423) and the now-unused `ArgoAppList` / `ArgoAppDetail`
     / `ArgoSyncResult` types.
   * `e2e/features/admin/route-matrix.feature` — drop the `/admin/argocd` row.
2. **`hugmesh-host-shell`**
   * `src/app/menu/menu.component.ts` — delete
     `{ label: 'ArgoCD', route: '/admin/argocd', testid: 'subnav-admin-argocd' }`
     (line ~239). Leaving the menu entry while the route is gone yields a blank
     shell page, which is the same lie in a new costume.

If the page is ever *restored* instead, the missing contract is: `GET
/bff/admin/argocd/applications` → `{items:[…]}`; `GET
/bff/admin/argocd/applications/{name}` → detail incl. resource tree; `POST
/bff/admin/argocd/applications/{name}/sync` with body `{confirm:"<name>"}` →
sync result — all `ROLE_ADMIN`, all returning **503 when ArgoCD is not reachable**
(the UI's only honest-failure signal), served by the admin BFF against
`argocd-server` in the **`devops`** namespace. Note the operator must still not be
shown a sync button that cannot sync.

### The moderation console (`/mod/console`)

This is the main day-to-day moderation surface and it is genuinely wired: the
moderation queue, refer/escalate, recommend-to-admin, ban and lift with an optional
TTL, domain-lock (force a user local-only), the audit trail, and the findings queue
with confirm/dismiss. Approve/deny of a referred item is **ADMIN-only** — a moderator
sees a disabled button explaining why.

Two panels are dark on this stack, by configuration:

* **Server-wide block** (Matrix and Mastodon) writes an audit row and returns
  "pending reconcile" but has **no external effect** — both homeserver legs ship
  disabled, and the Matrix one can never work (see §3).
* The queue filter's **self-silence appeals** option has no backing rows here.

---

## 3. Matrix administration

**There is no Matrix server-admin API on this mesh, and there cannot be one today.**
The homeserver is tuwunel (Conduit family), not Synapse. Every Synapse admin path —
user list, deactivate, password reset, room list/purge, media quarantine, server
notices, registration tokens, device management — returns `404 M_UNRECOGNIZED`. Any
Synapse runbook you find online is inapplicable here.

tuwunel's only server-admin transport is `!admin` commands typed into an auto-created
`#admins` room, and no mesh account is joined to it, so that path is closed from
inside the mesh regardless of role.

**What you *can* administer: rooms you have power in.** Matrix's own power-level model
is the real authority — kick, ban, and promoting someone to moderator are room-level
operations, and the BFF proxy already forwards them. Today the Matrix UI exposes kick
but not ban/unban or a power-level editor; that gap is UI-only work, listed in §6.

Access: **`/social/matrix`**, role `ROLE_MATRIX`.

---

## 4. Mastodon administration

**Mastodon's admin API is unreachable, and it needs two independent fixes.** Probed
live as `mesh-operator`:

```
GET /bff/user/mastodon/api/v1/admin/accounts
-> 403 {"error":"This action is outside the authorized scopes"}
```

1. The server-held token is minted with scopes `read write follow` — no `admin:*`.
2. Even with admin scopes it would still fail: no account in the Mastodon instance
   holds an admin role at all.

Both must change before any Mastodon admin console can exist. Until then, Mastodon
moderation is limited to what the mesh's own moderation console does (ban a user's
platform access, domain-lock them), which acts at the mesh layer rather than inside
Mastodon.

Access: **`/social/mastodon`**, role `ROLE_MASTODON`.

---

## 5. Forum administration

Two separate things, both currently blocked:

**The mesh's forum admin console** (`/bff/admin/forum/*` — stats, categories, users,
moderation queue, audit) returns HTTP 200 with a body that says
`degraded:401 Unauthorized`. The admin BFF calls the forum BFF without a token. The
underlying data is real — the same calls made directly return live phpBB rows — so
this is one authentication seam away from working.

**phpBB's own control panels (ACP/MCP/UCP) are sealed shut on purpose.** The container
denies every `.php` entrypoint except `app.php`, and the gateway has no phpBB route,
so `/forum/adm/index.php` just returns the shell's page. Consequences worth stating
plainly:

* Board settings and the forum-tree editor are **not reachable by anyone**.
* Per-forum and per-group **permissions cannot be edited** anywhere — group
  *assignment* has an API, but what a group may *do* lives only in the sealed ACP.
* Category management is **create-only** — no rename, edit, delete or reorder exists
  in either the BFF or the phpBB extension.

Access: **`/social/forum`**, role `ROLE_FORUM`.

---

## 5b. Connecting your own Matrix / Mastodon client

The ROLES for this exist and are grantable today from **Admin → Roles**
(`ROLE_MATRIX_EXTERNAL_CLIENT`, `ROLE_MASTODON_EXTERNAL_CLIENT`), and the
platform seeds gateway rules for them:

| Role | Granted access (be-gateway) |
|---|---|
| `ROLE_MATRIX_EXTERNAL_CLIENT` | `/_matrix/client/v3/login`, `/_matrix/client/r0/login` |
| `ROLE_MASTODON_EXTERNAL_CLIENT` | `/oauth/**`, `/api/v1/apps` |

**But there is no working connection address on the local compose lane yet, so
do not hand one to a user.** Probed live 2026-08-14:

* `https://localhost:8488/_matrix/client/versions` → **200, and the body is the
  shell's `index.html`** — an SPA fallback, not a homeserver. `/api/v1/instance`
  and `/oauth/authorize` behave the same way. A native client pointed here gets
  HTML where it expects JSON.
* `/be/_matrix/client/versions` (the be-gateway path the rules name) → **401**
  unauthenticated, **500** with a session cookie.

So the grant is real, the entitlement rows are real, and the transport is not
wired on this lane. Granting the role today changes what the gateway would
*permit*; it does not yet give the user a working address. Anything that
displays a "connect your client here" URL should stay unbuilt until a native
endpoint answers a real Matrix/Mastodon handshake — a banner advertising an SPA
fallback is worse than no banner.

## 6. Known gaps (real work, not mysteries)

Ordered by value. The first two are UI-only — the backends already work.

1. **Roles panel in the admin console** — `POST|DELETE /bff/admin/roles/{role}/{user}`
   exist and are ADMIN-gated, but the only role-granting UI is the Studio desktop
   dialog. Caveat to surface when built: this stack reports `casdoorAdminEnabled:false`,
   so a grant is recorded locally but does not reach Casdoor.
2. **Matrix ban/unban + power-level editor** — the proxy already forwards these verbs;
   the UI simply has no controls, so a room admin cannot appoint a moderator.
3. Bind the route-access console to the database the gateways actually read.
4. Authenticate the admin-BFF → forum-BFF call (turns the forum console half-on).
5. Fix the phpBB extension's role re-derivation, and stop the forum BFF converting its
   403 into an empty-list 200 — that false-green reads as "no users" instead of
   "authorization is broken".
6. **Remove the ArgoCD dashboard** (`/admin/argocd`) — cross-repo, spec in §2. It has
   no backend in any repo and fails *open*, showing an empty app grid instead of an
   error. Until it is removed, tell operators not to trust it.

---

## Appendix: if the browser refuses to open the mesh

If Chrome blocks `https://localhost:8488` with **no** "proceed anyway" link while
`curl -sk` works, your browser has an HSTS pin for `localhost` from an earlier build
(the gateway used to emit HSTS, which combined with a self-signed certificate makes
the error non-bypassable). Clear it once at `chrome://net-internals/#hsts` →
*Delete domain security policies* → `localhost`.
