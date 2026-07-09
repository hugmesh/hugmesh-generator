#!/usr/bin/env bash
# go-live-menu.sh — a console (ncurses/whiptail) front door for the go-live wizard.
#
# WHAT IT IS
#   An interactive terminal menu that drives the SAME flags scripts/go-live.sh
#   exposes (list / links / emit / verify / flip / rollback / status). It adds
#   NOTHING to the go-live engine — it just makes the knobs discoverable, in
#   the exact spirit of scripts/build-menu.sh over the `make` build targets.
#   Both front-ends read the one declarative provider catalog
#   (scripts/golive-providers.conf), so a new provider needs zero menu edits.
#
# SECRETS
#   Tokens are prompted MASKED, never persisted to the menu's saved options,
#   and handed to the engine via a 0600 temp file (--token-file) that is
#   deleted right after the run — they never appear in argv or on screen.
#
# THE FLIP
#   The engine's own typed-domain confirmation runs in the clear terminal —
#   the menu never wraps or weakens it (unattended go-live is a v1 non-goal).
#
# RENDERER
#   Uses whiptail (newt/ncurses) when a real TTY + whiptail are present;
#   otherwise falls back to a plain numbered-prompt menu (set NO_TUI=1 to
#   force the fallback) — the same UI abstraction as scripts/build-menu.sh.
#
# RUN IT
#   ./scripts/go-live-menu.sh          # or:  make go-live-menu
#
# It is interactive, so it deliberately does NOT use `set -e`: a TUI runs many
# commands that return non-zero benignly (whiptail Cancel = 1, grep no-match =
# 1). We keep -u/pipefail and handle every error explicitly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENGINE="${SCRIPT_DIR}/go-live.sh"
CATALOG="${GOLIVE_CATALOG:-${SCRIPT_DIR}/golive-providers.conf}"

# ── Colours (only when stderr is a TTY, matching scripts/build-menu.sh) ──────────
if [ -t 2 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
    C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_BLD=''; C_RST=''
fi
say()  { printf '%s[go-live-menu]%s %s\n' "${C_GRN}" "${C_RST}" "$*" >&2; }
warn() { printf '%s[go-live-menu] WARN:%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s[go-live-menu] ERROR:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }

# ── Persistent state (user-writable; NON-SECRET options only) ────────────────────
STATE_DIR="${SNAP_GOLIVE_STATE:-${XDG_STATE_HOME:-${HOME}/.local/state}/snapdragon-golive-menu}"
mkdir -p "${STATE_DIR}" 2>/dev/null || STATE_DIR="$(mktemp -d)"
CONF_FILE="${STATE_DIR}/menu.conf"

# ── Wizard option defaults (overridable in the Inputs screen; persisted) ─────────
OPT_PROVIDER=""           # a [section] id from golive-providers.conf
OPT_DOMAIN=""             # public domain (engine autofills from the device bake)
OPT_RECORD_IP=""          # public A/AAAA value (registrar-manual / router-manual)
OPT_TUNNEL_ID=""          # Cloudflare tunnel UUID (CNAME autofill / --create-dns)
OPT_DDNS_SERVICE="duckdns" # duckdns | cloudflare
OPT_DDNS_SUBDOMAIN=""     # DDNS hostname label
OPT_OUT_DIR=""            # artifact dir (empty = engine default: <repo>/out/go-live)
OPT_KEYS_DIR=""           # keys layout root (empty = engine default: keys-template/)
# SECRETS are deliberately NOT persisted (never written to ${CONF_FILE}); they
# are prompted fresh per action and live only in a 0600 temp file for the run.

# Restore saved options from a previous session (best-effort; ignore a bad file).
# shellcheck disable=SC1090
[ -f "${CONF_FILE}" ] && source "${CONF_FILE}" 2>/dev/null || true

save_conf() {
    {
        printf 'OPT_PROVIDER=%q\n'       "${OPT_PROVIDER}"
        printf 'OPT_DOMAIN=%q\n'         "${OPT_DOMAIN}"
        printf 'OPT_RECORD_IP=%q\n'      "${OPT_RECORD_IP}"
        printf 'OPT_TUNNEL_ID=%q\n'      "${OPT_TUNNEL_ID}"
        printf 'OPT_DDNS_SERVICE=%q\n'   "${OPT_DDNS_SERVICE}"
        printf 'OPT_DDNS_SUBDOMAIN=%q\n' "${OPT_DDNS_SUBDOMAIN}"
        printf 'OPT_OUT_DIR=%q\n'        "${OPT_OUT_DIR}"
        printf 'OPT_KEYS_DIR=%q\n'       "${OPT_KEYS_DIR}"
    } > "${CONF_FILE}" 2>/dev/null || true
}

# ── UI abstraction: whiptail when we can, a text prompt when we cannot ──────────
# (Same contract as scripts/build-menu.sh's helpers.)
HAVE_TUI=0
if [ -z "${NO_TUI:-}" ] && [ -t 0 ] && [ -t 1 ] \
   && [ "${TERM:-dumb}" != dumb ] && command -v whiptail >/dev/null 2>&1; then
    HAVE_TUI=1
fi
WT_TITLE="Snapdragon Go-Live Wizard"

# ui_menu TITLE PROMPT  tag1 item1  tag2 item2 ...   -> echoes chosen tag, rc=1 on cancel
ui_menu() {
    local title="$1" prompt="$2"; shift 2
    if [ "${HAVE_TUI}" = 1 ]; then
        whiptail --title "${WT_TITLE} — ${title}" --notags --menu "${prompt}" \
            22 78 12 "$@" 3>&1 1>&2 2>&3
        return $?
    fi
    local -a tags=() items=(); local i
    while [ "$#" -ge 2 ]; do tags+=("$1"); items+=("$2"); shift 2; done
    printf '\n%s== %s ==%s\n' "${C_BLD}" "${title}" "${C_RST}" >&2
    printf '%b\n' "${prompt}" >&2
    for i in "${!items[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${items[$i]}" >&2; done
    printf '   q) back / cancel\n' >&2
    local choice
    while true; do
        read -r -p "choice: " choice </dev/tty || return 1
        { [ "${choice}" = q ] || [ -z "${choice}" ]; } && return 1
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#tags[@]}" ]; then
            printf '%s' "${tags[$((choice-1))]}"; return 0
        fi
        warn "invalid choice — enter 1-${#tags[@]} or q"
    done
}

# ui_yesno TITLE TEXT  -> rc 0 = yes, 1 = no
ui_yesno() {
    local title="$1" text="$2"
    if [ "${HAVE_TUI}" = 1 ]; then
        whiptail --title "${WT_TITLE} — ${title}" --yesno "${text}" 14 78
        return $?
    fi
    printf '\n%b\n' "${text}" >&2
    local a; read -r -p "[y/N]: " a </dev/tty || return 1
    [[ "${a}" =~ ^[Yy] ]]
}

# ui_input TITLE TEXT DEFAULT  -> echoes the entered value (default on empty/cancel)
ui_input() {
    local title="$1" text="$2" def="$3" val
    if [ "${HAVE_TUI}" = 1 ]; then
        val="$(whiptail --title "${WT_TITLE} — ${title}" --inputbox "${text}" 12 78 "${def}" 3>&1 1>&2 2>&3)" \
            || { printf '%s' "${def}"; return 0; }
        printf '%s' "${val}"; return 0
    fi
    read -r -e -i "${def}" -p "${text}: " val </dev/tty || val="${def}"
    printf '%s' "${val:-${def}}"
}

# ui_password TITLE TEXT  -> echoes the entered secret (hidden input). Never logged,
# never persisted by the caller. Empty result is a valid "skip".
ui_password() {
    local title="$1" text="$2" val
    if [ "${HAVE_TUI}" = 1 ]; then
        val="$(whiptail --title "${WT_TITLE} — ${title}" --passwordbox "${text}" 12 78 3>&1 1>&2 2>&3)" \
            || { printf ''; return 0; }
        printf '%s' "${val}"; return 0
    fi
    read -r -s -p "${text}: " val </dev/tty || val=""
    printf '\n' >&2
    printf '%s' "${val}"
}

# ui_msg TITLE TEXT  -> informational box / printout
ui_msg() {
    local title="$1" text="$2"
    if [ "${HAVE_TUI}" = 1 ]; then
        whiptail --title "${WT_TITLE} — ${title}" --scrolltext --msgbox "${text}" 22 78
    else
        printf '\n%s== %s ==%s\n' "${C_BLD}" "${title}" "${C_RST}" >&2
        printf '%b\n' "${text}" >&2
        read -r -p "press Enter…" _ </dev/tty || true
    fi
}

# ── Catalog access (display only — the ONE shared declarative source) ────────────
cat_sections() { awk -F'[][]' '/^\[/ { print $2 }' "${CATALOG}"; }
cat_get() {
    awk -v s="$1" -v k="$2" '
        /^\[/ { in_s = ($0 == "[" s "]"); next }
        in_s && $1 == k && $2 == "=" { line = $0; sub(/^[^=]*= ?/, "", line); print line; exit }
    ' "${CATALOG}"
}

# ── Engine dispatch — every action below is JUST a go-live.sh flag spelling ──────
# base_flags -> the option flags derived from the saved inputs (NEVER a secret).
base_flags() {
    local -a f=()
    [ -n "${OPT_PROVIDER}" ]       && f+=(--provider "${OPT_PROVIDER}")
    [ -n "${OPT_DOMAIN}" ]         && f+=(--domain "${OPT_DOMAIN}")
    [ -n "${OPT_RECORD_IP}" ]      && f+=(--record-ip "${OPT_RECORD_IP}")
    [ -n "${OPT_TUNNEL_ID}" ]      && f+=(--tunnel-id "${OPT_TUNNEL_ID}")
    [ -n "${OPT_DDNS_SERVICE}" ]   && f+=(--ddns-service "${OPT_DDNS_SERVICE}")
    [ -n "${OPT_DDNS_SUBDOMAIN}" ] && f+=(--ddns-subdomain "${OPT_DDNS_SUBDOMAIN}")
    [ -n "${OPT_OUT_DIR}" ]        && f+=(--out "${OPT_OUT_DIR}")
    [ -n "${OPT_KEYS_DIR}" ]       && f+=(--keys-dir "${OPT_KEYS_DIR}")
    printf '%q ' "${f[@]+"${f[@]}"}"
}

# run_engine FLAGS... — run the engine in the clear terminal so its own output,
# prompts (masked token entry, the typed flip confirm) and colours work as-is.
run_engine() {
    local -a extra=("$@") flags
    # shellcheck disable=SC2294
    eval "flags=($(base_flags))"
    clear 2>/dev/null || true
    say "running: go-live.sh ${flags[*]+"${flags[*]}"} ${extra[*]+"${extra[*]}"}"
    bash "${ENGINE}" "${flags[@]+"${flags[@]}"}" "${extra[@]+"${extra[@]}"}"
    local rc=$?
    printf '\n' >&2
    read -r -p "press Enter to return to the menu…" _ </dev/tty || true
    return "${rc}"
}

# run_engine_with_token PROMPT FLAGS... — masked token prompt -> 0600 temp file
# -> --token-file; the file is removed right after the run.
run_engine_with_token() {
    local prompt="$1"; shift
    local tok tf
    tok="$(ui_password "Token" "${prompt}\n(taken once, handed to the engine via a 0600 temp file, then deleted — never saved)")"
    if [ -z "${tok}" ]; then
        ui_msg "Token" "No token entered — the engine will prompt on its own TTY instead (or cancel there)."
        run_engine "$@"
        return $?
    fi
    tf="$(umask 077 && mktemp "${STATE_DIR}/.tok.XXXXXX")" || { warn "mktemp failed"; return 1; }
    printf '%s\n' "${tok}" > "${tf}"
    tok=""
    run_engine --token-file "${tf}" "$@"
    local rc=$?
    rm -f "${tf}" 2>/dev/null
    return "${rc}"
}

# ── Screens ──────────────────────────────────────────────────────────────────────
provider_screen() {
    local -a items=(); local p
    while IFS= read -r p; do
        items+=("${p}" "$(printf '%-18s %s' "${p}" "$(cat_get "${p}" title)")")
    done < <(cat_sections)
    items+=(back "‹ back")
    local choice
    choice="$(ui_menu "Provider" "Pick the exposure provider (current: ${OPT_PROVIDER:-none}).\nDetails: main menu → Provider info." "${items[@]}")" || return 0
    [ "${choice}" = back ] && return 0
    OPT_PROVIDER="${choice}"
    save_conf
    ui_msg "Provider" "$(cat_get "${choice}" title)\n\n$(cat_get "${choice}" summary)\n\nRequired inputs: $(cat_get "${choice}" inputs)\nOptional inputs: $(cat_get "${choice}" optional)"
}

inputs_screen() {
    while true; do
        local choice
        choice="$(ui_menu "Inputs" "Wizard inputs (autofill: the engine reads the device's baked cluster domain when Domain is left empty)." \
            domain  "Domain ............ ${OPT_DOMAIN:-(engine autofill / device bake)}" \
            ip      "Record IP ......... ${OPT_RECORD_IP:-(unset)}" \
            tunnel  "CF tunnel UUID .... ${OPT_TUNNEL_ID:-(unset)}" \
            ddnss   "DDNS service ...... ${OPT_DDNS_SERVICE}" \
            ddnssub "DDNS subdomain .... ${OPT_DDNS_SUBDOMAIN:-(unset)}" \
            out     "Artifact dir ...... ${OPT_OUT_DIR:-(engine default: out/go-live)}" \
            keys    "Keys layout dir ... ${OPT_KEYS_DIR:-(engine default: keys-template/)}" \
            back    "‹ back")" || { save_conf; return 0; }
        case "${choice}" in
            domain)  OPT_DOMAIN="$(ui_input "Domain" "Public domain to go live on (empty = engine autofill from the device bake)" "${OPT_DOMAIN}")" ;;
            ip)      OPT_RECORD_IP="$(ui_input "Record IP" "Public A/AAAA record value (registrar-manual / router paths)" "${OPT_RECORD_IP}")" ;;
            tunnel)  OPT_TUNNEL_ID="$(ui_input "Tunnel UUID" "Cloudflare tunnel UUID (CNAME target <uuid>.cfargotunnel.com; enables --create-dns)" "${OPT_TUNNEL_ID}")" ;;
            ddnss)   OPT_DDNS_SERVICE="$(ui_menu "DDNS service" "Which thin DDNS driver?" \
                         duckdns "DuckDNS (single account token)" \
                         cloudflare "Cloudflare DNS-record update (zone-scoped API token)" \
                         back "‹ keep ${OPT_DDNS_SERVICE}")" || true
                     [ "${OPT_DDNS_SERVICE}" = back ] || [ -n "${OPT_DDNS_SERVICE}" ] || OPT_DDNS_SERVICE="duckdns"
                     [ "${OPT_DDNS_SERVICE}" = back ] && OPT_DDNS_SERVICE="duckdns" ;;
            ddnssub) OPT_DDNS_SUBDOMAIN="$(ui_input "DDNS subdomain" "DDNS hostname label (e.g. 'home' -> home.duckdns.org / home.<domain>)" "${OPT_DDNS_SUBDOMAIN}")" ;;
            out)     OPT_OUT_DIR="$(ui_input "Artifact dir" "Where --emit writes records/zone/checklist (empty = engine default)" "${OPT_OUT_DIR}")" ;;
            keys)    OPT_KEYS_DIR="$(ui_input "Keys dir" "Keys layout root the tokens are written under (empty = engine default keys-template/)" "${OPT_KEYS_DIR}")" ;;
            back|"") save_conf; return 0 ;;
        esac
        save_conf
    done
}

links_screen() {
    [ -n "${OPT_PROVIDER}" ] || { ui_msg "Links" "Pick a provider first."; return 0; }
    ui_msg "Deep links — ${OPT_PROVIDER}" "$(bash "${ENGINE}" --provider "${OPT_PROVIDER}" --links 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')"
    ui_yesno "Open" "Open these pages in the default browser now?\n(xdg-open; engine flag --links --open)" \
        && run_engine --links --open
}

emit_screen() {
    [ -n "${OPT_PROVIDER}" ] || { ui_msg "Emit" "Pick a provider first."; return 0; }
    local inputs; inputs="$(cat_get "${OPT_PROVIDER}" inputs)"
    if [[ " ${inputs} " == *' token '* ]]; then
        run_engine_with_token "$(cat_get "${OPT_PROVIDER}" title)\n\nPaste the provider token (see the Links screen for where to create it)." --emit
    else
        run_engine --emit
    fi
}

create_dns_screen() {
    [ "${OPT_PROVIDER}" = cloudflare-tunnel ] \
        || { ui_msg "Create DNS" "--create-dns is the OPTIONAL Cloudflare thin driver — pick the cloudflare-tunnel provider first."; return 0; }
    [ -n "${OPT_TUNNEL_ID}" ] || { ui_msg "Create DNS" "Set the CF tunnel UUID in Inputs first (the CNAME target is <uuid>.cfargotunnel.com)."; return 0; }
    local tok tf
    tok="$(ui_password "CF API token" "Cloudflare API token (scope: Zone.DNS Edit on the one zone).\nHanded over via a 0600 temp file; deleted after the run; never saved.")"
    [ -n "${tok}" ] || { ui_msg "Create DNS" "No token entered — cancelled."; return 0; }
    tf="$(umask 077 && mktemp "${STATE_DIR}/.tok.XXXXXX")" || { warn "mktemp failed"; return 1; }
    printf '%s\n' "${tok}" > "${tf}"
    tok=""
    run_engine --create-dns --cf-api-token-file "${tf}"
    rm -f "${tf}" 2>/dev/null
}

flip_screen() {
    ui_yesno "Go live" "Run the pre-flip verify + FLIP TO PUBLIC?\n\nThe engine writes /etc/snapdragon/go-live after ITS OWN typed-domain\nconfirmation in the terminal (there is no way around it — by design).\nsnapdragon-firewall-reconcile converges within 60s.\n\nRollback any time: menu → Rollback (deletes the marker)." || return 0
    local persist=""
    ui_yesno "Persist" "ALSO persist release-state=public?\n\nNo  = marker only (rollback = just delete the marker)  ← recommended\nYes = survives marker deletion; rollback then needs --persist too" \
        && persist="--persist"
    # shellcheck disable=SC2086
    run_engine --flip ${persist}
}

rollback_screen() {
    ui_yesno "Rollback" "Delete the go-live marker (device reverts to INTERNAL within 60s)?" || return 0
    local persist=""
    ui_yesno "Persist" "ALSO reset release-state=internal?\n(Needed if you flipped with 'persist' — otherwise the device stays public.)" \
        && persist="--persist"
    # shellcheck disable=SC2086
    run_engine --rollback ${persist}
}

status_text() { bash "${ENGINE}" --status 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g'; }

main_menu() {
    while true; do
        local status_line="provider=${OPT_PROVIDER:-none}  domain=${OPT_DOMAIN:-auto}"
        local choice
        choice="$(ui_menu "Main" "${status_line}\nFlow: provider → inputs → links → emit → verify → GO LIVE." \
            provider "1. Pick provider (exposure model) …" \
            inputs   "2. Inputs (domain / IPs / DDNS) …" \
            links    "3. Show provider deep links (+ open in browser)" \
            info     "   Provider info (inputs, artifacts, notes)" \
            emit     "4. Emit artifacts + store token (records/zone/checklist)" \
            createdns "   Optional: create the CF tunnel CNAMEs (thin API driver)" \
            verify   "5. Verify edge (DNS / HTTP / tunnel probes)" \
            flip     "6. GO LIVE — write the marker (typed confirm)" \
            rollback "Rollback — delete the marker (back to internal)" \
            status   "Show go-live status" \
            quit     "Quit")" || return 0
        case "${choice}" in
            provider)  provider_screen ;;
            inputs)    inputs_screen ;;
            links)     links_screen ;;
            info)      [ -n "${OPT_PROVIDER}" ] \
                           && ui_msg "Provider info" "$(bash "${ENGINE}" --provider "${OPT_PROVIDER}" --info 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')" \
                           || ui_msg "Provider info" "Pick a provider first." ;;
            emit)      emit_screen ;;
            createdns) create_dns_screen ;;
            verify)    run_engine --verify ;;
            flip)      flip_screen ;;
            rollback)  rollback_screen ;;
            status)    ui_msg "Status" "$(status_text)" ;;
            quit|"")   return 0 ;;
        esac
    done
}

# ── Entry point ─────────────────────────────────────────────────────────────────
main() {
    [ -f "${ENGINE}" ]  || die "engine not found at ${ENGINE}"
    [ -r "${CATALOG}" ] || die "provider catalog not found at ${CATALOG}"
    if [ "${HAVE_TUI}" != 1 ]; then
        warn "whiptail/TTY not available — using the plain text menu (set NO_TUI= to re-enable; install dev-libs/newt for the rich UI)."
    fi
    main_menu
    save_conf
    clear 2>/dev/null || true
}

# Run only when executed directly; `source`-ing the file (e.g. for tests) just
# loads the functions without starting the interactive menu.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
