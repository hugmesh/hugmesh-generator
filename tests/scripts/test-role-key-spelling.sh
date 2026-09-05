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
#   C) NO FIFTH SPELLING. Separator variants (backend_gpu, edge.ai, edgeai) in ANY
#      casing, and any MIS-CASED role token in a --role position. Both are DERIVED
#      from the canonical tokens rather than hand-listed, because a hand-listed set
#      is arbitrary, not closed: the first version banned `Edge_AI` and let `EDGE_AI`,
#      `edgeAI`, `edge.ai`, `Backend_GPU` and `back_end` all through.
#
#   D) ARTIFACT SELECTION STAYS PLATFORM-ANCHORED. The role token is what the
#      globbers key on, so widening a glob to cover every alias is how the platform
#      anchor gets lost — measured: `make qemu-x86 ROLE=pki` handing an aarch64 Pi
#      image to qemu-system-x86_64, and the flasher offering a Jetson image for an
#      arm64 request. Asserted against a fixture by RUNNING the real resolution code.
#
# The builder set is DISCOVERED (`git ls-files build-*-stage4.sh`) and every builder
# found must be classified, so a NEW builder inventing a fresh vocabulary is a FAIL
# rather than an invisible eleventh dialect.
#
# WHAT THIS GUARD DELIBERATELY DOES NOT TOUCH — and why each is a role WORD that is
# NOT a role TOKEN. A mechanical sweep would corrupt all four:
#   * k8s LABEL KEYS  hugmesh.net/backend, /frontend, /pki, /edge-ai. Uniformly long,
#     never divergent (there is no short-form hugmesh.net/<alias> anywhere, in either
#     the `key=value` or the YAML `key: "true"` shape, and check A7 pins BOTH),
#     frozen by scripts/tooling/tokens.json, nodeSelector'd by 73 files under
#     specs/cluster/, and read by two live selectors that fail OPEN on a stale one.
#   * gateway TIERS   hugmesh-be-gateway / hugmesh-fe-gateway, apps/20-gateway-*.yaml
#   * reserved URL HANDLES  specs/cluster/reserved-prefixes.yaml reserves the literal
#     handle `be`; hugmesh.net/be/** is a live URL PATH, not a label key.
#   * PERSON roles    user|mod|admin|superadmin (--person-role), persisted under the
#     same JSON key name `role` as an image role (and, multi-role since issue #228,
#     as a `roles` list beside it — grants like games/games-services included).
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

# A0) THE BUILDER SET IS DISCOVERED, NOT DECLARED. A hardcoded list makes a NEW
#     builder invisible to every check below — it could invent a fresh vocabulary,
#     source nothing, and stay green, which is the exact route "the fourth spelling
#     keeps coming back" takes. So the list comes from `git ls-files`, and every
#     builder found must be CLASSIFIED as role-axis or free-slug. Adding a builder
#     is then a decision that has to be made here.
mapfile -t BUILDERS < <(cd "${GEN}" && git ls-files 'build-*-stage4.sh' | sort)
[ "${#BUILDERS[@]}" -gt 0 ] || guard_require_capability "git ls-files found no build-*-stage4.sh — every builder check below would be vacuous"
ROLE_AXIS=(build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh)
FREE_SLUG=(build-frite-stage4.sh build-orangepi5-stage4.sh build-orangepi4-lts-stage4.sh
           build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh
           build-orangepi-zero3-stage4.sh build-orangepi3-lts-stage4.sh)
unclassified=""
for b in "${BUILDERS[@]}"; do
    case " ${ROLE_AXIS[*]} ${FREE_SLUG[*]} " in
        *" ${b} "*) ;;
        *) unclassified="${unclassified} ${b}" ;;
    esac
done
if [ -z "${unclassified// /}" ]; then
    ok "every builder on disk is classified (${#ROLE_AXIS[@]} role-axis, ${#FREE_SLUG[@]} free-slug)"
else
    bad "UNCLASSIFIED builder(s):${unclassified} — a new builder must be declared here as role-axis or free-slug, or nothing below checks its role vocabulary at all"
fi
for b in "${ROLE_AXIS[@]}" "${FREE_SLUG[@]}"; do
    [ -f "${GEN}/${b}" ] || bad "${b} is classified here but does not exist — the classification is stale"
done

# A1) every builder SOURCES the lib. A builder that does not cannot fold an alias,
#     and would be free to grow its own vocabulary again.
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
for b in "${FREE_SLUG[@]}"; do
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

# A4c) THE HOSTNAME TABLE ITSELF — a POSITIVE control on the derived rule.
#      A4b proves the builders no longer hardcode a hostname; that moved the whole
#      surface INTO scripts/_roles-lib.sh, which is exempt from the bucket-B scan
#      (it is the file that declares the aliases). So the lib's own table became the
#      one place a hostname regression could live unseen: two lines in
#      HUGMESH_ROLE_HOSTNAME_SUFFIX would bake /etc/hostname = hugmesh-be on every
#      x86 backend node with a fully green gate. Mutation-proven — that is exactly
#      what happened. Pinned here so changing a hostname is a DECISION made in the
#      guard, not a table edit nobody reads.
#      The rule: "${BRAND}-${ROLE}", with these documented exceptions and no others.
HOSTNAME_EXCEPTIONS="
x86:backend-gpu=hugmesh-host
x86:standalone-thick=hugmesh-standalone
jetson:edge-ai=hugmesh-jetson-edge-ai
jetson:backend-gpu=hugmesh-jetson-gpu
jetson:omnibus=hugmesh-jetson-full
jetson:desktop=hugmesh-jetson
rpi5:generic=gentoo-rpi5
"
hn_bad=0
for pair in "x86:${HUGMESH_ROLES_X86}" "rpi5:${HUGMESH_ROLES_RPI5}" "jetson:${HUGMESH_ROLES_JETSON}"; do
    plat="${pair%%:*}"
    for r in ${pair#*:}; do
        if want="$(_hm_role_lookup "${HOSTNAME_EXCEPTIONS}" "${plat}:${r}")"; then :; else want="hugmesh-${r}"; fi
        got="$(hugmesh_role_hostname "${plat}" "${r}" hugmesh)"
        if [ "${got}" != "${want}" ]; then
            bad "default hostname for ${plat}/${r} is '${got}', pinned as '${want}'"
            hn_bad=1
        fi
    done
done
[ "${hn_bad}" -eq 0 ] && ok "every default hostname matches the pinned table (\${BRAND}-\${ROLE}, 7 documented exceptions)"

# A4d) THE ARTIFACT TAG IS THE IDENTITY FUNCTION. `be+gpu) ROLE_TAG="host"` was the
#      translation that made the CLI token and the filename disagree by design, and
#      deleting it is the centrepiece of this change — so it needs a guard, or it
#      grows back in its natural, canonical-armed form
#      (`backend-gpu) ROLE_TAG="be+gpu"`), which no alias-as-case-ARM ban can see.
#      ROLE_TAG may only ever be built out of ${ROLE}.
# Anywhere on the line, not just line-anchored: the translation grows back INSIDE a
# case arm (`    backend-gpu)  ROLE_TAG="be+gpu" ;;`), which a `^[[:space:]]*ROLE_TAG=`
# anchor cannot see — mutation-proven, that exact shape passed green.
rt="$(grep -nE '(^|[^A-Za-z0-9_])_?(PLAN_)?ROLE_TAG=' "${GEN}/build-x86-host-stage4.sh" || true)"
rt="$(echo "${rt}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
rt_bad="$(echo "${rt}" | grep -vE 'ROLE_TAG="\$\{ROLE\}' || true)"
rt_bad="$(echo "${rt_bad}" | sed '/^$/d')"
if [ -z "${rt}" ]; then
    bad "no ROLE_TAG assignment found in build-x86-host-stage4.sh — A4d would be vacuous"
elif [ -z "${rt_bad}" ]; then
    ok "artifact ROLE_TAG is derived from \${ROLE} only (the be+gpu->host fold stays deleted)"
else
    bad "ROLE_TAG is TRANSLATED again — the artifact filename would stop matching the --role token"
    echo "${rt_bad}" | sed 's/^/      /' | head -5
fi

# A4e) THE /etc/hugmesh/role MARKER. It is the first derived output axis and the one
#      thing a running node carries forever; specs/etc/keys-provision/provision.sh
#      reads it to pick a node's staging keys. Every builder must write ${ROLE}
#      verbatim — a literal there would bake a spelling nothing else uses.
mk_bad=""
for b in "${BUILDERS[@]}"; do
    w="$(grep -nE '>[[:space:]]*"\$\{SYSROOT\}/etc/hugmesh/role"' "${GEN}/${b}" || true)"
    if [ -z "${w}" ]; then
        mk_bad="${mk_bad} ${b}(no marker write)"
    elif ! echo "${w}" | grep -E 'echo "\$\{ROLE\}"' >/dev/null; then
        mk_bad="${mk_bad} ${b}(not \${ROLE})"
    fi
done
if [ -z "${mk_bad// /}" ]; then
    ok "every builder writes /etc/hugmesh/role as \${ROLE} (the canonical token, verbatim)"
else
    bad "the /etc/hugmesh/role marker is not the canonical role in:${mk_bad}"
fi

# A5) THE STUDIO. ROLE_CHOICES is the Studio's own authority; its per-platform sets
#     must EQUAL the lib's. This is the check that catches "the Studio offers a role
#     no builder builds" AND "a builder grew a role the Studio cannot reach".
#
#     A5a compares the CANONICALIZED sets, so it is deliberately blind to which
#     SPELLING the Studio holds — and the Studio inventing `be`/`fe` is the exact
#     divergence this whole change deletes. A5b therefore checks the RAW ids, and it
#     is the one that would notice a revert. (Mutation-proven: replacing the Studio's
#     `backend`/`frontend` ids with `be`/`fe` left A5a fully green, because
#     builder_role() folds both spellings to the same token before comparing.)
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

# A5b) THE RAW STUDIO IDS — every platform, including the seven free-slug boards,
#      which A5a never looks at. An id may be a canonical token or a declared
#      COMPOSITE id (rpi5-desktop / jetson-desktop carry a platform and are retired
#      separately, see the lib). It may NOT be a plain input alias: `be`/`fe` are
#      accepted from an operator forever, and are exactly what the Studio must stop
#      OFFERING. It may not be an invented spelling either.
studio_raw_ids() {
    PYTHONPATH="${GEN}/studio" "${PY}" - <<'EOF'
from hugmesh_studio.core.config import ROLE_CHOICES
print("\n".join(sorted({r for mode in ROLE_CHOICES for r, _p, _l in ROLE_CHOICES[mode]})))
EOF
}
raw="$(studio_raw_ids 2>/dev/null || true)"
composite_ids="$(printf '%s\n' ${HUGMESH_ROLE_COMPOSITE} | sed 's/=.*//' | sort -u | tr '\n' ' ')"
if [ -z "${raw}" ]; then
    bad "Studio ROLE_CHOICES raw ids could not be read — A5b would be vacuous"
else
    # The seven free-slug boards have NO role axis: the Studio's "role" id there is
    # the BOARD itself (frite, orangepi5, …) and its --role is a hostname marker.
    # DERIVED from the lib's own hostname table rather than restated, so a new board
    # is declared in one place. x86/rpi5/jetson are the role-axis platforms.
    board_ids="$(printf '%s\n' ${HUGMESH_ROLE_HOSTNAME_SUFFIX} | sed 's/:.*//' \
                 | grep -vxE 'x86|rpi5|jetson' | sort -u | tr '\n' ' ')"
    offending=""
    for r in ${raw}; do
        hugmesh_role_is_canonical "${r}" && continue
        case " ${composite_ids} " in *" ${r} "*) continue ;; esac
        case " ${board_ids} " in *" ${r} "*) continue ;; esac
        offending="${offending} ${r}"
    done
    if [ -z "${offending// /}" ]; then
        ok "Studio ROLE_CHOICES raw ids: all canonical (or a declared composite id / free-slug board)"
    else
        bad "Studio OFFERS a non-canonical role id:${offending}"
        echo "      An alias (be, fe, be+gpu, edge_ai, …) is accepted from an operator FOREVER,"
        echo "      but the Studio is a producer: its ids become argv, session records and"
        echo "      artifact names. Offering one is the divergence, not the compatibility."
    fi
fi

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
# The `KEY=VALUE` shape alone was not enough: all ~73 nodeSelector files write the
# YAML `key: "true"` shape, and only `be`/`fe` were listed. Both mutation-proven —
# `hugmesh.net/be: "true"` in a real gateway manifest passed green. Matched now: any
# short suffix, terminated by anything that is not a path character, so the LIVE URL
# PATH `hugmesh.net/be/**` (specs/cluster/apps/20-gateway-fe.yaml) is untouched —
# that is a user-visible route, not a label key, and renaming it would break URLs.
# A COMMENT IS NOT EXEMPT HERE, unlike bucket B: `# kubectl get nodes -l
# hugmesh.net/be=true` is a copy-pasteable command that would silently return
# nothing, and a selector that returns nothing FAILS OPEN in bootstrap.sh. What
# keeps prose out is the terminator, not the comment marker — a label KEY is always
# followed by `=` or `:` (or a bare `-l key` at end of line), never by a backtick,
# which is how the lib's own "there are ZERO hugmesh.net/be keys" sentence is
# written. `/` is excluded so the LIVE URL PATH hugmesh.net/be/** is untouched.
lab="$(scan 'hugmesh\.net/(be|fe|be-gpu|be\+gpu|gpu-host|gpu_host|edge_ai|backend_gpu)([^A-Za-z0-9/_.`-]|$)' || true)"
lab="$(echo "${lab}" | sed '/^$/d')"
if [ -z "${lab}" ]; then
    ok "no short-form hugmesh.net/<alias> LABEL KEY, in either the = or the YAML : shape"
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
#   templates/archetypes/gateway/_identity.env
#                                 PROFILE="be" is the GATEWAY TIER (the exemplar
#                                 member is hugmesh-gateway's `be` profile), one of
#                                 the four non-role axes this guard's header lists.
#                                 It is a drift ORACLE, never consumed at emit time.
ALLOW_B='tests/build-matrix/check\.sh:[0-9]+:.*x86\.be-gpu|templates/archetypes/gateway/_identity\.env:[0-9]+:PROFILE='
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
# NOTE `host` and `full` are excluded from the argv/JSON forms below: `--role host`
# is also gen-provision-keys.sh's own PROFILE name (a different axis that legitimately
# means the plain worker manifest), and `--desktop full` / `"desktop":"full"` is the
# desktop WEIGHT. Both are matched by the narrower forms that follow instead.
# LONGEST ALTERNATIVE FIRST so `be+gpu` is never matched as `be` plus a boundary.
A_STRICT='be\+gpu|be-gpu|gpu-host|gpu_host|standalone-full|edge_ai|be|fe'
# The terminator is "anything that is not a role-token character", not " or $ or a
# double quote. The repo's own doc idiom writes a command in BACKTICKS
# (docs/ARCHITECTURE.md: `build-rpi5-stage4.sh --role backend`), and a backtick-,
# comma- or period-terminated command line is every bit as copy-pasteable as a bare
# one. `--role=<alias>` and the short `-r <alias>` are the same emission spelled
# differently. All four forms were mutation-proven to slip the narrower pattern.
A_END='([^A-Za-z0-9._+-]|$)'
ban_output "--role[= ](${A_STRICT})${A_END}"       '`--role <alias>` on a command line'
ban_output "(build-[a-z0-9-]+-stage4\.sh|launch-(x86|pi)\.sh|flash-disk\.sh|mesh-cluster\.sh)[^|;&]* -r (${A_STRICT})${A_END}" \
                                                   'a short `-r <alias>` on a builder/launcher command line'
ban_output '"role"[[:space:]]*:[[:space:]]*"('"${A_STRICT}"')"'   'a `"role": "<alias>"` JSON value'
# Any variable, any indent, `export` or not: `export ROLE=be+gpu` and a WORKER_ROLE
# default are the same emission as a bare `ROLE=`. Mutation-proven: the `^ROLE=`
# anchor missed both, and a real one was live in tests/qemu/mesh-cluster.sh.
ban_output "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\"?(${A_STRICT})\"?[[:space:]]*(#|;|\$)" \
                                                   'an alias assigned to a shell variable'
# Any indent: an 8-space `be)` arm is a case arm too.
ban_output "^[[:space:]]+(${A_STRICT})\)"         'a role `case` arm'
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
# The canonical set is CLOSED. The old form of this bucket was a hand-written,
# case-SENSITIVE list of nine literals, which is arbitrary rather than closed: it
# banned `Edge_AI` but not `EDGE_AI`, `edgeAI`, `edge.ai`, `Backend_GPU` or
# `back_end`, all of which walked straight through when an adversarial battery tried
# them. Both checks below are now DERIVED from the canonical tokens, so a new
# multi-word role is covered the day it is declared.

# C1) SEPARATOR variants, generated from the vocabulary, matched case-insensitively.
#     `backend-gpu` may not also be spelled backend_gpu / backend.gpu / backend+gpu /
#     backendgpu in ANY casing.
#     TWO carve-outs, both for the same reason — an IDENTIFIER cannot hold a hyphen:
#       * an ALL-CAPS match is a shell variable / mermaid node id / env name
#         (WANT_EDGE_AI, EDGE_AI, OMNIBUS, the ARCHITECTURE.md diagram's EDGEAI node).
#       * a pytest FUNCTION STEM (def test_…_standalone_thin) — the same carve-out,
#         and the same shape, as tests/scripts/test-platform-key-spelling.sh's
#         test_emission_orange_pi_3_lts.
#     A DECLARED ALIAS is never a fifth spelling: `edge_ai` is in the alias table and
#     in artifact names already on disk.
sep_variants=""
for t in ${HUGMESH_ROLES_CANONICAL}; do
    case "${t}" in *-*) ;; *) continue ;; esac
    _h="${t%%-*}"; _r="${t#*-}"
    sep_variants="${sep_variants} ${_h}_${_r} ${_h}\\.${_r} ${_h}\\+${_r} ${_h}${_r}"
done
SEP_RE="$(echo ${sep_variants} | tr ' ' '|')"
[ -n "${SEP_RE}" ] || bad "no separator variants were generated — C1 would be vacuous"
declared_lc=" $(echo ${HUGMESH_ROLES_CANONICAL} $(printf '%s\n' ${HUGMESH_ROLE_ALIASES} | sed 's/=.*//') | tr 'A-Z' 'a-z') "
c1_hits="$( (cd "${GEN}" && grep -HoIn -iE -- "(${SEP_RE})" "${TRACKED[@]}" 2>/dev/null) || true)"
c1_bad=""
while IFS= read -r h; do
    [ -n "${h}" ] || continue
    m="${h##*:}"
    case "${m}" in *[a-z]*) ;; *) continue ;; esac            # ALL-CAPS identifier: allowed
    lc="$(echo "${m}" | tr 'A-Z' 'a-z')"
    case "${declared_lc}" in *" ${lc} "*) continue ;; esac    # a declared alias
    # grep -o gives file:line:MATCH, so the pytest carve-out has to read the SOURCE
    # line back — matching it against the token alone silently never fires.
    _f="${h%%:*}"; _rest="${h#*:}"; _ln="${_rest%%:*}"
    _src="$(sed -n "${_ln}p" "${GEN}/${_f}" 2>/dev/null || true)"
    case "${_src}" in *"def test_"*"${m}"*) continue ;; esac
    c1_bad="${c1_bad}${h}
"
done <<< "${c1_hits}"
c1_bad="$(echo "${c1_bad}" | sed '/^$/d')"
if [ -z "${c1_bad}" ]; then
    ok "no separator variant of a canonical role (backend_gpu / edge.ai / edgeai / …), in any casing"
else
    bad "a FIFTH spelling of a canonical role — the set is closed (${HUGMESH_ROLES_CANONICAL})"
    echo "${c1_bad}" | sed 's/^/      /' | head -8
fi

# C2) CASE variants IN A ROLE POSITION. `--role EDGE_AI` / `--role BACKEND-GPU` /
#     `--role Be` are not separator variants, so C1's identifier carve-out lets them
#     past — but in a role position an identifier carve-out makes no sense: the
#     tokens are lowercase everywhere. This fires ONLY when the token case-folds onto
#     something the vocabulary already knows, so it can never bite on a placeholder
#     (`--role <r>`, `--role ${ROLE}`) or on prose ("validates --role through the
#     shared vocabulary"), which is why it needs no allowlist at all.
known_lc=" $(echo ${HUGMESH_ROLES_CANONICAL} \
    $(printf '%s\n' ${HUGMESH_ROLE_ALIASES} | sed 's/=.*//') \
    $(printf '%s\n' ${HUGMESH_ROLE_COMPOSITE} | sed 's/=.*//') | tr 'A-Z' 'a-z') "
c2_hits="$( (cd "${GEN}" && grep -HoIn -E -- '--role[= ][A-Za-z0-9_.+-]+' "${TRACKED[@]}" 2>/dev/null) || true)"
c2_bad=""
while IFS= read -r h; do
    [ -n "${h}" ] || continue
    tok="${h##*--role}"; tok="${tok#[= ]}"
    lc="$(echo "${tok}" | tr 'A-Z' 'a-z')"
    [ "${tok}" = "${lc}" ] && continue
    case "${known_lc}" in *" ${lc} "*) c2_bad="${c2_bad}${h}
" ;; esac
done <<< "${c2_hits}"
c2_bad="$(echo "${c2_bad}" | sed '/^$/d')"
if [ -z "${c2_bad}" ]; then
    ok "no MIS-CASED role token in a --role position (role tokens are lowercase, always)"
else
    bad "a role token is spelled with the wrong case in a --role position"
    echo "${c2_bad}" | sed 's/^/      /' | head -8
fi

# ══ D) ARTIFACT SELECTION STAYS PLATFORM-ANCHORED ══════════════════════════════
# The role token is what the artifact GLOBBERS key on, and widening a glob to cover
# every alias is exactly how one loses the platform anchor: an unanchored
# `hugmesh-*-<role>-*.img` matches the rpi5 image as happily as the x86 one, and both
# land in the same WORK_DIR under the documented `make` default
# (Makefile: WORK_DIR ?= $(CURDIR)/out, written by BOTH `make x86-<role>` and
# `make rpi-<role>`). Measured: `make qemu-x86 ROLE=pki` handed an aarch64 Raspberry
# Pi image to qemu-system-x86_64 — for `pki`, a role with NO aliases at all, so no
# spelling check anywhere could have caught it.
#
# ASSERTED BY BEHAVIOUR against a fixture, not by reading the glob order: the real
# autodetect_img body is evaluated out of each launcher with the real
# scripts/_roles-lib.sh sourced. The launchers themselves die early on a missing
# qemu-system-*, which a CI container has, so the FUNCTION is exercised rather than
# the script.
fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT
for n in hugmesh-x86-amd64-pki-test-20260101T000000Z.img \
         hugmesh-x86-amd64-backend-test-20260101T000000Z.img \
         hugmesh-x86-amd64-frontend-test-20260101T000000Z.img \
         hugmesh-rpi5-arm64-pki-test-20260101T000000Z.img \
         hugmesh-rpi5-arm64-backend-test-20260101T000000Z.img \
         hugmesh-rpi5-arm64-frontend-test-20260101T000000Z.img \
         hugmesh-x86-amd64-host-test-20260101T000000Z.img ; do
    : > "${fixture_dir}/${n}"
done
autodetect_of() {  # autodetect_of <launcher> <role> [dir]
    local _dd
    _dd="${3:-${fixture_dir}}"
    bash -c "
        set -uo pipefail
        . '${LIB}'
        $(awk '/^autodetect_img\(\) \{/,/^\}/' "${GEN}/tests/qemu/$1")
        autodetect_img '${_dd}' '$2'
    " 2>/dev/null | tail -1
}
# THE FOREIGN PLATFORM IS ALWAYS THE NEWEST, per launcher. newest-mtime-first is
# what makes a lost anchor bite, so a fixture that leaves the launcher's own platform
# newest cannot fail — mutation-proven: with rpi5 newest for BOTH probes, breaking
# launch-pi.sh's anchor stayed green because the unanchored glob still landed on rpi5.
for pair in "launch-x86.sh:x86-amd64:rpi5" "launch-pi.sh:rpi5-arm64:x86"; do
    L="${pair%%:*}"; rest="${pair#*:}"; want_plat="${rest%%:*}"; foreign="${rest##*:}"
    touch -d '2020-01-01 00:00' "${fixture_dir}"/hugmesh-*.img
    touch -d '2030-01-01 00:00' "${fixture_dir}"/hugmesh-"${foreign}"-*.img
    for r in pki backend frontend; do
        got="$(basename "$(autodetect_of "${L}" "${r}")" 2>/dev/null || true)"
        case "${got}" in
            hugmesh-"${want_plat}"-*) ok "${L} --role ${r}: stays on ${want_plat} (${got})" ;;
            "") bad "${L} --role ${r}: autodetect_img returned NOTHING — the probe is vacuous, or the function moved" ;;
            *)  bad "${L} --role ${r}: crossed platforms and picked ${got} — a ${want_plat} launcher must never boot another board's image" ;;
        esac
    done
done

# D1b) THE ROLE THAT IS ABSENT ON THE LAUNCHER'S OWN PLATFORM. D1 cannot see this:
#      its fixture holds an own-platform image of every probed role, so the
#      platform-anchored glob always wins and the unanchored one is never reached —
#      mutation-proven: reverting launch-pi.sh's fix left every D1 check green,
#      because the defect only fires when the requested role has NO rpi5 image and
#      an x86 one exists (an alias-loop `hugmesh-*-<role>-*.img` beats the rpi5
#      platform fallback). The pre-rename contract, restored here, is "right arch
#      even at the cost of the role": the launcher must fall back to an own-platform
#      image of ANOTHER role before it ever crosses to a foreign board's image.
d1b_dir="$(mktemp -d)"
: > "${d1b_dir}/hugmesh-rpi5-arm64-backend-test-20260101T000000Z.img"
: > "${d1b_dir}/hugmesh-x86-amd64-pki-test-20260102T000000Z.img"
for pair in "launch-pi.sh:pki:rpi5-arm64" "launch-x86.sh:backend:x86-amd64"; do
    L="${pair%%:*}"; rest="${pair#*:}"; r="${rest%%:*}"; want_plat="${rest##*:}"
    got="$(basename "$(autodetect_of "${L}" "${r}" "${d1b_dir}")" 2>/dev/null || true)"
    case "${got}" in
        hugmesh-"${want_plat}"-*) ok "${L} --role ${r} (no own-platform ${r} image): falls back on ${want_plat} (${got})" ;;
        "") bad "${L} --role ${r}: autodetect_img returned NOTHING — the probe is vacuous, or the function moved" ;;
        *)  bad "${L} --role ${r}: with no own-platform ${r} image it crossed to ${got} — the platform fallback must fire before any foreign-board role match" ;;
    esac
done
rm -rf "${d1b_dir}"

# D2) the FLASHER. Same anchor, far higher stakes: it writes a whole physical disk.
#     `--arch` alone is not enough on arm64, where rpi5, jetson, frite and four Orange
#     Pi boards ALL emit arm64 images — the arch token cannot separate them.
#     The fixture carries a STALE `hugmesh-frite-arm64-backend-…` image, which is
#     exactly what the free-slug boards used to emit (`--role backend` on an Orange Pi
#     was silently accepted and became a hostname), and makes it the NEWEST. Only the
#     platform anchor keeps `--role backend --arch arm64` off it.
: > "${fixture_dir}/hugmesh-jetson-orin-nano-arm64-full-test-20260101T000000Z.img"
: > "${fixture_dir}/hugmesh-frite-arm64-backend-test-20260101T000000Z.img"
: > "${fixture_dir}/hugmesh-frite-arm64-pki-test-20260101T000000Z.img"
touch -d '2020-01-01 00:00' "${fixture_dir}"/hugmesh-*.img
touch -d '2031-01-01 00:00' "${fixture_dir}"/hugmesh-frite-*.img "${fixture_dir}"/hugmesh-jetson-*.img
flash_pick() {  # flash_pick <role> <arch>
    (cd "${GEN}" && ./scripts/flash-disk.sh --role "$1" --arch "$2" \
        --work-dir "${fixture_dir}" --list 2>/dev/null \
        | sed -n 's/^Would flash: //p') || true
}
for probe in "backend:arm64:hugmesh-rpi5-" "pki:arm64:hugmesh-rpi5-" \
             "omnibus:arm64:hugmesh-jetson-" "backend:x86:hugmesh-x86-" \
             "be:x86:hugmesh-x86-" "host:x86:hugmesh-x86-"; do
    r="${probe%%:*}"; rest="${probe#*:}"; a="${rest%%:*}"; want="${rest##*:}"
    got="$(basename "$(flash_pick "${r}" "${a}")" 2>/dev/null || true)"
    case "${got}" in
        "${want}"*) ok "flash-disk.sh --role ${r} --arch ${a}: ${got}" ;;
        "")         bad "flash-disk.sh --role ${r} --arch ${a}: found NOTHING — the probe is vacuous" ;;
        *)          bad "flash-disk.sh --role ${r} --arch ${a} resolved to ${got}, expected a ${want}* image — a wrong-board flash writes a whole disk" ;;
    esac
done

# D3) the roles that genuinely span boards (desktop, laptop, a free slug) cannot be
#     narrowed by derivation, so the flasher must REFUSE rather than pick the newest.
: > "${fixture_dir}/hugmesh-rpi5-arm64-desktop-user-test-20260101T000000Z.img"
: > "${fixture_dir}/hugmesh-frite-arm64-desktop-user-test-20260101T000000Z.img"
amb_out="$( (cd "${GEN}" && ./scripts/flash-disk.sh --role desktop --arch arm64 \
             --work-dir "${fixture_dir}" --list 2>/dev/null) || true)"
if echo "${amb_out}" | grep -E '^AMBIGUOUS' >/dev/null; then
    ok "flash-disk.sh --role desktop --arch arm64: reports the cross-board ambiguity"
else
    bad "flash-disk.sh --role desktop --arch arm64: picked a board silently — desktop is built by rpi5, jetson, frite and four Orange Pi boards, and newest-mtime is not a board choice"
fi

# D4) THE BRAND IS NOT AN ANCHOR — and removing it must not cost the platform one.
#     The artifact's first field is ${BRAND} (build-rpi5-stage4.sh / build-x86-host-
#     stage4.sh IMG_PATH), which is "hugmesh" only by DEFAULT: `--brand sdhm` for
#     the operator's own mesh, a forced `gentoo` for an unaffiliated build. Every
#     globber above used to spell `hugmesh-` literally, so a finished sdhm mesh was
#     invisible to the launchers, the flasher AND the emulation picker — the
#     reported defect ("mesh emulation screen dropdown can't seem to use the 3 pi
#     images session that completed successfully").
#
#     Both halves are asserted together on purpose. Widening the brand is one edit
#     away from widening the PLATFORM too (`*-host-*` would match a Pi image whose
#     ROLE is host), and this fixture makes the branded FOREIGN image the newest one
#     so a lost anchor picks it.
brand_dir="$(mktemp -d)"
: > "${brand_dir}/sdhm-rpi5-arm64-pki-test-20260831T015954Z.img"
: > "${brand_dir}/sdhm-rpi5-arm64-backend-test-20260831T025801Z.img"
: > "${brand_dir}/sdhm-x86-amd64-pki-test-20260831T045801Z.img"
: > "${brand_dir}/sdhm-x86-amd64-backend-test-20260831T055801Z.img"
touch -d '2020-01-01 00:00' "${brand_dir}"/sdhm-*.img
for probe in "launch-pi.sh:pki:sdhm-rpi5-:sdhm-x86-" \
             "launch-pi.sh:backend:sdhm-rpi5-:sdhm-x86-" \
             "launch-x86.sh:pki:sdhm-x86-:sdhm-rpi5-" \
             "launch-x86.sh:backend:sdhm-x86-:sdhm-rpi5-"; do
    L="${probe%%:*}"; rest="${probe#*:}"
    r="${rest%%:*}"; rest="${rest#*:}"
    want="${rest%%:*}"; foreign="${rest##*:}"
    # the FOREIGN-platform branded image is the newest, so an unanchored glob takes it
    touch -d '2030-01-01 00:00' "${brand_dir}"/"${foreign}"*.img
    got="$(basename "$(autodetect_of "${L}" "${r}" "${brand_dir}")" 2>/dev/null || true)"
    case "${got}" in
        "${want}"*) ok "${L} --role ${r}: resolves a BRANDED image, still platform-anchored (${got})" ;;
        "")         bad "${L} --role ${r}: found NOTHING in a dir of sdhm-* images — the brand is still hard-coded" ;;
        *)          bad "${L} --role ${r}: crossed platforms to ${got} — widening the brand must not widen the platform anchor" ;;
    esac
    touch -d '2020-01-01 00:00' "${brand_dir}"/sdhm-*.img
done
for probe in "backend:arm64:sdhm-rpi5-" "pki:arm64:sdhm-rpi5-" \
             "backend:x86:sdhm-x86-" "pki:x86:sdhm-x86-"; do
    r="${probe%%:*}"; rest="${probe#*:}"; a="${rest%%:*}"; want="${rest##*:}"
    got="$(basename "$( (cd "${GEN}" && ./scripts/flash-disk.sh --role "${r}" --arch "${a}" \
        --work-dir "${brand_dir}" --list 2>/dev/null | sed -n 's/^Would flash: //p') || true)" \
        2>/dev/null || true)"
    case "${got}" in
        "${want}"*) ok "flash-disk.sh --role ${r} --arch ${a} (branded): ${got}" ;;
        "")         bad "flash-disk.sh --role ${r} --arch ${a}: found NOTHING among sdhm-* images — the brand is still hard-coded" ;;
        *)          bad "flash-disk.sh --role ${r} --arch ${a} resolved to ${got}, expected a ${want}* image" ;;
    esac
done
rm -rf "${brand_dir}"

# D5) THE ONE BRAND LITERAL THAT IS KEPT ON PURPOSE, GUARDED.
#     launch-x86.sh's any-role fallback still globs `hugmesh-host-*.img` with the
#     brand spelled out, because "host" is ALSO a role alias (be+gpu): widening it
#     to `*-host-*` would match <brand>-rpi5-arm64-host-….img and hand an aarch64
#     image to qemu-system-x86_64. Nothing asserted that until now — mutating both
#     kept literals left the whole suite green, because every other probe's fixture
#     either has an own-platform image of the requested role (so the role-scoped
#     globs return first) or no ARM image whose role is `host` at all.
#
#     This fixture reaches the any-role loop on purpose: the requested role exists
#     on NEITHER image, so the role-scoped globs all miss, and the Pi image (whose
#     role field is literally `host`) is the newest.
host_dir="$(mktemp -d)"
: > "${host_dir}/sdhm-rpi5-arm64-host-test-20260831T090000Z.img"
: > "${host_dir}/sdhm-x86-amd64-pki-test-20260831T010000Z.img"
touch -d '2020-01-01 00:00' "${host_dir}/sdhm-x86-amd64-pki-test-20260831T010000Z.img"
touch -d '2030-01-01 00:00' "${host_dir}/sdhm-rpi5-arm64-host-test-20260831T090000Z.img"
got="$(basename "$(autodetect_of launch-x86.sh frontend "${host_dir}")" 2>/dev/null || true)"
case "${got}" in
    sdhm-x86-*) ok "launch-x86.sh any-role fallback: stays on x86 (${got}) with a newer ARM image whose ROLE is 'host'" ;;
    "")         bad "launch-x86.sh any-role fallback: found NOTHING — the probe is vacuous, or autodetect_img moved" ;;
    *)          bad "launch-x86.sh any-role fallback: picked ${got} — \`hugmesh-host-*\` must keep its literal brand, or a Pi image reaches qemu-system-x86_64" ;;
esac
rm -rf "${host_dir}"

# D6) A BRAND MAY CONTAIN '-', AND ONLY THE MANIFEST KNOWS WHERE IT ENDS.
#     validate_brand accepts any DNS label, so `--brand my-mesh` mints
#     my-mesh-rpi5-arm64-pki-test-<stamp>.img. A positional "strip up to the first
#     '-'" reads its platform as "mesh-rpi5", which is not a board — beside a
#     default-brand image of the SAME board that reads "rpi5", flash-disk.sh then
#     announces a cross-platform ambiguity that does not exist and a real flash
#     REFUSES. platform_of ends the brand by NAME when the session manifest
#     declares one (the same key run-qemu-docker.sh and qemu_tests.py read).
hyphen_dir="$(mktemp -d)"
cat > "${hyphen_dir}/hugmesh-mesh-manifest.json" <<'JSON'
{
  "format": 2,
  "brand": "my-mesh",
  "brand_title": "My Mesh",
  "images": [{"id": "pki.rpi5", "role": "pki", "platform": "rpi5"}]
}
JSON
: > "${hyphen_dir}/my-mesh-rpi5-arm64-pki-test-20260831T015954Z.img"
: > "${hyphen_dir}/hugmesh-rpi5-arm64-pki-test-20260830T015954Z.img"
listing="$( (cd "${GEN}" && ./scripts/flash-disk.sh --role pki --arch arm64 \
    --work-dir "${hyphen_dir}" --list 2>&1) || true)"
case "${listing}" in
    *AMBIGUOUS*) bad "flash-disk.sh: a hyphenated brand reads as its own platform — one rpi5 dir announced a cross-platform ambiguity" ;;
    *"Would flash: "*) ok "flash-disk.sh: manifest brand 'my-mesh' ends the brand field; both images are one rpi5 platform" ;;
    *) bad "flash-disk.sh --list produced no verdict for a hyphenated-brand dir: ${listing}" ;;
esac
rm -rf "${hyphen_dir}"

# D7) THE ROLE TOKEN IS TERMINAL, NOT A PREFIX.
#     `backend` / `backend-gpu` is the ONE pair in the canonical set where one
#     spelling is the other's prefix at a hyphen boundary (the alias set adds
#     be/be-gpu and full/standalone-full). Every artifact consumer finds an image
#     with a `*-<role>-*` glob, and `-backend-` prefix-matches
#     <brand>-x86-amd64-backend-gpu-<env>-<ts>.img.
#
#     This became REACHABLE when the be+gpu -> `host` artifact-tag fold was dropped
#     (build-x86-host-stage4.sh now emits ROLE_TAG="${ROLE}"): while the GPU image
#     was named …-host-…, `-be-` could not prefix-match `-host-`, and no emitted
#     name pair collided on any platform. Measured on the merge commit: with the
#     DEFAULT x86 fleet (scripts/build-all-roles.sh X86_BUILD_ROLES=
#     "pki backend frontend backend-gpu", built into ONE work dir),
#     `flash-disk.sh --role backend --arch x86` resolved the backend-GPU image —
#     a whole-physical-disk write of the GPU worker onto a plain backend node,
#     with no AMBIGUOUS line and no assert_one_platform refusal possible, because
#     both artifacts are platform x86.
#
#     BOTH mtime orderings are probed, because the two channels mis-pick for
#     DIFFERENT reasons and a one-ordering fixture proves only one of them:
#       * flash-disk.sh is genuinely `ls -1t` mtime-ordered, so it only mis-picks
#         when backend-gpu is the newer — which the default fleet order guarantees.
#       * the launchers' `for c in <glob>` lists expand to individual filenames in
#         ALPHABETICAL order BEFORE `ls -1t` sees them (each iteration `ls`es one
#         already-expanded path), and `backend-gpu` sorts before `backend-<env>`,
#         so they mis-pick regardless of mtime.
#     Asserted on the FULL basename, not a platform prefix: every candidate here is
#     x86, so a prefix assertion (what D1/D2 use) cannot see this at all.
term_dir="$(mktemp -d)"
term_reset() {  # term_reset <newest-role>
    local _n
    local _i=1
    for _n in pki backend frontend backend-gpu; do
        touch -d "2026-02-0${_i} 00:00" "${term_dir}/hugmesh-x86-amd64-${_n}-test-2026020${_i}T000000Z.img"
        _i=$((_i+1))
    done
    touch -d '2026-03-01 00:00' "${term_dir}"/hugmesh-x86-amd64-"$1"-test-*.img
}
# The DEFAULT x86 fleet, in scripts/build-all-roles.sh's own build order, stamped
# so the filenames record it: pki oldest … backend-gpu newest.
: > "${term_dir}/hugmesh-x86-amd64-pki-test-20260201T000000Z.img"
: > "${term_dir}/hugmesh-x86-amd64-backend-test-20260202T000000Z.img"
: > "${term_dir}/hugmesh-x86-amd64-frontend-test-20260203T000000Z.img"
: > "${term_dir}/hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.img"
term_stage4() {  # extract run-qemu-test.sh's real autodetect_stage4
    bash -c "
        set -uo pipefail
        . '${LIB}'
        $(awk '/^autodetect_stage4\(\) \{/,/^\}/' "${GEN}/tests/qemu/run-qemu-test.sh")
        autodetect_stage4 '$1' '$2'
    " 2>/dev/null | tail -1
}
term_entrypoint() {  # extract docker-entrypoint.sh's real autodetect_img
    bash -c "
        set -uo pipefail
        . '${LIB}'
        ARTIFACTS='$1'; PLATFORM='$2'; ROLE='$3'
        $(awk '/^autodetect_img\(\) \{/,/^\}/' "${GEN}/tests/qemu/docker-entrypoint.sh")
        autodetect_img
    " 2>/dev/null | tail -1
}
term_check() {  # term_check <what> <got> <want-basename>
    case "$2" in
        "$3") ok "$1: $2" ;;
        "")   bad "$1: resolved NOTHING — the probe is vacuous, or the function moved" ;;
        *)    bad "$1: resolved $2, expected $3 — the role glob prefix-matched a LONGER role" ;;
    esac
}
for newest in backend-gpu backend; do
    term_reset "${newest}"
    ord="(${newest} newest)"
    for r in backend be; do
        got="$(basename "$( (cd "${GEN}" && ./scripts/flash-disk.sh --role "${r}" --arch x86 \
            --work-dir "${term_dir}" --list 2>/dev/null | sed -n 's/^Would flash: //p') || true)" 2>/dev/null || true)"
        term_check "flash-disk.sh --role ${r} --arch x86 ${ord}" "${got}" \
            "hugmesh-x86-amd64-backend-test-20260202T000000Z.img"
    done
    got="$(basename "$(autodetect_of launch-x86.sh backend "${term_dir}")" 2>/dev/null || true)"
    term_check "launch-x86.sh --role backend ${ord}" "${got}" \
        "hugmesh-x86-amd64-backend-test-20260202T000000Z.img"
    got="$(basename "$(term_entrypoint "${term_dir}" x86 backend)" 2>/dev/null || true)"
    term_check "docker-entrypoint.sh autodetect_img ROLE=backend ${ord}" "${got}" \
        "hugmesh-x86-amd64-backend-test-20260202T000000Z.img"
    # launch-pi.sh's LAST-RESORT unanchored role loop: no rpi5 image of any role in
    # this dir, so it is the loop that answers, and it globs `-${r}-*` too.
    got="$(basename "$(autodetect_of launch-pi.sh backend "${term_dir}")" 2>/dev/null || true)"
    term_check "launch-pi.sh --role backend, unanchored last resort ${ord}" "${got}" \
        "hugmesh-x86-amd64-backend-test-20260202T000000Z.img"
    # THE OTHER DIRECTION: the longer role must still resolve its OWN image. A fix
    # that filtered too hard would leave `--role backend-gpu` with nothing.
    got="$(basename "$( (cd "${GEN}" && ./scripts/flash-disk.sh --role backend-gpu --arch x86 \
        --work-dir "${term_dir}" --list 2>/dev/null | sed -n 's/^Would flash: //p') || true)" 2>/dev/null || true)"
    term_check "flash-disk.sh --role backend-gpu --arch x86 ${ord}" "${got}" \
        "hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.img"
    got="$(basename "$(autodetect_of launch-x86.sh backend-gpu "${term_dir}")" 2>/dev/null || true)"
    term_check "launch-x86.sh --role backend-gpu ${ord}" "${got}" \
        "hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.img"
done
rm -rf "${term_dir}"

# D7a2) EVERY role-scoped loop in each consumer, not just the first one to answer.
#       The pickers try several patterns in order, and a fixture that lets an EARLY
#       pattern answer leaves the later ones unprobed — mutation-proven: dropping the
#       filter from launch-x86.sh's LAST-RESORT unanchored loop, and from
#       docker-entrypoint.sh's autodetect_stage4, left every other check above green.
#       One fixture per loop, each shaped so that loop is the one that answers.
#
#       launch-x86.sh's last resort: an arm64-ONLY dir, so both x86-anchored loops
#       miss and the unanchored role loop is what returns. `-backend-` matches the
#       jetson GPU image, which is the newest.
lastres_dir="$(mktemp -d)"
: > "${lastres_dir}/hugmesh-rpi5-arm64-backend-test-20260201T000000Z.img"
: > "${lastres_dir}/hugmesh-jetson-orin-nano-arm64-backend-gpu-test-20260204T000000Z.img"
touch -d '2026-02-01 00:00' "${lastres_dir}"/hugmesh-rpi5-*.img
touch -d '2026-02-04 00:00' "${lastres_dir}"/hugmesh-jetson-*.img
term_check "launch-x86.sh --role backend, unanchored last resort (arm64-only dir)" \
    "$(basename "$(autodetect_of launch-x86.sh backend "${lastres_dir}")" 2>/dev/null || true)" \
    "hugmesh-rpi5-arm64-backend-test-20260201T000000Z.img"
rm -rf "${lastres_dir}"

#       launch-pi.sh's rpi5-ANCHORED loop (D7's launch-pi probe reaches the last
#       resort instead, because that fixture holds no rpi5 image at all).
pianch_dir="$(mktemp -d)"
: > "${pianch_dir}/hugmesh-rpi5-arm64-backend-test-20260201T000000Z.img"
: > "${pianch_dir}/hugmesh-rpi5-arm64-backend-gpu-test-20260204T000000Z.img"
touch -d '2026-02-01 00:00' "${pianch_dir}/hugmesh-rpi5-arm64-backend-test-20260201T000000Z.img"
touch -d '2026-02-04 00:00' "${pianch_dir}/hugmesh-rpi5-arm64-backend-gpu-test-20260204T000000Z.img"
term_check "launch-pi.sh --role backend, rpi5-anchored loop" \
    "$(basename "$(autodetect_of launch-pi.sh backend "${pianch_dir}")" 2>/dev/null || true)" \
    "hugmesh-rpi5-arm64-backend-test-20260201T000000Z.img"
rm -rf "${pianch_dir}"

#       docker-entrypoint.sh's autodetect_stage4 — a SECOND globber in the same file,
#       with the same prefix defect and the same alphabetical `for c in` expansion.
term_entry_s4() {
    bash -c "
        set -uo pipefail
        . '${LIB}'
        ARTIFACTS='$1'; PLATFORM='$2'; ROLE='$3'
        $(awk '/^autodetect_stage4\(\) \{/,/^\}/' "${GEN}/tests/qemu/docker-entrypoint.sh")
        autodetect_stage4
    " 2>/dev/null | tail -1
}
es4_dir="$(mktemp -d)"
: > "${es4_dir}/hugmesh-x86-amd64-backend-test-20260202T000000Z.stage4.tar.xz"
: > "${es4_dir}/hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.stage4.tar.xz"
touch -d '2026-02-02 00:00' "${es4_dir}/hugmesh-x86-amd64-backend-test-20260202T000000Z.stage4.tar.xz"
touch -d '2026-02-04 00:00' "${es4_dir}/hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.stage4.tar.xz"
term_check "docker-entrypoint.sh autodetect_stage4 ROLE=backend" \
    "$(basename "$(term_entry_s4 "${es4_dir}" x86 backend)" 2>/dev/null || true)" \
    "hugmesh-x86-amd64-backend-test-20260202T000000Z.stage4.tar.xz"
term_check "docker-entrypoint.sh autodetect_stage4 ROLE=backend-gpu" \
    "$(basename "$(term_entry_s4 "${es4_dir}" x86 backend-gpu)" 2>/dev/null || true)" \
    "hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.stage4.tar.xz"
rm -rf "${es4_dir}"

# D7b) THE STAGE4 CHANNEL. tests/qemu/run-qemu-test.sh picks the stage4 tarball with
#      an UNANCHORED `*-<role>-*.stage4.tar.xz` glob (no platform token at all), one
#      level up as well as in the work dir, newest-mtime-first — so a mixed session
#      dir hands a `--role backend` boot the backend-GPU rootfs.
s4_dir="$(mktemp -d)"
: > "${s4_dir}/hugmesh-rpi5-arm64-backend-test-20260201T000000Z.stage4.tar.xz"
: > "${s4_dir}/hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.stage4.tar.xz"
touch -d '2026-02-01 00:00' "${s4_dir}"/hugmesh-rpi5-*.stage4.tar.xz
touch -d '2026-02-04 00:00' "${s4_dir}"/hugmesh-x86-*.stage4.tar.xz
term_check "run-qemu-test.sh autodetect_stage4 --role backend" \
    "$(basename "$(term_stage4 "${s4_dir}" backend)" 2>/dev/null || true)" \
    "hugmesh-rpi5-arm64-backend-test-20260201T000000Z.stage4.tar.xz"
term_check "run-qemu-test.sh autodetect_stage4 --role backend-gpu" \
    "$(basename "$(term_stage4 "${s4_dir}" backend-gpu)" 2>/dev/null || true)" \
    "hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.stage4.tar.xz"
rm -rf "${s4_dir}"

# D7c) THE SHADOW SET IS DERIVED, NOT HAND-LISTED. Two ALIAS pairs collide the same
#      way (`-be-` inside `-be-gpu-`, `-full-` inside `-standalone-full-`), and a
#      future canonical role that extends an existing one would collide too. A
#      hard-coded "backend vs backend-gpu" special case passes D7 and misses all of
#      them, so the derivation itself is asserted here — against the same lib every
#      consumer sources (already sourced at the top of this guard).
for want in "backend:backend-gpu be-gpu" "be:backend-gpu be-gpu" "omnibus:standalone-full" \
            "full:standalone-full" "backend-gpu:" "host:" "pki:" "frontend:" \
            "standalone-thick:" "edge-ai:" "desktop:"; do
    r="${want%%:*}"; expect="${want#*:}"
    got="$(hugmesh_role_shadow_tokens "${r}" || true)"
    if [ "${got}" = "${expect}" ]; then
        ok "hugmesh_role_shadow_tokens ${r} = [${got}]"
    else
        bad "hugmesh_role_shadow_tokens ${r} = [${got}], expected [${expect}] — the shadow set must be DERIVED from the vocabulary, not hand-listed"
    fi
done
# The alias collision, end to end: a legacy `…-amd64-full-…` omnibus artifact beside
# a legacy `…-amd64-standalone-full-…` one. Only the derivation keeps them apart.
alias_dir="$(mktemp -d)"
: > "${alias_dir}/hugmesh-x86-amd64-full-test-20260201T000000Z.img"
: > "${alias_dir}/hugmesh-x86-amd64-standalone-full-test-20260204T000000Z.img"
touch -d '2026-02-01 00:00' "${alias_dir}/hugmesh-x86-amd64-full-test-20260201T000000Z.img"
touch -d '2026-02-04 00:00' "${alias_dir}/hugmesh-x86-amd64-standalone-full-test-20260204T000000Z.img"
term_check "flash-disk.sh --role omnibus --arch x86 (alias collision)" \
    "$(basename "$( (cd "${GEN}" && ./scripts/flash-disk.sh --role omnibus --arch x86 \
        --work-dir "${alias_dir}" --list 2>/dev/null | sed -n 's/^Would flash: //p') || true)" 2>/dev/null || true)" \
    "hugmesh-x86-amd64-full-test-20260201T000000Z.img"
rm -rf "${alias_dir}"

# D7d) A LONGER ROLE'S IMAGE IS NOT AN ANSWER AT ALL. With ONLY the GPU image in the
#      dir, the flasher must REFUSE (that is what it did before the rename, when the
#      GPU artifact was named …-host-… and `-backend-` matched nothing) rather than
#      silently offer it. The whole-disk write is the reason a fail-safe refusal is
#      the required behaviour here.
only_dir="$(mktemp -d)"
: > "${only_dir}/hugmesh-x86-amd64-backend-gpu-test-20260204T000000Z.img"
only_out="$( (cd "${GEN}" && ./scripts/flash-disk.sh --role backend --arch x86 \
    --work-dir "${only_dir}" --list 2>/dev/null) || true)"
case "${only_out}" in
    *"Would flash: (no artifact found"*) ok "flash-disk.sh --role backend --arch x86 with only a backend-gpu image: refuses" ;;
    *"Would flash: "*) bad "flash-disk.sh --role backend --arch x86 offered $(printf '%s' "${only_out}" | sed -n 's/^Would flash: //p') — a backend-gpu image is not a backend image, and this writes a whole disk" ;;
    *) bad "flash-disk.sh --list produced no verdict: ${only_out}" ;;
esac
rm -rf "${only_dir}"

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
