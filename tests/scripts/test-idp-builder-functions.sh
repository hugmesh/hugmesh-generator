#!/usr/bin/env bash
# test-idp-builder-functions.sh — function-level regression for the mesh-node IdP
# external-mode builder passes (I6.3). The x86/rpi5 builders' idp functions are
# small + dependency-light on purpose so this test can EXTRACT the REAL functions
# from the builder and run them against a FIXTURE sysroot — never a real build.
#
# Extracts and exercises the actual code (so the test tracks the builder, not a
# copy): _validate_idp, _idp_default_jwks, bake_idp_conf, rewrite_idp_sysroot,
# gate_casdoor_apps, write_idp_readme, apply_idp_external (+ the real
# _sed_rep_escape the rewrite depends on). Asserts:
#   * casdoor default = BYTE-IDENTITY: apply_idp_external touches nothing; a
#     fixture tree is bit-for-bit unchanged; _validate_idp returns 0 under set -e.
#   * _validate_idp fail-closed: unknown idp, external-no-issuer, external-no-
#     client, http:// issuer, casdoor+stray-issuer all exit nonzero.
#   * _idp_default_jwks: entra -> /discovery/v2.0/keys, aws -> /.well-known/jwks.json,
#     oidc -> /.well-known/jwks.
#   * external apply: idp.conf baked 0644 with the public fields + NO secret;
#     issuer + JWKS pins rewritten (incl. the @@CLUSTER_DOMAIN@@ template form —
#     the F4 half-rewrite regression); Casdoor apps/manifests gated out;
#     README-IDP.md dropped with the honest-limits text.
#
#
# ALSO IN THIS FILE (2026-09-04, issue #224 follow-up). The name says "idp"; the
# scope is now the mesh-node CONF-BAKE passes in these two builders, IdP and Vault
# alike, plus the call sites of both. Two additions, and they are here rather than in
# a new suite because a new suite would move test-guard-integrity.sh's
# PREMERGE_BASELINE and this file is already gated by shell-suites.yml and
# .gitlab-ci.yml:
#   * CALL SITES. Everything above extracts a function and invokes it itself, which
#     says nothing about whether the builder ever runs it. Deleting the one-line
#     `bake_vault_conf` / `_validate_vault` calls left every gate in the repo green.
#     Both vault calls and both idp calls are now pinned, with negative controls on
#     the matcher.
#   * VAULT. _validate_vault + bake_vault_conf against a fixture sysroot (empty
#     address = byte no-op; fail-closed table; 0644 vault.conf with the address,
#     mount and base path and NO token/unseal field; client role = warn-drop; the
#     ${BRAND} base-path DEFAULT is validated too) — and the OTHER END of the
#     contract: keys-provision's real vault_conf_get / resolve_vault_source read the
#     baked file back, prove it is read and not sourced, and prove the reader trims
#     the ends rather than stripping the interior.
#
# Runs ANYWHERE with bash — NO cross-build, NO root, NO network.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# Extract a shell function body verbatim from a builder (the frite test's idiom).
extract_fn() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }

# Harmless stubs for the builder helpers the idp functions call.
info() { :; }
warn() { :; }
err()  { echo "ERR: $*" >&2; }
banner() { :; }

for BUILDER in build-x86-host-stage4.sh build-rpi5-stage4.sh; do
  echo "== ${BUILDER}: idp builder functions =="
  B="${REPO}/${BUILDER}"
  [ -f "${B}" ] || { bad "${BUILDER} missing"; continue; }

  # Load the REAL functions into a subshell-free scope for this builder.
  # unset + a parse check for the same reason the vault block below states: the two
  # builders share one shell, so a definition that fails to load leaves the PREVIOUS
  # builder's copy in scope and the iteration silently re-tests it.
  unset -f _sed_rep_escape _validate_idp _idp_default_jwks \
           bake_idp_conf rewrite_idp_sysroot gate_casdoor_apps \
           write_idp_readme apply_idp_external
  for fn in _sed_rep_escape _validate_idp _idp_default_jwks \
            bake_idp_conf rewrite_idp_sysroot gate_casdoor_apps \
            write_idp_readme apply_idp_external; do
    src="$(extract_fn "${fn}" "${B}")"
    [ -n "${src}" ] || { bad "${BUILDER}: could not extract ${fn}"; continue 2; }
    eval "${src}" 2>/dev/null \
      || { bad "${BUILDER}: ${fn} does not PARSE (the extracted body is not a valid function)"; continue 2; }
  done
  type apply_idp_external >/dev/null 2>&1 || { bad "${BUILDER}: apply_idp_external not loaded"; continue; }

  CLUSTER_DOMAIN="acme.example"

  # ── casdoor default: BYTE-IDENTITY ──────────────────────────────────────────
  IDP=casdoor IDP_ISSUER="" IDP_CLIENT_ID="" IDP_JWKS=""
  ( set -e; _validate_idp ) && ok "${BUILDER}: _validate_idp(casdoor) returns 0 under set -e" \
    || bad "${BUILDER}: _validate_idp(casdoor) failed under set -e"

  SYSROOT="$(mktemp -d)"
  mkdir -p "${SYSROOT}/var/lib/hugmesh/cluster/apps" "${SYSROOT}/etc/hugmesh"
  printf 'issuer https://id.acme.example\njwks http://casdoor.hugmesh-pki.svc.cluster.local:8000/.well-known/jwks\n' \
      > "${SYSROOT}/var/lib/hugmesh/cluster/apps/gw.yaml"
  : > "${SYSROOT}/var/lib/hugmesh/cluster/apps/05-casdoor.yaml"
  before="$(find "${SYSROOT}" -type f | sort | xargs sha256sum 2>/dev/null)"
  apply_idp_external
  after="$(find "${SYSROOT}" -type f | sort | xargs sha256sum 2>/dev/null)"
  [ "${before}" = "${after}" ] && ok "${BUILDER}: apply_idp_external(casdoor) is a byte no-op" \
    || bad "${BUILDER}: apply_idp_external(casdoor) MUTATED the tree"
  [ -e "${SYSROOT}/etc/hugmesh/idp.conf" ] && bad "${BUILDER}: casdoor baked an idp.conf" \
    || ok "${BUILDER}: casdoor baked NO idp.conf"
  rm -rf "${SYSROOT}"

  # ── _validate_idp fail-closed table ─────────────────────────────────────────
  vfail() { # label  IDP ISSUER CLIENT JWKS
    IDP="$2" IDP_ISSUER="$3" IDP_CLIENT_ID="$4" IDP_JWKS="$5"
    if ( _validate_idp ) 2>/dev/null; then bad "${BUILDER}: $1 was ACCEPTED (want reject)"
    else ok "${BUILDER}: rejects $1"; fi
  }
  vfail "unknown idp"          bogus ""                      ""      ""
  vfail "external no-issuer"   entra ""                      client  ""
  vfail "external no-client"   entra "https://iss.example"   ""      ""
  vfail "external http issuer" entra "http://insecure.ex"    client  ""
  vfail "casdoor+stray issuer" casdoor "https://iss.example" ""      ""

  # ── _idp_default_jwks per-provider derivation ───────────────────────────────
  IDP=entra IDP_ISSUER="https://login.microsoftonline.com/t/v2.0"
  [ "$(_idp_default_jwks)" = "https://login.microsoftonline.com/t/v2.0/discovery/v2.0/keys" ] \
    && ok "${BUILDER}: entra JWKS -> /discovery/v2.0/keys" || bad "${BUILDER}: entra JWKS wrong ($(_idp_default_jwks))"
  IDP=aws IDP_ISSUER="https://cognito-idp.us-east-1.amazonaws.com/pool"
  [ "$(_idp_default_jwks)" = "https://cognito-idp.us-east-1.amazonaws.com/pool/.well-known/jwks.json" ] \
    && ok "${BUILDER}: aws JWKS -> /.well-known/jwks.json" || bad "${BUILDER}: aws JWKS wrong"
  IDP=oidc IDP_ISSUER="https://oidc.example/"
  [ "$(_idp_default_jwks)" = "https://oidc.example/.well-known/jwks" ] \
    && ok "${BUILDER}: oidc JWKS -> /.well-known/jwks (trailing slash trimmed)" || bad "${BUILDER}: oidc JWKS wrong"

  # ── external apply: bake + rewrite + gate + readme ──────────────────────────
  IDP=entra
  IDP_ISSUER="https://login.microsoftonline.com/t/v2.0"
  IDP_CLIENT_ID="app-mesh"
  IDP_JWKS="https://login.microsoftonline.com/t/v2.0/discovery/v2.0/keys"
  SYSROOT="$(mktemp -d)"
  tree="${SYSROOT}/var/lib/hugmesh/cluster"
  mkdir -p "${tree}/apps" "${tree}/manifests/casdoor" "${SYSROOT}/etc/hugmesh"
  # concrete-domain issuer + in-cluster jwks:
  printf 'issuer: https://id.acme.example\njwks: http://casdoor.hugmesh-pki.svc.cluster.local:8000/.well-known/jwks\n' \
      > "${tree}/apps/gw.yaml"
  # concrete-domain jwks pin (must NOT half-rewrite):
  printf 'jwks: https://id.acme.example/.well-known/jwks\n' > "${tree}/apps/jwks.yaml"
  # the @@CLUSTER_DOMAIN@@ TEMPLATE form incl. a jwks URL (the F4 regression):
  printf 'oidc_issuer = https://id.@@CLUSTER_DOMAIN@@/\noidc_jwks = https://id.@@CLUSTER_DOMAIN@@/.well-known/jwks\n' \
      > "${tree}/apps/tmpl.conf"
  : > "${tree}/apps/05-casdoor.yaml"; : > "${tree}/apps/06-casdoor-games.yaml"

  apply_idp_external

  ic="${SYSROOT}/etc/hugmesh/idp.conf"
  [ -f "${ic}" ] && ok "${BUILDER}: external baked idp.conf" || bad "${BUILDER}: no idp.conf baked"
  [ "$(stat -c '%a' "${ic}" 2>/dev/null)" = "644" ] && ok "${BUILDER}: idp.conf is 0644" || bad "${BUILDER}: idp.conf not 0644"
  grep -q "^provider=entra$" "${ic}" && grep -q "^client_id=app-mesh$" "${ic}" \
    && ok "${BUILDER}: idp.conf carries provider+client_id" || bad "${BUILDER}: idp.conf fields wrong"
  # No secret VALUE: reject an actual client_secret/secret= field (the file's
  # comment legitimately says "client SECRETS ... never here", so match the field,
  # not the word).
  grep -qiE '^[[:space:]]*(client_)?secret[[:space:]]*[=:]' "${ic}" \
    && bad "${BUILDER}: idp.conf carries a secret field" || ok "${BUILDER}: idp.conf has NO secret field"

  grep -q "https://login.microsoftonline.com/t/v2.0/discovery/v2.0/keys" "${tree}/apps/gw.yaml" \
    && ok "${BUILDER}: in-cluster JWKS pin rewritten to the external JWKS" || bad "${BUILDER}: gw jwks not rewritten"
  grep -q "issuer: https://login.microsoftonline.com/t/v2.0$" "${tree}/apps/gw.yaml" \
    && ok "${BUILDER}: concrete-domain issuer rewritten" || bad "${BUILDER}: gw issuer not rewritten"
  # concrete-domain jwks must be the JWKS, NOT the issuer (no half-rewrite):
  grep -q "jwks: https://login.microsoftonline.com/t/v2.0/discovery/v2.0/keys$" "${tree}/apps/jwks.yaml" \
    && ok "${BUILDER}: concrete jwks pin -> external JWKS (not half-rewritten to issuer)" || bad "${BUILDER}: concrete jwks half-rewritten"
  # F4: the @@CLUSTER_DOMAIN@@ template jwks must land on the JWKS, not <issuer>/.well-known/jwks:
  grep -q "oidc_jwks = https://login.microsoftonline.com/t/v2.0/discovery/v2.0/keys$" "${tree}/apps/tmpl.conf" \
    && ok "${BUILDER}: @@CLUSTER_DOMAIN@@ template JWKS -> external JWKS (F4 fixed)" \
    || { bad "${BUILDER}: template JWKS half-rewritten (F4)"; grep oidc_jwks "${tree}/apps/tmpl.conf"; }
  grep -q "oidc_issuer = https://login.microsoftonline.com/t/v2.0/$" "${tree}/apps/tmpl.conf" \
    && ok "${BUILDER}: @@CLUSTER_DOMAIN@@ template issuer rewritten" || bad "${BUILDER}: template issuer not rewritten"

  [ ! -e "${tree}/apps/05-casdoor.yaml" ] && [ ! -e "${tree}/apps/06-casdoor-games.yaml" ] && [ ! -d "${tree}/manifests/casdoor" ] \
    && ok "${BUILDER}: Casdoor apps + manifests gated out" || bad "${BUILDER}: Casdoor tree NOT gated out"

  rm="${SYSROOT}/etc/hugmesh/README-IDP.md"
  [ -f "${rm}" ] && grep -qi 'does NOT work' "${rm}" && grep -qi '/bff/login' "${rm}" \
    && ok "${BUILDER}: README-IDP.md dropped with the honest-limits text" || bad "${BUILDER}: README-IDP.md missing/incomplete"
  rm -rf "${SYSROOT}"
done

# ══ CALL SITES: the builder must actually INVOKE what it defines ═══════════════
# WHY THIS BLOCK EXISTS. Everything above EXTRACTS a function and then invokes it
# ITSELF. That proves the function is correct and proves NOTHING about whether the
# builder ever runs it. MEASURED 2026-09-04 (adversarial review of #224): delete the
# one-line `bake_vault_conf` call from BOTH builders — and, separately, the
# `_validate_vault` line — and 578 studio pytest cases stayed green while
# tests/build-matrix/flag-coverage.sh, tests/scripts/test-eso-provider-refs.sh,
# tests/scripts/test-guard-integrity.sh and THIS suite all still exited 0. The whole
# --vault-* feature was inert with every gate in the repo green. flag-coverage.sh
# cannot close it: it proves a flag is PARSED, never that its value is CONSUMED.
#
# The identical hole existed for the idp pair, which is why both are pinned here
# rather than only the new one.
#
# A CALL is a line whose only content is the function name (a trailing comment is
# allowed). The definition line is `name() {` and cannot match; a comment line starts
# with `#` and cannot match either — verified by the negative controls below.
echo "== call sites: defined AND invoked =="
callsites() { # <name> <file> -> count of top-level call lines
  grep -cE "^[[:space:]]*$1[[:space:]]*(#.*)?$" "$2" 2>/dev/null || true
}
for BUILDER in build-x86-host-stage4.sh build-rpi5-stage4.sh; do
  B="${REPO}/${BUILDER}"
  for fn in _validate_idp apply_idp_external _validate_vault bake_vault_conf; do
    grep -qE "^${fn}\(\) \{" "${B}" || { bad "${BUILDER}: ${fn} is not even DEFINED"; continue; }
    n="$(callsites "${fn}" "${B}")"
    if [ "${n}" -ge 1 ]; then ok "${BUILDER}: ${fn} is invoked (${n} call site(s))"
    else bad "${BUILDER}: ${fn} is DEFINED BUT NEVER CALLED — the pass is inert"; fi
  done
done
# Negative controls for the matcher itself: a name that only ever appears as a
# definition, a comment or a substring must count ZERO, or the four checks above
# would pass on any builder at all.
NEG="$(mktemp)"
printf 'zzz_never_called() {\n    :\n}\n# zzz_never_called is only mentioned here\necho zzz_never_called_suffix\n' > "${NEG}"
[ "$(callsites zzz_never_called "${NEG}")" = "0" ] \
  && ok "call-site matcher: a defined-but-uncalled function counts 0 (def/comment/substring are not calls)" \
  || bad "call-site matcher: counted a non-call as a call"
printf 'zzz_never_called\n' >> "${NEG}"
[ "$(callsites zzz_never_called "${NEG}")" = "1" ] \
  && ok "call-site matcher: a bare call line counts 1" \
  || bad "call-site matcher: missed a bare call line"
printf '    zzz_never_called   # indented, with a trailing comment\n' >> "${NEG}"
[ "$(callsites zzz_never_called "${NEG}")" = "2" ] \
  && ok "call-site matcher: an indented call with a trailing comment counts" \
  || bad "call-site matcher: missed an indented/commented call line"
rm -f "${NEG}"

# ══ VAULT: the /etc/hugmesh/vault.conf bake, and the first-boot read-back ══════
# The sibling of the idp bake above, in the SAME two builders (issue #224), plus
# the other end of the contract: keys-provision reads back what the builder wrote.
# Both ends are extracted REAL code — no copy, no cross-build, no cluster.
for BUILDER in build-x86-host-stage4.sh build-rpi5-stage4.sh; do
  echo "== ${BUILDER}: vault builder functions =="
  B="${REPO}/${BUILDER}"
  [ -f "${B}" ] || { bad "${BUILDER} missing"; continue; }
  # The two validators are regex CONSTANTS at top level, not functions.
  eval "$(grep -m1 '^_IDP_URL_RE=' "${B}")"
  eval "$(grep -m1 '^_VAULT_PATH_RE=' "${B}")"
  # UNSET first, and fail LOUDLY on a body that does not parse. Both matter: the two
  # builders are walked in one shell, so a definition from the FIRST iteration stays
  # in scope for the second, and a `eval` that quietly failed would have re-run the
  # x86 function while claiming to test rpi5. Measured while building this block —
  # two mutations planted in the rpi5 builder "survived" for exactly that reason.
  unset -f _validate_vault bake_vault_conf
  for fn in _validate_vault bake_vault_conf; do
    src="$(extract_fn "${fn}" "${B}")"
    [ -n "${src}" ] || { bad "${BUILDER}: could not extract ${fn}"; continue 2; }
    eval "${src}" 2>/dev/null \
      || { bad "${BUILDER}: ${fn} does not PARSE (the extracted body is not a valid function)"; continue 2; }
    type -t "${fn}" >/dev/null 2>&1 \
      || { bad "${BUILDER}: ${fn} did not load"; continue 2; }
  done

  ROLE="omnibus"; ROLE_CLIENT=false; BRAND="hugmesh"
  VAULT_ADDR=""; VAULT_KV_MOUNT=""; VAULT_BASE_PATH=""
  # The EXTERNAL address (issue #335). Set explicitly rather than left unbound: the
  # function bodies default it so an OLDER harness degrades instead of dying, and a
  # harness that relied on that default would silently stop testing the flag.
  VAULT_EXTERNAL_ADDR=""

  # ── the empty address is the byte no-op default ─────────────────────────────
  SYSROOT="$(mktemp -d)"
  bake_vault_conf
  [ -e "${SYSROOT}/etc/hugmesh/vault.conf" ] \
    && bad "${BUILDER}: an empty --vault-addr baked a vault.conf" \
    || ok "${BUILDER}: empty --vault-addr bakes NOTHING (the offline default)"
  rm -rf "${SYSROOT}"

  # ── _validate_vault fail-closed table ───────────────────────────────────────
  vvfail() { # label  ADDR MOUNT BASE
    VAULT_ADDR="$2" VAULT_KV_MOUNT="$3" VAULT_BASE_PATH="$4"
    if ( _validate_vault ) 2>/dev/null; then bad "${BUILDER}: $1 was ACCEPTED (want reject)"
    else ok "${BUILDER}: rejects $1"; fi
  }
  vvfail "an http:// vault address"    "http://vault.acme.example:8200" "" ""
  vvfail "a shell-shaped KV mount"     "https://vault.acme.example:8200" 'kv$(id)' ""
  vvfail "a shell-shaped base path"    "https://vault.acme.example:8200" "" '$(rm -rf /)'
  vvfail "a base path with a space"    "https://vault.acme.example:8200" "" "acme corp"
  VAULT_ADDR="https://vault.acme.example:8200" VAULT_KV_MOUNT="kv" VAULT_BASE_PATH="acme/prod"
  ( set -e; _validate_vault ) && ok "${BUILDER}: _validate_vault accepts a valid trio under set -e" \
    || bad "${BUILDER}: _validate_vault rejected a valid trio"
  # ── the EXTERNAL address arm (#335), mirroring config.vault_field_error ──────
  vxfail() { # label  EXTERNAL
    VAULT_ADDR="https://vault.acme.example:8200" VAULT_KV_MOUNT="" VAULT_BASE_PATH="" \
      VAULT_EXTERNAL_ADDR="$2"
    if ( _validate_vault ) 2>/dev/null; then bad "${BUILDER}: $1 was ACCEPTED (want reject)"
    else ok "${BUILDER}: rejects $1"; fi
  }
  vxfail "an http:// EXTERNAL address"          "http://ext.acme.example:8200"
  vxfail "an EXTERNAL address equal to the internal one" "https://vault.acme.example:8200"
  VAULT_ADDR="https://vault.acme.example:8200" VAULT_KV_MOUNT="" VAULT_BASE_PATH="" \
    VAULT_EXTERNAL_ADDR="https://ext.acme.example:8200"
  ( set -e; _validate_vault ) \
    && ok "${BUILDER}: _validate_vault accepts a distinct https EXTERNAL address" \
    || bad "${BUILDER}: _validate_vault rejected a valid external address"
  VAULT_ADDR="" VAULT_KV_MOUNT="" VAULT_BASE_PATH="" VAULT_EXTERNAL_ADDR=""
  ( set -e; _validate_vault ) && ok "${BUILDER}: _validate_vault(empty) returns 0 under set -e" \
    || bad "${BUILDER}: _validate_vault(empty) failed under set -e"

  # ── a set address bakes CONNECTION FACTS ONLY, 0644 ─────────────────────────
  SYSROOT="$(mktemp -d)"
  VAULT_ADDR="https://vault.acme.example:8200"; VAULT_KV_MOUNT="kv"; VAULT_BASE_PATH="acme/prod"
  bake_vault_conf
  VC="${SYSROOT}/etc/hugmesh/vault.conf"
  [ -f "${VC}" ] && ok "${BUILDER}: a set address bakes vault.conf" || bad "${BUILDER}: no vault.conf baked"
  [ "$(stat -c '%a' "${VC}" 2>/dev/null)" = "644" ] && ok "${BUILDER}: vault.conf is 0644" || bad "${BUILDER}: vault.conf not 0644"
  grep -q "^VAULT_ADDR=https://vault.acme.example:8200$" "${VC}" \
    && grep -q "^VAULT_KV_MOUNT=kv$" "${VC}" && grep -q "^VAULT_BASE_PATH=acme/prod$" "${VC}" \
    && ok "${BUILDER}: vault.conf carries the address + mount + base path" \
    || { bad "${BUILDER}: vault.conf fields wrong"; cat "${VC}"; }
  # CONNECTION FACTS ONLY: no token/unseal field may ever appear (the custody rule).
  grep -qiE '^[[:space:]]*(vault_)?(token|unseal[_-]?key)[[:space:]]*[=:]' "${VC}" \
    && bad "${BUILDER}: vault.conf carries a token/unseal field" \
    || ok "${BUILDER}: vault.conf has NO token/unseal field"
  # OMIT-WHEN-EMPTY (#335): no external address => no such line AT ALL, so a build
  # that never named one writes the pre-#335 file byte for byte. An empty-valued
  # VAULT_EXTERNAL_ADDR= line is precisely the regression this rules out.
  grep -q '^VAULT_EXTERNAL_ADDR' "${VC}" \
    && bad "${BUILDER}: an unset external address still wrote a VAULT_EXTERNAL_ADDR line" \
    || ok "${BUILDER}: an unset external address writes NO line (byte-identical to pre-#335)"
  rm -rf "${SYSROOT}"

  # ── the EXTERNAL address, when set, is baked BESIDE the internal one ─────────
  SYSROOT="$(mktemp -d)"
  VAULT_EXTERNAL_ADDR="https://ext.acme.example:8200"
  bake_vault_conf
  VC="${SYSROOT}/etc/hugmesh/vault.conf"
  grep -q "^VAULT_ADDR=https://vault.acme.example:8200$" "${VC}" \
    && grep -q "^VAULT_EXTERNAL_ADDR=https://ext.acme.example:8200$" "${VC}" \
    && ok "${BUILDER}: vault.conf carries the external address beside the internal one" \
    || { bad "${BUILDER}: external address missing from vault.conf"; cat "${VC}"; }
  [ "$(stat -c '%a' "${VC}" 2>/dev/null)" = "644" ] \
    && ok "${BUILDER}: vault.conf is still 0644 with the external address" \
    || bad "${BUILDER}: vault.conf not 0644 after the external append"
  VAULT_EXTERNAL_ADDR=""

  # ── the first-boot READ-BACK, with keys-provision's own reader ──────────────
  # The other end of the contract: what the builder wrote must come back byte-for-
  # byte through the REAL vault_conf_get/resolve_vault_source. Extracted from
  # provision.sh so a change to either end that breaks the pair fails here.
  PROV="${REPO}/specs/etc/keys-provision/provision.sh"
  unset -f vault_conf_get resolve_vault_source
  for fn in vault_conf_get resolve_vault_source; do
    src="$(extract_fn "${fn}" "${PROV}")"
    [ -n "${src}" ] || { bad "provision.sh: could not extract ${fn}"; continue 2; }
    eval "${src}" 2>/dev/null \
      || { bad "provision.sh: ${fn} does not PARSE"; continue 2; }
    type -t "${fn}" >/dev/null 2>&1 || { bad "provision.sh: ${fn} did not load"; continue 2; }
  done
  jqe() { return 1; }   # no .vault block in the manifest -> the image is the source
  VAULT_IMAGE_CONF="${VC}"
  resolve_vault_source
  [ "${VAULT_SRC}" = "image" ] && ok "${BUILDER}: first boot resolves the baked file as the source" \
    || bad "${BUILDER}: VAULT_SRC='${VAULT_SRC}' (want 'image')"
  [ "${vault_address}" = "https://vault.acme.example:8200" ] && [ "${vault_kv_mount}" = "kv" ] \
    && [ "${vault_base_path}" = "acme/prod" ] && [ "${vault_enabled}" = "true" ] \
    && ok "${BUILDER}: the baked trio reads back unchanged, enabled=true" \
    || bad "${BUILDER}: read-back mismatch: '${vault_address}' '${vault_kv_mount}' '${vault_base_path}' enabled=${vault_enabled}"
  # The reader must READ the file, never SOURCE it.
  printf 'EVIL=$(touch %s/PWNED)\n' "${SYSROOT}" >> "${VC}"
  vault_conf_get VAULT_ADDR >/dev/null
  [ -e "${SYSROOT}/PWNED" ] && bad "${BUILDER}: vault.conf was SOURCED — a stray line executed" \
    || ok "${BUILDER}: vault.conf is read, not sourced (a stray line executes nothing)"
  rm -rf "${SYSROOT}"

  # ── the reader TRIMS the ends, it does not STRIP the interior ───────────────
  # `${v//[[:space:]]/}` deleted every space anywhere, so `acme corp` silently
  # became `acmecorp` — a wrong value that reads exactly like a working one.
  TDIR="$(mktemp -d)"
  printf 'VAULT_ADDR=  "https://v.example:8200"  \nVAULT_BASE_PATH=acme corp\n' > "${TDIR}/vault.conf"
  VAULT_IMAGE_CONF="${TDIR}/vault.conf"
  [ "$(vault_conf_get VAULT_ADDR)" = "https://v.example:8200" ] \
    && ok "${BUILDER}: reader trims padding and quotes off a value" \
    || bad "${BUILDER}: padded/quoted value read back as '$(vault_conf_get VAULT_ADDR)'"
  [ "$(vault_conf_get VAULT_BASE_PATH)" = "acme corp" ] \
    && ok "${BUILDER}: reader keeps an interior space verbatim (no silent join)" \
    || bad "${BUILDER}: interior space was STRIPPED: '$(vault_conf_get VAULT_BASE_PATH)'"
  rm -rf "${TDIR}"

  # ── a client role is a loud no-op, not a bake ───────────────────────────────
  SYSROOT="$(mktemp -d)"
  ROLE_CLIENT=true; ROLE="desktop"
  VAULT_ADDR="https://vault.acme.example:8200"; VAULT_KV_MOUNT=""; VAULT_BASE_PATH=""
  bake_vault_conf
  [ -e "${SYSROOT}/etc/hugmesh/vault.conf" ] \
    && bad "${BUILDER}: a client role baked a vault.conf" \
    || ok "${BUILDER}: a client role bakes NO vault.conf (warn-drop)"
  ROLE_CLIENT=false; ROLE="omnibus"
  rm -rf "${SYSROOT}"

  # ── the ${BRAND} default is validated too, not only the flags ───────────────
  # _validate_vault only ever sees the FLAGS, so the base path's DEFAULT was the
  # one value that could reach the file unchecked.
  SYSROOT="$(mktemp -d)"
  VAULT_ADDR="https://vault.acme.example:8200"; VAULT_KV_MOUNT=""; VAULT_BASE_PATH=""
  BRAND="acme corp"
  if ( bake_vault_conf ) 2>/dev/null; then
    bad "${BUILDER}: a space-bearing \${BRAND} default was baked unchecked"
  else
    ok "${BUILDER}: a space-bearing \${BRAND} default is refused (not silently baked)"
  fi
  BRAND="acme"
  bake_vault_conf
  grep -q "^VAULT_BASE_PATH=acme$" "${SYSROOT}/etc/hugmesh/vault.conf" \
    && ok "${BUILDER}: an unset --vault-base-path defaults to the brand slug" \
    || bad "${BUILDER}: the brand-slug default did not land"
  grep -q "^VAULT_KV_MOUNT=secret$" "${SYSROOT}/etc/hugmesh/vault.conf" \
    && ok "${BUILDER}: an unset --vault-kv-mount defaults to 'secret'" \
    || bad "${BUILDER}: the KV-mount default did not land"
  BRAND="hugmesh"
  rm -rf "${SYSROOT}"
done

echo
if [ "${F}" -eq 0 ]; then echo "idp+vault-builder-functions: ${P} passed, 0 failed"; else echo "idp+vault-builder-functions: ${P} passed, ${F} FAILED"; fi
[ "${F}" -eq 0 ] || exit 1
exit 0
