#!/usr/bin/env bash
# test-pki-role-san-coverage.sh — simulate Vault PKI issuance for every cert the
# cluster asks for. Pure PyYAML + bash; no cluster, no kubectl, no vault, no
# network.
#
# WHY THIS EXISTS. specs/cluster has two halves of one contract that nothing
# compared:
#
#   manifests/vault-pki/pki-init-configmap.yaml   creates the issuing roles
#   manifests/**/*-externalsecrets.yaml           ask those roles for certs
#
# They had silently diverged. The roles allowed
# `${app},${app}.svc.cluster.local,svc.cluster.local,${DOMAIN}` with
# allow_subdomains — which covers *.svc.cluster.local ONLY — while every ESO
# generator ALSO asks for the TWO-LABEL `<service>.<namespace>` SAN. On a live
# kind cluster the ESO controller logged, for every generic-loop app:
#
#   could not generate [0]: Error making API request.
#   URL: PUT https://vault.../v1/pki_int/issue/hugmesh-user-bff-api
#   Code: 400. Errors:
#   * subject alternate name hugmesh-user-bff-api.hugmesh-backend not allowed by this role
#
# so NOT ONE generic-loop app could ever be issued its mTLS cert: no keystore
# initContainer got material and the whole fleet mTLS wave was dead on arrival.
# It had been hit at least twice before — media-poisoner and harbor each carry a
# hand-patched copy of the role block with that exact two-label form pasted into
# their own allowed_domains — and each time it was papered over per-role instead
# of fixed in the loop. This gate exists so the NEXT one cannot ship: it fails
# the pipeline naming the exact (role, SAN) pair Vault would 400 on.
#
# It also closes the obvious wrong repair. Making coverage green by widening the
# role (a blanket `svc.cluster.local`, the cluster domain, allow_any_name) hands
# every role the right to mint every OTHER workload's identity off the shared
# cluster CA — so [pki-san-containment] fails instead. Both directions come from
# one faithful port of Vault's own ValidateNames.
#
# Layout mirrors test-cluster-manifest-integrity.sh: a positive run over the
# repo's own tree, then NEGATIVE CONTROLS — each defect class injected into a
# staged copy, each of which MUST bite — plus a self-test of the ported matcher,
# because a gate whose matcher is wrong is worse than no gate.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

CHECKER="$(dirname "${BASH_SOURCE[0]}")/pki_role_san_coverage.py"
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

echo "== Vault PKI role <-> ExternalSecret SAN coverage gate =="

# ── (0) MATCHER SELF-TEST ────────────────────────────────────────────────────
# The whole gate is only as good as its port of issuing.ValidateNames. These
# assertions pin the semantics that are easy to get wrong, and that getting
# wrong in either direction produces a silently useless gate:
#   * allow_subdomains is HasSuffix("."+entry) => ANY prefix depth, so
#     svc.cluster.local matches a.b.svc.cluster.local but NOT the bare a.b
#   * allow_bare_domains is an EXACT match, label count irrelevant
#   * allow_glob_domains only fires when the ENTRY holds a '*', and go-glob's
#     '*' spans dots (it is not fnmatch)
#   * allow_localhost DEFAULTS TO TRUE in Vault, so an unset role leaks it
echo "-- matcher self-test: the ported Vault semantics --"
python3 - "$(dirname "${BASH_SOURCE[0]}")" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import pki_role_san_coverage as m

def role(domains, **flags):
    r = dict(m.ROLE_BOOL_DEFAULTS)
    r.update(flags)
    r["allowed_domains"] = domains
    r["_raw"] = {}
    return r

BARE_SUB = role(["svc.cluster.local"], allow_bare_domains=True,
                allow_subdomains=True, allow_localhost=False)
EXACT = role(["hugmesh-user-bff-api", "hugmesh-user-bff-api.hugmesh-backend",
              "hugmesh-user-bff-api.hugmesh-backend.svc.cluster.local"],
             allow_bare_domains=True, allow_localhost=False)
GLOB = role(["*.hugmesh-backend"], allow_glob_domains=True, allow_localhost=False)
DEFAULTS = role(["example.com"])

cases = [
    # THE SHIPPED BUG: the two-label form is not a subdomain of svc.cluster.local
    (BARE_SUB, "hugmesh-user-bff-api.hugmesh-backend", False),
    (BARE_SUB, "hugmesh-user-bff-api.hugmesh-backend.svc.cluster.local", True),
    (BARE_SUB, "svc.cluster.local", True),          # bare, via allow_bare_domains
    # ... and the blanket's real cost: ANY service in the cluster
    (BARE_SUB, "vault.vault.svc.cluster.local", True),
    # exact-match role: precisely its own three names, nothing adjacent
    (EXACT, "hugmesh-user-bff-api.hugmesh-backend", True),
    (EXACT, "hugmesh-user-bff-api.hugmesh-backend.svc.cluster.local", True),
    (EXACT, "hugmesh-user-bff-api", True),
    (EXACT, "hugmesh-user-bff-api.hugmesh-frontend", False),
    (EXACT, "evil.hugmesh-user-bff-api.hugmesh-backend", False),   # sub off
    (EXACT, "vault.vault.svc.cluster.local", False),
    # go-glob: '*' spans dots, so it is NOT a one-label wildcard
    (GLOB, "a.hugmesh-backend", True),
    (GLOB, "a.b.hugmesh-backend", True),
    (GLOB, "a.hugmesh-frontend", False),
    # Vault's DEFAULTS, which a role that sets nothing inherits
    (DEFAULTS, "localhost", True),
    (DEFAULTS, "example.com", False),               # allow_bare_domains defaults OFF
]
bad = 0
for r, name, want in cases:
    got, why = m.name_allowed(name, r)
    if got != want:
        bad += 1
        print("  FAIL matcher: %r expected %s got %s (%s)" % (name, want, got, why))
if m.go_glob("*.example.com", "a.b.example.com") is not True:
    bad += 1; print("  FAIL go_glob: '*' must span dots")
if m.go_glob("ftp*.example.com", "ftpx.example.com") is not True:
    bad += 1; print("  FAIL go_glob: prefix glob")
if m.go_glob("ftp*.example.com", "xftp1.example.com") is not False:
    bad += 1; print("  FAIL go_glob: leading text must anchor")
if bad:
    print("  FAIL matcher self-test: %d case(s) wrong" % bad)
    sys.exit(1)
print("  PASS matcher self-test: %d ValidateNames case(s) + go-glob semantics" % len(cases))
PY
[ $? -eq 0 ] || { echo; echo "== pki role SAN coverage: FAIL (matcher self-test) =="; exit 1; }

echo
echo "-- positive: the repo's own specs/cluster must pass every check --"
python3 "${CHECKER}" "${REPO}/specs/cluster"
RC=$?
if [ "${RC}" -ne 0 ]; then
  echo
  echo "== pki role SAN coverage: FAIL (see above) =="
  exit 1
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
echo
echo "-- negative controls: each injected defect must be caught --"
NEG_P=0; NEG_F=0
neg_ok(){ echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad(){ echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# $1 = human label, $2 = expected check-id substring, $3 = optional extra
# substring the failure text MUST contain (pass "" to skip), $4 = shell snippet
# run with $T = the staged tree root, which injects the defect.
expect_catch() {
  local label="$1" want="$2" want_text="$3" inject="$4"
  local T="${WORK}/tree"
  rm -rf "${T}"; cp -r "${REPO}/specs/cluster" "${T}"
  ( T="${T}"; eval "${inject}" ) || { neg_bad "${label} (injection itself failed)"; return; }
  local out rc
  out="$(python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
  # -F: the check ids contain [] and -, which grep would read as a bracket range.
  if [ "${rc}" -ne 0 ] && grep -qF "  FAIL ${want}" <<<"${out}"; then
    if [ -n "${want_text}" ] && ! grep -qF "${want_text}" <<<"${out}"; then
      neg_bad "${label} caught by ${want} but the message never names ${want_text}"
      return
    fi
    neg_ok "${label} -> caught by ${want}"
  else
    neg_bad "${label} NOT caught (rc=${rc}); wanted ${want}. Output:"
    sed 's/^/        /' <<<"${out}" | tail -20
  fi
}

# (1) THE SHIPPED DEFECT, re-injected verbatim: the flat allowed_domains that was
#     on main. Every generic-loop app 400s, exactly as the live ESO log showed.
expect_catch "the shipped flat allowed_domains (no <service>.<namespace> form)" \
  "[pki-san-coverage]" "hugmesh-user-bff-api.hugmesh-backend" '
  python3 - "$T" <<"PY"
import sys
p=sys.argv[1]+"/manifests/vault-pki/pki-init-configmap.yaml"
s=open(p,encoding="utf-8").read()
old = chr(36)+"{svc},"+chr(36)+"{svc_ns},"+chr(36)+"{svc_ns}.svc.cluster.local"
assert s.count(old)==1, "loop allowed_domains anchor matched %d times, not 1" % s.count(old)
new = chr(36)+"{role},"+chr(36)+"{role}.svc.cluster.local,svc.cluster.local,"+chr(36)+"{DOMAIN}"
s = s.replace(old, new, 1)
flags = "allow_bare_domains=true allow_subdomains=false allow_glob_domains=false"
assert s.count(flags)==3, "role flag anchor matched %d times, not 3" % s.count(flags)
# 3 = the entry loop + the two identities that genuinely cannot fold into it
# (harbor: 3 names of 2 kinds; coturn: public turn.<domain> CN + in-cluster SANs).
# This count is a tripwire that the file still has the shape the injection
# assumes — bump it deliberately when a role is added, never to silence it.
s = s.replace(flags, "allow_bare_domains=true allow_subdomains=true allow_glob_domains=true", 1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (2) the WRONG REPAIR, form A: bolt the blanket back on to make coverage green.
#     Coverage still passes (every real SAN is issuable); containment must refuse
#     it, because every role can then mint every OTHER workload cluster identity
#     off the shared CA. This is the control that makes "just widen it" a dead end.
expect_catch "coverage kept green by re-adding the blanket svc.cluster.local" \
  "[pki-san-containment]" "" '
  python3 - "$T" <<"PY"
import sys
p=sys.argv[1]+"/manifests/vault-pki/pki-init-configmap.yaml"
s=open(p,encoding="utf-8").read()
old = chr(36)+"{svc},"+chr(36)+"{svc_ns},"+chr(36)+"{svc_ns}.svc.cluster.local"
assert s.count(old)==1, "loop allowed_domains anchor matched %d times, not 1" % s.count(old)
s = s.replace(old, old+",svc.cluster.local", 1)
flags = "allow_bare_domains=true allow_subdomains=false allow_glob_domains=false"
assert s.count(flags)==3, "role flag anchor matched %d times, not 3" % s.count(flags)
# 3 = the entry loop + the two identities that genuinely cannot fold into it
# (harbor: 3 names of 2 kinds; coturn: public turn.<domain> CN + in-cluster SANs).
# This count is a tripwire that the file still has the shape the injection
# assumes — bump it deliberately when a role is added, never to silence it.
s = s.replace(flags, "allow_bare_domains=true allow_subdomains=true allow_glob_domains=false", 1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (3) the WRONG REPAIR, form B: allow_any_name. The bluntest possible widening.
expect_catch "coverage 'fixed' with allow_any_name=true" \
  "[pki-role-posture]" "allow_any_name" '
  sed -i "s/allow_any_name=false/allow_any_name=true/" \
      "$T/manifests/vault-pki/pki-init-configmap.yaml"
'
# (4) a loop entry pointing at the WRONG namespace — the drift a service moving
#     tier would cause. Only the two-label + FQDN forms break, so nothing but a
#     real per-name simulation notices.
expect_catch "loop entry carries the wrong namespace for its service" \
  "[pki-san-coverage]" "hugmesh-user-bff-api.hugmesh-backend" '
  sed -i "s|hugmesh-user-bff-api:hugmesh-user-bff-api.hugmesh-backend|hugmesh-user-bff-api:hugmesh-user-bff-api.hugmesh-frontend|" \
      "$T/manifests/vault-pki/pki-init-configmap.yaml"
'
# (5) drift from the OTHER side: a generator gains a SAN nobody granted. This is
#     the direction that actually happens in review — the manifest is edited, the
#     role is not.
expect_catch "an ExternalSecret gains a SAN the role never allowed" \
  "[pki-san-coverage]" "hugmesh-user-bff-api.hugmesh-games" '
  sed -i "s|alt_names: hugmesh-user-bff-api,hugmesh-user-bff-api.hugmesh-backend|alt_names: hugmesh-user-bff-api,hugmesh-user-bff-api.hugmesh-backend,hugmesh-user-bff-api.hugmesh-games|" \
      "$T/manifests/external-secrets/pki-externalsecrets.yaml"
'
# (6) THE ROLE-NAME != SERVICE-NAME TRAP, which is what forced media-poisoner and
#     harbor out of the loop in the first place: derive the identity from the
#     ROLE name and every SAN the workload really asks for is rejected.
expect_catch "role identity derived from the role name, not the Service name" \
  "[pki-san-coverage]" "hugmesh-media-poisoner" '
  sed -i "s|media-poisoner:hugmesh-media-poisoner.hugmesh-backend|media-poisoner:media-poisoner.hugmesh-backend|" \
      "$T/manifests/vault-pki/pki-init-configmap.yaml"
'
# (7) harbor is the one role outside the loop; it must be checked identically.
expect_catch "harbor loses the public registry host from allowed_domains" \
  "[pki-san-coverage]" "registry.hugmesh.systems" '
  sed -i "s|,registry.\${DOMAIN}\"|\"|" \
      "$T/manifests/vault-pki/pki-init-configmap.yaml"
'
# (8) VACUITY, side A: no requests left to simulate. A gate that reports a clean
#     pass over zero inputs is the failure mode this repo has been bitten by
#     before (the reserved-prefix code-copy skip), so it must fail LOUDLY.
expect_catch "every VaultDynamicSecret removed (gate must not pass vacuously)" \
  "[pki-san-coverage]" "vacuous" '
  grep -rl "kind: VaultDynamicSecret" "$T" | xargs sed -i "s/kind: VaultDynamicSecret/kind: VaultDynamicSecretPARKED/"
'
# (9) VACUITY, side B: the role loop collapses to a single entry, so almost
#     nothing is simulated even though the file still parses and still runs.
expect_catch "role loop collapsed to one entry (gate must not pass vacuously)" \
  "[pki-role-posture]" "vacuous" '
  python3 - "$T" <<PY
import re,sys
p=sys.argv[1]+"/manifests/vault-pki/pki-init-configmap.yaml"
s=open(p,encoding="utf-8").read()
pat=re.compile(r"    for entry in .*?; do\n", re.S)
assert pat.search(s), "for-entry loop header anchor missing"
open(p,"w",encoding="utf-8").write(
    pat.sub("    for entry in hugmesh-api:hugmesh-api.hugmesh-backend; do\n", s, count=1))
PY
'

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
[ "${NEG_F}" -eq 0 ] || exit 1
echo "== pki role SAN coverage: PASS =="
exit 0
