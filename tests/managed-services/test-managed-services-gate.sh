#!/usr/bin/env bash
# test-managed-services-gate.sh — hermetic unit test for the MANAGED BACKING
# SERVICES gate (gate_backing_services + helpers) in build-x86-host-stage4.sh,
# modelled on tests/egress-vpn/test-optional-service-gate.sh.
#
# NO real build, NO cloud calls. It EXTRACTS the REAL gate functions from the
# builder (so the test tracks them) and runs them against a FIXTURE tree copied
# from specs/cluster, proving:
#   * registry parse sanity + registry<->builder tier agreement;
#   * DEFAULT byte-identity (empty selection => diff -r EMPTY);
#   * per-service managed proofs (workload pruned, BOTH URL envs rewritten, ESO
#     Secret names kept, unrelated apps survive);
#   * the refusal table (unknown id, tier-3 id with blocker text, malformed/empty
#     endpoint);
#   * the gen-cluster-secrets managed velero block (env -> offline json mirror;
#     blank = omitted; chmod 600).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-x86-host-stage4.sh"
RPI5="${REPO}/build-rpi5-stage4.sh"
REG="${REPO}/specs/cluster/backing-services.yaml"
SRC="${REPO}/specs/cluster"
GEN="${REPO}/scripts/gen-cluster-secrets.sh"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing"; exit 1; }
[ -f "${REG}" ]     || { echo "  FAIL registry missing"; exit 1; }

P=0; F=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# ── Extract the REAL gate functions from the builder (handles one-liners). ──────
extract_fn() {
    awk -v fn="$1" '
        !p && $0 ~ ("^" fn "\\(\\)[[:space:]]*\\{") { p=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next }
        p { print; if ($0 ~ /^\}/) exit }
    ' "${BUILDER}"
}
# Builder-side data (the tier id sets) + no-op logging stubs.
eval "$(grep -E '^_MGD_TIER(12|3)_IDS=' "${BUILDER}")"
info(){ :; }; warn(){ :; }
for fn in _mgd_die _mgd_tier3_blocker _mgd_endpoint _mgd_selected _mgd_is_tier12 \
          _mgd_is_tier3 validate_managed_services _mgd_rewrite_env _mgd_pg \
          _mgd_pg_casdoor _mgd_velero _mgd_fed_bundles _mgd_bake_readme \
          gate_backing_services _opt_drop_kustomize_line; do
    eval "$(extract_fn "${fn}")"
    type "${fn}" >/dev/null 2>&1 || { echo "  FAIL could not extract ${fn}"; exit 1; }
done

echo "== managed backing services gate unit test =="

# ── 1. Registry parse sanity + builder/registry tier agreement ─────────────────
# Needs python3 WITH pyyaml. A python3 that lacks pyyaml (e.g. the offscreen
# PySide6 venv the build-matrix harness puts first on PATH) must SKIP honestly —
# NOT report a false 'registry/builder mismatch' for what is a missing optional dep.
if ! command -v python3 >/dev/null; then
  echo "  SKIP registry assertion (no python3)"
elif ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "  SKIP registry assertion (python3 has no pyyaml)"
else
  BUILDER_TIER12="${_MGD_TIER12_IDS}" BUILDER_TIER3="${_MGD_TIER3_IDS}" \
  python3 - "${REG}" <<'PY' && ok "registry parses; tier-1/2 + tier-3 sets agree with the builder" || bad "registry/builder mismatch"
import os, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["kind"] == "BackingServiceRegistry", "wrong kind"
svcs = {s["id"]: s for s in d["spec"]["services"]}
# tier-1/2 (coded) + tier-3 (docs-only) sets from the YAML tier/docsOnly fields.
t12 = {i for i, s in svcs.items() if int(s["tier"]) in (1, 2)}
t3  = {i for i, s in svcs.items() if int(s["tier"]) == 3}
assert set(os.environ["BUILDER_TIER12"].split()) == t12, f"tier12 mismatch: {t12}"
assert set(os.environ["BUILDER_TIER3"].split())  == t3,  f"tier3 mismatch: {t3}"
# required ids present
need = {"velero-objectstore","smtp","kafka","clickhouse","federation-bundles",
        "postgres-admin-bff","postgres-user-bff","postgres-mod-bff",
        "postgres-forum-bff","postgres-wiki-bff","postgres-casdoor",
        "cassandra","harbor","vault-kv","vault-pki"}
missing = need - set(svcs)
assert not missing, f"registry missing ids: {missing}"
# tier-3 entries are docsOnly + mode-locked self-hosted + carry a blocker
for i in t3:
    s = svcs[i]
    assert s.get("docsOnly") is True, f"{i} not docsOnly"
    assert s.get("modeLocked") == "self-hosted", f"{i} not mode-locked"
    assert s.get("blocker"), f"{i} has no blocker note"
# a Postgres id declares BOTH URL endpointFields
ef = svcs["postgres-admin-bff"]["endpointFields"]
envs = {e.get("env") for e in ef}
assert {"SPRING_R2DBC_URL","SPRING_LIQUIBASE_URL"} <= envs, f"admin-bff endpointFields: {envs}"
PY
fi

# Both builders define + call gate_backing_services (x86 + rpi5 parity).
grep -q 'gate_backing_services()' "${BUILDER}" && grep -q 'gate_backing_services()' "${RPI5}" \
  && ok "gate_backing_services defined in BOTH builders" || bad "gate_backing_services missing from a builder"
grep -qE '^\s*gate_backing_services\b' "${BUILDER}" && grep -qE '^\s*gate_backing_services\b' "${RPI5}" \
  && ok "gate_backing_services CALLED in both builders (after gate_optional_services)" || bad "gate_backing_services not wired into a builder"

# ── Fixture tree: copy the REAL manifests the gate touches into a sysroot. ──────
seed() {
    SYSROOT="${WORK}/sysroot-$1"; rm -rf "${SYSROOT}"
    tree="${SYSROOT}/var/lib/hugmesh/cluster"
    mkdir -p "${tree}/apps" "${tree}/manifests"
    local a m
    for a in 30-admin-bff-db 34-user-bff-db 32-mod-bff-db 38-forum-bff-db 34a-wiki-bff-db \
             35-analytics-kafka 35-analytics-clickhouse 35-analytics-discovery; do
        cp "${SRC}/apps/${a}.yaml" "${tree}/apps/" 2>/dev/null
    done
    for m in admin-bff-api user-bff-api mod-bff-api forum-bff-api wiki-bff-api federation-api \
             observability velero casdoor analytics admin-bff-db user-bff-db mod-bff-db \
             forum-bff-db wiki-bff-db; do
        cp -r "${SRC}/manifests/${m}" "${tree}/manifests/" 2>/dev/null
    done
}

# ── 2. DEFAULT byte-identity: empty selection => zero change (diff -r EMPTY) ────
seed default
cp -r "${tree}" "${WORK}/snapshot"
MANAGED_SERVICES="" gate_backing_services
if diff -r "${WORK}/snapshot" "${tree}" >/dev/null 2>&1; then
    ok "DEFAULT (empty MANAGED_SERVICES): baked tree byte-identical (diff -r empty)"
else
    bad "DEFAULT selection mutated the tree"; diff -r "${WORK}/snapshot" "${tree}" | head
fi
[ -e "${SYSROOT}/etc/hugmesh/backing-services.conf" ] \
    && bad "DEFAULT wrote backing-services.conf (should not)" \
    || ok "DEFAULT: no backing-services.conf baked"

# ── 2b. WHITESPACE-only selection is also byte-identity: word-splitting yields
# zero tokens, so a value that is only tabs/newlines/spaces must NOT bake anything
# (the guard strips ALL whitespace, not just spaces). Regression for the review's
# tab-only finding.
seed default
cp -r "${tree}" "${WORK}/snapshot-ws"
MANAGED_SERVICES="$(printf '\t \n')" gate_backing_services
if diff -r "${WORK}/snapshot-ws" "${tree}" >/dev/null 2>&1 \
   && [ ! -e "${SYSROOT}/etc/hugmesh/backing-services.conf" ]; then
    ok "WHITESPACE-only MANAGED_SERVICES: baked tree byte-identical (no bake)"
else
    bad "WHITESPACE-only selection mutated the tree / baked a conf"
fi

# ── 3a. Managed Postgres (admin-bff): both URLs repointed, DB pruned, ESO kept ─
seed pg
MANAGED_SERVICES="postgres-admin-bff=my.rds.amazonaws.com:5432" gate_backing_services
dep="${tree}/manifests/admin-bff-api/deployment.yaml"
[ ! -f "${tree}/apps/30-admin-bff-db.yaml" ] && ok "pg: DB ArgoCD app pruned" || bad "pg: DB app survived"
[ ! -d "${tree}/manifests/admin-bff-db" ]    && ok "pg: DB manifests dir pruned" || bad "pg: DB manifests survived"
grep -q 'value: "r2dbc:postgresql://my.rds.amazonaws.com:5432/adminbff"' "${dep}" \
    && ok "pg: SPRING_R2DBC_URL repointed to managed endpoint" || bad "pg: R2DBC not rewritten"
grep -q 'value: "jdbc:postgresql://my.rds.amazonaws.com:5432/adminbff"' "${dep}" \
    && ok "pg: SPRING_LIQUIBASE_URL repointed (the second URL — both must change)" || bad "pg: LIQUIBASE not rewritten"
grep -q 'admin-bff-db-app-auth' "${dep}" \
    && ok "pg: ESO Secret names KEPT (admin-bff-db-app-auth still sourced)" || bad "pg: ESO Secret name lost"
# usernames/valueFrom blocks untouched (the rewrite only touched the two value: lines)
grep -q 'SPRING_R2DBC_USERNAME' "${dep}" && ok "pg: unrelated env (USERNAME) untouched" || bad "pg: clobbered USERNAME"

# ── 3b. Kafka: bootstrap repointed, own app+manifests pruned, discovery survives ─
seed kafka
MANAGED_SERVICES="kafka=b-1.msk:9098,b-2.msk:9098" gate_backing_services
kdep="${tree}/manifests/admin-bff-api/deployment.yaml"
grep -q 'value: "b-1.msk:9098,b-2.msk:9098"' "${kdep}" \
    && ok "kafka: SPRING_KAFKA_BOOTSTRAP_SERVERS repointed" || bad "kafka: bootstrap not rewritten"
[ ! -f "${tree}/apps/35-analytics-kafka.yaml" ] && ok "kafka: analytics-kafka app pruned" || bad "kafka: app survived"
[ ! -d "${tree}/manifests/analytics/kafka" ]    && ok "kafka: analytics/kafka manifests pruned" || bad "kafka: manifests survived"
[ -f "${tree}/apps/35-analytics-discovery.yaml" ] \
    && ok "kafka: unrelated analytics-discovery app SURVIVES (only kafka pruned)" || bad "kafka: over-pruned discovery"

# ── 3c. ClickHouse: CLICKHOUSE_URL + uptrace DSN host, clickhouse app pruned ────
seed ch
MANAGED_SERVICES="clickhouse=https://xyz.clickhouse.cloud:8443" gate_backing_services
grep -q 'value: "https://xyz.clickhouse.cloud:8443"' "${tree}/manifests/admin-bff-api/deployment.yaml" \
    && ok "clickhouse: CLICKHOUSE_URL repointed" || bad "clickhouse: URL not rewritten"
grep -q 'clickhouse://snap:${CLICKHOUSE_PASSWORD}@xyz.clickhouse.cloud:8443/uptrace' "${tree}/manifests/observability/deployment.yaml" \
    && ok "clickhouse: uptrace ch.dsn host repointed (password ref + query preserved)" || bad "clickhouse: uptrace DSN not rewritten"
[ ! -f "${tree}/apps/35-analytics-clickhouse.yaml" ] && ok "clickhouse: analytics-clickhouse app pruned" || bad "clickhouse: app survived"

# ── 3d. Velero: BSL doc-0 bucket/region set + s3Url dropped; VSL doc-1 untouched ─
seed velero
MANAGED_VELERO_BUCKET=my-managed-bucket MANAGED_VELERO_REGION=eu-west-1 \
    MANAGED_SERVICES="velero-objectstore=aws" gate_backing_services
bsl="${tree}/manifests/velero/backupstoragelocation.yaml"
grep -q 'bucket: my-managed-bucket' "${bsl}" && ok "velero: BSL bucket set" || bad "velero: bucket not set"
grep -q 'region: eu-west-1' "${bsl}"         && ok "velero: BSL region set" || bad "velero: region not set"
# Grep an ACTIVE (uncommented) s3Url line only — the commented per-brand template
# further down legitimately still mentions s3Url.
grep -qE '^[[:space:]]*s3Url:' "${bsl}" && bad "velero: active s3Url survived for real-AWS (should be dropped)" || ok "velero: active s3Url dropped for endpoint=aws (real S3)"
grep -q 'region: hugmesh' "${bsl}" && ok "velero: the VSL doc-1 region left untouched (only doc-0 rewritten)" || bad "velero: clobbered the VSL region"

# ── 3e. Casdoor PG: DSN host+sslmode flipped, pg.yaml + kustomize line dropped ──
seed casdoor
MANAGED_SERVICES="postgres-casdoor=pg.example.com:5432" gate_backing_services
cm="${tree}/manifests/casdoor/app-conf-configmap.yaml"
grep -q 'host=pg.example.com port=5432' "${cm}" && ok "casdoor: dataSourceName host+port flipped" || bad "casdoor: DSN host not flipped"
grep -q 'sslmode=require' "${cm}" && ok "casdoor: DSN sslmode flipped disable->require" || bad "casdoor: sslmode not flipped"
[ ! -f "${tree}/manifests/casdoor/pg.yaml" ] && ok "casdoor: bundled pg.yaml pruned" || bad "casdoor: pg.yaml survived"
grep -q 'pg.yaml' "${tree}/manifests/casdoor/kustomization.yaml" && bad "casdoor: kustomize pg.yaml line survived" || ok "casdoor: kustomize pg.yaml line dropped"
[ -d "${tree}/manifests/casdoor" ] && ok "casdoor: manifest dir kept (05-casdoor is the IdP, NOT pruned)" || bad "casdoor: over-pruned the IdP dir"

# ── 3f. Federation bundles: storage flag flipped to s3 + S3 env injected ───────
seed fed
MANAGED_SERVICES="federation-bundles=snap-bundles@https://s3.example.com" gate_backing_services
fdep="${tree}/manifests/federation-api/deployment.yaml"
grep -qE 'name: APP_BUNDLES_STORAGE' "${fdep}" && grep -q 'value: "s3"' "${fdep}" \
    && ok "federation-bundles: APP_BUNDLES_STORAGE flipped to s3" || bad "federation-bundles: storage flag not flipped"
grep -q 'APP_BUNDLES_S3_BUCKET' "${fdep}" && grep -q 'value: "snap-bundles"' "${fdep}" \
    && ok "federation-bundles: APP_BUNDLES_S3_BUCKET injected" || bad "federation-bundles: S3 bucket env not injected"
grep -q 'value: "https://s3.example.com"' "${fdep}" \
    && ok "federation-bundles: APP_BUNDLES_S3_ENDPOINT injected" || bad "federation-bundles: S3 endpoint env not injected"

# ── 3g. backing-services.conf baked with the selection (no creds) ──────────────
seed conf
MANAGED_SERVICES="kafka=b-1.msk:9098 smtp=email-smtp.us-east-1.amazonaws.com:587" gate_backing_services
conf="${SYSROOT}/etc/hugmesh/backing-services.conf"
[ -f "${conf}" ] && ok "conf: /etc/hugmesh/backing-services.conf baked" || bad "conf: not baked"
grep -q '^kafka=b-1.msk:9098$' "${conf}" && ok "conf: records kafka=endpoint" || bad "conf: kafka line missing"
grep -q '^smtp=email-smtp.us-east-1.amazonaws.com:587$' "${conf}" && ok "conf: records smtp=endpoint (recorded even w/ no manifest seam)" || bad "conf: smtp line missing"
[ -f "${tree}/README-MANAGED.md" ] && grep -q 'Role-split SQL' "${tree}/README-MANAGED.md" \
    && ok "conf: README-MANAGED.md baked with honesty notes" || bad "conf: README-MANAGED.md missing/incomplete"

# ── 4. Refusal table (fail-closed; validate_managed_services dies) ─────────────
refuse() {  # $1 selection ; $2 expected stderr substring ; $3 label
    ( MANAGED_SERVICES="$1"; validate_managed_services ) 2>"${WORK}/err"; local rc=$?
    if [ "${rc}" -ne 0 ] && grep -qi -- "$2" "${WORK}/err"; then ok "refusal: $3"
    else bad "refusal: $3 (rc=${rc}, stderr='$(cat "${WORK}/err")')"; fi
}
refuse "bogus-service=x"        "unknown backing-service id" "unknown id dies"
refuse "harbor=my.ecr.aws"      "TIER-3"                     "tier-3 (harbor) refused as mode-locked"
refuse "harbor=my.ecr.aws"      "air-gap"                    "tier-3 refusal carries the harbor blocker text"
refuse "vault-pki=acm"          "cert-manager"               "tier-3 refusal carries the vault-pki blocker text"
refuse "kafka"                  "malformed"                  "malformed token (no '=') dies"
refuse "kafka="                 "empty endpoint"             "empty endpoint dies"
refuse "postgres-user-bff=:5432" "no host"                   "bare :port endpoint (no host) dies"
# a valid selection PASSES validation
( MANAGED_SERVICES="kafka=b:9098 postgres-user-bff=h:5432"; validate_managed_services ) 2>/dev/null \
    && ok "validation ACCEPTS a well-formed tier-1/2 selection" || bad "validation rejected a valid selection"

# ── 5. gen-cluster-secrets managed velero block (offline json mirror) ──────────
if command -v python3 >/dev/null && command -v openssl >/dev/null && [ -f "${GEN}" ]; then
  # Enabled: creds -> offline secrets.json velero-cloud-credentials (INI), chmod 600.
  ( cd "${REPO}" && MANAGED_VELERO_ACCESS_KEY_ID=AKIATESTKEY \
      MANAGED_VELERO_SECRET_ACCESS_KEY=s3cr3t/test+key \
      KEYS_FILE=/nonexistent VAULT_ADDR="" \
      bash scripts/gen-cluster-secrets.sh --out "${WORK}/keys-on" ) >/dev/null 2>&1
  SJ="${WORK}/keys-on/secrets.json"
  if [ -f "${SJ}" ]; then
    MODE="$(stat -c '%a' "${SJ}" 2>/dev/null || stat -f '%Lp' "${SJ}" 2>/dev/null)"
    [ "${MODE}" = "600" ] && ok "gen-secrets: offline secrets.json is chmod 600" || bad "gen-secrets: secrets.json mode ${MODE} != 600"
    ENABLED_KEY="${SJ}" python3 - <<'PY' && ok "gen-secrets: ENABLED -> velero-cloud-credentials INI mirrored" || bad "gen-secrets: velero block missing when enabled"
import json, os, sys
d = json.load(open(os.environ["ENABLED_KEY"]))
v = d.get("velero", {}).get("velero-cloud-credentials", {})
cloud = v.get("cloud", "")
assert "AKIATESTKEY" in cloud and "s3cr3t/test+key" in cloud, f"cloud INI wrong: {cloud!r}"
assert "aws_access_key_id" in cloud, "not an INI"
sys.exit(0)
PY
  else
    bad "gen-secrets: no secrets.json produced (enabled run)"
  fi
  # Disabled: no velero env => NO velero key in the offline bundle.
  ( cd "${REPO}" && KEYS_FILE=/nonexistent VAULT_ADDR="" \
      bash scripts/gen-cluster-secrets.sh --out "${WORK}/keys-off" ) >/dev/null 2>&1
  SJ2="${WORK}/keys-off/secrets.json"
  if [ -f "${SJ2}" ]; then
    DISABLED_KEY="${SJ2}" python3 - <<'PY' && ok "gen-secrets: DISABLED (blank creds) -> velero block OMITTED entirely" || bad "gen-secrets: velero block present when disabled"
import json, os, sys
d = json.load(open(os.environ["DISABLED_KEY"]))
assert "velero" not in d, "velero present when it should be omitted"
sys.exit(0)
PY
  else
    bad "gen-secrets: no secrets.json produced (disabled run)"
  fi
else
  echo "  SKIP gen-cluster-secrets managed block (need python3+openssl)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
