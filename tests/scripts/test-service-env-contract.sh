#!/usr/bin/env bash
# test-service-env-contract.sh — the gate for "the cluster manifests do not tell the
# services what they need, so the services fall back to defaults that name things this
# cluster does not have".
#
# WHY THIS EXISTS. The GitOps cluster payload was stood up for the first time on
# 2026-08-05 (KIND_PROFILE=sso). The native-login chain hit FIVE configuration blockers
# back to back, each only visible after fixing the one before it
# (docs/KIND-SSO-E2E-FINDINGS.md #11-#15): CASDOOR_ORG unset ("The user:
# <pre-rebrand-org>/e2e-user doesn't exist"), the OIDC client-id defaulting to `user-bff`
# against a registered `app-user-bff` ("Invalid client_id"), a pre-rebrand redirect-uri,
# NXDOMAIN namespace defaults, and admin-bff unable to START on an unresolved
# ${SVC_PASSWORD}. Every one had an override in tests/stack/compose.local.yaml, several
# with a comment naming the exact error, that had never reached specs/cluster.
#
# WHY IT LOOKS LIKE THIS. The first version of this gate asserted a hand-written list of
# keys. It was green on a tree that still carried 23 more instances of the same defect
# and two Deployments emitting `casdoor.hugmesh-casdoor.svc.cluster.local` — a namespace
# that has never existed. A list catches what someone typed into it; the defect IS the
# thing nobody typed. So the completeness half is now DERIVED
# (tests/scripts/service_env_defaults.py): each service's OWN application.yml supplies
# the keys and their fallbacks, this specs/cluster tree supplies which namespaces and
# domains exist, and any placeholder whose default names something absent must be
# overridden. Only the IdP/Vault agreement rules — the things no config file could tell
# you — remain written down, in specs/cluster/service-env-contract.yaml.
#
# THE SERVICE CHECKOUTS ARE PART OF THE GATE, NOT A CONVENIENCE. Without them the
# derived check has nothing to derive from, so the checker exits 3 INCOMPLETE and this
# script fails. Same lesson as lint:reserved-prefixes, which spent months green while
# its most valuable stage printed "[SKIP] … (not checked out)".
#
# Negative controls below cover: the four verbatim blockers; the OTHER side drifting
# (casdoor-init moving while the manifests stay correct); the bootstrap disagreeing with
# itself; an unreadable casdoor-init (must ABORT, not pass); a BRAND-NEW stale default
# invented in a service repo, under a key and a namespace that appear nowhere in this
# repo; the CLUSTER side moving (a namespace deleted out from under a correct manifest);
# a whole new BFF arriving; and the sources going missing, which must be INCOMPLETE and
# never green.
#
# Offline: no cluster, no kubectl, no network; writes only into its own mktemp dir.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${REPO}/tests/scripts/service_env_contract.py"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

echo "== service env-contract gate =="
echo "-- positive: the repo's own specs/cluster must satisfy the contract --"
python3 "${CHECKER}" "${REPO}/specs/cluster"
RC=$?
if [ "${RC}" -eq 3 ]; then
  echo
  echo "== service env contract: INCOMPLETE =="
  echo "   The derived check needs the first-party BFF checkouts. Set SERVICE_SRC_ROOT"
  echo "   (CI clones them; locally, sibling checkouts next to this repo are found"
  echo "   automatically). A green run without them would be a lie, so this is a FAIL."
  exit 1
fi
if [ "${RC}" -ne 0 ]; then
  echo
  echo "== service env contract: FAIL (see above) =="
  exit 1
fi

# The source root the positive run resolved — the negative controls stage a COPY of it
# so a control can plant a defect in a service repo without touching the checkout.
SRC_ROOT="$(python3 "${CHECKER}" "${REPO}/specs/cluster" 2>/dev/null | sed -n 's/^  --   service sources: \(.*\) (.*$/\1/p' | head -1)"
[ -d "${SRC_ROOT}" ] || { echo "  FAIL could not determine the service-source root"; exit 1; }

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
echo
echo "-- negative controls: each injected defect must be caught --"
NEG_P=0; NEG_F=0
neg_ok(){   echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad(){  echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
# One pristine copy of the service sources; controls that need to mutate them copy again.
#
# ONLY the files the checker actually reads — every `hugmesh-*/src/main/resources/
# application.yml` under the resolved root — not the root itself. `cp -r "${SRC_ROOT}"`
# is fine when SERVICE_SRC_ROOT points at CI's dedicated clone dir, but the LOCAL
# fallback root is the operator's whole sibling-checkout tree (dozens of repos,
# node_modules, build output, many GB): copying it once per control is not viable, and
# when it fails every control reports "injection itself failed" — 19 red controls that
# say nothing about the gate. resolve_service_src() only requires that each needed repo
# has its application.yml, so this minimal tree satisfies it exactly.
stage_pristine_sources() {
  local dest="$1" src ymls=0
  mkdir -p "${dest}"
  for src in "${SRC_ROOT}"/hugmesh-*/src/main/resources/application.yml; do
    [ -f "${src}" ] || continue
    local repo; repo="${src#"${SRC_ROOT}"/}"; repo="${repo%%/*}"
    mkdir -p "${dest}/${repo}/src/main/resources"
    cp "${src}" "${dest}/${repo}/src/main/resources/application.yml"
    ymls=$((ymls+1))
  done
  # ANTI-VACUITY: an empty stage makes every control below fail as "injection failed"
  # (or, worse, pass for the wrong reason) while looking like a gate problem.
  [ "${ymls}" -gt 0 ] || { echo "  FAIL staged ZERO service application.yml files from ${SRC_ROOT}"; exit 1; }
}
stage_pristine_sources "${WORK}/src-pristine"

# $1 = label, $2 = expected "[check-id] … substring" in the failure output,
# $3 = shell snippet run with $T = staged specs/cluster and $S = staged service sources.
expect_catch() {
  local label="$1" want="$2" inject="$3"
  local T="${WORK}/tree" S="${WORK}/src"
  rm -rf "${T}" "${S}"
  cp -r "${REPO}/specs/cluster" "${T}"
  cp -r "${WORK}/src-pristine" "${S}"
  ( T="${T}"; S="${S}"; eval "${inject}" ) || { neg_bad "${label} (injection itself failed)"; return; }
  local out rc
  out="$(SERVICE_SRC_ROOT="${S}" python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
  if [ "${rc}" -ne 0 ] && grep -qF "${want}" <<<"${out}"; then
    neg_ok "${label} -> caught (${want})"
  else
    neg_bad "${label} NOT caught (rc=${rc}); wanted ${want}. Output:"
    sed 's/^/        /' <<<"${out}" | tail -25
  fi
}

# Same, but the defect is injected by a shell FUNCTION taking $1=staged specs/cluster
# and $2=staged service sources. Used wherever the injected text is itself full of
# `${...}` — a Spring placeholder inside an eval'd string is unreadable and, worse,
# silently degrades into a control that injects nothing and "passes".
expect_catch_fn() {
  local label="$1" want="$2" fn="$3"
  local T="${WORK}/tree" S="${WORK}/src"
  rm -rf "${T}" "${S}"
  cp -r "${REPO}/specs/cluster" "${T}"
  cp -r "${WORK}/src-pristine" "${S}"
  "${fn}" "${T}" "${S}" || { neg_bad "${label} (injection itself failed)"; return; }
  local out rc
  out="$(SERVICE_SRC_ROOT="${S}" python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
  if [ "${rc}" -ne 0 ] && grep -qF "${want}" <<<"${out}"; then
    neg_ok "${label} -> caught (${want})"
  else
    neg_bad "${label} NOT caught (rc=${rc}); wanted ${want}. Output:"
    sed 's/^/        /' <<<"${out}" | tail -25
  fi
}

# Helper: rewrite ONE env entry of ONE Deployment in a staged manifest.
# Usage: py_env <tree> <relative manifest> <deployment name> <python snippet over `env`>
PY_ENV='
import sys, yaml
path, dep = sys.argv[1], sys.argv[2]
docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
for d in docs:
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == dep:
        conts = d["spec"]["template"]["spec"]["containers"]
        c = next((x for x in conts if x.get("name") == dep), conts[0])
        env = c["env"]
        exec(sys.argv[3])
yaml.safe_dump_all(docs, open(path, "w", encoding="utf-8"), sort_keys=False)
'

# (1) #11 verbatim: the org override goes missing again.
expect_catch "CASDOOR_ORG dropped from user-bff (finding #11)" \
  "[env-required] hugmesh-user-bff-api: CASDOOR_ORG is NOT set" "
  python3 -c '${PY_ENV}' \"\$T/manifests/user-bff-api/deployment.yaml\" hugmesh-user-bff-api \
    'env[:] = [e for e in env if e[\"name\"] != \"CASDOOR_ORG\"]'
"

# (2) #12 verbatim: the client-id falls back to the app's own default.
expect_catch "OIDC client-id reverted to the app default 'user-bff' (finding #12)" \
  "[casdoor-agreement] hugmesh-user-bff-api: APP_BFF_OIDC_CLIENT_ID" "
  python3 -c '${PY_ENV}' \"\$T/manifests/user-bff-api/deployment.yaml\" hugmesh-user-bff-api \
    '[e.update(value=\"user-bff\") for e in env if e[\"name\"]==\"APP_BFF_OIDC_CLIENT_ID\"]'
"

# (3) #13's defect class: the redirect URI is a host Casdoor never registered.
#     The planted value must be UNREGISTERED — an earlier sweep rebranded this
#     control's literal into `https://hugmesh.net/login/callback`, which is exactly
#     what init-job.yaml DOES register, so the control planted a CORRECT value and
#     could never bite. It went unnoticed because the whole gate was exiting
#     INCOMPLETE. A reserved-for-documentation host cannot be rebranded into a real
#     one by the next sweep.
expect_catch "redirect-uri points at a host Casdoor never registered (finding #13)" \
  "[casdoor-agreement] hugmesh-user-bff-api: APP_BFF_OIDC_REDIRECT_URI" "
  python3 -c '${PY_ENV}' \"\$T/manifests/user-bff-api/deployment.yaml\" hugmesh-user-bff-api \
    '[e.update(value=\"https://login.example.invalid/login/callback\") for e in env if e[\"name\"]==\"APP_BFF_OIDC_REDIRECT_URI\"]'
"

# (4) #15 verbatim: admin-bff loses the mandatory placeholder again. It must be caught
#     TWICE — by the contract (which Secret) and by the DERIVED startup check (the app
#     has no default for it at all), so the second is asserted separately in (5).
expect_catch "SVC_PASSWORD dropped from admin-bff (finding #15)" \
  "[env-required] hugmesh-admin-bff-api: SVC_PASSWORD is NOT set" "
  python3 -c '${PY_ENV}' \"\$T/manifests/admin-bff-api/deployment.yaml\" hugmesh-admin-bff-api \
    'env[:] = [e for e in env if e[\"name\"] != \"SVC_PASSWORD\"]'
"

# (5) …and the same omission seen from the DERIVED side, which needs no contract entry:
#     a placeholder with no packaged default is a pod that never starts.
expect_catch "SVC_PASSWORD dropped — the derived no-default check must bite too" \
  "[env-startup] hugmesh-admin-bff-api: SVC_PASSWORD has NO default" "
  python3 -c '${PY_ENV}' \"\$T/manifests/admin-bff-api/deployment.yaml\" hugmesh-admin-bff-api \
    'env[:] = [e for e in env if e[\"name\"] != \"SVC_PASSWORD\"]'
"

# (6) The subtle version of #15: the ref is there but marked optional, so a missing
#     Secret degrades to an unresolved placeholder + crash-loop instead of a clear
#     CreateContainerConfigError.
expect_catch "SVC_PASSWORD marked optional (hides the missing Secret behind a Spring crash)" \
  "[env-secret] hugmesh-admin-bff-api: SVC_PASSWORD has optional=True" "
  python3 -c '${PY_ENV}' \"\$T/manifests/admin-bff-api/deployment.yaml\" hugmesh-admin-bff-api \
    '[e[\"valueFrom\"][\"secretKeyRef\"].update(optional=True) for e in env if e[\"name\"]==\"SVC_PASSWORD\"]'
"

# (7) A secret reference nothing provisions — the class that cost the whole
#     route-access Secret (findings #3) applied to this env instead.
expect_catch "SVC_PASSWORD points at a Secret key no ExternalSecret materializes" \
  "which NO ExternalSecret materializes" "
  python3 -c '${PY_ENV}' \"\$T/manifests/admin-bff-api/deployment.yaml\" hugmesh-admin-bff-api \
    '[e[\"valueFrom\"][\"secretKeyRef\"].update(key=\"broker-password\") for e in env if e[\"name\"]==\"SVC_PASSWORD\"]' &&
  python3 - \"\$T\" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]) / 'service-env-contract.yaml'
c = yaml.safe_load(p.read_text())
for s in c['services']:
    for r in s.get('requires') or []:
        if r['key'] == 'SVC_PASSWORD':
            r['fromSecret'] = 'user-bff-hs-token/broker-password'
p.write_text(yaml.safe_dump(c, sort_keys=False))
PY
"

# (8) THE OTHER SIDE MOVES. The manifests are untouched and correct; casdoor-init
#     starts registering a different callback. A one-sided check would stay green.
expect_catch "casdoor-init drifts: user-bff redirect override changed (manifests untouched)" \
  "[casdoor-agreement] hugmesh-user-bff-api: APP_BFF_OIDC_REDIRECT_URI" "
  python3 - \"\$T\" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / 'manifests/casdoor/init-job.yaml'
s = p.read_text(encoding='utf-8')
old = 'app[\"redirectUris\"] = [\"https://hugmesh.net/login/callback\"]'
assert old in s, 'injection anchor not found'
p.write_text(s.replace(old, 'app[\"redirectUris\"] = [\"https://hugmesh.net/bff/auth/callback\"]'), encoding='utf-8')
PY
"

# (9) THE OTHER SIDE MOVES, org edition: init_data.json seeds one org while the Job
#     env names another. That is exactly how #11 could have been reintroduced from
#     the IdP side rather than the consumer side.
expect_catch "casdoor bootstrap disagrees with itself on the organization" \
  "[casdoor-org] the Casdoor bootstrap does not agree with itself" "
  python3 - \"\$T\" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / 'manifests/casdoor/init-data-configmap.yaml'
s = p.read_text(encoding='utf-8')
old = '\"owner\": \"admin\",\n          \"name\": \"hugmesh\",'
assert old in s, 'injection anchor not found'
p.write_text(s.replace(old, '\"owner\": \"admin\",\n          \"name\": \"notthisorg\",', 1), encoding='utf-8')
PY
"

# (10) #12 from the IdP side: the registered clientId prefix changes, so every
#      consumer's pinned `app-user-bff` becomes wrong.
expect_catch "casdoor-init drifts: registered clientId prefix changed" \
  "[casdoor-agreement] hugmesh-admin-bff-api: APP_BFF_OIDC_CLIENT_ID" "
  python3 - \"\$T\" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / 'manifests/casdoor/init-job.yaml'
s = p.read_text(encoding='utf-8')
old = 'appname = f\"app-{name}\"'
assert old in s, 'injection anchor not found'
p.write_text(s.replace(old, 'appname = f\"hm-{name}\"'), encoding='utf-8')
PY
"

# (11) #14 verbatim: a pre-rebrand namespace comes back as an EMITTED value. The
#      planted host keeps the RETIRED spelling on purpose — this control's whole
#      subject is a pre-rebrand identifier resurfacing, so a rebranded fixture would
#      make it a duplicate of (12) and stop testing what it names. Drift-guard
#      fixture: the token is named here to prove it is CAUGHT, never to keep it live.
expect_catch "pre-rebrand namespace reintroduced in an env value (finding #14)" \
  "[stale-ref] hugmesh-user-bff-api/hugmesh-user-bff-api: ADMIN_BFF_INTERNAL_BASE_URL" "
  python3 -c '${PY_ENV}' \"\$T/manifests/user-bff-api/deployment.yaml\" hugmesh-user-bff-api \
    '[e.update(value=\"http://snapdragon-admin-bff-api.snapdragon-backend.svc.cluster.local:8080\") for e in env if e[\"name\"]==\"ADMIN_BFF_INTERNAL_BASE_URL\"]'
"

# (12) …and the version a brand-prefix pattern rule CANNOT see: a perfectly
#      post-rebrand-looking host in a namespace that has simply never existed. Two live
#      Deployments were emitting exactly this shape (casdoor.hugmesh-casdoor…) while the
#      pattern-matching predecessor of this check reported clean.
expect_catch "emitted value names a hugmesh-SHAPED namespace that does not exist" \
  "[stale-ref] hugmesh-user-bff-api/hugmesh-user-bff-api: ADMIN_BFF_INTERNAL_BASE_URL" "
  python3 -c '${PY_ENV}' \"\$T/manifests/user-bff-api/deployment.yaml\" hugmesh-user-bff-api \
    '[e.update(value=\"http://hugmesh-admin-bff-api.hugmesh-services.svc.cluster.local:8080\") for e in env if e[\"name\"]==\"ADMIN_BFF_INTERNAL_BASE_URL\"]'
"

# (13) THE CONTROL THAT DECIDES WHETHER THIS GATE IS A LIST OR A RULE. A service repo
#      grows a BRAND-NEW placeholder with a stale default — a key name that appears
#      nowhere in this repo, in a namespace with no pre-rebrand string in it, in a
#      service the contract records as holding no IdP rules. Nobody edits any list, and
#      the build must go red.
inject_new_stale_default() {   # $1 = staged specs/cluster, $2 = staged service sources
  cat >> "$2/hugmesh-wiki-bff-api/src/main/resources/application.yml" <<'YAML'

wiki:
  indexer:
    enabled: "${WIKI_INDEXER_ENABLED:false}"
    base-url: "${WIKI_INDEXER_BASE_URL:http://opensearch.hugmesh-search.svc.cluster.local:9200}"
YAML
}
expect_catch_fn "a NEW stale default appears in a service repo (no list mentions it)" \
  "[env-derived] hugmesh-wiki-bff-api: none of WIKI_INDEXER_BASE_URL is set" \
  inject_new_stale_default

# (14) The same rule from the CLUSTER side: the manifests and the services are both
#      unchanged, and the cluster stops providing a namespace. Every address that
#      pointed into it is now dangling — the mirror image of the casdoor-init drift
#      controls above, and the reason "what exists" is read from the tree rather than
#      hard-coded.
inject_namespace_removed() {   # $1 = staged specs/cluster
  python3 - "$1" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
gone = "hugmesh-inference"
hit = 0
for p in sorted(root.rglob("*.yaml")):
    if p.parent.name == "templates":
        continue
    try:
        docs = [d for d in yaml.safe_load_all(p.read_text(encoding="utf-8")) if d]
    except Exception:
        continue
    changed = False
    keep = []
    for d in docs:
        if isinstance(d, dict) and d.get("kind") == "Namespace" and (d.get("metadata") or {}).get("name") == gone:
            changed = True
            continue
        keep.append(d)
    # also stop DEPLOYING into it, so the namespace is genuinely absent from the tree
    def strip(node):
        global changed
        if isinstance(node, dict):
            for k, v in list(node.items()):
                if k == "namespace" and v == gone:
                    node[k] = "devops"
                    changed = True
                else:
                    strip(v)
        elif isinstance(node, list):
            for v in node:
                strip(v)
    for d in keep:
        strip(d)
    if changed:
        p.write_text(yaml.safe_dump_all(keep, sort_keys=False), encoding="utf-8")
        hit += 1
assert hit, "injection anchor not found: no manifest declares or uses " + gone
PY
}
expect_catch_fn "a namespace is removed from specs/cluster while manifests still address it" \
  "[stale-ref] hugmesh-user-bff-api/hugmesh-user-bff-api: MODERATION_IMAGE_BASE_URL" \
  inject_namespace_removed

# (15) A new first-party BFF lands — WITH its source, so the run gets as far as the
#      classification check — carrying a stale default of its own. Both must bite: the
#      derived check on its packaged default, and coverage on the missing classification.
inject_new_bff() {   # $1 = staged specs/cluster, $2 = staged service sources
  mkdir -p "$1/manifests/newthing-bff-api" "$2/hugmesh-newthing-bff-api/src/main/resources"
  cat > "$1/manifests/newthing-bff-api/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: hugmesh-newthing-bff-api, namespace: hugmesh-backend }
spec:
  replicas: 1
  selector: { matchLabels: { app: hugmesh-newthing-bff-api } }
  template:
    metadata: { labels: { app: hugmesh-newthing-bff-api } }
    spec:
      containers:
        - name: hugmesh-newthing-bff-api
          image: hugmesh/newthing-bff-api:dev
          env:
            - { name: CASDOOR_ISSUER_URI, value: "https://id.hugmesh.net" }
YAML
  # Drift-guard fixture: the packaged default deliberately keeps a RETIRED
  # pre-rebrand namespace — that is the exact shape [env-derived] exists to catch
  # when a new BFF arrives carrying its own stale default. Named to be caught.
  cat > "$2/hugmesh-newthing-bff-api/src/main/resources/application.yml" <<'YAML'
newthing:
  peer:
    base-url: "${NEWTHING_PEER_BASE_URL:http://newthing-peer.snapdragon-backend.svc.cluster.local:8080}"
YAML
}
expect_catch_fn "a new BFF arrives carrying its own stale default" \
  "[env-derived] hugmesh-newthing-bff-api: none of NEWTHING_PEER_BASE_URL is set" inject_new_bff
expect_catch_fn "a new first-party *-bff-api Deployment is not classified in the contract" \
  "[coverage] first-party BFF Deployment(s) not classified" inject_new_bff

# (15b) …and the same new BFF with NO source checkout must be INCOMPLETE, not green:
#       an unexaminable service is exactly the state this gate refuses to bless.
inject_new_bff_no_source() { inject_new_bff "$1" "$2"; rm -rf "$2/hugmesh-newthing-bff-api"; }
expect_catch_fn "a new BFF whose source is absent must be INCOMPLETE, not green" \
  "INCOMPLETE [env-derived]" inject_new_bff_no_source

# (16) THE GUARD'S OWN HONESTY, part 1. If casdoor-init is refactored into a shape the
#      extractor cannot read, the checker must ABORT (rc 2), not report agreement with
#      a value it never actually read.
expect_catch "unreadable casdoor-init shape must abort, not pass vacuously" \
  "[casdoor-source]" "
  python3 - \"\$T\" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / 'manifests/casdoor/init-job.yaml'
s = p.read_text(encoding='utf-8')
assert '\n    APPS = {' in s, 'injection anchor not found'
p.write_text(s.replace('\n    APPS = {', '\n    APPLICATIONS = {', 1), encoding='utf-8')
PY
"

# (17) THE GUARD'S OWN HONESTY, part 2 — the one that would have caught the whole
#      "green because it never ran" family. Remove a service checkout and the run must
#      be INCOMPLETE (rc 3), never a pass.
echo "-- guard honesty: absent service sources must be INCOMPLETE, not green --"
rm -rf "${WORK}/src-missing"; cp -r "${WORK}/src-pristine" "${WORK}/src-missing"
rm -rf "${WORK}/src-missing/hugmesh-mod-bff-api"
# Run a STAGED COPY of the checker, so resolve_service_src()'s last-resort candidate
# — `repo_root.parent`, i.e. the directory holding the checker's own repo — is a temp
# dir with no checkouts in it. On a developer box that fallback is the operator's
# sibling-checkout tree, which DOES carry every repo, so the control silently proved
# nothing there and only ever bit in CI. Same checker, same inputs, no fallback.
mkdir -p "${WORK}/fakerepo/tests/scripts"
# The checker imports its sibling service_env_defaults module by name, so the whole
# scripts dir travels — copying the entry point alone dies on ModuleNotFoundError,
# which the assertion below would have read as "not INCOMPLETE" (rc 1, not 3).
cp "$(dirname "${CHECKER}")"/*.py "${WORK}/fakerepo/tests/scripts/"
OUT="$(SERVICE_SRC_ROOT="${WORK}/src-missing" python3 "${WORK}/fakerepo/tests/scripts/$(basename "${CHECKER}")" "${REPO}/specs/cluster" 2>&1)"; HRC=$?
if [ "${HRC}" -eq 3 ] && grep -q "INCOMPLETE" <<<"${OUT}"; then
  neg_ok "a missing service checkout is INCOMPLETE (rc 3), not a silent pass"
else
  neg_bad "a missing service checkout did NOT force INCOMPLETE (rc=${HRC})"
  sed 's/^/        /' <<<"${OUT}" | tail -10
fi

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
if [ "${NEG_F}" -ne 0 ]; then
  echo "== service env contract: FAIL (the gate itself is not biting) =="
  exit 1
fi
echo "== service env contract: PASS =="
# The verdict, as an exit status and not just a printed word. Reachable only
# when the NEG_F guard above did not fire, so it is behaviour-neutral today —
# it exists so the status stays carried if a later check lands after this line.
[ "${NEG_F}" -eq 0 ]
