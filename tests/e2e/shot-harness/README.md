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

**Every row must end up waiting for something** — at least one
`expect`/`expectAttached`/`expectHidden` naming a `data-testid` on the screen you
are capturing. `page.goto()` resolves on load, not on render, and `signin-only`
returns the instant it clicks submit. Without a wait, the shot lands on the
previous screen and gets filed under a name that says otherwise. The validator
rejects a row that has no wait.

**Every `testid` must exist.** Verify against the UI source (`data-testid="…"` in
`hugmesh-login-ui`, `-host-shell`, `-user-ui`, `-admin-ui`, `-mod-ui`, `-wiki-ui`,
`-superadmin-service-catalog-ui`) or against `tests/e2e/specs`. A testid nobody
shipped sends a tester hunting for a control that does not exist.

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
| `shots.sh` | the one command: preflight, credential read, run |
| `capture.spec.ts` | the driver; reuses `specs/helpers.ts` `onboard()`/`shot()` |
| `evidence.mjs` | the is-this-really-evidence check; runs offline on any PNG |
| `shots.config.ts` | Playwright config for this lane only (not in `npm test`) |
