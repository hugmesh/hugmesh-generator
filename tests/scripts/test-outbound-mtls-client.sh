#!/usr/bin/env bash
# test-outbound-mtls-client.sh — outbound (client-side) mTLS must be given the
# password to the stores it is told to use.
#
# WHY THIS EXISTS. A pod's init container mints one PKCS12 keypair, protects it
# with a freshly generated password `${P}`, and writes that password into
# /stores/application.properties — which Spring loads via
# SPRING_CONFIG_ADDITIONAL_LOCATION. It wrote exactly two keys:
#
#     server.ssl.key-store-password=${P}
#     server.ssl.trust-store-password=${P}
#
# Those configure the INBOUND listener. The OUTBOUND client is a completely
# separate binding — `hugmesh.mtls.client.*` (FederationHttpClientSsl,
# @ConfigurationProperties) — whose application.yml defaults are
# ${SSL_KEY_STORE_PASSWORD:} / ${SSL_TRUST_STORE_PASSWORD:}: environment
# variables that NOTHING in any pod spec sets. They therefore resolved to the
# empty string, and the empty string cannot open a password-protected PKCS12.
#
# Two different failures follow from the same missing line, depending on the gate:
#
#   gate OFF (user-bff-api) — customize() returns the HttpClient UNCHANGED, so
#     every outbound https call used the JDK default truststore. That store holds
#     public roots and never the cluster CA, so calls to admin-bff, federation-api
#     and the :4443 homeserver proxies could not complete. Live on kind 2026-08-06:
#       POST /bff/login -> 500
#       SSLHandshakeException (certificate_unknown): PKIX path building failed
#       R:hugmesh-admin-bff-api.hugmesh-backend.svc.cluster.local:8080
#     This was NOT a CA mismatch. Both sides carried the byte-identical CA
#     (sha256 67:12:76:F2:...:D3:42) and the cert on the wire matched the Secret.
#     The client could not OPEN the truststore that already held the right CA —
#     an hour of chasing the wrong layer.
#
#   gate ON (forum-bff-api) — customize() calls buildSslContext(), KeyStore.load()
#     is handed new char[0], and the whole thing throws IllegalStateException. A
#     hard startup failure, shipped and unnoticed because forum-bff is not in the
#     kind SSO profile.
#
# THE INVARIANT, deliberately dumb and unevadable:
#
#   1. A manifest that switches HUGMESH_MTLS_CLIENT_ENABLED on MUST write both
#      hugmesh.mtls.client.{key,trust}-store-password.
#   2. Whatever it writes them to must be the SAME value the server-side keys
#      use — i.e. the password the stores were actually created with. Asserting
#      equality rather than a literal `${P}` means renaming the shell variable
#      moves both sides together and cannot drift them apart.
#   3. A manifest that writes client store passwords must actually BUILD stores
#      (openssl pkcs12 -export), or it is handing out a password to nothing.
#
# NOT IN SCOPE, on purpose: charts/hugmesh-gateway binds a different prefix
# (`hugmesh.tls.*`) in a different codebase and mints its stores its own way. It
# is not missing from this guard by accident.
#
# Offline: bash + grep + sed only. No cluster, no python, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# Control runs re-enter this script against synthetic manifest trees. The flag is
# a POSITIONAL ARGUMENT, never an environment variable: an inherited env var
# would silently downgrade a real CI run to a control run — skipping every
# control and the vacuity floor — with nothing in the output saying so.
CHILD=no
[ "${1:-}" = "--scan-only" ] && CHILD=yes

# The directory override is honoured ONLY in a child run. In a real run it is
# ignored outright, so a stray MTLS_MANIFEST_DIR in the environment can never
# point CI at some other tree and report a confident PASS about it.
if [ "${CHILD}" = yes ]; then
  DIR="${MTLS_MANIFEST_DIR:-${REPO}/specs/cluster/manifests}"
else
  DIR="${REPO}/specs/cluster/manifests"
fi

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards; this repo has shipped several.
for t in grep sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip)" >&2; exit 1; }
done
[ -d "${DIR}" ] || { echo "FATAL: manifest dir not found: ${DIR}" >&2; exit 1; }

# Right-hand side of a properties assignment, first occurrence, whitespace trimmed.
# Returns empty when the key is absent — callers must distinguish absent from set,
# never score a PASS off an absent value.
rhs() { # <file> <property-key>
  sed -n "s/^[[:space:]]*$(printf '%s' "$2" | sed 's/[.[\*^$]/\\&/g')=\(.*\)$/\1/p" "$1" \
    | head -1 | sed 's/[[:space:]]*$//'
}

ROOT_SPECS="${DIR}/.."

CLIENT_KEY_PW='hugmesh.mtls.client.key-store-password'
CLIENT_TRUST_PW='hugmesh.mtls.client.trust-store-password'
SERVER_KEY_PW='server.ssl.key-store-password'
SERVER_TRUST_PW='server.ssl.trust-store-password'

violations=()
n_store_builders=0
n_gate_on=0
n_client_pw=0
v5=()
n_gate_wired=0

# RULE 1, isolated between sentinels so the sabotage control at the bottom can
# blank it and prove the negative controls really are exercising it. The
# sentinels exist because the obvious `/^rule1() {/,/^}/` range was
# SELF-REFERENTIAL: the sed's own replacement text sits at column 0 in this file
# and starts with `rule1() {`, so sed opened a second range on its own source and
# deleted the rest of the script. These two markers appear at column 0 exactly
# once each, and never inside the sed that consumes them.
# >>> RULE1
rule1() { # <svc> <client-key-pw> <client-trust-pw>
  [ -n "$2" ] || violations+=("$1: HUGMESH_MTLS_CLIENT_ENABLED=true but ${CLIENT_KEY_PW} is never written — the client keystore cannot be opened (IllegalStateException at client construction)")
  [ -n "$3" ] || violations+=("$1: HUGMESH_MTLS_CLIENT_ENABLED=true but ${CLIENT_TRUST_PW} is never written — outbound TLS falls back to the JDK default trust, which has no cluster CA")
}
# <<< RULE1

# ── RULE 5 — the username gate may not be wired, or armed, without its credential
#    and its transport.   (hugmesh-generator#376)
#
# federation-api authenticates /api/federation/username/** only as an OAuth2 resource
# server and serves TLS with client-auth=need. A caller that points the gate at it
# therefore needs two things in ITS OWN manifest, or every availability check fails
# closed (and FEDERATION_USERNAME_GATE_ENABLED=true would refuse every
# provider-derived username):
#   (a) the Casdoor client-credentials trio the auth-core client reads, either
#       APP_CASDOOR_PLATFORM_{BASE_URL,CLIENT_ID,CLIENT_SECRET} or
#       FEDERATION_USERNAME_GATE_SERVICE_BEARER_{CASDOOR_BASE_URL,CLIENT_ID,CLIENT_SECRET};
#       the id and secret must be secretKeyRefs (never a literal), and each ref must
#       name a Secret that an ExternalSecret in the kustomized external-secrets tree
#       really creates, with that key, in the manifest's own namespace;
#   (b) HUGMESH_MTLS_CLIENT_ENABLED=true (rule 1 then demands the store passwords).
# It applies to any manifest that sets FEDERATION_USERNAME_GATE_BASE_URL or switches
# FEDERATION_USERNAME_GATE_ENABLED on — NOT only to a manifest with the flag on, because
# the flag ships OFF and a rule that only watched the flag would never fire.
#
# The flag itself is deliberately not asserted off: flipping it is the last step of
# #376 and a legitimate later change, which this rule then lets through only if the
# wiring above is present.
#
# For admin-bff-api only, the credential is also pinned to the application the
# operator chose on 2026-10-15 (its OWN application, app-admin-bff, with its own
# secret): the ExternalSecret must template clientId app-admin-bff and read property
# admin-bff of the casdoor-apps Vault path, not another application's pair.
# >>> RULE5
env_region() { # <file> <ENV_NAME> -> the env entry, comments dropped, on one line
  awk -v n="$2" '
    function flush() { if (inr) { print buf; inr = 0; buf = "" } }
    /^[[:space:]]*#/ { next }
    {
      if ($0 ~ ("name:[[:space:]]*" n "([^A-Za-z0-9_]|$)")) {
        flush(); inr = 1; buf = $0
        if ($0 ~ /^[[:space:]]*-[[:space:]]*\{.*\}[[:space:]]*$/) flush()
        next
      }
      if (inr) { if ($0 ~ /^[[:space:]]*-[[:space:]]/) flush(); else buf = buf " " $0 }
    }
    END { flush() }' "$1"
}

secret_ref() { # <file> <ENV_NAME> -> "<secret> <key>" of its secretKeyRef, else empty
  env_region "$1" "$2" | sed -nE 's/.*secretKeyRef:[[:space:]]*\{?[[:space:]]*name:[[:space:]]*([^ ,}]+)[[:space:]]*,?[[:space:]]*key:[[:space:]]*([^ ,}]+).*/\1 \2/p' | head -1
}

# The ExternalSecret that creates Secret <name> in <ns> holding <key>.
# Prints: <file>|<template clientId>|<remoteRef property>|<remoteRef key>
es_for() { # <external-secrets dir> <name> <ns> <key>
  local ef
  for ef in "$1"/*.yaml; do
    [ -f "${ef}" ] || continue
    awk -v name="$2" -v ns="$3" -v key="$4" -v file="${ef}" '
      function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); gsub(/["'"'"' ]/, "", s); return s }
      function reset() { kind = ""; mname = ""; mns = ""; tname = ""; haskey = 0; sect = ""; ts = 0; cid = ""; prop = ""; rkey = "" }
      function fin() {
        if (kind == "ExternalSecret" && haskey && ((tname != "" ? tname : mname) == name) && (ns == "" || mns == ns)) {
          print file "|" cid "|" prop "|" rkey; found = 1
        }
        reset()
      }
      BEGIN { reset() }
      /^---[[:space:]]*$/ { fin(); next }
      /^[[:space:]]*#/ { next }
      /^kind:[[:space:]]*ExternalSecret[[:space:]]*$/ { kind = "ExternalSecret"; next }
      /^metadata:/ { sect = "metadata"; next }
      /^spec:/ { sect = "spec"; ts = 0; next }
      sect == "metadata" && /^  name:/ { mname = val($0); next }
      sect == "metadata" && /^  namespace:/ { mns = val($0); next }
      sect == "spec" && /^  target:/ { ts = 1; next }
      sect == "spec" && /^  [A-Za-z]/ { ts = 0 }
      ts && /^    name:/ { tname = val($0); next }
      ts && $0 ~ ("^[[:space:]]+" key ":[[:space:]]") { haskey = 1 }
      $0 ~ ("secretKey:[[:space:]]*" key "([^A-Za-z0-9_]|$)") { haskey = 1 }
      $0 ~ /^[[:space:]]+clientId:/ { cid = val($0) }
      $0 ~ /^[[:space:]]+property:/ { prop = val($0) }
      $0 ~ /^[[:space:]]+key:[[:space:]]/ { rkey = val($0) }
      END { fin() }' "${ef}"
  done
}

rule5() { # <manifest> <label>
  local f="$1" svc="$2" fam id sec trio ns ref rname rkeyname es esf listed base
  local ESDIR="${DIR}/external-secrets"
  # the transport
  if ! grep -qE 'HUGMESH_MTLS_CLIENT_ENABLED[",}[:space:]].*value:[[:space:]]*"?true"?' "${f}" \
     && ! grep -A2 -E 'name:[[:space:]]*HUGMESH_MTLS_CLIENT_ENABLED[[:space:]]*$' "${f}" 2>/dev/null \
          | grep -E 'value:[[:space:]]*"?true"?' >/dev/null; then
    v5+=("${svc}: wires the federation username gate but HUGMESH_MTLS_CLIENT_ENABLED is not true — federation-api serves client-auth=need, so the handshake is refused before any credential is read")
  fi
  # the credential: one complete family
  fam=""
  if [ -n "$(env_region "${f}" APP_CASDOOR_PLATFORM_BASE_URL)" ] \
     && [ -n "$(env_region "${f}" APP_CASDOOR_PLATFORM_CLIENT_ID)" ] \
     && [ -n "$(env_region "${f}" APP_CASDOOR_PLATFORM_CLIENT_SECRET)" ]; then
    fam="APP_CASDOOR_PLATFORM"; trio="APP_CASDOOR_PLATFORM_CLIENT_ID APP_CASDOOR_PLATFORM_CLIENT_SECRET"
  elif [ -n "$(env_region "${f}" FEDERATION_USERNAME_GATE_SERVICE_BEARER_CASDOOR_BASE_URL)" ] \
     && [ -n "$(env_region "${f}" FEDERATION_USERNAME_GATE_SERVICE_BEARER_CLIENT_ID)" ] \
     && [ -n "$(env_region "${f}" FEDERATION_USERNAME_GATE_SERVICE_BEARER_CLIENT_SECRET)" ]; then
    fam="FEDERATION_USERNAME_GATE_SERVICE_BEARER"; trio="FEDERATION_USERNAME_GATE_SERVICE_BEARER_CLIENT_ID FEDERATION_USERNAME_GATE_SERVICE_BEARER_CLIENT_SECRET"
  fi
  if [ -z "${fam}" ]; then
    v5+=("${svc}: wires the federation username gate but supplies no complete Casdoor credential trio (APP_CASDOOR_PLATFORM_{BASE_URL,CLIENT_ID,CLIENT_SECRET} or FEDERATION_USERNAME_GATE_SERVICE_BEARER_{CASDOOR_BASE_URL,CLIENT_ID,CLIENT_SECRET}) — federation-api accepts only a bearer, so every check fails closed")
    return 0
  fi
  base="$(dirname "${f}")"
  ns="$(sed -nE 's/^namespace:[[:space:]]*"?([A-Za-z0-9._-]+)"?[[:space:]]*$/\1/p' "${base}/kustomization.yaml" 2>/dev/null | head -1)"
  for id in ${trio}; do
    ref="$(secret_ref "${f}" "${id}")"
    if [ -z "${ref}" ]; then
      v5+=("${svc}: ${id} is not a secretKeyRef — a client credential must never be a literal in the manifest")
      continue
    fi
    rname="${ref% *}"; rkeyname="${ref#* }"
    es="$(es_for "${ESDIR}" "${rname}" "${ns}" "${rkeyname}" | head -1)"
    if [ -z "${es}" ]; then
      v5+=("${svc}: ${id} reads Secret ${rname} key ${rkeyname}${ns:+ in ${ns}}, but no ExternalSecret under external-secrets/ creates that Secret with that key — the env would stay empty")
      continue
    fi
    esf="${es%%|*}"
    listed="$(basename "${esf}")"
    grep -qE "^[[:space:]]*-[[:space:]]+${listed}([[:space:]]|\$)" "${ESDIR}/kustomization.yaml" 2>/dev/null \
      || v5+=("${svc}: ${id} is backed by an ExternalSecret in ${listed}, which external-secrets/kustomization.yaml does not list — it is never rendered, so the Secret never exists")
    # the operator's decision for admin-bff-api: its own application and its own secret
    if [ "$(basename "${base}")" = admin-bff-api ] && [ "${id##*_}" = SECRET ]; then
      IFS='|' read -r _ cid prop rkey <<<"${es}"
      [ "${cid}" = "app-admin-bff" ] \
        || v5+=("${svc}: Secret ${rname} templates clientId '${cid}', not app-admin-bff — admin-bff holds the service role as its OWN application (decision 2026-10-15 on #376)")
      [ "${prop}" = "admin-bff" ] && [ "${rkey#*/}" = "casdoor-apps" ] \
        || v5+=("${svc}: Secret ${rname} reads '${rkey}' property '${prop}', not the admin-bff property of casdoor-apps — that is another application's secret")
    fi
  done
}
# <<< RULE5

# ONE pattern, not two. An earlier draft globbed `*/deployment.yaml` AND `*/*.yaml`,
# so every deployment was scanned twice and every count was silently doubled —
# 4 edited files reported as 8. A doubled count sails past a `>=` floor, which is
# precisely the kind of number a reader would take as evidence.
shopt -s nullglob
for f in "${DIR}"/*/*.yaml; do
  [ -f "${f}" ] || continue
  svc="$(basename "$(dirname "${f}")")/$(basename "${f}")"

  builds_stores=no
  grep -q 'openssl pkcs12 -export' "${f}" && builds_stores=yes
  [ "${builds_stores}" = yes ] && n_store_builders=$((n_store_builders+1))

  gate_on=no
  # value: "true" / value: true, on the same line as the gate name (the shipped
  # `- { name: X, value: "true" }` flow-map shape) or on the following line.
  if grep -qE 'HUGMESH_MTLS_CLIENT_ENABLED[",}[:space:]].*value:[[:space:]]*"?true"?' "${f}" \
     || grep -A2 -E 'name:[[:space:]]*HUGMESH_MTLS_CLIENT_ENABLED[[:space:]]*$' "${f}" 2>/dev/null \
          | grep -E 'value:[[:space:]]*"?true"?' >/dev/null; then
    gate_on=yes
    n_gate_on=$((n_gate_on+1))
  fi

  ckey="$(rhs "${f}" "${CLIENT_KEY_PW}")"
  ctrust="$(rhs "${f}" "${CLIENT_TRUST_PW}")"
  has_client_pw=no
  { [ -n "${ckey}" ] || [ -n "${ctrust}" ]; } && { has_client_pw=yes; n_client_pw=$((n_client_pw+1)); }

  # RULE 1 — gate on ⇒ both client store passwords present.
  [ "${gate_on}" = yes ] && rule1 "${svc}" "${ckey}" "${ctrust}"

  # RULE 2 — client passwords must be the SAME value the stores were built with.
  if [ "${has_client_pw}" = yes ]; then
    skey="$(rhs "${f}" "${SERVER_KEY_PW}")"
    strust="$(rhs "${f}" "${SERVER_TRUST_PW}")"
    if [ -z "${skey}" ] || [ -z "${strust}" ]; then
      violations+=("${svc}: writes client store passwords but not the server ones — the two halves are supposed to share one generated password, so this cannot be right")
    else
      [ -n "${ckey}" ]   && [ "${ckey}" != "${skey}" ] \
        && violations+=("${svc}: ${CLIENT_KEY_PW}=${ckey} differs from ${SERVER_KEY_PW}=${skey} — the client would open the keystore with a password it was not created with")
      [ -n "${ctrust}" ] && [ "${ctrust}" != "${strust}" ] \
        && violations+=("${svc}: ${CLIENT_TRUST_PW}=${ctrust} differs from ${SERVER_TRUST_PW}=${strust}")
    fi

    # RULE 3 — a password for stores this pod never creates is meaningless.
    [ "${builds_stores}" = yes ] \
      || violations+=("${svc}: writes client store passwords but never builds a PKCS12 (no 'openssl pkcs12 -export') — password for stores that do not exist")
  fi
done

# RULE 5 — applies to a manifest that wires the username gate, not only one that arms it.
for f in "${DIR}"/*/*.yaml; do
  [ -f "${f}" ] || continue
  svc="$(basename "$(dirname "${f}")")/$(basename "${f}")"
  if grep -qE 'FEDERATION_USERNAME_GATE_BASE_URL' "${f}" \
     || grep -qE 'FEDERATION_USERNAME_GATE_ENABLED[",}[:space:]].*value:[[:space:]]*"?true"?' "${f}" \
     || grep -A2 -E 'name:[[:space:]]*FEDERATION_USERNAME_GATE_ENABLED[[:space:]]*$' "${f}" 2>/dev/null \
          | grep -E 'value:[[:space:]]*"?true"?' >/dev/null; then
    n_gate_wired=$((n_gate_wired+1))
    rule5 "${f}" "${svc}"
  fi
done
shopt -u nullglob

if [ "${#violations[@]}" -eq 0 ]; then
  ok "every gate-on manifest supplies both client store passwords, matching the server ones"
else
  for v in "${violations[@]}"; do bad "${v}"; done
fi

if [ "${#v5[@]}" -eq 0 ]; then
  ok "every manifest that wires the federation username gate carries its credential (backed by an ExternalSecret) and the mTLS client gate"
else
  for v in "${v5[@]}"; do bad "${v}"; done
fi

# ── RULE 4 — nothing may address a TLS-serving peer over http://.
#
# The stores being right is useless if the URL never reaches them. Both gateways
# carried `BFF_BASE_URL: http://hugmesh-admin-bff-api...:8080` while admin-bff
# serves TLS with client-auth=need, so the session bridge spoke plain HTTP into a
# TLS port and got:
#     [bff-session] BFF introspection call failed:
#     Connection prematurely closed BEFORE response — returning 503
# The browser saw 503 {"error":"session_backend_unavailable"} for a freshly minted,
# perfectly valid session. Every OTHER reference to that peer was already https —
# these two were missed when admin-bff's server TLS went on, and no gate compared
# the two sides.
#
# DERIVED, not a list: the TLS-serving set comes from whichever manifests actually
# set SSL_ENABLED=true, so a service turning TLS on automatically brings its callers
# under the rule with nobody editing anything.
# >>> RULE4
tls_hosts=""
for d in "${DIR}"/*/; do
  [ -d "${d}" ] || continue
  grep -rhqE 'SSL_ENABLED[",}[:space:]]+value:[[:space:]]*"?true"?' "${d}" 2>/dev/null || continue
  svc="$(grep -rhE '^[[:space:]]*name:[[:space:]]*[a-z0-9-]+[[:space:]]*$' "${d}" 2>/dev/null \
         | sed 's/.*name:[[:space:]]*//; s/[[:space:]]*$//' | sort -u | grep -E '^hugmesh-' | head -1)"
  [ -n "${svc}" ] && tls_hosts="${tls_hosts} ${svc}"
done

# KNOWN-BROKEN, deliberately NOT flipped here — each with the reason it cannot be a
# one-word change, and each anti-rot checked below so a stale exemption fails the
# build rather than quietly widening. These are recorded as OPEN in
# docs/KIND-SSO-E2E-FINDINGS.md; they are real defects, not false positives.
#
#   remote-fragment/deployment.yaml -> federation-api
#     remote-fragment mounts NO PKCS12 stores and has no client-mTLS leg at all
#     (zero matches for openssl pkcs12 -export / SSL_KEY_STORE / MTLS_CLIENT_ENABLED),
#     so https:// would fail the handshake instead of the read. The fix is the whole
#     store-building treatment, and this service is not in any profile I can run, so
#     flipping the scheme blind would trade a visible failure for a subtler one.
#
#   test-runner/test-job-{lean,heavy}.yaml -> admin-bff /bff/admin/test-reports/ingest
#     Same story: no stores, no client identity. These are the report-ingest POSTs,
#     so the failure mode is "results silently never ingested" rather than a broken
#     user path — which is exactly why nobody noticed.
#
#   charts/hugmesh-gateway/values.yaml -> hugmesh-api
#     A chart DEFAULT route, overridden per-Application by the gateway apps' own
#     route tables. Changing a default that every real deployment replaces is
#     untestable from here and risks moving a value nothing reads.
#
# THE COMMON SHAPE, worth naming: every one of these is a NON-SPRING caller — a Job
# or a sync sidecar — and the mTLS wave only ever reached the Spring services, which
# get their stores from an init container and their client config from a
# @ConfigurationProperties prefix. Nothing gave the Jobs an equivalent, so their
# calls to TLS-serving peers cannot succeed by any scheme. Tracked as OPEN in
# docs/KIND-SSO-E2E-FINDINGS.md rather than papered over with a scheme flip that
# would swap a connection error for a handshake error.
EXEMPT_HTTP_TLS="specs/cluster/manifests/remote-fragment/deployment.yaml specs/cluster/charts/hugmesh-gateway/values.yaml specs/cluster/manifests/test-runner/test-job-lean.yaml specs/cluster/manifests/test-runner/test-job-heavy.yaml"

if [ -z "${tls_hosts// /}" ]; then
  # Child probes stage a couple of synthetic manifests and no TLS-serving service;
  # that is not a finding, it just means this rule has nothing to say about them.
  [ "${CHILD}" = yes ] || bad "derived NO TLS-serving services — the SSL_ENABLED shape moved, so rule 4 proves NOTHING"
else
  http_viol=""
  for h in ${tls_hosts}; do
    hits="$(grep -rn "http://${h}\." "${DIR}/.." --include=*.yaml 2>/dev/null \
            | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
    [ -n "${hits}" ] && http_viol="${http_viol}
${hits}"
  done
  n_bad=0; n_exempt=0
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    rel="${line#"${DIR}/../"}"; rel="specs/cluster/${rel}"
    path="${rel%%:*}"
    skip=no
    for e in ${EXEMPT_HTTP_TLS}; do [ "${path}" = "${e}" ] && skip=yes; done
    if [ "${skip}" = yes ]; then
      n_exempt=$((n_exempt+1))
      [ "${CHILD}" = yes ] || echo "     known-broken (exempt, see header + findings doc): ${rel}"
    else
      bad "http:// URL addressing a TLS-serving peer (it dies as 'Connection prematurely closed BEFORE response'): ${rel}"
      n_bad=$((n_bad+1))
    fi
  done <<< "${http_viol}"
  [ "${n_bad}" -eq 0 ] && ok "no unexempted http:// URL addresses any of the $(echo ${tls_hosts} | wc -w) TLS-serving services (${n_exempt} known-broken, listed)"

  # ANTI-ROT on the exemptions: an exemption for a file that no longer has the
  # defect is a licence nobody revoked. Parent-only — probe trees have neither file.
  if [ "${CHILD}" = no ]; then
    for e in ${EXEMPT_HTTP_TLS}; do
      f="${ROOT_SPECS}/${e#specs/cluster/}"
      if [ ! -r "${f}" ]; then
        bad "exemption names a file that no longer exists: ${e} — remove it"
      elif ! grep -qE 'http://hugmesh-[a-z-]+\.' "${f}"; then
        bad "exemption for ${e} is STALE (it no longer contains an http:// peer URL) — remove it so the rule bites again"
      else
        ok "exemption still describes a real, still-present defect: ${e}"
      fi
    done
  fi
fi
# <<< RULE4

# ── Vacuity floor + anti-rot. Properties of the REAL repo, never of a synthetic
#    probe: leaving them on in a child run would make every probe fail for the
#    wrong reason, which is exactly how a sibling guard on this branch ended up
#    with controls that passed while the logic under them was deleted.
if [ "${CHILD}" = no ]; then
  echo
  echo "-- scanned ${DIR}: ${n_store_builders} store-building manifest(s), ${n_gate_on} with the client gate on, ${n_client_pw} writing client store passwords --"

  if [ "${n_store_builders}" -ge 4 ]; then
    ok "vacuity floor: ${n_store_builders} manifests build PKCS12 stores (>=4)"
  else
    bad "vacuity floor: only ${n_store_builders} manifests build PKCS12 stores — either the layout moved or this guard is now scanning nothing"
  fi

  if [ "${n_gate_on}" -ge 1 ]; then
    ok "anti-rot: ${n_gate_on} manifest(s) actually switch HUGMESH_MTLS_CLIENT_ENABLED on, so rule 1 has something to bite"
  else
    bad "anti-rot: NO manifest switches HUGMESH_MTLS_CLIENT_ENABLED on — rule 1 is unexercised and this guard proves nothing"
  fi

  # RULE 5 floor. The flag ships OFF, so this counts manifests that WIRE the gate, and
  # names admin-bff-api explicitly: a count alone would stay >=1 if the wiring moved.
  if [ "${n_gate_wired}" -ge 1 ] && [ -f "${DIR}/admin-bff-api/deployment.yaml" ] \
     && grep -q 'FEDERATION_USERNAME_GATE_BASE_URL' "${DIR}/admin-bff-api/deployment.yaml"; then
    ok "anti-rot: ${n_gate_wired} manifest(s) wire the federation username gate, admin-bff-api among them, so rule 5 has something to bite"
  else
    bad "anti-rot: admin-bff-api no longer wires FEDERATION_USERNAME_GATE_BASE_URL (or none does) — rule 5 is unexercised and proves nothing"
  fi

  if [ "${n_client_pw}" -ge 4 ]; then
    ok "anti-rot: ${n_client_pw} manifest(s) write client store passwords (>=4 — the services whose apps declare the hugmesh.mtls.client prefix)"
  else
    bad "anti-rot: only ${n_client_pw} manifest(s) write client store passwords; user-bff/forum-bff/mesh-bff/mod-bff all declare the prefix and all need them"
  fi
fi

# ── Controls. Child runs stop here: they exist to be measured, not to measure.
if [ "${CHILD}" = yes ]; then
  echo "== outbound mTLS client stores: ${pass} passed, ${fail} failed =="
  [ "${fail}" -eq 0 ]
  exit $?
fi

echo
echo "-- negative controls --"

T="$(mktemp -d)"
case "$(realpath "${T}")" in
  /tmp/*|/var/tmp/*|"${TMPDIR:-/nonexistent}"*) : ;;
  *) echo "FATAL: refusing to write controls outside a temp dir: ${T}" >&2; exit 1 ;;
esac
cleanup() { case "$(realpath "${T}" 2>/dev/null)" in /tmp/*|/var/tmp/*|"${TMPDIR:-/nonexistent}"/*) rm -rf "${T}" ;; esac; }
trap cleanup EXIT

# Synthesise a manifest with the REAL shipped shape — the store-building block,
# the flow-map env entry, the heredoc — never a simplification. A control whose
# fixture is simpler than production tests a shape that does not ship.
probe() { # <path> <gate:on|off> <client-pw:both|none|key|mismatch> <stores:yes|no>
  local out="$1" gate="$2" cpw="$3" stores="$4"
  mkdir -p "$(dirname "${out}")"
  {
    echo 'apiVersion: apps/v1'
    echo 'kind: Deployment'
    echo 'spec:'
    echo '  template:'
    echo '    spec:'
    echo '      initContainers:'
    echo '        - name: build-keystore'
    echo '          command: ["/bin/sh", "-ec"]'
    echo '          args:'
    echo '            - |'
    echo '              P="$(openssl rand -base64 24 | tr -d ${SQ}/+=${SQ} | cut -c1-24)"'
    if [ "${stores}" = yes ]; then
      echo '              openssl pkcs12 -export -inkey /pki/tls.key -in /pki/tls.crt \'
      echo '                -certfile /pki/ca.crt -name probe \'
      echo '                -out /stores/keystore.p12 -passout "pass:${P}"'
      echo '              keytool -importcert -noprompt -alias hugmesh-cluster-ca \'
      echo '                -file /pki/ca.crt -keystore /stores/truststore.p12 \'
      echo '                -storetype PKCS12 -storepass "${P}"'
    fi
    echo '              umask 077'
    echo '              cat > /stores/application.properties <<EOF'
    echo '              server.ssl.key-store-password=${P}'
    echo '              server.ssl.trust-store-password=${P}'
    case "${cpw}" in
      both)
        echo '              hugmesh.mtls.client.key-store-password=${P}'
        echo '              hugmesh.mtls.client.trust-store-password=${P}' ;;
      key)
        echo '              hugmesh.mtls.client.key-store-password=${P}' ;;
      mismatch)
        echo '              hugmesh.mtls.client.key-store-password=${P}'
        echo '              hugmesh.mtls.client.trust-store-password=hunter2' ;;
      none) : ;;
    esac
    echo '              EOF'
    echo '      containers:'
    echo '        - name: probe'
    echo '          env:'
    echo '            - { name: SSL_ENABLED, value: "true" }'
    [ "${gate}" = on ] && echo '            - { name: HUGMESH_MTLS_CLIENT_ENABLED, value: "true" }'
    echo '            - { name: SPRING_CONFIG_ADDITIONAL_LOCATION, value: "file:/stores/" }'
  } > "${out}"
}
SQ="'"

run_probe() { # <manifest-dir> -> rc
  MTLS_MANIFEST_DIR="$1" bash "${BASH_SOURCE[0]}" --scan-only >/dev/null 2>&1
}

pair() { # <name> <bad-dir> <good-dir>
  local name="$1" bad="$2" good="$3"
  if run_probe "${bad}"; then
    bad "control '${name}': the DEFECTIVE probe was not caught"
  elif ! run_probe "${good}"; then
    bad "control '${name}': the CORRECTED probe also failed — the control cannot distinguish, so it proves nothing"
  else
    ok "control '${name}': defective probe caught, corrected probe clean"
  fi
}

# 1. THE SHIPPED DEFECT: gate on, no client passwords at all (forum-bff-api's
#    exact pre-fix state).
probe "${T}/b1/svc/deployment.yaml" on none yes
probe "${T}/g1/svc/deployment.yaml" on both yes
pair "gate on with no client store passwords" "${T}/b1" "${T}/g1"

# 2. Half-done: keystore password supplied, truststore password forgotten. This is
#    the subtler half — it does not crash, it silently trusts the JDK defaults.
probe "${T}/b2/svc/deployment.yaml" on key yes
probe "${T}/g2/svc/deployment.yaml" on both yes
pair "gate on with only the keystore password" "${T}/b2" "${T}/g2"

# 3. Drift: a client password that is not the password the stores were built with.
probe "${T}/b3/svc/deployment.yaml" on mismatch yes
probe "${T}/g3/svc/deployment.yaml" on both yes
pair "client password differs from the server password" "${T}/b3" "${T}/g3"

# 4. A password handed out for stores this pod never creates.
probe "${T}/b4/svc/deployment.yaml" off both no
probe "${T}/g4/svc/deployment.yaml" off both yes
pair "client passwords without any PKCS12 being built" "${T}/b4" "${T}/g4"

# 5. RULE 5 — the username gate wired without its credential or transport. The probe
#    is a whole manifest TREE (deployment + kustomization + external-secrets), because
#    the rule cross-checks the deployment's secretKeyRefs against an ExternalSecret.
probe5() { # <root> <variant> -- variants below
  local root="$1" v="$2" d="$1/admin-bff-api" e="$1/external-secrets"
  local sname=admin-bff-casdoor-client skey=clientSecret cprop=admin-bff cid=app-admin-bff listed=secretstore.yaml
  case "${v}" in
    badref)   sname=wrong-secret-name ;;
    badkey)   skey=client_secret_typo ;;
    otherapp) cprop=signup-gate; cid=app-signup-gate ;;
    unlisted) listed=other.yaml ;;
  esac
  mkdir -p "${d}" "${e}"
  {
    echo 'apiVersion: apps/v1'
    echo 'kind: Deployment'
    echo 'spec:'
    echo '  template:'
    echo '    spec:'
    echo '      initContainers:'
    echo '        - name: build-keystore'
    echo '          args:'
    echo '            - |'
    echo '              P="$(openssl rand -base64 24 | tr -d x | cut -c1-24)"'
    echo '              openssl pkcs12 -export -inkey /pki/tls.key -in /pki/tls.crt \\'
    echo '                -out /stores/keystore.p12 -passout "pass:${P}"'
    echo '              cat > /stores/application.properties <<EOF'
    echo '              server.ssl.key-store-password=${P}'
    echo '              server.ssl.trust-store-password=${P}'
    echo '              hugmesh.mtls.client.key-store-password=${P}'
    echo '              hugmesh.mtls.client.trust-store-password=${P}'
    echo '              EOF'
    echo '      containers:'
    echo '        - name: probe'
    echo '          env:'
    echo '            - name: FEDERATION_USERNAME_GATE_BASE_URL'
    echo '              value: "https://hugmesh-federation-api.hugmesh-backend.svc.cluster.local:8080"'
    [ "${v}" = flagon ] && echo '            - { name: FEDERATION_USERNAME_GATE_ENABLED, value: "true" }'
    [ "${v}" = nomtls ] || echo '            - { name: HUGMESH_MTLS_CLIENT_ENABLED, value: "true" }'
    if [ "${v}" != nocreds ] && [ "${v}" != flagon ]; then
      echo '            - name: APP_CASDOOR_PLATFORM_BASE_URL'
      echo '              value: "http://casdoor.hugmesh-pki.svc.cluster.local:8000"'
      echo '            - name: APP_CASDOOR_PLATFORM_CLIENT_ID'
      echo '              valueFrom:'
      echo "                secretKeyRef: { name: ${sname}, key: clientId, optional: true }"
      if [ "${v}" = literal ]; then
        echo '            - name: APP_CASDOOR_PLATFORM_CLIENT_SECRET'
        echo '              value: "hunter2"'
      elif [ "${v}" != nosecret ]; then
        echo '            - name: APP_CASDOOR_PLATFORM_CLIENT_SECRET'
        echo '              valueFrom:'
        echo "                secretKeyRef: { name: ${sname}, key: ${skey}, optional: true }"
      fi
    fi
    echo '            - { name: SPRING_CONFIG_ADDITIONAL_LOCATION, value: "file:/stores/" }'
  } > "${d}/deployment.yaml"
  printf 'namespace: hugmesh-backend\nresources:\n  - deployment.yaml\n' > "${d}/kustomization.yaml"
  printf 'resources:\n  - %s\n' "${listed}" > "${e}/kustomization.yaml"
  cat > "${e}/secretstore.yaml" <<YAML
# a comment that mentions secretKey: clientSecret must not count
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: some-other-secret
  namespace: hugmesh-backend
spec:
  target:
    name: some-other-secret
  data:
    - secretKey: clientSecret
      remoteRef: { key: hugmesh/x, property: y }
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: admin-bff-casdoor-client
  namespace: hugmesh-backend
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: hugmesh-vault
    kind: ClusterSecretStore
  target:
    name: admin-bff-casdoor-client
    creationPolicy: Owner
    template:
      data:
        clientId: "${cid}"
        clientSecret: "{{ .clientSecret }}"
  data:
    - secretKey: clientSecret
      remoteRef:
        key: hugmesh/casdoor-apps
        property: ${cprop}
YAML
}
for v in good nomtls nocreds nosecret literal badref badkey otherapp unlisted flagon; do
  probe5 "${T}/r5-${v}" "${v}"
done
for v in nomtls nocreds nosecret literal badref badkey otherapp unlisted flagon; do
  pair "rule 5, ${v}" "${T}/r5-${v}" "${T}/r5-good"
done

# 5. THE SABOTAGE CONTROL. Strip rule 1 out of a copy of this very file and
#    require that the pair which depends on it then STOPS failing. If the controls
#    still pass without the logic they exercise, they are theatre — the state
#    adversarial review found a sibling guard in, on this same branch.
SAB="${T}/sabotage.sh"
sed '/^# >>> RULE1$/,/^# <<< RULE1$/c\
rule1() { :; }' "${BASH_SOURCE[0]}" > "${SAB}"

# THE SABOTAGE MUST BE PROVEN TO HAVE HAPPENED. The first version of this block
# used a sed whose delimiter collided with the pattern; sed wrote nothing, bash
# ran an EMPTY file, exited 0, and the control reported PASS. A guard must never
# score a pass off an absent value — least of all the guard whose whole subject
# is a value that was absent.
sab_ready=yes
if [ ! -s "${SAB}" ]; then
  bad "sabotage control: the sabotaged copy is empty — sed produced nothing, so this control proves NOTHING"
  sab_ready=no
elif cmp -s "${SAB}" "${BASH_SOURCE[0]}"; then
  bad "sabotage control: the sabotaged copy is IDENTICAL to the original — the mutation never landed, so this control proves NOTHING"
  sab_ready=no
elif ! bash -n "${SAB}" 2>/dev/null; then
  bad "sabotage control: the sabotaged copy is not valid bash — it would fail for a reason unrelated to rule 1, so this control proves NOTHING"
  sab_ready=no
elif ! grep -q '^rule1() { :; }$' "${SAB}"; then
  bad "sabotage control: rule1 was not blanked as intended — the source shape moved and this control proves NOTHING"
  sab_ready=no
fi

if [ "${sab_ready}" = yes ]; then
  if MTLS_MANIFEST_DIR="${T}/b1" bash "${SAB}" --scan-only >/dev/null 2>&1; then
    ok "sabotage control: with rule 1 blanked, the defective probe is NO LONGER caught — so the controls above really do exercise it"
  else
    bad "sabotage control: the defective probe still 'fails' with rule 1 blanked — the controls are measuring something else"
  fi
fi

# 6. THE SAME SABOTAGE CONTROL FOR RULE 5. Blank rule5() in a copy and require that the
#    probe it exists to catch is then NOT caught — with the mutation proven to have landed.
SAB5="${T}/sabotage5.sh"
sed '/^# >>> RULE5$/,/^# <<< RULE5$/c\
rule5() { :; }' "${BASH_SOURCE[0]}" > "${SAB5}"
if [ ! -s "${SAB5}" ] || cmp -s "${SAB5}" "${BASH_SOURCE[0]}" || ! bash -n "${SAB5}" 2>/dev/null \
   || ! grep -q '^rule5() { :; }$' "${SAB5}"; then
  bad "sabotage control (rule 5): the sabotaged copy is empty, unchanged, invalid or not blanked — this control proves NOTHING"
elif MTLS_MANIFEST_DIR="${T}/r5-nocreds" bash "${SAB5}" --scan-only >/dev/null 2>&1; then
  ok "sabotage control (rule 5): with rule 5 blanked, the credential-less probe is NO LONGER caught — so its controls exercise it"
else
  bad "sabotage control (rule 5): the credential-less probe still 'fails' with rule 5 blanked — the controls are measuring something else"
fi

echo
echo "== outbound mTLS client stores: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
