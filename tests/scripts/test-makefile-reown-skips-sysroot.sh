#!/usr/bin/env bash
# test-makefile-reown-skips-sysroot.sh — the Makefile's post-build reown,
# EXECUTED against a scratch work directory.
#
# hugmesh-generator#659: after a native build through `make`, chown-artifacts
# did `chown -R $(HOST_UID):$(HOST_GID) "$(WORK_DIR)"` — the WHOLE work
# directory, build system included. The next `--resume` built an image out of
# a tree the operator owned: every directory in it uid 1002, sshd and tor
# refusing to start, the build green. The reown must hand the ARTIFACTS to the
# host user (images, ISOs, tarballs, logs, keys, sessions/, shared/, the
# locks, isoroot) and never descend into a directory named `sysroot`.
#
# WHAT IS RUN. The `define chown-artifacts` body is extracted from the real
# Makefile, its make variables substituted, and the resulting shell line is
# executed twice: once with a STUB `chown` on PATH that records every path it
# is handed (so the exact set can be asserted), and once for real with this
# user's own uid (a no-op chown that proves the find expression is valid and
# exits 0). Then the OLD line is put back in a COPY and the same assertions go
# RED. The Studio's output-directory advice (worklist_driver.py), which used to
# tell a person to run the same `chown -R`, is pinned to the same shape.
#
# No root, no build, no `| grep -q` under pipefail, `grep -a` everywhere.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TEST_DIR}/../.." && pwd)"
MK="${REPO}/Makefile"
WD="${REPO}/studio/hugmesh_studio/core/worklist_driver.py"
WALL="${WALL:-30}"

P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }

[ -f "${MK}" ] || { echo "MISSING: ${MK}"; exit 2; }
[ -f "${WD}" ] || { echo "MISSING: ${WD}"; exit 2; }
for t in find chown awk sed cmp timeout; do command -v "$t" >/dev/null 2>&1 || { echo "MISSING tool: $t"; exit 2; }; done

TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR}"' EXIT
mkdir -p "${TDIR}/bin"
cat > "${TDIR}/bin/chown" <<'STUB'
#!/usr/bin/env bash
# record: flags on one line, then each path on its own line
flags=""; for a in "$@"; do case "$a" in -*) flags="${flags} $a" ;; *) printf '%s\n' "$a" >> "${STUB_STATE}/paths" ;; esac; done
printf '%s\n' "${flags}" >> "${STUB_STATE}/flags"
exit 0
STUB
chmod +x "${TDIR}/bin/chown"
export STUB_STATE="${TDIR}/state"; mkdir -p "${STUB_STATE}"

# ── the scratch work directory, shaped like out/ after a native pki build ────
make_workdir() {
    local w="$1"
    rm -rf "$w"
    mkdir -p "$w/snap-build-x86/sysroot/etc" "$w/snap-build-x86/sysroot/var/empty" "$w/snap-build-x86/sysroot/usr/lib64" \
             "$w/snap-build-x86/isoroot/boot" "$w/snap-build-x86/distfiles" "$w/snap-build-x86/pkgdir" \
             "$w/snap-build-pi5/sysroot/etc" "$w/custom-subdir/sysroot/etc" \
             "$w/sessions/20260930-1/logs" "$w/shared/seed/amd64" "$w/keys-pki" "$w/qemu-runs" "$w/secureboot"
    : > "$w/hugmesh-x86-amd64-pki-test-20260930T141408Z.img"
    : > "$w/hugmesh-x86-amd64-pki-test-20260930T141408Z.live.iso"
    : > "$w/hugmesh-x86-amd64-pki-test-20260930T141408Z.fs.tar.xz"
    : > "$w/build.log"; : > "$w/snap-build-x86.lock"; : > "$w/snap-build-x86/sysroot.seed"
    : > "$w/snap-build-x86/sysroot/etc/gentoo-release"; : > "$w/snap-build-x86/sysroot/usr/lib64/libc.so"
    : > "$w/snap-build-pi5/sysroot/etc/gentoo-release"; : > "$w/custom-subdir/sysroot/etc/gentoo-release"
    : > "$w/shared/seed/amd64/stage3-amd64-hardened-openrc-20260920T170055Z.tar.xz"
    # a symlink among the artifacts that points INTO the sysroot: chown -h must
    # change the link, never follow it.
    ln -s "snap-build-x86/sysroot/etc" "$w/link-into-sysroot"
}
W="${TDIR}/out"; make_workdir "${W}"

# ── extract the define body from the Makefile and turn it into a shell line ──
recipe_from() {   # <Makefile> -> the one recipe line with make vars substituted
    awk '/^define chown-artifacts$/{on=1; next} /^endef$/{on=0} on' "$1" \
        | sed -e 's/^[[:space:]]*@//' \
              -e "s|\$(HOST_UID)|${HOST_UID_SUB}|g" -e "s|\$(HOST_GID)|${HOST_GID_SUB}|g" \
              -e "s|\$(WORK_DIR)|${W}|g" -e 's|\$(SUDO)||g'
}
run_recipe() {   # <Makefile> [stub|real]
    local recipe
    recipe="$(recipe_from "$1")"
    [ -n "${recipe}" ] || return 99
    rm -f "${STUB_STATE}/paths" "${STUB_STATE}/flags"
    if [ "${2:-stub}" = stub ]; then
        PATH="${TDIR}/bin:${PATH}" timeout "${WALL}" bash -c "${recipe}"
    else
        timeout "${WALL}" bash -c "${recipe}"
    fi
}

echo "== chown-artifacts, extracted from the Makefile and executed =="
HOST_UID_SUB=1002; HOST_GID_SUB=1002
recipe="$(recipe_from "${MK}")"
[ -n "${recipe}" ] && ok "define chown-artifacts extracted: ${recipe}" || { bad "no define chown-artifacts in the Makefile"; echo "== ${P} passed, ${F} failed =="; exit 1; }

assert_reown() {   # <label> -> 0 when the recorded chown paths are right
    local label="$1" rc=0
    local paths="${STUB_STATE}/paths" flags="${STUB_STATE}/flags"
    [ -s "${paths}" ] || { bad "${label}: chown was never called"; return 1; }
    # artifacts handed over
    for want in "${W}" "${W}/hugmesh-x86-amd64-pki-test-20260930T141408Z.img" "${W}/hugmesh-x86-amd64-pki-test-20260930T141408Z.live.iso" \
                "${W}/build.log" "${W}/snap-build-x86.lock" "${W}/sessions/20260930-1/logs" "${W}/shared/seed/amd64/stage3-amd64-hardened-openrc-20260920T170055Z.tar.xz" \
                "${W}/keys-pki" "${W}/snap-build-x86" "${W}/snap-build-x86/isoroot/boot" "${W}/snap-build-x86/sysroot.seed" "${W}/snap-build-x86/distfiles" "${W}/link-into-sysroot"; do
        grep -a -x -F -e "${want}" "${paths}" >/dev/null || { bad "${label}: artifact NOT handed over: ${want}"; rc=1; }
    done
    # no sysroot, at any depth, and nothing under one
    if grep -a -E -e '/sysroot(/|$)' "${paths}" >/dev/null; then
        bad "${label}: a sysroot path was handed to chown: $(grep -a -E -e '/sysroot(/|$)' "${paths}" | head -3 | tr '\n' ' ')"; rc=1
    fi
    # the symlink's TARGET (inside the sysroot) was not followed
    grep -a -x -F -e "${W}/snap-build-x86/sysroot/etc" "${paths}" >/dev/null && { bad "${label}: the link into the sysroot was followed"; rc=1; }
    # -h on every call, never -R (counted with `grep -c`, no pipeline: under
    # pipefail a `grep -v` that selects nothing fails the whole pipe)
    local n_recursive n_without_h
    n_recursive="$(grep -a -c -F -e '-R' "${flags}" || true)"
    n_without_h="$(grep -a -c -v -F -e '-h' "${flags}" || true)"
    [ "${n_recursive}" -eq 0 ] || { bad "${label}: chown -R used"; rc=1; }
    [ "${n_without_h}" -eq 0 ] || { bad "${label}: a chown call without -h"; rc=1; }
    return "${rc}"
}
run_recipe "${MK}" stub; rc=$?
[ "${rc}" -eq 0 ] && assert_reown "current Makefile" \
    && ok "current Makefile: every artifact (dir + files + lock + seed + marker + isoroot + symlink) handed to 1002:1002 with chown -h; NO sysroot (snap-build-x86, snap-build-pi5, custom-subdir) and nothing under one; the link into the sysroot not followed"
n_calls="$(wc -l < "${STUB_STATE}/flags")"; n_paths="$(wc -l < "${STUB_STATE}/paths")"
echo "    (chown called ${n_calls} time(s) over ${n_paths} paths)"

# For real, with this user's own uid: a no-op that proves the expression runs and exits 0.
HOST_UID_SUB="$(id -u)"; HOST_GID_SUB="$(id -g)"
make_workdir "${W}"
out="$(run_recipe "${MK}" real 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ -z "${out}" ] && [ "$(stat -c %u "${W}/build.log")" = "$(id -u)" ] \
    && ok "for real (own uid): the recipe runs, exits 0, no output" || bad "for real: rc=${rc}: ${out}"
HOST_UID_SUB=1002; HOST_GID_SUB=1002
# HOST_UID empty: the whole line is skipped (the bare-host no-op documented in the Makefile).
recipe_empty="$(recipe_from "${MK}" | sed -e 's|1002:1002|:|' -e 's|-n "1002"|-n ""|')"
rm -f "${STUB_STATE}/paths"
PATH="${TDIR}/bin:${PATH}" bash -c "${recipe_empty}"; rc=$?
[ "${rc}" -eq 0 ] && [ ! -s "${STUB_STATE}/paths" ] && ok "HOST_UID empty: nothing is chowned, exit 0" || bad "HOST_UID empty: rc=${rc} paths=$(cat "${STUB_STATE}/paths" 2>/dev/null)"

echo "== mutation battery on a COPY of the Makefile =="
# M1: the old line back -> the sysroot is handed over (RED).
sed -e '/^define chown-artifacts$/,/^endef$/{s|find "$(WORK_DIR)" -type d -name sysroot -prune -o -exec chown -h $(HOST_UID):$(HOST_GID) {} +|chown -R $(HOST_UID):$(HOST_GID) "$(WORK_DIR)"|}' "${MK}" > "${TDIR}/Makefile.m1"
cmp -s "${TDIR}/Makefile.m1" "${MK}" && bad "M1 did not change the Makefile text"
make_workdir "${W}"
# the stub does not recurse; feed it what `chown -R` would touch by resolving the tree ourselves
cat > "${TDIR}/bin/chown" <<'STUB'
#!/usr/bin/env bash
flags=""; rec=0; for a in "$@"; do case "$a" in -R) rec=1; flags="${flags} $a" ;; -*) flags="${flags} $a" ;; *) if [ $rec = 1 ]; then find "$a" -print >> "${STUB_STATE}/paths"; else printf '%s\n' "$a" >> "${STUB_STATE}/paths"; fi ;; esac; done
printf '%s\n' "${flags}" >> "${STUB_STATE}/flags"; exit 0
STUB
run_recipe "${TDIR}/Makefile.m1" stub >/dev/null 2>&1
if grep -a -E -e '/sysroot(/|$)' "${STUB_STATE}/paths" >/dev/null && grep -a -F -e '-R' "${STUB_STATE}/flags" >/dev/null; then
    ok "M1 old 'chown -R WORK_DIR' restored: the sysroot and everything under it is handed over (leg RED)"
else
    bad "M1: restoring the old line was not caught"
fi
# M2: -prune dropped -> find descends into the sysroot (RED).
sed -e '/^define chown-artifacts$/,/^endef$/{s| -prune -o | -o |}' "${MK}" > "${TDIR}/Makefile.m2"
cmp -s "${TDIR}/Makefile.m2" "${MK}" && bad "M2 did not change the Makefile text"
make_workdir "${W}"
run_recipe "${TDIR}/Makefile.m2" stub >/dev/null 2>&1
grep -a -E -e '/sysroot/' "${STUB_STATE}/paths" >/dev/null && ok "M2 -prune dropped: paths under the sysroot are handed over (leg RED)" || bad "M2: dropping -prune was not caught"
# M3: -h dropped -> the link into the sysroot is followed by a real chown; the flag pin goes RED.
sed -e '/^define chown-artifacts$/,/^endef$/{s|chown -h |chown |}' "${MK}" > "${TDIR}/Makefile.m3"
cmp -s "${TDIR}/Makefile.m3" "${MK}" && bad "M3 did not change the Makefile text"
make_workdir "${W}"
run_recipe "${TDIR}/Makefile.m3" stub >/dev/null 2>&1
n_without_h="$(grep -a -c -v -F -e '-h' "${STUB_STATE}/flags" || true)"
[ "${n_without_h}" -gt 0 ] && ok "M3 -h dropped: a chown call without -h (leg RED; a real chown would follow the link into the sysroot)" || bad "M3: dropping -h was not caught"

echo "== the Studio's advice has the same shape =="
if grep -a -F -e "-type d -name sysroot -prune -o -exec chown -h" "${WD}" >/dev/null \
   && ! grep -a -F -e 'f"sudo chown -R {getpass.getuser()} {probe}"' "${WD}" >/dev/null; then
    ok "worklist_driver.py: the output-directory remedy prunes sysroot and uses chown -h; the old 'sudo chown -R <probe>' line is gone"
else
    bad "worklist_driver.py: remedy still 'chown -R' or missing the prune"
fi
# every other reown of a work directory in the repo is one of these two, or is
# the qemu harness's own run/result dirs (never a build system), or the Studio
# MSI builder's throwaway table-dump directory (build-msi-wine.sh hands back the
# one directory it mounted into a container as /out; no image build system is
# ever mounted there).
others="$(grep -a -rn -E -e 'chown -R' --include=Makefile --include='*.sh' --include='*.py' "${REPO}" 2>/dev/null \
    | grep -a -v -E -e '/(out|\.stack-src|node_modules|\.venv|tests)/' -e '^[^:]*:[0-9]+:[[:space:]]*#' -e 'worklist_driver.py' -e 'install-x86.sh' -e 'provision.sh' -e 'build-msi-wine.sh' || true)"
[ -z "${others}" ] && ok "no other 'chown -R' over a work directory in Makefile/scripts/Studio (installer, key provisioning, the MSI builder and the qemu harness reown their own trees, not a build system)" \
    || bad "other chown -R sites to review: ${others}"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
