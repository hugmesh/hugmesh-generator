#!/usr/bin/env bash
# ============================================================================
# test-foreign-ingest-fuzz.sh — Phase 7 HOSTILE-FOREIGN-MESH ingestion FUZZ SUITE.
# ============================================================================
#
# The EXIT GATE for cross-mesh decentralization. A FOREIGN mesh's base is treated as
# FULLY HOSTILE even when validly signed. This suite feeds a corpus of malicious-but-
# well-formed foreign bases through the EXACT inbound gate
# (scripts/ingest-foreign-base.sh) AND BOTH enforcement wire-ins
# (scripts/pull-repo-base.sh --foreign, scripts/render-repo-tree.sh --foreign-mesh)
# and asserts EACH case:
#
#   (1) exit != 0 / fail-closed;
#   (2) the foreign base is NOT admitted (no verified snapshot in the quarantine,
#       no path on stdout);
#   (3) NOTHING is pushed onward (render never writes BRAND_OUT, so the publish tail
#       has no tree to sign-with-our-key / push to Forgejo).
#
# Malicious classes (task item 6):
#   unsigned; valid-sig-but-unknown-mesh; valid-sig-but-WRONG-key; tampered-after-sign
#   (flip a byte); mutable-ref-not-digest; digest-mismatch swap; provenance-digest !=
#   pinned; post-sign SUBDIR envelope-named plant; signed-in SUBDIR envelope-named
#   frozen carrier; secret smuggled in a foreign file; frozen-namespace override in
#   foreign code; SBOM absent; SBOM malformed; CRITICAL-vuln dep in SBOM; symlink-
#   escape; abs-symlink; '..' traversal; oversized / deep-nest DoS; replay (old
#   generation); pull-wiring refusals (unsigned / unknown-mesh / disabled-row /
#   mutable-ref through pull-repo-base.sh --foreign, OFFLINE).
# PLUS a LEGIT POSITIVE CONTROL: a properly-signed, clean, digest-pinned base from a
# TRUSTED mesh IS admitted AND render_repo_tree renders it (0 residual tokens),
# proving the gate is not a blanket lockout.
#
# BUILD-HOST RUNNABLE: normal user, NO root, NO network, scratch containment dir.
# SKIPs (exit 0) only if a required tool is genuinely absent.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${REPO}/scripts/ingest-foreign-base.sh"
RRT="${REPO}/scripts/render-repo-tree.sh"
ADVISORY="${REPO}/templates/mesh-trust/advisory-floor.txt"

[ -r "${GATE}" ] || { echo "FAIL gate missing: ${GATE}"; exit 1; }
for t in openssl jq base64 find realpath sha256sum du; do
  command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# Source the gate for the canonical tree-digest helper used to build fixtures (main
# is BASH_SOURCE-guarded; only functions load). Every CASE still drives the gate as a
# SUBPROCESS so rc/stdout/env-overrides are clean and the quarantine state is real.
# shellcheck source=/dev/null
. "${GATE}"

echo "== Phase 7 hostile-foreign-mesh INGEST FUZZ SUITE (build-host: no root, no network) =="

# ── Trust store: the RIGHT key for acme-mesh + a WRONG (foreign) key ────────────
MESH="acme-mesh"
TRUST="${WORK}/trust"; mkdir -p "${TRUST}/${MESH}"
PRIV="${WORK}/priv.pem";   openssl genpkey -algorithm ed25519 -out "${PRIV}"  2>/dev/null || { echo "SKIP: no ed25519"; exit 0; }
WPRIV="${WORK}/wrong.pem"; openssl genpkey -algorithm ed25519 -out "${WPRIV}" 2>/dev/null
openssl pkey -in "${PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${TRUST}/${MESH}/foreign-provenance-pub.ed25519"

# ── Fixture builders ────────────────────────────────────────────────────────────
# A CLEAN foreign angular-mfe base carrying the archetype recipe's required upstream
# anchors (so the positive control also renders). Not secrets; not our frozen
# protocol constants (Snapdragon-Systems/ and @snapdragon/ are NOT snapdragon.systems/).
mkclean_base() { # mkclean_base DIR
  local d="$1"
  mkdir -p "${d}/src"
  printf '{\n  "name": "@snapdragon/login",\n  "version": "1.0.0"\n}\n' > "${d}/package.json"
  printf '<html><head><title>Snapdragon Login (remote)</title></head><body></body></html>\n' > "${d}/src/index.html"
  printf 'include:\n  - project: Snapdragon-Systems/snapdragon-generator\n    file: ci.yml\n' > "${d}/.gitlab-ci.yml"
  printf 'export const remoteEntry = "login";\n' > "${d}/federation-base.js"
  cat > "${d}/.snapdragon-sbom.json" <<'JSON'
{ "bomFormat":"CycloneDX","specVersion":"1.5",
  "metadata":{"component":{"name":"snapdragon-login-ui","version":"1.0.0"}},
  "components":[{"name":"handlebars","version":"4.7.8"},{"name":"left-pad","version":"1.3.0"}] }
JSON
}

# Sign a base: (re)compute the canonical tree digest, write the manifest carrying the
# pin/mesh/tree/generation, sign it with $priv. sign_base DIR PRIV MESH PIN GEN
sign_base() {
  local d="$1" priv="$2" mesh="$3" pin="$4" gen="$5"
  rm -f "${d}/.snapdragon-provenance.json" "${d}/.snapdragon-provenance.json.sig"
  local tree; tree="$(_fib_tree_digest "$d")"
  cat > "${d}/.snapdragon-provenance.json" <<JSON
{ "schema":"snapdragon.systems/provenance/v1",
  "base":{"repo":"snapdragon-login-ui","commitSha":"${pin}","meshId":"${mesh}","treeSha256":"${tree}","generation":${gen},"mode":"overlay"},
  "template":{"archetype":"angular-mfe"},
  "tenant":{"brand":"acme","org":"Acme-Inc","clusterDomain":"acme.test"} }
JSON
  openssl pkeyutl -sign -inkey "$priv" -rawin \
    -in "${d}/.snapdragon-provenance.json" -out "${d}/.snapdragon-provenance.json.sig" 2>/dev/null
}

# A 64-hex immutable "digest" for a fixture (deterministic from a label).
digest_of() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

# ── run_gate + assertions ───────────────────────────────────────────────────────
GATE_RC=0; GATE_OUT=""; GATE_Q=""
run_gate() { # run_gate CASEID BASE MESH PIN [extra gate args...]
  local cid="$1" base="$2" mesh="$3" pin="$4"; shift 4
  local q="${WORK}/q/${cid}"; mkdir -p "$q"
  GATE_Q="$q"
  GATE_OUT="$(FIB_ADVISORY_FLOOR_DEFAULT="${ADVISORY}" bash "${GATE}" \
      --base "$base" --mesh-id "$mesh" --pinned-digest "$pin" \
      --trust-store "$TRUST" --quarantine "$q" --advisory-floor "$ADVISORY" "$@" 2>>"${WORK}/gate.err")"
  GATE_RC=$?
}
# assert_reject: rc!=0, empty stdout, and NO admitted snapshot dir in the quarantine.
assert_reject() { # assert_reject CASE
  local admit
  admit="$(find "${GATE_Q}" -maxdepth 1 -mindepth 1 -type d ! -name .building ! -name .src 2>/dev/null | head -n1)"
  if [ "${GATE_RC}" -ne 0 ] && [ -z "${GATE_OUT}" ] && [ -z "${admit}" ]; then
    ok "$1: fail-closed + NOT admitted (rc=${GATE_RC}, no path, no snapshot)"
  else
    bad "$1: NOT fail-closed (rc=${GATE_RC}, out='${GATE_OUT}', admit='${admit}')"
  fi
}

# ── (1) UNSIGNED ────────────────────────────────────────────────────────────────
B="${WORK}/unsigned"; mkclean_base "$B"; PIN="$(digest_of unsigned)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
rm -f "${B}/.snapdragon-provenance.json.sig"
run_gate unsigned "$B" "$MESH" "$PIN"; assert_reject "(unsigned)"

# ── (2) VALID SIG BUT UNKNOWN MESH (no trust entry) ──────────────────────────────
B="${WORK}/unknownmesh"; mkclean_base "$B"; PIN="$(digest_of unknownmesh)"; sign_base "$B" "$PRIV" "nobody-mesh" "$PIN" 5
run_gate unknownmesh "$B" "nobody-mesh" "$PIN"; assert_reject "(unknown-mesh / no-TOFU)"

# ── (3) VALID SIG BUT WRONG KEY (signed by a foreign key, mesh is known) ─────────
B="${WORK}/wrongkey"; mkclean_base "$B"; PIN="$(digest_of wrongkey)"; sign_base "$B" "$WPRIV" "$MESH" "$PIN" 5
run_gate wrongkey "$B" "$MESH" "$PIN"; assert_reject "(wrong-key signature)"

# ── (4) TAMPERED-AFTER-SIGN (flip a byte in a code file post-sign) ───────────────
B="${WORK}/tampered"; mkclean_base "$B"; PIN="$(digest_of tampered)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
printf '// backdoor\n' >> "${B}/federation-base.js"
run_gate tampered "$B" "$MESH" "$PIN"; assert_reject "(tampered-after-sign: tree-digest mismatch)"

# ── (4b) DIGEST-SWAP: tamper tree AND update manifest.treeSha256 to match -> sig breaks ─
B="${WORK}/digestswap"; mkclean_base "$B"; PIN="$(digest_of digestswap)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
printf '// backdoor\n' >> "${B}/federation-base.js"
NEWTREE="$(_fib_tree_digest "$B")"
jq --arg t "$NEWTREE" '.base.treeSha256=$t' "${B}/.snapdragon-provenance.json" > "${B}/.m" && mv "${B}/.m" "${B}/.snapdragon-provenance.json"
run_gate digestswap "$B" "$MESH" "$PIN"; assert_reject "(digest-swap: manifest updated, signature no longer verifies)"

# ── (4c) POST-SIGN SUBDIR ENVELOPE-NAMED PLANT — a file merely NAMED like the
#         attestation manifest, planted in a SUBDIR after signing. The tree digest
#         is ROOT-anchored, so this file is ordinary content: adding it post-sign
#         MUST break the digest binding (regression test for the fail-open where
#         -name excluded it from the digest everywhere in the tree). ─────────────
B="${WORK}/subenv"; mkclean_base "$B"; PIN="$(digest_of subenv)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
printf '{"schema":"snapdragon.systems/provenance/v1","note":"planted post-sign"}\n' > "${B}/src/.snapdragon-provenance.json"
run_gate subenv "$B" "$MESH" "$PIN"; assert_reject "(post-sign SUBDIR envelope-named plant: digest-covered)"

# ── (4d) SIGNED-IN SUBDIR ENVELOPE-NAMED FROZEN CARRIER — present at signing (so
#         the digest matches!) but carrying OUR frozen protocol constant under an
#         envelope-shaped name. The frozen screen excludes ONLY the root-level
#         envelope, so this MUST still reject (laundering-vector regression). ────
B="${WORK}/subenvfrozen"; mkclean_base "$B"
printf 'labels: { snapdragon.systems/domain: attacker }\n' > "${B}/src/.snapdragon-provenance.json"
PIN="$(digest_of subenvfrozen)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate subenvfrozen "$B" "$MESH" "$PIN"; assert_reject "(signed-in SUBDIR envelope-named frozen-constant carrier)"

# ── (5) MUTABLE REF instead of an immutable digest ──────────────────────────────
B="${WORK}/mutable"; mkclean_base "$B"; sign_base "$B" "$PRIV" "$MESH" "$(digest_of mutable)" 5
run_gate mutable "$B" "$MESH" "main"; assert_reject "(mutable-ref pin 'main' refused)"

# ── (6) DIGEST-MISMATCH: pinned digest != manifest.base.commitSha ────────────────
B="${WORK}/mismatch"; mkclean_base "$B"; sign_base "$B" "$PRIV" "$MESH" "$(digest_of realpin)" 5
run_gate mismatch "$B" "$MESH" "$(digest_of DIFFERENTPIN)"; assert_reject "(pinned-digest != provenance-digest)"

# ── (7) SECRET smuggled in a foreign file ────────────────────────────────────────
B="${WORK}/secret"; mkclean_base "$B"
printf 'CASDOOR_ADMIN_CLIENT_SECRET=s3cr3t-Kx9fQp2Lm7Vb8Nz4Wt6Rd1Yh0Jc5Ug\n' > "${B}/src/leak.env"
PIN="$(digest_of secret)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate secret "$B" "$MESH" "$PIN"; assert_reject "(smuggled secret in src/**)"

# ── (7b) KEYLESS high-entropy bearer smuggled in src ─────────────────────────────
B="${WORK}/bearer"; mkclean_base "$B"
printf 'authorization: Bearer BqYq2wYQ0Km7v8Nx3Rd1Yh0Jc5UgKx9fQp2Lm7Vb8Nz4Wt6Rd1Yh0Jc5Ug\n' > "${B}/src/auth.txt"
PIN="$(digest_of bearer)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate bearer "$B" "$MESH" "$PIN"; assert_reject "(keyless high-entropy credential in src/**)"

# ── (8) FROZEN-NAMESPACE OVERRIDE in foreign code ────────────────────────────────
B="${WORK}/frozen"; mkclean_base "$B"
printf 'metadata:\n  labels:\n    snapdragon.systems/domain: attacker\n' > "${B}/src/hijack.yaml"
PIN="$(digest_of frozen)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate frozen "$B" "$MESH" "$PIN"; assert_reject "(frozen snapdragon.systems/* override in foreign code)"

# ── (8b) FROZEN WIRE HEADER injected in foreign code ─────────────────────────────
B="${WORK}/header"; mkclean_base "$B"
printf 'const h = { "X-Snapdragon-Local": "1" };\n' > "${B}/src/wire.ts"
PIN="$(digest_of header)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate header "$B" "$MESH" "$PIN"; assert_reject "(frozen X-Snapdragon-Local wire header in foreign code)"

# ── (8c) NUL-BYTE-CLOAKED FROZEN CONSTANT (mustFix: frozen screen must FORCE-TEXT) ─
#         A frozen constant hidden in a file that also carries a NUL byte. The old
#         'grep -I' treated any NUL-bearing file as binary and SKIPPED it, so this
#         impersonation/laundering carrier was ADMITTED (rc=0). The screen now scans
#         with -a (force-text): the frozen 'snapdragon.systems/' label-key MUST reject.
B="${WORK}/nulfrozen"; mkclean_base "$B"
printf 'cfg\x00 label: snapdragon.systems/domain: attacker\n' > "${B}/src/hijack.conf"
PIN="$(digest_of nulfrozen)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate nulfrozen "$B" "$MESH" "$PIN"; assert_reject "(NUL-cloaked frozen snapdragon.systems/ constant — force-text screen)"

# ── (8d) NUL-BYTE-CLOAKED FROZEN WIRE HEADER ─────────────────────────────────────
B="${WORK}/nulheader"; mkclean_base "$B"
printf 'blob\x00\x00X-Device-Terminal-StepUp: 1\n' > "${B}/src/wire.bin"
PIN="$(digest_of nulheader)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate nulheader "$B" "$MESH" "$PIN"; assert_reject "(NUL-cloaked frozen wire header X-Device-Terminal-StepUp)"

# ── (9) SBOM ABSENT ──────────────────────────────────────────────────────────────
B="${WORK}/nosbom"; mkclean_base "$B"; rm -f "${B}/.snapdragon-sbom.json"
PIN="$(digest_of nosbom)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate nosbom "$B" "$MESH" "$PIN"; assert_reject "(SBOM absent)"

# ── (9b) SBOM MALFORMED (not JSON) ───────────────────────────────────────────────
B="${WORK}/badsbom"; mkclean_base "$B"; printf 'not json {{{\n' > "${B}/.snapdragon-sbom.json"
PIN="$(digest_of badsbom)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate badsbom "$B" "$MESH" "$PIN"; assert_reject "(SBOM malformed)"

# ── (9c) SBOM EMPTY (zero components) ─────────────────────────────────────────────
B="${WORK}/emptysbom"; mkclean_base "$B"; printf '{"bomFormat":"CycloneDX","components":[]}\n' > "${B}/.snapdragon-sbom.json"
PIN="$(digest_of emptysbom)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate emptysbom "$B" "$MESH" "$PIN"; assert_reject "(SBOM has zero components)"

# ── (10) CRITICAL VULN dep in SBOM (matches the pinned advisory floor) ───────────
B="${WORK}/vuln"; mkclean_base "$B"
cat > "${B}/.snapdragon-sbom.json" <<'JSON'
{ "bomFormat":"CycloneDX","components":[{"name":"handlebars","version":"4.7.8"},{"name":"log4j-core","version":"2.14.1"}] }
JSON
PIN="$(digest_of vuln)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate vuln "$B" "$MESH" "$PIN"; assert_reject "(CRITICAL vuln dep log4j-core@2.14.1 in SBOM)"

# ── (10b) VENDORED-JAR OMITTED FROM SBOM (mustFix: SBOM-omission tree corroboration) ─
#          The tree VENDORS a CRITICAL jar but the self-attested SBOM lists only a
#          benign component. Gate [d] used to trust the SBOM alone and ADMIT; it now
#          corroborates against the ACTUAL tree (jar filename) and MUST reject.
B="${WORK}/vulnjar"; mkclean_base "$B"; mkdir -p "${B}/libs"
printf 'PK\x03\x04 fake jar bytes\n' > "${B}/libs/log4j-core-2.14.1.jar"
cat > "${B}/.snapdragon-sbom.json" <<'JSON'
{ "bomFormat":"CycloneDX","components":[{"name":"handlebars","version":"4.7.8"}] }
JSON
PIN="$(digest_of vulnjar)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate vulnjar "$B" "$MESH" "$PIN"; assert_reject "(vendored log4j-core-2.14.1.jar omitted from SBOM — tree corroboration)"

# ── (10c) VENDORED-WHEEL OMITTED FROM SBOM (PEP-503 name canonicalisation) ────────
#          A wheel filename normalises '-'->'_' (log4j_core); the tree scan emits the
#          canonical hyphenated name so it still matches the hyphenated floor.
B="${WORK}/vulnwhl"; mkclean_base "$B"; mkdir -p "${B}/wheels"
: > "${B}/wheels/log4j_core-2.14.1-py3-none-any.whl"
PIN="$(digest_of vulnwhl)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate vulnwhl "$B" "$MESH" "$PIN"; assert_reject "(vendored wheel log4j_core-2.14.1 omitted from SBOM — canonicalised tree match)"

# ── (10d) NPM package-lock.json CARRIES A CRITICAL DEP OMITTED FROM SBOM ──────────
B="${WORK}/vulnlock"; mkclean_base "$B"
printf '{"lockfileVersion":3,"packages":{"node_modules/lodash":{"version":"4.17.20"}}}\n' > "${B}/package-lock.json"
PIN="$(digest_of vulnlock)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate vulnlock "$B" "$MESH" "$PIN"; assert_reject "(package-lock.json lodash@4.17.20 omitted from SBOM — lockfile corroboration)"

# ── (10e) GROUP/PURL NAME-SHIFTED MISDECLARATION (honest version, shifted name) ───
#          SBOM lists the vulnerable version under a group-prefixed name so the raw
#          'name@version' never matches the floor; the normaliser strips the prefix.
B="${WORK}/vulnname"; mkclean_base "$B"
printf '{"bomFormat":"CycloneDX","components":[{"name":"org.apache.logging.log4j:log4j-core","version":"2.14.1"}]}\n' > "${B}/.snapdragon-sbom.json"
PIN="$(digest_of vulnname)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate vulnname "$B" "$MESH" "$PIN"; assert_reject "(group-prefixed log4j-core@2.14.1 misdeclaration — name normalisation)"

# ── (10f) NEGATIVE CONTROL — a BENIGN vendored jar (not on the floor) still ADMITS ─
#          Proves the tree-vuln scan is a floor match, NOT a blanket ban on vendored
#          artifacts (no false positive that would break legitimate foreign bases).
B="${WORK}/benignjar"; mkclean_base "$B"; mkdir -p "${B}/libs"
printf 'PK\x03\x04 fake\n' > "${B}/libs/left-pad-1.3.0.jar"
PIN="$(digest_of benignjar)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 6
run_gate benignjar "$B" "$MESH" "$PIN" --min-generation 5
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.snapdragon-mesh-admitted" ]; then
  ok "(benign vendored jar left-pad-1.3.0.jar not on floor -> ADMITTED, no false positive)"
else
  bad "(benign vendored jar wrongly REJECTED (rc=${GATE_RC}) — tree-vuln scan over-blocks)"
fi

# ── (11) SYMLINK ESCAPE (relative symlink out of the tree) ───────────────────────
B="${WORK}/symesc"; mkclean_base "$B"; ln -s '../../../../etc/passwd' "${B}/src/escape"
PIN="$(digest_of symesc)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate symesc "$B" "$MESH" "$PIN"; assert_reject "(symlink escaping the tree root)"

# ── (11b) ABSOLUTE-target symlink ────────────────────────────────────────────────
B="${WORK}/symabs"; mkclean_base "$B"; ln -s '/etc/shadow' "${B}/src/abs"
PIN="$(digest_of symabs)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate symabs "$B" "$MESH" "$PIN"; assert_reject "(absolute-target symlink)"

# ── (11c) '..' traversal symlink ─────────────────────────────────────────────────
B="${WORK}/travsym"; mkclean_base "$B"; mkdir -p "${B}/a/b"; ln -s '../../..' "${B}/a/b/up"
PIN="$(digest_of travsym)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate travsym "$B" "$MESH" "$PIN"; assert_reject "('..' traversal symlink)"

# ── (12) DoS — file-count / total-bytes / deep-nest (caps overridden small) ──────
B="${WORK}/dosfiles"; mkclean_base "$B"; mkdir -p "${B}/many"
i=0; while [ $i -lt 60 ]; do : > "${B}/many/f${i}"; i=$((i+1)); done
PIN="$(digest_of dosfiles)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
GATE_Q="${WORK}/q/dosfiles"; mkdir -p "$GATE_Q"
GATE_OUT="$(FIB_MAX_FILES=50 bash "${GATE}" --base "$B" --mesh-id "$MESH" --pinned-digest "$PIN" \
    --trust-store "$TRUST" --quarantine "$GATE_Q" --advisory-floor "$ADVISORY" 2>>"${WORK}/gate.err")"; GATE_RC=$?
assert_reject "(DoS: file-count cap)"

B="${WORK}/dosbytes"; mkclean_base "$B"; head -c 4096 /dev/zero | tr '\0' 'A' > "${B}/big.txt"
PIN="$(digest_of dosbytes)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
GATE_Q="${WORK}/q/dosbytes"; mkdir -p "$GATE_Q"
GATE_OUT="$(FIB_MAX_BYTES=1024 bash "${GATE}" --base "$B" --mesh-id "$MESH" --pinned-digest "$PIN" \
    --trust-store "$TRUST" --quarantine "$GATE_Q" --advisory-floor "$ADVISORY" 2>>"${WORK}/gate.err")"; GATE_RC=$?
assert_reject "(DoS: total-bytes cap)"

B="${WORK}/dosdepth"; mkclean_base "$B"; mkdir -p "${B}/a/b/c/d/e/f/g/h"; : > "${B}/a/b/c/d/e/f/g/h/deep.txt"
PIN="$(digest_of dosdepth)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
GATE_Q="${WORK}/q/dosdepth"; mkdir -p "$GATE_Q"
GATE_OUT="$(FIB_MAX_DEPTH=4 bash "${GATE}" --base "$B" --mesh-id "$MESH" --pinned-digest "$PIN" \
    --trust-store "$TRUST" --quarantine "$GATE_Q" --advisory-floor "$ADVISORY" 2>>"${WORK}/gate.err")"; GATE_RC=$?
assert_reject "(DoS: deep-nest cap)"

# ── (13) REPLAY — genuinely signed OLD generation below the floor ────────────────
B="${WORK}/replay"; mkclean_base "$B"; PIN="$(digest_of replay)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 3
run_gate replay "$B" "$MESH" "$PIN" --min-generation 9; assert_reject "(replay: gen 3 < min-generation 9)"

echo
echo "-- pull-repo-base.sh --foreign wiring: the gate is REQUIRED before a base path is returned --"
# Drives the REAL scripts/pull-repo-base.sh --foreign path (registry row -> raw
# source via *_BASE_DIR override, OFFLINE=1 so no network) and asserts: a hostile
# base returns rc!=0 + NOTHING on stdout + no admitted snapshot; an unknown /
# disabled mesh fails closed at the registry; a clean base returns the ADMITTED
# quarantine snapshot (never the raw tree).
PRB="${REPO}/scripts/pull-repo-base.sh"
REG="${WORK}/registry.json"
jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:true, gitBase:"https://forge.acme.test/acme", minGeneration:0}}}' > "$REG"
REGOFF="${WORK}/registry-disabled.json"
jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:false, gitBase:"https://forge.acme.test/acme", minGeneration:0}}}' > "$REGOFF"
run_prb() { # run_prb CASEID REGISTRY BASE MESH PIN
  local cid="$1" reg="$2" base="$3" mesh="$4" pin="$5"
  GATE_Q="${WORK}/prb/${cid}/.mesh-quarantine/login-ui"
  GATE_OUT="$(REPO_BASE_CACHE="${WORK}/prb/${cid}" MESH_REGISTRY="$reg" \
      MESH_TRUST_STORE="$TRUST" LOGIN_UI_BASE_DIR="$base" OFFLINE=1 \
      FIB_ADVISORY_FLOOR_DEFAULT="$ADVISORY" \
      bash "$PRB" --foreign --mesh "$mesh" --pinned-digest "$pin" login-ui 2>>"${WORK}/gate.err")"
  GATE_RC=$?
}
# (P1) hostile: unsigned foreign base behind the pull wiring -> refused, nothing returned.
B="${WORK}/prb_unsigned"; mkclean_base "$B"; PIN="$(digest_of prb_unsigned)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
rm -f "${B}/.snapdragon-provenance.json.sig"
run_prb p1 "$REG" "$B" "$MESH" "$PIN"; assert_reject "(pull-wiring: unsigned foreign base refused)"
# (P2) unknown mesh: no registry row -> fail-closed BEFORE any fetch/gate.
B="${WORK}/prb_unknown"; mkclean_base "$B"; PIN="$(digest_of prb_unknown)"; sign_base "$B" "$PRIV" "nobody-mesh" "$PIN" 5
run_prb p2 "$REG" "$B" "nobody-mesh" "$PIN"; assert_reject "(pull-wiring: mesh with no registry row refused)"
# (P3) disabled mesh row -> refused even with a valid signature.
B="${WORK}/prb_disabled"; mkclean_base "$B"; PIN="$(digest_of prb_disabled)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_prb p3 "$REGOFF" "$B" "$MESH" "$PIN"; assert_reject "(pull-wiring: disabled registry row refused)"
# (P4) mutable ref refused at the pull layer (before any fetch would happen).
B="${WORK}/prb_mutable"; mkclean_base "$B"; sign_base "$B" "$PRIV" "$MESH" "$(digest_of prb_mutable)" 5
run_prb p4 "$REG" "$B" "$MESH" "main"; assert_reject "(pull-wiring: mutable-ref pin refused)"
# (P5) POSITIVE: clean signed base -> rc=0 and the ADMITTED snapshot (not the raw dir).
B="${WORK}/prb_legit"; mkclean_base "$B"; PIN="$(digest_of prb_legit)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_prb p5 "$REG" "$B" "$MESH" "$PIN"
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.snapdragon-mesh-admitted" ] \
   && [ "$(cd "${GATE_OUT}" && pwd)" != "$(cd "$B" && pwd)" ]; then
  ok "(pull-wiring) clean base returned as the ADMITTED snapshot (never the raw tree)"
else
  bad "(pull-wiring) clean base not admitted correctly (rc=${GATE_RC}, out='${GATE_OUT}')"
fi

echo
echo "-- render enforcement: a REJECTED foreign base never writes BRAND_OUT (nothing to push) --"
# Drive the REAL render wire-in for representative malicious cases and assert
# render-repo-tree.sh _die's BEFORE the tar-copy — BRAND_OUT is never created, so the
# publish tail (which pushes whatever render emits) has nothing to sign/push onward.
BRANDCONF="${WORK}/brand.conf"
cat > "${BRANDCONF}" <<'C'
BRAND=acme
BRAND_TITLE="Acme Portal"
ORG=Acme-Inc
CLUSTER_DOMAIN=acme.test
C
HAVE_RENDER=0
if command -v node >/dev/null 2>&1 && [ -d "${REPO}/scripts/tooling/node_modules/handlebars" ]; then HAVE_RENDER=1; fi
assert_no_render() { # assert_no_render CASE BASE MESH PIN [mingen]
  local case="$1" base="$2" mesh="$3" pin="$4" mg="${5:-0}"
  local out="${WORK}/rout/${case}"; rm -rf "$out"
  if bash "${RRT}" "${BRANDCONF}" --enable-repo-tree --repo login-ui --archetype angular-mfe \
        --out-dir "$out" --base "$base" --foreign-mesh "$mesh" --pinned-digest "$pin" \
        --trust-store "$TRUST" --min-generation "$mg" \
        --set APP_SLUG=login --set TITLE_WORD=Login >/dev/null 2>&1; then
    bad "${case}: render EMITTED from a rejected foreign base (LEAK)"
  elif [ -e "${out}/acme-login-ui" ]; then
    bad "${case}: BRAND_OUT written despite reject"
  else
    ok "${case}: render fail-closed, BRAND_OUT never written (nothing reaches publish)"
  fi
}
if [ "${HAVE_RENDER}" -eq 1 ]; then
  # unsigned
  B="${WORK}/r_unsigned"; mkclean_base "$B"; PIN="$(digest_of r_unsigned)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5; rm -f "${B}/.snapdragon-provenance.json.sig"
  assert_no_render "render-unsigned" "$B" "$MESH" "$PIN"
  # tampered
  B="${WORK}/r_tampered"; mkclean_base "$B"; PIN="$(digest_of r_tampered)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5; printf 'x\n' >> "${B}/federation-base.js"
  assert_no_render "render-tampered" "$B" "$MESH" "$PIN"
  # secret
  B="${WORK}/r_secret"; mkclean_base "$B"; printf 'ROOT_PASS: "s3cr3t-Kx9fQp2Lm7Vb8Nz4Wt6Rd1Yh0"\n' > "${B}/src/leak.yaml"; PIN="$(digest_of r_secret)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
  assert_no_render "render-secret" "$B" "$MESH" "$PIN"
else
  echo "  SKIP render-enforcement cases (node/handlebars unavailable — run: (cd scripts/tooling && npm install))"
fi

echo
echo "-- POSITIVE CONTROL: a clean, signed, digest-pinned base from a TRUSTED mesh IS admitted + renders --"
B="${WORK}/legit"; mkclean_base "$B"; PIN="$(digest_of legit)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 7
run_gate legit "$B" "$MESH" "$PIN" --min-generation 5
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -d "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.snapdragon-mesh-admitted" ]; then
  ok "(legit) gate ADMITTED a clean signed digest-pinned base (rc=0, snapshot promoted)"
else
  bad "(legit) gate REJECTED a clean base (rc=${GATE_RC}, out='${GATE_OUT}') — FALSE POSITIVE / blanket lockout"
fi
if [ "${HAVE_RENDER}" -eq 1 ]; then
  OUT="${WORK}/rout/legit"; rm -rf "$OUT"
  if bash "${RRT}" "${BRANDCONF}" --enable-repo-tree --repo login-ui --archetype angular-mfe \
        --out-dir "$OUT" --base "$B" --foreign-mesh "$MESH" --pinned-digest "$PIN" \
        --trust-store "$TRUST" --min-generation 5 \
        --set APP_SLUG=login --set TITLE_WORD=Login >"${WORK}/legit-render.log" 2>&1; then
    BO="${OUT}/acme-login-ui"
    if [ -d "$BO" ] && [ -n "$(ls -A "$BO" 2>/dev/null)" ]; then
      ok "(legit) render_repo_tree emitted a tree ($(find "$BO" -type f | wc -l | tr -d ' ') files) from the admitted foreign base"
    else bad "(legit) render produced no tree"; fi
    if grep -rqE '\{\{[A-Z_]+\}\}' "$BO" 2>/dev/null; then bad "(legit) residual {{TOKEN}} remains"; else ok "(legit) 0 residual {{TOKEN}}s in the rendered tree"; fi
    if grep -rq '{{BRAND_TITLE}}' "$BO" 2>/dev/null; then bad "(legit) BRAND_TITLE unsubstituted"; fi
    if grep -rq 'Acme Portal Login (remote)' "$BO" 2>/dev/null; then ok "(legit) brand token substituted (title rebranded)"; else bad "(legit) brand rebrand not applied"; fi
    # gate markers + foreign attestation envelope must NOT ride into the emitted tree.
    if [ -e "${BO}/.snapdragon-mesh-admitted" ] || [ -e "${BO}/.foreign-mesh-id" ] || [ -e "${BO}/.snapdragon-provenance.json" ] || [ -e "${BO}/.snapdragon-sbom.json" ]; then
      bad "(legit) gate/foreign-attestation markers leaked into the emitted tree"
    else ok "(legit) gate markers + foreign attestation stripped from the emitted tree"; fi
  else
    bad "(legit) render_repo_tree FAILED on the admitted clean base — FALSE POSITIVE"; sed 's/^/      /' "${WORK}/legit-render.log" | tail -8
  fi
else
  echo "  SKIP (legit) render (node/handlebars unavailable) — gate-admit half asserted above"
fi

echo
echo "== FOREIGN-INGEST FUZZ SUITE: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
