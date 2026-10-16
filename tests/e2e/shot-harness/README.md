# Screenshot harness for the manual test plans

Every manual test plan (issues **#290–#314**, one per persona) cites screenshots by
**path**, never by pasted image — a GitHub issue body caps at 65,536 characters and
one inline PNG does not survive that. This harness produces those files.

## The one command

```bash
cd tests/e2e && npm run shots -- --persona member --door https://localhost:8488
```

Needs a **running, seeded** stack (`make stack-up && make stack-seed`). It refuses
and exits **2** before starting a browser if the door is not answering, or is
answering but is not this platform's front door.

## Where the files land

```
tests/e2e/shots/<persona>-<NN>-<slug>.png
```

Gitignored — regenerated on demand. A committed screenshot shows a build nobody is
testing while reading as current evidence.

Print the exact lines your plan should quote:

```bash
cd tests/e2e && npm run shots -- --paths --persona member
```

## Adding a shot to a plan — no code

The shot list is **data**: [`shots.json`](shots.json). Append a row, then gate it
offline (no stack, no credential, no browser):

```bash
cd tests/e2e && npm run shots:validate
```

```json
{
  "persona": "member",
  "step": "04",
  "slug": "profile-saved",
  "auth": "onboard",
  "login": "e2e-user",
  "route": "/user/profile",
  "do": [
    { "action": "fill",  "testid": "profile-displayName", "value": "Test Member" },
    { "action": "click", "testid": "profile-save" },
    { "action": "expect", "testid": "profile-status" }
  ]
}
```

| field | values |
|---|---|
| `persona` | one of the 17 slugs — `npm run shots -- --list` |
| `step` | **two digits**, matching the plan's step number, so shots sort in plan order |
| `slug` | lower-case kebab-case |
| `auth` | `anon` (never signs in) · `signin-only` (stage 1, `helpers.registerOnly`) · `onboard` (full two-stage sign-in) |
| `login` | the seeded handle, e.g. `e2e-user`; `@superadmin` follows `SUPERADMIN_USERNAME` |
| `route` | door-relative, e.g. `/user/profile` — the door comes from `--door`, never from this file |
| `do[]` | `goto` · `click` · `fill` · `press` · `expect` · `expectAttached` · `expectHidden` |
| `first` | optional, on a testid action, **only `true`**: act on the *first* match when the UI renders that testid once per list row (admin-ui's `gs-suspend` inside `*ngFor`). Without it a second match is a strict-mode failure, on purpose — the plan must say it accepts "whichever row is first" |
| `settle` | optional, `{"mask": ["<selector>", …]}`: live regions (a `<canvas>` or `requestAnimationFrame` loop, which the settle step cannot freeze) to paint over in the two frames `waitForSettle()` compares. Selectors come from the closed `MASK_SELECTORS` list in `shot-table.mjs`, each naming the UI source that ships it; anything else fails `validate` |

**A `settle.mask` is not an opt-out.** Fonts and finite animations are still waited
for across the whole page, every pixel *outside* the masked boxes must still hold
still for two frames 300ms apart, a selector that matches nothing masks nothing, and
a mask covering more than half the viewport is refused. Only the comparison is
masked: the PNG still contains the live region as it happened to be painted. To add a
selector, read the UI source for it, then add it to `MASK_SELECTORS` with the file
that ships it. Offline pins: `npm run shots:settle-unit` (browser, no stack) and
`npm run shots:validate-unit` (no browser).

**Every row must end up waiting for something** — at least one
`expect`/`expectAttached`/`expectHidden` naming a `data-testid` on the screen you
are capturing. `page.goto()` resolves on load, not on render, and `signin-only`
returns the instant it clicks submit. Without a wait, the shot lands on the
previous screen and gets filed under a name that says otherwise. The validator
rejects a row that has no wait.

**Every `testid` must exist — and be unique on that screen**, or the action carries
`"first": true` and the plan says which row that is. `page.getByTestId()` is strict:
two matches fail the row rather than act on one. Verify against the UI source (`data-testid="…"` in
`hugmesh-login-ui`, `-host-shell`, `-user-ui`, `-admin-ui`, `-mod-ui`, `-wiki-ui`,
`-superadmin-service-catalog-ui`) or against `tests/e2e/specs`. A testid nobody
shipped sends a tester hunting for a control that does not exist.

## Rows that write, and the order they run in

Every row is an independent test that signs in afresh; rows run in `personas[]`
order, then `step` order, and **one red row costs exactly its own PNG** — no later
row is skipped for it (the driver runs in Playwright's `default` mode, not `serial`,
since 2026-09-16; the only early stop is a door that stops answering mid-run). The
epilogue prints `N of M cited PNG(s) present` and a `MISSING` line per absent file,
whichever way the run exited — read that, not the count of files in the directory.

Most rows read, or fill a form and stop *before* the write. The rows that do write
are listed in the `//state` comment at the top of `shots.json`, each a step its plan
names. Two of them interact across personas: `curtailed-member-10` files an appeal
that makes `admin-20` (expects the empty inbox) fail until an admin decides it —
`--all` runs admin first; a per-persona re-run of admin afterwards does not.

## Credentials

`"value": "@password"` resolves the seeded shared password at run time. **Never put a
literal password in `shots.json`** — the validator rejects it.

The harness **reads** `.e2e-credentials` (via `e2e_password_read`, sourced) and never
mints. `tests/stack/e2e-password.sh` *generates* when **executed** directly; minting
here would produce a password the running stack was never seeded with, and every
sign-in would fail for a reason nothing names.

## Why it refuses

An empty or error-page PNG under a believable filename is worse than no PNG: it is
indistinguishable from evidence to everyone who did not run the harness. So:

- **before the browser** — `GET <door>/` must answer, and `GET <door>/bff/session`
  must answer `200|401|403`. A bare nginx default backend answers `404` to
  everything, which is what the kind node on the neighbouring port does (measured
  2026-08-27).
- **after each shot** — PNG signature, IHDR dimensions, byte length, and a
  flat-frame check. A failing image is **deleted**, not left behind.
- **an unknown persona** fails loudly rather than capturing zero shots and looking
  clean.

## Files

| file | what it is |
|---|---|
| `shots.json` | the shot table — the only file a plan author edits |
| `shot-table.mjs` | offline validator / `list` / `paths` / `needs-auth` |
| `settle.ts` / `settle.spec.ts` | the settle step and its offline pin (`npm run shots:settle-unit`) |
| `shot-table.test.mjs` | offline pin for the `settle.mask` validation (`npm run shots:validate-unit`) |
| `shots.sh` | the one command: preflight, credential read, run |
| `capture.spec.ts` | the driver; reuses `specs/helpers.ts` `onboard()`/`shot()` |
| `evidence.mjs` | the is-this-really-evidence check; runs offline on any PNG |
| `shots.config.ts` | Playwright config for this lane only (not in `npm test`) |
