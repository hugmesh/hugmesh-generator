#!/usr/bin/env bash
# ── PLATFORM-KEY SPELLING / CROSS-CHANNEL AGREEMENT GUARD ───────────────────────
# A platform reaches the user through FOUR independent channels (CLI builder, make
# targets, the ncurses menu, the Studio GUI/config) plus the docker job channel, the
# worklist schema and the catalogs. Every one of them keys off a *string*. Nothing in
# the build-matrix harness notices when two channels disagree on that string by a
# hyphen — each channel is internally consistent, so `check.sh` stays green while the
# GUI silently cannot dispatch the builder the menu offers.
#
# This guard pins the string. Two buckets:
#
#   A) CROSS-CHANNEL SET AGREEMENT (all platforms). config.py's BUILDER_SCRIPTS is
#      the REFERENCE key set. Every other authoritative enumeration must contain the
#      exact same set — no extra key, no missing key, no re-spelled key.
#
#   B) FIFTH-SPELLING BAN (Orange Pi 3 LTS). This board's name is the only one in the
#      fleet whose obvious transliterations differ (Orange Pi "3 LTS" -> orangepi3-lts
#      / orangepi3lts / orangepi-3-lts / orangepi_3_lts / orange-pi-3-lts ...), and the
#      stranded wip pass that introduced it had already drifted between two of them.
#      The canonical set is CLOSED and enumerated below; any spelling outside it fails.
#
# The Orange Pi 3 LTS canonical set (each form owns exactly one namespace):
#   orangepi3-lts               THE platform key — all 4 channels, docker, schema
#                               enums, catalogs, matrix.tsv, device-catalog
#                               builder.platform, and the make target name
#   build-orangepi3-lts-stage4.sh / specs-orangepi3-lts/ / snap-build-orangepi3-lts /
#   install-orangepi3-lts.sh    path forms (hyphenated — identical to the key)
#   ORANGEPI3LTS_*              fleet/make/menu env-var prefix (a shell identifier
#                               cannot contain '-'); mirrors ORANGEPIZERO3_*
#   OPI3LTS_*                   builder-internal var prefix; mirrors OPIZ3_*
#   orangepi3lts                Python attribute stem (FleetConfig.orangepi3lts*),
#                               function stem (run_orangepi3lts_build), DEFAULT_USER
#   orange-pi-3-lts             device-catalog / image-catalog device *id* ONLY
#                               (matches the orange-pi-zero3 id convention)
#   orange_pi_3_lts             ONLY inside the pytest function stem
#                               test_emission_orange_pi_3_lts_* — the device id with
#                               hyphens->underscores, because a Python identifier
#                               cannot hold '-'; mirrors the sibling
#                               test_emission_orange_pi_zero3_live_golden_argv
#
# Two UPSTREAM artifact names are deliberately allowed through the ban because they
# name things that live in kernel.org/U-Boot, not in this repo — and both are cited
# precisely to record that mainline does NOT ship them:
#   sun50i-h6-orangepi-3-lts    the out-of-tree (Armbian) DTS name
#   orangepi_3_lts_defconfig    the U-Boot defconfig name that is a hard 404
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== platform-key spelling / cross-channel agreement =="

PY=python3
command -v "${PY}" >/dev/null 2>&1 || { echo "  SKIP no python3"; exit 0; }

# The spelling scan runs over GIT-TRACKED files only. Two reasons: build output
# (out/), pytest caches (studio/.pytest_cache) and __pycache__ are not source and
# would produce phantom hits; and only tracked content can actually ship a wrong
# key. This guard's own file is excluded everywhere too — it necessarily spells out
# every banned form in its documentation and its own ban table.
SELF_REL="tests/scripts/test-platform-key-spelling.sh"
mapfile -t TRACKED < <(cd "${GEN}" && git ls-files 2>/dev/null | grep -v "^${SELF_REL}$")
if [ "${#TRACKED[@]}" -eq 0 ]; then
    echo "  SKIP not a git checkout (or no tracked files) — spelling scan needs git ls-files"
    exit 0
fi
# grep over the tracked list; -I skips binaries. Prints "file:line:text".
scan() { (cd "${GEN}" && grep -In -E -- "$1" "${TRACKED[@]}" 2>/dev/null) || true; }

# ── A) cross-channel key-set agreement ─────────────────────────────────────────
# Each probe prints its key set, one per line, sorted. The reference is config.py's
# BUILDER_SCRIPTS (the dict the Studio actually dispatches through).
ref="$("${PY}" - "${GEN}" <<'EOF'
import re, sys, pathlib
src = (pathlib.Path(sys.argv[1]) / "studio/hugmesh_studio/core/config.py").read_text()
m = re.search(r"^BUILDER_SCRIPTS\s*=\s*\{(.*?)^\}", src, re.S | re.M)
assert m, "BUILDER_SCRIPTS not found in config.py"
print("\n".join(sorted(re.findall(r'"([^"]+)"\s*:', m.group(1)))))
EOF
)"
[ -n "${ref}" ] || { bad "could not extract BUILDER_SCRIPTS from config.py"; echo "== ${P} passed, ${F} failed =="; exit 1; }
echo "  reference key set: $(echo "${ref}" | tr '\n' ' ')"

cmp_set() {  # cmp_set <label> <newline-separated set>
    local label="$1" got="$2"
    if [ "${got}" = "${ref}" ]; then
        ok "${label}: key set matches BUILDER_SCRIPTS"
    else
        bad "${label}: key set DIFFERS from BUILDER_SCRIPTS"
        diff <(echo "${ref}") <(echo "${got}") | sed 's/^/      /' || true
    fi
}

# worklist schema — BOTH platform enums must carry the same set
"${PY}" - "${GEN}" <<'EOF' >/tmp/.pk_schema 2>/dev/null || true
import json, sys, pathlib
d = json.loads((pathlib.Path(sys.argv[1]) / "docs/schemas/worklist.v1.schema.json").read_text())
out, seen = [], 0
def walk(o):
    global seen
    if isinstance(o, dict):
        e = o.get("enum")
        if isinstance(e, list) and "x86" in e and "rpi5" in e:
            seen += 1
            out.append(tuple(sorted(e)))
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)
print(seen)
for s in set(out):
    print("\n".join(s))
EOF
schema_n="$(head -n1 /tmp/.pk_schema 2>/dev/null || echo 0)"
schema_set="$(tail -n +2 /tmp/.pk_schema 2>/dev/null | sort -u)"
if [ "${schema_n}" -lt 2 ]; then
    bad "worklist.v1.schema.json: expected >=2 platform enums, found ${schema_n}"
else
    ok "worklist.v1.schema.json: ${schema_n} platform enums found"
    cmp_set "worklist.v1.schema.json enums (deduped)" "${schema_set}"
fi

# matrix.tsv column 1 — the harness's own cell inventory
cmp_set "tests/build-matrix/matrix.tsv column 1" \
    "$(grep -v '^#' "${GEN}/tests/build-matrix/matrix.tsv" | grep -v '^[[:space:]]*$' \
        | awk '{print $1}' | grep -v '^platform$' | sort -u)"

# prebuild-smoke.sh — the shared-binpkg per-arch loop
cmp_set "tests/build-matrix/prebuild-smoke.sh arch loop" \
    "$(sed -nE 's/^for arch in (.*); do$/\1/p' "${GEN}/tests/build-matrix/prebuild-smoke.sh" \
        | tr ' ' '\n' | grep -v '^$' | sort -u)"

# device-catalog.json — every builder-backed device's builder.platform
cmp_set "studio/.../device-catalog.json builder.platform values" \
    "$("${PY}" - "${GEN}" <<'EOF'
import json, sys, pathlib
d = json.loads((pathlib.Path(sys.argv[1]) / "studio/hugmesh_studio/core/device-catalog.json").read_text())
print("\n".join(sorted({dev["builder"]["platform"] for dev in d["devices"]
                        if dev.get("builder") and dev["builder"].get("platform")})))
EOF
)"

# config.py PLATFORM_LABELS — the GUI's own label table must not drift from dispatch
cmp_set "config.py PLATFORM_LABELS" \
    "$("${PY}" - "${GEN}" <<'EOF'
import re, sys, pathlib
src = (pathlib.Path(sys.argv[1]) / "studio/hugmesh_studio/core/config.py").read_text()
m = re.search(r"^PLATFORM_LABELS\s*=\s*\{(.*?)^\}", src, re.S | re.M)
assert m
print("\n".join(sorted(re.findall(r'"([^"]+)"\s*:', m.group(1)))))
EOF
)"

# every BUILDER_SCRIPTS value must be a real executable builder in the repo root
while IFS= read -r k; do
    b="$("${PY}" - "${GEN}" "${k}" <<'EOF'
import re, sys, pathlib
src = (pathlib.Path(sys.argv[1]) / "studio/hugmesh_studio/core/config.py").read_text()
m = re.search(r"^BUILDER_SCRIPTS\s*=\s*\{(.*?)^\}", src, re.S | re.M)
print(dict(re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"', m.group(1)))[sys.argv[2]])
EOF
)"
    if [ -f "${GEN}/${b}" ]; then ok "key '${k}' -> ${b} exists"
    else bad "key '${k}' -> ${b} MISSING from the repo root"; fi
done <<< "${ref}"

# ── B) Orange Pi 3 LTS fifth-spelling ban ──────────────────────────────────────
KEY="orangepi3-lts"

# B1) the key is present in each of the four channels + docker, at a STRUCTURAL site
#     (not just in prose) — a channel that silently drops the platform fails here.
chan() {  # chan <label> <file> <grep-E pattern>
    if grep -qE "$3" "${GEN}/$2"; then ok "channel $1: '${KEY}' wired ($2)"
    else bad "channel $1: '${KEY}' NOT wired in $2 (pattern: $3)"; fi
}
chan "CLI builder"   "build-orangepi3-lts-stage4.sh" "_plan PLATFORM[[:space:]]+\"${KEY}\""
chan "CLI /etc/board" "build-orangepi3-lts-stage4.sh" "echo \"${KEY}\".*etc/hugmesh/board"
chan "make target"   "Makefile"                      "^${KEY}:"
chan "make live"     "Makefile"                      "^${KEY}-live:"
chan "make installer" "Makefile"                     "^${KEY}-installer:"
chan "ncurses menu"  "scripts/build-menu.sh"         "^[[:space:]]*${KEY}\)"
chan "docker job"    "docker/build-image.sh"         "^[[:space:]]*${KEY}\)"
chan "Studio config" "studio/hugmesh_studio/core/config.py" "\"${KEY}\":[[:space:]]*\"build-orangepi3-lts-stage4.sh\""
chan "Studio GUI"    "studio/hugmesh_studio/gui/pages/role.py" "machine == \"${KEY}\""
chan "fleet driver"  "studio/hugmesh_studio/core/build_sessions.py" "\(\"${KEY}\","

# B2) the env-var prefix is EXACTLY ORANGEPI3LTS_ (never ORANGEPI3_LTS_ / OPI3_LTS_)
for badpfx in 'ORANGEPI3_LTS_' 'ORANGE_PI3LTS_' 'OPI3_LTS_' 'ORANGEPI3LTS-'; do
    hits="$(scan "$(printf '%s' "${badpfx}" | sed 's/[][^$.*\\/]/\\&/g')")"
    if [ -z "${hits}" ]; then
        ok "no '${badpfx}' identifier prefix"
    else
        bad "banned identifier prefix '${badpfx}' present"
        echo "${hits}" | sed 's/^/      /' | head -5
    fi
done

# B3) THE BAN. Any 3-LTS spelling outside the canonical set fails. Each pattern is
#     stripped of its documented upstream-artifact exception FIRST, so a real
#     violation cannot hide behind one.
#     ban_variant <regex> <allow-regex-or-empty> <human name>
ban_variant() {
    local pat="$1" allow="$2" name="$3" hits
    hits="$(scan "${pat}")"
    if [ -n "${allow}" ]; then
        hits="$(echo "${hits}" | grep -vE -- "${allow}" || true)"
    fi
    if [ -z "${hits}" ]; then
        ok "no '${name}' spelling"
    else
        bad "banned spelling '${name}' found — the canonical key is '${KEY}'"
        echo "${hits}" | sed 's/^/      /' | head -8
    fi
}
ban_variant 'orangepi-3-lts'  'sun50i-h6-orangepi-3-lts'  'orangepi-3-lts'
ban_variant 'orangepi_3_lts'  'orangepi_3_lts_defconfig'  'orangepi_3_lts'
ban_variant 'orangepi3_lts'   ''                          'orangepi3_lts'
# the ONLY sanctioned underscore form is the pytest function stem (device id with
# '-'->'_', because a Python identifier cannot hold a hyphen)
ban_variant 'orange_pi_3_lts' 'test_emission_orange_pi_3_lts' 'orange_pi_3_lts'
ban_variant 'orangepi3LTS'    ''                          'orangepi3LTS'
ban_variant 'orangepi3-LTS'   ''                          'orangepi3-LTS'
ban_variant 'OrangePi3Lts'    ''                          'OrangePi3Lts'
ban_variant 'opi-3-lts'       ''                          'opi-3-lts'

# B4) the two allowed upstream-artifact citations must STILL be there. If a later
#     edit "cleans them up", the README silently loses the evidence that mainline
#     ships no -lts variant — which is the entire reason this port boots the plain
#     OPi3's DTB. (Positive control for the exceptions carved out in B3.)
if grep -rIq 'sun50i-h6-orangepi-3-lts' "${GEN}/specs-orangepi3-lts"; then
    ok "upstream out-of-tree DTS name still cited in specs-orangepi3-lts/"
else
    bad "specs-orangepi3-lts/ no longer cites sun50i-h6-orangepi-3-lts (lost evidence)"
fi
if grep -rIq 'orangepi_3_lts_defconfig' "${GEN}/specs-orangepi3-lts" "${GEN}/build-orangepi3-lts-stage4.sh"; then
    ok "U-Boot 404 defconfig name still cited (orangepi_3_lts_defconfig)"
else
    bad "orangepi_3_lts_defconfig citation lost (that 404 is why we boot the plain OPi3 defconfig)"
fi

# ── C) Orange Pi 4 LTS namespace closure (same discipline as B) ────────────────
KEY="orangepi4-lts"

# C1) structural presence in each channel + docker.
chan "CLI builder"    "build-orangepi4-lts-stage4.sh" "_plan PLATFORM[[:space:]]+\"${KEY}\""
# 4 LTS is variant-capable (--board), so it writes the fleet's key:variant form
# ("orangepi4-lts:${OPI4LTS_BOARD}") exactly like frite/orangepi5 — the probe
# accepts the key with either a closing quote (bare, 3 LTS) or a ':' (variant).
chan "CLI /etc/board" "build-orangepi4-lts-stage4.sh" "echo \"${KEY}[:\"].*etc/hugmesh/board"
chan "make target"    "Makefile"                      "^${KEY}:"
chan "make live"      "Makefile"                      "^${KEY}-live:"
chan "make installer" "Makefile"                      "^${KEY}-installer:"
chan "ncurses menu"   "scripts/build-menu.sh"         "^[[:space:]]*${KEY}\)"
chan "docker job"     "docker/build-image.sh"         "^[[:space:]]*${KEY}\)"
chan "Studio config"  "studio/hugmesh_studio/core/config.py" "\"${KEY}\":[[:space:]]*\"build-orangepi4-lts-stage4.sh\""
chan "Studio GUI"     "studio/hugmesh_studio/gui/pages/role.py" "machine == \"${KEY}\""
chan "fleet driver"   "studio/hugmesh_studio/core/build_sessions.py" "\(\"${KEY}\","

# C2) the env-var prefix is EXACTLY ORANGEPI4LTS_ (never ORANGEPI4_LTS_ / OPI4_LTS_)
for badpfx in 'ORANGEPI4_LTS_' 'ORANGE_PI4LTS_' 'OPI4_LTS_' 'ORANGEPI4LTS-'; do
    hits="$(scan "$(printf '%s' "${badpfx}" | sed 's/[][^$.*\\/]/\\&/g')")"
    if [ -z "${hits}" ]; then
        ok "no '${badpfx}' identifier prefix"
    else
        bad "banned identifier prefix '${badpfx}' present"
        echo "${hits}" | sed 's/^/      /' | head -5
    fi
done

# C3) THE BAN. Note 'orange-pi-4-lts' (the catalog device id) is CANONICAL and is
#     deliberately NOT banned — it mirrors the orange-pi-3-lts id convention. The
#     banned near-miss below is 'orangepi-4-lts' (no hyphen after "orange"), which
#     is only allowed inside the two upstream artifact names this port cites as
#     ABSENT evidence.
ban_variant 'orangepi-4-lts'  'rk3399-orangepi-4-lts|orangepi-4-lts-rk3399_defconfig' 'orangepi-4-lts'
ban_variant 'orangepi_4_lts'  'orangepi_4_lts_defconfig'  'orangepi_4_lts'
ban_variant 'orangepi4_lts'   ''                          'orangepi4_lts'
ban_variant 'orange_pi_4_lts' 'test_emission_orange_pi_4_lts' 'orange_pi_4_lts'
ban_variant 'orangepi4LTS'    ''                          'orangepi4LTS'
ban_variant 'orangepi4-LTS'   ''                          'orangepi4-LTS'
ban_variant 'OrangePi4Lts'    ''                          'OrangePi4Lts'
ban_variant 'opi-4-lts'       ''                          'opi-4-lts'

# C4) positive control for C3's exceptions: the two "mainline does NOT ship this"
#     citations must survive. They are the whole evidence base for booting the
#     shared Orange Pi RK3399 DTB/defconfig; a later "cleanup" would silently
#     delete the justification and leave the port looking arbitrary.
if grep -rIq 'rk3399-orangepi-4-lts' "${GEN}/specs-orangepi4-lts" "${GEN}/build-orangepi4-lts-stage4.sh"; then
    ok "absent-DTB name still cited (rk3399-orangepi-4-lts)"
else
    bad "rk3399-orangepi-4-lts citation lost (that absence is why we ship rk3399-orangepi.dtb)"
fi
if grep -rIq 'orangepi_4_lts_defconfig' "${GEN}/specs-orangepi4-lts"; then
    ok "U-Boot 404 defconfig name still cited (orangepi_4_lts_defconfig)"
else
    bad "orangepi_4_lts_defconfig citation lost (that 404 is why we use orangepi-rk3399_defconfig)"
fi

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
