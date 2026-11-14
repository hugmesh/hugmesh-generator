#!/usr/bin/env bash
# test-x86-from-step.sh — guards `build-x86-host-stage4.sh --resume --from-step STEP`,
# the rerun of a build from one of its late steps (package-stage4, image-raw,
# image-live, image-installer) that the Studio's per-step rerun control dispatches.
#
# A rerun skips one region of the builder: every step that changes the sysroot, from
# the stage3 extraction to the label pass. What it must still have is checked here:
#
#   1. NOTHING THE LATE STEPS NEED LIVES ONLY IN THE SKIPPED REGION. Every variable a
#      late step reads and every function it calls is set or defined before the
#      region (or in the late steps themselves). A name that moves back into the
#      region would be unset on a rerun (set -u kills it mid-ISO). The analysis is
#      mutation-tested below: a late read of a region-only name must be caught.
#   2. THE STAMP AND THE EVIDENCE. late_entry_build_ts is executed against fixture
#      trees: the late-step record wins; a build from before the record is accepted
#      on its lock's stamp only with that run's stage4; anything else is refused.
#   3. STEP ORDER. late_step_runs follows X86_LATE_STEPS, and those ids are the
#      Studio's x86 progress-table ids, in the same order.
#   4. ARGUMENTS. A bad step, a missing --resume and a bare --from-step are refused
#      (run through --print-plan: no root, no work dir).
#   5. THE GUARDS. Each late step runs under late_step_runs and records done=<step>;
#      the record is written at the end of the region and removed at a full run's start.
#
# What only a real build can show: the late steps themselves running as root on a
# kept sysroot (they need chroot, loop devices and mounts).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILDER="${REPO}/build-x86-host-stage4.sh"
TABLES="${REPO}/studio/hugmesh_studio/core/progress-tables.json"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

echo "== x86 --from-step guards =="

# ── 1. dependency analysis ───────────────────────────────────────────────────
echo "-- 1) late steps need nothing only the skipped region sets --"
START='if [ -z "${FROM_STEP}" ]; then'
END='fi   # ── end of the skippable region ──'
# split <builder> <outdir> — pre / region / late, by the two marker lines
split_builder() {
    local b="$1" d="$2" a z n
    a="$(grep -nxF -- "${START}" "${b}" | cut -d: -f1)"
    z="$(grep -nxF -- "${END}" "${b}" | cut -d: -f1)"
    [ "$(grep -cxF -- "${START}" "${b}")" = 1 ] && [ "$(grep -cxF -- "${END}" "${b}")" = 1 ] || return 1
    [ -n "${a}" ] && [ -n "${z}" ] && [ "${a}" -lt "${z}" ] || return 1
    n="$(wc -l < "${b}")"
    mkdir -p "${d}"
    sed -n "1,$((a - 1))p" "${b}" > "${d}/pre"
    sed -n "$((a + 1)),$((z - 1))p" "${b}" > "${d}/mid"
    sed -n "$((z + 1)),${n}p" "${b}" > "${d}/late"
}
# names assigned anywhere in a file (VAR=, VAR+=, local/export/declare VAR=, VAR[i]=)
assigned() {
    grep -oE '(^|[[:space:];&|({])(export |local |readonly |declare( -[a-zA-Z]+)? )?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=' "$1" \
        | sed -E 's/^[[:space:];&|({]*//; s/^(export|local|readonly|declare( -[a-zA-Z]+)?) //; s/(\[.*)?\+?=$//' | sort -u
}
read_vars() { grep -oE '\$\{?#?!?[A-Za-z_][A-Za-z0-9_]*' "$1" | sed -E 's/^\$\{?#?!?//' | sort -u; }
defined_fns() { cat "$@" | grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{' | sed 's/().*//' | sort -u; }
words() { grep -oE '\b[a-zA-Z_][a-zA-Z0-9_]*\b' "$@" | sort -u; }
# region_only <dir> — "var:NAME" / "fn:NAME" for every region-only dependency of pre+late
region_only() {
    local d="$1"
    assigned "${d}/pre" > "${d}/a_pre"; assigned "${d}/mid" > "${d}/a_mid"; assigned "${d}/late" > "${d}/a_late"
    cat "${d}/pre" "${d}/late" > "${d}/out"
    read_vars "${d}/out" > "${d}/r_out"
    sort -u "${d}/a_pre" "${d}/a_late" > "${d}/a_out"
    comm -23 "${d}/r_out" "${d}/a_out" | comm -12 - "${d}/a_mid" | sed 's/^/var:/'
    defined_fns "${d}/mid" > "${d}/f_mid"; defined_fns "${d}/pre" "${d}/late" > "${d}/f_out"
    words "${d}/out" > "${d}/w_out"
    comm -12 "${d}/f_mid" "${d}/w_out" | comm -23 - "${d}/f_out" | sed 's/^/fn:/'
}
if split_builder "${BUILDER}" "${TMPD}/real"; then
    ok "the skippable region is marked exactly once (start and end)"
    deps="$(region_only "${TMPD}/real")"
    [ -z "${deps}" ] && ok "no late step (and no earlier code) reads a variable or calls a function only the skipped region sets" \
        || bad "late steps depend on the skipped region — move these ahead of it: $(tr '\n' ' ' <<<"${deps}")"
    # Mutation: a late read of a region-only variable and a call of a region-only
    # function (both real names from the region) must each be caught.
    mv="$(comm -23 "${TMPD}/real/a_mid" <(sort -u "${TMPD}/real/a_pre" "${TMPD}/real/a_late") | grep -E '^[A-Z][A-Z0-9_]{3,}$' | head -1)"
    mf="$(comm -23 "${TMPD}/real/f_mid" "${TMPD}/real/f_out" | head -1)"
    if [ -n "${mv}" ] && [ -n "${mf}" ]; then
        cp "${BUILDER}" "${TMPD}/mut.sh"
        printf 'echo "${%s}"\n%s\n' "${mv}" "${mf}" >> "${TMPD}/mut.sh"
        split_builder "${TMPD}/mut.sh" "${TMPD}/mut" && mdeps="$(region_only "${TMPD}/mut")"
        grep -qx "var:${mv}" <<<"${mdeps:-}" && grep -qx "fn:${mf}" <<<"${mdeps:-}" \
            && ok "mutation: a late read of \${${mv}} and a call of ${mf}() (both region-only) are caught" \
            || bad "mutation NOT caught: late \${${mv}} / ${mf}() -> '${mdeps:-}'"
    else
        bad "could not pick a region-only variable and function for the mutation check"
    fi
else
    bad "the skippable region's markers are missing or duplicated ('${START}' / '${END}')"
fi

# ── 2. stamp + evidence, executed ────────────────────────────────────────────
echo "-- 2) late_entry_build_ts and late_step_runs, executed --"
fx() { awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "${BUILDER}"; }
{
    echo 'err(){ echo "ERROR: $*" >&2; }'
    echo 'LATE_STATE="${BUILD_ROOT}/late-steps.state"'
    grep -E '^late_state_get\(\)' "${BUILDER}"
    grep -E '^late_step_done\(\)' "${BUILDER}"
    grep -E '^late_kept\(\)' "${BUILDER}"
    fx late_entry_build_ts
    fx late_step_runs
    fx late_entry_kept_check
    awk '/^X86_LATE_STEPS=\(/{print; exit}' "${BUILDER}"
    echo 'info(){ :; }'
    echo 'case "$1" in ts) late_entry_build_ts ;; runs) late_step_runs "$2" ;; kept) BUILD_TS="$2"; late_entry_kept_check ;; esac'
} > "${TMPD}/fns.sh"
for f in late_state_get late_entry_build_ts late_step_runs late_step_done late_kept late_entry_kept_check; do
    grep -q "^${f}()" "${TMPD}/fns.sh" || bad "could not extract ${f}() from the builder"
done
W="${TMPD}/w"; BR="${W}/wl-x"; S4P="${W}/gentoo-x86-amd64-standalone-unaffiliated-prod"
reset_tree() { rm -rf "${W}"; mkdir -p "${BR}"; }
ts_of() { # $1 = FROM_STEP — prints the stamp (rc 0) or the refusal (rc 1)
    env -i PATH="${PATH}" WORK_DIR="${W}" BUILD_ROOT="${BR}" BRAND=gentoo ROLE_TAG=standalone-unaffiliated \
        ENV=prod FROM_STEP="$1" bash "${TMPD}/fns.sh" ts 2>&1
}
T1=20990101T000000Z; T2=20990102T000000Z
reset_tree
out="$(ts_of image-live)" && bad "a tree with no record and no lock was continued: ${out}" \
    || { case "${out}" in *"holds no earlier run"*) ok "no record, no lock: refused, and says so" ;; *) bad "no-record refusal reads wrong: ${out}" ;; esac; }
printf 'pid=1 build_ts=%s role=x work_dir=%s started=x\n' "${T1}" "${W}" > "${BR}.lock"
out="$(ts_of image-live)" && bad "legacy lock without its stage4 was continued: ${out}" \
    || { case "${out}" in *"never got past its last sysroot change"*) ok "legacy lock without that run's stage4: refused (the run never finished its sysroot)" ;; *) bad "legacy refusal reads wrong: ${out}" ;; esac; }
echo x > "${S4P}-${T1}.stage4.tar.xz"
out="$(ts_of image-live)" && [ "${out}" = "${T1}" ] && ok "legacy build: lock stamp + that run's stage4 -> continues ${T1}" || bad "legacy build not continued: ${out}"
out="$(ts_of package-stage4)" && [ "${out}" = "${T1}" ] && ok "legacy build from package-stage4: continues ${T1}" || bad "legacy package-stage4: ${out}"
# a newer run started (lock rewritten) but died before its stage4: the old stage4 must not authorise it
printf 'pid=2 build_ts=%s role=x work_dir=%s started=x\n' "${T2}" "${W}" > "${BR}.lock"
out="$(ts_of image-live)" && bad "a newer run that died early was continued on an OLDER run's stage4: ${out}" \
    || ok "a newer run that died before its stage4 is refused (the older stage4 does not count)"
printf 'pid=3 build_ts=../../etc role=x\n' > "${BR}.lock"
out="$(ts_of image-live)" && bad "a malformed stamp was accepted: ${out}" || ok "a malformed stamp in the lock is refused"
# the record wins over the lock
reset_tree; printf 'pid=1 build_ts=%s\n' "${T1}" > "${BR}.lock"; echo x > "${S4P}-${T1}.stage4.tar.xz"
printf 'BUILD_TS=%s\nKCACHE_HIT=true\n' "${T2}" > "${BR}/late-steps.state"
out="$(ts_of package-stage4)" && [ "${out}" = "${T2}" ] && ok "the late-step record's stamp wins; package-stage4 needs no earlier stage4" || bad "record not used for package-stage4: ${out}"
out="$(ts_of image-live)" && bad "image-live continued with no stage4 for the recorded run: ${out}" \
    || ok "from image-live the recorded run's stage4 must exist (the installer ISO and the kept artifacts need it)"
echo x > "${S4P}-${T2}.stage4.tar.xz"
out="$(ts_of image-installer)" && [ "${out}" = "${T2}" ] && ok "record + its stage4: image-installer continues ${T2}" || bad "record run not continued: ${out}"
# every KEPT step must have finished in the earlier run
kept() { # $1 = FROM_STEP, $2 = BUILD_IMG, $3 = LIVE_ISO — prints the refusal (rc 1) or nothing
    env -i PATH="${PATH}" WORK_DIR="${W}" BUILD_ROOT="${BR}" BRAND=gentoo ROLE_TAG=standalone-unaffiliated \
        ENV=prod FROM_STEP="$1" BUILD_IMG="$2" LIVE_ISO="$3" bash "${TMPD}/fns.sh" kept "${T2}" 2>&1
}
reset_tree; echo x | xz > "${S4P}-${T2}.stage4.tar.xz"; echo i > "${S4P}-${T2}.img.xz"
printf 'BUILD_TS=%s\nKCACHE_HIT=false\ndone=package-stage4\ndone=image-raw\n' "${T2}" > "${BR}/late-steps.state"
out="$(kept image-live true true)" && ok "record: stage4 + .img done -> a rerun from image-live keeps them" || bad "record with both steps done refused: ${out}"
printf 'BUILD_TS=%s\nKCACHE_HIT=false\ndone=package-stage4\n' "${T2}" > "${BR}/late-steps.state"
out="$(kept image-live true true)" && bad "a rerun kept an .img step the record says never finished" \
    || { case "${out}" in *"never finished: image-raw"*) ok "record without done=image-raw: refused, naming image-raw (the .img file alone does not count)" ;; *) bad "missing image-raw refused wrongly: ${out}" ;; esac; }
out="$(kept image-live false true)" && ok "with --no-img the .img step is not required" || bad "--no-img rerun refused: ${out}"
out="$(kept package-stage4 true true)" && ok "from package-stage4 nothing is kept, nothing required" || bad "package-stage4 rerun refused: ${out}"
printf 'BUILD_TS=%s\nKCACHE_HIT=false\nLEGACY=1\n' "${T2}" > "${BR}/late-steps.state"
out="$(kept image-live true true)" && ok "a record a legacy rerun started (LEGACY=1): the earlier run's artifacts count" || bad "legacy record refused with artifacts present: ${out}"
rm -f "${S4P}-${T2}.img.xz"
out="$(kept image-live true true)" && bad "legacy: a rerun kept an .img that does not exist" \
    || ok "legacy: a missing .img is refused (no green rerun with an artifact missing)"
echo i > "${S4P}-${T2}.img.xz"; echo "not xz" > "${S4P}-${T2}.stage4.tar.xz"
out="$(kept image-installer true false)" && bad "a damaged kept stage4 was accepted" \
    || { case "${out}" in *"is damaged"*) ok "a kept stage4 that does not read whole (xz -t) is refused" ;; *) bad "damaged stage4 refused wrongly: ${out}" ;; esac; }
# step order
runs() { env -i PATH="${PATH}" FROM_STEP="$1" bash "${TMPD}/fns.sh" runs "$2"; }
exp_ok=true
for pair in ":package-stage4:0" ":image-installer:0" "image-live:package-stage4:1" "image-live:image-raw:1" \
            "image-live:image-live:0" "image-live:image-installer:0" "package-stage4:image-raw:0" \
            "image-installer:image-live:1" "image-raw:image-raw:0" "image-raw:package-stage4:1"; do
    IFS=: read -r from step want <<<"${pair}"
    runs "${from}" "${step}"; got=$?
    [ "${got}" = "${want}" ] || { exp_ok=false; bad "late_step_runs: from '${from:-<none>}' step ${step} -> rc ${got}, want ${want}"; }
done
${exp_ok} && ok "late_step_runs: every step without --from-step; from STEP, that step and the ones after it only"

# ── 3. ids = the Studio's progress-table ids, same order ────────────────────
echo "-- 3) X86_LATE_STEPS are the Studio's x86 phase ids, in order --"
late_ids="$(awk '/^X86_LATE_STEPS=\(/{sub(/^X86_LATE_STEPS=\(/,""); sub(/\).*/,""); print; exit}' "${BUILDER}")"
if command -v python3 >/dev/null; then
    tab_ids="$(python3 -c 'import json,sys; print(" ".join(p["id"] for p in json.load(open(sys.argv[1]))["platforms"]["x86"]["phases"]))' "${TABLES}")"
    sub="$(python3 -c 'import sys; t=sys.argv[1].split(); l=sys.argv[2].split(); i=[t.index(x) if x in t else -1 for x in l]; print("ok" if l and -1 not in i and i==sorted(i) and l==t[-len(l):] else "no")' "${tab_ids}" "${late_ids}")"
    [ "${sub}" = ok ] && ok "X86_LATE_STEPS (${late_ids}) are the last x86 phases of the progress table, in order" \
        || bad "X86_LATE_STEPS (${late_ids}) do not match the tail of the x86 progress table (${tab_ids})"
else
    bad "python3 missing — cannot read the progress table"
fi

# ── 4. arguments ─────────────────────────────────────────────────────────────
echo "-- 4) --from-step arguments (via --print-plan: no root, no work dir) --"
plan() { (cd "${TMPD}" && timeout 120 bash "${BUILDER}" --role standalone-unaffiliated --print-plan "$@" 2>&1); }
out="$(plan --resume --from-step bogus)" && bad "--from-step bogus accepted" \
    || { case "${out}" in *"--from-step must be one of"*) ok "an unknown step is refused, with the list" ;; *) bad "unknown step refused wrongly: ${out: -200}" ;; esac; }
out="$(plan --from-step image-live)" && bad "--from-step without --resume accepted" \
    || { case "${out}" in *"--from-step needs --resume"*) ok "--from-step without --resume is refused" ;; *) bad "no-resume refusal wrong: ${out: -200}" ;; esac; }
out="$(plan --resume --from-step)" && bad "a bare --from-step accepted" \
    || { case "${out}" in *"--from-step needs a STEP"*) ok "a bare --from-step is refused" ;; *) bad "bare refusal wrong: ${out: -200}" ;; esac; }
out="$(plan --resume --from-step image-live)" && ok "--resume --from-step image-live passes argument validation" \
    || bad "--resume --from-step image-live refused at plan time: ${out: -300}"

# ── 5. the guards in the late steps ──────────────────────────────────────────
echo "-- 5) each late step is guarded and recorded --"
late="${TMPD}/real/late"
for st in package-stage4 image-raw image-live; do
    grep -qE "late_step_runs ${st}" "${late}" && ok "${st} runs under late_step_runs" || bad "${st} has no late_step_runs guard"
done
for st in package-stage4 image-raw image-live image-installer; do
    grep -qE "late_step_done ${st}" "${late}" && ok "${st} records done=${st}" || bad "${st} is never recorded as done"
done
mid="${TMPD}/real/mid"
tail -5 "${mid}" | grep -F 'printf '"'"'BUILD_TS=%s\nKCACHE_HIT=%s\n'"'"' "${BUILD_TS}"' >/dev/null \
    && ok "the late-step record is written as the region's last statement (the sysroot is final there)" \
    || bad "the late-step record is not written at the end of the skippable region"
pre="${TMPD}/real/pre"
awk '/^    banner "Rerunning from step /{f=1} f&&/^else$/{e=1} e&&/^fi$/{exit} e&&/^    rm -f "\$\{LATE_STATE\}"$/{print "hit"; exit}' "${pre}" | grep -x hit >/dev/null \
    && ok "a full run removes the old record before it changes anything" \
    || bad "a full run does not remove an old late-step record first (a run that dies early would leave a stale one)"
# The extraction block (owner gate on its --resume branch) stays BEFORE the region, so
# a rerun — always --resume — passes the same ownership gate and extracts nothing.
grep -qxF 'if [ -f "${SYSROOT}/etc/gentoo-release" ] && ${RESUME}; then' "${pre}" \
    && grep -qE '^    hmr_owner_gate "\$\{SYSROOT\}" \|\| exit 1$' "${pre}" \
    && ok "a rerun passes the extraction block's --resume owner gate (it sits before the skipped region)" \
    || bad "the extraction block (and its owner gate) is no longer ahead of the skipped region"

# the live step writes boot/initramfs-live.img into the sysroot; a rerun that repacks
# the stage4 or the .img must drop it first (a full run packs both before it exists)
awk '/^    banner "Rerunning from step /{f=1} f&&/^else$/{exit} f' "${pre}" > "${TMPD}/entry.sh"
grep -F 'if late_step_runs package-stage4 || late_step_runs image-raw; then' "${TMPD}/entry.sh" >/dev/null \
    && grep -F 'rm -f "${SYSROOT}/boot/initramfs-live.img"' "${TMPD}/entry.sh" >/dev/null \
    && ok "a rerun from package-stage4 or image-raw removes the earlier live step's initramfs-live.img" \
    || bad "a rerun that repacks the stage4/.img would carry the live step's initramfs-live.img"
grep -F 'late_entry_kept_check || exit 1' "${TMPD}/entry.sh" >/dev/null \
    && ok "a rerun checks every kept step before anything runs" || bad "the rerun entry never calls late_entry_kept_check"

echo
echo "x86 --from-step guards: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
