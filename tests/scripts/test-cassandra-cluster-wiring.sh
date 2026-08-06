#!/usr/bin/env bash
# test-cassandra-cluster-wiring.sh — the Cassandra half of the GitOps payload
# must be able to talk to its own database. Pure PyYAML + bash; no cluster, no
# kubectl, no docker, no network.
#
# WHY THIS EXISTS. The first time the cluster payload was ever stood up on a real
# kind cluster (docs/KIND-SSO-E2E-FINDINGS.md) two of the sixteen fresh-cluster
# blockers were Cassandra, and between them they meant NO GATEWAY COULD EVER
# START — not slowly, not degraded, never:
#
#   #5  The bitnami cassandra image defaults CASSANDRA_AUTHENTICATOR to
#       PasswordAuthenticator. The chart passed no credentials to anything, so
#       every gateway died in bean creation on "requires authentication
#       (org.apache.cassandra.auth.PasswordAuthenticator), but no authenticator
#       configured" -> CrashLoopBackOff. The per-app least-privilege roles that
#       existed for exactly this purpose were parked in a DARK overlay wired to
#       nothing, behind a header asserting the server had no authenticator at all.
#   #6  Nothing cluster-side created the keyspaces. `grep -r 'CREATE KEYSPACE'
#       specs/cluster` returned nothing, and Spring's schema-action
#       CREATE_IF_NOT_EXISTS creates TABLES, never keyspaces — so the next error
#       after auth was `InvalidKeyspaceException: Invalid keyspace
#       snapdragon_gateway`. compose.local.yaml has had a cassandra-init service
#       doing exactly this for years, with a comment describing the bug.
#
# Three more defects of the same family were found while fixing those, and this
# gate covers them too, because each was invisible to every existing check:
#
#   * admin-bff-api's manifest set CASSANDRA_CONTACT_POINTS, an env that binds to
#     NOTHING in that image (it reads ${ROUTE_MIRROR_CASSANDRA}). Its route mirror
#     defaults ENABLED and swallows failures, so it silently dialled the
#     pre-rebrand snapdragon-pki DNS and wrote no gateway_route_access or
#     url_registry rows at all. Hence [creds] keys off the VALUE being a cassandra
#     host, not off the env's name.
#   * The dark overlay's grant matrix made the gateways SELECT-only readers. Their
#     image runs a CQL schema-migration runner (CREATE TABLE + ALTER TABLE), so
#     applying it would have swapped the auth failure for an authorization one.
#     THIS IS THE ONE A PRESENCE CHECK CANNOT SEE, and the reason the [role]
#     section below asserts a MATRIX rather than the existence of a grant. Every
#     role in that overlay was created, and every role held a GRANT naming the
#     keyspace it used; the matrix was simply the wrong way round. So each
#     consumer DECLARES its CQL permission class next to the credential it uses
#     (cassandra.access in the gateway Applications, the
#     snapdragon.systems/cassandra-access pod annotation in the plain manifests)
#     and the bootstrap's grants are checked against it for SET EQUALITY — too
#     few permissions and too many are both build failures, on either side of the
#     contract. The first control in that block re-lands that historical matrix
#     verbatim.
#   * apps/00-cassandra.yaml named the datacenter dc1 while the chart-default
#     SimpleSnitch always advertises datacenter1 — federation-api believed the
#     manifest and would have thrown NoNodeAvailableException the moment its cache
#     was enabled.
#
# The rule this gate encodes: a workload that dials Cassandra is emitted WITH
# credentials, from a Secret its own namespace really gets, seeded on BOTH
# delivery paths, naming a keyspace and a role that a bootstrap the cluster
# actually runs really creates — or the build fails.
#
# Every check carries a NEGATIVE CONTROL below: the assertion is re-run against a
# staged copy of the tree with that one defect planted, and MUST fail there. Each
# injection asserts that it actually applied, so a mutation that silently failed
# to match is reported as a broken control rather than scored as a pass.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$(dirname "${BASH_SOURCE[0]}")/cassandra_cluster_wiring.py"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

echo "== cassandra cluster-wiring gate =="
echo "-- positive: the repo's own tree must pass every check --"
python3 "${CHECKER}" "${REPO}"
if [ $? -ne 0 ]; then
  echo
  echo "== cassandra cluster wiring: FAIL (see above) =="
  exit 1
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
echo
echo "-- negative controls: each injected defect must be caught --"
NEG_P=0; NEG_F=0
neg_ok(){  echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad(){ echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# The checker reads specs/cluster, scripts/gen-cluster-secrets.sh and
# templates/apps — stage exactly those so a control is cheap.
stage_tree() {
  local T="$1"
  rm -rf "${T}"; mkdir -p "${T}/specs" "${T}/scripts" "${T}/templates"
  cp -r "${REPO}/specs/cluster"                 "${T}/specs/cluster"
  cp    "${REPO}/scripts/gen-cluster-secrets.sh" "${T}/scripts/"
  cp -r "${REPO}/templates/apps"                "${T}/templates/apps"
}

# $1 = label, $2 = expected check-id, $3 = shell snippet with $T = staged root.
expect_catch() {
  local label="$1" want="$2" inject="$3"
  local T="${WORK}/tree"
  stage_tree "${T}"
  if ! ( T="${T}"; eval "${inject}" ); then
    neg_bad "${label} (injection itself failed — control proves nothing)"
    return
  fi
  local out rc
  out="$(python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
  # -F: the check ids contain [] and -, which grep would read as a bracket range.
  if [ "${rc}" -ne 0 ] && grep -qF "  FAIL ${want}" <<<"${out}"; then
    neg_ok "${label} -> caught by ${want}"
  else
    neg_bad "${label} NOT caught (rc=${rc}); wanted ${want}. Output:"
    sed 's/^/        /' <<<"${out}" | tail -20
  fi
}

# A python one-liner helper: replace EXACTLY once, or exit non-zero so the
# control reports "injection itself failed" instead of scoring a false PASS.
sub() { # sub <file> <old> <new>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(f"injection anchor found {s.count(old)} times in {p}, wanted exactly 1")
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
}
export -f sub

# add_cql <staged-root> <statement>… — append CQL AFTER every existing statement,
# so the injected statement is the last word on the matrix. Used by the
# permission-matrix controls: they must bite on the EFFECTIVE grant set, not on
# the presence of some text somewhere in the file.
add_cql() {
  python3 - "$@" <<'PY'
import sys
p = sys.argv[1] + "/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml"
tail = '    echo "==> cassandra bootstrap complete'
s = open(p, encoding="utf-8").read()
if s.count(tail) != 1:
    sys.exit("tail anchor found %d times, wanted 1" % s.count(tail))
block = "".join('    cql "%s"\n' % a for a in sys.argv[2:])
open(p, "w", encoding="utf-8").write(s.replace(tail, block + tail, 1))
PY
}
export -f add_cql

# ── #5: the credentials themselves ───────────────────────────────────────────
expect_catch "gateway Application with no Cassandra username (the shipped bug)" "[creds]" '
  sub "$T/specs/cluster/apps/20-gateway-fe.yaml" "          username: fe_gw_cass" "          username: \"\""
'
expect_catch "gateway credential half-wired (username, no Secret key)" "[creds]" '
  sub "$T/specs/cluster/apps/20-gateway-be.yaml" "          passwordSecretKey: be-gateway" "          passwordSecretKey: \"\""
'
expect_catch "Cassandra password committed as a literal instead of a secretKeyRef" "[creds]" '
  sub "$T/specs/cluster/manifests/admin-bff-api/deployment.yaml" \
      "            - name: CASSANDRA_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: cassandra-app-creds
                  key: admin-bff" \
      "            - name: CASSANDRA_PASSWORD
              value: \"hunter2\""
'
expect_catch "credentials wired but the driver told not to send them" "[creds]" '
  sub "$T/specs/cluster/manifests/admin-bff-api/deployment.yaml" \
      "{ name: CASSANDRA_AUTH_ENABLED, value: \"true\" }" \
      "{ name: CASSANDRA_AUTH_ENABLED, value: \"false\" }"
'
expect_catch "consumer mounts a Secret its own namespace never gets" "[creds-secret]" '
  sub "$T/specs/cluster/manifests/external-secrets/cassandra-externalsecrets.yaml" \
      "  name: cassandra-app-creds
  namespace: hugmesh-frontend" \
      "  name: cassandra-app-creds
  namespace: hugmesh-pki-typo"
'

# ── the two delivery paths (blocker #3 was this exact shape) ────────────────
expect_catch "Vault seeding missing one property of a live ExternalSecret" "[seed]" '
  sub "$T/scripts/gen-cluster-secrets.sh" \
      "            superadmin-gateway=\"\${CASSANDRA_APP_SUPERADMIN_GATEWAY_PASSWORD}\" \\
" ""
'
expect_catch "offline USB bundle missing a key the Vault path has" "[seed]" '
  sub "$T/scripts/gen-cluster-secrets.sh" \
      "            \"fe-gateway\": os.environ[\"CASSANDRA_APP_FE_GATEWAY_PASSWORD\"],
        },
        \"bff-internal-token\": {" \
      "        },
        \"bff-internal-token\": {"
'

# ── #6: the keyspace/role bootstrap ─────────────────────────────────────────
expect_catch "keyspace a consumer uses is never created (the shipped bug)" "[keyspace]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml" \
      "CREATE KEYSPACE IF NOT EXISTS snapdragon_gateway WITH" \
      "CREATE KEYSPACE IF NOT EXISTS snapdragon_gateway_typo WITH"
'
expect_catch "role a consumer authenticates as is never created" "[role]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml" \
      "    create_role federation_cass FEDERATION_CASS_PASSWORD" \
      "    create_role federation_typo FEDERATION_CASS_PASSWORD"
'
expect_catch "role created but never GRANTed (deny-by-default authorizer)" "[role]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml" \
      "    for r in pki_gw_cass be_gw_cass fe_gw_cass sa_gw_cass; do" \
      "    for r in pki_gw_cass be_gw_cass sa_gw_cass; do"
'
# ── THE PERMISSION MATRIX ───────────────────────────────────────────────────
# The controls above prove a role is CREATEd and GRANTed something. That is the
# check this gate was rejected for: it scored the shipped backwards matrix green.
# Everything below asserts WHICH permission each principal holds on WHICH
# keyspace, so each of these lands a fully-formed grant matrix in which every role
# still has a grant naming its own keyspace.
expect_catch "the shipped backwards matrix, re-landed verbatim from the deleted overlay" "[role]" '
  python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml"
# Lifted VERBATIM from origin/main manifests/cassandra-hardening/
# bootstrap-roles-configmap.yaml, the dark overlay this branch deleted: the four
# gateways as SELECT-only readers and admin-bff as the writer. Every role holds a
# grant on its keyspace, so a presence check passes; the gateway image runs the
# CQL migration runner, so on a real cluster this dies on the first CREATE TABLE.
historical = """    # snapdragon_gateway: admin-bff writes the URL registry; gateways read.
    cql "GRANT MODIFY ON KEYSPACE snapdragon_gateway TO admin_bff_cass;"
    cql "GRANT SELECT ON KEYSPACE snapdragon_gateway TO admin_bff_cass;"
    for r in pki_gw_cass be_gw_cass fe_gw_cass sa_gw_cass; do
      cql "GRANT SELECT ON KEYSPACE snapdragon_gateway TO \${r};"
    done
    # snapdragon_federation: federation-api owns its manifest cache (r/w).
    cql "GRANT MODIFY ON KEYSPACE snapdragon_federation TO federation_cass;"
    cql "GRANT SELECT ON KEYSPACE snapdragon_federation TO federation_cass;"
"""
s = open(p, encoding="utf-8").read()
head = "    for r in pki_gw_cass"
tail = "    echo \"==> cassandra bootstrap complete"
if s.count(head) != 1 or s.count(tail) != 1:
    sys.exit("grant-block anchors not found exactly once")
open(p, "w", encoding="utf-8").write(s[:s.index(head)] + historical + "\n" + s[s.index(tail):])
PY
'
expect_catch "gateways left ONE permission short (ALTER) — three of four still granted" "[role]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml" \
      "      cql \"GRANT ALTER  ON KEYSPACE snapdragon_gateway TO \${r};\"
" ""
'
expect_catch "a later REVOKE quietly takes back a correct GRANT" "[role]" '
  add_cql "$T" "REVOKE MODIFY ON KEYSPACE snapdragon_gateway FROM be_gw_cass;"
'
expect_catch "DROP handed to a role whose declared class is DML-only" "[role]" '
  add_cql "$T" "GRANT DROP ON KEYSPACE snapdragon_gateway TO admin_bff_cass;"
'
expect_catch "a role granted on a keyspace its consumer never dials" "[role]" '
  add_cql "$T" "GRANT SELECT ON KEYSPACE snapdragon_gateway TO federation_cass;"
'
expect_catch "ALL PERMISSIONS ON ALL KEYSPACES beside the correct grants" "[role]" '
  add_cql "$T" "GRANT ALL PERMISSIONS ON ALL KEYSPACES TO federation_cass;"
'
expect_catch "role-to-role inheritance instead of a permission grant" "[role]" '
  add_cql "$T" "GRANT admin_bff_cass TO fe_gw_cass;"
'
expect_catch "a permission CQL does not accept on a KEYSPACE resource" "[role]" '
  add_cql "$T" "GRANT EXECUTE ON KEYSPACE snapdragon_gateway TO fe_gw_cass;"
'
expect_catch "application roles created as cluster SUPERUSERs" "[role]" '
  python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml"
s = open(p, encoding="utf-8").read()
if s.count("SUPERUSER = false") != 2:
    sys.exit("expected 2 SUPERUSER = false, found %d" % s.count("SUPERUSER = false"))
open(p, "w", encoding="utf-8").write(s.replace("SUPERUSER = false", "SUPERUSER = true"))
PY
'
expect_catch "two consumers collapsed onto one shared role" "[role]" '
  sub "$T/specs/cluster/apps/20-gateway-fe.yaml" "          username: fe_gw_cass" "          username: be_gw_cass"
'
expect_catch "a seventh, unowned privileged login role" "[role]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml" \
      "    create_role federation_cass FEDERATION_CASS_PASSWORD" \
      "    create_role federation_cass FEDERATION_CASS_PASSWORD
    create_role ops_cass        FEDERATION_CASS_PASSWORD" &&
  add_cql "$T" "GRANT SELECT ON KEYSPACE snapdragon_gateway TO ops_cass;"
'
expect_catch "declared class promoted without touching a single GRANT" "[role]" '
  sub "$T/specs/cluster/manifests/admin-bff-api/deployment.yaml" \
      "snapdragon.systems/cassandra-access: dml" \
      "snapdragon.systems/cassandra-access: schema-owner"
'
expect_catch "consumer declares no permission class at all" "[role]" '
  sub "$T/specs/cluster/manifests/admin-bff-api/deployment.yaml" \
      "        snapdragon.systems/cassandra-access: dml
" ""
'
expect_catch "gateway Application declares no permission class" "[role]" '
  sub "$T/specs/cluster/apps/22-gateway-superadmin.yaml" \
      "          access: schema-owner
" ""
'
expect_catch "the role password the bootstrap SETS is not the one the consumer SENDS" "[creds-secret]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-job.yaml" \
      "            - name: ADMIN_BFF_CASS_PASSWORD
              valueFrom: { secretKeyRef: { name: cassandra-app-creds, key: admin-bff } }" \
      "            - name: ADMIN_BFF_CASS_PASSWORD
              valueFrom: { secretKeyRef: { name: cassandra-app-creds, key: federation } }"
'
expect_catch "a role password the bootstrap Job never supplies" "[creds]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-job.yaml" \
      "            - name: SA_GW_CASS_PASSWORD
              valueFrom: { secretKeyRef: { name: cassandra-app-creds, key: superadmin-gateway } }
" ""
'
expect_catch "a role password the script stops requiring, so an empty value would pass" "[creds]" '
  sub "$T/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml" \
      "    require FEDERATION_CASS_PASSWORD  \"federation-api\"
" ""
'
expect_catch "a CREATE TABLE ordered before the keyspace that holds it" "[order]" '
  python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml"
s = open(p, encoding="utf-8").read()
ks = "    cql \"CREATE KEYSPACE IF NOT EXISTS snapdragon_federation WITH replication = \${KEYSPACE_REPLICATION};\"\n"
tbl_head = "    cql \"CREATE TABLE IF NOT EXISTS snapdragon_federation.federation_manifest ("
if s.count(ks) != 1 or s.count(tbl_head) != 1:
    sys.exit("anchors not found exactly once")
i = s.index(tbl_head)
j = s.index("\n", s.index("         );\"", i)) + 1
tbl = s[i:j]
s = s.replace(tbl, "", 1).replace(ks, tbl + ks, 1)
open(p, "w", encoding="utf-8").write(s)
PY
'
expect_catch "chart stops publishing the declared class onto the pod" "[chart]" '
  sub "$T/specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml" \
      "        snapdragon.systems/cassandra-access: {{ .Values.cassandra.access | quote }}" \
      "        snapdragon.systems/cassandra-audited: \"yes\""
'
expect_catch "chart lets an unclassified role render instead of failing" "[chart]" '
  python3 - "$T" <<PY
import re, sys
p = sys.argv[1] + "/specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml"
s = open(p, encoding="utf-8").read()
m = re.search(r"\{\{- if not \(has \.Values\.cassandra\.access.*?\{\{- end \}\}\n", s, re.S)
if not m:
    sys.exit("access-class fail() guard not found")
open(p, "w", encoding="utf-8").write(s.replace(m.group(0), "", 1))
PY
'

expect_catch "GRANT ordered before the CREATE KEYSPACE it names" "[order]" '
  python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml"
s = open(p, encoding="utf-8").read()
line = "    cql \"CREATE KEYSPACE IF NOT EXISTS snapdragon_federation WITH replication = \${KEYSPACE_REPLICATION};\"\n"
if s.count(line) != 1:
    sys.exit("anchor not found exactly once")
s = s.replace(line, "", 1)
anchor = "    echo \"==> cassandra bootstrap complete"
if s.count(anchor) != 1:
    sys.exit("tail anchor not found")
s = s.replace(anchor, line + anchor, 1)
open(p, "w", encoding="utf-8").write(s)
PY
'
expect_catch "bootstrap Application left manual-sync (would never run)" "[bootstrap]" '
  sub "$T/specs/cluster/apps/00b-cassandra-init.yaml" \
      "    automated: { prune: true, selfHeal: true }
" ""
'
expect_catch "bootstrap overlay renders only half its objects" "[bootstrap]" '
  sub "$T/specs/cluster/manifests/cassandra-init/kustomization.yaml" \
      "  - bootstrap-job.yaml         # PostSync hook that runs it" ""
'
expect_catch "bootstrap Job not admitted by the default-deny Cassandra policy" "[bootstrap]" '
  sub "$T/specs/cluster/manifests/networkpolicy/db-ingress.yaml" \
      "            matchLabels: { app: cassandra-bootstrap }" \
      "            matchLabels: { app: cassandra-bootstrap-typo }"
'
expect_catch "whole bootstrap overlay deleted (the pre-fix state)" "[bootstrap]" '
  rm -rf "$T/specs/cluster/manifests/cassandra-init"
'

# ── the datacenter name every client has to agree on ────────────────────────
expect_catch "consumer local-dc disagrees with what the snitch advertises" "[local-dc]" '
  sub "$T/specs/cluster/manifests/federation-api/deployment.yaml" \
      "            - name: MANIFEST_CACHE_LOCAL_DC
              value: \"datacenter1\"" \
      "            - name: MANIFEST_CACHE_LOCAL_DC
              value: \"dc1\""
'
expect_catch "server manifest names a datacenter SimpleSnitch cannot advertise" "[local-dc]" '
  sub "$T/specs/cluster/apps/00-cassandra.yaml" "          datacenter: datacenter1" "          datacenter: dc1"
'

# ── the chart is the shared surface: it must not let half-wiring render ─────
expect_catch "chart stops emitting the credential env" "[chart]" '
  sub "$T/specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml" \
      "            - name: SPRING_CASSANDRA_USERNAME" "            - name: CASSANDRA_USER"
'
expect_catch "chart makes a missing Secret coordinate a silent default" "[chart]" '
  python3 - "$T" <<PY
import sys, re
p = sys.argv[1] + "/specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml"
s = open(p, encoding="utf-8").read()
n = s.count("required \"cassandra.password")
if n != 2:
    sys.exit("expected 2 required() guards, found %d" % n)
s = re.sub("required \"cassandra\\\\.password[^\"]*\" ", "", s)
if s.count("required \"cassandra.password") != 0:
    sys.exit("required() guards were not removed")
open(p, "w", encoding="utf-8").write(s)
PY
'
expect_catch "an Application hands helm values this gate cannot read" "[chart]" '
  sub "$T/specs/cluster/apps/20-gateway-pki.yaml" \
      "      releaseName: hugmesh-pki-gateway" \
      "      valueFiles: [secret-values.yaml]
      releaseName: hugmesh-pki-gateway"
'

# ── the declared brand-template exemption must stay all-or-nothing ──────────
expect_catch "brand gateway template declares half a Cassandra credential" "[brand]" '
  sub "$T/templates/apps/20-gateway-be.yaml.hbs" \
      "        instance:" \
      "        cassandra:
          username: be_gw_cass
        instance:"
'
expect_catch "brand gateway template brings a credential but no permission class" "[brand]" '
  sub "$T/templates/apps/20-gateway-be.yaml.hbs" \
      "        instance:" \
      "        cassandra:
          username: be_gw_cass
          passwordSecretKey: be-gateway
        instance:"
'

# ── vacuity: if the consumer scan finds nothing, that is a FAILURE ──────────
expect_catch "consumer scan silently finds nothing (vacuous pass)" "[input]" '
  python3 - "$T" <<PY
import os, sys
root = sys.argv[1] + "/specs/cluster"
host = "cassandra.hugmesh-pki.svc.cluster.local"
n = 0
for dp, _d, fs in os.walk(root):
    for f in fs:
        if not f.endswith((".yaml", ".yml")):
            continue
        p = os.path.join(dp, f)
        s = open(p, encoding="utf-8").read()
        if host not in s:
            continue
        open(p, "w", encoding="utf-8").write(s.replace(host, "not" + host))
        n += 1
if n < 3:
    sys.exit("only %d file(s) had a contact point neutralised — control proves nothing" % n)
PY
'

echo
echo "-- negative controls: ${NEG_P} passed, ${NEG_F} failed --"
if [ "${NEG_F}" -ne 0 ]; then
  echo "== cassandra cluster wiring: FAIL (a control did not bite; the gate may be vacuous) =="
  exit 1
fi
echo "== cassandra cluster wiring: PASS =="
