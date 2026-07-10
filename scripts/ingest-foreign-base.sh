#!/usr/bin/env bash
# ============================================================================
# ingest-foreign-base.sh — Phase 7 INBOUND foreign-mesh base ingestion GATE.
# ============================================================================
#
#  >>> BUILD-HOST ONLY. The fail-closed supply-chain gate for a base pulled from <<<
#  >>> a FOREIGN mesh (a GIT_BASE that is NOT our home mesh). A foreign base is   <<<
#  >>> treated as FULLY HOSTILE even when it is validly signed: a valid signature <<<
#  >>> proves WHO produced the manifest, never that the on-disk tree is safe.     <<<
#
# CONTRACT: everything runs inside a per-run QUARANTINE snapshot. ONLY a tree that
# passes EVERY gate is atomically admitted (its verified path is printed on STDOUT);
# ANY failure purges the snapshot, admits NOTHING, prints no path, and returns
# non-zero so the caller (pull-repo-base.sh / render-repo-tree.sh) fails closed and
# the foreign code is NEVER used as a base and NEVER pushed onward.
#
# The design MIRRORS the two proven fail-closed idioms already in this repo — the
# baked-key detached-Ed25519 verifier (specs/usr/lib/snapdragon/registry-verify.sh)
# and the reconcile quarantine->scan->promote gate (snapdragon-domain-reconcile) —
# and REUSES the existing primitives (provenance.sh verify, secret-scan.sh,
# token-classifier.js / tokens.json). It does NOT re-implement crypto or scanning.
#
# GATES, in order, each fail-closed (a missing tool is a REJECT, never a skip):
#   [DoS]  pre-flight caps on the SOURCE (file count / total bytes / path depth)
#          BEFORE any copy, so a zip-bomb / deep-nest tree cannot exhaust the host.
#   [SNAP] snapshot the source into a private per-run quarantine (closes TOCTOU:
#          every later gate AND the eventual overlay copy read the SAME frozen bytes,
#          never the mutable shared cache).
#   [g]    CONTAINMENT — reject symlinks that escape the snapshot root, absolute-
#          target symlinks, '..' traversal, and hardlinks. HOISTED ahead of the
#          content gates (like the Phase-6 DoS-cap hoist) so a planted symlink can
#          never subvert a later gate into reading a trusted file outside the tree.
#   [a]    DIGEST PIN — the base MUST be identified by an IMMUTABLE content digest
#          (40/64-hex commit SHA), never a mutable ref (main/HEAD/latest/a branch).
#          manifest.base.commitSha MUST equal the pinned digest; a recomputed
#          canonical TREE digest MUST equal manifest.base.treeSha256 (binds the
#          SIGNED manifest to the actual file bytes — provenance metadata alone does
#          NOT cover the tree); manifest.base.meshId MUST equal the declared mesh.
#   [b]    PROVENANCE / SIGNATURE — verify .snapdragon-provenance.json(.sig) via
#          provenance.sh against the FOREIGN mesh's PINNED pubkey resolved from the
#          trust store (base64 SPKI DER, pubkeys-only). NO trust-on-first-use: an
#          unknown mesh with no pinned key fails closed. Verify ONLY against the
#          staged key, NEVER the pubkey the envelope advertises. Plus a REPLAY floor
#          (generation >= min-generation) so an old signed-but-vulnerable base is
#          rejected.
#   [c]    SBOM — require a parseable, non-empty SBOM; reject absent/malformed.
#   [d]    VULN — scan a component set against a PINNED OFFLINE advisory floor;
#          fail-closed on any CRITICAL. The set is the UNION of the self-attested
#          SBOM (name-normalised to defeat group/purl name-shifting) AND the tree's
#          ACTUAL vendored jars/wheels + npm/pip lockfiles, so a hostile signer cannot
#          hide a known-CRITICAL dep by omitting/misversioning it in its own SBOM. A
#          source-compiled vuln (no artifact/lockfile) + the live vuln DB still need
#          network and are DEFERRED to the cluster (Trivy) — honest.
#   [e]    SECRET SCAN — secret-scan.sh over the ENTIRE tree with NO excludes (the
#          render emit-scan's src/main/java + src/test carve-out is a FIRST-PARTY CI
#          concern and MUST NOT apply to untrusted foreign source).
#   [f]    FROZEN / DENYLIST — foreign code must not carry OUR frozen protocol
#          identity (snapdragon.systems/* label-key namespace, X-Snapdragon-Local &
#          the other wire headers, the step-up subprotocol prefix); the declared
#          mesh-id / manifest identity fields are screened via token-classifier.
#
# SOURCEABLE: when sourced (BASH_SOURCE guard at the bottom), only the functions
# load — the adversarial fuzz suite drives each gate and reuses _fib_tree_digest.
#
# Usage:
#   ingest-foreign-base.sh --base DIR --mesh-id ID --pinned-digest SHA \
#       --trust-store DIR --quarantine DIR [--min-generation N] \
#       [--advisory-floor FILE]
#
# Exit: 0 + the admitted verified-snapshot path on STDOUT; non-zero (nothing on
# stdout, snapshot purged) on ANY failure.
set -uo pipefail

_fib_log()  { echo "[ingest-foreign-base] $*" >&2; }
_fib_die()  { echo "[ingest-foreign-base] REJECT: $*" >&2; return 1; }

FIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIB_ROOT="$(cd "${FIB_DIR}/.." && pwd)"

# ── Overridable seams (like the reconcile DR_* seams) so the fuzz suite can drive
#    the real gate wiring on the build host with no root and no network. ─────────
FIB_PROVENANCE="${FIB_PROVENANCE:-${FIB_DIR}/provenance.sh}"
FIB_SECRET_SCAN="${FIB_SECRET_SCAN:-${FIB_DIR}/secret-scan.sh}"
FIB_TOKENS_JSON="${FIB_TOKENS_JSON:-${FIB_DIR}/tooling/tokens.json}"
FIB_TOKEN_CLASSIFIER="${FIB_TOKEN_CLASSIFIER:-${FIB_DIR}/tooling/token-classifier.js}"
FIB_ADVISORY_FLOOR_DEFAULT="${FIB_ROOT}/templates/mesh-trust/advisory-floor.txt"
# DoS caps — a foreign tree over ANY of these is refused BEFORE it is copied.
FIB_MAX_FILES="${FIB_MAX_FILES:-20000}"
FIB_MAX_BYTES="${FIB_MAX_BYTES:-268435456}"   # 256 MiB
FIB_MAX_DEPTH="${FIB_MAX_DEPTH:-24}"

# Fixed attestation-envelope names shipped by a foreign base (parity with the
# provenance.sh manifest names + a Phase-7 SBOM sidecar).
FIB_MANIFEST=".snapdragon-provenance.json"
FIB_SIG=".snapdragon-provenance.json.sig"
FIB_SBOM=".snapdragon-sbom.json"
# Markers dropped into an ADMITTED snapshot (stripped before overlay-copy).
FIB_ADMIT_STAMP=".snapdragon-mesh-admitted"
FIB_FOREIGN_MARK=".foreign-mesh-id"

_FIB_DNS_LABEL='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

_fib_have() { command -v "$1" >/dev/null 2>&1; }

# ── _fib_tree_digest DIR -> stdout (canonical sha256 of the tree CONTENT) ───────
# A pure function of the on-disk BYTES: sha256 of each regular file, keyed by its
# LC_ALL=C-sorted relative path, then sha256 of the record stream. Excludes ONLY
# the ROOT-LEVEL provenance manifest + its detached sig (a manifest cannot contain
# its own hash) and .git metadata; the SBOM and everything else IS covered, so
# swapping any byte — including the SBOM — changes the digest and (because the
# digest is carried in the signed manifest as base.treeSha256) breaks the
# signature. ROOT-ANCHORED (-path './x', NOT -name): the envelope lives only at
# the tree root, so a file merely NAMED .snapdragon-provenance.json planted in a
# SUBDIR is ordinary tree content — digest-covered, meaning it cannot be added or
# altered after signing without breaking the binding. Deterministic and
# independent of the manifest, so it is the anti-circular binding between the signed
# manifest and the real files. Prints nothing + non-zero on error (fail-closed).
_fib_tree_digest() {
  local dir="$1"
  _fib_have sha256sum || return 1
  [ -d "$dir" ] || return 1
  (
    cd "$dir" || exit 1
    find . -type f \
        ! -path './.git/*' \
        ! -path "./${FIB_MANIFEST}" \
        ! -path "./${FIB_SIG}" \
        ! -path "./${FIB_ADMIT_STAMP}" \
        ! -path "./${FIB_FOREIGN_MARK}" \
        -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' f; do
          printf '%s  %s\n' "$(sha256sum "$f" 2>/dev/null | awk '{print $1}')" "$f"
        done \
      | sha256sum | awk '{print $1}'
  )
}

# ── _fib_jq_str FILE JQFILTER -> stdout (empty on any error) ────────────────────
_fib_jq_str() {
  local f="$1" filter="$2"
  _fib_have jq || return 1
  jq -r -e "${filter} // empty" "$f" 2>/dev/null
}

# ── _fib_split_nv "artifact-2.14.1" -> "artifact@2.14.1" ─────────────────────────
# Split a jar-style "<name>-<version>" stem at the FIRST '-<digit>' boundary
# (greedy name, so trailing '-SNAPSHOT'/'-jre' qualifiers stay with the version).
# Prints nothing if there is no version-shaped suffix.
_fib_split_nv() {
  local s="$1"
  if [[ "$s" =~ ^(.+)-([0-9][A-Za-z0-9._-]*)$ ]]; then
    printf '%s@%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# ── _fib_tree_components DIR -> stdout ("name@version" lines) ────────────────────
# Best-effort component set derived from the ACTUAL on-disk tree, INDEPENDENT of the
# attacker-authored SBOM. This is the anti-omission corroboration for gate [d]: a
# hostile mesh that VENDORS a CRITICAL dependency but omits/misdeclares it in its own
# .snapdragon-sbom.json is still caught, because the floor is matched against
# (SBOM ∪ THIS). Sources, all offline & parser-light:
#   • vendored *.jar  filenames  (maven: <artifactId>-<version>.jar)
#   • vendored *.whl / *.egg     filenames  (PEP 427: <name>-<version>-...)
#   • package-lock.json          (npm v1 .dependencies + v2/v3 .packages, recursive)
#   • requirements*.txt          (pip pinned "name==version")
# Never fails the gate on its own error (best-effort discovery); any component it DOES
# find that hits the floor is a hard reject in [d]. The DoS caps already bound the
# tree, so these walks are bounded.
_fib_tree_components() {
  local dir="$1" f stem
  [ -d "$dir" ] || return 0
  # (1) vendored jar/whl/egg artifacts by filename
  while IFS= read -r -d '' f; do
    case "$f" in
      *.jar)          stem="$(basename "$f" .jar)"; _fib_split_nv "$stem" ;;
      *.whl|*.egg)    stem="$(basename "$f")"; stem="${stem%.*}"
                      # PEP 427/egg: name-version-<rest>; version is field 2. Emit the
                      # raw name AND its PEP-503 canonical form (lowercase, [-_.]+ -> -)
                      # so a wheel's '_'-normalised name still matches a hyphenated floor.
                      printf '%s\n' "$stem" | awk -F- 'NF>=2 && $2 ~ /^[0-9]/ {
                        raw=$1; can=tolower(raw); gsub(/[._-]+/,"-",can)
                        print raw"@"$2; if (can!=raw) print can"@"$2 }' ;;
    esac
  done < <(find "$dir" -type f \( -name '*.jar' -o -name '*.whl' -o -name '*.egg' \) -print0 2>/dev/null)
  # (2) npm package-lock.json — v2/v3 .packages AND v1 recursive .dependencies
  while IFS= read -r -d '' f; do
    jq -r '
      def walkdeps:
        to_entries[] | select(.value|type=="object")
        | (if (.value.version // "") != "" and (.key|length) > 0
             then (.key + "@" + .value.version) else empty end),
          ((.value.dependencies // {}) | walkdeps);
      [ ((.packages // {}) | to_entries[]
           | select((.value.version // "") != "")
           | ((.key | sub("^.*node_modules/";"")) as $n
              | select(($n|length) > 0) | ($n + "@" + .value.version))),
        ((.dependencies // {}) | walkdeps) ]
      | .[]' "$f" 2>/dev/null
  done < <(find "$dir" -type f -name 'package-lock.json' -print0 2>/dev/null)
  # (3) pip requirements*.txt — pinned exact versions only ("name==version")
  while IFS= read -r -d '' f; do
    awk -F'==' '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*[A-Za-z0-9._-]+==/ {
        n=$1; gsub(/[[:space:]]/,"",n)
        split($2, a, /[ \t;#\[]/); v=a[1]
        if (v != "") print n"@"v
      }' "$f" 2>/dev/null
  done < <(find "$dir" -type f -name 'requirements*.txt' -print0 2>/dev/null)
}

# ── ingest_foreign_base (the gate) ──────────────────────────────────────────────
# Args parsed from "$@". Emits the admitted snapshot path on stdout on full pass.
ingest_foreign_base() {
  local BASE="" MESH_ID="" PINNED="" TRUST="" QUAR="" MIN_GEN="0" ADVISORY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)           BASE="$2"; shift 2 ;;
      --mesh-id)        MESH_ID="$2"; shift 2 ;;
      --pinned-digest)  PINNED="$2"; shift 2 ;;
      --trust-store)    TRUST="$2"; shift 2 ;;
      --quarantine)     QUAR="$2"; shift 2 ;;
      --min-generation) MIN_GEN="$2"; shift 2 ;;
      --advisory-floor) ADVISORY="$2"; shift 2 ;;
      *) _fib_die "unknown argument: $1"; return 1 ;;
    esac
  done
  ADVISORY="${ADVISORY:-${FIB_ADVISORY_FLOOR_DEFAULT}}"

  # ── arg validation (fail-closed) ─────────────────────────────────────────────
  [ -n "$BASE" ] && [ -d "$BASE" ]     || { _fib_die "--base must be an existing directory"; return 1; }
  [ -n "$MESH_ID" ]                    || { _fib_die "--mesh-id required"; return 1; }
  # mesh-id is a strict DNS label so TRUST/<mesh-id> can never traverse.
  [[ "$MESH_ID" =~ $_FIB_DNS_LABEL ]]  || { _fib_die "--mesh-id '${MESH_ID}' is not a DNS label (path-safety + trust-key selection)"; return 1; }
  [ -n "$TRUST" ] && [ -d "$TRUST" ]   || { _fib_die "--trust-store must be an existing directory (no trust store => no admission)"; return 1; }
  [ -n "$QUAR" ]                       || { _fib_die "--quarantine required"; return 1; }
  case "$MIN_GEN" in ''|*[!0-9]*) _fib_die "--min-generation must be a non-negative integer"; return 1 ;; esac

  # [a-pre] DIGEST PIN — the request MUST pin an IMMUTABLE digest, not a moving ref.
  case "$PINNED" in
    '' ) _fib_die "--pinned-digest required (an immutable commit SHA; a foreign base is NEVER admitted by a moving ref)"; return 1 ;;
    main|master|HEAD|latest|dev|develop|trunk )
         _fib_die "--pinned-digest '${PINNED}' is a MUTABLE ref — refuse (pin to a commit SHA / signed tag digest)"; return 1 ;;
  esac
  if ! [[ "$PINNED" =~ ^[0-9a-f]{40}$ || "$PINNED" =~ ^[0-9a-f]{64}$ ]]; then
    _fib_die "--pinned-digest '${PINNED}' is not a 40/64-hex immutable digest"; return 1
  fi

  _fib_have find || { _fib_die "find not found"; return 1; }
  _fib_have jq   || { _fib_die "jq not found (SBOM/manifest parse) — fail-closed"; return 1; }

  # ── [DoS] pre-flight caps on the SOURCE, BEFORE any copy ─────────────────────
  local nfiles
  # head bounds find via SIGPIPE so a 10M-entry tree cannot be fully walked.
  nfiles="$(find "$BASE" -mindepth 1 2>/dev/null | head -n "$((FIB_MAX_FILES + 1))" | wc -l | tr -d ' ')"
  if [ "$nfiles" -gt "$FIB_MAX_FILES" ]; then
    _fib_die "source tree has > ${FIB_MAX_FILES} entries (DoS/zip-bomb guard)"; return 1
  fi
  local nbytes
  nbytes="$(du -sb "$BASE" 2>/dev/null | awk '{print $1+0}')"
  if [ -n "$nbytes" ] && [ "$nbytes" -gt "$FIB_MAX_BYTES" ]; then
    _fib_die "source tree is ${nbytes} bytes > ${FIB_MAX_BYTES} (DoS guard)"; return 1
  fi
  local maxdepth
  maxdepth="$(cd "$BASE" && find . -type f 2>/dev/null | awk -F/ 'NF>m{m=NF} END{print m+0}')"
  if [ "$maxdepth" -gt "$FIB_MAX_DEPTH" ]; then
    _fib_die "source tree nests ${maxdepth} levels > ${FIB_MAX_DEPTH} (deep-nest DoS guard)"; return 1
  fi

  # ── [SNAP] snapshot into a private per-run quarantine (closes TOCTOU) ─────────
  # Build under .building/<tag>; only a fully-passed tree is mv'd to the admit path,
  # so a half-verified tree is never observable at the returned path.
  mkdir -p "${QUAR}/.building" 2>/dev/null || { _fib_die "cannot create quarantine ${QUAR}"; return 1; }
  local tag="${MESH_ID}-${PINNED:0:16}"
  local build="${QUAR}/.building/${tag}"
  local admit="${QUAR}/${tag}"
  rm -rf "$build" "$admit" 2>/dev/null || true
  mkdir -p "$build" || { _fib_die "cannot create build dir"; return 1; }
  # Realpath-contain the build + admit dirs strictly under the quarantine root.
  local q_abs b_abs a_abs
  q_abs="$(realpath -m -- "$QUAR" 2>/dev/null)" || { _fib_die "quarantine realpath failed"; rm -rf "$build"; return 1; }
  b_abs="$(realpath -m -- "$build" 2>/dev/null)"
  a_abs="$(realpath -m -- "$admit" 2>/dev/null)"
  case "${b_abs}/" in "${q_abs}"/*) : ;; *) _fib_die "build dir escapes quarantine"; rm -rf "$build"; return 1 ;; esac
  case "${a_abs}/" in "${q_abs}"/*) : ;; *) _fib_die "admit dir escapes quarantine"; rm -rf "$build"; return 1 ;; esac
  # cp -a preserves symlinks AS symlinks (so containment can inspect them) and does
  # NOT dereference — a symlink is never followed during the copy.
  if ! cp -a "${BASE}/." "${build}/" 2>/dev/null; then
    _fib_die "snapshot copy failed"; rm -rf "$build"; return 1
  fi
  # From here on, purge-on-any-failure.
  _fib_reject() { _fib_die "$1"; rm -rf "$build" "$admit" 2>/dev/null; return 1; }

  # ── [g] CONTAINMENT (hoisted) — no escaping/abs symlinks, no traversal, no hardlinks ─
  local l ltar
  while IFS= read -r -d '' l; do
    ltar="$(readlink "$l" 2>/dev/null)"
    case "$ltar" in
      /*)   _fib_reject "absolute-target symlink in foreign tree: ${l#$build/} -> ${ltar}"; return 1 ;;
      *..*) _fib_reject "'..' traversal symlink in foreign tree: ${l#$build/} -> ${ltar}"; return 1 ;;
    esac
    # Escaping check: resolve the target relative to the link's own directory and
    # require it stays strictly under the snapshot root.
    local ldir tabs
    ldir="$(dirname "$l")"
    tabs="$(realpath -m -- "${ldir}/${ltar}" 2>/dev/null)"
    case "${tabs}/" in "${b_abs}"/*) : ;; *) _fib_reject "escaping symlink in foreign tree: ${l#$build/} -> ${ltar}"; return 1 ;; esac
  done < <(find "$build" -type l -print0 2>/dev/null)
  # Hardlinks (regular files with link count > 1) — reject defensively.
  if find "$build" -type f -links +1 2>/dev/null | head -n1 | grep -q .; then
    _fib_reject "hardlink(s) present in foreign tree — refusing"; return 1
  fi

  # ── [a] DIGEST PIN — bind the SIGNED manifest to the actual tree bytes ────────
  local manifest="${build}/${FIB_MANIFEST}"
  [ -f "$manifest" ] || { _fib_reject "no ${FIB_MANIFEST} in foreign base (unsigned/unattested)"; return 1; }
  [ -f "${build}/${FIB_SIG}" ] || { _fib_reject "no ${FIB_SIG} detached signature in foreign base"; return 1; }
  local m_commit m_mesh m_tree m_gen
  m_commit="$(_fib_jq_str "$manifest" '.base.commitSha')"
  m_mesh="$(_fib_jq_str "$manifest" '.base.meshId')"
  m_tree="$(_fib_jq_str "$manifest" '.base.treeSha256')"
  m_gen="$(_fib_jq_str "$manifest" '.base.generation')"
  [ -n "$m_commit" ] || { _fib_reject "manifest missing base.commitSha"; return 1; }
  [ -n "$m_mesh" ]   || { _fib_reject "manifest missing base.meshId (origin binding)"; return 1; }
  [ -n "$m_tree" ]   || { _fib_reject "manifest missing base.treeSha256 (tree->manifest binding)"; return 1; }
  [ "$m_commit" = "$PINNED" ]  || { _fib_reject "manifest base.commitSha (${m_commit}) != pinned digest (${PINNED}) — digest swap"; return 1; }
  [ "$m_mesh" = "$MESH_ID" ]   || { _fib_reject "manifest base.meshId (${m_mesh}) != declared mesh (${MESH_ID}) — cross-mesh replay"; return 1; }
  local recomputed
  recomputed="$(_fib_tree_digest "$build")" || { _fib_reject "tree digest computation failed"; return 1; }
  [ -n "$recomputed" ] || { _fib_reject "empty tree digest"; return 1; }
  [ "$recomputed" = "$m_tree" ] || { _fib_reject "recomputed tree digest (${recomputed}) != manifest base.treeSha256 (${m_tree}) — tampered-after-sign"; return 1; }

  # ── [b] PROVENANCE / SIGNATURE against the PINNED trust-store pubkey (no TOFU) ─
  local trustkey="${TRUST}/${MESH_ID}/foreign-provenance-pub.ed25519"
  [ -f "$trustkey" ] || { _fib_reject "no pinned pubkey for mesh '${MESH_ID}' at ${trustkey} — UNKNOWN mesh, fail-closed (no trust-on-first-use)"; return 1; }
  _fib_have openssl || { _fib_reject "openssl not found"; return 1; }
  _fib_have base64  || { _fib_reject "base64 not found"; return 1; }
  local pub_pem="${build%/}/../.trustpub-${tag}.pem"
  # Reconstruct the PEM from base64 SPKI DER (registry-verify.sh:109-110 idiom) AND
  # validate it is an Ed25519 PUBLIC key — openssl -pubin REJECTS a private key, so
  # a mistaken/hostile private key in the store can never be used (pubkeys-only,
  # gen-provision-keys.sh validate_registry_pub parity).
  if ! base64 -d "$trustkey" 2>/dev/null | openssl pkey -pubin -inform DER -out "$pub_pem" 2>/dev/null; then
    rm -f "$pub_pem" 2>/dev/null
    _fib_reject "trust-store key for '${MESH_ID}' is not base64 SPKI DER of an Ed25519 PUBLIC key (placeholder/private/garbage) — fail-closed"; return 1
  fi
  if ! openssl pkey -pubin -in "$pub_pem" -noout -text 2>/dev/null | grep -qi 'ED25519'; then
    rm -f "$pub_pem" 2>/dev/null
    _fib_reject "trust-store key for '${MESH_ID}' is not Ed25519 — fail-closed"; return 1
  fi
  if ! bash "$FIB_PROVENANCE" verify --repo-dir "$build" --pub "$pub_pem" >/dev/null 2>&1; then
    rm -f "$pub_pem" 2>/dev/null
    _fib_reject "provenance signature does NOT verify against the pinned '${MESH_ID}' key — unsigned/tampered/foreign-key"; return 1
  fi
  rm -f "$pub_pem" 2>/dev/null
  # REPLAY floor: a genuinely-signed but rolled-back/known-vuln base is rejected.
  case "$m_gen" in ''|*[!0-9]*) _fib_reject "manifest base.generation missing/non-numeric — replay floor cannot be enforced"; return 1 ;; esac
  if [ "$m_gen" -lt "$MIN_GEN" ]; then
    _fib_reject "manifest generation ${m_gen} < min-generation floor ${MIN_GEN} — replay of an old/known-vuln base"; return 1
  fi

  # ── [c] SBOM — present, parseable, non-empty ─────────────────────────────────
  local sbom="${build}/${FIB_SBOM}"
  [ -f "$sbom" ] || { _fib_reject "no ${FIB_SBOM} in foreign base (SBOM required)"; return 1; }
  jq -e . "$sbom" >/dev/null 2>&1 || { _fib_reject "${FIB_SBOM} is not valid JSON (malformed)"; return 1; }
  # Accept CycloneDX (.components[]) or SPDX (.packages[]); each entry needs name+version.
  local ncomp
  ncomp="$(jq -r '[(.components // .packages // [])[] | select((.name!=null) and ((.version // .versionInfo)!=null))] | length' "$sbom" 2>/dev/null || echo 0)"
  case "$ncomp" in ''|*[!0-9]*) ncomp=0 ;; esac
  if [ "$ncomp" -lt 1 ]; then
    _fib_reject "${FIB_SBOM} declares zero well-formed components (name+version) — malformed/empty"; return 1
  fi

  # ── [d] VULN — components vs the PINNED OFFLINE advisory floor ────────────────
  [ -f "$ADVISORY" ] || { _fib_reject "advisory floor ${ADVISORY} absent — cannot prove no-CRITICAL, fail-closed"; return 1; }
  # Floor lines: "name version SEVERITY [id]" ; '#'/blank ignored. CRITICAL rows
  # form the denied name@version set.
  #
  # The component set matched against the floor is the UNION of two sources so a
  # hostile-but-signed mesh cannot slip a known-CRITICAL dependency past this gate by
  # simply lying in the SBOM it authored:
  #   • the self-attested SBOM (.components[]/.packages[]) — each entry ALSO normalised
  #     by stripping a group/purl prefix ("group:artifact" / ".../artifact" -> artifact)
  #     so a version-honest-but-name-shifted misdeclaration still matches the floor;
  #   • _fib_tree_components — the ACTUAL vendored jars/wheels + npm/pip lockfiles on
  #     disk, INDEPENDENT of the SBOM, so an OMITTED or MISVERSIONED dependency that is
  #     really present in the tree is caught.
  # HONEST SCOPE: this corroborates the SBOM against vendored artifacts + lockfiles; a
  # vulnerability compiled straight from in-tree SOURCE (no jar/wheel, no lockfile row)
  # is still only caught by the LIVE vuln DB (Trivy) DEFERRED to the cluster.
  local comp_list crit
  comp_list="$( {
      jq -r '(.components // .packages // [])[]
             | (.version // .versionInfo) as $v | select($v != null)
             | (.name + "@" + $v),
               ((.name | sub("^.*[:/]";"")) + "@" + $v)' "$sbom" 2>/dev/null
      _fib_tree_components "$build"
    } | LC_ALL=C sort -u )"
  crit=""
  while IFS= read -r fl; do
    case "$fl" in ''|\#*) continue ;; esac
    local fname fver fsev
    fname="$(printf '%s\n' "$fl" | awk '{print $1}')"
    fver="$(printf '%s\n' "$fl" | awk '{print $2}')"
    fsev="$(printf '%s\n' "$fl" | awk '{print toupper($3)}')"
    [ "$fsev" = "CRITICAL" ] || continue
    if printf '%s\n' "$comp_list" | grep -qxF "${fname}@${fver}"; then
      crit="${fname}@${fver}"
      break
    fi
  done < "$ADVISORY"
  if [ -n "$crit" ]; then
    _fib_reject "SBOM component ${crit} matches a CRITICAL advisory-floor entry — fail-closed"; return 1
  fi

  # ── [e] SECRET SCAN — WHOLE tree, NO excludes (foreign source is NOT trusted) ─
  [ -r "$FIB_SECRET_SCAN" ] || { _fib_reject "secret-scan.sh missing at ${FIB_SECRET_SCAN} — fail-closed (no unscanned admit)"; return 1; }
  if ! bash "$FIB_SECRET_SCAN" "$build" >/dev/null 2>&1; then
    _fib_reject "secret-scan flagged the foreign tree (smuggled credential/backdoor token)"; return 1
  fi

  # ── [f] FROZEN / DENYLIST ────────────────────────────────────────────────────
  # (f.1) node token-classifier screens the DECLARED origin identity (mesh-id + the
  #       manifest tenant fields) — reuse of the same isDenied/isFrozen predicates
  #       the render path uses. node-optional: skipped only if node is genuinely
  #       absent (the tree grep below is the node-free backstop).
  if _fib_have node && [ -r "$FIB_TOKEN_CLASSIFIER" ]; then
    local m_brand m_org
    m_brand="$(_fib_jq_str "$manifest" '.tenant.brand')"
    m_org="$(_fib_jq_str "$manifest" '.tenant.org')"
    if ! FIB_MESH="$MESH_ID" FIB_BRAND="$m_brand" FIB_ORG="$m_org" \
         node -e '
           const c = require(process.argv[1]);
           for (const v of [process.env.FIB_MESH, process.env.FIB_BRAND, process.env.FIB_ORG]) {
             if (!v) continue;
             if (c.isDenied(v) || c.isFrozen(v)) { console.error("frozen/denied origin field:", v); process.exit(1); }
           }
           process.exit(0);
         ' "$FIB_TOKEN_CLASSIFIER" 2>/dev/null; then
      _fib_reject "a declared origin field (mesh-id/brand/org) is a frozen/denylisted constant"; return 1
    fi
  fi
  # (f.2) node-free frozen-constant grep over the foreign CODE tree (excludes the
  #       ROOT-LEVEL attestation envelope ONLY, whose schema legitimately uses
  #       snapdragon.systems/ — exact-path -vxF match, so a file merely NAMED like
  #       the envelope in a SUBDIR is ordinary foreign code and IS screened).
  #       Foreign code must NOT carry OUR wire/label protocol identity — that is
  #       impersonation / a laundering vector. Frozen set is sourced from tokens.json.
  #       FORCE-TEXT (-a, NOT -I): -I would treat any file with an early NUL byte as
  #       "binary" and skip it, so a single embedded NUL would HIDE a frozen constant
  #       from this anti-laundering screen (an admitted impersonation vector). -a scans
  #       every byte; a spurious match on a truly-binary blob only ever fails CLOSED.
  local frozen_terms
  frozen_terms="$(jq -r '
      ((.frozen_protocol_constants.label_key_namespaces // [])
       + (.frozen_protocol_constants.wire_headers // [])
       + (.frozen_protocol_constants.subprotocol_prefixes // []))[]' \
      "$FIB_TOKENS_JSON" 2>/dev/null)"
  if [ -n "$frozen_terms" ]; then
    local term hit
    while IFS= read -r term; do
      [ -n "$term" ] || continue
      hit="$(grep -ralF -- "$term" "$build" 2>/dev/null \
              | grep -vxF -e "${build}/${FIB_MANIFEST}" -e "${build}/${FIB_SIG}" -e "${build}/${FIB_SBOM}" \
              | head -n1)"
      if [ -n "$hit" ]; then
        _fib_reject "foreign code carries OUR frozen protocol constant '${term}' (${hit#$build/}) — impersonation/laundering"; return 1
      fi
    done <<< "$frozen_terms"
  fi

  # ── ADMIT — atomic promote of the fully-passed snapshot ──────────────────────
  # Drop gate markers, then atomically mv .building/<tag> -> <tag>. The markers let
  # render-repo-tree detect an already-admitted base (avoid double-gating) and are
  # stripped from the overlay copy.
  printf '%s\n' "$MESH_ID" > "${build}/${FIB_FOREIGN_MARK}"
  {
    printf 'mesh-id=%s\n' "$MESH_ID"
    printf 'pinned-digest=%s\n' "$PINNED"
    printf 'tree-sha256=%s\n' "$recomputed"
    printf 'generation=%s\n' "$m_gen"
    printf 'verified=1\n'
  } > "${build}/${FIB_ADMIT_STAMP}"
  rm -rf "$admit" 2>/dev/null || true
  if ! mv -f "$build" "$admit" 2>/dev/null; then
    _fib_reject "atomic admit mv failed"; return 1
  fi
  _fib_log "ADMIT mesh=${MESH_ID} digest=${PINNED} gen=${m_gen} -> ${admit}"
  printf '%s\n' "$admit"
  return 0
}

# ── main (guarded so the fuzz suite can source the functions) ────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ingest_foreign_base "$@"
  exit $?
fi
