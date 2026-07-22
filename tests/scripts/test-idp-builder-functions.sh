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
  for fn in _sed_rep_escape _validate_idp _idp_default_jwks \
            bake_idp_conf rewrite_idp_sysroot gate_casdoor_apps \
            write_idp_readme apply_idp_external; do
    src="$(extract_fn "${fn}" "${B}")"
    [ -n "${src}" ] || { bad "${BUILDER}: could not extract ${fn}"; continue 2; }
    eval "${src}"
  done
  type apply_idp_external >/dev/null 2>&1 || { bad "${BUILDER}: apply_idp_external not loaded"; continue; }

  CLUSTER_DOMAIN="acme.example"

  # ── casdoor default: BYTE-IDENTITY ──────────────────────────────────────────
  IDP=casdoor IDP_ISSUER="" IDP_CLIENT_ID="" IDP_JWKS=""
  ( set -e; _validate_idp ) && ok "${BUILDER}: _validate_idp(casdoor) returns 0 under set -e" \
    || bad "${BUILDER}: _validate_idp(casdoor) failed under set -e"

  SYSROOT="$(mktemp -d)"
  mkdir -p "${SYSROOT}/var/lib/snapdragon/cluster/apps" "${SYSROOT}/etc/snapdragon"
  printf 'issuer https://id.acme.example\njwks http://casdoor.snapdragon-pki.svc.cluster.local:8000/.well-known/jwks\n' \
      > "${SYSROOT}/var/lib/snapdragon/cluster/apps/gw.yaml"
  : > "${SYSROOT}/var/lib/snapdragon/cluster/apps/05-casdoor.yaml"
  before="$(find "${SYSROOT}" -type f | sort | xargs sha256sum 2>/dev/null)"
  apply_idp_external
  after="$(find "${SYSROOT}" -type f | sort | xargs sha256sum 2>/dev/null)"
  [ "${before}" = "${after}" ] && ok "${BUILDER}: apply_idp_external(casdoor) is a byte no-op" \
    || bad "${BUILDER}: apply_idp_external(casdoor) MUTATED the tree"
  [ -e "${SYSROOT}/etc/snapdragon/idp.conf" ] && bad "${BUILDER}: casdoor baked an idp.conf" \
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
  tree="${SYSROOT}/var/lib/snapdragon/cluster"
  mkdir -p "${tree}/apps" "${tree}/manifests/casdoor" "${SYSROOT}/etc/snapdragon"
  # concrete-domain issuer + in-cluster jwks:
  printf 'issuer: https://id.acme.example\njwks: http://casdoor.snapdragon-pki.svc.cluster.local:8000/.well-known/jwks\n' \
      > "${tree}/apps/gw.yaml"
  # concrete-domain jwks pin (must NOT half-rewrite):
  printf 'jwks: https://id.acme.example/.well-known/jwks\n' > "${tree}/apps/jwks.yaml"
  # the @@CLUSTER_DOMAIN@@ TEMPLATE form incl. a jwks URL (the F4 regression):
  printf 'oidc_issuer = https://id.@@CLUSTER_DOMAIN@@/\noidc_jwks = https://id.@@CLUSTER_DOMAIN@@/.well-known/jwks\n' \
      > "${tree}/apps/tmpl.conf"
  : > "${tree}/apps/05-casdoor.yaml"; : > "${tree}/apps/06-casdoor-games.yaml"

  apply_idp_external

  ic="${SYSROOT}/etc/snapdragon/idp.conf"
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

  rm="${SYSROOT}/etc/snapdragon/README-IDP.md"
  [ -f "${rm}" ] && grep -qi 'does NOT work' "${rm}" && grep -qi '/bff/login' "${rm}" \
    && ok "${BUILDER}: README-IDP.md dropped with the honest-limits text" || bad "${BUILDER}: README-IDP.md missing/incomplete"
  rm -rf "${SYSROOT}"
done

echo
if [ "${F}" -eq 0 ]; then echo "idp-builder-functions: ${P} passed, 0 failed"; else echo "idp-builder-functions: ${P} passed, ${F} FAILED"; fi
[ "${F}" -eq 0 ] || exit 1
exit 0
