# Desktop login: local password AND SSO at the greeter

Every HugMesh desktop image (x86 client roles; every ARM builder that writes a
lightdm.conf: Frite `--desktop light`, RPi5 and Jetson `--role desktop`, Orange
Pi 4 LTS and Orange Pi 5) offers **two** ways in at the
lightdm greeter, and both must work in all three situations an image can be
in: (1) standalone, never associated with a mesh; (2) on a tailnet but not
mesh-associated; (3) mesh-associated (KEYS-provisioned). Where SSO cannot
work, the greeter says why and the local path is untouched. Nothing hangs.

| path | credential | needs | who |
|------|------------|-------|-----|
| **A. local** | the account's password in `/etc/shadow` | nothing | the `--local-pass` user (standalone), KEYS `users.json` users, the keyless first-boot fallback user. The `--local-pass` and fallback users are administrators only with `--local-admin` (`docs/STANDALONE-DESKTOP.md`) |
| **B. SSO** | approval at the per-domain IdP (`https://id.<domain>`, RFC 8628 device flow) | the IdP reachable (usually over the tailnet) | anyone the IdP knows; the account is created on the device on first sign-in |
| **B'. SSO offline** | the user's offline password (set during an online SSO sign-in) | nothing, while the bounded cache is valid | SSO-managed accounts only |

## What the user does

lightdm-gtk-greeter speaks plain PAM. The hint line above the password box
(`pam_echo`) says: *"Leave the password empty to sign in with `<brand>` SSO
(`id.<domain>`); or type your local password."*

* **Local**: pick the user, type the password. Exactly as before; the SSO
  helper steps aside without a network call.
* **SSO**: pick or type the user name (`greeter-show-manual-login=true`, so a
  user the device has never seen can type theirs), leave the password
  **empty**, press Enter. The greeter shows *"open `<url>` on your phone or any
  browser and enter the code `XXXX-XXXX`"* and *"Sign in to `id.<domain>` there
  if it asks (MFA applies), then approve. Type your SSO password only on that
  page, never on this screen."* So, on the phone or browser:
  1. open the URL. Casdoor's URL already carries the code; the page shows it
     as *"Confirmation code"* — check it matches the one on the greeter;
  2. **sign in to the IdP if it asks** — a browser that is already signed in to
     `id.<domain>` also gets a *"Continue with your current account"* button
     above the form; a fresh one gets only the IdP's own user name / password
     form, and a user who has MFA
     enrolled is then asked for the second factor (TOTP) before anything is
     approved;
  3. **approve** (*"Approve and sign in"*, or the continue button). The session
     starts.

  **Never type the IdP password on the desktop**: the greeter's password box
  means the LOCAL (or offline) password, and the greeter only ever shows a URL
  and a code. Bounded: `LOGIN_TIMEOUT` (180 s) or the code's own expiry, then
  the greeter is back; Cancel works at any time.
  *IdP side*: Casdoor starts a device flow only for an application that lists
  the **"Device login" sign-in method** (the `device_code` grant alone gets
  `unauthorized_client` — #878). With that method **alone** the approval page
  `/login/oauth/device/<code>` is a dead end for a browser that is not signed in
  to the IdP: it shows *"To access HugMesh Desktop (PKCE):"* and no input and no
  button. The `hugmesh-desktop` seed (`manifests/casdoor/init-job.yaml`)
  therefore lists **Device login + Password**: the approval page renders the
  application's own sign-in form, and signing in there IS the approval.
  Measured against `casbin/casdoor:3.80.0`:
  * a fresh browser gets the sign-in form; `alice` signs in, the desktop's token
    poll returns her token (`name` alice, `roles` [desktop-user], `aud`
    hugmesh-desktop);
  * a user with TOTP enrolled gets the MFA step after the password, and the
    token poll stays `authorization_pending` until the code is entered (the
    org's MFA policy, `reconcile_org_mfa`, is enforced by `/api/login` for every
    application). After a correct code casdoor 3.80.0 approves the device but
    leaves its page on the MFA form (no *"Logged in successfully"*); the
    desktop signs in regardless;
  * a browser already signed in to the IdP gets *"Continue with your current
    account to approve this sign-in"* above the form, one tap approves;
  * the **resource-owner password grant stays refused**
    (`grant_type=password` -> `unsupported_grant_type`): the Password sign-in
    *method* is not the password *grant*, which is `grantTypes` alone and
    omits `password`.

  Two consequences to know. Casdoor keys sign-in methods per application, not
  per page, so the PKCE authorize page for `hugmesh-desktop` also gets the
  sign-in form (the ordinary auth-code model, the IdP's page in a browser;
  nothing shipped drives that page — the greeter and `hugmesh-sso-token` use
  the device grant). And leaving Password off was never a server-side barrier:
  casdoor 3.80.0's `/api/login` checks the password method only when the
  request names `signinMethod: "Password"`, so a request that omits it signed
  in and approved a device code with Password off too. The defences are the
  ones above: the greeter never sees the password, MFA applies on the IdP page,
  and the password grant is off.
  `tests/scripts/test-casdoor-init-honesty.sh` §2c holds every seed to this:
  Device login present, a sign-in method the approval page can render
  (Password), and no `password` grant on the public device client.
* **SSO offline**: type the offline password instead. To set or change it, type
  the password you want and approve one more online sign-in (the greeter says
  so). It works while the cache is valid (`OFFLINE_MAX_AGE_DAYS`, 14 by
  default, counted from the last online sign-in).
* **First boot with no password set** (keyless boot, or standalone without
  `--local-pass`): the random one-time password went to the text console,
  which the greeter hides. The hint now says: *"'user' has a ONE-TIME password
  that the first boot printed on the text console: press Ctrl+Alt+F1 to read
  it, Ctrl+Alt+F7 to come back."* The helper detects this from `/etc/shadow`
  (a usable hash whose last-change day is 0, i.e. `chage -d 0`); the firstboot
  script is not involved and not changed.

## What SSO says when it cannot work

The reason on the greeter, then *"Sign in with your local password instead."*,
then exit 1 so the local path still runs:

* `SSO sign-in is not enabled on this device (an administrator can turn it on: sso-greeter configure --enable --issuer https://...).`
  (or: `no identity provider is configured`, `the configured identity provider is not an https URL`)
* `SSO sign-in unavailable: cannot reach id.<domain> (no tailnet agent on this image; ...)`
  / `(tailnet needs login; ...)` / `(tailnet stopped; ...)` / `<host> does not resolve`.
  The tailnet state comes from `tailscale status --json` when the agent exists.
* `SSO sign-in refused by id.<domain> (<error>)`, `SSO sign-in not completed (access_denied)`,
  `SSO sign-in timed out after N s.`
* `SSO token rejected (name mismatch | signature invalid | token expired | issuer mismatch | audience mismatch)`
* `<user> is a local account on this device: type its password (SSO does not take over local accounts).`
* `<user> is a system account: SSO never signs in to it.` (root, nobody, any uid below `UID_MIN`)
* `<user> exists on this device but is not an SSO account: type its local password.`
* `Offline sign-in for <user> expired on <date>; an online SSO sign-in is needed.`

## Pieces

| piece | path | role |
|-------|------|------|
| PAM stack | `specs/etc/pam.d/lightdm` → `/etc/pam.d/lightdm` | `pam_echo` hint; `pam_exec quiet stdout expose_authtok` running the helper under `[success=done default=ignore]`; then the stock `system-local-login`; a `session` line hands the token to the session |
| helper | `specs/usr/lib/hugmesh/sso-greeter` → `/usr/lib/hugmesh/sso-greeter` | `pam-auth`, `pam-session`, `probe`, `status`, `list`, `revoke`, `configure` |
| conf | `/etc/hugmesh/sso-greeter.conf` (written by the builder) | `SSO_ENABLED`, `ISSUER`, `CLIENT_ID`, `BRAND_TITLE`, `OFFLINE_MAX_AGE_DAYS`, `ADMIN_ROLE`, `LOGIN_TIMEOUT`, `CONNECT_TIMEOUT`, `POSTURE` |
| hint | `/run/hugmesh/sso-greeter/hint` | written by `probe` (lightdm `greeter-setup-script`, local facts only) and refreshed by every attempt |
| cache | `/var/lib/hugmesh/sso-greeter/users/<name>.json` (0600, dir 0700) | `iss`, `sub`, `name`, `roles`, `last_online`, `offline_until`, optional scrypt hash of the offline password; never a token |
| registry | `/var/lib/hugmesh/sso-greeter/managed/<name>` (0600) | the uid of each account the helper CREATED; SSO signs in to these only. `revoke` keeps it (revoke ends offline sign-in, not the account) |
| hand-off | `/run/hugmesh/sso-greeter/handoff/<uid>` (0600 root, tmpfs) → `/run/user/<uid>/hugmesh/oidc-token.src` | the verified access token reaches the existing desktop-governance chain (`hugmesh-sso-token login --if-needed` honours it; the desktop-sudo mapper re-verifies it) with no second device prompt |
| bake | `scripts/_desktop-sso-lib.sh` (`desktop_sso_bake`, `desktop_sso_verify`) | called by `build-x86-host-stage4.sh` (client roles, not `--unaffiliated`), `build-frite-stage4.sh` (`--desktop light`), `build-rpi5-stage4.sh` and `build-jetson-stage4.sh` (`--role desktop`), `build-orangepi4-lts-stage4.sh` and `build-orangepi5-stage4.sh` (desktop roles), right after each one's lightdm.conf heredoc, pre-emerge; verified post-emerge (the stack must survive `x11-misc/lightdm`'s own file; a parked `._cfg0000_lightdm` is removed). `tests/scripts/test-desktop-sso-bake.sh` fails any builder that writes a lightdm.conf without both calls |

Why stock modules: `pam_exec` streams the helper's stdout to the conversation
line by line (`pam_info`) while the helper is still polling, prompts once with
`expose_authtok` and passes the answer on stdin, leaving `PAM_AUTHTOK` set for
the local path (`pam_unix try_first_pass`): one prompt. Measured on libpam
1.7.2 with `pam_start_confdir` (a second `expose_authtok` stand-in received the
same bytes with no second prompt), which
`tests/desktop-governance/test-sso-greeter.sh` repeats on every run where
libpam is present. No C module, no SSSD, nothing to
cross-compile.

## Configuration: build time and runtime

**Build time** (every desktop builder: x86, Frite, RPi5, Jetson, Orange Pi 4
LTS, Orange Pi 5):

* `--with-sso` / `--no-sso` / `--skip-sso` **bake** `SSO_ENABLED` (on x86 they
  used to change only a `_plan` line; the ARM builders had no flag). Default ON
  for a mesh desktop; `--standalone` turns it OFF unless `--with-sso`.
  `--unaffiliated` (x86) bakes nothing (plain Gentoo).
* `--sso-issuer https://HOST[:PORT][/PATH]` names the IdP (default
  `https://id.<cluster domain>`). It implies `--with-sso` (also on a standalone
  image), conflicts with `--no-sso`, and is validated twice (the builder's flag
  check and the bake): https only, no query, fragment, credentials, quotes or
  newlines. An IdP reached over a tailnet is named here by its tailnet DNS name.
* `--print-plan` shows `SSO=` and `SSO_ISSUER=`.
* SSO ON on a **mesh** image also bakes `/etc/hugmesh/desktop-governance/`. That
  dir is the signal `keys-provision` uses for a GOVERNED image: KEYS users lose
  `wheel`, static sudoers grants are suppressed, and sudo is the JWKS-verified
  `desktop-sudo` claim through polkit. `provision_desktop_governance()` now also
  runs the baked `session-install.sh.tmpl`, so the token producer / deposit /
  session wrapper / XDG autostart no longer need a KEYS `run[]` hook.
* A **standalone** image never gets the governance dir, SSO on or off: it has no
  KEYS chain to run the mapper, so baking it would strip `wheel` from KEYS users
  with nothing to replace it. A standalone SSO user gets `wheel` only while the
  IdP says `desktop-admin`. SSO OFF bakes no governance dir either: the image
  stays ungoverned and `wheel` sudo stays. The local login account joins `wheel`
  only when the build passed `--local-admin`.

**Runtime** (root, on the device; contacts nothing):

    sso-greeter configure --enable --issuer https://id.example.org
    sso-greeter configure --issuer https://idp.tail1234.ts.net    # another IdP
    sso-greeter configure --offline-days 3 --admin-role ops-admin
    sso-greeter configure --disable

`configure` rewrites `/etc/hugmesh/sso-greeter.conf` in place (comments and other
keys kept, mode 0644), refuses an issuer that is not https, `--enable` without
an issuer, and anything that is not a plain token, then refreshes the greeter
hint. This is how a standalone image is opted in after the fact. The tailnet
itself is joined with the tailnet agent's own command (`tailscale up
--login-server=...`) where the image carries one; the SSO failure line names the
tailnet state so the admin can see which step is missing. The per-domain
`--domain-idp` choice (#509) is not read by the greeter yet: `--sso-issuer` /
`configure --issuer` is the explicit override.
* The Frite light desktop list now declares `dev-lang/python` and
  `sys-auth/polkit` as a stated contract (the helper and the mapper are python3;
  polkit is the governed sudo gate's authority).

## Privilege and security

* The IdP `name` claim must equal the user name selected at the greeter (the
  mapper's binding). The token is verified RS256 against the issuer JWKS
  (last-good cached), `iss`, `aud` = `hugmesh-desktop`, `exp`/`nbf`.
* SSO never takes over a local account (one with a usable shadow hash), and
  never signs in to an account it did not create: root, nobody and every uid
  below `UID_MIN` are refused, and so is any existing account missing from the
  registry (a KEYS user with a locked password, say). All of these are refused
  before any network request. An SSO-managed account is created with
  `useradd -m`, password locked, groups `audio,video,usb,plugdev`, and its uid
  recorded in the registry. `wheel` is never granted on a governed image; on an
  ungoverned one only while the verified token carries `ADMIN_ROLE`
  (`desktop-admin`), and it is removed at the next online sign-in when the role
  is gone.
* The offline cache holds no token. It is bounded (`offline_until`), revocable
  (`sso-greeter revoke <user>|--all`, root) and cleared when the IdP answers
  `access_denied`. **A revocation at the IdP cannot reach a device that stays
  offline**: the bound is the max age. Set `OFFLINE_MAX_AGE_DAYS=0` to forbid
  offline SSO sign-in entirely.
* No token or typed password is ever printed, logged or exported; stdout goes to
  the greeter, stderr to lightdm's log. Every `HSG_*` test seam is ignored
  unless `HSG_INSECURE_TEST=1`.
* Cancel at the greeter: lightdm kills the session child that forked the
  helper, so the helper is reparented and its stdout pipe closes. It checks
  both on every poll and abandons the flow before any account, cache record or
  parked token exists (an approval that arrives afterwards changes nothing).
* `pam_exec` gives the helper the PAM environment only (no `PATH`, since
  `pam_env` runs later in the stack); the helper sets
  `PATH=/usr/sbin:/usr/bin:/sbin:/bin` itself so `useradd`/`usermod`/`gpasswd`
  resolve.
* Standalone images never phone home: with SSO off nothing is contacted; with
  SSO on the only traffic is the IdP, at authentication time, after the user
  left the password empty (the opt-in gesture). `probe` is local-only.
* **PAM order with #860.** #860 wires `pam_ecryptfs` after the LAST line of each
  `system-auth` stack (never right after pambase's `[success=1 ...] pam_unix.so`).
  The greeter stack `include`s `system-local-login` -> `system-login` ->
  `system-auth` and never edits `system-auth`, so the two compose: a local login
  through the greeter is prompted once, authenticated by the same `pam_unix`
  line, and reaches the `pam_ecryptfs unwrap` line; an SSO login ends at
  `success=done` before `system-auth`. The suite executes exactly this chain
  (#860's own `wire_pam_ecryptfs` over its pambase fixture) and shows that the
  pre-#860 placement breaks a local greeter login through it.
* `success=done` skips the rest of the auth stack for an SSO login: `pam_nologin`,
  faillock and `pam_ecryptfs unwrap`. An SSO-managed home is plaintext on the
  LUKS root; `--home-encrypted` is a local-account feature (there is no
  password to wrap against). Put a `pam_nologin.so` line above the exec line if
  `/etc/nologin` must also block SSO on an image.

## Situations

| situation | local | SSO |
|-----------|-------|-----|
| (1) standalone, never associated (`--standalone`, SSO off by default) | yes | greeter says "not enabled" and how an admin turns it on; with `--with-sso`/`--sso-issuer` at build, or `sso-greeter configure --enable --issuer` later, works whenever that IdP is reachable (public, or over a tailnet: build with `--with-tailscale`, then `tailscale up`), otherwise says why. Nothing is contacted until SSO is on AND a user leaves the password empty |
| (2) on a tailnet, not mesh-associated | yes | yes, if the IdP is reachable over that tailnet; the reason names the tailnet state otherwise. A standalone image carries the tailnet agent only when built with `--with-tailscale` (every desktop builder); without it the reason reads "no tailnet agent on this image" |
| (3) mesh-associated (KEYS) | yes (users.json) | yes; governed image, sudo via the `desktop-sudo` claim; the greeter token is handed to the session chain |

**Situation (2) on a standalone image needs the tailnet client baked.**
`--standalone` drops it by default on every builder. `--with-tailscale` keeps
it: x86 has had the flag (`MESH_FORCED`), and the ARM desktop builders (rpi5,
Frite, Orange Pi 4 LTS, Orange Pi 5, Jetson) now take it too. Jetson still
refuses `--standalone` itself, for its LUKS layout. The flag keeps the tailnet
binaries and puts `tailscaled` in the default runlevel. On ARM the one mesh
install step also lands the headscale *binary*, as it does on a mesh desktop;
the headscale *service* stays off (role-gated). The image stays standalone: it is
UNGOVERNED, the SSO posture is `standalone`, and SSO stays off unless
`--with-sso`/`--sso-issuer` says otherwise. The device joins a tailnet only when
an admin runs `tailscale up --login-server=...` (or a KEYS stick provisions it).
With the flag, "contacts nothing" holds for the greeter helper, not for the
image: `tailscaled` is the admin's opt-in, and it runs whatever its own defaults
contact. Without the flag, a standalone image ships no tailnet agent at all.

    ./build-rpi5-stage4.sh --role desktop --standalone --with-tailscale \
        --sso-issuer https://id.tail1234.ts.net --local-pass ...

Studio: an ARM build gets `--skip-mesh` when its tailscale field is off, and no
`--with-tailscale` when it is on, so a Studio standalone ARM build keeps the
no-tailnet default. Emitting the flag is a Studio follow-up.

## Proven offline / to prove on a boot

Offline (`tests/desktop-governance/test-sso-greeter.sh`, 126 checks;
`tests/scripts/test-desktop-sso-bake.sh`, 218 checks incl. 41 negative
controls; its section H RUNS the four ARM desktop builders' `--print-plan` for
the `--standalone --with-tailscale` matrix, and 20 builder plants turn it red):
everything in this document except the greeter's rendering. The
libpam legs run the real `/etc/pam.d/lightdm` with the real helper through
`pam_start_confdir`, alone and over #860's wired include chain.

The guards the requirement names are check functions that run green on the real
helper and are re-run against planted defects, each plant verified to change the
file and still parse:

| guard | check | plants it catches |
|-------|-------|-------------------|
| no `wheel` without the admin role | `chk_no_wheel_without_admin` | wheel always; governed ignored; any role counts as admin |
| no token (or typed password) in any output | `chk_no_token_in_logs` (greeter text, lightdm log, session hand-off, `status`, `list`) | token logged at park; at hand-off; typed password logged |
| cache expiry | `chk_cache_expiry` | `offline_until` not checked |
| fallback to local with a visible reason | `chk_fallback_reason` + `chk_stack_fallback` (libpam) | failure accepted; reason dropped; local-password pointer dropped; "not enabled" reason dropped; reachability check bypassed; exec line `required`; `default=die`; `success=ok` |
| zero network until SSO is opted in | `chk_net_standalone`, `chk_net_disabled_with_issuer`, `chk_net_probe_on` (a `sys.addaudithook` logs every connect/lookup to ANY host; a control proves it sees the opt-in sign-in) | the enabled gate dropped; `probe` checks reachability; typed passwords check reachability |
| never a system / unmanaged account | `chk_system_account`, `chk_unmanaged_account` | both account guards dropped; the registry guard dropped |
| runtime config validation | `chk_cfg_validation` | any issuer accepted |

A boot must still show: lightdm-gtk-greeter renders the `pam_echo` hint and the
helper's text-info lines (it shows the last message; assume last-message-wins),
an empty password is submitted as an empty answer, the code and URL stay
visible while the helper polls, login is accepted and a session is running, and
Cancel returns to the greeter. Screenshots per the operator rule.

## Operator commands (root)

    sso-greeter status [USER]     # enabled/issuer/posture/governed; a user's record
    sso-greeter list              # every offline record
    sso-greeter revoke USER|--all # revoke offline sign-in (and any parked token)
    sso-greeter probe             # rewrite the greeter hint (what greeter-setup-script runs)
    sso-greeter configure ...     # turn SSO on/off, set the IdP, the offline bound, the admin role
