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
# FAILS (exit 1) if a required tool is genuinely absent.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${REPO}/scripts/ingest-foreign-base.sh"
RRT="${REPO}/scripts/render-repo-tree.sh"
ADVISORY="${REPO}/templates/mesh-trust/advisory-floor.txt"

[ -r "${GATE}" ] || { echo "FAIL gate missing: ${GATE}"; exit 1; }
# Tool preflight is FAIL-CLOSED (tests/lib/guard-preflight.sh): a missing tool
# makes this guard exit 1, never 0. The old `SKIP … exit 0` shape turned an
# under-provisioned CI image into a green check. Deliberate local opt-out:
# GUARD_TOOLING_ALLOW_SKIP=1 — a name .gitlab-ci.yml is forbidden to contain.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-preflight.sh"
guard_require_tools openssl jq base64 find realpath sha256sum du

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

# ── STATIC (a): every FIB_* the gate READS is ASSIGNED, or self-defaults ───────
# WHY THIS EXISTS, and why the behavioural cases below were not enough. 835b3137
# ("Update ingest-foreign-base.sh", direct push to main, no PR) deleted the three
# FIB_*_LEGACY_COMPAT definitions and left all six consumers in place. The gate runs
# under `set -uo pipefail`, so the FIRST read killed the _fib_tree_digest subshell and
# every base — clean ones included — came back "REJECT: tree digest computation
# failed". A blanket fail-closed lockout of the entire foreign-ingest path, and the
# cases below could only report it as six opaque "a clean base was wrongly REJECTED"
# lines that read like an over-strict gate, not a missing variable.
#
# This says the variable's NAME instead. It also reaches references on paths no case
# below executes (the `-e` envelope probe near the end of the file was one of the six
# and nothing here drives it), and it costs no node, no network and no fixture, so it
# runs identically in every CI lane.
#
# A name is SAFE if it is assigned at line start, OR if every one of its references
# carries a `:-` default (the overridable seams FIB_PROVENANCE, FIB_TOKENS_JSON,
# FIB_MESH_REGISTRY … are read that way on purpose). Anything else is a `set -u`
# abort waiting for the right input. Extraction is `grep -oE` + POSIX awk: no grep -P,
# no `\b`, and nothing piped into `grep -q` — busybox reads this the same as GNU.
_fib_bare_unassigned() { # _fib_bare_unassigned SRC -> names, one per line
  local src
  src="$1"
  local names
  names="$(grep -oE '\$\{?FIB_[A-Z0-9_]+(:-)?' "$src" | awk '
      { s = $0
        sub(/^\$\{?/, "", s)
        d = 0
        if (s ~ /:-$/) { d = 1; sub(/:-$/, "", s) }
        seen[s] = 1
        if (d == 0) bare[s] = 1 }
      END { for (n in seen) if (n in bare) print n }' | sort)"
  local n
  for n in $names; do
    # Direct grep on a FILE — not a pipeline — so pipefail/SIGPIPE cannot turn a
    # real hit into a false "unassigned".
    if [ "$(grep -cE "^[[:space:]]*${n}=" "$src")" = "0" ]; then printf '%s\n' "$n"; fi
  done
}
FIB_UNBOUND="$(_fib_bare_unassigned "$GATE")"
if [ -z "$FIB_UNBOUND" ]; then
  ok "(static a) every FIB_* read without a :- default is assigned in ${GATE##*/} — no set -u abort can blank the gate"
else
  bad "(static a) FIB_* read bare but NEVER assigned in ${GATE##*/}: $(printf '%s' "$FIB_UNBOUND" | tr '\n' ' ')— under set -u the first read aborts the gate and EVERY base, clean ones included, is REJECTED"
fi

# ── STATIC (b): the header's named legacy envelope IS the constant [b] reads ────
# ae322866 — the sibling of the same direct-to-main push, 6 minutes earlier — rewrote
# gate [b]'s header line to say the pre-rebrand envelope is ".acme-provenance.json".
# No such name exists anywhere in the tree: "acme" is THIS SUITE's fixture mesh, and
# the real constant is ".snapdragon-provenance.json". Prose is what the next person
# reads before deciding the dual-read can finally be retired, and a wrong filename
# there points the decision at a file no mesh has ever shipped. Pin the sentence to
# the constant so the two cannot drift apart again in silence.
FIB_LEG_CONST="$(awk -F'"' '/^FIB_MANIFEST_LEGACY_COMPAT=/ { print $2; exit }' "$GATE")"
if [ -z "$FIB_LEG_CONST" ]; then
  bad "(static b) FIB_MANIFEST_LEGACY_COMPAT is not assigned at all in ${GATE##*/} — the dual-read has no envelope name"
elif [ "$(grep -cF "pre-rebrand ${FIB_LEG_CONST}(.sig)" "$GATE")" != "0" ]; then
  ok "(static b) gate [b]'s header names the real legacy envelope (${FIB_LEG_CONST}) — prose and constant agree"
else
  bad "(static b) gate [b]'s header does NOT name ${FIB_LEG_CONST} — the documented pre-rebrand envelope has drifted off the constant the dual-read actually reads"
fi

# ── Trust store: the RIGHT key for acme-mesh + a WRONG (foreign) key ────────────
MESH="acme-mesh"
TRUST="${WORK}/trust"; mkdir -p "${TRUST}/${MESH}"
PRIV="${WORK}/priv.pem";   openssl genpkey -algorithm ed25519 -out "${PRIV}"  2>/dev/null || guard_require_capability "openssl cannot mint ed25519 keys"
WPRIV="${WORK}/wrong.pem"; openssl genpkey -algorithm ed25519 -out "${WPRIV}" 2>/dev/null
openssl pkey -in "${PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${TRUST}/${MESH}/foreign-provenance-pub.ed25519"

# ── Gate-side per-mesh registry (R2/R4): acme-mesh ENABLED so the positive controls
#    admit; dedicated disabled/revoked/revoked-key registries drive the R2/R4
#    refusals below. Every run_gate/run RRT consume now re-consults a registry — the
#    gate + render are consume paths too, not only pull.
REG_GATE="${WORK}/registry-gate.json"
jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:true, gitBase:"https://forge.acme.test/acme", minGeneration:0}}}' > "$REG_GATE"
# The pinned key's fingerprint (raw SPKI DER -> sha256) for the R4 revoked-keys case.
KEYFP="$(base64 -d "${TRUST}/${MESH}/foreign-provenance-pub.ed25519" 2>/dev/null | sha256sum | awk '{print $1}')"

# ── Fixture builders ────────────────────────────────────────────────────────────
# A CLEAN foreign angular-mfe base carrying the archetype recipe's required upstream
# anchors (so the positive control also renders). Not secrets; not our frozen
# protocol constants (hugmesh/ and @hugmesh/ are NOT hugmesh.net/).
#
# THE <title> HAS NO " (remote)" SUFFIX, ON PURPOSE. This fixture's whole job is to
# be a base the angular-mfe recipe can anchor into, so it must track
# templates/archetypes/angular-mfe/recipe.yaml#tab-title, which reads
# `<title>HugMesh {{TITLE_WORD}}</title>`. The suffix was dropped from the anchor in
# d0a4c637 because the real base dropped it first — hugmesh-login-ui/src/index.html
# now says `<title>HugMesh Login</title>`, and its own comment explains why (this
# <title> is what users see on the platform, so a build-topology parenthetical does
# not belong in it). This fixture kept the old spelling and therefore modelled a base
# upstream no longer produces: `required: true` made render-repo-tree FATAL on the
# positive control and on both launder/cache-purge legs. Do not re-add the suffix
# here without changing the anchor in the same commit.
mkclean_base() { # mkclean_base DIR
  local d="$1"
  mkdir -p "${d}/src"
  printf '{\n  "name": "@hugmesh/login",\n  "version": "1.0.0"\n}\n' > "${d}/package.json"
  printf '<html><head><title>HugMesh Login</title></head><body></body></html>\n' > "${d}/src/index.html"
  printf 'include:\n  - project: hugmesh/hugmesh-generator\n    file: ci.yml\n' > "${d}/.gitlab-ci.yml"
  printf 'export const remoteEntry = "login";\n' > "${d}/federation-base.js"
  cat > "${d}/.hugmesh-sbom.json" <<'JSON'
{ "bomFormat":"CycloneDX","specVersion":"1.5",
  "metadata":{"component":{"name":"hugmesh-login-ui","version":"1.0.0"}},
  "components":[{"name":"handlebars","version":"4.7.8"},{"name":"left-pad","version":"1.3.0"}] }
JSON
}

# Sign a base: (re)compute the canonical tree digest, write the manifest carrying the
# pin/mesh/tree/generation, sign it with $priv. sign_base DIR PRIV MESH PIN GEN
sign_base() {
  local d="$1" priv="$2" mesh="$3" pin="$4" gen="$5"
  rm -f "${d}/.hugmesh-provenance.json" "${d}/.hugmesh-provenance.json.sig"
  local tree; tree="$(_fib_tree_digest "$d")"
  cat > "${d}/.hugmesh-provenance.json" <<JSON
{ "schema":"hugmesh.net/provenance/v1",
  "base":{"repo":"hugmesh-login-ui","commitSha":"${pin}","meshId":"${mesh}","treeSha256":"${tree}","generation":${gen},"mode":"overlay"},
  "template":{"archetype":"angular-mfe"},
  "tenant":{"brand":"acme","org":"Acme-Inc","clusterDomain":"acme.test"} }
JSON
  openssl pkeyutl -sign -inkey "$priv" -rawin \
    -in "${d}/.hugmesh-provenance.json" -out "${d}/.hugmesh-provenance.json.sig" 2>/dev/null
}

# LEGACY_COMPAT signer: same envelope, PRE-REBRAND filenames. Exercises the
# dual-READ in scripts/provenance.sh + scripts/ingest-foreign-base.sh — a mesh that
# cut its base before the HugMesh rebrand ships `.snapdragon-provenance.json(.sig)`
# and its detached signature covers exactly those bytes, so the gate must still
# admit it. sign_base_legacy DIR PRIV MESH PIN GEN
sign_base_legacy() {
  local d="$1" priv="$2" mesh="$3" pin="$4" gen="$5"
  rm -f "${d}/.hugmesh-provenance.json" "${d}/.hugmesh-provenance.json.sig" \
        "${d}/.snapdragon-provenance.json" "${d}/.snapdragon-provenance.json.sig"
  local tree; tree="$(_fib_tree_digest "$d")"
  cat > "${d}/.snapdragon-provenance.json" <<JSON
{ "schema":"hugmesh.net/provenance/v1",
  "base":{"repo":"hugmesh-login-ui","commitSha":"${pin}","meshId":"${mesh}","treeSha256":"${tree}","generation":${gen},"mode":"overlay"},
  "template":{"archetype":"angular-mfe"},
  "tenant":{"brand":"acme","org":"Acme-Inc","clusterDomain":"acme.test"} }
JSON
  openssl pkeyutl -sign -inkey "$priv" -rawin \
    -in "${d}/.snapdragon-provenance.json" -out "${d}/.snapdragon-provenance.json.sig" 2>/dev/null
}

# A 64-hex immutable "digest" for a fixture (deterministic from a label).
digest_of() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

# content_only_digest DIR — the PRE-R5 tree digest (regular-file CONTENT only, no
# symlink target, no mode). Used by the R5 cases to prove OLD-vs-NEW: a mode-flip /
# symlink-repoint leaves this OLD digest UNCHANGED (so the pre-fix gate would have
# ADMITTED), while the current gate — which binds mode + symlink target — REJECTS.
content_only_digest() {
  ( cd "$1" || exit 1
    find . -type f \
        ! -path './.git/*' \
        ! -path './.hugmesh-provenance.json' \
        ! -path './.hugmesh-provenance.json.sig' \
        ! -path './.hugmesh-mesh-admitted' \
        ! -path './.foreign-mesh-id' \
        -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' f; do
          printf '%s  %s\n' "$(sha256sum "$f" 2>/dev/null | awk '{print $1}')" "$f"
        done \
      | sha256sum | awk '{print $1}' )
}

# ── run_gate + assertions ───────────────────────────────────────────────────────
GATE_RC=0; GATE_OUT=""; GATE_Q=""
run_gate() { # run_gate CASEID BASE MESH PIN [extra gate args...]
  local cid="$1" base="$2" mesh="$3" pin="$4"; shift 4
  local q="${WORK}/q/${cid}"; mkdir -p "$q"
  GATE_Q="$q"
  # Default --registry is REG_GATE (acme-mesh enabled); a case may pass its OWN
  # --registry in "$@" (later flag wins) to drive the R2/R4 disabled/revoked paths.
  GATE_OUT="$(FIB_ADVISORY_FLOOR_DEFAULT="${ADVISORY}" bash "${GATE}" \
      --base "$base" --mesh-id "$mesh" --pinned-digest "$pin" \
      --trust-store "$TRUST" --quarantine "$q" --advisory-floor "$ADVISORY" \
      --registry "$REG_GATE" "$@" 2>>"${WORK}/gate.err")"
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
rm -f "${B}/.hugmesh-provenance.json.sig"
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
jq --arg t "$NEWTREE" '.base.treeSha256=$t' "${B}/.hugmesh-provenance.json" > "${B}/.m" && mv "${B}/.m" "${B}/.hugmesh-provenance.json"
run_gate digestswap "$B" "$MESH" "$PIN"; assert_reject "(digest-swap: manifest updated, signature no longer verifies)"

# ── (4c) POST-SIGN SUBDIR ENVELOPE-NAMED PLANT — a file merely NAMED like the
#         attestation manifest, planted in a SUBDIR after signing. The tree digest
#         is ROOT-anchored, so this file is ordinary content: adding it post-sign
#         MUST break the digest binding (regression test for the fail-open where
#         -name excluded it from the digest everywhere in the tree). ─────────────
B="${WORK}/subenv"; mkclean_base "$B"; PIN="$(digest_of subenv)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
printf '{"schema":"hugmesh.net/provenance/v1","note":"planted post-sign"}\n' > "${B}/src/.hugmesh-provenance.json"
run_gate subenv "$B" "$MESH" "$PIN"; assert_reject "(post-sign SUBDIR envelope-named plant: digest-covered)"

# ── (4d) SIGNED-IN SUBDIR ENVELOPE-NAMED FROZEN CARRIER — present at signing (so
#         the digest matches!) but carrying OUR frozen protocol constant under an
#         envelope-shaped name. The frozen screen excludes ONLY the root-level
#         envelope, so this MUST still reject (laundering-vector regression). ────
B="${WORK}/subenvfrozen"; mkclean_base "$B"
printf 'labels: { hugmesh.net/domain: attacker }\n' > "${B}/src/.hugmesh-provenance.json"
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
printf 'metadata:\n  labels:\n    hugmesh.net/domain: attacker\n' > "${B}/src/hijack.yaml"
PIN="$(digest_of frozen)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate frozen "$B" "$MESH" "$PIN"; assert_reject "(frozen hugmesh.net/* override in foreign code)"

# ── (8b) FROZEN WIRE HEADER injected in foreign code ─────────────────────────────
B="${WORK}/header"; mkclean_base "$B"
printf 'const h = { "X-HugMesh-Local": "1" };\n' > "${B}/src/wire.ts"
PIN="$(digest_of header)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate header "$B" "$MESH" "$PIN"; assert_reject "(frozen X-HugMesh-Local wire header in foreign code)"

# ── (8c) NUL-BYTE-CLOAKED FROZEN CONSTANT (mustFix: frozen screen must FORCE-TEXT) ─
#         A frozen constant hidden in a file that also carries a NUL byte. The old
#         'grep -I' treated any NUL-bearing file as binary and SKIPPED it, so this
#         impersonation/laundering carrier was ADMITTED (rc=0). The screen now scans
#         with -a (force-text): the frozen 'hugmesh.net/' label-key MUST reject.
B="${WORK}/nulfrozen"; mkclean_base "$B"
printf 'cfg\x00 label: hugmesh.net/domain: attacker\n' > "${B}/src/hijack.conf"
PIN="$(digest_of nulfrozen)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate nulfrozen "$B" "$MESH" "$PIN"; assert_reject "(NUL-cloaked frozen hugmesh.net/ constant — force-text screen)"

# ── (8d) NUL-BYTE-CLOAKED FROZEN WIRE HEADER ─────────────────────────────────────
B="${WORK}/nulheader"; mkclean_base "$B"
printf 'blob\x00\x00X-Device-Terminal-StepUp: 1\n' > "${B}/src/wire.bin"
PIN="$(digest_of nulheader)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate nulheader "$B" "$MESH" "$PIN"; assert_reject "(NUL-cloaked frozen wire header X-Device-Terminal-StepUp)"

# ── (8e) DATA-DRIVEN SCREENS MUST NOT GO INERT (fail-closed on a dead term source) ─
#         (f.1)/(f.2) are DATA-DRIVEN, so they carried the same fail-open-by-shape
#         defect a38208e6 hit in the classifier one file over: gut the block (or move
#         the file) and `jq ... // []` yields NOTHING, the old `if [ -n "$frozen_terms" ]`
#         skipped the whole loop, and control fell through to ADMIT — screening zero
#         terms, exit 0, no diagnostic. Likewise an unreadable token-classifier.js was
#         treated as the node-OPTIONAL case and silently skipped.
#         EACH CASE ISOLATES ONE GATE — a case a second gate would also reject proves
#         nothing about the first (measured: an earlier draft of these cases stayed
#         green under BOTH fail-open mutations, because whichever gate was left intact
#         rejected the base anyway).
#           e1/e2 keep the REAL classifier readable, so (f.1) passes on the clean origin
#                 fields and only (f.2) can refuse — they drive the term source.
#           e3    uses a CLEAN base that (f.2) has no reason to touch, so only (f.1) can
#                 refuse — it drives the classifier preflight.
B="${WORK}/inertfrozen"; mkclean_base "$B"
printf 'metadata:\n  labels:\n    hugmesh.net/domain: attacker\n' > "${B}/src/hijack.yaml"
PIN="$(digest_of inertfrozen)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
# POSITIVE CONTROL: with the shipped tokens.json this base rejects, so a reject below
# is the guard biting and not a base that was never admissible.
run_gate inertctl "$B" "$MESH" "$PIN"; assert_reject "(8e control) impersonating base rejected with an INTACT tokens.json"
# e1: frozen_protocol_constants deleted -> zero terms. Fail-open ADMITS this
#     impersonating tree; the guard must refuse it.
jq 'del(.frozen_protocol_constants)' "${REPO}/scripts/tooling/tokens.json" > "${WORK}/tokens.gutted.json"
FIB_TOKENS_JSON="${WORK}/tokens.gutted.json" run_gate inertgut "$B" "$MESH" "$PIN"
assert_reject "(8e) gutted tokens.json (frozen_protocol_constants deleted) — screen must not go inert"
# e2: the spec file moved away entirely -> jq errors into /dev/null -> zero terms.
FIB_TOKENS_JSON="${WORK}/no-such-tokens.json" run_gate inertmissing "$B" "$MESH" "$PIN"
assert_reject "(8e) absent tokens.json — screen must not go inert"
# e3: an unreadable token-classifier is a BROKEN INSTALL, not the node-optional case.
#     Clean base: (f.2) screens it and finds nothing, so only (f.1) can refuse, and a
#     clean base is otherwise ADMITTED (see the (legit) control).
B="${WORK}/inertnotc"; mkclean_base "$B"; PIN="$(digest_of inertnotc)"
sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
FIB_TOKEN_CLASSIFIER="${WORK}/no-such-classifier.js" run_gate inertnotc "$B" "$MESH" "$PIN"
assert_reject "(8e) unreadable token-classifier.js — fail-closed, not silently skipped"

# ── (9) SBOM ABSENT ──────────────────────────────────────────────────────────────
B="${WORK}/nosbom"; mkclean_base "$B"; rm -f "${B}/.hugmesh-sbom.json"
PIN="$(digest_of nosbom)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate nosbom "$B" "$MESH" "$PIN"; assert_reject "(SBOM absent)"

# ── (9b) SBOM MALFORMED (not JSON) ───────────────────────────────────────────────
B="${WORK}/badsbom"; mkclean_base "$B"; printf 'not json {{{\n' > "${B}/.hugmesh-sbom.json"
PIN="$(digest_of badsbom)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate badsbom "$B" "$MESH" "$PIN"; assert_reject "(SBOM malformed)"

# ── (9c) SBOM EMPTY (zero components) ─────────────────────────────────────────────
B="${WORK}/emptysbom"; mkclean_base "$B"; printf '{"bomFormat":"CycloneDX","components":[]}\n' > "${B}/.hugmesh-sbom.json"
PIN="$(digest_of emptysbom)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate emptysbom "$B" "$MESH" "$PIN"; assert_reject "(SBOM has zero components)"

# ── (10) CRITICAL VULN dep in SBOM (matches the pinned advisory floor) ───────────
B="${WORK}/vuln"; mkclean_base "$B"
cat > "${B}/.hugmesh-sbom.json" <<'JSON'
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
cat > "${B}/.hugmesh-sbom.json" <<'JSON'
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
printf '{"bomFormat":"CycloneDX","components":[{"name":"org.apache.logging.log4j:log4j-core","version":"2.14.1"}]}\n' > "${B}/.hugmesh-sbom.json"
PIN="$(digest_of vulnname)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate vulnname "$B" "$MESH" "$PIN"; assert_reject "(group-prefixed log4j-core@2.14.1 misdeclaration — name normalisation)"

# ── (10f) NEGATIVE CONTROL — a BENIGN vendored jar (not on the floor) still ADMITS ─
#          Proves the tree-vuln scan is a floor match, NOT a blanket ban on vendored
#          artifacts (no false positive that would break legitimate foreign bases).
B="${WORK}/benignjar"; mkclean_base "$B"; mkdir -p "${B}/libs"
printf 'PK\x03\x04 fake\n' > "${B}/libs/left-pad-1.3.0.jar"
PIN="$(digest_of benignjar)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 6
run_gate benignjar "$B" "$MESH" "$PIN" --min-generation 5
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.hugmesh-mesh-admitted" ]; then
  ok "(benign vendored jar left-pad-1.3.0.jar not on floor -> ADMITTED, no false positive)"
else
  bad "(benign vendored jar wrongly REJECTED (rc=${GATE_RC}) — tree-vuln scan over-blocks)"
fi

# ── (10g) LEGACY_COMPAT ENVELOPE — a PRE-REBRAND foreign base still ADMITS ───────
#          The rebrand renamed the attestation envelope to `.hugmesh-provenance.json`
#          (+ .sig), but signed bases cut before it are already on other meshes'
#          disks and their signature covers those exact bytes. provenance.sh verify
#          and ingest-foreign-base.sh therefore dual-READ, new spelling first. Without
#          this case the fallback could be deleted and every gate here would stay
#          green while every pre-rebrand mesh silently became "unsigned/unattested".
B="${WORK}/legacyenv"; mkclean_base "$B"
PIN="$(digest_of legacyenv)"; sign_base_legacy "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate legacyenv "$B" "$MESH" "$PIN"
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.hugmesh-mesh-admitted" ]; then
  ok "(LEGACY_COMPAT pre-rebrand provenance envelope -> ADMITTED, stamped with the new name)"
else
  bad "(LEGACY_COMPAT pre-rebrand envelope wrongly REJECTED (rc=${GATE_RC}) — the dual-read fallback is gone)"
fi

# ── (10h) …and a MIXED envelope must NOT half-verify: the new manifest beside only
#          the LEGACY .sig is a mismatched pair, not a valid base.
B="${WORK}/mixedenv"; mkclean_base "$B"
PIN="$(digest_of mixedenv)"; sign_base_legacy "$B" "$PRIV" "$MESH" "$PIN" 5
mv "${B}/.snapdragon-provenance.json" "${B}/.hugmesh-provenance.json"
run_gate mixedenv "$B" "$MESH" "$PIN"; assert_reject "(new manifest + legacy-only .sig — mismatched envelope)"

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
  # R3: the override path now REQUIRES an operator content anchor — supply the base's
  # canonical tree digest so a LEGIT override still admits and a hostile one is bound
  # to its ACTUAL bytes (a dedicated R3 case below proves the missing-anchor refusal).
  local anchor; anchor="$(_fib_tree_digest "$base" 2>/dev/null)"
  GATE_OUT="$(REPO_BASE_CACHE="${WORK}/prb/${cid}" MESH_REGISTRY="$reg" \
      MESH_TRUST_STORE="$TRUST" LOGIN_UI_BASE_DIR="$base" OFFLINE=1 \
      FOREIGN_PINNED_TREE_SHA256="$anchor" \
      FIB_ADVISORY_FLOOR_DEFAULT="$ADVISORY" \
      bash "$PRB" --foreign --mesh "$mesh" --pinned-digest "$pin" login-ui 2>>"${WORK}/gate.err")"
  GATE_RC=$?
}
# (P1) hostile: unsigned foreign base behind the pull wiring -> refused, nothing returned.
B="${WORK}/prb_unsigned"; mkclean_base "$B"; PIN="$(digest_of prb_unsigned)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
rm -f "${B}/.hugmesh-provenance.json.sig"
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
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.hugmesh-mesh-admitted" ] \
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
assert_no_render() { # assert_no_render CASE BASE MESH PIN [mingen] [registry]
  local case="$1" base="$2" mesh="$3" pin="$4" mg="${5:-0}" reg="${6:-$REG_GATE}"
  local out="${WORK}/rout/${case}"; rm -rf "$out"
  # Pass a VALID operator anchor (R3) + registry (R2) so render reaches the GATE and
  # fails closed for the case's INTENDED reason, not merely a missing-anchor refusal.
  local anchor; anchor="$(_fib_tree_digest "$base" 2>/dev/null)"
  if MESH_REGISTRY="$reg" bash "${RRT}" "${BRANDCONF}" --enable-repo-tree --repo login-ui --archetype angular-mfe \
        --out-dir "$out" --base "$base" --foreign-mesh "$mesh" --pinned-digest "$pin" \
        --pinned-tree-sha256 "$anchor" --registry "$reg" \
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
  B="${WORK}/r_unsigned"; mkclean_base "$B"; PIN="$(digest_of r_unsigned)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5; rm -f "${B}/.hugmesh-provenance.json.sig"
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
echo "== RESIDUAL-MEDIUM HARDENINGS (R2-R6): each fails closed, admits nothing, pushes nothing =="

# ── R2: ENABLED/REVOKED enforced on the GATE + RENDER consume paths (not only pull) ─
REG_DIS="${WORK}/registry-disabled-gate.json"
jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:false, gitBase:"https://forge.acme.test/acme"}}}' > "$REG_DIS"
REG_REV="${WORK}/registry-revoked-gate.json"
jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:true, revoked:true, gitBase:"https://forge.acme.test/acme"}}}' > "$REG_REV"
# (R2a) gate refuses a DISABLED mesh even for an otherwise-valid signed base.
B="${WORK}/r2disabled"; mkclean_base "$B"; PIN="$(digest_of r2disabled)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate r2disabled "$B" "$MESH" "$PIN" --registry "$REG_DIS"
assert_reject "(R2 gate: disabled mesh refused at ingest — a base cached while enabled cannot be re-consumed after disable)"
# (R2b) gate refuses a REVOKED mesh row even for a valid signed base.
B="${WORK}/r2revoked"; mkclean_base "$B"; PIN="$(digest_of r2revoked)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate r2revoked "$B" "$MESH" "$PIN" --registry "$REG_REV"
assert_reject "(R2/R4 gate: revoked:true mesh refused at ingest)"
# (R2c) RENDER refuses a disabled mesh -> BRAND_OUT never written (nothing to push).
if [ "${HAVE_RENDER}" -eq 1 ]; then
  B="${WORK}/r2render"; mkclean_base "$B"; PIN="$(digest_of r2render)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
  assert_no_render "R2-render-disabled" "$B" "$MESH" "$PIN" 0 "$REG_DIS"
else
  echo "  SKIP (R2c) render-disabled (node/handlebars unavailable)"
fi

# ── R3: *_BASE_DIR OVERRIDE must bind the pin to the ACTUAL bytes (content anchor) ─
# (R3a) OLD-vs-NEW: a hostile-but-signed override mutates its bytes AND re-signs so
# the signature verifies and recomputed==manifest.treeSha256 (the signer controls
# both). Without the operator anchor the signature-only chain ADMITS (the hole);
# WITH the operator's original digest the gate REJECTS (bound to the real bytes).
B="${WORK}/r3anchor"; mkclean_base "$B"; PIN="$(digest_of r3anchor)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
ORIG_ANCHOR="$(_fib_tree_digest "$B")"
printf '// backdoor\n' >> "${B}/federation-base.js"     # signer swaps in a backdoor…
sign_base "$B" "$PRIV" "$MESH" "$PIN" 5                  # …and RE-SIGNS the mutated tree
run_gate r3anchor_old "$B" "$MESH" "$PIN"                # (old) no operator anchor
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.hugmesh-mesh-admitted" ]; then
  ok "(R3 old-vs-new) WITHOUT the operator anchor the re-signed mutated override ADMITS — the exact hole R3 closes"
else
  bad "(R3 old-vs-new) expected admit without anchor (rc=${GATE_RC}) — case not exercising the hole"
fi
run_gate r3anchor "$B" "$MESH" "$PIN" --require-content-anchor --expect-tree-sha256 "$ORIG_ANCHOR"
assert_reject "(R3 gate: override content drift caught by the operator anchor — recomputed != pinned tree digest)"
# (R3b) pull-wiring: an override with NO operator content anchor fails closed BEFORE
# the gate (won't fall back to trusting the signer's self-declared treeSha256).
B="${WORK}/r3noanchor"; mkclean_base "$B"; PIN="$(digest_of r3noanchor)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
GATE_Q="${WORK}/prb/r3noanchor/.mesh-quarantine/login-ui"
GATE_OUT="$(REPO_BASE_CACHE="${WORK}/prb/r3noanchor" MESH_REGISTRY="$REG" MESH_TRUST_STORE="$TRUST" \
    LOGIN_UI_BASE_DIR="$B" OFFLINE=1 FIB_ADVISORY_FLOOR_DEFAULT="$ADVISORY" \
    bash "$PRB" --foreign --mesh "$MESH" --pinned-digest "$PIN" login-ui 2>>"${WORK}/gate.err")"; GATE_RC=$?
assert_reject "(R3 pull-wiring: override without an operator content anchor refused)"

# ── R4: key revocation + cached-base freshness re-checked at consume ──────────────
# (R4a) the signing KEY is revoked via registry revokedKeys[] -> refused DESPITE a
# valid signature (revoke a compromised foreign key without a live CRL/OCSP).
REG_REVKEY="${WORK}/registry-revkey.json"
jq -n --arg m "$MESH" --arg fp "$KEYFP" \
  '{schemaVersion:1, meshes:{($m):{enabled:true, revokedKeys:[$fp], gitBase:"https://forge.acme.test/acme"}}}' > "$REG_REVKEY"
B="${WORK}/r4revkey"; mkclean_base "$B"; PIN="$(digest_of r4revkey)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate r4revkey "$B" "$MESH" "$PIN" --registry "$REG_REVKEY"
assert_reject "(R4 gate: signing key in registry revokedKeys refused despite a valid signature)"
# (R4b) FRESHNESS: a base admitted under the shipped floor is re-gated against a
# RAISED floor (a component that became CRITICAL after admission) and is refused.
B="${WORK}/r4fresh"; mkclean_base "$B"; PIN="$(digest_of r4fresh)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
run_gate r4fresh_ok "$B" "$MESH" "$PIN"                 # shipped floor: left-pad@1.3.0 benign
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.hugmesh-mesh-admitted" ]; then
  ok "(R4 freshness) base admits under the shipped floor (pre-disclosure)"
else
  bad "(R4 freshness) base unexpectedly rejected under the shipped floor (rc=${GATE_RC})"
fi
FLOOR2="${WORK}/floor-raised.txt"; printf 'left-pad 1.3.0 CRITICAL CVE-TEST-0001\n' > "$FLOOR2"
GATE_Q="${WORK}/q/r4fresh_re"; mkdir -p "$GATE_Q"
GATE_OUT="$(FIB_ADVISORY_FLOOR_DEFAULT="$FLOOR2" bash "${GATE}" --base "$B" --mesh-id "$MESH" --pinned-digest "$PIN" \
    --trust-store "$TRUST" --quarantine "$GATE_Q" --advisory-floor "$FLOOR2" --registry "$REG_GATE" 2>>"${WORK}/gate.err")"; GATE_RC=$?
assert_reject "(R4 freshness: re-gated cached base refused under the RAISED advisory floor)"
# (R4c) revoke-by-DELETION: removing the staged pinned key stops the cached base.
B="${WORK}/r4del"; mkclean_base "$B"; PIN="$(digest_of r4del)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
TRUST_DEL="${WORK}/trust-del"; mkdir -p "${TRUST_DEL}/${MESH}"   # mesh dir present, key REMOVED
GATE_Q="${WORK}/q/r4del"; mkdir -p "$GATE_Q"
GATE_OUT="$(FIB_ADVISORY_FLOOR_DEFAULT="$ADVISORY" bash "${GATE}" --base "$B" --mesh-id "$MESH" --pinned-digest "$PIN" \
    --trust-store "$TRUST_DEL" --quarantine "$GATE_Q" --advisory-floor "$ADVISORY" --registry "$REG_GATE" 2>>"${WORK}/gate.err")"; GATE_RC=$?
assert_reject "(R4 revoke-by-deletion: removed pinned key -> cached base refused, no admission)"

# ── R5: the digest binds symlink TARGETS + exec/mode bits (old-vs-new proofs) ─────
# (R5a) a mode flip (exec bit) AFTER signing, NOT re-signed. The OLD content-only
# digest is blind to it (would ADMIT); the current digest binds it -> REJECT.
B="${WORK}/r5mode"; mkclean_base "$B"; chmod 0644 "${B}/federation-base.js"
PIN="$(digest_of r5mode)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
R5_OLD_BEFORE="$(content_only_digest "$B")"
chmod 0755 "${B}/federation-base.js"          # flip exec bit; do NOT re-sign
R5_OLD_AFTER="$(content_only_digest "$B")"
run_gate r5mode "$B" "$MESH" "$PIN"
assert_reject "(R5 mode-flip: post-sign exec-bit change caught by the mode-bound digest)"
if [ "$R5_OLD_BEFORE" = "$R5_OLD_AFTER" ]; then
  ok "(R5 mode-flip OLD-vs-NEW) content-only digest UNCHANGED by the flip -> the pre-fix gate would have ADMITTED"
else
  bad "(R5 mode-flip OLD-vs-NEW) content-only digest changed — not proving old-vs-new"
fi
# (R5b) an in-tree symlink REPOINTED (both targets contained, no '..') AFTER signing,
# NOT re-signed. The OLD walk excluded symlinks entirely (blind -> ADMIT); the
# current digest binds the target -> REJECT.
B="${WORK}/r5link"; mkclean_base "$B"; printf 'other\n' > "${B}/src/other.txt"; ln -s index.html "${B}/src/link"
PIN="$(digest_of r5link)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
R5L_OLD_BEFORE="$(content_only_digest "$B")"
rm "${B}/src/link"; ln -s other.txt "${B}/src/link"     # repoint within src (contained); do NOT re-sign
R5L_OLD_AFTER="$(content_only_digest "$B")"
run_gate r5link "$B" "$MESH" "$PIN"
assert_reject "(R5 symlink-repoint: post-sign link-target change caught by the target-bound digest)"
if [ "$R5L_OLD_BEFORE" = "$R5L_OLD_AFTER" ]; then
  ok "(R5 symlink-repoint OLD-vs-NEW) content-only digest UNCHANGED by the repoint -> the pre-fix gate would have ADMITTED"
else
  bad "(R5 symlink-repoint OLD-vs-NEW) content-only digest changed — not proving old-vs-new"
fi

# ── R6: DoS caps HOISTED ahead of the clone/pipeline (bound before disk exhaustion) ─
# (R6a) pull's post-fetch, pre-gate inode cap fires on an oversized override BEFORE
# the ingestion gate runs (offline; mirrors the gate's hoisted DoS-cap pattern).
# THE ENTRY COUNT IS THE TEST. This case used 40 entries against a cap of 20,
# which proved the cap fires but could never have caught how it fired. The guard
# counts with `find … | head -n $((cap+1)) | wc -l`; head exits early — as it must,
# a DoS guard may not enumerate a hostile tree in full — and that SIGPIPEs find.
# Under pull-repo-base.sh's `set -euo pipefail` the 141 became the pipeline's
# status and killed the script AT THE ASSIGNMENT, so the `die` explaining the
# refusal never ran. It only does that once find's output OVERFLOWS THE 64 KiB
# PIPE BUFFER: at 40 short paths (~2 KiB) find finishes writing before head can
# exit and nothing is signalled. 3000 entries is ~180 KiB, far into the range
# where it is deterministic — measured 200/200 above 128 KiB, 0/3000 below 16 KiB.
B="${WORK}/r6files"; mkclean_base "$B"; mkdir -p "${B}/many"
i=0; while [ $i -lt 3000 ]; do : > "${B}/many/f${i}"; i=$((i+1)); done
PIN="$(digest_of r6files)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 5
R6_ANCHOR="$(_fib_tree_digest "$B")"
GATE_Q="${WORK}/prb/r6files/.mesh-quarantine/login-ui"
GATE_OUT="$(REPO_BASE_CACHE="${WORK}/prb/r6files" MESH_REGISTRY="$REG" MESH_TRUST_STORE="$TRUST" \
    LOGIN_UI_BASE_DIR="$B" OFFLINE=1 FOREIGN_PINNED_TREE_SHA256="$R6_ANCHOR" FOREIGN_MAX_FILES=20 \
    FIB_ADVISORY_FLOOR_DEFAULT="$ADVISORY" \
    bash "$PRB" --foreign --mesh "$MESH" --pinned-digest "$PIN" login-ui 2>>"${WORK}/gate.err")"; GATE_RC=$?
assert_reject "(R6 pull pre-gate inode cap: oversized override refused ahead of the gate)"
# ...and it must REFUSE, not crash. assert_reject only requires rc != 0, and an
# abort is also rc != 0 — so it cannot tell a guard that explained itself from one
# that died mid-count. The message IS the guard's output; demand it.
if grep -q 'DoS/zip-bomb guard' "${WORK}/gate.err" 2>/dev/null; then
  ok "(R6 pull pre-gate inode cap: refusal is EXPLAINED, not an abort)"
else
  bad "(R6 pull pre-gate inode cap: rc was non-zero but the DoS-guard message never printed — the cap died mid-count instead of refusing; see ${WORK}/gate.err)"
fi
# (R6b) fetch-time byte watchdog: a fake git that streams an UNBOUNDED clone is
# ABORTED mid-fetch before it can exhaust disk (the clone stays bounded near the cap).
if command -v setsid >/dev/null 2>&1; then
  FAKEBIN="${WORK}/fakebin"; mkdir -p "$FAKEBIN"
  cat > "${FAKEBIN}/git" <<'FG'
#!/usr/bin/env bash
# Fake git for the R6 fetch-time watchdog test: init/remote/checkout no-op; fetch
# simulates a hostile unbounded clone (1 MiB chunks, slowly, "forever").
dir="."
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="$2"; shift 2 ;;
    init|remote) exit 0 ;;
    checkout) exit 0 ;;
    fetch)
      mkdir -p "$dir"; i=0
      while [ $i -lt 400 ]; do head -c 1048576 /dev/zero > "${dir}/blob.${i}" 2>/dev/null; i=$((i+1)); sleep 0.03; done
      exit 0 ;;
    *) shift ;;
  esac
done
exit 0
FG
  chmod +x "${FAKEBIN}/git"
  REG_CLONE="${WORK}/registry-clone.json"
  jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:true, gitBase:"https://forge.acme.test/acme", minGeneration:0}}}' > "$REG_CLONE"
  CLONE_CACHE="${WORK}/prb/r6clone"; rm -rf "$CLONE_CACHE"
  PIN64="$(digest_of r6clone)"
  PATH="${FAKEBIN}:${PATH}" REPO_BASE_CACHE="$CLONE_CACHE" MESH_REGISTRY="$REG_CLONE" \
    MESH_TRUST_STORE="$TRUST" FOREIGN_FETCH_MAX_BYTES=4194304 FOREIGN_PINNED_TREE_SHA256="$(digest_of r6clone_anchor)" \
    bash "$PRB" --foreign --mesh "$MESH" --pinned-digest "$PIN64" login-ui >/dev/null 2>>"${WORK}/gate.err"
  R6_RC=$?
  R6_CLONE_DIR="${CLONE_CACHE}/foreign/${MESH}/hugmesh-login-ui"
  R6_SZ="$(du -sb "$R6_CLONE_DIR" 2>/dev/null | awk '{print $1+0}')"
  if [ "$R6_RC" -ne 0 ] && [ "${R6_SZ:-0}" -lt 16777216 ]; then
    ok "(R6 fetch-time watchdog) unbounded hostile clone ABORTED mid-fetch (rc=${R6_RC}, clone bounded at ${R6_SZ}B < 16MiB)"
  else
    bad "(R6 fetch-time watchdog) clone not bounded (rc=${R6_RC}, size=${R6_SZ}B) — watchdog did not fire"
  fi
  rm -rf "$CLONE_CACHE"
else
  echo "  SKIP (R6b) fetch-time watchdog (setsid unavailable)"
fi
# (R6c) CHECKOUT-time byte watchdog (mustFix): git stores blobs COMPRESSED in the pack,
# and `git checkout` is the step that INFLATES them onto disk. A decompression-bomb
# pinned tree ships a SMALL pack (under the fetch cap, so the FETCH watchdog never
# fires) that expands to a runaway working tree on checkout. Before the fix the checkout
# was UNCAPPED — it wrote the full inflated tree to disk and only _prb_enforce_source_caps
# (a du AFTER checkout) noticed, too late to stop disk exhaustion. The checkout is now
# wrapped in the SAME watchdog: it is ABORTED MID-CHECKOUT and the clone stays bounded
# near the cap, fail-closed. The fake git's fetch stays UNDER the fetch cap so this
# proves the CHECKOUT guard specifically (not the fetch guard).
if command -v setsid >/dev/null 2>&1; then
  FAKEBIN2="${WORK}/fakebin-co"; mkdir -p "$FAKEBIN2"
  cat > "${FAKEBIN2}/git" <<'FG'
#!/usr/bin/env bash
# Fake git for the R6 CHECKOUT-time watchdog test: init/remote no-op; fetch writes a
# SMALL 2 MiB "pack" (under the fetch cap) then exits 0; checkout simulates inflating a
# decompression bomb — 1 MiB chunks, slowly, "forever" — into the clone dir.
dir="."
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="$2"; shift 2 ;;
    init|remote) exit 0 ;;
    fetch)
      mkdir -p "${dir}/.git/objects"; head -c 2097152 /dev/zero > "${dir}/.git/objects/pack.bin" 2>/dev/null
      exit 0 ;;
    checkout)
      mkdir -p "$dir"; i=0
      while [ $i -lt 400 ]; do head -c 1048576 /dev/zero > "${dir}/inflated.${i}" 2>/dev/null; i=$((i+1)); sleep 0.03; done
      exit 0 ;;
    *) shift ;;
  esac
done
exit 0
FG
  chmod +x "${FAKEBIN2}/git"
  REG_CO="${WORK}/registry-checkout.json"
  jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:true, gitBase:"https://forge.acme.test/acme", minGeneration:0}}}' > "$REG_CO"
  CO_CACHE="${WORK}/prb/r6checkout"; rm -rf "$CO_CACHE"
  PINCO="$(digest_of r6checkout)"
  # fetch cap 16 MiB (fetch writes 2 MiB -> passes); checkout cap (FOREIGN_MAX_BYTES) 8 MiB.
  PATH="${FAKEBIN2}:${PATH}" REPO_BASE_CACHE="$CO_CACHE" MESH_REGISTRY="$REG_CO" \
    MESH_TRUST_STORE="$TRUST" FOREIGN_FETCH_MAX_BYTES=16777216 FOREIGN_MAX_BYTES=8388608 \
    FOREIGN_PINNED_TREE_SHA256="$(digest_of r6checkout_anchor)" \
    bash "$PRB" --foreign --mesh "$MESH" --pinned-digest "$PINCO" login-ui >/dev/null 2>>"${WORK}/gate.err"
  CO_RC=$?
  CO_DIR="${CO_CACHE}/foreign/${MESH}/hugmesh-login-ui"
  CO_SZ="$(du -sb "$CO_DIR" 2>/dev/null | awk '{print $1+0}')"
  # bounded well under the 400 MiB runaway (8 MiB cap + watchdog grace), and fail-closed.
  if [ "$CO_RC" -ne 0 ] && [ "${CO_SZ:-0}" -lt 67108864 ]; then
    ok "(R6 checkout-time watchdog) decompression-bomb checkout ABORTED mid-inflate (rc=${CO_RC}, clone bounded at ${CO_SZ}B < 64MiB, not the 400MiB runaway)"
  else
    bad "(R6 checkout-time watchdog) checkout not bounded (rc=${CO_RC}, size=${CO_SZ}B) — the fetch cap left checkout unguarded"
  fi
  rm -rf "$CO_CACHE"
else
  echo "  SKIP (R6c) checkout-time watchdog (setsid unavailable)"
fi

echo
echo "-- POSITIVE CONTROL: a clean, signed, digest-pinned base from a TRUSTED mesh IS admitted + renders --"
B="${WORK}/legit"; mkclean_base "$B"; PIN="$(digest_of legit)"; sign_base "$B" "$PRIV" "$MESH" "$PIN" 7
run_gate legit "$B" "$MESH" "$PIN" --min-generation 5
if [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_OUT}" ] && [ -d "${GATE_OUT}" ] && [ -f "${GATE_OUT}/.hugmesh-mesh-admitted" ]; then
  ok "(legit) gate ADMITTED a clean signed digest-pinned base (rc=0, snapshot promoted)"
else
  bad "(legit) gate REJECTED a clean base (rc=${GATE_RC}, out='${GATE_OUT}') — FALSE POSITIVE / blanket lockout"
fi
if [ "${HAVE_RENDER}" -eq 1 ]; then
  OUT="${WORK}/rout/legit"; rm -rf "$OUT"
  LEGIT_ANCHOR="$(_fib_tree_digest "$B")"
  if MESH_REGISTRY="$REG_GATE" bash "${RRT}" "${BRANDCONF}" --enable-repo-tree --repo login-ui --archetype angular-mfe \
        --out-dir "$OUT" --base "$B" --foreign-mesh "$MESH" --pinned-digest "$PIN" \
        --pinned-tree-sha256 "$LEGIT_ANCHOR" --registry "$REG_GATE" \
        --trust-store "$TRUST" --min-generation 5 \
        --set APP_SLUG=login --set TITLE_WORD=Login >"${WORK}/legit-render.log" 2>&1; then
    BO="${OUT}/acme-login-ui"
    if [ -d "$BO" ] && [ -n "$(ls -A "$BO" 2>/dev/null)" ]; then
      ok "(legit) render_repo_tree emitted a tree ($(find "$BO" -type f | wc -l | tr -d ' ') files) from the admitted foreign base"
    else bad "(legit) render produced no tree"; fi
    if grep -rqE '\{\{[A-Z_]+\}\}' "$BO" 2>/dev/null; then bad "(legit) residual {{TOKEN}} remains"; else ok "(legit) 0 residual {{TOKEN}}s in the rendered tree"; fi
    if grep -rq '{{BRAND_TITLE}}' "$BO" 2>/dev/null; then bad "(legit) BRAND_TITLE unsubstituted"; fi
    # The WHOLE <title> element, not a loose substring: the recipe's tab-title
    # replacement is `<title>{{BRAND_TITLE}} {{TITLE_WORD}}</title>`, so pinning the
    # closing tag is what proves the rebrand landed AND that no stale " (remote)"
    # tail survived (a bare 'Acme Portal Login' would match either shape).
    if grep -rq '<title>Acme Portal Login</title>' "$BO" 2>/dev/null; then ok "(legit) brand token substituted (title rebranded)"; else bad "(legit) brand rebrand not applied"; fi
    # gate markers + foreign attestation envelope must NOT ride into the emitted tree.
    if [ -e "${BO}/.hugmesh-mesh-admitted" ] || [ -e "${BO}/.foreign-mesh-id" ] || [ -e "${BO}/.hugmesh-provenance.json" ] || [ -e "${BO}/.hugmesh-sbom.json" ]; then
      bad "(legit) gate/foreign-attestation markers leaked into the emitted tree"
    else ok "(legit) gate markers + foreign attestation stripped from the emitted tree"; fi
  else
    bad "(legit) render_repo_tree FAILED on the admitted clean base — FALSE POSITIVE"; sed 's/^/      /' "${WORK}/legit-render.log" | tail -8
  fi
else
  echo "  SKIP (legit) render (node/handlebars unavailable) — gate-admit half asserted above"
fi

echo
echo "-- Phase 7 GRAFT: gen-provision-keys.sh --foreign-mesh-trust KEY-STAGING (capability #1) --"
# Without this, A's no-TOFU foreign-mesh trust store has no way to get pubkeys onto a
# node. Assert: a REAL Ed25519 PUBLIC half stages gate-readable at
# <mesh>/foreign-provenance-pub.ed25519; a PRIVATE key ABORTS + stages nothing.
GPK="${REPO}/scripts/gen-provision-keys.sh"
if command -v ssh-keygen >/dev/null && command -v python3 >/dev/null; then
  KSRC="${WORK}/fmt-src"; mkdir -p "${KSRC}"
  openssl pkey -in "${PRIV}" -pubout -out "${KSRC}/beta-mesh.ed25519.pub" 2>/dev/null     # PEM pubkey
  mkdir -p "${WORK}/priv-as-pub"; cp "${PRIV}" "${WORK}/priv-as-pub/evil-mesh.ed25519.pub" # a PRIVATE key
  KOUT="${WORK}/keys-out-accept"
  if NONINTERACTIVE=1 bash "${GPK}" --role host --no-device-ssh --random -o "${KOUT}" \
        --foreign-mesh-trust "${KSRC}" >/dev/null 2>"${WORK}/gpk.err"; then
    STAGED="${KOUT}/mesh-trust/beta-mesh/foreign-provenance-pub.ed25519"
    if [ -f "${STAGED}" ] && base64 -d "${STAGED}" 2>/dev/null \
         | openssl pkey -pubin -inform DER -noout -text 2>/dev/null | grep -i ED25519 >/dev/null; then
      ok "(key-staging) real Ed25519 pubkey STAGED gate-readable at <mesh>/foreign-provenance-pub.ed25519"
    else bad "(key-staging) staged key missing / not gate-readable at ${STAGED}"; fi
  else bad "(key-staging) accept run failed: $(tail -2 "${WORK}/gpk.err")"; fi
  KOUT2="${WORK}/keys-out-reject"
  if NONINTERACTIVE=1 bash "${GPK}" --role host --no-device-ssh --random -o "${KOUT2}" \
        --foreign-mesh-trust "${WORK}/priv-as-pub" >/dev/null 2>"${WORK}/gpk2.err"; then
    bad "(key-staging) a PRIVATE key was ACCEPTED as a trust pubkey (must ABORT)"
  else
    grep -q "does not parse as an Ed25519 PUBLIC key" "${WORK}/gpk2.err" \
      && ok "(key-staging) PRIVATE key REJECTED (fail-closed, pubkeys-only)" \
      || ok "(key-staging) rejected (rc!=0): $(grep -i ERROR "${WORK}/gpk2.err" | head -1)"
    [ ! -f "${KOUT2}/mesh-trust/evil-mesh/foreign-provenance-pub.ed25519" ] \
      && ok "(key-staging) private key NOT staged (nothing left behind)" || bad "(key-staging) private key was staged (LEAK)"
  fi
else
  echo "  SKIP key-staging (need ssh-keygen + python3 for gen-provision-keys.sh)"
fi

echo
echo "-- Phase 7 GRAFT: render-tenant-set.js repos[].origin {mesh,digest} FORWARDING (capability #3) --"
RTS="${REPO}/scripts/tooling/render-tenant-set.js"
mkbrand() { # mkbrand FILE ORIGIN_INLINE_YAML — minimal valid brand YAML, one login-ui repo
  cat > "$1" <<Y
brand: acme
title: Acme Arcade
org: acme
domains:
  - acme.games
repos:
  - name: login-ui
    archetype: angular-mfe
    installed: true
    identity: { app_slug: login, title_word: Login }
    origin: $2
Y
}
if command -v node >/dev/null && [ -d "${REPO}/scripts/tooling/node_modules/js-yaml" ]; then
  # (o1) origin.mesh not a DNS label -> fail-closed in the driver (before any spawn).
  mkbrand "${WORK}/o_badmesh.yaml" '{ mesh: "Bad_Mesh", digest: "0000000000000000000000000000000000000000" }'
  if node "${RTS}" "${WORK}/o_badmesh.yaml" --out-dir "${WORK}/oout1" --only login-ui >/dev/null 2>"${WORK}/o1.err"; then
    bad "(manifest-origin) non-DNS origin.mesh ACCEPTED"
  else grep -q "origin.mesh" "${WORK}/o1.err" && ok "(manifest-origin) non-DNS origin.mesh rejected" \
        || ok "(manifest-origin) rejected: $(grep FATAL "${WORK}/o1.err" | head -1)"; fi
  # (o2) origin.digest not 40-hex (a mutable ref) -> fail-closed.
  mkbrand "${WORK}/o_baddig.yaml" '{ mesh: "acme-mesh", digest: "main" }'
  if node "${RTS}" "${WORK}/o_baddig.yaml" --out-dir "${WORK}/oout2" --only login-ui >/dev/null 2>"${WORK}/o2.err"; then
    bad "(manifest-origin) mutable-ref origin.digest ACCEPTED"
  else grep -q "origin.digest" "${WORK}/o2.err" && ok "(manifest-origin) mutable-ref origin.digest rejected" \
        || ok "(manifest-origin) rejected: $(grep FATAL "${WORK}/o2.err" | head -1)"; fi
  # (o3) POSITIVE FORWARDING: a valid origin forwards --foreign-mesh so an UNSIGNED base
  #      is REJECTED by the ingest gate. If the flag were NOT forwarded, render-repo-tree
  #      would take the own-mesh path and SUCCEED — so rc!=0 PROVES the forwarding.
  #      R3: render-repo-tree.sh --foreign-mesh now REQUIRES an operator content anchor
  #      before it will even reach the gate; render-tenant-set.js does not forward one
  #      (render-repo-tree.sh falls back to the registry's pinnedTreeSha256). Supply a
  #      test-local registry row with the correct anchor so this case still dies for its
  #      INTENDED reason (the gate's signature check), not merely the earlier R3 pre-check.
  if [ "${HAVE_RENDER}" -eq 1 ]; then
    UB="${WORK}/o_unsigned"; mkclean_base "$UB"; OPIN="$(digest_of o_unsigned | cut -c1-40)"
    sign_base "$UB" "$PRIV" "$MESH" "$OPIN" 5; rm -f "${UB}/.hugmesh-provenance.json.sig"
    OANCHOR="$(_fib_tree_digest "$UB")"
    OREG="${WORK}/o_registry.json"
    jq -n --arg m "$MESH" --arg t "$OANCHOR" \
      '{schemaVersion:1, meshes:{($m):{enabled:true, gitBase:"https://forge.acme.test/acme", minGeneration:0, pinnedTreeSha256:$t}}}' > "$OREG"
    mkbrand "${WORK}/o_fwd.yaml" "{ mesh: \"${MESH}\", digest: \"${OPIN}\" }"
    if (cd "$REPO" && LOGIN_UI_BASE_DIR="$UB" MESH_TRUST_STORE="$TRUST" MESH_REGISTRY="$OREG" OFFLINE=1 \
          node "${RTS}" "${WORK}/o_fwd.yaml" --out-dir "${WORK}/oout3" --only login-ui >/dev/null 2>"${WORK}/o3.err"); then
      bad "(manifest-origin) FORWARDING BROKEN: unsigned foreign base rendered (own-mesh path, gate skipped)"
    else
      grep -qi "signature\|does not verify\|unsigned" "${WORK}/o3.err" \
        && ok "(manifest-origin) valid origin forwards --foreign-mesh -> unsigned base REJECTED by the gate's signature check (forwarding proven)" \
        || ok "(manifest-origin) valid origin forwards --foreign-mesh -> rejected (rc!=0): $(grep -i 'FATAL\|reject' "${WORK}/o3.err" | head -1)"
    fi
  else echo "  SKIP (manifest-origin forwarding) node/handlebars unavailable"; fi
else
  echo "  SKIP manifest-origin (need node + js-yaml)"
fi

echo
echo "-- Phase 7 GRAFT: publish-tenant-set.sh LAUNDER-REFUSAL (capability #2) --"
# A foreign-origin tree may be published ONLY with a valid '.hugmesh-mesh-admitted'
# receipt from A's gate. Positive: a signed clean foreign base admits (persistent
# stamp), renders foreign-overlay, and publishes (push fires + provenance records
# base.originMesh). Then the stamp is DELETED and the SAME publish must die BEFORE any
# push (launder-refusal), pushing nothing.
PUB="${REPO}/scripts/publish-tenant-set.sh"
PRB="${REPO}/scripts/pull-repo-base.sh"
if [ "${HAVE_RENDER}" -eq 1 ]; then
  REAL_GIT="$(command -v git)"; LSTUB="${WORK}/launder-bin"; mkdir -p "$LSTUB"
  PLOG="${WORK}/push.log"; CLOG="${WORK}/curl.log"; : > "$PLOG"; : > "$CLOG"
  cat > "${LSTUB}/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" push "*) printf 'PUSH %s\n' "\$*" >> "${PLOG}";; esac
exec "${REAL_GIT}" "\$@"
EOF
  cat > "${LSTUB}/curl" <<EOF
#!/usr/bin/env bash
printf 'CURL %s\n' "\$*" >> "${CLOG}"; exit 0
EOF
  chmod +x "${LSTUB}/git" "${LSTUB}/curl"
  LCACHE="${WORK}/lcache"; mkdir -p "$LCACHE"
  LREG="${WORK}/lregistry.json"
  jq -n --arg m "$MESH" '{schemaVersion:1, meshes:{($m):{enabled:true, gitBase:"https://forge.acme.test/acme", minGeneration:0}}}' > "$LREG"
  LBASE="${WORK}/lbase"; mkclean_base "$LBASE"
  LPIN="$(digest_of launder-legit)"; sign_base "$LBASE" "$PRIV" "$MESH" "$LPIN" 5
  # R3: both the *_BASE_DIR override path (pull-repo-base.sh) and the local-base
  # render path (render-repo-tree.sh --foreign-mesh) now REQUIRE an operator content
  # anchor binding the pin to the ACTUAL bytes (no git commit->tree binding on either
  # path). Compute it once via the gate's own helper (sourced at file scope above).
  LANCHOR="$(_fib_tree_digest "$LBASE")"
  # 1) pull-repo-base --foreign (override) -> persistent admitted snapshot + stamp.
  LADM="$(REPO_BASE_CACHE="$LCACHE" MESH_REGISTRY="$LREG" MESH_TRUST_STORE="$TRUST" \
     LOGIN_UI_BASE_DIR="$LBASE" OFFLINE=1 FIB_ADVISORY_FLOOR_DEFAULT="$ADVISORY" \
     FOREIGN_PINNED_TREE_SHA256="$LANCHOR" \
     bash "$PRB" --foreign --mesh "$MESH" --pinned-digest "$LPIN" login-ui 2>"${WORK}/lprb.err")"
  LSTAMP="${LCACHE}/.mesh-quarantine/login-ui/${MESH}-${LPIN:0:16}/.hugmesh-mesh-admitted"
  [ -f "$LSTAMP" ] && ok "(launder) inbound gate left a persistent .hugmesh-mesh-admitted stamp" \
    || bad "(launder) no admission stamp: $(tail -2 "${WORK}/lprb.err")"
  # 2) durable foreign-clone origin signal (as fetch-mode would create).
  mkdir -p "${LCACHE}/foreign/${MESH}"; cp -r "$LBASE" "${LCACHE}/foreign/${MESH}/hugmesh-login-ui"
  # 3) render the foreign-overlay tree through the gate.
  LOUT="${WORK}/lout"
  if (cd "$REPO" && MESH_REGISTRY="$LREG" bash "$RRT" "${BRANDCONF}" --enable-repo-tree --repo login-ui --archetype angular-mfe \
        --out-dir "$LOUT" --base "$LBASE" --foreign-mesh "$MESH" --pinned-digest "$LPIN" \
        --pinned-tree-sha256 "$LANCHOR" \
        --trust-store "$TRUST" --min-generation 0 --set APP_SLUG=login --set TITLE_WORD=Login >/dev/null 2>"${WORK}/lrender.err") \
     && [ -d "${LOUT}/acme-login-ui" ]; then ok "(launder) foreign-overlay tree rendered"
  else bad "(launder) render failed: $(tail -3 "${WORK}/lrender.err")"; fi
  # 4) publish WITH the stamp present -> push fires + provenance records origin.
  LBARE="${WORK}/lbare"; mkdir -p "$LBARE"; "${REAL_GIT}" init -q --bare "${LBARE}/acme-login-ui.git"
  : > "$PLOG"
  if (cd "$REPO" && PATH="${LSTUB}:${PATH}" REPO_BASE_CACHE="$LCACHE" FORGEJO_PUSH_TOKEN=dummy \
        FORGEJO_API_MODE=none FORGEJO_REMOTE_TEMPLATE="file://${LBARE}/%s.git" \
        bash "$PUB" "$LOUT" >/dev/null 2>"${WORK}/lpub.err"); then ok "(launder) publish pushed the foreign-overlay tree (stamp verified at publish)"
  else bad "(launder) publish FAILED with the stamp present: $(tail -3 "${WORK}/lpub.err")"; fi
  grep -q PUSH "$PLOG" && ok "(launder) push recorder saw the POSITIVE push (recorder is live, not vacuous)" \
    || bad "(launder) no push recorded on the positive control"
  grep -q '"originMesh": "'"${MESH}"'"' "${LOUT}/acme-login-ui/.hugmesh-provenance.json" 2>/dev/null \
    && ok "(launder) provenance records base.originMesh=${MESH} + mode foreign-overlay" || bad "(launder) provenance lacks the foreign lineage"
  LMAIN="$("${REAL_GIT}" -C "${LBARE}/acme-login-ui.git" rev-parse main 2>/dev/null)"
  # 5) DELETE the stamp -> the SAME publish must die BEFORE any push.
  rm -f "$LSTAMP"; printf 'drift\n' >> "${LOUT}/acme-login-ui/README.md"
  : > "$PLOG"; : > "$CLOG"
  if (cd "$REPO" && PATH="${LSTUB}:${PATH}" REPO_BASE_CACHE="$LCACHE" FORGEJO_PUSH_TOKEN=dummy \
        FORGEJO_API_MODE=none FORGEJO_REMOTE_TEMPLATE="file://${LBARE}/%s.git" \
        bash "$PUB" "$LOUT" >/dev/null 2>"${WORK}/lpub2.err"); then
    bad "(launder) publish SUCCEEDED with the stamp GONE (foreign code LAUNDERED!)"
  else
    grep -q "NO .hugmesh-mesh-admitted stamp" "${WORK}/lpub2.err" \
      && ok "(launder) publish REFUSED the stamp-less foreign base (fail-closed reason)" \
      || ok "(launder) publish refused (rc!=0): $(grep FATAL "${WORK}/lpub2.err" | head -1)"
  fi
  { [ ! -s "$PLOG" ] && [ ! -s "$CLOG" ]; } && ok "(launder) nothing pushed onward (0 git-push, 0 curl)" \
    || { bad "(launder) PUSH/CURL fired"; sed 's/^/        /' "$PLOG" "$CLOG" 2>/dev/null; }
  [ "$("${REAL_GIT}" -C "${LBARE}/acme-login-ui.git" rev-parse main 2>/dev/null)" = "$LMAIN" ] \
    && ok "(launder) bare remote unchanged (nothing pushed after refusal)" || bad "(launder) remote MOVED after refusal"

  echo
  echo "  -- CACHE-PURGE sub-case: the DURABLE in-tree base-origin marker survives a foreign-cache purge --"
  # THE RESIDUAL MEDIUM: publish's foreign-origin detection keyed SOLELY off the
  # REMOVABLE foreign cache dir. Purged after render but before publish, the pre-fix
  # publish saw NO foreign signal, treated the foreign-DERIVED tree as own-mesh, and
  # re-signed+PUSHED it with no stamp re-verify. THE FIX: render writes a durable,
  # OUR-authored .hugmesh-base-origin.json INTO BRAND_OUT that TRAVELS with the tree;
  # publish keys off THAT fail-closed. This case renders a foreign-overlay tree, then
  # `rm -rf`s the ENTIRE foreign cache (clone + quarantine stamp), then publishes: the
  # marker still forces the foreign path so publish REFUSES the now-stamp-less tree and
  # pushes NOTHING. OLD-vs-NEW: with the marker ALSO removed (pre-fix state — no marker,
  # no cache, no stamp) the SAME purged tree publishes as own-mesh (the exact laundering
  # the marker closes), pushing to a separate bare remote.
  CPCACHE="${WORK}/cpcache"; mkdir -p "$CPCACHE"
  CPBASE="${WORK}/cpbase"; mkclean_base "$CPBASE"
  CPPIN="$(digest_of cachepurge)"; sign_base "$CPBASE" "$PRIV" "$MESH" "$CPPIN" 5
  CPANCHOR="$(_fib_tree_digest "$CPBASE")"
  # durable admitted snapshot + stamp (pull --foreign) + the foreign clone signal.
  REPO_BASE_CACHE="$CPCACHE" MESH_REGISTRY="$LREG" MESH_TRUST_STORE="$TRUST" \
     LOGIN_UI_BASE_DIR="$CPBASE" OFFLINE=1 FIB_ADVISORY_FLOOR_DEFAULT="$ADVISORY" \
     FOREIGN_PINNED_TREE_SHA256="$CPANCHOR" \
     bash "$PRB" --foreign --mesh "$MESH" --pinned-digest "$CPPIN" login-ui >/dev/null 2>"${WORK}/cpprb.err"
  mkdir -p "${CPCACHE}/foreign/${MESH}"; cp -r "$CPBASE" "${CPCACHE}/foreign/${MESH}/hugmesh-login-ui"
  # render the foreign-overlay tree (writes the durable base-origin marker into BRAND_OUT).
  CPOUT="${WORK}/cpout"; rm -rf "$CPOUT"
  if (cd "$REPO" && MESH_REGISTRY="$LREG" bash "$RRT" "${BRANDCONF}" --enable-repo-tree --repo login-ui --archetype angular-mfe \
        --out-dir "$CPOUT" --base "$CPBASE" --foreign-mesh "$MESH" --pinned-digest "$CPPIN" \
        --pinned-tree-sha256 "$CPANCHOR" \
        --trust-store "$TRUST" --min-generation 0 --set APP_SLUG=login --set TITLE_WORD=Login >/dev/null 2>"${WORK}/cprender.err") \
     && [ -d "${CPOUT}/acme-login-ui" ]; then ok "(cache-purge) foreign-overlay tree rendered"
  else bad "(cache-purge) render failed: $(tail -3 "${WORK}/cprender.err")"; fi
  CPMARK="${CPOUT}/acme-login-ui/.hugmesh-base-origin.json"
  if [ -f "$CPMARK" ] \
     && [ "$(jq -r '.originMesh'   "$CPMARK" 2>/dev/null)" = "$MESH" ] \
     && [ "$(jq -r '.pinnedDigest' "$CPMARK" 2>/dev/null)" = "$CPPIN" ] \
     && [ "$(jq -r '.treeSha256'   "$CPMARK" 2>/dev/null)" = "$CPANCHOR" ]; then
    ok "(cache-purge) render wrote a durable OUR-authored base-origin marker (originMesh+pinnedDigest+treeSha256)"
  else bad "(cache-purge) render did not write a well-formed base-origin marker at ${CPMARK}"; fi
  # PURGE the entire foreign cache (clone + quarantine stamp) — the pre-fix signal is gone.
  CPSTAMP="${CPCACHE}/.mesh-quarantine/login-ui/${MESH}-${CPPIN:0:16}/.hugmesh-mesh-admitted"
  [ -f "$CPSTAMP" ] && ok "(cache-purge) durable admission stamp present pre-purge" || bad "(cache-purge) no stamp pre-purge: $(tail -2 "${WORK}/cpprb.err")"
  rm -rf "${CPCACHE}/foreign" "${CPCACHE}/.mesh-quarantine"
  { [ ! -e "${CPCACHE}/foreign/${MESH}/hugmesh-login-ui" ] && [ ! -f "$CPSTAMP" ]; } \
    && ok "(cache-purge) foreign cache clone + quarantine stamp purged (pre-fix cache-scan is now blind)" \
    || bad "(cache-purge) cache not fully purged"
  # (NEW) publish WITH the durable marker present + cache/stamp gone -> MUST refuse, push nothing.
  CPBARE="${WORK}/cpbare"; mkdir -p "$CPBARE"; "${REAL_GIT}" init -q --bare "${CPBARE}/acme-login-ui.git"
  : > "$PLOG"; : > "$CLOG"
  if (cd "$REPO" && PATH="${LSTUB}:${PATH}" REPO_BASE_CACHE="$CPCACHE" FORGEJO_PUSH_TOKEN=dummy \
        FORGEJO_API_MODE=none FORGEJO_REMOTE_TEMPLATE="file://${CPBARE}/%s.git" \
        bash "$PUB" "$CPOUT" >/dev/null 2>"${WORK}/cppub.err"); then
    bad "(cache-purge) publish SUCCEEDED via marker-present + cache-purged (foreign code LAUNDERED past the belt!)"
  else
    grep -q "NO .hugmesh-mesh-admitted stamp" "${WORK}/cppub.err" \
      && ok "(cache-purge) publish detected foreign via the in-tree marker + REFUSED the stamp-less tree (fail-closed)" \
      || ok "(cache-purge) publish refused (rc!=0): $(grep FATAL "${WORK}/cppub.err" | head -1)"
  fi
  { [ ! -s "$PLOG" ] && [ ! -s "$CLOG" ]; } && ok "(cache-purge) nothing pushed onward (0 git-push, 0 curl)" \
    || { bad "(cache-purge) PUSH/CURL fired despite refusal"; sed 's/^/        /' "$PLOG" "$CLOG" 2>/dev/null; }
  [ -z "$("${REAL_GIT}" -C "${CPBARE}/acme-login-ui.git" rev-parse --verify main 2>/dev/null)" ] \
    && ok "(cache-purge) bare remote has no commits (nothing pushed after refusal)" || bad "(cache-purge) remote received a push after refusal"
  # (OLD-vs-NEW) remove the marker too -> reproduce the PRE-FIX state (no marker, no
  # cache, no stamp). The pre-fix publish saw NO foreign signal, treated the foreign-
  # DERIVED tree as own-mesh, and PUSHED it. Assert that here to prove the bypass was
  # real and the durable marker is precisely what closes it.
  rm -f "$CPMARK"; rm -rf "${CPOUT}/acme-login-ui/.git"
  CPBARE2="${WORK}/cpbare-old"; mkdir -p "$CPBARE2"; "${REAL_GIT}" init -q --bare "${CPBARE2}/acme-login-ui.git"
  : > "$PLOG"; : > "$CLOG"
  if (cd "$REPO" && PATH="${LSTUB}:${PATH}" REPO_BASE_CACHE="$CPCACHE" FORGEJO_PUSH_TOKEN=dummy \
        FORGEJO_API_MODE=none FORGEJO_REMOTE_TEMPLATE="file://${CPBARE2}/%s.git" \
        bash "$PUB" "$CPOUT" >/dev/null 2>"${WORK}/cppub-old.err") && grep -q PUSH "$PLOG"; then
    ok "(cache-purge OLD-vs-NEW) with the marker ALSO removed the SAME purged tree publishes as own-mesh + PUSHES (pre-fix laundering reproduced -> the marker is what closes it)"
  else
    bad "(cache-purge OLD-vs-NEW) marker-less purged tree did NOT publish+push (rc=$?, push=$(grep -c PUSH "$PLOG")) — pre-fix laundering not reproduced: $(grep FATAL "${WORK}/cppub-old.err" | head -1)"
  fi
else
  echo "  SKIP publish launder-refusal (node/handlebars unavailable — key-staging + manifest-origin halves still assert above)"
fi

echo
echo "== FOREIGN-INGEST FUZZ SUITE: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
