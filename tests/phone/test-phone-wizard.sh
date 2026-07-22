#!/usr/bin/env bash
# test-phone-wizard.sh — offline logic test for the MDM phone wizard
# driver (scripts/phone-wizard.sh): GrapheneOS Pixel onboarding — detect ->
# fetch (verified) -> flash -> attest (self-hosted AttestationServer pairing)
# -> mdm-enroll (Headwind MDM device-owner) -> enroll -> profile -> ingest.
#
# Runs ANYWHERE with bash + jq + ssh-keygen + sha256sum — NO network, NO root,
# NO device, NO adb/fastboot install. The android tools and curl are PATH-shim
# STUBS (in ${WORK}/bin) that log every invocation to ${WORK}/logs and serve
# release fixtures from a local dir; the sshsig SUPPLY-CHAIN CRYPTO IS REAL —
# an ephemeral ed25519 key signs the fixture artifact with `ssh-keygen -Y sign`
# and the driver verifies it through the same dlv_verify_sshsig path production
# uses (cases tagged [REAL]). SKIPs (exit 0) only if a required tool is
# genuinely absent. Mirrors tests/go-live/test-go-live-driver.sh conventions
# (P/F counters, mktemp+trap, seam-driven sandboxing).
#
# Assertion groups:
#   (1)  static: driver parses (bash -n); help exits 0; unknown verb/option -> 1.
#   (2)  plan is OFFLINE + DRY-RUN: PLAN_<K>=<V> lines, zero curl calls,
#        touches nothing, secrets only as REDACTED presence markers.
#   (3)  plan gates: unknown codename -> 4; bad channel -> 1; device-id
#        sanitation; --print-plan alias; unknown plan target -> 1.
#   (4)  keys-dir resolution (docker-mesh-node layout): login-server/authkey/
#        role picked up; explicit flags win; missing dir -> 1.
#   (5)  detect via stubbed adb/fastboot: DEVICE_* lines; none -> 2;
#        ambiguity -> 2; --serial not connected -> 4; unauthorized warns.
#   (6)  [REAL] fetch happy path: genuine sshsig verifies, .verified-<sha256>
#        marker + version cache written, artifact extracted.
#   (7)  [REAL] tamper: corrupted artifact -> exit 3 AND the artifact+sig are
#        DELETED (a bad zip must never survive to be flashed).
#   (8)  [REAL] fingerprint-pin fail-closed: appended foreign signer key -> 3;
#        empty pin with the DEFAULT signers refused -> 3; empty pin with
#        overridden signers allowed (unpinned).
#   (9)  fetch idempotency/caching: re-fetch is fully offline (zero curl calls,
#        exactly one marker); malformed release metadata -> 1.
#   (10) flash refusal gates: non-TTY without BOTH --yes AND --serial -> 2;
#        no artifact -> 2; bytes changed since fetch -> 2; old fastboot -> 2.
#   (11) flash happy path (stubbed fastboot): flash-all.sh runs with
#        ANDROID_SERIAL bound; unlock precedes lock; exit 0.
#   (12) enroll (ADDENDUM 2026-07-16 — existing-device onboarding): no login
#        server -> 1; GrapheneOS enrolls, os=grapheneos recorded; STOCK
#        ANDROID enrolls WITHOUT --force, os=android recorded (first-class,
#        not a degraded path); genuinely UNDETECTABLE OS still needs --force
#        (os=unknown); tailnet join verified from stub tailscale0 addr;
#        enrollment.json fields; authkey NEVER shown without --show-authkey.
#   (13) profile lifecycle: escrow 0600/0700 + passphrase shape; duplicate -> 2;
#        rotate keeps .prev-<ts>; --pass-file honored, empty -> 1; remove
#        refuses non-TTY without --yes, --yes retires escrow to .revoked-<ts>.
#   (14) ingest + SECRET SWEEP: phone-ingest/v2 record fields; POST without
#        mTLS identity -> 2 (fail-closed); POST goes through curl with the
#        record; then a sweep proving NO secret (authkey, any escrowed or
#        supplied passphrase) ever appeared on stdout/stderr or any stub argv.
#   (15) enroll --no-usb (ADDENDUM 2026-07-16): needs --device-id (no adb
#        serial to derive one); makes ZERO adb calls; enrollment.json is
#        verification:"operator-attested" with tailscale_ip:null; authkey
#        absent from stdout by default, shown once with --show-authkey.
#   (16) Tailscale APK signer-digest pin (--apk-signer-sha256, apksigner
#        PATH-shim stub): match -> OK; mismatch -> exit 3; apksigner missing
#        -> exit 2; empty apksigner output -> exit 3 (fail-closed).
#   (17) enroll's adb-unreachable precondition (get-state != device) actually
#        triggers -> exit 2.
#   (18) enroll's tailnet-join VERIFY timeout actually triggers (blank
#        tailscale0 fixture) -> exit 1 within PW_JOIN_TIMEOUT.
#   (19) flash's SEL_STATE==adb reboot-into-bootloader wait loop
#        (PW_FASTBOOT_REAPPEAR_TIMEOUT seam): happy path (serial reappears
#        mid-poll) and the dieout (never reappears -> exit 1, flash-all
#        never ran).
#   (20) fastboot unlock/lock failure branches (stub knobs fb-flashing-fail /
#        fb-unlocked): already-unlocked fallback, unlock-fail-and-locked
#        abort, lock-fail-leaves-device-unlocked.
#   (21) flash-all.sh failure path: exit 1, "do NOT lock", and no
#        'flashing lock' line ever reaches fastboot.log.
#   (22) mdm-enroll (Phase 3: Headwind MDM device-owner enrollment): FRESH
#        device (1 user) + valid --headwind-apk/signer pin -> dpm
#        set-device-owner com.hmdm.launcher/.AdminReceiver in adb.log,
#        mdm.json fields correct; NON-fresh (2 users) -> exit 2 (one-shot
#        AOSP gate), --force downgrades to a warning and proceeds;
#        --headwind-signer-sha256 mismatch -> exit 3.
#   (23) attest (Phase 3: self-hosted AttestationServer pairing via the
#        Snapdragon-forked Auditor, package systems.snapdragon.auditor):
#        valid --auditor-apk/signer -> attestation.json
#        {auditor_package, verdict:"operator-paired"}; ingest folds the
#        attestation fields in; --auditor-signer-sha256 mismatch -> exit 3;
#        the authkey/secret sweep still passes after these runs.
#   (24) wizard step ordering (STATIC, no execution): cmd_wizard's body
#        references exactly Step 1/8..8/8, and its actual verb calls are
#        wired in source order detect < fetch < flash < attest < mdm-enroll
#        < enroll < profile < ingest — attest/mdm-enroll both strictly
#        before profile (the step that forecloses device-owner mode).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="${REPO}/scripts/phone-wizard.sh"
DLLIB="${REPO}/scripts/_download-lib.sh"

[ -r "${DRIVER}" ] || { echo "  FAIL driver missing: ${DRIVER}"; exit 1; }
[ -r "${DLLIB}" ]  || { echo "  FAIL download lib missing: ${DLLIB}"; exit 1; }
for t in jq ssh-keygen sha256sum awk; do
    command -v "${t}" >/dev/null || { echo "SKIP: need ${t}"; exit 0; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== MDM phone wizard: offline driver test (stub tools + REAL sshsig crypto) =="

# ── Layout ─────────────────────────────────────────────────────────
BIN="${WORK}/bin"; STATE="${WORK}/state"; LOGD="${WORK}/logs"
FIXTURES="${WORK}/fixtures"; OUT="${WORK}/out"
SWEEP="${WORK}/sweep.log"   # every DEFAULT-path capture lands here for group 14
mkdir -p "${BIN}" "${STATE}" "${LOGD}" "${FIXTURES}" "${OUT}"
: > "${SWEEP}"

SERIAL_A="TESTSER123"
DEVID="phone-testser123"    # sanitize_id(TESTSER123)
CODENAME="oriole"
VER="2026071500"
RELEASES_URL="https://releases.phone-test.invalid"

# ── PATH-shim stubs: adb / fastboot / curl (log argv, serve state/fixtures) ──
cat > "${BIN}/adb" <<'EOF'
#!/usr/bin/env bash
S="${PW_STUB_STATE:?}"; L="${PW_STUB_LOG_DIR:?}"
printf 'ADB %s\n' "$*" >> "${L}/adb.log"
[ "${1:-}" = "-s" ] && shift 2
case "${1:-}" in
    devices)   cat "${S}/adb-devices" 2>/dev/null || echo "List of devices attached"; exit 0 ;;
    get-state) cat "${S}/adb-getstate" 2>/dev/null || echo device; exit 0 ;;
    reboot|install) exit 0 ;;
    pull)
        [ -n "${3:-}" ] && { cp "${S}/apk-fixture" "${3}" 2>/dev/null || printf 'apk-fixture-bytes\n' > "${3}"; }
        exit 0 ;;
    shell)
        shift
        case "$*" in
            'getprop ro.product.device')            cat "${S}/codename" 2>/dev/null || echo oriole ;;
            'getprop ro.build.version.incremental') cat "${S}/incremental" 2>/dev/null || echo 2026071500 ;;
            'getprop ro.build.version.release')     cat "${S}/release" 2>/dev/null || echo 14 ;;
            'getprop ro.build.fingerprint')         echo 'google/oriole/oriole:14/TEST/2026071500:user/release-keys' ;;
            'getprop net.hostname')                 echo phone-stub-host ;;
            getprop)                                cat "${S}/getprop-dump" 2>/dev/null || echo '[ro.gos]: [grapheneos]' ;;
            'pm list users')
                printf '\tUserInfo{0:Owner:c13}\n'
                [ -e "${S}/user-created" ] && printf '\tUserInfo{10:enterprise:410}\n' ;;
            'pm create-user '*) touch "${S}/user-created"; echo 'Success: created user id 10' ;;
            'pm remove-user '*) rm -f "${S}/user-created"; echo 'Success: removed user' ;;
            'am start-user '*|'am switch-user '*) echo ok ;;
            'pm list packages') cat "${S}/packages" 2>/dev/null || echo 'package:com.tailscale.ipn' ;;
            'pm path '*)        echo 'package:/data/app/stub/base.apk' ;;
            'ip -o addr show')
                # Real Android names the Tailscale VpnService iface tun0 (kernel
                # tun%d), never tailscale0 — the driver now probes ALL interfaces
                # and scopes to tun*. Fixture toggle unchanged: an empty
                # tailscale-addr file forces the not-joined (timeout) path.
                cat "${S}/tailscale-addr" 2>/dev/null \
                    || printf '5: tun0    inet 100.64.0.7/32 scope global tun0\\       valid_lft forever preferred_lft forever\n' ;;
            'dumpsys lock_settings'|'locksettings set-password '*) : ;;
            'dpm set-device-owner '*)
                # Knob (${S}/dpm-fail): simulate the real one-shot AOSP
                # IllegalStateException a stale device-owner attempt hits.
                # Not exercised by the fresh-device/--force cases below
                # (those rely on the driver's OWN pm-list-users precondition
                # gate firing first), kept for completeness/future use.
                if [ -e "${S}/dpm-fail" ]; then
                    printf 'java.lang.IllegalStateException: Not allowed to set the device owner because there are already several users on the device.\n' >&2
                    exit 1
                fi
                printf 'Success: Device owner set to package ComponentInfo{com.hmdm.launcher/com.hmdm.launcher.AdminReceiver}\n' ;;
            *) : ;;
        esac
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "${BIN}/fastboot" <<'EOF'
#!/usr/bin/env bash
S="${PW_STUB_STATE:?}"; L="${PW_STUB_LOG_DIR:?}"
printf 'FASTBOOT %s\n' "$*" >> "${L}/fastboot.log"
[ "${1:-}" = "-s" ] && shift 2
case "${1:-}" in
    devices)   cat "${S}/fb-devices" 2>/dev/null; exit 0 ;;
    --version) cat "${S}/fb-version" 2>/dev/null || echo 'fastboot version 35.0.2-android'; exit 0 ;;
    getvar)
        case "${2:-}" in
            product)  echo "product: $(cat "${S}/codename" 2>/dev/null || echo oriole)" >&2 ;;
            unlocked) echo "unlocked: $(cat "${S}/fb-unlocked" 2>/dev/null || echo yes)" >&2 ;;
        esac
        exit 0 ;;
    flashing)
        fail="$(cat "${S}/fb-flashing-fail" 2>/dev/null || true)"
        case ",${fail}," in *",${2:-},"*) exit 1 ;; esac
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
# curl stub: serves ${PW_STUB_FIXTURES}/<basename-of-url>; -o writes a file,
# else body goes to stdout (the resolve_version capture). POSTs (-X) are logged
# and accepted. Missing fixture -> exit 22 (curl --fail's HTTP-error code).
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
FX="${PW_STUB_FIXTURES:?}"; L="${PW_STUB_LOG_DIR:?}"
printf 'CURL %s\n' "$*" >> "${L}/curl.log"
dest=""; url=""; post=0; prev=""
for a in "$@"; do
    [ "${prev}" = "-o" ] && dest="${a}"
    case "${a}" in http://*|https://*) url="${a}" ;; -X) post=1 ;; esac
    prev="${a}"
done
[ "${post}" -eq 1 ] && exit 0
[ -n "${url}" ] || exit 2
f="${FX}/$(basename "${url}")"
[ -f "${f}" ] || exit 22
if [ -n "${dest}" ]; then cp "${f}" "${dest}"; else cat "${f}"; fi
exit 0
EOF
cat > "${BIN}/apksigner" <<'EOF'
#!/usr/bin/env bash
S="${PW_STUB_STATE:?}"; L="${PW_STUB_LOG_DIR:?}"
printf 'APKSIGNER %s\n' "$*" >> "${L}/apksigner.log"
if [ -f "${S}/apksigner-digest" ]; then
    d="$(cat "${S}/apksigner-digest" 2>/dev/null)"
    [ -n "${d}" ] && printf 'Signer #1 certificate SHA-256 digest: %s\n' "${d}"
else
    printf 'Signer #1 certificate SHA-256 digest: %s\n' "deadbeefcafef00d"
fi
exit 0
EOF
chmod +x "${BIN}/adb" "${BIN}/fastboot" "${BIN}/curl" "${BIN}/apksigner"

reset_state() {
    printf 'List of devices attached\n' > "${STATE}/adb-devices"
    : > "${STATE}/fb-devices"
    printf 'fastboot version 35.0.2-android\n' > "${STATE}/fb-version"
    printf '%s\n' "${CODENAME}" > "${STATE}/codename"
    printf '2026071500\n' > "${STATE}/incremental"
    printf '[ro.gos]: [grapheneos]\n' > "${STATE}/getprop-dump"
    printf '14\n' > "${STATE}/release"
    printf 'package:com.tailscale.ipn\n' > "${STATE}/packages"
    rm -f "${STATE}/user-created" "${STATE}/tailscale-addr" "${STATE}/adb-getstate" \
          "${STATE}/fb-flashing-fail" "${STATE}/fb-unlocked" "${STATE}/apksigner-digest"
}
clear_logs() { : > "${LOGD}/adb.log"; : > "${LOGD}/fastboot.log"; : > "${LOGD}/curl.log"; }
reset_state; clear_logs; : > "${LOGD}/flash-all.log"

# ── [REAL] crypto material: ephemeral ed25519 signer + pinned signers file ──
ssh-keygen -t ed25519 -N '' -C 'phone-wizard-test' -f "${WORK}/sign_key" -q \
    || { echo "SKIP: ssh-keygen cannot mint ed25519"; exit 0; }
SIGNERS="${WORK}/allowed_signers"
printf 'contact@grapheneos.org %s\n' "$(awk '{print $1" "$2}' "${WORK}/sign_key.pub")" > "${SIGNERS}"
FP="$(ssh-keygen -lf "${WORK}/sign_key.pub" | awk '{print $2}')"
ssh-keygen -t ed25519 -N '' -C 'foreign' -f "${WORK}/foreign_key" -q

# Fixture artifact: a real zip containing <codename>-install-<ver>/flash-all.sh
# when a zip builder + bsdtar are around (exercises the extraction path);
# otherwise random bytes + a pre-planted flash dir (extraction skipped).
ZIPNAME="${CODENAME}-install-${VER}.zip"
FLASHALL="${WORK}/flash-all.sh"
cat > "${FLASHALL}" <<'EOF'
#!/bin/sh
printf 'FLASH-ALL serial=%s pwd=%s\n' "${ANDROID_SERIAL:-none}" "$PWD" >> "${PW_STUB_LOG_DIR:?}/flash-all.log"
EOF
HAVE_REALZIP=0
if command -v python3 >/dev/null 2>&1 && command -v bsdtar >/dev/null 2>&1; then
    python3 - "${FIXTURES}/${ZIPNAME}" "${FLASHALL}" "${CODENAME}-install-${VER}" <<'PY' && HAVE_REALZIP=1
import sys, zipfile
dest, flashall, inner = sys.argv[1:4]
with zipfile.ZipFile(dest, "w") as z:
    z.writestr(inner + "/flash-all.sh", open(flashall).read())
PY
fi
if [ "${HAVE_REALZIP}" -eq 0 ]; then
    head -c 4096 /dev/urandom > "${FIXTURES}/${ZIPNAME}"
fi
# Pre-plant the extracted flash dir when the artifact is not a real zip.
plant_flash_dir() {  # $1 = work-dir
    [ "${HAVE_REALZIP}" -eq 1 ] && return 0
    mkdir -p "$1/${CODENAME}-install-${VER}"
    cp "${FLASHALL}" "$1/${CODENAME}-install-${VER}/flash-all.sh"
}
( cd "${FIXTURES}" && ssh-keygen -Y sign -f "${WORK}/sign_key" -n 'factory images' "${ZIPNAME}" >/dev/null 2>&1 ) \
    || { echo "SKIP: ssh-keygen -Y sign unavailable"; exit 0; }
printf '%s 1752537600 %s stable\n' "${VER}" "${CODENAME}" > "${FIXTURES}/${CODENAME}-stable"

# Tampered-fixture dir: same sig, corrupted zip bytes.
FIX_TAMPER="${WORK}/fixtures-tamper"; mkdir -p "${FIX_TAMPER}"
cp "${FIXTURES}/${ZIPNAME}" "${FIXTURES}/${ZIPNAME}.sig" "${FIXTURES}/${CODENAME}-stable" "${FIX_TAMPER}/"
printf 'X' >> "${FIX_TAMPER}/${ZIPNAME}"
# Malformed-metadata dir: garbage channel file.
FIX_BADMETA="${WORK}/fixtures-badmeta"; mkdir -p "${FIX_BADMETA}"
printf 'banana\n' > "${FIX_BADMETA}/${CODENAME}-stable"

# ── Driver invocation: PATH shim + env seams, stdin /dev/null, 2>&1 ─────────
# pw [VAR=VAL ...] <verb> [args...]; run() also appends the capture to the
# secret-sweep log (use pw directly for output that must stay OUT of the sweep,
# e.g. the deliberate --show-authkey disclosure).
pw() {
    local extra=()
    while [[ "${1:-}" == *=* ]]; do extra+=("$1"); shift; done
    env PATH="${BIN}:${PATH}" \
        PW_STUB_STATE="${STATE}" PW_STUB_LOG_DIR="${LOGD}" PW_STUB_FIXTURES="${FIXTURES}" \
        PW_ALLOWED_SIGNERS="${SIGNERS}" PW_EXPECTED_SIGNER_FP="${FP}" \
        PW_RELEASES_URL="${RELEASES_URL}" PW_JOIN_TIMEOUT=4 PW_POLL_INTERVAL=1 \
        "${extra[@]}" bash "${DRIVER}" "$@" </dev/null 2>&1
}
OUT_TXT=""; RC=0
run() { OUT_TXT="$(pw "$@")"; RC=$?; printf '%s\n' "${OUT_TXT}" >> "${SWEEP}"; }
has() { grep -qF -- "$1" <<<"${OUT_TXT}"; }
plan_val() { sed -n "s/^PLAN_$1=//p" <<<"${OUT_TXT}" | head -n1; }

# ── (1) static ───────────────────────────────────────────────────────────────
bash -n "${DRIVER}" && ok "(1) driver parses (bash -n)" || bad "(1) driver has a syntax error"
run help
[ "${RC}" -eq 0 ] && has "Verbs:" && ok "(1) help exits 0 with usage" || bad "(1) help wrong (rc=${RC})"
run not-a-verb
[ "${RC}" -eq 1 ] && ok "(1) unknown verb -> exit 1" || bad "(1) unknown verb rc=${RC}, want 1"
run plan --codename "${CODENAME}" --not-an-option
[ "${RC}" -eq 1 ] && ok "(1) unknown option -> exit 1" || bad "(1) unknown option rc=${RC}, want 1"
run plan --codename "${CODENAME}" --serial
[ "${RC}" -eq 1 ] && has "requires a value" && ! has "unbound variable" \
    && ok "(1) option given without its value -> clean pw_die rc 1 (not bash's unbound-variable abort)" \
    || bad "(1) --serial-without-value rc=${RC}, out='${OUT_TXT}'"

# ── (2) plan is OFFLINE + DRY-RUN, secrets only as presence markers ─────────
clear_logs
PLAN_WD="${WORK}/plan-wd"; PLAN_OUT="${WORK}/plan-out"
run plan --codename "${CODENAME}" --work-dir "${PLAN_WD}" --out "${PLAN_OUT}"
[ "${RC}" -eq 0 ] && ok "(2) plan exits 0" || bad "(2) plan rc=${RC}"
[ "$(plan_val CODENAME)" = "${CODENAME}" ] && [ "$(plan_val DEVICE_NAME)" = "Pixel 6" ] \
    && ok "(2) plan resolves the catalog (oriole -> Pixel 6)" || bad "(2) plan catalog lookup wrong"
[ "$(plan_val VERSION)" = "resolve-at-fetch" ] && ok "(2) plan without --resolve stays offline (resolve-at-fetch)" \
    || bad "(2) plan version '$(plan_val VERSION)', want resolve-at-fetch"
[ "$(plan_val ZIP_URL)" = "${RELEASES_URL}/${CODENAME}-install-<version>.zip" ] \
    && ok "(2) plan zip URL built from the releases seam" || bad "(2) plan zip URL '$(plan_val ZIP_URL)'"
[ "$(plan_val SIGNER_FP)" = "${FP}" ] && ok "(2) plan shows the effective signer pin" || bad "(2) plan signer fp '$(plan_val SIGNER_FP)'"
[ "$(plan_val AUTHKEY)" = "REDACTED:absent" ] && [ "$(plan_val PROFILE_PASS)" = "REDACTED:generate" ] \
    && ok "(2) plan renders secrets as REDACTED presence markers only" || bad "(2) plan secret markers wrong"
[ "$(plan_val STEPS)" = "detect,fetch,flash,attest,mdm-enroll,enroll,profile,ingest" ] \
    && ok "(2) plan (default wizard target) lists the full 8-step chain (Phase 3: attest+mdm-enroll)" \
    || bad "(2) plan steps '$(plan_val STEPS)'"
[ ! -s "${LOGD}/curl.log" ] && ok "(2) plan made ZERO network (curl) calls" || { bad "(2) plan called curl"; cat "${LOGD}/curl.log"; }
[ ! -e "${PLAN_WD}" ] && [ ! -e "${PLAN_OUT}" ] && ok "(2) plan touched NOTHING (no work/out dirs created)" \
    || bad "(2) plan created dirs (dry-run violated)"
run plan fetch --codename "${CODENAME}"
[ "$(plan_val VERB)" = "fetch" ] && [ "$(plan_val STEPS)" = "resolve-version,download,verify,extract" ] \
    && ok "(2) plan <verb> targets that verb's steps" || bad "(2) plan fetch target wrong"

# ── (3) plan gates: catalog, channel, device-id sanitation, alias ───────────
run plan --codename not-a-pixel
[ "${RC}" -eq 4 ] && ok "(3) unknown codename -> exit 4 (fail-closed catalog)" || bad "(3) unknown codename rc=${RC}, want 4"
run plan --codename "${CODENAME}" --channel nightly
[ "${RC}" -eq 1 ] && ok "(3) bad --channel -> exit 1" || bad "(3) bad channel rc=${RC}, want 1"
run plan --codename "${CODENAME}" --device-id 'Phone_ABC!!'
[ "$(plan_val DEVICE_ID)" = "phone-abc" ] && ok "(3) --device-id sanitized to [a-z0-9-] (Phone_ABC!! -> phone-abc)" \
    || bad "(3) device-id sanitation gave '$(plan_val DEVICE_ID)'"
run plan --codename "${CODENAME}" --device-id '___'
[ "${RC}" -eq 1 ] && ok "(3) --device-id that sanitizes to empty -> exit 1" || bad "(3) empty-sanitized device-id rc=${RC}, want 1"
run plan definitely-not-a-verb
[ "${RC}" -eq 1 ] && ok "(3) unknown plan target -> exit 1" || bad "(3) unknown plan target rc=${RC}, want 1"
run detect --print-plan
[ "${RC}" -eq 0 ] && [ "$(plan_val VERB)" = "detect" ] && ok "(3) --print-plan is a plan alias (plans the given verb)" \
    || bad "(3) --print-plan alias broken (rc=${RC}, verb='$(plan_val VERB)')"

# ── (4) keys-dir resolution (docker-mesh-node layout) ───────────────────────
KEYS="${WORK}/keys"; mkdir -p "${KEYS}/tailscale"
AUTHKEY_VALUE="tskey-auth-k9SECRETSWEEPVALUE7x"
printf 'https://headscale.phone-test.invalid\n' > "${KEYS}/login-server"
(umask 077; printf '%s\n' "${AUTHKEY_VALUE}" > "${KEYS}/tailscale/authkey")
printf 'admin\n' > "${KEYS}/role"
run plan --codename "${CODENAME}" --keys-dir "${KEYS}"
[ "$(plan_val LOGIN_SERVER)" = "https://headscale.phone-test.invalid" ] \
    && ok "(4) keys-dir login-server resolved" || bad "(4) login-server '$(plan_val LOGIN_SERVER)'"
[ "$(plan_val AUTHKEY)" = "REDACTED:present" ] && ok "(4) keys-dir authkey shows presence only (REDACTED:present)" \
    || bad "(4) authkey marker '$(plan_val AUTHKEY)'"
[ "$(plan_val ROLE)" = "admin" ] && ok "(4) keys-dir role file resolved" || bad "(4) role '$(plan_val ROLE)'"
run plan --codename "${CODENAME}" --keys-dir "${KEYS}" --login-server https://override.invalid
[ "$(plan_val LOGIN_SERVER)" = "https://override.invalid" ] && ok "(4) explicit --login-server overrides keys-dir" \
    || bad "(4) override lost: '$(plan_val LOGIN_SERVER)'"
KEYS2="${WORK}/keys2"; mkdir -p "${KEYS2}"
printf 'https://h2.invalid\n' > "${KEYS2}/login-server"
run plan --codename "${CODENAME}" --keys-dir "${KEYS2}"
[ "$(plan_val ROLE)" = "user" ] && ok "(4) role defaults to user without a role file" || bad "(4) default role '$(plan_val ROLE)'"
run plan --codename "${CODENAME}" --keys-dir "${WORK}/no-such-keys"
[ "${RC}" -eq 1 ] && ok "(4) missing --keys-dir -> exit 1" || bad "(4) missing keys-dir rc=${RC}, want 1"

# ── (5) detect via stubs ─────────────────────────────────────────────────────
reset_state
run detect
[ "${RC}" -eq 2 ] && ok "(5) no device connected -> exit 2" || bad "(5) no-device rc=${RC}, want 2"
printf 'List of devices attached\n%s             device usb:1-4 product:oriole\n' "${SERIAL_A}" > "${STATE}/adb-devices"
run detect
[ "${RC}" -eq 0 ] && has "DEVICE_SERIAL=${SERIAL_A}" && has "DEVICE_STATE=adb" \
    && has "DEVICE_CODENAME=${CODENAME}" && has "DEVICE_NAME=Pixel 6" \
    && ok "(5) detect prints DEVICE_* for the single adb device" \
    || { bad "(5) detect output wrong (rc=${RC})"; echo "${OUT_TXT}"; }
printf 'List of devices attached\n%s device usb:1-4\nSECOND9999 device usb:1-5\n' "${SERIAL_A}" > "${STATE}/adb-devices"
run detect
[ "${RC}" -eq 2 ] && ok "(5) multiple devices without --serial -> exit 2" || bad "(5) ambiguity rc=${RC}, want 2"
run detect --serial SECOND9999
[ "${RC}" -eq 0 ] && has "DEVICE_SERIAL=SECOND9999" && ok "(5) --serial picks the named device" \
    || bad "(5) --serial pick failed (rc=${RC})"
run detect --serial GHOST0000
[ "${RC}" -eq 4 ] && ok "(5) --serial not connected -> exit 4" || bad "(5) ghost serial rc=${RC}, want 4"
printf 'List of devices attached\n%s unauthorized usb:1-4\n' "${SERIAL_A}" > "${STATE}/adb-devices"
run detect
has "UNAUTHORIZED" && ok "(5) unauthorized device warns about the USB-debugging prompt" \
    || bad "(5) no unauthorized warning"

# ── (6) [REAL] fetch happy path ──────────────────────────────────────────────
reset_state; clear_logs
WD="${WORK}/wd"; mkdir -p "${WD}"; plant_flash_dir "${WD}"
run fetch --codename "${CODENAME}" --work-dir "${WD}"
ZIP="${WD}/${ZIPNAME}"
[ "${RC}" -eq 0 ] && ok "[REAL] (6) fetch exits 0 with a genuinely signed artifact" || { bad "[REAL] (6) fetch rc=${RC}"; echo "${OUT_TXT}"; }
SHA="$(sha256sum "${ZIP}" 2>/dev/null | awk '{print $1}')"
[ -n "${SHA}" ] && [ -f "${ZIP}.verified-${SHA}" ] && ok "[REAL] (6) .verified-<sha256> marker matches the bytes" \
    || bad "[REAL] (6) verification marker missing/mismatched"
[ "$(cat "${WD}/.resolved-${CODENAME}-stable" 2>/dev/null)" = "${VER}" ] \
    && ok "(6) channel resolution cached next to the artifact" || bad "(6) version cache missing/wrong"
[ -f "${WD}/${CODENAME}-install-${VER}/flash-all.sh" ] && ok "(6) flash-all.sh present (extracted)" \
    || bad "(6) flash dir missing after fetch"
grep -q "${CODENAME}-stable" "${LOGD}/curl.log" && grep -q "${ZIPNAME}.sig" "${LOGD}/curl.log" \
    && ok "(6) fetch pulled metadata + artifact + sig via the (stub) network" || bad "(6) curl.log missing expected fetches"

# ── (7) [REAL] tamper -> exit 3 + artifact deleted ───────────────────────────
WD2="${WORK}/wd-tamper"; mkdir -p "${WD2}"; plant_flash_dir "${WD2}"
run "PW_STUB_FIXTURES=${FIX_TAMPER}" fetch --codename "${CODENAME}" --work-dir "${WD2}"
[ "${RC}" -eq 3 ] && ok "[REAL] (7) tampered artifact -> exit 3 (tamper)" || bad "[REAL] (7) tamper rc=${RC}, want 3"
[ ! -e "${WD2}/${ZIPNAME}" ] && [ ! -e "${WD2}/${ZIPNAME}.sig" ] \
    && ok "[REAL] (7) tampered artifact + sig DELETED (cannot survive to flash)" \
    || bad "[REAL] (7) tampered artifact survived in ${WD2}"
compgen -G "${WD2}/${ZIPNAME}.verified-*" >/dev/null && bad "[REAL] (7) tamper left a verification marker" \
    || ok "[REAL] (7) no verification marker after tamper"

# ── (8) [REAL] fingerprint-pin fail-closed ───────────────────────────────────
SIGNERS_EVIL="${WORK}/allowed_signers_evil"
cat "${SIGNERS}" > "${SIGNERS_EVIL}"
printf 'contact@grapheneos.org %s\n' "$(awk '{print $1" "$2}' "${WORK}/foreign_key.pub")" >> "${SIGNERS_EVIL}"
WD3="${WORK}/wd-evil"; mkdir -p "${WD3}"; plant_flash_dir "${WD3}"
run "PW_ALLOWED_SIGNERS=${SIGNERS_EVIL}" fetch --codename "${CODENAME}" --work-dir "${WD3}"
[ "${RC}" -eq 3 ] && ok "[REAL] (8) APPENDED foreign key in allowed_signers -> exit 3 (pin pre-check)" \
    || bad "[REAL] (8) appended-key rc=${RC}, want 3"
[ ! -e "${WD3}/${ZIPNAME}" ] && ok "[REAL] (8) artifact deleted on pin failure too" || bad "[REAL] (8) artifact survived pin failure"
run "PW_EXPECTED_SIGNER_FP=" "PW_ALLOWED_SIGNERS=" plan --codename "${CODENAME}"
[ "${RC}" -eq 3 ] && ok "[REAL] (8) empty pin + DEFAULT signers file REFUSED (exit 3, fail-closed)" \
    || bad "[REAL] (8) empty-pin refusal rc=${RC}, want 3"
run "PW_EXPECTED_SIGNER_FP=" plan --codename "${CODENAME}"
[ "${RC}" -eq 0 ] && [ "$(plan_val SIGNER_FP)" = "unpinned" ] \
    && ok "(8) empty pin WITH overridden signers allowed (test seam, shows unpinned)" \
    || bad "(8) empty pin + overridden signers rc=${RC}, fp='$(plan_val SIGNER_FP)'"
run "PW_SKIP_FP_PIN=1" plan --codename "${CODENAME}"
[ "${RC}" -eq 0 ] && [ "$(plan_val SIGNER_FP)" = "unpinned" ] && ok "(8) PW_SKIP_FP_PIN=1 -> unpinned" \
    || bad "(8) PW_SKIP_FP_PIN rc=${RC}, fp='$(plan_val SIGNER_FP)'"
run "PW_SKIP_FP_PIN=1" "PW_ALLOWED_SIGNERS=" plan --codename "${CODENAME}"
[ "${RC}" -eq 3 ] && ok "(8) PW_SKIP_FP_PIN=1 WITHOUT overriding ALLOWED_SIGNERS (default signers file) -> pw_die rc 3 (closes the fail-open bypass)" \
    || bad "(8) PW_SKIP_FP_PIN=1 + default signers rc=${RC}, want 3"

# ── (9) fetch idempotency + malformed metadata ───────────────────────────────
clear_logs
run fetch --codename "${CODENAME}" --work-dir "${WD}"
[ "${RC}" -eq 0 ] && ok "(9) re-fetch of a verified artifact exits 0" || bad "(9) re-fetch rc=${RC}"
[ ! -s "${LOGD}/curl.log" ] && ok "(9) re-fetch was FULLY OFFLINE (zero curl calls — cached resolution + re-verify)" \
    || { bad "(9) re-fetch hit the network"; cat "${LOGD}/curl.log"; }
[ "$(ls "${WD}/${ZIPNAME}".verified-* 2>/dev/null | wc -l)" -eq 1 ] \
    && ok "(9) exactly ONE verification marker after re-fetch" || bad "(9) marker set wrong after re-fetch"
WD4="${WORK}/wd-badmeta"; mkdir -p "${WD4}"
run "PW_STUB_FIXTURES=${FIX_BADMETA}" fetch --codename "${CODENAME}" --work-dir "${WD4}"
[ "${RC}" -eq 1 ] && ok "(9) malformed release metadata -> exit 1" || bad "(9) malformed metadata rc=${RC}, want 1"

# ── (10) flash refusal gates (non-TTY) ──────────────────────────────────────
reset_state
printf '%s\tfastboot\n' "${SERIAL_A}" > "${STATE}/fb-devices"
# fwupd may legitimately run on a dev host; --force-fwupd keeps THESE gate
# tests deterministic (the fwupd gate itself is not under test here).
run flash --codename "${CODENAME}" --work-dir "${WD}" --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 2 ] && has "refusing to flash on a non-TTY" \
    && ok "(10) non-TTY flash WITHOUT --yes refused at the confirmation gate (exit 2)" \
    || bad "(10) no-yes flash rc=${RC} (want 2 at the confirm gate)"
run flash --codename "${CODENAME}" --work-dir "${WD}" --yes --force-fwupd
[ "${RC}" -eq 2 ] && has "refusing to flash on a non-TTY" \
    && ok "(10) non-TTY flash with --yes but WITHOUT --serial refused (needs BOTH)" \
    || bad "(10) yes-without-serial rc=${RC}, want 2"
[ ! -s "${LOGD}/flash-all.log" ] && ok "(10) refused flashes never ran flash-all.sh" || bad "(10) flash-all ran despite refusal"
WD_EMPTY="${WORK}/wd-empty"; mkdir -p "${WD_EMPTY}"
run flash --codename "${CODENAME}" --work-dir "${WD_EMPTY}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 2 ] && has "run 'fetch' first" && ok "(10) flash with NO fetched artifact refused (exit 2)" \
    || bad "(10) missing-artifact rc=${RC}, want 2"
cp "${ZIP}" "${ZIP}.bak"; printf 'X' >> "${ZIP}"
run flash --codename "${CODENAME}" --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 2 ] && has "re-run 'fetch'" && ok "(10) artifact bytes changed since fetch -> refused (marker mismatch, exit 2)" \
    || bad "(10) byte-change rc=${RC}, want 2"
mv "${ZIP}.bak" "${ZIP}"
printf 'fastboot version 34.0.1\n' > "${STATE}/fb-version"
run flash --codename "${CODENAME}" --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 2 ] && has "too old" && ok "(10) fastboot < 35 refused (GrapheneOS needs >= 35.0.2)" \
    || bad "(10) old-fastboot rc=${RC}, want 2"
printf 'fastboot version 35.0.2-android\n' > "${STATE}/fb-version"

# ── (11) flash happy path (stub fastboot, real gates satisfied) ─────────────
: > "${LOGD}/flash-all.log"; : > "${LOGD}/fastboot.log"
run flash --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 0 ] && ok "(11) flash (stubbed fastboot) exits 0" || { bad "(11) flash rc=${RC}"; echo "${OUT_TXT}"; }
grep -q "serial=${SERIAL_A}" "${LOGD}/flash-all.log" \
    && ok "(11) flash-all.sh ran with ANDROID_SERIAL bound to the target device" \
    || bad "(11) flash-all.sh did not run with the serial"
UNLOCK_LN="$(grep -n 'flashing unlock' "${LOGD}/fastboot.log" | head -n1 | cut -d: -f1)"
LOCK_LN="$(grep -n 'flashing lock' "${LOGD}/fastboot.log" | head -n1 | cut -d: -f1)"
[ -n "${UNLOCK_LN}" ] && [ -n "${LOCK_LN}" ] && [ "${UNLOCK_LN}" -lt "${LOCK_LN}" ] \
    && ok "(11) bootloader unlock precedes re-lock (both attempted, in order)" \
    || bad "(11) unlock/lock sequence wrong (unlock=${UNLOCK_LN:-none}, lock=${LOCK_LN:-none})"
grep -q -- "-s ${SERIAL_A} flashing" "${LOGD}/fastboot.log" && ok "(11) flashing verbs bound to -s <serial>" \
    || bad "(11) flashing verbs not serial-bound"

# (11) re-flash retires stale device-owner / attestation records: a wipe
# destroys on-device DPC + attestation state, so a prior mdm.json/attestation.json
# for this device must be moved aside (.stale-<ts>) or a later ingest would fold
# a phantom enrolled:true / operator-paired verdict. enrollment.json/profile.json
# are left (enroll/profile re-run after flash and overwrite their own records).
FLREC="${WD%/*}/device/phone-$(printf '%s' "${SERIAL_A}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-')"
# ^ DEVICE_ID default = phone-<sanitize_id(SERIAL)>, --out defaults under the work dir's parent
mkdir -p "${FLREC}"
printf '{"enrolled":true,"set_via":"adb-device-owner"}' > "${FLREC}/mdm.json"
printf '{"verdict":"operator-paired"}'                  > "${FLREC}/attestation.json"
printf '{"role":"admin"}'                               > "${FLREC}/enrollment.json"
: > "${LOGD}/flash-all.log"; : > "${LOGD}/fastboot.log"
run flash --work-dir "${WD}" --out "${WD%/*}" --serial "${SERIAL_A}" --yes --force-fwupd
if [ "${RC}" -eq 0 ] && [ ! -f "${FLREC}/mdm.json" ] && [ ! -f "${FLREC}/attestation.json" ] \
   && ls "${FLREC}"/mdm.json.stale-* >/dev/null 2>&1 && ls "${FLREC}"/attestation.json.stale-* >/dev/null 2>&1; then
    ok "(11) re-flash retires stale mdm.json + attestation.json to .stale-<ts>"
else
    bad "(11) flash did not retire stale device records (rc=${RC}, mdm=$(ls "${FLREC}"/mdm.json* 2>/dev/null))"
fi
[ -f "${FLREC}/enrollment.json" ] \
    && ok "(11) re-flash leaves enrollment.json (enroll re-runs and overwrites it)" \
    || bad "(11) flash wrongly retired enrollment.json"
rm -rf "${FLREC}"

# ── (19) flash: SEL_STATE==adb reboot-into-bootloader wait loop ────────────
# Device starts up in adb (not already in fastboot) -> flash must `adb reboot
# bootloader` then poll for the same serial to reappear in fastboot, using the
# PW_FASTBOOT_REAPPEAR_TIMEOUT seam so the test doesn't cost real minutes.
reset_state
printf 'List of devices attached\n%s             device usb:1-4\n' "${SERIAL_A}" > "${STATE}/adb-devices"
: > "${STATE}/fb-devices"
: > "${LOGD}/flash-all.log"; : > "${LOGD}/fastboot.log"; : > "${LOGD}/adb.log"
( sleep 1; printf '%s\tfastboot\n' "${SERIAL_A}" > "${STATE}/fb-devices" ) &
run "PW_FASTBOOT_REAPPEAR_TIMEOUT=6" flash --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
wait
[ "${RC}" -eq 0 ] && ok "(19) flash from adb state: reboot-into-bootloader happy path (serial reappears mid-poll) exits 0" \
    || { bad "(19) adb-reboot happy path rc=${RC}"; echo "${OUT_TXT}"; }
grep -q 'reboot bootloader' "${LOGD}/adb.log" && ok "(19) adb reboot bootloader was issued before the fastboot poll" \
    || bad "(19) 'adb reboot bootloader' missing from adb.log"
grep -q "serial=${SERIAL_A}" "${LOGD}/flash-all.log" \
    && ok "(19) flash-all.sh ran once the device reappeared in fastboot" \
    || bad "(19) flash-all.sh did not run after the device reappeared"

reset_state
printf 'List of devices attached\n%s             device usb:1-4\n' "${SERIAL_A}" > "${STATE}/adb-devices"
: > "${STATE}/fb-devices"
: > "${LOGD}/flash-all.log"; : > "${LOGD}/fastboot.log"
run "PW_FASTBOOT_REAPPEAR_TIMEOUT=2" flash --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 1 ] && has "did not reappear in fastboot" \
    && ok "(19) flash from adb state: device that NEVER reappears in fastboot dies (exit 1) within the shrunk timeout" \
    || bad "(19) adb-reboot dieout rc=${RC}, out='${OUT_TXT}'"
[ ! -s "${LOGD}/flash-all.log" ] && ok "(19) flash-all.sh never ran when the device never reappeared" \
    || bad "(19) flash-all.sh ran despite the reappear dieout"

# ── (20) flash: fastboot unlock/lock failure branches (stub knobs) ─────────
reset_state
printf '%s\tfastboot\n' "${SERIAL_A}" > "${STATE}/fb-devices"
printf 'unlock\n' > "${STATE}/fb-flashing-fail"
printf 'yes\n' > "${STATE}/fb-unlocked"
: > "${LOGD}/flash-all.log"; : > "${LOGD}/fastboot.log"
run flash --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 0 ] && has "already unlocked" \
    && ok "(20) unlock report fails but getvar unlocked=yes -> already-unlocked-continuing" \
    || bad "(20) unlock-fail+unlocked=yes rc=${RC}, out='${OUT_TXT}'"
grep -q "serial=${SERIAL_A}" "${LOGD}/flash-all.log" \
    && ok "(20) flashing proceeded via the already-unlocked fallback" || bad "(20) flash-all.sh did not run via the fallback"

printf 'no\n' > "${STATE}/fb-unlocked"
: > "${LOGD}/flash-all.log"
run flash --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 1 ] && has "aborting before any flash" \
    && ok "(20) unlock report fails and getvar unlocked=no -> exit 1, aborts before any flash" \
    || bad "(20) unlock-fail+unlocked=no rc=${RC}, out='${OUT_TXT}'"
[ ! -s "${LOGD}/flash-all.log" ] && ok "(20) flash-all.sh never ran after the unlock-abort" \
    || bad "(20) flash-all.sh ran despite the unlock-abort"

rm -f "${STATE}/fb-flashing-fail" "${STATE}/fb-unlocked"
printf 'lock\n' > "${STATE}/fb-flashing-fail"
: > "${LOGD}/flash-all.log"; : > "${LOGD}/fastboot.log"
run flash --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 1 ] && has "REMAINS UNLOCKED" \
    && ok "(20) lock report fails -> exit 1, device REMAINS UNLOCKED" \
    || bad "(20) lock-fail rc=${RC}, out='${OUT_TXT}'"
grep -q "serial=${SERIAL_A}" "${LOGD}/flash-all.log" \
    && ok "(20) flash-all.sh DID run before the lock failure (flash itself succeeded)" \
    || bad "(20) flash-all.sh did not run before the lock failure"
rm -f "${STATE}/fb-flashing-fail" "${STATE}/fb-unlocked"

# ── (21) flash: flash-all.sh failure path (partial-flash abort) ────────────
FLASHDIR_21="${WD}/${CODENAME}-install-${VER}"
cp "${FLASHDIR_21}/flash-all.sh" "${FLASHDIR_21}/flash-all.sh.bak"
cat > "${FLASHDIR_21}/flash-all.sh" <<'FAEOF'
#!/bin/sh
printf 'FLASH-ALL FAILING serial=%s pwd=%s\n' "${ANDROID_SERIAL:-none}" "$PWD" >> "${PW_STUB_LOG_DIR:?}/flash-all.log"
exit 7
FAEOF
reset_state
printf '%s\tfastboot\n' "${SERIAL_A}" > "${STATE}/fb-devices"
: > "${LOGD}/flash-all.log"; : > "${LOGD}/fastboot.log"
run flash --work-dir "${WD}" --yes --serial "${SERIAL_A}" --force-fwupd
[ "${RC}" -eq 1 ] && has "flash-all.sh FAILED" && has "do NOT lock" \
    && ok "(21) flash-all.sh failure -> exit 1, 'do NOT lock' guidance shown" \
    || bad "(21) flash-all-fail rc=${RC}, out='${OUT_TXT}'"
grep -q 'flashing unlock' "${LOGD}/fastboot.log" && ok "(21) flashing-unlock WAS attempted before the flash-all failure" \
    || bad "(21) flashing unlock missing from fastboot.log"
! grep -q 'flashing lock' "${LOGD}/fastboot.log" \
    && ok "(21) NO flashing-lock line reaches fastboot.log after a flash-all.sh failure (re-lock never runs)" \
    || bad "(21) a flashing-lock line ran despite the flash-all.sh failure"
mv "${FLASHDIR_21}/flash-all.sh.bak" "${FLASHDIR_21}/flash-all.sh"

# ── (12) enroll ──────────────────────────────────────────────────────────────
reset_state
printf 'List of devices attached\n%s             device usb:1-4\n' "${SERIAL_A}" > "${STATE}/adb-devices"
run enroll --out "${OUT}"
[ "${RC}" -eq 1 ] && ok "(12) enroll without a login server -> exit 1" || bad "(12) no-login-server rc=${RC}, want 1"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 0 ] && ok "(12) enroll (stub adb, GrapheneOS probe + tailnet join) exits 0" || { bad "(12) enroll rc=${RC}"; echo "${OUT_TXT}"; }
has "https://headscale.phone-test.invalid" && ok "(12) join runbook names the headscale login server" \
    || bad "(12) runbook missing the login server"
has "tailnet join VERIFIED: 100.64.0.7" && ok "(12) tailnet join verified from the stub tun0 CGNAT address" \
    || bad "(12) join not verified"
! has "${AUTHKEY_VALUE}" && ok "(12) pre-auth key NOT displayed without --show-authkey" \
    || bad "(12) authkey LEAKED to output without --show-authkey"
ENR="${OUT}/device/${DEVID}/enrollment.json"
[ -f "${ENR}" ] \
    && [ "$(jq -r '.serial' "${ENR}")" = "${SERIAL_A}" ] \
    && [ "$(jq -r '.codename' "${ENR}")" = "${CODENAME}" ] \
    && [ "$(jq -r '.tailscale_ip' "${ENR}")" = "100.64.0.7" ] \
    && [ "$(jq -r '.role' "${ENR}")" = "admin" ] \
    && [ "$(jq -r '.login_server' "${ENR}")" = "https://headscale.phone-test.invalid" ] \
    && [ "$(jq -r '.os' "${ENR}")" = "grapheneos" ] \
    && [ "$(jq -r '.os_version' "${ENR}")" = "2026071500" ] \
    && [ "$(jq -r '.verification' "${ENR}")" = "adb-heuristic" ] \
    && ok "(12) enrollment.json carries serial/codename/tailscale_ip/role/login_server/os" \
    || bad "(12) enrollment.json missing/wrong"
# --show-authkey is the DELIBERATE disclosure path — captured OUTSIDE the sweep.
SHOWKEY_OUT="$(pw enroll --keys-dir "${KEYS}" --out "${OUT}" --show-authkey)"
grep -qF -- "${AUTHKEY_VALUE}" <<<"${SHOWKEY_OUT}" && ok "(12) --show-authkey displays the key once (explicit opt-in)" \
    || bad "(12) --show-authkey did not display the key"
# ADDENDUM 2026-07-16: stock Android is a first-class supported OS for enroll
# — NOT a degraded/forced path. A device that looks like plain Android (no
# GrapheneOS calendar-datestamp incremental, no 'grapheneos' in getprop, but a
# normal ro.build.version.release) enrolls WITHOUT --force.
printf 'eng.userdebug.1\n' > "${STATE}/incremental"
printf '[ro.build.flavor]: [aosp]\n' > "${STATE}/getprop-dump"
printf '14\n' > "${STATE}/release"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 0 ] && has "stock Android" \
    && ok "(12) stock-Android device enrolls WITHOUT --force (first-class OS)" \
    || bad "(12) stock-Android enroll rc=${RC}, want 0"
[ "$(jq -r '.os' "${ENR}")" = "android" ] && [ "$(jq -r '.os_version' "${ENR}")" = "14" ] \
    && ok "(12) enrollment.json records os=android (+ os_version) for stock Android" \
    || bad "(12) stock-Android enrollment.json os fields wrong"
# A datestamp-SHAPED incremental (YYYYMMDDNN) alone must NOT be enough to
# classify a device as GrapheneOS -- require the harder getprop marker too
# (a common AOSP/vendor build-number convention, no GrapheneOS-unique signal).
printf '2025011500\n' > "${STATE}/incremental"
printf '[ro.build.flavor]: [lineage_oriole-userdebug]\n[ro.product.brand]: [lineage]\n' > "${STATE}/getprop-dump"
printf '14\n' > "${STATE}/release"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 0 ] && [ "$(jq -r '.os' "${ENR}")" != "grapheneos" ] \
    && ok "(12) datestamp-shaped incremental WITHOUT a grapheneos getprop marker is NOT misclassified as grapheneos" \
    || bad "(12) datestamp-only incremental rc=${RC}, os='$(jq -r '.os' "${ENR}" 2>/dev/null)'"
# A genuinely UNDETECTABLE OS (no GrapheneOS signal AND no readable release
# property) still needs --force — only "unknown" gates, never "android".
: > "${STATE}/release"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 2 ] && has "could not determine the device OS" \
    && ok "(12) genuinely undetectable OS still refused without --force (exit 2)" \
    || bad "(12) undetectable-OS rc=${RC}, want 2"
run enroll --keys-dir "${KEYS}" --out "${OUT}" --force
[ "${RC}" -eq 0 ] && [ "$(jq -r '.os' "${ENR}")" = "unknown" ] \
    && ok "(12) --force downgrades the undetectable-OS gate to a warning (os=unknown)" \
    || bad "(12) --force enroll rc=${RC}"
printf '2026071500\n' > "${STATE}/incremental"
printf '[ro.gos]: [grapheneos]\n' > "${STATE}/getprop-dump"
printf '14\n' > "${STATE}/release"
run enroll --keys-dir "${KEYS}" --out "${OUT}"   # regenerate enrollment.json as GrapheneOS for the downstream ingest checks
[ "${RC}" -eq 0 ] && [ "$(jq -r '.os' "${ENR}")" = "grapheneos" ] \
    && ok "(12) enrollment.json regenerated as os=grapheneos after restoring the default probe state" \
    || bad "(12) enroll re-run after state restore rc=${RC}"

# ── (16) enroll: Tailscale APK signer-digest pin (--apk-signer-sha256) ─────
DIGEST_OK="deadbeefcafef00d"
DIGEST_BAD="cafebabefeedface"
printf '%s\n' "${DIGEST_OK}" > "${STATE}/apksigner-digest"
run enroll --keys-dir "${KEYS}" --out "${OUT}" --apk-signer-sha256 "${DIGEST_OK}"
[ "${RC}" -eq 0 ] && has "Tailscale APK signer pin OK" \
    && ok "(16) --apk-signer-sha256 matching digest -> OK, enroll proceeds" \
    || bad "(16) apk-signer match rc=${RC}, out='${OUT_TXT}'"
run enroll --keys-dir "${KEYS}" --out "${OUT}" --apk-signer-sha256 "${DIGEST_BAD}"
[ "${RC}" -eq 3 ] && has "signer digest MISMATCH" \
    && ok "(16) --apk-signer-sha256 mismatched digest -> exit 3 (fail-closed supply-chain gate)" \
    || bad "(16) apk-signer mismatch rc=${RC}, want 3, out='${OUT_TXT}'"
: > "${STATE}/apksigner-digest"
run enroll --keys-dir "${KEYS}" --out "${OUT}" --apk-signer-sha256 "${DIGEST_OK}"
[ "${RC}" -eq 3 ] && ok "(16) empty/unparseable apksigner output -> exit 3 (fail-closed, not a false pass)" \
    || bad "(16) apk-signer empty-output rc=${RC}, want 3"
rm -f "${STATE}/apksigner-digest"
mv "${BIN}/apksigner" "${WORK}/apksigner.hidden"
run enroll --keys-dir "${KEYS}" --out "${OUT}" --apk-signer-sha256 "${DIGEST_OK}"
[ "${RC}" -eq 2 ] && has "apksigner" \
    && ok "(16) apksigner tool missing -> exit 2 (require_tool preflight)" \
    || bad "(16) apksigner-missing rc=${RC}, want 2"
mv "${WORK}/apksigner.hidden" "${BIN}/apksigner"

# ── (17) enroll: adb-unreachable precondition actually triggers ────────────
printf 'offline\n' > "${STATE}/adb-getstate"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 2 ] && has "not reachable over adb" \
    && ok "(17) adb get-state != device -> exit 2 (not-reachable handset runbook)" \
    || bad "(17) adb-unreachable rc=${RC}, want 2"
rm -f "${STATE}/adb-getstate"

# ── (18) enroll: tailnet-join VERIFY timeout actually triggers ─────────────
: > "${STATE}/tailscale-addr"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 1 ] && has "device never got a tailnet address" \
    && ok "(18) blank tun0 fixture -> exit 1 within PW_JOIN_TIMEOUT (join-verify timeout fires)" \
    || bad "(18) tailnet-timeout rc=${RC}, want 1"
rm -f "${STATE}/tailscale-addr"

# Regenerate enrollment.json as GrapheneOS (default probe state) for the
# downstream (13)/(14) checks, after the (16)-(18) state perturbations above.
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 0 ] && [ "$(jq -r '.os' "${ENR}")" = "grapheneos" ] \
    && ok "(12) enrollment.json regenerated as os=grapheneos after the (16)-(18) probes" \
    || bad "(12) enroll re-run after (16)-(18) rc=${RC}"

# ── (13) profile lifecycle ───────────────────────────────────────────────────
run profile --out "${OUT}"
[ "${RC}" -eq 0 ] && ok "(13) profile creates the enterprise user + escrows (exit 0)" || { bad "(13) profile rc=${RC}"; echo "${OUT_TXT}"; }
ESCROW="${OUT}/vault-seed/device/${DEVID}/enterprise-profile.pass"
[ -f "${ESCROW}" ] && [ "$(stat -c '%a' "${ESCROW}")" = "600" ] && ok "(13) escrow file is 0600" \
    || bad "(13) escrow missing or not 0600"
[ "$(stat -c '%a' "$(dirname "${ESCROW}")")" = "700" ] && ok "(13) escrow dir is 0700" || bad "(13) escrow dir not 0700"
GEN_PASS1="$(cat "${ESCROW}")"
grep -qE '^[a-z]{6}(-[a-z]{6}){5}$' <<<"${GEN_PASS1}" \
    && ok "(13) generated passphrase is 6x6 lowercase words (41 chars, lockscreen-typable)" \
    || bad "(13) passphrase shape wrong: '${GEN_PASS1//?/x}' (${#GEN_PASS1} chars)"
PROF="${OUT}/device/${DEVID}/profile.json"
[ -f "${PROF}" ] && [ "$(jq -r '.user_id' "${PROF}")" = "10" ] \
    && [ "$(jq -r '.set_via' "${PROF}")" = "operator" ] \
    && [ "$(jq -r '.credential_custody' "${PROF}")" = "vault-seed" ] \
    && ok "(13) profile.json records user_id=10, set_via=operator, vault-seed custody" \
    || bad "(13) profile.json missing/wrong"
run profile --out "${OUT}"
[ "${RC}" -eq 2 ] && ok "(13) duplicate profile refused (exit 2 — rotate/remove instead)" || bad "(13) duplicate profile rc=${RC}, want 2"
run rotate-profile-pass --out "${OUT}"
[ "${RC}" -eq 0 ] && ok "(13) rotate-profile-pass exits 0" || bad "(13) rotate rc=${RC}"
GEN_PASS2="$(cat "${ESCROW}")"
[ "${GEN_PASS2}" != "${GEN_PASS1}" ] && ok "(13) rotation replaced the escrowed passphrase" || bad "(13) escrow unchanged after rotate"
PREV="$(ls "${ESCROW}".prev-* 2>/dev/null | head -n1)"
[ -n "${PREV}" ] && [ "$(cat "${PREV}")" = "${GEN_PASS1}" ] && [ "$(stat -c '%a' "${PREV}")" = "600" ] \
    && ok "(13) previous escrow kept as .prev-<ts> (0600)" || bad "(13) .prev escrow missing/wrong"
FILE_PASS="filepass-sweepme-abcdef-ghijkl-mnopqr-stuvwx"
(umask 077; printf '%s\n' "${FILE_PASS}" > "${WORK}/pass-file")
run rotate-profile-pass --out "${OUT}" --pass-file "${WORK}/pass-file"
[ "${RC}" -eq 0 ] && [ "$(cat "${ESCROW}")" = "${FILE_PASS}" ] && ok "(13) --pass-file supplies the passphrase (escrowed verbatim)" \
    || bad "(13) --pass-file not honored (rc=${RC})"
: > "${WORK}/empty-pass"
run rotate-profile-pass --out "${OUT}" --pass-file "${WORK}/empty-pass"
[ "${RC}" -eq 1 ] && ok "(13) empty --pass-file refused (exit 1, fail-closed)" || bad "(13) empty pass-file rc=${RC}, want 1"
run remove-profile --out "${OUT}"
[ "${RC}" -eq 2 ] && [ -e "${STATE}/user-created" ] \
    && ok "(13) remove-profile refuses on a non-TTY without --yes (user untouched)" \
    || bad "(13) remove-profile no-yes rc=${RC} (want 2, user intact)"
run remove-profile --out "${OUT}" --yes
[ "${RC}" -eq 0 ] && [ ! -e "${STATE}/user-created" ] && ok "(13) remove-profile --yes removes the user" \
    || bad "(13) remove --yes rc=${RC}"
compgen -G "${ESCROW}.revoked-*" >/dev/null && [ ! -e "${ESCROW}" ] \
    && ok "(13) escrow retired to .revoked-<ts> on removal" || bad "(13) escrow not retired on removal"
run profile --out "${OUT}"   # recreate for ingest (fresh escrow + user)
[ "${RC}" -eq 0 ] && ok "(13) profile re-creates cleanly after removal (re-entrant)" || bad "(13) recreate rc=${RC}"
GEN_PASS3="$(cat "${ESCROW}" 2>/dev/null)"

# ── (13) --i-understand-adb-exposure: credential-set-via-adb path ──────────
# The ONE deliberate secret-exposure branch in the whole custody model — must
# be exercised so a regression (flag parsing break, arg mis-order, default
# flip) cannot silently ship undetected.
run remove-profile --out "${OUT}" --yes
[ "${RC}" -eq 0 ] && ok "(13) remove-profile --yes clears state ahead of the adb-exposure case" \
    || bad "(13) pre-adb-exposure cleanup rc=${RC}"
run profile --out "${OUT}" --i-understand-adb-exposure
[ "${RC}" -eq 0 ] && ok "(13) profile --i-understand-adb-exposure exits 0" \
    || { bad "(13) adb-exposure profile rc=${RC}"; echo "${OUT_TXT}"; }
[ "$(jq -r '.set_via' "${PROF}")" = "adb" ] && ok "(13) profile.json records set_via=adb for the --i-understand-adb-exposure path" \
    || bad "(13) set_via '$(jq -r '.set_via' "${PROF}" 2>/dev/null)', want adb"
has "argv exposure accepted via --i-understand-adb-exposure" \
    && ok "(13) the adb-exposure info line is shown (documented, not silently swept)" \
    || bad "(13) missing the adb-exposure acknowledgement line"
ADB_EXPOSURE_PASS="$(cat "${ESCROW}" 2>/dev/null)"
grep -qF -- "${ADB_EXPOSURE_PASS}" "${LOGD}/adb.log" \
    && ok "(13) the escrowed passphrase DOES appear in adb.log for this one opt-in path (inverse of the secret sweep, scoped here only)" \
    || bad "(13) --i-understand-adb-exposure passphrase did NOT reach adb.log as documented"
run remove-profile --out "${OUT}" --yes
run profile --out "${OUT}"
[ "${RC}" -eq 0 ] && [ "$(jq -r '.set_via' "${PROF}")" = "operator" ] \
    && ok "(13) state restored to the default operator-set credential path after the adb-exposure case" \
    || bad "(13) adb-exposure state restore rc=${RC}, set_via='$(jq -r '.set_via' "${PROF}" 2>/dev/null)'"
GEN_PASS3="$(cat "${ESCROW}" 2>/dev/null)"

# ── (14) ingest + SECRET SWEEP ──────────────────────────────────────────────
run ingest --out "${OUT}"
[ "${RC}" -eq 1 ] && ok "(14) ingest without --device-id/--serial -> exit 1" || bad "(14) bare ingest rc=${RC}, want 1"
run ingest --device-id "${DEVID}" --out "${OUT}"
ING="${OUT}/device/${DEVID}/ingest.json"
[ "${RC}" -eq 0 ] && [ -f "${ING}" ] && ok "(14) ingest emits the record (exit 0)" || { bad "(14) ingest rc=${RC}"; echo "${OUT_TXT}"; }
[ "$(jq -r '.schema' "${ING}")" = "phone-ingest/v2" ] && [ "$(jq -r '.device_class' "${ING}")" = "phone" ] \
    && [ "$(jq -r '.os' "${ING}")" = "grapheneos" ] \
    && ok "(14) record is schema=phone-ingest/v2, device_class=phone, os=grapheneos" \
    || bad "(14) record schema fields wrong"
# No mdm-enroll has run at this point (group 22 is later), so the v2 mdm fold
# must report the NEGATIVE shape — enrolled:false with empty fields, mirroring
# enterprise_profile's presence contract, never a missing object.
[ "$(jq -r '.mdm.enrolled' "${ING}")" = "false" ] \
    && [ "$(jq -r '.mdm.dpc_package' "${ING}")" = "" ] \
    && [ "$(jq -r '.mdm.headwind_url' "${ING}")" = "" ] \
    && ok "(14) v2 mdm fold: negative shape (enrolled:false, empty fields) before any mdm-enroll" \
    || bad "(14) v2 mdm negative fold wrong: $(jq -c '.mdm' "${ING}" 2>/dev/null)"
[ "$(jq -r '.codename' "${ING}")" = "${CODENAME}" ] && [ "$(jq -r '.marketing_name' "${ING}")" = "Pixel 6" ] \
    && [ "$(jq -r '.serial' "${ING}")" = "${SERIAL_A}" ] && [ "$(jq -r '.tailscale_ip' "${ING}")" = "100.64.0.7" ] \
    && [ "$(jq -r '.role' "${ING}")" = "admin" ] \
    && ok "(14) record inherits enrollment facts (codename/name/serial/tailnet IP/role) with no --codename passed" \
    || bad "(14) record enrollment-fact inheritance wrong"
[ "$(jq -r '.enterprise_profile.present' "${ING}")" = "true" ] \
    && [ "$(jq -r '.enterprise_profile.user_id' "${ING}")" = "10" ] \
    && [ "$(jq -r '.enterprise_profile.credential_custody' "${ING}")" = "vault-seed" ] \
    && ok "(14) record carries the enterprise-profile presence + custody (never the secret)" \
    || bad "(14) enterprise_profile block wrong"
# An EXPLICIT --superdomain that happens to equal the compiled-in default
# string must still be honored over the enrollment record's (different)
# value -- not silently treated as "not passed" and overridden.
cp "${ENR}" "${ENR}.sdbak"
jq '.superdomain = "corp-a.internal"' "${ENR}" > "${ENR}.tmp" && mv "${ENR}.tmp" "${ENR}"
run ingest --device-id "${DEVID}" --out "${OUT}" --superdomain snapdragon.internal
[ "${RC}" -eq 0 ] && [ "$(jq -r '.superdomain' "${ING}")" = "snapdragon.internal" ] \
    && ok "(14) explicit --superdomain snapdragon.internal is honored over a differing enrollment-record value (not silently overridden)" \
    || bad "(14) explicit-superdomain-equals-default rc=${RC}, superdomain='$(jq -r '.superdomain' "${ING}" 2>/dev/null)'"
mv "${ENR}.sdbak" "${ENR}"
run ingest --device-id "${DEVID}" --out "${OUT}" --ingest-url https://registry.phone-test.invalid/self-report
[ "${RC}" -eq 2 ] && ok "(14) --ingest-url without mTLS identity -> exit 2 (fail-closed)" \
    || bad "(14) no-mTLS POST rc=${RC}, want 2"
printf 'dummy-cert\n' > "${WORK}/client.crt"; printf 'dummy-key\n' > "${WORK}/client.key"
clear_logs
run ingest --device-id "${DEVID}" --out "${OUT}" --ingest-url https://registry.phone-test.invalid/self-report \
    --client-cert "${WORK}/client.crt" --client-key "${WORK}/client.key" --ca "${WORK}/client.crt"
[ "${RC}" -eq 0 ] && grep -q 'CURL .*-X POST .*https://registry.phone-test.invalid/self-report' "${LOGD}/curl.log" \
    && grep -q -- "--data-binary @${ING}" "${LOGD}/curl.log" \
    && ok "(14) mTLS ingest POSTs the record through curl (stub-observed)" \
    || { bad "(14) ingest POST wrong (rc=${RC})"; cat "${LOGD}/curl.log"; }
# No token flag -> no X-Internal-Token header material at all.
grep -q -- "-H @" "${LOGD}/curl.log" && bad "(14) tokenless ingest sent a header file" \
    || ok "(14) tokenless ingest sends NO internal-token header (mTLS-only deployments unchanged)"

# --internal-token-file: the armed-prod internal gate. The token must reach curl
# via a 0600 header FILE (-H @file), never argv, and the file must not outlive
# the POST. ITOK_VALUE joins the secret sweep below.
ITOK_VALUE="itok-$(date +%s)-sweepable-internal-token"
printf '%s\n' "${ITOK_VALUE}" > "${WORK}/internal.token"
clear_logs
run ingest --device-id "${DEVID}" --out "${OUT}" --ingest-url https://registry.phone-test.invalid/self-report \
    --client-cert "${WORK}/client.crt" --client-key "${WORK}/client.key" --ca "${WORK}/client.crt" \
    --internal-token-file "${WORK}/internal.token"
HDRFILE="${OUT}/device/${DEVID}/.ingest-token-header"
[ "${RC}" -eq 0 ] && grep -q -- "-H @${HDRFILE}" "${LOGD}/curl.log" \
    && ok "(14) token ingest passes the header FILE to curl (-H @file, stub-observed)" \
    || { bad "(14) token ingest header-file wiring wrong (rc=${RC})"; cat "${LOGD}/curl.log"; }
grep -qF -- "${ITOK_VALUE}" "${LOGD}/curl.log" && bad "(14) INTERNAL TOKEN LEAKED onto curl argv" \
    || ok "(14) the token VALUE never appears on curl argv (rides the header file only)"
[ ! -f "${HDRFILE}" ] && ok "(14) the token header file is deleted after the POST" \
    || bad "(14) the token header file lingers at ${HDRFILE}"

# Fail-closed: a missing or empty token file is a precondition error (exit 2).
run ingest --device-id "${DEVID}" --out "${OUT}" --ingest-url https://registry.phone-test.invalid/self-report \
    --client-cert "${WORK}/client.crt" --client-key "${WORK}/client.key" --ca "${WORK}/client.crt" \
    --internal-token-file "${WORK}/no-such.token"
[ "${RC}" -eq 2 ] && ok "(14) --internal-token-file pointing nowhere -> exit 2 (fail-closed)" \
    || bad "(14) missing token file rc=${RC}, want 2"
: > "${WORK}/empty.token"
run ingest --device-id "${DEVID}" --out "${OUT}" --ingest-url https://registry.phone-test.invalid/self-report \
    --client-cert "${WORK}/client.crt" --client-key "${WORK}/client.key" --ca "${WORK}/client.crt" \
    --internal-token-file "${WORK}/empty.token"
[ "${RC}" -eq 2 ] && ok "(14) an EMPTY token file -> exit 2 (fail-closed, no blank header)" \
    || bad "(14) empty token file rc=${RC}, want 2"

# status is read-only and must also never leak secrets — capture into the sweep.
run status --device-id "${DEVID}" --out "${OUT}"
[ "${RC}" -eq 0 ] && has "escrow (${DEVID}): present" && ok "(14) status reports escrow PRESENCE (never contents)" \
    || bad "(14) status escrow line wrong (rc=${RC})"

# SECRET SWEEP: no secret value may appear in any default-path capture (stdout+
# stderr of every run() above) nor on any stub tool's argv log. The escrow files
# themselves (0600, under vault-seed/) are the ONLY sanctioned resting place.
SWEEP_TARGETS=("${SWEEP}" "${LOGD}/adb.log" "${LOGD}/fastboot.log" "${LOGD}/curl.log" "${LOGD}/flash-all.log")
LEAK=0
sweep_one() {  # $1 = label, $2 = secret value
    [ -n "$2" ] || return 0
    local t
    for t in "${SWEEP_TARGETS[@]}"; do
        if grep -qF -- "$2" "${t}" 2>/dev/null; then
            bad "(14) SECRET SWEEP: $1 leaked into $(basename "${t}")"
            LEAK=1
        fi
    done
}
sweep_one "tailscale pre-auth key" "${AUTHKEY_VALUE}"
sweep_one "generated passphrase #1" "${GEN_PASS1}"
sweep_one "generated passphrase #2" "${GEN_PASS2}"
sweep_one "generated passphrase #3" "${GEN_PASS3}"
sweep_one "--pass-file passphrase" "${FILE_PASS}"
sweep_one "internal ingest token" "${ITOK_VALUE}"
[ "${LEAK}" -eq 0 ] && ok "(14) SECRET SWEEP clean: no authkey/passphrase on stdout, stderr, or any stub argv" \
    || bad "(14) SECRET SWEEP found leaks (see above)"

# ── (15) enroll --no-usb (ADDENDUM 2026-07-16: guided handset-only path) ────
clear_logs
NOUSB_DEVID="phone-nousb-test"
run enroll --no-usb --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 1 ] && ok "(15) --no-usb without --device-id -> exit 1 (no adb serial to derive one)" \
    || bad "(15) --no-usb no-device-id rc=${RC}, want 1"
run enroll --no-usb --keys-dir "${KEYS}" --out "${OUT}" --device-id "${NOUSB_DEVID}"
[ "${RC}" -eq 1 ] && has "needs --codename" \
    && ok "(15) --no-usb with --device-id but no --codename -> exit 1 (no probe to read the model)" \
    || { bad "(15) --no-usb no-codename rc=${RC}, want 1"; echo "${OUT_TXT}"; }
run enroll --no-usb --keys-dir "${KEYS}" --out "${OUT}" --device-id "${NOUSB_DEVID}" --codename "${CODENAME}"
[ "${RC}" -eq 0 ] && has "no-USB guided handset runbook" && has "NEXT STEPS" \
    && ok "(15) --no-usb enroll exits 0 with the guided runbook + NEXT-STEPS block" \
    || { bad "(15) --no-usb enroll rc=${RC}"; echo "${OUT_TXT}"; }
[ ! -s "${LOGD}/adb.log" ] && ok "(15) --no-usb made ZERO adb calls (stub log stays empty)" \
    || { bad "(15) --no-usb touched adb"; cat "${LOGD}/adb.log"; }
! has "${AUTHKEY_VALUE}" && ok "(15) --no-usb: pre-auth key NOT shown without --show-authkey" \
    || bad "(15) --no-usb authkey LEAKED to output"
NOUSB_ENR="${OUT}/device/${NOUSB_DEVID}/enrollment.json"
[ -f "${NOUSB_ENR}" ] \
    && [ "$(jq -r '.verification' "${NOUSB_ENR}")" = "operator-attested" ] \
    && [ "$(jq -r '.tailscale_ip' "${NOUSB_ENR}")" = "null" ] \
    && [ "$(jq -r '.login_server' "${NOUSB_ENR}")" = "https://headscale.phone-test.invalid" ] \
    && [ "$(jq -r '.codename' "${NOUSB_ENR}")" = "${CODENAME}" ] \
    && ok "(15) --no-usb enrollment.json is verification:operator-attested, tailscale_ip:null, codename recorded" \
    || bad "(15) --no-usb enrollment.json missing/wrong"
# --show-authkey is the DELIBERATE disclosure path — captured OUTSIDE the sweep.
NOUSB_SHOWKEY_OUT="$(pw enroll --no-usb --keys-dir "${KEYS}" --out "${OUT}" --device-id "${NOUSB_DEVID}" --codename "${CODENAME}" --show-authkey)"
grep -qF -- "${AUTHKEY_VALUE}" <<<"${NOUSB_SHOWKEY_OUT}" \
    && ok "(15) --no-usb --show-authkey still displays the key once (explicit opt-in)" \
    || bad "(15) --no-usb --show-authkey did not display the key"
[ ! -s "${LOGD}/adb.log" ] && ok "(15) --no-usb --show-authkey run also made ZERO adb calls" \
    || bad "(15) --no-usb --show-authkey touched adb"

# ── (22) mdm-enroll (Phase 3: Headwind MDM device-owner enrollment) ────────
reset_state
rm -f "${STATE}/adb-getstate" "${STATE}/dpm-fail" "${STATE}/apksigner-digest"
printf 'List of devices attached\n%s             device usb:1-4\n' "${SERIAL_A}" > "${STATE}/adb-devices"
printf 'package:com.tailscale.ipn\npackage:com.hmdm.launcher\n' > "${STATE}/packages"
HEADWIND_URL_T="https://headwind.phone-test.invalid"
DIGEST_HW_OK="00112233445566778899aabbccddeeff0011223344556677889900aabbccdd"
DIGEST_HW_BAD="ffeeddccbbaa99887766554433221100ffeeddccbbaa998877665544332211"
printf '%s\n' "${DIGEST_HW_OK}" > "${STATE}/apksigner-digest"

clear_logs
run mdm-enroll --out "${OUT}" --headwind-url "${HEADWIND_URL_T}" --headwind-signer-sha256 "${DIGEST_HW_OK}"
[ "${RC}" -eq 0 ] && ok "(22) mdm-enroll on a FRESH device (1 user) exits 0" \
    || { bad "(22) mdm-enroll fresh-device rc=${RC}"; echo "${OUT_TXT}"; }
grep -q 'dpm set-device-owner com.hmdm.launcher/.AdminReceiver' "${LOGD}/adb.log" \
    && ok "(22) 'dpm set-device-owner com.hmdm.launcher/.AdminReceiver' appears in adb.log" \
    || { bad "(22) dpm set-device-owner call missing/wrong in adb.log"; cat "${LOGD}/adb.log"; }
MDM="${OUT}/device/${DEVID}/mdm.json"
[ -f "${MDM}" ] \
    && [ "$(jq -r '.device_id' "${MDM}")" = "${DEVID}" ] \
    && [ "$(jq -r '.serial' "${MDM}")" = "${SERIAL_A}" ] \
    && [ "$(jq -r '.dpc_package' "${MDM}")" = "com.hmdm.launcher" ] \
    && [ "$(jq -r '.headwind_url' "${MDM}")" = "${HEADWIND_URL_T}" ] \
    && [ "$(jq -r '.os' "${MDM}")" = "grapheneos" ] \
    && [ "$(jq -r '.set_via' "${MDM}")" = "adb-device-owner" ] \
    && ok "(22) mdm.json fields correct (device_id/serial/dpc_package/headwind_url/os/set_via)" \
    || bad "(22) mdm.json missing/wrong: $(cat "${MDM}" 2>/dev/null)"

# mdm-enroll must tell the operator the device is only a HINT until a SUPERADMIN
# confirms it managed — the spoof-proof trust boundary (self-report never makes
# a phone lockable). The NEXT STEP must name the management endpoint + mode.
printf '%s' "${OUT_TXT}" | grep -q 'SUPERADMIN must CONFIRM this device as managed' \
    && printf '%s' "${OUT_TXT}" | grep -q 'phone-devices/'"${DEVID}"'/management' \
    && printf '%s' "${OUT_TXT}" | grep -q 'mesh_owned' \
    && ok "(22) mdm-enroll prints the superadmin managed-confirmation NEXT STEP (trust boundary)" \
    || bad "(22) mdm-enroll NEXT STEP missing the managed-confirmation guidance"

# mdm-enroll must ALSO document the fleet-owner hand-off (enterprise subscription
# tier): a SUPERADMIN assigns physical_owner + owner_domain, grants ROLE_FLEET_ADMIN
# and the fleet_entitlement so a non-superadmin owner manages ONLY their own phones
# on the PUBLIC surface (owner+domain is the sole tenancy wall).
printf '%s' "${OUT_TXT}" | grep -q 'hand this device to a FLEET OWNER' \
    && printf '%s' "${OUT_TXT}" | grep -q 'phone-devices/'"${DEVID}"'/owner' \
    && printf '%s' "${OUT_TXT}" | grep -q 'ROLE_FLEET_ADMIN' \
    && printf '%s' "${OUT_TXT}" | grep -q 'fleet-entitlements/' \
    && ok "(22) mdm-enroll prints the fleet-owner provisioning NEXT STEP (owner+entitlement)" \
    || bad "(22) mdm-enroll NEXT STEP missing the fleet-owner provisioning guidance"

# NON-fresh device (2 users) -> refused (exit 2): device-owner mode is a
# one-shot AOSP gate, permanently foreclosed once a secondary user exists.
touch "${STATE}/user-created"
run mdm-enroll --out "${OUT}" --headwind-url "${HEADWIND_URL_T}" --headwind-signer-sha256 "${DIGEST_HW_OK}"
[ "${RC}" -eq 2 ] && has "device-owner mode is no longer obtainable" \
    && ok "(22) NON-fresh device (2 users) refused (exit 2, fail-closed one-shot AOSP gate)" \
    || bad "(22) non-fresh mdm-enroll rc=${RC}, want 2, out='${OUT_TXT}'"

# --force downgrades the precondition to a warning and proceeds anyway.
run mdm-enroll --out "${OUT}" --headwind-url "${HEADWIND_URL_T}" --headwind-signer-sha256 "${DIGEST_HW_OK}" --force
[ "${RC}" -eq 0 ] && has "continuing under --force" \
    && ok "(22) --force downgrades the NON-fresh precondition to a warning and proceeds (rc 0)" \
    || bad "(22) --force mdm-enroll rc=${RC}, want 0, out='${OUT_TXT}'"
rm -f "${STATE}/user-created"

# --headwind-signer-sha256 mismatch -> exit 3 (fail-closed supply-chain gate,
# same apksigner-verify helper --apk-signer-sha256/--auditor-signer-sha256 use).
run mdm-enroll --out "${OUT}" --headwind-url "${HEADWIND_URL_T}" --headwind-signer-sha256 "${DIGEST_HW_BAD}"
[ "${RC}" -eq 3 ] && has "signer digest MISMATCH" \
    && ok "(22) --headwind-signer-sha256 mismatch -> exit 3 (fail-closed)" \
    || bad "(22) headwind-signer-mismatch rc=${RC}, want 3, out='${OUT_TXT}'"
rm -f "${STATE}/apksigner-digest"

# With mdm.json now on disk, a re-ingest must fold it POSITIVELY into the v2
# record (the group-14 check proved the enrolled:false shape pre-mdm-enroll).
run ingest --device-id "${DEVID}" --out "${OUT}"
[ "${RC}" -eq 0 ] \
    && [ "$(jq -r '.mdm.enrolled' "${ING}")" = "true" ] \
    && [ "$(jq -r '.mdm.dpc_package' "${ING}")" = "com.hmdm.launcher" ] \
    && [ "$(jq -r '.mdm.headwind_url' "${ING}")" = "${HEADWIND_URL_T}" ] \
    && [ "$(jq -r '.mdm.set_via' "${ING}")" = "adb-device-owner" ] \
    && [ -n "$(jq -r '.mdm.enrolled_at // empty' "${ING}")" ] \
    && ok "(22) re-ingest folds mdm.json into the v2 record (enrolled/dpc/url/set_via/at)" \
    || bad "(22) v2 mdm positive fold wrong (rc=${RC}): $(jq -c '.mdm' "${ING}" 2>/dev/null)"

# ── (23) attest (Phase 3: self-hosted AttestationServer pairing via the
#      Snapdragon-forked Auditor) ──────────────────────────────────────────
reset_state
rm -f "${STATE}/adb-getstate" "${STATE}/apksigner-digest"
printf 'List of devices attached\n%s             device usb:1-4\n' "${SERIAL_A}" > "${STATE}/adb-devices"
printf 'package:com.tailscale.ipn\npackage:systems.snapdragon.auditor\n' > "${STATE}/packages"
ATTEST_URL_T="https://attest.phone-test.invalid"
DIGEST_AUD_OK="990e04f0864b19f14f84e0e432f7a393f297ab105a22c1e1b10b442a4a62c42"
DIGEST_AUD_BAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
printf '%s\n' "${DIGEST_AUD_OK}" > "${STATE}/apksigner-digest"

clear_logs
run attest --out "${OUT}" --attestation-url "${ATTEST_URL_T}" --auditor-signer-sha256 "${DIGEST_AUD_OK}"
[ "${RC}" -eq 0 ] && has "Auditor APK signer pin OK" \
    && ok "(23) attest (valid --auditor-signer-sha256 pin) exits 0" \
    || { bad "(23) attest rc=${RC}"; echo "${OUT_TXT}"; }
ATT="${OUT}/device/${DEVID}/attestation.json"
[ -f "${ATT}" ] \
    && [ "$(jq -r '.device_id' "${ATT}")" = "${DEVID}" ] \
    && [ "$(jq -r '.auditor_package' "${ATT}")" = "systems.snapdragon.auditor" ] \
    && [ "$(jq -r '.verdict' "${ATT}")" = "operator-paired" ] \
    && [ "$(jq -r '.attestation_url' "${ATT}")" = "${ATTEST_URL_T}" ] \
    && ok "(23) attestation.json: auditor_package=systems.snapdragon.auditor, verdict=operator-paired" \
    || bad "(23) attestation.json missing/wrong: $(cat "${ATT}" 2>/dev/null)"

# ingest folds the attestation fields in (advisory/logged, D9).
run ingest --device-id "${DEVID}" --out "${OUT}"
[ "${RC}" -eq 0 ] \
    && [ "$(jq -r '.auditor_package' "${ING}")" = "systems.snapdragon.auditor" ] \
    && [ "$(jq -r '.attestation_verdict' "${ING}")" = "operator-paired" ] \
    && [ "$(jq -r '.attestation_url' "${ING}")" = "${ATTEST_URL_T}" ] \
    && ok "(23) ingest folds the attestation fields in (auditor_package/attestation_verdict/attestation_url)" \
    || bad "(23) ingest attestation-fold missing/wrong: $(cat "${ING}" 2>/dev/null)"

# --auditor-signer-sha256 mismatch -> exit 3 (fail-closed).
run attest --out "${OUT}" --attestation-url "${ATTEST_URL_T}" --auditor-signer-sha256 "${DIGEST_AUD_BAD}"
[ "${RC}" -eq 3 ] && has "signer digest MISMATCH" \
    && ok "(23) --auditor-signer-sha256 mismatch -> exit 3 (fail-closed)" \
    || bad "(23) auditor-signer-mismatch rc=${RC}, want 3, out='${OUT_TXT}'"
rm -f "${STATE}/apksigner-digest"

# The authkey/secret sweep still passes after the attest + mdm-enroll runs
# above (neither verb handles a secret, but re-run the sweep so a regression
# that accidentally routed one through this new code cannot go undetected).
LEAK=0
sweep_one "tailscale pre-auth key (post attest/mdm-enroll)" "${AUTHKEY_VALUE}"
sweep_one "generated passphrase #1 (post attest/mdm-enroll)" "${GEN_PASS1}"
sweep_one "generated passphrase #3 (post attest/mdm-enroll)" "${GEN_PASS3}"
sweep_one "--pass-file passphrase (post attest/mdm-enroll)" "${FILE_PASS}"
[ "${LEAK}" -eq 0 ] && ok "(23) SECRET SWEEP still clean after the attest + mdm-enroll runs" \
    || bad "(23) SECRET SWEEP found a leak after attest/mdm-enroll (see above)"

# ── (24) wizard step ordering (STATIC: grep cmd_wizard's own source body —
#      no execution, no TTY needed) ─────────────────────────────────────────
WIZ_START="$(grep -n '^cmd_wizard()' "${DRIVER}" | head -n1 | cut -d: -f1)"
if [ -n "${WIZ_START}" ]; then
    WIZ_END="$(awk -v s="${WIZ_START}" 'NR>s && /^}/{print NR; exit}' "${DRIVER}")"
else
    bad "(24) cmd_wizard() not found in ${DRIVER}"
    WIZ_START=0; WIZ_END=0
fi
line_of() {  # $1 = grep -E pattern; first matching CODE line NUMBER within
             # cmd_wizard's body (or empty) — comment-only lines are
             # skipped, so a prose mention (e.g. "Mirrors cmd_flash's own
             # preflight..." in the front-loading comment, well before the
             # real Step 3 call) can never masquerade as the actual call.
    awk -v s="${WIZ_START}" -v e="${WIZ_END}" -v pat="$1" \
        'NR>=s && NR<=e {
             line=$0; sub(/^[ \t]+/, "", line);
             if (line ~ /^#/) next;
             if ($0 ~ pat) { print NR; exit }
         }' "${DRIVER}"
}

STEP_LABELS="$(sed -n "${WIZ_START},${WIZ_END}p" "${DRIVER}" | grep -oE 'Step [0-9]/8' | sort -u)"
EXPECTED_LABELS="$(printf 'Step %d/8\n' 1 2 3 4 5 6 7 8)"
[ "${STEP_LABELS}" = "${EXPECTED_LABELS}" ] \
    && ok "(24) cmd_wizard references exactly Step 1/8..8/8, no gaps/dup numbering" \
    || bad "(24) cmd_wizard step labels wrong: got '$(tr '\n' ',' <<<"${STEP_LABELS}")'"

L_DETECT="$(line_of 'cmd_detect')"
L_FETCH="$(line_of 'cmd_fetch')"
L_FLASH="$(line_of 'cmd_flash')"
L_ATTEST="$(line_of 'cmd_attest')"
L_MDM="$(line_of 'cmd_mdm_enroll')"
L_ENROLL="$(line_of 'cmd_enroll;')"
L_PROFILE="$(line_of 'cmd_profile;')"
L_INGEST="$(line_of 'cmd_ingest')"
if [ -n "${L_DETECT}" ] && [ -n "${L_FETCH}" ] && [ -n "${L_FLASH}" ] && [ -n "${L_ATTEST}" ] \
   && [ -n "${L_MDM}" ] && [ -n "${L_ENROLL}" ] && [ -n "${L_PROFILE}" ] && [ -n "${L_INGEST}" ] \
   && [ "${L_DETECT}" -lt "${L_FETCH}" ] && [ "${L_FETCH}" -lt "${L_FLASH}" ] \
   && [ "${L_FLASH}" -lt "${L_ATTEST}" ] && [ "${L_ATTEST}" -lt "${L_MDM}" ] \
   && [ "${L_MDM}" -lt "${L_ENROLL}" ] && [ "${L_ENROLL}" -lt "${L_PROFILE}" ] \
   && [ "${L_PROFILE}" -lt "${L_INGEST}" ]; then
    ok "(24) cmd_wizard calls are wired in the correct source order: detect < fetch < flash < attest < mdm-enroll < enroll < profile < ingest"
else
    bad "(24) cmd_wizard call order wrong (lines: detect=${L_DETECT:-?} fetch=${L_FETCH:-?} flash=${L_FLASH:-?} attest=${L_ATTEST:-?} mdm-enroll=${L_MDM:-?} enroll=${L_ENROLL:-?} profile=${L_PROFILE:-?} ingest=${L_INGEST:-?})"
fi
[ -n "${L_ATTEST}" ] && [ -n "${L_MDM}" ] && [ -n "${L_PROFILE}" ] \
    && [ "${L_ATTEST}" -lt "${L_PROFILE}" ] && [ "${L_MDM}" -lt "${L_PROFILE}" ] \
    && ok "(24) both attest and mdm-enroll are wired strictly before profile (the step that forecloses device-owner mode)" \
    || bad "(24) attest/mdm-enroll not both wired before profile (attest=${L_ATTEST:-?} mdm-enroll=${L_MDM:-?} profile=${L_PROFILE:-?})"

# ── (25) MDM provider selection (--mdm-provider headwind|azure-intune) ──────
# The wizard sources the MDM provider registry and branches mdm-enroll on the
# provider's MECHANISM (dpc-adb vs os-enrollment), never on a hard-coded id.
# Assert: the provider threads through plan; a bogus provider/intune-id is
# rejected; the azure-intune os-enrollment path prints the Intune RUNBOOK, makes
# ZERO adb calls, needs no --headwind-url, and lands mdm_provider +
# intune_device_id in mdm.json/ingest.json; and NO azure secret (tenant/client
# secret) is EVER accepted on argv or emitted (custody is server-side only).
clear_logs

# default provider is the sovereign one; plan surfaces it.
run plan --codename "${CODENAME}"
[ "$(plan_val MDM_PROVIDER)" = "headwind" ] && [ "$(plan_val MDM_MECHANISM)" = "dpc-adb" ] \
    && [ "$(plan_val MDM_SOVEREIGNTY)" = "sovereign" ] \
    && ok "(25) plan default: MDM provider=headwind, mechanism=dpc-adb, sovereignty=sovereign" \
    || bad "(25) plan default provider fields wrong (provider=$(plan_val MDM_PROVIDER), mech=$(plan_val MDM_MECHANISM))"

# azure-intune threads through plan (provider/mechanism/sovereignty + intune id).
run plan --codename "${CODENAME}" --mdm-provider azure-intune --intune-device-id abc-123
[ "$(plan_val MDM_PROVIDER)" = "azure-intune" ] && [ "$(plan_val MDM_MECHANISM)" = "os-enrollment" ] \
    && [ "$(plan_val MDM_SOVEREIGNTY)" = "cloud" ] && [ "$(plan_val INTUNE_DEVICE_ID)" = "abc-123" ] \
    && ok "(25) plan --mdm-provider azure-intune threads provider/mechanism/sovereignty/intune-id" \
    || bad "(25) azure plan threading wrong (provider=$(plan_val MDM_PROVIDER), mech=$(plan_val MDM_MECHANISM), sov=$(plan_val MDM_SOVEREIGNTY), id=$(plan_val INTUNE_DEVICE_ID))"

# plan mdm-enroll steps are mechanism-specific (os-enrollment runbook, not adb).
run plan mdm-enroll --mdm-provider azure-intune
[ "$(plan_val STEPS)" = "os-enrollment-runbook,record-intune-device-id" ] \
    && ok "(25) plan mdm-enroll (azure) lists os-enrollment steps (no adb dpm)" \
    || bad "(25) azure mdm-enroll plan steps '$(plan_val STEPS)'"
run plan mdm-enroll --mdm-provider headwind
[ "$(plan_val STEPS)" = "adb-sanity,fresh-device-precondition,dpc-install,set-device-owner,push-init-json,record" ] \
    && ok "(25) plan mdm-enroll (headwind) still lists the adb device-owner steps" \
    || bad "(25) headwind mdm-enroll plan steps '$(plan_val STEPS)'"

# validation: unknown provider + malformed intune id fail closed (exit 1).
run plan --codename "${CODENAME}" --mdm-provider not-a-provider
[ "${RC}" -eq 1 ] && has "must be one of" && ok "(25) unknown --mdm-provider -> exit 1 (validated vs the registry)" \
    || bad "(25) unknown provider rc=${RC}, want 1"
run plan --codename "${CODENAME}" --mdm-provider azure-intune --intune-device-id 'bad id!'
[ "${RC}" -eq 1 ] && has "invalid --intune-device-id" && ok "(25) malformed --intune-device-id -> exit 1" \
    || bad "(25) bad intune id rc=${RC}, want 1"

# azure-intune mdm-enroll (os-enrollment): runbook path, ZERO adb, no --headwind-url.
reset_state; clear_logs
AZ_DEVID="phone-az-test"
AZ_INTUNE_ID="12345678-90ab-cdef-1234-567890abcdef"
run mdm-enroll --mdm-provider azure-intune --out "${OUT}"
[ "${RC}" -eq 1 ] && has "needs --device-id" \
    && ok "(25) azure mdm-enroll without --device-id -> exit 1 (OS-level, no adb serial)" \
    || bad "(25) azure mdm-enroll no-device-id rc=${RC}, want 1"
run mdm-enroll --mdm-provider azure-intune --out "${OUT}" --device-id "${AZ_DEVID}" --intune-device-id "${AZ_INTUNE_ID}"
[ "${RC}" -eq 0 ] && ok "(25) azure mdm-enroll exits 0 (no --headwind-url required)" \
    || { bad "(25) azure mdm-enroll rc=${RC}"; echo "${OUT_TXT}"; }
[ ! -s "${LOGD}/adb.log" ] && ok "(25) azure mdm-enroll made ZERO adb calls (os-enrollment, stub log empty)" \
    || { bad "(25) azure mdm-enroll touched adb"; cat "${LOGD}/adb.log"; }
has "remoteLock" && has "UNLOCK ASYMMETRY" && has "NOT over adb" \
    && ok "(25) azure mdm-enroll prints the Intune runbook (remoteLock + unlock asymmetry + os-level)" \
    || bad "(25) azure mdm-enroll runbook incomplete"
has "SUPERADMIN must CONFIRM this device as managed" \
    && ok "(25) azure mdm-enroll still prints the superadmin managed-confirmation NEXT STEP (trust boundary)" \
    || bad "(25) azure mdm-enroll missing the managed-confirmation guidance"
AZ_MDM="${OUT}/device/${AZ_DEVID}/mdm.json"
[ -f "${AZ_MDM}" ] \
    && [ "$(jq -r '.mdm_provider' "${AZ_MDM}")" = "azure-intune" ] \
    && [ "$(jq -r '.intune_device_id' "${AZ_MDM}")" = "${AZ_INTUNE_ID}" ] \
    && [ "$(jq -r '.set_via' "${AZ_MDM}")" = "intune-os-enrollment" ] \
    && [ "$(jq -r '.dpc_package' "${AZ_MDM}")" = "" ] \
    && ok "(25) azure mdm.json: mdm_provider=azure-intune, intune_device_id set, set_via=intune-os-enrollment, no DPC" \
    || bad "(25) azure mdm.json wrong: $(cat "${AZ_MDM}" 2>/dev/null)"

# ingest folds the azure provider fields (top-level device-reported + nested).
AZ_ING="${OUT}/device/${AZ_DEVID}/ingest.json"
run ingest --device-id "${AZ_DEVID}" --codename "${CODENAME}" --out "${OUT}"
[ "${RC}" -eq 0 ] \
    && [ "$(jq -r '.mdm_provider' "${AZ_ING}")" = "azure-intune" ] \
    && [ "$(jq -r '.intune_device_id' "${AZ_ING}")" = "${AZ_INTUNE_ID}" ] \
    && [ "$(jq -r '.mdm.provider' "${AZ_ING}")" = "azure-intune" ] \
    && [ "$(jq -r '.mdm.set_via' "${AZ_ING}")" = "intune-os-enrollment" ] \
    && ok "(25) ingest folds azure fields: top-level mdm_provider/intune_device_id + nested mdm.provider" \
    || bad "(25) azure ingest fold wrong: $(jq -c '{mdm_provider,intune_device_id,mdm}' "${AZ_ING}" 2>/dev/null)"

# a headwind device's ingest reports mdm_provider=headwind at top level (backfill
# default) — build a fresh headwind mdm.json and confirm the default lands.
HW_DEVID="phone-hw-prov-test"
HW_REC="${OUT}/device/${HW_DEVID}"; mkdir -p "${HW_REC}"
printf '{"mdm_provider":"headwind","dpc_package":"com.hmdm.launcher","headwind_url":"https://hw.invalid","set_via":"adb-device-owner","enrolled_at":"2026-07-22T00:00:00Z","intune_device_id":""}' > "${HW_REC}/mdm.json"
run ingest --device-id "${HW_DEVID}" --codename "${CODENAME}" --out "${OUT}"
HW_ING="${HW_REC}/ingest.json"
[ "${RC}" -eq 0 ] && [ "$(jq -r '.mdm_provider' "${HW_ING}")" = "headwind" ] \
    && [ "$(jq -r '.intune_device_id' "${HW_ING}")" = "" ] \
    && ok "(25) a headwind device's ingest carries top-level mdm_provider=headwind, empty intune_device_id" \
    || bad "(25) headwind ingest provider fold wrong: $(jq -c '{mdm_provider,intune_device_id}' "${HW_ING}" 2>/dev/null)"

# STRUCTURAL secret hygiene: the wizard exposes NO flag that accepts an azure
# tenant/client secret on argv (custody is server-side only, admin-bff env). The
# only azure-specific input is --intune-device-id, which is a device id, not a
# secret. Prove no such secret flag exists in the driver source.
if grep -Eq -- '--(tenant|client-secret|azure-secret|graph-secret|intune-secret)' "${DRIVER}"; then
    bad "(25) SECRET HYGIENE: the wizard exposes an azure tenant/client-secret flag on argv"
else
    ok "(25) SECRET HYGIENE: the wizard has NO azure tenant/client-secret argv flag (custody is server-side only)"
fi

echo
echo "== phone-wizard test: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
