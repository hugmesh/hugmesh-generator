#!/usr/bin/env bash
# test-virtual-display-kernel.sh — offline lint proving every desktop image the
# containerised QEMU runner can open in a RESIZING window has the guest-kernel
# half of that promise, and that the board table in docs/CLIENT-IMAGES.md says
# exactly what the kernel fragments deliver — no more (a "guest resize" row over a
# serial-only kernel) and no less (a resize-capable kernel documented as serial).
#
# WHY THE FRAGMENTS, NOT THE DEFCONFIG. The viewer sends its window size to QEMU;
# the virtio-gpu device raises a new preferred mode on its DRM connector; only a
# kernel with CONFIG_DRM_VIRTIO_GPU sees it, and only one with CONFIG_VIRTIO_INPUT
# gets the tablet/keyboard, and the session-side autofit/agent path needs
# CONFIG_INPUT_UINPUT. x86_64_defconfig happens to carry the first two today and
# bcm2712_defconfig carries NONE of them; the generic arm64 defconfig the three
# merge_config boards build from carries none either. A defconfig is an upstream
# file a version bump rewrites, so the contract is pinned in the repo's own
# fragments, in the chain the builder actually applies, with LAST-WINS semantics
# (a `disable`/`# … is not set` appended after an `enable` wins in both dialects,
# and `=m` is not `=y` for a kernel that mounts root without an initramfs).
#
# Properties:
#   1) each "guest resize" board's fragment chain ends with the three symbols =y;
#   2) their Kconfig menus/parents are set in the SAME chain (olddefconfig drops a
#      leaf whose menu is off with no message: INPUT_UINPUT needs INPUT_MISC, …);
#   3) the docs table lists every board that has a desktop fragment (plus jetson),
#      names fragment files that exist, and its capability column equals what the
#      chain implies — both directions;
#   4) a "serial only" board does not claim virtio-gpu anywhere in its fragments;
#   5) each builder still applies its desktop fragment (a renamed fragment would
#      pass 1-4 and ship nothing).
#
# `--self-test` runs a mutation battery: each mutation must CHANGE a file and must
# turn this lint red. Pure static analysis: no network, no root, no kernel tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${VDK_REPO:-$(cd "${HERE}/../.." && pwd)}"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

run_lint() {
REPO="$1" python3 - <<'PY'
import os, re, sys, glob

repo = os.environ["REPO"]
P = [0]; F = [0]
def ok(m):  print("  PASS " + m); P[0] += 1
def bad(m): print("  FAIL " + m); F[0] += 1

NEEDED = ["CONFIG_DRM_VIRTIO_GPU", "CONFIG_VIRTIO_INPUT", "CONFIG_INPUT_UINPUT"]

# board -> (dialect, fragment chain in builder order, builder script,
#           the fragment the builder must name for the desktop role)
# dialect: "actions" = scripts/config lines (`enable CONFIG_X`), applied per line
# then olddefconfig; "literal" = .config lines merged by merge_config.sh.
BOARDS = {
    "x86":           ("actions", ["specs-x86/kernel/hardened-k8s.config", "specs-x86/kernel/desktop.config"],
                      "build-x86-host-stage4.sh", "kernel/desktop.config"),
    "rpi5":          ("actions", ["specs-rpi5/kernel/hardened-k8s.config", "specs-rpi5/kernel/desktop.config"],
                      "build-rpi5-stage4.sh", "kernel/desktop.config"),
    "frite":         ("literal", ["specs-frite/kernel/hardened-desktop.config"],
                      "build-frite-stage4.sh", "kernel/hardened-desktop.config"),
    "orangepi5":     ("literal", ["specs-orangepi5/kernel/hardened-desktop.config"],
                      "build-orangepi5-stage4.sh", "kernel/hardened-desktop.config"),
    "orangepi4-lts": ("literal", ["specs-orangepi4-lts/kernel/hardened-desktop.config"],
                      "build-orangepi4-lts-stage4.sh", "kernel/hardened-desktop.config"),
    "jetson":        ("literal", ["specs-jetson/kernel/hardened-node.config", "specs-jetson/kernel/tegra234.config"],
                      "build-jetson-stage4.sh", "kernel/tegra234.config"),
}

# Kconfig parents that must be requested in the same chain, per dialect. The
# literal boards merge onto the generic arm64 defconfig, so they state the virtio
# bus too; the actions boards get VIRTIO_PCI from their base fragment.
DEPS = {
    "actions": {"CONFIG_DRM_VIRTIO_GPU": ["CONFIG_DRM"],
                "CONFIG_VIRTIO_INPUT":   ["CONFIG_VIRTIO_PCI"],
                "CONFIG_INPUT_UINPUT":   ["CONFIG_INPUT_MISC"]},
    "literal": {"CONFIG_DRM_VIRTIO_GPU": ["CONFIG_DRM", "CONFIG_VIRTIO_MENU", "CONFIG_VIRTIO_PCI"],
                "CONFIG_VIRTIO_INPUT":   ["CONFIG_VIRTIO"],
                "CONFIG_INPUT_UINPUT":   ["CONFIG_INPUT_MISC"]},
}

def read(rel):
    p = os.path.join(repo, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()

ACT = re.compile(r'^\s*(enable|disable|module|set-val|set-str|undefine)\s+(CONFIG_[A-Z0-9_]+)(?:\s|$)')
LIT_SET = re.compile(r'^\s*(CONFIG_[A-Z0-9_]+)=(y|m|n)\s*$')
LIT_UNSET = re.compile(r'^\s*#\s*(CONFIG_[A-Z0-9_]+) is not set\s*$')

def chain_state(dialect, files):
    """Final state of every symbol after the chain, last assignment wins."""
    state = {}
    for rel in files:
        text = read(rel)
        if text is None:
            return None
        for line in text.splitlines():
            if dialect == "actions":
                if re.match(r'^\s*#', line):
                    continue
                m = ACT.match(line)
                if not m:
                    continue
                act, sym = m.groups()
                state[sym] = {"enable": "y", "module": "m", "disable": "n",
                              "undefine": "n", "set-val": "y", "set-str": "y"}[act]
            else:
                m = LIT_SET.match(line)
                if m:
                    state[m.group(1)] = m.group(2); continue
                m = LIT_UNSET.match(line)
                if m:
                    state[m.group(1)] = "n"
    return state

def resize_capable(state):
    return state is not None and all(state.get(s) == "y" for s in NEEDED)

print()
print("-- 1) the resize-capable chains end with virtio-gpu, virtio-input and uinput =y --")
implied = {}
for board, (dialect, files, builder, named) in BOARDS.items():
    st = chain_state(dialect, files)
    if st is None:
        bad("%s: a fragment in %s is missing" % (board, files)); implied[board] = None; continue
    implied[board] = "guest resize" if resize_capable(st) else "serial only"
    if board == "jetson":
        continue
    missing = ["%s=%s" % (s, st.get(s, "unset")) for s in NEEDED if st.get(s) != "y"]
    if missing:
        bad("%s: chain %s does not end with all three =y: %s" % (board, " + ".join(files), ", ".join(missing)))
    else:
        ok("%s: %s end with %s =y" % (board, " + ".join(os.path.basename(f) for f in files), ", ".join(NEEDED)))

print()
print("-- 2) their Kconfig parents are requested in the same chain --")
for board, (dialect, files, builder, named) in BOARDS.items():
    if board == "jetson":
        continue
    st = chain_state(dialect, files) or {}
    gaps = []
    for sym, parents in DEPS[dialect].items():
        for p in parents:
            if st.get(p) != "y":
                gaps.append("%s needs %s (=%s)" % (sym, p, st.get(p, "unset")))
    if gaps:
        bad("%s: %s" % (board, "; ".join(gaps)))
    else:
        ok("%s: every parent of the three symbols is =y in the chain" % board)

print()
print("-- 3) docs/CLIENT-IMAGES.md's board table says what the fragments deliver --")
doc = read("docs/CLIENT-IMAGES.md")
rows = {}
if doc is None:
    bad("docs/CLIENT-IMAGES.md missing")
else:
    m = re.search(r'^## Emulated desktop display.*?$(.*?)^## ', doc, re.M | re.S)
    section = m.group(1) if m else ""
    for line in section.splitlines():
        if not line.startswith("|") or line.startswith("|---") or "Board (desktop image)" in line:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 3:
            bad("table row has %d cells, want 3: %r" % (len(cells), line)); continue
        board = cells[0].split()[0]
        frags = re.findall(r'`([^`]+)`', cells[1])
        rows[board] = (frags, cells[2].strip().lower())
    if not rows:
        bad("the 'Emulated desktop display' table is missing or empty")

# every board with a desktop fragment on disk (+ jetson) must have a row
on_disk = set()
for f in glob.glob(os.path.join(repo, "specs-*", "kernel", "desktop.config")) + \
         glob.glob(os.path.join(repo, "specs-*", "kernel", "hardened-desktop.config")):
    on_disk.add(os.path.basename(os.path.dirname(os.path.dirname(f)))[len("specs-"):])
on_disk.add("jetson")
for board in sorted(on_disk):
    if board not in rows:
        bad("%s has a desktop kernel fragment (or is jetson) but no row in the table" % board)
    elif board not in BOARDS:
        bad("%s is in the table but this lint has no chain for it — add it to BOARDS" % board)
for board in sorted(rows):
    if board not in on_disk:
        bad("table row %s names a board with no desktop fragment on disk" % board)
for board, (frags, cap) in sorted(rows.items()):
    if board not in BOARDS:
        continue
    for f in frags:
        if read(f) is None:
            bad("%s row names %s, which does not exist" % (board, f))
    if sorted(frags) != sorted(BOARDS[board][1]):
        bad("%s row names %s; the builder applies %s" % (board, frags, BOARDS[board][1]))
    if cap not in ("guest resize", "serial only"):
        bad("%s row capability %r is neither 'guest resize' nor 'serial only'" % (board, cap))
    elif implied.get(board) is None:
        pass
    elif cap != implied[board]:
        bad("%s row says '%s' but its fragment chain implies '%s'" % (board, cap, implied[board]))
    else:
        ok("%s row: '%s' matches the chain" % (board, cap))

print()
print("-- 4) a serial-only board claims no virtio-gpu --")
for board, (frags, cap) in sorted(rows.items()):
    if cap != "serial only" or board not in BOARDS:
        continue
    st = chain_state(BOARDS[board][0], BOARDS[board][1]) or {}
    if st.get("CONFIG_DRM_VIRTIO_GPU") in ("y", "m"):
        bad("%s is documented 'serial only' but its fragments set CONFIG_DRM_VIRTIO_GPU=%s" % (board, st["CONFIG_DRM_VIRTIO_GPU"]))
    else:
        ok("%s: serial only, and no fragment enables CONFIG_DRM_VIRTIO_GPU" % board)

print()
print("-- 5) every builder still applies the desktop fragment the chain relies on --")
for board, (dialect, files, builder, named) in BOARDS.items():
    text = read(builder)
    if text is None:
        bad("%s: %s missing" % (board, builder)); continue
    live = [l for l in text.splitlines() if named in l and not re.match(r'^\s*#', l)]
    if live:
        ok("%s: %s names %s on a live line" % (board, builder, named))
    else:
        bad("%s: %s never names %s outside a comment — the fragment would never be applied" % (board, builder, named))

print()
print("== %d passed, %d failed ==" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
}

self_test() {
    # Each mutation: a sed/append over a COPY of the tree; it must change the file
    # (otherwise the case proves nothing) and must turn the lint red.
    local base tmp n=0 failed=0
    base="$(mktemp -d "${TMPDIR:-/tmp}/vdk-selftest.XXXXXX")"
    copy_tree() {
        local dst="$1"
        mkdir -p "${dst}/docs" "${dst}/tests/scripts"
        cp -r "${REPO}"/specs-x86 "${REPO}"/specs-rpi5 "${REPO}"/specs-frite \
              "${REPO}"/specs-orangepi5 "${REPO}"/specs-orangepi4-lts "${REPO}"/specs-jetson "${dst}/" 2>/dev/null
        cp "${REPO}/docs/CLIENT-IMAGES.md" "${dst}/docs/"
        cp "${REPO}"/build-x86-host-stage4.sh "${REPO}"/build-rpi5-stage4.sh "${REPO}"/build-frite-stage4.sh \
           "${REPO}"/build-orangepi5-stage4.sh "${REPO}"/build-orangepi4-lts-stage4.sh "${REPO}"/build-jetson-stage4.sh "${dst}/"
    }
    # name, file, mutation (a bash snippet run with $f = the file in the copy)
    local -a CASES=(
        "x86 loses uinput|specs-x86/kernel/desktop.config|sed -i '/^enable CONFIG_INPUT_UINPUT\$/d' \"\$f\""
        "rpi5 disable appended after enable (last wins)|specs-rpi5/kernel/desktop.config|printf 'disable CONFIG_DRM_VIRTIO_GPU\n' >> \"\$f\""
        "frite 'is not set' appended (merge_config last wins)|specs-frite/kernel/hardened-desktop.config|printf '# CONFIG_VIRTIO_INPUT is not set\n' >> \"\$f\""
        "orangepi5 virtio-gpu demoted to =m|specs-orangepi5/kernel/hardened-desktop.config|sed -i 's/^CONFIG_DRM_VIRTIO_GPU=y\$/CONFIG_DRM_VIRTIO_GPU=m/' \"\$f\""
        "orangepi4-lts drops the INPUT_MISC menu|specs-orangepi4-lts/kernel/hardened-desktop.config|sed -i '/^CONFIG_INPUT_MISC=y\$/d' \"\$f\""
        "x86 drops INPUT_MISC from the chain|specs-x86/kernel/desktop.config|sed -i '/^enable CONFIG_INPUT_MISC\$/d' \"\$f\""
        "docs: jetson row claims guest resize|docs/CLIENT-IMAGES.md|sed -i '/^| jetson /s/serial only/guest resize/' \"\$f\""
        "docs: x86 row understates (serial only)|docs/CLIENT-IMAGES.md|sed -i '/^| x86 /s/guest resize/serial only/' \"\$f\""
        "docs: frite row deleted|docs/CLIENT-IMAGES.md|sed -i '/^| frite /d' \"\$f\""
        "docs: rpi5 row names a fragment the builder does not apply|docs/CLIENT-IMAGES.md|sed -i '/^| rpi5 /s#specs-rpi5/kernel/desktop.config#specs-rpi5/kernel/rp1-pi5.config#' \"\$f\""
        "jetson fragment claims virtio-gpu while documented serial only|specs-jetson/kernel/tegra234.config|printf 'CONFIG_DRM_VIRTIO_GPU=y\n' >> \"\$f\""
        "x86 builder stops applying desktop.config|build-x86-host-stage4.sh|sed -i '\\|cat \"\${SPECS_DIR}/kernel/desktop.config\"|d' \"\$f\""
        "frite builder merges a differently named fragment|build-frite-stage4.sh|sed -i 's|merge_config.sh -m .config \"\${SPECS_DIR}/kernel/hardened-desktop.config\"|merge_config.sh -m .config \"\${SPECS_DIR}/kernel/hardened-desktop-x.config\"|' \"\$f\""
    )
    echo "== self-test: clean copy must pass =="
    copy_tree "${base}/clean"
    if VDK_REPO="${base}/clean" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        echo "  PASS clean copy is green"
    else
        echo "  FAIL clean copy is red — the battery below cannot be trusted"; failed=1
    fi
    echo "== self-test: every mutation must change its file and turn the lint red =="
    local case name rel mut f
    for case in "${CASES[@]}"; do
        n=$((n+1))
        name="${case%%|*}"; rel="${case#*|}"; mut="${rel#*|}"; rel="${rel%%|*}"
        tmp="${base}/m${n}"
        copy_tree "${tmp}"
        f="${tmp}/${rel}"
        eval "${mut}"
        if cmp -s "${REPO}/${rel}" "${f}"; then
            echo "  FAIL m${n} ${name}: mutation did not change ${rel}"; failed=1; continue
        fi
        if VDK_REPO="${tmp}" bash "${BASH_SOURCE[0]}" >"${tmp}/out.txt" 2>&1; then
            echo "  FAIL m${n} ${name}: lint stayed GREEN"; failed=1
        else
            echo "  PASS m${n} ${name}: $(grep -m1 '^  FAIL' "${tmp}/out.txt" | cut -c1-110)"
        fi
    done
    rm -rf "${base}"
    return "${failed}"
}

case "${1:-}" in
    --self-test) self_test; exit $? ;;
    "") echo "== virtual display: the guest kernel half of a resizing window =="; run_lint "${REPO}"; exit $? ;;
    *) echo "usage: $0 [--self-test]"; exit 2 ;;
esac
