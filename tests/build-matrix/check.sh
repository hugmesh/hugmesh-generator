#!/usr/bin/env bash
# check.sh — full-matrix verification: EVERY image option buildable in EVERY channel.
#
# Walks tests/build-matrix/matrix.tsv (the canonical (platform, role, env, board,
# flavor, desktop) cell list) and, for every row, proves all five build channels
# agree on the cell:
#
#   CLI   invoke the builder with --print-plan + the row's flags; assert exit 0
#         and PLAN_ROLE/PLAN_ENV (+ PLAN_BOARD/PLAN_FLAVOR/PLAN_DESKTOP where the
#         platform has those axes) match the row.
#   MAKE  `make -n <target> NATIVE=1 ENV=<env> ...` must resolve and its recipe
#         must invoke the right builder with the row's --role/--env/axis flags.
#   MENU  source scripts/build-menu.sh (NO_TUI, isolated SNAP_MENU_STATE), set the
#         row's OPT_*, call build_make_cmd; assert the composed make argv targets
#         the right make target with ENV= (+ FRITE_* / JETSON_BOARD for the
#         platform axes).
#   GUI   write a config JSON for the row; `python3 -m hugmesh_studio
#         --print-command` (headless, Qt-free) must emit a command containing the
#         right builder + role/axes + env.
#   JOB   extract docker/build-image.sh's resolve_build_target() (the admin
#         web-UI k8s-Job worker's HARDWARE_CLASS role whitelists) and assert the
#         row's cell resolves to the right platform/role/axes — statically;
#         docker/k8s are never invoked.
#
# Plus NEGATIVE checks: invalid roles / boards / envs, an x86-only flag on the
# rpi5 builder and bogus job-worker HARDWARE_CLASS tokens must all FAIL
# (exit != 0 / a rejected resolve).
#
# Plus GUI FLAG-THREADING probes (GUITHR — the GUI channel's MENUTHR): every
# option field threads config-JSON -> --print-command -> the REAL builder's
# --print-plan acceptance (+ PLAN_* facts), GUI GATING probes (x86-only fields
# on ARM configs must emit NOTHING; jetson encrypt/standalone must hard-fail),
# and the builder-flag COVERAGE differ (tests/build-matrix/flag-coverage.sh):
# every parsed builder flag fielded or documented, every emitted flag parsed.
#
# Everything is dry-run (--print-plan / make -n / command printing / static
# parsing) — no root, no writes outside mktemp, CI-friendly (< ~2 min).
#
#   bash tests/build-matrix/check.sh        # or: make matrix-check
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
MATRIX="${TEST_DIR}/matrix.tsv"
PYTHON="${PYTHON:-python3}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${REPO_DIR}"

# per-channel pass/fail counters
CLI_PASS=0;  CLI_FAIL=0
MAKE_PASS=0; MAKE_FAIL=0
MENU_PASS=0; MENU_FAIL=0
GUI_PASS=0;  GUI_FAIL=0
JOB_PASS=0;  JOB_FAIL=0
THR_PASS=0;  THR_FAIL=0
NEG_PASS=0;  NEG_FAIL=0
CAT_PASS=0;  CAT_FAIL=0

_fail() { # _fail CHANNEL ROW REASON [OUTPUT-FILE]
    printf 'FAIL [%s] %s — %s\n' "$1" "$2" "$3" >&2
    [ -n "${4:-}" ] && [ -s "${4:-}" ] && sed 's/^/    | /' "$4" | tail -n 6 >&2
    return 0
}

# builder script per platform
builder_for() {
    case "$1" in
        rpi5)      echo build-rpi5-stage4.sh ;;
        x86)       echo build-x86-host-stage4.sh ;;
        frite)     echo build-frite-stage4.sh ;;
        jetson)    echo build-jetson-stage4.sh ;;
        orangepi5) echo build-orangepi5-stage4.sh ;;
        orangepizero2) echo build-orangepi-zero2-stage4.sh ;;
        *)      return 1 ;;
    esac
}

# ── channel 1: CLI — builder --print-plan ───────────────────────────────────────
check_cli() { # platform role env board flavor desktop
    local platform="$1" role="$2" env="$3" board="$4" flavor="$5" desktop="$6"
    local row="cli ${platform}/${role}/${env}${board:+ board=${board}}${flavor:+ flavor=${flavor}}${desktop:+ desktop=${desktop}}"
    local builder out="${TMP_DIR}/cli.out" args=()
    builder="$(builder_for "${platform}")"
    # standalone-shaped matrix rows encode the ARM standalone-posture JOB-channel
    # HARDWARE_CLASS grammar (docker/build-image.sh's header comment): rpi5's
    # "standalone-desktop" role and frite/orangepi5/orangepizero2's "standalone"
    # flavor are JOB-channel-ONLY tokens, not real builder vocabulary (the
    # builders only ever take --role desktop / --flavor installer plus a
    # SEPARATE --standalone flag) — translate them into the REAL invocation
    # here and assert against the REAL resolved plan values, never the raw
    # HARDWARE_CLASS-shaped token (which the real builder would reject).
    local want_role="${role}" want_flavor="${flavor}" standalone_probe=false
    if [ "${platform}" = rpi5 ] && [ "${role}" = standalone-desktop ]; then
        want_role="desktop"
        standalone_probe=true
    fi
    if { [ "${platform}" = frite ] || [ "${platform}" = orangepi5 ] || [ "${platform}" = orangepizero2 ]; } \
       && [ "${flavor}" = standalone ]; then
        want_flavor="installer"
        standalone_probe=true
    fi
    case "${platform}" in
        frite)     args=(--board "${board}" --flavor "${want_flavor}" --desktop "${desktop}") ;;
        jetson)    args=(--role "${role}" --board "${board}") ;;
        rpi5)      args=(--role "${want_role}"); [ -n "${board}" ] && args+=(--board "${board}") ;;
        orangepi5) args=(--board "${board}" --flavor "${want_flavor}") ;;
        orangepizero2) args=(--flavor "${want_flavor}") ;;
        *)      args=(--role "${role}") ;;
    esac
    if ${standalone_probe}; then
        args+=(--standalone --local-user matrixprobe)
    fi
    args+=(--env "${env}" --print-plan)
    if ! "./${builder}" "${args[@]}" >"${out}" 2>&1; then
        _fail CLI "${row}" "builder exited non-zero" "${out}"; CLI_FAIL=$((CLI_FAIL+1)); return
    fi
    local miss=""
    grep -qx "PLAN_BUILDER=${builder}"  "${out}" || miss+=" PLAN_BUILDER=${builder}"
    grep -qx "PLAN_ROLE=${want_role}"   "${out}" || miss+=" PLAN_ROLE=${want_role}"
    grep -qx "PLAN_ENV=${env}"          "${out}" || miss+=" PLAN_ENV=${env}"
    if ${standalone_probe}; then
        grep -qx "PLAN_STANDALONE=true" "${out}" || miss+=" PLAN_STANDALONE=true"
    fi
    if [ "${platform}" = frite ]; then
        grep -qx "PLAN_BOARD=${board}"     "${out}" || miss+=" PLAN_BOARD=${board}"
        grep -qx "PLAN_FLAVOR=${want_flavor}"   "${out}" || miss+=" PLAN_FLAVOR=${want_flavor}"
        grep -qx "PLAN_DESKTOP=${desktop}" "${out}" || miss+=" PLAN_DESKTOP=${desktop}"
    fi
    if [ "${platform}" = jetson ]; then
        grep -qx "PLAN_BOARD=${board}" "${out}" || miss+=" PLAN_BOARD=${board}"
    fi
    if [ "${platform}" = rpi5 ] && [ -n "${board}" ]; then
        # rpi5 has NO dedicated PLAN_BOARD key (reuses PLAN_PLATFORM so the
        # DEFAULT board's --print-plan output stays byte-identical to before
        # this axis existed — see build-rpi5-stage4.sh's Phase 6 commit message).
        grep -qx "PLAN_PLATFORM=${board}" "${out}" || miss+=" PLAN_PLATFORM=${board}"
    fi
    if [ "${platform}" = orangepi5 ]; then
        grep -qx "PLAN_BOARD=${board}"   "${out}" || miss+=" PLAN_BOARD=${board}"
        grep -qx "PLAN_FLAVOR=${want_flavor}" "${out}" || miss+=" PLAN_FLAVOR=${want_flavor}"
    fi
    if [ "${platform}" = orangepizero2 ]; then
        # No PLAN_BOARD key at all — this platform has NO --board axis (a
        # single board, unlike Frite/Orange-Pi-5's board tables).
        grep -qx "PLAN_FLAVOR=${want_flavor}" "${out}" || miss+=" PLAN_FLAVOR=${want_flavor}"
    fi
    if [ -n "${miss}" ]; then
        _fail CLI "${row}" "plan keys missing/mismatched:${miss}" "${out}"; CLI_FAIL=$((CLI_FAIL+1))
    else
        CLI_PASS=$((CLI_PASS+1))
    fi
}

# ── channel 2: MAKE — target exists + threads the row's flags (make -n) ─────────
check_make() { # platform role env board flavor desktop
    local platform="$1" role="$2" env="$3" board="$4" flavor="$5" desktop="$6"
    local target builder out="${TMP_DIR}/make.out" vars=()
    builder="$(builder_for "${platform}")"
    case "${platform}" in
        rpi5)      target="rpi-${role}"; [ -n "${board}" ] && vars=("RPI_BOARD=${board}") ;;
        x86)       target="x86-${role}" ;;
        jetson)    target="jetson-${role}"; vars=("JETSON_BOARD=${board}") ;;
        frite)     target="frite"
                   vars=("FRITE_BOARD=${board}" "FRITE_FLAVOR=${flavor}" "FRITE_DESKTOP=${desktop}") ;;
        orangepi5) target="orangepi5"
                   vars=("ORANGEPI5_BOARD=${board}" "ORANGEPI5_FLAVOR=${flavor}") ;;
        orangepizero2) target="orangepizero2"
                   vars=("ORANGEPIZERO2_FLAVOR=${flavor}") ;;
    esac
    local row="make ${target} ENV=${env}${vars[0]:+ ${vars[*]}}"
    if ! make -n "${target}" NATIVE=1 "ENV=${env}" "${vars[@]}" >"${out}" 2>&1; then
        _fail MAKE "${row}" "make -n exited non-zero" "${out}"; MAKE_FAIL=$((MAKE_FAIL+1)); return
    fi
    local miss=""
    grep -q "${builder}" "${out}" || miss+=" ${builder}"
    grep -q -- "--env ${env}" "${out}" || miss+=" '--env ${env}'"
    case "${platform}" in
        frite)
            grep -q -- "--board ${board}"     "${out}" || miss+=" '--board ${board}'"
            grep -q -- "--flavor ${flavor}"   "${out}" || miss+=" '--flavor ${flavor}'"
            grep -q -- "--desktop ${desktop}" "${out}" || miss+=" '--desktop ${desktop}'"
            ;;
        jetson)
            grep -q -- "--role ${role}"   "${out}" || miss+=" '--role ${role}'"
            grep -q -- "--board ${board}" "${out}" || miss+=" '--board ${board}'"
            ;;
        orangepi5)
            grep -q -- "--board ${board}"   "${out}" || miss+=" '--board ${board}'"
            grep -q -- "--flavor ${flavor}" "${out}" || miss+=" '--flavor ${flavor}'"
            ;;
        rpi5)
            grep -q -- "--role ${role}" "${out}" || miss+=" '--role ${role}'"
            # rpi5's board rows don't all set a board (rpi5-default rows have
            # board="" -> "-" in the TSV), so only assert --board when the row
            # actually specifies one (mirrors check_cli's identical guard).
            if [ -n "${board}" ]; then
                grep -q -- "--board ${board}" "${out}" || miss+=" '--board ${board}'"
            fi
            ;;
        orangepizero2)
            grep -q -- "--flavor ${flavor}" "${out}" || miss+=" '--flavor ${flavor}'"
            ;;
        *)
            grep -q -- "--role ${role}" "${out}" || miss+=" '--role ${role}'"
            ;;
    esac
    if [ -n "${miss}" ]; then
        _fail MAKE "${row}" "recipe missing:${miss}" "${out}"; MAKE_FAIL=$((MAKE_FAIL+1))
    else
        MAKE_PASS=$((MAKE_PASS+1))
    fi
}

# ── channel 3: MENU — build_make_cmd composes the right make argv ───────────────
# One child bash sources scripts/build-menu.sh ONCE (its execute-guard keeps it
# non-interactive when sourced) and walks every matrix row, so the whole channel
# costs a single fork. Emits one "MENU PASS|FAIL <row> [reason]" line per row.
run_menu_channel() {
    local out="${TMP_DIR}/menu.out"
    MATRIX="${MATRIX}" REPO_DIR="${REPO_DIR}" bash <<'MENU_EOF' >"${out}" 2>"${TMP_DIR}/menu.err"
set -u
export NO_TUI=1
SNAP_MENU_STATE="$(mktemp -d)"; export SNAP_MENU_STATE
trap 'rm -rf "${SNAP_MENU_STATE}"' EXIT
# shellcheck disable=SC1091
source "${REPO_DIR}/scripts/build-menu.sh"

# i0 — THE MENU'S PRISTINE DEFAULT. This is the ONLY point where build-menu.sh's own
# top-level OPT_INSTALLER_UI default is observable: reset_opts (below) HARDCODES
# OPT_INSTALLER_UI="", which MASKS it, so every probe that calls reset_opts first —
# including i1 — tests the emit condition against a value the harness supplied rather
# than the one the script ships. Review mutation-proved the gap: setting build-menu.sh's
# default to "all" (precisely the flat-default regression i1 claims to prevent) left
# check.sh at TOTAL 774 passed / 0 failed. i1 pins the EMIT CONDITION; this pins the
# DEFAULT. Both are needed — a flat default is the regression that actually hurts,
# because it is what the GUI channel's own bug looked like (config.py's
# `installer_ui: str = "all"`, #384).
case "${OPT_INSTALLER_UI}" in
    "") echo "MENUTHR PASS build-menu.sh (i0 installer-ui default is empty = defer to builder)" ;;
    *)  echo "MENUTHR FAIL build-menu.sh — i0: build-menu.sh's top-level OPT_INSTALLER_UI default is '${OPT_INSTALLER_UI}', not empty. A flat default kills build-x86-host-stage4.sh's `[ -z \"\${INSTALLER_UI}\" ]` sentinel for EVERY target, so headless nodes get an ISO installer stack. Empty = defer to the builder's role-aware fork." ;;
esac

# baseline: every option build_make_cmd reads, at the script's own defaults.
# NOTE: this deliberately RESTATES OPT_INSTALLER_UI="" so probes are hermetic — which is
# exactly why i0 above must run BEFORE the first reset_opts call.
reset_opts() {
    OPT_WORK_DIR=/tmp/matrix-menu-out OPT_JOBS=4 OPT_ENV=test OPT_PATH=docker
    OPT_BRAND="" OPT_DOMAIN="" OPT_RESUME=no OPT_OMNIBUS=no OPT_PENTEST=no
    OPT_FRITE_FLEET=no OPT_JETSON_FLEET=no
    OPT_IMGFLAGS="" OPT_X86_EDGE_AI=no OPT_EDGE_AI_RUNTIME=ollama
    OPT_EDGE_AI_MODELS="" OPT_EDGE_AI_MODEL_DEFAULT="" OPT_X86_EDGE_AI_ANALYSIS=no
    OPT_TOR_ONION=no OPT_CHARACTER_STUDIO=no OPT_SERVICES="" OPT_INSTALLER_UI=""
    OPT_EXTRA_FLAGS=""
    OPT_BR_WALLPAPER="" OPT_BR_GRUB_BG="" OPT_BR_LOGIN_BG="" OPT_BR_LOGO=""
    OPT_BR_ACCENT="" OPT_BR_SCHEME=""
    OPT_HOME_MODE="" OPT_HOME_DEVICE="" OPT_HOME_BACKUP="" OPT_HOME_ENCRYPTED=no
    OPT_HOME_SEED="" OPT_HOME_ARCHIVE=""
    OPT_FRITE_BOARD=la-frite OPT_FRITE_FLAVOR=both OPT_FRITE_DESKTOP=light
    OPT_JETSON_BOARD=orin-nano OPT_JETSON_KFLAVOR=mainline
    OPT_ORANGEPI5_BOARD=orange-pi-5-plus OPT_ORANGEPI5_FLAVOR=both OPT_ORANGEPI5_FLEET=no
    OPT_ORANGEPIZERO2_FLAVOR=both
    OPT_SA_GPU=all-free OPT_SA_STEAM=native OPT_SA_MEDIA=yes OPT_SA_USER=snap
    OPT_SA_KEYFILE=none OPT_SA_YUBIKEY=none OPT_SA_THEME="" OPT_SA_PROXY=yes
    OPT_SA_SNORT=yes OPT_SA_AIDE=no OPT_SA_KBUILTIN=no OPT_SA_EGRESS=""
    OPT_SA_MEDIA_LABEL="" OPT_ROOT_LOGIN=no SA_LOCAL_PASS="" SA_LUKS_PASS=""
}

has_elem() { local e; for e in "${RUN_MAKE[@]}"; do [ "${e}" = "$1" ] && return 0; done; return 1; }

while IFS=$'\t' read -r platform role env board flavor desktop; do
    case "${platform}" in \#*|"") continue ;; esac
    reset_opts
    OPT_ENV="${env}"
    case "${platform}" in
        rpi5)   target="rpi-${role}"
                # board="" (the rpi5-default rows) must resolve to the menu's
                # own default ("rpi5"), same as an operator who never opened
                # the Pi-board picker at all — mirrors OPT_RPI_BOARD's own
                # top-level default in build-menu.sh.
                OPT_RPI_BOARD="${board:-rpi5}" ;;
        x86)    target="x86-${role}" ;;
        jetson) target="jetson-${role}"
                OPT_JETSON_BOARD="${board}" ;;
        frite)  target="frite"
                OPT_FRITE_BOARD="${board}" OPT_FRITE_FLAVOR="${flavor}" OPT_FRITE_DESKTOP="${desktop}" ;;
        orangepi5) target="orangepi5"
                OPT_ORANGEPI5_BOARD="${board}" OPT_ORANGEPI5_FLAVOR="${flavor}" ;;
        orangepizero2) target="orangepizero2"
                OPT_ORANGEPIZERO2_FLAVOR="${flavor}" ;;
        *)      echo "MENU FAIL ${platform}/${role}/${env} unknown platform"; continue ;;
    esac
    row="${target} ENV=${env}"
    build_make_cmd "${target}" "matrix ${row}" 1
    miss=""
    [ "${RUN_MAKE[0]}" = "${target}" ] || miss+=" target(got ${RUN_MAKE[0]})"
    has_elem "ENV=${env}" || miss+=" ENV=${env}"
    if [ "${platform}" = rpi5 ]; then
        # RPI_BOARD is ALWAYS emitted for rpi/rpi-% targets (unlike the CLI
        # channel's --board flag, which is only emitted for a non-default
        # board) — see build-menu.sh's build_make_cmd.
        has_elem "RPI_BOARD=${OPT_RPI_BOARD}" || miss+=" RPI_BOARD=${OPT_RPI_BOARD}"
    fi
    if [ "${platform}" = frite ]; then
        has_elem "FRITE_BOARD=${board}"     || miss+=" FRITE_BOARD=${board}"
        has_elem "FRITE_FLAVOR=${flavor}"   || miss+=" FRITE_FLAVOR=${flavor}"
        has_elem "FRITE_DESKTOP=${desktop}" || miss+=" FRITE_DESKTOP=${desktop}"
    fi
    if [ "${platform}" = jetson ]; then
        has_elem "JETSON_BOARD=${board}" || miss+=" JETSON_BOARD=${board}"
    fi
    if [ "${platform}" = orangepi5 ]; then
        has_elem "ORANGEPI5_BOARD=${board}"   || miss+=" ORANGEPI5_BOARD=${board}"
        has_elem "ORANGEPI5_FLAVOR=${flavor}" || miss+=" ORANGEPI5_FLAVOR=${flavor}"
    fi
    if [ "${platform}" = orangepizero2 ]; then
        has_elem "ORANGEPIZERO2_FLAVOR=${flavor}" || miss+=" ORANGEPIZERO2_FLAVOR=${flavor}"
    fi
    if [ -n "${miss}" ]; then
        echo "MENU FAIL ${row} — missing:${miss} (argv: ${RUN_MAKE[*]})"
    else
        echo "MENU PASS ${row}"
    fi
done < "${MATRIX}"

# ── MENU→MAKE flag-threading probes (end-to-end) ────────────────────────────
# The 'Image flags' (OPT_IMGFLAGS) and 'Extra builder flags' (OPT_EXTRA_FLAGS)
# knobs are offered for EVERY target, so both probe tokens must survive the
# whole menu channel — build_make_cmd AND the make recipe it composes — and
# land in the builder argv on every platform. Catches the silent-drop class
# where the menu emits a make-var (IMG_FLAGS= / STANDALONE_FLAGS=) that the
# target's recipe never consumes (the jetson/frite re-verify findings).
for target in rpi-backend x86-pki frite jetson-edge_ai orangepi5 orangepizero2; do
    reset_opts
    OPT_IMGFLAGS='--menu-imgflags-probe'
    OPT_EXTRA_FLAGS='--menu-extraflags-probe'
    build_make_cmd "${target}" "thread-probe ${target}" 1
    recipe="$(make -n "${RUN_MAKE[@]}" NATIVE=1 2>&1)" || {
        echo "MENUTHR FAIL ${target} — make -n exited non-zero"; continue; }
    miss=""
    case "${recipe}" in *--menu-imgflags-probe*)    ;; *) miss+=" OPT_IMGFLAGS" ;; esac
    case "${recipe}" in *--menu-extraflags-probe*)  ;; *) miss+=" OPT_EXTRA_FLAGS" ;; esac
    if [ -n "${miss}" ]; then
        echo "MENUTHR FAIL ${target} — dropped:${miss} (argv: ${RUN_MAKE[*]})"
    else
        echo "MENUTHR PASS ${target}"
    fi
done

# ── MENU role-class parity: the ncurses channel's OWN installer-ui contract ─────
# The menu composes its flag string by hand and NEVER imports studio's config.py,
# so a validation layer added in python CANNOT reach this channel. Its contract is
# therefore pinned here, on its own terms.
#
# i1 — DEFER ON NODES. At the menu's default (OPT_INSTALLER_UI=""), no --installer-ui
# may be emitted for a node target: silence is what lets build-x86-host-stage4.sh's
# own `[ -z "${INSTALLER_UI}" ] && { ${STANDALONE} && INSTALLER_UI=all || INSTALLER_UI=cli; }`
# sentinel resolve the role-correct value. Emitting ANY constant here would kill that
# fork and bake an ISO installer stack into a headless node (~16 min/image of Qt).
# This is the guard that stops a future "make the menu match the GUI" edit from
# importing the GUI's flat-default bug into the one channel that never had it.
# i2 — HONOUR ON DESKTOPS. An explicit value must still thread through, or the fix
# would have silently broken the knob instead.
for target in x86-pki x86-be x86-fe x86-omnibus; do
    reset_opts
    build_make_cmd "${target}" "installer-ui default ${target}" 1
    case "${RUN_MAKE[*]}" in
        *--installer-ui*) echo "MENUTHR FAIL ${target} — i1: emitted --installer-ui at the menu default; the builder's role-aware sentinel is now dead code and this node gets an ISO installer stack (argv: ${RUN_MAKE[*]})" ;;
        *)                echo "MENUTHR PASS ${target} (i1 installer-ui defers to builder)" ;;
    esac
done
reset_opts
OPT_INSTALLER_UI=calamares
build_make_cmd x86-standalone-thick "installer-ui explicit desktop" 1
case "${RUN_MAKE[*]}" in
    *"--installer-ui calamares"*) echo "MENUTHR PASS x86-standalone-thick (i2 explicit installer-ui honoured)" ;;
    *) echo "MENUTHR FAIL x86-standalone-thick — i2: explicit --installer-ui calamares dropped (argv: ${RUN_MAKE[*]})" ;;
esac

# ── fleet-option threading: RESUME/PENTEST/OMNIBUS/FRITE_FLEET/JETSON_FLEET ──
# must gate to BOTH whole-fleet targets, build-all and build-everything — the
# exact class of gap the '★ FULL matrix' menu entry introduced (a new fleet
# target added without extending build_make_cmd's target==build-all gate, so
# Resume-sysroots/pentest/fleet toggles silently vanished for build-everything
# only). `make -n ... NATIVE=1` mirrors the MENUTHR probes above: forces the
# native branch so the composed make-vars are visible verbatim in the printed
# recipe rather than swallowed by the docker re-invocation branch.
for target in build-all build-everything; do
    reset_opts
    OPT_RESUME=yes OPT_OMNIBUS=yes OPT_FRITE_FLEET=yes OPT_JETSON_FLEET=yes OPT_PENTEST=yes
    build_make_cmd "${target}" "fleet-thread-probe ${target}" 1
    recipe="$(make -n "${RUN_MAKE[@]}" NATIVE=1 2>&1)" || {
        echo "FLEETTHR FAIL ${target} — make -n exited non-zero"; continue; }
    miss=""
    case "${recipe}" in *--resume*)       ;; *) miss+=" RESUME" ;; esac
    case "${recipe}" in *"X86_OMNIBUS='1'"*) ;; *) miss+=" X86_OMNIBUS" ;; esac
    case "${recipe}" in *"FRITE='1'"*)    ;; *) miss+=" FRITE" ;; esac
    case "${recipe}" in *"JETSON='1'"*)   ;; *) miss+=" JETSON" ;; esac
    case "${recipe}" in *"PENTEST='1'"*)  ;; *) miss+=" PENTEST" ;; esac
    if [ -n "${miss}" ]; then
        echo "FLEETTHR FAIL ${target} — dropped:${miss} (argv: ${RUN_MAKE[*]})"
    else
        echo "FLEETTHR PASS ${target}"
    fi
done

# ── ROLESET_ENVVARS docker-boundary threading: RPI_BOARD/RPI_ROLES/SKIP_RPI/ ──
# ORANGEPIZERO2* — a real bug: these are set on the Makefile command line
# directly (RPI_BOARD/RPI_ROLES/SKIP_RPI have no menu widget for the fleet
# targets at all, unlike the single-role rpi-%/rpi targets — so the FLEETTHR
# probe above, which drives build_make_cmd(), can never exercise them), NOT
# routed through build_make_cmd()/the menu, so this probes `make -n` directly
# instead. A prior version of ROLESET_ENVVARS omitted all four (plus
# ORANGEPIZERO2/ORANGEPIZERO2_FLAVOR, which build-everything's OWN recipe DOES
# set unconditionally but which then still vanished at this exact boundary),
# so `make build-everything RPI_BOARD=rpi4 RPI_ROLES="..."` silently built the
# default rpi5/pki+backend+frontend set and dropped Orange Pi Zero 2 no matter
# what was requested — on BOTH the native leg ($(ALL) invoking
# build-all-roles.sh directly) and the Docker leg (the in-container `make`
# re-invoke), since only tokens literally baked into ROLESET_ENVVARS survive
# either boundary.
rolesetthr_recipe="$(make -n build-everything RPI_BOARD=rpi4 RPI_ROLES="pki backend frontend desktop" SKIP_RPI=0 2>&1)" || {
    echo "ROLESETTHR FAIL build-everything — make -n exited non-zero"
}
if [ -n "${rolesetthr_recipe:-}" ]; then
    miss=""
    case "${rolesetthr_recipe}" in *"RPI_BOARD='rpi4'"*) ;; *) miss+=" RPI_BOARD" ;; esac
    case "${rolesetthr_recipe}" in *"RPI_ROLES='pki backend frontend desktop'"*) ;; *) miss+=" RPI_ROLES" ;; esac
    case "${rolesetthr_recipe}" in *"ORANGEPIZERO2='1'"*) ;; *) miss+=" ORANGEPIZERO2" ;; esac
    case "${rolesetthr_recipe}" in *"ORANGEPIZERO2_FLAVOR="*) ;; *) miss+=" ORANGEPIZERO2_FLAVOR" ;; esac
    if [ -n "${miss}" ]; then
        echo "ROLESETTHR FAIL build-everything — dropped at the docker-run boundary:${miss}"
    else
        echo "ROLESETTHR PASS build-everything"
    fi
fi

# ── UNAFFILIATED MENU→MAKE threading probe ───────────────────────────────────
# The unaffiliated desktop must thread --role standalone-unaffiliated into the
# recipe and must NOT emit --theme even with the menu's persisted 'boogiepop'
# theme default in place (any branding flag is a builder HARD conflict there —
# the role presets the neutral identity itself).
reset_opts
OPT_SA_THEME=boogiepop   # the default a branded standalone run leaves persisted
build_make_cmd x86-standalone-unaffiliated "unaff-thread-probe" 1
if recipe="$(make -n "${RUN_MAKE[@]}" NATIVE=1 2>&1)"; then
    miss=""
    case "${recipe}" in *"--role standalone-unaffiliated"*) ;; *) miss+=" '--role standalone-unaffiliated'" ;; esac
    case "${recipe}" in *"--theme"*) miss+=" '--theme LEAKED'" ;; esac
    if [ -n "${miss}" ]; then
        echo "UNAFFTHR FAIL x86-standalone-unaffiliated —${miss} (argv: ${RUN_MAKE[*]})"
    else
        echo "UNAFFTHR PASS x86-standalone-unaffiliated"
    fi
else
    echo "UNAFFTHR FAIL x86-standalone-unaffiliated — make -n exited non-zero"
fi
MENU_EOF
    local rc=$?
    MENU_PASS=$(grep -c '^MENU PASS' "${out}" || true)
    MENU_FAIL=$(grep -c '^MENU FAIL' "${out}" || true)
    # the child's MENU→MAKE threading probes count toward the THRD bucket;
    # FAIL-CLOSED like everything else: 12 probes expected, shortfall = failures.
    #   6 IMGFLAGS/EXTRA_FLAGS threading (rpi-backend, x86-pki, frite, jetson-edge_ai,
    #     orangepi5, orangepizero2)
    # + 1 installer-ui menu DEFAULT i0 (build-menu.sh's pristine OPT_INSTALLER_UI)
    # + 4 installer-ui role-class parity i1 (x86-pki, x86-be, x86-fe, x86-omnibus)
    # + 1 installer-ui parity i2 (x86-standalone-thick)
    # Keep this count in sync with those probe lists' lengths. It is fail-closed for a
    # reason: a probe that stops EMITTING (renamed target, early `continue`) would
    # otherwise vanish silently and take its coverage with it.
    local mthr_pass
    mthr_pass=$(grep -c '^MENUTHR PASS' "${out}" || true)
    THR_PASS=$((THR_PASS + mthr_pass))
    THR_FAIL=$((THR_FAIL + 12 - mthr_pass))
    # same fail-closed accounting for the fleet-option (build-all/build-everything)
    # threading probes: 2 expected (one per fleet target).
    local fthr_pass
    fthr_pass=$(grep -c '^FLEETTHR PASS' "${out}" || true)
    THR_PASS=$((THR_PASS + fthr_pass))
    THR_FAIL=$((THR_FAIL + 2 - fthr_pass))
    # and for the unaffiliated-desktop threading probe: 1 expected.
    local uthr_pass
    uthr_pass=$(grep -c '^UNAFFTHR PASS' "${out}" || true)
    THR_PASS=$((THR_PASS + uthr_pass))
    THR_FAIL=$((THR_FAIL + 1 - uthr_pass))
    # and for the ROLESET_ENVVARS docker-boundary probe (RPI_BOARD/RPI_ROLES/
    # ORANGEPIZERO2*): 1 expected.
    local rthr_pass
    rthr_pass=$(grep -c '^ROLESETTHR PASS' "${out}" || true)
    THR_PASS=$((THR_PASS + rthr_pass))
    THR_FAIL=$((THR_FAIL + 1 - rthr_pass))
    # FAIL-CLOSED: a crashed/aborted menu child (source error, set -u trip, …)
    # must count as a channel failure, not as "0 rows = 0 failures" — otherwise
    # the 5-channels-per-cell guarantee silently degrades to 4 (the completeness
    # gate below backstops this too).
    if [ ${rc} -ne 0 ]; then
        _fail MENU "channel" "menu child exited ${rc}" "${TMP_DIR}/menu.err"
        MENU_FAIL=$((MENU_FAIL+1))
    fi
    grep -E '^(MENU|MENUTHR|FLEETTHR|UNAFFTHR|ROLESETTHR) FAIL' "${out}" >&2 || true
}

# ── channel 4: GUI — hugmesh_studio --print-command (headless, Qt-free) ──────
# Studio ids differ from the builder spellings in two places: rpi5 spells the
# node roles out (be/fe <-> backend/frontend) and the jetson desktop role id is
# disambiguated (jetson-desktop -> --role desktop). Exercise the Studio ids.
gui_config_json() { # platform role env board flavor desktop -> stdout JSON
    local platform="$1" role="$2" env="$3" board="$4" flavor="$5" desktop="$6"
    local mode gui_role="${role}" gui_flavor="${flavor}" standalone=false
    # JOB-grammar standalone tokens -> REAL ImageConfig standalone semantics
    # (mirrors check_cli's translation): rpi5's "standalone-desktop" role and
    # frite/orangepi5/orangepizero2's "standalone" flavor are HARDWARE_CLASS
    # spellings the builders reject outright, so a config JSON carrying them raw
    # would only prove token-echoing. The real Studio posture is role=desktop /
    # flavor=installer plus the standalone field (the HomePage checkbox ->
    # --standalone); check_gui additionally proves the resulting command against
    # the builder's own --print-plan for these rows.
    if [ "${platform}" = rpi5 ] && [ "${role}" = standalone-desktop ]; then
        gui_role=desktop; standalone=true
    fi
    if { [ "${platform}" = frite ] || [ "${platform}" = orangepi5 ] || [ "${platform}" = orangepizero2 ]; } \
       && [ "${flavor}" = standalone ]; then
        gui_flavor=installer; standalone=true
    fi
    case "${platform}" in
        rpi5)   mode=mesh
                case "${role}" in backend) gui_role=be ;; frontend) gui_role=fe ;; esac ;;
        frite)  mode=cloud; gui_role=frite ;;
        jetson) mode=mesh
                [ "${role}" = desktop ] && gui_role=jetson-desktop ;;
        orangepi5) mode=cloud; gui_role=orangepi5 ;;
        orangepizero2) mode=cloud; gui_role=orangepizero2 ;;
        x86)    case "${role}" in
                    standalone-*)             mode=standalone ;;
                    laptop|chromebook|desktop) mode=cloud ;;
                    *)                         mode=mesh ;;
                esac ;;
    esac
    # a standalone-posture row is standalone MODE in the Studio (the wizard skips
    # the keyzip/domains/users pages for it), whatever the platform
    ${standalone} && mode=standalone
    printf '{"platform":"%s","role":"%s","mode":"%s","env":"%s"' \
        "${platform}" "${gui_role}" "${mode}" "${env}"
    ${standalone} && printf ',"standalone":true'
    if [ "${platform}" = frite ]; then
        printf ',"board":"%s","flavor":"%s","desktop":"%s"' "${board}" "${gui_flavor}" "${desktop}"
    elif [ "${platform}" = jetson ]; then
        # the jetson board axis (the GUI's Jetson board combo writes the same key)
        printf ',"board":"%s"' "${board}"
    elif [ "${platform}" = orangepi5 ]; then
        printf ',"board":"%s","flavor":"%s"' "${board}" "${gui_flavor}"
    elif [ "${platform}" = rpi5 ] && [ -n "${board}" ]; then
        # the rpi5 board axis (--board rpi4/rpi3; the rpi5-default rows have
        # board="" and correctly emit NO "board" key at all, same as an
        # operator who never touched the board field — ImageConfig.board
        # defaults to "" -> no --board flag, the builder's own rpi5 default).
        printf ',"board":"%s"' "${board}"
    elif [ "${platform}" = orangepizero2 ]; then
        printf ',"flavor":"%s"' "${gui_flavor}"
    fi
    printf '}\n'
}

# Re-run a printed `--print-command` native command against the REAL builder with
# --print-plan appended (drop the sudo prefix — planning needs no root). Proves
# the whole emitted argv is builder-ACCEPTED, not merely token-present.
gui_plan_from_command() { # printed-command-file plan-out-file
    local cmdline
    cmdline="$(head -n 1 "$1")"
    cmdline="${cmdline#sudo }"
    bash -c "cd '${REPO_DIR}' && ${cmdline} --print-plan" >"$2" 2>&1
}

check_gui() { # platform role env board flavor desktop
    local platform="$1" role="$2" env="$3" board="$4" flavor="$5" desktop="$6"
    local row="gui ${platform}/${role}/${env}${board:+ board=${board}}${flavor:+ flavor=${flavor}}${desktop:+ desktop=${desktop}}"
    local builder out="${TMP_DIR}/gui.out" cfg="${TMP_DIR}/gui.json" plan="${TMP_DIR}/gui.plan"
    builder="$(builder_for "${platform}")"
    # standalone-shaped rows assert the TRANSLATED (real-builder) vocabulary,
    # exactly like check_cli's want_role/want_flavor — never the raw JOB token.
    local want_role="${role}" want_flavor="${flavor}" standalone_probe=false
    if [ "${platform}" = rpi5 ] && [ "${role}" = standalone-desktop ]; then
        want_role="desktop"
        standalone_probe=true
    fi
    if { [ "${platform}" = frite ] || [ "${platform}" = orangepi5 ] || [ "${platform}" = orangepizero2 ]; } \
       && [ "${flavor}" = standalone ]; then
        want_flavor="installer"
        standalone_probe=true
    fi
    gui_config_json "${platform}" "${role}" "${env}" "${board}" "${flavor}" "${desktop}" >"${cfg}"
    # STDOUT ONLY into "${out}" — it is the ARGV channel: the token greps below read it and
    # gui_plan_from_command re-runs its FIRST LINE as a real command. Merging stderr (2>&1)
    # let any warning the Studio legitimately writes to stderr land ahead of the argv
    # (stderr is unbuffered; a redirected stdout is block-buffered) and be executed as the
    # command. Diagnostics are preserved: stderr is appended to the tail only on failure.
    if ! (cd studio && "${PYTHON}" -m hugmesh_studio --print-command \
            --config "${cfg}" --backend native --generator-dir "${REPO_DIR}") \
            >"${out}" 2>"${out}.err"; then
        cat "${out}.err" >>"${out}"
        _fail GUI "${row}" "--print-command exited non-zero" "${out}"; GUI_FAIL=$((GUI_FAIL+1)); return
    fi
    local miss=""
    grep -q "${builder}" "${out}" || miss+=" ${builder}"
    grep -q -- "--env ${env}" "${out}" || miss+=" '--env ${env}'"
    if [ "${platform}" = frite ]; then
        grep -q -- "--board ${board}"     "${out}" || miss+=" '--board ${board}'"
        grep -q -- "--flavor ${want_flavor}" "${out}" || miss+=" '--flavor ${want_flavor}'"
        grep -q -- "--desktop ${desktop}" "${out}" || miss+=" '--desktop ${desktop}'"
    elif [ "${platform}" = orangepi5 ]; then
        grep -q -- "--board ${board}"   "${out}" || miss+=" '--board ${board}'"
        grep -q -- "--flavor ${want_flavor}" "${out}" || miss+=" '--flavor ${want_flavor}'"
    elif [ "${platform}" = orangepizero2 ]; then
        grep -q -- "--flavor ${want_flavor}" "${out}" || miss+=" '--flavor ${want_flavor}'"
    else
        grep -q -- "--role ${want_role}" "${out}" || miss+=" '--role ${want_role}'"
        if [ "${platform}" = jetson ]; then
            grep -q -- "--board ${board}" "${out}" || miss+=" '--board ${board}'"
        fi
        if [ "${platform}" = rpi5 ] && [ -n "${board}" ]; then
            grep -q -- "--board ${board}" "${out}" || miss+=" '--board ${board}'"
        fi
    fi
    if ${standalone_probe}; then
        # the 8 JOB-grammar standalone rows used to pass VACUOUSLY here (raw
        # tokens echoed, builder-rejected argv — live-proven): now require the
        # real --standalone flag AND full builder --print-plan acceptance.
        grep -q -- "--standalone" "${out}" || miss+=" '--standalone'"
        if [ -z "${miss}" ]; then
            if ! gui_plan_from_command "${out}" "${plan}"; then
                miss+=" builder-rejected-argv(--print-plan rc!=0)"
            else
                grep -qx "PLAN_STANDALONE=true" "${plan}" || miss+=" PLAN_STANDALONE=true"
            fi
        fi
    fi
    if [ -n "${miss}" ]; then
        _fail GUI "${row}" "command missing:${miss}" "${out}"; GUI_FAIL=$((GUI_FAIL+1))
    else
        GUI_PASS=$((GUI_PASS+1))
    fi
}

# ── channel 5: JOB — docker/build-image.sh (the admin web-UI k8s-Job worker) ────
# The image-gen Job maps IMAGE_TYPE + HARDWARE_CLASS onto a generator build
# target through resolve_build_target()'s hand-maintained role whitelists (the
# HARDWARE_CLASS convention in docker/build-image.sh's header) — the one build
# channel matrix.tsv did not hold to account, so those case statements could
# silently drift from the matrix. Extract the REAL function (sed — fully
# static, docker/k8s are never invoked) and drive it in one isolated child,
# one probe per matrix row plus bogus-token negatives, emitting
# "JOB PASS|FAIL <row>" / "JOBNEG PASS|FAIL <name>" lines like the menu child.
run_job_channel() {
    local out="${TMP_DIR}/job.out" fn="${TMP_DIR}/job.fn"
    sed -n '/^resolve_build_target() {$/,/^}$/p' docker/build-image.sh >"${fn}"
    # DRIFT ASSERT (fail-loud): the extraction leans on the function's exact
    # name and brace style, and the probes on its output variables. If
    # docker/build-image.sh is refactored so any of that moves, this must
    # ERROR — never skip silently ("0 rows probed" would otherwise read as
    # "0 failures"; the completeness gate below backstops this too).
    if [ "$(tail -n 1 "${fn}" 2>/dev/null)" != "}" ] \
       || ! grep -q 'HARDWARE_CLASS' "${fn}" || ! grep -q 'PLATFORM=' "${fn}"; then
        _fail JOB "channel" "cannot extract resolve_build_target() from docker/build-image.sh — the whitelist format drifted; update this probe" "${fn}"
        JOB_FAIL=$((JOB_FAIL+1))
        NEG_FAIL=$((NEG_FAIL+5))   # the 5 JOBNEG probes below never ran
        return
    fi
    MATRIX="${MATRIX}" FN="${fn}" bash <<'JOB_EOF' >"${out}" 2>"${TMP_DIR}/job.err"
set -u
# the extracted-verbatim resolve_build_target() + every variable it reads or
# writes (mirrors build-image.sh's own top-level initialisation)
HARDWARE_CLASS="" IMAGE_TYPE=""
PLATFORM="" BUILD_ROLE="" RPI5_BOARD_OUT="" RPI5_STANDALONE=false \
    FRITE_BOARD_OUT="" FRITE_FLAVOR_OUT="" FRITE_STANDALONE=false \
JETSON_BOARD_OUT="" ORANGEPI5_BOARD_OUT="" ORANGEPI5_FLAVOR_OUT="" ORANGEPI5_STANDALONE=false \
    ORANGEPIZERO2_FLAVOR_OUT="" ORANGEPIZERO2_STANDALONE=false KEYS_ROLE=""
# shellcheck disable=SC1090
source "${FN}"

# resolve HW TYPE — reset the output vars, then run the REAL worker function
resolve() {
    HARDWARE_CLASS="$1" IMAGE_TYPE="$2"
    PLATFORM="" BUILD_ROLE="" RPI5_BOARD_OUT="" RPI5_STANDALONE=false \
        FRITE_BOARD_OUT="" FRITE_FLAVOR_OUT="" FRITE_STANDALONE=false \
    JETSON_BOARD_OUT="" ORANGEPI5_BOARD_OUT="" ORANGEPI5_FLAVOR_OUT="" ORANGEPI5_STANDALONE=false \
        ORANGEPIZERO2_FLAVOR_OUT="" ORANGEPIZERO2_STANDALONE=false KEYS_ROLE=""
    resolve_build_target
}

# DRIFT CANARY (fail-loud): a known-good cell must resolve to the expected
# outputs BEFORE the walk is trusted. If build-image.sh renames the function's
# output variables (PLATFORM/BUILD_ROLE/…), every row assertion below would
# compare empty strings and pass vacuously — this canary trips first instead.
if ! resolve x86.be-gpu primary \
   || [ "${PLATFORM}" != x86 ] || [ "${BUILD_ROLE}" != "be+gpu" ]; then
    echo "JOBDRIFT FAIL canary x86.be-gpu/primary — got PLATFORM='${PLATFORM}' BUILD_ROLE='${BUILD_ROLE}'; resolve_build_target's outputs drifted — update this probe"
    exit 3
fi

while IFS=$'\t' read -r platform role env board flavor desktop; do
    case "${platform}" in \#*|"") continue ;; esac
    [ "${board}" = "-" ]   && board=""
    [ "${flavor}" = "-" ]  && flavor=""
    [ "${desktop}" = "-" ] && desktop=""
    row="${platform}/${role}/${env}${board:+ board=${board}}${flavor:+ flavor=${flavor}}${desktop:+ desktop=${desktop}}"
    # Map the row onto the worker's HARDWARE_CLASS convention (build-image.sh
    # header): dot-delimited, "+" spelled "-" (the charset has no "+"), client
    # roles ride IMAGE_TYPE=client, node roles IMAGE_TYPE=primary. This
    # channel has NO env axis (the Job contract carries no hardening-tier
    # field — every Job build gets the fail-secure prod posture) and no frite
    # desktop axis (the worker builds the builder default), so test/prod (and
    # light/none) rows deliberately probe the same whitelist cell.
    case "${platform}" in
        rpi5)   hw="rpi5.${role}${board:+.${board}}"; type=primary ;;
        x86)    hw="x86.${role/+/-}"
                case "${role}" in
                    laptop|chromebook|desktop|standalone-*) type=client ;;
                    *)                                      type=primary ;;
                esac ;;
        frite)  hw="frite.${board}.${flavor}"; type=client ;;
        jetson) hw="jetson.${role}.${board}"; type=primary ;;
        orangepi5)     hw="orangepi5.${board}.${flavor}"; type=client ;;
        orangepizero2) hw="orangepizero2.${flavor}"; type=client ;;
        *)      echo "JOB FAIL ${row} — unknown platform"; continue ;;
    esac
    if { [ "${platform}" = frite ] || [ "${platform}" = orangepi5 ] || [ "${platform}" = orangepizero2 ]; } \
       && [ "${flavor}" = both ]; then
        # flavor=both builds TWO artifacts; the worker's single-imageRef
        # ingest contract deliberately REJECTS it (build-image.sh's frite
        # convention note, mirrored by orangepi5/orangepizero2). The
        # documented behavior for this cell is a clean refusal — assert
        # exactly that, never acceptance.
        if resolve "${hw}" "${type}"; then
            echo "JOB FAIL ${row} — flavor=both must be rejected (single-imageRef ingest contract), got acceptance"
        else
            echo "JOB PASS ${row} (documented flavor=both rejection)"
        fi
        continue
    fi
    if ! resolve "${hw}" "${type}"; then
        echo "JOB FAIL ${row} — HARDWARE_CLASS=${hw} IMAGE_TYPE=${type} rejected (whitelist drifted from matrix.tsv?)"
        continue
    fi
    # standalone-shaped rows (rpi5's "standalone-desktop" role / frite|
    # orangepi5|orangepizero2's "standalone" flavor) resolve to a DIFFERENT
    # real value than the row's raw token (role -> "desktop", flavor ->
    # "installer") plus a *_STANDALONE flag going true — compute the expected
    # values here instead of asserting the raw token verbatim.
    expect_role="${role}"
    expect_flavor="${flavor}"
    expect_standalone=false
    if [ "${platform}" = rpi5 ] && [ "${role}" = standalone-desktop ]; then
        expect_role="desktop"
        expect_standalone=true
    fi
    if { [ "${platform}" = frite ] || [ "${platform}" = orangepi5 ] || [ "${platform}" = orangepizero2 ]; } \
       && [ "${flavor}" = standalone ]; then
        expect_flavor="installer"
        expect_standalone=true
    fi
    miss=""
    [ "${PLATFORM}" = "${platform}" ] || miss+=" PLATFORM(got '${PLATFORM}')"
    case "${platform}" in
        rpi5)
            expect_board="${board:-rpi5}"
            [ "${BUILD_ROLE}" = "${expect_role}" ]          || miss+=" BUILD_ROLE(got '${BUILD_ROLE}')"
            [ "${RPI5_BOARD_OUT}" = "${expect_board}" ] || miss+=" RPI5_BOARD_OUT(got '${RPI5_BOARD_OUT}')"
            if ${expect_standalone}; then
                [ "${RPI5_STANDALONE}" = true ] || miss+=" RPI5_STANDALONE(got '${RPI5_STANDALONE}')"
            fi
            ;;
        frite)
            [ "${FRITE_BOARD_OUT}" = "${board}" ]   || miss+=" FRITE_BOARD_OUT(got '${FRITE_BOARD_OUT}')"
            [ "${FRITE_FLAVOR_OUT}" = "${expect_flavor}" ] || miss+=" FRITE_FLAVOR_OUT(got '${FRITE_FLAVOR_OUT}')"
            if ${expect_standalone}; then
                [ "${FRITE_STANDALONE}" = true ] || miss+=" FRITE_STANDALONE(got '${FRITE_STANDALONE}')"
            fi
            ;;
        jetson)
            [ "${BUILD_ROLE}" = "${expect_role}" ]        || miss+=" BUILD_ROLE(got '${BUILD_ROLE}')"
            [ "${JETSON_BOARD_OUT}" = "${board}" ] || miss+=" JETSON_BOARD_OUT(got '${JETSON_BOARD_OUT}')"
            ;;
        orangepi5)
            [ "${ORANGEPI5_BOARD_OUT}" = "${board}" ]   || miss+=" ORANGEPI5_BOARD_OUT(got '${ORANGEPI5_BOARD_OUT}')"
            [ "${ORANGEPI5_FLAVOR_OUT}" = "${expect_flavor}" ] || miss+=" ORANGEPI5_FLAVOR_OUT(got '${ORANGEPI5_FLAVOR_OUT}')"
            if ${expect_standalone}; then
                [ "${ORANGEPI5_STANDALONE}" = true ] || miss+=" ORANGEPI5_STANDALONE(got '${ORANGEPI5_STANDALONE}')"
            fi
            ;;
        orangepizero2)
            [ "${ORANGEPIZERO2_FLAVOR_OUT}" = "${expect_flavor}" ] || miss+=" ORANGEPIZERO2_FLAVOR_OUT(got '${ORANGEPIZERO2_FLAVOR_OUT}')"
            if ${expect_standalone}; then
                [ "${ORANGEPIZERO2_STANDALONE}" = true ] || miss+=" ORANGEPIZERO2_STANDALONE(got '${ORANGEPIZERO2_STANDALONE}')"
            fi
            ;;
        *)
            [ "${BUILD_ROLE}" = "${expect_role}" ]        || miss+=" BUILD_ROLE(got '${BUILD_ROLE}')"
            ;;
    esac
    if [ -n "${miss}" ]; then
        echo "JOB FAIL ${row} — resolved wrong target:${miss}"
    else
        echo "JOB PASS ${row}"
    fi
done < "${MATRIX}"

# ── JOB negative probes: bogus HARDWARE_CLASS tokens must be REJECTED ────────
# (never silently defaulted to a real build target — build-image.sh's own
# "an unrecognized combination is a clean FAILED ingest" rule)
expect_reject() { # NAME HW TYPE
    if resolve "$2" "$3"; then
        echo "JOBNEG FAIL $1 — expected rejection, resolved PLATFORM='${PLATFORM}' BUILD_ROLE='${BUILD_ROLE}'"
    else
        echo "JOBNEG PASS $1"
    fi
}
expect_reject "x86: bogus role"           x86.bogus primary
expect_reject "bare legacy: bogus role"   bogus     client
expect_reject "rpi5: node role as client" rpi5.pki  client
# ARM standalone-posture grammar negatives (see docker/build-image.sh's
# "ARM STANDALONE GAP"/"JETSON STANDALONE EXCEPTION" header notes):
#  - jetson deliberately has NO standalone token at all — a jetson
#    HARDWARE_CLASS shaped like one must fall through to the same generic
#    "unsupported combination" rejection as any other bogus role, never a
#    silent accept.
#  - rpi5 is never a client-image-type platform, INCLUDING with the new
#    standalone-desktop role token (the IMAGE_TYPE=client guard at the top of
#    the rpi5 case arm runs before the role is even parsed, so this must
#    reject exactly like the existing bare rpi5.pki/client probe above).
expect_reject "jetson: standalone-shaped role rejected" jetson.standalone-desktop.orin-nano primary
expect_reject "rpi5: standalone-desktop role as client" rpi5.standalone-desktop.rpi4 client
JOB_EOF
    local rc=$?
    JOB_PASS=$(grep -c '^JOB PASS' "${out}" || true)
    JOB_FAIL=$(grep -c '^JOB FAIL' "${out}" || true)
    # the child's negative probes count toward the NEG bucket; FAIL-CLOSED like
    # the menu child's threading probes: 5 expected, shortfall = failures.
    local jneg_pass
    jneg_pass=$(grep -c '^JOBNEG PASS' "${out}" || true)
    NEG_PASS=$((NEG_PASS + jneg_pass))
    NEG_FAIL=$((NEG_FAIL + 5 - jneg_pass))
    # FAIL-CLOSED: a crashed job child (drift canary, set -u trip, …) is a
    # channel failure, never "0 rows = 0 failures" (the completeness gate
    # below backstops this too).
    if [ ${rc} -ne 0 ]; then
        _fail JOB "channel" "job child exited ${rc}" "${TMP_DIR}/job.err"
        JOB_FAIL=$((JOB_FAIL+1))
    fi
    grep -E '^(JOB|JOBNEG|JOBDRIFT) FAIL' "${out}" >&2 || true
}

# ── threading checks: STANDALONE_FLAGS + IMG_FLAGS must reach the builder argv ──
# (make -n) The menu routes every extra builder flag through STANDALONE_FLAGS on
# the x86-% / jetson / jetson-% / frite targets, and the 'Image flags' knob
# through IMG_FLAGS on ALL of them; a recipe that silently drops either voids
# that knob for the whole platform (the jetson-menu / frite re-verify audit
# findings), so prove both expansions with probe tokens. (The MENU→MAKE leg of
# the same guarantee is probed end-to-end inside run_menu_channel's child.)
run_threading_checks() {
    local t out="${TMP_DIR}/thr.out"
    for t in x86-pki x86-standalone-thin jetson jetson-edge_ai frite orangepi5 orangepizero2; do
        if make -n "${t}" NATIVE=1 STANDALONE_FLAGS='--matrix-sf-probe' >"${out}" 2>&1 \
           && grep -q -- '--matrix-sf-probe' "${out}"; then
            THR_PASS=$((THR_PASS+1))
        else
            _fail THREAD "make ${t}" "STANDALONE_FLAGS not threaded into the recipe" "${out}"
            THR_FAIL=$((THR_FAIL+1))
        fi
    done
    for t in rpi-backend x86-pki frite jetson jetson-edge_ai orangepi5 orangepizero2; do
        if make -n "${t}" NATIVE=1 IMG_FLAGS='--matrix-if-probe' >"${out}" 2>&1 \
           && grep -q -- '--matrix-if-probe' "${out}"; then
            THR_PASS=$((THR_PASS+1))
        else
            _fail THREAD "make ${t}" "IMG_FLAGS not threaded into the recipe" "${out}"
            THR_FAIL=$((THR_FAIL+1))
        fi
    done
}

# ── GUI→BUILDER flag-threading probes (GUITHR — the GUI channel's MENUTHR) ─────
# One probe = config JSON -> `--print-command --backend native` -> assert every
# expected token in the printed argv -> re-run that EXACT command against the
# REAL builder with --print-plan appended and assert acceptance (plus PLAN_*
# facts where the builder exposes one). Catches BOTH silent-drop (field never
# reaches argv) and vacuous threading (emitted flag the builder would reject) —
# the same live-proven failure class the standalone matrix rows had.
# Expectation grammar: 'token'  must appear in the printed command
#                      '!token' must NOT appear in the printed command
#                      'PLAN:pat' / 'PLAN:!pat'  must (not) match the plan output
GUITHR_EXPECTED=61   # fail-closed: keep in sync with the guithr call list below
GUITHR_EXPECTED=62   # fail-closed: keep in sync with the guithr call list below
                     # (was stale at 57 while 61 probes existed — the main merge
                     # added probes without bumping it; 62 = those 61 + sunshine)
                     # (51 + packages_add/packages_drop, WS-BUILDER emission flip;
                     # + superdomain mesh-x86/mesh-rpi5/standalone-absent, WS-SUPER-B;
                     # + chromebook standalone-desktop discoverability)
GUITHR_RUN=0

guithr() { # NAME CFG-JSON EXPECT...
    local name="$1" json="$2"; shift 2
    local cfg="${TMP_DIR}/guithr.json" out="${TMP_DIR}/guithr.out" plan="${TMP_DIR}/guithr.plan"
    GUITHR_RUN=$((GUITHR_RUN+1))
    printf '%s\n' "${json}" >"${cfg}"
    # STDOUT ONLY — see check_gui: "${out}" is the ARGV channel (the expectation greps read
    # it and gui_plan_from_command EXECUTES its first line). A merged stderr warning became
    # line 1 and was run as the command, failing every node-role probe with
    # "builder-rejected-argv". Stderr still surfaces in the FAIL tail below.
    if ! (cd studio && "${PYTHON}" -m hugmesh_studio --print-command \
            --config "${cfg}" --backend native --generator-dir "${REPO_DIR}") \
            >"${out}" 2>"${out}.err"; then
        cat "${out}.err" >>"${out}"
        _fail GUITHR "${name}" "--print-command exited non-zero" "${out}"
        THR_FAIL=$((THR_FAIL+1)); return
    fi
    local miss="" e
    for e in "$@"; do
        case "${e}" in
            PLAN:*) ;;   # plan-side, checked after the plan run below
            !*)     grep -q -- "${e#!}" "${out}" && miss+=" LEAKED:'${e#!}'" ;;
            *)      grep -q -- "${e}" "${out}" || miss+=" '${e}'" ;;
        esac
    done
    # ALWAYS prove builder acceptance — flag-present is not flag-accepted.
    if [ -z "${miss}" ]; then
        if ! gui_plan_from_command "${out}" "${plan}"; then
            miss+=" builder-rejected-argv(--print-plan rc!=0)"
            cat "${plan}" >>"${out}"   # surface the builder's error in the FAIL tail
        else
            for e in "$@"; do
                case "${e}" in
                    PLAN:!*) grep -q -- "${e#PLAN:!}" "${plan}" && miss+=" PLAN-LEAKED:'${e#PLAN:!}'" ;;
                    PLAN:*)  grep -q -- "${e#PLAN:}" "${plan}" || miss+=" PLAN:'${e#PLAN:}'" ;;
                esac
            done
        fi
    fi
    if [ -n "${miss}" ]; then
        _fail GUITHR "${name}" "missing/mismatched:${miss}" "${out}"; THR_FAIL=$((THR_FAIL+1))
    else
        THR_PASS=$((THR_PASS+1))
    fi
}

run_gui_threading_checks() {
    # fixtures for flags whose values the builder existence-checks BEFORE the plan
    local FIX="${TMP_DIR}/guithr-fix"
    mkdir -p "${FIX}/keysusb/Keys"
    printf '# matrix-probe brand profile (comment-only; CLI still wins)\n' >"${FIX}/brand.conf"
    touch "${FIX}/keysusb/Keys/kernel_key.pem" "${FIX}/keysusb/Keys/kernel_key.der" \
          "${FIX}/seedpkgs.list" "${FIX}/home.tar" "${FIX}/seedcode"

    # ── x86 ──
    guithr g1-cluster-domain-mesh-node \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","cluster_domain":"acme.example"}' \
        '--cluster-domain acme.example' 'PLAN:^PLAN_CLUSTER_DOMAIN=acme.example$'
    guithr g1-cluster-domain-cloud-client \
        '{"platform":"x86","role":"desktop","mode":"cloud","env":"test","cluster_domain":"acme.example"}' \
        '--cluster-domain acme.example' 'PLAN:^PLAN_CLUSTER_DOMAIN=acme.example$'
    guithr g3-brand-profile-x86 \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","brand_profile":"'"${FIX}"'/brand.conf"}' \
        "--config ${FIX}/brand.conf"
    guithr g4-release-state-x86 \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","release_state":"public"}' \
        '--release-state public'
    guithr g6-games-domain-x86 \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","games_domain":"games.acme.example"}' \
        '--games-domain games.acme.example'
    guithr g18-person-role-and-domains \
        '{"platform":"x86","role":"desktop","mode":"cloud","env":"test","person_role":"admin","domains":[{"name":"d.acme.example"}]}' \
        '--person-role admin' '--domains d.acme.example' 'PLAN:^PLAN_PERSON_ROLE=admin$'
    guithr g26-identity-x86 \
        '{"platform":"x86","role":"standalone-thick","mode":"standalone","env":"test","hostname":"myhost","timezone":"America/New_York","user":"bob"}' \
        '--hostname myhost' '--timezone America/New_York' '--user bob' 'PLAN:^PLAN_HOSTNAME=myhost$'
    guithr g27-node-fallback-creds \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","user_password":"pw","root_password":"pw2"}' \
        '--user-password pw' '--root-password pw2'
    guithr g21-capable-composable \
        '{"platform":"x86","role":"laptop","mode":"cloud","env":"test","capable":true}' \
        '--capable' 'PLAN:capable=true'
    guithr g22-unaffiliated-composable \
        '{"platform":"x86","role":"standalone-thin","mode":"standalone","env":"test","unaffiliated":true}' \
        '--unaffiliated' 'PLAN:^PLAN_UNAFFILIATED=true$'
    # Chromebook DESKTOP discoverability (coreboot/UEFI laptop image, ADR-16): a
    # first-class desktop selection in standalone mode too (no mesh/SSO), not only as a
    # cloud client — the request's Chromebook ask. Builder-accepted, role-class client.
    guithr g-chromebook-standalone-desktop \
        '{"platform":"x86","role":"chromebook","mode":"standalone","env":"test"}' \
        '--role chromebook' '--no-tailscale' '--no-sso' \
        'PLAN:^PLAN_ROLE=chromebook$' 'PLAN:^PLAN_ROLE_CLASS=client$'
    guithr g29-mesh-pins-x86 \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","tailscale":true,"headscale_version":"0.23.0","tailscale_version":"1.60.0","skip_tailscale":true}' \
        '--headscale-version 0.23.0' '--tailscale-version 1.60.0' '--skip-tailscale' \
        'PLAN:^PLAN_MESH=headscale=0.23.0,tailscale=skip$'
    guithr g33-nvidia-cuda \
        '{"platform":"x86","role":"be+gpu","mode":"mesh","env":"test","gpu_driver":"nvidia","nvidia_cuda":true}' \
        '--gpu-driver nvidia' '--nvidia-cuda' 'PLAN:^PLAN_CUDA=true$'
    guithr g33-grub-theme \
        '{"platform":"x86","role":"desktop","mode":"cloud","env":"test","grub_theme":"/tmp/gt"}' \
        '--grub-theme /tmp/gt'
    guithr g5-secure-boot-on \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","secure_boot":"on"}' \
        '--secure-boot' 'PLAN:secure_boot=true'
    guithr g5-secure-boot-off \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","secure_boot":"off"}' \
        '--no-secure-boot' 'PLAN:secure_boot=false'
    guithr g5-keys-usb-chain \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","keys_usb":"'"${FIX}"'/keysusb","secureboot_key":"'"${FIX}"'/keysusb/Keys/kernel_key.pem","secureboot_cert":"'"${FIX}"'/keysusb/Keys/kernel_key.der"}' \
        "--keys-usb ${FIX}/keysusb" '--secureboot-key' '--secureboot-cert'
    guithr g13-explicit-none-services \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","optional_services":["none"]}' \
        "--optional-services ''" 'PLAN:^PLAN_OPTIONAL_SERVICES=none$'
    guithr g14-all-services \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","optional_services":["all"]}' \
        '--all-services' 'PLAN:^PLAN_OPTIONAL_SERVICES=.*akkoma'
    guithr g14-exclude-services \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","optional_services":["all"],"exclude_services":["games","owncast"]}' \
        "--exclude-services 'games owncast'" 'PLAN:!^PLAN_OPTIONAL_SERVICES=.*games'
    guithr g23-x86-artifacts \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","build_img":"off","live_iso":"on","installer_iso":true,"build_tar":"on"}' \
        '--no-img' '--live-iso' '--installer-iso' '--tar' \
        'PLAN:^PLAN_ARTIFACTS=stage4.tar.xz,live.iso,installer.iso,fs.tar.xz$'
    guithr g25-grow-x86 \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","grow":"16G"}' \
        '--grow 16G' 'PLAN:grow=16g'
    guithr g31-home-extras \
        '{"platform":"x86","role":"standalone-thick","mode":"standalone","env":"test","home_seed_code_from":"'"${FIX}"'/seedcode","include_home_archive":"'"${FIX}"'/home.tar","seed_packages_from":"'"${FIX}"'/seedpkgs.list"}' \
        '--home-seed-code-from' '--include-home-archive' '--seed-packages-from'
    guithr g32-media-data-set \
        '{"platform":"x86","role":"standalone-thick","mode":"standalone","env":"test","media_data":"off","media_label":"DATA","no_vaults":true}' \
        '--no-media-data' '--media-label DATA' '--no-vaults' 'PLAN:media_data=false'
    guithr g34-force-off-tristates \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","aide":"off","tor_onion_service":"off","character_studio":"off","character_forge":"off","edge_ai_service":"off","sunshine":"off"}' \
        '--no-aide' '--no-tor' '--no-character-studio' '--no-character-forge' '--no-edge-ai' '--no-sunshine'
    # sunshine (thin-desktop stream host, §8b): the with-channel on a tailnet
    # CLIENT desktop — the only surface the builder applies it to (elsewhere it
    # warn-drops, the loud-harmless-no-op convention).
    guithr g34-with-sunshine-client \
        '{"platform":"x86","role":"laptop","mode":"cloud","env":"test","sunshine":true}' \
        '--with-sunshine'
    # character-forge (3D maker multi-app slug): the lone tri-state flag pair on
    # BOTH channels of the tri-state (with/no), plus the slug through the
    # --optional-services checklist path (x86 + rpi5 parity below).
    guithr g34-with-character-forge \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","character_forge":true}' \
        '--with-character-forge' 'PLAN:^PLAN_OPTIONAL_SERVICES=.*character-forge'
    guithr g13-character-forge-slug-in-services \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","optional_services":["akkoma","character-forge"]}' \
        "--optional-services 'akkoma character-forge'" 'PLAN:^PLAN_OPTIONAL_SERVICES=.*character-forge'
    guithr g30-image-stamps \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","release_tag":"rc1","version":"1.2.3"}' \
        '--release-tag rc1' '--version 1.2.3'
    guithr g38-plumbing-x86 \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","skip_kernel":true,"skip_clean":true,"distdir":"/tmp","build_subdir":"sub","seed_url":"http://s/x"}' \
        '--skip-kernel' '--skip-clean' '--distdir /tmp' '--build-subdir sub' '--seed-url http://s/x'
    guithr g2-headscale-url-env-passthrough \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","headscale_url":"https://hs.acme.example"}' \
        'env HEADSCALE_URL=https://hs.acme.example' '!--headscale-url'
    # ── package deltas (WS-BUILDER emission flip): --packages-add appends explicit
    # atoms to the resolved set; --packages-drop of a NON-mandatory atom is honored.
    guithr g9-packages-add \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","packages_add":"app-editors/vim app-misc/tmux"}' \
        '--packages-add' 'app-editors/vim' 'PLAN:^PLAN_PACKAGES_ADD=app-editors/vim app-misc/tmux$'
    guithr g9-packages-drop \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test","packages_drop":"app-editors/nano"}' \
        '--packages-drop' 'app-editors/nano' 'PLAN:^PLAN_PACKAGES_DROP=app-editors/nano$'
    # ── orchestration superdomain (WS-SUPER-B): emitted (effective <brand>.internal) for
    # a MESH build, threaded to the builder's PLAN_SUPERDOMAIN; ABSENT for standalone
    # (no orchestration plane). Default brand -> hugmesh.internal.
    guithr g-superdomain-mesh-x86 \
        '{"platform":"x86","role":"be","mode":"mesh","env":"test"}' \
        '--superdomain hugmesh.internal' 'PLAN:^PLAN_SUPERDOMAIN=hugmesh.internal$'
    guithr g-superdomain-standalone-absent-x86 \
        '{"platform":"x86","role":"standalone-thick","mode":"standalone","env":"test"}' \
        '!--superdomain' 'PLAN:^PLAN_SUPERDOMAIN=$'

    # ── rpi5 ──
    guithr g4-release-state-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","release_state":"public"}' \
        '--role backend' '--release-state public'
    guithr g6-games-domain-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","games_domain":"games.acme.example"}' \
        '--games-domain games.acme.example'
    guithr g15-infra-slugs-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","optional_services":["tor","egress-vpn"]}' \
        "--optional-services 'tor egress-vpn'" 'PLAN:^PLAN_OPTIONAL_SERVICES=.*tor'
    # character-forge flag parity on the ARM channel (the tri-state is _X86_RPI5).
    guithr g34-with-character-forge-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","character_forge":true}' \
        '--with-character-forge' 'PLAN:^PLAN_OPTIONAL_SERVICES=.*character-forge'
    guithr g34-no-character-forge-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","character_forge":"off"}' \
        '--no-character-forge' 'PLAN:!^PLAN_OPTIONAL_SERVICES=.*character-forge'
    guithr g13-explicit-none-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","optional_services":["none"]}' \
        "--optional-services ''" 'PLAN:^PLAN_OPTIONAL_SERVICES=none$'
    guithr g24-rpi5-iso-tar \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","build_iso":true,"build_tar":"on"}' \
        '--iso' '--tar' 'PLAN:^PLAN_ARTIFACTS=stage4.tar.xz,img,iso,fs.tar.xz$'
    guithr g24-rpi5-sd-only \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","sd_only":true,"skip_iso":true,"build_img":"off"}' \
        '--sd-only' '--skip-iso' '--no-img' 'PLAN:sd_only=true'
    guithr g37-rpi5-kernel-board-overrides \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","dtb_prefix":"bcm2712","kernel_img":"Image","pcie_gen3":true,"cpu":"cortex-a76","defconfig":"foo_defconfig"}' \
        '--dtb-prefix bcm2712' '--kernel-img Image' '--pcie-gen3' '--cpu cortex-a76' '--defconfig foo_defconfig' \
        'PLAN:pcie_gen3=true'
    guithr g28-local-user-without-standalone \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","local_user":"alice"}' \
        '--local-user alice' '!--standalone' 'PLAN:^PLAN_LOCAL_USER=alice$' 'PLAN:^PLAN_STANDALONE=false$'
    guithr g26-identity-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","hostname":"myhost","timezone":"America/New_York","user":"bob"}' \
        '--hostname myhost' '--timezone America/New_York' '--user bob' 'PLAN:^PLAN_HOSTNAME=myhost$'
    guithr g29-mesh-pins-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","tailscale":true,"headscale_version":"0.23.0","tailscale_version":"1.60.0","skip_tailscale":true}' \
        '--headscale-version 0.23.0' '--tailscale-version 1.60.0' '--skip-tailscale' \
        'PLAN:^PLAN_MESH=headscale=0.23.0,tailscale=skip$'
    guithr g38-plumbing-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","extra_packages":"app-editors/vim","build_subdir":"sub","seed_url":"http://s/x","version":"1.2.3","skip_kernel":true,"skip_clean":true}' \
        '--extra-packages app-editors/vim' '--build-subdir sub' '--seed-url http://s/x' '--version 1.2.3' '--skip-kernel' '--skip-clean'
    guithr g25-grow-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","grow":"none"}' \
        '--grow none' 'PLAN:grow=none'
    # WS-SUPER-B on ARM: the derived superdomain threads to the rpi5 builder's PLAN too.
    guithr g-superdomain-mesh-rpi5 \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test"}' \
        '--superdomain hugmesh.internal' 'PLAN:^PLAN_SUPERDOMAIN=hugmesh.internal$'

    # ── frite ──
    guithr g35-uboot-chain-frite \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","uboot_url":"https://x/u.bin","uboot_defconfig":"foo_defconfig"}' \
        '--uboot-url https://x/u.bin' '--uboot-defconfig foo_defconfig'
    guithr g35-skip-uboot-frite \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","skip_uboot":true}' \
        '--skip-uboot'
    guithr g37-frite-dtb-cpu \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","dtb":"meson.dtb","cpu":"cortex-a53"}' \
        '--dtb meson.dtb' '--cpu cortex-a53'
    guithr g24-image-only-frite \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","image_only":true}' \
        '--image-only'
    guithr g3-brand-profile-frite \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","brand_profile":"'"${FIX}"'/brand.conf"}' \
        "--config ${FIX}/brand.conf"

    # ── jetson ──
    guithr g36-jetson-kernel-flavor \
        '{"platform":"jetson","role":"edge_ai","mode":"mesh","env":"test","kernel_flavor":"l4t"}' \
        '--kernel-flavor l4t' 'PLAN:^PLAN_KERNEL_FLAVOR=l4t$'
    guithr g24-jetson-no-img \
        '{"platform":"jetson","role":"edge_ai","mode":"mesh","env":"test","build_img":"off"}' \
        '--no-img' 'PLAN:^PLAN_ARTIFACTS=stage4.tar.xz$'
    guithr g37-jetson-overrides \
        '{"platform":"jetson","role":"edge_ai","mode":"mesh","env":"test","dtb":"tegra234.dtb","cpu":"cortex-a78","defconfig":"foo_defconfig"}' \
        '--dtb tegra234.dtb' '--cpu cortex-a78' '--defconfig foo_defconfig' 'PLAN:^PLAN_DTB=tegra234.dtb$'

    # ── orangepi5 ──
    guithr g35-uboot-opi5 \
        '{"platform":"orangepi5","role":"orangepi5","mode":"cloud","env":"test","uboot_url":"https://x/u.bin","dtb":"rk3588.dtb"}' \
        '--uboot-url https://x/u.bin' '--dtb rk3588.dtb'
    guithr g24-g25-opi5-artifacts-grow \
        '{"platform":"orangepi5","role":"orangepi5","mode":"cloud","env":"test","image_only":true,"grow":"fill"}' \
        '--image-only' '--grow fill'

    # ── orangepizero2 ──
    guithr g35-uboot-opz2 \
        '{"platform":"orangepizero2","role":"orangepizero2","mode":"cloud","env":"test","uboot_defconfig":"foo_defconfig","skip_uboot":true,"dtb":"sun50i.dtb"}' \
        '--uboot-defconfig foo_defconfig' '--skip-uboot' '--dtb sun50i.dtb'
    guithr g26-identity-opz2 \
        '{"platform":"orangepizero2","role":"orangepizero2","mode":"cloud","env":"test","hostname":"myhost","timezone":"America/New_York","user":"bob"}' \
        '--hostname myhost' '--timezone America/New_York' '--user bob'

    # fail-closed completeness: a skipped/miscounted probe list is a failure,
    # never silently fewer checks (mirrors the MENUTHR shortfall accounting).
    if [ "${GUITHR_RUN}" -ne "${GUITHR_EXPECTED}" ]; then
        _fail GUITHR "completeness" "ran ${GUITHR_RUN}/${GUITHR_EXPECTED} probes — update GUITHR_EXPECTED alongside the probe list"
        THR_FAIL=$((THR_FAIL+1))
    fi
}

# ── negative checks: bad cells must FAIL loudly ─────────────────────────────────
expect_fail() { # NAME cmd...
    local name="$1"; shift
    local out="${TMP_DIR}/neg.out"
    if "$@" >"${out}" 2>&1; then
        _fail NEG "${name}" "expected non-zero exit, got 0" "${out}"; NEG_FAIL=$((NEG_FAIL+1))
    else
        NEG_PASS=$((NEG_PASS+1))
    fi
}

run_negative_checks() {
    expect_fail "x86: invalid role"          ./build-x86-host-stage4.sh --role bogus --print-plan
    expect_fail "rpi5: invalid role"         ./build-rpi5-stage4.sh --role laptop --print-plan
    expect_fail "rpi5: x86-only flag --steam" ./build-rpi5-stage4.sh --role backend --steam native --print-plan
    # NOTE: --local-pass/--local-user/--standalone are NOT x86-only anymore (the
    # standalone-ARM track ported them onto rpi5/frite/jetson) — --gpu-driver
    # stays a genuinely x86-only concept (vendor GPU driver matrix; RPi5's
    # Broadcom VideoCore has no such axis) so it replaces --local-pass here.
    expect_fail "rpi5: x86-only flag --gpu-driver" ./build-rpi5-stage4.sh --role backend --gpu-driver nvidia --print-plan
    expect_fail "rpi5: --standalone with no compatible role" ./build-rpi5-stage4.sh --role backend --standalone --print-plan
    # --board rpi3 (Phase 8) is DESKTOP-ONLY — hard-errors on every OTHER role.
    # Exercise more than one non-desktop role (the most important behavioral
    # guarantee of Phase 8), not just one.
    expect_fail "rpi5: --board rpi3 + role backend"  ./build-rpi5-stage4.sh --board rpi3 --role backend --print-plan
    expect_fail "rpi5: --board rpi3 + role pki"       ./build-rpi5-stage4.sh --board rpi3 --role pki --print-plan
    expect_fail "rpi5: --board rpi3 + role frontend"  ./build-rpi5-stage4.sh --board rpi3 --role frontend --print-plan
    expect_fail "rpi5: --board rpi3 + role generic"   ./build-rpi5-stage4.sh --board rpi3 --role generic --print-plan
    expect_fail "frite: invalid board"       ./build-frite-stage4.sh --board bogus --print-plan
    expect_fail "frite: invalid desktop"     ./build-frite-stage4.sh --board la-frite --desktop kde --print-plan
    expect_fail "jetson: invalid role"       ./build-jetson-stage4.sh --role bogus --print-plan
    expect_fail "jetson: invalid board"      ./build-jetson-stage4.sh --role edge_ai --board bogus --print-plan
    expect_fail "jetson: invalid env"        ./build-jetson-stage4.sh --role edge_ai --env staging --print-plan
    expect_fail "x86: invalid env"           ./build-x86-host-stage4.sh --role pki --env staging --print-plan
    expect_fail "orangepi5: invalid board"   ./build-orangepi5-stage4.sh --board bogus --print-plan
    expect_fail "orangepi5: invalid flavor"  ./build-orangepi5-stage4.sh --flavor bogus --print-plan
    expect_fail "orangepi5: invalid env"     ./build-orangepi5-stage4.sh --env staging --print-plan
    expect_fail "orangepizero2: invalid flavor" ./build-orangepi-zero2-stage4.sh --flavor bogus --print-plan
    expect_fail "orangepizero2: invalid env"    ./build-orangepi-zero2-stage4.sh --env staging --print-plan
    # NOTE: no "invalid board" negative test — this platform has NO --board
    # flag at all (a single board, unlike Frite/Orange-Pi-5's board tables);
    # --board bogus hits the generic "Unknown option" branch instead.
    expect_fail "orangepizero2: --board is not a flag on this builder" \
        ./build-orangepi-zero2-stage4.sh --board bogus --print-plan
    # -r/--role on orangepi5/orangepizero2 is an undocumented marker-only
    # escape hatch (neither builder has a real --role axis) that used to flow
    # unescaped into ART_PREFIX/STAGE4_TARBALL/LIVE_PATH/INSTALLER_PATH with NO
    # allow-list check at all — a path-traversal-shaped value must now be
    # rejected the same way every other identity input (BRAND/ORG/HOSTNAME/…) is.
    expect_fail "orangepi5: --role path-traversal rejected" \
        ./build-orangepi5-stage4.sh --role '../../tmp/evil' -H myhost --print-plan
    expect_fail "orangepizero2: --role path-traversal rejected" \
        ./build-orangepi-zero2-stage4.sh --role '../../tmp/evil' -H myhost --print-plan
    # UNAFFILIATED desktop: branding flags are a HARD conflict (no brand identity
    # at all), and --unaffiliated composes onto desktop/client roles only — a
    # cluster node is HugMesh platform machinery by definition.
    expect_fail "x86: unaffiliated role + --theme conflicts" \
        ./build-x86-host-stage4.sh --role standalone-unaffiliated --theme boogiepop --print-plan
    expect_fail "x86: --unaffiliated on a cluster role" \
        ./build-x86-host-stage4.sh --role pki --unaffiliated --print-plan
    # package deltas (WS-BUILDER): a malformed atom must be rejected at the builder
    # boundary (charset allowlist, mirroring core/validate.py), and a --packages-drop
    # of a tier-1 mandatory-payload atom must hard-fail (the image would fail its
    # post-emerge payload assert) — NEVER silently emit a payload-less stage4.
    expect_fail "x86: malformed --packages-add atom rejected" \
        ./build-x86-host-stage4.sh --role be --packages-add 'app-editors/vim; reboot' --print-plan
    expect_fail "x86: --packages-drop of a mandatory-payload atom rejected" \
        ./build-x86-host-stage4.sh --role be --packages-drop sys-cluster/kubelet --print-plan
    # orchestration superdomain (WS-SUPER-B): a malformed superdomain must be rejected at
    # the builder boundary (same RFC-1123 DNS allowlist as --cluster-domain).
    expect_fail "x86: malformed --superdomain rejected" \
        ./build-x86-host-stage4.sh --role be --superdomain 'x;reboot.internal' --print-plan
    # GUI: an unknown platform must refuse to print a command
    printf '{"platform":"bogus","role":"pki","mode":"mesh","env":"test"}\n' >"${TMP_DIR}/neg.json"
    expect_fail "gui: unknown platform" \
        env -C "${REPO_DIR}/studio" "${PYTHON}" -m hugmesh_studio --print-command \
            --config "${TMP_DIR}/neg.json" --backend native --generator-dir "${REPO_DIR}"
}

# ── GUI per-platform gating probes (the G10/G12 silent-drop class) ──────────────
# An x86-only field set on an ARM config must emit NO flag at all (the builder
# would exit "Unknown option" on it — the exact silent-drop class the capability
# table exists to prevent), and the jetson encrypt-root/standalone hard-blocks
# must fail --print-command loudly, mirroring the builder's own contract.
gui_gate() { # NAME CFG-JSON FLAG-THAT-MUST-BE-ABSENT...
    local name="$1" json="$2"; shift 2
    local cfg="${TMP_DIR}/guigate.json" out="${TMP_DIR}/guigate.out"
    printf '%s\n' "${json}" >"${cfg}"
    if ! (cd studio && "${PYTHON}" -m hugmesh_studio --print-command \
            --config "${cfg}" --backend native --generator-dir "${REPO_DIR}") >"${out}" 2>&1; then
        _fail GUIGATE "${name}" "--print-command exited non-zero (gating must DROP, not crash)" "${out}"
        NEG_FAIL=$((NEG_FAIL+1)); return
    fi
    local miss="" f
    for f in "$@"; do
        grep -q -- "${f}" "${out}" && miss+=" LEAKED:'${f}'"
    done
    if [ -n "${miss}" ]; then
        _fail GUIGATE "${name}" "x86-only flag leaked onto an ARM command:${miss}" "${out}"
        NEG_FAIL=$((NEG_FAIL+1))
    else
        NEG_PASS=$((NEG_PASS+1))
    fi
}

run_gui_gating_checks() {
    gui_gate "rpi5: steam is x86-only" \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","steam":"native"}' \
        '--steam'
    gui_gate "rpi5: gpu-driver is x86-only" \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","gpu_driver":"nvidia"}' \
        '--gpu-driver'
    gui_gate "rpi5: edge-AI set is x86-only" \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","edge_ai_service":"on","edge_ai_runtime":"vllm"}' \
        '--with-edge-ai' '--edge-ai-runtime'
    gui_gate "rpi5: u-boot chain is frite/opi5/opz2-only" \
        '{"platform":"rpi5","role":"be","mode":"mesh","env":"test","uboot_url":"https://x/u.bin","skip_uboot":true}' \
        '--uboot-url' '--skip-uboot'
    gui_gate "frite: secure-boot family is x86-only" \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","secure_boot":"on","keys_usb":"/tmp/keys"}' \
        '--secure-boot' '--keys-usb'
    gui_gate "frite: node fallback creds are x86-only" \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","user_password":"pw","root_password":"pw2"}' \
        '--user-password' '--root-password'
    gui_gate "frite: release-tag/distdir are x86-only" \
        '{"platform":"frite","role":"frite","mode":"cloud","env":"test","release_tag":"rc1","distdir":"/tmp"}' \
        '--release-tag' '--distdir'
    gui_gate "jetson: services/games are x86+rpi5-only" \
        '{"platform":"jetson","role":"edge_ai","mode":"mesh","env":"test","optional_services":["akkoma"],"enable_games":true}' \
        '--optional-services' '--enable-games'
    gui_gate "orangepi5: cluster plane is x86+rpi5-only" \
        '{"platform":"orangepi5","role":"orangepi5","mode":"cloud","env":"test","release_state":"public","games_domain":"games.acme.example"}' \
        '--release-state' '--games-domain'
    gui_gate "orangepizero2: branding assets are x86-only" \
        '{"platform":"orangepizero2","role":"orangepizero2","mode":"cloud","env":"test","theme":"boogiepop","wallpaper":"/tmp/w.png","brand_locked":true}' \
        '--theme' '--wallpaper' '--brand-locked'
    # jetson encrypt-root/standalone: HARD-FAIL, not silent drop — the Orin's
    # single boot+root partition cannot boot LUKS2-encrypted (by design).
    printf '{"platform":"jetson","role":"edge_ai","mode":"mesh","env":"test","encrypt_root":true}\n' >"${TMP_DIR}/jet-enc.json"
    expect_fail "gui: jetson encrypt-root hard-blocked" \
        env -C "${REPO_DIR}/studio" "${PYTHON}" -m hugmesh_studio --print-command \
            --config "${TMP_DIR}/jet-enc.json" --backend native --generator-dir "${REPO_DIR}"
    printf '{"platform":"jetson","role":"jetson-desktop","mode":"standalone","env":"test","standalone":true}\n' >"${TMP_DIR}/jet-sa.json"
    expect_fail "gui: jetson standalone hard-blocked" \
        env -C "${REPO_DIR}/studio" "${PYTHON}" -m hugmesh_studio --print-command \
            --config "${TMP_DIR}/jet-sa.json" --backend native --generator-dir "${REPO_DIR}"
}

# ── builder-flag coverage differ (tests/build-matrix/flag-coverage.sh) ──────────
# Diffs every builder's parsed arg surface against the Studio's real per-platform
# emission (PLATFORM_FIELD_SUPPORT-driven): 6 forward checks (every parsed flag
# fielded or documented-out-of-scope) + 6 reverse checks (every emitted flag
# parsed) + 12 packages-delta checks (--packages-add/--packages-drop, both
# parsed AND fielded, on all six builders — WS-BUILDER's atomic flip) + 6
# superdomain checks (--superdomain parsed AND fielded on all six — WS-SUPER-B's
# flip). FAIL-CLOSED: 30 expected, shortfall = failures.
COV_EXPECTED=30
COV_PASS=0; COV_FAIL=0
run_flag_coverage() {
    local out="${TMP_DIR}/flagcov.out"
    bash "${TEST_DIR}/flag-coverage.sh" >"${out}" 2>&1
    local rc=$? cpass
    cpass=$(grep -c '^FLAGCOV PASS' "${out}" || true)
    COV_PASS=$((COV_PASS + cpass))
    COV_FAIL=$((COV_FAIL + COV_EXPECTED - cpass))
    if [ ${rc} -ne 0 ] && [ "${cpass}" -eq "${COV_EXPECTED}" ]; then
        # rc!=0 with all sections passing = the script itself broke — fail loudly
        _fail FLAGCOV "script" "flag-coverage.sh exited ${rc}" "${out}"
        COV_FAIL=$((COV_FAIL+1))
    fi
    grep '^FLAGCOV FAIL' "${out}" >&2 || true
}

# ── four-choice taxonomy parity (TAXO) ──────────────────────────────────────────
# The Studio GUI (gui/pages/mode.py) is the REFERENCE implementation of the flow's
# four-choice opening screen (docs/STUDIO-WIZARD-FLOW.md). This bucket proves the SAME
# four choices are surfaced in the ncurses menu (scripts/build-menu.sh's mode_screen)
# AND the CLI guide (docker/build-image.sh's print_intents_guide), using the code-copy
# (live-extraction) assertion idiom the JOB/COVG buckets use. FAIL-CLOSED: an expected
# pass count, shortfall = failures.
#
#   GOLDEN set  extracted LIVE from mode.py — NOT hand-copied. mode.py imports Qt (can't
#               be imported Qt-free), so the labels are grep'd statically. A canary
#               asserts the golden taxonomy is EXACTLY 4 lines, so a silent shrink/grow
#               of the reference trips the gate (forces golden + every channel to move
#               together). A bogus label must be ABSENT from every channel (proves grep
#               discriminates, not matching everything).
#   registration parity  is manifest-only (User.registration — surfaced only in the
#               Studio users.py + --print-specs; the ncurses/CLI image builders carry no
#               per-user manifest), so the four tokens are asserted in the Studio users
#               surface ONLY. BUILD-MATRIX.md documents that registration is not a
#               menu/CLI image-build knob (the gate stays honest, not vacuously green).
# 12 taxonomy (4 mode.py + 4 menu + 4 cli) + 4 registration = 16 expected.
TAXO_EXPECTED=16
TAXO_PASS=0; TAXO_FAIL=0
run_parity_taxonomy_checks() {
    local mode_py="studio/hugmesh_studio/gui/pages/mode.py"
    local menu="scripts/build-menu.sh"
    local cli="docker/build-image.sh"
    local users_py="studio/hugmesh_studio/gui/pages/users.py"
    local -a golden=("Mesh node" "Local Docker mesh" "Mesh desktop client" "Standalone Gentoo desktop")
    local label

    # 1) GOLDEN source: the 4 labels live in the Studio reference (mode.py).
    for label in "${golden[@]}"; do
        if grep -qF -- "${label}" "${mode_py}"; then TAXO_PASS=$((TAXO_PASS+1))
        else echo "TAXO FAIL golden/mode.py missing '${label}'" >&2; TAXO_FAIL=$((TAXO_FAIL+1)); fi
    done
    # 2) menu channel — each choice must appear as a REAL ui_menu ITEM line
    #    (choice-tag + quoted label), NOT merely as prose. A whole-file substring grep
    #    is VACUOUS here: "Local Docker mesh" also occurs in the ui_menu prompt sentence,
    #    the routing comments, AND every reused local_mesh_screen ui_msg/ui_menu dialog
    #    TITLE below — so deleting the actual opening item (the choice a user can pick)
    #    would leave the string present and the gate falsely green. Anchoring to the
    #    opening-item shape `^<ws><tag><ws>"<label> …` makes dropping any one of the four
    #    a genuine (non-vacuous) grep miss. Tags mirror the golden order.
    local -a menu_tags=("meshnode" "localmesh" "client" "standalone")
    local i
    for i in 0 1 2 3; do
        label="${golden[$i]}"
        if grep -qE -- "^[[:space:]]*${menu_tags[$i]}[[:space:]]+\"${label} " "${menu}"; then
            TAXO_PASS=$((TAXO_PASS+1))
        else
            echo "TAXO FAIL menu channel missing opening choice item '${menu_tags[$i]}  \"${label} …\"' (${menu})" >&2
            TAXO_FAIL=$((TAXO_FAIL+1))
        fi
    done
    # 3) cli channel — each choice must appear as a REAL numbered intent item
    #    (`  N. <label> — …`) in print_intents_guide, not as incidental prose, so
    #    dropping an intent from the guide is likewise a non-vacuous miss.
    for i in 0 1 2 3; do
        label="${golden[$i]}"
        if grep -qE -- "^[[:space:]]*[0-9]+\.[[:space:]]+${label} " "${cli}"; then
            TAXO_PASS=$((TAXO_PASS+1))
        else
            echo "TAXO FAIL cli channel missing numbered intent '${label}' (${cli})" >&2
            TAXO_FAIL=$((TAXO_FAIL+1))
        fi
    done

    # NON-VACUITY canary (a): a bogus label must be ABSENT from every channel file.
    local bogus="Bare-metal cloud image" f
    for f in "${mode_py}" "${menu}" "${cli}"; do
        if grep -qF -- "${bogus}" "${f}"; then
            echo "TAXO FAIL non-vacuity: bogus label '${bogus}' unexpectedly present in ${f} — grep is matching too broadly" >&2
            TAXO_FAIL=$((TAXO_FAIL+1))
        fi
    done
    # NON-VACUITY canary (b): the golden taxonomy is EXACTLY 4 in mode.py.
    local n
    n="$(grep -cE 'Mesh node|Local Docker mesh|Mesh desktop client|Standalone Gentoo desktop' "${mode_py}")"
    if [ "${n}" -ne 4 ]; then
        echo "TAXO FAIL non-vacuity: mode.py golden taxonomy is ${n} lines, expected exactly 4 — the reference changed; update the golden set + every channel together" >&2
        TAXO_FAIL=$((TAXO_FAIL+1))
    fi

    # registration parity (manifest-only): the 4 first-login registration methods live
    # only in the Studio users surface. Asserted here, DOCUMENTED as not-a-menu/CLI knob.
    local tok
    for tok in derive discord gmail password; do
        if grep -qF -- "\"${tok}\"" "${users_py}"; then TAXO_PASS=$((TAXO_PASS+1))
        else echo "TAXO FAIL registration token '${tok}' missing from ${users_py}" >&2; TAXO_FAIL=$((TAXO_FAIL+1)); fi
    done

    # FAIL-CLOSED completeness gate (mirror COVG's COV_EXPECTED): every expected pass
    # must be present — a silent-skip (a file renamed away, a probe that never ran) is a
    # shortfall, not a vacuous green.
    if [ "${TAXO_PASS}" -lt "${TAXO_EXPECTED}" ]; then
        echo "TAXO FAIL completeness: ${TAXO_PASS}/${TAXO_EXPECTED} parity assertions passed" >&2
        TAXO_FAIL=$((TAXO_FAIL + TAXO_EXPECTED - TAXO_PASS))
    fi
}

# ── web/JOB catalog honesty gate (CAT) ──────────────────────────────────────────
# docs/catalog/image-catalog.json is the machine-readable grammar the admin-ui worklist
# multi-select (the "web modal") consumes. The honesty rule + all-menus-mirror require it
# to gate rpi3 EXACTLY like the Studio GUI: rpi3 (1GB RAM) is desktop-only and
# build-rpi5-stage4.sh hard-errors a non-desktop role on --board rpi3, so NO node role may
# offer rpi3 in ANY menu — including this one. This bucket (a) re-emits the catalog and
# fails on drift from the committed copy, and (b) asserts no non-desktop role exposes rpi3.
# NON-VACUITY: the desktop rpi5 role MUST still carry rpi3 (proves the check discriminates,
# not just "rpi3 absent everywhere").
# DEVICE VIEW (arch->family->device taxonomy, additive keys from core/device_catalog):
# (4) no UNSUPPORTED device is serialized with derived roles or selectable config axes
# (visible-but-not-buildable is the whole point of listing them, #351); (5) NON-VACUITY —
# at least one unsupported AND one experimental device exist, proving the status badge
# machinery discriminates; (6) the rpi3 DEVICE's mesh roles are exactly {rpi5-desktop}
# (the device-level twin of the node-rpi3 axis gate in (2)/(3)).
# FAIL-CLOSED: 6 expected assertions.
CAT_EXPECTED=6
run_catalog_checks() {
    local out="${TMP_DIR}/catalog.out"
    if ! "${PYTHON}" - "${REPO_DIR}" >"${out}" 2>&1 <<'PY'
import importlib.util, json, os, sys
repo = sys.argv[1]
# load the (dashed) emitter and the committed artifact
spec = importlib.util.spec_from_file_location(
    "_emit", os.path.join(repo, "scripts", "emit-image-catalog.py"))
emit = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.join(repo, "studio"))
spec.loader.exec_module(emit)
fresh = emit.build_image_catalog()
with open(os.path.join(repo, "docs", "catalog", "image-catalog.json"), encoding="utf-8") as fh:
    committed = json.load(fh)

def node_rpi3(cat):
    hits = []
    for mode, roles in cat["roles"].items():
        for e in roles:
            if e["image_class"] == "desktop":
                continue
            for p in e["platforms"]:
                if "rpi3" in p["axes"].get("board", []):
                    hits.append((mode, e["role"]))
    return hits

fails = []
# (1) committed catalog is in sync with the emitter (drift guard)
if committed != fresh:
    fails.append("DRIFT: docs/catalog/image-catalog.json != emit-image-catalog.py output "
                 "(re-run scripts/emit-image-catalog.py)")
# (2) no node role offers rpi3 in the committed (web-served) catalog
bad = node_rpi3(committed)
if bad:
    fails.append(f"NODE-RPI3: node roles offer rpi3 in the web catalog: {bad}")
# (3) NON-VACUITY: the desktop rpi5 role still carries rpi3
desk = [e for e in committed["roles"]["cloud"] if e["role"] == "rpi5-desktop"]
axis = desk and [p for p in desk[0]["platforms"] if p["platform"] == "rpi5"]
if not (axis and "rpi3" in axis[0]["axes"].get("board", [])):
    fails.append("NON-VACUITY: desktop rpi5 role lost rpi3 — the gate would be vacuously green")
# (4) device view honesty: no unsupported device carries derived roles / config axes
devices = committed.get("devices", [])
bad = [d["id"] for d in devices
       if d.get("status") == "unsupported"
       and (d.get("config_axes") or any(d.get("roles", {}).values()))]
if not devices:
    fails.append("DEVICE-VIEW: web catalog lost its devices key (arch/family/device taxonomy)")
elif bad:
    fails.append(f"UNSUPPORTED-BUILDABLE: unsupported devices serialized with roles/axes: {bad}")
# (5) NON-VACUITY: the status machinery must discriminate — both non-default statuses exist
statuses = {d.get("status") for d in devices}
if not {"unsupported", "experimental"} <= statuses:
    fails.append(f"STATUS-VACUITY: need >=1 unsupported AND >=1 experimental device, got {sorted(s for s in statuses if s)}")
# (6) the rpi3 DEVICE offers exactly the desktop image on mesh (device-level node gate)
rpi3 = [d for d in devices if d.get("id") == "rpi3"]
if not (rpi3 and {r["role"] for r in rpi3[0].get("roles", {}).get("mesh", [])} == {"rpi5-desktop"}):
    fails.append("DEVICE-RPI3: the rpi3 device's mesh roles are not exactly {rpi5-desktop}")

for f in fails:
    print("CAT FAIL", f)
print("CAT_OK" if not fails else "CAT_BAD")
PY
    then :; fi
    local passed
    passed=$(( CAT_EXPECTED - $(grep -c '^CAT FAIL' "${out}" || true) ))
    grep '^CAT FAIL' "${out}" >&2 || true
    if [ "${passed}" -lt 0 ]; then passed=0; fi
    CAT_PASS=$((CAT_PASS + passed))
    CAT_FAIL=$((CAT_FAIL + CAT_EXPECTED - passed))
}

# ── NON-GATING developer smokes ─────────────────────────────────────────────────
# The worklist-envelope parity smoke (WS-MODEL) and the JOB-channel image-spec
# parity fixture (WS-JOB) exercise the redesign's end-to-end command-translation
# invariants. They are run here for VISIBILITY but deliberately do NOT gate the
# matrix (design 6/7.1: promoted into the gate only once stable) — their result
# never enters TOTAL_FAIL or the exit status below.
SMOKE_REPORT=""
run_nongating_smokes() {
    local spec name path out rc
    for spec in "worklist-smoke:${TEST_DIR}/worklist-smoke.sh" \
                "image-spec-parity:${REPO_DIR}/tests/build-image-spec-parity.sh" \
                "image-spec-guards:${REPO_DIR}/tests/build-image-spec-guards.sh" \
                "image-tor-onion:${REPO_DIR}/tests/build-image-tor-onion.sh" \
                "image-idp:${REPO_DIR}/tests/build-image-idp.sh" \
                "idp-builder-functions:${REPO_DIR}/tests/scripts/test-idp-builder-functions.sh" \
                "qemu-matrix-assertions:${REPO_DIR}/tests/qemu/assertions_test.sh" \
                "host-accept-keywords:${REPO_DIR}/tests/scripts/test-host-accept-keywords.sh" \
                "python-targets-seed:${REPO_DIR}/tests/scripts/test-python-targets-seed.sh" \
                "calamares-boost-seed:${REPO_DIR}/tests/scripts/test-calamares-boost-seed.sh" \
                "installer-ui-node-default:${REPO_DIR}/tests/scripts/test-installer-ui-node-default.sh" \
                "host-selinux-tools:${REPO_DIR}/tests/scripts/test-host-selinux-tools.sh" \
                "builder-log-paths:${REPO_DIR}/tests/scripts/test-builder-log-paths.sh" \
                "dracut-cross-lib:${REPO_DIR}/tests/scripts/test-dracut-cross-lib.sh" \
                "host-mutation-guard:${REPO_DIR}/tests/scripts/test-host-mutation-guard.sh" \
                "sharedbinpkg-prebuild-target:${TEST_DIR}/prebuild-smoke.sh" \
                "sharedbinpkg-per-board-pkgdir:${REPO_DIR}/tests/scripts/test-rpi5-per-board-pkgdir.sh" \
                "sharedbinpkg-ro-distdir:${REPO_DIR}/tests/scripts/test-arm-ro-distdir.sh" \
                "sharedbinpkg-pool-fingerprint:${REPO_DIR}/tests/scripts/test-binpkg-pool-fingerprint.sh" \
                "managed-services-gate:${REPO_DIR}/tests/managed-services/test-managed-services-gate.sh" \
                "package-completeness:${REPO_DIR}/tests/build-package-completeness.sh" \
                "spec-use-parity:${REPO_DIR}/tests/scripts/test-spec-use-parity.sh"; do
        name="${spec%%:*}"; path="${spec#*:}"
        if [ ! -f "${path}" ]; then
            SMOKE_REPORT+="  ${name}: SKIP (not present)"$'\n'; continue
        fi
        out="${TMP_DIR}/smoke-${name}.out"
        if PYTHON="${PYTHON}" bash "${path}" >"${out}" 2>&1; then
            SMOKE_REPORT+="  ${name}: PASS"$'\n'
        else
            rc=$?
            SMOKE_REPORT+="  ${name}: FAIL rc=${rc} (non-gating — does NOT fail the matrix)"$'\n'
            printf 'NON-GATING smoke FAIL [%s] (informational):\n' "${name}" >&2
            sed 's/^/    | /' "${out}" | tail -n 8 >&2
        fi
    done
}

# ── walk the matrix ─────────────────────────────────────────────────────────────
[ -f "${MATRIX}" ] || { echo "matrix.tsv not found at ${MATRIX}" >&2; exit 1; }

ROWS=0
while IFS=$'\t' read -r platform role env board flavor desktop; do
    case "${platform}" in \#*|"") continue ;; esac
    [ "${board}" = "-" ]   && board=""
    [ "${flavor}" = "-" ]  && flavor=""
    [ "${desktop}" = "-" ] && desktop=""
    ROWS=$((ROWS+1))
    check_cli  "${platform}" "${role}" "${env}" "${board}" "${flavor}" "${desktop}"
    check_make "${platform}" "${role}" "${env}" "${board}" "${flavor}" "${desktop}"
    check_gui  "${platform}" "${role}" "${env}" "${board}" "${flavor}" "${desktop}"
done < "${MATRIX}"

run_menu_channel
run_job_channel
run_threading_checks
run_gui_threading_checks
run_negative_checks
run_gui_gating_checks
run_flag_coverage
run_parity_taxonomy_checks
run_catalog_checks
run_nongating_smokes

TOTAL_PASS=$((CLI_PASS + MAKE_PASS + MENU_PASS + GUI_PASS + JOB_PASS + THR_PASS + NEG_PASS + COV_PASS + TAXO_PASS + CAT_PASS))
TOTAL_FAIL=$((CLI_FAIL + MAKE_FAIL + MENU_FAIL + GUI_FAIL + JOB_FAIL + THR_FAIL + NEG_FAIL + COV_FAIL + TAXO_FAIL + CAT_FAIL))

# COMPLETENESS gate (fail-closed): every channel must have PASSED every matrix
# row — not merely "no failures". This catches the silent-skip class of hole
# (a crashed channel child, a row one channel's parse never reached) where a
# per-row counter simply does not tick and the "5 channels per cell" guarantee
# would otherwise degrade without a single FAIL line.
CH_SHORT=0
for _ch in CLI MAKE MENU GUI JOB; do
    _pv="${_ch}_PASS"
    if [ "${!_pv}" -ne "${ROWS}" ]; then
        printf 'FAIL [%s] channel INCOMPLETE: %d/%d matrix rows passed\n' \
            "${_ch}" "${!_pv}" "${ROWS}" >&2
        CH_SHORT=1
    fi
done

echo    "── build-matrix check ──────────────────────────────────────"
echo    "matrix cells: ${ROWS}"
printf  'CLI  (--print-plan):    %3d passed, %d failed\n' "${CLI_PASS}"  "${CLI_FAIL}"
printf  'MAKE (make -n):         %3d passed, %d failed\n' "${MAKE_PASS}" "${MAKE_FAIL}"
printf  'MENU (build_make_cmd):  %3d passed, %d failed\n' "${MENU_PASS}" "${MENU_FAIL}"
printf  'GUI  (--print-command): %3d passed, %d failed\n' "${GUI_PASS}"  "${GUI_FAIL}"
printf  'JOB  (build-image.sh):  %3d passed, %d failed\n' "${JOB_PASS}"  "${JOB_FAIL}"
printf  'THRD (flag threading):  %3d passed, %d failed\n' "${THR_PASS}"  "${THR_FAIL}"
printf  'NEG  (must-fail):       %3d passed, %d failed\n' "${NEG_PASS}"  "${NEG_FAIL}"
printf  'COVG (flag coverage):   %3d passed, %d failed\n' "${COV_PASS}"  "${COV_FAIL}"
printf  'TAXO (4-choice parity): %3d passed, %d failed\n' "${TAXO_PASS}" "${TAXO_FAIL}"
printf  'CAT  (web-catalog honesty): %3d passed, %d failed\n' "${CAT_PASS}" "${CAT_FAIL}"
printf  'TOTAL:                  %3d passed, %d failed\n' "${TOTAL_PASS}" "${TOTAL_FAIL}"
if [ -n "${SMOKE_REPORT}" ]; then
    echo "── non-gating smokes (informational; NOT in TOTAL) ─────────"
    printf '%s' "${SMOKE_REPORT}"
fi
[ "${TOTAL_FAIL}" -eq 0 ] && [ "${ROWS}" -gt 0 ] && [ "${CH_SHORT}" -eq 0 ]
