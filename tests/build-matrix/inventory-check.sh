#!/usr/bin/env bash
# inventory-check.sh — the ALL-IMAGES gate: the committed inventory must still be what
# the six build channels actually say.
#
# tests/build-matrix/check.sh proves the 150 CURATED matrix.tsv cells build from five
# channels. This gate is the other half: it proves the committed FULL inventory
# (docs/catalog/image-inventory.json — every image docs/catalog/image-catalog.json
# advertises, x which channels can express it) still matches reality, so a channel change
# can never silently drift away from the documented inventory.
#
# Five legs, all dry-run (no root, no docker, no network, no build):
#
#   DRIFT  re-run scripts/emit-image-inventory.py into a temp tree and diff BOTH artifacts
#          against the committed copies. Adding a role/board/flavor, changing a menu
#          picker, widening the Job worker's HARDWARE_CLASS grammar or teaching the
#          Makefile a new axis var all change the regenerated output — so the inventory
#          and its doc table cannot rot behind the channels. FIX: re-run the generator and
#          commit the result (and review what moved).
#   CLI    INDEPENDENT re-verification, in bash, of the JSON's per-image `channels.cli`:
#          run each image's builder with its own axis flags + --print-plan and require the
#          recorded verdict. A generator bug that silently marked everything reachable
#          cannot survive this leg (it never imports the generator).
#   JOB    same, for `channels.job`: docker/build-image.sh's REAL resolve_build_target,
#          extracted and executed against each image's recorded HARDWARE_CLASS.
#   INV    hard invariants that must hold for "we can create all images" to be true:
#            * every non-phantom image is CLI-buildable          (a builder rejecting an
#                                                                 advertised image = fail)
#            * every image is GUI- and WORKLIST-expressible      (the Studio IS the
#                                                                 grammar's own source)
#            * every matrix.tsv cell maps onto an inventory image (no undocumented target)
#   BASE   the reviewed gap/phantom BASELINE: the committed counts are the numbers a human
#          signed off on. A NEW gap or phantom fails here even if someone regenerated the
#          JSON, so widening a hole is never a silent green.
#
#   bash tests/build-matrix/inventory-check.sh      # or: make inventory-check
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
PYTHON="${PYTHON:-python3}"
INVENTORY="${REPO_DIR}/docs/catalog/image-inventory.json"
INVENTORY_MD="${REPO_DIR}/docs/IMAGE-INVENTORY.md"
GENERATOR="${REPO_DIR}/scripts/emit-image-inventory.py"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
cd "${REPO_DIR}"

DRIFT_PASS=0; DRIFT_FAIL=0
CLI_PASS=0;   CLI_FAIL=0
JOB_PASS=0;   JOB_FAIL=0
INV_PASS=0;   INV_FAIL=0
BASE_PASS=0;  BASE_FAIL=0

_fail() { printf 'FAIL [%s] %s\n' "$1" "$2" >&2; }

for f in "${INVENTORY}" "${INVENTORY_MD}" "${GENERATOR}"; do
    [ -f "${f}" ] || { echo "inventory-check: missing ${f#${REPO_DIR}/}" >&2; exit 2; }
done

# ── leg 1: DRIFT — regenerate and diff ────────────────────────────────────────────────
printf '== DRIFT — regenerate docs/catalog/image-inventory.json + docs/IMAGE-INVENTORY.md\n'
if "${PYTHON}" "${GENERATOR}" --quiet --generator-dir "${REPO_DIR}" \
        --out "${TMP_DIR}/image-inventory.json" --md "${TMP_DIR}/IMAGE-INVENTORY.md" \
        >"${TMP_DIR}/gen.log" 2>&1; then
    for pair in "image-inventory.json:${INVENTORY}" "IMAGE-INVENTORY.md:${INVENTORY_MD}"; do
        fresh="${TMP_DIR}/${pair%%:*}"; committed="${pair#*:}"
        if diff -q "${committed}" "${fresh}" >/dev/null 2>&1; then
            DRIFT_PASS=$((DRIFT_PASS + 1))
        else
            DRIFT_FAIL=$((DRIFT_FAIL + 1))
            _fail DRIFT "${committed#${REPO_DIR}/} is STALE — a build channel changed and the"
            printf '    inventory was not regenerated. Re-run:  %s\n' \
                   "python3 scripts/emit-image-inventory.py" >&2
            diff -u "${committed}" "${fresh}" 2>/dev/null | head -n 40 | sed 's/^/    | /' >&2
        fi
    done
else
    DRIFT_FAIL=$((DRIFT_FAIL + 1))
    _fail DRIFT "scripts/emit-image-inventory.py exited non-zero"
    tail -n 20 "${TMP_DIR}/gen.log" | sed 's/^/    | /' >&2
fi

# ── the per-image probe table (id, platform, builder args, channels.cli/.job, hwclass) ──
# Emitted from the COMMITTED json only — this leg must not re-derive anything from the
# generator, or it would just be checking the generator against itself.
"${PYTHON}" - "${INVENTORY}" >"${TMP_DIR}/probe.tsv" <<'PY'
import json, sys
inv = json.load(open(sys.argv[1], encoding="utf-8"))
BUILDER = {
    "x86": "build-x86-host-stage4.sh", "rpi5": "build-rpi5-stage4.sh",
    "frite": "build-frite-stage4.sh", "jetson": "build-jetson-stage4.sh",
    "orangepi5": "build-orangepi5-stage4.sh",
    "orangepizero2": "build-orangepi-zero2-stage4.sh",
    "orangepizero2w": "build-orangepi-zero2w-stage4.sh",
    "orangepizero3": "build-orangepi-zero3-stage4.sh",
    "orangepi3-lts": "build-orangepi3-lts-stage4.sh",
    "orangepi4-lts": "build-orangepi4-lts-stage4.sh",
}
for r in inv["images"]:
    args = []
    if r["builder_role"]:
        args += ["--role", r["builder_role"]]
    for flag, key in (("--board", "board"), ("--flavor", "flavor"), ("--desktop", "desktop")):
        if r[key]:
            args += [flag, r[key]]
    # "|"-delimited, NOT tabs: tab is IFS *whitespace*, so bash `read` would COLLAPSE
    # consecutive tabs around an empty field (x86 has no board; job=no rows record no
    # accepted types) and silently shift every later column into the wrong variable.
    print("|".join([
        r["id"], BUILDER[r["platform"]], " ".join(args),
        r["channels"]["cli"], r["plan_role"], r["channels"]["job"],
        r["job_token"]["IMAGE_TYPE"], r["job_token"]["HARDWARE_CLASS"],
        ",".join(r["job_token"]["accepted_image_types"]),
        # the axis values the builder must come back with for a cli=yes verdict —
        # without these the CLI leg would pass a phantom relabelled as buildable
        r["board"], r["flavor"], r["desktop"],
    ]))
PY

# ── leg 2: CLI — every recorded verdict re-proved against the real builder ─────────────
printf '== CLI — re-prove every image against its builder (--print-plan)\n'
PROBE_ROWS="$(grep -c . "${TMP_DIR}/probe.tsv" || true)"
WANT_ROWS="$("${PYTHON}" -c "import json,sys;print(json.load(open(sys.argv[1]))['image_count'])" "${INVENTORY}")"
# an empty/short probe table would make the row-count guards below vacuous — pin it to the
# committed inventory's own image_count before trusting anything derived from it
if [ "${PROBE_ROWS}" -ne "${WANT_ROWS}" ]; then
    echo "inventory-check: probe table has ${PROBE_ROWS} rows, inventory declares ${WANT_ROWS} images" >&2
    exit 2
fi
while IFS='|' read -r id builder args want_cli plan_role _j _t _h _a board flavor desktop; do
    [ -n "${id}" ] || continue
    # </dev/null: the builder must never eat probe.tsv rows off our loop's stdin
    # shellcheck disable=SC2086 — args is a pre-split flag list, word splitting is intended
    if bash "${REPO_DIR}/${builder}" ${args} --env test --print-plan \
            >"${TMP_DIR}/plan.out" 2>"${TMP_DIR}/plan.err" </dev/null; then
        got_role="$(sed -n 's/^PLAN_ROLE=//p' "${TMP_DIR}/plan.out" | head -1)"
        got_flavor="$(sed -n 's/^PLAN_FLAVOR=//p' "${TMP_DIR}/plan.out" | head -1)"
        got_board="$(sed -n 's/^PLAN_BOARD=//p' "${TMP_DIR}/plan.out" | head -1)"
        # PLAN_DESKTOP can carry a modifier suffix ("full+capable") — the BASE weight is
        # the axis value.
        got_desktop="$(sed -n 's/^PLAN_DESKTOP=//p' "${TMP_DIR}/plan.out" | head -1)"
        got_desktop="${got_desktop%%+*}"
        # Is every advertised axis honored? Empty PLAN_* counts as honored (the builder has
        # no such axis fact) — the same rule scripts/emit-image-inventory.py::plan_mismatch
        # applies, and rpi5 has no PLAN_BOARD contract (the board renames the artifact).
        honored=1
        [ -z "${flavor}" ] || [ -z "${got_flavor}" ] || [ "${got_flavor}" = "${flavor}" ] || honored=0
        [ -z "${desktop}" ] || [ -z "${got_desktop}" ] || [ "${got_desktop}" = "${desktop}" ] || honored=0
        if [ "${builder}" != build-rpi5-stage4.sh ]; then
            [ -z "${board}" ] || [ -z "${got_board}" ] || [ "${got_board}" = "${board}" ] || honored=0
        fi
        why=""
        [ "${got_role}" = "${plan_role}" ] || why="PLAN_ROLE=${got_role} (inventory: ${plan_role})"
        if [ "${want_cli}" = no ]; then
            # recorded as a PHANTOM: the builder ACCEPTS the argv but drops an advertised
            # axis. Re-prove exactly that — if every axis is suddenly honored the phantom
            # verdict is STALE and must be re-reviewed (the DRIFT leg will agree).
            if [ "${honored}" = 1 ]; then
                CLI_FAIL=$((CLI_FAIL + 1))
                _fail CLI "${id} — recorded as a phantom (cli=no) but the builder now HONORS every advertised axis; regenerate + re-review"
            else
                CLI_PASS=$((CLI_PASS + 1))
            fi
        elif [ -n "${why}" ] || [ "${honored}" = 0 ]; then
            # a cli=yes verdict CLAIMS the builder honors every advertised axis; re-prove
            # it, or a phantom relabelled "buildable" would sail through this leg
            [ "${honored}" = 1 ] || why="${why} axis not honored (PLAN_FLAVOR=${got_flavor} PLAN_DESKTOP=${got_desktop} PLAN_BOARD=${got_board})"
            CLI_FAIL=$((CLI_FAIL + 1))
            _fail CLI "${id} —${why}"
        else
            CLI_PASS=$((CLI_PASS + 1))
        fi
    else
        if [ "${want_cli}" = no ]; then
            CLI_PASS=$((CLI_PASS + 1))
        else
            CLI_FAIL=$((CLI_FAIL + 1))
            _fail CLI "${id} — inventory says cli=${want_cli} but ${builder} ${args} REJECTED it"
            tail -n 3 "${TMP_DIR}/plan.err" | sed 's/^/    | /' >&2
        fi
    fi
done <"${TMP_DIR}/probe.tsv"
if [ "$((CLI_PASS + CLI_FAIL))" -ne "${PROBE_ROWS}" ]; then
    CLI_FAIL=$((CLI_FAIL + 1))
    _fail CLI "probed $((CLI_PASS + CLI_FAIL - 1)) of ${PROBE_ROWS} images — the loop lost rows (a builder read our stdin?)"
fi

# ── leg 3: JOB — resolve_build_target, really executed ────────────────────────────────
printf '== JOB — re-prove every image against docker/build-image.sh resolve_build_target()\n'
"${PYTHON}" - "${REPO_DIR}/docker/build-image.sh" >"${TMP_DIR}/resolve.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index("\nresolve_build_target() {")
depth = 0
for i in range(start + 1, len(src)):
    if src[i] == "\n" and src[i + 1:i + 2] == "}" and depth == 1:
        sys.stdout.write(src[start + 1:i + 2]); break
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
else:
    sys.exit("could not extract resolve_build_target()")
PY
[ -s "${TMP_DIR}/resolve.sh" ] || { echo "inventory-check: resolve_build_target extraction failed" >&2; exit 2; }

# shellcheck source=/dev/null
(
    set -u
    PLATFORM=""; BUILD_ROLE=""; KEYS_ROLE=""
    RPI5_BOARD_OUT=""; JETSON_BOARD_OUT=""; FRITE_BOARD_OUT=""; FRITE_FLAVOR_OUT=""
    ORANGEPI5_BOARD_OUT=""; ORANGEPI5_FLAVOR_OUT=""; ORANGEPIZERO2_FLAVOR_OUT=""
    ORANGEPIZERO2W_FLAVOR_OUT=""; ORANGEPIZERO3_FLAVOR_OUT=""
    ORANGEPI3LTS_FLAVOR_OUT=""; ORANGEPI4LTS_FLAVOR_OUT=""
    # THE role vocabulary, sourced exactly as docker/build-image.sh sources it. The
    # extracted resolve_build_target() body CALLS hugmesh_role_for /
    # hugmesh_role_keyprofile; a probe that omitted them would see every row reject
    # and would report a total JOB-channel outage as if it were a real regression.
    # shellcheck source=scripts/_roles-lib.sh
    . "${REPO_DIR}/scripts/_roles-lib.sh"
    . "${TMP_DIR}/resolve.sh"
    # "|" IFS (see the probe.tsv emitter): tabs would collapse around empty fields.
    # 12 named vars so the trailing board/flavor/desktop columns can never bleed into
    # `accepted` via read's catch-all last variable.
    while IFS='|' read -r id _b _a _c _p want_job itype hwclass accepted _board _flavor _desktop; do
        [ -n "${id}" ] || continue
        IMAGE_TYPE="${itype}"; HARDWARE_CLASS="${hwclass}"
        PLATFORM=""; BUILD_ROLE=""
        if resolve_build_target 2>/dev/null; then natural_ok=1; else natural_ok=0; fi
        # The ARM standalone posture the resolver flipped (or didn't) for this row —
        # resolve_build_target defaults all eight *_STANDALONE vars false up front, so
        # after a successful resolve this is exactly the posture the assembled build
        # would carry.
        resolved_standalone=false
        case "${RPI5_STANDALONE}${FRITE_STANDALONE}${ORANGEPI5_STANDALONE}${ORANGEPIZERO2_STANDALONE}${ORANGEPIZERO2W_STANDALONE}${ORANGEPIZERO3_STANDALONE}${ORANGEPI3LTS_STANDALONE}${ORANGEPI4LTS_STANDALONE}" in
            *true*) resolved_standalone=true ;;
        esac
        case "${want_job}" in
            yes)           [ "${natural_ok}" = 1 ] && echo "JOB PASS ${id}" \
                             || echo "JOB FAIL ${id} — inventory says job=yes but IMAGE_TYPE=${itype} HARDWARE_CLASS=${hwclass} was REJECTED" ;;
            escape-hatch)  # natural type must be rejected AND some other type accepted
                           if [ "${natural_ok}" = 1 ]; then
                               echo "JOB FAIL ${id} — inventory says job=escape-hatch but the natural IMAGE_TYPE=${itype} RESOLVES"
                           elif [ -z "${accepted}" ]; then
                               echo "JOB FAIL ${id} — inventory says job=escape-hatch but no IMAGE_TYPE is recorded as accepted"
                           else
                               echo "JOB PASS ${id}"
                           fi ;;
            no)            # job=no is honest in TWO recorded shapes: the token is
                           # rejected outright, OR it resolves to a DIFFERENT image
                           # (today's class: an ARM standalone/... record whose token
                           # folds onto the mesh-affiliated image — the resolver
                           # accepts it but leaves every *_STANDALONE flag false).
                           # Re-prove whichever shape is recorded — a resolver that
                           # starts honoring the posture makes the verdict STALE and
                           # must fail loudly, mirroring the CLI leg's phantom branch.
                           if [ "${natural_ok}" = 0 ]; then
                               echo "JOB PASS ${id}"
                           else
                               case "${id}" in
                                   standalone/*)
                                       if [ "${resolved_standalone}" = "false" ]; then
                                           echo "JOB PASS ${id}"
                                       else
                                           echo "JOB FAIL ${id} — recorded job=no (posture dropped) but the resolver now HONORS the standalone posture; regenerate + re-review"
                                       fi ;;
                                   *)  echo "JOB FAIL ${id} — inventory says job=no but IMAGE_TYPE=${itype} HARDWARE_CLASS=${hwclass} RESOLVES to the same image" ;;
                               esac
                           fi ;;
            *)             echo "JOB FAIL ${id} — unknown recorded verdict '${want_job}'" ;;
        esac
    done <"${TMP_DIR}/probe.tsv"
) >"${TMP_DIR}/job.out" 2>"${TMP_DIR}/job.err"
JOB_PASS=$(grep -c '^JOB PASS' "${TMP_DIR}/job.out" || true)
JOB_FAIL=$(grep -c '^JOB FAIL' "${TMP_DIR}/job.out" || true)
grep '^JOB FAIL' "${TMP_DIR}/job.out" >&2 || true
# 0 pass + 0 fail = the subshell died before probing anything (a resolve.sh source error,
# say) — that must be a LOUD failure, never an empty green
if [ "$((JOB_PASS + JOB_FAIL))" -ne "${PROBE_ROWS}" ]; then
    JOB_FAIL=$((JOB_FAIL + 1))
    _fail JOB "probed $((JOB_PASS + JOB_FAIL - 1)) of ${PROBE_ROWS} images — the resolve subshell lost rows"
    tail -n 5 "${TMP_DIR}/job.err" | sed 's/^/    | /' >&2
fi

# ── legs 4+5: INV (hard invariants) and BASE (reviewed baseline) ──────────────────────
printf '== INV — hard invariants + BASE — reviewed gap/phantom baseline\n'
"${PYTHON}" - "${INVENTORY}" "${REPO_DIR}/tests/build-matrix/matrix.tsv" \
    >"${TMP_DIR}/inv.out" 2>&1 <<'PY'
import json, sys
inv = json.load(open(sys.argv[1], encoding="utf-8"))
imgs = inv["images"]

def ok(msg):   print(f"INV PASS {msg}")
def bad(msg):  print(f"INV FAIL {msg}")

# 1. every non-phantom advertised image must be CLI-buildable
broken = [r["id"] for r in imgs if not r["phantom"] and r["channels"]["cli"] != "yes"]
(ok if not broken else bad)(
    f"every non-phantom image is CLI-buildable ({len(imgs) - len(broken)}/"
    f"{len([r for r in imgs if not r['phantom']])})"
    + ("" if not broken else f" — NOT buildable: {', '.join(broken[:8])}"))

# 2. the Studio channels are the grammar's own source: they must reach 100%
for ch in ("gui", "worklist"):
    miss = [r["id"] for r in imgs if r["channels"][ch] != "yes"]
    (ok if not miss else bad)(
        f"{ch} expresses every advertised image ({len(imgs) - len(miss)}/{len(imgs)})"
        + ("" if not miss else f" — missing: {', '.join(miss[:8])}"))

# 3. no matrix.tsv cell may be missing from the inventory
(ok if not inv["undocumented"] else bad)(
    f"every matrix.tsv cell maps onto an inventory image "
    f"(undocumented={len(inv['undocumented'])})"
    + ("" if not inv["undocumented"] else f" — {', '.join(inv['undocumented'][:8])}"))

# 4. per-channel counts must agree with the per-image records (self-consistency)
for ch, counts in inv["per_channel_counts"].items():
    real = {"yes": 0, "escape-hatch": 0, "no": 0}
    for r in imgs:
        real[r["channels"][ch]] += 1
    (ok if real == counts else bad)(f"per_channel_counts[{ch}] matches the image records")

# 5. image_count must equal the number of records
(ok if inv["image_count"] == len(imgs) else bad)(
    f"image_count ({inv['image_count']}) == len(images) ({len(imgs)})")
PY
INV_RC=$?
INV_PASS=$(grep -c '^INV PASS' "${TMP_DIR}/inv.out" || true)
INV_FAIL=$(grep -c '^INV FAIL' "${TMP_DIR}/inv.out" || true)
grep '^INV FAIL' "${TMP_DIR}/inv.out" >&2 || true
# a python crash prints NEITHER marker — 0 pass + 0 fail must be a loud failure
if [ "${INV_RC}" -ne 0 ] || [ "$((INV_PASS + INV_FAIL))" -eq 0 ]; then
    INV_FAIL=$((INV_FAIL + 1))
    _fail INV "the invariant probe itself crashed (rc=${INV_RC})"
    tail -n 5 "${TMP_DIR}/inv.out" | sed 's/^/    | /' >&2
fi

# The REVIEWED baseline. These are the numbers a human signed off on; a change in either
# direction is a real event that must be re-reviewed (raise = a new hole, lower = a fix
# worth recording). Update BOTH numbers in the same commit as the change that moves them.
#
# PHANTOMS re-baselined 16 -> 0 (desktop-axis-honesty): the 16 split three ways —
#   (A) 12 x86 cluster-node entries (be/fe/pki/omnibus/edge_ai/be+gpu x thin|full):
#       a headless k8s server has no desktop (builder plans DESKTOP=none); the catalog
#       grammar wrongly advertised a desktop axis for node roles — PRUNED (the six
#       roles now carry one honest desktop-less record each);
#   (B) 3 weight-pinning standalone entries (standalone-thin/full,
#       standalone-thick/thin, standalone-unaffiliated/thin): the weight is IN THE
#       ROLE NAME, so these were contradictions in terms — PRUNED, and the builder
#       now hard-errors a contradictory explicit --desktop instead of silently
#       overriding it;
#   (C) 1 REAL BUG (cloud/x86/desktop/thin): the desktop role's full-weight default
#       silently upgraded an explicit --desktop thin — FIXED via DESKTOP_SET
#       explicitness tracking; the entry is KEPT and is now cli=yes.
# GAPS re-baselined 61 -> 62: the newly-real cloud/x86/desktop/thin is expressible
# from cli/gui/worklist/job but make/menu have no first-class --desktop thin
# selection (make: STANDALONE_FLAGS escape hatch; menu: no x86 desktop picker) —
# an honest, reviewed gap, not a regression.
#
# GAPS re-baselined 62 -> 68 (2026-08-27, the one-role-vocabulary branch). NOT six
# new gaps: six gaps that the COMMITTED inventory had gone stale about. This suite's
# own DRIFT leg was RED on origin/main — docs/catalog/image-inventory.json no longer
# matched what the emitter produces — so the 62 was describing an older tree.
# MEASURED, three ways, before touching this number:
#   * regenerate the inventory on UNMODIFIED origin/main  -> 68 gaps
#   * regenerate it on this branch                        -> 68 gaps
#   * diff the two gap ID SETS                            -> identical, 0 either way
# The six the stale file was hiding are the mesh-mode person-desktop rows
#   mesh/x86/{laptop,chromebook,desktop}/{thin,full}
# (a mesh-attached person device has no first-class thin/full desktop selection in
# make or the menu — the same honest gap (C) above already records for cloud mode).
# Written down rather than papered over: a wrong baseline reads as reviewed and stops
# anyone looking, which is exactly how the 62 survived.
BASELINE_GAPS=68
BASELINE_PHANTOMS=0
GOT_GAPS="$("${PYTHON}" -c "import json,sys;print(len(json.load(open(sys.argv[1]))['channel_gaps']))" "${INVENTORY}")"
GOT_PHANTOMS="$("${PYTHON}" -c "import json,sys;print(len(json.load(open(sys.argv[1]))['phantoms']))" "${INVENTORY}")"
if [ "${GOT_GAPS}" = "${BASELINE_GAPS}" ]; then
    BASE_PASS=$((BASE_PASS + 1))
else
    BASE_FAIL=$((BASE_FAIL + 1))
    _fail BASE "channel_gaps=${GOT_GAPS}, reviewed baseline is ${BASELINE_GAPS} — a channel gap was $([ "${GOT_GAPS}" -gt "${BASELINE_GAPS}" ] && echo OPENED || echo closed); review docs/IMAGE-INVENTORY.md and update BASELINE_GAPS"
fi
if [ "${GOT_PHANTOMS}" = "${BASELINE_PHANTOMS}" ]; then
    BASE_PASS=$((BASE_PASS + 1))
else
    BASE_FAIL=$((BASE_FAIL + 1))
    _fail BASE "phantoms=${GOT_PHANTOMS}, reviewed baseline is ${BASELINE_PHANTOMS} — update BASELINE_PHANTOMS with the review"
fi

# ── summary ───────────────────────────────────────────────────────────────────────────
TOTAL_FAIL=$((DRIFT_FAIL + CLI_FAIL + JOB_FAIL + INV_FAIL + BASE_FAIL))
TOTAL_PASS=$((DRIFT_PASS + CLI_PASS + JOB_PASS + INV_PASS + BASE_PASS))
printf '\n──────────── inventory-check summary ────────────\n'
printf 'DRIFT (regenerate + diff):  %3d passed, %d failed\n' "${DRIFT_PASS}" "${DRIFT_FAIL}"
printf 'CLI   (builder --print-plan):%3d passed, %d failed\n' "${CLI_PASS}" "${CLI_FAIL}"
printf 'JOB   (resolve_build_target):%3d passed, %d failed\n' "${JOB_PASS}" "${JOB_FAIL}"
printf 'INV   (hard invariants):    %3d passed, %d failed\n' "${INV_PASS}" "${INV_FAIL}"
printf 'BASE  (reviewed baseline):  %3d passed, %d failed\n' "${BASE_PASS}" "${BASE_FAIL}"
printf 'TOTAL:                      %3d passed, %d failed\n' "${TOTAL_PASS}" "${TOTAL_FAIL}"
if [ "${TOTAL_FAIL}" -eq 0 ]; then
    printf '\nALL CHANNELS AGREE WITH THE COMMITTED INVENTORY (%s images)\n' \
        "$("${PYTHON}" -c "import json,sys;print(json.load(open(sys.argv[1]))['image_count'])" "${INVENTORY}")"
    exit 0
fi
printf '\nINVENTORY / CHANNEL DISAGREEMENT — see the FAIL lines above.\n' >&2
exit 1
