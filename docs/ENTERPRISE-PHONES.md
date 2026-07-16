# Enterprise phones — GrapheneOS on Google Pixel (the fourth onboarding form)

> **Status: 🚧 v1 driver in-flight** (branch `feat/pixel-graphene-phone-wizard`).
> One driver, [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh), owns the
> whole flow; nothing in this document is shipped on `main` yet.

_State key: **✅ shipped** (on `main`) · **🚧 in-flight** · **🔭 planned / deferred**._

This is the **fourth onboarding form**: alongside the appliance images
([`BUILD-MATRIX.md`](BUILD-MATRIX.md)), the client desktops
([`CLIENT-IMAGES.md`](CLIENT-IMAGES.md)), and the FD-09 Local Docker mesh node
([`clients/docker-mesh-node/`](../clients/docker-mesh-node)), the platform can
now take a **USB-connected Google Pixel** and turn it into an
enterprise-managed mesh device:

```
detect ─► fetch (VERIFIED GrapheneOS -install- zip) ─► flash ─► enroll (headscale
tailnet join, register-and-approve) ─► profile (separately-encrypted GrapheneOS
secondary user, credential escrowed into vault-seed custody) ─► ingest (device registry)
```

It follows the repo's documented **non-build precedent** (see the
Local-Docker-mesh paragraph in [`BUILD-MATRIX.md`](BUILD-MATRIX.md)): the phone
is **NOT a build-matrix cell, NOT a platform, NOT a WorklistEntry** — nothing is
compiled or imaged here. Like the Local Docker mesh and the go-live wizard triad
([`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md)), the driver owns ALL the logic and
the faces stay thin: `make phone-*` targets (🚧, host-side pass-through
delegates in the Makefile — never dispatched into the builder container, since
the driver needs the host USB bus and a real TTY for its destructive gates);
ncurses-menu/Studio faces are 🔭 (see [Deferred](#deferred)).

## Verbs (the real surface)

`scripts/phone-wizard.sh <verb> [options]`. The **default posture is
dry-run/read-only**: only `fetch`, `flash`, `enroll`, `profile`,
`rotate-profile-pass`, `remove-profile` and `ingest` change anything, and the
destructive ones are gated.

| Verb | Mutates? | What it does |
| --- | --- | --- |
| `plan [verb]` | never | Dry-run (default target: `wizard`). Validates options + catalog lookup, prints `PLAN_<K>=<V>` lines, touches NOTHING. Fully offline unless `--resolve` is passed (the version prints as `resolve-at-fetch` when unknown). `--print-plan` anywhere is an alias for this verb. |
| `detect` | never | Read-only probe: adb/fastboot device list, serial, codename, current OS fingerprint. Prints `DEVICE_*` lines. |
| `fetch` | work-dir | Resolve the `--channel` release, download the GrapheneOS `<codename>-install-<version>.zip`(+`.sig`) into `--work-dir`, verify the sshsig **fail-closed**, extract, write a `.verified-<sha256>` marker. Idempotent (a cached resolution next to its verified zip makes re-fetch fully offline). |
| `flash` | **DESTRUCTIVE** | Wipe the phone and flash the VERIFIED artifact. Typed-serial confirmation on a TTY; non-TTY requires BOTH `--yes` AND a matching `--serial`. Refuses anything without a matching verification marker, and re-verifies the signature again before flashing. |
| `enroll` | out-dir | Post-first-boot (adb): guided tailnet join with keys from `--keys-dir` (docker-mesh-node layout) or `--login-server`/`--authkey-file`; verifies `tailscale0` got a 100.64/10 address and writes the enrollment record. |
| `profile` | device + out-dir | Create the `enterprise` secondary user, generate + escrow its passphrase (vault-seed custody), operator sets the credential on the handset (default path). |
| `rotate-profile-pass` | out-dir (+device) | Generate + escrow a new profile passphrase atomically (previous escrow kept as `.prev-<ts>`). |
| `remove-profile` | **DESTRUCTIVE** | Remove the enterprise user (typed profile-name confirm, or `--yes`); escrow retired to `.revoked-<ts>`. Per-profile FBE keys are evicted — the profile's data is gone. |
| `ingest` | out-dir (+POST) | Emit the `phone-ingest/v1` device-registry record; with `--ingest-url` + the mTLS flags, POST it (fail-closed without client cert+key). |
| `status` | never | Read-only: tools, device, tailnet, profile, escrow **presence** (never contents). |
| `wizard` | (per step) | Interactive guided full flow (TTY only): detect → fetch → flash → enroll → profile → ingest, re-entrant — already-completed steps can be skipped. |
| `help` | never | Usage. |

### Exit codes (auditable contract)

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | usage / runtime error |
| `2` | missing tool / precondition / refused gate |
| `3` | signature or fingerprint-pin verification failure (**tamper** — artifact deleted) |
| `4` | unknown codename / requested device not found |

### Options

Device + release: `--serial S` (required when several devices are connected;
always compared against what is actually detected) · `--codename C` (see
[`scripts/phone-devices.tsv`](../scripts/phone-devices.tsv)) · `--channel
stable|beta|alpha` (default `stable`) · `--graphene-version V` (pin an exact
release, skips channel resolution) · `--work-dir D` (artifact dir, default
`out/phone-wizard`) · `--out D` (output tree: enrollment/profile/ingest records
+ vault-seed escrow; default `keys-out`).

Mesh + identity: `--keys-dir D` (docker-mesh-node layout — see
[Enrollment](#enrollment--mesh-join)) · `--login-server URL` (headscale control
URL, overrides keys-dir) · `--authkey-file F` (0600 file holding the one-time
pre-auth key) · `--device-id ID` (stable id, `[a-z0-9-]`, default
`phone-<sanitized serial>`) · `--superdomain D` (orchestration superdomain /
MagicDNS base, default `snapdragon.internal`) · `--role
user|mod|admin|superadmin` (default `user`, or the keys-dir `role` file).

Profile custody: `--pass-file F` (0600 file supplying the profile passphrase;
else one is generated from `/dev/urandom`) · `--profile-name N` (default
`enterprise`).

Enroll extras: `--tailscale-apk F` (adb-install during enroll) ·
`--apk-signer-sha256 H` (pin the APK signer cert SHA-256; fail-closed when set).

Ingest: `--ingest-url URL` + `--client-cert F --client-key F --ca F` (mTLS
client identity; POST is refused without cert+key).

Gates + overrides: `--yes` (non-interactive confirmation, per-verb gates) ·
`--force` (downgrade the GrapheneOS sanity probe to a warning) · `--force-fwupd`
(proceed even if fwupd is running) · `--show-authkey` (display the pre-auth key
ONCE during enroll; default: never displayed) · `--i-understand-adb-exposure`
(set the profile credential over adb — see
[Secret custody](#secret-custody-model)) · `--resolve` (allow `plan` to resolve
the version over the network) · `--print-plan` (alias for the `plan` verb) ·
`--no-color`.

Env seams (tests override these; defaults are the real thing): `PW_ADB`,
`PW_FASTBOOT`, `PW_RELEASES_URL`, `PW_ALLOWED_SIGNERS`, `PW_EXPECTED_SIGNER_FP`
(empty allowed ONLY with `PW_ALLOWED_SIGNERS` overridden), `PW_SKIP_FP_PIN=1`,
`PW_JOIN_TIMEOUT`, `PW_POLL_INTERVAL`.

### Quick start

```console
$ scripts/phone-wizard.sh plan                      # offline dry-run of the whole flow (PLAN_* lines)
$ scripts/phone-wizard.sh wizard                    # guided TTY flow: detect → fetch → flash → enroll → profile → ingest
# scripted, step by step:
$ scripts/phone-wizard.sh detect
$ scripts/phone-wizard.sh fetch  --codename komodo --channel stable
$ scripts/phone-wizard.sh flash  --serial <S> --codename komodo         # typed-serial confirm on a TTY
$ scripts/phone-wizard.sh enroll --serial <S> --keys-dir <keys>         # or --login-server + --authkey-file
$ scripts/phone-wizard.sh profile --serial <S>
$ scripts/phone-wizard.sh ingest --device-id phone-<s>                  # emit-only; add --ingest-url + mTLS flags to POST
```

## Verified GrapheneOS facts (pinned in the repo)

These are the externally-verified facts the driver is built on. Provenance is
recorded in the pinned files themselves (fetched **2026-07-15**); each fact is
enforced in code, fail-closed — not prose.

- **sshsig is the ONLY current verification method.** The old signify
  `factory.pub` is GONE — `releases.grapheneos.org` returns HTTP 410 for it.
  GrapheneOS `-install-` zips carry detached OpenSSH sshsig signatures
  (`ssh-keygen -Y verify`), identity `contact@grapheneos.org`, namespace
  `factory images`, per the official CLI install procedure
  (`https://grapheneos.org/install/cli`). Pinned signers file:
  [`scripts/phone-allowed-signers`](../scripts/phone-allowed-signers).
- **Double fingerprint pin.** The expected signer-key fingerprint
  `SHA256:AhgHif0mei+9aNyKLfMZBh2yptHdw/aN7Tlh/j2eFwM` is asserted against
  **every** key line in the signers file before each verify (`ssh-keygen -lf`) —
  `-Y verify` accepts ANY listed key for the principal, so this catches a
  *replaced* AND an *appended* key. Implemented as `dlv_verify_sshsig` in
  [`scripts/_download-lib.sh`](../scripts/_download-lib.sh). `ssh-keygen`
  ignores `#` comment lines in allowed_signers files (verified against OpenSSH
  10.3 for both `-Y verify` and `-lf`).
- **Tamper ⇒ exit 3, artifact DELETED.** A failed verify removes the zip, the
  `.sig` and any marker — a bad zip must never survive to be flashed later.
  `flash` additionally refuses any artifact without a byte-matching
  `.verified-<sha256>` marker and re-verifies the signature again.
- **fastboot ≥ 35.0.2 is a GrapheneOS hard requirement.** Preflighted;
  older android-tools exit 2. A running `fwupd` can seize the fastboot USB
  interface, so that is preflighted too (`--force-fwupd` overrides).
- **Release metadata** is a one-line file at
  `https://releases.grapheneos.org/<codename>-<channel>`:
  `"<version> <unix-ts> <codename> <channel>"`, channels
  `stable|beta|alpha`, version an 8+-digit datestamp. Echoed
  codename/channel are cross-checked; mismatch refuses.
- **Artifacts** are `<codename>-install-<version>.zip` (+`.sig`) containing the
  official `flash-all.sh`, which the driver runs from inside the extracted dir
  with a local `TMPDIR` (space safety, per the official CLI instructions),
  bound to OUR device via `ANDROID_SERIAL`.
- **Device catalog, fail-closed:**
  [`scripts/phone-devices.tsv`](../scripts/phone-devices.tsv) pins the **21
  devices** GrapheneOS ships release channels for (Pixel 6 → Pixel 10a, as of
  2026-07-15). An unknown codename exits 4; there is deliberately **no
  `--allow-unknown` escape hatch in v1** — an unknown codename would fetch and
  flash an artifact nobody vetted for this fleet.
- **Bootloader lifecycle:** unlocking WIPES the device (and requires "OEM
  unlocking" in Developer options); re-locking wipes again and re-enables full
  verified boot — the driver walks the operator through both volume-key
  confirmations and treats a declined re-lock as a loud failure (the device
  REMAINS UNLOCKED). It **never** runs `fastboot erase avb_custom_key` — that
  is the revert-to-stock path.
- **Secondary users are separately encrypted.** The enterprise profile is a
  GrapheneOS secondary user with its own file-based-encryption keys; removing
  the user evicts those FBE keys (the profile's data is gone). The generated
  credential is 6 dash-joined 6-char lowercase words from `/dev/urandom`
  (41 chars, comfortably above the 28-char bar the custody model requires) —
  lowercase-only so it is typable on the handset lockscreen keyboard.
- **Tailscale on Android** is package `com.tailscale.ipn`; a successful tailnet
  join is verified by polling for a CGNAT (`100.64/10`) address on
  `tailscale0` over adb.

## The orchestration superdomain (what the phone joins)

The handset joins the brand's **orchestration superdomain** — quoted verbatim
from [`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md), which is the canonical
definition:

> - **Orchestration superdomain** — `<brand>.internal` (default
>   `snapdragon.internal`), the headscale MagicDNS `base_domain` every mesh node
>   joins. It is **permanently internal**: it carries the tailnet + `kube-api.<superdomain>`
>   control-plane endpoint, is never routable, and is **never** go-live-flipped.
>   It is delivered through the KEYS channel — `scripts/gen-provision-keys.sh`
>   stamps it into `provision.json` `.mesh.magic_dns_domain` (from `SUPERDOMAIN` /
>   `--superdomain`, default `<BRAND>.internal`), which headscale consumes — so no
>   go-live provider, DNS record set, or `RELEASE_STATE` transition ever touches it.

The wizard's `--superdomain` flag (default `snapdragon.internal`) is this same
value; it lands in `PLAN_SUPERDOMAIN`, the enrollment record, and the ingest
record. A phone is a mesh *member*, never a go-live target — the public apex
never applies to it.

## Enrollment — mesh join

`enroll` reuses the FD-09 Local-Docker-mesh keys contract
([`clients/docker-mesh-node/keys.example`](../clients/docker-mesh-node/keys.example)),
all files optional individually:

```
<keys-dir>/login-server        headscale control URL
<keys-dir>/tailscale/authkey   one-time pre-auth key (or <keys-dir>/authkey)
<keys-dir>/casdoor.json        { issuer, client_id, domain }
<keys-dir>/role                user|mod|admin|superadmin
```

The join itself is operator-performed on the handset (the driver prints the
runbook, then **verifies** the result over adb):

1. Tailscale app → custom coordination server → the resolved login server.
2. Authenticate with the one-time pre-auth key (SEC-08: single-use, 24 h
   expiry — mint a fresh one if it is stale), or via Casdoor OIDC with the
   `snapdragon/headscale` group — the same gate the superadmin's own client
   join uses, see [`SUPERADMIN-MESH-CLIENT.md`](SUPERADMIN-MESH-CLIENT.md).
3. ADR-14 register-and-approve: the node registers as PENDING and only joins
   after a superadmin approves it in the superadmin UI. (If the join-verify
   times out while approval is pending, re-run `enroll` once approved — it is
   idempotent up to the record write.)

Optional APK custody: `--tailscale-apk` installs a vetted APK over adb, and
`--apk-signer-sha256` pins the signing cert of **what is actually installed**
(the driver pulls the on-device `base.apk` and checks it with `apksigner`,
fail-closed) — pinning the installed artifact, not the file we happened to
install. On success a non-secret `enrollment.json` is written under
`<out>/device/<device-id>/`.

## Enterprise profile — escrowed credential custody

`profile` creates the `enterprise` secondary user (`pm create-user`), then
**escrows the passphrase FIRST** — custody is established before anything else
can fail:

```
<out>/vault-seed/device/<device-id>/enterprise-profile.pass   (dirs 0700, file 0600)
```

destined for Vault at `secret/<brand>/device/<device-id>/phone-profile` (the
per-device vault-seed custody chain). By **default the operator sets the
credential on the handset** by reading the 0600 escrow file themselves — the
wizard never prints it. Setting it over `adb shell locksettings set-password`
puts the passphrase **in adb argv, which is visible phone-side**
(logcat/`ps`); that path is a documented residual exposure and requires the
explicit `--i-understand-adb-exposure` gate.

Lifecycle: `rotate-profile-pass` rotates the escrow atomically (stage `.new`,
demote the current file to `.prev-<ts>`, promote) and re-runs the credential-set
flow; `remove-profile` removes the user (typed profile-name confirm, or
`--yes`) and retires the escrow to `.revoked-<ts>` — revoke the Vault copy too.

## Secret-custody model

No secret ever travels on argv, in `plan` output, or to stdout/logs — `plan`
prints **`REDACTED` presence markers only** (`PLAN_AUTHKEY=REDACTED:present`,
`PLAN_PROFILE_PASS=REDACTED:generate`). The tailscale pre-auth key and the
enterprise-profile passphrase move via **0600 files only** (`--authkey-file` /
`--pass-file` / the vault-seed escrow dir). The pre-auth key is never passed
via `adb shell` argv and is only displayed with an explicit `--show-authkey`
(once). `status` reports escrow **presence, never contents**. The one
deliberate exception is the gated adb credential-set path above.

## Ingest — device registry

`ingest` emits `<out>/device/<device-id>/ingest.json`, schema
**`phone-ingest/v1`**: `device_id`, `device_class:"phone"`, `serial`,
`codename`, `marketing_name`, `os:"grapheneos"`, `os_version`, `superdomain`,
`login_server`, `tailscale_ip`, `tailscale_hostname`, `role`,
`attached_domain`, `enterprise_profile{present,user_id,credential_custody}`,
`enrolled_at`, `generated_at`. Recorded facts (enrollment/profile records) are
preferred; live adb detection fills only what is missing and reachable.

Default is **emit-only**. With `--ingest-url` the record is POSTed with the
platform's mTLS client identity (`--client-cert`/`--client-key` + `--ca`),
mirroring the device-enrollment-report transport — fail-closed when the
identity material is missing. Alternatively, hand the record to the registry
importer.

## Remote-management model (v1, deliberate)

There is **no MDM agent, no on-phone resident daemon, no APK store**. Remote
management is limited to the USB-tethered verbs above plus the **mesh-side
controls**: headscale key expiry / node removal, and Casdoor credential
revocation. Losing the phone therefore costs mesh membership and platform
sessions, not custody of anything the escrow chain holds.

## Summary

| Capability | Where | State |
| --- | --- | --- |
| Driver: full verb surface (`plan`/`detect`/`fetch`/`flash`/`enroll`/`profile`/`rotate-profile-pass`/`remove-profile`/`ingest`/`status`/`wizard`) | [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | 🚧 |
| Fail-closed artifact verification (sshsig + double fingerprint pin, tamper ⇒ delete + exit 3) | `dlv_verify_sshsig` + [`scripts/phone-allowed-signers`](../scripts/phone-allowed-signers) | 🚧 |
| Pinned device catalog (21 devices, unknown codename ⇒ exit 4, no escape hatch) | [`scripts/phone-devices.tsv`](../scripts/phone-devices.tsv) | 🚧 |
| Destructive gates (typed-serial flash confirm; non-TTY needs `--yes`+`--serial`; typed profile-name removal) | `flash` / `remove-profile` | 🚧 |
| Tailnet enroll (keys-dir contract, SEC-08 pre-auth or Casdoor OIDC, ADR-14 approval, 100.64/10 join verify) | `enroll` | 🚧 |
| Escrowed enterprise profile (vault-seed custody, operator-set default, atomic rotation, revocation trail) | `profile` / `rotate-profile-pass` / `remove-profile` | 🚧 |
| `phone-ingest/v1` registry record + mTLS POST | `ingest` | 🚧 |
| Offline `plan` dry-run + `REDACTED` secret discipline | `plan` / `--print-plan` | 🚧 |
| `make phone-*` thin face (host-side delegates; secrets stay file-path knobs) | `Makefile` | 🚧 |
| Thin ncurses-menu/Studio faces over the driver (non-build precedent) | — | 🔭 |
| MDM agent / on-phone daemon / APK store | — | 🔭 (deliberate v1 non-goals) |
| OTA/update posture management (GrapheneOS updates itself; no fleet lever) | — | 🔭 |

## Deferred

Tracked here per the driver's header. Still 🔭, by design:

- **Thin ncurses-menu/Studio faces** — over the driver's verbs, exactly like
  the Local Docker mesh and go-live precedents (driver owns all logic; faces
  stay thin, no build-matrix row). The `make phone-*` face is already 🚧 on
  this branch.
- **Any on-phone agent** (MDM, resident daemon, APK store) — v1 keeps remote
  management at the mesh side (headscale key expiry, Casdoor revocation) plus
  the USB-tethered verbs.
- **Fleet OTA posture** — GrapheneOS's own updater handles OS updates; a
  fleet-visible update/compliance report would ride a future agent, which v1
  deliberately does not have.
