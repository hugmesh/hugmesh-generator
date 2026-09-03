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
(self-hosted AttestationServer pairing, via a HugMesh-forked Auditor app)
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
anything, and the destructive ones are gated. The table below is the **phone**
(default) device class; `--device-class quest` narrows it to a 4-verb chain —
see [Quest headsets](#quest-headsets-meta-quest-33s----device-class-quest).

| Verb | Mutates? | What it does |
| --- | --- | --- |
| `plan [verb]` | never | Dry-run (default target: `wizard`). Validates options + catalog lookup, prints `PLAN_<K>=<V>` lines, touches NOTHING. Fully offline unless `--resolve` is passed (the version prints as `resolve-at-fetch` when unknown). `--print-plan` anywhere is an alias for this verb. |
| `detect` | never | Read-only probe: adb/fastboot device list, serial, codename, current OS fingerprint. Prints `DEVICE_*` lines. |
| `fetch` | work-dir | Resolve the `--channel` release, download the GrapheneOS `<codename>-install-<version>.zip`(+`.sig`) into `--work-dir`, verify the sshsig **fail-closed**, extract, write a `.verified-<sha256>` marker. Idempotent (a cached resolution next to its verified zip makes re-fetch fully offline). |
| `flash` | **DESTRUCTIVE** | Wipe the phone and flash the VERIFIED artifact. Typed-serial confirmation on a TTY; non-TTY requires BOTH `--yes` AND a matching `--serial`. Refuses anything without a matching verification marker, and re-verifies the signature again before flashing. |
| `attest` | device + out-dir | Install the signer-pinned HugMesh-forked Auditor (`--auditor-apk`/`--auditor-signer-sha256`) and print the self-hosted [AttestationServer](#management-plane) pairing runbook (`--attestation-url`). The in-app QR scan cannot be driven over adb, so this is an **operator-attested** pairing (`verdict:"operator-paired"`), not a cryptographic verification by the wizard. Runs **before** `mdm-enroll` — see [Management plane](#management-plane) for why. Writes `attestation.json`. |
| `mdm-enroll` | device + out-dir | Enroll the phone as a Headwind MDM device-owner (`dpm set-device-owner com.hmdm.launcher/.AdminReceiver`) after a fail-closed fresh-device precondition (`pm list users` must show exactly one user AND `dumpsys account` must show zero accounts). Installs the signer-pinned DPC APK (`--headwind-apk`/`--headwind-signer-sha256`) and pushes a non-interactive `init.json` (`com.hmdm.BASE_URL=--headwind-url`) into its external files dir. **MUST run before `profile`** — see [Management plane](#management-plane). Writes `mdm.json`. |
| `enroll` | out-dir | Add a running phone to the mesh — freshly flashed **or already-running**, GrapheneOS **or stock Android** (the OS probe records which; it never gates — see [Onboarding existing phones](#onboarding-existing-phones-no-reflash)). Guided tailnet join with keys from `--keys-dir` (docker-mesh-node layout) or `--login-server`/`--authkey-file`; verifies the tailnet join (a 100.64/10 address on the Tailscale `tun*` interface — Android names it `tun0`, not `tailscale0`) and writes the enrollment record. `--no-usb` drops adb entirely (guided handset-only runbook, operator-attested record; needs `--device-id` + `--codename`). |
| `profile` | device + out-dir | Create the `enterprise` secondary user, generate + escrow its passphrase (vault-seed custody), operator sets the credential on the handset (default path). **This permanently forecloses device-owner mode** — see [Management plane](#management-plane); it must never run before `mdm-enroll`. |
| `rotate-profile-pass` | out-dir (+device) | Generate + escrow a new profile passphrase atomically (previous escrow kept as `.prev-<ts>`). |
| `remove-profile` | **DESTRUCTIVE** | Remove the enterprise user (typed profile-name confirm, or `--yes`); escrow retired to `.revoked-<ts>`. Per-profile FBE keys are evicted — the profile's data is gone. |
| `ingest` | out-dir (+POST) | Emit the `phone-ingest/v2` device-registry record (folding in `attestation.json` and `mdm.json` fields when present — see [Ingest](#ingest--device-registry)); with `--ingest-url` + the mTLS flags, POST it (fail-closed without client cert+key). |
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
`phone-<sanitized serial>`) · `--superdomain D` (Tailscale root domain /
MagicDNS base, default `hugmesh.internal`) · `--role
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
env `HMDM_URL`) · `--auditor-apk F` (HugMesh-forked Auditor APK to
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

## The Tailscale root domain (what the phone joins)

The handset joins the brand's **Tailscale root domain** — quoted verbatim
from [`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md), which is the canonical
definition:

> - **Tailscale root domain** (formerly "orchestration superdomain", the name
>   Studio and this document used before 2026-09) — `<brand>.internal` (default
>   `hugmesh.internal`), the headscale MagicDNS `base_domain` every mesh node
>   joins. It is **permanently internal**: it carries the tailnet + `kube-api.<superdomain>`
>   control-plane endpoint, is never routable, and is **never** go-live-flipped.
>   It is delivered through the KEYS channel — `scripts/gen-provision-keys.sh`
>   stamps it into `provision.json` `.mesh.magic_dns_domain` (from `SUPERDOMAIN` /
>   `--superdomain`, default `<BRAND>.internal`), which headscale consumes — so no
>   go-live provider, DNS record set, or `RELEASE_STATE` transition ever touches it.

The wizard's `--superdomain` flag (default `hugmesh.internal`) is this same
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
   `hugmesh/headscale` group — the same gate the superadmin's own client
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

## Quest headsets (Meta Quest 3/3S) — `--device-class quest`

`--device-class quest` onboards a **Meta Quest 3 (`eureka`) or Quest 3S
(`panther`)** as another MDM-managed Android device on the mesh — **as-is, on
Horizon OS**: this wizard never reflashes a headset. The class changes three
things and nothing else — the codename **catalog**, the **verb subset**, and a
fail-closed **identity pin** — every custody rule above (masked auth key,
0600 `--authkey-file`, dry-run-by-default `plan`) applies unchanged.

- **Class-scoped catalog** — quest codenames resolve against
  [`scripts/quest-devices.tsv`](../scripts/quest-devices.tsv) (exit 4 on
  anything else, same as the phone catalog). The split is load-bearing:
  **`panther` is BOTH the Pixel 7 (phone catalog) and the Quest 3S (quest
  catalog)** — the class picks which catalog a codename means, and detection
  pins the rest: `ro.product.manufacturer` must be `oculus`/`Meta`
  (USB vendor id `2833`) or the quest path refuses the device outright. A
  fastboot-state device is likewise refused (that is a handset bootloader,
  not a Quest).
- **The quest verb chain is `detect → mdm-enroll → enroll → ingest`**
  (`wizard` guides exactly those four; `plan` previews them):
  - `detect` — requires **Developer Mode ON** (a Meta developer account,
    enabled per-headset in the Meta Horizon phone app). When the headset is
    not adb-visible the driver prints the full Developer-Mode + udev
    (vendor `2833`) runbook instead of a bare failure.
  - `mdm-enroll` — the same Headwind device-owner enrollment (signer-pinned
    DPC APK, `init.json` `com.hmdm.BASE_URL` + `com.hmdm.CONFIG`), with the
    phone's fresh-device gates downgraded to **advisories**: Horizon OS setup
    requires a Meta account, so `dpm set-device-owner` is the real arbiter and
    its refusal (with the hint) is the gate. `--headwind-config` is the
    app-push lever; `--xr-chat-url` (https-only — WebXR needs a secure
    context) records the XR-chat entry URL in `mdm.json`, prints the Headwind
    web-page-app console runbook, and fires a `VIEW` intent so the operator
    can confirm the room loads in the headset browser.
  - `enroll` — the same tailnet join with a **sideload runbook** for the
    Tailscale APK (no Play/Horizon-store carry on a managed headset) and the
    **same `tun0` 100.64/10 join verification** as phones. Default device id
    `quest-<sanitized serial>`.
  - `ingest` — the `phone-ingest/v2` record with `device_class:"quest"`
    (plus the honest registry-gap warning until the registry grows the field).
- **Unsupported, fail-closed with rationale (exit 2):** `fetch`/`flash`
  (GrapheneOS artifacts are Pixel-only; Horizon OS cannot be reflashed),
  `attest` (the Auditor/AttestationServer trust root requires GrapheneOS-class
  hardware-attestation profiles — **no attestation tier exists for Quest**),
  and the `profile` verbs (Horizon OS's user model is Meta-account-bound; no
  separately-encrypted GrapheneOS-style secondary user to escrow).
  `--mdm-provider azure-intune` is refused for the class too: Horizon OS has
  no Intune/Company-Portal support — a Quest is managed via the `dpc-adb`
  provider (Headwind) only.

**All four faces** drive the one driver: CLI (`make quest-plan` /
`quest-detect` / `quest-mdm-enroll` / `quest-enroll` / `quest-ingest` /
`quest-status` / `quest-wizard`, with `HEADWIND_CONFIG=` / `XR_CHAT_URL=`
knobs), ncurses (`quest_screen` under the "MDM Quest headset" opening choice —
quest verbs only, Headwind sub-screen, XR-chat URL knob), Studio GUI
(`QuestPage`, the ModePage "MDM Quest headset" side-flow — streamed verbs
off-thread, guided `wizard` handed to a terminal), and the raw
`scripts/phone-wizard.sh <verb> --device-class quest`. A live headset smoke is
`make quest-plan CODENAME=eureka` (offline dry-run) then `make quest-detect`
with the Quest USB-attached.

## Thin desktop (Quest ⇄ thin-client node, tailnet-only) — `--thin-desktop`

An **opt-in** capability pair (§8b of the XR-chat design; see
[`docs/XR-CHAT.md`](XR-CHAT.md)): a mesh-enrolled Quest opens a usable
**virtual desktop of one of the mesh's thin-client x86 desktop nodes** over
the tailnet — never off-mesh. Transport is **Sunshine** (self-hosted stream
host, GPLv3) on the node + **Moonlight** (`com.limelight`) on the headset;
pairing and streaming ride tailnet IPs/MagicDNS names only.

### Quest side — `--thin-desktop` on `mdm-enroll` (quest class only)

`mdm-enroll --thin-desktop` provisions the headset as the Moonlight terminal,
riding the SAME two-leg pattern as the XR-chat URL provisioning above:

- **Immediate (this wizard):** sideload the Moonlight APK with the same
  operator-custody + signer-pin path as every APK this wizard trusts —
  `--moonlight-apk <file>` + `--moonlight-signer-sha256 <hex>` (fail-closed
  apksigner verify of the on-device APK; exit 3 on mismatch). Then push the
  **managed host list** (`--thin-desktop-hosts frite,box2.hugmesh.internal`,
  env `THIN_DESKTOP_HOSTS`; lowercase tailnet DNS names, charset fenced
  fail-closed) as `hugmesh-thin-desktop-hosts.json` into Moonlight's external
  files dir — the exact `init.json` push mechanics. **Honesty note:**
  Moonlight does not auto-import that file (no managed-config surface exists
  in moonlight-android); it is the on-device custody record and the
  Headwind-push target — the operator adds each host in Moonlight by its
  tailnet name.
- **Durable (Headwind, app-push):** the printed console runbook — upload the
  same Moonlight APK as an application in the device's CONFIGURATION
  (`--headwind-config`, the app-push lever) and add the host-list file to
  that configuration's **Files**, so every headset on the configuration
  converges without adb.
- **Pairing (operator, per node):** Moonlight on the headset adds the node by
  tailnet name → shows a **PIN** → the operator enters it in the Sunshine web
  UI at `https://localhost:47990` **on that node's console** (or an SSH
  tunnel) — the pairing UI is loopback-only by design, never mesh-reachable.

Gates (all fail-closed, before any adb call): `--thin-desktop` is
**quest-class only** (exit 2 with rationale on phones — there is no
phone-class thin-desktop terminal in v1); the Moonlight/host knobs **require**
the toggle (exit 1); bad host charset exits 1. `mdm.json` records
`thin_desktop` + `thin_desktop_hosts` uniformly (`false`/`[]` when off — an
un-toggled run's adb traffic is byte-identical to before the feature).
Faces: CLI `make quest-mdm-enroll THIN_DESKTOP=1 MOONLIGHT_APK=…
MOONLIGHT_SIGNER_SHA256=… THIN_DESKTOP_HOSTS=…`; ncurses `quest_screen` →
"Thin desktop" sub-screen; Studio `QuestPage` → "Thin desktop" toggle group.
E2E: `tests/phone/e2e-quest-thin-desktop.sh` (mocked adb, ordered sequence +
pushed-file content + every failure path).

### Node side — `build-x86-host-stage4.sh --with-sunshine`

The generator bakes the stream host into **tailnet CLIENT desktop images**
(default-off; warn-dropped on cluster roles — no desktop session to stream —
and on tailnet-less desktops: standalone/unaffiliated/`--skip-tailscale`; a
composable `--standalone --with-tailscale` desktop stays eligible):

- **Package** `games-util/sunshine` (own flag-gated package list + `~amd64`
  keyword file, the `--steam` pattern).
- **Mesh fence** `hugmesh-sunshine-firewall` — a reconcile-family member (one
  script, one OpenRC oneshot ordered before `tailscaled`, one clearly-scoped
  nftables table `hugmesh_thin_desktop`, 60s cron): stream ports **TCP 47984,
  47989, 48010 + UDP 47998-48002** admitted ONLY `iifname tailscale0` AND
  `saddr 100.64.0.0/10` (both conditions — a spoofed CGNAT source on the LAN
  iface stays dropped), dropped everywhere else; **web UI TCP 47990
  loopback-only**. Sunshine has no native bind-to-interface option, so this
  netfilter fence IS the "bound to the tailscale iface only" guarantee.
  Fail-closed: render/apply errors keep the existing ruleset.
- **Session service** — `/etc/xdg/autostart/hugmesh-sunshine.desktop` →
  `hugmesh-sunshine-session`: Sunshine must run *inside* the user's desktop
  session (display capture + uinput), and this fleet's desktop images are
  **OpenRC**, so the XDG autostart wrapper is the deliberate equivalent of
  the design's "systemd user service" (documented divergence; idempotent per
  user, waits for `tailscale0`, launches with the managed
  `/etc/hugmesh/thin-desktop/sunshine.conf` — `upnp off`,
  `origin_web_ui_allowed pc`, default port base).
- **Studio/menu parity:** Studio RolePage "Client desktop options" tri-state
  (G34 `--with-sunshine`/`--no-sunshine`), ncurses x86 options
  "Thin-desktop host" toggle, flag-coverage + build-matrix `check.sh` probes.

### WiVRn — the sibling path (documented stub, not rolled out)

Where Moonlight streams the node's **2D desktop** into a flat panel in the
headset, **WiVRn** streams a **native OpenXR app** (the shadows-of-the-net
PCVR build) from the same node to the same headset as actual room-scale VR.
v1 ships a config stub only — `/etc/hugmesh/thin-desktop/wivrn.toml.example`
(baked by `--with-sunshine`) documents the mesh-honest defaults (TCP+UDP 9757
fenced to the tailscale iface exactly like the Sunshine port set, tailnet
pairing only). The full rollout (package + fence extension + session unit) is
tracked follow-up work.

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
**`phone-ingest/v2`**: `device_id`, `device_class:"phone"`, `serial`,
`codename`, `marketing_name`, `os` (`grapheneos`|`android`|`unknown` —
inherited from `enrollment.json`'s OS probe, see
[Onboarding existing phones](#onboarding-existing-phones-no-reflash)),
`os_version`, `superdomain`, `login_server`, `tailscale_ip`,
`tailscale_hostname`, `role`, `attached_domain`,
`enterprise_profile{present,user_id,credential_custody}`,
`attestation_url`, `auditor_package`, `attestation_verdict` (folded in from
`attestation.json` when `attest` has run — empty strings otherwise; advisory
fields only, per D9 never enrollment-blocking),
`mdm{enrolled,dpc_package,headwind_url,set_via,enrolled_at}` (folded in from
`mdm.json` when `mdm-enroll` has run — `enrolled:false` with empty fields
otherwise, mirroring `enterprise_profile`'s presence contract), `enrolled_at`,
`generated_at`. Recorded facts (enrollment/profile records) are preferred;
live adb detection fills only what is missing and reachable.

The `mdm{...}` object is what bumped the schema string `v1`→`v2` — it closed
the tracked "mdm.json is not folded into ingest.json" gap.

**Merge-order note (cross-repo):** the `v2` bump is additive, but the BFF's
`PhoneIngestRequest` DTO pattern-pins the accepted schema string. Widening it
to accept both `phone-ingest/v1` and `phone-ingest/v2` is a coordinated
hugmesh-admin-bff-api change that **must land first** — until it does, a
`POST` of a `v2` record to a `v1`-only registry fails Bean Validation with a
clean `400` (the record is still written to disk, so nothing is lost; only the
POST leg fails). Once the BFF accepts both, v1 producers keep working (the
`mdm` fields simply stay null for them) and the bump is non-breaking on the
registry side.

Default is **emit-only**. The dedicated registry endpoint is
**`POST /bff/internal/device-registry/phone-ingest`** (hugmesh-admin-bff-api):
point `--ingest-url` at it with the mTLS identity flags
(`--client-cert`/`--client-key`/`--ca`; the wizard fails closed without
them), plus `--internal-token-file F` when the deployment arms the BFF's
app-layer `X-Internal-Token` gate (armed prod 401s the POST without it; the
token rides a 0600 `-H @file` header file, never curl's argv). It accepts the `phone-ingest/v2` shape — and still the older `phone-ingest/v1` — (snake_case, unknown
additive keys ignored; non-phone `schema`/`device_class` is a clean 400),
UPSERTs one `phone_device` row per `device_id` (a re-ingest refreshes the
telemetry and bumps `ingest_count`), and rides the same mTLS-gated
`/bff/internal/**` transport as the node self-report. A superadmin reads the
fleet at `GET /bff/superadmin/phone-devices` (+ `/{deviceId}`). Do **not**
point `--ingest-url` at `/bff/internal/device-enrollment/self-report` — that
is a **different, disjoint contract**: the node-side `machineKeyFp`
self-report used for headscale cluster-node reconciliation
(`specs/usr/sbin/hugmesh-device-enrollment-report`), whose handler
requires `machineKeyFp` — a `phone-ingest/v2` record posted there fails Bean
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
Headwind DPC, the HugMesh Auditor fork) plus the optional Tailscale APK;
general app push/update/delete across a fleet is a Headwind CE console
capability, reachable by an operator directly against the Headwind server, not
something this wizard drives. Losing a phone that never ran `mdm-enroll`
still costs only mesh membership and platform sessions; a phone that **has**
been enrolled as a Headwind device-owner is additionally reachable through the
Headwind console for remote wipe/lock/policy, and — once a superadmin has
confirmed it as **managed** — through the platform's own reversible, audited,
step-up-gated **remote lockout** (see
[Roles & device management](#roles--device-management-managed-vs-byod-and-remote-lockout)).
A BYOD phone the owner never took device-owner of is deliberately outside all of
this. See [Management plane](#management-plane).

## Roles & device management (managed vs BYOD, and remote lockout)

A phone is a **device**, not a role-bearing user. The human holding it
authenticates to the platform exactly as they always do — a Casdoor login
carrying their normal role (`user`/`mod`/`admin`/`superadmin`) — and that
identity is what governs everything they do through the gateways. The phone's
own identity is a *device* identity: a headscale/tailnet node plus (when
enrolled) a Headwind DPC posture. So `phone_device.role` is **inventory
telemetry, never an authorization input** — a phone can never grant its holder
access it did not already have, and the ingest channel (`/bff/internal/**`,
mTLS, device-reported) is stated in-code to "confer NO access." A guard test in
`hugmesh-admin-bff-api` pins this invariant so it cannot regress.

Two device classes, and only one is remotely manageable:

- **Mesh-owned (managed).** The mesh owner flashed / device-owner-enrolled the
  phone with **physical access** (`mdm-enroll`, USB, fresh-device-only). Such a
  phone can be **remotely locked** by a superadmin.
- **BYOD.** A phone the mesh owner never took device-owner of (plain `enroll`,
  including `--no-usb`). Normal registration, mesh membership, telemetry — but
  the owner has **no** management lever over it. A BYOD phone **can never be
  locked**; the lock endpoint refuses it with a clean 409.

**The trust boundary (why the distinction is spoof-proof).** The phone's
self-reported device-owner facts (`mdm.enrolled` / `mdm.set_via`,
[phone-ingest/v2](#ingest--device-registry)) arrive over the same in-cluster
mTLS ingest that "confers no access" — they are **trivially spoofable within
the cluster**, so they are treated only as an *advisory promotion hint*.
Lock-eligibility hangs off a separate, **authoritative** field —
`phone_device.management_mode` (`unmanaged` default, or `mesh_owned`) — that is
**writable only via `/bff/superadmin/**` by a SUPERADMIN**, never by the ingest
path. This mirrors the node registry's `owner_type`, which is likewise
operator-assigned at register time and never self-claimed. Concretely: after
`mdm-enroll`, the wizard prints a NEXT STEP telling the operator that a
superadmin must **confirm** the phone as managed in the fleet console
(`PUT /bff/superadmin/phone-devices/<id>/management {"mode":"mesh_owned"}`, or
the *Mark managed* action on the Phone-fleet page). The confirmation — a
superadmin-JWT-authenticated, step-up-gated action — is the authoritative act;
the device's self-report is only what surfaces the phone as *eligible to
promote*.

**Remote lockout** is a reversible, audited control-plane action modeled on the
node SSH-license revoke precedent (`device_ssh_license`): a CAS
`unlocked ↔ locked` state with a monotonic `lock_generation` and a
`lock_propagation_state` (`pending`/`applied`/`failed`/`degraded`), rows never
deleted (the state is its own audit trail). It is **SUPERADMIN-only and
step-up-gated** (`X-PhoneLock-StepUp`, mirroring SSH key issuance) — the
step-up stands in for the physical-access assurance the provisioning side had.
Endpoints: `POST /bff/superadmin/phone-devices/<id>/lock` (409 unless
`management_mode = mesh_owned`), `.../unlock`, and `.../management`. Gateway
RBAC needs no new row — the existing tailnet
`hugmesh-superadmin-gateway` → `/bff/superadmin/** → ROLE_SUPERADMIN` floor
already governs them (longest-pattern-wins); the per-method `@PreAuthorize` is
the fine gate.

Enforcement has **two flag-gated legs**, both best-effort, with the
control-plane lock state always authoritative regardless of their outcome:

1. **DPC lock via Headwind** (`app.phone-lock.headwind.enabled`, default off) —
   commands the device-owner DPC to lock through Headwind's `/rest` surface.
2. **Mesh-access cut** (`app.phone-lock.mesh-deny.enabled`, default off) —
   denies the locked phone's tailnet node at the headscale ACL layer (the same
   push mechanism the node SSH-license revoke uses), so a locked phone loses
   platform + mesh reachability, not just its screen.

With both legs off (the default) a lock still records authoritative,
audited state and reports `propagation_state = degraded` with the reason
"issue the lock via the Headwind `/manage` console" — so the capability is
useful the moment the manifests are deployed, and hardens as the legs are
enabled. **Honest infra gaps:** real-time DPC push to phones over MQTT
(`:31000`) is still the deferred tailnet-topology work noted in
`headwind.yaml`; the mesh-deny leg additionally needs the headscale-ACL feature
(`app.registry.headscale-acl.enabled`) and the phone→node ACL identity. These
are why the legs ship default-off, not because the control plane is
incomplete.

### Fleet owners & enterprise subscription

The lockout controls above are **SUPERADMIN-only** and reached over the tailnet.
The **fleet-owner** tier lets a *non-superadmin* enterprise customer manage the
subset of phones **they** own — locking/unlocking their own handsets — from the
**public** front-door gateway, without ever seeing anyone else's devices. Three
thin seams make that safe:

- **`ROLE_FLEET_ADMIN` capability.** A dedicated Casdoor role, a *sibling* of
  `admin`/`mod` (never a superset of `admin`, never auto-granted). It is the only
  non-superadmin role that reaches `/bff/admin/phone-fleet/**`. Granted by a
  SUPERADMIN via the existing role-grant surface (it is listed in the admin-bff
  `GRANTABLE_ROLE_PATTERN`).
- **Owner-within-domain scoping (the tenancy wall).** Two operator-authoritative
  columns on `phone_device` — **`physical_owner`** (the Casdoor subject who owns
  the handset) and **`owner_domain`** (the brand/domain it belongs to). Like
  `management_mode`, both are **writable only via `/bff/superadmin/**` by a
  SUPERADMIN**, never by the spoofable ingest path (the ingest INSERT/REFRESH
  column lists omit them, so a re-ingest can never set or overwrite them). Every
  fleet-owner read and mutation is predicated
  `WHERE physical_owner = :callerSubject AND owner_domain = :callerDomain`
  (owner **and** domain — both walls). A device the caller does not own in their
  own domain returns **404**, never 403, so the surface cannot be used to
  enumerate other owners' devices, and a cross-owner lock matches **zero rows**
  (never a lock).
- **`fleet_entitlement` (the enterprise-subscription seam).** A thin
  per-subject table (`active` / `seats` / `expires_at`). Every fleet-owner
  endpoint additionally requires `FleetEntitlementService.isEntitled(subject)` —
  a row that **exists AND is `active` AND is unexpired** — and **fails closed**
  (no row → not entitled → **403 "fleet entitlement required"**). SUPERADMIN is
  exempt. This is deliberately *thin*: it gates access, it is not a billing
  system.

**The PUBLIC-fe-gateway caveat.** Unlike the superadmin lockout plane (tailnet-
only, network-isolated), the fleet surface is reachable on the **public**
`hugmesh-fe-gateway` at `/bff/admin/phone-fleet/**`. There is therefore **no
tailnet defence-in-depth** in front of it: the **owner + domain predicate is the
SOLE tenancy wall**, so both legs of it are load-bearing and every path
fails closed. The gateway route-access seed carries a dedicated
`/bff/admin/phone-fleet/** → ROLE_FLEET_ADMIN` allow row (plus `ROLE_ADMIN` /
`ROLE_SUPERADMIN` as supersets) — a coarse gate ahead of the app-layer wall —
because the generic `/bff/admin/** → ROLE_ADMIN` floor would otherwise
default-deny a pure fleet owner (longest-pattern-wins).

**How a SUPERADMIN provisions a fleet** (one-time, per fleet owner):

1. **Assign the owner** on each handed-over device —
   `PUT /bff/superadmin/phone-devices/<id>/owner {"physicalOwner":"<subject>","ownerDomain":"<domain>"}`
   (SUPERADMIN + step-up). This sets the two authoritative columns.
2. **Grant the capability** — grant `ROLE_FLEET_ADMIN` to that subject.
3. **Grant the entitlement** —
   `PUT /bff/superadmin/fleet-entitlements/<subject> {"active":true,"seats":<n>,"expiresAt":"<ts?>"}`.

From then on the owner sees and locks/unlocks **only** their own in-domain
phones on the public Phone-fleet page; they **cannot** mark-managed, set an
owner, or grant entitlements — those stay SUPERADMIN-only provisioning acts.

**Step-up for fleet lock/unlock — requires MFA enabled.** The two mutations
(`.../lock`, `.../unlock`) are step-up-gated exactly like the superadmin plane, but
a fleet owner satisfies step-up **only via the Casdoor-MFA leg** — a fresh MFA
re-confirmation on their session. They **cannot** use the workload-token leg: the
only mint endpoints (`/bff/admin/desktop/step-up`, `/bff/superadmin/workload/step-up`)
are `ADMIN`/`SUPERADMIN` and require an operator SSH license a fleet customer never
holds. So fleet lock/unlock is reachable **only where `app.casdoor.mfa.enabled=true`**;
with MFA dark, a fleet owner's lock/unlock fails closed with a **403** (their list/get
still work). This is intentional — a fleet customer re-confirms a device lock with MFA,
not with an operator credential — so **enable MFA before handing a fleet owner
lock/unlock**.

## MDM providers

Device management is a **pluggable provider registry**, not a single hard-coded
backend. Two providers ship, both **primary and first-class** — the driver
validates `--mdm-provider` against the registry
([`specs/usr/lib/hugmesh/mdm-providers.sh`](../specs/usr/lib/hugmesh/mdm-providers.sh),
mirroring the go-live wizard's `go-live-providers.sh`) and branches on each
provider's *mechanism*, never on its id:

| | **`headwind`** (DEFAULT) | **`azure-intune`** (opt-in) |
| --- | --- | --- |
| Control plane | **Self-hosted** Headwind MDM (your cluster) | **Microsoft Graph / Intune** (SaaS) |
| Sovereignty | 🟢 **Sovereign** — no external control plane | 🔴 **Cloud** — third-party SaaS dependency |
| Mechanism | `dpc-adb` — DPC promoted to device-owner over adb (`dpm set-device-owner`) | `os-enrollment` — Entra registration + Company Portal / provisioning package (**OS-level, not adb**) |
| Enroll driver step | Installs + configures the DPC over adb | Prints a **runbook**; records the Graph `managedDevice` id |
| Remote lock | Mesh-owned DPC enforces on-device | `POST …/deviceManagement/managedDevices/{id}/remoteLock` |
| Secret custody | none needed device-side | client-credentials secret lives **only** in the cluster (Vault → ExternalSecret → admin-bff), never the wizard/argv |

**The DEFAULT is always the sovereign provider.** `--mdm-provider` defaults to
`headwind`; selecting `azure-intune` is an explicit per-deployment opt-in that
**forfeits sovereignty for that fleet** (a hard Microsoft SaaS dependency for
management traffic). Sovereignty is preserved by default and only ever
relinquished on a deliberate operator choice.

> **Not the Entra login app.** The Intune provider is device-management only. Its
> Azure app registration is a **confidential client-credentials Graph app**
> (Microsoft Graph `.default` scope,
> `DeviceManagementManagedDevices.PrivilegedOperations.All` for `remoteLock`) —
> **disjoint** from any Entra *OIDC login* app the platform's cloud-deploy /
> identity work may register. Different app registration, different secret, no
> shared config key.

### `azure-intune` — enrollment (OS-level, `os-enrollment` mechanism)

Intune enrollment happens **in the OS**, not over adb — `dpm set-device-owner`
is a Headwind-only, sovereign mechanism and is **not used** for Intune. So
`mdm-enroll --mdm-provider azure-intune` drives nothing over adb; it prints the
registry's enrollment runbook and records the resulting Graph device id:

1. Register the device with **Entra ID** (Microsoft Entra device registration)
   under the target tenant.
2. Install the **Intune Company Portal** app, sign in with the enrolling Entra
   account, complete the Company-Portal flow (or apply your Android Enterprise
   **provisioning package**).
3. The device appears as a **`managedDevice`** in the Intune admin center.
4. Pass `--intune-device-id <managedDevice-id>` (obtain it from the admin center
   device blade, or via Graph `GET …/deviceManagement/managedDevices`). The
   wizard records it into `mdm.json` / `ingest.json` (device-reported); the
   admin-bff `AzureIntuneLockClient` targets it on lock.

### `azure-intune` — remote lock (Graph `remoteLock`)

The lock leg is **server-side only** (admin-bff `AzureIntuneLockClient`) — the
wizard never holds the Graph secret. On lock it mints a **client-credentials**
token and calls the Intune `remoteLock` action:

```
token:  POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
        scope = https://graph.microsoft.com/.default
lock:   POST https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{id}/remoteLock
```

The mesh-deny leg (headscale cut) fires **regardless of provider** — it is a
platform-side action independent of the DPC backend, so a locked device is cut
from the mesh whether it is Headwind- or Intune-managed.

### The unlock **asymmetry** (Intune)

Intune has **no native force-unlock**. A `remoteLock` is *user-unlockable
device-side* with the existing passcode — the handset owner can simply unlock
it. So the platform "unlock" action for an Intune device:

- **clears the control-plane lock record** (and lifts the provider-independent
  mesh-deny cut / can re-enable the device), and
- **does NOT push a credential or force-unlock the handset** — there is no Graph
  primitive that does so.

This is deliberately different from a self-hosted DPC, where the mesh-owned
controller has fuller on-device authority. The admin-ui surfaces this as a note
on the Lock/Unlock action for Intune devices. The control-plane lock **state**
is authoritative regardless of provider: an unknown or spoofed device-reported
provider only *degrades enforcement* (the matching DPC leg is skipped), it never
blocks the lock record or the mesh-deny cut.

### Client-credentials app-registration setup (Intune)

One confidential Graph app registration per Entra tenant:

1. **Entra admin center → App registrations → New registration** (single tenant).
2. **Certificates & secrets → New client secret** — copy the value once.
3. **API permissions → Microsoft Graph → Application permissions →**
   `DeviceManagementManagedDevices.PrivilegedOperations.All` (for `remoteLock`);
   **Grant admin consent**.
4. Seed Vault (never argv, never a manifest literal):
   ```
   vault kv put secret/hugmesh/azure-intune \
     TENANT_ID=<tenant-guid> CLIENT_ID=<app-guid> CLIENT_SECRET=<client-secret>
   ```
5. Opt in: uncomment `azure-intune-externalsecrets.yaml` in the external-secrets
   `kustomization.yaml` **and** set `app.phone-lock.azure-intune.enabled=true` on
   admin-bff. Until both are done the leg is dark
   (`NoopAzureIntuneLockClient`), and the default (Headwind, sovereign) posture
   stands.

The credential materializes via
[`specs/cluster/manifests/external-secrets/azure-intune-externalsecrets.yaml`](../specs/cluster/manifests/external-secrets/azure-intune-externalsecrets.yaml)
into the admin-bff env (`APP_PHONELOCK_AZUREINTUNE_*`, Spring relaxed binding) —
blank-safe (renders empty until the Vault path is populated), default-off, and
labelled with the sovereignty-forfeiture caveat.

## Management plane

**Now real, not a roadmap paragraph.** The device-management plane for
**both** stock-Android and GrapheneOS phones is two independent, self-hosted,
default-off cluster optional-services — **Headwind MDM**
([github.com/h-mdm](https://github.com/h-mdm), Apache-2.0,
`specs/cluster/apps/23-headwind.yaml`) and the **GrapheneOS
AttestationServer** (MIT, forked, `specs/cluster/apps/24-attestation-server.yaml`)
— both merged to `main` as cluster manifests (namespace `hugmesh-pki`,
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

### `attest` — AttestationServer pairing via the HugMesh-forked Auditor

`attest` installs our own fork of GrapheneOS's Auditor app — package
`systems.hugmesh.auditor` (deliberately different from the stock
`app.attestation.auditor`, so a pin is unambiguous and a stock install is
never clobbered) — signer-pinned via `--auditor-signer-sha256`, using the same
shared apksigner-verify helper `mdm-enroll` and `enroll` use. It then prints a
runbook pointing the operator at the self-hosted AttestationServer console
(`--attestation-url`, e.g. `https://attestation.hugmesh.net`) to scan
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
server AUDITOR_SIGNER_DIGEST  ===  HugMesh Auditor fork's release-signing-cert SHA-256
server ATTESTATION_DOMAIN     ===  fork's DOMAIN constant  ===  attestation.hugmesh.net
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
| `phone-ingest/v2` registry record (attestation + mdm folds) + mTLS POST | `ingest` | 🚧 |
| Offline `plan` dry-run + `REDACTED` secret discipline | `plan` / `--print-plan` | 🚧 |
| `make phone-*` thin face (host-side delegates; secrets stay file-path knobs) — all 13 verbs incl. `phone-mdm-enroll`/`phone-attest` | `Makefile` | 🚧 |
| Thin ncurses-menu face over the driver (all 13 verbs + MDM/attestation knob sub-screen, non-build precedent) | `phone_screen` in [`scripts/build-menu.sh`](../scripts/build-menu.sh) | ✅ |
| Thin Studio (GUI) face over the driver (phone + quest side-flows off the ModePage; streamed verbs off-thread, TTY verbs handed to a terminal) | `PhonePage` / `QuestPage` in `studio/hugmesh_studio/gui/pages/` | ✅ |
| Quest device class (`--device-class quest`): class-scoped catalog, oculus/Meta identity pin, 4-verb chain, unsupported verbs fail-closed w/ rationale | [`scripts/quest-devices.tsv`](../scripts/quest-devices.tsv) + `require_class_supports` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#450) |
| Quest XR-chat URL provisioning (`--headwind-config` app-push lever + `--xr-chat-url` https-only, mdm.json record, VIEW-intent verify) | `cmd_mdm_enroll()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#450) |
| `make quest-*` thin face (7 quest verbs; `HEADWIND_CONFIG=`/`XR_CHAT_URL=` knobs) | `Makefile` | ✅ merged (#450) |
| Thin ncurses quest face (`quest_screen`: quest verbs only, Headwind sub-screen, XR-chat knob) | `quest_screen` in [`scripts/build-menu.sh`](../scripts/build-menu.sh) | ✅ |
| Quest mocked-adb e2e (real command-sequence assertions incl. unauthorized-headset, no-dev-mode, wrong-vendor, unsupported-verb paths) | [`tests/phone/e2e-quest-join.sh`](../tests/phone/e2e-quest-join.sh) | ✅ merged (#450) |
| APK store (general fleet app push/update/delete beyond the wizard's own vetted, signer-pinned sideloads) | — | 🔭 (deliberate v1 non-goal; Headwind's own console can do this directly, see [Remote-management model](#remote-management-model)) |
| Existing-device onboarding (GrapheneOS + stock Android, USB-guided or `--no-usb`, no reflash) | `enroll` | 🚧 |
| Headwind MDM cluster optional-service (Postgres-backed, tailnet-only, `hugmesh-pki` namespace) | `specs/cluster/apps/23-headwind.yaml`, `specs/cluster/manifests/headwind/` | ✅ merged |
| GrapheneOS AttestationServer cluster optional-service (SQLite PVC, tailnet-only, forked Auditor identity baked in) | `specs/cluster/apps/24-attestation-server.yaml`, `specs/cluster/manifests/attestation-server/` | ✅ merged |
| `mdm-enroll` verb — Headwind device-owner enrollment, fresh-device precondition (now checks accounts too, not just users — #393), signer-pinned DPC APK, `init.json` `BASE_URL` injection | `cmd_mdm_enroll()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390, hardened #393) |
| `attest` verb — HugMesh-forked Auditor pairing to the self-hosted AttestationServer, operator-attested verdict | `cmd_attest()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390) |
| 8-step wizard order (`attest`/`mdm-enroll` immediately post-flash, before `profile`) | `cmd_wizard()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390) |
| Auditor-fork ↔ AttestationServer signer-digest coupling (`AUDITOR_SIGNER_DIGEST`) | [Management plane](#management-plane) | ✅ server-side patch merged; digest itself is set at Auditor-fork release-signing time (operator step, outside this repo) |
| OTA/update posture management (GrapheneOS updates itself; Headwind CE ships no OTA lever) | — | 🔭 |

## Deferred

Tracked here per the driver's header. Still 🔭, by design. The earlier
**"any on-phone agent (MDM, resident daemon, APK store)"** entry is
**superseded and removed from this list** — Headwind's device-owner DPC is
now delivered (see [Management plane](#management-plane)); only the
APK-store half of that non-goal still stands (see the Summary table).

- ~~**Thin Studio (GUI) face**~~ — **delivered** (see the Summary table): the
  `make phone-*`/`quest-*` faces, the ncurses `phone_screen`/`quest_screen`
  and the Studio `PhonePage`/`QuestPage` are all thin faces over the one
  driver (driver owns all logic; no build-matrix row), with the
  `HEADWIND_*`/`AUDITOR_*`/`ATTESTATION_URL`/`INTERNAL_TOKEN_FILE` knobs
  forwarded file-path-only per the custody pattern.
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
