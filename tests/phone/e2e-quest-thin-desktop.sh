#!/usr/bin/env bash
# e2e-quest-thin-desktop.sh — END-TO-END provisioning of the THIN-DESKTOP
# capability (§8b) on a MOCKED Meta Quest 3, driven through
# scripts/phone-wizard.sh's REAL quest mdm-enroll verb against ONE stateful
# mock headset. Sibling of e2e-quest-join.sh (same conventions: stateful
# PATH-shim stubs, causal installs, captured pushes, ordered adb-sequence
# assertions, every negative control fires).
#
# Under test HERE is the --thin-desktop leg added on top of the quest class:
#   * Moonlight (com.limelight) rides the SAME operator-custody + apksigner
#     signer-pin path as every other sideload — install really fires, the pin
#     really bites (mismatch -> exit 3, nothing recorded);
#   * managed host-list provisioning: the REAL pushed file's content is
#     asserted (schema/superdomain/hosts array, exactly 4 keys), the empty-
#     hosts warning fires and still pushes hosts:[];
#   * the adb COMMAND SEQUENCE stays ordered: DPC install < dpm < init.json
#     push < XR-chat VIEW intent < Moonlight install < host-list push;
#   * mdm.json carries thin_desktop:true + the hosts array — and stays
#     thin_desktop:false + [] on an un-toggled run with ZERO Moonlight adb
#     traffic (byte-honest default);
#   * failure paths: phone-class --thin-desktop (exit 2, ZERO adb), stray
#     knob without the toggle (exit 1, ZERO adb), bad host charset (exit 1,
#     ZERO adb), Moonlight absent with no APK (exit 1, no mdm.json), host-list
#     push failure (exit 1, no mdm.json), attacker-signed Moonlight (exit 3,
#     no mdm.json even though the Headwind pin passed).
#
# Runs ANYWHERE with bash + jq + coreutils/awk — NO network, NO root, NO
# device, NO adb install. SKIP (exit 0) only if a required tool is missing.
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

echo "== thin-desktop e2e: Moonlight + managed host list on a mocked Quest 3 =="

BIN="${WORK}/bin"; LOGD="${WORK}/logs"; FIX="${WORK}/fixtures"
mkdir -p "${BIN}" "${LOGD}" "${FIX}"

SERIAL="2G0YC1ZF8800TD"
DEVID="quest-2g0yc1zf8800td"
HEADWIND_URL="https://headwind.hugmesh.invalid"
HEADWIND_CONFIG="quest-fleet"
XR_CHAT_URL="https://chat.hugmesh.invalid/matrix/rooms/xr/chat3d"
HOSTS_CSV="frite,box2.hugmesh.internal"

SIGNER_OK="$(printf 'hugmesh-thin-desktop-e2e-signer' | sha256sum | awk '{print $1}')"
SIGNER_BAD="$(printf 'attacker-signer'                | sha256sum | awk '{print $1}')"

# ── Stateful mock headset (e2e-quest-join.sh's shape + a Moonlight-aware
#    install case and a targetable push-failure latch) ─────────────────────
STATE="${WORK}/device"
new_device() {
    rm -rf "${STATE}"; mkdir -p "${STATE}"
    printf 'List of devices attached\n%s\tdevice\n' "${SERIAL}" > "${STATE}/adb-devices"
    printf 'device\n'                                            > "${STATE}/adb-getstate"
    printf 'eureka\n'                                            > "${STATE}/codename"
    printf 'oculus\n'                                            > "${STATE}/manufacturer"
    printf '14\n'                                                > "${STATE}/release"
    printf '[ro.build.type]: [user]\n'                           > "${STATE}/getprop-dump"
    printf 'Account {name=quest-owner@meta.invalid, type=com.oculus.account}\n' > "${STATE}/dumpsys-account"
    : > "${STATE}/packages"
    rm -f "${STATE}/device-owner-set" "${STATE}/push-fail-hosts"
    rm -rf "${STATE}/pushed"
    printf '%s' "${SIGNER_OK}"                                   > "${STATE}/apksigner-digest"
}

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
            *moonlight*)       echo 'package:com.limelight'     >> "${S}/packages" ;;
            *tailscale*)       echo 'package:com.tailscale.ipn' >> "${S}/packages" ;;
        esac
        exit 0 ;;
    push)
        if [ -e "${S}/push-fail-hosts" ] && [[ "${3:-}" == *thin-desktop-hosts* ]]; then
            echo 'adb: error: failed to copy' >&2; exit 1
        fi
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
            'getprop ro.build.version.release')     cat "${S}/release"      2>/dev/null || true ;;
            getprop)                                cat "${S}/getprop-dump" 2>/dev/null || true ;;
            'pm list users')    printf '\tUserInfo{0:Owner:c13}\n' ;;
            'dumpsys account')  cat "${S}/dumpsys-account" 2>/dev/null || true ;;
            'pm list packages') cat "${S}/packages" 2>/dev/null || true ;;
            'pm path '*)        echo 'package:/data/app/stub/base.apk' ;;
            'mkdir -p '*)       : ;;
            'am start '*)       echo 'Starting: Intent { act=android.intent.action.VIEW }' ;;
            'dpm set-device-owner '*)
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
printf 'FASTBOOT %s\n' "$*" >> "${PW_STUB_LOG_DIR:?}/fastboot.log"
case "${1:-}" in --version) echo 'fastboot version 35.0.2-android' ;; esac
exit 0
EOF
cat > "${BIN}/apksigner" <<'EOF'
#!/usr/bin/env bash
printf 'APKSIGNER %s\n' "$*" >> "${PW_STUB_LOG_DIR:?}/apksigner.log"
printf 'Signer #1 certificate SHA-256 digest: %s\n' "$(cat "${PW_STUB_STATE:?}/apksigner-digest" 2>/dev/null || echo deadbeef)"
exit 0
EOF
chmod +x "${BIN}"/*

: > "${FIX}/headwind-dpc.apk"; : > "${FIX}/moonlight.apk"
OUT="${WORK}/out"; mkdir -p "${OUT}"

pw() {
    env PATH="${BIN}:${PATH}" \
        PW_STUB_STATE="${STATE}" PW_STUB_LOG_DIR="${LOGD}" \
        bash "${DRIVER}" "$@" </dev/null 2>&1
}
OUT_TXT=""; RC=0
run() { OUT_TXT="$(pw "$@")"; RC=$?; }
has() { grep -qF -- "$1" <<<"${OUT_TXT}"; }
clear_logs() { : > "${LOGD}/adb.log"; : > "${LOGD}/apksigner.log"; : > "${LOGD}/fastboot.log"; }
adb_seq() { grep -n -- "$1" "${LOGD}/adb.log" 2>/dev/null | head -n1 | cut -d: -f1; }

Q=(--device-class quest --serial "${SERIAL}" --out "${OUT}")
MDM_BASE=("${Q[@]}" --headwind-url "${HEADWIND_URL}" --headwind-config "${HEADWIND_CONFIG}" \
          --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}" \
          --xr-chat-url "${XR_CHAT_URL}")
TD=(--thin-desktop --moonlight-apk "${FIX}/moonlight.apk" \
    --moonlight-signer-sha256 "${SIGNER_OK}" --thin-desktop-hosts "${HOSTS_CSV}")

# ═══════════ TD-A: the happy path (toggle + APK + pin + hosts) ═══════════
echo "-- TD-A: full thin-desktop provisioning rides mdm-enroll --"
new_device; clear_logs
run mdm-enroll "${MDM_BASE[@]}" "${TD[@]}"
MDM="${OUT}/device/${DEVID}/mdm.json"
if [ "${RC}" -eq 0 ] && has "Moonlight APK signer pin OK" \
   && has "thin-desktop host list pushed"; then
    ok "A1 mdm-enroll --thin-desktop succeeded: Moonlight installed, signer-pinned, host list pushed"
else
    bad "A1 rc=${RC}"; echo "${OUT_TXT}"
fi
# The ORDERED adb sequence: the thin-desktop leg runs after the XR-chat leg,
# before the record — DPC < dpm < init.json < VIEW intent < Moonlight < hosts.
S1="$(adb_seq 'install -r .*headwind-dpc.apk')"
S2="$(adb_seq 'dpm set-device-owner com.hmdm.launcher/.AdminReceiver')"
S3="$(adb_seq 'push .*init.json')"
S4="$(adb_seq 'am start -a android.intent.action.VIEW')"
S5="$(adb_seq 'install -r .*moonlight.apk')"
S6="$(adb_seq 'push .*thin-desktop-hosts')"
if [ -n "${S1}" ] && [ -n "${S2}" ] && [ -n "${S3}" ] && [ -n "${S4}" ] \
   && [ -n "${S5}" ] && [ -n "${S6}" ] \
   && [ "${S1}" -lt "${S2}" ] && [ "${S2}" -lt "${S3}" ] && [ "${S3}" -lt "${S4}" ] \
   && [ "${S4}" -lt "${S5}" ] && [ "${S5}" -lt "${S6}" ]; then
    ok "A2 adb sequence ordered: DPC(${S1}) < dpm(${S2}) < init.json(${S3}) < VIEW(${S4}) < Moonlight(${S5}) < hosts(${S6})"
else
    bad "A2 sequence wrong (${S1:-x} ${S2:-x} ${S3:-x} ${S4:-x} ${S5:-x} ${S6:-x})"; cat "${LOGD}/adb.log"
fi
# The REAL pushed provisioning file: schema + superdomain + the exact hosts
# array, and nothing else (exactly 4 keys).
HOSTS_PUSHED="${STATE}/pushed/sdcard/Android/data/com.limelight/files/hugmesh-thin-desktop-hosts.json"
if [ -f "${HOSTS_PUSHED}" ] \
   && [ "$(jq -r '.schema'          "${HOSTS_PUSHED}")" = "thin-desktop-hosts/v1" ] \
   && [ "$(jq -r '.superdomain'     "${HOSTS_PUSHED}")" = "hugmesh.internal" ] \
   && [ "$(jq -c '.hosts'           "${HOSTS_PUSHED}")" = '["frite","box2.hugmesh.internal"]' ] \
   && [ "$(jq -r 'keys | length'    "${HOSTS_PUSHED}")" = "4" ]; then
    ok "A3 pushed host-list file: schema/v1 + superdomain + EXACT hosts array (4 keys)"
else
    bad "A3 pushed host list wrong: $(cat "${HOSTS_PUSHED}" 2>/dev/null)"
fi
if [ -f "${MDM}" ] \
   && [ "$(jq -r '.thin_desktop'       "${MDM}")" = "true" ] \
   && [ "$(jq -c '.thin_desktop_hosts' "${MDM}")" = '["frite","box2.hugmesh.internal"]' ] \
   && [ "$(jq -r '.device_class'       "${MDM}")" = "quest" ] \
   && [ "$(jq -r '.xr_chat_url'        "${MDM}")" = "${XR_CHAT_URL}" ]; then
    ok "A4 mdm.json: thin_desktop=true + hosts array recorded alongside the XR-chat leg"
else
    bad "A4 mdm.json wrong: $(cat "${MDM}" 2>/dev/null)"
fi
has "https://localhost:47990" && has "Files" && has "tailnet name" \
    && ok "A5 pairing + Headwind app-push runbook printed (PIN at loopback web UI; configuration Files push)" \
    || bad "A5 runbook missing pieces"
grep -c 'APKSIGNER' "${LOGD}/apksigner.log" | grep -x '2' >/dev/null \
    && ok "A6 apksigner verified BOTH pinned APKs (Headwind + Moonlight)" \
    || bad "A6 apksigner call count wrong: $(grep -c APKSIGNER "${LOGD}/apksigner.log")"

# ═══════════ TD-B: empty hosts + off-by-default honesty ═══════════
echo "-- TD-B: empty host list + un-toggled default --"
new_device; clear_logs
run mdm-enroll "${MDM_BASE[@]}" --thin-desktop --moonlight-apk "${FIX}/moonlight.apk"
HP2="${STATE}/pushed/sdcard/Android/data/com.limelight/files/hugmesh-thin-desktop-hosts.json"
if [ "${RC}" -eq 0 ] && has "EMPTY managed host list" \
   && [ "$(jq -c '.hosts' "${HP2}" 2>/dev/null)" = "[]" ]; then
    ok "B1 no --thin-desktop-hosts: warning fires and the pushed file carries hosts:[]"
else
    bad "B1 empty-hosts rc=${RC}"; echo "${OUT_TXT}"
fi
new_device; clear_logs
run mdm-enroll "${MDM_BASE[@]}"
if [ "${RC}" -eq 0 ] \
   && [ "$(jq -r '.thin_desktop'       "${MDM}")" = "false" ] \
   && [ "$(jq -c '.thin_desktop_hosts' "${MDM}")" = "[]" ] \
   && ! grep -q 'limelight\|moonlight' "${LOGD}/adb.log"; then
    ok "B2 un-toggled run: thin_desktop=false + [] recorded, ZERO Moonlight adb traffic"
else
    bad "B2 default-off rc=${RC}"; grep -i 'moonlight\|limelight' "${LOGD}/adb.log" 2>/dev/null; echo "${OUT_TXT}"
fi

# ═══════════ TD-C: fail-closed option gates (ZERO adb on each) ═══════════
echo "-- TD-C: option gates fire before any adb call --"
new_device; clear_logs
run mdm-enroll --serial "${SERIAL}" --out "${OUT}" --headwind-url "${HEADWIND_URL}" --thin-desktop
if [ "${RC}" -eq 2 ] && has "quest capability" && [ ! -s "${LOGD}/adb.log" ]; then
    ok "C1 phone-class --thin-desktop -> exit 2 with the rationale, ZERO adb"
else
    bad "C1 rc=${RC} (want 2, zero adb)"; echo "${OUT_TXT}"
fi
clear_logs
run mdm-enroll "${MDM_BASE[@]}" --moonlight-apk "${FIX}/moonlight.apk"
if [ "${RC}" -eq 1 ] && has "need --thin-desktop" && [ ! -s "${LOGD}/adb.log" ]; then
    ok "C2 stray --moonlight-apk without the toggle -> exit 1, ZERO adb"
else
    bad "C2 rc=${RC} (want 1, zero adb)"; echo "${OUT_TXT}"
fi
clear_logs
run mdm-enroll "${MDM_BASE[@]}" --thin-desktop --thin-desktop-hosts 'frite,BAD HOST'
if [ "${RC}" -eq 1 ] && has "invalid --thin-desktop-hosts entry" && [ ! -s "${LOGD}/adb.log" ]; then
    ok "C3 bad host charset -> exit 1, ZERO adb"
else
    bad "C3 rc=${RC} (want 1, zero adb)"; echo "${OUT_TXT}"
fi

# ═══════════ TD-D: provisioning failure paths (after the gates) ═══════════
echo "-- TD-D: Moonlight/push failures leave NO record behind --"
OUTD="${WORK}/out-d"; mkdir -p "${OUTD}"
new_device; clear_logs
run mdm-enroll "${MDM_BASE[@]/${OUT}/${OUTD}}" --out "${OUTD}" --thin-desktop --thin-desktop-hosts frite
if [ "${RC}" -eq 1 ] && has "com.limelight is not installed" \
   && [ ! -f "${OUTD}/device/${DEVID}/mdm.json" ]; then
    ok "D1 no --moonlight-apk and Moonlight absent -> exit 1, NO mdm.json (record only after success)"
else
    bad "D1 rc=${RC}"; echo "${OUT_TXT}"
fi
new_device; touch "${STATE}/push-fail-hosts"; clear_logs
run mdm-enroll "${MDM_BASE[@]/${OUT}/${OUTD}}" --out "${OUTD}" "${TD[@]}"
if [ "${RC}" -eq 1 ] && has "adb push of hugmesh-thin-desktop-hosts.json" \
   && [ ! -f "${OUTD}/device/${DEVID}/mdm.json" ]; then
    ok "D2 host-list push failure -> exit 1, NO mdm.json"
else
    bad "D2 rc=${RC}"; echo "${OUT_TXT}"
fi
# Attacker-signed Moonlight: the Headwind pin must PASS first (its expected
# digest is switched to the bad one the stub now reports), so the exit-3 is
# attributable to the MOONLIGHT pin alone.
new_device; printf '%s' "${SIGNER_BAD}" > "${STATE}/apksigner-digest"; clear_logs
run mdm-enroll "${Q[@]/${OUT}/${OUTD}}" --out "${OUTD}" \
    --headwind-url "${HEADWIND_URL}" --headwind-apk "${FIX}/headwind-dpc.apk" \
    --headwind-signer-sha256 "${SIGNER_BAD}" \
    --thin-desktop --moonlight-apk "${FIX}/moonlight.apk" \
    --moonlight-signer-sha256 "${SIGNER_OK}" --thin-desktop-hosts frite
if [ "${RC}" -eq 3 ] && has "Moonlight APK signer digest MISMATCH" \
   && [ ! -f "${OUTD}/device/${DEVID}/mdm.json" ]; then
    ok "D3 attacker-signed Moonlight -> exit 3 on the MOONLIGHT pin (Headwind pin passed), NO mdm.json"
else
    bad "D3 rc=${RC}"; echo "${OUT_TXT}"
fi

echo "== thin-desktop e2e result: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
