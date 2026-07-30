#!/usr/bin/env bash
# build-arm-payload-gates.sh — guards the ARM/cross-builder halves of the
# "broken artifacts with exit 0" forensic findings:
#
#   1. SILENT PACKAGE LOSS. The ARM cross builders' payload emerges run
#      --keep-going and their post-emerge asserts were hand-maintained BINARY
#      lists — session 20260719-103006-a775c2 shipped pki/be/fe rpi5 .img.xz
#      artifacts whose logs all say "WARNING:   skipped net-firewall/firewalld"
#      (pki/be line 2736, fe 2755) right before "Stage4 payload verified (...)"
#      (pki line 3817): no firewall on the image AND a dangling 'firewall'
#      runlevel service. Fix: scripts/_payload-gate-lib.sh, the cross twin of
#      build-x86-host-stage4.sh's REQUESTED-ATOM COMPLETENESS GATE (#461/#465),
#      wired into all of them (originally the five of PR #470; the Orange Pi
#      Zero 2W / Zero 3 forks are wired identically from birth).
#
#   2. KERNEL-LESS ARTIFACTS WITH EXIT 0. A failed sys-kernel/*-sources emerge
#      degraded to a warn-skipped kernel phase and warn-only downstream
#      (frite/opi5/zero2 skipped the LIVE image and shipped a kernel-less
#      stage4; jetson skipped the .img; rpi5 --no-img shipped a kernel-less
#      tarball). Fix: a non-bypassable kernel tier in the gate + the downstream
#      warns promoted to hard failures unless --skip-kernel made kernel-less
#      output a deliberate operator choice.
#
# Unlike the x86 gate (which lives inside an unquoted chroot heredoc and needs
# render-then-bash-n, see tests/build-package-completeness.sh), the cross
# builders' gate is plain host-side shell in a SOURCED lib — so this test can
# do something stronger than parse it: EXECUTE the real gate against a fake
# TARGET sysroot vdb and prove each decision tier, including that the query
# hits the target vdb and never the host's (the vacuous-pass failure mode).
#
# Pure static + fake-sysroot execution. No emerge, no chroot, no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
LIB="${REPO}/scripts/_payload-gate-lib.sh"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# builder -> its kernel package (rpi5 boots the foundation's fork; the rest
# build mainline from gentoo-sources — mirrors each specs-*/portage/packages.list)
declare -A KATOM=(
  [build-rpi5-stage4.sh]=sys-kernel/raspberrypi-sources
  [build-frite-stage4.sh]=sys-kernel/gentoo-sources
  [build-jetson-stage4.sh]=sys-kernel/gentoo-sources
  [build-orangepi5-stage4.sh]=sys-kernel/gentoo-sources
  [build-orangepi-zero2-stage4.sh]=sys-kernel/gentoo-sources
  [build-orangepi-zero2w-stage4.sh]=sys-kernel/gentoo-sources
  [build-orangepi-zero3-stage4.sh]=sys-kernel/gentoo-sources
  [build-orangepi3-lts-stage4.sh]=sys-kernel/gentoo-sources
  [build-orangepi4-lts-stage4.sh]=sys-kernel/gentoo-sources
)
BUILDERS=(build-rpi5-stage4.sh build-frite-stage4.sh build-jetson-stage4.sh
          build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh
          build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh
          build-orangepi3-lts-stage4.sh build-orangepi4-lts-stage4.sh)

echo "== ARM payload gates (requested-atom completeness + kernel tier) =="

echo "-- A) the shared gate lib --"
[ -f "${LIB}" ] && ok "scripts/_payload-gate-lib.sh exists" || bad "gate lib MISSING"
bash -n "${LIB}" 2>/dev/null && ok "lib is valid bash" || bad "lib does not parse"
# The #465 lesson, at the source: the python must emit NOTHING when nothing is
# missing (print("\n".join([])) writes a bare newline = a 1-byte file that a
# naive [ -s ] consumer reads as one missing package), and the shell side must
# count NON-BLANK lines, so either guard alone suffices.
grep -q 'if out:' "${LIB}" \
  && ok "python only prints when something is actually missing (the #465 guard)" \
  || bad "python prints unconditionally — the empty-list false positive is back"
grep -q "grep -c '\[\^\[:space:\]\]'" "${LIB}" \
  && ok "shell counts NON-BLANK missing lines" || bad "shell side lost the non-blank count"
# The vacuous-pass honesty guard: the python refuses to run against the wrong
# EROOT instead of silently checking the HOST vdb (where most atoms exist too).
grep -q 'EROOT %r != requested sysroot' "${LIB}" \
  && ok "EROOT-mismatch refusal present (no silent host-vdb fallback)" \
  || bad "no EROOT honesty guard — a mis-plumbed ROOT would pass vacuously"

echo "-- B) per-builder wiring --"
for b in "${BUILDERS[@]}"; do
  f="${REPO}/${b}"
  echo "   [${b}]"
  bash -n "${f}" 2>/dev/null && ok "builder parses" || bad "builder does NOT parse"
  grep -q 'source "${SCRIPT_DIR}/scripts/_payload-gate-lib.sh"' "${f}" \
    && ok "sources the gate lib" || bad "does not source _payload-gate-lib.sh"
  grep -q '^ALLOW_MISSING_PACKAGES=false' "${f}" \
    && ok "defaults to FAILING on a degraded image" || bad "not fail-by-default"
  grep -q -- '--allow-missing-packages) ALLOW_MISSING_PACKAGES=true' "${f}" \
    && ok "--allow-missing-packages opt-out is parsed" || bad "opt-out flag not wired"
  grep -q -- '--allow-missing-packages$' "${f}" \
    && ok "opt-out is documented in --help" || bad "opt-out missing from usage text"
  grep -q "_kernel_gate_atom=\"${KATOM[${b}]}\"" "${f}" \
    && ok "kernel tier pins ${KATOM[${b}]}" \
    || bad "kernel tier does not pin ${KATOM[${b}]}"
  grep -q '${SKIP_KERNEL} && _kernel_gate_atom=""' "${f}" \
    && ok "--skip-kernel is the sanctioned kernel opt-out" \
    || bad "kernel tier ignores --skip-kernel"
  # The gate must consume the builder's REAL resolved set and the TARGET
  # sysroot — not a re-derived list, not the host root.
  grep -Eq 'requested_atom_gate "\$\{SYSROOT\}" "\$\{BUILD_ROOT\}" "[a-z0-9-]+" *\\' "${f}" \
    && ok "gate is pointed at \${SYSROOT} (the vdb cross_emerge writes)" \
    || bad "gate call does not target \${SYSROOT}"
  grep -q '"${_kernel_gate_atom}" "${STAGE4_PACKAGES\[@\]}"' "${f}" \
    && ok "gate checks the resolved STAGE4_PACKAGES set" \
    || bad "gate does not consume STAGE4_PACKAGES"
  # Ordering: after the payload emerge, before the --packages-only exit AND
  # before the kernel phase (failing after a multi-minute kernel build, or
  # never running in --packages-only mode, would defeat the point).
  gate_ln=$(grep -n 'requested_atom_gate "${SYSROOT}"' "${f}" | head -1 | cut -d: -f1)
  emer_ln=$(grep -n 'cross_emerge --update --deep --newuse --keep-going' "${f}" | head -1 | cut -d: -f1)
  pkgo_ln=$(grep -n 'packages-only: per-board binpkg pool prebuilt' "${f}" | head -1 | cut -d: -f1)
  # Kernel-phase anchor: the canonical taxonomy banner ("Building hardened kernel",
  # uniform across every cross builder) — with the pre-taxonomy "Phase 3" wording as
  # a fallback so this gate still orders correctly on an old checkout/branch.
  kern_ln=$(grep -nE 'banner "(Building hardened kernel|Phase 3: Cross-compiling)' "${f}" | head -1 | cut -d: -f1)
  if [ -n "${gate_ln}" ] && [ -n "${emer_ln}" ] && [ -n "${pkgo_ln}" ] && [ -n "${kern_ln}" ] \
     && [ "${gate_ln}" -gt "${emer_ln}" ] && [ "${gate_ln}" -lt "${pkgo_ln}" ] \
     && [ "${gate_ln}" -lt "${kern_ln}" ]; then
    ok "gate ordered: emerge(${emer_ln}) < gate(${gate_ln}) < packages-only(${pkgo_ln}) & kernel(${kern_ln})"
  else
    bad "gate mis-ordered (gate=${gate_ln:-?} emerge=${emer_ln:-?} pkgs-only=${pkgo_ln:-?} kernel=${kern_ln:-?})"
  fi
done

echo "-- C) the gate DECISION, executed against a real fake target vdb --"
# The lib queries portage's vardb via host python3 with ROOT/PORTAGE_CONFIGROOT
# env — exactly the env shape cross_emerge() gives the emerge it judges. Build
# a throwaway sysroot with a real vdb layout and run the REAL function.
if ! python3 -c 'import portage' 2>/dev/null; then
  echo "  NOTE host python3 has no portage module — execution tier SKIPPED (static tier above still ran)"
else
  FR="${TMP}/fakeroot"; W="${TMP}/gatework"
  mkdir -p "${FR}/var/db/pkg/sys-kernel/gentoo-sources-6.12.9" \
           "${FR}/etc/portage/repos.conf" "${W}"
  # A profile + repos.conf so portage's config can construct against the fake
  # CONFIGROOT. Reuse the host's own profile target — its existence is the one
  # host assumption, and `import portage` above already implies a Gentoo host.
  _prof="$(readlink -f /etc/portage/make.profile 2>/dev/null || true)"
  _repo="$(portageq get_repo_path / gentoo 2>/dev/null || echo /var/db/repos/gentoo)"
  if [ -z "${_prof}" ] || [ ! -d "${_prof}" ] || [ ! -d "${_repo}" ]; then
    echo "  NOTE no host profile/repo to borrow — execution tier SKIPPED"
  else
    ln -s "${_prof}" "${FR}/etc/portage/make.profile"
    printf '[DEFAULT]\nmain-repo = gentoo\n\n[gentoo]\nlocation = %s\n' "${_repo}" \
      > "${FR}/etc/portage/repos.conf/gentoo.conf"
    # shellcheck source=../scripts/_payload-gate-lib.sh
    source "${LIB}"

    # (1) everything present -> rc 0 + the completeness line.
    out="$(requested_atom_gate "${FR}" "${W}" t false sys-kernel/gentoo-sources \
           sys-kernel/gentoo-sources 2>&1)"; rc=$?
    if [ ${rc} -eq 0 ] && [[ "${out}" == *"Package completeness: all"* ]]; then
      ok "clean set passes (${out##*: })"
    else
      bad "clean set failed (rc=${rc}): ${out}"
    fi

    # (2) kernel atom missing -> rc 1 EVEN WITH allow_missing=true.
    out="$(requested_atom_gate "${FR}" "${W}" t true sys-kernel/raspberrypi-sources \
           sys-kernel/raspberrypi-sources 2>&1)"; rc=$?
    if [ ${rc} -ne 0 ] && [[ "${out}" == *"kernel package sys-kernel/raspberrypi-sources is NOT installed"* ]]; then
      ok "missing kernel fails even under --allow-missing-packages"
    else
      bad "missing kernel NOT fatal under allow_missing=true (rc=${rc}): ${out}"
    fi

    # (3) non-kernel atom missing -> rc 1, atom NAMED.
    out="$(requested_atom_gate "${FR}" "${W}" t false sys-kernel/gentoo-sources \
           sys-kernel/gentoo-sources net-firewall/firewalld 2>&1)"; rc=$?
    if [ ${rc} -ne 0 ] && [[ "${out}" == *firewalld* ]]; then
      ok "missing firewalld fails the build and is NAMED (the a775c2 ship-class)"
    else
      bad "missing firewalld not caught/named (rc=${rc}): ${out}"
    fi

    # (4) same, with allow_missing=true -> rc 0 but a LOUD degraded warning.
    out="$(requested_atom_gate "${FR}" "${W}" t true sys-kernel/gentoo-sources \
           sys-kernel/gentoo-sources net-firewall/firewalld 2>&1)"; rc=$?
    if [ ${rc} -eq 0 ] && [[ "${out}" == *"DEGRADED image"* ]]; then
      ok "--allow-missing-packages degrades non-kernel misses to a loud warning"
    else
      bad "allow_missing path broken (rc=${rc}): ${out}"
    fi

    # (5) HOST/TARGET discrimination: sys-apps/portage is necessarily installed
    #     on the build host (portage IS the host package manager) but absent
    #     from the fake target vdb — the gate must report it MISSING. If the
    #     ROOT plumbing ever regresses to the host vdb, this is the case that
    #     catches the resulting vacuous pass.
    out="$(requested_atom_gate "${FR}" "${W}" t false "" sys-apps/portage 2>&1)"; rc=$?
    if [ ${rc} -ne 0 ] && [[ "${out}" == *sys-apps/portage* ]]; then
      ok "gate reads the TARGET vdb, not the host's (host-installed atom reported missing)"
    else
      bad "gate consulted the HOST vdb (rc=${rc}) — vacuous pass: ${out}"
    fi

    # (6) tooling honesty: a sysroot portage cannot construct against must WARN
    #     "NOT verified" and continue (rc 0) — never abort, never pass silently.
    out="$(requested_atom_gate "${TMP}/does-not-exist" "${W}" t false "" x/y 2>&1)"; rc=$?
    if [ ${rc} -eq 0 ] && [[ "${out}" == *"NOT verified"* ]]; then
      ok "tooling failure degrades to a loud WARN (x86-gate posture), not an abort"
    else
      bad "tooling-failure path wrong (rc=${rc}): ${out}"
    fi
  fi
fi

echo "-- D) kernel-less downstream: warns promoted to hard failures --"
# Finding 2's tail: even with the vdb tier, the downstream must never again
# emit "complete" runs with missing bootable artifacts. Old warn-only shapes
# must be GONE; each err path must exist; --skip-kernel keeps a deliberate
# kernel-less build possible (asserted via the flag-gated warn variants).
for b in "${BUILDERS[@]}"; do
  f="${REPO}/${b}"
  echo "   [${b}]"
  # no-sources branch: reuse allowed only when a previously-built kernel exists.
  grep -q 'refusing to continue toward' "${f}" \
    && ok "no-sources branch hard-fails without a prior kernel" \
    || bad "no-sources branch can still warn-skip toward a kernel-less artifact"
  grep -q 'cleaned --resume sysroot); reusing it' "${f}" \
    && ok "…but still allows the legitimate cleaned---resume kernel reuse" \
    || bad "the cleaned---resume reuse path is gone (would break --resume builds)"
done
# The old unconditional warn texts must be gone from their builders.
grep -q 'warn "No raspberrypi-sources found in sysroot, skipping kernel build."' "${REPO}/build-rpi5-stage4.sh" \
  && bad "rpi5 still warn-skips a missing kernel source tree" \
  || ok "rpi5 old warn-skip is gone"
for b in build-frite-stage4.sh build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh \
         build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh \
         build-orangepi3-lts-stage4.sh build-orangepi4-lts-stage4.sh; do
  f="${REPO}/${b}"
  grep -q 'warn "no kernel in boot stage — skipping LIVE image."' "${f}" \
    && bad "${b}: LIVE image still silently skippable without --skip-kernel" \
    || ok "${b}: kernel-less LIVE skip now requires --skip-kernel"
  grep -q 'err "no kernel in boot stage — the requested LIVE image cannot boot' "${f}" \
    && ok "${b}: kernel-less LIVE is a hard error otherwise" \
    || bad "${b}: no hard error for a kernel-less LIVE request"
  # NB: the zero2w/zero3 rules must precede the zero2 rule — sed runs the
  # expressions in order and 'build-orangepi-zero2.*' would swallow both.
  grep -q 'warn "Kernel ${'"$(echo "${b}" | sed 's/build-frite.*/FRITE_KERNEL_IMG/;s/build-orangepi4-lts.*/OPI4LTS_KERNEL_IMG/;s/build-orangepi5.*/OPI5_KERNEL_IMG/;s/build-orangepi-zero2w.*/OPIZ2W_KERNEL_IMG/;s/build-orangepi-zero3.*/OPIZ3_KERNEL_IMG/;s/build-orangepi3-lts.*/OPI3LTS_KERNEL_IMG/;s/build-orangepi-zero2.*/OPIZ2_KERNEL_IMG/')"'} not in sysroot — the boot tree will be incomplete."' "${f}" \
    && bad "${b}: boot tree still built kernel-less with only a warn" \
    || ok "${b}: kernel-less boot tree hard-fails unless --skip-kernel"
done
f="${REPO}/build-jetson-stage4.sh"
grep -q 'warn "no kernel in sysroot /boot — skipping the .img (stage4 is still usable' "${f}" \
  && bad "jetson: .img still silently skippable without --skip-kernel" \
  || ok "jetson: kernel-less .img skip now requires --skip-kernel"
grep -q 'err "no kernel in sysroot /boot — cannot build the .img. The kernel phase was"' "${f}" \
  && ok "jetson: kernel-less .img is a hard error otherwise" \
  || bad "jetson: no hard error for a kernel-less .img"

echo "-- E) the EROOT honesty guard is pinned (defense-in-depth) --"
# Section C's HOST/TARGET discrimination proves the ROOT= plumbing works (drop
# it and 4 checks fail — mutation-verified). What C does NOT exercise is the
# in-python EROOT!=sysroot refusal, because in every C scenario portage really
# does resolve to the fake sysroot, so the guard branch never fires: an
# independent review mutation that blinded the comparison (`if False:`) left
# all of C green. The guard only matters in the one condition a test cannot
# honestly manufacture with stock portage — ROOT set but IGNORED — so pin its
# SHAPE textually: the comparison, its refusal exit, and the caller mapping
# any python failure to the loud NOT-verified WARN rather than a pass.
LIB="${REPO}/scripts/_payload-gate-lib.sh"
grep -q 'os.path.realpath(eroot.rstrip("/") or "/") != os.path.realpath(want or "/")' "${LIB}" \
  && ok "EROOT-vs-sysroot comparison present" \
  || bad "the EROOT honesty comparison is gone — a mis-plumbed ROOT would pass vacuously against the HOST vdb"
grep -q 'sys.exit(3)' "${LIB}" \
  && ok "guard refuses (exit 3) instead of proceeding" \
  || bad "the EROOT guard no longer refuses on mismatch"
grep -q 'portage python API / EROOT resolution error above) — package set NOT verified' "${LIB}" \
  && ok "python failure maps to the loud NOT-verified WARN" \
  || bad "a failing gate python no longer reports 'NOT verified'"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
