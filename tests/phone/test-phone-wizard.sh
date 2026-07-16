#!/usr/bin/env bash
# test-phone-wizard.sh — offline logic test for the enterprise-phone wizard
# driver (scripts/phone-wizard.sh): GrapheneOS Pixel onboarding — detect ->
# fetch (verified) -> flash -> enroll -> profile -> ingest.
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
#   (12) enroll: no login server -> 1; non-GrapheneOS device -> 2 (--force
#        downgrades); tailnet join verified from stub tailscale0 addr;
#        enrollment.json fields; authkey NEVER shown without --show-authkey.
#   (13) profile lifecycle: escrow 0600/0700 + passphrase shape; duplicate -> 2;
#        rotate keeps .prev-<ts>; --pass-file honored, empty -> 1; remove
#        refuses non-TTY without --yes, --yes retires escrow to .revoked-<ts>.
#   (14) ingest + SECRET SWEEP: phone-ingest/v1 record fields; POST without
#        mTLS identity -> 2 (fail-closed); POST goes through curl with the
#        record; then a sweep proving NO secret (authkey, any escrowed or
#        supplied passphrase) ever appeared on stdout/stderr or any stub argv.
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

echo "== enterprise-phone wizard: offline driver test (stub tools + REAL sshsig crypto) =="

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
    reboot|install|pull) exit 0 ;;
    shell)
        shift
        case "$*" in
            'getprop ro.product.device')            cat "${S}/codename" 2>/dev/null || echo oriole ;;
            'getprop ro.build.version.incremental') cat "${S}/incremental" 2>/dev/null || echo 2026071500 ;;
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
            'ip -o addr show dev tailscale0')
                cat "${S}/tailscale-addr" 2>/dev/null \
                    || printf '30: tailscale0    inet 100.64.0.7/32 scope global tailscale0\n' ;;
            'dumpsys lock_settings'|'locksettings set-password '*) : ;;
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
            unlocked) echo 'unlocked: yes' >&2 ;;
        esac
        exit 0 ;;
    flashing)  exit 0 ;;
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
chmod +x "${BIN}/adb" "${BIN}/fastboot" "${BIN}/curl"

reset_state() {
    printf 'List of devices attached\n' > "${STATE}/adb-devices"
    : > "${STATE}/fb-devices"
    printf 'fastboot version 35.0.2-android\n' > "${STATE}/fb-version"
    printf '%s\n' "${CODENAME}" > "${STATE}/codename"
    printf '2026071500\n' > "${STATE}/incremental"
    printf '[ro.gos]: [grapheneos]\n' > "${STATE}/getprop-dump"
    printf 'package:com.tailscale.ipn\n' > "${STATE}/packages"
    rm -f "${STATE}/user-created" "${STATE}/tailscale-addr" "${STATE}/adb-getstate"
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
[ "$(plan_val STEPS)" = "detect,fetch,flash,enroll,profile,ingest" ] \
    && ok "(2) plan (default wizard target) lists the full step chain" || bad "(2) plan steps '$(plan_val STEPS)'"
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

# ── (12) enroll ──────────────────────────────────────────────────────────────
reset_state
printf 'List of devices attached\n%s             device usb:1-4\n' "${SERIAL_A}" > "${STATE}/adb-devices"
run enroll --out "${OUT}"
[ "${RC}" -eq 1 ] && ok "(12) enroll without a login server -> exit 1" || bad "(12) no-login-server rc=${RC}, want 1"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 0 ] && ok "(12) enroll (stub adb, GrapheneOS probe + tailnet join) exits 0" || { bad "(12) enroll rc=${RC}"; echo "${OUT_TXT}"; }
has "https://headscale.phone-test.invalid" && ok "(12) join runbook names the headscale login server" \
    || bad "(12) runbook missing the login server"
has "tailnet join VERIFIED: 100.64.0.7" && ok "(12) tailnet join verified from the stub tailscale0 CGNAT address" \
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
    && ok "(12) enrollment.json carries serial/codename/tailscale_ip/role/login_server" \
    || bad "(12) enrollment.json missing/wrong"
# --show-authkey is the DELIBERATE disclosure path — captured OUTSIDE the sweep.
SHOWKEY_OUT="$(pw enroll --keys-dir "${KEYS}" --out "${OUT}" --show-authkey)"
grep -qF -- "${AUTHKEY_VALUE}" <<<"${SHOWKEY_OUT}" && ok "(12) --show-authkey displays the key once (explicit opt-in)" \
    || bad "(12) --show-authkey did not display the key"
printf 'eng.userdebug.1\n' > "${STATE}/incremental"
printf '[ro.build.flavor]: [aosp]\n' > "${STATE}/getprop-dump"
run enroll --keys-dir "${KEYS}" --out "${OUT}"
[ "${RC}" -eq 2 ] && has "does not look like GrapheneOS" \
    && ok "(12) non-GrapheneOS device refused (exit 2, fail-closed sanity probe)" \
    || bad "(12) non-GOS rc=${RC}, want 2"
run enroll --keys-dir "${KEYS}" --out "${OUT}" --force
[ "${RC}" -eq 0 ] && ok "(12) --force downgrades the GrapheneOS probe to a warning" || bad "(12) --force enroll rc=${RC}"
printf '2026071500\n' > "${STATE}/incremental"
printf '[ro.gos]: [grapheneos]\n' > "${STATE}/getprop-dump"

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

# ── (14) ingest + SECRET SWEEP ──────────────────────────────────────────────
run ingest --out "${OUT}"
[ "${RC}" -eq 1 ] && ok "(14) ingest without --device-id/--serial -> exit 1" || bad "(14) bare ingest rc=${RC}, want 1"
run ingest --device-id "${DEVID}" --out "${OUT}"
ING="${OUT}/device/${DEVID}/ingest.json"
[ "${RC}" -eq 0 ] && [ -f "${ING}" ] && ok "(14) ingest emits the record (exit 0)" || { bad "(14) ingest rc=${RC}"; echo "${OUT_TXT}"; }
[ "$(jq -r '.schema' "${ING}")" = "phone-ingest/v1" ] && [ "$(jq -r '.device_class' "${ING}")" = "phone" ] \
    && [ "$(jq -r '.os' "${ING}")" = "grapheneos" ] \
    && ok "(14) record is schema=phone-ingest/v1, device_class=phone, os=grapheneos" \
    || bad "(14) record schema fields wrong"
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
[ "${LEAK}" -eq 0 ] && ok "(14) SECRET SWEEP clean: no authkey/passphrase on stdout, stderr, or any stub argv" \
    || bad "(14) SECRET SWEEP found leaks (see above)"

echo
echo "== phone-wizard test: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
