# Mobile Device Management (MDM) — GrapheneOS + existing-device phone onboarding (the fourth onboarding form)

> **Status: ✅ shipped on `main`** — the flash/enroll/profile/ingest driver,
> the existing-device onboarding path, **Headwind MDM**, the **GrapheneOS
> AttestationServer**, and the `attest`/`mdm-enroll` verbs that drive them
> from this wizard are all merged (#376/#381/#383/#386/#390, hardened by the
> 9-defect pre-deploy-gap pass in #393). One driver,
> [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh), owns the whole
> flow. **Headwind MDM** and the **GrapheneOS AttestationServer** are merged,
> default-off cluster optional-services (see
> [Management plane](#management-plane)). Real pre-deploy gaps remain — see
> [Deferred](#deferred) — but nothing in this doc is pending on an unmerged
> branch.

_State key: **✅ shipped** (on `main`) · **🚧 in-flight** · **🔭 planned / deferred**._

This is the **fourth onboarding form**: alongside the appliance images
([`BUILD-MATRIX.md`](BUILD-MATRIX.md)), the client desktops
([`CLIENT-IMAGES.md`](CLIENT-IMAGES.md)), and the FD-09 Local Docker mesh node
([`clients/docker-mesh-node/`](../clients/docker-mesh-node)), the platform can
take a **USB-connected Google Pixel** and turn it into an MDM-managed
mesh device end to end:

```
detect ─► fetch (VERIFIED GrapheneOS -install- zip) ─► flash ─► attest
(self-hosted AttestationServer pairing, via a Snapdragon-forked Auditor app)
─► mdm-enroll (Headwind MDM device-owner enrollment — MUST run before
'profile', which permanently forecloses device-owner mode) ─► enroll
(headscale tailnet join, register-and-approve) ─► profile (separately-encrypted
GrapheneOS secondary user, credential escrowed into vault-seed custody)
─► ingest (device registry)
```

`enroll` also stands alone as a **first-class existing-device onboarding
path**: a phone this wizard never flashed — GrapheneOS *or stock Android* —
USB-guided or (`--no-usb`) with no adb at all. See
[Onboarding existing phones (no reflash)](#onboarding-existing-phones-no-reflash).
`flash` itself remains GrapheneOS/Pixel-only. `attest` and `mdm-enroll` are
likewise adb-based and apply to freshly-flashed **and** already-running
phones — see [Management plane](#management-plane) for the ordering
constraint that makes device-owner enrollment a one-shot, fresh-device-only
operation.

It follows the repo's documented **non-build precedent** (see the
Local-Docker-mesh paragraph in [`BUILD-MATRIX.md`](BUILD-MATRIX.md)): the phone
is **NOT a build-matrix cell, NOT a platform, NOT a WorklistEntry** — nothing is
compiled or imaged here. Like the Local Docker mesh and the go-live wizard triad
([`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md)), the driver owns ALL the logic and
the faces stay thin: `make phone-*` targets (✅ shipped, host-side pass-through
delegates in the Makefile — never dispatched into the builder container, since
the driver needs the host USB bus and a real TTY for its destructive gates;
all 13 verbs have targets, including `phone-mdm-enroll`/`phone-attest`);
the ncurses-menu face (✅ shipped: `phone_screen` in `scripts/build-menu.sh`
wraps all 13 verbs, with an MDM/attestation sub-screen threading the
Headwind/Auditor/ingest-token knobs file-path-only); the Studio face is 🔭
(see [Deferred](#deferred)).

## Verbs (the real surface)

`scripts/phone-wizard.sh <verb> [options]`. The **default posture is
dry-run/read-only**: only `fetch`, `flash`, `attest`, `mdm-enroll`, `enroll`,
`profile`, `rotate-profile-pass`, `remove-profile` and `ingest` change
anything, and the destructive ones are gated.

| Verb | Mutates? | What it does |
| --- | --- | --- |
| `plan [verb]` | never | Dry-run (default target: `wizard`). Validates options + catalog lookup, prints `PLAN_<K>=<V>` lines, touches NOTHING. Fully offline unless `--resolve` is passed (the version prints as `resolve-at-fetch` when unknown). `--print-plan` anywhere is an alias for this verb. |
| `detect` | never | Read-only probe: adb/fastboot device list, serial, codename, current OS fingerprint. Prints `DEVICE_*` lines. |
| `fetch` | work-dir | Resolve the `--channel` release, download the GrapheneOS `<codename>-install-<version>.zip`(+`.sig`) into `--work-dir`, verify the sshsig **fail-closed**, extract, write a `.verified-<sha256>` marker. Idempotent (a cached resolution next to its verified zip makes re-fetch fully offline). |
| `flash` | **DESTRUCTIVE** | Wipe the phone and flash the VERIFIED artifact. Typed-serial confirmation on a TTY; non-TTY requires BOTH `--yes` AND a matching `--serial`. Refuses anything without a matching verification marker, and re-verifies the signature again before flashing. |
| `attest` | device + out-dir | Install the signer-pinned Snapdragon-forked Auditor (`--auditor-apk`/`--auditor-signer-sha256`) and print the self-hosted [AttestationServer](#management-plane) pairing runbook (`--attestation-url`). The in-app QR scan cannot be driven over adb, so this is an **operator-attested** pairing (`verdict:"operator-paired"`), not a cryptographic verification by the wizard. Runs **before** `mdm-enroll` — see [Management plane](#management-plane) for why. Writes `attestation.json`. |
| `mdm-enroll` | device + out-dir | Enroll the phone as a Headwind MDM device-owner (`dpm set-device-owner com.hmdm.launcher/.AdminReceiver`) after a fail-closed fresh-device precondition (`pm list users` must show exactly one user AND `dumpsys account` must show zero accounts). Installs the signer-pinned DPC APK (`--headwind-apk`/`--headwind-signer-sha256`) and pushes a non-interactive `init.json` (`com.hmdm.BASE_URL=--headwind-url`) into its external files dir. **MUST run before `profile`** — see [Management plane](#management-plane). Writes `mdm.json`. |
| `enroll` | out-dir | Add a running phone to the mesh — freshly flashed **or already-running**, GrapheneOS **or stock Android** (the OS probe records which; it never gates — see [Onboarding existing phones](#onboarding-existing-phones-no-reflash)). Guided tailnet join with keys from `--keys-dir` (docker-mesh-node layout) or `--login-server`/`--authkey-file`; verifies the tailnet join (a 100.64/10 address on the Tailscale `tun*` interface — Android names it `tun0`, not `tailscale0`) and writes the enrollment record. `--no-usb` drops adb entirely (guided handset-only runbook, operator-attested record; needs `--device-id` + `--codename`). |
| `profile` | device + out-dir | Create the `enterprise` secondary user, generate + escrow its passphrase (vault-seed custody), operator sets the credential on the handset (default path). **This permanently forecloses device-owner mode** — see [Management plane](#management-plane); it must never run before `mdm-enroll`. |
| `rotate-profile-pass` | out-dir (+device) | Generate + escrow a new profile passphrase atomically (previous escrow kept as `.prev-<ts>`). |
| `remove-profile` | **DESTRUCTIVE** | Remove the enterprise user (typed profile-name confirm, or `--yes`); escrow retired to `.revoked-<ts>`. Per-profile FBE keys are evicted — the profile's data is gone. |
| `ingest` | out-dir (+POST) | Emit the `phone-ingest/v1` device-registry record (folding in `attestation.json`'s fields when present — see [Ingest](#ingest--device-registry)); with `--ingest-url` + the mTLS flags, POST it (fail-closed without client cert+key). |
| `status` | never | Read-only: tools, device, tailnet, profile, escrow **presence** (never contents). |
| `wizard` | (per step) | Interactive guided full flow (TTY only): detect → fetch → flash → attest → mdm-enroll → enroll → profile → ingest, re-entrant — already-completed steps can be skipped. |
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
+ vault-seed escrow; default `out/phone-wizard/keys-out` — deliberately its
own namespace under `--work-dir`'s tree, not the repo-root `keys-out/` that
[`gen-provision-keys.sh`](../scripts/gen-provision-keys.sh) treats as its own
disposable scratch space and unconditionally `rm -rf`s).

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

Management-plane extras (see [Management plane](#management-plane)):
`--headwind-apk F` (Headwind DPC APK to adb-install during `mdm-enroll`) ·
`--headwind-signer-sha256 H` (pin the Headwind APK signer cert SHA-256;
fail-closed when set) · `--headwind-url URL` (Headwind server base URL,
written into the DPC's non-interactive `init.json` as `com.hmdm.BASE_URL`;
env `HMDM_URL`) · `--auditor-apk F` (Snapdragon-forked Auditor APK to
adb-install during `attest`) · `--auditor-signer-sha256 H` (pin the Auditor
fork's release-cert SHA-256; fail-closed when set) · `--attestation-url URL`
(self-hosted AttestationServer console URL, printed in the `attest` pairing
runbook; env `ATTEST_URL`).

Ingest: `--ingest-url URL` + `--client-cert F --client-key F --ca F` (mTLS
client identity; POST is refused without cert+key).

Gates + overrides: `--yes` (non-interactive confirmation, per-verb gates) ·
`--force` (downgrade FOUR independent hard-requirement checks to warnings:
the `enroll` OS-probe gate — only when the OS is genuinely undetectable,
GrapheneOS and stock Android never need it; `flash`'s fastboot-version
preflight — when the `fastboot --version` string is unparsable, normally
enforcing GrapheneOS's ≥35.0.2 requirement; `enroll`'s
Tailscale-package-appear wait — skip confirming the app actually installed
before the tailnet-join poll starts; and `mdm-enroll`'s fresh-device
precondition — see [Management plane](#management-plane) for why this one is
a one-shot, not-really-safe-to-force check) · `--force-fwupd` (proceed even if
fwupd is running) · `--show-authkey` (display
the pre-auth key ONCE during enroll; default: never displayed) · `--no-usb`
(enroll only: skip every adb probe — see
[Onboarding existing phones](#onboarding-existing-phones-no-reflash)) ·
`--i-understand-adb-exposure` (set the profile credential over adb — see
[Secret custody](#secret-custody-model)) · `--resolve` (allow `plan` to resolve
the version over the network) · `--print-plan` (alias for the `plan` verb) ·
`--no-color`.

Env seams (tests override these; defaults are the real thing): `PW_ADB`,
`PW_FASTBOOT`, `PW_RELEASES_URL`, `PW_ALLOWED_SIGNERS`, `PW_EXPECTED_SIGNER_FP`
(empty allowed ONLY with `PW_ALLOWED_SIGNERS` overridden), `PW_SKIP_FP_PIN=1`,
`PW_JOIN_TIMEOUT`, `PW_POLL_INTERVAL`. Also `HMDM_URL` / `ATTEST_URL` supply
default `--headwind-url` / `--attestation-url` values (an explicit flag always
wins).

### Quick start

```console
$ scripts/phone-wizard.sh plan                      # offline dry-run of the whole flow (PLAN_* lines)
$ scripts/phone-wizard.sh wizard                    # guided TTY flow: detect → fetch → flash → attest → mdm-enroll → enroll → profile → ingest
# scripted, step by step:
$ scripts/phone-wizard.sh detect
$ scripts/phone-wizard.sh fetch  --codename komodo --channel stable
$ scripts/phone-wizard.sh flash  --serial <S> --codename komodo         # typed-serial confirm on a TTY
# management plane, immediately after flash, BEFORE 'profile' (see Management plane):
$ scripts/phone-wizard.sh attest     --serial <S> --auditor-apk auditor.apk \
    --auditor-signer-sha256 <fork-cert-sha256> --attestation-url <attestation-server-console-url>
$ scripts/phone-wizard.sh mdm-enroll --serial <S> --headwind-apk hmdm.apk \
    --headwind-signer-sha256 <headwind-cert-sha256> --headwind-url <headwind-console-url>   # tailnet-only; see Management plane
$ scripts/phone-wizard.sh enroll --serial <S> --keys-dir <keys>         # or --login-server + --authkey-file
# an ALREADY-RUNNING phone (GrapheneOS or stock Android) — no flash needed:
$ scripts/phone-wizard.sh enroll --keys-dir <keys>                     # os probe records grapheneos|android
$ scripts/phone-wizard.sh enroll --no-usb --keys-dir <keys> --device-id phone-existing-01 --codename oriole   # no adb at all
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
  join is verified by polling for a CGNAT (`100.64/10`) address on the
  Tailscale `tun*` interface over adb. (Android's Tailscale app is a
  `VpnService`, so the kernel names its interface `tun0`/`tunN`, never
  `tailscale0` — that name only exists on desktop `tailscaled`. The probe
  scopes the CGNAT match to `tun*` so a cellular carrier-NAT `100.64/10`
  address on an `rmnet*` interface is not mistaken for a join.)

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

## Onboarding existing phones (no reflash)

`enroll` does not assume the device came through this wizard's own `flash` —
it is a first-class path for **already-running** phones, both existing
GrapheneOS phones and **stock Android** phones. `flash` stays
GrapheneOS/Pixel-only; nothing here changes that.

### USB-guided (adb) — the default `enroll` above

The OS probe (`ro.build.version.incremental` datestamp **AND** a `grapheneos`
getprop marker — both required, not either alone, so a non-GrapheneOS ROM
with a datestamp-shaped incremental can't be misclassified — else
`ro.build.version.release`) records what it finds — `os:"grapheneos"` or
`os:"android"` — into `enrollment.json` and, downstream, `ingest.json`. It
**never gates** on which one it finds: stock Android is a supported OS for
enroll, not a `--force`-guarded fallback. `--force` is reserved for the case
the probe genuinely cannot tell (no GrapheneOS signal **and** no readable
release property) — that case alone is recorded `os:"unknown"` and refuses
without `--force`.

**This is a best-effort, SPOOFABLE heuristic, not a security boundary.** Every
signal it reads (`ro.build.version.incremental`, the `grapheneos` getprop
string, `ro.build.version.release`) is a build/OEM-controlled property that a
tampered or custom ROM can set to whatever it wants — `enroll`'s own OS probe
cannot cryptographically attest what OS is actually running. That is what the
self-hosted [AttestationServer trust root](#management-plane) is for (`attest`
— hardware-backed, both classes); it is now wired up, but it is a **separate
verb producing a separate, parallel record** (`attestation.json`,
advisory/logged per D9, and itself only *operator-attested* pairing in v1, not
a wizard-verified cryptographic pass — see [Management
plane](#management-plane)). It does not retroactively upgrade `enroll`'s own
`os` field. Downstream consumers of `enrollment.json` / `ingest.json` must
still not treat the `os` field as a verified fact; that is also why its
verification tier is named `adb-heuristic`, not `adb-verified` — see the table
below.

### `--no-usb` — no adb at all

`enroll --no-usb` drops the adb dependency entirely for hosts with no
USB/adb access to the handset (or an operator who would rather not tether
it). It prints a guided, handset-only runbook — install Tailscale, point it
at the custom coordination server, authenticate with the pre-auth key (the
key is still **never** echoed without `--show-authkey`) — then writes an
`enrollment.json` marked `verification:"operator-attested"` with
`tailscale_ip:null`: the wizard performed no adb probe to confirm the join
itself. It needs `--device-id` **and** `--codename` explicitly (no adb probe
runs, so there is no serial to derive the id from and no way to read the device
model — an empty codename would strand the follow-up `ingest`) and exits 0 with
a **NEXT STEPS** block telling the operator how to
verify the join **mesh-side** instead: approve the PENDING node (ADR-14) in
the superadmin UI, then confirm a `100.64/10` tailnet address there or via
`headscale nodes list`.

| | USB-guided `enroll` | `enroll --no-usb` |
| --- | --- | --- |
| adb required | yes | no |
| OS recorded | `grapheneos` \| `android` \| `unknown` (probed) | `unknown` (not probed) |
| Join verified by | polling the Tailscale `tun*` interface for a `100.64/10` address | operator, mesh-side, after the fact |
| `enrollment.json` `verification` | `adb-heuristic` (best-effort, spoofable getprop signal — see above) | `operator-attested` |
| `enrollment.json` `tailscale_ip` | the polled address | `null` |

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
puts the passphrase **in adb argv, which is visible on BOTH exposure
surfaces**: phone-side (logcat/`ps` on the device) **and** on the operator's
own host, in the local `adb` client process's own argv (`ps auxww` /
`/proc/<pid>/cmdline`, or any execve/audit logging) for the life of that
child process — a real risk on a shared provisioning workstation, jump box,
or CI runner, i.e. exactly the kind of host this driver is designed to run
on unattended. That path is a documented residual exposure and requires the
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
`codename`, `marketing_name`, `os` (`grapheneos`|`android`|`unknown` —
inherited from `enrollment.json`'s OS probe, see
[Onboarding existing phones](#onboarding-existing-phones-no-reflash)),
`os_version`, `superdomain`, `login_server`, `tailscale_ip`,
`tailscale_hostname`, `role`, `attached_domain`,
`enterprise_profile{present,user_id,credential_custody}`,
`attestation_url`, `auditor_package`, `attestation_verdict` (folded in from
`attestation.json` when `attest` has run — empty strings otherwise; advisory
fields only, per D9 never enrollment-blocking), `enrolled_at`,
`generated_at`. Recorded facts (enrollment/profile records) are preferred;
live adb detection fills only what is missing and reachable. The schema
string stays `phone-ingest/v1` — the new attestation fields are additive, so
a pre-Phase-3 consumer can still parse the record.

**`mdm.json` is not yet folded into `ingest.json`.** `mdm-enroll` writes its
own record (`device_id`, `serial`, `dpc_package`, `headwind_url`, `os`,
`set_via:"adb-device-owner"`, `enrolled_at`) alongside `attestation.json` and
`enrollment.json` under `<out>/device/<device-id>/`, but — unlike the
attestation fields above — `cmd_ingest()` does not currently read it. Until a
future revision folds `mdm.json` into the ingest record (or bumps the schema
to carry a dedicated `mdm{...}` object, per the design's `phone-ingest/v2`
sketch), a device-registry consumer that needs MDM-enrollment status must
read `mdm.json` directly. Tracked as a real, currently-open gap — not
silently glossed over.

Default is **emit-only**. The dedicated registry endpoint is
**`POST /bff/internal/device-registry/phone-ingest`** (snapdragon-admin-bff-api):
point `--ingest-url` at it with the mTLS identity flags
(`--client-cert`/`--client-key`/`--ca`; the wizard fails closed without
them), plus `--internal-token-file F` when the deployment arms the BFF's
app-layer `X-Internal-Token` gate (armed prod 401s the POST without it; the
token rides a 0600 `-H @file` header file, never curl's argv). It accepts exactly this `phone-ingest/v1` shape (snake_case, unknown
additive keys ignored; non-phone `schema`/`device_class` is a clean 400),
UPSERTs one `phone_device` row per `device_id` (a re-ingest refreshes the
telemetry and bumps `ingest_count`), and rides the same mTLS-gated
`/bff/internal/**` transport as the node self-report. A superadmin reads the
fleet at `GET /bff/superadmin/phone-devices` (+ `/{deviceId}`). Do **not**
point `--ingest-url` at `/bff/internal/device-enrollment/self-report` — that
is a **different, disjoint contract**: the node-side `machineKeyFp`
self-report used for headscale cluster-node reconciliation
(`specs/usr/sbin/snapdragon-device-enrollment-report`), whose handler
requires `machineKeyFp` — a `phone-ingest/v1` record posted there fails Bean
Validation and lands nowhere useful.

## Remote-management model

Remote management is the USB-tethered verbs above (now including `attest` and
`mdm-enroll`, see [Management plane](#management-plane)) plus the **mesh-side
controls** that were always there: headscale key expiry / node removal, and
Casdoor credential revocation. The earlier v1 non-goal — "no MDM agent, no
on-phone resident daemon" — is **superseded**: Headwind's DPC agent
(`com.hmdm.launcher`) is now an on-phone resident daemon by design, running in
device-owner mode on every phone that has run `mdm-enroll`. What is still
true, and remains a deliberate v1 non-goal: **no first-party APK store** —
`phone-wizard.sh` sideloads exactly two vetted, signer-pinned APKs (the
Headwind DPC, the Snapdragon Auditor fork) plus the optional Tailscale APK;
general app push/update/delete across a fleet is a Headwind CE console
capability, reachable by an operator directly against the Headwind server, not
something this wizard drives. Losing a phone that never ran `mdm-enroll`
still costs only mesh membership and platform sessions; a phone that **has**
been enrolled as a Headwind device-owner is additionally reachable through the
Headwind console for remote wipe/lock/policy — see
[Management plane](#management-plane).

## Management plane

**Now real, not a roadmap paragraph.** The device-management plane for
**both** stock-Android and GrapheneOS phones is two independent, self-hosted,
default-off cluster optional-services — **Headwind MDM**
([github.com/h-mdm](https://github.com/h-mdm), Apache-2.0,
`specs/cluster/apps/23-headwind.yaml`) and the **GrapheneOS
AttestationServer** (MIT, forked, `specs/cluster/apps/24-attestation-server.yaml`)
— both merged to `main` as cluster manifests (namespace `snapdragon-pki`,
tailnet-only, Harbor/superadmin devops posture, no public
`*.CLUSTER_DOMAIN` surface). `scripts/phone-wizard.sh`'s `attest` and
`mdm-enroll` verbs are the operator-facing glue that drives them from the
handset side (merged via #390, hardened by #393 — see the top-of-doc status
banner). No managed-Google-Play / Android-Enterprise-style
plane routed through a third-party SaaS vendor's backend was used or
considered for either half — both services are sovereign, no Google
FCM/Pub/Sub/Play-Integrity dependency for management traffic.

### Ordering: attest, then mdm-enroll, then profile — never reversed

Device-owner mode (`dpm set-device-owner`) is a **one-shot AOSP gate**: it
only succeeds while the target user has zero secondary users and zero added
accounts, and is **permanent** for the life of the OS install once foreclosed
— no undo short of a reflash. The wizard's 8-step order places both
management-plane verbs immediately after `flash`, before anything that could
add a user or account:

```
1/8 detect  2/8 fetch  3/8 flash  4/8 attest  5/8 mdm-enroll  6/8 enroll  7/8 profile  8/8 ingest
```

- **`attest` runs first (4/8)** — it needs no device-owner state, so it
  captures the hardware trust root on the cleanest possible device state.
- **`mdm-enroll` runs next (5/8)**, and is the *last* point at which
  device-owner mode is obtainable — `cmd_mdm_enroll()` opens with a
  fail-closed precondition check (`adb shell pm list users` must show exactly
  one user AND `adb shell dumpsys account` must show zero accounts —
  `dpm set-device-owner` fails if either is violated, independently);
  running it out of order turns the cryptic AOSP `IllegalStateException`
  into a documented `exit 2` ("a secondary user/account already exists —
  device-owner mode is no longer obtainable; reflash to retry"). `--force`
  downgrades this to a warning.
- **`profile` (7/8) is what permanently forecloses the window** — it creates
  the escrowed `enterprise` secondary user. It must never run before
  `mdm-enroll`.
- **Already-enrolled / already-running phones** (see [Onboarding existing
  phones](#onboarding-existing-phones-no-reflash)) cannot retroactively obtain
  device-owner mode — an inherent AOSP constraint, not a wizard limitation.
  The honest composed flow for such a device is `attest` → `enroll` →
  `profile` → `ingest`, with `mdm.json` simply never written and MDM
  enrollment requiring a factory-reset-and-redo.

### `mdm-enroll` — Headwind device-owner enrollment

`mdm-enroll` runs `dpm set-device-owner com.hmdm.launcher/.AdminReceiver`
over adb against a fresh device, after installing the Headwind DPC APK
(`--headwind-apk`, signer-pinned via `--headwind-signer-sha256` using the same
`verify_installed_signer()` apksigner-verify helper `enroll` uses for the
Tailscale APK — it pulls the currently-installed `base.apk` and checks its
apksigner cert digest, pinning what is actually on the device). Once
device-owner mode is set, the wizard pushes a non-interactive `init.json`
(`{"com.hmdm.BASE_URL": "<--headwind-url>"}`) into the app's external files
dir (`getExternalFilesDir()/init.json`), which Headwind's own
`updateSettingsFromFile()` reads on next launch — no operator QR scan needed
for the server-pointing step itself. Writes `mdm.json` (`device_id`, `serial`,
`dpc_package`, `headwind_url`, `os`, `set_via:"adb-device-owner"`,
`enrolled_at`) under `<out>/device/<device-id>/`.

**Stock-Android caveat (best-effort, not a wizard bug).** GrapheneOS
device-owner enrollment via adb is the **reliable** path — no Play Protect
gate exists at setup on GrapheneOS at all. Since late 2025, Google Play
Protect enforces an approved-DPC allow-list at provisioning time on
Play-Protect-certified stock-Android devices; an unlisted custom DPC can hit
that block with an opaque appeal path. `cmd_mdm_enroll()` prints an
un-suppressible advisory before attempting `dpm set-device-owner` on a
stock-Android device, and a resulting failure is a normal `exit 1`
(precondition/tool failure) with the allow-list named as the likely cause —
not treated as a driver defect.

### `attest` — AttestationServer pairing via the Snapdragon-forked Auditor

`attest` installs our own fork of GrapheneOS's Auditor app — package
`systems.snapdragon.auditor` (deliberately different from the stock
`app.attestation.auditor`, so a pin is unambiguous and a stock install is
never clobbered) — signer-pinned via `--auditor-signer-sha256`, using the same
shared apksigner-verify helper `mdm-enroll` and `enroll` use. It then prints a
runbook pointing the operator at the self-hosted AttestationServer console
(`--attestation-url`, e.g. `https://attestation.snapdragon.systems`) to scan
the pairing QR code from inside the Auditor app. **The in-app camera scan
cannot be driven over adb** — this wizard performs no cryptographic
verification of the attestation chain itself, so the pairing is recorded
honestly as `verdict:"operator-paired"`, never a claimed cryptographic pass.
Attestation is **advisory/logged in v1** (D9), not a hard enrollment-blocking
precondition — fleet-scale operational characteristics (alerting granularity,
a machine-queryable verdict API) are undocumented upstream and are meant to
be piloted before promoting this to a hard gate. Writes `attestation.json`
(`device_id`, `auditor_package`, `attestation_url`, `verdict`, `at`) under
`<out>/device/<device-id>/`, and its `attestation_url` / `auditor_package` /
`attestation_verdict` fields are folded into `ingest.json` — see
[Ingest](#ingest--device-registry).

### The coupling: the fork's signer pin *is* the server's trust anchor

The self-hosted AttestationServer only trusts attestations that carry our
own Auditor fork's identity — this is a build-time patch to
`AttestationProtocol.java`'s `AUDITOR_APP_PACKAGE_NAME_RELEASE` /
`AUDITOR_APP_SIGNATURE_DIGEST_RELEASE` constants
(`specs/cluster/manifests/attestation-server/Dockerfile`), not the stock
GrapheneOS Auditor's published pin. Concretely:

```
server AUDITOR_SIGNER_DIGEST  ===  Snapdragon Auditor fork's release-signing-cert SHA-256
server ATTESTATION_DOMAIN     ===  fork's DOMAIN constant  ===  attestation.snapdragon.systems
```

These are **built and set together** — if `AUDITOR_SIGNER_DIGEST` does not
exactly equal the fork's real release-cert digest, the server rejects
*every* attestation from our own app, with no partial-credit or fallback
path. The `--auditor-signer-sha256` value `attest` pins on-device must be the
same digest the AttestationServer image was built with. This is the same
value operationally, checked at two independent points (the wizard's
apksigner-verify on-device, and the server's compiled-in constant) — a
mismatch anywhere in the chain fails closed, never silently.

## Summary

| Capability | Where | State |
| --- | --- | --- |
| Driver: full verb surface (`plan`/`detect`/`fetch`/`flash`/`attest`/`mdm-enroll`/`enroll`/`profile`/`rotate-profile-pass`/`remove-profile`/`ingest`/`status`/`wizard`) | [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | 🚧 |
| Fail-closed artifact verification (sshsig + double fingerprint pin, tamper ⇒ delete + exit 3) | `dlv_verify_sshsig` + [`scripts/phone-allowed-signers`](../scripts/phone-allowed-signers) | 🚧 |
| Pinned device catalog (21 devices, unknown codename ⇒ exit 4, no escape hatch) | [`scripts/phone-devices.tsv`](../scripts/phone-devices.tsv) | 🚧 |
| Destructive gates (typed-serial flash confirm; non-TTY needs `--yes`+`--serial`; typed profile-name removal) | `flash` / `remove-profile` | 🚧 |
| Tailnet enroll (keys-dir contract, SEC-08 pre-auth or Casdoor OIDC, ADR-14 approval, 100.64/10 join verify) | `enroll` | 🚧 |
| Escrowed enterprise profile (vault-seed custody, operator-set default, atomic rotation, revocation trail) | `profile` / `rotate-profile-pass` / `remove-profile` | 🚧 |
| `phone-ingest/v1` registry record + mTLS POST | `ingest` | 🚧 |
| Offline `plan` dry-run + `REDACTED` secret discipline | `plan` / `--print-plan` | 🚧 |
| `make phone-*` thin face (host-side delegates; secrets stay file-path knobs) — all 13 verbs incl. `phone-mdm-enroll`/`phone-attest` | `Makefile` | 🚧 |
| Thin ncurses-menu face over the driver (all 13 verbs + MDM/attestation knob sub-screen, non-build precedent) | `phone_screen` in [`scripts/build-menu.sh`](../scripts/build-menu.sh) | ✅ |
| Thin Studio (GUI) face over the driver | — | 🔭 |
| APK store (general fleet app push/update/delete beyond the wizard's own vetted, signer-pinned sideloads) | — | 🔭 (deliberate v1 non-goal; Headwind's own console can do this directly, see [Remote-management model](#remote-management-model)) |
| Existing-device onboarding (GrapheneOS + stock Android, USB-guided or `--no-usb`, no reflash) | `enroll` | 🚧 |
| Headwind MDM cluster optional-service (Postgres-backed, tailnet-only, `snapdragon-pki` namespace) | `specs/cluster/apps/23-headwind.yaml`, `specs/cluster/manifests/headwind/` | ✅ merged |
| GrapheneOS AttestationServer cluster optional-service (SQLite PVC, tailnet-only, forked Auditor identity baked in) | `specs/cluster/apps/24-attestation-server.yaml`, `specs/cluster/manifests/attestation-server/` | ✅ merged |
| `mdm-enroll` verb — Headwind device-owner enrollment, fresh-device precondition (now checks accounts too, not just users — #393), signer-pinned DPC APK, `init.json` `BASE_URL` injection | `cmd_mdm_enroll()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390, hardened #393) |
| `attest` verb — Snapdragon-forked Auditor pairing to the self-hosted AttestationServer, operator-attested verdict | `cmd_attest()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390) |
| 8-step wizard order (`attest`/`mdm-enroll` immediately post-flash, before `profile`) | `cmd_wizard()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390) |
| Auditor-fork ↔ AttestationServer signer-digest coupling (`AUDITOR_SIGNER_DIGEST`) | [Management plane](#management-plane) | ✅ server-side patch merged; digest itself is set at Auditor-fork release-signing time (operator step, outside this repo) |
| OTA/update posture management (GrapheneOS updates itself; Headwind CE ships no OTA lever) | — | 🔭 |

## Deferred

Tracked here per the driver's header. Still 🔭, by design. The earlier
**"any on-phone agent (MDM, resident daemon, APK store)"** entry is
**superseded and removed from this list** — Headwind's device-owner DPC is
now delivered (see [Management plane](#management-plane)); only the
APK-store half of that non-goal still stands (see the Summary table).

- **Thin Studio (GUI) face** — over the driver's verbs, exactly like
  the Local Docker mesh and go-live precedents (driver owns all logic; faces
  stay thin, no build-matrix row). The `make phone-*` face is ✅ complete —
  all 13 verbs, including `phone-mdm-enroll` and `phone-attest` (with the
  `HEADWIND_*`/`AUDITOR_*`/`ATTESTATION_URL`/`INTERNAL_TOKEN_FILE` knobs
  forwarded file-path-only, per the custody pattern) — and the **ncurses-menu
  face is ✅ complete** (`phone_screen` wraps all 13 verbs; the MDM/attestation
  sub-screen threads the same knobs, ingest token as a file path only). Only
  the Studio face remains 🔭.
- **Casdoor SSO for Headwind** — nothing in this recon confirmed Headwind has
  OIDC/SAML support (its own auth is local username/password behind a
  pluggable `HmdmAuthInterface`); until that is independently confirmed,
  Headwind stays gated by network reachability + `ROLE_SUPERADMIN` route
  access plus a Vault-managed local admin account, not Casdoor identity
  federation.
- **`attest --attestation-verdict-source api`** — an automated, machine-queryable
  attestation-verdict mode. No confirmed headless "submit and get a JSON
  verdict" API surface exists for the self-hosted AttestationServer today
  (its `/api/devices.json` sits behind a login-session cookie, not a bare API
  key); `attest` ships only the operator-attested pairing tier in v1.
- **GrapheneOS QR-at-setup provisioning** — Headwind's `SetupWizard2` PRs
  remain unmerged upstream as of this recon. ADB is the only supported
  GrapheneOS device-owner path today; `cmd_mdm_enroll()` is written so that
  QR provisioning, once it lands upstream, only touches the function's
  internals, not the wizard's step order or exit-code contract.
- **OTA/update posture reporting** — GrapheneOS's own updater handles OS
  updates; Headwind CE ships no OTA lever, so a management-plane-visible
  update/compliance report would ride a future agent capability this driver
  does not have.
- **Folding `mdm.json` into `ingest.json`** (or a `phone-ingest/v2` schema
  bump carrying a dedicated `mdm{...}` object) — see
  [Ingest](#ingest--device-registry). A real, currently-open gap, not a
  design decision.
