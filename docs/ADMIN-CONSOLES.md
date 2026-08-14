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

**Route access is the one to be careful with.** `GET /bff/admin/route-access` returns
`{"rules":[]}` even for a superadmin, while the gateways are enforcing 129 seeded rules
from a different database. Anything you add through that console lands in a table no
gateway reads. Treat the panel as non-functional until the binding is fixed; the
enforced rules live in `route-access-db`.

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

---

## Appendix: if the browser refuses to open the mesh

If Chrome blocks `https://localhost:8488` with **no** "proceed anyway" link while
`curl -sk` works, your browser has an HSTS pin for `localhost` from an earlier build
(the gateway used to emit HSTS, which combined with a self-signed certificate makes
the error non-bypassable). Clear it once at `chrome://net-internals/#hsts` →
*Delete domain security policies* → `localhost`.
