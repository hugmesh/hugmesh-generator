#!/usr/bin/env bash
# test-layer-a-bff-fixture-identity.sh — the CROSS-REPO leg of the Layer-A parity
# contract, gated on every pull request (shell-suites.yml, layer-a job).
#
# WHAT IT PINS. Layer-A has two writers of one headscale policy: the node-side
# renderer (specs/usr/sbin/gen-headscale-policy.sh, live on every control node) and
# hugmesh-admin-bff-api's HeadscaleAclCompiler (dark; decision 101 = B makes it the
# ONLY writer at the hugmesh-generator#634 cut-over). Both are held to ONE document,
# tests/device-registry/fixtures/layer-a-parity-{params.env,export.json,policy.golden.json}:
#   * here, the real renderer must reproduce the golden (check 3 below);
#   * there, HeadscaleAclParityTest must make the compiler reproduce ITS copy;
#   * and the two copies must be the SAME BYTES (check 2), or the two writers are
#     being held to different documents and their agreement is unproven.
#
# WHY A SEPARATE SUITE. test-layer-a-headscale-acl.sh carries the same byte check (its
# 2b) but cannot gate a pull request yet: two of its checks pin the BFF's declared
# policy mode to this fleet's `file` and are red against the BFF's `database` by design
# until the #634 cut-over (#634 item 4). That suite therefore ran in no pull-request
# job, and with it the only comparison of the two goldens. After #896 emptied the
# owner lists of the security tags here, the BFF's copy (and its compiler) kept
# `"hugmesh"` as the owner of tag:superadmin and of every tag:dev_<fp> — the shape
# #888/#896 removed because every pre-auth key is minted for that user — and nothing
# reported it. This suite is that comparison, without the policy-mode pair.
#
# NO SKIP, NO INCOMPLETE. The sibling checkout is REQUIRED. Absent, this suite FAILS
# (exit 1) with a ::error:: line; it never exits 0 or 3 without comparing. CI supplies
# the checkout at a pinned commit. Locally, point LAYERA_BFF_ROOT at a checkout of
# hugmesh-admin-bff-api (or LAYERA_SIBLING_ROOT at a directory that holds one).
# LAYERA_BFF_EXPECT_REF, when set, must equal the checkout's HEAD.
#
# Offline: bash + jq + openssl + awk + cmp (+ git for the HEAD print). No JVM: the
# BFF side of the contract is its own HeadscaleAclParityTest.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="${REPO}/tests/device-registry/$(basename "${BASH_SOURCE[0]}")"
RENDERER="${REPO}/specs/usr/sbin/gen-headscale-policy.sh"
TMPL="${REPO}/specs/etc/headscale/policy.hujson.tmpl"
FIXDIR="${REPO}/tests/device-registry/fixtures"
FIXTURES="layer-a-parity-params.env layer-a-parity-export.json layer-a-parity-policy.golden.json"

SIBLING_ROOT="${LAYERA_SIBLING_ROOT:-${REPO}/.layera-siblings}"
BFF_ROOT="${LAYERA_BFF_ROOT:-${SIBLING_ROOT}/hugmesh-admin-bff-api}"
BFF_FIX="${BFF_ROOT}/src/test/resources/layer-a"
BFF_PARITY_TEST="${BFF_ROOT}/src/test/java/net/hugmesh/adminbff/device/HeadscaleAclParityTest.java"
BFF_COMPILER="${BFF_ROOT}/src/main/java/net/hugmesh/adminbff/device/HeadscaleAclCompiler.java"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
strip() { sed -e 's#//.*$##' "$1"; }   # hujson line comments -> strict JSON
# Executable Java lines only: javadoc/block-comment continuations and // lines dropped.
java_code() { grep -v -E '^[[:space:]]*(/?\*|//)' "$1"; }

for t in jq openssl awk cmp diff; do
    command -v "$t" >/dev/null 2>&1 || { echo "::error::${t} is required and absent — this guard checked NOTHING"; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# fixture_identity <generator-fixture-dir> <bff-fixture-dir>: one line per fixture,
# "SAME <name>", "DIFFERS <name>" or "MISSING <name>". Shared with the negative control.
fixture_identity() {
    local gdir="$1" bdir="$2" f
    for f in ${FIXTURES}; do
        if [ ! -r "${bdir}/${f}" ] || [ ! -r "${gdir}/${f}" ]; then echo "MISSING ${f}"
        elif cmp -s "${gdir}/${f}" "${bdir}/${f}"; then echo "SAME ${f}"
        else echo "DIFFERS ${f}"; fi
    done
}

# owner_problems <golden.json>: prints one line per security tag that is not declared
# with the EMPTY owner list, and per membership tag that lost its owner. Empty output
# = clean. Security tags: tag:superadmin, tag:mesh_*, tag:dev_*, tag:dom_* — every one
# the force-tagger assigns. A key-minting user as their owner lets a node self-assign them.
owner_problems() {
    jq -r '
        def sec: test("^tag:(superadmin$|mesh_|dev_|dom_)");
        (.tagOwners // {}) as $o
        | ( $o | to_entries[] | select(.key | sec) | select(.value != [])
            | "security tag \(.key) has owner(s) \(.value | tojson)" ),
          ( [ .ssh[]? | (.src[]?, .dst[]?) ] | unique[] | select(. != "tag:hugmesh")
            | select($o[.] == null) | "ssh names \(.) but tagOwners does not declare it" ),
          ( ["tag:hugmesh","tag:pki","tag:be","tag:fe","tag:host"][]
            | select($o[.] != ["hugmesh"]) | "membership tag \(.) is not owned by exactly [\"hugmesh\"]" )
    ' "$1" 2>/dev/null || echo "unparseable: $1"
}

echo "== Layer-A cross-repo fixture identity (hugmesh-generator <-> hugmesh-admin-bff-api) =="

# ── 1. The sibling checkout is required.
if [ ! -r "${BFF_COMPILER}" ] || [ ! -r "${BFF_PARITY_TEST}" ] || [ ! -d "${BFF_FIX}" ]; then
    bad "the hugmesh-admin-bff-api checkout is absent or incomplete at ${BFF_ROOT}"
    echo "::error::test-layer-a-bff-fixture-identity: no hugmesh-admin-bff-api checkout at ${BFF_ROOT} (looked for HeadscaleAclCompiler.java, HeadscaleAclParityTest.java and src/test/resources/layer-a/). Nothing was compared, so this is a FAILURE, not a skip. Set LAYERA_BFF_ROOT, or LAYERA_SIBLING_ROOT to a directory holding hugmesh-admin-bff-api."
    echo "== RESULT: ${P} passed, ${F} failed =="
    exit 1
fi
BFF_HEAD="$(git -C "${BFF_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
ok "sibling hugmesh-admin-bff-api checkout present (${BFF_ROOT}, HEAD ${BFF_HEAD})"
if [ -n "${LAYERA_BFF_EXPECT_REF:-}" ]; then
    if [ "${BFF_HEAD}" = "${LAYERA_BFF_EXPECT_REF}" ]; then
        ok "sibling HEAD is the pinned commit ${LAYERA_BFF_EXPECT_REF}"
    else
        bad "sibling HEAD ${BFF_HEAD} != pinned LAYERA_BFF_EXPECT_REF ${LAYERA_BFF_EXPECT_REF} — the job is comparing against a commit nobody pinned"
    fi
fi

# ── 2. The two copies of the shared parity fixtures are the same bytes.
echo "-- fixture byte identity --"
while read -r verdict name; do
    case "${verdict}" in
        SAME)    ok "parity fixture ${name} is byte-identical in both repos" ;;
        MISSING) bad "parity fixture ${name} is missing from one repo (${FIXDIR} or ${BFF_FIX})" ;;
        *)       bad "parity fixture ${name} DIFFERS between hugmesh-generator and hugmesh-admin-bff-api — the two writers are held to DIFFERENT documents; copy this repo's file there byte for byte (and make the compiler reproduce it)"
                 diff -u "${FIXDIR}/${name}" "${BFF_FIX}/${name}" 2>/dev/null | head -30 | sed 's/^/      /' ;;
    esac
done < <(fixture_identity "${FIXDIR}" "${BFF_FIX}")

# The BFF's half must still exist and still read the shared files, in CODE, not prose.
for name in ${FIXTURES}; do
    if java_code "${BFF_PARITY_TEST}" | grep -F "\"${name}\"" >/dev/null; then
        ok "BFF HeadscaleAclParityTest loads ${name}"
    else
        bad "BFF HeadscaleAclParityTest no longer loads ${name} — its half of the contract is not asserting the shared document"
    fi
done
if java_code "${BFF_PARITY_TEST}" | grep -F 'new HeadscaleAclCompiler(' >/dev/null \
   && java_code "${BFF_PARITY_TEST}" | grep -F '.isEqualTo(golden)' >/dev/null; then
    ok "BFF HeadscaleAclParityTest compiles the shared export and compares it to the golden"
else
    bad "BFF HeadscaleAclParityTest no longer compiles the export and asserts equality with the golden"
fi

# ── 3. The golden is what the LIVE writer emits. Without this, two identical copies
# could agree on a document neither writer produces.
echo "-- the golden is the live renderer's output --"
# NODE_ENV, POLICY_TMPL, TS_SSH_USER and MESH_TAG are the globals render_policy reads
# (normally set by the renderer's _init from node.env).
# shellcheck disable=SC2034
NODE_ENV=/dev/null
# shellcheck source=/dev/null
. "${RENDERER}"
# shellcheck disable=SC2034
POLICY_TMPL="${TMPL}"
# shellcheck source=/dev/null
. "${FIXDIR}/layer-a-parity-params.env"
# shellcheck disable=SC2034
MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"
if render_policy "${FIXDIR}/layer-a-parity-export.json" "${WORK}/rendered.hujson"; then
    if diff -u "${FIXDIR}/layer-a-parity-policy.golden.json" <(strip "${WORK}/rendered.hujson" | jq -S .) >/dev/null 2>&1; then
        ok "gen-headscale-policy.sh renders the parity export to exactly the golden"
    else
        bad "gen-headscale-policy.sh no longer renders the golden — regenerate it (jq -S) in BOTH repos and re-review"
        diff -u "${FIXDIR}/layer-a-parity-policy.golden.json" <(strip "${WORK}/rendered.hujson" | jq -S .) | head -30 | sed 's/^/      /'
    fi
else
    bad "render_policy failed on the parity export"
fi

# ── 4. Neither copy gives a security tag an owner (stated directly, so a red run
# names the tag instead of only saying "differs").
echo "-- security tags are ownerless in both copies --"
for g in "${FIXDIR}/layer-a-parity-policy.golden.json" "${BFF_FIX}/layer-a-parity-policy.golden.json"; do
    probs="$(owner_problems "${g}")"
    if [ -z "${probs}" ]; then
        ok "every security tag is declared with the EMPTY owner list and the membership tags keep theirs: ${g#"${REPO}/"}"
    else
        bad "tag owners wrong in ${g}:"
        printf '%s\n' "${probs}" | sed 's/^/      /'
    fi
done

# ── 5. Negative controls: each check above must be able to fail.
if [ -z "${LAYERA_NC_CHILD:-}" ]; then
    echo "-- negative controls --"
    # NC1: one byte changed in a copy of the BFF golden -> check 2 reports DIFFERS.
    mkdir -p "${WORK}/nc1"; cp "${BFF_FIX}"/layer-a-parity-* "${WORK}/nc1/"
    sed -i 's/"tag:pki"/"tag:pkj"/' "${WORK}/nc1/layer-a-parity-policy.golden.json"
    if cmp -s "${WORK}/nc1/layer-a-parity-policy.golden.json" "${BFF_FIX}/layer-a-parity-policy.golden.json"; then
        bad "NC1 did not change the planted copy — the control is vacuous"
    elif fixture_identity "${FIXDIR}" "${WORK}/nc1" | grep -Fx 'DIFFERS layer-a-parity-policy.golden.json' >/dev/null; then
        ok "NC1: a one-byte change to the BFF's golden is reported as DIFFERS"
    else
        bad "NC1: a one-byte change to the BFF's golden went unreported"
    fi
    # NC2: the pre-#896 shape — the membership user owns tag:superadmin and a dev tag.
    jq '.tagOwners["tag:superadmin"] = ["hugmesh"]
        | .tagOwners |= with_entries(if (.key | startswith("tag:dev_")) then .value = ["hugmesh"] else . end)' \
        "${FIXDIR}/layer-a-parity-policy.golden.json" > "${WORK}/nc2.json"
    nc2="$(owner_problems "${WORK}/nc2.json")"
    if printf '%s\n' "${nc2}" | grep -F 'security tag tag:superadmin has owner' >/dev/null \
       && printf '%s\n' "${nc2}" | grep -F 'security tag tag:dev_' >/dev/null; then
        ok "NC2: owners restored on tag:superadmin and tag:dev_* are both reported"
    else
        bad "NC2: owned security tags went unreported (got: ${nc2:-nothing})"
    fi
    # NC3: the mesh tag the SUPERADMIN rule names, undeclared.
    jq 'del(.tagOwners[(.ssh[0].dst[0])])' "${FIXDIR}/layer-a-parity-policy.golden.json" > "${WORK}/nc3.json"
    if owner_problems "${WORK}/nc3.json" | grep -F 'ssh names tag:mesh_' >/dev/null; then
        ok "NC3: an undeclared tag:mesh_<id> is reported"
    else
        bad "NC3: an undeclared tag:mesh_<id> went unreported"
    fi
    # NC4: tag:hugmesh emptied (an over-correction that breaks membership) is reported.
    jq '.tagOwners["tag:hugmesh"] = []' "${FIXDIR}/layer-a-parity-policy.golden.json" > "${WORK}/nc4.json"
    if owner_problems "${WORK}/nc4.json" | grep -F 'membership tag tag:hugmesh' >/dev/null; then
        ok "NC4: a membership tag that lost its owner is reported"
    else
        bad "NC4: a membership tag that lost its owner went unreported"
    fi
    # NC5: no sibling -> this suite exits 1 with ::error::, never 0 and never 3.
    mkdir -p "${WORK}/empty"
    nc5_out="$(LAYERA_NC_CHILD=1 LAYERA_BFF_ROOT="${WORK}/empty" bash "${SELF}" </dev/null 2>&1)"; nc5_rc=$?
    if [ "${nc5_rc}" -eq 1 ] && printf '%s\n' "${nc5_out}" | grep -F '::error::' >/dev/null; then
        ok "NC5: an absent sibling checkout exits 1 with ::error:: (not a skip, not exit 3)"
    else
        bad "NC5: an absent sibling checkout exited ${nc5_rc} (want 1 with ::error::)"
    fi
    # NC6: a pin that does not match the checkout fails.
    if [ "${BFF_HEAD}" != unknown ]; then
        LAYERA_NC_CHILD=1 LAYERA_BFF_ROOT="${BFF_ROOT}" LAYERA_BFF_EXPECT_REF=0000000000000000000000000000000000000000 \
            bash "${SELF}" </dev/null >"${WORK}/nc6.out" 2>&1; nc6_rc=$?
        if [ "${nc6_rc}" -ne 0 ] && grep -F '!= pinned LAYERA_BFF_EXPECT_REF' "${WORK}/nc6.out" >/dev/null; then
            ok "NC6: a sibling HEAD that is not the pinned commit fails"
        else
            bad "NC6: a mismatched pin was accepted (rc=${nc6_rc})"
        fi
    fi
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
