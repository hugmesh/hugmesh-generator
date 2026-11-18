#!/usr/bin/env bash
# test-x86-build-sudoers-strip.sh — the x86 builder's build-only sudoers grant never
# reaches a packed sysroot, whatever --skip-clean is set to, and a failed build does
# not leave it behind.
#
# THE GRANT. build-x86-host-stage4.sh writes etc/sudoers.d/build-notty
# (`Defaults !requiretty` + `portage ALL=(ALL) NOPASSWD: ALL`) into the sysroot and
# patches etc/sudoers (requiretty off, an includedir line marked `# build-added`), so
# portage's pkg_postinst can sudo without a tty. In an image that line makes anything
# running as portage (an on-device emerge, an ebuild phase on a CACHED image) root.
#
# WHAT WAS WRONG (NEW-14, 2026-11-11). The removal sat inside `if ! ${SKIP_CLEAN}`;
# the else branch only printed a banner. Every image built with --skip-clean (which
# the Studio offers on every platform) shipped the grant, and a build that failed
# left it in the sysroot a later run could reuse.
#
# HOW. The builder's own text is extracted and EXECUTED against a fixture sysroot,
# with only the commands that need root, a chroot or the SELinux toolchain stubbed:
#   A. the grant write, the chroot-phase EXIT trap and the Clean phase up to the
#      stage4 banner, for SKIP_CLEAN=false and true: the run completes and the
#      sysroot carries no drop-in, no portage NOPASSWD line, no build-added
#      includedir, and requiretty is back (checked by this file, not by the gate);
#   B. failed builds: the write then exit 1 (before the chroot phase), the write and
#      the chroot-phase trap then a failing command, the same killed by SIGTERM, and
#      an exit from the Clean phase's binpkgs-mountpoint refusal;
#   C. build_sudoers_gate against planted variants (and a clean sysroot it must pass);
#   D. a grant re-planted AFTER the strip, by a later step, stops the run before the
#      stage4 banner;
#   E. structure: every pack site that reads ${SYSROOT} follows a fatal gate call
#      with no chroot between them; no other builder writes the grant; the
#      --skip-clean help says the grant is removed regardless;
#   F. mutations of the builder, each of which must turn this suite red (skipped in
#      the child runs it makes; SUDOERS_GUARD_BUILDER points a run at a mutant).
# No root, no network, no chroot. Wired into the debian leg (python:3.12-slim: GNU sed
# and grep, mawk) and .gitlab-ci.yml's job that runs the other x86 pack suites.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILDER="${SUDOERS_GUARD_BUILDER:-${REPO}/build-x86-host-stage4.sh}"
CHILD="${SUDOERS_GUARD_CHILD:-0}"
# shellcheck source=../lib/guard-preflight.sh
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools awk sed grep mktemp cmp timeout

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/sudoers-strip.XXXXXX")"
TMPD="$(cd "${TMPD}" && pwd -P)"
trap '[ -n "${KEEP_TMPD:-}" ] || rm -rf "${TMPD}"' EXIT
[ -f "${BUILDER}" ] || { echo "  FAIL builder not found: ${BUILDER}"; echo "== 0 passed, 1 failed =="; exit 1; }

echo "== x86 build-only sudoers grant: stripped on every path, gated before every pack =="
echo "   builder: ${BUILDER#"${REPO}/"}"

# ── Extraction ───────────────────────────────────────────────────────────────
# The two helpers (absent on a builder from before the fix: empty files, and the
# legs that need them go red on their own).
for fn in build_sudoers_strip build_sudoers_gate; do
    awk -v re="^${fn}\\\\(\\\\) \\\\{\$" '$0 ~ re {f=1} f {print} f && /^\}$/ {exit}' "${BUILDER}" > "${TMPD}/${fn}.sh"
done
cat "${TMPD}/build_sudoers_strip.sh" "${TMPD}/build_sudoers_gate.sh" > "${TMPD}/funcs.sh"
# The Clean phase calls the lib's slx_ship_bootpath_files (/srv + the portage-tmpdir
# mask) where the builder used to ship them inline: the REAL function and its two
# message helpers, so the shared-specs mask below is what it installs.
awk '/^_slx_(say|fail)\(\)/ {print} /^slx_ship_bootpath_files\(\) \{$/ {f=1} f {print} f && /^\}$/ {f=0}' \
    "${REPO}/scripts/_selinux-policy-lib.sh" >> "${TMPD}/funcs.sh"
# The grant write: from its comment to the next phase header (exclusive).
awk '/^# Portage pkg_postinst calls sudo internally/ {f=1}
     f && /^# ── 4\. Install spec files/ {exit}
     f {print}' "${BUILDER}" > "${TMPD}/write.sh"
# The chroot phase's EXIT trap: the first col-0 `trap` after umount_chroot's body.
# (the first top-level trap after umount_chroot() that names it: the definition moved
# ahead of the --from-step region, the chroot phase's trap did not)
awk '/^umount_chroot\(\) \{$/ {u=1} u && /^\}$/ {d=1; next} d && /^trap .*umount_chroot/ {print; exit}' \
    "${BUILDER}" > "${TMPD}/chroot-trap.sh"
# The Clean phase and everything after it up to the stage4 banner (exclusive). The two
# --from-step plumbing lines at the end of the skippable region (the late-step record
# and the region's closing `fi`; tests/scripts/test-x86-from-step.sh owns them) are left
# out: this fixture runs the Clean phase alone, outside that region.
awk '/^# ── 8\. Clean/ {f=1}
     f && /^banner "Packaging stage4 tarball"$/ {exit}
     f && /^fi   # ── end of the skippable region ──$/ {next}
     f && /^printf .BUILD_TS=%s.*> "\$\{LATE_STATE\}"$/ {next}
     f {print}' "${BUILDER}" > "${TMPD}/clean.sh"

echo "-- 0) extraction --"
grep -a -F 'sudoers.d/build-notty' "${TMPD}/write.sh" >/dev/null \
    && ok "grant write extracted ($(wc -l < "${TMPD}/write.sh") lines)" \
    || bad "could not extract the grant write (# Portage pkg_postinst ... -> # ── 4. Install spec files)"
grep -a -E 'umount_chroot' "${TMPD}/chroot-trap.sh" >/dev/null \
    && ok "chroot-phase EXIT trap extracted: $(cat "${TMPD}/chroot-trap.sh")" \
    || bad "could not extract the chroot-phase EXIT trap after umount_chroot()"
if grep -a -F 'if ! ${SKIP_CLEAN}; then' "${TMPD}/clean.sh" >/dev/null \
   && grep -a -x -F 'umount_chroot; trap - EXIT' "${TMPD}/clean.sh" >/dev/null; then
    ok "Clean phase extracted ($(wc -l < "${TMPD}/clean.sh") lines, through to the stage4 banner)"
else
    bad "could not extract the Clean phase (# ── 8. Clean -> banner \"Packaging stage4 tarball\")"
fi
for fn in build_sudoers_strip build_sudoers_gate; do
    [ -s "${TMPD}/${fn}.sh" ] && ok "${fn}() extracted" || bad "${fn}() is not defined in the builder"
done

# ── Fixture + runner ─────────────────────────────────────────────────────────
# mkfix DIR — a sysroot the way the stage3 leaves it: requiretty on, NO includedir
# (so the write appends its build-added one), one legitimate drop-in that must survive.
mkfix() {
    local d="$1"
    rm -rf "${d}"
    mkdir -p "${d}/etc/sudoers.d" "${d}/var/log" "${d}/var/cache/binpkgs" "${d}/var/tmp" "${d}/tmp" \
             "${d}/usr/share/doc/pkg" "${d}/usr/share/locale/en" "${d}/usr/lib/locale" "${d}/usr/lib64" "${d}/lib/firmware" \
             "${d}/usr/bin" "${d}/usr/sbin" "${d}/lib64" "${d}/lib/modules"
    printf 'root ALL=(ALL:ALL) ALL\nDefaults requiretty\n' > "${d}/etc/sudoers"
    chmod 0640 "${d}/etc/sudoers"
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > "${d}/etc/sudoers.d/wheel"
    echo doc > "${d}/usr/share/doc/pkg/README"
}
SS="${TMPD}/shared-specs"; mkdir -p "${SS}/etc/tmpfiles.d"; echo '# masked' > "${SS}/etc/tmpfiles.d/portage-tmpdir.conf"

# The stubs: what needs root, a chroot, mounts or the SELinux toolchain. Nothing
# that touches the sudoers files is stubbed.
cat > "${TMPD}/stubs.sh" <<'EOF'
banner(){ echo "==> $*"; }; info(){ echo "    $*"; }; warn(){ echo "    WARNING: $*"; }; err(){ echo "    ERROR: $*" >&2; }
umount_chroot(){ :; }
mountpoint(){ case "${2:-}" in */var/cache/binpkgs) [ "${STUB_BINPKGS_MOUNTED:-0}" = 1 ] ;; *) return 1 ;; esac; }
hmr_stale_mounts(){ :; }; hmr_stale_mount_hint(){ :; }; hmr_canon(){ printf '%s\n' "$1"; }
strip(){ :; }; chroot(){ :; }
desktop_sso_verify(){ return 0; }; slx_stage_node_policy(){ return 0; }; pcs_unquiet_sendfile_noise(){ return 0; }
slx_policy_type(){ echo targeted; }
slx_store_install_modules(){ return 0; }; slx_map_root_login(){ return 0; }; slx_write_selinux_config(){ return 0; }
slx_write_probe_table(){ return 0; }; slx_label_gate(){ return 0; }
# The sysroot label pass runs after the Clean phase's strip and before the stage4
# banner: leg D re-plants a grant here, as a later step could.
slx_label_tree(){
    case "${STUB_REPLANT:-}" in
        dropin) printf 'Defaults !requiretty\nportage ALL=(ALL) NOPASSWD: ALL\n' > "${SYSROOT}/etc/sudoers.d/build-notty" ;;
        other)  printf 'portage ALL=(ALL) NOPASSWD: ALL\n' > "${SYSROOT}/etc/sudoers.d/zz-late" ;;
    esac
    return 0
}
EOF

# flow NAME SKIP_CLEAN PARTS... — one bash process, the builder's shell options, the
# named extracted parts in order. A part is a file under TMPD or a literal `@cmd`.
flow() {
    local name="$1" skip="$2" sr="${TMPD}/sr-$1"; shift 2
    mkfix "${sr}"
    {
        echo 'set -euo pipefail'
        printf "SYSROOT='%s'; BUILD_ROOT='%s'; SHARED_SPECS='%s'; SKIP_CLEAN=%s\n" "${sr}" "${TMPD}/br" "${SS}" "${skip}"
        echo 'ISO_CACHED=false; X86_POOL_DIR=""; ROLE_CLIENT=false; GPU=false; UNAFFILIATED=false'
        # set ahead of the --from-step region in the builder, so not in the Clean text
        echo 'SLX_PROBE_TABLE="${BUILD_ROOT}/selinux-label-probes.tsv"'
        # a SYSROOT outside this suite's scratch dir would point the Clean phase's
        # rm -rf at real paths: refuse before anything runs
        printf "case \"\${SYSROOT}\" in '%s'/sr-*) ;; *) echo 'refusing: SYSROOT outside the scratch dir' >&2; exit 98 ;; esac\n" "${TMPD}"
        echo '[ -d "${SYSROOT}/etc" ] || exit 98'
        cat "${TMPD}/stubs.sh" "${TMPD}/funcs.sh"
        local p
        for p in "$@"; do
            case "${p}" in @*) echo "${p#@}" ;; *) cat "${TMPD}/${p}" ;; esac
        done
    } > "${TMPD}/flow-${name}.sh"
    mkdir -p "${TMPD}/br"
    timeout 60 bash "${TMPD}/flow-${name}.sh" > "${TMPD}/flow-${name}.out" 2>&1
}
# residue SYSROOT — what of the grant is left (empty = nothing). This file's own
# reading, independent of build_sudoers_gate.
residue() {
    local d="$1" f out=""
    [ -e "${d}/etc/sudoers.d/build-notty" ] || [ -L "${d}/etc/sudoers.d/build-notty" ] && out="${out} [drop-in build-notty]"
    for f in "${d}/etc/sudoers" "${d}"/etc/sudoers.d/*; do
        [ -f "${f}" ] || continue
        awk '/^[[:space:]]*#/ {next} /NOPASSWD/ && /(^|[^[:alnum:]_.-])portage([^[:alnum:]_.-]|$)/ {h=1} END {exit !h}' "${f}" \
            && out="${out} [portage NOPASSWD in ${f#"${d}"}]"
    done
    grep -a -F '# build-added' "${d}/etc/sudoers" >/dev/null 2>&1 && out="${out} [build-added includedir]"
    grep -a -E '^Defaults[[:space:]]+!requiretty' "${d}/etc/sudoers" >/dev/null 2>&1 && out="${out} [requiretty still off]"
    grep -a -x -F 'Defaults requiretty' "${d}/etc/sudoers" >/dev/null 2>&1 || out="${out} [requiretty line gone]"
    [ -f "${d}/etc/sudoers.d/wheel" ] || out="${out} [the legitimate wheel drop-in was removed]"
    printf '%s' "${out}"
}

# ── A0. the write plants what this suite looks for (so a clean result means something) ──
echo "-- A0) the grant write, EXECUTED, plants the grant --"
flow a0 false write.sh '@trap - EXIT'; rc=$?
r="$(residue "${TMPD}/sr-a0")"
if [ "${rc}" -eq 0 ] && grep -F '[drop-in build-notty]' <<<"${r}" >/dev/null && grep -F '[portage NOPASSWD in /etc/sudoers.d/build-notty]' <<<"${r}" >/dev/null \
   && grep -F '[build-added includedir]' <<<"${r}" >/dev/null && grep -F '[requiretty still off]' <<<"${r}" >/dev/null; then
    ok "the write leaves drop-in + portage NOPASSWD + build-added includedir + requiretty off (the fixture is live)"
else
    bad "the write did not plant the grant this suite checks for (rc=${rc}, residue:${r:- none}): $(tail -5 "${TMPD}/flow-a0.out")"
fi

# ── A. a successful build, both --skip-clean values ──────────────────────────
echo "-- A) write -> chroot-phase trap -> Clean phase -> stage4 banner, EXECUTED --"
for sc in false true; do
    flow "a-${sc}" "${sc}" write.sh chroot-trap.sh clean.sh '@echo REACHED_PACK'; rc=$?
    r="$(residue "${TMPD}/sr-a-${sc}")"
    if [ "${rc}" -eq 0 ] && grep -x REACHED_PACK "${TMPD}/flow-a-${sc}.out" >/dev/null && [ -z "${r}" ]; then
        ok "SKIP_CLEAN=${sc}: the build reaches the stage4 pack with no grant left in the sysroot"
    elif [ "${rc}" -eq 0 ]; then
        bad "SKIP_CLEAN=${sc}: the build reached the stage4 pack with the grant still in the sysroot:${r}"
    else
        bad "SKIP_CLEAN=${sc}: the build stopped before the pack (rc=${rc}, residue:${r:- none}): $(grep -a -E 'ERROR|refusing' "${TMPD}/flow-a-${sc}.out" | head -3)"
    fi
done
grep -a -x -F '==> SKIPPED sysroot clean (--skip-clean)' "${TMPD}/flow-a-true.out" >/dev/null \
    && ok "SKIP_CLEAN=true still skipped the size clean (banner printed)" \
    || bad "SKIP_CLEAN=true no longer skips the size clean"
[ -f "${TMPD}/sr-a-true/usr/share/doc/pkg/README" ] && [ ! -e "${TMPD}/sr-a-false/usr/share/doc/pkg/README" ] \
    && ok "--skip-clean keeps docs, the clean path prunes them (the flag kept its documented meaning)" \
    || bad "the docs prune no longer follows --skip-clean"

# ── B. failed builds ─────────────────────────────────────────────────────────
echo "-- B) failed builds leave no grant, EXECUTED --"
flow b1 false write.sh '@exit 1'; rc=$?; r="$(residue "${TMPD}/sr-b1")"
[ "${rc}" -ne 0 ] && [ -z "${r}" ] && ok "B1 exit 1 right after the write (before the chroot phase): no grant left" \
    || bad "B1 exit right after the write left:${r:- (nothing, but rc=${rc})}"
flow b2 false write.sh chroot-trap.sh '@false' '@echo NOT_REACHED'; rc=$?; r="$(residue "${TMPD}/sr-b2")"
[ "${rc}" -ne 0 ] && [ -z "${r}" ] && ok "B2 a failing command in the chroot phase (set -e): no grant left" \
    || bad "B2 a failure in the chroot phase left:${r:- (nothing, but rc=${rc})}"
# (stderr dropped: the shell reports the child's SIGTERM death as a "Terminated" job line)
{ flow b3 false write.sh chroot-trap.sh '@kill -TERM $$' '@sleep 5' '@echo NOT_REACHED'; } 2>/dev/null; rc=$?; r="$(residue "${TMPD}/sr-b3")"
[ "${rc}" -ne 0 ] && [ -z "${r}" ] && ok "B3 SIGTERM in the chroot phase: no grant left" \
    || bad "B3 SIGTERM in the chroot phase left:${r:- (nothing, but rc=${rc})}"
for sc in false true; do
    STUB_BINPKGS_MOUNTED=1 flow "b4-${sc}" "${sc}" write.sh chroot-trap.sh clean.sh '@echo REACHED_PACK'; rc=$?
    r="$(residue "${TMPD}/sr-b4-${sc}")"
    if [ "${rc}" -ne 0 ] && grep -a -F 'STILL a mountpoint' "${TMPD}/flow-b4-${sc}.out" >/dev/null && [ -z "${r}" ]; then
        ok "B4 SKIP_CLEAN=${sc}: the Clean phase's binpkgs refusal (exit after the trap is disarmed) leaves no grant"
    else
        bad "B4 SKIP_CLEAN=${sc}: exit from the binpkgs refusal (rc=${rc}) left:${r:- (nothing; refusal not reached?)}"
    fi
done

# ── C. the gate, EXECUTED against planted variants ───────────────────────────
echo "-- C) build_sudoers_gate, EXECUTED --"
# gate_on NAME SETUP — a clean fixture, SETUP run in it (cwd = the sysroot), then the gate.
gate_on() {
    local name="$1" setup="$2" d="${TMPD}/g-$1"
    mkfix "${d}"
    ( cd "${d}" && eval "${setup}" ) || { echo "setup failed"; return 99; }
    SYSROOT="${d}" bash -c 'set -euo pipefail
        err(){ echo "ERROR: $*" >&2; }; . "$1"
        build_sudoers_gate' _ "${TMPD}/funcs.sh" > "${TMPD}/g-${name}.out" 2>&1
}
gate_on clean 'printf "# portage ALL=(ALL) NOPASSWD: ALL\n" > etc/sudoers.d/notes; printf "ALL ALL=(ALL) ALL\n" >> etc/sudoers'; rc=$?
[ "${rc}" -eq 0 ] && ok "C0 a clean sysroot passes (wheel drop-in, a commented-out portage line)" \
    || bad "C0 the gate refuses a clean sysroot (rc=${rc}): $(cat "${TMPD}/g-clean.out")"
while IFS='|' read -r name setup; do
    [ -n "${name}" ] || continue
    gate_on "${name}" "${setup}"; rc=$?
    [ "${rc}" -eq 1 ] && ok "C ${name}: refused" || bad "C ${name}: NOT refused (rc=${rc}): $(cat "${TMPD}/g-${name}.out")"
done <<'EOF'
dropin-no-portage-line|printf 'Defaults !requiretty\n' > etc/sudoers.d/build-notty
dropin-dangling-link|ln -s /nonexistent etc/sudoers.d/build-notty
dropin-renamed|printf 'portage ALL=(ALL) NOPASSWD: ALL\n' > etc/sudoers.d/zz-build
main-sudoers-line|printf 'portage ALL=(ALL) NOPASSWD: ALL\n' >> etc/sudoers
group-form|printf '%%portage ALL=(root) NOPASSWD: /usr/bin/emerge\n' > etc/sudoers.d/emerge
spacing-and-tabs|printf '   portage\tALL = (ALL)   NOPASSWD:ALL\n' > etc/sudoers.d/spaced
user-list|printf 'root,portage ALL=(ALL) NOPASSWD: ALL\n' > etc/sudoers.d/list
nul-byte-file|printf 'x\000y\nportage ALL=(ALL) NOPASSWD: ALL\n' > etc/sudoers.d/binary
build-added-includedir|printf '\n#includedir /etc/sudoers.d # build-added\n' >> etc/sudoers
EOF
SYSROOT="" bash -c 'set -euo pipefail; err(){ echo "ERROR: $*" >&2; }; . "$1"; build_sudoers_gate' _ "${TMPD}/funcs.sh" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 1 ] && ok "C no SYSROOT: the gate fails closed" || bad "C no SYSROOT: the gate returned ${rc} (want 1)"

# ── D. a grant re-planted after the strip never reaches the pack ─────────────
echo "-- D) a grant re-planted after the strip stops the build before the stage4 pack, EXECUTED --"
for rp in dropin other; do
    STUB_REPLANT="${rp}" flow "d-${rp}" true write.sh chroot-trap.sh clean.sh '@echo REACHED_PACK'; rc=$?
    if [ "${rc}" -ne 0 ] && ! grep -x REACHED_PACK "${TMPD}/flow-d-${rp}.out" >/dev/null; then
        ok "D ${rp}: re-planted by the label pass -> refused before the stage4 banner (rc=${rc})"
    else
        bad "D ${rp}: a grant re-planted after the strip reached the stage4 pack (rc=${rc})"
    fi
done

# ── E. structure ─────────────────────────────────────────────────────────────
echo "-- E) structure --"
# Logical lines (continuations joined), comment lines dropped, as "N<TAB>text".
awk '{ line = (cont ? acc " " $0 : $0); if (!cont) start = NR }
     /\\$/ { sub(/\\$/, "", line); acc = line; cont = 1; next }
     { cont = 0; if (line !~ /^[[:space:]]*#/) printf "%d\t%s\n", start, line }' "${BUILDER}" > "${TMPD}/logical.tsv"
# Pack sites: a tar that CREATES from -C "${SYSROOT}", or mksquashfs "${SYSROOT}".
awk -F'\t' '($2 ~ /tar -C "\$\{SYSROOT\}"/ && $2 ~ /(^|[[:space:]])-c[A-Za-z]*([[:space:]]|$)/) || $2 ~ /mksquashfs "\$\{SYSROOT\}"/ {print $1}' \
    "${TMPD}/logical.tsv" > "${TMPD}/sites"
nsites="$(wc -l < "${TMPD}/sites" | tr -d ' ')"
[ "${nsites}" -ge 3 ] && ok "E found ${nsites} pack sites reading \${SYSROOT} (stage4 tar, live mksquashfs, live tar2sqfs fallback)" \
    || bad "E found ${nsites} pack sites reading \${SYSROOT} (want >= 3): the census broke"
while read -r site; do
    g="$(awk -F'\t' -v s="${site}" '$1 < s && $2 ~ /^[[:space:]]*build_sudoers_gate \|\| \{ err .*; exit 1; \}[[:space:]]*$/ {g=$1} END {print g+0}' "${TMPD}/logical.tsv")"
    if [ "${g}" -eq 0 ]; then
        bad "E pack site at line ${site}: no fatal build_sudoers_gate call before it"; continue
    fi
    between="$(awk -F'\t' -v a="${g}" -v b="${site}" '$1 > a && $1 < b && ($2 ~ /chroot "\$\{SYSROOT\}"/ || $2 ~ /(^|[;[:space:]])mount_chroot([;[:space:]]|$)/) {print $1}' "${TMPD}/logical.tsv" | head -1)"
    [ -z "${between}" ] && ok "E pack site at line ${site}: fatal gate at line ${g}, no chroot between" \
        || bad "E pack site at line ${site}: a chroot runs at line ${between}, after the gate at line ${g}"
done < "${TMPD}/sites"
others=""
for b in "${REPO}"/build-*-stage4.sh; do
    [ "$(basename "${b}")" = build-x86-host-stage4.sh ] && continue
    grep -a -v -E '^[[:space:]]*#' "${b}" | grep -a -E 'build-notty|portage[[:space:]]+ALL=.*NOPASSWD' >/dev/null && others="${others} $(basename "${b}")"
done
[ -z "${others}" ] && ok "E no other builder writes a portage NOPASSWD grant" || bad "E other builder(s) write the grant with no strip/gate:${others}"
helpblk="$(awk '/^      --skip-clean / {f=1; print; next} f && /^      --/ {exit} f {print}' "${BUILDER}")"
if grep -F 'sudoers grant is removed' <<<"${helpblk}" >/dev/null && ! grep -F 'Keep docs/headers/symbols.' <<<"${helpblk}" >/dev/null; then
    ok "E --skip-clean help says the build-only sudoers grant is removed regardless"
else
    bad "E --skip-clean help does not say the grant is removed regardless: ${helpblk}"
fi

# ── F. mutations ─────────────────────────────────────────────────────────────
if [ "${CHILD}" != 1 ] && [ "${F}" -ne 0 ]; then
    echo "-- F) mutations NOT run: the unmutated builder is already red above, so every mutant would be 'caught' for free --"
elif [ "${CHILD}" != 1 ]; then
    echo "-- F) mutations of the builder (each must turn this suite red) --"
    caught=0; survived=0
    # mutate NAME DESCRIPTION — reads a filter program on stdin (awk or sed), applies it.
    mutant() {   # NAME KIND PROGRAM DESCRIPTION
        local name="$1" kind="$2" prog="$3" desc="$4" m="${TMPD}/mut-$1.sh"
        if [ "${kind}" = sed ]; then sed -e "${prog}" "${BUILDER}" > "${m}"; else awk "${prog}" "${BUILDER}" > "${m}"; fi
        if cmp -s "${BUILDER}" "${m}"; then
            bad "mutation ${name} did not change the builder (its pattern no longer matches): ${desc}"; return
        fi
        if SUDOERS_GUARD_BUILDER="${m}" SUDOERS_GUARD_CHILD=1 timeout 300 bash "${BASH_SOURCE[0]}" > "${TMPD}/mut-${name}.out" 2>&1; then
            bad "mutation ${name} SURVIVED: ${desc}"; survived=$((survived+1))
        else
            ok "mutation ${name} caught ($(grep -c '^  FAIL' "${TMPD}/mut-${name}.out") red): ${desc}"; caught=$((caught+1))
        fi
    }
    mutant pre-fix-shape awk '
        /^build_sudoers_strip$/ {print "${SKIP_CLEAN} || build_sudoers_strip"; next}
        /^[[:space:]]*build_sudoers_gate \|\| / {next}
        {print}' "the pre-fix shape: strip only on the clean path, no gate anywhere"
    mutant strip-under-skip-clean sed 's/^build_sudoers_strip$/${SKIP_CLEAN} || build_sudoers_strip/' \
        "the inline strip made conditional on --skip-clean again"
    mutant no-inline-strip sed '/^build_sudoers_strip$/d' "the inline strip at the top of the Clean phase deleted"
    mutant no-early-trap sed "/^trap 'build_sudoers_strip || true' EXIT\$/d" "the EXIT trap armed before the write deleted"
    mutant chroot-trap-reverted sed "s/^trap 'build_sudoers_strip || true; umount_chroot' EXIT\$/trap umount_chroot EXIT/" \
        "the chroot phase's trap back to umount_chroot alone"
    mutant strip-wrong-path sed 's|^    rm -f "${SYSROOT}/etc/sudoers.d/build-notty"$|    rm -f "${SYSROOT}/etc/sudoers.d/build-notty.old"|' \
        "build_sudoers_strip removes the wrong file"
    mutant strip-keeps-requiretty-patch sed "/^        sed -i 's\/^Defaults !requiretty\/Defaults requiretty\/' \"\${SYSROOT}\/etc\/sudoers\"\$/d" \
        "the requiretty revert dropped"
    mutant strip-keeps-includedir sed '/^        sed -i .\/^#includedir .*build-added\$\/d. "${SYSROOT}\/etc\/sudoers"$/d' \
        "the build-added includedir revert dropped"
    mutant gate-always-passes awk '{print} /^build_sudoers_gate\(\) \{$/ {print "    return 0"}' "build_sudoers_gate always returns 0"
    mutant gate-narrow-regex sed 's#/NOPASSWD/ \&\& /(^|\[^\[:alnum:\]_.-\])portage(\[^\[:alnum:\]_.-\]|\$)/ {hit=1}#/NOPASSWD/ \&\& /^portage / {hit=1}#' \
        "the gate only matches a line starting 'portage '"
    mutant gate-main-file-only sed 's#^    for f in "${SYSROOT}/etc/sudoers" "${SYSROOT}"/etc/sudoers.d/\*; do$#    for f in "${SYSROOT}/etc/sudoers"; do#' \
        "the gate reads only the main sudoers file"
    mutant gate-no-dropin-check sed 's#^    if \[ -e "${SYSROOT}/etc/sudoers.d/build-notty" \] || \[ -L "${SYSROOT}/etc/sudoers.d/build-notty" \]; then$#    if false; then#' \
        "the gate stops checking for the drop-in by name"
    mutant gate-no-includedir-check sed "s/grep -a -x -F '#includedir \/etc\/sudoers.d # build-added' /grep -a -x -F '#includedir \/etc\/sudoers.d # build-added-x' /" \
        "the gate stops checking the build-added includedir"
    mutant no-stage4-gate sed '/^build_sudoers_gate || { err "the sysroot carries a build-only sudoers grant/d' \
        "the gate before the stage4 tar deleted"
    mutant stage4-gate-nonfatal sed 's/^\(build_sudoers_gate || { err "the sysroot carries a build-only sudoers grant[^;]*\); exit 1; }$/\1; true; }/' \
        "the gate before the stage4 tar made non-fatal"
    mutant stage4-gate-after-tar awk '
        /^build_sudoers_gate \|\| \{ err "the sysroot carries a build-only sudoers grant/ {held=$0; next}
        {print}
        held != "" && /^    \|\| \{ err "stage4 tar \(with xattrs\) failed/ {print held; held=""}' \
        "the gate before the stage4 tar moved after it"
    mutant no-live-gate sed '/^        build_sudoers_gate || { err "live pack:/d' "the gate before the live squash deleted"
    mutant live-gate-before-chroot awk '
        /^        build_sudoers_gate \|\| \{ err "live pack:/ {next}
        /^        mount_chroot; trap umount_chroot EXIT$/ {print "        build_sudoers_gate || { err \"live pack: x\"; exit 1; }"}
        {print}' "the live gate moved above the live dracut chroot"
    echo "  mutations: ${caught} caught, ${survived} survived"
    [ "${caught}" -ge 18 ] || bad "only ${caught} mutations were caught (want 18)"
fi

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
