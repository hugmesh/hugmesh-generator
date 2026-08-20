#!/usr/bin/env bash
# test-eso-seed-contract.sh — cross-check EVERY ExternalSecret under
# specs/cluster against what scripts/gen-cluster-secrets.sh actually provisions,
# on BOTH delivery paths. Pure bash + python3 + PyYAML; no cluster, no kubectl,
# no vault binary, no docker, no network.
#
# WHY THIS EXISTS. gen-cluster-secrets.sh is the ONLY thing that provisions
# cluster secrets — ONLINE (`vault kv put`) and OFFLINE (the USB secrets.json
# bundle). The ExternalSecrets under specs/cluster declare what the cluster
# READS. Nothing in CI ever compared the two, and the two drifted:
#
#   route-access-db-roles + route-access-superadmin-gateway both read property
#   `superadmin_gateway_password` of secret/hugmesh/route-access-db. The script
#   minted FIVE route-access passwords; SIX are required. Real ESO controller
#   log, kind cluster, 2026-08-05:
#
#     error retrieving secret at .data[5], key: hugmesh/route-access-db,
#     err: cannot find secret data for key: "superadmin_gateway_password"
#
#   ESO resolves an ExternalSecret ALL-OR-NOTHING, so ONE missing property did
#   not cost one key — it cost the WHOLE Secret. route-access-db-roles was never
#   created, route-access-db sat in CreateContainerConfigError forever, the
#   gateway_route_access table (the SOURCE OF TRUTH for all route authorization)
#   never existed, and every gateway silently fell back to its baked
#   CanonicalSeed. That reproduces on ANY cluster provisioned from scratch, by
#   EITHER delivery path.
#
# A one-line data fix for that one property would be worthless: the same class
# recurs every time someone adds a property, a Secret or a namespace to an
# ExternalSecret without touching the seeder. So this gate checks the CONTRACT,
# not the instance — it runs the REAL gen-cluster-secrets.sh under a `vault`
# stub, captures both delivery products, and asserts every single
# {key, property} and every materialized Secret key is covered.
#
# SCOPE — the claim and the behaviour are one sentence. EVERY ExternalSecret
# under specs/cluster is walked, not just manifests/external-secrets: the
# cassandra-hardening overlay and manifests/cloudflared hold four more, and they
# were unguarded. A file is CHECKED when its own directory's kustomization.yaml
# lists it in `resources:`; anything else is reported under [not-rendered]. A
# DARK overlay (no ArgoCD Application points at it) is still checked — its
# objects are real and an operator applies them by hand at flip time, which is
# exactly when an unseeded reference bites.
#
# CLASSIFICATION IS PER REFERENCE. An ExternalSecret whose cert comes from a
# Vault-PKI generator may ALSO carry spec.data[] KV remoteRefs; those are
# checked, and the offline-bundle expectations still apply to every Secret key
# the template derives from them. Only generator-derived keys are out of scope.
#
# HONEST SCOPE. Some references are NOT the seeder's job — Vault-PKI generator
# certs, operator-provisioned homeserver admin tokens, the Cloudflare tunnel
# token off the keys USB, in-cluster-minted Harbor robot creds, and files no
# kustomization applies. The checker CLASSIFIES those explicitly and PRINTS every
# one with its reason instead of whitelisting them silently, and a classification
# entry cannot outlive the reference it excuses.
#
# CONDITIONAL MEANS PROVEN CONDITIONAL. A reference a DEFAULT provisioning run
# cannot satisfy is not waved through: the gate runs gen-cluster-secrets.sh once
# per declared optional feature, in ISOLATION, and an entry may only be excused
# if one of those flags — on its own — is what makes it appear, AND that
# feature's seeder guard line and its manifest's own "may not materialize"
# statement both still exist.
#
# DOMAIN COUPLING. specs/cluster is NOT what a cluster runs: build-*-stage4.sh
# copies it to /var/lib/hugmesh/cluster and rebrand_sysroot() then seds
# `hugmesh.net` -> `${CLUSTER_DOMAIN}` across that whole tree. So a template
# literal embedding the default domain is really `<x>@${CLUSTER_DOMAIN}` online,
# and the offline bundle must derive it the same way. Comparing the repo manifest
# to a default-brand bundle cannot see that (both read hugmesh.net), so the
# gate runs the seeder a FIFTH time under a non-default CLUSTER_DOMAIN and
# requires every domain-bearing literal to move with it — and every domain-free
# literal to stay put.
#
# WHAT IS NOT ASSERTED: whether a correctly-shaped value is the RIGHT value.
# Names must resolve, literals must match byte-for-byte, domain-bearing literals
# must track CLUSTER_DOMAIN, and nothing may be blank with every feature on — but
# this gate does not judge password strength or whether an OAuth placeholder was
# replaced. That belongs to the provisioning tests.
#
# NEGATIVE CONTROLS. Each check is re-run against a deliberately-broken copy of
# the inputs and MUST bite, so a green run cannot be vacuous.
#
# Needs: bash, python3 + PyYAML, openssl (gen-cluster-secrets.sh mints with it).
# A MISSING TOOL IS A HARD FAILURE, not a skip: a gate that exits 0 when its
# interpreter is absent is a gate that has never run (tests/stack/
# test-m2-bootstrap.sh's .stack-src SKIP hid three auth-core pin drifts exactly
# that way). Set ESO_SEED_CONTRACT_ALLOW_SKIP=1 to opt out DELIBERATELY on a
# workstation that lacks the tooling; CI never sets it, and control (t3) below
# proves .gitlab-ci.yml cannot.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GCS="${REPO}/scripts/gen-cluster-secrets.sh"
CLUSTER="${REPO}/specs/cluster"
CI_FILE="${REPO}/.gitlab-ci.yml"
CHECKER="$(dirname "${BASH_SOURCE[0]}")/eso_seed_contract.py"

# ── tool preflight: HARD FAILURE unless an explicit opt-out is set ───────────
MISSING=""
for t in python3 openssl; do
    command -v "${t}" >/dev/null || MISSING="${MISSING} ${t}"
done
if [ -z "${MISSING}" ] && ! python3 -c 'import yaml' 2>/dev/null; then
    MISSING="${MISSING} python3-PyYAML"
fi
if [ -n "${MISSING}" ]; then
    if [ "${ESO_SEED_CONTRACT_ALLOW_SKIP:-0}" = "1" ]; then
        echo "SKIP: missing${MISSING} and ESO_SEED_CONTRACT_ALLOW_SKIP=1 was set"
        echo "      (DELIBERATE local opt-out. CI never sets this variable, so the"
        echo "       gate cannot skip there — see .gitlab-ci.yml lint:eso-seed-contract.)"
        exit 0
    fi
    echo "  FAIL missing required tool(s):${MISSING}"
    echo "       This gate compares gen-cluster-secrets.sh's real output against every"
    echo "       ExternalSecret; without them it cannot run, and exiting 0 would report"
    echo "       a contract as satisfied that was never checked. Install them, or set"
    echo "       ESO_SEED_CONTRACT_ALLOW_SKIP=1 to opt out deliberately (never in CI)."
    exit 1
fi

[ -f "${GCS}" ]     || { echo "  FAIL gen-cluster-secrets.sh missing: ${GCS}"; exit 1; }
[ -d "${CLUSTER}" ] || { echo "  FAIL specs/cluster missing: ${CLUSTER}"; exit 1; }
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── the `vault` stub ─────────────────────────────────────────────────────────
# gen-cluster-secrets.sh takes its ONLINE path only when VAULT_ADDR + VAULT_TOKEN
# are set AND `command -v vault` succeeds. Recording the real argv beats grepping
# the script: it captures what the script ACTUALLY invokes, including anything
# built up in an array or emitted from a conditional branch.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/vault" <<'STUB'
#!/usr/bin/env bash
python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1:])+"\n")' "$@" \
    >> "${VAULT_STUB_LOG}"
exit 0
STUB
chmod +x "${WORK}/bin/vault"

echo "== ESO seed contract: gen-cluster-secrets.sh vs every ExternalSecret in specs/cluster =="

# ── produce both delivery products, once per provisioning scenario ───────────
# default        every optional feature off (what a plain build provisions).
# mail           ONLY outbound mail on.
# managed-velero ONLY the managed object-store creds on.
# all-features   everything on.
# The two ISOLATED feature runs are what make a "conditional" classification
# evidence-based: an entry may be excused only if ONE named flag, alone, is what
# makes it appear. Without them "conditional" is an auto-pass.
# KEYS_FILE is pointed at a path that does not exist so a developer's real
# keys-out/secrets/cluster-creds.json cannot influence the result, and --out
# keeps the run entirely inside the temp dir (keys-out is never touched).
RUNS="${WORK}/runs"
MAIL_ENV=(MAIL_PROVIDER=smtp MAIL_HOST=smtp.example.invalid
          MAIL_USER=seed-contract-gate MAIL_PASSWORD=seed-contract-gate)
VELERO_ENV=(MANAGED_VELERO_ACCESS_KEY_ID=seed-contract-gate
            MANAGED_VELERO_SECRET_ACCESS_KEY=seed-contract-gate)

run_gen() { # run_gen <label> <cluster-domain> [extra env assignments...]
    local label="$1" domain="$2"; shift 2
    local dir="${RUNS}/${label}"
    mkdir -p "${dir}"
    # Recorded so the checker knows which domain produced this bundle; without it
    # [domain-coupled] cannot tell a CLUSTER_DOMAIN-tracking value from a
    # hardcoded one, and it fails rather than assume.
    printf '%s\n' "${domain}" > "${dir}/cluster-domain"
    if ! env "$@" \
            PATH="${WORK}/bin:${PATH}" \
            CLUSTER_DOMAIN="${domain}" \
            VAULT_STUB_LOG="${dir}/vault.log" \
            VAULT_ADDR="https://vault.invalid:8200" \
            VAULT_TOKEN="stub-token-for-the-seed-contract-gate" \
            KEYS_FILE="${WORK}/no-such-keys-file.json" \
            bash "${GCS}" --out "${dir}/bundle" >"${dir}/stdout.log" 2>&1; then
        bad "(a) gen-cluster-secrets.sh (${label}) exited non-zero"
        sed 's/^/        /' "${dir}/stdout.log" | tail -20
        return 1
    fi
    [ -s "${dir}/vault.log" ] || { bad "(a) ${label}: no \`vault kv put\` was recorded — the ONLINE path did not run"; return 1; }
    [ -s "${dir}/bundle/secrets.json" ] || { bad "(a) ${label}: no offline bundle at ${dir}/bundle/secrets.json"; return 1; }
    return 0
}
die_early() { echo; echo "== ESO seed contract: ${P} passed, $((F+1)) failed =="; exit 1; }

# The seeder's OWN default domain, read from the script rather than repeated here
# (the checker parses the same line, and fails if it is gone).
DEFAULT_DOMAIN="$(sed -n 's/^CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-\([^}"]*\)}"/\1/p' "${GCS}" | head -1)"
if [ -z "${DEFAULT_DOMAIN}" ]; then
    bad "(a) could not read the seeder's default CLUSTER_DOMAIN from ${GCS}"
    die_early
fi
# A domain that is DIFFERENT from the default and cannot resolve anywhere.
PROBE_DOMAIN="rebrand-probe.invalid"

run_gen default        "${DEFAULT_DOMAIN}"                           || die_early
run_gen mail           "${DEFAULT_DOMAIN}" "${MAIL_ENV[@]}"          || die_early
run_gen managed-velero "${DEFAULT_DOMAIN}" "${VELERO_ENV[@]}"        || die_early
run_gen all-features   "${DEFAULT_DOMAIN}" "${MAIL_ENV[@]}" "${VELERO_ENV[@]}" || die_early
# The REBRAND PROBE: a plain default run under a NON-default CLUSTER_DOMAIN. The
# baked manifests are sed'd hugmesh.net -> ${CLUSTER_DOMAIN} by
# rebrand_sysroot(), so any template literal embedding the domain must move with
# it in the bundle too. Nothing but [domain-coupled] reads this run.
run_gen rebranded      "${PROBE_DOMAIN}"                             || die_early
ok "(a) ran the REAL gen-cluster-secrets.sh 5x (default / mail-only / managed-velero-only / all-on / rebranded-domain) under a vault stub"

# Every run must be non-trivial, or every later assertion could pass vacuously.
BASE_PUTS="$(grep -c '"kv"' "${RUNS}/default/vault.log" 2>/dev/null || echo 0)"
if [ "${BASE_PUTS}" -ge 20 ]; then
    ok "(a) default run recorded ${BASE_PUTS} \`vault kv put\` invocations"
else
    bad "(a) default run recorded only ${BASE_PUTS} \`vault kv put\` invocations — too few to be a real run"
fi

# ── POSITIVE: the repo's own tree must satisfy the contract ──────────────────
echo
echo "-- positive: every checked ExternalSecret must be seeded by both paths --"
run_checker() { # run_checker <specs/cluster dir> <seeder> <runs dir>
    python3 "${CHECKER}" "$1" "$2" "$3" 2>&1
}
OUT="$(run_checker "${CLUSTER}" "${GCS}" "${RUNS}")"; RC=$?
sed 's/^/    /' <<<"${OUT}"
if [ "${RC}" -eq 0 ]; then
    ok "(b) specs/cluster satisfies the seed contract"
else
    bad "(b) the tree does NOT satisfy the seed contract (see above)"
fi

# The scope claim must be MEASURED, not asserted in a comment: fail if the walk
# stops covering the ExternalSecrets that live outside manifests/external-secrets.
# Anchored at line start: only a top-level `kind: ExternalSecret` DECLARES an
# object — an indented mention (e.g. a kustomize patch TARGET naming the kind,
# as apps/05b-casdoor-domains.yaml carries) is a reference, not a document, and
# the checker's YAML walk rightly does not count it.
ES_FILES_OUTSIDE="$(grep -rlE '^kind: ExternalSecret' "${CLUSTER}" \
    --include='*.yaml' --include='*.yml' 2>/dev/null \
    | grep -v '/manifests/external-secrets/' | sort | wc -l)"
if grep -qF "file(s) outside manifests/external-secrets" <<<"${OUT}" \
    && grep -qE "\(${ES_FILES_OUTSIDE} file\(s\) outside manifests/external-secrets" <<<"${OUT}"; then
    ok "(b) the walk reports exactly the ${ES_FILES_OUTSIDE} ExternalSecret file(s) that live outside manifests/external-secrets"
else
    bad "(b) the walk's out-of-dir count does not match the ${ES_FILES_OUTSIDE} file(s) grep finds — the scope claim and the behaviour have drifted"
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Each injects one defect of a class and requires the matching check to bite,
# naming the offending item. Without these the gate could be a no-op.
echo
echo "-- negative controls: each injected defect must be caught, by name --"

# $1 = label, $2 = expected check id, $3 = expected substring naming the item,
# $4 = snippet run with $T (staged copy of specs/cluster), $R (staged runs dir)
#      and $G (staged copy of gen-cluster-secrets.sh).
expect_catch() {
    local label="$1" want_check="$2" want_name="$3" inject="$4"
    local T="${WORK}/neg-cluster" R="${WORK}/neg-runs" G="${WORK}/neg-gcs.sh"
    rm -rf "${T}" "${R}"; rm -f "${G}"
    cp -r "${CLUSTER}" "${T}"
    cp -r "${RUNS}" "${R}"
    cp "${GCS}" "${G}"
    if ! ( T="${T}" R="${R}" G="${G}" eval "${inject}" ); then
        bad "negative control: ${label} (the injection itself failed)"
        return
    fi
    local out rc
    out="$(run_checker "${T}" "${G}" "${R}")"; rc=$?
    if [ "${rc}" -eq 1 ] \
        && grep -qF "FAIL ${want_check}" <<<"${out}" \
        && grep -qF "${want_name}" <<<"${out}"; then
        ok "negative control: ${label} -> caught by ${want_check}, naming '${want_name}'"
    else
        bad "negative control: ${label} NOT caught (rc=${rc}); wanted ${want_check} naming '${want_name}'. Output:"
        sed 's/^/        /' <<<"${out}" | tail -25
    fi
}

# Helper used by several controls: apply a python edit to EVERY staged run.
# (Args to the snippet: each run directory.)
ALL_RUN_DIRS='"$R"/default "$R"/mail "$R"/managed-velero "$R"/all-features "$R"/rebranded'

# (n1) THE SHIPPED DEFECT, both halves: unmint the superadmin route-access
# password exactly as origin/main left it — absent from the `vault kv put` and
# absent from the offline bundle, in every provisioning scenario.
expect_catch "the shipped defect: superadmin_gateway_password unseeded on BOTH paths" \
    "[online-seed]" "superadmin_gateway_password" '
python3 - '"${ALL_RUN_DIRS}"' <<PY
import json, sys
for d in sys.argv[1:]:
    p = d + "/vault.log"
    out = []
    for line in open(p):
        a = json.loads(line)
        a = [x for x in a if not x.startswith("superadmin_gateway_password=")]
        out.append(json.dumps(a))
    open(p, "w").write("\n".join(out) + "\n")
    p = d + "/bundle/secrets.json"
    b = json.load(open(p))
    b["hugmesh-pki"]["route-access-db-roles"].pop("superadmin_gateway_password", None)
    b["hugmesh-pki"].pop("route-access-superadmin-gateway", None)
    json.dump(b, open(p, "w"), indent=2, sort_keys=True)
PY
'

# (n2) THE WHOLE CLASS, forward-looking: a NEW property added to an existing
# ExternalSecret that nobody teaches the seeder about. This is the shape every
# future recurrence takes.
expect_catch "a brand-new ExternalSecret property nobody seeds" \
    "[online-seed]" "tomorrows_unseeded_password" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/secretstore.yaml"
s = open(p, encoding="utf-8").read()
s = s.replace(
    "    - secretKey: superadmin_gateway_password\n"
    "      remoteRef: { key: hugmesh/route-access-db, property: superadmin_gateway_password }",
    "    - secretKey: superadmin_gateway_password\n"
    "      remoteRef: { key: hugmesh/route-access-db, property: superadmin_gateway_password }\n"
    "    - secretKey: tomorrows_password\n"
    "      remoteRef: { key: hugmesh/route-access-db, property: tomorrows_unseeded_password }",
    1)
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n3) A WHOLE Vault path nobody writes (a new slug wired up manifest-first).
expect_catch "an ExternalSecret reading a Vault path that is never written" \
    "[online-seed]" "hugmesh/never-written-doc" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/secretstore.yaml"
s = open(p, encoding="utf-8").read()
s = s.replace("      remoteRef: { key: hugmesh/user-bff-db, property: app_password }",
              "      remoteRef: { key: hugmesh/never-written-doc, property: app_password }", 1)
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n4) OFFLINE-ONLY drift: the online path seeds it, the USB bundle does not.
# This half is invisible to any Vault-side check and breaks only air-gapped
# provisioning — which is exactly how it stayed unnoticed.
expect_catch "a Secret key present online but missing from the USB bundle" \
    "[offline-bundle]" "fe_gateway_password" '
python3 - '"${ALL_RUN_DIRS}"' <<PY
import json, sys
for d in sys.argv[1:]:
    p = d + "/bundle/secrets.json"
    b = json.load(open(p))
    b["hugmesh-pki"]["route-access-db-roles"].pop("fe_gateway_password", None)
    json.dump(b, open(p, "w"), indent=2, sort_keys=True)
PY
'

# (n5) The doubled-mount-prefix class: a remoteRef.key that repeats the
# ClusterSecretStore mount. ESO prepends the mount itself, so the lookup goes to
# secret/data/secret/... — it LOOKS plausible in review and resolves to nothing.
expect_catch "a remoteRef.key that repeats the store KV mount" \
    "[mount-relative]" "secret/hugmesh/bff-internal-token" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/sso-externalsecrets.yaml"
s = open(p, encoding="utf-8").read()
s = s.replace("        key: hugmesh/bff-internal-token",
              "        key: secret/hugmesh/bff-internal-token", 1)
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n6) ANTI-ROT: an out-of-scope classification must not outlive its reference.
# Delete the ExternalSecret an exemption excuses; the exemption must fail loudly
# rather than sit there quietly excusing nothing.
expect_catch "a classification entry whose ExternalSecret is gone" \
    "[stale-exemption]" "hugmesh/coturn-shared-secret" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/kustomization.yaml"
s = open(p, encoding="utf-8").read()
s = s.replace("  - coturn-externalsecrets.yaml", "  #- coturn-externalsecrets.yaml", 1)
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n7) An extract-based Secret whose offline keys disagree with the Vault doc —
# how `signup-gate-webhook` reached the bundle under the wrong property name.
expect_catch "an extract-based Secret with an offline key no Vault property backs" \
    "[offline-bundle]" "casdoor-app-secrets" '
python3 - '"${ALL_RUN_DIRS}"' <<PY
import json, sys
for d in sys.argv[1:]:
    p = d + "/bundle/secrets.json"
    b = json.load(open(p))
    apps = b["hugmesh-pki"]["casdoor-app-secrets"]
    apps["signup-gate-webhook-secret"] = apps.pop("signup-gate-webhook")
    json.dump(b, open(p, "w"), indent=2, sort_keys=True)
PY
'

# (n8) GUARD THEATRE, half one — the hole the first version of this gate had.
# An ExternalSecret that carries a generator `sourceRef` in dataFrom ALSO
# carrying a spec.data[] KV remoteRef nobody seeds. The old checker skipped the
# WHOLE object the moment it saw a sourceRef, so this passed green.
expect_catch "an unseeded KV property hiding inside a generator-backed ExternalSecret" \
    "[online-seed]" "hidden_behind_generator" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/pki-externalsecrets.yaml"
s = open(p, encoding="utf-8").read()
anchor = ("metadata: { name: hugmesh-api-mtls, namespace: hugmesh-backend }\n"
          "spec:\n  refreshInterval: 168h\n  target:\n")
assert anchor in s, "anchor not found"
s = s.replace(anchor,
    "metadata: { name: hugmesh-api-mtls, namespace: hugmesh-backend }\n"
    "spec:\n  refreshInterval: 168h\n"
    "  secretStoreRef: { name: hugmesh-vault, kind: ClusterSecretStore }\n"
    "  data:\n"
    "    - secretKey: hidden\n"
    "      remoteRef: { key: hugmesh/route-access-db, property: hidden_behind_generator }\n"
    "  target:\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n9) GUARD THEATRE, half two — the OFFLINE assertion must not be skipped
# either. Same generator-backed object, but this time the KV reference IS seeded
# online and the Secret key the template derives from it is missing from the USB
# bundle. The old checker asserted nothing at all about such an object.
expect_catch "a generator-backed ExternalSecret whose KV-derived key never reaches the USB bundle" \
    "[offline-bundle]" "hugmesh-backend/hugmesh-admin-bff-api-mtls" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/pki-externalsecrets.yaml"
s = open(p, encoding="utf-8").read()
anchor = ("metadata: { name: hugmesh-admin-bff-api-mtls, namespace: hugmesh-backend }\n"
          "spec:\n  refreshInterval: 168h\n  target:\n")
assert anchor in s, "anchor not found"
s = s.replace(anchor,
    "metadata: { name: hugmesh-admin-bff-api-mtls, namespace: hugmesh-backend }\n"
    "spec:\n  refreshInterval: 168h\n"
    "  secretStoreRef: { name: hugmesh-vault, kind: ClusterSecretStore }\n"
    "  data:\n"
    "    - secretKey: internal_token\n"
    "      remoteRef: { key: hugmesh/bff-internal-token, property: token }\n"
    "  target:\n", 1)
i = s.index("name: hugmesh-admin-bff-api-mtls\n    creationPolicy: Owner")
j = s.index("        ca.crt: \"{{ .issuing_ca }}\"\n", i) + len("        ca.crt: \"{{ .issuing_ca }}\"\n")
s = s[:j] + "        internal-token: \"{{ .internal_token }}\"\n" + s[j:]
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n10) SCOPE: an ExternalSecret that lives OUTSIDE manifests/external-secrets.
# This used to inject into manifests/cassandra-hardening/cassandra-externalsecrets.yaml.
# That file moved INTO manifests/external-secrets when the Cassandra auth stage
# stopped being dark (KIND-SSO-E2E-FINDINGS #5 — the server had demanded
# credentials all along), and no OTHER rendered-and-seeded ExternalSecret lives
# outside that directory today: the three that do (cloudflared, coturn-public,
# cassandra TLS) all land in [not-rendered]/[conditional], where a mutated
# property is legitimately not an [online-seed] finding. Depending on which files
# happen to sit where is what made this control fragile, so it now CREATES the
# condition it tests: a rendered ExternalSecret in a non-external-secrets overlay
# (manifests/cassandra-init), added to that overlay's own kustomization, reading a
# property nothing seeds. The walk must still find it.
expect_catch "an unseeded property in an ExternalSecret outside manifests/external-secrets" \
    "[online-seed]" "never_seeded_outside_property" '
python3 - "$T" <<PY
import sys, os
d = sys.argv[1] + "/manifests/cassandra-init"
if not os.path.isdir(d):
    sys.exit("manifests/cassandra-init is gone — this control needs a rendered overlay outside manifests/external-secrets")
open(d + "/probe-externalsecret.yaml", "w", encoding="utf-8").write("""apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: seed-contract-probe
  namespace: hugmesh-pki
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: hugmesh-vault
    kind: ClusterSecretStore
  target:
    name: seed-contract-probe
    creationPolicy: Owner
  data:
    - secretKey: probe
      remoteRef: { key: hugmesh/cassandra-app-creds, property: never_seeded_outside_property }
""")
k = d + "/kustomization.yaml"
s = open(k, encoding="utf-8").read()
if "resources:" not in s:
    sys.exit("kustomization has no resources: list")
s = s.replace("resources:", "resources:\n  - probe-externalsecret.yaml", 1)
open(k, "w", encoding="utf-8").write(s)
PY
'

# (n11) THE [conditional] AUTO-PASS: an always-rendered ExternalSecret whose
# Vault path a DEFAULT provisioning run never writes. The old bucket accepted
# anything the all-features run happened to satisfy, so this went fully green.
# Now it must be attributable to a NAMED feature flag whose isolated run
# produces it — and no feature does.
expect_catch "a reference a default run cannot satisfy that no declared feature explains" \
    "[conditional]" "secret/hugmesh/bff-internal-token" '
python3 - "$R"/default "$R"/mail "$R"/managed-velero <<PY
import json, sys
for d in sys.argv[1:]:
    p = d + "/vault.log"
    out = []
    for line in open(p):
        a = json.loads(line)
        if a[:3] == ["kv", "put", "secret/hugmesh/bff-internal-token"]:
            continue
        out.append(json.dumps(a))
    open(p, "w").write("\n".join(out) + "\n")
PY
'

# (n12) A conditional claim the MANIFESTS do not support: the feature keeps its
# seeder guard, but the manifest statement that lets its Secret not materialize
# is gone. The classification is then the gate excusing itself.
expect_catch "a conditional feature whose manifest no longer declares the Secret optional" \
    "[conditional]" "velero-externalsecrets.yaml" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/velero-externalsecrets.yaml"
s = open(p, encoding="utf-8").read()
s = s.replace("SHIPS DARK: this ExternalSecret only materializes when the velero namespace",
              "This ExternalSecret is always required", 1)
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n13) ONLINE/OFFLINE VALUE DIVERGENCE: a literal template.data value that ESO
# writes verbatim online while the seeder puts a different string in the bundle.
# Name-only checking cannot see this — the key is present on both paths.
expect_catch "a literal template value the USB bundle disagrees with" \
    "[literal-value]" "headwind-admin" '
python3 - '"${ALL_RUN_DIRS}"' <<PY
import json, sys
for d in sys.argv[1:]:
    p = d + "/bundle/secrets.json"
    b = json.load(open(p))
    b["hugmesh-pki"]["headwind-admin"]["email"] = "admin@somewhere.else"
    json.dump(b, open(p, "w"), indent=2, sort_keys=True)
PY
'

# (n14) A NAME THAT RESOLVES TO NOTHING: the property is written, so every
# name-based check passes, but the value is the empty string even with every
# feature on. ESO materializes the Secret and the consumer boots blank.
expect_catch "a seeded property whose value is empty with every feature enabled" \
    "[non-empty]" "hugmesh/user-bff-hs-token" '
python3 - '"${ALL_RUN_DIRS}"' <<PY
import json, sys
for d in sys.argv[1:]:
    p = d + "/vault.log"
    out = []
    for line in open(p):
        a = json.loads(line)
        a = ["svc-password=" if x.startswith("svc-password=") else x for x in a]
        out.append(json.dumps(a))
    open(p, "w").write("\n".join(out) + "\n")
PY
'

# (n15) A template key interpolating a variable NOTHING provides — ESO renders
# it empty with no error anywhere, so the consumer gets a blank value.
expect_catch "a template key interpolating a variable nothing provides" \
    "[template-vars]" "nothing_provides_this" '
python3 - "$T" <<PY
import sys
p = sys.argv[1] + "/manifests/external-secrets/headwind-externalsecrets.yaml"
s = open(p, encoding="utf-8").read()
s = s.replace("        email: \"admin@hugmesh.net\"",
              "        email: \"admin@hugmesh.net\"\n"
              "        phantom: \"{{ .nothing_provides_this }}\"", 1)
open(p, "w", encoding="utf-8").write(s)
PY
'

# (n16) VACUITY: a missing run artifact must FAIL, never pass. Without the
# isolated feature runs the [conditional] bucket would silently become the
# auto-pass this rework removed.
expect_catch "a missing provisioning-run artifact" \
    "[runs]" "managed-velero" '
rm -rf "$R"/managed-velero
'

# (n17) THE DOMAIN-COUPLING HOLE that (n13) alone cannot see. headwind-admin's
# `email` is the one template literal embedding the cluster domain, and the baked
# manifest is sed'd hugmesh.net -> ${CLUSTER_DOMAIN} by rebrand_sysroot(). So
# HARDCODING "admin@hugmesh.net" in the offline bundle matches the manifest
# byte-for-byte on the DEFAULT brand — (n13) and the whole [literal-value] check
# stay green — while handing every REBRANDED cluster's headwind pod a different
# ADMIN_EMAIL online than offline. This injects exactly that hardcode into the
# rebrand probe, and only [domain-coupled] can catch it.
expect_catch "a domain-bearing literal the seeder hardcodes instead of tracking CLUSTER_DOMAIN" \
    "[domain-coupled]" "headwind-admin" '
python3 - "$R"/rebranded <<PY
import json, sys
p = sys.argv[1] + "/bundle/secrets.json"
b = json.load(open(p))
b["hugmesh-pki"]["headwind-admin"]["email"] = "admin@hugmesh.net"
json.dump(b, open(p, "w"), indent=2, sort_keys=True)
PY
'

# (n18) The SYMMETRIC direction: a literal WITHOUT the domain in it must not move
# either. rebrand_sysroot() leaves such a value alone, so ESO writes it verbatim
# on every brand; a seeder that varies it by domain makes the offline path drift
# where the online path is fixed.
expect_catch "a domain-free literal the seeder varies by CLUSTER_DOMAIN anyway" \
    "[domain-coupled]" "casdoor-admin" '
python3 - "$R"/rebranded <<PY
import json, sys
p = sys.argv[1] + "/bundle/secrets.json"
b = json.load(open(p))
b["hugmesh-pki"]["casdoor-admin"]["username"] = "admin-rebrand-probe"
json.dump(b, open(p, "w"), indent=2, sort_keys=True)
PY
'

# (n19) VACUITY of the probe itself: if the rebrand run is executed under the
# DEFAULT domain, every comparison above becomes an identity and the check proves
# nothing. It must say so rather than pass.
expect_catch "a rebrand probe that does not actually rebrand" \
    "[domain-coupled]" "does not rebrand" '
python3 - "$R"/rebranded "$G" <<PY
import re, sys
dom = re.search(r"^CLUSTER_DOMAIN=\"\\\$\{CLUSTER_DOMAIN:-([^}\"]+)\}\"",
                open(sys.argv[2], encoding="utf-8").read(), re.M).group(1)
open(sys.argv[1] + "/cluster-domain", "w").write(dom + "\n")
PY
'

# ── TOOLING PREFLIGHT: a missing tool must FAIL, and CI must not be able to opt out ──
echo
echo "-- tooling preflight: absent tooling is a hard failure, not a silent skip --"
mkdir -p "${WORK}/nopy"
# bash + dirname are all the script needs to REACH its preflight (env resolves
# the command itself through the stripped PATH); python3/openssl are absent on
# purpose. mktemp is included so the "opt-out honored" leg exits cleanly too.
for b in bash dirname mktemp; do
    src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${WORK}/nopy/${b}"
done
# (t1) python3 absent, no opt-out -> exit 1, and the message must say why.
T1_OUT="$(env -u ESO_SEED_CONTRACT_ALLOW_SKIP PATH="${WORK}/nopy" \
    bash "${BASH_SOURCE[0]}" 2>&1)"; T1_RC=$?
if [ "${T1_RC}" -ne 0 ] && grep -qF "FAIL missing required tool(s)" <<<"${T1_OUT}"; then
    ok "(t1) with python3 absent and no opt-out the gate FAILS (rc=${T1_RC}) instead of exiting 0"
else
    bad "(t1) with python3 absent the gate did not hard-fail (rc=${T1_RC}): ${T1_OUT}"
fi
# (t2) the deliberate local escape hatch still works, and says so loudly.
T2_OUT="$(env ESO_SEED_CONTRACT_ALLOW_SKIP=1 PATH="${WORK}/nopy" \
    bash "${BASH_SOURCE[0]}" 2>&1)"; T2_RC=$?
if [ "${T2_RC}" -eq 0 ] && grep -qF "ESO_SEED_CONTRACT_ALLOW_SKIP=1 was set" <<<"${T2_OUT}"; then
    ok "(t2) ESO_SEED_CONTRACT_ALLOW_SKIP=1 is honored as a DELIBERATE local opt-out (rc=0)"
else
    bad "(t2) the explicit opt-out did not work (rc=${T2_RC}): ${T2_OUT}"
fi
# (t3) PROOF that the CI path cannot silently pass: the opt-out variable must
# appear NOWHERE in .gitlab-ci.yml (not in the job, not in a global `variables:`
# block, not in an `.env`-style include), and the job must really run this file.
if [ ! -f "${CI_FILE}" ]; then
    bad "(t3) ${CI_FILE} not found — cannot prove CI never opts out"
elif grep -qF "ESO_SEED_CONTRACT_ALLOW_SKIP" "${CI_FILE}"; then
    bad "(t3) .gitlab-ci.yml mentions ESO_SEED_CONTRACT_ALLOW_SKIP — CI could skip this gate silently:"
    grep -nF "ESO_SEED_CONTRACT_ALLOW_SKIP" "${CI_FILE}" | sed 's/^/        /'
elif ! grep -qF "tests/scripts/test-eso-seed-contract.sh" "${CI_FILE}"; then
    bad "(t3) no .gitlab-ci.yml job runs tests/scripts/test-eso-seed-contract.sh — the gate is not wired in"
else
    ok "(t3) .gitlab-ci.yml runs this gate and never sets ESO_SEED_CONTRACT_ALLOW_SKIP, so the CI path cannot skip it"
fi

echo
echo "== ESO seed contract: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
