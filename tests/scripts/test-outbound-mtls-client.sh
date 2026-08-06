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

CLIENT_KEY_PW='hugmesh.mtls.client.key-store-password'
CLIENT_TRUST_PW='hugmesh.mtls.client.trust-store-password'
SERVER_KEY_PW='server.ssl.key-store-password'
SERVER_TRUST_PW='server.ssl.trust-store-password'

violations=()
n_store_builders=0
n_gate_on=0
n_client_pw=0

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
          | grep -qE 'value:[[:space:]]*"?true"?'; then
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
shopt -u nullglob

if [ "${#violations[@]}" -eq 0 ]; then
  ok "every gate-on manifest supplies both client store passwords, matching the server ones"
else
  for v in "${violations[@]}"; do bad "${v}"; done
fi

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
cleanup() { case "$(realpath "${T}" 2>/dev/null)" in /tmp/*|/var/tmp/*) rm -rf "${T}" ;; esac; }
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

echo
echo "== outbound mTLS client stores: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
