# shots.json reconcile — 2026-09-16

Reconciliation of `tests/e2e/shot-harness/shots.json` against the 17 LIVE manual
test plans (#290 #292 #294 #295 #296 #297 #298 #299 #300 #301 #302 #303 #307 #310
#311 #313 #314). Bodies fetched 2026-09-16 with `gh issue view --json body,comments`;
all 17 were last edited 2026-09-10; the single comment (#313, 2026-09-06) predates the
UI-first rewrite and cites no shot.

**Input.** The shared checkout's uncommitted working-tree file (md5
`8343afd864c4297167309f8c232a492a`, 195 rows, 17 personas) — the 17 lane agents'
concurrent appends and the survivor of two lost-update incidents (their journal
confirms: one lane reformatted the file and ran `git checkout` on it, destroying ~67
rows other lanes re-appended; another found its rows overwritten). HEAD `bb20f354`
carried 8 rows. The file was COPIED out; the shared checkout was not touched.

**Output.** 193 rows, 17 personas, on `docs/shot-table-rows` off origin/main
`3f80816e`. `node shot-table.mjs validate` → `shots.json OK — 17 personas, 193 shots`.
Versus the input: 0 added, 45 changed, 2 removed, 148 byte-identical. Versus HEAD:
190 added, 1 changed, 5 removed, 2 identical. The file is emitted in HEAD's and the
README's established shape (2-space, one-line action objects) — the lanes' copy was a
plain `JSON.stringify(…, null, 2)`.

This pass was done twice: a first attempt in this session produced 42 changes and a
draft of this file but died before committing; every one of its claims was then
re-derived independently (fresh issue fetch, fresh UI-repo fetches, own scripts) and
three more classes of defect were checked that it had not (gateway 403 documents,
vacuous waits, login handles vs the seeder). The three additional row changes and the
measurements below come from the second pass.

## Per-persona verdict — bijection holds for all 17

"cited" = every `shots/<persona>-NN-slug.png` the live body mentions. "hand/page" =
citations the plan itself marks as NOT harness rows. "harness" = cited − hand/page.
The required bijection is **harness ⇔ `shot-table.mjs paths <persona>`**.

| persona | issue | cited | hand/page | harness | rows | vs input | verdict |
|---|---|---|---|---|---|---|---|
| anonymous | 290 | 6 | 0 | 6 | 6 | −2 orphans, 2 changed | OK — HEAD's 01/02 were renumbered to 03/05 by the lane; #290: `--paths` "must print exactly the six" |
| games-namespace-admin | 292 | 13 | 0 | 13 | 13 | 3 changed | OK |
| moderator | 294 | 17 | 0 | 17 | 17 | 6 changed | OK — HEAD's `moderator-01-mod-console` is uncited (step 1 is `docker ps`); the lane's journal says it was superseded by 10-mod-home |
| pending | 295 | 10 | 0 | 10 | 10 | 0 | OK as found — see H3 |
| mesh-operator | 296 | 12 | 0 | 12 | 12 | 2 changed | OK — rows 08/09, which the plan's own † note called unpassable, now start at `/` |
| device-owner | 297 | 10 | 9 | 1 | 1 | 0 | OK — 8 "by hand" + `-20-anon-admin-401` ("is by hand: the 401 body is empty") correctly absent |
| superadmin | 298 | 18 | 0 | 18 | 18 | 6 changed | OK — incl. one inverted assertion (step 18) |
| member | 299 | 22 | 0 | 22 | 22 | 9 changed | OK — incl. the N15 guard target |
| games-operator | 300 | 9 | 0 | 9 | 9 | 0 | OK as found — see H1, H4 |
| image-builder | 301 | 12 | 3 | 9 | 9 | 1 changed | OK — 3 Casdoor-console shots correctly absent; step 20 re-based on its Do item 1 (H2b) |
| games-store-member | 302 | 7 | 0 | 7 | 7 | 4 changed | OK — see H4 (`e2e-gamesservices` is manufactured by steps 5–7) |
| studio-operator | 303 | 26 | 21 | 5 | 5 | 2 changed | OK — 7 `page` + 14 `hand` absent; the 5 `web` rows present |
| admin | 307 | 23 | 0 | 23 | 23 | 2 changed | OK — HEAD's `admin-01-admin-console` uncited |
| games-member | 310 | 12 | 1 | 11 | 11 | 2 changed | OK — step 18 hand shot absent; step 12 is H2a |
| curtailed-member | 311 | 20 | 14 | 6 | 6 | 0 | OK — plan: "The harness produces six of these: 04, 05, 06, 09, 10, 20"; matches exactly |
| own-client | 313 | 15 | 0 | 15 | 15 | 3 changed | OK — 25/26/30 gained a present wait (below) |
| fleet-owner | 314 | 9 | 0 | 9 | 9 | 3 changed | OK |

Totals: 241 cited = 48 hand/page + 193 harness rows. Orphans after this pass: 0.
HEAD's `superadmin-01-signed-in-home` is likewise uncited by #298 and absent.

## Testid verification — 205 unique, 0 unverified

All 14 UI repos were fetched (`env -u GH_TOKEN -u GITHUB_TOKEN git fetch`) and the
sweep ran on **origin/main** (`git grep -a`), because six local checkouts are behind:
host-shell by 41 commits, login-ui 12, wiki-ui 12, character-studio-ui 10, tube-ui 9,
superadmin-service-catalog-ui 7, forum-ui 7, mod-ui 6, mastodon-ui 3, matrix-ui 2.
181 testids are literal `data-testid="…"` on origin/main (none is literal only in a
stale checkout). 24 are template-generated, each confirmed at its generator:

- `home-card-nav-{admin,mod,forum,matrix}[-help]` — host-shell `menu.component.html:252,263,274` (`'home-card-' + entry.testid`); entries `nav-matrix` :275, `nav-forum` :288, `nav-admin` :307, `nav-mod` :315 in `menu.component.ts`.
- `card-{admin,forum,games,games-admin,matrix,mastodon}[-help]` — `home-services.component.html:7,17,27` (`'card-' + card.id`); ids at `home-services.service.ts:37-81`.
- `menu-mod`, `menu-character-studio` — `header-controls.component.html:167` over `header-controls.component.ts:121,157`.
- `subnav-admin-{domains,device-licenses,egress-vpn}` — `menu.component.html:224` (`section.testid`) over `menu.component.ts:241,231,240`, all three `show: () => this.session.isSuperadmin()`.
- `grant-ROLE_*` / `revoke-ROLE_*` — admin-ui `roles.component.html:44,52` over `roles.component.ts:62,66,69,86` (ROLE_MATRIX, ROLE_GAMES, ROLE_MATRIX_EXTERNAL_CLIENT, ROLE_IMAGE_BUILDER).

## Why 36 of the 45 changes are route changes (verified end to end)

`capture.spec.ts` does `if (row.route) await page.goto(row.route)` — a HARD document
GET. Three facts, each read from source this pass:

1. **Gateway.** `tests/stack/gateway-routes/fe/application-routes.yml` routes `/login/**`
   (:154), `/admin/**` (:160), `/mod/**` (:168), `/user/**` (:174) to the remote's own
   container with `StripPrefix=1`. The SPA deep-link fallback `remote-deeplink-to-host-shell`
   (:88-92, `Header=Accept, .*text/html.*`) lists only `/social/matrix|mastodon|forum`,
   `/wiki`, `/tube`, `/owncast`, `/character-studio`, `/character-forge`. Its comment (:68-70)
   says `/user`, `/admin`, `/mod` "have NO gateway route" — false; they do.
2. **Remotes.** user-ui, admin-ui, mod-ui `nginx.conf` (origin/main) all carry
   `try_files $uri $uri/ /index.html` (:232, :77, :213) — a hard GET on `/admin/roles`
   boots the STANDALONE remote: no header, no menubar, no cards, no `denied-notice`.
3. **Shell.** `menu.component.ts` `isHomeUrl()` (:106-110) matches `/user` exactly;
   `homeCardsActive` (:180-182) = loggedIn && isHomeUrl; `barVisible` (:188-193) is false
   then, and the template's `@else if (homeCardsActive())` branch (:231) renders
   `home-services-nav` (:243) with `home-card-<entry.testid>` cards over
   `serviceCardEntries()` = visible entries minus Home (:334-336) — so `nav-home` is
   never on `/user`. `card-<id>` renders only in `HomeComponent` at `/home`
   (`app.routes.ts:150`; spec `18-rbac-phase8-10-pending.spec.ts:225-231` says so).
   `roleHomeGuard` (`role-home.guard.ts:42-44`) sends `''` to `/login` | `/login/appeal` |
   `/user`. `menu-bar-mode.service.ts:79` defaults to `'static'`.

No committed spec contradicts this: the four specs that hard-`goto` a remote prefix
(08:80, 09:83, 33:139, 33:152) wait only on remote-owned content. An ownership
cross-check (every row on a remote prefix × the repo owning each testid it waits on)
found no row waiting on a shell-only testid except two on deep-linked prefixes
(`pending-13` on `/social/matrix`, `games-member-15` on `/character-forge/`), which the
fallback route sends to the shell. Every `home-services-nav`/`home-card-*`/`nav-submenu`
row now starts at `/`; every `card-*` row at `/home`.

## Changes (45 rows) — grouped by reason

Every changed row carries a `note` suffix `[reconciled 2026-09-16] …`.

**Removed (2).** `anonymous-01-front-door`, `anonymous-02-login-form` — HEAD rows the
lane renumbered to 03/05; not cited by #290.

**`/user` → `/` (22).** member-02, moderator-07/08/09/24/38/40, fleet-owner-05/06/20,
member-05 (`/user/profile`)/22, anonymous-15, own-client-30, mesh-operator-08/09,
games-store-member-08/15-services-nav/15-profile-menu-no-consoles/17, admin-03,
games-member-19. Actions unchanged.

**→ `/home` (8).** member-06/19/20/21, games-namespace-admin-10 (both rows),
studio-operator-17/18. Actions unchanged.

**`/admin` → `/` + `click home-card-nav-admin` (4).** admin-06-console-nav,
superadmin-09 (both rows), superadmin-08-admin-console (its `click nav-admin` replaced by
the card click, `expect nav-admin` added — the bar is back once the console is active).

**Bar entries on `/user` (4).** superadmin-07: `nav-admin`/`nav-mod` →
`home-card-nav-admin`/`home-card-nav-mod`. superadmin-18-pure-superadmin-home: the row
expected `nav-admin` VISIBLE; plan step 18 says Admin is **absent** and Moderation
offered → `expect home-services-nav`, `expectHidden home-card-nav-admin`, `expect
home-card-nav-mod`. games-member-06: `nav-home` → `home-services-nav`.
games-namespace-admin-05: `card-games-admin` → `home-card-nav-admin`.

**Guard targets (2).** member-28-games-denied: `denied-notice` → `login-view` —
`games.guard.ts:22-25` returns `parseUrl('/login')`, not a `roleGuard()` factory guard.
superadmin-18-denied-notice: `/admin` → `/home?denied=%2Fadmin` — `role-guard.factory.ts:6,44-46`
is what produces `denied-notice`; a hard `/admin` is the bare admin-ui.

**Others (2).** member-04-menubar-member: `/user/profile` → `/about` (bar hidden on
`/user`, bare remote on a hard `/user/profile`; `/about` is an unguarded shell page,
`app.routes.ts:155`). anonymous-16-no-session: `/login` → `/` (a hard `/login` is the
standalone login-ui, where both `expectHidden` checks are vacuous; `/` is one of the four
routes step 16 lists, and `loginChromeHidden` (`menu.component.ts:162-164`, `isLoginUrl`
:82-84) is exactly the barless state the step describes).

**Second-pass changes (3 rows + 1 note).**

- `image-builder-20-admin-denied`: `/admin` + `expectHidden admin-menu` → `/` + `click
  profile-trigger`, `expect menu-logout`, `expectHidden menu-admin` — plan #301 step 20
  **Do item 1**. As written the row hard-GETs `/admin` as `e2e-user`; the fe route-access
  row `/admin/** → ROLE_ADMIN` (`20-schema.sql:515`) answers an EMPTY 403 document, which
  is a flat frame (measured, below) that `evidence.mjs` deletes — the plan would cite a PNG
  that never appears.
- `own-client-25`, `own-client-26`: `expect matrix-view` prepended. Their only wait was an
  `expectHidden`, which resolves on a blank page before the shell boots. `matrix-view` is
  the root `<section>` of `MatrixChatComponent` (`matrix-chat.component.html:1`), which
  hosts `<hug-client-connect-banner>` (:6) and is `MATRIX_ROUTES` path `''`
  (`matrix.routes.ts:14`) — the "chat view" the plan says to look at.
- `own-client-30`: `expect menu-logout` inserted after `click profile-trigger` so the row
  waits on the OPEN menu, not on two absences (`menu-logout` is `show: () => true`,
  `header-controls.component.ts:161`).
- `member-05` note corrected: its original route was `/user/profile`, not `/user`.
- `//routing` top-level comment kept; its pointer to this file removed (a later stage may
  delete it).

**Order.** Rows sorted by `personas[]` order, then `step` (stable), so `paths <persona>`
prints in plan order.

## Measurements made this pass (offline, no stack)

```
$ node shot-harness/shot-table.mjs validate
shots.json OK — 17 personas, 193 shots
$ bash -n shot-harness/shots.sh; node --check shot-harness/shot-table.mjs; node --check shot-harness/evidence.mjs   # all OK
```

**An empty 403 document IS a flat frame** (settles H2). A local `http.createServer`
answered `/empty403` (403, no body) and `/html403` (403, `text/html`, empty); Playwright
1.61.1's cached chromium (headless, 1280x900, `fullPage`) screenshotted each; RAM 20G
available. `page.url()` stayed the requested URL (not `chrome-error://`), body text `""`.
With `pngjs` resolvable, `evidence.mjs` → `every sampled pixel is identical (1280x900
flat frame) … REJECTED`, exit 1, for BOTH; a 200 page with text → `evidence (1608x900,
7913 bytes, flat-checked=true)`, exit 0. So any row whose document the gateway 403s
with an empty body loses its PNG every run.

**`evidence.mjs` fails OPEN without pngjs** (H9). The same two PNGs judged from a
directory with no `node_modules` → `evidence (1280x900, 5289 bytes, flat-checked=false)`,
exit 0. This is deliberate (`evidence.mjs:50-52`: "a box without it loses THIS check and
keeps every other one") and `npm run shots` runs from `tests/e2e` where `npm ci` installs
pngjs — but a blank PNG is accepted as evidence on any box where that install is missing.

**Gateway decision per row.** Every row's `route` (and `goto`) was run through the fe
route-access rules (`20-schema.sql`, all `hugmesh-fe-gateway` rows, longest pattern
wins per `GatewayRouteAccessService.decide()` :177-227; unmatched = `NO_RULE`, forwarded)
against the login's roles (`rbac-roles.ts`, `e2e-extra-personas.sh:53-64`,
`seed-e2e.sh:430`), honouring the SUPERADMIN cross-domain and ADMIN own-domain bypasses
(`GatewayRouteAccessFilter.java:187,218`). 190 routed rows: 61 PUBLIC, 31 NO_RULE,
30 ALLOW, 36 admin-bypass, 28 superadmin-bypass, 4 DENY. Of the 4: `pending-13` is a
false positive — #295 step 13 MEASURED 2026-09-05 that the gateway serves the shell
(`200 text/html`, same `main-*.js`) to the pending jar, so the session carries more than
the static catalogue's `roles: []`; `games-operator-19` depends on #300's own Casdoor curl
granting `e2e-mod` `ROLE_GAMES_SERVICES_RUNNER` (H4); `image-builder-20` was fixed above;
`games-member-12` is H2a.

**Login handles.** 19 distinct. 17 are seeded (`rbac-roles.ts` catalogue via
`seed-e2e.sh`, `e2e-extra-personas.sh`, or `@superadmin` → `SUPERADMIN_USERNAME`).
`e2e-gamesservices` (6 rows, #302) and `qa-tester` (1 row, #303) exist NOWHERE in the
tree — both are created by their plans' own steps. `mesh-operator` (37 rows, 8 personas)
exists only under `SEED_COMPLETE_REGISTRATION=1` (`seed-e2e.sh:431-433`).

## Hazards — need a decision, NOT fixed here

**H1 — 104 rows hard-GET a remote prefix and photograph the bare remote.** Every row on
`/login…` (26), `/admin/…` (59), `/mod/…` (12), `/user/…` (14) whose waits are
remote-owned DOES capture, but shows the standalone remote with no shell chrome — the
F4 failure shape of #296, the defect the operator reported 2026-08-14 for the social
remotes. (`/login` rows are fine: the standalone login-ui is the designed door.) Two ways
out: (a) fix the gateway — add `/user/**,/admin/**,/mod/**` to the deep-link route's Path
list, which also fixes refresh-on-`/admin` for humans and makes the :68-70 comment true;
(b) rewrite the `/admin/<section>` rows as `/` + `click home-card-nav-admin` + `click
subnav-admin-<section>` (34 subnav testids exist; none for `/admin/oidc-providers` or
`/admin/games-services`). Not done: it changes what the shot depicts versus the plan's
literal *Go to*, and (a) makes it unnecessary.

**H2a — `games-member-12-games-admin-403` will be DELETED every run.** Plan #310 step 12
cites a harness PNG of "blank page, document status 403, empty body" and says "the
harness settles by asserting `games-admin-todo-badge` is not there". Measured above: that
document is a flat frame; `evidence.mjs` deletes it and the capture test FAILS on this
row. Either the plan marks step 12 by hand (as #297 does for `-20-anon-admin-401`) or the
row goes. Row kept so the citation is not dangling today; the decision is the plan
author's. **H2b** — `image-builder-20` had the same shape and a UI alternative inside
its own step; that one was re-based (above) and the plan author should confirm the shot
now depicting Do item 1 is acceptable.

**H3 — pending rows sign in six times as `e2e-pending` (05, 11, 12, 13, 14, 17).** All
six are `signin-only` (`registerOnly`: fill, submit, return) — none clicks
`login-complete`, so none completes registration or mutates the fixture. But
`registerOnly()` returns the instant it clicks submit, and five of the six then
`page.goto(route)` (11/12/14/17 → `/`, 13 → `/social/matrix`) — racing login-ui's own POST
`/bff/login` → hydrate → provision → hard nav. If the cookie is not set when the document
loads, `roleHomeGuard` lands on `/login` and the row's `expect home-services-nav` times out. Six attempts also approach Casdoor's
`failedSigninLimit=5` if the credential is wrong; #295 gates the run on step 1 for that
reason. Unverified live.

**H4 — logins no seeder creates.** `e2e-gamesservices` (7 games-store-member rows) is
manufactured by #302 steps 5–7; `e2e-mod`'s `ROLE_GAMES_SERVICES(_RUNNER)` for
`games-operator-19` by #300's Casdoor curl; `qa-tester` (studio-operator-18) in Studio by
hand. The harness must run AFTER those steps, or those rows 401/403.

**H5 — `mesh-operator` exists only on the `SEED_COMPLETE_REGISTRATION=1` path.** 37 rows
across 8 personas; on a plain `make stack-seed` every one 401s at sign-in.

**H6 — the games service is DEFAULT-OFF.** Spec 18 documents `card-games`/`card-games-admin`
in state `absent` on every lane this repo brings up; the 6 rows expecting them assert
visibility only, so they capture the greyed card with "not available on this deployment"
helptext, not the role text #292 step 10 lists first.

**H7 — bounced-to-`/login` rows while signed in.** admin-38, admin-45, superadmin-22,
games-namespace-admin-18/22, games-store-member-15-games-bounced, member-28 expect
`login-view` after a client guard `parseUrl('/login')` with a live session; what login-ui
renders for an already-authenticated visitor is asserted by no spec found. Unverified.

**H8 — mutating rows.** image-builder-13/14 (grant/revoke ROLE_IMAGE_BUILDER),
own-client-20/24 (grant/revoke ROLE_MATRIX_EXTERNAL_CLIENT), games-member-18
(revoke ROLE_GAMES), games-operator-14/15/17 (suspend/resume/terminate), admin-11
(suspension), admin-15 (announcement), mesh-operator-15/16 (wiki page / forum topic),
curtailed-member-10 (appeal). Running a persona twice, or out of step order, changes what
later shots show.

**H9 — `evidence.mjs` accepts a blank PNG when pngjs is absent** (measured above).

## Plan-text discrepancies (for the plan authors — rows were made to match the UI)

1. #298 step 7: "menubar shows Admin (`nav-admin`) and Moderation (`nav-mod`)" on `/user` — cards `home-card-nav-*`; the bar is hidden there.
2. #298 step 18: `nav-admin` absent / `nav-mod` offered — same card rendering.
3. #310 step 6: "menubar … Home (`nav-home`)" on `/user` — no bar, and Home is filtered out of the cards.
4. #292 step 5: "Admin is one click away in the left menubar (`nav-admin`)" on `/user` — `home-card-nav-admin`.
5. #292 step 10: the `card-games` grid on `/` — it renders on `/home` only.
6. #299 steps 6, 19, 20, 21: `card-*` on `/user` — `/home`.
7. #303 steps 17/18: `card-admin` on the post-sign-in landing — `/home`.
8. #299 N15: `gamesGuard` bounces to `/home?denied=%2Fgames` — `games.guard.ts:25` returns `/login`.
9. #299 step 4: "Go to `/user/profile`" for the member menubar — bare remote on a hard GET; row uses `/about`.
10. #310 step 12 cites a harness PNG of an empty-body 403 (H2a).
11. #301 step 20 cites a harness PNG of `/admin` as e2e-user — an empty-body 403 (H2b, re-based).
12. `application-routes.yml:68-70`: "/user, /admin and /mod … have NO gateway route" — they do (:160-179).

## What a human must still verify

Nothing here ran against a mesh. Verified offline only: table validity, testid existence
on origin/main, route serving by reading the gateway table, the remotes' nginx and the
shell's router/menu code, the gateway's route-access decision per row, and the evidence
guard's behaviour on an empty-403 document. A live `npm run shots -- --persona <p> --door …`
per persona, on a `SEED_COMPLETE_REGISTRATION=1` stack, after each plan's manufacturing
steps, is the only proof the 193 rows capture what their plans say; H1/H3/H7 can only be
settled there.

`npm ci` was not run (RAM 20G available; not needed): the offline checks used a temporary
symlink to the shared checkout's `tests/e2e/node_modules` (pngjs 7, @playwright/test
1.61.1, chromium-1228 cache), removed before commit. No compile, test suite, stack,
cluster, image build or QEMU was started.
