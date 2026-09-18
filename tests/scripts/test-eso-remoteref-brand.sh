#!/usr/bin/env bash
# test-eso-remoteref-brand.sh — the Vault BASE SEGMENT that ESO reads must follow
# BRAND, on the path ArgoCD actually serves, and the in-cluster writer must move
# with it. Issue #285; decision 38 = B on hugmesh-generator#347 ("Template the
# brand into all 143 ExternalSecret remoteRef keys. The reader follows the writer,
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
  "specs/cluster/apps/04-external-secrets-config.yaml|specs/cluster/manifests/external-secrets|121|no"
  "specs/cluster/apps/12-cloudflared.yaml|specs/cluster/manifests/cloudflared|1|no"
  "specs/cluster/apps/03b-harbor-provision.yaml|specs/cluster/manifests/harbor|0|yes"
)

# THE EXPECTED CENSUS. Recomputed below from the tree, never taken on faith; the
# numbers are here so a change that moves one of them has to say so in a diff.
EXP_TOTAL=143      # every "key: hugmesh/" literal under specs/cluster
EXP_LIVE=141       # ... minus the 2 commented-out examples in velero-externalsecrets.yaml
EXP_SERVED=121     # ... carried by apps/04 (files listed in its kustomization resources)
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
  printf '%s\n' "$(extract_fn rebrand_sysroot "${REPO}/${b}")" | grep -av '^[[:space:]]*#' \
    | grep -aq 'var/lib/hugmesh/cluster' || { ok "${b}: does not walk the baked cluster tree (rule present for parity)"; continue; }
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
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
