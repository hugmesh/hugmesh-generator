#!/usr/bin/env bash
# ── ROLE-KEY SPELLING / CROSS-CHANNEL AGREEMENT GUARD ──────────────────────────
# An image is identified by a device platform and then a ROLE. That role token used
# to be spelled independently in about fourteen places: the SAME logical node was
# `--role be` on x86 and `--role backend` on rpi5, `gpu-host` on jetson and `be+gpu`
# on x86, `be-gpu` on the docker job channel, and `host` in the artifact filename.
# TEN hand-maintained translation tables bridged them — four of which were copies of
# one another, and one of which ran BACKWARDS (tests/build-matrix/check.sh mapped
# backend->be while the Studio mapped be->backend).
#
# Nothing noticed, because every channel was internally consistent. `make
# matrix-check` stayed green by HARD-CODING the mapping — it could only stay green
# WHILE the channels disagreed. This is the same disease
# tests/scripts/test-platform-key-spelling.sh was written for on the PLATFORM key;
# there was no ROLE equivalent, and that absence is why the fourth spelling kept
# coming back.
#
# THE REFERENCE IS scripts/_roles-lib.sh. Three buckets:
#
#   A) CROSS-CHANNEL SET AGREEMENT. Every channel that names a role must derive its
#      set from the lib, and the Studio's per-platform role sets must equal the
#      lib's. Every builder must SOURCE the lib and CALL it — a builder that keeps
#      its own case-arm vocabulary is the defect.
#
#   B) ALIAS-AS-OUTPUT BAN. Aliases (be, fe, be+gpu, be-gpu, host, gpu-host,
#      gpu_host, full, edge_ai, standalone-full) are accepted on INPUT forever and
#      must NEVER be EMITTED. "Emitted" is judged STRUCTURALLY — a `--role <alias>`,
#      a `"role":"<alias>"`, a `ROLE=<alias>` assignment, a `case` arm, a matrix.tsv
#      role column, a catalog role id. Prose that NAMES an alias (this file, the
#      lib's own table, a comment recording why the fold exists) is not an emission
#      and is not banned: a ban that fired on prose would be answered with a wall of
#      allowlist entries, and a false exemption reason is worse than no exemption.
#
#   C) NO FIFTH SPELLING. backend_gpu / backendgpu / be_gpu / edgeai / edge_AI and
#      friends are banned outright — the closed-set discipline that keeps a rename
#      from growing a new variant six months later.
#
# WHAT THIS GUARD DELIBERATELY DOES NOT TOUCH — and why each is a role WORD that is
# NOT a role TOKEN. A mechanical sweep would corrupt all four:
#   * k8s LABEL KEYS  hugmesh.net/backend, /frontend, /pki, /edge-ai. Uniformly long,
#     never divergent (there is no hugmesh.net/be anywhere, and check A7 pins that),
#     frozen by scripts/tooling/tokens.json, nodeSelector'd by 73 files under
#     specs/cluster/, and read by two live selectors that fail OPEN on a stale one.
#   * gateway TIERS   hugmesh-be-gateway / hugmesh-fe-gateway, apps/20-gateway-*.yaml
#   * reserved URL HANDLES  specs/cluster/reserved-prefixes.yaml reserves the literal
#     handle `be`; hugmesh.net/be/** is a live URL PATH, not a label key.
#   * PERSON roles    user|mod|admin|superadmin (--person-role), persisted under the
#     same JSON key name `role` as an image role.
#   * k8s TOPOLOGY roles  control-plane|master|server|worker|none (.kubernetes.role)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== role-key spelling / cross-channel agreement =="

PY=python3
# Tool preflight is FAIL-CLOSED (tests/lib/guard-preflight.sh): a missing tool makes
# this guard exit 1, never 0.
. "${HERE}/../lib/guard-preflight.sh"
guard_require_tools "${PY}"

LIB="${GEN}/scripts/_roles-lib.sh"
[ -f "${LIB}" ] || guard_require_capability "scripts/_roles-lib.sh is missing — the role vocabulary has no declaration, so nothing below can be checked"

SELF_REL="tests/scripts/test-role-key-spelling.sh"
mapfile -t TRACKED < <(cd "${GEN}" && git ls-files 2>/dev/null | grep -v "^${SELF_REL}$")
if [ "${#TRACKED[@]}" -eq 0 ]; then
    # Not a skip: the whole ban is `grep over git ls-files`, so an empty list means
    # the scan covered nothing — and "no banned spellings in zero files" is
    # indistinguishable from a clean repo.
    guard_require_capability "git ls-files returned nothing in ${GEN} — not a git checkout, so the spelling scan would cover ZERO files (a vacuous green)"
fi
scan() { (cd "${GEN}" && grep -In -E -- "$1" "${TRACKED[@]}" 2>/dev/null) || true; }

# ── the reference sets, straight out of the lib ────────────────────────────────
# Sourced rather than parsed: if the lib does not even source cleanly, every set
# below would be empty and this guard would pass vacuously.
# shellcheck source=scripts/_roles-lib.sh
. "${LIB}"
for v in HUGMESH_ROLES_CANONICAL HUGMESH_ROLES_X86 HUGMESH_ROLES_RPI5 HUGMESH_ROLES_JETSON; do
    if [ -z "${!v:-}" ]; then
        bad "${v} is empty or undeclared in scripts/_roles-lib.sh — every set comparison below would be vacuous"
        echo "== ${P} passed, ${F} failed =="; exit 1
    fi
done
echo "  canonical roles: ${HUGMESH_ROLES_CANONICAL}"
ALIASES="$(printf '%s\n' ${HUGMESH_ROLE_ALIASES} | sed 's/=.*//' | sort -u)"
echo "  input aliases  : $(echo ${ALIASES} | tr '\n' ' ')"
[ -n "${ALIASES}" ] || { bad "HUGMESH_ROLE_ALIASES is empty — bucket B would ban nothing"; }

sorted() { printf '%s\n' $1 | sort -u; }
cmp_set() {  # cmp_set <label> <expected set> <got set>
    local label="$1"
    local want
    local got
    want="$(sorted "$2")"
    got="$(sorted "$3")"
    if [ "${want}" = "${got}" ]; then
        ok "${label}: matches scripts/_roles-lib.sh"
    else
        bad "${label}: DIFFERS from scripts/_roles-lib.sh"
        diff <(echo "${want}") <(echo "${got}") | sed 's/^/      /' || true
    fi
}
subset_of() {  # subset_of <label> <superset> <candidate set>
    local label="$1"
    local extra
    extra="$(comm -23 <(sorted "$3") <(sorted "$2") | tr '\n' ' ')"
    if [ -z "${extra// /}" ]; then ok "${label}: every token is in the vocabulary"
    else bad "${label}: token(s) outside the vocabulary: ${extra}"; fi
}

# ══ A) CROSS-CHANNEL SET AGREEMENT ═════════════════════════════════════════════

# A1) every builder SOURCES the lib. A builder that does not cannot fold an alias,
#     and would be free to grow its own vocabulary again.
BUILDERS=(build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh
          build-frite-stage4.sh build-orangepi5-stage4.sh build-orangepi4-lts-stage4.sh
          build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh
          build-orangepi-zero3-stage4.sh build-orangepi3-lts-stage4.sh)
for b in "${BUILDERS[@]}"; do
    if grep -q '_roles-lib\.sh' "${GEN}/${b}"; then ok "${b} sources the role vocabulary"
    else bad "${b} does NOT source scripts/_roles-lib.sh — it can grow its own role spelling again"; fi
done

# A2) the three role-axis builders VALIDATE through it, with their own platform key.
for pair in "build-x86-host-stage4.sh:x86" "build-rpi5-stage4.sh:rpi5" "build-jetson-stage4.sh:jetson"; do
    b="${pair%%:*}"; plat="${pair##*:}"
    if grep -q "hugmesh_role_validate \"\${ROLE}\" ${plat}" "${GEN}/${b}"; then
        ok "${b} normalizes/validates --role through hugmesh_role_validate (${plat})"
    else
        bad "${b} no longer calls hugmesh_role_validate \"\${ROLE}\" ${plat} — --role is unvalidated, or validated by a private table"
    fi
done

# A3) the seven FREE-SLUG boards refuse a cluster node role. `--role backend` on an
#     Orange Pi used to be silently accepted and quietly became a hostname.
# ASSERTED BY BEHAVIOUR, not by grepping for the call. A source-text probe is
# satisfied by a commented-out line — mutation-proven: deleting the call and leaving
# the comment above it kept this check green. --print-plan needs no root and writes
# nothing, so the real builder can be asked directly.
for b in build-frite-stage4.sh build-orangepi5-stage4.sh build-orangepi4-lts-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh \
         build-orangepi-zero3-stage4.sh build-orangepi3-lts-stage4.sh; do
    if timeout 120 bash "${GEN}/${b}" --print-plan --role backend >/dev/null 2>&1; then
        bad "${b} ACCEPTED '--role backend' — it has no role axis, so that names a cluster node image it cannot build; the token would silently become a hostname"
    else
        ok "${b} refuses '--role backend' (it has no role axis)"
    fi
    # ...and the control for the control: its OWN default role must still work, or
    # the check above would pass for a builder that rejects everything.
    if timeout 120 bash "${GEN}/${b}" --print-plan >/dev/null 2>&1; then
        ok "${b} still accepts its own default role (the rejection is not blanket)"
    else
        bad "${b} rejects its OWN default role — the node-role refusal is over-broad"
    fi
done

# A4) each role-axis builder's CASE ARMS are exactly its platform's canonical set.
#     Aliases must NOT appear as arms: they fold before the block runs.
arms_of() {  # arms_of <builder> — the role case block's arm patterns, one per line
    "${PY}" - "${GEN}/$1" <<'EOF'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
src = re.sub(r"(?m)(?:(?<=^)|(?<=\s))#.*$", "", src)          # strip comments
blocks = [m.group(1) for m in re.finditer(
    r'case\s+"\$\{ROLE\}"\s+in\n(.*?)\n\s*esac', src, re.S)]
# the OWNING block is the one whose arms assign build state (not the printed
# keys-hints block, whose arms only echo)
own = [b for b in blocks if re.search(r"(ROLE_K8S|ROLE_CLIENT|ROOT_MiB|HOSTNAME)=", b)]
assert len(own) == 1, f"expected exactly one role case block, found {len(own)}"
out = set()
for m in re.finditer(r"(?m)^\s{4}([A-Za-z0-9_+|*-]+)\)", own[0]):
    for tok in m.group(1).split("|"):
        if tok and tok != "*":
            out.add(tok)
print("\n".join(sorted(out)))
EOF
}
cmp_set "build-x86-host-stage4.sh role case arms"  "${HUGMESH_ROLES_X86}"    "$(arms_of build-x86-host-stage4.sh)"
cmp_set "build-rpi5-stage4.sh role case arms"      "${HUGMESH_ROLES_RPI5}"   "$(arms_of build-rpi5-stage4.sh)"
cmp_set "build-jetson-stage4.sh role case arms"    "${HUGMESH_ROLES_JETSON}" "$(arms_of build-jetson-stage4.sh)"

# A3b) THE ALIAS CONTRACT — a POSITIVE control, and the only thing that notices a
#      DELETION. Every other check here compares SETS, so removing an alias makes
#      every set smaller and consistently so: mutation-proven, dropping `be` from the
#      table left this guard entirely green while `--role be` stopped working.
#      These ten spellings are what this repo's own docs, its Makefile targets, its
#      HARDWARE_CLASS grammar, hundreds of saved Studio session records and every
#      already-flashed node actually say. They are accepted on INPUT forever; that is
#      not a deprecation window, and there is no forcing function that would ever let
#      it expire. Removing one is a decision, and it has to be made HERE.
alias_of() { _hm_role_lookup "${HUGMESH_ROLE_ALIASES}" "$1" 2>/dev/null || true; }
for pair in "be:backend" "fe:frontend" "be+gpu:backend-gpu" "be-gpu:backend-gpu" \
            "host:backend-gpu" "gpu-host:backend-gpu" "gpu_host:backend-gpu" \
            "full:omnibus" "edge_ai:edge-ai" "standalone-full:standalone-thick"; do
    a="${pair%%:*}"; want="${pair##*:}"
    got="$(alias_of "${a}")"
    if [ "${got}" = "${want}" ]; then
        ok "alias '${a}' -> '${want}' still accepted"
    else
        bad "alias '${a}' no longer resolves to '${want}' (got '${got:-<nothing>}') — every CLI that documented this spelling must keep taking it"
    fi
done
# ...and the composite ids, which carry a SECOND axis and must never be flattened
# into the plain alias table (a bare fold would drop the platform, or in
# standalone-desktop's case the FDE posture).
for pair in "rpi5-desktop:desktop	platform=rpi5" "jetson-desktop:desktop	platform=jetson" \
            "standalone-desktop:desktop	standalone=true"; do
    a="${pair%%:*}"; want="${pair#*:}"
    got="$(hugmesh_role_composite "${a}" 2>/dev/null || true)"
    if [ "${got}" = "${want}" ]; then
        ok "composite alias '${a}' -> ${want//	/ + }"
    else
        bad "composite alias '${a}' changed or was dropped (got '${got:-<nothing>}') — it carries a platform/flag, not just a spelling"
    fi
done
for a in rpi5-desktop jetson-desktop standalone-desktop; do
    if hugmesh_role_canonicalize "${a}" >/dev/null 2>&1; then
        bad "composite id '${a}' leaked into the PLAIN alias table — folding it there drops its second axis"
    else
        ok "composite id '${a}' is kept out of the plain alias fold"
    fi
done

# A4b) NO HARDCODED HOSTNAME. Every default hostname in the three role-axis builders
#      must come from hugmesh_role_hostname. A literal `HOSTNAME="${BRAND}-be"` is
#      the other half of a rename: the CLI token converges, the baked /etc/hostname
#      does not, and nothing downstream notices because a hostname is never
#      validated against the vocabulary.
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh; do
    hard="$(grep -nE 'HOSTNAME="\$\{BRAND\}-' "${GEN}/${b}" || true)"
    if [ -z "${hard}" ]; then
        ok "${b}: every default hostname is derived (hugmesh_role_hostname)"
    else
        bad "${b}: a hardcoded \"\${BRAND}-<role>\" hostname — it must come from hugmesh_role_hostname, or a role rename leaves the baked /etc/hostname behind"
        echo "${hard}" | sed 's/^/      /' | head -5
    fi
    if grep -q 'hugmesh_role_hostname' "${GEN}/${b}"; then
        ok "${b}: calls hugmesh_role_hostname"
    else
        bad "${b}: never calls hugmesh_role_hostname — its hostname defaults are a second copy of the table"
    fi
done

# A5) THE STUDIO. ROLE_CHOICES is the Studio's own authority; its per-platform sets
#     must EQUAL the lib's. This is the check that catches "the Studio offers a role
#     no builder builds" AND "a builder grew a role the Studio cannot reach".
studio_roles() {  # studio_roles <platform>
    PYTHONPATH="${GEN}/studio" "${PY}" - "$1" <<'EOF'
import sys
from hugmesh_studio.core.config import ROLE_CHOICES
from hugmesh_studio.core import roles
plat = sys.argv[1]
ids = {r for mode in ROLE_CHOICES for r, plats, _l in ROLE_CHOICES[mode] if plat in plats}
# composite ids (rpi5-desktop / jetson-desktop) resolve to a real role + a platform
print("\n".join(sorted({roles.builder_role(r, plat) for r in ids})))
EOF
}
for pair in "x86:${HUGMESH_ROLES_X86}" "rpi5:${HUGMESH_ROLES_RPI5}" "jetson:${HUGMESH_ROLES_JETSON}"; do
    plat="${pair%%:*}"; want="${pair#*:}"
    got="$(studio_roles "${plat}" 2>/dev/null || true)"
    if [ -z "${got}" ]; then
        bad "Studio ROLE_CHOICES could not be read for platform ${plat} — the comparison would be vacuous"
    else
        cmp_set "Studio ROLE_CHOICES (${plat})" "${want}" "${got}"
    fi
done

# A6) roles.py must READ the lib, not restate it. A second declaration is the bug.
ROLES_PY="${GEN}/studio/hugmesh_studio/core/roles.py"
if grep -q '_roles-lib\.sh' "${ROLES_PY}"; then
    ok "core/roles.py reads scripts/_roles-lib.sh (one declaration, two readers)"
else
    bad "core/roles.py no longer references scripts/_roles-lib.sh — it has become a SECOND declaration"
fi

# A7) THE LABEL SIDE IS LONG AND STAYS LONG. This is not a rename — it is a pin.
#     There is no hugmesh.net/be or /fe anywhere and there must never be one; the
#     freeze in scripts/tooling/tokens.json covers the NAMESPACE by substring and
#     cannot tell the two apart, so this is the only thing that would notice.
lab="$(scan 'hugmesh\.net/(be|fe)=' || true)"
if [ -z "${lab}" ]; then
    ok "no short-form hugmesh.net/{be,fe} LABEL KEY (the label side never diverged, and must not start)"
else
    bad "a SHORT-FORM hugmesh.net label key appeared — the label suffix is NOT part of this rename"
    echo "${lab}" | sed 's/^/      /' | head -8
    echo "      Renaming a k8s label key suffix would need: 73 nodeSelector files under"
    echo "      specs/cluster/, the two live selector reads in bootstrap.sh (which fail"
    echo "      OPEN on a stale one), kind's bootstrap-kind.sh, KEYS USB sticks already"
    echo "      in the field that nothing in-tree can migrate, and possibly a JVM change"
    echo "      in another repo (tokens.json records that label keys are compiled into"
    echo "      operators). It buys nothing: ROLE_LABELS is print-only."
fi

# A8) the make / fleet / matrix / catalog channels carry only vocabulary tokens.
mk_var() { sed -nE "s/^$1[[:space:]]*[:?]?=[[:space:]]*(.*)$/\1/p" "${GEN}/Makefile" | head -1; }
subset_of "Makefile X86_ROLE_LIST"   "${HUGMESH_ROLES_X86}"    "$(mk_var X86_ROLE_LIST)"
subset_of "Makefile X86_EVERY_ROLE"  "${HUGMESH_ROLES_X86}"    "$(mk_var X86_EVERY_ROLE)"
subset_of "Makefile RPI_ROLES"       "${HUGMESH_ROLES_RPI5}"   "$(mk_var RPI_ROLES)"
subset_of "Makefile JETSON_ROLE"     "${HUGMESH_ROLES_JETSON}" "$(mk_var JETSON_ROLE)"
subset_of "Makefile ROLE default"    "${HUGMESH_ROLES_X86}"    "$(mk_var ROLE)"
subset_of "scripts/build-all-roles.sh x86 default set" "${HUGMESH_ROLES_X86}" \
    "$(sed -nE 's/^[[:space:]]*X86_BUILD_ROLES=\(([a-z0-9 -]*)\)([[:space:]]*#.*)?$/\1/p' "${GEN}/scripts/build-all-roles.sh" | tr '\n' ' ')"
subset_of "scripts/build-all-roles.sh rpi5 default set" "${HUGMESH_ROLES_RPI5}" \
    "$(sed -nE 's/^[[:space:]]*RPI_ROLES=\(([a-z0-9 -]*)\)([[:space:]]*#.*)?$/\1/p' "${GEN}/scripts/build-all-roles.sh" | tr '\n' ' ')"

# matrix.tsv column 2. `appliance` and `standalone-desktop` are NOT node roles:
# the first is the free-slug boards' hostname marker, the second is the docker
# HARDWARE_CLASS composite (role desktop PLUS --standalone). Both are declared here
# with their reason rather than silently tolerated.
subset_of "tests/build-matrix/matrix.tsv role column" \
    "${HUGMESH_ROLES_CANONICAL} appliance standalone-desktop" \
    "$(grep -v '^#' "${GEN}/tests/build-matrix/matrix.tsv" | awk 'NF{print $2}' | grep -v '^role$' | sort -u | tr '\n' ' ')"

# the committed catalogs — the grammar a DIFFERENT repo's admin-ui consumes.
cat_roles="$("${PY}" - "${GEN}" <<'EOF'
import json, sys, pathlib
d = json.loads((pathlib.Path(sys.argv[1]) / "docs/catalog/image-catalog.json").read_text())
out = set()
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("role"), str):
            out.add(o["role"])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(d)
print(" ".join(sorted(out)))
EOF
)"
subset_of "docs/catalog/image-catalog.json role ids" \
    "${HUGMESH_ROLES_CANONICAL} rpi5-desktop jetson-desktop frite orangepi5 orangepizero2 orangepizero2w orangepizero3 orangepi3-lts orangepi4-lts appliance" \
    "${cat_roles}"

# ══ B) ALIAS-AS-OUTPUT BAN ═════════════════════════════════════════════════════
# STRUCTURAL positions only (see the header). The lib itself declares the aliases,
# and this guard's own file necessarily names every one of them.
#
# ALLOWLIST — every entry carries its REAL reason. A false exemption reason reads as
# considered and stops anyone looking; this list is meant to reach EMPTY except for
# the deliberate, permanent entries below.
#   tests/build-matrix/check.sh   ONE canary resolves `x86.be-gpu` on purpose: it is
#                                 the JOB channel's charset workaround and the probe
#                                 proves both that the alias is still ACCEPTED and
#                                 that the output is canonical (BUILD_ROLE=backend-gpu).
ALLOW_B='tests/build-matrix/check\.sh:[0-9]+:.*x86\.be-gpu'
ban_output() {  # ban_output <regex> <human name>
    local pat="$1"
    local name="$2"
    local hits
    hits="$(scan "${pat}")"
    # A COMMENT cannot emit anything. Comment lines are prose — including this
    # repo's habit of quoting the exact reproducer of a defect it fixed
    # (scripts/flash-disk.sh cites `--role be --arch x86 --list`, the command that
    # printed an arm64 Pi ISO) — and a ban that fired on them would be answered with
    # an allowlist instead of a fix. Real command lines and code still bite.
    hits="$(echo "${hits}" | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(#|//|--|\*)" || true)"
    hits="$(echo "${hits}" | grep -vE "^scripts/_roles-lib\.sh:" || true)"
    hits="$(echo "${hits}" | grep -vE -- "${ALLOW_B}" || true)"
    hits="$(echo "${hits}" | sed '/^$/d')"
    if [ -z "${hits}" ]; then
        ok "no alias EMITTED as ${name}"
    else
        bad "an input alias is EMITTED as ${name} — aliases are accepted forever, never written"
        echo "${hits}" | sed 's/^/      /' | head -10
    fi
}
A_RE='be|fe|be\+gpu|be-gpu|host|gpu-host|gpu_host|full|edge_ai|standalone-full'
# NOTE `host` and `full` are excluded from the argv/JSON forms below: `--role host`
# is also gen-provision-keys.sh's own PROFILE name (a different axis that legitimately
# means the plain worker manifest), and `--desktop full` / `"desktop":"full"` is the
# desktop WEIGHT. Both are matched by the narrower forms that follow instead.
A_STRICT='be|fe|be\+gpu|be-gpu|gpu-host|gpu_host|edge_ai|standalone-full'
ban_output "--role (${A_STRICT})( |\$|\")"            '`--role <alias>` on a command line'
ban_output '"role"[[:space:]]*:[[:space:]]*"('"${A_STRICT}"')"'   'a `"role": "<alias>"` JSON value'
ban_output "^[[:space:]]*ROLE=\"?(${A_STRICT})\"?[[:space:]]*(#|\$)" 'a `ROLE=<alias>` shell default'
ban_output "^[[:space:]]{4}(${A_STRICT})\)"           'a role `case` arm'
# matrix.tsv is scanned as a FILE, not by a whole-tree regex: `^<word> <alias> `
# matches ordinary English prose ("would be a no-op", "cannot be end-to-end tested")
# in every README in the repo, and a ban that fires on prose gets answered with a
# wall of allowlist entries instead of a fix.
mx_alias="$(awk 'NF && $1 !~ /^#/ {print FILENAME ":" FNR ": " $2}' \
    "${GEN}/tests/build-matrix/matrix.tsv" \
    | grep -E ": (${A_STRICT}|host|full)$" || true)"
if [ -z "${mx_alias}" ]; then
    ok "no alias EMITTED as a matrix.tsv role column cell"
else
    bad "an input alias is EMITTED in tests/build-matrix/matrix.tsv's role column"
    echo "${mx_alias}" | sed 's/^/      /' | head -8
fi

# B2) the two aliases that are ALSO legitimate words on another axis. `host` is
#     gen-provision-keys.sh's own PROFILE name (provision.host.json, the plain worker
#     manifest) and `full` is a desktop WEIGHT (--desktop full) — so they cannot be
#     banned by shape alone. They ARE banned when handed to a BUILDER or to the
#     flasher, which is the only place they would mean a role.
bs_alias="$(scan "(build-[a-z0-9-]+-stage4\.sh|flash-disk\.sh)[^|;&]* --role (host|full)( |\$)")"
bs_alias="$(echo "${bs_alias}" | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(#|//)" || true)"
bs_alias="$(echo "${bs_alias}" | sed '/^$/d')"
if [ -z "${bs_alias}" ]; then
    ok "no builder/flasher invocation passes the ambiguous aliases \`host\` or \`full\`"
else
    bad "a builder or the flasher is invoked with \`--role host\` / \`--role full\` — both are ACCEPTED forever, but the canonical spellings are backend-gpu and omnibus"
    echo "${bs_alias}" | sed 's/^/      /' | head -8
fi

# ══ C) NO FIFTH SPELLING ═══════════════════════════════════════════════════════
# The canonical set is CLOSED. Each of these is a plausible transliteration someone
# would reach for; none may exist anywhere, in prose or in code.
ban_variant() {  # ban_variant <regex> <human name>
    local hits
    hits="$(scan "$1")"
    hits="$(echo "${hits}" | sed '/^$/d')"
    if [ -z "${hits}" ]; then ok "no '$2' spelling"
    else bad "banned spelling '$2' — the canonical set is closed (${HUGMESH_ROLES_CANONICAL})"
         echo "${hits}" | sed 's/^/      /' | head -6; fi
}
ban_variant 'backend_gpu'   'backend_gpu'
ban_variant 'backendgpu'    'backendgpu'
ban_variant 'backend\+gpu'  'backend+gpu'
ban_variant 'be_gpu'        'be_gpu'
ban_variant 'frontend-gpu'  'frontend-gpu'
ban_variant 'edgeai'        'edgeai'
ban_variant 'edge\+ai'      'edge+ai'
ban_variant 'Edge_AI'       'Edge_AI'
ban_variant 'omni-bus'      'omni-bus'
# The ONLY sanctioned underscore forms are pytest FUNCTION STEMS: a Python
# identifier cannot hold a hyphen, so `test_..._standalone_thin` is the role id with
# '-'->'_'. Same carve-out shape (and same reason) as
# tests/scripts/test-platform-key-spelling.sh's `test_emission_orange_pi_3_lts`.
ban_variant_except() {  # ban_variant_except <regex> <allow-regex> <human name>
    local hits
    hits="$(scan "$1")"
    hits="$(echo "${hits}" | grep -vE -- "$2" || true)"
    hits="$(echo "${hits}" | sed '/^$/d')"
    if [ -z "${hits}" ]; then ok "no '$3' spelling outside the pytest function stem"
    else bad "banned spelling '$3' — the canonical set is closed (${HUGMESH_ROLES_CANONICAL})"
         echo "${hits}" | sed 's/^/      /' | head -6; fi
}
ban_variant_except 'standalone_thin'  'def test_[a-z0-9_]*standalone_thin'  'standalone_thin'
ban_variant_except 'standalone_thick' 'def test_[a-z0-9_]*standalone_thick' 'standalone_thick'

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
