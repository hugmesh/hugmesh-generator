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
# The second half (2026-11-10) checks that the reown REACHES the host user. It
# drives the real Makefile's 19 NATIVE build targets with stub builders: the
# HOST_UID that DOCKER_RUN forwards through the environment must survive, and
# the reown must run after a failed build too, with make still reporting the
# failure. Mutations M4-M8 put each old shape back in a copy and go red.
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

# ══ the reown actually reaches the host user, on every exit path ═════════════
# The prover's finding (2026-11-10): after a Docker-dispatched `make x86-...`,
# every artifact, log and work dir was still root:root. Two causes, both in the
# Makefile, both executed here against the REAL Makefile with stub builders:
#   (a) `HOST_UID := $(shell id -u)` overrode the HOST_UID that DOCKER_RUN puts
#       in the container's ENVIRONMENT, so the in-container make chowned to 0:0;
#   (b) the reown was its own recipe line, so make never reached it after a
#       FAILED build — and a failed build is exactly when the operator has to
#       clean up.
# Every make run below is `make -C <repo> -f <Makefile or a mutated copy>`.
# Each builder variable (X86, RPI, ALL, ...) is replaced on the make command
# line by a fake builder that records its argv and exits with FAKE_RC. SUDO is
# emptied, and `chown` is a stub on PATH that records what it was handed. Nothing
# is built, nothing needs root, and nothing in the work tree is touched.
command -v make >/dev/null 2>&1 || { echo "MISSING tool: make"; exit 2; }
echo "== HOST_UID/HOST_GID: the environment (DOCKER_RUN's -e) and the command line win =="
print_ids() {   # <Makefile> [env assignments...] -> "uid:gid" as the Makefile resolves them
    local mk="$1"; shift
    env -u HOST_UID -u HOST_GID "$@" make -s -C "${REPO}" -f "${mk}" --no-print-directory \
        --eval 'reown-test-print-ids: ; @echo $(HOST_UID):$(HOST_GID)' reown-test-print-ids NATIVE=1 2>/dev/null
}
print_docker_run() {   # <Makefile> [env assignments...] -> the DOCKER_RUN command text
    local mk="$1"; shift
    env -u HOST_UID -u HOST_GID "$@" make -s -C "${REPO}" -f "${mk}" --no-print-directory \
        --eval 'reown-test-print-dr: ; @echo $(DOCKER_RUN)' reown-test-print-dr 2>/dev/null
}
ME="$(id -u):$(id -g)"
got="$(print_ids "${MK}" HOST_UID=4242 HOST_GID=4243)"
[ "${got}" = "4242:4243" ] && ok "env HOST_UID=4242 HOST_GID=4243 (what DOCKER_RUN gives the container): the Makefile keeps 4242:4243" \
    || bad "env HOST_UID=4242 HOST_GID=4243: the Makefile resolved '${got}' (the in-container make would chown to that)"
got="$(print_ids "${MK}")"
[ "${got}" = "${ME}" ] && ok "HOST_UID/HOST_GID unset: falls back to id -u/-g (${ME})" || bad "HOST_UID unset: resolved '${got}', want ${ME}"
got="$(print_ids "${MK}" HOST_UID= HOST_GID=)"
[ "${got}" = "${ME}" ] && ok "HOST_UID/HOST_GID empty in the env: falls back to id -u/-g, never an empty chown owner" || bad "HOST_UID empty: resolved '${got}', want ${ME}"
got="$(env -u HOST_UID -u HOST_GID HOST_UID=4242 make -s -C "${REPO}" -f "${MK}" --no-print-directory --eval 'reown-test-print-ids: ; @echo $(HOST_UID):$(HOST_GID)' reown-test-print-ids NATIVE=1 HOST_UID=55 HOST_GID=56 2>/dev/null)"
[ "${got}" = "55:56" ] && ok "command line HOST_UID=55 HOST_GID=56 (build-menu.sh's sudo'd native run) beats the env" || bad "command line: resolved '${got}', want 55:56"
dr="$(print_docker_run "${MK}")"
case " ${dr} " in
    *" -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) "*) ok "DOCKER_RUN forwards the invoking uid/gid: -e HOST_UID=$(id -u) -e HOST_GID=$(id -g)" ;;
    *) bad "DOCKER_RUN does not forward -e HOST_UID=$(id -u) -e HOST_GID=$(id -g): ${dr}" ;;
esac

echo "== every NATIVE build recipe reowns on success AND on failure =="
cat > "${TDIR}/bin/chown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_STATE}/chown-calls"
exit 0
STUB
chmod +x "${TDIR}/bin/chown"
FAKE="${TDIR}/fakebuild"
cat > "${FAKE}" <<'STUB'
#!/usr/bin/env bash
mkdir -p "${FAKE_WD}"
printf '%s\n' "$*" >> "${STUB_STATE}/builds"
exit "${FAKE_RC:-0}"
STUB
chmod +x "${FAKE}"
# target -> the builder variable its NATIVE recipe runs. The pattern rules are
# exercised through one valid stem each (the orangepi ones validate it first).
TARGETS="build-all:ALL rebuild:ALL rpi:RPI x86:X86 omnibus:X86 x86-standalone:X86 rpi-desktop:RPI x86-pki:X86
 frite:FRITE_BUILD jetson:JETSON_BUILD jetson-desktop:JETSON_BUILD orangepi5:ORANGEPI5_BUILD orangepi5-backend:ORANGEPI5_BUILD
 orangepizero2:ORANGEPIZERO2_BUILD orangepizero2w:ORANGEPIZERO2W_BUILD orangepizero3:ORANGEPIZERO3_BUILD
 orangepi3-lts:ORANGEPI3LTS_BUILD orangepi4-lts:ORANGEPI4LTS_BUILD orangepi4-lts-frontend:ORANGEPI4LTS_BUILD"
run_native() {   # <Makefile> <target> <builder var> <fake rc> -> make's rc; records in STUB_STATE
    local mk="$1" t="$2" v="$3" frc="$4"
    rm -rf "${W}"; mkdir -p "${W}/sessions"
    rm -f "${STUB_STATE}/chown-calls" "${STUB_STATE}/builds"
    env -u HOST_UID -u HOST_GID HOST_UID=4242 HOST_GID=4243 FAKE_RC="${frc}" FAKE_WD="${W}" STUB_STATE="${STUB_STATE}" \
        PATH="${TDIR}/bin:${PATH}" timeout "${WALL}" \
        make -s -C "${REPO}" -f "${mk}" --no-print-directory "${t}" NATIVE=1 WORK_DIR="${W}" SUDO= "${v}=${FAKE}" >/dev/null 2>&1
}
reowned() {   # -> 0 when the stub chown was handed WORK_DIR itself as 4242:4243 with -h
    [ -s "${STUB_STATE}/chown-calls" ] || return 1
    awk -v w="${W}" '$1 == "-h" && $2 == "4242:4243" { for (i = 3; i <= NF; i++) if ($i == w) f = 1 } END { exit !f }' "${STUB_STATE}/chown-calls"
}
check_targets() {   # <Makefile> -> number of failing legs on stdout; each failing leg in STUB_STATE/legs
    local mk="$1" tv t v frc rc nfail=0
    : > "${STUB_STATE}/legs"
    for tv in ${TARGETS}; do
        t="${tv%%:*}"; v="${tv#*:}"
        for frc in 0 9; do
            run_native "${mk}" "${t}" "${v}" "${frc}"; rc=$?
            local why=""
            [ -s "${STUB_STATE}/builds" ] || why="${why} the fake builder never ran;"
            if [ "${frc}" -eq 0 ]; then [ "${rc}" -eq 0 ] || why="${why} make rc=${rc} on a green build;"
            else [ "${rc}" -ne 0 ] || why="${why} make rc=0 on a FAILED build (status swallowed);"; fi
            reowned || why="${why} WORK_DIR not handed to 4242:4243 (chown calls: $({ tr '\n' '|' < "${STUB_STATE}/chown-calls"; } 2>/dev/null));"
            if [ -n "${why}" ]; then
                nfail=$((nfail+1))
                printf 'make %s (builder exit %s):%s\n' "${t}" "${frc}" "${why}" >> "${STUB_STATE}/legs"
            fi
        done
    done
    echo "${nfail}"
}
n_targets="$(echo ${TARGETS} | wc -w)"
nf="$(check_targets "${MK}")"
while IFS= read -r leg; do bad "${leg}"; done < "${STUB_STATE}/legs"
if [ "${nf}" = 0 ]; then
    ok "${n_targets} build targets x {builder exits 0, builder exits 9}: make's status follows the builder, and WORK_DIR goes to the env's 4242:4243 with chown -h EVERY time"
else
    bad "${nf} of $((n_targets*2)) build/exit-status legs did not reown or lost the status (listed above)"
fi
# Coverage: every recipe that runs build-then-reown is in TARGETS, and no build
# recipe still reowns from a SEPARATE line (which make skips after a failure).
mk_targets="$(awk '/^[A-Za-z0-9%][A-Za-z0-9%_.-]*:/{t=$1; sub(/:.*/,"",t)} /^\t@?\$\(call build-then-reown,/{print t}' "${MK}" | sort -u)"
missing=""
for t in ${mk_targets}; do
    case " $(echo ${TARGETS} | sed -e 's/:[A-Z0-9_]*//g') " in
        *" ${t} "*) ;;
        *) pat="${t%\%}"; [ "${pat}" != "${t}" ] && case " $(echo ${TARGETS} | sed -e 's/:[A-Z0-9_]*//g') " in *" ${pat}"*) continue ;; esac; missing="${missing} ${t}" ;;
    esac
done
n_calls_mk="$(grep -a -c -E -e '^	@?\$\(call build-then-reown,' "${MK}" || true)"
n_sep="$(grep -a -c -E -e '^	@?\$\(chown-artifacts\)[[:space:]]*$' "${MK}" || true)"
[ -z "${missing}" ] && [ "${n_sep}" -eq 0 ] && [ "${n_calls_mk}" -ge 19 ] \
    && ok "coverage: all ${n_calls_mk} build-then-reown recipes are exercised above, and no recipe reowns from a separate line" \
    || bad "coverage: untested build-then-reown targets:${missing:- none}; separate \$(chown-artifacts) lines: ${n_sep}; calls: ${n_calls_mk}"

echo "== mutation battery (reown reach) on COPIES of the Makefile =="
mutate() {   # <name> <sed program> -> sets m to the mutated copy, or to "" (and FAILs) when sed changed nothing
    m="${TDIR}/Makefile.$1"
    sed -e "$2" "${MK}" > "${m}"
    if cmp -s "${m}" "${MK}"; then bad "$1 did not change the Makefile text"; m=""; fi
}
# M4: the old simply-expanded `id -u` assignment -> the env's uid is overridden.
mutate m4 's|^HOST_UID := $(or $(HOST_UID),$(shell id -u))$|HOST_UID := $(shell id -u)|; s|^HOST_GID := $(or $(HOST_GID),$(shell id -g))$|HOST_GID := $(shell id -g)|'
if [ -n "${m}" ]; then
    got="$(print_ids "${m}" HOST_UID=4242 HOST_GID=4243)"
    nfm="$(check_targets "${m}")"
    [ "${got}" != "4242:4243" ] && [ "${nfm}" -gt 0 ] && ok "M4 'HOST_UID := \$(shell id -u)' restored: env 4242 resolves to ${got} and ${nfm} reown legs go RED" \
        || bad "M4: the old assignment was not caught (resolved ${got}, ${nfm} red legs)"
fi
# M5: reown back on its own recipe line after the build (the pre-fix shape).
mutate m5 's|^\(	@\{0,1\}\)$(call build-then-reown,\(.*\))$|\1\2\
	@$(chown-artifacts)|'
if [ -n "${m}" ]; then
    nfm="$(check_targets "${m}")"
    [ "${nfm}" -eq "${n_targets}" ] && ok "M5 reown split back onto its own line: all ${nfm} FAILED-build legs go RED (the green legs stay green)" \
        || bad "M5: splitting the reown off was caught on ${nfm} legs, want exactly ${n_targets} (one per target)"
fi
# M6: no subshell -> a loop's `|| exit 1` exits the recipe shell before the reown.
mutate m6 '/^define build-then-reown$/,/^endef$/{s|( $(1) )|$(1)|}'
if [ -n "${m}" ]; then
    nfm="$(check_targets "${m}")"
    [ "${nfm}" -ge 3 ] && ok "M6 subshell dropped: ${nfm} legs RED (the for-loop recipes rpi, x86, x86-standalone exit before the reown)" \
        || bad "M6: dropping the subshell was caught on only ${nfm} legs"
fi
# M7: the build's status is swallowed.
mutate m7 '/^define build-then-reown$/,/^endef$/{s|exit $$rc|exit 0|}'
if [ -n "${m}" ]; then
    nfm="$(check_targets "${m}")"
    [ "${nfm}" -eq "${n_targets}" ] && ok "M7 'exit 0' after the reown: all ${nfm} FAILED-build legs go RED (a failed build reported green)" \
        || bad "M7: swallowing the status was caught on ${nfm} legs, want ${n_targets}"
fi
# M8: DOCKER_RUN stops forwarding the uid.
mutate m8 's|^  -e HOST_UID=$(HOST_UID) -e HOST_GID=$(HOST_GID) \\$|  \\|'
if [ -n "${m}" ]; then
    dr="$(print_docker_run "${m}")"
    case " ${dr} " in *" -e HOST_UID="*) bad "M8: removing the -e HOST_UID forward was not caught" ;; *) ok "M8 '-e HOST_UID/GID' dropped from DOCKER_RUN: the forward pin goes RED" ;; esac
fi

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
    | grep -a -v -E -e '/(out|\.stack-src|node_modules|\.venv|tests)/' -e '^[^:]*:[0-9]+:[[:space:]]*#' -e 'worklist_driver.py' -e 'install-x86.sh' -e 'provision.sh' -e 'build-msi-wine.sh' -e "chown -R'd " || true)"
[ -z "${others}" ] && ok "no other 'chown -R' over a work directory in Makefile/scripts/Studio (installer, key provisioning, the MSI builder and the qemu harness reown their own trees, not a build system)" \
    || bad "other chown -R sites to review: ${others}"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
