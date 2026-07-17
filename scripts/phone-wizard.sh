#!/usr/bin/env bash
# phone-wizard.sh — enterprise-phone onboarding driver (GrapheneOS on Google Pixel).
#
# This is the FOURTH onboarding form, alongside the appliance images, the client
# desktops, and the Local Docker mesh node (clients/docker-mesh-node). It takes a
# USB-connected Google Pixel and turns it into an enterprise-managed mesh device:
#
#   detect -> fetch (verified GrapheneOS -install- zip) -> flash -> attest
#   (self-hosted AttestationServer pairing, via a Snapdragon-forked Auditor
#   app) -> mdm-enroll (Headwind MDM device-owner enrollment — MUST run before
#   'profile', which permanently forecloses device-owner mode) -> enroll
#   (headscale tailnet join, register-and-approve) -> profile (a separately-
#   encrypted GrapheneOS secondary user whose credential is escrowed into the
#   platform's per-device vault-seed custody chain) -> ingest (device registry).
#
# `enroll` is ALSO a first-class standalone path for phones this wizard never
# flashed: an already-running GrapheneOS phone OR a stock Android phone (the
# OS probe records which, it never gates enrollment). `enroll --no-usb` drops
# the adb dependency entirely — a guided handset runbook plus an
# operator-attested record, for hosts with no USB/adb access to the device.
# `flash` remains GrapheneOS/Pixel-only.
#
# It follows the repo's documented NON-BUILD precedent: the phone is NOT a
# build-matrix cell, NOT a platform, NOT a WorklistEntry — like the Local Docker
# mesh and the go-live wizard triad, this driver owns ALL the logic and the
# menu/GUI faces stay thin.
#
# MANAGEMENT PLANE (Phase 3 — supersedes the earlier "no MDM agent" non-goal):
# self-hosted Headwind MDM (com.hmdm.launcher/.AdminReceiver, set via adb
# device-owner) is the on-phone DPC for every enrolled phone; self-hosted
# GrapheneOS AttestationServer (paired via a Snapdragon-forked Auditor app,
# package systems.snapdragon.auditor) is the hardware-rooted trust signal.
# Both are tailnet-only optional-services on the existing cluster — no SaaS/
# commercial MDM, no Google Play Integrity, no Google FCM/Pub/Sub dependency.
# Attestation is advisory/logged (not enrollment-blocking) in v1. Remaining
# NON-GOALS: no APK store, no fleet-wide OTA/compliance posture beyond what
# Headwind CE ships. Deferred work (Casdoor SSO for Headwind, an automated
# `attest --attestation-verdict-source api` mode, GrapheneOS QR provisioning)
# is tracked in docs/ENTERPRISE-PHONES.md.
#
# SECRET-CUSTODY MODEL: no secret ever travels on argv, in PLAN output, or to
# stdout/logs (REDACTED presence markers only). The tailscale pre-auth key and
# the enterprise-profile passphrase move via 0600 files only (--authkey-file /
# --pass-file / the vault-seed escrow dir). The generated profile passphrase is
# escrowed under <out>/vault-seed/device/<device-id>/ — destined for Vault at
# secret/<brand>/device/<device-id>/phone-profile — and is by DEFAULT set on the
# handset by the operator (setting it over `adb shell` puts it in adb argv,
# which is visible BOTH phone-side (logcat/ps on the device) AND on THIS
# host, in the local adb client's own argv (ps/procfs) for the life of that
# process — a real risk on shared provisioning hosts/jump boxes/CI runners;
# that path requires --i-understand-adb-exposure).
#
# Docs: docs/ENTERPRISE-PHONES.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/_download-lib.sh
source "${SCRIPT_DIR}/_download-lib.sh"

# ── Pinned GrapheneOS supply-chain facts (see scripts/phone-allowed-signers) ─
GRAPHENE_IDENTITY="contact@grapheneos.org"
GRAPHENE_NAMESPACE="factory images"
GRAPHENE_SIGNER_FP_PIN="SHA256:AhgHif0mei+9aNyKLfMZBh2yptHdw/aN7Tlh/j2eFwM"

# ── Snapdragon Auditor fork identity (Phase 3 attestation coupling) ────────
# applicationId is deliberately DIFFERENT from the stock GrapheneOS Auditor
# (app.attestation.auditor) — avoids clobbering a stock install and keeps the
# --auditor-signer-sha256 pin unambiguous. See docs/ENTERPRISE-PHONES.md for
# the fork rationale (DOMAIN=attestation.snapdragon.systems, own release key).
AUDITOR_PACKAGE="systems.snapdragon.auditor"

# ── Env seams (tests override these; defaults are the real thing) ──
ADB="${PW_ADB:-adb}"
FASTBOOT="${PW_FASTBOOT:-fastboot}"
RELEASES_URL="${PW_RELEASES_URL:-https://releases.grapheneos.org}"
ALLOWED_SIGNERS="${PW_ALLOWED_SIGNERS:-${SCRIPT_DIR}/phone-allowed-signers}"
DEVICES_TSV="${SCRIPT_DIR}/phone-devices.tsv"
JOIN_TIMEOUT="${PW_JOIN_TIMEOUT:-300}"      # seconds to wait for tailscale0
POLL_INTERVAL="${PW_POLL_INTERVAL:-5}"      # seconds between polls

# ── Options (defaults) ─────────────────────────────────────────────
SERIAL=""
CODENAME=""
CHANNEL="stable"
GRAPHENE_VERSION=""
WORK_DIR="${REPO_DIR}/out/phone-wizard"
OUT_DIR="${REPO_DIR}/out/phone-wizard/keys-out"
KEYS_DIR=""
LOGIN_SERVER=""
AUTHKEY_FILE=""
PASS_FILE=""
DEVICE_ID=""
SUPERDOMAIN="snapdragon.internal"
SUPERDOMAIN_SET=0
ROLE=""
PROFILE_NAME="enterprise"
TAILSCALE_APK=""
APK_SIGNER_SHA256=""
HEADWIND_APK=""
HEADWIND_SIGNER_SHA256=""
HEADWIND_URL="${HMDM_URL:-}"
AUDITOR_APK=""
AUDITOR_SIGNER_SHA256=""
ATTESTATION_URL="${ATTEST_URL:-}"
INGEST_URL=""
CLIENT_CERT=""
CLIENT_KEY=""
CA_FILE=""
ASSUME_YES=0
FORCE=0
FORCE_FWUPD=0
SHOW_AUTHKEY=0
ADB_EXPOSURE_OK=0
RESOLVE=0
NO_COLOR=0
PRINT_PLAN=0
NO_USB=0

# ── Logging (stdout is reserved for machine lines + runbooks) ──────
C_RED=''; C_GRN=''; C_YEL=''; C_RST=''
apply_colors() {
    if [ -t 2 ] && [ "${NO_COLOR}" -eq 0 ]; then
        C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RST=$'\033[0m'
    else
        C_RED=''; C_GRN=''; C_YEL=''; C_RST=''
    fi
}
apply_colors
pw_info() { printf '%s[phone-wizard]%s %s\n' "${C_GRN}" "${C_RST}" "$*" >&2; }
pw_warn() { printf '%s[phone-wizard] WARN:%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
# pw_die <exit-code> <message…> — every abnormal exit goes through here so the
# exit-code contract stays auditable: 1 usage/runtime, 2 missing tool /
# precondition / refused gate, 3 signature or pin verify failure (tamper),
# 4 unknown codename / requested device not found.
pw_die() { local rc="$1"; shift; printf '%s[phone-wizard] ERROR:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit "${rc}"; }
have()   { command -v "$1" >/dev/null 2>&1; }

# _need_arg <flag> <remaining-arg-count> — every value-taking option in
# main()'s parse loop calls this before dereferencing "$2", so an option
# given as the last argument (no value) fails through the controlled
# usage()/pw_die() path instead of bash's own uncaught "unbound variable"
# abort under set -u.
_need_arg() { [ "$2" -ge 2 ] || pw_die 1 "option $1 requires a value"; }

# Missing tool → exit 2, naming it + an install hint (fail-closed preflight).
require_tool() {
    local t="$1" hint="$2"
    have "${t}" || pw_die 2 "missing required tool: ${t} — ${hint}"
}
require_android_tools() {
    require_tool "${ADB}" "install android-tools (Gentoo: dev-util/android-tools; Debian: apt install android-sdk-platform-tools)"
    require_tool "${FASTBOOT}" "install android-tools >= 35.0.2 (GrapheneOS requires fastboot >= 35.0.2)"
}

usage() {
cat <<EOF
Usage: $0 <verb> [options]

  Enterprise-phone wizard: flash a USB-connected Google Pixel with VERIFIED
  GrapheneOS, enroll it in the brand's orchestration superdomain (headscale
  tailnet), pair it to the self-hosted AttestationServer trust root, enroll it
  as a Headwind MDM device-owner, provision an escrowed enterprise profile,
  and emit a device-registry ingest record. The DEFAULT posture is
  dry-run/read-only: only 'fetch', 'flash', 'attest', 'mdm-enroll', 'enroll',
  'profile', 'rotate-profile-pass', 'remove-profile' and 'ingest' change
  anything, and the destructive ones are gated.

Verbs:
  plan [verb]          Dry-run (DEFAULT target: wizard). Validates options +
                       catalog lookup, prints PLAN_<K>=<V> lines, touches
                       NOTHING. Fully offline unless --resolve is passed
                       (version prints as resolve-at-fetch when unknown).
                       --print-plan anywhere is an alias for this verb.
  detect               Read-only probe: adb/fastboot device list, serial,
                       codename, current OS fingerprint. Prints DEVICE_* lines.
  fetch                Resolve the --channel release, download the GrapheneOS
                       <codename>-install-<version>.zip(+.sig) into --work-dir,
                       verify the sshsig FAIL-CLOSED, extract, write a
                       .verified-<sha256> marker. Idempotent.
  flash                DESTRUCTIVE: wipe the phone and flash the VERIFIED
                       artifact. Typed-serial confirmation on a TTY; non-TTY
                       requires BOTH --yes AND a matching --serial.
  attest               Install the Snapdragon-forked Auditor (signer-pinned
                       via --auditor-signer-sha256) and print the pairing
                       runbook for the self-hosted AttestationServer at
                       --attestation-url. The in-app QR scan cannot be driven
                       over adb — this is an OPERATOR-ATTESTED pairing
                       (verdict:"operator-paired"), not a cryptographic
                       verification by this wizard. Runs BEFORE mdm-enroll:
                       captures the hardware trust root on the cleanest
                       possible device state.
  mdm-enroll           Enroll the phone as a Headwind MDM device-owner
                       (com.hmdm.launcher/.AdminReceiver via
                       `dpm set-device-owner`). FRESH-DEVICE precondition:
                       `pm list users` must show exactly ONE user, else this
                       fails closed (exit 2) — device-owner mode is a
                       one-shot AOSP gate, permanently foreclosed once a
                       secondary user/account exists (--force downgrades to
                       a warning). MUST run before 'profile'. Installs the
                       DPC via --headwind-apk (signer-pinned via
                       --headwind-signer-sha256) and pushes an init.json
                       (com.hmdm.BASE_URL=--headwind-url) into the app's
                       external files dir. GrapheneOS device-owner via adb is
                       RELIABLE; stock-Android is BEST-EFFORT (Play Protect's
                       DPC allow-list may block provisioning — not a wizard
                       bug).
  enroll               Add a running phone to the mesh (freshly flashed OR an
                       ALREADY-RUNNING GrapheneOS or stock-Android phone — the
                       OS probe records which, it never gates enrollment;
                       'flash' stays GrapheneOS/Pixel-only). Post-first-boot
                       (adb): guided tailnet join with keys from --keys-dir
                       (docker-mesh-node layout) or --login-server/
                       --authkey-file; verifies tailscale0 and writes the
                       enrollment record. --no-usb skips every adb probe:
                       guided handset-only runbook, operator-attested record
                       (tailscale_ip left null) — verify the join mesh-side.
  profile              Create the "enterprise" secondary user, generate +
                       escrow its passphrase (vault-seed custody), operator
                       sets the credential on the handset (default path).
  rotate-profile-pass  Generate + escrow a new profile passphrase atomically
                       (previous escrow kept as .prev-<ts>).
  remove-profile       DESTRUCTIVE: remove the enterprise user (typed
                       profile-name confirm, or --yes); escrow -> .revoked-<ts>.
  ingest               Emit the phone-ingest/v1 device-registry record;
                       with --ingest-url + mTLS flags, POST it.
  status               Read-only: tools, device, tailnet, profile, escrow
                       presence (never contents).
  wizard               Interactive guided full flow (TTY): detect -> fetch ->
                       flash -> attest -> mdm-enroll -> enroll -> profile ->
                       ingest, re-entrant.
  help                 This help.

Options:
  --serial S             Target device serial (required when several devices
                         are connected; compared against what is detected).
  --codename C           Device codename (see scripts/phone-devices.tsv).
  --channel CH           Release channel: stable|beta|alpha. Default: ${CHANNEL}
  --graphene-version V   Pin an exact release (skips channel resolution).
  --work-dir D           Artifact dir. Default: ${WORK_DIR}
  --out D                Output tree (enrollment/profile/ingest records +
                         vault-seed escrow). Default: ${OUT_DIR}
  --keys-dir D           Keys dir, docker-mesh-node layout: login-server,
                         tailscale/authkey, casdoor.json, role.
  --login-server URL     Headscale control URL (overrides keys-dir).
  --authkey-file F       0600 file holding the one-time pre-auth key.
  --pass-file F          0600 file supplying the profile passphrase (else one
                         is generated from /dev/urandom).
  --device-id ID         Stable device id ([a-z0-9-]); default
                         phone-<sanitized serial>.
  --superdomain D        Orchestration superdomain (MagicDNS base).
                         Default: ${SUPERDOMAIN}
  --role R               Mesh role (user|mod|admin|superadmin). Default: user
                         (or the keys-dir role file).
  --profile-name N       Secondary-user name. Default: ${PROFILE_NAME}
  --tailscale-apk F      Tailscale APK to adb-install during enroll.
  --apk-signer-sha256 H  Pin: APK signer cert SHA-256 (fail-closed if set).
  --headwind-apk F       Headwind DPC APK to adb-install during mdm-enroll.
  --headwind-signer-sha256 H
                         Pin: Headwind APK signer cert SHA-256 (fail-closed
                         if set).
  --headwind-url URL     Headwind server base URL, written into the DPC's
                         non-interactive init.json config
                         (com.hmdm.BASE_URL). Env: HMDM_URL.
  --auditor-apk F        Snapdragon Auditor fork APK to adb-install during
                         attest.
  --auditor-signer-sha256 H
                         Pin: Auditor APK signer cert SHA-256 (fail-closed
                         if set) — the fork's release-cert digest.
  --attestation-url URL  Self-hosted AttestationServer console URL, printed
                         in the attest pairing runbook. Env: ATTEST_URL.
  --ingest-url URL       POST the ingest record here (needs the mTLS flags).
  --client-cert F --client-key F --ca F
                         mTLS client identity + CA for --ingest-url.
  --yes                  Non-interactive confirmation (see per-verb gates).
  --force                Downgrade hard-requirement checks to warnings: the
                         enroll OS-probe (OS genuinely undetectable), the
                         flash fastboot-version preflight (version string
                         unparsable — normally enforces GrapheneOS's
                         >=35.0.2 requirement), and the enroll Tailscale-
                         package-appear wait (skip confirming install).
  --force-fwupd          Proceed with flashing even if fwupd is running.
  --show-authkey         Display the pre-auth key ONCE during enroll (default:
                         never displayed; operator pastes from own custody).
  --no-usb               enroll only: skip every adb probe. Prints a guided
                         handset-only runbook (Tailscale install, login
                         server, authkey custody) and records an
                         operator-attested enrollment (tailscale_ip null) —
                         verify the join mesh-side afterwards. Needs
                         --device-id (no adb serial to derive one from).
  --i-understand-adb-exposure
                         Set the profile credential over adb (the passphrase
                         lands in adb argv — visible via ps/procfs on THIS
                         host as well as phone-side (logcat/ps); documented
                         residual exposure; default is operator-set).
  --resolve              Allow 'plan' to resolve the version (network).
  --print-plan           Alias for the 'plan' verb (plans the given verb).
  --no-color             Disable colored logging.
  -h, --help             This help.

Env seams (tests): PW_ADB, PW_FASTBOOT, PW_RELEASES_URL, PW_ALLOWED_SIGNERS,
  PW_EXPECTED_SIGNER_FP (empty allowed ONLY with PW_ALLOWED_SIGNERS overridden),
  PW_SKIP_FP_PIN=1, PW_JOIN_TIMEOUT, PW_POLL_INTERVAL,
  PW_FASTBOOT_REAPPEAR_TIMEOUT.
  Also: HMDM_URL / ATTEST_URL supply default --headwind-url /
  --attestation-url values (an explicit flag always wins).

Exit codes:
  0 success   1 usage/runtime error   2 missing tool / precondition / refused
  3 signature or fingerprint-pin verification failure (tamper — artifact deleted)
  4 unknown codename / requested device not found
EOF
exit "${1:-0}"
}

# ── Small helpers ──────────────────────────────────────────────────
now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_ts()  { date -u '+%Y%m%dT%H%M%SZ'; }

# Sanitize an id to the [a-z0-9-] charset a k8s object name / Vault path
# segment allows (mirrors gen-provision-keys.sh DEVICE_ID sanitation).
sanitize_id() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-' | sed -e 's/^-*//' -e 's/-*$//'
}

# POSIX single-quote-escape a value for interpolation into a REMOTE shell
# command string (adb shell re-joins argv into one command line device-side —
# local bash argv-array separation does not survive the trip). Used anywhere
# a secret/operator value must be handed to `adb shell` safely.
quote_for_remote_sh() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Fail-closed --profile-name charset gate: this value is interpolated into a
# `pm create-user` remote-shell command and (via profile_user_id) used to
# match an on-device user — restrict it to a safe, unambiguous charset so
# neither trip can be abused.
validate_profile_name() {
    [[ "${PROFILE_NAME}" =~ ^[A-Za-z0-9_-]+$ ]] || pw_die 1 "invalid --profile-name '${PROFILE_NAME}' (must match [A-Za-z0-9_-]+)"
}

# Resolve DEVICE_ID: explicit --device-id (sanitized) wins; else derive from
# the serial. Empty when neither is known yet (plan prints a placeholder).
resolve_device_id() {
    if [ -n "${DEVICE_ID}" ]; then
        DEVICE_ID="$(sanitize_id "${DEVICE_ID}")"
        [ -n "${DEVICE_ID}" ] || pw_die 1 "--device-id reduced to empty after sanitising (use [a-z0-9-])"
    elif [ -n "${SERIAL}" ]; then
        DEVICE_ID="phone-$(sanitize_id "${SERIAL}")"
    fi
}

# Catalog lookup: codename -> marketing name on stdout; rc 1 when absent.
catalog_lookup() {
    [ -f "${DEVICES_TSV}" ] || pw_die 2 "device catalog missing: ${DEVICES_TSV}"
    awk -F'\t' -v c="$1" '!/^#/ && NF>=2 && $1==c { print $2; exit }' "${DEVICES_TSV}" | grep . || return 1
}

# Fail-closed codename gate (exit 4, no --allow-unknown escape in v1).
require_codename() {
    [ -n "${CODENAME}" ] || pw_die 1 "a device codename is required (pass --codename, or connect the device so 'detect' can read it)"
    DEVICE_NAME="$(catalog_lookup "${CODENAME}")" || pw_die 4 "unknown codename '${CODENAME}' — not in ${DEVICES_TSV}. Check https://grapheneos.org/releases and extend the catalog if this is a new device."
}

validate_channel() {
    case "${CHANNEL}" in
        stable|beta|alpha) : ;;
        *) pw_die 1 "--channel must be stable|beta|alpha (got '${CHANNEL}')" ;;
    esac
}

# Effective signer-fingerprint pin. Fail-closed: skipping the pin while still
# trusting the DEFAULT allowed_signers file is refused — an empty pin is only
# meaningful when the test harness supplies its own signers file.
effective_signer_fp() {
    local fp
    if [ "${PW_SKIP_FP_PIN:-0}" = "1" ]; then
        fp=""
    else
        fp="${PW_EXPECTED_SIGNER_FP-${GRAPHENE_SIGNER_FP_PIN}}"
    fi
    if [ -z "${fp}" ] && [ -z "${PW_ALLOWED_SIGNERS:-}" ]; then
        pw_die 3 "refusing to skip the signer fingerprint pin while using the default allowed_signers (${ALLOWED_SIGNERS}); override PW_ALLOWED_SIGNERS too, or set PW_SKIP_FP_PIN=1"
    fi
    printf '%s' "${fp}"
}

# ── Keys-dir resolution (docker-mesh-node contract) ────────────────
# Files (all optional individually; see clients/docker-mesh-node/keys.example):
#   <keys-dir>/login-server        headscale control URL
#   <keys-dir>/tailscale/authkey   one-time pre-auth key (or <keys-dir>/authkey)
#   <keys-dir>/casdoor.json        { issuer, client_id, domain }
#   <keys-dir>/role                user|mod|admin|superadmin
ATTACHED_DOMAIN=""
resolve_keys() {
    if [ -n "${KEYS_DIR}" ]; then
        [ -d "${KEYS_DIR}" ] || pw_die 1 "--keys-dir not found: ${KEYS_DIR}"
        if [ -z "${LOGIN_SERVER}" ] && [ -f "${KEYS_DIR}/login-server" ]; then
            LOGIN_SERVER="$(tr -d ' \n' < "${KEYS_DIR}/login-server")"
        fi
        local f
        for f in "${KEYS_DIR}/tailscale/authkey" "${KEYS_DIR}/authkey"; do
            [ -z "${AUTHKEY_FILE}" ] && [ -f "${f}" ] && AUTHKEY_FILE="${f}"
        done
        if [ -z "${ROLE}" ] && [ -f "${KEYS_DIR}/role" ]; then
            ROLE="$(tr -d ' \n' < "${KEYS_DIR}/role")"
        fi
        if [ -f "${KEYS_DIR}/casdoor.json" ] && have jq; then
            ATTACHED_DOMAIN="$(jq -r '.domain // empty' "${KEYS_DIR}/casdoor.json" 2>/dev/null || true)"
        fi
    fi
    ROLE="${ROLE:-user}"
}

# ── Device probing ─────────────────────────────────────────────────
FB_SERIALS=()
ADB_SERIALS=()
list_devices() {
    FB_SERIALS=(); ADB_SERIALS=()
    local out line s state
    out="$("${FASTBOOT}" devices 2>/dev/null || true)"
    while IFS= read -r line; do
        s="$(awk '{print $1}' <<<"${line}")"
        state="$(awk '{print $2}' <<<"${line}")"
        [ -n "${s}" ] && [ "${state}" = "fastboot" ] && FB_SERIALS+=("${s}")
    done <<<"${out}"
    out="$("${ADB}" devices -l 2>/dev/null || true)"
    while IFS= read -r line; do
        case "${line}" in ''|'List of devices'*|\**) continue ;; esac
        s="$(awk '{print $1}' <<<"${line}")"
        state="$(awk '{print $2}' <<<"${line}")"
        case "${state}" in
            device) ADB_SERIALS+=("${s}") ;;
            unauthorized) pw_warn "device ${s} is UNAUTHORIZED — accept the USB-debugging prompt on the handset" ;;
            *) : ;;
        esac
    done <<<"${out}"
}

# Choose the target device. Sets SEL_SERIAL + SEL_STATE (fastboot|adb).
# Ambiguity without --serial → exit 2 listing serials; a --serial that is not
# connected → exit 4; nothing connected → exit 2.
SEL_SERIAL=""
SEL_STATE=""
choose_device() {
    list_devices
    local all=() s
    for s in ${FB_SERIALS[@]+"${FB_SERIALS[@]}"}; do all+=("${s}:fastboot"); done
    for s in ${ADB_SERIALS[@]+"${ADB_SERIALS[@]}"}; do all+=("${s}:adb"); done
    if [ -n "${SERIAL}" ]; then
        for s in ${all[@]+"${all[@]}"}; do
            if [ "${s%%:*}" = "${SERIAL}" ]; then
                SEL_SERIAL="${SERIAL}"; SEL_STATE="${s##*:}"
                return 0
            fi
        done
        pw_die 4 "device with serial '${SERIAL}' is not connected (connected: $(printf '%s ' ${all[@]+"${all[@]}"}))"
    fi
    case "${#all[@]}" in
        0) pw_die 2 "no device detected — connect the phone over USB (adb: enable USB debugging; fastboot: boot the bootloader) and retry" ;;
        1) SEL_SERIAL="${all[0]%%:*}"; SEL_STATE="${all[0]##*:}" ;;
        *) pw_die 2 "multiple devices connected — pass --serial. Connected: $(printf '%s ' "${all[@]}")" ;;
    esac
}

# Codename of the selected device (fastboot getvar writes to stderr).
probe_codename() {
    local s="$1" state="$2" out=""
    if [ "${state}" = "fastboot" ]; then
        out="$("${FASTBOOT}" -s "${s}" getvar product 2>&1 || true)"
        awk -F': *' '/^product:/ { print $2; exit }' <<<"${out}" | tr -d '\r'
    else
        "${ADB}" -s "${s}" shell getprop ro.product.device 2>/dev/null | tr -d '\r\n' || true
    fi
}

# OS probe (best-effort; ADDENDUM 2026-07-16): identify GrapheneOS vs stock
# Android vs a genuinely undetectable OS over adb. Sets OS_ID
# (grapheneos|android|unknown) + OS_VERSION (GrapheneOS's calendar-datestamp
# incremental, or the Android release number — whichever was actually read).
# Never fatal here: callers decide whether "unknown" gates behind --force.
OS_ID=""
OS_VERSION=""
probe_os() {
    local s="$1" incr relnum has_gos_marker=1
    OS_ID="unknown"; OS_VERSION=""
    incr="$("${ADB}" -s "${s}" shell getprop ro.build.version.incremental 2>/dev/null | tr -d '\r\n' || true)"
    # The bare YYYYMMDDNN datestamp shape is NOT GrapheneOS-unique (common on
    # other AOSP-derived/vendor ROMs) — require it AND a harder GrapheneOS-
    # specific getprop marker, not either alone, so a non-GrapheneOS ROM with
    # a datestamp-shaped incremental can't be misclassified.
    "${ADB}" -s "${s}" shell getprop 2>/dev/null | grep -qi grapheneos || has_gos_marker=0
    if [[ "${incr}" =~ ^20[0-9]{8}$ ]] && [ "${has_gos_marker}" -eq 1 ]; then
        OS_ID="grapheneos"; OS_VERSION="${incr}"
        return 0
    fi
    relnum="$("${ADB}" -s "${s}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "${relnum}" ]; then
        OS_ID="android"; OS_VERSION="${relnum}"
    fi
}

# ── Artifact naming / verification ─────────────────────────────────
zip_path()    { printf '%s/%s-install-%s.zip' "${WORK_DIR}" "${CODENAME}" "$1"; }
version_cache_path() { printf '%s/.resolved-%s-%s' "${WORK_DIR}" "${CODENAME}" "${CHANNEL}"; }

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# Verify the artifact's sshsig against the pinned allowed_signers (+ double
# fingerprint pin). On failure: DELETE the artifact (+sig +marker) and exit 3 —
# a bad zip must never survive to be flashed later.
verify_artifact_or_die() {
    local zip="$1" sig="${1}.sig" fp
    fp="$(effective_signer_fp)"
    if ! dlv_verify_sshsig "${zip}" "${sig}" "${ALLOWED_SIGNERS}" \
            "${GRAPHENE_IDENTITY}" "${GRAPHENE_NAMESPACE}" "${fp}"; then
        rm -f "${zip}" "${sig}" "${zip}".verified-* 2>/dev/null || true
        pw_die 3 "signature verification FAILED for $(basename "${zip}") — artifact DELETED, refusing to proceed"
    fi
}

# Resolve the release version for CODENAME/CHANNEL from the one-line metadata
# file at <releases>/<codename>-<channel>: "<version> <unix-ts> <codename> <channel>".
resolve_version() {
    require_tool curl "install net-misc/curl"
    local url="${RELEASES_URL}/${CODENAME}-${CHANNEL}" meta mver mts mcn mch
    pw_info "resolving ${CODENAME} ${CHANNEL} release via ${url}"
    meta="$(curl -fsS --proto '=https,http' --retry 3 --retry-delay 2 "${url}")" \
        || pw_die 1 "could not fetch release metadata: ${url}"
    read -r mver mts mcn mch <<<"${meta}" || true
    [[ "${mver}" =~ ^[0-9]{8,}$ ]] || pw_die 1 "malformed release metadata from ${url}: '${meta}'"
    [ "${mcn}" = "${CODENAME}" ] && [ "${mch}" = "${CHANNEL}" ] \
        || pw_die 1 "release metadata mismatch (asked ${CODENAME}-${CHANNEL}, got '${mcn} ${mch}') — refusing"
    : "${mts}"  # timestamp unused, kept for the format contract
    GRAPHENE_VERSION="${mver}"
}

# Locate the extracted flash-all.sh dir for CODENAME (+version when known).
find_flash_dir() {
    local hit
    hit="$(find "${WORK_DIR}" -maxdepth 2 -type f -name flash-all.sh -path "*${CODENAME}*" 2>/dev/null | head -n1 || true)"
    [ -n "${hit}" ] && dirname "${hit}" || return 1
}

# ── JSON emission (jq for correctness; required by enroll/profile/ingest) ──
require_jq() { require_tool jq "install app-misc/jq"; }

# ── Passphrase generation + escrow (vault-seed custody) ────────────
# 6 dash-joined 6-char words from /dev/urandom (>= 41 chars, >= 28 required).
# No wordlist dependency; lowercase letters only, so it is typable on the
# handset lockscreen keyboard.
gen_passphrase() {
    local words=() w i
    for i in 1 2 3 4 5 6; do
        w="$(set +o pipefail; LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 6)"
        [ "${#w}" -eq 6 ] || pw_die 1 "passphrase generation failed (/dev/urandom)"
        words+=("${w}")
    done
    (IFS=-; printf '%s' "${words[*]}")
    : "${i}"
}

escrow_path() { printf '%s/vault-seed/device/%s/enterprise-profile.pass' "${OUT_DIR}" "$1"; }

# Write <pass> to the escrow file (dirs 0700, file 0600). Never echoes it.
write_escrow() {
    local dest="$1" pass="$2" dir
    dir="$(dirname "${dest}")"
    mkdir -p "${dir}"
    chmod 700 "${dir}" "$(dirname "${dir}")" 2>/dev/null || true
    (umask 077; printf '%s\n' "${pass}" > "${dest}")
    chmod 600 "${dest}"
}

# Resolve the passphrase source: --pass-file (must exist) or generate. Sets
# PASS_VALUE + PASS_SOURCE(file|generate). Never printed.
PASS_VALUE=""
PASS_SOURCE=""
resolve_passphrase() {
    if [ -n "${PASS_FILE}" ]; then
        [ -f "${PASS_FILE}" ] || pw_die 1 "--pass-file not found: ${PASS_FILE}"
        PASS_VALUE="$(tr -d '\n' < "${PASS_FILE}")"
        [ -n "${PASS_VALUE}" ] || pw_die 1 "--pass-file is empty (fail-closed)"
        PASS_SOURCE="file"
    else
        PASS_VALUE="$(gen_passphrase)"
        PASS_SOURCE="generate"
    fi
}

# ── pm list users parsing ──────────────────────────────────────────
# Lines look like: "	UserInfo{10:enterprise:410}". Prints the id for <name>.
# Parsed with awk + PLAIN STRING equality (not a regex/sed match) so a name
# containing regex metacharacters (., *, [, …) can never match a DIFFERENT
# on-device user than the one literally named.
profile_user_id() {
    local s="$1" name="$2"
    "${ADB}" -s "${s}" shell pm list users 2>/dev/null | tr -d '\r' \
        | awk -F'[{:}]' -v n="${name}" '$0 ~ /UserInfo\{/ && $3 == n { print $2; exit }'
}

# ── Shared: signer-pinned APK verification (fail-closed when a pin is given,
# no-op otherwise) ──────────────────────────────────────────────────────────
# Pulls the CURRENTLY INSTALLED base.apk for <pkg> and checks its apksigner
# cert digest against <expected> — keeps the check honest (pins what is
# actually on the device, not the file that was pushed). Used by enroll
# (Tailscale), mdm-enroll (Headwind DPC), and attest (Auditor fork) — one
# apksigner-verify code path for every sideloaded APK this wizard trusts.
# <label> names the app in messages; <flag> names the option in the
# require_tool hint (e.g. --apk-signer-sha256).
verify_installed_signer() {
    local s="$1" pkg="$2" expected="$3" label="$4" flag="$5"
    [ -n "${expected}" ] || return 0
    require_tool apksigner "install dev-util/android-sdk-build-tools (apksigner) — required to enforce ${flag}"
    local rpath tmpapk digest
    rpath="$("${ADB}" -s "${s}" shell pm path "${pkg}" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -n1)"
    [ -n "${rpath}" ] || pw_die 2 "cannot resolve the installed APK path for ${pkg}"
    tmpapk="$(mktemp --suffix=.apk)"
    "${ADB}" -s "${s}" pull "${rpath}" "${tmpapk}" >/dev/null 2>&1 || { rm -f "${tmpapk}"; pw_die 1 "adb pull of ${rpath} failed"; }
    digest="$(apksigner verify --print-certs "${tmpapk}" 2>/dev/null \
        | sed -nE 's/^Signer #1 certificate SHA-256 digest: ([0-9a-f]+)$/\1/p' | head -n1)"
    rm -f "${tmpapk}"
    if [ -z "${digest}" ] || [ "${digest}" != "$(tr 'A-F' 'a-f' <<<"${expected}")" ]; then
        pw_die 3 "${label} APK signer digest MISMATCH (got '${digest:-none}', pinned '${expected}') — refusing to proceed with an untrusted ${label} client"
    fi
    pw_info "${label} APK signer pin OK"
}

# ── verb: plan ─────────────────────────────────────────────────────
cmd_plan() {
    local target="${1:-wizard}"
    validate_channel
    local name="" version zip_url sig_url fp_disp authkey_disp pass_disp
    local devid_disp serial_disp escrow_disp ingest_disp steps

    if [ -n "${CODENAME}" ]; then
        require_codename   # exit 4 on unknown
        name="${DEVICE_NAME}"
    fi

    version="${GRAPHENE_VERSION}"
    if [ -z "${version}" ]; then
        if [ "${RESOLVE}" -eq 1 ]; then
            [ -n "${CODENAME}" ] || pw_die 1 "--resolve needs --codename"
            resolve_version
            version="${GRAPHENE_VERSION}"
        else
            version="resolve-at-fetch"
        fi
    fi

    local cn_disp="${CODENAME:-<codename>}" v_disp="${version}"
    [ "${version}" = "resolve-at-fetch" ] && v_disp="<version>"
    zip_url="${RELEASES_URL}/${cn_disp}-install-${v_disp}.zip"
    sig_url="${zip_url}.sig"

    fp_disp="$(effective_signer_fp)"; [ -n "${fp_disp}" ] || fp_disp="unpinned"

    resolve_keys   # read-only: fills LOGIN_SERVER/AUTHKEY_FILE/ROLE/ATTACHED_DOMAIN
    if [ -n "${AUTHKEY_FILE}" ] && [ -f "${AUTHKEY_FILE}" ]; then
        authkey_disp="REDACTED:present"
    else
        authkey_disp="REDACTED:absent"
    fi
    if [ -n "${PASS_FILE}" ]; then pass_disp="REDACTED:file"; else pass_disp="REDACTED:generate"; fi

    resolve_device_id
    devid_disp="${DEVICE_ID:-resolve-at-run}"
    serial_disp="${SERIAL:-detect-at-run}"
    escrow_disp="$(escrow_path "${devid_disp}")"
    ingest_disp="${INGEST_URL:-emit-only}"

    case "${target}" in
        wizard)     steps="detect,fetch,flash,attest,mdm-enroll,enroll,profile,ingest" ;;
        fetch)      steps="resolve-version,download,verify,extract" ;;
        flash)      steps="preflight,detect,verify-artifact,confirm,unlock,flash-all,lock" ;;
        attest)     steps="adb-sanity,auditor-install,pairing-runbook,record" ;;
        mdm-enroll) steps="adb-sanity,fresh-device-precondition,dpc-install,set-device-owner,push-init-json,record" ;;
        enroll)     if [ "${NO_USB}" -eq 1 ]; then
                        steps="join-runbook,record-operator-attested"
                    else
                        steps="adb-sanity,tailscale-app,join-runbook,verify-join,record"
                    fi ;;
        profile)    steps="create-user,start-user,escrow,set-credential,record" ;;
        detect|status|ingest|plan|rotate-profile-pass|remove-profile) steps="${target}" ;;
        *) pw_die 1 "plan: unknown target verb '${target}' (see --help)" ;;
    esac

    cat <<EOF
PLAN_VERB=${target}
PLAN_SERIAL=${serial_disp}
PLAN_CODENAME=${CODENAME:-detect-at-run}
PLAN_DEVICE_NAME=${name:-unknown}
PLAN_CHANNEL=${CHANNEL}
PLAN_VERSION=${version}
PLAN_ZIP_URL=${zip_url}
PLAN_SIG_URL=${sig_url}
PLAN_SIGNER_FP=${fp_disp}
PLAN_WORK_DIR=${WORK_DIR}
PLAN_OUT=${OUT_DIR}
PLAN_KEYS_DIR=${KEYS_DIR:-unset}
PLAN_LOGIN_SERVER=${LOGIN_SERVER:-unset}
PLAN_AUTHKEY=${authkey_disp}
PLAN_PROFILE_PASS=${pass_disp}
PLAN_DEVICE_ID=${devid_disp}
PLAN_SUPERDOMAIN=${SUPERDOMAIN}
PLAN_ROLE=${ROLE}
PLAN_ESCROW_PATH=${escrow_disp}
PLAN_INGEST_URL=${ingest_disp}
PLAN_HEADWIND_URL=${HEADWIND_URL:-unset}
PLAN_HEADWIND_SIGNER_FP=${HEADWIND_SIGNER_SHA256:-unpinned}
PLAN_ATTESTATION_URL=${ATTESTATION_URL:-unset}
PLAN_AUDITOR_SIGNER_FP=${AUDITOR_SIGNER_SHA256:-unpinned}
PLAN_STEPS=${steps}
EOF
}

# ── verb: detect ───────────────────────────────────────────────────
cmd_detect() {
    require_android_tools
    choose_device
    local cn fpq="" nm
    cn="$(probe_codename "${SEL_SERIAL}" "${SEL_STATE}")"
    nm="$(catalog_lookup "${cn}" 2>/dev/null || echo "unknown (not in ${DEVICES_TSV##*/})")"
    if [ "${SEL_STATE}" = "adb" ]; then
        fpq="$("${ADB}" -s "${SEL_SERIAL}" shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r\n' || true)"
    fi
    cat <<EOF
DEVICE_SERIAL=${SEL_SERIAL}
DEVICE_STATE=${SEL_STATE}
DEVICE_CODENAME=${cn:-unknown}
DEVICE_NAME=${nm}
DEVICE_FINGERPRINT=${fpq:-unavailable}
EOF
    # Feed later steps in the wizard flow.
    SERIAL="${SEL_SERIAL}"
    [ -n "${CODENAME}" ] || CODENAME="${cn}"
}

# ── verb: fetch ────────────────────────────────────────────────────
cmd_fetch() {
    require_tool ssh-keygen "install net-misc/openssh"
    require_tool sha256sum "install sys-apps/coreutils"
    [ -f "${ALLOWED_SIGNERS}" ] || pw_die 2 "allowed_signers file missing: ${ALLOWED_SIGNERS}"
    validate_channel
    require_codename

    mkdir -p "${WORK_DIR}"

    # Track whether GRAPHENE_VERSION came from an explicit --graphene-version
    # pin on THIS invocation, so a one-off pin (e.g. downgrade testing) never
    # poisons the shared per-channel cache read by every future unpinned
    # fetch/flash for this codename+channel.
    local user_pinned=0
    [ -n "${GRAPHENE_VERSION}" ] && user_pinned=1

    # Version: explicit pin > cached resolution (kept next to its verified zip,
    # so a re-fetch is fully offline/idempotent) > live channel metadata.
    if [ -z "${GRAPHENE_VERSION}" ] && [ -f "$(version_cache_path)" ]; then
        local cached
        cached="$(tr -d ' \n' < "$(version_cache_path)")"
        if [ -n "${cached}" ] && [ -f "$(zip_path "${cached}")" ]; then
            GRAPHENE_VERSION="${cached}"
            pw_info "using cached ${CHANNEL} resolution ${GRAPHENE_VERSION} (rm ${WORK_DIR} or pass --graphene-version to re-resolve)"
        fi
    fi
    [ -n "${GRAPHENE_VERSION}" ] || resolve_version

    local zip sig marker sha
    zip="$(zip_path "${GRAPHENE_VERSION}")"
    sig="${zip}.sig"

    if [ -f "${zip}" ] && [ -f "${sig}" ]; then
        sha="$(sha256_of "${zip}")"
        marker="${zip}.verified-${sha}"
        if [ -f "${marker}" ]; then
            pw_info "existing artifact found — re-verifying instead of re-downloading"
        else
            pw_info "existing artifact found without a matching marker — re-verifying"
        fi
    else
        pw_info "downloading ${CODENAME}-install-${GRAPHENE_VERSION}.zip (+.sig) into ${WORK_DIR}"
        dlv_fetch "${RELEASES_URL}/$(basename "${zip}")" "${zip}" || pw_die 1 "artifact download failed"
        dlv_fetch "${RELEASES_URL}/$(basename "${sig}")" "${sig}" || { rm -f "${zip}"; pw_die 1 "signature download failed"; }
    fi

    verify_artifact_or_die "${zip}"
    sha="$(sha256_of "${zip}")"
    marker="${zip}.verified-${sha}"
    # Refresh the marker set: exactly ONE marker, matching the current bytes.
    rm -f "${zip}".verified-* 2>/dev/null || true
    : > "${marker}"
    # Never let an explicit one-off --graphene-version pin overwrite the
    # shared per-channel cache — only organically-resolved (cache-hit or
    # live channel-lookup) versions get persisted for future unpinned runs.
    [ "${user_pinned}" -eq 1 ] || printf '%s\n' "${GRAPHENE_VERSION}" > "$(version_cache_path)"

    if ! find_flash_dir >/dev/null; then
        require_tool bsdtar "install app-arch/libarchive"
        pw_info "extracting $(basename "${zip}")"
        bsdtar -x -f "${zip}" -C "${WORK_DIR}" || pw_die 1 "extraction failed for ${zip}"
        find_flash_dir >/dev/null || pw_die 1 "extracted zip contains no flash-all.sh — unexpected artifact layout"
    fi

    pw_info "fetch complete: $(basename "${zip}") VERIFIED (sha256 ${sha})"
    pw_info "marker: ${marker}"
}

# ── verb: flash ────────────────────────────────────────────────────
cmd_flash() {
    require_android_tools
    require_tool ssh-keygen "install net-misc/openssh"
    require_tool sha256sum "install sys-apps/coreutils"
    validate_channel

    # Preflight: fastboot >= 35 (GrapheneOS hard requirement: >= 35.0.2).
    local vline major
    vline="$("${FASTBOOT}" --version 2>/dev/null | head -n1 || true)"
    major="$(sed -nE 's/^fastboot version ([0-9]+)\..*/\1/p' <<<"${vline}")"
    if [ -z "${major}" ]; then
        [ "${FORCE}" -eq 1 ] || pw_die 2 "could not parse fastboot version ('${vline}') — GrapheneOS needs fastboot >= 35.0.2; upgrade android-tools (or --force if you know it is new enough)"
        pw_warn "unparsable fastboot version '${vline}' — continuing under --force"
    elif [ "${major}" -lt 35 ]; then
        pw_die 2 "fastboot ${vline#fastboot version } is too old — GrapheneOS requires >= 35.0.2; upgrade android-tools"
    fi

    # Preflight: fwupd fights over the fastboot USB device.
    if have pgrep && pgrep -x fwupd >/dev/null 2>&1; then
        [ "${FORCE_FWUPD}" -eq 1 ] || pw_die 2 "fwupd is running and can seize the fastboot interface — stop it (systemctl stop fwupd) or pass --force-fwupd"
        pw_warn "fwupd is running — continuing under --force-fwupd"
    fi

    # Device: --serial mismatch → exit 4; several without --serial → exit 2.
    choose_device
    local s="${SEL_SERIAL}"
    if [ -z "${CODENAME}" ]; then
        CODENAME="$(probe_codename "${s}" "${SEL_STATE}")"
    fi
    require_codename

    # Verified artifact gate: marker + byte re-verify + signature re-verify.
    local zip sha marker
    if [ -n "${GRAPHENE_VERSION}" ]; then
        zip="$(zip_path "${GRAPHENE_VERSION}")"
    else
        zip="$(ls -1t "${WORK_DIR}/${CODENAME}"-install-*.zip 2>/dev/null | head -n1 || true)"
    fi
    [ -n "${zip}" ] && [ -f "${zip}" ] \
        || pw_die 2 "no fetched artifact for ${CODENAME} in ${WORK_DIR} — run 'fetch' first (flash refuses anything unverified)"
    sha="$(sha256_of "${zip}")"
    marker="${zip}.verified-${sha}"
    [ -f "${marker}" ] \
        || pw_die 2 "no verification marker for $(basename "${zip}") (or the bytes changed since fetch) — re-run 'fetch' (flash refuses anything unverified)"
    verify_artifact_or_die "${zip}"
    pw_info "artifact re-verified: $(basename "${zip}")"

    local flashdir
    if ! flashdir="$(find_flash_dir)"; then
        require_tool bsdtar "install app-arch/libarchive"
        bsdtar -x -f "${zip}" -C "${WORK_DIR}" || pw_die 1 "extraction failed for ${zip}"
        flashdir="$(find_flash_dir)" || pw_die 1 "extracted zip contains no flash-all.sh"
    fi

    # Destructive gate: typed-serial confirmation on a TTY; non-TTY needs BOTH
    # --yes AND --serial (already matched against the connected device above).
    echo
    echo "  !!! DESTRUCTIVE: flashing GrapheneOS $(basename "${zip}")"
    echo "  !!! onto ${DEVICE_NAME} (${CODENAME}) serial ${s}."
    echo "  !!! ALL DATA ON THE DEVICE WILL BE DESTROYED (unlock wipes; lock wipes again)."
    echo
    if [ -t 0 ]; then
        local typed=""
        read -r -p "Type the device serial (${s}) to confirm, anything else aborts: " typed
        [ "${typed}" = "${s}" ] || pw_die 2 "confirmation mismatch — aborted, nothing flashed"
    else
        if [ "${ASSUME_YES}" -ne 1 ] || [ -z "${SERIAL}" ]; then
            pw_die 2 "refusing to flash on a non-TTY without BOTH --yes and --serial <s> (typed-serial confirmation unavailable)"
        fi
    fi

    # Into the bootloader if the device is up in adb.
    if [ "${SEL_STATE}" = "adb" ]; then
        pw_info "rebooting ${s} into the bootloader"
        "${ADB}" -s "${s}" reboot bootloader || pw_die 1 "adb reboot bootloader failed"
        # Env seams (tests shrink these): PW_FASTBOOT_REAPPEAR_TIMEOUT,
        # PW_POLL_INTERVAL (shared with the enroll tailnet-join poll).
        local reappear_timeout="${PW_FASTBOOT_REAPPEAR_TIMEOUT:-120}"
        local waited=0
        while :; do
            list_devices
            local found=0 fb
            for fb in ${FB_SERIALS[@]+"${FB_SERIALS[@]}"}; do [ "${fb}" = "${s}" ] && found=1; done
            [ "${found}" -eq 1 ] && break
            waited=$((waited + POLL_INTERVAL)); sleep "${POLL_INTERVAL}"
            [ "${waited}" -lt "${reappear_timeout}" ] || pw_die 1 "device ${s} did not reappear in fastboot within ${reappear_timeout}s"
        done
    fi

    # Unlock (operator physically confirms on the handset; OEM unlocking must
    # already be enabled in Developer options). Tolerate an already-unlocked
    # bootloader; any other failure is fatal.
    echo
    echo "  On the handset: use the volume keys to select 'Unlock the bootloader'"
    echo "  and confirm with the power button. (Requires 'OEM unlocking' enabled"
    echo "  in Developer options; unlocking WIPES the device.)"
    echo
    pw_info "running: fastboot -s ${s} flashing unlock (waiting for the operator)"
    if ! "${FASTBOOT}" -s "${s}" flashing unlock; then
        local unl
        unl="$("${FASTBOOT}" -s "${s}" getvar unlocked 2>&1 || true)"
        if grep -qE '^unlocked:[[:space:]]*yes' <<<"${unl}"; then
            pw_info "bootloader already unlocked — continuing"
        else
            pw_die 1 "fastboot flashing unlock failed (and the device does not report unlocked) — aborting before any flash"
        fi
    fi

    # Flash: run the official flash-all.sh from inside the extracted dir with a
    # local TMPDIR (space safety, per the official CLI instructions). fastboot
    # calls inside flash-all.sh bind to OUR device via ANDROID_SERIAL.
    pw_info "running flash-all.sh from ${flashdir} (this takes several minutes)"
    (
        cd "${flashdir}"
        mkdir -p tmp
        ANDROID_SERIAL="${s}" TMPDIR="${PWD}/tmp" bash flash-all.sh
    ) || pw_die 1 "flash-all.sh FAILED — device may be in a partial state; do NOT lock; re-run flash"

    # Re-lock (operator confirms on the handset; wipes again). NEVER
    # `fastboot erase avb_custom_key` — that is the revert-to-stock path.
    echo
    echo "  On the handset: use the volume keys to select 'Lock the bootloader'"
    echo "  and confirm with the power button. Locking wipes the device again"
    echo "  and (re-)enables full verified boot."
    echo
    pw_info "running: fastboot -s ${s} flashing lock (waiting for the operator)"
    "${FASTBOOT}" -s "${s}" flashing lock \
        || pw_die 1 "fastboot flashing lock failed/declined — the device REMAINS UNLOCKED; re-run flash or lock manually before deployment"

    pw_info "flash complete. Boot the device, complete first-boot setup, then enable"
    pw_info "Developer options + USB debugging (Owner profile) and run 'attest',"
    pw_info "THEN 'mdm-enroll' (device-owner mode is foreclosed once 'profile' runs)."
}

# ── verb: attest ───────────────────────────────────────────────────
# Installs the Snapdragon-forked Auditor and prints the AttestationServer
# pairing runbook. Runs FIRST among the two new Phase-3 verbs (before
# mdm-enroll) because it needs no device-owner state and captures the
# hardware trust root on the cleanest possible device state (see
# docs/ENTERPRISE-PHONES.md, "CRITICAL ordering").
#
# Pairing (O3, unresolved upstream): no confirmed headless "submit and get a
# JSON verdict" API exists for the self-hosted AttestationServer — the
# Auditor<->AttestationServer TOFU pairing is driven INSIDE the Auditor app UI
# by scanning a QR code the AttestationServer console renders (it encodes
# domain/userId/subscribeKey). This wizard has no way to drive an in-app
# camera scan over adb, so this step is honestly OPERATOR-ATTESTED
# (verdict:"operator-paired"), never a claimed cryptographic pass. Attestation
# is advisory/logged in v1 (D9) — never a hard enrollment-blocking precondition.
cmd_attest() {
    require_android_tools
    require_jq
    [ -n "${ATTESTATION_URL}" ] || pw_die 1 "attest needs --attestation-url (or ATTEST_URL) — the self-hosted AttestationServer console URL"

    choose_device
    local s="${SEL_SERIAL}"
    local state
    state="$("${ADB}" -s "${s}" get-state 2>/dev/null | tr -d '\r\n' || true)"
    [ "${state}" = "device" ] || pw_die 2 "attest needs the device up in adb (state: ${state:-none}) — complete first-boot setup, enable USB debugging, and retry"

    if [ -z "${CODENAME}" ]; then
        CODENAME="$(probe_codename "${s}" adb)"
    fi
    require_codename
    SERIAL="${s}"
    resolve_device_id

    local pkg="${AUDITOR_PACKAGE}"
    if [ -n "${AUDITOR_APK}" ]; then
        [ -f "${AUDITOR_APK}" ] || pw_die 1 "--auditor-apk not found: ${AUDITOR_APK}"
        pw_info "installing ${AUDITOR_APK}"
        "${ADB}" -s "${s}" install -r "${AUDITOR_APK}" || pw_die 1 "adb install failed"
    fi
    if ! "${ADB}" -s "${s}" shell pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:${pkg}"; then
        if [ -n "${AUDITOR_APK}" ]; then
            pw_die 1 "installed the APK but ${pkg} is not listed — wrong APK?"
        fi
        pw_die 1 "no --auditor-apk given and ${pkg} is not installed — pass --auditor-apk"
    fi
    verify_installed_signer "${s}" "${pkg}" "${AUDITOR_SIGNER_SHA256}" "Auditor" "--auditor-signer-sha256"

    echo
    echo "== attestation pairing runbook (operator, on the handset) =="
    echo "  1. Open the Auditor app (package: ${pkg})."
    echo "  2. Choose to pair with / verify against a remote server."
    echo "  3. Open the AttestationServer console in a browser:"
    echo "       ${ATTESTATION_URL}"
    echo "     and scan the displayed QR code with the Auditor app — it"
    echo "     encodes domain/userId/subscribeKey. This wizard CANNOT drive"
    echo "     that in-app camera scan; the pairing step is operator-attested."
    echo "  4. Confirm the app reports a successful pairing / first audit."
    echo
    if [ -t 0 ]; then
        local ack=""
        read -r -p "Press Enter once pairing is confirmed on the handset (or type skip): " ack
        [ "${ack}" = "skip" ] && pw_warn "pairing confirmation SKIPPED by operator — attestation.json still records verdict:operator-paired (unverified by this wizard)"
    else
        pw_warn "non-TTY: cannot wait for operator ack — confirm pairing on the handset before deploying"
    fi

    local rec_dir="${OUT_DIR}/device/${DEVICE_ID}" rec
    mkdir -p "${rec_dir}"
    rec="${rec_dir}/attestation.json"
    jq -n \
        --arg device_id "${DEVICE_ID}" \
        --arg auditor_package "${pkg}" \
        --arg attestation_url "${ATTESTATION_URL}" \
        --arg at "$(now_iso)" \
        '{device_id:$device_id, auditor_package:$auditor_package,
          attestation_url:$attestation_url, verdict:"operator-paired", at:$at}' \
        > "${rec}"
    pw_info "attestation record written: ${rec} (verdict: operator-paired — operator-attested, NOT cryptographically verified by this wizard)"
}

# ── verb: mdm-enroll ────────────────────────────────────────────────
# Enrolls the phone as a Headwind MDM device-owner
# (com.hmdm.launcher/.AdminReceiver via `dpm set-device-owner`). This is a
# ONE-SHOT AOSP gate: it only succeeds while the target user has ZERO
# secondary users and ZERO added accounts, and is PERMANENT for the life of
# the OS install once foreclosed (no undo short of a reflash). MUST run
# before 'profile' (which creates the escrowed secondary user that forecloses
# it) — see docs/ENTERPRISE-PHONES.md, "CRITICAL ordering".
cmd_mdm_enroll() {
    require_android_tools
    require_jq
    [ -n "${HEADWIND_URL}" ] || pw_die 1 "mdm-enroll needs --headwind-url (or HMDM_URL) — the DPC's non-interactive init.json config target"

    choose_device
    local s="${SEL_SERIAL}"
    local state
    state="$("${ADB}" -s "${s}" get-state 2>/dev/null | tr -d '\r\n' || true)"
    [ "${state}" = "device" ] || pw_die 2 "mdm-enroll needs the device up in adb (state: ${state:-none}) — complete first-boot setup, enable USB debugging, and retry"

    if [ -z "${CODENAME}" ]; then
        CODENAME="$(probe_codename "${s}" adb)"
    fi
    require_codename
    SERIAL="${s}"
    resolve_device_id

    # FRESH-DEVICE precondition (fail-closed): if the operator runs the verbs
    # out of order, this turns the cryptic AOSP IllegalStateException into a
    # clear, documented exit-2 message instead of a mid-flow surprise.
    # --force downgrades it to a warning (matches the GrapheneOS-fingerprint-
    # probe --force convention already used elsewhere in this driver).
    local users_out user_count
    users_out="$("${ADB}" -s "${s}" shell pm list users 2>/dev/null | tr -d '\r')"
    user_count="$(awk '$0 ~ /UserInfo\{/ {c++} END{print c+0}' <<<"${users_out}")"
    if [ "${user_count}" -ne 1 ]; then
        if [ "${FORCE}" -eq 1 ]; then
            pw_warn "device already reports ${user_count} users/profiles (want exactly 1) — device-owner mode may already be foreclosed; continuing under --force, dpm set-device-owner may fail"
        else
            pw_die 2 "a secondary user/account already exists — device-owner mode is no longer obtainable; reflash to retry"
        fi
    fi

    # OS probe: GrapheneOS device-owner via adb is RELIABLE (no Play Protect
    # gate exists at setup). Stock Android is BEST-EFFORT — since late 2025
    # Play Protect enforces an approved-DPC allow-list at provisioning time on
    # Play-Protect-certified devices, which can block an unlisted custom DPC
    # with an opaque appeal path. The raw adb `dpm set-device-owner` call this
    # verb uses is architecturally a DIFFERENT code path than the
    # provisioning-UI flow that allow-list historically gates, but that has
    # NOT been independently reconfirmed against 2026-era Play Protect builds
    # — so this advisory prints un-suppressibly before every attempt, and a
    # resulting failure on stock Android is a normal exit-1 (not a wizard bug).
    probe_os "${s}"
    case "${OS_ID}" in
        grapheneos) pw_info "device OS: GrapheneOS — device-owner via adb is the reliable path here" ;;
        android)    pw_warn "device OS: stock Android${OS_VERSION:+ ${OS_VERSION}} — device-owner via adb is BEST-EFFORT on certified stock builds (Play Protect's DPC allow-list may block provisioning; a resulting failure is not a wizard bug)" ;;
        *)          pw_warn "device OS could not be determined — proceeding, but device-owner via adb is unverified on this build" ;;
    esac

    # Install the Headwind DPC APK (signer-pinned via the same apksigner-
    # verify logic 'enroll' uses for the Tailscale APK).
    local pkg="com.hmdm.launcher"
    if [ -n "${HEADWIND_APK}" ]; then
        [ -f "${HEADWIND_APK}" ] || pw_die 1 "--headwind-apk not found: ${HEADWIND_APK}"
        pw_info "installing ${HEADWIND_APK}"
        "${ADB}" -s "${s}" install -r "${HEADWIND_APK}" || pw_die 1 "adb install failed"
    fi
    if ! "${ADB}" -s "${s}" shell pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:${pkg}"; then
        if [ -n "${HEADWIND_APK}" ]; then
            pw_die 1 "installed the APK but ${pkg} is not listed — wrong APK?"
        fi
        pw_die 1 "no --headwind-apk given and ${pkg} is not installed — pass --headwind-apk"
    fi
    verify_installed_signer "${s}" "${pkg}" "${HEADWIND_SIGNER_SHA256}" "Headwind" "--headwind-signer-sha256"

    # Device-owner: the one-shot AOSP call itself.
    pw_info "running: dpm set-device-owner ${pkg}/.AdminReceiver"
    local dpm_out
    dpm_out="$("${ADB}" -s "${s}" shell dpm set-device-owner "${pkg}/.AdminReceiver" 2>&1 | tr -d '\r' || true)"
    if ! grep -q '^Success:' <<<"${dpm_out}"; then
        local hint=""
        [ "${OS_ID}" = "android" ] && hint=" (stock-Android Play Protect's DPC allow-list is the likely cause — see the advisory above)"
        pw_die 1 "dpm set-device-owner failed: ${dpm_out}${hint}"
    fi
    pw_info "device owner set: ${dpm_out}"

    # Non-interactive config-injection (O4, verified against upstream Headwind
    # source): the app reads com.hmdm.BASE_URL (+ optional
    # DEVICE_ID/CONFIG/GROUP/CERTS keys) from an init.json file dropped in its
    # external files dir (getExternalFilesDir()/init.json,
    # updateSettingsFromFile()) — this is the confirmed non-interactive
    # mechanism this driver can push over adb without any operator QR-scan
    # (the server also emits the same payload via
    # GET /public/qr/json/{id} for a QR-provisioning flow this driver does
    # not perform).
    local ext_dir="/sdcard/Android/data/${pkg}/files" tmp_init
    "${ADB}" -s "${s}" shell mkdir -p "${ext_dir}" >/dev/null 2>&1 || true
    tmp_init="$(mktemp)"
    jq -n --arg base_url "${HEADWIND_URL}" '{"com.hmdm.BASE_URL":$base_url}' > "${tmp_init}"
    "${ADB}" -s "${s}" push "${tmp_init}" "${ext_dir}/init.json" >/dev/null 2>&1 \
        || { rm -f "${tmp_init}"; pw_die 1 "adb push of init.json to ${ext_dir} failed"; }
    rm -f "${tmp_init}"
    pw_info "init.json pushed: ${ext_dir}/init.json (com.hmdm.BASE_URL=${HEADWIND_URL})"

    local rec_dir="${OUT_DIR}/device/${DEVICE_ID}" rec
    mkdir -p "${rec_dir}"
    rec="${rec_dir}/mdm.json"
    jq -n \
        --arg device_id "${DEVICE_ID}" \
        --arg serial "${s}" \
        --arg dpc_package "${pkg}" \
        --arg headwind_url "${HEADWIND_URL}" \
        --arg os "${OS_ID}" \
        --arg enrolled_at "$(now_iso)" \
        '{device_id:$device_id, serial:$serial, dpc_package:$dpc_package,
          headwind_url:$headwind_url, os:$os, set_via:"adb-device-owner",
          enrolled_at:$enrolled_at}' \
        > "${rec}"
    pw_info "mdm record written: ${rec}"
}

# ── verb: enroll (--no-usb variant) ─────────────────────────────────
# Guided handset-only runbook (operator + handset, no adb whatsoever): for
# hosts with no USB/adb access to the device, or an operator who would rather
# not tether it. Records an OPERATOR-ATTESTED enrollment (verification field)
# with tailscale_ip left null — the wizard did not verify the join itself;
# the operator verifies it mesh-side (headscale / superadmin UI) afterwards.
cmd_enroll_no_usb() {
    resolve_device_id
    [ -n "${DEVICE_ID}" ] || pw_die 1 "--no-usb enroll needs --device-id (there is no adb serial to derive one from)"

    echo
    echo "== no-USB guided handset runbook (operator + handset only; no adb) =="
    echo "  Every adb probe is skipped in this mode. Perform these steps"
    echo "  directly on the handset, then verify the join MESH-SIDE afterwards"
    echo "  (see NEXT STEPS below) — this wizard cannot confirm it for you."
    echo
    echo "  1. Install Tailscale on the handset (Play Store 'Tailscale', or a"
    echo "     vetted APK from your own custody)."
    echo "  2. Open Tailscale -> Settings -> Accounts -> use a CUSTOM"
    echo "     coordination server:  ${LOGIN_SERVER}"
    echo "  3. Authenticate with the one-time pre-auth key (SEC-08: single-use,"
    echo "     24h expiry — mint a fresh one if it is stale), or via Casdoor"
    echo "     OIDC with the snapdragon/headscale group."
    if [ "${SHOW_AUTHKEY}" -eq 1 ]; then
        if [ -n "${AUTHKEY_FILE}" ] && [ -f "${AUTHKEY_FILE}" ]; then
            echo "  --show-authkey: the pre-auth key follows on the NEXT line (shown once):"
            cat "${AUTHKEY_FILE}"
        else
            pw_warn "--show-authkey given but no authkey file resolved (--authkey-file / keys-dir)"
        fi
    else
        echo "     (pre-auth key NOT displayed — paste it from your own custody, or"
        echo "      re-run with --show-authkey)"
    fi
    echo "  4. ADR-14 register-and-approve: the node registers as PENDING and"
    echo "     only joins after a superadmin approves it in the superadmin UI."
    echo

    local rec_dir="${OUT_DIR}/device/${DEVICE_ID}" rec
    mkdir -p "${rec_dir}"
    rec="${rec_dir}/enrollment.json"
    jq -n \
        --arg device_id "${DEVICE_ID}" \
        --arg serial "${SERIAL}" \
        --arg codename "${CODENAME}" \
        --arg superdomain "${SUPERDOMAIN}" \
        --arg login_server "${LOGIN_SERVER}" \
        --arg role "${ROLE}" \
        --arg attached_domain "${ATTACHED_DOMAIN}" \
        --arg enrolled_at "$(now_iso)" \
        '{device_id:$device_id, serial:$serial, codename:$codename, os:"unknown",
          os_version:"", superdomain:$superdomain, login_server:$login_server,
          tailscale_ip:null, role:$role, attached_domain:$attached_domain,
          enrolled_at:$enrolled_at, verification:"operator-attested"}' \
        > "${rec}"
    pw_info "enrollment record written (operator-attested, no-usb): ${rec}"

    echo
    echo "== NEXT STEPS: verify the join mesh-side (no adb probe was run) =="
    echo "  1. In the superadmin UI, approve the PENDING node (ADR-14) once it"
    echo "     registers — the handset's Tailscale app shows 'Connected' after."
    echo "  2. Confirm the device appears with a 100.64/10 tailnet address"
    echo "     (headscale nodes list, or the superadmin mesh-devices view)."
    echo "  3. Once verified, run 'ingest' (add --ingest-url to publish it) to"
    echo "     record the device. 'profile' still needs adb if you also want"
    echo "     the escrowed enterprise-profile container on this handset."
    echo
}

# ── verb: enroll ───────────────────────────────────────────────────
cmd_enroll() {
    require_jq
    resolve_keys
    [ -n "${LOGIN_SERVER}" ] || pw_die 1 "no login server — pass --login-server URL or --keys-dir with a login-server file"

    if [ "${NO_USB}" -eq 1 ]; then
        cmd_enroll_no_usb
        return 0
    fi

    require_android_tools

    # Device must be up in adb (Owner profile, USB debugging enabled).
    choose_device
    local s="${SEL_SERIAL}"
    local state
    state="$("${ADB}" -s "${s}" get-state 2>/dev/null | tr -d '\r\n' || true)"
    if [ "${state}" != "device" ]; then
        echo
        echo "  The device is not reachable over adb (state: ${state:-none}). On the handset:"
        echo "    1. Finish first-boot setup in the OWNER profile."
        echo "    2. Settings -> About phone -> tap 'Build number' 7x (enables Developer options)."
        echo "    3. Settings -> System -> Developer options -> enable 'USB debugging'."
        echo "    4. Reconnect USB and accept the 'Allow USB debugging?' prompt."
        echo
        pw_die 2 "enroll needs the device up in adb — follow the handset steps above and retry"
    fi

    if [ -z "${CODENAME}" ]; then
        CODENAME="$(probe_codename "${s}" adb)"
    fi
    require_codename
    SERIAL="${s}"
    resolve_device_id

    # (1) OS probe (ADDENDUM 2026-07-16): GrapheneOS and stock Android are
    # BOTH first-class supported OSes for enroll — this wizard onboards
    # ALREADY-RUNNING phones, not only ones it flashed itself. The probe
    # records os/os_version below; it only GATES when the OS is genuinely
    # undetectable ('unknown'), and --force downgrades even that to a warning.
    probe_os "${s}"
    case "${OS_ID}" in
        grapheneos) : ;;
        android)    pw_info "device OS: stock Android${OS_VERSION:+ ${OS_VERSION}} — supported for enroll ('flash' remains GrapheneOS/Pixel-only)" ;;
        unknown)
            [ "${FORCE}" -eq 1 ] || pw_die 2 "could not determine the device OS (adb getprop returned nothing usable) — pass --force to enroll anyway"
            pw_warn "device OS could not be determined — continuing under --force (recorded as os=unknown)"
            ;;
    esac

    # (2) Tailscale app.
    local pkg="com.tailscale.ipn"
    if [ -n "${TAILSCALE_APK}" ]; then
        [ -f "${TAILSCALE_APK}" ] || pw_die 1 "--tailscale-apk not found: ${TAILSCALE_APK}"
        pw_info "installing ${TAILSCALE_APK}"
        "${ADB}" -s "${s}" install -r "${TAILSCALE_APK}" || pw_die 1 "adb install failed"
    fi
    if ! "${ADB}" -s "${s}" shell pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:${pkg}"; then
        if [ -n "${TAILSCALE_APK}" ]; then
            pw_die 1 "installed the APK but ${pkg} is not listed — wrong APK?"
        fi
        echo
        echo "  Tailscale is not installed. On the handset, install it from the"
        echo "  Play Store ('Tailscale') or drop a vetted APK and re-run with"
        echo "  --tailscale-apk. Waiting up to ${JOIN_TIMEOUT}s for it to appear…"
        echo
        local waited=0
        while ! "${ADB}" -s "${s}" shell pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:${pkg}"; do
            waited=$((waited + POLL_INTERVAL)); sleep "${POLL_INTERVAL}"
            if [ "${waited}" -ge "${JOIN_TIMEOUT}" ]; then
                [ "${FORCE}" -eq 1 ] || pw_die 2 "${pkg} did not appear within ${JOIN_TIMEOUT}s — install it and retry (or --force to skip this wait)"
                pw_warn "continuing without a visible ${pkg} (--force)"
                break
            fi
        done
    fi
    # Signer pin (fail-closed when given): verify the ON-DEVICE apk's signing
    # cert digest with apksigner (shared helper — same logic mdm-enroll and
    # attest reuse for the Headwind DPC and Auditor fork APKs).
    verify_installed_signer "${s}" "${pkg}" "${APK_SIGNER_SHA256}" "Tailscale" "--apk-signer-sha256"

    # (3) Join runbook. The pre-auth key is NEVER passed via adb shell argv
    # (adb shell command lines are visible in device-side logcat/ps) and is
    # only displayed with an explicit --show-authkey.
    echo
    echo "== tailnet join runbook (operator performs these on the handset) =="
    echo "  1. Open the Tailscale app -> Settings -> Accounts -> use a CUSTOM"
    echo "     coordination server:  ${LOGIN_SERVER}"
    echo "  2. Authenticate with the one-time pre-auth key (SEC-08: single-use,"
    echo "     24h expiry — mint a fresh one if it is stale), or via Casdoor"
    echo "     OIDC with the snapdragon/headscale group."
    if [ "${SHOW_AUTHKEY}" -eq 1 ]; then
        if [ -n "${AUTHKEY_FILE}" ] && [ -f "${AUTHKEY_FILE}" ]; then
            echo "  --show-authkey: the pre-auth key follows on the NEXT line (shown once):"
            cat "${AUTHKEY_FILE}"
        else
            pw_warn "--show-authkey given but no authkey file resolved (--authkey-file / keys-dir)"
        fi
    else
        echo "     (pre-auth key NOT displayed — paste it from your own custody, or"
        echo "      re-run with --show-authkey)"
    fi
    echo "  3. ADR-14 register-and-approve: the node registers as PENDING and only"
    echo "     joins after a superadmin approves it in the superadmin UI."
    echo

    # (4) Verify the join: poll for a CGNAT (100.64/10) address on tailscale0.
    pw_info "waiting up to ${JOIN_TIMEOUT}s for tailscale0 to get a 100.64/10 address"
    local waited=0 addr=""
    while :; do
        addr="$("${ADB}" -s "${s}" shell ip -o addr show dev tailscale0 2>/dev/null | tr -d '\r' \
            | grep -oE 'inet 100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}' \
            | head -n1 | awk '{print $2}' || true)"
        [ -n "${addr}" ] && break
        waited=$((waited + POLL_INTERVAL))
        [ "${waited}" -lt "${JOIN_TIMEOUT}" ] || pw_die 1 "device never got a tailnet address (tailscale0, 100.64/10) within ${JOIN_TIMEOUT}s — join FAILED or still pending superadmin approval; re-run enroll once approved"
        sleep "${POLL_INTERVAL}"
    done
    pw_info "tailnet join VERIFIED: ${addr}"

    # (5) Non-secret enrollment record.
    local rec_dir="${OUT_DIR}/device/${DEVICE_ID}" rec
    mkdir -p "${rec_dir}"
    rec="${rec_dir}/enrollment.json"
    jq -n \
        --arg device_id "${DEVICE_ID}" \
        --arg serial "${s}" \
        --arg codename "${CODENAME}" \
        --arg os "${OS_ID}" \
        --arg os_version "${OS_VERSION}" \
        --arg superdomain "${SUPERDOMAIN}" \
        --arg login_server "${LOGIN_SERVER}" \
        --arg tailscale_ip "${addr}" \
        --arg role "${ROLE}" \
        --arg attached_domain "${ATTACHED_DOMAIN}" \
        --arg enrolled_at "$(now_iso)" \
        '{device_id:$device_id, serial:$serial, codename:$codename, os:$os,
          os_version:$os_version, superdomain:$superdomain, login_server:$login_server,
          tailscale_ip:$tailscale_ip, role:$role,
          attached_domain:$attached_domain, enrolled_at:$enrolled_at,
          verification:"adb-heuristic"}' \
        > "${rec}"
    pw_info "enrollment record written: ${rec}"
}

# ── credential-set flow shared by profile + rotate ─────────────────
# Result lands in SET_VIA (operator|adb) — deliberately NOT printed on stdout:
# the operator runbook below goes to stdout, so a $(…) capture would swallow it.
SET_VIA=""
set_profile_credential() {
    local s="$1" uid="$2"
    SET_VIA="operator"
    if [ "${ADB_EXPOSURE_OK}" -eq 1 ]; then
        # DOCUMENTED RESIDUAL EXPOSURE: adb shell argv is visible BOTH
        # phone-side (logcat/ps on the device) AND on THIS host, in the local
        # adb client's own argv (ps auxww / /proc/<pid>/cmdline) for the life
        # of the adb child process — a real risk on shared provisioning
        # workstations, jump boxes, or CI runners. Gated behind
        # --i-understand-adb-exposure; see docs/ENTERPRISE-PHONES.md.
        #
        # `adb shell` re-joins all post-'shell' argv elements into ONE remote
        # command line that the device's shell re-parses (local bash argv-
        # array separation does not survive the trip) — so PASS_VALUE must be
        # single-quote-escaped and passed as one pre-quoted command string,
        # never as a bare argv element, or shell metacharacters in a strong
        # passphrase become live remote-shell syntax (command injection).
        pw_info "setting the profile credential over adb (user ${uid}) — argv exposure accepted via --i-understand-adb-exposure (visible on this host's process table too)"
        local q_pass
        q_pass="$(quote_for_remote_sh "${PASS_VALUE}")"
        "${ADB}" -s "${s}" shell "locksettings set-password --user ${uid} ${q_pass}" >/dev/null \
            || pw_die 1 "locksettings set-password failed for user ${uid}"
        SET_VIA="adb"
    else
        echo
        echo "== set the enterprise-profile credential (operator, on the handset) =="
        echo "  1. Switch into the '${PROFILE_NAME}' profile (Settings -> System ->"
        echo "     Users, or the QS user switcher)."
        echo "  2. Settings -> Security -> Screen lock -> Password."
        echo "  3. Enter the escrowed passphrase from:"
        echo "       $(escrow_path "${DEVICE_ID}")"
        echo "     (0600 escrow file — read it yourself; the wizard never prints it)."
        echo
        if [ -t 0 ]; then
            local ack=""
            read -r -p "Press Enter once the credential is set (or type skip): " ack
            [ "${ack}" = "skip" ] && pw_warn "credential set SKIPPED by operator — the profile is NOT yet separately encrypted"
        else
            pw_warn "non-TTY: cannot wait for operator ack — set the credential on the handset before deploying"
        fi
        # Best-effort confirmation only (needs no secret): lock_settings dumpsys
        # is often permission-restricted; failure here is not a verdict.
        "${ADB}" -s "${s}" shell dumpsys lock_settings >/dev/null 2>&1 || true
    fi
}

# ── verb: profile ──────────────────────────────────────────────────
cmd_profile() {
    require_android_tools
    require_jq
    choose_device
    local s="${SEL_SERIAL}"
    SERIAL="${s}"
    resolve_device_id

    local uid
    uid="$(profile_user_id "${s}" "${PROFILE_NAME}")"
    [ -z "${uid}" ] || pw_die 2 "a user named '${PROFILE_NAME}' already exists (id ${uid}) — use rotate-profile-pass to rotate its credential or remove-profile to recreate"

    pw_info "creating secondary user '${PROFILE_NAME}'"
    local out
    out="$("${ADB}" -s "${s}" shell pm create-user "${PROFILE_NAME}" 2>&1 | tr -d '\r' || true)"
    uid="$(sed -nE 's/^Success: created user id ([0-9]+).*$/\1/p' <<<"${out}" | head -n1)"
    [ -n "${uid}" ] || pw_die 1 "pm create-user failed: ${out}"

    pw_info "starting user ${uid}"
    if ! "${ADB}" -s "${s}" shell am start-user "${uid}" >/dev/null 2>&1; then
        "${ADB}" -s "${s}" shell am switch-user "${uid}" >/dev/null 2>&1 \
            || pw_warn "could not start user ${uid} (am start-user/switch-user) — start it from the handset user switcher"
    fi

    # Passphrase: generate (default) or --pass-file; escrow FIRST (custody
    # before anything else can fail), 0600 under vault-seed/.
    resolve_passphrase
    local escrow
    escrow="$(escrow_path "${DEVICE_ID}")"
    [ ! -f "${escrow}" ] || pw_die 2 "escrow already exists: ${escrow} — use rotate-profile-pass"
    write_escrow "${escrow}" "${PASS_VALUE}"
    pw_info "passphrase escrowed (0600): ${escrow}"
    pw_info "Vault custody convention: secret/<brand>/device/${DEVICE_ID}/phone-profile"

    set_profile_credential "${s}" "${uid}"

    local rec_dir="${OUT_DIR}/device/${DEVICE_ID}" rec
    mkdir -p "${rec_dir}"
    rec="${rec_dir}/profile.json"
    jq -n \
        --arg device_id "${DEVICE_ID}" \
        --arg user_name "${PROFILE_NAME}" \
        --argjson user_id "${uid}" \
        --arg set_via "${SET_VIA}" \
        --arg created_at "$(now_iso)" \
        '{device_id:$device_id, user_name:$user_name, user_id:$user_id,
          credential_custody:"vault-seed", set_via:$set_via, created_at:$created_at}' \
        > "${rec}"
    pw_info "profile record written: ${rec}"
}

# ── verb: rotate-profile-pass ──────────────────────────────────────
cmd_rotate_profile_pass() {
    require_android_tools
    require_jq
    choose_device
    local s="${SEL_SERIAL}"
    SERIAL="${s}"
    resolve_device_id

    local uid
    uid="$(profile_user_id "${s}" "${PROFILE_NAME}")"
    [ -n "${uid}" ] || pw_die 2 "no user named '${PROFILE_NAME}' on the device — run 'profile' first"

    resolve_passphrase
    local escrow tsuf
    escrow="$(escrow_path "${DEVICE_ID}")"
    tsuf="$(now_ts)"
    # Atomic escrow rotation: stage .new, demote current to .prev-<ts>, promote.
    write_escrow "${escrow}.new" "${PASS_VALUE}"
    if [ -f "${escrow}" ]; then
        mv "${escrow}" "${escrow}.prev-${tsuf}"
        pw_info "previous escrow kept: ${escrow}.prev-${tsuf}"
    fi
    mv "${escrow}.new" "${escrow}"
    pw_info "rotated escrow (0600): ${escrow}"

    set_profile_credential "${s}" "${uid}"
    pw_info "rotation complete (credential set_via=${SET_VIA}); push the new value to Vault: secret/<brand>/device/${DEVICE_ID}/phone-profile"
}

# ── verb: remove-profile ───────────────────────────────────────────
cmd_remove_profile() {
    require_android_tools
    choose_device
    local s="${SEL_SERIAL}"
    SERIAL="${s}"
    resolve_device_id

    local uid
    uid="$(profile_user_id "${s}" "${PROFILE_NAME}")"
    [ -n "${uid}" ] || pw_die 2 "no user named '${PROFILE_NAME}' on the device — nothing to remove"

    echo
    echo "  !!! DESTRUCTIVE: removing user '${PROFILE_NAME}' (id ${uid}) on ${s}."
    echo "  !!! All data inside the enterprise profile is destroyed (per-profile"
    echo "  !!! FBE keys are evicted and gone)."
    echo
    if [ -t 0 ]; then
        local typed=""
        read -r -p "Type the profile name (${PROFILE_NAME}) to confirm: " typed
        [ "${typed}" = "${PROFILE_NAME}" ] || pw_die 2 "confirmation mismatch — aborted"
    else
        [ "${ASSUME_YES}" -eq 1 ] || pw_die 2 "refusing to remove the profile on a non-TTY without --yes"
    fi

    local out
    out="$("${ADB}" -s "${s}" shell pm remove-user "${uid}" 2>&1 | tr -d '\r' || true)"
    grep -q '^Success' <<<"${out}" || pw_die 1 "pm remove-user ${uid} failed: ${out}"
    pw_info "user ${uid} ('${PROFILE_NAME}') removed"

    local escrow
    escrow="$(escrow_path "${DEVICE_ID}")"
    if [ -f "${escrow}" ]; then
        mv "${escrow}" "${escrow}.revoked-$(now_ts)"
        pw_info "escrow retired: ${escrow}.revoked-* (revoke the Vault copy too)"
    else
        pw_warn "no escrow file at ${escrow} — nothing to retire"
    fi
}

# ── verb: ingest ───────────────────────────────────────────────────
cmd_ingest() {
    require_jq
    resolve_keys

    # Prefer recorded facts (enrollment.json/profile.json); fall back to live
    # detection only for what is missing and reachable.
    if [ -z "${DEVICE_ID}" ] && [ -z "${SERIAL}" ]; then
        pw_die 1 "ingest needs --device-id or --serial (or run it after enroll, passing the same identifiers)"
    fi
    resolve_device_id

    local rec_dir="${OUT_DIR}/device/${DEVICE_ID}"
    local enr="${rec_dir}/enrollment.json" prof="${rec_dir}/profile.json"
    local serial="${SERIAL}" codename="${CODENAME}" login_server="${LOGIN_SERVER}"
    local ts_ip="" enrolled_at="" attached="${ATTACHED_DOMAIN}" role="${ROLE}"
    local os_id="" os_version=""
    if [ -f "${enr}" ]; then
        serial="${serial:-$(jq -r '.serial // empty' "${enr}")}"
        codename="${codename:-$(jq -r '.codename // empty' "${enr}")}"
        login_server="${login_server:-$(jq -r '.login_server // empty' "${enr}")}"
        ts_ip="$(jq -r '.tailscale_ip // empty' "${enr}")"
        enrolled_at="$(jq -r '.enrolled_at // empty' "${enr}")"
        attached="${attached:-$(jq -r '.attached_domain // empty' "${enr}")}"
        role="$(jq -r --arg d "${role}" '.role // $d' "${enr}")"
        os_id="$(jq -r '.os // empty' "${enr}")"
        os_version="$(jq -r '.os_version // empty' "${enr}")"
        [ "${SUPERDOMAIN_SET}" -eq 0 ] && SUPERDOMAIN="$(jq -r --arg d "${SUPERDOMAIN}" '.superdomain // $d' "${enr}")"
    fi
    [ -n "${codename}" ] || pw_die 1 "cannot resolve the codename — pass --codename or run enroll first"
    CODENAME="${codename}"
    require_codename

    # Live best-effort extras over adb (never fatal — phones may be unplugged).
    # os/os_version: prefer the recorded enrollment fact; fall back to a live
    # probe only when nothing was recorded (e.g. ingest run standalone).
    local ts_hostname="${DEVICE_ID}"
    if [ -n "${serial}" ] && have "${ADB}"; then
        if [ -z "${os_id}" ]; then
            probe_os "${serial}"
            os_id="${OS_ID}"; os_version="${OS_VERSION}"
        fi
        local hn
        hn="$("${ADB}" -s "${serial}" shell getprop net.hostname 2>/dev/null | tr -d '\r\n' || true)"
        [ -n "${hn}" ] && ts_hostname="${hn}"
    fi
    os_id="${os_id:-unknown}"

    local prof_present=false prof_uid=null
    if [ -f "${prof}" ]; then
        prof_present=true
        prof_uid="$(jq -r '.user_id // "null"' "${prof}")"
    fi

    # Fold the attest record in when present (Phase 3) — advisory/logged
    # fields only (D9: attestation is never enrollment-blocking in v1).
    local attest_json="${rec_dir}/attestation.json"
    local attestation_url="" auditor_package="" attestation_verdict=""
    if [ -f "${attest_json}" ]; then
        attestation_url="$(jq -r '.attestation_url // empty' "${attest_json}")"
        auditor_package="$(jq -r '.auditor_package // empty' "${attest_json}")"
        attestation_verdict="$(jq -r '.verdict // empty' "${attest_json}")"
    fi

    mkdir -p "${rec_dir}"
    local ingest="${rec_dir}/ingest.json"
    jq -n \
        --arg device_id "${DEVICE_ID}" \
        --arg serial "${serial}" \
        --arg codename "${codename}" \
        --arg marketing_name "${DEVICE_NAME}" \
        --arg os "${os_id}" \
        --arg os_version "${os_version}" \
        --arg superdomain "${SUPERDOMAIN}" \
        --arg login_server "${login_server}" \
        --arg tailscale_ip "${ts_ip}" \
        --arg tailscale_hostname "${ts_hostname}" \
        --arg role "${role}" \
        --arg attached_domain "${attached}" \
        --argjson profile_present "${prof_present}" \
        --argjson profile_uid "${prof_uid}" \
        --arg attestation_url "${attestation_url}" \
        --arg auditor_package "${auditor_package}" \
        --arg attestation_verdict "${attestation_verdict}" \
        --arg enrolled_at "${enrolled_at}" \
        --arg generated_at "$(now_iso)" \
        '{schema:"phone-ingest/v1", device_id:$device_id, device_class:"phone",
          serial:$serial, codename:$codename, marketing_name:$marketing_name,
          os:$os, os_version:$os_version, superdomain:$superdomain,
          login_server:$login_server, tailscale_ip:$tailscale_ip,
          tailscale_hostname:$tailscale_hostname, role:$role,
          attached_domain:$attached_domain,
          enterprise_profile:{present:$profile_present, user_id:$profile_uid,
                              credential_custody:"vault-seed"},
          attestation_url:$attestation_url, auditor_package:$auditor_package,
          attestation_verdict:$attestation_verdict,
          enrolled_at:$enrolled_at, generated_at:$generated_at}' \
        > "${ingest}"
    pw_info "ingest record written: ${ingest}"

    if [ -n "${INGEST_URL}" ]; then
        # Mirror the device-enrollment-report transport: mTLS client identity,
        # --fail, JSON body. Fail-closed on missing identity material.
        require_tool curl "install net-misc/curl"
        { [ -n "${CLIENT_CERT}" ] && [ -n "${CLIENT_KEY}" ] && [ -f "${CLIENT_CERT}" ] && [ -f "${CLIENT_KEY}" ]; } \
            || pw_die 2 "--ingest-url needs --client-cert and --client-key (mTLS-gated ingest, fail-closed)"
        local args=(-sS -m 30 --fail -X POST -H 'Content-Type: application/json' --data-binary @"${ingest}")
        [ -n "${CA_FILE}" ] && args+=(--cacert "${CA_FILE}")
        args+=(--cert "${CLIENT_CERT}" --key "${CLIENT_KEY}")
        pw_info "POSTing ingest record to ${INGEST_URL}"
        curl "${args[@]}" "${INGEST_URL}" >/dev/null \
            || pw_die 1 "ingest POST failed (${INGEST_URL}) — the record is still at ${ingest}; retry with the same flags"
        pw_info "ingest POST accepted"
    else
        echo
        echo "== next step: register the device =="
        echo "  Emit-only mode. No dedicated phone-ingest registry endpoint"
        echo "  exists yet (the /bff/internal/device-enrollment/self-report"
        echo "  route is a DIFFERENT, machine-key-fp cluster-node contract —"
        echo "  it will reject this phone-ingest/v1 record). Hand ${ingest}"
        echo "  to the registry importer, or use --ingest-url once a real"
        echo "  phone-ingest endpoint is stood up (mTLS client identity via"
        echo "  --client-cert/--client-key/--ca)."
    fi
}

# ── verb: status ───────────────────────────────────────────────────
cmd_status() {
    echo "== phone-wizard status (read-only) =="
    local t
    for t in "${ADB}" "${FASTBOOT}" curl ssh-keygen bsdtar jq; do
        if have "${t}"; then echo "tool ${t}: OK"; else echo "tool ${t}: MISSING"; fi
    done
    echo
    if have "${ADB}" && have "${FASTBOOT}"; then
        list_devices
        local s
        for s in ${FB_SERIALS[@]+"${FB_SERIALS[@]}"}; do echo "device ${s}: fastboot (bootloader)"; done
        for s in ${ADB_SERIALS[@]+"${ADB_SERIALS[@]}"}; do
            echo "device ${s}: adb"
            local addr
            addr="$("${ADB}" -s "${s}" shell ip -o addr show dev tailscale0 2>/dev/null | tr -d '\r' \
                | grep -oE 'inet 100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n1 | awk '{print $2}' || true)"
            echo "  tailscale0: ${addr:-no address (not joined / app not running)}"
            local uid
            uid="$(profile_user_id "${s}" "${PROFILE_NAME}")"
            echo "  profile '${PROFILE_NAME}': ${uid:+present (user id ${uid})}${uid:-absent}"
            if [ -z "${DEVICE_ID}" ]; then SERIAL="${s}"; resolve_device_id; fi
        done
        [ "${#FB_SERIALS[@]}" -eq 0 ] && [ "${#ADB_SERIALS[@]}" -eq 0 ] && echo "no device connected"
    else
        echo "device probing skipped (adb/fastboot missing)"
    fi
    echo
    if [ -n "${DEVICE_ID}" ]; then
        local escrow
        escrow="$(escrow_path "${DEVICE_ID}")"
        if [ -f "${escrow}" ]; then
            echo "escrow (${DEVICE_ID}): present ($(stat -c '%a' "${escrow}" 2>/dev/null || echo '?') ${escrow})"
        else
            echo "escrow (${DEVICE_ID}): absent (${escrow})"
        fi
    else
        echo "escrow: pass --device-id/--serial to check a specific device"
    fi
}

# ── verb: wizard (interactive guided flow) ─────────────────────────
wiz_confirm() {
    local prompt="$1" ans=""
    read -r -p "${prompt} [Y/n/q] " ans
    case "${ans}" in
        q|Q) pw_die 1 "wizard aborted by operator" ;;
        n|N) return 1 ;;
        *)   return 0 ;;
    esac
}

cmd_wizard() {
    [ -t 0 ] || pw_die 2 "the wizard is interactive and needs a TTY — use the individual verbs (detect/fetch/flash/attest/mdm-enroll/enroll/profile/ingest) for scripting"

    # Front-load every downstream step's hard, knowable-in-advance
    # preconditions BEFORE Step 3's destructive flash runs — otherwise an
    # operator can complete the irreversible bootloader-unlock/wipe/flash/lock
    # sequence only to have a later step immediately die on one of these same
    # checks. Mirrors cmd_flash's own preflight-before-destructive-gate style.
    resolve_keys
    [ -n "${LOGIN_SERVER}" ] || pw_die 1 "no login server — pass --login-server URL or --keys-dir with a login-server file"
    [ -n "${ATTESTATION_URL}" ] || pw_die 1 "no --attestation-url (or ATTEST_URL) — the self-hosted AttestationServer console URL, needed by Step 4 (attest)"
    [ -n "${HEADWIND_URL}" ] || pw_die 1 "no --headwind-url (or HMDM_URL) — the Headwind DPC's non-interactive config target, needed by Step 5 (mdm-enroll)"

    echo "== enterprise-phone wizard =="
    echo "Guided flow: detect -> fetch -> flash -> attest -> mdm-enroll -> enroll -> profile -> ingest."
    echo "Each step asks first; already-completed steps can be skipped (re-entrant)."
    echo "CRITICAL ordering: attest runs on the cleanest device state (before"
    echo "device-owner); mdm-enroll (device-owner) MUST run before profile, which"
    echo "creates the secondary user that permanently forecloses device-owner mode."
    echo

    # 1/8 detect (fills SERIAL/CODENAME for everything after).
    if wiz_confirm "Step 1/8 — detect the USB-connected device?"; then
        cmd_detect
    fi
    resolve_device_id

    # 2/8 fetch (skippable when a verified artifact already exists).
    local have_verified=0
    if [ -n "${CODENAME}" ]; then
        local z
        z="$(ls -1t "${WORK_DIR}/${CODENAME}"-install-*.zip 2>/dev/null | head -n1 || true)"
        if [ -n "${z}" ] && [ -f "${z}.verified-$(sha256_of "${z}" 2>/dev/null || echo none)" ]; then
            have_verified=1
        fi
    fi
    if [ "${have_verified}" -eq 1 ]; then
        if wiz_confirm "Step 2/8 — a VERIFIED artifact already exists; re-run fetch anyway?"; then cmd_fetch; fi
    else
        if wiz_confirm "Step 2/8 — fetch + verify GrapheneOS for '${CODENAME:-<detect first>}' (${CHANNEL})?"; then cmd_fetch; fi
    fi

    # 3/8 flash (its own typed-serial gate runs inside).
    if wiz_confirm "Step 3/8 — FLASH the device (DESTROYS ALL DATA)?"; then
        cmd_flash
        echo
        echo "  Handset time: boot GrapheneOS, complete first-boot setup, then enable"
        echo "  Developer options + USB debugging in the OWNER profile."
        read -r -p "  Press Enter when the device is back up with USB debugging enabled… " _
    fi

    # 4/8 attest — BEFORE mdm-enroll: needs no device-owner state and captures
    # the hardware trust root on the cleanest possible device state.
    if [ -n "${DEVICE_ID}" ] && [ -f "${OUT_DIR}/device/${DEVICE_ID}/attestation.json" ]; then
        if wiz_confirm "Step 4/8 — attestation record already exists; re-pair?"; then cmd_attest; fi
    else
        if wiz_confirm "Step 4/8 — pair the device to the self-hosted AttestationServer?"; then cmd_attest; fi
    fi

    # 5/8 mdm-enroll — MUST run before Step 7 (profile), which creates the
    # secondary user that permanently forecloses device-owner mode.
    if [ -n "${DEVICE_ID}" ] && [ -f "${OUT_DIR}/device/${DEVICE_ID}/mdm.json" ]; then
        if wiz_confirm "Step 5/8 — MDM enrollment record already exists; re-enroll (fails if a secondary user now exists)?"; then cmd_mdm_enroll; fi
    else
        if wiz_confirm "Step 5/8 — enroll the device as a Headwind MDM device-owner?"; then cmd_mdm_enroll; fi
    fi

    # 6/8 enroll (skippable when the record already exists).
    if [ -n "${DEVICE_ID}" ] && [ -f "${OUT_DIR}/device/${DEVICE_ID}/enrollment.json" ]; then
        if wiz_confirm "Step 6/8 — enrollment record already exists; re-enroll?"; then cmd_enroll; fi
    else
        if wiz_confirm "Step 6/8 — enroll the device in the mesh (tailnet join)?"; then cmd_enroll; fi
    fi
    resolve_device_id

    # 7/8 profile.
    if [ -n "${DEVICE_ID}" ] && [ -f "${OUT_DIR}/device/${DEVICE_ID}/profile.json" ]; then
        if wiz_confirm "Step 7/8 — profile record already exists; rotate its passphrase instead?"; then cmd_rotate_profile_pass; fi
    else
        if wiz_confirm "Step 7/8 — create + escrow the enterprise profile?"; then cmd_profile; fi
    fi

    # 8/8 ingest.
    if wiz_confirm "Step 8/8 — emit the device-registry ingest record?"; then cmd_ingest; fi

    echo
    pw_info "wizard complete — records under ${OUT_DIR}/device/${DEVICE_ID:-<device-id>}/, escrow under ${OUT_DIR}/vault-seed/"
}

# ── Arg parse + dispatch ───────────────────────────────────────────
main() {
    local verb="${1:-help}"
    [ $# -gt 0 ] && shift
    case "${verb}" in
        -h|--help|help) usage 0 ;;
        --print-plan)   verb="plan" ;;
    esac

    local plan_target=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --serial)              _need_arg "$1" $#; SERIAL="$2"; shift 2 ;;
            --codename)            _need_arg "$1" $#; CODENAME="$2"; shift 2 ;;
            --channel)             _need_arg "$1" $#; CHANNEL="$2"; shift 2 ;;
            --graphene-version)    _need_arg "$1" $#; GRAPHENE_VERSION="$2"; shift 2 ;;
            --work-dir)            _need_arg "$1" $#; WORK_DIR="$2"; shift 2 ;;
            --out)                 _need_arg "$1" $#; OUT_DIR="$2"; shift 2 ;;
            --keys-dir)            _need_arg "$1" $#; KEYS_DIR="$2"; shift 2 ;;
            --login-server)        _need_arg "$1" $#; LOGIN_SERVER="$2"; shift 2 ;;
            --authkey-file)        _need_arg "$1" $#; AUTHKEY_FILE="$2"; shift 2 ;;
            --pass-file)           _need_arg "$1" $#; PASS_FILE="$2"; shift 2 ;;
            --device-id)           _need_arg "$1" $#; DEVICE_ID="$2"; shift 2 ;;
            --superdomain)         _need_arg "$1" $#; SUPERDOMAIN="$2"; SUPERDOMAIN_SET=1; shift 2 ;;
            --role)                _need_arg "$1" $#; ROLE="$2"; shift 2 ;;
            --profile-name)        _need_arg "$1" $#; PROFILE_NAME="$2"; shift 2 ;;
            --tailscale-apk)       _need_arg "$1" $#; TAILSCALE_APK="$2"; shift 2 ;;
            --apk-signer-sha256)   _need_arg "$1" $#; APK_SIGNER_SHA256="$2"; shift 2 ;;
            --headwind-apk)          _need_arg "$1" $#; HEADWIND_APK="$2"; shift 2 ;;
            --headwind-signer-sha256) _need_arg "$1" $#; HEADWIND_SIGNER_SHA256="$2"; shift 2 ;;
            --headwind-url)          _need_arg "$1" $#; HEADWIND_URL="$2"; shift 2 ;;
            --auditor-apk)           _need_arg "$1" $#; AUDITOR_APK="$2"; shift 2 ;;
            --auditor-signer-sha256) _need_arg "$1" $#; AUDITOR_SIGNER_SHA256="$2"; shift 2 ;;
            --attestation-url)       _need_arg "$1" $#; ATTESTATION_URL="$2"; shift 2 ;;
            --ingest-url)          _need_arg "$1" $#; INGEST_URL="$2"; shift 2 ;;
            --client-cert)         _need_arg "$1" $#; CLIENT_CERT="$2"; shift 2 ;;
            --client-key)          _need_arg "$1" $#; CLIENT_KEY="$2"; shift 2 ;;
            --ca)                  _need_arg "$1" $#; CA_FILE="$2"; shift 2 ;;
            --yes)                 ASSUME_YES=1; shift ;;
            --force)               FORCE=1; shift ;;
            --force-fwupd)         FORCE_FWUPD=1; shift ;;
            --show-authkey)        SHOW_AUTHKEY=1; shift ;;
            --no-usb)              NO_USB=1; shift ;;
            --i-understand-adb-exposure) ADB_EXPOSURE_OK=1; shift ;;
            --resolve)             RESOLVE=1; shift ;;
            --print-plan)          PRINT_PLAN=1; shift ;;
            --no-color)            NO_COLOR=1; shift ;;
            -h|--help)             usage 0 ;;
            -*)                    echo "Unknown option: $1" >&2; usage 1 ;;
            *)
                if [ "${verb}" = "plan" ] && [ -z "${plan_target}" ]; then
                    plan_target="$1"; shift
                else
                    echo "Unexpected extra argument: $1" >&2; usage 1
                fi ;;
        esac
    done
    apply_colors
    validate_profile_name

    # --print-plan anywhere plans the given verb instead of running it.
    if [ "${PRINT_PLAN}" -eq 1 ] && [ "${verb}" != "plan" ]; then
        plan_target="${verb}"
        verb="plan"
    fi

    case "${verb}" in
        plan)                cmd_plan "${plan_target:-wizard}" ;;
        detect)              cmd_detect ;;
        fetch)               cmd_fetch ;;
        flash)               cmd_flash ;;
        attest)               cmd_attest ;;
        mdm-enroll)           cmd_mdm_enroll ;;
        enroll)              cmd_enroll ;;
        profile)             cmd_profile ;;
        rotate-profile-pass) cmd_rotate_profile_pass ;;
        remove-profile)      cmd_remove_profile ;;
        ingest)              cmd_ingest ;;
        status)              cmd_status ;;
        wizard)              cmd_wizard ;;
        *) echo "Unknown verb: ${verb}" >&2; usage 1 ;;
    esac
}

main "$@"
