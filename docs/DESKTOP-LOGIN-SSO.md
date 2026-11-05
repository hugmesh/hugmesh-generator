# Desktop login: local password AND SSO at the greeter

Every HugMesh desktop image (x86 client roles; the ARM boards with
`--desktop light`, starting with the Frite) offers **two** ways in at the
lightdm greeter, and both must work in all three situations an image can be
in: (1) standalone, never associated with a mesh; (2) on a tailnet but not
mesh-associated; (3) mesh-associated (KEYS-provisioned). Where SSO cannot
work, the greeter says why and the local path is untouched. Nothing hangs.

| path | credential | needs | who |
|------|------------|-------|-----|
| **A. local** | the account's password in `/etc/shadow` | nothing | the `--local-pass` user (standalone), KEYS `users.json` users, the keyless first-boot fallback user |
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
  **empty**, press Enter. The greeter shows *"open `<url>` on any device and
  enter the code `XXXX-XXXX`"*. Approve on a phone or any browser. The session
  starts. Bounded: `LOGIN_TIMEOUT` (180 s) or the code's own expiry, then the
  greeter is back; Cancel works at any time.
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

One line on the greeter, then exit 1 so the local path still runs:

* `SSO sign-in is not enabled on this image (built with --skip-sso).`
* `SSO sign-in unavailable: cannot reach id.<domain> (no tailnet agent on this image; ...)`
  / `(tailnet needs login; ...)` / `(tailnet stopped; ...)` / `<host> does not resolve`.
  The tailnet state comes from `tailscale status --json` when the agent exists.
* `SSO sign-in refused by id.<domain> (<error>)`, `SSO sign-in not completed (access_denied)`,
  `SSO sign-in timed out after N s.`
* `SSO token rejected (name mismatch | signature invalid | token expired | issuer mismatch | audience mismatch)`
* `<user> is a local account on this device: type its password (SSO does not take over local accounts).`
* `Offline sign-in for <user> expired on <date>; an online SSO sign-in is needed.`

## Pieces

| piece | path | role |
|-------|------|------|
| PAM stack | `specs/etc/pam.d/lightdm` → `/etc/pam.d/lightdm` | `pam_echo` hint; `pam_exec quiet stdout expose_authtok` running the helper under `[success=done default=ignore]`; then the stock `system-local-login`; a `session` line hands the token to the session |
| helper | `specs/usr/lib/hugmesh/sso-greeter` → `/usr/lib/hugmesh/sso-greeter` | `pam-auth`, `pam-session`, `probe`, `status`, `list`, `revoke` |
| conf | `/etc/hugmesh/sso-greeter.conf` (written by the builder) | `SSO_ENABLED`, `ISSUER`, `CLIENT_ID`, `BRAND_TITLE`, `OFFLINE_MAX_AGE_DAYS`, `ADMIN_ROLE`, `LOGIN_TIMEOUT`, `CONNECT_TIMEOUT`, `POSTURE` |
| hint | `/run/hugmesh/sso-greeter/hint` | written by `probe` (lightdm `greeter-setup-script`, local facts only) and refreshed by every attempt |
| cache | `/var/lib/hugmesh/sso-greeter/users/<name>.json` (0600, dir 0700) | `iss`, `sub`, `name`, `roles`, `last_online`, `offline_until`, optional scrypt hash of the offline password; never a token |
| hand-off | `/run/hugmesh/sso-greeter/handoff/<uid>` (0600 root, tmpfs) → `/run/user/<uid>/hugmesh/oidc-token.src` | the verified access token reaches the existing desktop-governance chain (`hugmesh-sso-token login --if-needed` honours it; the desktop-sudo mapper re-verifies it) with no second device prompt |
| bake | `scripts/_desktop-sso-lib.sh` (`desktop_sso_bake`, `desktop_sso_verify`) | called by `build-x86-host-stage4.sh` (client roles, not `--unaffiliated`) and `build-frite-stage4.sh` (`--desktop light`), pre-emerge; verified post-emerge (the stack must survive `x11-misc/lightdm`'s own file; a parked `._cfg0000_lightdm` is removed) |

Why stock modules: `pam_exec` streams the helper's stdout to the conversation
line by line (`pam_info`) while the helper is still polling, prompts once with
`expose_authtok` and passes the answer on stdin, leaving `PAM_AUTHTOK` set for
the local path (`pam_unix try_first_pass`): one prompt. Measured on libpam
1.7.2 with `pam_start_confdir` (a second `expose_authtok` stand-in received the
same bytes with no second prompt), which
`tests/desktop-governance/test-sso-greeter.sh` repeats on every run where
libpam is present. No C module, no SSSD, nothing to
cross-compile.

## Build flags

* x86: `--with-sso` / `--no-sso` / `--skip-sso` now **bake** `SSO_ENABLED`
  (they used to change only a `_plan` line). Default ON for client roles;
  `--standalone` turns it OFF unless `--with-sso`. `--unaffiliated` bakes
  nothing (plain Gentoo).
* Frite: the same three flags, new. Default ON; `--standalone` turns it OFF
  unless `--with-sso`; `--print-plan` shows `SSO=`.
* SSO ON also bakes `/etc/hugmesh/desktop-governance/` into the image. That dir
  is the signal `keys-provision` uses for a GOVERNED image: KEYS users lose
  `wheel`, static sudoers grants are suppressed, and sudo is the JWKS-verified
  `desktop-sudo` claim through polkit. `provision_desktop_governance()` now also
  runs the baked `session-install.sh.tmpl`, so the token producer / deposit /
  session wrapper / XDG autostart no longer need a KEYS `run[]` hook. SSO OFF
  bakes no governance dir: the image stays ungoverned and `wheel` sudo stays.
* The Frite light desktop list now declares `dev-lang/python` and
  `sys-auth/polkit` as a stated contract (the helper and the mapper are python3;
  polkit is the governed sudo gate's authority).

## Privilege and security

* The IdP `name` claim must equal the user name selected at the greeter (the
  mapper's binding). The token is verified RS256 against the issuer JWKS
  (last-good cached), `iss`, `aud` = `hugmesh-desktop`, `exp`/`nbf`.
* SSO never takes over a local account (one with a usable shadow hash). An
  SSO-managed account is created with `useradd -m`, password locked, groups
  `audio,video,usb,plugdev`. `wheel` is never granted on a governed image; on an
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
* `success=done` skips the rest of the auth stack for an SSO login: `pam_nologin`,
  faillock and `pam_ecryptfs unwrap`. An SSO-managed home is plaintext on the
  LUKS root; `--home-encrypted` is a local-account feature (there is no
  password to wrap against). Put a `pam_nologin.so` line above the exec line if
  `/etc/nologin` must also block SSO on an image.

## Situations

| situation | local | SSO |
|-----------|-------|-----|
| (1) standalone, never associated (`--standalone`, SSO off by default) | yes | greeter says "not enabled"; with `--with-sso`, works whenever `id.<domain>` is reachable (public IdP or a tailnet joined by hand), otherwise says why |
| (2) on a tailnet, not mesh-associated | yes | yes, if the IdP is reachable over that tailnet; the reason names the tailnet state otherwise |
| (3) mesh-associated (KEYS) | yes (users.json) | yes; governed image, sudo via the `desktop-sudo` claim; the greeter token is handed to the session chain |

Adjacent, not fixed here: the Frite `--standalone` still forces
`SKIP_TAILSCALE` with no `--with-tailscale` override (x86 has `MESH_FORCED`), so
situation (2) on a standalone Frite needs the tailnet joined by hand.

## Proven offline / to prove on a boot

Offline (`tests/desktop-governance/test-sso-greeter.sh`, 71 checks incl. a
5-mutation battery; `tests/scripts/test-desktop-sso-bake.sh`, 61 checks incl.
7 negative controls): everything in this document except the greeter's
rendering. The libpam leg runs the real `/etc/pam.d/lightdm` with the real
helper through `pam_start_confdir`.

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
