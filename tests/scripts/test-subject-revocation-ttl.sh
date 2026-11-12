#!/usr/bin/env bash
# test-subject-revocation-ttl.sh — the admin-bff gateway-revocation posture, pinned to the
# Casdoor seed it depends on.
#
# WHAT THIS GUARDS
# Revoking a role, disabling an account or revoking a desktop-sudo claim makes admin-bff
# write a `subject:<user>` key to the gateway revocation list. The gateway refuses every
# token for that subject while the key lives (set membership, no iat comparison). Casdoor
# tokens are NOT shortened by any of those actions: a raw JWT stays valid until its own
# `exp`. So the key has to outlive the LONGEST token Casdoor issues, or the revoked token
# works again the moment the key lapses.
#
# THE DEFECT THIS EXISTS TO KEEP FIXED
# admin-bff passed a 1 h literal at every revoke site, described as "the custody JWT
# lifetime". manifests/casdoor/init-job.yaml seeds expireInHours: 168 for every app-*
# client and for hugmesh-desktop, so a revoked token was refused for one hour and then
# accepted again for up to ~7 days. The TTL is now admin-bff configuration
# (broker.gateway-revocation.subject-cutoff-ttl-seconds), and this file pins the cluster
# value against the seed:
#
#   RULE 1  every `expireInHours` under specs/cluster/manifests/casdoor*/ is an integer
#           literal this parser reads (fail closed on any other spelling, and on none).
#           ALL three Casdoor seeds count — casdoor (the platform IdP), casdoor-domain
#           (per-brand IdPs) and casdoor-games. That is CONSERVATIVE: the platform and
#           per-brand issuers are what the gateway's DomainRegistry validates; whether
#           a casdoor-games token ever reaches a subject-key check was not traced, so it
#           is counted rather than assumed away. refreshExpireInHours is NOT counted: a
#           refresh mints a NEW token from Casdoor's CURRENT state, and the key refuses
#           that new token anyway while it lives. That reasoning holds only when admin-bff
#           actually changed Casdoor (role removed, user disabled). In the cluster today
#           the Casdoor admin client ships dark (CASDOOR_ADMIN_ENABLED is not set), so the
#           role endpoints answer 503 and an uninvite removes the allowlist row without
#           disabling the Casdoor user — there, once any key lapses, a fresh login or
#           refresh works again whatever this TTL is. That residual is the Casdoor admin
#           client's flip, not this guard's.
#   RULE 2  the admin-bff Deployment sets BROKER_GATEWAY_REVOCATION_SUBJECT_CUTOFF_TTL_SECONDS
#           to an integer >= max(expireInHours) x 3600, and nothing else under specs/
#           sets it (an overlay that lowered it would be invisible to rule 2 otherwise).
#   RULE 3  BROKER_GATEWAY_REVOCATION_ENABLED is unset or one of Spring's false spellings
#           (false/off/no/0). The client sends no Authorization header and the gateway
#           answers an anonymous write with 401, which the client swallows — on would claim
#           a cut-off that never lands. When the service credential exists
#           (hugmesh-admin-bff-api#45, hugmesh-generator#347 decision 45) flip it in the SAME
#           change that wires the credential, and change this rule there. Also wait for
#           every gateway to keep the later expiry of a key (hugmesh-gateway#69): with a
#           last-write-wins key a role grant or a suspension tick right after a cut-off
#           shortens it to 1 h.
#   RULE 4  BROKER_HS_TOKEN_REGISTRY_ENABLED is "true", and the session it writes through
#           targets hugmesh_gateway (the keyspace where gateway migration 006 creates
#           hs_tokens) with Cassandra auth on.
#
# WHAT IT DOES NOT PROVE
# That a running admin-bff image binds the env (an image older than the admin-bff change
# ignores BROKER_GATEWAY_REVOCATION_SUBJECT_CUTOFF_TTL_SECONDS and keeps 1 h), or that a
# write reaches a live gateway. Both are live checks.
#
# Offline: bash + python3 + PyYAML. No cluster, no network, no docker. Negative controls
# stage copies of the inputs under mktemp and never touch the checkout.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

# check <root> — prints PASS/FAIL lines, exits non-zero on any FAIL.
check() {
  python3 - "$1" <<'PY'
import glob, os, re, sys
import yaml

root = sys.argv[1]
fails = 0
def ok(m):  print("  PASS " + m)
def bad(m):
    global fails
    fails += 1
    print("  FAIL " + m)

# ── RULE 1: the seeded token lifetimes ───────────────────────────────────────
TOKEN   = re.compile(r'(?<![A-Za-z])expireInHours')
# The integer must END the value (a separator, a comment or the end of the line follows),
# so `= 24 * 30` is not read as 24: anything that is not a bare literal is unreadable,
# and unreadable fails closed below.
LITERAL = re.compile(r'''(?<![A-Za-z])expireInHours["']?\]?\s*[:=]\s*(\d+)(?=\s*(?:[,;})\]#]|$))''')
seeds = sorted(glob.glob(os.path.join(root, "specs/cluster/manifests/casdoor*/**/*.yaml"), recursive=True))
values, unread = [], []
for path in seeds:
    rel = os.path.relpath(path, root)
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("#") or not TOKEN.search(line):
            continue
        mentions = len(TOKEN.findall(line))
        lits = [int(v) for v in LITERAL.findall(line)]
        if len(lits) != mentions:
            unread.append("%s:%d: %s" % (rel, n, line.strip()[:120]))
        values += [(v, "%s:%d" % (rel, n)) for v in lits]
if unread:
    bad("rule1: expireInHours spelled in a way this guard cannot read as an integer literal "
        "(fail closed — a lifetime it cannot read is a lifetime it cannot bound):")
    for u in unread:
        print("         " + u)
if not values:
    bad("rule1: no expireInHours literal under specs/cluster/manifests/casdoor*/ — "
        "the seed shape changed; refusing to bound the TTL against nothing")
    print("  %d failure(s)" % fails)
    sys.exit(1)
longest, where = max(values)
dirs = sorted({v[1].split("/")[3] for v in values})
ok("rule1: %d expireInHours literal(s) across %s; longest %dh at %s"
   % (len(values), ", ".join(dirs), longest, where))

# ── RULE 2..4: the admin-bff Deployment env ──────────────────────────────────
dep_rel = "specs/cluster/manifests/admin-bff-api/deployment.yaml"
dep = os.path.join(root, dep_rel)
env = None
for d in yaml.safe_load_all(open(dep, encoding="utf-8")):
    if d and d.get("kind") == "Deployment":
        for c in d["spec"]["template"]["spec"]["containers"]:
            if c.get("name") == "hugmesh-admin-bff-api":
                env = {}
                for e in c.get("env", []) or []:
                    if e.get("name") in env:
                        bad("rule2: env %s is set twice in the admin-bff container (last wins, "
                            "the first reads like the value)" % e["name"])
                    env[e.get("name")] = e
if env is None:
    bad("rule2: no hugmesh-admin-bff-api container in %s" % dep_rel)
    print("  %d failure(s)" % fails)
    sys.exit(1)

def literal(name):
    e = env.get(name)
    if e is None:
        return None
    if "valueFrom" in e or "value" not in e:
        return "<not a literal value>"
    return str(e["value"])

CUTOFF = "BROKER_GATEWAY_REVOCATION_SUBJECT_CUTOFF_TTL_SECONDS"
need = longest * 3600
v = literal(CUTOFF)
if v is None:
    bad("rule2: %s is not set on admin-bff — the TTL would fall back to whatever the image "
        "ships (1 h before the admin-bff fix) instead of being pinned against the seed" % CUTOFF)
elif not re.fullmatch(r"\d+", v):
    bad("rule2: %s=%r is not a plain integer number of seconds" % (CUTOFF, v))
elif int(v) < need:
    bad("rule2: %s=%s is SHORTER than the longest seeded Casdoor token (%dh = %ds at %s): a revoked "
        "token works again for up to %ds after the key lapses"
        % (CUTOFF, v, longest, need, where, need - int(v)))
else:
    ok("rule2: %s=%s >= %dh x 3600 = %d" % (CUTOFF, v, longest, need))

others = []
for path in glob.glob(os.path.join(root, "specs/**/*"), recursive=True):
    if os.path.isfile(path) and os.path.abspath(path) != os.path.abspath(dep):
        try:
            if CUTOFF in open(path, encoding="utf-8", errors="replace").read():
                others.append(os.path.relpath(path, root))
        except OSError:
            pass
if others:
    bad("rule2: %s is also set outside %s (an overlay could lower it unseen): %s"
        % (CUTOFF, dep_rel, ", ".join(sorted(others))))
else:
    ok("rule2: %s is set only in %s" % (CUTOFF, dep_rel))

FLAG = "BROKER_GATEWAY_REVOCATION_ENABLED"
f = literal(FLAG)
# Spring binds true/on/yes/1 (any case) to true and false/off/no/0 to false. Only an unset
# value or one of the false spellings passes; anything else is on, or does not bind.
if f is not None and f.strip().lower() not in ("false", "off", "no", "0"):
    bad("rule3: %s is on, but auth-core's GatewayRevocationClient sends no Authorization header and "
        "the gateway answers an anonymous POST /api/gateway/revocations with 401, which the client "
        "swallows — this claims a cut-off that never lands. Flip it in the change that wires the "
        "service credential (hugmesh-admin-bff-api#45, hugmesh-generator#347 decision 45), once "
        "every gateway keeps the later expiry of a key (hugmesh-gateway#69), and update this rule "
        "there." % (FLAG + "=" + repr(f)))
else:
    ok("rule3: %s is %s (no credential exists yet, so on would be an inert toggle)"
       % (FLAG, "unset" if f is None else repr(f)))

REG = "BROKER_HS_TOKEN_REGISTRY_ENABLED"
r = literal(REG)
if r is None or r.strip().lower() != "true":
    bad("rule4: %s is %s — brokered homeserver tokens would never be registered, and the gateway's "
        "hs-revocation filter fails CLOSED on a bearer it has no row for"
        % (REG, "unset" if r is None else repr(r)))
else:
    ok("rule4: %s=true" % REG)
ks, auth = literal("ROUTE_MIRROR_KEYSPACE"), literal("CASSANDRA_AUTH_ENABLED")
if ks != "hugmesh_gateway":
    bad("rule4: ROUTE_MIRROR_KEYSPACE=%r — the registry writes through that session, but gateway "
        "migration 006 creates hs_tokens in hugmesh_gateway" % ks)
else:
    ok("rule4: the registry session targets hugmesh_gateway (gateway migration 006's keyspace)")
if (auth or "").lower() != "true":
    bad("rule4: CASSANDRA_AUTH_ENABLED=%r — the cluster Cassandra runs PasswordAuthenticator, so an "
        "unauthenticated registry write fails on every mint" % auth)
else:
    ok("rule4: CASSANDRA_AUTH_ENABLED=true (writes as the DML-only admin_bff_cass role)")

print("  %d failure(s)" % fails)
sys.exit(1 if fails else 0)
PY
}

echo "== subject revocation TTL vs the Casdoor seed =="
echo "-- positive: the repo's own specs/cluster --"
if check "${REPO}"; then
  ok "positive: the checked-in tree satisfies rules 1-4"
else
  bad "positive: the checked-in tree violates the contract (see above)"
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Each stages a copy of the inputs, plants ONE defect, confirms the file really changed,
# and requires the checker to go red.
echo
echo "-- negative controls: each planted defect must be caught --"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
DEP_REL="specs/cluster/manifests/admin-bff-api/deployment.yaml"
INIT_REL="specs/cluster/manifests/casdoor/init-job.yaml"
DOMAIN_REL="specs/cluster/manifests/casdoor-domain/init-job.yaml"

stage() {
  local d="${WORK}/$1"
  rm -rf "${d}"; mkdir -p "${d}/specs/cluster/manifests"
  cp -R "${REPO}"/specs/cluster/manifests/casdoor* "${d}/specs/cluster/manifests/"
  mkdir -p "${d}/specs/cluster/manifests/admin-bff-api"
  cp "${REPO}/${DEP_REL}" "${d}/${DEP_REL}"
  echo "${d}"
}

# neg <label> <stage-dir> <file-rel> <old> <new> [all]
# Replaces the FIRST occurrence of <old> (every one with `all`) — a literal string
# replacement, no evaluation — then requires the checker to go red.
neg() {
  local label="$1" d="$2" rel="$3" old="$4" new="$5" mode="${6:-first}"
  local before after
  before="$(cksum < "${d}/${rel}")"
  python3 - "${d}/${rel}" "${old}" "${new}" "${mode}" <<'PY'
import sys
p, old, new, mode = sys.argv[1:5]
s = open(p, encoding="utf-8").read()
s = s.replace(old, new) if mode == "all" else s.replace(old, new, 1)
open(p, "w", encoding="utf-8").write(s)
PY
  after="$(cksum < "${d}/${rel}")"
  if [ "${before}" = "${after}" ]; then
    bad "negative control ${label}: the mutation did not change ${rel} (anchor drifted) — control proves nothing"
    return
  fi
  verdict "${label}" "${d}"
}

# verdict <label> <stage-dir> — the checker must go red; echo the FIRST failure it gave so
# the log shows each control was caught by the rule it targets, not by a crash.
verdict() {
  local out
  if out="$(check "$2" 2>&1)"; then
    bad "negative control $1: checker stayed GREEN"
  else
    ok "negative control $1: caught — $(printf '%s\n' "${out}" | sed -n 's/^  FAIL //p' | head -1 | cut -c1-110)"
  fi
}

CUT='BROKER_GATEWAY_REVOCATION_SUBJECT_CUTOFF_TTL_SECONDS'
D="$(stage n1)"; neg "N1 a platform app's expireInHours raised to 336" "${D}" "${INIT_REL}" \
  $'"expireInHours": 168, "enablePassword": True, "enableSignUp": False,\n            # D6+D8' \
  $'"expireInHours": 336, "enablePassword": True, "enableSignUp": False,\n            # D6+D8'
D="$(stage n2)"; neg "N2 a per-brand Casdoor seed raised to 200h (other seeds count)" "${D}" "${DOMAIN_REL}" \
  '"expireInHours": 168' '"expireInHours": 200'
D="$(stage n3)"; neg "N3 the cut-off TTL lowered back to 3600" "${D}" "${DEP_REL}" \
  "${CUT}, value: \"604800\"" "${CUT}, value: \"3600\""
D="$(stage n4)"; neg "N4 the cut-off TTL env removed" "${D}" "${DEP_REL}" \
  "            - { name: ${CUT}, value: \"604800\" }"$'\n' ''
D="$(stage n5)"; neg "N5 expireInHours spelled as a non-literal" "${D}" "${INIT_REL}" \
  'app["expireInHours"] = 4' 'app["expireInHours"] = USER_BFF_HOURS'
# N6 must strip EVERY seed: rename in the platform seed through neg (proves the anchor),
# then in the other two, so no literal anywhere remains to satisfy rule 1.
D="$(stage n6)"
for f in "${D}"/specs/cluster/manifests/casdoor-*/*.yaml; do
  [ -f "${f}" ] && sed -i 's/expireInHours/lifetimeHours/g' "${f}"
done
neg "N6 no expireInHours in any Casdoor seed" "${D}" "${INIT_REL}" 'expireInHours' 'lifetimeHours' all
D="$(stage n7)"; neg "N7 the revocation flag turned on with no credential" "${D}" "${DEP_REL}" \
  'BROKER_GATEWAY_REVOCATION_ENABLED, value: "false"' 'BROKER_GATEWAY_REVOCATION_ENABLED, value: "true"'
D="$(stage n8)"; neg "N8 the hs_tokens registry turned back off" "${D}" "${DEP_REL}" \
  'BROKER_HS_TOKEN_REGISTRY_ENABLED, value: "true"' 'BROKER_HS_TOKEN_REGISTRY_ENABLED, value: "false"'
D="$(stage n9)"; neg "N9 the registry session pointed at another keyspace" "${D}" "${DEP_REL}" \
  'value: "hugmesh_gateway"' 'value: "hugmesh_other"'
D="$(stage n10)"; neg "N10 the cut-off TTL set twice (a lower duplicate after it)" "${D}" "${DEP_REL}" \
  "${CUT}, value: \"604800\" }"$'\n' \
  "${CUT}, value: \"604800\" }"$'\n'"            - { name: ${CUT}, value: \"3600\" }"$'\n'
D="$(stage n12)"; neg "N12 expireInHours written as arithmetic (24 * 30 is not 24)" "${D}" "${INIT_REL}" \
  'app["expireInHours"] = 4' 'app["expireInHours"] = 24 * 30'
for spelling in on yes 1 TRUE; do
  D="$(stage "n13-${spelling}")"; neg "N13 the revocation flag turned on as \"${spelling}\"" "${D}" "${DEP_REL}" \
    'BROKER_GATEWAY_REVOCATION_ENABLED, value: "false"' "BROKER_GATEWAY_REVOCATION_ENABLED, value: \"${spelling}\""
done
D="$(stage n11)"
mkdir -p "${D}/specs/cluster/overlays/x"
printf 'env:\n  - { name: %s, value: "60" }\n' "${CUT}" > "${D}/specs/cluster/overlays/x/patch.yaml"
verdict "N11 an overlay also sets the TTL" "${D}"

echo
echo "  ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
