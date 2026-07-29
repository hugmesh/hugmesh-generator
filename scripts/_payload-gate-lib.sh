#!/usr/bin/env bash
# _payload-gate-lib.sh — SOURCED helper: requested-atom completeness gate for the
# five CROSS builders (rpi5 / frite / jetson / orangepi5 / orangepi-zero2).
#
# WHY THIS EXISTS — SILENT PACKAGE LOSS REACHED SHIPPED ARM ARTIFACTS.
# The payload emerges run --keep-going, and until this gate the only post-emerge
# assertion was a hand-maintained list of a few BINARIES. A package with no
# binary on that list could fail and the build still exited 0. Not theoretical:
# in session 20260719-103006-a775c2 every rpi5 role log (build-pki.rpi5.log,
# build-be.rpi5.log, build-fe.rpi5.log) carries
#     WARNING:   skipped net-firewall/firewalld
# (pki/be at line 2736, fe at 2755 — a glib[introspection] USE conflict), yet
# pki's line 3817 went on to say
#     Stage4 payload verified (NetworkManager nmcli sshd auditd crond jq parted
#     flashrom rpi-eeprom-update kubelet kubeadm kubectl containerd)
# and all three .img.xz artifacts SHIPPED — with no firewall at all AND a
# dangling 'firewall' entry in the default runlevel (build-rpi5-stage4.sh puts
# `firewall` in DEFAULT_SVCS unconditionally and aliases /etc/init.d/firewall
# -> firewalld, which was never installed).
#
# This is the cross-build twin of build-x86-host-stage4.sh's REQUESTED-ATOM
# COMPLETENESS GATE (PR #461, empty-list false-positive fixed in #465): after
# the payload emerge, EVERY requested atom must have a matching entry in
# portage's vardb, every missing atom is listed, and the build FAILS — with the
# same --allow-missing-packages escape hatch. Differences from the x86 gate,
# both forced by the cross topology:
#
#   1. WHICH vdb. These builders do not chroot for the emerge — they run the
#      host's ${CROSS_TARGET}-emerge with ROOT/SYSROOT/PORTAGE_CONFIGROOT all
#      pointed at the target sysroot (see each builder's cross_emerge()). So the
#      authoritative vdb is ${SYSROOT}/var/db/pkg, NOT the host's, and this gate
#      queries it exactly the way cross_emerge writes it: host python3 with
#      ROOT= and PORTAGE_CONFIGROOT= in the environment before `import portage`.
#      The python additionally REFUSES to run (loud WARN, see below) if the
#      EROOT portage resolved is not the sysroot it was pointed at — a gate that
#      silently fell back to the HOST vdb would pass vacuously, because most of
#      the requested atoms are installed on the build host too.
#   2. KERNEL TIER. A missing sys-kernel/*-sources is not a "degraded image",
#      it is an UNBOOTABLE one (the kernel phase warn-skipped and the artifacts
#      shipped kernel-less with exit 0 — the frite/opi5/opi-zero2/jetson hole).
#      So the kernel atom is checked FIRST and is NOT bypassable by
#      --allow-missing-packages; the only sanctioned way to build without a
#      kernel is the explicit --skip-kernel (the caller passes '' then).
#
# Tooling failure (no python3, portage API error, EROOT mismatch) is a loud
# WARN, not an abort — a gate that kills a multi-hour cross build because its
# own tooling misfired would be worse than the hole it closes (same posture as
# the x86 gate). Only a REAL missing package (or kernel) is fatal.
#
# Shared so the five cross builders cannot drift on the load-bearing bit (same
# reasoning as _binpkg-pool-lib.sh / _dracut-cross-lib.sh).

# requested_atom_gate SYSROOT WORKDIR TAG ALLOW_MISSING KERNEL_ATOM ATOM...
#   SYSROOT       target sysroot whose vdb is authoritative (${SYSROOT})
#   WORKDIR       per-build scratch dir for the atom lists (${BUILD_ROOT} — NOT
#                 /tmp: parallel per-board builds share the host /tmp and the
#                 x86 gate only got away with /tmp because its files live
#                 inside the build chroot)
#   TAG           log prefix, e.g. "build-rpi5"
#   ALLOW_MISSING "true" => degraded image is accepted with a WARN
#                 (--allow-missing-packages); anything else fails the build
#   KERNEL_ATOM   cat/pn whose absence is ALWAYS fatal regardless of
#                 ALLOW_MISSING ('' = no kernel tier, i.e. --skip-kernel)
#   ATOM...       the resolved requested set (the builder's STAGE4_PACKAGES)
# Returns 0 when complete (or degraded-but-allowed / gate could not run);
# returns 1 on a real gap — the caller must abort the build.
requested_atom_gate() {
    local sysroot="$1" workdir="$2" tag="$3" allow_missing="$4" kernel_atom="$5"
    shift 5
    local req="${workdir}/hugmesh-requested-atoms.txt"
    local mis="${workdir}/hugmesh-missing-atoms.txt"
    mkdir -p "${workdir}"
    # The kernel atom is normally already in the set (it comes from
    # packages.list), but append it explicitly so an edited packages.list can
    # never silently exempt the kernel from its own tier.
    { printf '%s\n' "$@"; [ -n "${kernel_atom}" ] && printf '%s\n' "${kernel_atom}"; } > "${req}"
    : > "${mis}"

    if ! command -v python3 >/dev/null 2>&1; then
        # Unreachable in practice — cross_emerge IS host portage IS python3 —
        # kept so a broken PATH degrades honestly instead of passing vacuously.
        printf '[%s] WARN: python3 absent — requested-atom completeness gate SKIPPED (package set NOT verified)\n' "${tag}" >&2
        return 0
    fi

    # One python startup for the whole set (a per-atom portageq loop would add
    # minutes); vardb.match() understands every atom form the lists can carry
    # (plain cat/pn, =cat/pn-ver, <cat/pn-ver, slots, virtuals). Anything
    # portage cannot parse is REPORTED, never skipped. Emit NOTHING when
    # nothing is missing — print("\n".join([])) writes a bare newline, which
    # `grep -c '[^[:space:]]'` below must never miscount as one missing atom
    # (the exact false positive that killed every clean x86 build until #465).
    # ROOT/PORTAGE_CONFIGROOT are exported for the ONE child only — the same
    # env shape cross_emerge() uses for the emerge whose result we are judging.
    if ! REQ_FILE="${req}" ROOT="${sysroot}" PORTAGE_CONFIGROOT="${sysroot}" \
        python3 - >"${mis}" <<'PYEOF'
import os, sys
import portage
eroot = portage.settings["EROOT"]
# Honesty guard: if portage did NOT resolve to the sysroot we pointed it at,
# every lookup below would hit the HOST vdb and pass vacuously. Refuse instead.
want = os.environ["ROOT"].rstrip("/")
if os.path.realpath(eroot.rstrip("/") or "/") != os.path.realpath(want or "/"):
    sys.stderr.write("EROOT %r != requested sysroot %r\n" % (eroot, want))
    sys.exit(3)
vardb = portage.db[eroot]["vartree"].dbapi
seen, out = set(), []
with open(os.environ["REQ_FILE"]) as fh:
    for line in fh:
        atom = line.strip()
        if not atom or atom in seen:
            continue
        seen.add(atom)
        try:
            if not vardb.match(atom):
                out.append(atom)
        except Exception as exc:
            out.append("%s  (unparsable atom: %s)" % (atom, exc))
if out:
    print("\n".join(out))
PYEOF
    then
        printf '[%s] WARN: completeness gate could not run (portage python API / EROOT resolution error above) — package set NOT verified\n' "${tag}" >&2
        return 0
    fi

    # KERNEL TIER first: never maskable by --allow-missing-packages. A kernel
    # that failed to merge under --keep-going used to degrade to a warn-skipped
    # kernel phase and an unbootable artifact with exit 0.
    if [ -n "${kernel_atom}" ] && grep -qxF "${kernel_atom}" "${mis}"; then
        printf '[%s] ERROR: kernel package %s is NOT installed in the target vdb (%s/var/db/pkg).\n' \
            "${tag}" "${kernel_atom}" "${sysroot}" >&2
        printf '[%s]        Its emerge failed under --keep-going; without it the kernel phase has\n' "${tag}" >&2
        printf '[%s]        nothing to build and the artifact CANNOT BOOT. This is not bypassable\n' "${tag}" >&2
        printf '[%s]        with --allow-missing-packages — a kernel-less image is not "degraded",\n' "${tag}" >&2
        printf '[%s]        it is dead. Fix the emerge failure above, or pass --skip-kernel to\n' "${tag}" >&2
        printf '[%s]        deliberately build without a kernel.\n' "${tag}" >&2
        return 1
    fi

    local missing_n
    missing_n=$(grep -c '[^[:space:]]' "${mis}" 2>/dev/null || true)
    [ -n "${missing_n}" ] || missing_n=0
    if [ "${missing_n}" -gt 0 ]; then
        printf '[%s] ERROR: %s requested package(s) are NOT installed in the target vdb:\n' "${tag}" "${missing_n}" >&2
        sed "s/^/[${tag}]          /" "${mis}" >&2
        printf '[%s]        The emerge above ran with --keep-going, so these failed WITHOUT\n' "${tag}" >&2
        printf '[%s]        aborting it. Review the per-package errors in the emerge output.\n' "${tag}" >&2
        if [ "${allow_missing}" = "true" ]; then
            printf '[%s] WARN: --allow-missing-packages given — shipping a DEGRADED image anyway.\n' "${tag}" >&2
            return 0
        fi
        printf '[%s]        Fix them, or rebuild with --allow-missing-packages to accept a\n' "${tag}" >&2
        printf '[%s]        knowingly degraded image.\n' "${tag}" >&2
        return 1
    fi
    printf '[%s] Package completeness: all %s requested atoms installed in the target vdb.\n' \
        "${tag}" "$(sort -u "${req}" | grep -c .)"
    return 0
}
