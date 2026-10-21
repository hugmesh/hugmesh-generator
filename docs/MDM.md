# Mobile Device Management (MDM) — GrapheneOS + existing-device phone onboarding (the fourth onboarding form)

> **Status: ✅ shipped on `main`.** The flash/enroll/profile/ingest driver, the
> existing-device onboarding path, **Headwind MDM**, the **GrapheneOS
> AttestationServer** and the `attest`/`mdm-enroll` verbs that drive them from
> this wizard are all merged (#376/#381/#383/#386/#390, hardened by the
> 9-defect pre-deploy-gap pass in #393). One driver,
> [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh), owns the whole flow.
> **Headwind MDM** and the **GrapheneOS AttestationServer** are merged,
> default-off cluster optional-services (see
> [Management plane](#management-plane)). Real pre-deploy gaps remain; see
> [Deferred](#deferred). Nothing in this doc waits on an unmerged branch.

_State key: **✅ shipped** (on `main`) · **🚧 in-flight** · **🔭 planned / deferred**._

This is the **fourth onboarding form**, beside the appliance images
([`BUILD-MATRIX.md`](BUILD-MATRIX.md)), the client desktops
([`CLIENT-IMAGES.md`](CLIENT-IMAGES.md)) and the FD-09 Local Docker mesh node
([`clients/docker-mesh-node/`](../clients/docker-mesh-node)). The platform takes
a **USB-connected Google Pixel** and turns it into an MDM-managed mesh device, end
to end:

```
detect ─► fetch (VERIFIED GrapheneOS -install- zip) ─► flash ─► attest
(self-hosted AttestationServer pairing, via a HugMesh-forked Auditor app)
─► mdm-enroll (Headwind MDM device-owner enrollment — MUST run before
'profile', which permanently forecloses device-owner mode) ─► enroll
(headscale tailnet join, register-and-approve) ─► profile (separately-encrypted
GrapheneOS secondary user, credential escrowed into vault-seed custody)
─► ingest (device registry)
```

`enroll` also stands alone as a **first-class existing-device onboarding path**.
It takes a phone this wizard never flashed, GrapheneOS *or stock Android*,
USB-guided or (`--no-usb`) with no adb at all. See
[Onboarding existing phones (no reflash)](#onboarding-existing-phones-no-reflash).
`flash` stays GrapheneOS/Pixel-only. `attest` and `mdm-enroll` are also
adb-based and work on freshly flashed **and** already-running phones. Device-owner
enrollment is a one-shot, fresh-device-only operation; see
[Management plane](#management-plane) for the ordering rule behind that.

The phone follows the repo's documented **non-build precedent** (see the
Local-Docker-mesh paragraph in [`BUILD-MATRIX.md`](BUILD-MATRIX.md)). It is **NOT
a build-matrix cell, NOT a platform, NOT a WorklistEntry**. Nothing is compiled
or imaged. As with the Local Docker mesh and the go-live wizard triad
([`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md)), the driver owns ALL the logic and the
faces stay thin:

- `make phone-*` targets (✅ shipped): host-side pass-through delegates in the
  Makefile. They never run inside the builder container, because the driver
  needs the host USB bus and a real TTY for its destructive gates. All 13 verbs
  have targets, including `phone-mdm-enroll` and `phone-attest`.
- The ncurses-menu face (✅ shipped): `phone_screen` in `scripts/build-menu.sh`
  wraps all 13 verbs. An MDM/attestation sub-screen passes the
  Headwind/Auditor/ingest-token knobs as file paths only.
- The Studio face (✅ shipped): `PhonePage` and `QuestPage` in
  `studio/hugmesh_studio/gui/pages/`.

## Verbs (the real surface)

`scripts/phone-wizard.sh <verb> [options]`. The **default posture is
dry-run/read-only**. Only `fetch`, `flash`, `attest`, `mdm-enroll`, `enroll`,
`profile`, `rotate-profile-pass`, `remove-profile` and `ingest` change anything,
and the destructive ones are gated. The table below is the **phone** (default)
device class. `--device-class quest` narrows it to a 4-verb chain; see
[Quest headsets](#quest-headsets-meta-quest-33s----device-class-quest).

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
always compared against what is actually detected) · `--device-class
phone|quest` (default `phone`; see [Quest headsets](#quest-headsets-meta-quest-33s----device-class-quest)) ·
`--codename C` (see [`scripts/phone-devices.tsv`](../scripts/phone-devices.tsv),
or [`scripts/quest-devices.tsv`](../scripts/quest-devices.tsv) with
`--device-class quest`) · `--channel stable|beta|alpha` (default `stable`) ·
`--graphene-version V` (pin an exact release, skips channel resolution) ·
`--work-dir D` (artifact dir, default `out/phone-wizard`) · `--out D` (output
tree: enrollment/profile/ingest records + vault-seed escrow; default
`out/phone-wizard/keys-out`). The default is deliberately its own namespace
under `--work-dir`'s tree. The repo-root `keys-out/` is no substitute:
[`gen-provision-keys.sh`](../scripts/gen-provision-keys.sh) treats that as its
own disposable scratch space and `rm -rf`s it unconditionally.

Mesh + identity: `--keys-dir D` (docker-mesh-node layout; see
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
`--mdm-provider headwind|azure-intune` (default `headwind`; see
[MDM providers](#mdm-providers)) · `--intune-device-id ID` (Intune only: the
Graph `managedDevice` id the lock leg targets) · `--headwind-apk F` (Headwind DPC
APK to adb-install during `mdm-enroll`) · `--headwind-signer-sha256 H` (pin the
Headwind APK signer cert SHA-256; fail-closed when set) · `--headwind-url URL`
(Headwind server base URL, written into the DPC's non-interactive `init.json` as
`com.hmdm.BASE_URL`; env `HMDM_URL`) · `--auditor-apk F` (HugMesh-forked Auditor
APK to adb-install during `attest`) · `--auditor-signer-sha256 H` (pin the
Auditor fork's release-cert SHA-256; fail-closed when set) · `--attestation-url
URL` (self-hosted AttestationServer console URL, printed in the `attest` pairing
runbook; env `ATTEST_URL`).

Quest-only extras (see [Quest headsets](#quest-headsets-meta-quest-33s----device-class-quest) and
[Thin desktop](#thin-desktop-quest--thin-client-node-tailnet-only----thin-desktop)):
`--headwind-config NAME` (the Headwind CONFIGURATION the headset joins; written as
`com.hmdm.CONFIG`) · `--xr-chat-url URL` (https only; env `XR_CHAT_URL`) ·
`--thin-desktop` · `--moonlight-apk F` · `--moonlight-signer-sha256 H` ·
`--thin-desktop-hosts L` (env `THIN_DESKTOP_HOSTS`).

Ingest: `--ingest-url URL` + `--client-cert F --client-key F --ca F` (mTLS client
identity; POST is refused without cert+key) · `--internal-token-file F` (the
BFF's `X-Internal-Token`, see [Ingest](#ingest--device-registry)).

Gates + overrides: `--yes` (non-interactive confirmation, per-verb gates) ·
`--force` (downgrade FOUR independent hard-requirement checks to warnings):
- the `enroll` OS-probe gate, only when the OS is genuinely undetectable
  (GrapheneOS and stock Android never need `--force`);
- `flash`'s fastboot-version preflight, when the `fastboot --version` string is
  unparsable (normally it enforces GrapheneOS's ≥35.0.2 requirement);
- `enroll`'s Tailscale-package-appear wait, which skips confirming that the app
  installed before the tailnet-join poll starts;
- `mdm-enroll`'s fresh-device precondition. This one is a one-shot and not
  really safe to force; see [Management plane](#management-plane).

Also: `--force-fwupd` (proceed even if fwupd is running) · `--show-authkey`
(display the pre-auth key ONCE during enroll; default: never displayed) ·
`--no-usb` (enroll only: skip every adb probe; see
[Onboarding existing phones](#onboarding-existing-phones-no-reflash)) ·
`--i-understand-adb-exposure` (set the profile credential over adb; see
[Secret custody](#secret-custody-model)) · `--resolve` (allow `plan` to resolve
the version over the network) · `--print-plan` (alias for the `plan` verb) ·
`--no-color`.

Env seams (tests override these; the defaults are the real thing): `PW_ADB`,
`PW_FASTBOOT`, `PW_RELEASES_URL`, `PW_ALLOWED_SIGNERS`, `PW_EXPECTED_SIGNER_FP`
(empty allowed ONLY with `PW_ALLOWED_SIGNERS` overridden), `PW_SKIP_FP_PIN=1`,
`PW_JOIN_TIMEOUT`, `PW_POLL_INTERVAL`, `PW_FASTBOOT_REAPPEAR_TIMEOUT`. Also
`HMDM_URL` / `ATTEST_URL` / `XR_CHAT_URL` / `THIN_DESKTOP_HOSTS` supply default
`--headwind-url` / `--attestation-url` / `--xr-chat-url` / `--thin-desktop-hosts`
values (an explicit flag always wins).

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

The driver rests on these externally verified facts. The pinned files record
their provenance (fetched **2026-07-15**), and the code enforces each one,
fail-closed.

- **sshsig is the ONLY current verification method.** The old signify
  `factory.pub` is GONE: `releases.grapheneos.org` answers HTTP 410 for it.
  GrapheneOS `-install-` zips carry detached OpenSSH sshsig signatures
  (`ssh-keygen -Y verify`), identity `contact@grapheneos.org`, namespace
  `factory images`, per the official CLI install procedure
  (`https://grapheneos.org/install/cli`). The pinned signers file is
  [`scripts/phone-allowed-signers`](../scripts/phone-allowed-signers).
- **Double fingerprint pin.** Before each verify, the driver checks the expected
  signer-key fingerprint `SHA256:AhgHif0mei+9aNyKLfMZBh2yptHdw/aN7Tlh/j2eFwM`
  against **every** key line in the signers file (`ssh-keygen -lf`).
  `-Y verify` accepts ANY listed key for the principal, so the check catches a
  *replaced* key AND an *appended* one. It is implemented as `dlv_verify_sshsig`
  in [`scripts/_download-lib.sh`](../scripts/_download-lib.sh). `ssh-keygen`
  ignores `#` comment lines in allowed_signers files (verified against OpenSSH
  10.3 for both `-Y verify` and `-lf`).
- **Tamper ⇒ exit 3, artifact DELETED.** A failed verify removes the zip, the
  `.sig` and any marker. A bad zip must never survive to be flashed later.
  `flash` also refuses any artifact without a byte-matching `.verified-<sha256>`
  marker, and re-verifies the signature.
- **fastboot ≥ 35.0.2 is a GrapheneOS hard requirement.** The driver preflights
  it; older android-tools exit 2. A running `fwupd` can seize the fastboot USB
  interface, so the driver preflights that too (`--force-fwupd` overrides).
- **Release metadata** is a one-line file at
  `https://releases.grapheneos.org/<codename>-<channel>`:
  `"<version> <unix-ts> <codename> <channel>"`. Channels are
  `stable|beta|alpha`; the version is an 8+-digit datestamp. The driver
  cross-checks the echoed codename and channel and refuses a mismatch.
- **Artifacts** are `<codename>-install-<version>.zip` (+`.sig`). They contain the
  official `flash-all.sh`. The driver runs it from inside the extracted dir with
  a local `TMPDIR` (space safety, per the official CLI instructions), bound to
  OUR device through `ANDROID_SERIAL`.
- **Device catalog, fail-closed.**
  [`scripts/phone-devices.tsv`](../scripts/phone-devices.tsv) pins the **21
  devices** GrapheneOS ships release channels for (Pixel 6 → Pixel 10a, as of
  2026-07-15). An unknown codename exits 4. There is deliberately **no
  `--allow-unknown` escape hatch in v1**: an unknown codename would fetch and
  flash an artifact nobody vetted for this fleet.
- **Bootloader lifecycle.** Unlocking WIPES the device (and needs "OEM unlocking"
  in Developer options). Re-locking wipes again and re-enables full verified
  boot. The driver walks the operator through both volume-key confirmations. If
  the operator declines the re-lock, the driver fails loudly (the device REMAINS
  UNLOCKED). It **never** runs `fastboot erase avb_custom_key`, which is the
  revert-to-stock path.
- **Secondary users are separately encrypted.** The enterprise profile is a
  GrapheneOS secondary user with its own file-based-encryption keys. Removing the
  user evicts those FBE keys, and the profile's data is gone. The generated
  credential is 6 dash-joined 6-char lowercase words from `/dev/urandom` (41
  chars, comfortably above the 28-char bar the custody model requires). It is
  lowercase-only so you can type it on the handset lockscreen keyboard.
- **Tailscale on Android** is package `com.tailscale.ipn`. The driver verifies a
  successful tailnet join by polling over adb for a CGNAT (`100.64/10`) address
  on the Tailscale `tun*` interface. Android's Tailscale app is a `VpnService`,
  so the kernel names its interface `tun0`/`tunN`, never `tailscale0`; that name
  exists only for desktop `tailscaled`. The probe scopes the CGNAT match to
  `tun*`, so a cellular carrier-NAT `100.64/10` address on an `rmnet*` interface
  is not mistaken for a join.

## The Tailscale root domain (what the phone joins)

The handset joins the brand's **Tailscale root domain**, quoted verbatim from
[`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md), which is the canonical definition:

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
value. It lands in `PLAN_SUPERDOMAIN`, the enrollment record and the ingest
record. A phone is a mesh *member*, never a go-live target, so the public apex
never applies to it.

## Enrollment — mesh join

`enroll` reuses the keys contract of the FD-09 Local-Docker mesh
([`clients/docker-mesh-node/keys.example`](../clients/docker-mesh-node/keys.example)).
Each file is optional on its own:

```
<keys-dir>/login-server        headscale control URL
<keys-dir>/tailscale/authkey   one-time pre-auth key (or <keys-dir>/authkey)
<keys-dir>/casdoor.json        { issuer, client_id, domain }
<keys-dir>/role                user|mod|admin|superadmin
```

The operator performs the join on the handset. The driver prints the runbook,
then **verifies** the result over adb:

1. In the Tailscale app, choose a custom coordination server and enter the
   resolved login server.
2. Authenticate with the one-time pre-auth key (SEC-08: single-use, 24 h expiry;
   mint a fresh one if it is stale), or through Casdoor OIDC with the
   `hugmesh/headscale` group, the same gate the superadmin's own client join uses
   (see [`SUPERADMIN-MESH-CLIENT.md`](SUPERADMIN-MESH-CLIENT.md)).
3. ADR-14 register-and-approve: the node registers as PENDING and joins only
   after a superadmin approves it in the superadmin UI. If the join check times
   out while approval is pending, re-run `enroll` once it is approved. It is
   idempotent up to the record write.

Optional APK custody: `--tailscale-apk` installs a vetted APK over adb, and
`--apk-signer-sha256` pins the signing cert of **what is actually installed**.
The driver pulls the on-device `base.apk` and checks it with `apksigner`,
fail-closed. It pins the installed artifact, not the file we happened to install.
On success the driver writes a non-secret `enrollment.json` under
`<out>/device/<device-id>/`.

## Onboarding existing phones (no reflash)

`enroll` does not assume the device came through this wizard's own `flash`. It is
a first-class path for **already-running** phones: existing GrapheneOS phones and
**stock Android** phones. `flash` stays GrapheneOS/Pixel-only, and nothing here
changes that.

### USB-guided (adb) — the default `enroll` above

The OS probe records what it finds, `os:"grapheneos"` or `os:"android"`, into
`enrollment.json` and, downstream, `ingest.json`. It needs **both** the
`ro.build.version.incremental` datestamp AND a `grapheneos` getprop marker, not
either alone, so a non-GrapheneOS ROM with a datestamp-shaped incremental cannot
be misclassified. Otherwise it falls back to `ro.build.version.release`. It
**never gates** on which OS it finds: stock Android is a supported OS for enroll,
not a `--force`-guarded fallback. `--force` is only for the case where the probe
genuinely cannot tell (no GrapheneOS signal **and** no readable release
property). That case alone is recorded as `os:"unknown"`, and it refuses without
`--force`.

**This is a best-effort, SPOOFABLE heuristic, not a security boundary.** Every
signal it reads (`ro.build.version.incremental`, the `grapheneos` getprop string,
`ro.build.version.release`) is a build- or OEM-controlled property, and a
tampered or custom ROM can set it to anything. `enroll`'s OS probe cannot
cryptographically attest what OS is running. That is the job of the self-hosted
[AttestationServer trust root](#management-plane) (`attest`, hardware-backed,
both classes). It is now wired up, but it is a **separate verb that produces a
separate, parallel record** (`attestation.json`, advisory and logged per D9, and
in v1 only an *operator-attested* pairing, not a pass the wizard verified
cryptographically; see [Management plane](#management-plane)). It does not
upgrade `enroll`'s own `os` field. Consumers of `enrollment.json` / `ingest.json`
must still not treat `os` as a verified fact. That is also why the verification
tier is named `adb-heuristic`, not `adb-verified` (see the table below).

### `--no-usb` — no adb at all

`enroll --no-usb` drops the adb dependency for hosts that have no USB/adb access
to the handset, or for an operator who would rather not tether it. It prints a
guided, handset-only runbook: install Tailscale, point it at the custom
coordination server, authenticate with the pre-auth key (the key is still
**never** echoed without `--show-authkey`). Then it writes an `enrollment.json`
marked `verification:"operator-attested"` with `tailscale_ip:null`, because the
wizard ran no adb probe to confirm the join. It needs `--device-id` **and**
`--codename`: with no adb probe there is no serial to derive the id from and no
way to read the device model, and an empty codename would strand the follow-up
`ingest`. It exits 0 with a **NEXT STEPS** block that tells the operator how to
verify the join **mesh-side**: approve the PENDING node (ADR-14) in the
superadmin UI, then confirm a `100.64/10` tailnet address there or with
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
(`panther`)** as another MDM-managed Android device on the mesh. It does so
**as-is, on Horizon OS**; this wizard never reflashes a headset. The class
changes three things and nothing else: the codename **catalog**, the **verb
subset** and a fail-closed **identity pin**. Every custody rule above (masked
auth key, 0600 `--authkey-file`, dry-run-by-default `plan`) applies unchanged.

- **Class-scoped catalog.** Quest codenames resolve against
  [`scripts/quest-devices.tsv`](../scripts/quest-devices.tsv). Anything else exits
  4, as in the phone catalog. The split matters: **`panther` is BOTH the Pixel 7
  (phone catalog) and the Quest 3S (quest catalog)**. The class decides which
  catalog a codename means, and detection pins the rest.
  `ro.product.manufacturer` must be `oculus`/`Meta` (USB vendor id `2833`), or
  the quest path refuses the device outright. It also refuses a device in
  fastboot state, because that is a handset bootloader, not a Quest.
- **The quest verb chain is `detect → mdm-enroll → enroll → ingest`.** `wizard`
  guides exactly those four, and `plan` previews them:
  - `detect` needs **Developer Mode ON** (a Meta developer account, enabled
    per headset in the Meta Horizon phone app). When the headset is not
    adb-visible, the driver prints the full Developer-Mode and udev (vendor
    `2833`) runbook instead of a bare failure.
  - `mdm-enroll` does the same Headwind device-owner enrollment (signer-pinned
    DPC APK, `init.json` `com.hmdm.BASE_URL` + `com.hmdm.CONFIG`), with the
    phone's fresh-device gates downgraded to **advisories**. Horizon OS setup
    requires a Meta account, so `dpm set-device-owner` is the real arbiter, and
    its refusal (with the hint) is the gate. `--headwind-config` is the app-push
    lever. `--xr-chat-url` (https only, because WebXR needs a secure context)
    records the XR-chat entry URL in `mdm.json`, prints the Headwind
    web-page-app console runbook and fires a `VIEW` intent, so the operator can
    confirm the room loads in the headset browser.
  - `enroll` does the same tailnet join, with a **sideload runbook** for the
    Tailscale APK (a managed headset has no Play or Horizon-store carry) and the
    **same `tun0` 100.64/10 join verification** as phones. The default device id
    is `quest-<sanitized serial>`.
  - `ingest` writes the `phone-ingest/v2` record with `device_class:"quest"`,
    plus a warning about the registry gap until the registry grows the field.
- **Unsupported, fail-closed with a stated reason (exit 2):**
  - `fetch`/`flash`: GrapheneOS artifacts are Pixel-only, and Horizon OS cannot
    be reflashed.
  - `attest`: the Auditor/AttestationServer trust root needs GrapheneOS-class
    hardware-attestation profiles, and **no attestation tier exists for Quest**.
  - the `profile` verbs: Horizon OS's user model is bound to a Meta account, so
    there is no separately encrypted GrapheneOS-style secondary user to escrow.
  - `--mdm-provider azure-intune`: Horizon OS has no Intune/Company-Portal
    support. A Quest is managed only through the `dpc-adb` provider (Headwind).

**All four faces** drive the one driver:
- CLI: `make quest-plan` / `quest-detect` / `quest-mdm-enroll` / `quest-enroll` /
  `quest-ingest` / `quest-status` / `quest-wizard`, with `HEADWIND_CONFIG=` and
  `XR_CHAT_URL=` knobs;
- ncurses: `quest_screen` under the "MDM Quest headset" opening choice (quest
  verbs only, a Headwind sub-screen, an XR-chat URL knob);
- Studio GUI: `QuestPage`, the ModePage "MDM Quest headset" side-flow (streamed
  verbs run off-thread; the guided `wizard` is handed to a terminal);
- raw: `scripts/phone-wizard.sh <verb> --device-class quest`.

For a live headset smoke test, run `make quest-plan CODENAME=eureka` (an offline
dry-run), then `make quest-detect` with the Quest attached over USB.

## Thin desktop (Quest ⇄ thin-client node, tailnet-only) — `--thin-desktop`

An **opt-in** capability pair (§8b of the XR-chat design; see
[`docs/XR-CHAT.md`](XR-CHAT.md)). A mesh-enrolled Quest opens a usable **virtual
desktop of one of the mesh's thin-client x86 desktop nodes** over the tailnet,
never off-mesh. The transport is **Sunshine** (self-hosted stream host, GPLv3) on
the node and **Moonlight** (`com.limelight`) on the headset. Pairing and streaming
use tailnet IPs and MagicDNS names only.

### Quest side — `--thin-desktop` on `mdm-enroll` (quest class only)

`mdm-enroll --thin-desktop` provisions the headset as the Moonlight terminal. It
uses the SAME two-leg pattern as the XR-chat URL provisioning above:

- **Immediate (this wizard).** Sideload the Moonlight APK with the same
  operator-custody and signer-pin path as every APK this wizard trusts:
  `--moonlight-apk <file>` + `--moonlight-signer-sha256 <hex>` (fail-closed
  apksigner verify of the on-device APK; exit 3 on mismatch). Then push the
  **managed host list** (`--thin-desktop-hosts frite,box2.hugmesh.internal`, env
  `THIN_DESKTOP_HOSTS`; lowercase tailnet DNS names, charset fenced fail-closed)
  as `hugmesh-thin-desktop-hosts.json` into Moonlight's external files dir, with
  the exact mechanics of the `init.json` push. **Honesty note:** Moonlight does
  not import that file by itself (moonlight-android has no managed-config
  surface). The file is the on-device custody record and the Headwind push
  target. The operator adds each host in Moonlight by its tailnet name.
- **Durable (Headwind, app-push).** Follow the printed console runbook. Upload
  the same Moonlight APK as an application in the device's CONFIGURATION
  (`--headwind-config`, the app-push lever) and add the host-list file to that
  configuration's **Files**. Every headset on the configuration then converges
  without adb.
- **Pairing (operator, per node).** Moonlight on the headset adds the node by
  tailnet name and shows a **PIN**. The operator enters it in the Sunshine web UI
  at `https://localhost:47990` **on that node's console** (or through an SSH
  tunnel). The pairing UI is loopback-only by design and never reachable from
  the mesh.

Gates (all fail-closed, before any adb call): `--thin-desktop` is **quest-class
only** (exit 2 with a reason on phones; v1 has no phone-class thin-desktop
terminal). The Moonlight and host knobs **require** the toggle (exit 1). A bad
host charset exits 1. `mdm.json` records `thin_desktop` and `thin_desktop_hosts`
uniformly (`false`/`[]` when off), so a run without the toggle sends byte-identical
adb traffic to what it sent before the feature existed. Faces: CLI `make
quest-mdm-enroll THIN_DESKTOP=1 MOONLIGHT_APK=… MOONLIGHT_SIGNER_SHA256=…
THIN_DESKTOP_HOSTS=…`; ncurses `quest_screen` → "Thin desktop" sub-screen; Studio
`QuestPage` → "Thin desktop" toggle group. E2E:
`tests/phone/e2e-quest-thin-desktop.sh` (mocked adb: ordered sequence, pushed-file
content and every failure path).

### Node side — `build-x86-host-stage4.sh --with-sunshine`

The generator bakes the stream host into **tailnet CLIENT desktop images**. It is
default-off, and the builder warns and drops it on cluster roles (no desktop
session to stream) and on tailnet-less desktops (standalone, unaffiliated,
`--skip-tailscale`). A composable `--standalone --with-tailscale` desktop stays
eligible.

- **Package** `games-util/sunshine` (own flag-gated package list and `~amd64`
  keyword file, the `--steam` pattern).
- **Mesh fence** `hugmesh-sunshine-firewall`, a member of the reconcile family:
  one script, one OpenRC oneshot ordered before `tailscaled`, one clearly scoped
  nftables table `hugmesh_thin_desktop`, and a 60s cron. Stream ports **TCP 47984,
  47989, 48010 + UDP 47998-48002** are admitted ONLY on `iifname tailscale0` AND
  `saddr 100.64.0.0/10` (both conditions, so a spoofed CGNAT source on the LAN
  interface stays dropped) and dropped everywhere else. The **web UI, TCP 47990,
  is loopback-only**. Sunshine has no native bind-to-interface option, so this
  netfilter fence IS the "bound to the tailscale iface only" guarantee. It fails
  closed: a render or apply error keeps the existing ruleset.
- **Session service** `/etc/xdg/autostart/hugmesh-sunshine.desktop` →
  `hugmesh-sunshine-session`. Sunshine must run *inside* the user's desktop
  session (display capture and uinput), and this fleet's desktop images use
  **OpenRC**. The XDG autostart wrapper is therefore the deliberate stand-in for
  the design's "systemd user service" (a documented divergence). It is idempotent
  per user, waits for `tailscale0`, and launches with the managed
  `/etc/hugmesh/thin-desktop/sunshine.conf` (`upnp off`,
  `origin_web_ui_allowed pc`, default port base).
- **Studio/menu parity:** the Studio RolePage "Client desktop options" tri-state
  (G34 `--with-sunshine`/`--no-sunshine`), the ncurses x86 options "Thin-desktop
  host" toggle, and flag-coverage + build-matrix `check.sh` probes.

### WiVRn — the sibling path (documented stub, not rolled out)

Moonlight streams the node's **2D desktop** into a flat panel in the headset.
**WiVRn** streams a **native OpenXR app** (the shadows-of-the-net PCVR build)
from the same node to the same headset as real room-scale VR. v1 ships a config
stub only: `/etc/hugmesh/thin-desktop/wivrn.toml.example`, baked by
`--with-sunshine`. It documents the mesh-honest defaults: TCP+UDP 9757 fenced to
the tailscale interface exactly like the Sunshine port set, tailnet pairing only.
The full rollout (package, fence extension, session unit) is tracked follow-up
work.

## Enterprise profile — escrowed credential custody

`profile` creates the `enterprise` secondary user (`pm create-user`), then
**escrows the passphrase FIRST**. Custody exists before anything else can fail:

```
<out>/vault-seed/device/<device-id>/enterprise-profile.pass   (dirs 0700, file 0600)
```

The file is destined for Vault at `secret/<brand>/device/<device-id>/phone-profile`
(the per-device vault-seed custody chain). By **default the operator sets the
credential on the handset** by reading the 0600 escrow file; the wizard never
prints it. Setting it over `adb shell locksettings set-password` puts the
passphrase **in adb argv, which is visible on BOTH exposure surfaces**. On the
phone, logcat and `ps` show it. On the operator's own host, the local `adb`
client process shows it in its argv (`ps auxww`, `/proc/<pid>/cmdline`, or any
execve/audit logging) for the life of that child process. That is a real risk on
a shared provisioning workstation, jump box or CI runner, which are exactly the
hosts this driver is designed to run on unattended. The path is a documented
residual exposure, and it needs the explicit `--i-understand-adb-exposure` gate.

Lifecycle: `rotate-profile-pass` rotates the escrow atomically (stage `.new`,
demote the current file to `.prev-<ts>`, promote) and re-runs the credential-set
flow. `remove-profile` removes the user (typed profile-name confirm, or `--yes`)
and retires the escrow to `.revoked-<ts>`. Revoke the Vault copy too.

## Secret-custody model

No secret ever travels on argv, in `plan` output, or to stdout or logs. `plan`
prints **`REDACTED` presence markers only** (`PLAN_AUTHKEY=REDACTED:present`,
`PLAN_PROFILE_PASS=REDACTED:generate`). The tailscale pre-auth key and the
enterprise-profile passphrase move through **0600 files only** (`--authkey-file`,
`--pass-file`, the vault-seed escrow dir). The pre-auth key never goes through
`adb shell` argv, and the wizard displays it only with an explicit
`--show-authkey` (once). `status` reports escrow **presence, never contents**.
The one deliberate exception is the gated adb credential-set path above.

## Ingest — device registry

`ingest` emits `<out>/device/<device-id>/ingest.json`, schema
**`phone-ingest/v2`**:
- identity: `device_id`, `device_class` (`"phone"`, or `"quest"` with
  `--device-class quest`), `serial`, `codename`, `marketing_name`;
- `os` (`grapheneos`|`android`|`unknown`, inherited from `enrollment.json`'s OS
  probe; see [Onboarding existing phones](#onboarding-existing-phones-no-reflash)),
  `os_version`;
- mesh: `superdomain`, `login_server`, `tailscale_ip`, `tailscale_hostname`,
  `role`, `attached_domain`;
- `enterprise_profile{present,user_id,credential_custody}`;
- attestation: `attestation_url`, `auditor_package`, `attestation_verdict`. They
  come from `attestation.json` when `attest` has run, and are empty strings
  otherwise. They are advisory fields only and, per D9, never block enrollment;
- MDM: `mdm_provider`, `intune_device_id`,
  `mdm{enrolled,provider,dpc_package,headwind_url,intune_device_id,set_via,enrolled_at}`.
  They come from `mdm.json` when `mdm-enroll` has run, and are `enrolled:false`
  with empty fields otherwise, mirroring `enterprise_profile`'s presence contract;
- `enrolled_at`, `generated_at`.

Recorded facts (enrollment and profile records) win. Live adb detection fills
only what is missing and reachable.

The `mdm{...}` object is what bumped the schema string from `v1` to `v2`. It
closed the tracked "mdm.json is not folded into ingest.json" gap.

**Cross-repo note:** the `v2` bump is additive. The BFF's `PhoneIngestRequest`
DTO pins the accepted schema string, and on `origin/main` it already accepts both
`phone-ingest/v1` and `phone-ingest/v2`
(`@Pattern(regexp = "phone-ingest/v1|phone-ingest/v2")`, `PhoneIngestRequest.java:45`).
v1 producers keep working (their `mdm` fields stay null). Only a registry older
than that change answers a `v2` POST with a `400` from Bean Validation. The
record is still written to disk, so nothing is lost. The same DTO accepts only
`device_class: phone` (`PhoneIngestRequest.java:56`), so a Quest record posted
there gets a `400` today (see [Quest headsets](#quest-headsets-meta-quest-33s----device-class-quest)).

The default is **emit-only**. The dedicated registry endpoint is
**`POST /bff/internal/device-registry/phone-ingest`** (hugmesh-admin-bff-api).
Point `--ingest-url` at it with the mTLS identity flags
(`--client-cert`/`--client-key`/`--ca`; the wizard fails closed without them).
Add `--internal-token-file F` when the deployment arms the BFF's app-layer
`X-Internal-Token` gate: an armed prod 401s the POST without it. The token rides
a 0600 `-H @file` header file, never curl's argv. The endpoint:
- accepts the `phone-ingest/v2` shape, and still the older `phone-ingest/v1`
  (snake_case; unknown additive keys ignored; a non-phone `schema` or
  `device_class` is a clean 400);
- UPSERTs one `phone_device` row per `device_id` (a re-ingest refreshes the
  telemetry and bumps `ingest_count`);
- rides the same mTLS-gated `/bff/internal/**` transport as the node self-report.

A superadmin reads the fleet at `GET /bff/superadmin/phone-devices` (+
`/{deviceId}`). Do **not** point `--ingest-url` at
`/bff/internal/device-enrollment/self-report`. That is a **different, disjoint
contract**: the node-side `machineKeyFp` self-report used for headscale
cluster-node reconciliation (`specs/usr/sbin/hugmesh-device-enrollment-report`).
Its handler requires `machineKeyFp`, so a `phone-ingest/v2` record posted there
fails Bean Validation and lands nowhere useful.

## Remote-management model

Remote management is the USB-tethered verbs above (now including `attest` and
`mdm-enroll`; see [Management plane](#management-plane)) plus the **mesh-side
controls** that were always there: headscale key expiry and node removal, and
Casdoor credential revocation.

The earlier v1 non-goal, "no MDM agent, no on-phone resident daemon", is
**superseded**. Headwind's DPC agent (`com.hmdm.launcher`) is now an on-phone
resident daemon by design. It runs in device-owner mode on every phone that has
run `mdm-enroll`.

One v1 non-goal still stands: **no first-party APK store**. `phone-wizard.sh`
sideloads only vetted, signer-pinned APKs: the Headwind DPC, the HugMesh Auditor
fork, the optional Tailscale APK and, on a Quest with `--thin-desktop`, the
Moonlight APK. General app push, update and delete across a fleet is a Headwind
CE console capability. An operator reaches it directly on the Headwind server;
this wizard does not drive it.

What losing a phone costs depends on its enrollment:
- A phone that never ran `mdm-enroll` costs only mesh membership and platform
  sessions.
- A phone **enrolled** as a Headwind device-owner can also be reached through the
  Headwind console for remote wipe, lock and policy. Once a superadmin has
  confirmed it as **managed**, the platform's own reversible, audited,
  step-up-gated **remote lockout** applies too (see
  [Roles & device management](#roles--device-management-managed-vs-byod-and-remote-lockout)).
- A BYOD phone whose owner never took device-owner of it is deliberately outside
  all of this. See [Management plane](#management-plane).

## Roles & device management (managed vs BYOD, and remote lockout)

A phone is a **device**, not a role-bearing user. The human holding it
authenticates to the platform as always: a Casdoor login with their normal role
(`user`/`mod`/`admin`/`superadmin`). That identity governs everything they do
through the gateways. The phone's own identity is a *device* identity: a
headscale/tailnet node plus, when enrolled, a Headwind DPC posture. So
`phone_device.role` is **inventory telemetry, never an authorization input**. A
phone can never give its holder access the holder did not already have. The
ingest channel (`/bff/internal/**`, mTLS, device-reported) is stated in the code
to "confer NO access". A guard test in `hugmesh-admin-bff-api` pins this
invariant against regression.

Two device classes exist, and only one can be managed remotely:

- **Mesh-owned (managed).** The mesh owner flashed or device-owner-enrolled the
  phone with **physical access** (`mdm-enroll`, USB, fresh-device-only). A
  superadmin can **remotely lock** such a phone.
- **BYOD.** A phone whose device-owner the mesh owner never took (plain `enroll`,
  including `--no-usb`). It gets normal registration, mesh membership and
  telemetry, but the owner has **no** management lever over it. A BYOD phone
  **can never be locked**; the lock endpoint refuses it with a clean 409.

**The trust boundary (why the distinction cannot be spoofed).** The phone's
self-reported device-owner facts (`mdm.enrolled` / `mdm.set_via`,
[phone-ingest/v2](#ingest--device-registry)) arrive over the same in-cluster mTLS
ingest that "confers no access". They are **trivially spoofable within the
cluster**, so the platform treats them only as an *advisory promotion hint*.
Lock-eligibility hangs off a separate, **authoritative** field,
`phone_device.management_mode` (`unmanaged` by default, or `mesh_owned`). Only
a SUPERADMIN can write it, through `/bff/superadmin/**`, and the ingest path never
can. This mirrors the node registry's `owner_type`, which the operator likewise
assigns at register time and the node never claims for itself. Concretely, after
`mdm-enroll` the wizard prints a NEXT STEP: a superadmin must **confirm** the
phone as managed in the fleet console
(`PUT /bff/superadmin/phone-devices/<id>/management {"mode":"mesh_owned"}`, or the
*Mark managed* action on the Phone-fleet page). That confirmation, a
superadmin-JWT-authenticated and step-up-gated action, is the authoritative act.
The device's self-report only surfaces the phone as *eligible to promote*.

**Remote lockout** is a reversible, audited control-plane action, modeled on the
node SSH-license revoke precedent (`device_ssh_license`). It is a CAS
`unlocked ↔ locked` state with a monotonic `lock_generation` and a
`lock_propagation_state` (`pending`/`applied`/`failed`/`degraded`). Rows are never
deleted; the state is its own audit trail. It is **SUPERADMIN-only and
step-up-gated** (`X-PhoneLock-StepUp`, mirroring SSH key issuance). The step-up
stands in for the physical-access assurance the provisioning side had.
Endpoints: `POST /bff/superadmin/phone-devices/<id>/lock` (409 unless
`management_mode = mesh_owned`), `.../unlock` and `.../management`. Gateway RBAC
needs no new row. The existing tailnet `hugmesh-superadmin-gateway` →
`/bff/superadmin/** → ROLE_SUPERADMIN` floor already governs them
(longest-pattern-wins), and the per-method `@PreAuthorize` is the fine gate.

Enforcement has **two flag-gated legs**. Both are best-effort, and the
control-plane lock state stays authoritative whatever they do:

1. **DPC lock via Headwind** (`app.phone-lock.headwind.enabled`, default off):
   commands the device-owner DPC to lock through Headwind's `/rest` surface.
2. **Mesh-access cut** (`app.phone-lock.mesh-deny.enabled`, default off): denies
   the locked phone's tailnet node at the headscale ACL layer (the same push
   mechanism the node SSH-license revoke uses). A locked phone loses platform and
   mesh reachability, not just its screen.

With both legs off (the default), a lock still records authoritative, audited
state and reports `propagation_state = degraded` with the reason "issue the lock
via the Headwind `/manage` console". The capability is useful the moment the
manifests are deployed, and it hardens as you enable the legs. **Honest infra
gaps:** real-time DPC push to phones over MQTT (`:31000`) is still the deferred
tailnet-topology work noted in `headwind.yaml`. The mesh-deny leg also needs the
headscale-ACL feature (`app.registry.headscale-acl.enabled`) and the phone→node
ACL identity. These gaps are why the legs ship default-off, not any incompleteness
in the control plane.

### Fleet owners & enterprise subscription

The lockout controls above are **SUPERADMIN-only**. They are reached over the
tailnet through `hugmesh-superadmin-gateway`, and the public `hugmesh-fe-gateway`
also carries a `/bff/superadmin/** → ROLE_SUPERADMIN` row
(`specs/cluster/manifests/route-access/initdb/20-schema.sql:982`).
The **fleet-owner** tier lets a *non-superadmin* enterprise customer manage the
subset of phones **they** own, locking and unlocking their own handsets, from the
**public** front-door gateway, without ever seeing anyone else's devices. Three
thin seams make that safe:

- **`ROLE_FLEET_ADMIN` capability.** A dedicated Casdoor role, a *sibling* of
  `admin`/`mod`: never a superset of `admin`, never auto-granted. It is the only
  non-superadmin role that reaches `/bff/admin/phone-fleet/**`. A SUPERADMIN
  grants it through the existing role-grant surface (it is listed in the
  admin-bff `GRANTABLE_ROLE_PATTERN`).
- **Owner-within-domain scoping (the tenancy wall).** Two operator-authoritative
  columns on `phone_device`: **`physical_owner`** (the Casdoor subject who owns
  the handset) and **`owner_domain`** (the brand/domain it belongs to). Like
  `management_mode`, only a SUPERADMIN can write them, through
  `/bff/superadmin/**`, and never the spoofable ingest path (the ingest
  INSERT/REFRESH column lists omit them, so a re-ingest can never set or
  overwrite them). Every fleet-owner read and mutation is predicated
  `WHERE physical_owner = :callerSubject AND owner_domain = :callerDomain`
  (owner **and** domain, both walls). A device the caller does not own in their
  own domain returns **404**, never 403, so the surface cannot enumerate other
  owners' devices. A cross-owner lock matches **zero rows**, so it never locks.
- **`fleet_entitlement` (the enterprise-subscription seam).** A thin per-subject
  table (`active` / `seats` / `expires_at`). Every fleet-owner endpoint also
  requires `FleetEntitlementService.isEntitled(subject)`: a row that **exists AND
  is `active` AND is unexpired**. It **fails closed** (no row → not entitled →
  **403 "fleet entitlement required"**). SUPERADMIN is exempt. The seam is
  deliberately *thin*. It gates access and is not a billing system.

**The PUBLIC-fe-gateway caveat.** Unlike the superadmin lockout plane, which has a
tailnet-only gateway in front of it, the fleet surface exists only on the
**public** `hugmesh-fe-gateway`, at `/bff/admin/phone-fleet/**`. There is no
**tailnet defence-in-depth** in front of it, so the **owner + domain predicate is
the SOLE tenancy wall**. Both legs of it are load-bearing, and every path fails
closed. The gateway route-access seed carries a dedicated
`/bff/admin/phone-fleet/** → ROLE_FLEET_ADMIN` allow row (plus `ROLE_ADMIN` and
`ROLE_SUPERADMIN` as supersets). It is a coarse gate ahead of the app-layer wall,
and it is needed because the generic `/bff/admin/** → ROLE_ADMIN` floor would
otherwise default-deny a pure fleet owner (longest-pattern-wins).

**How a SUPERADMIN provisions a fleet** (one-time, per fleet owner):

1. **Assign the owner** on each handed-over device:
   `PUT /bff/superadmin/phone-devices/<id>/owner {"physicalOwner":"<subject>","ownerDomain":"<domain>"}`
   (SUPERADMIN + step-up). This sets the two authoritative columns.
2. **Grant the capability.** Grant `ROLE_FLEET_ADMIN` to that subject.
3. **Grant the entitlement.**
   `PUT /bff/superadmin/fleet-entitlements/<subject> {"active":true,"seats":<n>,"expiresAt":"<ts?>"}`.

From then on the owner sees and locks or unlocks **only** their own in-domain
phones on the public Phone-fleet page. The owner **cannot** mark-managed, set an
owner or grant entitlements. Those stay SUPERADMIN-only provisioning acts.

**Step-up for fleet lock/unlock — requires MFA enabled.** The two mutations
(`.../lock`, `.../unlock`) are step-up-gated exactly like the superadmin plane.
A fleet owner can satisfy step-up **only through the Casdoor-MFA leg**: a fresh
MFA re-confirmation on their session. They **cannot** use the workload-token leg.
The only mint endpoints (`/bff/admin/desktop/step-up`,
`/bff/superadmin/workload/step-up`) are `ADMIN`/`SUPERADMIN` and need an operator
SSH license that a fleet customer never holds. So fleet lock/unlock works
**only where `app.casdoor.mfa.enabled=true`**. With MFA dark, a fleet owner's
lock/unlock fails closed with a **403**, while list and get still work. This is
intentional: a fleet customer re-confirms a device lock with MFA, not with an
operator credential. **Enable MFA before you hand a fleet owner lock/unlock.**

## MDM providers

Device management is a **pluggable provider registry**, not one hard-coded
backend. Two providers ship, both **primary and first-class**. The driver
validates `--mdm-provider` against the registry
([`specs/usr/lib/hugmesh/mdm-providers.sh`](../specs/usr/lib/hugmesh/mdm-providers.sh),
which mirrors the go-live wizard's `go-live-providers.sh`) and branches on each
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
`headwind`. Selecting `azure-intune` is an explicit per-deployment opt-in that
**forfeits sovereignty for that fleet**: management traffic then depends on
Microsoft SaaS. Sovereignty holds by default and goes away only on a deliberate
operator choice.

> **Not the Entra login app.** The Intune provider does device management only.
> Its Azure app registration is a **confidential client-credentials Graph app**
> (Microsoft Graph `.default` scope,
> `DeviceManagementManagedDevices.PrivilegedOperations.All` for `remoteLock`).
> It is **disjoint** from any Entra *OIDC login* app that the platform's
> cloud-deploy or identity work may register: a different app registration, a
> different secret and no shared config key.

### `azure-intune` — enrollment (OS-level, `os-enrollment` mechanism)

Intune enrollment happens **in the OS**, not over adb. `dpm set-device-owner` is
a Headwind-only, sovereign mechanism and Intune **does not use** it. So
`mdm-enroll --mdm-provider azure-intune` drives nothing over adb. It prints the
registry's enrollment runbook and records the resulting Graph device id:

1. Register the device with **Entra ID** (Microsoft Entra device registration)
   under the target tenant.
2. Install the **Intune Company Portal** app, sign in with the enrolling Entra
   account and finish the Company-Portal flow (or apply your Android Enterprise
   **provisioning package**).
3. The device appears as a **`managedDevice`** in the Intune admin center.
4. Pass `--intune-device-id <managedDevice-id>`. Get it from the admin center
   device blade, or from Graph `GET …/deviceManagement/managedDevices`. The
   wizard records it into `mdm.json` / `ingest.json` (device-reported), and the
   admin-bff `AzureIntuneLockClient` targets it on lock.

### `azure-intune` — remote lock (Graph `remoteLock`)

The lock leg is **server-side only** (admin-bff `AzureIntuneLockClient`). The
wizard never holds the Graph secret. On lock, the client mints a
**client-credentials** token and calls the Intune `remoteLock` action:

```
token:  POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
        scope = https://graph.microsoft.com/.default
lock:   POST https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{id}/remoteLock
```

The mesh-deny leg (the headscale cut) fires **whatever the provider**. It is a
platform-side action independent of the DPC backend, so a locked device is cut
from the mesh whether Headwind or Intune manages it.

### The unlock **asymmetry** (Intune)

Intune has **no native force-unlock**. A `remoteLock` is *user-unlockable
device-side* with the existing passcode, so the handset owner can simply unlock
it. The platform "unlock" action for an Intune device therefore:

- **clears the control-plane lock record** (and lifts the provider-independent
  mesh-deny cut, or can re-enable the device), and
- **does NOT push a credential or force-unlock the handset**, because no Graph
  primitive does that.

This deliberately differs from a self-hosted DPC, where the mesh-owned controller
has fuller on-device authority. The admin-ui shows a note on the Lock/Unlock
action for Intune devices. The control-plane lock **state** stays authoritative
whatever the provider. An unknown or spoofed device-reported provider only
*degrades enforcement* (the matching DPC leg is skipped). It never blocks the lock
record or the mesh-deny cut.

### Client-credentials app-registration setup (Intune)

One confidential Graph app registration per Entra tenant:

1. **Entra admin center → App registrations → New registration** (single tenant).
2. **Certificates & secrets → New client secret.** Copy the value once.
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
   admin-bff. Until you do both, the leg is dark (`NoopAzureIntuneLockClient`)
   and the default (Headwind, sovereign) posture stands.

The credential reaches the admin-bff env (`APP_PHONELOCK_AZUREINTUNE_*`, Spring
relaxed binding) through
[`specs/cluster/manifests/external-secrets/azure-intune-externalsecrets.yaml`](../specs/cluster/manifests/external-secrets/azure-intune-externalsecrets.yaml).
The manifest is blank-safe (it renders empty until the Vault path is populated),
default-off, and labelled with the sovereignty-forfeiture caveat.

## Management plane

**Now real, not a roadmap paragraph.** The device-management plane for **both**
stock-Android and GrapheneOS phones is two independent, self-hosted, default-off
cluster optional-services:

- **Headwind MDM** ([github.com/h-mdm](https://github.com/h-mdm), Apache-2.0,
  `specs/cluster/apps/23-headwind.yaml`);
- the **GrapheneOS AttestationServer** (MIT, forked,
  `specs/cluster/apps/24-attestation-server.yaml`).

Both are merged to `main` as cluster manifests (namespace `hugmesh-pki`,
tailnet-only, Harbor/superadmin devops posture, no public `*.CLUSTER_DOMAIN`
surface). The `attest` and `mdm-enroll` verbs of `scripts/phone-wizard.sh` are the
operator-facing glue that drives them from the handset side (merged via #390,
hardened by #393; see the status banner at the top). The design used and
considered no managed-Google-Play or Android-Enterprise-style plane routed
through a third-party SaaS vendor's backend, for either half. Both services are
sovereign, with no Google FCM, Pub/Sub or Play-Integrity dependency for management
traffic.

### Ordering: attest, then mdm-enroll, then profile — never reversed

Device-owner mode (`dpm set-device-owner`) is a **one-shot AOSP gate**. It
succeeds only while the target user has zero secondary users and zero added
accounts, and once foreclosed it is **permanent** for the life of the OS install,
with no undo short of a reflash. The wizard's 8-step order puts both
management-plane verbs right after `flash`, before anything that could add a user
or account:

```
1/8 detect  2/8 fetch  3/8 flash  4/8 attest  5/8 mdm-enroll  6/8 enroll  7/8 profile  8/8 ingest
```

- **`attest` runs first (4/8).** It needs no device-owner state, so it captures
  the hardware trust root on the cleanest possible device state.
- **`mdm-enroll` runs next (5/8)** and is the *last* point at which device-owner
  mode is obtainable. `cmd_mdm_enroll()` opens with a fail-closed precondition
  check: `adb shell pm list users` must show exactly one user AND `adb shell
  dumpsys account` must show zero accounts (`dpm set-device-owner` fails if
  either is violated, independently). Run out of order, it turns the cryptic AOSP
  `IllegalStateException` into a documented `exit 2` ("a secondary user/account
  already exists — device-owner mode is no longer obtainable; reflash to retry").
  `--force` downgrades this to a warning.
- **`profile` (7/8) is what permanently closes the window.** It creates the
  escrowed `enterprise` secondary user, so it must never run before `mdm-enroll`.
- **Already-enrolled and already-running phones** (see [Onboarding existing
  phones](#onboarding-existing-phones-no-reflash)) cannot gain device-owner mode
  later. That is an inherent AOSP constraint, not a wizard limitation. The honest
  flow for such a device is `attest` → `enroll` → `profile` → `ingest`. `mdm.json`
  is never written, and MDM enrollment needs a factory reset and a redo.

### `mdm-enroll` — Headwind device-owner enrollment

`mdm-enroll` installs the Headwind DPC APK (`--headwind-apk`, signer-pinned with
`--headwind-signer-sha256`). It uses the same `verify_installed_signer()`
apksigner helper that `enroll` uses for the Tailscale APK: it pulls the
currently installed `base.apk` and checks its apksigner cert digest, so it pins
what is actually on the device. Then it runs `dpm set-device-owner
com.hmdm.launcher/.AdminReceiver` over adb against a fresh device. Once
device-owner mode is set, the wizard pushes a non-interactive `init.json`
(`{"com.hmdm.BASE_URL": "<--headwind-url>"}`) into the app's external files dir
(`getExternalFilesDir()/init.json`). Headwind's own `updateSettingsFromFile()`
reads it on next launch, so the operator needs no QR scan for the server-pointing
step. The wizard writes `mdm.json` (`device_id`, `serial`, `device_class`,
`mdm_provider`, `dpc_package`, `headwind_url`, `headwind_config`, `xr_chat_url`,
`thin_desktop`, `thin_desktop_hosts`, `os`, `intune_device_id`,
`set_via:"adb-device-owner"`, `enrolled_at`) under `<out>/device/<device-id>/`.

**Stock-Android caveat (best-effort, not a wizard bug).** GrapheneOS device-owner
enrollment through adb is the **reliable** path. GrapheneOS has no Play Protect
gate at setup at all. Since late 2025, Google Play Protect enforces an approved-DPC
allow-list at provisioning time on Play-Protect-certified stock-Android devices.
An unlisted custom DPC can hit that block, with an opaque appeal path.
`cmd_mdm_enroll()` prints an un-suppressible advisory before it tries `dpm
set-device-owner` on a stock-Android device. A failure there is a normal `exit 1`
(precondition or tool failure) that names the allow-list as the likely cause. It
is not a driver defect.

### `attest` — AttestationServer pairing via the HugMesh-forked Auditor

`attest` installs our own fork of GrapheneOS's Auditor app, package
`systems.hugmesh.auditor`. The package differs on purpose from the stock
`app.attestation.auditor`, so a pin is unambiguous and a stock install is never
clobbered. The install is signer-pinned with `--auditor-signer-sha256`, using the
same shared apksigner-verify helper as `mdm-enroll` and `enroll`. Then `attest`
prints a runbook that points the operator at the self-hosted AttestationServer
console (`--attestation-url`, e.g. `https://attestation.hugmesh.net`) to scan the
pairing QR code from inside the Auditor app. **adb cannot drive the in-app camera
scan.** The wizard does no cryptographic verification of the attestation chain
itself, so it records the pairing honestly as `verdict:"operator-paired"`, never
as a cryptographic pass. Attestation is **advisory and logged in v1** (D9), not a
hard enrollment-blocking precondition. Fleet-scale operational characteristics
(alerting granularity, a machine-queryable verdict API) are undocumented upstream
and should be piloted before attestation becomes a hard gate. `attest` writes
`attestation.json` (`device_id`, `auditor_package`, `attestation_url`, `verdict`,
`at`) under `<out>/device/<device-id>/`. Its `attestation_url`,
`auditor_package` and `attestation_verdict` fields are folded into `ingest.json`;
see [Ingest](#ingest--device-registry).

### The coupling: the fork's signer pin *is* the server's trust anchor

The self-hosted AttestationServer trusts only attestations that carry our own
Auditor fork's identity. That is a build-time patch to `AttestationProtocol.java`'s
`AUDITOR_APP_PACKAGE_NAME_RELEASE` / `AUDITOR_APP_SIGNATURE_DIGEST_RELEASE`
constants (`specs/cluster/manifests/attestation-server/Dockerfile`), and not the
stock GrapheneOS Auditor's published pin. Concretely:

```
server AUDITOR_SIGNER_DIGEST  ===  HugMesh Auditor fork's release-signing-cert SHA-256
server ATTESTATION_DOMAIN     ===  fork's DOMAIN constant  ===  attestation.hugmesh.net
```

These are **built and set together**. If `AUDITOR_SIGNER_DIGEST` does not equal
the fork's real release-cert digest exactly, the server rejects *every*
attestation from our own app, with no partial credit and no fallback. The
`--auditor-signer-sha256` value that `attest` pins on the device must be the same
digest the AttestationServer image was built with. It is one value, checked at two
independent points (the wizard's apksigner-verify on the device, and the server's
compiled-in constant). A mismatch anywhere in the chain fails closed, never
silently.

## Summary

| Capability | Where | State |
| --- | --- | --- |
| Driver: full verb surface (`plan`/`detect`/`fetch`/`flash`/`attest`/`mdm-enroll`/`enroll`/`profile`/`rotate-profile-pass`/`remove-profile`/`ingest`/`status`/`wizard`) | [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ |
| Fail-closed artifact verification (sshsig + double fingerprint pin, tamper ⇒ delete + exit 3) | `dlv_verify_sshsig` + [`scripts/phone-allowed-signers`](../scripts/phone-allowed-signers) | ✅ |
| Pinned device catalog (21 devices, unknown codename ⇒ exit 4, no escape hatch) | [`scripts/phone-devices.tsv`](../scripts/phone-devices.tsv) | ✅ |
| Destructive gates (typed-serial flash confirm; non-TTY needs `--yes`+`--serial`; typed profile-name removal) | `flash` / `remove-profile` | ✅ |
| Tailnet enroll (keys-dir contract, SEC-08 pre-auth or Casdoor OIDC, ADR-14 approval, 100.64/10 join verify) | `enroll` | ✅ |
| Escrowed enterprise profile (vault-seed custody, operator-set default, atomic rotation, revocation trail) | `profile` / `rotate-profile-pass` / `remove-profile` | ✅ |
| `phone-ingest/v2` registry record (attestation + mdm folds) + mTLS POST | `ingest` | ✅ |
| Offline `plan` dry-run + `REDACTED` secret discipline | `plan` / `--print-plan` | ✅ |
| `make phone-*` thin face (host-side delegates; secrets stay file-path knobs) — all 13 verbs incl. `phone-mdm-enroll`/`phone-attest` | `Makefile` | ✅ |
| Thin ncurses-menu face over the driver (all 13 verbs + MDM/attestation knob sub-screen, non-build precedent) | `phone_screen` in [`scripts/build-menu.sh`](../scripts/build-menu.sh) | ✅ |
| Thin Studio (GUI) face over the driver (phone + quest side-flows off the ModePage; streamed verbs off-thread, TTY verbs handed to a terminal) | `PhonePage` / `QuestPage` in `studio/hugmesh_studio/gui/pages/` | ✅ |
| Quest device class (`--device-class quest`): class-scoped catalog, oculus/Meta identity pin, 4-verb chain, unsupported verbs fail-closed w/ rationale | [`scripts/quest-devices.tsv`](../scripts/quest-devices.tsv) + `require_class_supports` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#450) |
| Quest XR-chat URL provisioning (`--headwind-config` app-push lever + `--xr-chat-url` https-only, mdm.json record, VIEW-intent verify) | `cmd_mdm_enroll()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#450) |
| `make quest-*` thin face (7 quest verbs; `HEADWIND_CONFIG=`/`XR_CHAT_URL=` knobs) | `Makefile` | ✅ merged (#450) |
| Thin ncurses quest face (`quest_screen`: quest verbs only, Headwind sub-screen, XR-chat knob) | `quest_screen` in [`scripts/build-menu.sh`](../scripts/build-menu.sh) | ✅ |
| Quest mocked-adb e2e (real command-sequence assertions incl. unauthorized-headset, no-dev-mode, wrong-vendor, unsupported-verb paths) | [`tests/phone/e2e-quest-join.sh`](../tests/phone/e2e-quest-join.sh) | ✅ merged (#450) |
| APK store (general fleet app push/update/delete beyond the wizard's own vetted, signer-pinned sideloads) | — | 🔭 (deliberate v1 non-goal; Headwind's own console can do this directly, see [Remote-management model](#remote-management-model)) |
| Existing-device onboarding (GrapheneOS + stock Android, USB-guided or `--no-usb`, no reflash) | `enroll` | ✅ |
| Headwind MDM cluster optional-service (Postgres-backed, tailnet-only, `hugmesh-pki` namespace) | `specs/cluster/apps/23-headwind.yaml`, `specs/cluster/manifests/headwind/` | ✅ merged |
| GrapheneOS AttestationServer cluster optional-service (SQLite PVC, tailnet-only, forked Auditor identity baked in) | `specs/cluster/apps/24-attestation-server.yaml`, `specs/cluster/manifests/attestation-server/` | ✅ merged |
| `mdm-enroll` verb — Headwind device-owner enrollment, fresh-device precondition (now checks accounts too, not just users — #393), signer-pinned DPC APK, `init.json` `BASE_URL` injection | `cmd_mdm_enroll()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390, hardened #393) |
| `attest` verb — HugMesh-forked Auditor pairing to the self-hosted AttestationServer, operator-attested verdict | `cmd_attest()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390) |
| 8-step wizard order (`attest`/`mdm-enroll` immediately post-flash, before `profile`) | `cmd_wizard()` in [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) | ✅ merged (#390) |
| Auditor-fork ↔ AttestationServer signer-digest coupling (`AUDITOR_SIGNER_DIGEST`) | [Management plane](#management-plane) | ✅ server-side patch merged; digest itself is set at Auditor-fork release-signing time (operator step, outside this repo) |
| OTA/update posture management (GrapheneOS updates itself; Headwind CE ships no OTA lever) | — | 🔭 |

## Deferred

Tracked here per the driver's header. Each item is still 🔭, by design. The
earlier **"any on-phone agent (MDM, resident daemon, APK store)"** entry is
**superseded and removed from this list**: Headwind's device-owner DPC is now
delivered (see [Management plane](#management-plane)). Only the APK-store half of
that non-goal still stands (see the Summary table).

- ~~**Thin Studio (GUI) face**~~ — **delivered** (see the Summary table). The
  `make phone-*`/`quest-*` faces, the ncurses `phone_screen`/`quest_screen` and
  the Studio `PhonePage`/`QuestPage` are all thin faces over the one driver (the
  driver owns all logic; no build-matrix row). The `HEADWIND_*`, `AUDITOR_*`,
  `ATTESTATION_URL` and `INTERNAL_TOKEN_FILE` knobs pass through as file paths
  only, per the custody pattern.
- **Casdoor SSO for Headwind.** Nothing in this recon confirmed that Headwind
  supports OIDC or SAML (its own auth is local username/password behind a
  pluggable `HmdmAuthInterface`). Until someone confirms it independently,
  Headwind stays gated by network reachability, `ROLE_SUPERADMIN` route access
  and a Vault-managed local admin account, not by Casdoor identity federation.
- **`attest --attestation-verdict-source api`**, an automated, machine-queryable
  attestation-verdict mode. No confirmed headless "submit and get a JSON verdict"
  API surface exists for the self-hosted AttestationServer today (its
  `/api/devices.json` sits behind a login-session cookie, not a bare API key). In
  v1, `attest` ships only the operator-attested pairing tier.
- **GrapheneOS QR-at-setup provisioning.** Headwind's `SetupWizard2` PRs remain
  unmerged upstream as of this recon. adb is the only supported GrapheneOS
  device-owner path today. `cmd_mdm_enroll()` is written so that, once QR
  provisioning lands upstream, only the function's internals change, not the
  wizard's step order or exit-code contract.
- **OTA/update posture reporting.** GrapheneOS's own updater handles OS updates,
  and Headwind CE ships no OTA lever. A management-plane-visible update or
  compliance report would need a future agent capability that this driver does
  not have.
- ~~**Folding `mdm.json` into `ingest.json`**~~ — **delivered**: `phone-ingest/v2`
  carries the `mdm{...}` object (`cmd_ingest` in `scripts/phone-wizard.sh`); see
  [Ingest](#ingest--device-registry).
