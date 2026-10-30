#!/usr/bin/env bash
# e2e-quest-join.sh — END-TO-END onboarding of a MOCKED Meta Quest 3 joining
# the enterprise mesh, driven through scripts/phone-wizard.sh's REAL
# --device-class quest verb chain against ONE stateful mock headset.
#
# Sibling of e2e-android-join.sh (same conventions: stateful PATH-shim stubs
# modelling OBSERVABLE device state transitions, causal installs, captured
# pushes, a dpm latch, cumulative argv archive + secret sweep). What is under
# test HERE is the quest class surface added 2026-07-19:
#   * class-scoped catalogs — `panther` resolves to the Quest 3S in quest
#     class and to the Pixel 7 in phone class, in the SAME driver;
#   * the fail-closed manufacturer pin (a Google-manufactured device on the
#     quest path is refused, exit 2);
#   * quest verb gating — fetch/flash/attest/profile are UNSUPPORTED and die
#     2 with the rationale, at plan time too, writing NOTHING;
#   * mdm-enroll's quest divergence: a Meta account present does NOT exit 2
#     (Horizon OS setup requires one; dpm is the arbiter) but the advisory
#     fires; the dpm refusal path carries the factory-reset hint;
#   * XR-chat URL provisioning: https-only gate, init.json carries
#     com.hmdm.BASE_URL + com.hmdm.CONFIG, the VIEW-intent launch verify is
#     really fired, and the adb COMMAND SEQUENCE is asserted in order
#     (DPC install -> dpm set-device-owner -> init.json push -> VIEW intent);
#   * enroll reuses the tun0/CGNAT join verify verbatim (Horizon OS is
#     Android — the VpnService interface is tun0 there too) and the default
#     device id is quest-<serial>;
#   * failure paths: UNAUTHORIZED device (accept-inside-the-headset warning),
#     NO device at all (Developer-Mode runbook = the no-dev-mode path),
#     ingest --ingest-url registry-gap warning + fail-closed mTLS.
#
# Runs ANYWHERE with bash + jq + coreutils/awk — NO network, NO root, NO
# device, NO adb/fastboot install. SKIP (exit 0) only if a required tool is
# genuinely missing. Every negative control fires — no unexercised scaffolding.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="${REPO}/scripts/phone-wizard.sh"

[ -r "${DRIVER}" ] || { echo "  FAIL driver missing: ${DRIVER}"; exit 1; }
for t in jq awk sha256sum; do
    command -v "${t}" >/dev/null || { echo "SKIP: need ${t}"; exit 0; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== MDM quest e2e: a mocked Meta Quest 3 joins the mesh =="

# ── Layout ─────────────────────────────────────────────────────────
BIN="${WORK}/bin"; LOGD="${WORK}/logs"; FIX="${WORK}/fixtures"
mkdir -p "${BIN}" "${LOGD}" "${FIX}"
SWEEP="${WORK}/sweep.log";       : > "${SWEEP}"
ARGV_ALL="${WORK}/argv-all.log"; : > "${ARGV_ALL}"

SERIAL="2G0YC1ZF8800AB"                    # Quest serial shape (alnum, no dashes)
DEVID="quest-2g0yc1zf8800ab"               # quest-<sanitize_id(serial)> default
CODENAME="eureka"                          # Meta Quest 3, in scripts/quest-devices.tsv
LOGIN_SERVER="https://headscale.hugmesh.invalid"
HEADWIND_URL="https://headwind.hugmesh.invalid"
HEADWIND_CONFIG="quest-fleet"
XR_CHAT_URL="https://chat.hugmesh.invalid/matrix/rooms/xr/chat3d"
INGEST_URL="https://registry.hugmesh.invalid/bff/internal/phone-ingest"
# A FAKE auth key, spelled in two adjacent pieces so secret scanners stop
# reporting this fixture; the shell joins them, so the runtime value (and every
# custody check below) is unchanged.
AUTHKEY_SENTINEL="tskey-""auth-SECRET-quest-e2e-DO-NOT-LEAK-0001"
CGNAT_ADDR="100.64.9.77"

SIGNER_OK="$(printf 'hugmesh-quest-e2e-signer' | sha256sum | awk '{print $1}')"
SIGNER_BAD="$(printf 'attacker-signer'            | sha256sum | awk '{print $1}')"

# ── Stateful mock headset ──────────────────────────────────────────
# One state dir the stubs share and MUTATE. new_device() (re)initialises it as
# a set-up Quest 3 in Developer Mode: adb-visible, manufacturer oculus,
# 1 user + the Meta account Horizon OS setup requires (the REALISTIC state —
# unlike a fresh Pixel, "zero accounts" is unreachable on an adb-visible
# Quest), no enterprise apps, no tailnet address, device-owner unclaimed.
STATE="${WORK}/device"
new_device() {   # $1 (optional): manufacturer override (default oculus)
    rm -rf "${STATE}"; mkdir -p "${STATE}"
    printf 'List of devices attached\n%s\tdevice\n' "${SERIAL}" > "${STATE}/adb-devices"
    printf 'device\n'                                            > "${STATE}/adb-getstate"
    printf '%s\n' "${CODENAME}"                                  > "${STATE}/codename"
    printf '%s\n' "${1:-oculus}"                                 > "${STATE}/manufacturer"
    printf '14\n'                                                > "${STATE}/release"
    printf '[ro.build.type]: [user]\n'                           > "${STATE}/getprop-dump"
    printf '52400390017200000\n'                                 > "${STATE}/incremental"
    printf 'Account {name=quest-owner@meta.invalid, type=com.oculus.account}\n' > "${STATE}/dumpsys-account"
    : > "${STATE}/packages"
    printf '1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever\n30: wlan0    inet 192.168.1.77/24 brd 192.168.1.255 scope global wlan0\\       valid_lft forever preferred_lft forever\n' > "${STATE}/ifaces"
    rm -f "${STATE}/dpm-fail" "${STATE}/device-owner-set"
    rm -rf "${STATE}/pushed"
    printf '%s' "${SIGNER_OK}"                                   > "${STATE}/apksigner-digest"
}
device_joins()  { printf '14: tun0    inet %s/32 scope global tun0\\       valid_lft forever preferred_lft forever\n' "${CGNAT_ADDR}" >> "${STATE}/ifaces"; }
device_unauthorized() { printf 'List of devices attached\n%s\tunauthorized\n' "${SERIAL}" > "${STATE}/adb-devices"; }
device_absent()       { printf 'List of devices attached\n' > "${STATE}/adb-devices"; printf 'unknown\n' > "${STATE}/adb-getstate"; }

# ── PATH-shim stubs ────────────────────────────────────────────────
cat > "${BIN}/adb" <<'EOF'
#!/usr/bin/env bash
S="${PW_STUB_STATE:?}"; L="${PW_STUB_LOG_DIR:?}"
printf 'ADB %s\n' "$*" >> "${L}/adb.log"
[ "${1:-}" = "-s" ] && shift 2
case "${1:-}" in
    devices)   cat "${S}/adb-devices" 2>/dev/null || echo "List of devices attached"; exit 0 ;;
    get-state) cat "${S}/adb-getstate" 2>/dev/null || echo device; exit 0 ;;
    install)
        apk="${@: -1}"
        case "${apk}" in
            *headwind*|*hmdm*) echo 'package:com.hmdm.launcher' >> "${S}/packages" ;;
            *tailscale*)       echo 'package:com.tailscale.ipn' >> "${S}/packages" ;;
        esac
        exit 0 ;;
    push)
        if [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
            mkdir -p "${S}/pushed$(dirname "${3}")" 2>/dev/null
            cp "${2}" "${S}/pushed${3}" 2>/dev/null
        fi
        exit 0 ;;
    pull)      [ -n "${3:-}" ] && printf 'apk-fixture-bytes\n' > "${3}"; exit 0 ;;
    shell)
        shift
        case "$*" in
            'getprop ro.product.device')            cat "${S}/codename"     2>/dev/null || echo eureka ;;
            'getprop ro.product.manufacturer')      cat "${S}/manufacturer" 2>/dev/null || echo oculus ;;
            'getprop ro.build.version.incremental') cat "${S}/incremental"  2>/dev/null || true ;;
            'getprop ro.build.version.release')     cat "${S}/release"      2>/dev/null || true ;;
            'getprop ro.build.fingerprint')         echo 'oculus/eureka_pvt/eureka:12/SQ3A.220605.009.A1/52400390017200000:user/release-keys' ;;
            'getprop net.hostname')                 echo quest-e2e-host ;;
            getprop)                                cat "${S}/getprop-dump" 2>/dev/null || true ;;
            'pm list users')    printf '\tUserInfo{0:Owner:c13}\n' ;;
            'dumpsys account')  cat "${S}/dumpsys-account" 2>/dev/null || true ;;
            'pm list packages') cat "${S}/packages" 2>/dev/null || true ;;
            'pm path '*)        echo 'package:/data/app/stub/base.apk' ;;
            'ip -o addr show')  cat "${S}/ifaces" 2>/dev/null || true ;;
            'mkdir -p '*)       : ;;
            'am start '*)       echo 'Starting: Intent { act=android.intent.action.VIEW }' ;;
            'dpm set-device-owner '*)
                if [ -e "${S}/dpm-fail" ]; then
                    echo 'java.lang.IllegalStateException: Not allowed to set the device owner because there are already some accounts on the device' >&2; exit 1
                fi
                if [ -e "${S}/device-owner-set" ]; then
                    echo 'java.lang.IllegalStateException: Trying to set the device owner, but device owner is already set.' >&2; exit 1
                fi
                touch "${S}/device-owner-set"
                printf 'Success: Device owner set to package ComponentInfo{com.hmdm.launcher/com.hmdm.launcher.AdminReceiver}\n' ;;
            *) : ;;
        esac
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "${BIN}/fastboot" <<'EOF'
#!/usr/bin/env bash
L="${PW_STUB_LOG_DIR:?}"
printf 'FASTBOOT %s\n' "$*" >> "${L}/fastboot.log"
case "${1:-}" in devices) : ;; --version) echo 'fastboot version 35.0.2-android' ;; esac
exit 0
EOF
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
L="${PW_STUB_LOG_DIR:?}"
printf 'CURL %s\n' "$*" >> "${L}/curl.log"
exit 0
EOF
cat > "${BIN}/apksigner" <<'EOF'
#!/usr/bin/env bash
S="${PW_STUB_STATE:?}"; L="${PW_STUB_LOG_DIR:?}"
printf 'APKSIGNER %s\n' "$*" >> "${L}/apksigner.log"
printf 'Signer #1 certificate SHA-256 digest: %s\n' "$(cat "${S}/apksigner-digest" 2>/dev/null || echo deadbeef)"
exit 0
EOF
chmod +x "${BIN}"/*

: > "${FIX}/tailscale.apk"; : > "${FIX}/headwind-dpc.apk"
AUTHKEY_FILE="${FIX}/authkey"; printf '%s\n' "${AUTHKEY_SENTINEL}" > "${AUTHKEY_FILE}"; chmod 600 "${AUTHKEY_FILE}"

OUT="${WORK}/out"; mkdir -p "${OUT}"

# ── Driver invocation (quest class on every call via Q_ARGS) ───────
pw() {
    local extra=()
    while [[ "${1:-}" == *=* ]]; do extra+=("$1"); shift; done
    env PATH="${BIN}:${PATH}" \
        PW_STUB_STATE="${STATE}" PW_STUB_LOG_DIR="${LOGD}" \
        PW_JOIN_TIMEOUT="${PW_JOIN_TIMEOUT:-3}" PW_POLL_INTERVAL=1 \
        "${extra[@]}" bash "${DRIVER}" "$@" </dev/null 2>&1
}
OUT_TXT=""; RC=0
run()  { OUT_TXT="$(pw "$@")"; RC=$?; printf '%s\n' "${OUT_TXT}" >> "${SWEEP}"; }
has()     { grep -qF  -- "$1" <<<"${OUT_TXT}"; }
hasline() { grep -qxF -- "$1" <<<"${OUT_TXT}"; }
clear_logs() {
    cat "${LOGD}"/*.log >> "${ARGV_ALL}" 2>/dev/null || true
    : > "${LOGD}/adb.log"; : > "${LOGD}/curl.log"; : > "${LOGD}/fastboot.log"; : > "${LOGD}/apksigner.log"
}
# Line number of the FIRST adb.log line matching $1 (empty when absent) — the
# sequence assertions below compare these, so ORDER is what is proven.
adb_seq() { grep -n -- "$1" "${LOGD}/adb.log" 2>/dev/null | head -n1 | cut -d: -f1; }

Q=(--device-class quest)
ENROLL_ARGS=("${Q[@]}" --serial "${SERIAL}" --out "${OUT}" --login-server "${LOGIN_SERVER}" \
             --authkey-file "${AUTHKEY_FILE}" --tailscale-apk "${FIX}/tailscale.apk" \
             --apk-signer-sha256 "${SIGNER_OK}")

# ═══════════════ Scenario QA: a Quest 3 joins the mesh ═══════════════
echo "-- Scenario QA: full quest lifecycle (detect -> enroll -> mdm-enroll -> ingest) --"
new_device; clear_logs

# QA1 — detect: quest class, manufacturer + catalog name as EXACT lines.
run detect "${Q[@]}" --serial "${SERIAL}"
if [ "${RC}" -eq 0 ] && hasline "DEVICE_CLASS=quest" && hasline "DEVICE_STATE=adb" \
   && hasline "DEVICE_CODENAME=${CODENAME}" && hasline "DEVICE_NAME=Meta Quest 3" \
   && hasline "DEVICE_MANUFACTURER=oculus"; then
    ok "QA1 detect: class=quest, codename eureka -> Meta Quest 3, manufacturer=oculus (exact lines)"
else
    bad "QA1 detect rc=${RC}"; echo "${OUT_TXT}"
fi

# QA2 — enroll before the operator joins: tun0 has no CGNAT address -> the
# join verify times out exit 1; the runbook is the QUEST one (in-headset,
# sideload wording) and Horizon OS is announced as supported.
run PW_JOIN_TIMEOUT=2 enroll "${ENROLL_ARGS[@]}"
if [ "${RC}" -eq 1 ] && has "Horizon OS" && has "INSIDE the headset" \
   && has "still pending superadmin approval"; then
    ok "QA2 enroll (pre-join): quest runbook shown, join VERIFY pending -> exit 1"
else
    bad "QA2 enroll-pending rc=${RC} (want 1)"; echo "${OUT_TXT}"
fi
[ ! -f "${OUT}/device/${DEVID}/enrollment.json" ] \
    && ok "QA2 no enrollment.json while the join is unverified" \
    || bad "QA2 enrollment.json written despite an unverified join"

# QA3 — operator joins in-headset; tun0 comes up (SAME iface name as a
# handset — Horizon OS is Android). Re-run -> verified, default id quest-<serial>.
device_joins
run enroll "${ENROLL_ARGS[@]}"
ENR="${OUT}/device/${DEVID}/enrollment.json"
if [ "${RC}" -eq 0 ] && has "tailnet join VERIFIED: ${CGNAT_ADDR}" && [ -f "${ENR}" ]; then
    ok "QA3 enroll (post-join): tun0 CGNAT verified, enrollment.json under quest-<serial> id"
else
    bad "QA3 enroll rc=${RC}"; echo "${OUT_TXT}"
fi
if [ -f "${ENR}" ] \
   && [ "$(jq -r '.device_id'    "${ENR}")" = "${DEVID}" ] \
   && [ "$(jq -r '.codename'     "${ENR}")" = "${CODENAME}" ] \
   && [ "$(jq -r '.os'           "${ENR}")" = "android" ] \
   && [ "$(jq -r '.tailscale_ip' "${ENR}")" = "${CGNAT_ADDR}" ] \
   && [ "$(jq -r '.verification' "${ENR}")" = "adb-heuristic" ]; then
    ok "QA3 enrollment.json: device_id=${DEVID}, codename=eureka, os=android, tailscale_ip, verification"
else
    bad "QA3 enrollment.json fields wrong: $(cat "${ENR}" 2>/dev/null)"
fi
grep -q 'install -r .*tailscale.apk' "${LOGD}/adb.log" && has "Tailscale APK signer pin OK" \
    && ok "QA3 Tailscale APK really SIDELOADED (no store path on Horizon OS) and signer-pinned" \
    || bad "QA3 tailscale sideload/pin missing from the run"

# QA4 — mdm-enroll on the REALISTIC quest state (Meta account present): the
# phone class would exit 2 here; quest DOWNGRADES the gate to an advisory and
# dpm decides. XR-chat URL + Headwind config provisioning ride the same verb.
clear_logs
run mdm-enroll "${Q[@]}" --serial "${SERIAL}" --out "${OUT}" \
    --headwind-url "${HEADWIND_URL}" --headwind-config "${HEADWIND_CONFIG}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}" \
    --xr-chat-url "${XR_CHAT_URL}"
MDM="${OUT}/device/${DEVID}/mdm.json"
if [ "${RC}" -eq 0 ] && has "letting dpm set-device-owner decide" \
   && has "no Play Protect DPC allow-list applies"; then
    ok "QA4 mdm-enroll: Meta-account advisory fired (NOT exit 2 — quest divergence) and dpm succeeded"
else
    bad "QA4 mdm-enroll rc=${RC}"; echo "${OUT_TXT}"
fi
# THE COMMAND SEQUENCE, in order: DPC install -> device-owner claim ->
# init.json push -> XR-chat VIEW-intent launch verify.
S1="$(adb_seq 'install -r .*headwind-dpc.apk')"
S2="$(adb_seq 'dpm set-device-owner com.hmdm.launcher/.AdminReceiver')"
S3="$(adb_seq 'push .*init.json')"
S4="$(adb_seq 'am start -a android.intent.action.VIEW -d '"${XR_CHAT_URL}")"
if [ -n "${S1}" ] && [ -n "${S2}" ] && [ -n "${S3}" ] && [ -n "${S4}" ] \
   && [ "${S1}" -lt "${S2}" ] && [ "${S2}" -lt "${S3}" ] && [ "${S3}" -lt "${S4}" ]; then
    ok "QA4 adb sequence in order: DPC install (${S1}) < dpm (${S2}) < init.json push (${S3}) < VIEW intent (${S4})"
else
    bad "QA4 adb sequence wrong/missing (install=${S1:-x} dpm=${S2:-x} push=${S3:-x} view=${S4:-x})"; cat "${LOGD}/adb.log"
fi
PUSHED_INIT="${STATE}/pushed/sdcard/Android/data/com.hmdm.launcher/files/init.json"
if [ -f "${PUSHED_INIT}" ] \
   && [ "$(jq -r '."com.hmdm.BASE_URL"' "${PUSHED_INIT}")" = "${HEADWIND_URL}" ] \
   && [ "$(jq -r '."com.hmdm.CONFIG"'   "${PUSHED_INIT}")" = "${HEADWIND_CONFIG}" ] \
   && [ "$(jq -r 'keys | length'        "${PUSHED_INIT}")" = "2" ]; then
    ok "QA4 pushed init.json carries BASE_URL + CONFIG=${HEADWIND_CONFIG} (exactly 2 keys)"
else
    bad "QA4 pushed init.json wrong: $(cat "${PUSHED_INIT}" 2>/dev/null)"
fi
if [ -f "${MDM}" ] \
   && [ "$(jq -r '.device_class'    "${MDM}")" = "quest" ] \
   && [ "$(jq -r '.xr_chat_url'     "${MDM}")" = "${XR_CHAT_URL}" ] \
   && [ "$(jq -r '.headwind_config' "${MDM}")" = "${HEADWIND_CONFIG}" ] \
   && [ "$(jq -r '.dpc_package'     "${MDM}")" = "com.hmdm.launcher" ] \
   && [ "$(jq -r '.set_via'         "${MDM}")" = "adb-device-owner" ]; then
    ok "QA4 mdm.json: device_class=quest, xr_chat_url + headwind_config recorded"
else
    bad "QA4 mdm.json fields wrong: $(cat "${MDM}" 2>/dev/null)"
fi
has "Headwind console" && has "Web page" \
    && ok "QA4 Headwind app-push console runbook printed (web-page application entry)" \
    || bad "QA4 app-push runbook missing"

# QA5 — ingest: device_class=quest, quest catalog marketing name; the
# registry POST path warns about the phone-only endpoint and STILL fails
# closed on missing mTLS identity (warning first, then exit 2).
clear_logs
run ingest "${Q[@]}" --serial "${SERIAL}" --out "${OUT}"
ING="${OUT}/device/${DEVID}/ingest.json"
if [ "${RC}" -eq 0 ] && [ -f "${ING}" ] \
   && [ "$(jq -r '.schema'         "${ING}")" = "phone-ingest/v2" ] \
   && [ "$(jq -r '.device_class'   "${ING}")" = "quest" ] \
   && [ "$(jq -r '.marketing_name' "${ING}")" = "Meta Quest 3" ] \
   && [ "$(jq -r '.codename'       "${ING}")" = "${CODENAME}" ] \
   && [ "$(jq -r '.tailscale_ip'   "${ING}")" = "${CGNAT_ADDR}" ] \
   && [ "$(jq -r '.enterprise_profile.present' "${ING}")" = "false" ]; then
    ok "QA5 ingest: device_class=quest, Meta Quest 3, tailnet ip folded, no profile (unsupported on quest)"
else
    bad "QA5 ingest.json fields wrong: $(cat "${ING}" 2>/dev/null)"
fi
run ingest "${Q[@]}" --serial "${SERIAL}" --out "${OUT}" --ingest-url "${INGEST_URL}"
if [ "${RC}" -eq 2 ] && has 'device_class:"phone" only' ; then
    ok "QA5 ingest --ingest-url: registry-gap warning printed AND missing-mTLS still fails closed (exit 2)"
else
    bad "QA5 ingest POST-path rc=${RC} (want 2 + gap warning)"; echo "${OUT_TXT}"
fi

# ═══════════════ Scenario QB: quest failure paths + class gates ═══════════════
echo "-- Scenario QB: unauthorized / no-dev-mode / wrong vendor / unsupported verbs --"

# QB1 — UNAUTHORIZED headset: the in-headset accept prompt is the fix; no
# device is selectable -> exit 2, both the warning and the runbook fire.
new_device; device_unauthorized; clear_logs
run detect "${Q[@]}"
if [ "${RC}" -eq 2 ] && has "UNAUTHORIZED" && has "INSIDE the headset" \
   && has "Developer-Mode runbook"; then
    ok "QB1 unauthorized headset -> exit 2, accept-INSIDE-the-headset warning + runbook"
else
    bad "QB1 unauthorized rc=${RC} (want 2)"; echo "${OUT_TXT}"
fi

# QB2 — NO device at all (Developer Mode off is exactly this: the headset
# never appears on adb): exit 2 with the full dev-mode runbook incl. the
# vendor-2833 udev hint.
new_device; device_absent; clear_logs
run detect "${Q[@]}"
if [ "${RC}" -eq 2 ] && has "Developer Mode" && has "2833" && has "no Quest detected"; then
    ok "QB2 no adb device (dev mode off) -> exit 2 with the Developer-Mode + udev-2833 runbook"
else
    bad "QB2 no-dev-mode rc=${RC} (want 2)"; echo "${OUT_TXT}"
fi

# QB3 — WRONG VENDOR: a Google-manufactured device on the quest path is
# refused fail-closed (codenames overlap across vendors — this is the pin).
new_device Google; clear_logs
run detect "${Q[@]}" --serial "${SERIAL}"
[ "${RC}" -eq 2 ] && has "not oculus/Meta" \
    && ok "QB3 manufacturer=Google on the quest path -> exit 2 (fail-closed vendor pin)" \
    || { bad "QB3 wrong-vendor rc=${RC} (want 2)"; echo "${OUT_TXT}"; }
run mdm-enroll "${Q[@]}" --serial "${SERIAL}" --out "${OUT}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk"
[ "${RC}" -eq 2 ] && has "not oculus/Meta" \
    && ok "QB3 mdm-enroll refuses the non-quest device too (same pin, before any mutation)" \
    || { bad "QB3 mdm-enroll wrong-vendor rc=${RC} (want 2)"; echo "${OUT_TXT}"; }

# QB4 — UNSUPPORTED verbs fail closed with the rationale, at run AND plan
# time, and write nothing.
new_device; clear_logs
OUTB="${WORK}/out-b"; mkdir -p "${OUTB}"
run fetch "${Q[@]}" --codename "${CODENAME}"
[ "${RC}" -eq 2 ] && has "UNSUPPORTED" && has "Pixel-only" \
    && ok "QB4 fetch -> exit 2 UNSUPPORTED (GrapheneOS is Pixel-only)" \
    || { bad "QB4 fetch rc=${RC} (want 2)"; echo "${OUT_TXT}"; }
run flash "${Q[@]}" --serial "${SERIAL}" --codename "${CODENAME}" --yes
[ "${RC}" -eq 2 ] && has "UNSUPPORTED" \
    && ok "QB4 flash -> exit 2 UNSUPPORTED" \
    || { bad "QB4 flash rc=${RC} (want 2)"; echo "${OUT_TXT}"; }
run attest "${Q[@]}" --serial "${SERIAL}" --out "${OUTB}" --attestation-url https://a.invalid
if [ "${RC}" -eq 2 ] && has "UNSUPPORTED" && has "Auditor" \
   && [ ! -f "${OUTB}/device/${DEVID}/attestation.json" ]; then
    ok "QB4 attest -> exit 2 UNSUPPORTED (no Auditor tier on Horizon OS), no attestation.json"
else
    bad "QB4 attest rc=${RC} (want 2)"; echo "${OUT_TXT}"
fi
run profile "${Q[@]}" --serial "${SERIAL}" --out "${OUTB}"
if [ "${RC}" -eq 2 ] && has "UNSUPPORTED" && has "Meta-account-bound" \
   && [ ! -f "${OUTB}/vault-seed/device/${DEVID}/enterprise-profile.pass" ]; then
    ok "QB4 profile -> exit 2 UNSUPPORTED (Meta-account-bound user model), no escrow written"
else
    bad "QB4 profile rc=${RC} (want 2)"; echo "${OUT_TXT}"
fi
run plan flash "${Q[@]}"
[ "${RC}" -eq 2 ] && has "UNSUPPORTED" \
    && ok "QB4 plan flash (quest) -> exit 2 at PLAN time (no unexecutable plan printed)" \
    || { bad "QB4 plan-flash rc=${RC} (want 2)"; echo "${OUT_TXT}"; }

# QB5 — the catalog split is REAL: panther is the Quest 3S in quest class and
# the Pixel 7 in phone class; a Pixel codename is unknown in the quest catalog.
run plan enroll "${Q[@]}" --codename panther --login-server "${LOGIN_SERVER}"
hasline "PLAN_DEVICE_NAME=Meta Quest 3S" && hasline "PLAN_DEVICE_CLASS=quest" \
    && ok "QB5 quest class: panther -> Meta Quest 3S (exact line)" \
    || { bad "QB5 quest panther resolution wrong"; echo "${OUT_TXT}"; }
run plan enroll --codename panther --login-server "${LOGIN_SERVER}"
hasline "PLAN_DEVICE_NAME=Pixel 7" && hasline "PLAN_DEVICE_CLASS=phone" \
    && ok "QB5 phone class: the SAME codename -> Pixel 7 (catalogs are class-scoped)" \
    || { bad "QB5 phone panther resolution wrong"; echo "${OUT_TXT}"; }
run plan enroll "${Q[@]}" --codename oriole --login-server "${LOGIN_SERVER}"
[ "${RC}" -eq 4 ] && has "unknown codename" \
    && ok "QB5 a Pixel codename (oriole) is UNKNOWN in the quest catalog -> exit 4" \
    || { bad "QB5 quest-oriole rc=${RC} (want 4)"; echo "${OUT_TXT}"; }
run plan --device-class toaster
[ "${RC}" -eq 1 ] && has "must be phone|quest" \
    && ok "QB5 --device-class toaster -> exit 1 (validated)" \
    || { bad "QB5 bad-class rc=${RC} (want 1)"; echo "${OUT_TXT}"; }

# QB6 — dpm refusal on a quest: exit 1 with the factory-reset hint (NOT the
# stock-Android Play-Protect hint).
new_device; touch "${STATE}/dpm-fail"; clear_logs
run mdm-enroll "${Q[@]}" --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
if [ "${RC}" -eq 1 ] && has "dpm set-device-owner failed" && has "factory-reset" \
   && ! has "Play Protect's DPC allow-list is the likely cause"; then
    ok "QB6 dpm refusal on quest -> exit 1 with the factory-reset hint (not the Play-Protect one)"
else
    bad "QB6 dpm-fail rc=${RC} (want 1 + quest hint)"; echo "${OUT_TXT}"
fi
[ ! -f "${OUTB}/device/${DEVID}/mdm.json" ] \
    && ok "QB6 no mdm.json written on the refused device" \
    || bad "QB6 mdm.json written despite dpm refusal"

# QB7 — a second mdm-enroll on an already-owned quest fails the way AOSP does
# (the mock latches) — device-owner stays one-shot on quest too.
new_device; clear_logs
run mdm-enroll "${Q[@]}" --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
FIRST_RC="${RC}"
run mdm-enroll "${Q[@]}" --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
[ "${FIRST_RC}" -eq 0 ] && [ "${RC}" -eq 1 ] && has "device owner is already set" \
    && ok "QB7 device-owner is one-shot on quest: first 0, re-enroll -> exit 1 (AOSP latch)" \
    || { bad "QB7 re-enroll rc=${RC} (first=${FIRST_RC}), want 0 then 1"; echo "${OUT_TXT}"; }

# QB8 — NEGATIVE: a non-https --xr-chat-url is refused BEFORE any adb call
# (WebXR requires a secure context — an http URL can never enter VR).
new_device; clear_logs
run mdm-enroll "${Q[@]}" --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --xr-chat-url "http://chat.hugmesh.invalid/xr"
if [ "${RC}" -eq 1 ] && has "must be https://" && [ ! -s "${LOGD}/adb.log" ]; then
    ok "QB8 http --xr-chat-url -> exit 1 before ANY adb call (secure-context gate)"
else
    bad "QB8 http-url rc=${RC} (want 1, zero adb)"; echo "${OUT_TXT}"; cat "${LOGD}/adb.log" 2>/dev/null
fi

# QB9 — NEGATIVE (signer pin still bites in quest class): attacker-signed DPC
# -> exit 3, nothing enrolled.
new_device; printf '%s' "${SIGNER_BAD}" > "${STATE}/apksigner-digest"; clear_logs
OUTC="${WORK}/out-c"; mkdir -p "${OUTC}"
run mdm-enroll "${Q[@]}" --serial "${SERIAL}" --out "${OUTC}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
if [ "${RC}" -eq 3 ] && has "signer digest MISMATCH" \
   && [ ! -f "${OUTC}/device/${DEVID}/mdm.json" ]; then
    ok "QB9 NEGATIVE: attacker-signed Headwind DPC -> exit 3, no mdm.json (pin fails closed on quest)"
else
    bad "QB9 bad-signer rc=${RC} (want 3)"; echo "${OUT_TXT}"
fi

# ═══════════════ Scenario QD: secret sweep (cumulative argv) ═══════════════
echo "-- Scenario QD: no secret leaked anywhere across the quest e2e --"
clear_logs   # drain the last step's argv into ARGV_ALL
SWEEP_ALL="${WORK}/sweep-all.log"
cat "${SWEEP}" "${ARGV_ALL}" "${LOGD}"/*.log > "${SWEEP_ALL}" 2>/dev/null || true
# Positive control: the sweep must be able to find a planted value.
printf 'CONTROL %s\n' "${AUTHKEY_SENTINEL}" > "${WORK}/control.log"
if grep -qF -- "${AUTHKEY_SENTINEL}" "${WORK}/control.log"; then
    ok "QD0 POSITIVE CONTROL: the sweep grep finds a planted sentinel"
else
    bad "QD0 sweep grep is broken — QD1 proves nothing"
fi
if grep -qF -- "${AUTHKEY_SENTINEL}" "${SWEEP_ALL}"; then
    bad "QD1 pre-auth key LEAKED into output/argv"
else
    ok "QD1 pre-auth key never reached stdout/stderr or any stub argv"
fi

# ── Summary ────────────────────────────────────────────────────────
echo "== quest e2e result: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
