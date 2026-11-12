#!/usr/bin/env bash
# test-eso-remoteref-brand.sh — the Vault BASE SEGMENT that ESO reads must follow
# BRAND, on the path ArgoCD actually serves, and the in-cluster writer must move
# with it. Issue #285; decision 38 = B on hugmesh-generator#347 ("Template the
# brand into all 145 ExternalSecret remoteRef keys. The reader follows the writer,
# so a non-hugmesh BRAND works end to end.").
#
# --- THE MECHANISM, AND THE DEFECT THAT ALMOST SHIPPED INSTEAD ----------------
# An ExternalSecret remoteRef is "key: <base>/<doc>". The WRITERS are
# scripts/gen-cluster-secrets.sh (BASE="${BRAND:-hugmesh}") and the in-cluster
# harbor-provision Job (vault_put_merge("<VAULT_KV_BASE>/harbor-robots", ...)).
# Before this suite existed the READERS were the bare literal hugmesh/<doc>, so a
# mesh built with --brand != hugmesh read paths nothing had ever written.
#
# The FIRST attempt at decision 38 fixed that with a sed over the baked sysroot
# copy at ${SYSROOT}/var/lib/hugmesh/cluster/manifests. That is INERT, and this
# suite exists partly so nobody rebuilds it:
#   * specs/cluster/apps/04-external-secrets-config.yaml (and 03b, and 12) are
#     ArgoCD Applications whose source is a git repoURL + path. ESO reads the
#     manifests FROM GIT -- identical bytes for every mesh, branded or not.
#   * specs/cluster/bootstrap/bootstrap.sh applies from the baked tree ONLY
#     namespaces/namespaces.yaml, manifests/local-path and apps/*.yaml (the
#     Application OBJECTS), never the manifests those Applications point at. Its
#     own closing line says so.
# So the ONE brand-aware thing on ArgoCD's serving path is the Application object,
# because that IS applied from the baked tree. Hence the shape under test:
#   1. a single value surface -- the annotation platform.hugmesh.net/vault-base --
#      on the ClusterSecretStore (ESO tree), on the cloudflared ExternalSecret and
#      on the harbor-provision Job;
#   2. a "replacements" block in each git-served kustomization.yaml that copies
#      that annotation into the first "/"-delimited segment of every remoteRef key
#      (and onto harbor's VAULT_KV_BASE env);
#   3. a one-line kustomize JSON-6902 op in apps/{04,03b,12} that SETS the
#      annotation, plus a sentinel pair in all ten build-*-stage4.sh rebrand chains
#      that rewrites that one value to <BRAND> instead of letting the catch-all
#      "hugmesh -> ORG" rule eat it.
# The annotation key deliberately lives in the FROZEN platform.hugmesh.net
# namespace, which the rebrand chain already protects, so only the VALUE moves.
#
# --- WHAT THIS SUITE MEASURES ------------------------------------------------
# It renders what ArgoCD renders: the BAKED (rebranded) Application object plus the
# UPSTREAM git manifests, through real kustomize. tests/scripts/lib/
# eso_brand_render.py does exactly what ArgoCD's kustomize source does. It never
# inspects the baked manifests copy, because nothing reads it.
#
# REQUIRES kubectl (or kustomize) and PyYAML, and FAILS rather than skipping when
# they are missing: a silent skip here would report a pass over nothing.
#
# MUTATION-TESTED: dropping either capture rule, dropping the restore, moving the
# capture below the catch-all, restoring to ${_org} instead of ${_brand}, dropping
# the rule from one builder, dropping a "replacements" block, dropping an
# Application patch, leaving harbor's writer behind, and adding a dataFrom-only
# ExternalSecret without listing it in the reject set are each caught. The battery
# and its output are in the PR on issue #285.

# --- SECTION (7): THE SAME DEFECT FOR THE IdP ISSUER (issue #530) -------------
# rewrite_idp_sysroot() had the identical blind spot: it re-pointed the issuer and
# JWKS literals of the baked manifests copy, which nothing reads. Section (7) pins
# the fix: per-directory idp-trust carriers + replacements in git, a one-line op in
# each owning Application, inline casdoor values in the four gateway Applications.
# It needs helm as well (the extras job installs it).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="${REPO}/tests/scripts/lib/eso_brand_render.py"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# Harmless stubs for the builder helpers rebrand_sysroot calls.
info() { :; }
warn() { :; }
err()  { echo "ERR: $*" >&2; }
banner() { :; }
extract_fn() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }

command -v python3 >/dev/null || { echo "FATAL: python3 missing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML missing -- this suite cannot parse or render; refusing to report a pass"; exit 2; }
command -v kustomize >/dev/null 2>&1 || command -v kubectl >/dev/null 2>&1 || {
  echo "FATAL: neither kustomize nor kubectl on PATH -- this suite renders what ArgoCD renders and cannot run without one; refusing to report a pass"; exit 2; }
[ -f "${RENDER}" ] || { echo "FATAL: ${RENDER} missing"; exit 2; }

DEFAULT_BASE="hugmesh"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "${TMPROOT}"' EXIT

BUILDERS=(
  build-frite-stage4.sh
  build-jetson-stage4.sh
  build-orangepi-zero2-stage4.sh
  build-orangepi-zero2w-stage4.sh
  build-orangepi-zero3-stage4.sh
  build-orangepi3-lts-stage4.sh
  build-orangepi4-lts-stage4.sh
  build-orangepi5-stage4.sh
  build-rpi5-stage4.sh
  build-x86-host-stage4.sh
)

# app|git tree it serves|expected ExternalSecret key count|expects a harbor env
APPS=(
  "specs/cluster/apps/04-external-secrets-config.yaml|specs/cluster/manifests/external-secrets|127|no"
  "specs/cluster/apps/12-cloudflared.yaml|specs/cluster/manifests/cloudflared|1|no"
  "specs/cluster/apps/03b-harbor-provision.yaml|specs/cluster/manifests/harbor|0|yes"
)

# THE EXPECTED CENSUS. Recomputed below from the tree, never taken on faith; the
# numbers are here so a change that moves one of them has to say so in a diff.
# 149/147/127: 4e829ae0 (#848, games-bff) and 86ae63f6 (#885, mesh-token-issuer +
# headscale-admin) each bumped the census from the same base; the merge kept only one bump.
EXP_TOTAL=149      # every "key: hugmesh/" literal under specs/cluster
EXP_LIVE=147       # ... minus the 2 commented-out examples in velero-externalsecrets.yaml
EXP_SERVED=127     # ... carried by apps/04 (files listed in its kustomization resources)
EXP_CLOUDFLARED=1  # ... carried by apps/12
EXP_CASDOOR=3      # ... per-DOMAIN, patched by apps/05b's ApplicationSet (slug, not brand)
EXP_UNSERVED=16    # ... in files NOT listed in resources: azure-intune 3 (commented out,
                   #     opt-in), device-ssh .tpl 4 (a template), meshbridge 5, tube 4.
                   #     Not served, so not read; add one to resources and target (a) of
                   #     the replacements block picks it up automatically.

echo "== (0) builder census: the list and the tree agree =="
n_tree=$(cd "${REPO}" && ls -1 build-*-stage4.sh 2>/dev/null | wc -l)
[ "${n_tree}" -eq "${#BUILDERS[@]}" ] \
  && ok "builder list covers all ${n_tree} build-*-stage4.sh" \
  || bad "builder list has ${#BUILDERS[@]} entries, the tree has ${n_tree}"
for b in "${BUILDERS[@]}"; do [ -f "${REPO}/${b}" ] || bad "listed builder missing: ${b}"; done

echo
echo "== (1) THE MECHANISM: ArgoCD serves these manifests from GIT, not the baked tree =="
for row in "${APPS[@]}"; do
  IFS='|' read -r app dir _n _harbor <<<"${row}"
  base="$(basename "${app}")"
  out="$(python3 - "${REPO}/${app}" <<'PY'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
s = a["spec"]["source"]
print(s.get("repoURL", "-"), s.get("path", "-"), len(s.get("kustomize", {}).get("patches", [])))
PY
)"
  read -r repourl path npatch <<<"${out}"
  case "${repourl}" in
    http*://*|git@*) ok "${base}: source is a git repoURL (${repourl})" ;;
    *) bad "${base}: source.repoURL is '${repourl}' -- if this stopped being a git source, the model this suite pins changes" ;;
  esac
  [ "${path}" = "${dir}" ] \
    && ok "${base}: serves ${path} (so a sed over the BAKED copy of it is inert)" \
    || bad "${base}: serves '${path}', expected '${dir}'"
  [ "${npatch}" -ge 1 ] \
    && ok "${base}: carries ${npatch} kustomize patch -- the one brand seam on the serving path" \
    || bad "${base}: carries NO kustomize patch, so nothing can move its Vault base"
done

BOOT="${REPO}/specs/cluster/bootstrap/bootstrap.sh"
if [ -f "${BOOT}" ]; then
  leak=$(grep -na 'kubectl apply' "${BOOT}" | grep -a 'CLUSTER_DIR' \
         | grep -acE 'manifests/(external-secrets|harbor|cloudflared)')
  [ "${leak}" -eq 0 ] \
    && ok "bootstrap.sh applies NO baked manifests/{external-secrets,harbor,cloudflared} -- git is the reader" \
    || bad "bootstrap.sh now applies a BAKED manifests dir under test (${leak} site) -- the serving model changed; the builder rule targets apps/*.yaml only and must be revisited"
else
  bad "specs/cluster/bootstrap/bootstrap.sh missing -- cannot pin the serving model"
fi

echo
echo "== (2) CENSUS: every 'key: <base>/' literal under specs/cluster is accounted for =="
CENSUS="${TMPROOT}/census.json"
CENSUS_OUT="${CENSUS}" python3 - "${REPO}" <<'PY'
import os, re, sys, json, yaml
repo = sys.argv[1]
pat = re.compile(r"key: *['\"]?hugmesh/")
total = live = 0
per = {}
for dp, _, fns in os.walk(os.path.join(repo, "specs/cluster")):
    for fn in fns:
        if not (fn.endswith(".yaml") or fn.endswith(".hbs")):
            continue
        p = os.path.join(dp, fn)
        txt = open(p, encoding="utf-8", errors="replace").read()
        n = len(pat.findall(txt))
        if not n:
            continue
        nl = sum(1 for l in txt.splitlines() if pat.search(l) and not l.strip().startswith("#"))
        total += n
        live += nl
        per[os.path.relpath(p, repo)] = nl
served = os.path.join(repo, "specs/cluster/manifests/external-secrets")
res = set(yaml.safe_load(open(os.path.join(served, "kustomization.yaml")))["resources"])
in_res = out_res = 0
offenders = []
for fn in sorted(os.listdir(served)):
    rel = "specs/cluster/manifests/external-secrets/" + fn
    if rel not in per:
        continue
    if fn in res:
        in_res += per[rel]
    else:
        out_res += per[rel]
        offenders.append("%s(%d)" % (fn, per[rel]))
json.dump({
    "total": total, "live": live, "in_resources": in_res, "out_of_resources": out_res,
    "casdoor_domain": per.get("specs/cluster/manifests/casdoor-domain/external-secrets.yaml", 0),
    "cloudflared": per.get("specs/cluster/manifests/cloudflared/externalsecret.yaml", 0),
    "unserved_files": offenders,
    "other": {k: v for k, v in per.items()
              if not k.startswith("specs/cluster/manifests/external-secrets/")
              and k not in ("specs/cluster/manifests/casdoor-domain/external-secrets.yaml",
                            "specs/cluster/manifests/cloudflared/externalsecret.yaml")},
}, open(os.environ["CENSUS_OUT"], "w"))
PY
cj() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "${CENSUS}" "$1"; }
for pair in "total:${EXP_TOTAL}" "live:${EXP_LIVE}" "in_resources:${EXP_SERVED}" \
            "out_of_resources:${EXP_UNSERVED}" "casdoor_domain:${EXP_CASDOOR}" \
            "cloudflared:${EXP_CLOUDFLARED}"; do
  k="${pair%%:*}"; want="${pair##*:}"; got="$(cj "${k}")"
  [ "${got}" = "${want}" ] \
    && ok "census ${k} = ${got}" \
    || bad "census ${k} = ${got}, recorded ${want} -- a Vault key literal appeared or moved; account for it here (unserved files: $(cj unserved_files))"
done
other="$(cj other)"
[ "${other}" = "{}" ] \
  && ok "no Vault key literal outside the three accounted trees" \
  || bad "Vault key literals in an UNACCOUNTED file -- ${other}"
sum=$(( $(cj in_resources) + $(cj out_of_resources) + $(cj casdoor_domain) + $(cj cloudflared) ))
[ "${sum}" -eq "$(cj live)" ] \
  && ok "census closes: ${sum} == live ${sum}" \
  || bad "census does NOT close: parts sum to ${sum}, live is $(cj live)"

echo
echo "== (3) the default render is unchanged: every base is '${DEFAULT_BASE}' =="
for row in "${APPS[@]}"; do
  IFS='|' read -r app dir n harbor <<<"${row}"
  base="$(basename "${app}")"
  j="$(python3 "${RENDER}" "${REPO}/${app}" "${REPO}/${dir}")" || { bad "${base}: render failed"; continue; }
  g() { python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(json.dumps(d.get(sys.argv[2])))' "${j}" "$1"; }
  [ "$(g error)" = "null" ] || { bad "${base}: kustomize render errored -- $(g error)"; continue; }
  [ "$(g n_keys)" = "${n}" ] \
    && ok "${base}: renders ${n} ExternalSecret Vault key(s)" \
    || bad "${base}: renders $(g n_keys) Vault key(s), expected ${n}"
  if [ "${n}" -gt 0 ]; then
    [ "$(g bases)" = "{\"${DEFAULT_BASE}\": ${n}}" ] \
      && ok "${base}: all ${n} bases are '${DEFAULT_BASE}' by default" \
      || bad "${base}: default bases are $(g bases), expected all '${DEFAULT_BASE}'"
  fi
  if [ "${harbor}" = "yes" ]; then
    [ "$(g harbor_vault_kv_base)" = "\"${DEFAULT_BASE}\"" ] \
      && ok "${base}: the WRITER's VAULT_KV_BASE is '${DEFAULT_BASE}' by default" \
      || bad "${base}: VAULT_KV_BASE renders $(g harbor_vault_kv_base), expected '${DEFAULT_BASE}'"
  fi
  [ "$(g sentinel_leak)" = "false" ] \
    && ok "${base}: no rebrand sentinel in the default render" \
    || bad "${base}: a @@SDSYS...@@ sentinel leaked into the default render"
done

echo
echo "== (4) the sentinel pair is present, capture FIRST and restore LAST, in all ten builders =="
for b in "${BUILDERS[@]}"; do
  src="$(extract_fn rebrand_sysroot "${REPO}/${b}")"
  [ -n "${src}" ] || { bad "${b}: could not extract rebrand_sysroot"; continue; }
  body="$(printf '%s\n' "${src}" | grep -av '^[[:space:]]*#')"
  nums="$(printf '%s\n' "${body}" | grep -an -e '~1vault-base, value: ' -e 'vault-base: \\"' \
          -e '@@SDSYSVAULTBASE@@|\${_brand}' -e 'hugmesh|\${_org}' | sed 's/:.*//' | tr '\n' ' ')"
  cap1=$(printf '%s\n' "${body}" | grep -acn '~1vault-base, value: ')
  cap2=$(printf '%s\n' "${body}" | grep -ac 'vault-base: \\"' )
  res=$(printf '%s\n' "${body}" | grep -ac '@@SDSYSVAULTBASE@@|\${_brand}')
  [ "${cap1}" -ge 1 ] && [ "${cap2}" -ge 1 ] \
    && ok "${b}: both vault-base capture rules present" \
    || bad "${b}: vault-base capture rules missing (patch-op=${cap1} annotation=${cap2})"
  [ "${res}" -eq 1 ] \
    && ok "${b}: exactly one restore to \${_brand}" \
    || bad "${b}: ${res} restores to \${_brand}, expected 1 (a restore to \${_org} or none is the bug)"
  ln_cap=$(printf '%s\n' "${body}" | grep -an '~1vault-base, value: ' | head -1 | cut -d: -f1)
  # build-rpi5 spells the catch-all with the RAW ${ORG} (issue #491); the other
  # nine route it through the escaped ${_org}. Accept both.
  ln_catch=$(printf '%s\n' "${body}" | grep -anE 's\|hugmesh\|\$\{(_org|ORG)\}\|g' | head -1 | cut -d: -f1)
  ln_res=$(printf '%s\n' "${body}" | grep -an '@@SDSYSVAULTBASE@@|\${_brand}' | head -1 | cut -d: -f1)
  if [ -n "${ln_cap}" ] && [ -n "${ln_catch}" ] && [ -n "${ln_res}" ]; then
    [ "${ln_cap}" -lt "${ln_catch}" ] \
      && ok "${b}: capture runs BEFORE the catch-all hugmesh -> ORG" \
      || bad "${b}: capture is at line ${ln_cap}, the catch-all at ${ln_catch} -- the catch-all eats the value first"
    [ "${ln_res}" -gt "${ln_catch}" ] \
      && ok "${b}: restore runs AFTER the catch-all" \
      || bad "${b}: restore is at line ${ln_res}, the catch-all at ${ln_catch} -- the restored value gets rebranded again"
  else
    bad "${b}: could not locate capture/catch-all/restore lines (${ln_cap:-?}/${ln_catch:-?}/${ln_res:-?})"
  fi
done

echo
echo "== (5) END TO END: the BAKED Application + the GIT manifests, through real kustomize =="
# The four BRAND/ORG corners. (hugmesh, widgetco) is the one a default-brand mesh
# that only sets --org lands in -- Studio passes --org from the profile -- and is
# exactly where a naive "rewrite hugmesh to BRAND" rule is a no-op.
CORNERS=("acme widgetco" "acme hugmesh" "hugmesh widgetco" "acme acme")
for b in "${BUILDERS[@]}"; do
  for fn in _sed_rep_escape rebrand_sysroot; do
    s="$(extract_fn "${fn}" "${REPO}/${b}")"
    [ -n "${s}" ] || { bad "${b}: could not extract ${fn}"; continue 2; }
    eval "${s}"
  done
  # Only builders whose rebrand walks the baked cluster tree can carry the brand.
  # NOT `grep -q` here: this file runs under `set -o pipefail`, where a -q that exits
  # the moment it matches can SIGPIPE its upstream and report FAILURE on a match it
  # actually found. This is a NEGATIVE guard, so that coin flip would fail OPEN and
  # skip every behavioural check below. Drain with >/dev/null instead.
  walks=0
  printf '%s\n' "$(extract_fn rebrand_sysroot "${REPO}/${b}")" | grep -av '^[[:space:]]*#' \
    | grep -a 'var/lib/hugmesh/cluster' >/dev/null && walks=1
  [ "${walks}" -eq 1 ] || { ok "${b}: does not walk the baked cluster tree (rule present for parity)"; continue; }
  for corner in "${CORNERS[@]}"; do
    read -r brand org <<<"${corner}"
    SYSROOT="${TMPROOT}/sr"; rm -rf "${SYSROOT}"
    mkdir -p "${SYSROOT}/var/lib/hugmesh/cluster" "${SYSROOT}/etc/hugmesh"
    cp -r "${REPO}/specs/cluster/apps" "${SYSROOT}/var/lib/hugmesh/cluster/apps"
    BRAND="${brand}" ORG="${org}" BRAND_TITLE="Acme Mesh" CLUSTER_DOMAIN=example.org \
      GAMES_DOMAIN=acme.games rebrand_sysroot
    for row in "${APPS[@]}"; do
      IFS='|' read -r app dir n harbor <<<"${row}"
      baked="${SYSROOT}/var/lib/hugmesh/cluster/${app#specs/cluster/}"
      tag="${b} BRAND=${brand} ORG=${org} $(basename "${app}")"
      [ -f "${baked}" ] || { bad "${tag}: the baked Application is missing"; continue; }
      j="$(python3 "${RENDER}" "${baked}" "${REPO}/${dir}")" || { bad "${tag}: render failed"; continue; }
      g() { python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(json.dumps(d.get(sys.argv[2])))' "${j}" "$1"; }
      [ "$(g error)" = "null" ] || { bad "${tag}: kustomize errored -- $(g error)"; continue; }
      if [ "${n}" -gt 0 ]; then
        [ "$(g bases)" = "{\"${brand}\": ${n}}" ] \
          && ok "${tag}: all ${n} reader bases are '${brand}'" \
          || bad "${tag}: reader bases are $(g bases) -- the reader does NOT follow the writer"
      fi
      if [ "${harbor}" = "yes" ]; then
        [ "$(g harbor_vault_kv_base)" = "\"${brand}\"" ] \
          && ok "${tag}: the in-cluster WRITER's VAULT_KV_BASE is '${brand}'" \
          || bad "${tag}: VAULT_KV_BASE is $(g harbor_vault_kv_base), expected '${brand}' -- writer and reader disagree"
      fi
      [ "$(g sentinel_leak)" = "false" ] \
        && ok "${tag}: no sentinel leak" \
        || bad "${tag}: a @@SDSYS...@@ sentinel reached the rendered manifests"
    done
  done
  # default branding must stay a byte no-op over apps/
  SYSROOT="${TMPROOT}/sr"; rm -rf "${SYSROOT}"
  mkdir -p "${SYSROOT}/var/lib/hugmesh/cluster" "${SYSROOT}/etc/hugmesh"
  cp -r "${REPO}/specs/cluster/apps" "${SYSROOT}/var/lib/hugmesh/cluster/apps"
  before="$(find "${SYSROOT}" -type f | sort | xargs cat | cksum)"
  BRAND=hugmesh ORG=hugmesh BRAND_TITLE="HugMesh Systems" CLUSTER_DOMAIN=hugmesh.net \
    GAMES_DOMAIN=games.hugmesh.net rebrand_sysroot
  after="$(find "${SYSROOT}" -type f | sort | xargs cat | cksum)"
  [ "${before}" = "${after}" ] \
    && ok "${b}: default branding leaves the baked apps/ byte-identical" \
    || bad "${b}: default branding MUTATED the baked apps/ tree"
  rm -rf "${SYSROOT}"
done

echo
echo "== (6) the WRITER's base is brand-derived, and the two halves are named together =="
GEN="${REPO}/scripts/gen-cluster-secrets.sh"
if grep -aq '^BASE="\${BRAND:-hugmesh}"' "${GEN}"; then
  ok "gen-cluster-secrets.sh writes under BASE=\${BRAND:-hugmesh}"
else
  bad "gen-cluster-secrets.sh's BASE= is no longer \${BRAND:-hugmesh} -- the reader now follows BRAND, so moving the writer silently desyncs every mesh: $(grep -a '^BASE=' "${GEN}" | head -1)"
fi
if grep -aq 'VAULT_KV_BASE' "${REPO}/specs/cluster/manifests/harbor/harbor-provision-job.yaml"; then
  ok "the harbor Job still names VAULT_KV_BASE (the second writer is still wired)"
else
  bad "the harbor Job no longer has VAULT_KV_BASE -- check (5) above is measuring nothing"
fi

echo
echo "== (7) THE IdP ISSUER (issue #530): rewrite_idp_sysroot reaches what ArgoCD serves =="
# The SAME serving model as (1)-(5), for the identity provider instead of the
# Vault base. rewrite_idp_sysroot() (x86 + rpi5 stage4 builders) re-points every
# https://id.<CLUSTER_DOMAIN> issuer and in-cluster Casdoor JWKS pin in the baked
# cluster tree at an external IdP when --idp is not casdoor. Before #530 every one
# of those literals lived in a git-served manifests/** directory, so the rewrite
# reached /etc/hugmesh and nothing a workload read. Each load-bearing directory now
# carries a local-config `idp-trust` ConfigMap (never emitted) whose
# platform.hugmesh.net/idp-* annotations a `replacements` block copies onto the
# env, and the owning Application sets those annotations with a one-line JSON-6902
# op that the builder's existing sed reaches. The four gateway Applications carry
# casdoor.issuerUri/jwksUri in their inline helm values for the same reason.
#
# This section runs the REAL rebrand_sysroot + rewrite_idp_sysroot, extracted from
# both builders, over a copy of apps/ + manifests/ + charts/, then renders each
# BAKED Application against the GIT directory through real kustomize (and helm for
# the gateways). It never asserts on the baked manifests copy: asserting there is
# what hid this. MUTATION-TESTED; the battery is in the PR on issue #530.
IDP_RENDER="${REPO}/tests/scripts/lib/idp_issuer_render.py"
[ -f "${IDP_RENDER}" ] || { bad "${IDP_RENDER} missing"; }
command -v helm >/dev/null 2>&1 || bad "helm missing: the four gateway charts cannot be rendered (the extras job installs it; refusing to report a pass without it)"
EXT_ISS="https://sso.example.net:8443/realms/mesh"
EXT_JWKS="https://sso.example.net:8443/realms/mesh/protocol/openid-connect/certs"
GAMES_REALM_ISS="https://id.hugmesh.games"
GAMES_REALM_JWKS="http://casdoor-games.hugmesh-games.svc.cluster.local:8000/.well-known/jwks"

# app|git dir|env key (Kind/name/container/ENV)|role. EVERY env that carries the
# mesh issuer or an in-cluster Casdoor JWKS pin in a load-bearing served directory.
IDP_ROWS=(
  "31-admin-bff-api.yaml|admin-bff-api|Deployment/hugmesh-admin-bff-api/hugmesh-admin-bff-api/CASDOOR_ISSUER_URI|issuer"
  "31-admin-bff-api.yaml|admin-bff-api|Deployment/hugmesh-admin-bff-api/hugmesh-admin-bff-api/CASDOOR_JWKS_URI|jwks"
  "39b-character-forge-bff-api.yaml|character-forge-bff-api|Deployment/hugmesh-character-forge-bff-api/hugmesh-character-forge-bff-api/CASDOOR_ISSUER_URI|issuer"
  "39b-character-forge-bff-api.yaml|character-forge-bff-api|Deployment/hugmesh-character-forge-bff-api/hugmesh-character-forge-bff-api/CASDOOR_JWKS_URI|jwks"
  "29-federation-api.yaml|federation-api|Deployment/hugmesh-federation-api/hugmesh-federation-api/CASDOOR_ISSUER_URI|issuer"
  "29-federation-api.yaml|federation-api|Deployment/hugmesh-federation-api/hugmesh-federation-api/CASDOOR_JWKS_URI|jwks"
  "39-forum-bff-api.yaml|forum-bff-api|Deployment/hugmesh-forum-bff-api/hugmesh-forum-bff-api/CASDOOR_ISSUER_URI|issuer"
  "39-forum-bff-api.yaml|forum-bff-api|Deployment/hugmesh-forum-bff-api/hugmesh-forum-bff-api/CASDOOR_JWKS_URI|jwks"
  "30-phpbb.yaml|forum|Deployment/phpbb/phpbb/HUGMESH_JWT_ISSUER|issuer"
  "30-phpbb.yaml|forum|Deployment/phpbb/phpbb/HUGMESH_JWKS_URI|jwks"
  "40-frontend.yaml|frontend|Deployment/hugmesh-host-shell/web/CASDOOR_ISSUER|issuer"
  "50-games.yaml|games|Deployment/hugmesh-games/games/APP_TENANCY_ISSUERS|tenancy-issuer"
  "50-games.yaml|games|Deployment/hugmesh-games/games/APP_TENANCY_JWKS_URIS|tenancy-jwks"
  "03b-harbor-provision.yaml|harbor|Job/harbor-provision/reconcile/CASDOOR_OIDC_ENDPOINT|issuer"
  "34d-mesh-bff-api.yaml|mesh-bff-api|Deployment/hugmesh-mesh-bff-api/hugmesh-mesh-bff-api/CASDOOR_ISSUER_URI|issuer"
  "34d-mesh-bff-api.yaml|mesh-bff-api|Deployment/hugmesh-mesh-bff-api/hugmesh-mesh-bff-api/CASDOOR_JWKS_URI|jwks"
  "33-mod-bff-api.yaml|mod-bff-api|Deployment/hugmesh-mod-bff-api/hugmesh-mod-bff-api/CASDOOR_ISSUER_URI|issuer"
  "33-mod-bff-api.yaml|mod-bff-api|Deployment/hugmesh-mod-bff-api/hugmesh-mod-bff-api/CASDOOR_JWKS_URI|jwks"
  "52-owncast.yaml|owncast|Deployment/hugmesh-owncast/owncast-bff-api/CASDOOR_ISSUER_URI|issuer"
  "52-owncast.yaml|owncast|Deployment/hugmesh-owncast/owncast-bff-api/CASDOOR_JWKS_URI|jwks"
  "53-tube.yaml|tube|Deployment/hugmesh-tube/tube-bff-api/CASDOOR_ISSUER_URI|issuer"
  "53-tube.yaml|tube|Deployment/hugmesh-tube/tube-bff-api/CASDOOR_JWKS_URI|jwks"
  "37-user-bff-api.yaml|user-bff-api|Deployment/hugmesh-user-bff-api/hugmesh-user-bff-api/CASDOOR_ISSUER_URI|issuer"
  "37-user-bff-api.yaml|user-bff-api|Deployment/hugmesh-user-bff-api/hugmesh-user-bff-api/CASDOOR_JWKS_URI|jwks"
  "34b-wiki-bff-api.yaml|wiki-bff-api|Deployment/hugmesh-wiki-bff-api/hugmesh-wiki-bff-api/CASDOOR_ISSUER_URI|issuer"
  "34b-wiki-bff-api.yaml|wiki-bff-api|Deployment/hugmesh-wiki-bff-api/hugmesh-wiki-bff-api/CASDOOR_JWKS_URI|jwks"
)
GATEWAY_APPS=(20-gateway-be.yaml 20-gateway-fe.yaml 20-gateway-pki.yaml 22-gateway-superadmin.yaml)
# The minter: Casdoor's app.conf `origin`, carried by apps/05 the same way.
MINTER_APP=05-casdoor.yaml
MINTER_DIR=casdoor
ORIGIN_RE='origin = "([^"]*)"'

# THE CENSUS (issue #530's measurement): every file under specs/cluster/manifests
# with an `https://id.` literal, and what it is. A new one goes red here until it
# is classified, and a `moved` one must have a row above.
#   moved    - load-bearing runtime config on an external-IdP mesh's path; carried
#   held     - load-bearing, but the file is held by another open PR (follow-up)
#   off-path - only on a casdoor mesh: gate_casdoor_apps() removes its Application
#   per-domain - the casdoor-domains ApplicationSet already patches it per domain
#   prose    - a comment, or a code fallback that the env above overrides
#   carrier  - the idp-trust value surface this section pins (kustomization.yaml)
#   minter   - Casdoor's own `origin`: the `iss` it mints. Off an external-IdP mesh
#              (gate_casdoor_apps), but it must follow the validators everywhere
#              else, so it is carried too and checked for agreement in (7e)
IDP_CENSUS=(
  "admin-bff-api/deployment.yaml|moved"
  "akkoma/akkoma.yaml|held"
  "casdoor/app-conf-configmap.yaml|minter"
  "casdoor-games/app-conf-configmap.yaml|off-path"
  "casdoor-domain/app-conf-configmap.yaml|prose"
  "casdoor-domain/deployment.yaml|prose"
  "casdoor-domain/ingress.yaml|prose"
  "casdoor-domain/init-job.yaml|prose"
  "casdoor-domain/kustomization.yaml|prose"
  "casdoor-domain/params-configmap.yaml|per-domain"
  "casdoor-domain/service.yaml|prose"
  "character-forge-bff-api/deployment.yaml|moved"
  "federation-api/deployment.yaml|moved"
  "forum-bff-api/deployment.yaml|moved"
  "forum/phpbb.yaml|moved"
  "frontend/deployment.yaml|moved"
  "games/deployment.yaml|moved"
  "harbor/harbor-provision-job.yaml|moved"
  "harbor/harbor-provision-job.yaml.hbs|prose"
  "mesh-bff-api/deployment.yaml|moved"
  "mod-bff-api/deployment.yaml|moved"
  "owncast/deployment.yaml|moved"
  "remote-fragment/deployment.yaml|prose"
  "tube/deployment.yaml|moved"
  "user-bff-api/deployment.yaml|moved"
  "wiki-bff-api/deployment.yaml|moved"
  "admin-bff-api/kustomization.yaml|carrier"
  "character-forge-bff-api/kustomization.yaml|carrier"
  "federation-api/kustomization.yaml|carrier"
  "forum-bff-api/kustomization.yaml|carrier"
  "forum/kustomization.yaml|carrier"
  "frontend/kustomization.yaml|carrier"
  "games/kustomization.yaml|carrier"
  "harbor/kustomization.yaml|carrier"
  "mesh-bff-api/kustomization.yaml|carrier"
  "mod-bff-api/kustomization.yaml|carrier"
  "owncast/kustomization.yaml|carrier"
  "tube/kustomization.yaml|carrier"
  "user-bff-api/kustomization.yaml|carrier"
  "wiki-bff-api/kustomization.yaml|carrier"
  "casdoor/kustomization.yaml|carrier"
)
MAN="${REPO}/specs/cluster/manifests"
census_tree="$(cd "${MAN}" && grep -rlaF 'https://id.' . | sed 's|^\./||' | sort)"
census_table="$(printf '%s\n' "${IDP_CENSUS[@]}" | cut -d'|' -f1 | sort)"
n_tree=$(printf '%s\n' "${census_tree}" | grep -c .)
[ "${census_tree}" = "${census_table}" ] \
  && ok "census: all ${n_tree} manifests files with an https://id. literal are classified" \
  || bad "census: tree and table differ -- unclassified: $(comm -23 <(echo "${census_tree}") <(echo "${census_table}") | tr '\n' ' ')| stale: $(comm -13 <(echo "${census_tree}") <(echo "${census_table}") | tr '\n' ' ')"
for c in "${IDP_CENSUS[@]}"; do
  IFS='|' read -r f cls <<<"${c}"
  case "${cls}" in moved|carrier|minter) : ;; *) continue ;; esac
  d="${f%%/*}"
  { [ "${d}" = "${MINTER_DIR}" ] || printf '%s\n' "${IDP_ROWS[@]}" | cut -d'|' -f2 | grep -xF "${d}" >/dev/null; } \
    && ok "census: ${f} (${cls}) has a render row" \
    || bad "census: ${f} is classified ${cls} but no IDP_ROWS entry renders ${d}"
done
# Strip every idp-trust op from an Application (negative control + default proof).
strip_idp_ops() { # in out
  python3 - "$1" "$2" <<'PY'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
k = a["spec"]["source"].get("kustomize", {})
k["patches"] = [p for p in k.get("patches", []) if (p.get("target") or {}).get("name") != "idp-trust"]
if not k["patches"]:
    k.pop("patches")
if "kustomize" in a["spec"]["source"] and not k:
    a["spec"]["source"].pop("kustomize")
yaml.safe_dump(a, open(sys.argv[2], "w"), sort_keys=False)
PY
}
strip_gateway_casdoor() { # in out
  python3 - "$1" "$2" <<'PY'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
h = a["spec"]["source"]["helm"]
v = yaml.safe_load(h["values"]) or {}
v.pop("casdoor", None)
h["values"] = yaml.safe_dump(v, sort_keys=False)
yaml.safe_dump(a, open(sys.argv[2], "w"), sort_keys=False)
PY
}
expect_for() { # role -> expected value on an external-IdP mesh
  case "$1" in
    issuer) printf '%s' "${EXT_ISS}" ;;
    jwks)   printf '%s' "${EXT_JWKS}" ;;
    tenancy-issuer) printf '%s' "${GAMES_REALM_ISS}=default,${EXT_ISS}=default" ;;
    tenancy-jwks)   printf '%s' "${GAMES_REALM_ISS}=${GAMES_REALM_JWKS},${EXT_ISS}=${EXT_JWKS}" ;;
  esac
}
jget() { python3 -c 'import json,sys;d=json.loads(sys.argv[1]);v=d
for k in sys.argv[2:]: v=(v or {}).get(k)
print(v if isinstance(v,str) else json.dumps(v))' "$@"; }
IDP_APPS="$(printf '%s\n' "${IDP_ROWS[@]}" | cut -d'|' -f1,2 | sort -u)"
ALL_APPS="$(printf '%s\n%s|%s\n' "${IDP_APPS}" "${MINTER_APP}" "${MINTER_DIR}")"
# A copy of the GIT manifests with every idp-trust replacement removed: the tree as
# it was before #530, plus inert local-config carriers. (7b) and (7d) use it.
NR="${TMPROOT}/no-repl"; rm -rf "${NR}"; cp -r "${MAN}" "${NR}"
while IFS='|' read -r _app _dir; do
  python3 - "${NR}/${_dir}/kustomization.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]
k = yaml.safe_load(open(p))
k["replacements"] = [r for r in k.get("replacements", []) if r.get("source", {}).get("name") != "idp-trust"]
if not k["replacements"]:
    k.pop("replacements")
yaml.safe_dump(k, open(p, "w"), sort_keys=False)
PY
done <<<"${ALL_APPS}"

# rows_moved <app-file> <git-manifests-root> -> prints one line per row: OK|BAD <detail>
rows_moved() {
  local appf="$1" root="$2" base dir j row key role want got
  base="$(basename "${appf}")"
  dir="$(printf '%s\n' "${IDP_ROWS[@]}" | awk -F'|' -v a="${base}" '$1==a{print $2; exit}')"
  j="$(python3 "${IDP_RENDER}" env "${appf}" "${root}/${dir}")" || { echo "BAD ${base}: render failed: $(jget "${j}" error | head -c 300)"; return; }
  for row in "${IDP_ROWS[@]}"; do
    IFS='|' read -r a d key role <<<"${row}"
    [ "${a}" = "${base}" ] || continue
    want="$(expect_for "${role}")"
    got="$(jget "${j}" env "${key}")"
    [ "${got}" = "${want}" ] && echo "OK ${base} ${key##*/} -> ${role}" \
      || echo "BAD ${base} ${key##*/} is '${got}', want '${want}'"
  done
}

echo "-- (7a) serving model: each owning Application is a git source and carries the op"
while IFS='|' read -r app dir; do
  f="${REPO}/specs/cluster/apps/${app}"
  out="$(python3 - "${f}" <<'PY'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
s = a["spec"]["source"]
ops = [p for p in s.get("kustomize", {}).get("patches", []) if (p.get("target") or {}).get("name") == "idp-trust"]
print(s.get("repoURL", "-"), s.get("path", "-"), len(ops))
PY
)"
  read -r repourl path nops <<<"${out}"
  case "${repourl}" in http*://*) : ;; *) bad "${app}: source.repoURL '${repourl}' is not git -- the model this section pins changed" ;; esac
  [ "${path}" = "specs/cluster/manifests/${dir}" ] \
    && ok "${app}: serves ${path} from git (a sed over the baked copy is inert)" \
    || bad "${app}: serves '${path}', expected specs/cluster/manifests/${dir}"
  [ "${nops}" -eq 1 ] && ok "${app}: carries the idp-trust op" || bad "${app}: carries ${nops} idp-trust op(s), expected 1"
done <<<"${ALL_APPS}"
if [ -f "${BOOT}" ]; then
  leak=$(grep -na 'kubectl apply' "${BOOT}" | grep -a 'CLUSTER_DIR' | grep -acE 'manifests/[a-z]' )
  lp=$(grep -na 'kubectl apply' "${BOOT}" | grep -a 'CLUSTER_DIR' | grep -acE 'manifests/local-path')
  [ "${leak}" -eq "${lp}" ] \
    && ok "bootstrap.sh applies no baked manifests dir but local-path -- git is the reader" \
    || bad "bootstrap.sh applies a baked manifests dir other than local-path -- the serving model changed"
fi

echo "-- (7b) a casdoor mesh renders byte-identically: the ops and values equal the defaults"
while IFS='|' read -r app dir; do
  f="${REPO}/specs/cluster/apps/${app}"
  # The whole mechanism (op + carrier + replacements) against neither: equal
  # bytes. Comparing only with/without the op would miss a replacement that
  # writes into the WRONG place, because the carrier default would still feed it.
  strip_idp_ops "${f}" "${TMPROOT}/stripped.yaml"
  a="$(python3 "${IDP_RENDER}" env "${f}" "${MAN}/${dir}")"
  b="$(python3 "${IDP_RENDER}" env "${TMPROOT}/stripped.yaml" "${NR}/${dir}")"
  [ "$(jget "${a}" error)" = "null" ] || { bad "${app}: render errored -- $(jget "${a}" error | head -c 300)"; continue; }
  [ "$(jget "${b}" error)" = "null" ] || { bad "${app}: the no-replacements render errored -- $(jget "${b}" error | head -c 300)"; continue; }
  [ "$(jget "${a}" text_sha)" = "$(jget "${b}" text_sha)" ] \
    && ok "${app}: op + replacements are a byte no-op on ${dir} at the casdoor defaults" \
    || bad "${app}: op + replacements CHANGE the ${dir} render at the casdoor defaults"
  # The carrier is local-config: kustomize must drop it. If it is emitted, every
  # mesh gains a stray ConfigMap and the "byte-identical" claim above is false.
  c="$(python3 "${IDP_RENDER}" count "${f}" "${MAN}/${dir}" "idp-trust" "platform.hugmesh.net/idp-")"
  [ "$(python3 -c 'import json,sys;print(sum(json.loads(sys.argv[1])["counts"].values()))' "${c}")" = "0" ] \
    && ok "${app}: the idp-trust carrier is not emitted (local-config holds)" \
    || bad "${app}: the idp-trust carrier or its annotations reach the ${dir} render: $(jget "${c}" counts)"
done <<<"${ALL_APPS}"
for g in "${GATEWAY_APPS[@]}"; do
  f="${REPO}/specs/cluster/apps/${g}"
  strip_gateway_casdoor "${f}" "${TMPROOT}/gw-stripped.yaml"
  a="$(python3 "${IDP_RENDER}" helm "${f}" "${REPO}/specs/cluster/charts/hugmesh-gateway")"
  b="$(python3 "${IDP_RENDER}" helm "${TMPROOT}/gw-stripped.yaml" "${REPO}/specs/cluster/charts/hugmesh-gateway")"
  [ "$(jget "${a}" error)" = "null" ] || { bad "${g}: helm errored -- $(jget "${a}" error | head -c 300)"; continue; }
  [ "$(jget "${a}" text_sha)" = "$(jget "${b}" text_sha)" ] \
    && ok "${g}: the inline casdoor values equal the chart defaults (byte no-op)" \
    || bad "${g}: the inline casdoor values CHANGE the gateway render"
done

echo "-- (7c) END TO END: real rebrand_sysroot + rewrite_idp_sysroot, then render what ArgoCD serves"
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh; do
  unset -f _sed_rep_escape rebrand_sysroot rewrite_idp_sysroot
  for fn in _sed_rep_escape rebrand_sysroot rewrite_idp_sysroot; do
    s="$(extract_fn "${fn}" "${REPO}/${b}")"
    [ -n "${s}" ] || { bad "${b}: could not extract ${fn}"; continue 2; }
    eval "${s}" || { bad "${b}: ${fn} does not parse"; continue 2; }
  done
  # corner: "<label> <brand> <org> <domain>"
  for corner in "default hugmesh hugmesh hugmesh.net" "branded acme widgetco example.org"; do
    read -r label brand org dom <<<"${corner}"
    SYSROOT="${TMPROOT}/idp-sr"; rm -rf "${SYSROOT}"
    C="${SYSROOT}/var/lib/hugmesh/cluster"
    mkdir -p "${C}" "${SYSROOT}/etc/hugmesh"
    cp -r "${REPO}/specs/cluster/apps" "${REPO}/specs/cluster/manifests" "${REPO}/specs/cluster/charts" "${C}/"
    if [ "${label}" = "default" ]; then title="HugMesh Systems"; games=hugmesh.games; else title="Acme Mesh"; games=acme.games; fi
    BRAND="${brand}" ORG="${org}" BRAND_TITLE="${title}" CLUSTER_DOMAIN="${dom}" GAMES_DOMAIN="${games}" rebrand_sysroot
    IDP=oidc IDP_ISSUER="${EXT_ISS}" IDP_JWKS="${EXT_JWKS}" CLUSTER_DOMAIN="${dom}" rewrite_idp_sysroot
    tag="${b} ${label}"
    while IFS='|' read -r app dir; do
      while read -r verdict rest; do
        [ "${verdict}" = "OK" ] && ok "${tag}: ${rest}" || bad "${tag}: ${rest}"
      done < <(rows_moved "${C}/apps/${app}" "${MAN}")
      # Residue: no mesh issuer or in-cluster Casdoor JWKS literal survives in the
      # render. Allowed: harbor's Python fallback default inside its script
      # ConfigMap (1), which the CASDOOR_OIDC_ENDPOINT env above overrides.
      lits=("https://id.hugmesh.net" "casdoor.hugmesh-pki.svc.cluster.local:8000/.well-known/jwks")
      [ "${dom}" = "hugmesh.net" ] || lits+=("https://id.${dom}")
      [ "${brand}" = "hugmesh" ] || lits+=("casdoor.${brand}-pki.svc.cluster.local:8000/.well-known/jwks")
      j="$(python3 "${IDP_RENDER}" count "${C}/apps/${app}" "${MAN}/${dir}" "${lits[@]}")"
      n=$(python3 -c 'import json,sys;print(sum(json.loads(sys.argv[1])["counts"].values()))' "${j}")
      allow=0; [ "${dir}" = "harbor" ] && allow=1
      [ "${n}" -eq "${allow}" ] \
        && ok "${tag} ${app}: no mesh-issuer/Casdoor-JWKS residue in the render (allowed ${allow})" \
        || bad "${tag} ${app}: ${n} issuer/JWKS literal(s) survive in the render, allowed ${allow}: $(jget "${j}" counts)"
      # ORACLE (default corner, where only rewrite_idp_sysroot moved anything):
      # what ArgoCD renders must equal the baked copy rendered as if it were read.
      if [ "${label}" = "default" ]; then
        o="$(python3 "${IDP_RENDER}" oracle "${C}/apps/${app}" "${MAN}/${dir}" "${C}/manifests/${dir}")"
        d="$(jget "${o}" diff)"
        # Exceptions, each deliberate: harbor's script carries a Python fallback
        # default that its env overrides; games' APP_TENANCY_JWKS_URIS keeps the
        # games REALM half (casdoor-games), which the builder's first sed rule also
        # rewrites. That realm's Casdoor is gated off on an external-IdP mesh, so
        # no token names it; only the mesh half (,<issuer>=<jwks>) is load-bearing.
        want="[]"
        [ "${dir}" = "harbor" ] && want='["ConfigMap/harbor-provision-script.data.reconcile.py"]'
        [ "${dir}" = "games" ] && want='["Deployment/hugmesh-games.spec.template.spec.containers[games].env[APP_TENANCY_JWKS_URIS].value"]'
        [ "${d}" = "${want}" ] \
          && ok "${tag} ${app}: ArgoCD's render == the builder's intent (oracle; exceptions ${want})" \
          || bad "${tag} ${app}: ArgoCD's render differs from the builder's intent at ${d} (want ${want})"
      fi
    done <<<"${IDP_APPS}"
    for g in "${GATEWAY_APPS[@]}"; do
      j="$(python3 "${IDP_RENDER}" helm "${C}/apps/${g}" "${REPO}/specs/cluster/charts/hugmesh-gateway")"
      [ "$(jget "${j}" error)" = "null" ] || { bad "${tag} ${g}: helm errored -- $(jget "${j}" error | head -c 300)"; continue; }
      gi=$(python3 -c 'import json,sys;e=json.loads(sys.argv[1])["env"];print(sorted({v for k,v in e.items() if k.endswith("/CASDOOR_ISSUER_URI")}))' "${j}")
      gj=$(python3 -c 'import json,sys;e=json.loads(sys.argv[1])["env"];print(sorted({v for k,v in e.items() if k.endswith("/CASDOOR_JWKS_URI")}))' "${j}")
      [ "${gi}" = "['${EXT_ISS}']" ] && [ "${gj}" = "['${EXT_JWKS}']" ] \
        && ok "${tag} ${g}: the gateway validates against the external issuer + JWKS" \
        || bad "${tag} ${g}: gateway CASDOOR_ISSUER_URI=${gi} CASDOOR_JWKS_URI=${gj}"
    done
    # Keep the default-corner tree of the first builder for the controls below.
    if [ "${b}" = "build-x86-host-stage4.sh" ] && [ "${label}" = "default" ]; then
      rm -rf "${TMPROOT}/idp-keep"; cp -r "${C}" "${TMPROOT}/idp-keep"
    fi
  done
done
rm -rf "${TMPROOT}/idp-sr"

echo "-- (7d) NEGATIVE CONTROLS: without the op, or without replacements, the issuer does NOT move"
K="${TMPROOT}/idp-keep"
if [ -d "${K}" ]; then
  # (i) drop the JSON-6902 op from each rewritten baked Application
  while IFS='|' read -r app dir; do
    mkdir -p "${TMPROOT}/ctl"
    strip_idp_ops "${K}/apps/${app}" "${TMPROOT}/ctl/${app}"
    nb=$(rows_moved "${TMPROOT}/ctl/${app}" "${MAN}" | grep -c '^BAD')
    [ "${nb}" -gt 0 ] && ok "control (no op) ${app}: the check goes red (${nb} env unmoved)" \
      || bad "control (no op) ${app}: the check stays GREEN without the op -- it measures nothing"
  done <<<"${IDP_APPS}"
  # (ii) the same rewritten Applications against the no-replacements copy
  while IFS='|' read -r app dir; do
    nb=$(rows_moved "${K}/apps/${app}" "${NR}" | grep -c '^BAD')
    [ "${nb}" -gt 0 ] && ok "control (no replacements) ${dir}: the check goes red (${nb} env unmoved)" \
      || bad "control (no replacements) ${dir}: the check stays GREEN without replacements -- it measures nothing"
  done <<<"${IDP_APPS}"
  rm -rf "${TMPROOT}/ctl"
  # (iii) the gateways without their inline casdoor values
  for g in "${GATEWAY_APPS[@]}"; do
    strip_gateway_casdoor "${K}/apps/${g}" "${TMPROOT}/gw-ctl.yaml"
    j="$(python3 "${IDP_RENDER}" helm "${TMPROOT}/gw-ctl.yaml" "${REPO}/specs/cluster/charts/hugmesh-gateway")"
    gi=$(python3 -c 'import json,sys;e=json.loads(sys.argv[1])["env"];print(sorted({v for k,v in e.items() if k.endswith("/CASDOOR_ISSUER_URI")}))' "${j}")
    [ "${gi}" != "['${EXT_ISS}']" ] && ok "control (no values) ${g}: the gateway stays on ${gi}" \
      || bad "control (no values) ${g}: the gateway moved WITHOUT its values -- the check measures nothing"
  done
  rm -rf "${K}"
else
  bad "no rewritten tree kept from (7c) -- the negative controls did not run"
fi

echo "-- (7e) a custom-domain CASDOOR mesh: the minter and every validator agree on \`iss\`"
# rebrand_sysroot rewrites the baked ops above to https://id.<CLUSTER_DOMAIN> on any
# non-default domain, external IdP or not. On a casdoor mesh the tokens' `iss` is
# Casdoor's app.conf origin, so it must move with them. akkoma is the one validator
# left behind (its directory is held by another open PR): a named follow-up.
origin_of() { jget "$(python3 "${IDP_RENDER}" match "$1" "$2" "${ORIGIN_RE}")" matches; }
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh; do
  unset -f _sed_rep_escape rebrand_sysroot rewrite_idp_sysroot
  for fn in _sed_rep_escape rebrand_sysroot rewrite_idp_sysroot; do
    s="$(extract_fn "${fn}" "${REPO}/${b}")"
    [ -n "${s}" ] || { bad "${b}: could not extract ${fn}"; continue 2; }
    eval "${s}" || { bad "${b}: ${fn} does not parse"; continue 2; }
  done
  for corner in "custom-domain hugmesh hugmesh" "branded acme widgetco"; do
    read -r label brand org <<<"${corner}"
    dom=example.org; want="https://id.${dom}"
    SYSROOT="${TMPROOT}/idp-sr"; rm -rf "${SYSROOT}"
    C="${SYSROOT}/var/lib/hugmesh/cluster"
    mkdir -p "${C}" "${SYSROOT}/etc/hugmesh"
    cp -r "${REPO}/specs/cluster/apps" "${C}/"
    BRAND="${brand}" ORG="${org}" BRAND_TITLE="Acme Mesh" CLUSTER_DOMAIN="${dom}" GAMES_DOMAIN=acme.games rebrand_sysroot
    IDP=casdoor IDP_ISSUER="" IDP_JWKS="" CLUSTER_DOMAIN="${dom}" rewrite_idp_sysroot
    tag="${b} ${label} casdoor"
    o="$(origin_of "${C}/apps/${MINTER_APP}" "${MAN}/${MINTER_DIR}")"
    [ "${o}" = "[\"${want}\"]" ] \
      && ok "${tag}: Casdoor mints iss ${want}" \
      || bad "${tag}: Casdoor's origin renders ${o}, want [\"${want}\"] -- the minter does not follow the validators"
    while IFS='|' read -r app dir; do
      j="$(python3 "${IDP_RENDER}" env "${C}/apps/${app}" "${MAN}/${dir}")"
      for row in "${IDP_ROWS[@]}"; do
        IFS='|' read -r a d key role <<<"${row}"
        [ "${a}" = "${app}" ] || continue
        got="$(jget "${j}" env "${key}")"
        case "${role}" in
          issuer) exp="${want}" ;;
          tenancy-issuer) exp="${GAMES_REALM_ISS}=default,${want}=default" ;;
          *) continue ;;
        esac
        [ "${got}" = "${exp}" ] \
          && ok "${tag}: ${app} ${key##*/} agrees with the minter" \
          || bad "${tag}: ${app} ${key##*/} is '${got}', the minter says '${exp}'"
      done
    done <<<"${IDP_APPS}"
    for g in "${GATEWAY_APPS[@]}"; do
      j="$(python3 "${IDP_RENDER}" helm "${C}/apps/${g}" "${REPO}/specs/cluster/charts/hugmesh-gateway")"
      gi=$(python3 -c 'import json,sys;e=json.loads(sys.argv[1])["env"];print(sorted({v for k,v in e.items() if k.endswith("/CASDOOR_ISSUER_URI")}))' "${j}")
      [ "${gi}" = "['${want}']" ] && ok "${tag}: ${g} agrees with the minter" \
        || bad "${tag}: ${g} validates against ${gi}, the minter says ${want}"
    done
    if [ "${b}" = "build-x86-host-stage4.sh" ] && [ "${label}" = "custom-domain" ]; then
      # Controls: without apps/05's op, or without casdoor's replacement, the
      # minter stays on the git literal and the agreement check must catch it.
      strip_idp_ops "${C}/apps/${MINTER_APP}" "${TMPROOT}/c05.yaml"
      o="$(origin_of "${TMPROOT}/c05.yaml" "${MAN}/${MINTER_DIR}")"
      [ "${o}" != "[\"${want}\"]" ] && ok "control (no op) ${MINTER_APP}: the minter stays on ${o}" \
        || bad "control (no op) ${MINTER_APP}: the minter moved WITHOUT its op -- the check measures nothing"
      o="$(origin_of "${C}/apps/${MINTER_APP}" "${NR}/${MINTER_DIR}")"
      [ "${o}" != "[\"${want}\"]" ] && ok "control (no replacements) ${MINTER_DIR}: the minter stays on ${o}" \
        || bad "control (no replacements) ${MINTER_DIR}: the minter moved WITHOUT its replacement -- the check measures nothing"
    fi
  done
done
rm -rf "${TMPROOT}/idp-sr" "${NR}"

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
