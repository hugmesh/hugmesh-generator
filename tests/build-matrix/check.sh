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
#   GUI   write a config JSON for the row; `python3 -m snapdragon_studio
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

# baseline: every option build_make_cmd reads, at the script's own defaults
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
    # FAIL-CLOSED like everything else: 6 probes expected (rpi-backend, x86-pki,
    # frite, jetson-edge_ai, orangepi5, orangepizero2 — see the probe list
    # above; keep this count in sync with that list's length), shortfall = failures.
    local mthr_pass
    mthr_pass=$(grep -c '^MENUTHR PASS' "${out}" || true)
    THR_PASS=$((THR_PASS + mthr_pass))
    THR_FAIL=$((THR_FAIL + 6 - mthr_pass))
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

# ── channel 4: GUI — snapdragon_studio --print-command (headless, Qt-free) ──────
# Studio ids differ from the builder spellings in two places: rpi5 spells the
# node roles out (be/fe <-> backend/frontend) and the jetson desktop role id is
# disambiguated (jetson-desktop -> --role desktop). Exercise the Studio ids.
gui_config_json() { # platform role env board flavor desktop -> stdout JSON
    local platform="$1" role="$2" env="$3" board="$4" flavor="$5" desktop="$6"
    local mode gui_role="${role}"
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
    printf '{"platform":"%s","role":"%s","mode":"%s","env":"%s"' \
        "${platform}" "${gui_role}" "${mode}" "${env}"
    if [ "${platform}" = frite ]; then
        printf ',"board":"%s","flavor":"%s","desktop":"%s"' "${board}" "${flavor}" "${desktop}"
    elif [ "${platform}" = jetson ]; then
        # the jetson board axis (the GUI's Jetson board combo writes the same key)
        printf ',"board":"%s"' "${board}"
    elif [ "${platform}" = orangepi5 ]; then
        printf ',"board":"%s","flavor":"%s"' "${board}" "${flavor}"
    elif [ "${platform}" = rpi5 ] && [ -n "${board}" ]; then
        # the rpi5 board axis (--board rpi4/rpi3; the rpi5-default rows have
        # board="" and correctly emit NO "board" key at all, same as an
        # operator who never touched the board field — ImageConfig.board
        # defaults to "" -> no --board flag, the builder's own rpi5 default).
        printf ',"board":"%s"' "${board}"
    elif [ "${platform}" = orangepizero2 ]; then
        printf ',"flavor":"%s"' "${flavor}"
    fi
    printf '}\n'
}

check_gui() { # platform role env board flavor desktop
    local platform="$1" role="$2" env="$3" board="$4" flavor="$5" desktop="$6"
    local row="gui ${platform}/${role}/${env}${board:+ board=${board}}${flavor:+ flavor=${flavor}}${desktop:+ desktop=${desktop}}"
    local builder out="${TMP_DIR}/gui.out" cfg="${TMP_DIR}/gui.json"
    builder="$(builder_for "${platform}")"
    gui_config_json "${platform}" "${role}" "${env}" "${board}" "${flavor}" "${desktop}" >"${cfg}"
    if ! (cd studio && "${PYTHON}" -m snapdragon_studio --print-command \
            --config "${cfg}" --backend native --generator-dir "${REPO_DIR}") >"${out}" 2>&1; then
        _fail GUI "${row}" "--print-command exited non-zero" "${out}"; GUI_FAIL=$((GUI_FAIL+1)); return
    fi
    local miss=""
    grep -q "${builder}" "${out}" || miss+=" ${builder}"
    grep -q -- "--env ${env}" "${out}" || miss+=" '--env ${env}'"
    if [ "${platform}" = frite ]; then
        grep -q -- "--board ${board}"     "${out}" || miss+=" '--board ${board}'"
        grep -q -- "--flavor ${flavor}"   "${out}" || miss+=" '--flavor ${flavor}'"
        grep -q -- "--desktop ${desktop}" "${out}" || miss+=" '--desktop ${desktop}'"
    elif [ "${platform}" = orangepi5 ]; then
        grep -q -- "--board ${board}"   "${out}" || miss+=" '--board ${board}'"
        grep -q -- "--flavor ${flavor}" "${out}" || miss+=" '--flavor ${flavor}'"
    elif [ "${platform}" = orangepizero2 ]; then
        grep -q -- "--flavor ${flavor}" "${out}" || miss+=" '--flavor ${flavor}'"
    else
        grep -q -- "--role ${role}" "${out}" || miss+=" '--role ${role}'"
        if [ "${platform}" = jetson ]; then
            grep -q -- "--board ${board}" "${out}" || miss+=" '--board ${board}'"
        fi
        if [ "${platform}" = rpi5 ] && [ -n "${board}" ]; then
            grep -q -- "--board ${board}" "${out}" || miss+=" '--board ${board}'"
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
    # cluster node is Snapdragon platform machinery by definition.
    expect_fail "x86: unaffiliated role + --theme conflicts" \
        ./build-x86-host-stage4.sh --role standalone-unaffiliated --theme boogiepop --print-plan
    expect_fail "x86: --unaffiliated on a cluster role" \
        ./build-x86-host-stage4.sh --role pki --unaffiliated --print-plan
    # GUI: an unknown platform must refuse to print a command
    printf '{"platform":"bogus","role":"pki","mode":"mesh","env":"test"}\n' >"${TMP_DIR}/neg.json"
    expect_fail "gui: unknown platform" \
        env -C "${REPO_DIR}/studio" "${PYTHON}" -m snapdragon_studio --print-command \
            --config "${TMP_DIR}/neg.json" --backend native --generator-dir "${REPO_DIR}"
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
run_negative_checks

TOTAL_PASS=$((CLI_PASS + MAKE_PASS + MENU_PASS + GUI_PASS + JOB_PASS + THR_PASS + NEG_PASS))
TOTAL_FAIL=$((CLI_FAIL + MAKE_FAIL + MENU_FAIL + GUI_FAIL + JOB_FAIL + THR_FAIL + NEG_FAIL))

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
printf  'TOTAL:                  %3d passed, %d failed\n' "${TOTAL_PASS}" "${TOTAL_FAIL}"
[ "${TOTAL_FAIL}" -eq 0 ] && [ "${ROWS}" -gt 0 ] && [ "${CH_SHORT}" -eq 0 ]
