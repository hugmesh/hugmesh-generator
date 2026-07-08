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
        rpi5)   echo build-rpi5-stage4.sh ;;
        x86)    echo build-x86-host-stage4.sh ;;
        frite)  echo build-frite-stage4.sh ;;
        jetson) echo build-jetson-stage4.sh ;;
        *)      return 1 ;;
    esac
}

# ── channel 1: CLI — builder --print-plan ───────────────────────────────────────
check_cli() { # platform role env board flavor desktop
    local platform="$1" role="$2" env="$3" board="$4" flavor="$5" desktop="$6"
    local row="cli ${platform}/${role}/${env}${board:+ board=${board}}${flavor:+ flavor=${flavor}}${desktop:+ desktop=${desktop}}"
    local builder out="${TMP_DIR}/cli.out" args=()
    builder="$(builder_for "${platform}")"
    case "${platform}" in
        frite)  args=(--board "${board}" --flavor "${flavor}" --desktop "${desktop}") ;;
        jetson) args=(--role "${role}" --board "${board}") ;;
        *)      args=(--role "${role}") ;;
    esac
    args+=(--env "${env}" --print-plan)
    if ! "./${builder}" "${args[@]}" >"${out}" 2>&1; then
        _fail CLI "${row}" "builder exited non-zero" "${out}"; CLI_FAIL=$((CLI_FAIL+1)); return
    fi
    local want_role="${role}"
    local miss=""
    grep -qx "PLAN_BUILDER=${builder}"  "${out}" || miss+=" PLAN_BUILDER=${builder}"
    grep -qx "PLAN_ROLE=${want_role}"   "${out}" || miss+=" PLAN_ROLE=${want_role}"
    grep -qx "PLAN_ENV=${env}"          "${out}" || miss+=" PLAN_ENV=${env}"
    if [ "${platform}" = frite ]; then
        grep -qx "PLAN_BOARD=${board}"     "${out}" || miss+=" PLAN_BOARD=${board}"
        grep -qx "PLAN_FLAVOR=${flavor}"   "${out}" || miss+=" PLAN_FLAVOR=${flavor}"
        grep -qx "PLAN_DESKTOP=${desktop}" "${out}" || miss+=" PLAN_DESKTOP=${desktop}"
    fi
    if [ "${platform}" = jetson ]; then
        grep -qx "PLAN_BOARD=${board}" "${out}" || miss+=" PLAN_BOARD=${board}"
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
        rpi5)   target="rpi-${role}" ;;
        x86)    target="x86-${role}" ;;
        jetson) target="jetson-${role}"; vars=("JETSON_BOARD=${board}") ;;
        frite)  target="frite"
                vars=("FRITE_BOARD=${board}" "FRITE_FLAVOR=${flavor}" "FRITE_DESKTOP=${desktop}") ;;
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
        rpi5)   target="rpi-${role}" ;;
        x86)    target="x86-${role}" ;;
        jetson) target="jetson-${role}"
                OPT_JETSON_BOARD="${board}" ;;
        frite)  target="frite"
                OPT_FRITE_BOARD="${board}" OPT_FRITE_FLAVOR="${flavor}" OPT_FRITE_DESKTOP="${desktop}" ;;
        *)      echo "MENU FAIL ${platform}/${role}/${env} unknown platform"; continue ;;
    esac
    row="${target} ENV=${env}"
    build_make_cmd "${target}" "matrix ${row}" 1
    miss=""
    [ "${RUN_MAKE[0]}" = "${target}" ] || miss+=" target(got ${RUN_MAKE[0]})"
    has_elem "ENV=${env}" || miss+=" ENV=${env}"
    if [ "${platform}" = frite ]; then
        has_elem "FRITE_BOARD=${board}"     || miss+=" FRITE_BOARD=${board}"
        has_elem "FRITE_FLAVOR=${flavor}"   || miss+=" FRITE_FLAVOR=${flavor}"
        has_elem "FRITE_DESKTOP=${desktop}" || miss+=" FRITE_DESKTOP=${desktop}"
    fi
    if [ "${platform}" = jetson ]; then
        has_elem "JETSON_BOARD=${board}" || miss+=" JETSON_BOARD=${board}"
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
for target in rpi-backend x86-pki frite jetson-edge_ai; do
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
    # FAIL-CLOSED like everything else: 4 probes expected, shortfall = failures.
    local mthr_pass
    mthr_pass=$(grep -c '^MENUTHR PASS' "${out}" || true)
    THR_PASS=$((THR_PASS + mthr_pass))
    THR_FAIL=$((THR_FAIL + 4 - mthr_pass))
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
    # FAIL-CLOSED: a crashed/aborted menu child (source error, set -u trip, …)
    # must count as a channel failure, not as "0 rows = 0 failures" — otherwise
    # the 5-channels-per-cell guarantee silently degrades to 4 (the completeness
    # gate below backstops this too).
    if [ ${rc} -ne 0 ]; then
        _fail MENU "channel" "menu child exited ${rc}" "${TMP_DIR}/menu.err"
        MENU_FAIL=$((MENU_FAIL+1))
    fi
    grep -E '^(MENU|MENUTHR|FLEETTHR|UNAFFTHR) FAIL' "${out}" >&2 || true
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
    else
        grep -q -- "--role ${role}" "${out}" || miss+=" '--role ${role}'"
        if [ "${platform}" = jetson ]; then
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
        NEG_FAIL=$((NEG_FAIL+3))   # the 3 JOBNEG probes below never ran
        return
    fi
    MATRIX="${MATRIX}" FN="${fn}" bash <<'JOB_EOF' >"${out}" 2>"${TMP_DIR}/job.err"
set -u
# the extracted-verbatim resolve_build_target() + every variable it reads or
# writes (mirrors build-image.sh's own top-level initialisation)
HARDWARE_CLASS="" IMAGE_TYPE=""
PLATFORM="" BUILD_ROLE="" FRITE_BOARD_OUT="" FRITE_FLAVOR_OUT=""
JETSON_BOARD_OUT="" KEYS_ROLE=""
# shellcheck disable=SC1090
source "${FN}"

# resolve HW TYPE — reset the output vars, then run the REAL worker function
resolve() {
    HARDWARE_CLASS="$1" IMAGE_TYPE="$2"
    PLATFORM="" BUILD_ROLE="" FRITE_BOARD_OUT="" FRITE_FLAVOR_OUT=""
    JETSON_BOARD_OUT="" KEYS_ROLE=""
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
        rpi5)   hw="rpi5.${role}"; type=primary ;;
        x86)    hw="x86.${role/+/-}"
                case "${role}" in
                    laptop|chromebook|desktop|standalone-*) type=client ;;
                    *)                                      type=primary ;;
                esac ;;
        frite)  hw="frite.${board}.${flavor}"; type=client ;;
        jetson) hw="jetson.${role}.${board}"; type=primary ;;
        *)      echo "JOB FAIL ${row} — unknown platform"; continue ;;
    esac
    if [ "${platform}" = frite ] && [ "${flavor}" = both ]; then
        # flavor=both builds TWO artifacts; the worker's single-imageRef
        # ingest contract deliberately REJECTS it (build-image.sh's frite
        # convention note). The documented behavior for this cell is a clean
        # refusal — assert exactly that, never acceptance.
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
    miss=""
    [ "${PLATFORM}" = "${platform}" ] || miss+=" PLATFORM(got '${PLATFORM}')"
    case "${platform}" in
        frite)
            [ "${FRITE_BOARD_OUT}" = "${board}" ]   || miss+=" FRITE_BOARD_OUT(got '${FRITE_BOARD_OUT}')"
            [ "${FRITE_FLAVOR_OUT}" = "${flavor}" ] || miss+=" FRITE_FLAVOR_OUT(got '${FRITE_FLAVOR_OUT}')"
            ;;
        jetson)
            [ "${BUILD_ROLE}" = "${role}" ]        || miss+=" BUILD_ROLE(got '${BUILD_ROLE}')"
            [ "${JETSON_BOARD_OUT}" = "${board}" ] || miss+=" JETSON_BOARD_OUT(got '${JETSON_BOARD_OUT}')"
            ;;
        *)
            [ "${BUILD_ROLE}" = "${role}" ]        || miss+=" BUILD_ROLE(got '${BUILD_ROLE}')"
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
JOB_EOF
    local rc=$?
    JOB_PASS=$(grep -c '^JOB PASS' "${out}" || true)
    JOB_FAIL=$(grep -c '^JOB FAIL' "${out}" || true)
    # the child's negative probes count toward the NEG bucket; FAIL-CLOSED like
    # the menu child's threading probes: 3 expected, shortfall = failures.
    local jneg_pass
    jneg_pass=$(grep -c '^JOBNEG PASS' "${out}" || true)
    NEG_PASS=$((NEG_PASS + jneg_pass))
    NEG_FAIL=$((NEG_FAIL + 3 - jneg_pass))
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
    for t in x86-pki x86-standalone-thin jetson jetson-edge_ai frite; do
        if make -n "${t}" NATIVE=1 STANDALONE_FLAGS='--matrix-sf-probe' >"${out}" 2>&1 \
           && grep -q -- '--matrix-sf-probe' "${out}"; then
            THR_PASS=$((THR_PASS+1))
        else
            _fail THREAD "make ${t}" "STANDALONE_FLAGS not threaded into the recipe" "${out}"
            THR_FAIL=$((THR_FAIL+1))
        fi
    done
    for t in rpi-backend x86-pki frite jetson jetson-edge_ai; do
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
    expect_fail "rpi5: x86-only flag --local-pass" ./build-rpi5-stage4.sh --role backend --local-pass hunter2 --print-plan
    expect_fail "frite: invalid board"       ./build-frite-stage4.sh --board bogus --print-plan
    expect_fail "frite: invalid desktop"     ./build-frite-stage4.sh --board la-frite --desktop kde --print-plan
    expect_fail "jetson: invalid role"       ./build-jetson-stage4.sh --role bogus --print-plan
    expect_fail "jetson: invalid board"      ./build-jetson-stage4.sh --role edge_ai --board bogus --print-plan
    expect_fail "jetson: invalid env"        ./build-jetson-stage4.sh --role edge_ai --env staging --print-plan
    expect_fail "x86: invalid env"           ./build-x86-host-stage4.sh --role pki --env staging --print-plan
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
