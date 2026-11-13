#!/usr/bin/env bash
# test-riscv64-no-selinux.sh — riscv64 ships labelled "no SELinux"; nothing
# else may lose SELinux, and nothing riscv64 may claim it (hugmesh-generator#1059).
#
# Operator decision, 2026-11-12: Gentoo ships no hardened or SELinux profile for
# riscv, so riscv64 images use the plain rv64/lp64d profile and every surface says
# "no SELinux". Every other architecture keeps the hardened/selinux profile.
#
# The surfaces, and the one fact each must agree with (the catalog arch flag):
#   1) studio/hugmesh_studio/core/device-catalog.json — archs[].selinux, the label
#   2) scripts/_selinux-posture-lib.sh — the arch list and the words
#   3) specs-*/portage/profile/parent — what each builder selects as make.profile
#   4) build-*-stage4.sh — sources the lib, prints the summary line with the arch
#      its specs belong to; a riscv64 builder prints no SELinux claim of its own
#   5) scripts/publish-images.sh — records "selinux" per image from the lib
#   6) docs/BUILD-MATRIX.md — the marked "SELinux by architecture" table
#   7) docs/catalog/image-catalog.json — archs[].selinux
#
# No riscv64 builder exists yet (hugmesh-generator#1063 writes it). Checks 3 and 4
# therefore also run against FIXTURE trees: a copy of the real tree plus a
# riscv64 specs dir and builder, once correct and once per way of getting it
# wrong. The fixture runs prove those checks fire before a real riscv64 builder
# lands.
#
# Pure static analysis plus the lib's own functions: no network, no root, no
# docker. Usage: test-riscv64-no-selinux.sh [repo-root]   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$(cd "${HERE}/../.." && pwd)}"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

# check_tree <root> — every property over one tree; prints PASS/FAIL lines and
# exits non-zero when any FAIL.
check_tree() {
    ROOT="$1" python3 - <<'PY'
import glob, json, os, re, subprocess, sys

root = os.environ["ROOT"]
P = [0]; F = [0]
def ok(m):  print("  PASS " + m); P[0] += 1
def bad(m): print("  FAIL " + m); F[0] += 1
def rd(rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()

LIB = os.path.join(root, "scripts", "_selinux-posture-lib.sh")
RISCV_PROFILE = "default/linux/riscv/23.0/rv64/lp64d"

def lib(fn, *args):
    """Run one lib function under set -euo pipefail; (rc, stdout)."""
    script = 'set -euo pipefail; source "$1"; shift; "$@"'
    r = subprocess.run(["bash", "-c", script, "lib", LIB, fn, *args],
                       capture_output=True, text=True)
    return r.returncode, r.stdout

# ── 1) the catalog: one structured flag per arch ────────────────────────────
cat = json.loads(rd("studio/hugmesh_studio/core/device-catalog.json"))
archs = {a["id"]: a for a in cat["archs"]}
flags = {}
for aid, a in archs.items():
    v = a.get("selinux")
    if isinstance(v, bool):
        flags[aid] = v
    else:
        bad(f"catalog arch {aid}: 'selinux' must be true or false, got {v!r}")
if "riscv64" not in archs:
    bad("catalog has no riscv64 arch row")
elif flags.get("riscv64") is False:
    ok("catalog: riscv64 selinux=false")
else:
    bad(f"catalog: riscv64 claims SELinux (selinux={flags.get('riscv64')!r})")
lost = sorted(a for a, v in flags.items() if a != "riscv64" and v is not True)
if lost:
    bad(f"catalog: non-riscv64 arch(es) lost SELinux: {lost}")
else:
    ok(f"catalog: every other arch keeps SELinux ({sorted(a for a in flags if a != 'riscv64')})")
no_selinux = {a for a, v in flags.items() if v is False}

# the label: every no-SELinux arch says so; no SELinux-carrying arch says it
m = re.search(r'^NO_SELINUX = "([^"]+)"$', rd("studio/hugmesh_studio/core/device_catalog.py"), re.M)
WORDS = m.group(1) if m else None
if WORDS != "no SELinux":
    bad(f"device_catalog.NO_SELINUX must read 'no SELinux', got {WORDS!r}")
f0 = F[0]
for aid, a in archs.items():
    says = "no SELinux" in a["label"]
    if aid in no_selinux and not says:
        bad(f"catalog: {aid} label does not say 'no SELinux': {a['label']!r}")
    elif aid not in no_selinux and says:
        bad(f"catalog: {aid} carries SELinux but its label says 'no SELinux'")
if F[0] == f0:
    ok("catalog: arch labels say 'no SELinux' exactly where the flag is false")

# ── 2) the lib: same arch list, same words ──────────────────────────────────
src = rd("scripts/_selinux-posture-lib.sh")
m = re.search(r'^HUGMESH_NO_SELINUX_ARCHES="([^"]*)"$', src, re.M)
lib_set = set(m.group(1).split()) if m else None
if lib_set == no_selinux:
    ok(f"lib: HUGMESH_NO_SELINUX_ARCHES == catalog's no-SELinux archs ({sorted(no_selinux)})")
else:
    bad(f"lib: HUGMESH_NO_SELINUX_ARCHES {lib_set} != catalog's no-SELinux archs {no_selinux}")
m = re.search(r'^HUGMESH_NO_SELINUX_TEXT="([^"]*)"$', src, re.M)
if m and m.group(1) == WORDS:
    ok("lib: HUGMESH_NO_SELINUX_TEXT == device_catalog.NO_SELINUX")
else:
    bad(f"lib: HUGMESH_NO_SELINUX_TEXT {m.group(1) if m else None!r} != {WORDS!r}")
# behaviour, not just the literal: the JSON the manifest records, per arch token
for token, want in (("amd64", "true"), ("arm64", "true"), ("x86-64", "true"),
                    ("riscv64", "false")):
    if token == "riscv64" and "riscv64" not in no_selinux:
        want = "true"
    rc, out = lib("selinux_arch_json", token)
    if rc == 0 and out == want:
        ok(f"lib: selinux_arch_json {token} -> {out}")
    else:
        bad(f"lib: selinux_arch_json {token} -> rc={rc} {out!r}, want {want}")

# ── 3) the profiles each builder selects ────────────────────────────────────
def parent_lines(path):
    with open(path, encoding="utf-8") as fh:
        return [ln.split("#", 1)[0].strip() for ln in fh if ln.split("#", 1)[0].strip()]

parents = sorted(glob.glob(os.path.join(root, "specs-*", "portage", "profile", "parent")))
if not parents:
    bad("no specs-*/portage/profile/parent found at all")
specs_selinux = {}
for p in parents:
    specs = os.path.relpath(os.path.dirname(os.path.dirname(os.path.dirname(p))), root)
    lines = parent_lines(p)
    rc, _ = lib("selinux_profile_has", p)
    has = rc == 0
    specs_selinux[specs] = (has, [ln.removeprefix("gentoo:") for ln in lines])
    if specs.startswith("specs-riscv64"):
        if has or any("selinux" in ln for ln in lines):
            bad(f"{specs}: riscv64 profile claims SELinux: {lines}")
        elif not lines or lines[0].removeprefix("gentoo:") != RISCV_PROFILE:
            bad(f"{specs}: riscv64 must select the plain {RISCV_PROFILE} profile first, got {lines}")
        else:
            ok(f"{specs}: plain {RISCV_PROFILE}, no SELinux")
    else:
        if has:
            ok(f"{specs}: profile keeps SELinux ({lines[0].removeprefix('gentoo:')})")
        else:
            bad(f"{specs}: non-riscv64 profile LOST SELinux: {lines}")

# ── 4) every builder: lib sourced, summary line printed with the right arch ──
CODE = lambda s: [ln for ln in s.splitlines() if not ln.lstrip().startswith("#")]
builders = sorted(glob.glob(os.path.join(root, "build-*-stage4.sh")))
if not builders:
    bad("no build-*-stage4.sh found")
for b in builders:
    name = os.path.basename(b)
    with open(b, encoding="utf-8") as fh:
        code = CODE(fh.read())
    m = [re.match(r'^SPECS_DIR="\$\{SCRIPT_DIR\}/(specs-[A-Za-z0-9_-]+)"', ln) for ln in code]
    specs = next((x.group(1) for x in m if x), None)
    if specs is None or specs not in specs_selinux:
        bad(f"{name}: SPECS_DIR names no specs dir with a profile/parent ({specs})")
        continue
    if not any(re.match(r'^source "\$\{SCRIPT_DIR\}/scripts/_selinux-posture-lib\.sh"$', ln.strip())
               for ln in code):
        bad(f"{name}: does not source scripts/_selinux-posture-lib.sh")
    calls = [re.match(r'^selinux_summary_line ([A-Za-z0-9_-]+) "\$\{SPECS_DIR\}"$', ln.strip())
             for ln in code if "selinux_summary_line" in ln]
    if len(calls) != 1 or calls[0] is None:
        bad(f"{name}: must print exactly one `selinux_summary_line <arch> \"${{SPECS_DIR}}\"` "
            f"(found {len(calls)})")
        continue
    arch = calls[0].group(1)
    if arch not in flags:
        bad(f"{name}: summary arch {arch!r} is not a catalog arch")
        continue
    is_riscv = specs.startswith("specs-riscv64") or name.startswith("build-riscv64")
    if is_riscv and arch != "riscv64":
        bad(f"{name}: riscv64 builder prints its summary as {arch!r}")
    elif not is_riscv and arch == "riscv64":
        bad(f"{name}: non-riscv64 builder prints its summary as riscv64")
    elif flags[arch] != specs_selinux[specs][0]:
        bad(f"{name}: summary arch {arch} (selinux={flags[arch]}) disagrees with "
            f"{specs}'s profile (selinux={specs_selinux[specs][0]})")
    else:
        ok(f"{name}: summary line for {arch} matches {specs} (selinux={flags[arch]})")
    if is_riscv:
        # nothing the riscv64 builder prints itself may claim SELinux
        claims = [ln.strip() for ln in code
                  if re.search(r'^\s*(echo|info|printf|ok|warn)\b', ln)
                  and "selinux" in ln.lower() and "no selinux" not in ln.lower()]
        if claims:
            bad(f"{name}: riscv64 builder output claims SELinux: {claims[:3]}")
        else:
            ok(f"{name}: riscv64 builder prints no SELinux claim of its own")
    # the summary line the lib prints for this builder, run for real
    rc, out = lib("selinux_summary_line", arch, os.path.join(root, specs))
    want = "no SELinux" if not flags[arch] else "yes — hardened/selinux"
    if rc == 0 and want in out and "MISSING" not in out and "WRONG" not in out:
        ok(f"{name}: summary reads {out.strip()!r}")
    else:
        bad(f"{name}: summary reads {out.strip()!r} (rc={rc}), want {want!r}")

# ── 5) publish-manifest.json records it per image ───────────────────────────
pub = CODE(rd("scripts/publish-images.sh"))
if (any(ln.strip() == 'source "${SCRIPT_DIR}/_selinux-posture-lib.sh"' for ln in pub)
        and any('"selinux": %s' in ln and "selinux_arch_json" in ln for ln in pub)):
    ok("publish-images.sh: sources the lib and records \"selinux\" per image")
else:
    bad("publish-images.sh: does not record \"selinux\" per image from the lib")

# ── 6) the docs table ───────────────────────────────────────────────────────
doc = rd("docs/BUILD-MATRIX.md")
m = re.search(r"<!-- selinux-by-arch:begin -->\n(.*?)<!-- selinux-by-arch:end -->", doc, re.S)
if not m:
    bad("docs/BUILD-MATRIX.md: no selinux-by-arch table")
else:
    rows = {}
    for ln in m.group(1).splitlines():
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if len(cells) != 3 or cells[0] in ("Architecture",) or set(cells[0]) <= set("-"):
            continue
        rows[cells[0]] = cells
    if set(rows) != set(flags):
        bad(f"docs table archs {sorted(rows)} != catalog archs {sorted(flags)}")
    for aid, (_a, sel, prof) in rows.items():
        if aid not in flags:
            continue
        if flags[aid] and sel != "yes":
            bad(f"docs table: {aid} carries SELinux but the table says {sel!r}")
        elif not flags[aid] and sel != "no SELinux":
            bad(f"docs table: {aid} ships no SELinux but the table says {sel!r}")
        elif not flags[aid] and ("selinux" in prof.lower() or RISCV_PROFILE not in prof):
            bad(f"docs table: {aid} profile cell claims SELinux or is not {RISCV_PROFILE}: {prof!r}")
        else:
            ok(f"docs table: {aid} -> {sel}")
    # a SELinux-carrying arch's profile cell names the profile its builders select
    for b in builders:
        with open(b, encoding="utf-8") as fh:
            code = CODE(fh.read())
        c = [re.match(r'^selinux_summary_line ([A-Za-z0-9_-]+) ', ln.strip()) for ln in code]
        s = [re.match(r'^SPECS_DIR="\$\{SCRIPT_DIR\}/(specs-[A-Za-z0-9_-]+)"', ln) for ln in code]
        arch = next((x.group(1) for x in c if x), None)
        specs = next((x.group(1) for x in s if x), None)
        if arch in rows and specs in specs_selinux and specs_selinux[specs][1]:
            first = specs_selinux[specs][1][0]
            if first not in rows[arch][2]:
                bad(f"docs table: {arch} profile cell {rows[arch][2]!r} does not name "
                    f"{specs}'s {first}")

# ── 7) the emitted web catalog ──────────────────────────────────────────────
ic = json.loads(rd("docs/catalog/image-catalog.json"))
emitted = {a["id"]: a.get("selinux") for a in ic.get("archs", [])}
if emitted == flags:
    ok("docs/catalog/image-catalog.json: archs[].selinux == catalog")
else:
    bad(f"docs/catalog/image-catalog.json: archs[].selinux {emitted} != catalog {flags}")

print(f"  -- {P[0]} passed, {F[0]} failed")
sys.exit(1 if F[0] else 0)
PY
}

P=0; F=0
ok(){ echo "PASS $*"; P=$((P+1)); }
bad(){ echo "FAIL $*"; F=$((F+1)); }

echo "== riscv64 ships 'no SELinux'; nothing else loses it (real tree) =="
if check_tree "${REPO}"; then ok "real tree"; else bad "real tree"; fi

# ── fixtures: the riscv64 builder half, before a real one exists ────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/r64-noselinux.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

mk_fixture() {  # mk_fixture <dir> — a copy of what check_tree reads + a riscv64 builder
    local d="$1" f
    mkdir -p "${d}/scripts" "${d}/docs/catalog" "${d}/studio/hugmesh_studio/core"
    cp "${REPO}/scripts/_selinux-posture-lib.sh" "${REPO}/scripts/publish-images.sh" "${d}/scripts/"
    cp "${REPO}/docs/BUILD-MATRIX.md" "${d}/docs/"
    cp "${REPO}/docs/catalog/image-catalog.json" "${d}/docs/catalog/"
    cp "${REPO}/studio/hugmesh_studio/core/device-catalog.json" \
       "${REPO}/studio/hugmesh_studio/core/device_catalog.py" "${d}/studio/hugmesh_studio/core/"
    for f in "${REPO}"/specs-*/portage/profile/parent; do
        mkdir -p "${d}/${f#"${REPO}"/}" && rmdir "${d}/${f#"${REPO}"/}"
        cp "${f}" "${d}/${f#"${REPO}"/}"
    done
    for f in "${REPO}"/build-*-stage4.sh; do
        # only the lines check_tree reads: SPECS_DIR, the source line, the summary call
        grep -E '^SPECS_DIR=|_selinux-posture-lib\.sh"$|^selinux_summary_line ' "${f}" \
            > "${d}/${f##*/}" || true
    done
    mkdir -p "${d}/specs-riscv64/portage/profile"
    printf 'gentoo:default/linux/riscv/23.0/rv64/lp64d\n' > "${d}/specs-riscv64/portage/profile/parent"
    cat > "${d}/build-riscv64-stage4.sh" <<'SH'
SPECS_DIR="${SCRIPT_DIR}/specs-riscv64"    # riscv64-specific specs
source "${SCRIPT_DIR}/scripts/_selinux-posture-lib.sh"
echo "  Hostname:         ${HOSTNAME}"
selinux_summary_line riscv64 "${SPECS_DIR}"
echo "    - hardened profile, no SELinux"
SH
}

# expect_fixture <want: pass|fail> <label> <mutation command run inside the fixture>
expect_fixture() {
    local want="$1" label="$2" mut="$3" d before out rc
    d="${WORK}/fx-$((P + F))"
    mk_fixture "${d}"
    before="$(cd "${d}" && find . -type f -exec sha256sum {} + | sort | sha256sum)"
    ( cd "${d}" && eval "${mut}" ) || { bad "${label}: mutation command failed"; return; }
    if [ -n "${mut}" ] && [ "${before}" = "$(cd "${d}" && find . -type f -exec sha256sum {} + | sort | sha256sum)" ]; then
        bad "${label}: mutation did not change the fixture (proves nothing)"; return
    fi
    out="$(check_tree "${d}" 2>&1)"; rc=$?
    if [ "${want}" = pass ] && [ "${rc}" -eq 0 ]; then
        ok "${label}"
    elif [ "${want}" = fail ] && [ "${rc}" -ne 0 ]; then
        ok "${label} -> refused: $(printf '%s\n' "${out}" | grep -m1 '^  FAIL' | sed 's/^  FAIL //')"
    else
        bad "${label}: expected ${want}, got rc=${rc}"
        printf '%s\n' "${out}" | grep '^  FAIL' | sed 's/^/    /'
    fi
}

echo "== fixtures: a riscv64 builder, right and wrong =="
expect_fixture pass "fixture: correct riscv64 builder (plain rv64/lp64d, summary as riscv64)" ""
expect_fixture fail "riscv64 profile stacks features/selinux" \
    "printf 'gentoo:features/selinux\n' >> specs-riscv64/portage/profile/parent"
expect_fixture fail "riscv64 profile swapped for a hardened/selinux one" \
    "printf 'gentoo:default/linux/arm64/23.0/hardened/selinux\n' > specs-riscv64/portage/profile/parent"
expect_fixture fail "riscv64 builder summarises itself as arm64" \
    "sed -i 's/^selinux_summary_line riscv64/selinux_summary_line arm64/' build-riscv64-stage4.sh"
expect_fixture fail "riscv64 builder drops the summary line" \
    "sed -i '/^selinux_summary_line/d' build-riscv64-stage4.sh"
expect_fixture fail "riscv64 builder prints its own SELinux claim" \
    "printf 'echo \"    - SELinux LSM (kernel + userspace)\"\n' >> build-riscv64-stage4.sh"
expect_fixture fail "catalog flips riscv64 to selinux=true" \
    "sed -i 's/\"id\": \"riscv64\", \"label\": \"RISC-V 64 (no SELinux; no builder yet)\", \"selinux\": false/\"id\": \"riscv64\", \"label\": \"RISC-V 64 (no SELinux; no builder yet)\", \"selinux\": true/' studio/hugmesh_studio/core/device-catalog.json"
expect_fixture fail "catalog drops arm64's SELinux" \
    "sed -i 's/\"label\": \"ARM64 (single-board \/ edge devices)\", \"selinux\": true/\"label\": \"ARM64 (single-board \/ edge devices)\", \"selinux\": false/' studio/hugmesh_studio/core/device-catalog.json"
expect_fixture fail "an arm64 profile loses /selinux" \
    "printf 'gentoo:default/linux/arm64/23.0/hardened\n' > specs-rpi5/portage/profile/parent"
expect_fixture fail "the x86 profile loses /selinux" \
    "printf 'gentoo:default/linux/amd64/23.0/hardened\n' > specs-x86/portage/profile/parent"
expect_fixture fail "lib forgets riscv64" \
    "sed -i 's/^HUGMESH_NO_SELINUX_ARCHES=\"riscv64\"/HUGMESH_NO_SELINUX_ARCHES=\"\"/' scripts/_selinux-posture-lib.sh"
expect_fixture fail "docs table claims SELinux for riscv64" \
    "sed -i 's/^| riscv64 | no SELinux |/| riscv64 | yes |/' docs/BUILD-MATRIX.md"
expect_fixture fail "riscv64 label stops saying no SELinux" \
    "sed -i 's/RISC-V 64 (no SELinux; no builder yet)/RISC-V 64 (no builder yet)/' studio/hugmesh_studio/core/device-catalog.json"
expect_fixture fail "a non-riscv64 builder stops sourcing the lib" \
    "sed -i '/_selinux-posture-lib/d' build-x86-host-stage4.sh"
expect_fixture fail "publish-images.sh stops recording selinux" \
    "sed -i '/\"selinux\": %s/d' scripts/publish-images.sh"

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
