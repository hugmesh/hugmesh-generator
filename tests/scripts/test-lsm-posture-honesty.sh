#!/usr/bin/env bash
# test-lsm-posture-honesty.sh — offline lint proving the LSM posture each image
# ADVERTISES is the one its kernel can actually RUN.
#
# THE DEFECT THIS EXISTS TO STOP (found 2026-08-14, shipped on every board).
# The Linux kernel does not diagnose an `lsm=` name it cannot resolve. If a name
# in CONFIG_LSM / the boot cmdline has no module compiled in, the kernel prints a
# SHORTER "LSM: initializing lsm=..." line and boots on. Nothing fails, nothing
# warns. So `yama` and `bpf` sat in CONFIG_LSM, in specs-x86/etc/default/grub, in
# the generated grub.cfg AND in the signed UKI's .cmdline for months while the
# running kernel had neither:
#   out/qemu-runs/runs/newbuild2_x86-pki/launch/console.log:11
#     Command line: ... lsm=lockdown,yama,selinux,bpf lockdown=integrity ...
#   out/qemu-runs/runs/newbuild2_x86-pki/launch/console.log:181
#     LSM: initializing lsm=lockdown,capability,selinux
#   out/qemu-runs/runs/rpi5_pki/launch/console.log:79 — identical on the Pi.
# Two of the four advertised LSMs were decoration. Neither the build guard (which
# string-matched CONFIG_LSM and nothing else) nor the boot-verify (which grepped
# /proc/cmdline for the word "lockdown" — the image's claim about itself) could
# see it, because both graded the string rather than the kernel.
#
# The properties below make that unshippable without a build:
#   1) every name in a fragment's CONFIG_LSM has its enabling CONFIG_* symbol
#      set IN THAT SAME FRAGMENT;
#   2) the board's boot cmdline asks for exactly what its fragment builds — in
#      both directions, for lsm= and for lockdown=;
#   3) each builder's guard is fail-closed AND derives its required symbols from
#      CONFIG_LSM, so a name added later cannot outlive its module;
#   4) lockdown is a FLEET posture: all 10 boards build it, list it first in
#      CONFIG_LSM and lsm=, and pass lockdown=integrity (1-3 alone pass "neither").
# Plus two guards on the surrounding plumbing: the x86 grub cmdline (a build INPUT
# with a silent `${VAR:-short}` degradation path) and the QEMU launchers, which
# boot with -kernel/-append and so can grade their own literal instead of the image.
#
# Pure static analysis. No network, no root, no docker, no kernel tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== LSM posture honesty: the advertised stack is the runnable stack =="

REPO="${REPO}" python3 - <<'PY'
import os, re, sys

repo = os.environ["REPO"]
P = [0]; F = [0]
def ok(m):  print("  PASS " + m); P[0] += 1
def bad(m): print("  FAIL " + m); F[0] += 1

# name in CONFIG_LSM -> the Kconfig symbol that compiles it in.
# `capability` is always built with CONFIG_SECURITY and is never listed.
LSM_SYMBOL = {
    "lockdown":  "CONFIG_SECURITY_LOCKDOWN_LSM",
    "yama":      "CONFIG_SECURITY_YAMA",
    "selinux":   "CONFIG_SECURITY_SELINUX",
    "bpf":       "CONFIG_BPF_LSM",
    "apparmor":  "CONFIG_SECURITY_APPARMOR",
    "loadpin":   "CONFIG_SECURITY_LOADPIN",
    "safesetid": "CONFIG_SECURITY_SAFESETID",
    "landlock":  "CONFIG_SECURITY_LANDLOCK",
    "integrity": "CONFIG_INTEGRITY",
}

# board -> (kernel fragment, cmdline file, cmdline kind, builder)
# cmdline kind: "raw" = the file IS the cmdline; "grub" = GRUB_CMDLINE_LINUX=.
BOARDS = [
    ("x86",             "specs-x86/kernel/hardened-k8s.config",                 "specs-x86/etc/default/grub",          "grub", "build-x86-host-stage4.sh"),
    ("rpi5",            "specs-rpi5/kernel/hardened-k8s.config",                "specs-rpi5/boot/cmdline.txt.tmpl",    "raw",  "build-rpi5-stage4.sh"),
    ("frite",           "specs-frite/kernel/hardened-desktop.config",           "specs-frite/boot/cmdline.base",       "raw",  "build-frite-stage4.sh"),
    ("jetson",          "specs-jetson/kernel/hardened-node.config",             "specs-jetson/boot/cmdline.base",      "raw",  "build-jetson-stage4.sh"),
    ("orangepi-zero2",  "specs-orangepi-zero2/kernel/hardened-appliance.config",  "specs-orangepi-zero2/boot/cmdline.base",  "raw", "build-orangepi-zero2-stage4.sh"),
    ("orangepi-zero2w", "specs-orangepi-zero2w/kernel/hardened-appliance.config", "specs-orangepi-zero2w/boot/cmdline.base", "raw", "build-orangepi-zero2w-stage4.sh"),
    ("orangepi-zero3",  "specs-orangepi-zero3/kernel/hardened-appliance.config",  "specs-orangepi-zero3/boot/cmdline.base",  "raw", "build-orangepi-zero3-stage4.sh"),
    ("orangepi3-lts",   "specs-orangepi3-lts/kernel/hardened-appliance.config",   "specs-orangepi3-lts/boot/cmdline.base",   "raw", "build-orangepi3-lts-stage4.sh"),
    ("orangepi4-lts",   "specs-orangepi4-lts/kernel/hardened-desktop.config",     "specs-orangepi4-lts/boot/cmdline.base",   "raw", "build-orangepi4-lts-stage4.sh"),
    ("orangepi5",       "specs-orangepi5/kernel/hardened-desktop.config",         "specs-orangepi5/boot/cmdline.base",       "raw", "build-orangepi5-stage4.sh"),
]

def read(rel):
    p = os.path.join(repo, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()

# The two fragment dialects: x86/rpi5 are scripts/config action lines
# (`enable CONFIG_X` / `set-str CONFIG_LSM "…"`), the ARM boards are literal
# .config lines (`CONFIG_X=y`). Both must parse, or a lint that only understands
# one dialect silently exempts the other half of the fleet.
def frag_lsm(text):
    m = re.search(r'^set-str\s+CONFIG_LSM\s+"([^"]*)"\s*$', text, re.M) \
        or re.search(r'^CONFIG_LSM="([^"]*)"\s*$', text, re.M)
    return m.group(1) if m else None

def frag_enables(text, sym):
    return bool(re.search(r'^enable\s+%s\s*$' % re.escape(sym), text, re.M)
                or re.search(r'^%s=y\s*$' % re.escape(sym), text, re.M))

def cmdline_of(text, kind):
    if kind == "grub":
        m = re.search(r'^GRUB_CMDLINE_LINUX="([^"]*)"\s*$', text, re.M)
        return m.group(1) if m else None
    return text.strip()

def token(cmdline, key):
    for t in cmdline.split():
        if t.startswith(key + "="):
            return t[len(key) + 1:]
    return None

print()
print("-- 1) every name in CONFIG_LSM has its module compiled in the same fragment --")
lsm_by_board = {}
for board, frag, cmdf, kind, builder in BOARDS:
    text = read(frag)
    if text is None:
        bad("%s: fragment %s is missing" % (board, frag)); continue
    names = frag_lsm(text)
    if names is None:
        bad("%s: %s declares no CONFIG_LSM" % (board, frag)); continue
    lsm_by_board[board] = names
    missing, unknown = [], []
    for n in [x for x in names.split(",") if x]:
        if n == "capability":
            continue
        sym = LSM_SYMBOL.get(n)
        if sym is None:
            unknown.append(n); continue
        if not frag_enables(text, sym):
            missing.append("%s (needs %s)" % (n, sym))
    if unknown:
        bad("%s: CONFIG_LSM names %s — unknown to this lint; add the enabling symbol to LSM_SYMBOL"
            % (board, ", ".join(unknown)))
    elif missing:
        bad("%s: CONFIG_LSM=\"%s\" names LSMs the fragment does not build: %s — the kernel will SILENTLY DROP them"
            % (board, names, "; ".join(missing)))
    else:
        ok("%s: every LSM in \"%s\" is compiled in by %s" % (board, names, os.path.basename(frag)))

print()
print("-- 2) the boot cmdline asks for exactly what the fragment builds --")
for board, frag, cmdf, kind, builder in BOARDS:
    ftext, ctext = read(frag), read(cmdf)
    if ftext is None or ctext is None:
        bad("%s: cannot compare (missing %s)" % (board, frag if ftext is None else cmdf)); continue
    cmdline = cmdline_of(ctext, kind)
    if cmdline is None:
        bad("%s: %s defines no cmdline" % (board, cmdf)); continue
    want = lsm_by_board.get(board)
    got = token(cmdline, "lsm")
    if want is None:
        continue
    if got is None:
        bad("%s: %s carries no lsm= (fragment builds \"%s\")" % (board, cmdf, want))
    elif got != want:
        bad("%s: cmdline lsm=%s != CONFIG_LSM=\"%s\" — %s boots a different stack than it builds"
            % (board, got, want, cmdf))
    else:
        ok("%s: cmdline lsm=%s matches CONFIG_LSM" % (board, got))
    # lockdown= and CONFIG_SECURITY_LOCKDOWN_LSM must agree in BOTH directions.
    # Requesting a level the kernel cannot enforce is the same lie in a second
    # spelling; building it and never asking for it is dead weight.
    builds_lockdown = frag_enables(ftext, "CONFIG_SECURITY_LOCKDOWN_LSM")
    asks_lockdown = token(cmdline, "lockdown") is not None
    if builds_lockdown and not asks_lockdown:
        bad("%s: fragment builds CONFIG_SECURITY_LOCKDOWN_LSM but %s never passes lockdown=" % (board, cmdf))
    elif asks_lockdown and not builds_lockdown:
        bad("%s: %s passes lockdown=%s but the fragment does not build CONFIG_SECURITY_LOCKDOWN_LSM"
            % (board, cmdf, token(cmdline, "lockdown")))
    else:
        ok("%s: lockdown posture agrees (built=%s, requested=%s)" % (board, builds_lockdown, asks_lockdown))

print()
print("-- 3) each builder's guard is fail-closed AND derives symbols from CONFIG_LSM --")
for board, frag, cmdf, kind, builder in BOARDS:
    btext = read(builder)
    if btext is None:
        bad("%s: builder %s is missing" % (board, builder)); continue
    want = lsm_by_board.get(board)
    # The exact-string assert must name the SAME stack the fragment declares, or
    # the guard passes a build whose fragment has already drifted.
    if want is not None and ('CONFIG_LSM="%s"' % want) not in btext:
        bad("%s: %s does not assert CONFIG_LSM=\"%s\" (the value its fragment sets)" % (board, builder, want))
    else:
        ok("%s: %s asserts the fragment's exact CONFIG_LSM string" % (board, builder))
    # ...and the derived per-name guard, which is what makes a NEW name fail
    # rather than ship. Match on its load-bearing parts, not on formatting.
    # The x86 copy lives inside an unquoted `<<CHROOT` heredoc, so its runtime
    # `$` are written `\$`; accept either spelling or this lint would exempt the
    # one builder whose guard is hardest to read.
    derived = (re.search(r'for _l in \\?\$\(sed -n', btext)
               and 'CONFIG_LSM=' in btext
               and '_sym=CONFIG_SECURITY_YAMA' in btext
               and '_sym=CONFIG_BPF_LSM' in btext
               and 'SILENTLY DROP' in btext)
    if not derived:
        bad("%s: %s has no derived per-LSM guard — a name added to CONFIG_LSM without its "
            "CONFIG_* symbol would build green and boot without it" % (board, builder))
    else:
        ok("%s: %s derives the required CONFIG_* set from CONFIG_LSM" % (board, builder))
    # A guard that cannot exit non-zero is not a guard.
    if not re.search(r'SILENTLY DROP[^\n]*exit 1', btext):
        bad("%s: %s's derived LSM guard does not exit 1" % (board, builder))
    else:
        ok("%s: %s's derived LSM guard is fail-closed (exit 1)" % (board, builder))

print()
print("-- 4) the x86 grub cmdline is asserted at build time --")
# specs-x86/etc/default/grub is read by the UKI .cmdline, build_img's grub.cfg and
# the live-ISO menu, all three as `${GRUB_CMDLINE_LINUX:-<short fallback>}`. That
# fallback drops vsyscall=none, every cgroup param, slab_nomerge, init_on_alloc,
# page_alloc.shuffle, randomize_kstack_offset and BOTH console= entries — the last
# of which is what the serial boot-verify harness reads. An empty file degrades in
# silence; a truncated one ships verbatim. So the params must be present AND the
# builder must assert them.
GRUB_REQUIRED = [
    "lsm=lockdown,yama,selinux,bpf", "lockdown=integrity", "selinux=1", "audit=1",
    "vsyscall=none", "cgroup_enable=cpuset", "cgroup_enable=memory", "cgroup_memory=1",
    "slab_nomerge", "init_on_alloc=1", "page_alloc.shuffle=1",
    "randomize_kstack_offset=on", "console=tty0", "console=ttyS0,115200",
]
gtext = read("specs-x86/etc/default/grub")
if gtext is None:
    bad("specs-x86/etc/default/grub is missing")
else:
    cmdline = cmdline_of(gtext, "grub")
    if not cmdline:
        bad("specs-x86/etc/default/grub defines no GRUB_CMDLINE_LINUX")
    else:
        toks = cmdline.split()
        gone = [p for p in GRUB_REQUIRED if p not in toks]
        if gone:
            bad("specs-x86/etc/default/grub is missing: %s" % ", ".join(gone))
        else:
            ok("specs-x86/etc/default/grub carries all %d hardening/console params" % len(GRUB_REQUIRED))
btext = read("build-x86-host-stage4.sh")
if btext is None:
    bad("build-x86-host-stage4.sh is missing")
else:
    # The assertion must cover the FULL set, not a token subset: a guard that
    # checks only lsm= would still let the console= entries vanish.
    guard = re.search(r'_grub_cmdline=.*?\ndone\n', btext, re.S)
    gtxt = guard.group(0) if guard else ""
    gone = [p for p in GRUB_REQUIRED if p not in gtxt]
    if not gtxt:
        bad("build-x86-host-stage4.sh does not assert GRUB_CMDLINE_LINUX at all "
            "(an empty/truncated specs-x86/etc/default/grub would degrade silently)")
    elif gone:
        bad("build-x86-host-stage4.sh's grub-cmdline assert omits: %s" % ", ".join(gone))
    elif "exit 1" not in gtxt:
        bad("build-x86-host-stage4.sh's grub-cmdline assert does not exit 1")
    else:
        ok("build-x86-host-stage4.sh asserts all %d params and is fail-closed" % len(GRUB_REQUIRED))

print()
print("-- 5) the QEMU launchers do not grade their own literal --")
# launch-x86.sh passes NO -kernel/-append (firmware + GRUB chain runs), so the
# guest cmdline is genuinely the image's. The ARM/Pi launchers MUST use -append,
# because QEMU models none of those SoCs — which means a hardcoded lsm=/lockdown=
# there overrides the image and the in-guest assertions grade the harness.
launchers = [
    ("tests/qemu/launch-pi.sh",     "specs-rpi5/boot/cmdline.txt.tmpl"),
    ("tests/qemu/run-qemu-test.sh", "specs-rpi5/boot/cmdline.txt.tmpl"),
]
def code_only(text):
    """Drop whole-line comments. These files DOCUMENT the old hardcoded strings
    in their own WHY comments, and a naive grep would read the explanation of the
    defect as the defect."""
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))

for rel, specrel in launchers:
    ltext, stext = read(rel), read(specrel)
    if ltext is None or stext is None:
        bad("%s: cannot compare against %s" % (rel, specrel)); continue
    spec_lsm = token(stext.strip(), "lsm")
    hard = re.findall(r'lsm=([^\s"\\]+)', code_only(ltext))
    off = sorted({h for h in hard if h != spec_lsm})
    if off:
        bad("%s hardcodes lsm=%s but %s ships lsm=%s — the in-guest LSM assertions would "
            "grade the harness's literal" % (rel, ", ".join(off), specrel, spec_lsm))
    else:
        ok("%s's cmdline matches %s (lsm=%s)" % (os.path.basename(rel), os.path.basename(specrel), spec_lsm))
# launch-arm.sh serves 8 different boards, so it must DERIVE the posture rather
# than carry any literal at all.
atext = read("tests/qemu/launch-arm.sh")
if atext is None:
    bad("tests/qemu/launch-arm.sh is missing")
elif re.search(r'lsm=[a-z]', code_only(atext)):
    bad("tests/qemu/launch-arm.sh still hardcodes an lsm= literal — it boots 8 boards "
        "with different postures and must read each board's cmdline.base")
elif "cmdline.base" not in atext or "LSM_APPEND" not in atext:
    bad("tests/qemu/launch-arm.sh does not derive its security posture from the board's cmdline.base")
else:
    ok("launch-arm.sh derives each board's posture from its own cmdline.base")

print()
print("-- 6) lockdown is a FLEET posture: all 10 boards build it AND ask for it --")
# Properties 1-2 only require the fragment and the cmdline to AGREE, so "neither"
# passes them. That is exactly how 8 of 10 boards sat without lockdown for months
# while the lint stayed green: lockdown was a 2-of-10 posture and nothing said so.
# This pins the stronger claim. A board that drops lockdown must now be a decision
# that edits this lint, not a silent disagreement-free omission.
import glob
listed = {frag for _b, frag, _c, _k, _bl in BOARDS}
on_disk = {os.path.relpath(g, repo) for g in glob.glob(os.path.join(repo, "specs-*", "kernel", "hardened-*.config"))}
unlisted = sorted(on_disk - listed)
if unlisted:
    bad("hardened kernel fragments not covered by BOARDS (a new board escapes every property above): %s"
        % ", ".join(unlisted))
else:
    ok("every specs-*/kernel/hardened-*.config on disk (%d) is a board this lint grades" % len(on_disk))
for board, frag, cmdf, kind, builder in BOARDS:
    ftext, ctext = read(frag), read(cmdf)
    if ftext is None or ctext is None:
        bad("%s: cannot grade fleet lockdown (missing %s)" % (board, frag if ftext is None else cmdf)); continue
    problems = []
    for sym in ("CONFIG_SECURITY_LOCKDOWN_LSM", "CONFIG_SECURITY_LOCKDOWN_LSM_EARLY"):
        if not frag_enables(ftext, sym):
            problems.append("%s not enabled in %s" % (sym, os.path.basename(frag)))
    names = (frag_lsm(ftext) or "").split(",")
    if names[0] != "lockdown":
        problems.append('CONFIG_LSM="%s" does not start with lockdown (it must run before every other LSM)'
                        % (frag_lsm(ftext) or ""))
    cmd = cmdline_of(ctext, kind) or ""
    if (token(cmd, "lsm") or "").split(",")[0] != "lockdown":
        problems.append("%s lsm=%s does not start with lockdown" % (cmdf, token(cmd, "lsm")))
    if token(cmd, "lockdown") != "integrity":
        problems.append("%s passes lockdown=%s, expected integrity" % (cmdf, token(cmd, "lockdown")))
    if problems:
        bad("%s: not in the fleet lockdown posture: %s" % (board, "; ".join(problems)))
    else:
        ok("%s: lockdown built, first in CONFIG_LSM and lsm=, and lockdown=integrity requested" % board)
# bpf is the OTHER half of the old 2-of-10 split and is deliberately NOT a fleet
# claim: the ARM boards still name no `bpf` because they build no CONFIG_BPF_LSM,
# and property 1 already fails the build if one names it without the symbol. State
# the current truth here so promoting it is a visible edit, not drift.
arm_with_bpf = [b for b, frag, *_ in BOARDS
                if b not in ("x86", "rpi5") and "bpf" in (frag_lsm(read(frag) or "") or "").split(",")]
if arm_with_bpf:
    bad("ARM boards name bpf in CONFIG_LSM: %s — update this lint and the roadmap together once "
        "CONFIG_BPF_LSM + BTF are really built there" % ", ".join(arm_with_bpf))
else:
    ok("no ARM board names bpf in CONFIG_LSM (CONFIG_BPF_LSM + BTF are x86/rpi5-only, still pahole-gated)")

print()
print("== %d passed, %d failed ==" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
rc=$?
if [ "${rc}" -eq 0 ]; then
    ok "every board advertises an LSM posture its own kernel can actually run"
else
    bad "the analyser above reported at least one board whose advertised LSM posture is not runnable"
fi

echo "== RESULT: ${P} passed, ${F} failed (roll-up; per-property detail above) =="
[ "${F}" -eq 0 ]
