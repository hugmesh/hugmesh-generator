#!/usr/bin/env bash
# test-btf-pahole-pairing.sh — offline lint: a kernel fragment that asks for BTF must
# be built where pahole exists, and a build that provides pahole must be asking for BTF.
#
# WHY. The bpf LSM can be compiled in and named in CONFIG_LSM and still not enforce:
# attaching a BPF_PROG_TYPE_LSM program needs BTF. CONFIG_DEBUG_INFO_BTF has a
# dependency chain that fails SILENTLY at `make olddefconfig` (no warning, the symbol
# just is not set): DEBUG_INFO must be on (a DWARF choice, which needs DEBUG_KERNEL),
# pahole must be installed when Kconfig runs, and struct layout randomisation must be
# off. Half of that chain living in a fragment and the other half in a package list
# is how it drifts, so this pins the whole chain for the two boards that ship bpf:
# x86 (kernel linked in the sysroot chroot) and rpi5 (kernel cross-linked on the
# builder host, so pahole lives in Dockerfile.build, not in the image).
#
# Static analysis only. It cannot tell you Kconfig keeps the symbols; that is
# tests/scripts/test-btf-kconfig-resolve.sh, which needs a kernel tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

echo "== BTF <-> pahole pairing (x86, rpi5) =="
REPO="${REPO}" python3 - <<'PY'
import os, re, sys

repo = os.environ["REPO"]
P = [0]; F = [0]
def ok(m):  print("  PASS " + m); P[0] += 1
def bad(m): print("  FAIL " + m); F[0] += 1

def read(rel):
    p = os.path.join(repo, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()

def code(text):
    """Drop whole-line comments so prose that explains a line is never read as it."""
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))

def has(ctext, action, sym):
    return bool(re.search(r"^%s\s+%s\s*$" % (action, re.escape(sym)), ctext, re.M))

# The whole chain, in the words of scripts/config. All four or none.
BLOCK = [("enable", "CONFIG_DEBUG_KERNEL"),
         ("enable", "CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT"),
         ("enable", "CONFIG_DEBUG_INFO_BTF"),
         ("enable", "CONFIG_DEBUG_INFO_BTF_MODULES")]
# BTF depends on struct randomisation being off.
RANDSTRUCT_ON = ("CONFIG_RANDSTRUCT_FULL", "CONFIG_RANDSTRUCT_PERFORMANCE")

BOARDS = [
    # board, fragment, builder, where pahole must come from
    ("x86",  "specs-x86/kernel/hardened-k8s.config",  "build-x86-host-stage4.sh",  "chroot"),
    ("rpi5", "specs-rpi5/kernel/hardened-k8s.config", "build-rpi5-stage4.sh",      "host"),
]

def pahole_in_package_list():
    t = read("specs-x86/portage/packages.list")
    return t is not None and bool(re.search(r"^dev-util/pahole\s*$", code(t), re.M))

def x86_topup_before_configure():
    """The chroot installs pahole BEFORE `make defconfig`: Kconfig reads its version
    while it resolves, so a pahole installed after olddefconfig is too late."""
    t = read("build-x86-host-stage4.sh") or ""
    t = code(t)
    m = re.search(r"command -v pahole[^\n]*\n(?:[^\n]*\n){0,4}?[^\n]*emerge[^\n]*dev-util/pahole(?![\w-])", t)
    d = re.search(r"^make defconfig\s*$", t, re.M)
    return bool(m) and d is not None and m.start() < d.start()

def dockerfile_final_stage_has_pahole():
    """dev-util/pahole in the RUN emerge of the FINAL stage (after the crossdev
    stage, so adding it does not invalidate the cached toolchain layer)."""
    t = read("Dockerfile.build")
    if t is None:
        return False
    fm = re.search(r"^FROM\s.*\sAS final\s*$", t, re.M)
    if not fm:
        return False
    i = fm.end()
    for m in re.finditer(r"^RUN emerge(?:[^\n]*\\\n)*[^\n]*", t[i:], re.M):
        if re.search(r"^\s*dev-util/pahole\b", m.group(0), re.M):
            return True
    return False

def rpi5_pahole_checked_before_configure():
    """build-rpi5-stage4.sh links the kernel on the build host, so pahole must be on
    PATH there BEFORE the first Kconfig run (the board defconfig). The Dockerfile line
    alone does not prove that: a builder image built before it lacks pahole, and the
    post-olddefconfig guard only notices after the whole cross @stage4. Pin a
    function that fails on a missing pahole, called (|| exit 1) both in the t=0
    prerequisites and before `make ... "${RPI_DEFCONFIG}"`."""
    t = code(read("build-rpi5-stage4.sh") or "")
    name = None
    for m in re.finditer(r"^(\w+)\(\)\s*\{\n(.*?)^\}", t, re.M | re.S):
        body = m.group(2)
        if re.search(r"if command -v pahole\b[^\n]*; then\s*\n\s*return 0", body) \
                and "return 1" in body and "make docker-image" in body:
            name = m.group(1); break
    if name is None:
        return False, "no function that returns 1 (naming make docker-image) when pahole is missing"
    calls = [c.start() for c in re.finditer(r"^\s*%s \|\| exit 1\s*$" % re.escape(name), t, re.M)]
    prereq = re.search(r'^banner "Verifying prerequisites"', t, re.M)
    defcfg = re.search(r'^\s*make ARCH=arm64 [^\n]*"\$\{RPI_DEFCONFIG\}"\s*$', t, re.M)
    sysroot = re.search(r"^\s*KERNEL_SRC=", t, re.M)
    if not (prereq and defcfg and sysroot):
        return False, "cannot find the prerequisites banner, KERNEL_SRC= or the board defconfig make"
    early = [c for c in calls if prereq.start() < c < sysroot.start()]
    late = [c for c in calls if sysroot.start() < c < defcfg.start()]
    if not early:
        return False, "%s is not called (|| exit 1) in the prerequisites block" % name
    if not late:
        return False, "%s is not called (|| exit 1) between KERNEL_SRC= and the board defconfig make" % name
    return True, name

def guard_ok(btext):
    """The builder's post-olddefconfig loop must name both BTF symbols, exit 1 and
    explain pahole, so a dropped symbol stops the build instead of shipping."""
    for m in re.finditer(r"for must in ([^;\n]*CONFIG_DEBUG_INFO_BTF[^;\n]*); do\n(.*?)\n\s*done", code(btext), re.S):
        names = m.group(1).split()
        if "CONFIG_DEBUG_INFO_BTF" in names and "CONFIG_DEBUG_INFO_BTF_MODULES" in names \
                and "exit 1" in m.group(2) and "pahole" in m.group(2) and ".config" in m.group(2):
            return True
    return False

for board, frag, builder, where in BOARDS:
    ftext, btext = read(frag), read(builder)
    if ftext is None or btext is None:
        bad("%s: cannot read %s" % (board, frag if ftext is None else builder)); continue
    c = code(ftext)

    present = [(a, s) for a, s in BLOCK if has(c, a, s)]
    missing = [s for a, s in BLOCK if (a, s) not in present]
    btf_on = has(c, "enable", "CONFIG_DEBUG_INFO_BTF")
    if btf_on and missing:
        bad("%s: BTF is enabled but the chain is incomplete, olddefconfig will drop it silently; missing %s"
            % (board, ", ".join(missing)))
    elif not btf_on and present and len(present) != len(BLOCK):
        bad("%s: part of the BTF block is present without CONFIG_DEBUG_INFO_BTF: %s"
            % (board, ", ".join(s for _a, s in present)))
    elif btf_on:
        ok("%s: fragment carries the whole BTF chain (DEBUG_KERNEL, DWARF choice, BTF, BTF_MODULES)" % board)
    else:
        ok("%s: fragment carries no BTF" % board)

    rs = [s for s in RANDSTRUCT_ON if has(c, "enable", s)]
    if btf_on and rs:
        bad("%s: fragment enables %s together with BTF — DEBUG_INFO_BTF depends on struct randomisation "
            "being off, so one of them is silently lost" % (board, ", ".join(rs)))
    else:
        ok("%s: no struct randomisation choice is enabled beside BTF" % board)

    if where == "chroot":
        provided = pahole_in_package_list() and x86_topup_before_configure()
        what = "specs-x86/portage/packages.list plus the chroot top-up emerge before make defconfig"
    else:
        provided = dockerfile_final_stage_has_pahole()
        what = "Dockerfile.build final-stage emerge"
    if where == "host" and btf_on:
        good, why = rpi5_pahole_checked_before_configure()
        if good:
            ok("%s: %s checks pahole (fails, names make docker-image) at t=0 and before the board defconfig" % (board, builder))
        else:
            bad("%s: %s does not fail early on a missing pahole: %s" % (board, builder, why))
    if btf_on and not provided:
        bad("%s: BTF is enabled but pahole is not provided by %s" % (board, what))
    elif provided and not btf_on:
        bad("%s: pahole is provided by %s but the fragment does not enable BTF" % (board, what))
    elif btf_on:
        ok("%s: pahole is provided by %s" % (board, what))
    else:
        ok("%s: neither BTF nor pahole" % board)

    if btf_on:
        if guard_ok(btext):
            ok("%s: %s fails the build (exit 1, names pahole) when olddefconfig drops BTF" % (board, builder))
        else:
            bad("%s: %s has no fail-closed post-olddefconfig guard over CONFIG_DEBUG_INFO_BTF and "
                "CONFIG_DEBUG_INFO_BTF_MODULES that names pahole" % (board, builder))

# The pairing must not leak into the image on the rpi5 side: pahole there is a build
# host tool, and an arm64 pahole in the image would never run at kernel link time.
pi_list = read("specs-rpi5/portage/packages.list")
if pi_list is not None and re.search(r"^dev-util/pahole\s*$", code(pi_list), re.M):
    bad("specs-rpi5/portage/packages.list lists dev-util/pahole — the rpi5 kernel is linked on the build "
        "host (Dockerfile.build), so this ships an arm64 pahole that never runs at link time")
else:
    ok("specs-rpi5/portage/packages.list does not ship pahole (it belongs to the build host)")

print("== %d passed, %d failed ==" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
rc=$?
echo "== RESULT: rc=${rc} =="
exit "${rc}"
