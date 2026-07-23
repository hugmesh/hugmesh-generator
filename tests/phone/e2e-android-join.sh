#!/usr/bin/env bash
# e2e-android-join.sh — END-TO-END onboarding of a MOCKED stock-Android Pixel
# joining the enterprise mesh, driven through scripts/phone-wizard.sh's REAL
# verb chain in sequence against ONE stateful mock device.
#
# HOW THIS DIFFERS FROM tests/phone/test-phone-wizard.sh (the per-verb unit
# test): that test exercises each verb in isolation with FRESH fixtures reset
# between assertion groups. This e2e instead stands up a SINGLE persistent
# mock-device state directory that every verb reads AND MUTATES, then walks the
# whole existing-device onboarding lifecycle in real operator order —
#   detect -> enroll (pending -> operator-joins -> enrolled) -> mdm-enroll
#   -> attest -> profile -> ingest -> status -> remove-profile -> re-ingest
# — so the CUMULATIVE, cross-verb behaviour is what is under test: the records
# fold into each other, and state one verb writes (a created secondary user, an
# installed DPC package, a tailnet address that only appears once the operator
# joins) is what the NEXT verb sees. The headline device is STOCK ANDROID (the
# user asked specifically for "a mocked phone with android joining"); a
# GrapheneOS cross-check plus an IMPOSTOR ROM prove the OS classification is
# real and not hardcoded, and an ordering-foreclosure scenario proves a
# constraint that ONLY a stateful sequential run can catch (profile-before-
# mdm-enroll permanently forecloses device-owner mode).
#
# Runs ANYWHERE with bash + jq + coreutils/awk — NO network, NO root, NO device,
# NO adb/fastboot/apksigner install. adb/fastboot/curl/apksigner are PATH-shim
# STUBS that model a real handset's OBSERVABLE state transitions rather than
# pre-seeding each verb:
#   * `adb install` makes the package APPEAR in `pm list packages` (causal);
#   * `adb push` CAPTURES the pushed file, so the DPC's init.json config payload
#     is asserted for content, not just assumed;
#   * `pm create-user` grows `pm list users` 1 -> 2, which is what forecloses
#     device-owner mode;
#   * `dpm set-device-owner` LATCHES — a second attempt fails the way AOSP does;
#   * the Tailscale tun0 interface has no CGNAT address until the "operator joins";
#   * the curl stub REFUSES a POST that carries no mTLS client identity (exit
#     35), so the mTLS gate is enforced by the mock, not merely requested.
# openssl mints a REAL throwaway client cert/key; absent it, the mTLS assertions
# SKIP and the emit-only path is checked instead. SKIP (exit 0) only if a
# required tool is genuinely missing.
#
# EVERY negative control here is wired and FIRES (a bad signer digest, a failing
# dpm, an undetectable OS, an identity-less POST) — an assertion that cannot
# fail is not evidence, so nothing below is left as unexercised scaffolding.
#
# Scenarios:
#   A  stock-Android Pixel joins: full lifecycle, os=android recorded as a
#      FIRST-CLASS path (NO --force anywhere), tailnet-join pending->verified,
#      Headwind device-owner set + init.json payload verified, Auditor paired,
#      escrowed enterprise profile, phone-ingest/v2 record POSTed over mTLS,
#      status reports the live device, remove-profile retires the profile and a
#      re-ingest reflects it. All records cross-consistent.
#   B  ordering foreclosure (the teeth): profile BEFORE mdm-enroll -> exit 2;
#      an added account alone also forecloses; a re-run against an already-owned
#      device fails the way AOSP does.
#   C  OS classification: GrapheneOS -> os=grapheneos; an IMPOSTOR ROM with a
#      datestamp-shaped incremental but no GrapheneOS marker -> os=android
#      (pins the marker AND-gate the driver documents); a genuinely undetectable
#      OS -> exit 2 until --force.
#   D  secret sweep across the ENTIRE run, over a CUMULATIVE argv archive, with
#      a positive control proving the sweep actually bites.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="${REPO}/scripts/phone-wizard.sh"

[ -r "${DRIVER}" ] || { echo "  FAIL driver missing: ${DRIVER}"; exit 1; }
for t in jq awk sha256sum; do
    command -v "${t}" >/dev/null || { echo "SKIP: need ${t}"; exit 0; }
done
HAVE_OPENSSL=0; command -v openssl >/dev/null && HAVE_OPENSSL=1
[ "${PW_E2E_NO_OPENSSL:-0}" = "1" ] && HAVE_OPENSSL=0   # test seam: force the emit-only / no-mTLS branch

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== MDM phone e2e: a mocked stock-Android Pixel joins the mesh =="

# ── Layout ─────────────────────────────────────────────────────────
BIN="${WORK}/bin"; LOGD="${WORK}/logs"; FIX="${WORK}/fixtures"
mkdir -p "${BIN}" "${LOGD}" "${FIX}"
# Two sweep sinks (group D). SWEEP is append-only stdout/stderr. ARGV_ALL is the
# CUMULATIVE argv archive: clear_logs() drains the per-step logs into it before
# truncating, so argv history survives to the sweep instead of being wiped.
SWEEP="${WORK}/sweep.log";       : > "${SWEEP}"
ARGV_ALL="${WORK}/argv-all.log"; : > "${ARGV_ALL}"

SERIAL="E2ESER0001"
DEVID="phone-e2eser0001"          # sanitize_id(E2ESER0001)
CODENAME="oriole"                 # Pixel 6, in scripts/phone-devices.tsv
LOGIN_SERVER="https://headscale.hugmesh.invalid"
HEADWIND_URL="https://headwind.hugmesh.invalid"
ATTEST_URL="https://attestation.hugmesh.invalid"
INGEST_URL="https://registry.hugmesh.invalid/bff/internal/phone-ingest"
AUTHKEY_SENTINEL="tskey-auth-SECRET-e2e-DO-NOT-LEAK-0001"
CGNAT_ADDR="100.64.7.42"

# Real SHA-256 values as pinned APK signer digests (the stub apksigner emits
# whichever the mock is currently loaded with; the wizard pins one — so the
# string comparison the driver performs is genuine, and SIGNER_BAD really fires).
SIGNER_OK="$(printf 'hugmesh-e2e-signer' | sha256sum | awk '{print $1}')"
SIGNER_BAD="$(printf 'attacker-signer'      | sha256sum | awk '{print $1}')"

# ── Stateful mock device ───────────────────────────────────────────
# One state dir the stubs share and MUTATE. new_device() (re)initialises it as a
# freshly-set-up handset: 1 user (Owner), no accounts, NO enterprise apps yet,
# no tailnet address, device-owner not yet claimed.
STATE="${WORK}/device"
new_device() {   # $1 = os: android|grapheneos|impostor|undetectable
    rm -rf "${STATE}"; mkdir -p "${STATE}"
    printf 'List of devices attached\n%s\tdevice\n' "${SERIAL}" > "${STATE}/adb-devices"
    printf '%s\n' "${CODENAME}"                                  > "${STATE}/codename"
    printf 'device\n'                                            > "${STATE}/adb-getstate"
    : > "${STATE}/packages"                # nothing installed; the wizard sideloads each APK
    # Base `ip -o addr show` fixture: loopback + wlan0, NO tun (Tailscale not
    # joined yet). Real Android names the Tailscale VpnService iface tun0, never
    # tailscale0 — device_joins() appends a realistic folded-`\` tun0 line.
    printf '1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever\n23: wlan0    inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0\\       valid_lft forever preferred_lft forever\n' > "${STATE}/ifaces"
    rm -f "${STATE}/user-created" "${STATE}/dumpsys-account" "${STATE}/dpm-fail" \
          "${STATE}/device-owner-set"
    rm -rf "${STATE}/pushed"
    printf '%s' "${SIGNER_OK}"                                   > "${STATE}/apksigner-digest"
    printf '14\n'                                                > "${STATE}/release"
    case "${1}" in
        grapheneos)
            printf '[ro.gos_type]: [grapheneos]\n'               > "${STATE}/getprop-dump"
            printf '2026071500\n'                                > "${STATE}/incremental" ;;
        impostor)
            # A non-GrapheneOS AOSP-derived ROM whose incremental HAPPENS to be
            # datestamp-shaped. The driver documents that the datestamp alone is
            # NOT GrapheneOS-unique and must be AND-ed with a real marker; this
            # fixture is what makes that AND-gate load-bearing.
            printf '[ro.build.type]: [user]\n'                   > "${STATE}/getprop-dump"
            printf '2026071500\n'                                > "${STATE}/incremental" ;;
        undetectable)
            : > "${STATE}/getprop-dump"
            : > "${STATE}/incremental"
            : > "${STATE}/release" ;;
        *)  # stock Android: no grapheneos marker, real Pixel build-id incremental
            printf '[ro.build.type]: [user]\n'                   > "${STATE}/getprop-dump"
            printf '8815525\n'                                   > "${STATE}/incremental" ;;
    esac
}
# The operator joins: the Tailscale app brings up tun0 with the CGNAT address.
# Faithful to real `ip -o addr show` output — the record is folded onto one line
# with a literal `\` where multi-line output would wrap.
device_joins() { printf '12: tun0    inet %s/32 scope global tun0\\       valid_lft forever preferred_lft forever\n' "${CGNAT_ADDR}" >> "${STATE}/ifaces"; }
# A cellular data interface carrying a carrier-grade-NAT 100.64/10 address — a
# REAL false-positive source: it is in the CGNAT range but is NOT a tailnet. The
# driver's tun-scoping must NOT mistake it for a join.
device_cellular_cgnat() { printf '8: rmnet_data0    inet 100.100.50.25/30 scope global rmnet_data0\\       valid_lft forever preferred_lft forever\n' >> "${STATE}/ifaces"; }
add_account()  { printf 'Account {name=user@corp, type=com.google}\n' > "${STATE}/dumpsys-account"; }

# ── PATH-shim stubs ────────────────────────────────────────────────
cat > "${BIN}/adb" <<'EOF'
#!/usr/bin/env bash
S="${PW_STUB_STATE:?}"; L="${PW_STUB_LOG_DIR:?}"
printf 'ADB %s\n' "$*" >> "${L}/adb.log"
[ "${1:-}" = "-s" ] && shift 2
case "${1:-}" in
    devices)   cat "${S}/adb-devices" 2>/dev/null || echo "List of devices attached"; exit 0 ;;
    get-state) cat "${S}/adb-getstate" 2>/dev/null || echo device; exit 0 ;;
    reboot)    exit 0 ;;
    install)
        # Install is CAUSAL: the package becomes visible to `pm list packages`,
        # mapped from the apk basename (the mock's stand-in for a real install).
        apk="${@: -1}"
        case "${apk}" in
            *headwind*|*hmdm*) echo 'package:com.hmdm.launcher'          >> "${S}/packages" ;;
            *auditor*)         echo 'package:systems.hugmesh.auditor' >> "${S}/packages" ;;
            *tailscale*)       echo 'package:com.tailscale.ipn'          >> "${S}/packages" ;;
        esac
        exit 0 ;;
    push)
        # CAPTURE the pushed file under ${S}/pushed<remote-path> so its payload
        # can be asserted (this is the DPC's only config channel).
        if [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
            mkdir -p "${S}/pushed$(dirname "${3}")" 2>/dev/null
            cp "${2}" "${S}/pushed${3}" 2>/dev/null
        fi
        exit 0 ;;
    pull)      [ -n "${3:-}" ] && printf 'apk-fixture-bytes\n' > "${3}"; exit 0 ;;
    shell)
        shift
        case "$*" in
            'getprop ro.product.device')            cat "${S}/codename"     2>/dev/null || echo oriole ;;
            'getprop ro.build.version.incremental') cat "${S}/incremental"  2>/dev/null || true ;;
            'getprop ro.build.version.release')     cat "${S}/release"      2>/dev/null || true ;;
            'getprop ro.build.fingerprint')         echo 'google/oriole/oriole:13/TP1A.220624.014/8815525:user/release-keys' ;;
            'getprop net.hostname')                 echo phone-e2e-host ;;
            getprop)                                cat "${S}/getprop-dump" 2>/dev/null || true ;;
            'pm list users')
                printf '\tUserInfo{0:Owner:c13}\n'
                [ -e "${S}/user-created" ] && printf '\tUserInfo{10:enterprise:410}\n' ;;
            'pm create-user '*) touch "${S}/user-created"; echo 'Success: created user id 10' ;;
            'pm remove-user '*) rm -f "${S}/user-created"; echo 'Success: removed user' ;;
            'am start-user '*|'am switch-user '*) echo ok ;;
            'dumpsys account')  cat "${S}/dumpsys-account" 2>/dev/null || true ;;
            'pm list packages') cat "${S}/packages" 2>/dev/null || true ;;
            'pm path '*)        echo 'package:/data/app/stub/base.apk' ;;
            'ip -o addr show') cat "${S}/ifaces" 2>/dev/null || true ;;
            'dumpsys lock_settings'|'locksettings set-password '*|'mkdir -p '*) : ;;
            'dpm set-device-owner '*)
                # Knob: simulate a provisioning refusal (e.g. stock-Android Play
                # Protect blocking an unlisted DPC).
                if [ -e "${S}/dpm-fail" ]; then
                    echo 'java.lang.IllegalStateException: Not allowed to set the device owner' >&2; exit 1
                fi
                # LATCH like real AOSP: device-owner is one-shot for the life of
                # the OS install; a second attempt fails, it does not silently win.
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
# curl stub: models a registry that DEMANDS an mTLS client identity — a POST
# without --cert/--key is refused (exit 35, curl's SSL-connect error), so the
# mTLS gate is enforced by the mock rather than merely requested by the driver.
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
L="${PW_STUB_LOG_DIR:?}"
printf 'CURL %s\n' "$*" >> "${L}/curl.log"
post=0; cert=0; key=0
for a in "$@"; do
    case "${a}" in -X) post=1 ;; --cert) cert=1 ;; --key) key=1 ;; esac
done
if [ "${post}" -eq 1 ]; then
    { [ "${cert}" -eq 1 ] && [ "${key}" -eq 1 ]; } || exit 35
    exit 0
fi
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

# APK fixtures (real files so the driver's `[ -f ]` checks pass; contents unused
# — the stub apksigner supplies the signer digest). All three are really installed.
: > "${FIX}/tailscale.apk"; : > "${FIX}/headwind-dpc.apk"; : > "${FIX}/auditor-fork.apk"
# Pre-auth key: a 0600 secret file the operator holds; must NEVER be printed.
AUTHKEY_FILE="${FIX}/authkey"; printf '%s\n' "${AUTHKEY_SENTINEL}" > "${AUTHKEY_FILE}"; chmod 600 "${AUTHKEY_FILE}"

# mTLS material for the ingest POST (real throwaway cert/key when openssl exists).
CA="${FIX}/ca.pem"; CERT="${FIX}/client.pem"; KEY="${FIX}/client.key"
if [ "${HAVE_OPENSSL}" -eq 1 ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "${KEY}" -out "${CERT}" \
        -days 1 -subj "/CN=phone-ingest-e2e" >/dev/null 2>&1 || HAVE_OPENSSL=0
    [ "${HAVE_OPENSSL}" -eq 1 ] && cp "${CERT}" "${CA}"
fi

OUT="${WORK}/out"; mkdir -p "${OUT}"

# ── Driver invocation: PATH shim + env seams, stdin /dev/null, 2>&1 ─────────
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
# has()     — substring, for prose/advisory text where that is the intent.
# hasline() — WHOLE-LINE exact match, for machine-readable KEY=VALUE lines
#             (substring would let DEVICE_NAME=Pixel 6 pass for "Pixel 6 Pro").
has()     { grep -qF  -- "$1" <<<"${OUT_TXT}"; }
hasline() { grep -qxF -- "$1" <<<"${OUT_TXT}"; }
# Drain argv logs into the cumulative archive BEFORE truncating, so the group-D
# sweep sees every verb's argv, not just the last step's.
clear_logs() {
    cat "${LOGD}"/*.log >> "${ARGV_ALL}" 2>/dev/null || true
    : > "${LOGD}/adb.log"; : > "${LOGD}/curl.log"; : > "${LOGD}/fastboot.log"; : > "${LOGD}/apksigner.log"
}

ENROLL_ARGS=(--serial "${SERIAL}" --out "${OUT}" --login-server "${LOGIN_SERVER}" \
             --authkey-file "${AUTHKEY_FILE}" --tailscale-apk "${FIX}/tailscale.apk" \
             --apk-signer-sha256 "${SIGNER_OK}")

# ═══════════════════════ Scenario A: stock-Android join ═══════════════════════
echo "-- Scenario A: a stock-Android Pixel joins the mesh --"
new_device android; clear_logs

# A1 — detect: read a live stock-Android handset over adb.
run detect --serial "${SERIAL}"
if [ "${RC}" -eq 0 ] && hasline "DEVICE_STATE=adb" && hasline "DEVICE_CODENAME=${CODENAME}" \
   && hasline "DEVICE_NAME=Pixel 6"; then
    ok "A1 detect: adb state, codename ${CODENAME} -> Pixel 6 (exact-line match)"
else
    bad "A1 detect rc=${RC}"; echo "${OUT_TXT}"
fi

# A2 — enroll before the operator completes the custom-login/approval: the Tailscale
# has no CGNAT address, so the join VERIFY times out -> exit 1. os=android is
# announced as a SUPPORTED path and no --force is needed to reach the join wait.
run PW_JOIN_TIMEOUT=2 enroll "${ENROLL_ARGS[@]}"
if [ "${RC}" -eq 1 ] && has "stock Android" && has "supported for enroll" \
   && has "still pending superadmin approval"; then
    ok "A2 enroll (pre-join): os=android is first-class, join VERIFY pending -> exit 1"
else
    bad "A2 enroll-pending rc=${RC} (want 1)"; echo "${OUT_TXT}"
fi
[ ! -f "${OUT}/device/${DEVID}/enrollment.json" ] \
    && ok "A2 no enrollment.json written while the join is unverified" \
    || bad "A2 enrollment.json written despite an unverified join"

# A2b — carrier-grade-NAT is NOT a tailnet join. A cellular rmnet_data* interface
# legitimately carries a 100.64/10 address; the driver scopes its CGNAT match to
# tun* interfaces precisely so this cannot be mistaken for a join. With ONLY the
# rmnet CGNAT present (no tun), enroll must still time out -> exit 1.
device_cellular_cgnat
run PW_JOIN_TIMEOUT=2 enroll "${ENROLL_ARGS[@]}"
[ "${RC}" -eq 1 ] && has "still pending superadmin approval" \
    && ok "A2b carrier-NAT 100.64/10 on rmnet is NOT mistaken for a tailnet join (tun-scoped) -> exit 1" \
    || { bad "A2b carrier-NAT false-positive rc=${RC}, want 1"; echo "${OUT_TXT}"; }

# A3 — operator completes the join; the Tailscale tun0 interface comes up with
# the CGNAT address. Re-run -> success.
device_joins
run enroll "${ENROLL_ARGS[@]}"
ENR="${OUT}/device/${DEVID}/enrollment.json"
if [ "${RC}" -eq 0 ] && has "tailnet join VERIFIED: ${CGNAT_ADDR}" && [ -f "${ENR}" ]; then
    ok "A3 enroll (post-join): tailnet VERIFIED, enrollment.json written"
else
    bad "A3 enroll rc=${RC}"; echo "${OUT_TXT}"
fi
if [ -f "${ENR}" ] \
   && [ "$(jq -r '.os'            "${ENR}")" = "android" ] \
   && [ "$(jq -r '.os_version'    "${ENR}")" = "14" ] \
   && [ "$(jq -r '.serial'        "${ENR}")" = "${SERIAL}" ] \
   && [ "$(jq -r '.tailscale_ip'  "${ENR}")" = "${CGNAT_ADDR}" ] \
   && [ "$(jq -r '.login_server'  "${ENR}")" = "${LOGIN_SERVER}" ] \
   && [ "$(jq -r '.verification'  "${ENR}")" = "adb-heuristic" ]; then
    ok "A3 enrollment.json: os=android, os_version=14, serial, tailscale_ip, login_server, verification"
else
    bad "A3 enrollment.json fields wrong: $(cat "${ENR}" 2>/dev/null)"
fi
# The Tailscale APK was really sideloaded and its signer really pinned.
grep -q 'install -r .*tailscale.apk' "${LOGD}/adb.log" && has "Tailscale APK signer pin OK" \
    && ok "A3 Tailscale APK sideloaded and signer-pin verified" \
    || bad "A3 tailscale install/pin missing from the run"

# A4 — mdm-enroll: install the Headwind DPC and claim device-owner while the
# device is still FRESH (1 user, 0 accounts).
clear_logs
run mdm-enroll --serial "${SERIAL}" --out "${OUT}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
MDM="${OUT}/device/${DEVID}/mdm.json"
if [ "${RC}" -eq 0 ] \
   && grep -q 'dpm set-device-owner com.hmdm.launcher/.AdminReceiver' "${LOGD}/adb.log" \
   && has "device-owner via adb is BEST-EFFORT" ; then
    ok "A4 mdm-enroll: fresh device -> dpm set-device-owner (stock-Android best-effort advisory shown)"
else
    bad "A4 mdm-enroll rc=${RC}"; echo "${OUT_TXT}"; cat "${LOGD}/adb.log"
fi
if [ -f "${MDM}" ] \
   && [ "$(jq -r '.dpc_package'  "${MDM}")" = "com.hmdm.launcher" ] \
   && [ "$(jq -r '.headwind_url' "${MDM}")" = "${HEADWIND_URL}" ] \
   && [ "$(jq -r '.os'           "${MDM}")" = "android" ] \
   && [ "$(jq -r '.set_via'      "${MDM}")" = "adb-device-owner" ]; then
    ok "A4 mdm.json: dpc_package, headwind_url, os=android, set_via=adb-device-owner"
else
    bad "A4 mdm.json fields wrong: $(cat "${MDM}" 2>/dev/null)"
fi
# THE DPC's ONLY CONFIG CHANNEL: assert the init.json payload that was actually
# pushed to the device — content and destination, not just that a push happened.
PUSHED_INIT="${STATE}/pushed/sdcard/Android/data/com.hmdm.launcher/files/init.json"
if [ -f "${PUSHED_INIT}" ] \
   && [ "$(jq -r '."com.hmdm.BASE_URL"' "${PUSHED_INIT}")" = "${HEADWIND_URL}" ] \
   && [ "$(jq -r 'keys | length'        "${PUSHED_INIT}")" = "1" ]; then
    ok "A4 init.json really pushed to the DPC files dir with com.hmdm.BASE_URL=${HEADWIND_URL}"
else
    bad "A4 pushed init.json missing/wrong at ${PUSHED_INIT}: $(cat "${PUSHED_INIT}" 2>/dev/null)"
fi

# A5 — attest: install the HugMesh Auditor fork and pair to the AttestationServer.
clear_logs
run attest --serial "${SERIAL}" --out "${OUT}" --attestation-url "${ATTEST_URL}" \
    --auditor-apk "${FIX}/auditor-fork.apk" --auditor-signer-sha256 "${SIGNER_OK}"
ATT="${OUT}/device/${DEVID}/attestation.json"
if [ "${RC}" -eq 0 ] && [ -f "${ATT}" ] \
   && [ "$(jq -r '.auditor_package' "${ATT}")" = "systems.hugmesh.auditor" ] \
   && [ "$(jq -r '.verdict'         "${ATT}")" = "operator-paired" ]; then
    ok "A5 attest: auditor_package=systems.hugmesh.auditor, verdict=operator-paired"
else
    bad "A5 attest rc=${RC}"; echo "${OUT_TXT}"
fi

# A5b — NEGATIVE CONTROL (proves the signer pin bites): re-point the mock at an
# attacker signer and re-attest; the driver must refuse with exit 3.
clear_logs
printf '%s' "${SIGNER_BAD}" > "${STATE}/apksigner-digest"
OUT_BAD="${WORK}/out-badsigner"; mkdir -p "${OUT_BAD}"
run attest --serial "${SERIAL}" --out "${OUT_BAD}" --attestation-url "${ATTEST_URL}" \
    --auditor-apk "${FIX}/auditor-fork.apk" --auditor-signer-sha256 "${SIGNER_OK}"
if [ "${RC}" -eq 3 ] && has "signer digest MISMATCH" \
   && [ ! -f "${OUT_BAD}/device/${DEVID}/attestation.json" ]; then
    ok "A5b NEGATIVE: attacker-signed Auditor -> exit 3, no attestation.json (pin fails closed)"
else
    bad "A5b bad-signer rc=${RC}, want 3"; echo "${OUT_TXT}"
fi
printf '%s' "${SIGNER_OK}" > "${STATE}/apksigner-digest"   # restore

# A6 — profile: create + escrow the enterprise secondary user. THIS forecloses
# device-owner mode, which is why it runs AFTER mdm-enroll.
clear_logs
run profile --serial "${SERIAL}" --out "${OUT}"
PROF="${OUT}/device/${DEVID}/profile.json"
ESCROW="${OUT}/vault-seed/device/${DEVID}/enterprise-profile.pass"
if [ "${RC}" -eq 0 ] && [ -f "${PROF}" ] \
   && [ "$(jq -r '.user_id'            "${PROF}")" = "10" ] \
   && [ "$(jq -r '.credential_custody' "${PROF}")" = "vault-seed" ]; then
    ok "A6 profile: enterprise user created (uid 10), profile.json custody=vault-seed"
else
    bad "A6 profile rc=${RC}"; echo "${OUT_TXT}"
fi
if [ -f "${ESCROW}" ] && [ "$(stat -c '%a' "${ESCROW}")" = "600" ]; then
    ok "A6 passphrase escrow written 0600 under vault-seed/"
else
    bad "A6 escrow missing or not 0600: ${ESCROW} ($(stat -c '%a' "${ESCROW}" 2>/dev/null))"
fi
# Capture the generated passphrase NOW, while the escrow exists — A10 retires it
# later, but the group-D sweep must still prove this real value never leaked.
A6_PASS="$(cat "${ESCROW}" 2>/dev/null || true)"
USERS_NOW="$(env PATH="${BIN}:${PATH}" PW_STUB_STATE="${STATE}" PW_STUB_LOG_DIR="${LOGD}" \
             adb -s "${SERIAL}" shell pm list users)"
grep -q 'UserInfo{10:enterprise' <<<"${USERS_NOW}" \
    && ok "A6 the mock now reports 2 users (device-owner mode is foreclosed from here on)" \
    || bad "A6 secondary user not reflected in device state"

# A7 — ingest: fold enrollment + mdm + attest + profile into one phone-ingest/v2
# record and POST it over mTLS.
clear_logs
if [ "${HAVE_OPENSSL}" -eq 1 ]; then
    run ingest --serial "${SERIAL}" --out "${OUT}" --ingest-url "${INGEST_URL}" \
        --client-cert "${CERT}" --client-key "${KEY}" --ca "${CA}"
    POSTED=1
else
    run ingest --serial "${SERIAL}" --out "${OUT}"   # emit-only (no openssl for mTLS)
    POSTED=0
fi
ING="${OUT}/device/${DEVID}/ingest.json"
if [ "${RC}" -eq 0 ] && [ -f "${ING}" ] \
   && [ "$(jq -r '.schema'                     "${ING}")" = "phone-ingest/v2" ] \
   && [ "$(jq -r '.device_class'               "${ING}")" = "phone" ] \
   && [ "$(jq -r '.os'                         "${ING}")" = "android" ] \
   && [ "$(jq -r '.serial'                     "${ING}")" = "${SERIAL}" ] \
   && [ "$(jq -r '.tailscale_ip'               "${ING}")" = "${CGNAT_ADDR}" ] \
   && [ "$(jq -r '.enterprise_profile.present' "${ING}")" = "true" ] \
   && [ "$(jq -r '.enterprise_profile.user_id' "${ING}")" = "10" ] \
   && [ "$(jq -r '.attestation_verdict'        "${ING}")" = "operator-paired" ] \
   && [ "$(jq -r '.auditor_package'            "${ING}")" = "systems.hugmesh.auditor" ]; then
    ok "A7 ingest: phone-ingest/v2 folds enrollment+attest+profile (os=android, profile present, attested)"
else
    bad "A7 ingest.json fields wrong: $(cat "${ING}" 2>/dev/null)"
fi
# The v2 mdm object must carry the REAL A4 mdm-enroll facts — a record claiming
# device-owner enrollment that never happened (or dropping one that did) is
# exactly what the registry consumes this for.
if [ "$(jq -r '.mdm.enrolled'     "${ING}")" = "true" ] \
   && [ "$(jq -r '.mdm.dpc_package'  "${ING}")" = "com.hmdm.launcher" ] \
   && [ "$(jq -r '.mdm.headwind_url' "${ING}")" = "${HEADWIND_URL}" ] \
   && [ "$(jq -r '.mdm.set_via'      "${ING}")" = "adb-device-owner" ] \
   && [ -n "$(jq -r '.mdm.enrolled_at // empty' "${ING}")" ]; then
    ok "A7 ingest: v2 mdm fold carries the A4 device-owner facts (dpc/url/set_via/at)"
else
    bad "A7 v2 mdm fold wrong: $(jq -c '.mdm' "${ING}" 2>/dev/null)"
fi
# The enrollment facts the registry actually consumes — a record naming the wrong
# coordination server would otherwise sail through.
if [ "$(jq -r '.login_server'        "${ING}")" = "${LOGIN_SERVER}" ] \
   && [ "$(jq -r '.marketing_name'   "${ING}")" = "Pixel 6" ] \
   && [ "$(jq -r '.role'             "${ING}")" = "user" ] \
   && [ "$(jq -r '.superdomain'      "${ING}")" = "hugmesh.internal" ] \
   && [ "$(jq -r '.tailscale_hostname' "${ING}")" = "phone-e2e-host" ]; then
    ok "A7 ingest folds the identity facts: login_server, marketing_name, role, superdomain, hostname"
else
    bad "A7 ingest identity fold wrong: $(jq -c '{login_server,marketing_name,role,superdomain,tailscale_hostname}' "${ING}" 2>/dev/null)"
fi
if [ "${POSTED}" -eq 1 ]; then
    # Assert the mTLS identity actually REACHED curl — not merely that the
    # operator supplied the flags (the mock refuses an identity-less POST).
    if grep -q -- '-X POST' "${LOGD}/curl.log" && grep -q -- "@${ING}" "${LOGD}/curl.log" \
       && grep -q -- "--cert ${CERT}" "${LOGD}/curl.log" \
       && grep -q -- "--key ${KEY}"   "${LOGD}/curl.log" \
       && grep -q -- "--cacert ${CA}" "${LOGD}/curl.log"; then
        ok "A7 ingest POSTed with a real mTLS client identity (--cert/--key/--cacert on curl argv)"
    else
        bad "A7 ingest POST missing mTLS identity in curl.log"; cat "${LOGD}/curl.log"
    fi
    # Fail-closed: --ingest-url WITHOUT mTLS identity must be refused by the driver.
    run ingest --serial "${SERIAL}" --out "${OUT}" --ingest-url "${INGEST_URL}"
    [ "${RC}" -eq 2 ] && ok "A7 ingest --ingest-url without --client-cert/--client-key -> exit 2 (fail-closed)" \
        || bad "A7 ingest missing-mTLS rc=${RC}, want 2"
else
    echo "  SKIP A7 mTLS POST (openssl unavailable) — record emitted only"
fi

# A8 — final state consistency: every lifecycle record exists and agrees on identity.
RECS_OK=1
for r in enrollment mdm attestation profile ingest; do
    [ -f "${OUT}/device/${DEVID}/${r}.json" ] || { RECS_OK=0; echo "    missing ${r}.json"; }
done
DID_ENR="$(jq -r '.device_id' "${ENR}" 2>/dev/null)"
DID_MDM="$(jq -r '.device_id' "${MDM}" 2>/dev/null)"
DID_ING="$(jq -r '.device_id' "${ING}" 2>/dev/null)"
if [ "${RECS_OK}" -eq 1 ] && [ "${DID_ENR}" = "${DEVID}" ] \
   && [ "${DID_MDM}" = "${DEVID}" ] && [ "${DID_ING}" = "${DEVID}" ]; then
    ok "A8 all 5 lifecycle records present and agree on device_id=${DEVID}"
else
    bad "A8 lifecycle records incomplete or inconsistent (enr=${DID_ENR} mdm=${DID_MDM} ing=${DID_ING})"
fi

# A9 — status: the read-only operator view of the now-onboarded device. The
# profile line is asserted as a WHOLE line — the pre-fix driver printed
# "present (user id 10)10" (a broken ${uid:+…}${uid:-…} expansion), so this
# exact-line check is what makes that rendering bug visible.
clear_logs
run status --serial "${SERIAL}" --out "${OUT}"
if [ "${RC}" -eq 0 ] \
   && has "tailnet (tun*): ${CGNAT_ADDR}" \
   && hasline "  profile 'enterprise': present (user id 10)" \
   && has "escrow (${DEVID}): present"; then
    ok "A9 status: tailnet addr, 'profile: present (user id 10)' (exact), escrow present"
else
    bad "A9 status rc=${RC}"; echo "${OUT_TXT}"
fi

# A10 — remove-profile then re-ingest: retiring the enterprise profile must be
# reflected downstream. The pre-fix driver retired only the escrow and left
# profile.json behind, so a re-ingest still reported the destroyed profile as
# present:true — feeding the registry a false record.
clear_logs
run remove-profile --serial "${SERIAL}" --out "${OUT}" --yes
if [ "${RC}" -eq 0 ] && has "user 10 ('enterprise') removed" \
   && compgen -G "${OUT}/device/${DEVID}/profile.json.revoked-*" >/dev/null \
   && [ ! -f "${OUT}/device/${DEVID}/profile.json" ]; then
    ok "A10 remove-profile: user removed, profile.json retired to .revoked-<ts>"
else
    bad "A10 remove-profile rc=${RC}"; echo "${OUT_TXT}"
fi
run ingest --serial "${SERIAL}" --out "${OUT}"
if [ "${RC}" -eq 0 ] && [ "$(jq -r '.enterprise_profile.present' "${ING}")" = "false" ]; then
    ok "A10 re-ingest after removal reports enterprise_profile.present=false (no false record)"
else
    bad "A10 re-ingest present-flag wrong: $(jq -c '.enterprise_profile' "${ING}" 2>/dev/null)"
fi

# ═══════════════════ Scenario B: ordering + one-shot device-owner ═══════════════════
echo "-- Scenario B: device-owner is one-shot; profile forecloses it --"
new_device android; clear_logs
OUTB="${WORK}/out-b"; mkdir -p "${OUTB}"

run profile --serial "${SERIAL}" --out "${OUTB}"
[ "${RC}" -eq 0 ] && [ -e "${STATE}/user-created" ] \
    && ok "B1 profile ran first and created the secondary user" \
    || { bad "B1 profile rc=${RC}"; echo "${OUT_TXT}"; }

run mdm-enroll --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
[ "${RC}" -eq 2 ] && has "device-owner mode is no longer obtainable" \
    && ok "B2 mdm-enroll after profile -> exit 2 (foreclosed) — ordering constraint enforced e2e" \
    || { bad "B2 mdm-enroll-after-profile rc=${RC}, want 2"; echo "${OUT_TXT}"; }
[ ! -f "${OUTB}/device/${DEVID}/mdm.json" ] \
    && ok "B2 no mdm.json written on the foreclosed device" \
    || bad "B2 mdm.json written despite foreclosure"

new_device android; add_account; clear_logs
run mdm-enroll --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
[ "${RC}" -eq 2 ] && has "account(s) added" \
    && ok "B3 mdm-enroll with an added account -> exit 2 (account gate)" \
    || { bad "B3 mdm-enroll-with-account rc=${RC}, want 2"; echo "${OUT_TXT}"; }

# B4 — NEGATIVE CONTROL (proves the dpm failure path is real): provisioning
# refused (the Play-Protect DPC-allow-list case the driver warns about).
new_device android; touch "${STATE}/dpm-fail"; clear_logs
run mdm-enroll --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
[ "${RC}" -eq 1 ] && has "dpm set-device-owner failed" && has "Play Protect" \
    && ok "B4 NEGATIVE: refused provisioning -> exit 1 with the Play-Protect hint (stock Android)" \
    || { bad "B4 dpm-fail rc=${RC}, want 1"; echo "${OUT_TXT}"; }

# B5 — device-owner is ONE-SHOT: a second mdm-enroll on an already-owned device
# fails the way real AOSP does (the mock latches), rather than silently winning.
new_device android; clear_logs
run mdm-enroll --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
FIRST_RC="${RC}"
run mdm-enroll --serial "${SERIAL}" --out "${OUTB}" --headwind-url "${HEADWIND_URL}" \
    --headwind-apk "${FIX}/headwind-dpc.apk" --headwind-signer-sha256 "${SIGNER_OK}"
[ "${FIRST_RC}" -eq 0 ] && [ "${RC}" -eq 1 ] && has "device owner is already set" \
    && ok "B5 device-owner is one-shot: first enroll 0, re-enroll -> exit 1 (AOSP latch)" \
    || { bad "B5 re-enroll rc=${RC} (first=${FIRST_RC}), want 0 then 1"; echo "${OUT_TXT}"; }

# ═══════════════════ Scenario C: OS classification ═══════════════════
echo "-- Scenario C: OS classification is real, not hardcoded --"
OUTC="${WORK}/out-c"; mkdir -p "${OUTC}"
C_ARGS=(--out "${OUTC}" --login-server "${LOGIN_SERVER}" --authkey-file "${AUTHKEY_FILE}" \
        --tailscale-apk "${FIX}/tailscale.apk" --apk-signer-sha256 "${SIGNER_OK}")

new_device grapheneos; device_joins; clear_logs
run enroll --serial "${SERIAL}" "${C_ARGS[@]}"
ENRC="${OUTC}/device/${DEVID}/enrollment.json"
if [ "${RC}" -eq 0 ] && [ "$(jq -r '.os' "${ENRC}" 2>/dev/null)" = "grapheneos" ] \
   && [ "$(jq -r '.os_version' "${ENRC}" 2>/dev/null)" = "2026071500" ]; then
    ok "C1 GrapheneOS build enrolls as os=grapheneos (both device classes first-class)"
else
    bad "C1 GrapheneOS classification wrong: $(jq -c '{os,os_version}' "${ENRC}" 2>/dev/null)"; echo "${OUT_TXT}"
fi

# C2 — IMPOSTOR: a non-GrapheneOS ROM whose incremental is datestamp-shaped must
# NOT be promoted to grapheneos. This is what makes the driver's documented
# "datestamp AND marker" gate load-bearing — the datestamp alone is not unique.
rm -rf "${OUTC:?}/device"
new_device impostor; device_joins; clear_logs
run enroll --serial "${SERIAL}" "${C_ARGS[@]}"
if [ "${RC}" -eq 0 ] && [ "$(jq -r '.os' "${ENRC}" 2>/dev/null)" = "android" ]; then
    ok "C2 IMPOSTOR ROM (datestamp incremental, no GrapheneOS marker) -> os=android, not promoted"
else
    bad "C2 impostor misclassified: $(jq -c '{os,os_version}' "${ENRC}" 2>/dev/null)"; echo "${OUT_TXT}"
fi

# C3 — NEGATIVE CONTROL (proves the --force gate is real and reachable): a
# genuinely undetectable OS is refused, and --force downgrades it to a warning.
rm -rf "${OUTC:?}/device"
new_device undetectable; device_joins; clear_logs
run enroll --serial "${SERIAL}" "${C_ARGS[@]}"
[ "${RC}" -eq 2 ] && has "pass --force to enroll anyway" \
    && ok "C3 NEGATIVE: undetectable OS -> exit 2 (the --force gate is real)" \
    || { bad "C3 undetectable rc=${RC}, want 2"; echo "${OUT_TXT}"; }
run enroll --serial "${SERIAL}" "${C_ARGS[@]}" --force
[ "${RC}" -eq 0 ] && [ "$(jq -r '.os' "${ENRC}" 2>/dev/null)" = "unknown" ] \
    && ok "C3 --force enrolls the undetectable device, recorded honestly as os=unknown" \
    || { bad "C3 --force rc=${RC}: $(jq -c '{os}' "${ENRC}" 2>/dev/null)"; echo "${OUT_TXT}"; }

# ═══════════════════ Scenario E: no-USB operator-attested join ═══════════════════
# The USB-less path (no adb whatsoever): the operator drives the handset by hand
# and the wizard records an operator-attested enrollment, then the SAME 'ingest'
# the NEXT-STEPS block prescribes folds it into a registry record. This is the
# recommended no-USB flow — enroll --no-usb WITH --codename (there is no probe to
# read the model), then ingest.
echo "-- Scenario E: no-USB operator-attested lifecycle --"
new_device android; clear_logs
OUTE="${WORK}/out-e"; mkdir -p "${OUTE}"
NOUSB_ID="phone-nousb01"
# E0 — NEGATIVE: no adb probe runs in --no-usb, so the model can't be read; a
# missing --codename must fail clearly (rc 1) rather than record an empty
# codename that strands the follow-up ingest. Makes ZERO adb calls.
run enroll --no-usb --device-id "${NOUSB_ID}" \
    --login-server "${LOGIN_SERVER}" --authkey-file "${AUTHKEY_FILE}" --out "${OUTE}"
if [ "${RC}" -eq 1 ] && has "needs --codename" && [ ! -s "${LOGD}/adb.log" ] \
   && [ ! -f "${OUTE}/device/${NOUSB_ID}/enrollment.json" ]; then
    ok "E0 NEGATIVE: --no-usb without --codename -> exit 1 (no record written, zero adb)"
else
    bad "E0 no-usb-no-codename rc=${RC}, want 1"; echo "${OUT_TXT}"
fi
clear_logs
run enroll --no-usb --device-id "${NOUSB_ID}" --codename "${CODENAME}" \
    --login-server "${LOGIN_SERVER}" --authkey-file "${AUTHKEY_FILE}" --out "${OUTE}"
ENRE="${OUTE}/device/${NOUSB_ID}/enrollment.json"
if [ "${RC}" -eq 0 ] && [ -f "${ENRE}" ] \
   && [ "$(jq -r '.verification'  "${ENRE}")" = "operator-attested" ] \
   && [ "$(jq -r '.tailscale_ip'  "${ENRE}")" = "null" ] \
   && [ "$(jq -r '.codename'      "${ENRE}")" = "${CODENAME}" ]; then
    ok "E1 no-USB enroll: operator-attested, tailscale_ip:null, codename recorded"
else
    bad "E1 no-USB enroll rc=${RC}: $(cat "${ENRE}" 2>/dev/null)"
fi
[ ! -s "${LOGD}/adb.log" ] \
    && ok "E1 no-USB made ZERO adb calls (no device was tethered)" \
    || { bad "E1 no-USB touched adb"; cat "${LOGD}/adb.log"; }
run ingest --device-id "${NOUSB_ID}" --out "${OUTE}"
INGE="${OUTE}/device/${NOUSB_ID}/ingest.json"
if [ "${RC}" -eq 0 ] && [ -f "${INGE}" ] \
   && [ "$(jq -r '.os'                         "${INGE}")" = "unknown" ] \
   && [ "$(jq -r '.marketing_name'             "${INGE}")" = "Pixel 6" ] \
   && [ "$(jq -r '.enterprise_profile.present' "${INGE}")" = "false" ]; then
    ok "E2 no-USB ingest folds the operator-attested record (os=unknown, Pixel 6, no profile)"
else
    bad "E2 no-USB ingest rc=${RC}: $(jq -c '{os,marketing_name,profile:.enterprise_profile.present}' "${INGE}" 2>/dev/null)"
fi

# ═══════════════════ Scenario D: secret sweep (cumulative argv) ═══════════════════
echo "-- Scenario D: no secret leaked anywhere across the entire e2e --"
# D0 — POSITIVE CONTROL: the argv sweep must be PROVEN to bite. The driver has a
# documented, deliberately-gated argv-exposure mode (--i-understand-adb-exposure)
# that DOES put the passphrase on adb argv. Run it on a throwaway device/out and
# assert the sweep FINDS it — otherwise D1/D2 below are unfalsifiable.
new_device android; clear_logs
OUTD="${WORK}/out-d"; mkdir -p "${OUTD}"
run profile --serial "${SERIAL}" --out "${OUTD}" --i-understand-adb-exposure
CTRL_PASS="$(cat "${OUTD}/vault-seed/device/${DEVID}/enterprise-profile.pass" 2>/dev/null || true)"
CTRL_ARGV="$(cat "${LOGD}"/*.log 2>/dev/null || true)"
if [ -n "${CTRL_PASS}" ] && grep -qF -- "${CTRL_PASS}" <<<"${CTRL_ARGV}"; then
    ok "D0 POSITIVE CONTROL: the argv sweep is live (the deliberately-exposed passphrase IS found in adb argv)"
else
    bad "D0 argv sweep is NOT live — the exposed passphrase was not found, so D1/D2 prove nothing"
fi
clear_logs   # drains the control's argv into ARGV_ALL as well

# Assemble the full sweep: stdout/stderr of every default-path run + the
# CUMULATIVE argv archive + whatever is still in the live logs.
PASS_VAL="${A6_PASS}"   # captured in A6, before A10 retired the escrow
SWEEP_ALL="${WORK}/sweep-all.log"
cat "${SWEEP}" "${ARGV_ALL}" "${LOGD}"/*.log > "${SWEEP_ALL}" 2>/dev/null || true

if grep -qF -- "${AUTHKEY_SENTINEL}" "${SWEEP_ALL}"; then
    bad "D1 pre-auth key LEAKED into output/argv"
else
    ok "D1 pre-auth key never reached stdout/stderr or any stub argv"
fi
if [ -z "${PASS_VAL}" ]; then
    bad "D2 could not read Scenario A's escrowed passphrase — the sweep would be vacuous"
elif grep -qF -- "${PASS_VAL}" "${SWEEP_ALL}"; then
    bad "D2 profile passphrase LEAKED into output/argv (default path must never expose it)"
else
    ok "D2 Scenario A's escrowed passphrase never reached stdout/stderr or any stub argv"
fi
if [ -n "${PASS_VAL}" ] && [ "${#PASS_VAL}" -ge 28 ]; then
    ok "D3 sweep is meaningful: a real >=28-char passphrase exists in the 0600 escrow"
else
    bad "D3 escrow passphrase missing/short — sweep would be vacuous"
fi

# ── Summary ────────────────────────────────────────────────────────
echo "== e2e result: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
