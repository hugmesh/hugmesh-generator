#!/usr/bin/env bash
# test-optional-netpol-autosync.sh — an optional service's NetworkPolicy must not ship
# through an Application that reads a git path the build's prune cannot reach
# (hugmesh-generator#617).
#
# THE DEFECT IT PINS. `tor-onion-marked` lived in manifests/networkpolicy. The build's
# tor prune (scripts/_optional-services-lib.sh) removed it from the BAKED copy of that
# directory — but apps/08-networkpolicy.yaml, which survives every build, serves the
# path FROM GIT MAIN with prune + selfHeal. So every tracking cluster got the policy
# whatever the image selected; the prune edited a tree ArgoCD never reads (the #496
# shape). The fix moved it behind its own Application (apps/08b-networkpolicy-tor.yaml),
# and a device applies its BAKED apps/*.yaml (bootstrap.sh), so removing THAT file is a
# prune the cluster sees.
#
# HOW (behaviour, not source text): run the REAL gate_optional_services with NOTHING
# selected over a copy of specs/cluster (the baked tree a minimal build gets). For every
# Application that SURVIVES the gate and serves a git path under
# specs/cluster/manifests, render that path twice with `kubectl kustomize` — as git
# serves it (what ArgoCD applies) and as the bake left it (what the build intended). A
# NetworkPolicy present in the git render and absent from the baked one is a prune the
# cluster never sees: FAIL. It identifies policies by namespace/name, so stripping the
# `hugmesh.net/optional-service` label cannot hide one. Known exemptions are listed with
# their reason, printed, and must still be real (a stale exemption FAILS).
# Self-test: the same check, run over scratch copies with tor-onion-marked moved back
# into the auto-synced directory (with and without its label), must FAIL.
#
# Other kinds the same method finds (e.g. Deployment patches, Jobs, ConfigMaps a prune
# removes from a git-served directory) are printed as INFO — they are #496's scope, not
# this guard's.
#
#   bash tests/scripts/test-optional-netpol-autosync.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_optional-services-lib.sh"
for b in kubectl python3 diff; do
    command -v "${b}" >/dev/null 2>&1 || { echo "FAIL ${b} is required (an absent tool is a FAIL here, never a skip)"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL python3 yaml (PyYAML) is required"; exit 1; }
[ -f "${LIB}" ] || { echo "FAIL missing ${LIB}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/optional-netpol.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# Known exemptions: "<app file> <namespace>/<name>|<reason>". Each must still be a real
# violation, or this suite fails (a false exemption hides rot).
EXEMPT=(
  "08-networkpolicy.yaml hugmesh-backend/egress-vpn-allow-marked|egress-vpn-interaction.yaml, the egress-vpn sibling of #617 (same shape: bake-pruned from the baked copy, served from git by the auto-sync 08-networkpolicy) — not moved by #617, tracked on #496"
)

# bake CLUSTER_SRC SYSROOT — the baked tree a build with NOTHING selected gets, produced
# by the REAL gate.
bake() {
    rm -rf "$2"; mkdir -p "$2/var/lib/hugmesh"
    cp -r "$1" "$2/var/lib/hugmesh/cluster"
    ( set +u
      # shellcheck source=/dev/null
      source "${LIB}"
      info() { :; }; warn() { :; }
      SYSROOT="$2"; OPTIONAL_SERVICES=""
      gate_optional_services ) > "${WORK}/gate.log" 2>&1
}

# check CLUSTER_SRC SYSROOT -> one line per finding: "VIOLATION|INFO|EXEMPT <app> <kind> <ns>/<name> <sync>"
check() {
    python3 - "$1" "$2/var/lib/hugmesh/cluster" "${EXEMPT[@]}" <<'PY'
import glob, os, subprocess, sys, yaml
git_root, baked_root = sys.argv[1], sys.argv[2]
exempt = {e.split("|", 1)[0] for e in sys.argv[3:]}
PREFIX = "specs/cluster/"
def render(d):
    if not os.path.isfile(os.path.join(d, "kustomization.yaml")):
        return {}
    r = subprocess.run(["kubectl", "kustomize", d], capture_output=True, text=True)
    if r.returncode != 0:
        print("ERROR render %s: %s" % (d, r.stderr.strip()[:300]))
        return None
    out = {}
    for doc in yaml.safe_load_all(r.stdout):
        if not doc:
            continue
        md = doc.get("metadata") or {}
        out[(doc.get("kind"), md.get("namespace") or "-", md.get("name"))] = doc
    return out
same = lambda a, b: subprocess.run(["diff", "-rq", a, b], capture_output=True).returncode == 0
seen = 0
for app in sorted(glob.glob(os.path.join(baked_root, "apps", "*.yaml"))):
    for doc in yaml.safe_load_all(open(app)):
        if not doc or doc.get("kind") != "Application":
            continue
        src = (doc.get("spec") or {}).get("source") or {}
        path = src.get("path") or ""
        if "hugmesh-generator" not in (src.get("repoURL") or "") or not path.startswith(PREFIX + "manifests/"):
            continue
        seen += 1
        rel = path[len(PREFIX):]
        git_dir, baked_dir = os.path.join(git_root, rel), os.path.join(baked_root, rel)
        if os.path.isdir(baked_dir) and same(git_dir, baked_dir):
            continue            # the bake left this directory alone: nothing to lose
        g = render(git_dir)
        b = render(baked_dir) if os.path.isdir(baked_dir) else {}
        if g is None or b is None:
            continue
        sync = "auto" if ((doc.get("spec") or {}).get("syncPolicy") or {}).get("automated") is not None else "manual"
        for key in sorted(set(g) - set(b), key=str):
            kind, ns, name = key
            tag = os.path.basename(app)
            if kind == "NetworkPolicy":
                verdict = "EXEMPT" if ("%s %s/%s" % (tag, ns, name)) in exempt else "VIOLATION"
            else:
                verdict = "INFO"
            print("%s %s %s %s/%s %s" % (verdict, tag, kind, ns, name, sync))
print("SEEN %d" % seen)
PY
}

echo "== the real tree: every NetworkPolicy a prune removes must stay off the cluster =="
bake "${REPO}/specs/cluster" "${WORK}/sys-real"
OUT="$(check "${REPO}/specs/cluster" "${WORK}/sys-real")"
seen="$(printf '%s\n' "${OUT}" | sed -n 's/^SEEN //p')"
[ "${seen:-0}" -ge 20 ] && ok "the check walked ${seen} surviving git-served Applications (not vacuous)" || bad "only ${seen:-0} git-served Applications survived the gate — the walk is vacuous"
printf '%s\n' "${OUT}" | grep -a '^ERROR' >/dev/null && bad "a kustomize render failed: $(printf '%s\n' "${OUT}" | grep -a '^ERROR' | head -3)"
viol="$(printf '%s\n' "${OUT}" | grep -a '^VIOLATION' || true)"
[ -z "${viol}" ] && ok "no optional-service NetworkPolicy is served from git by an Application the build keeps" \
    || { bad "NetworkPolicies the build prunes but git still serves to every cluster:"; printf '%s\n' "${viol}" | sed 's/^/      | /'; }
printf '%s\n' "${OUT}" | grep -a 'NetworkPolicy hugmesh-backend/tor-onion-marked' >/dev/null \
    && bad "tor-onion-marked is served from git by a surviving Application (#617 regressed)" \
    || ok "tor-onion-marked reaches no cluster built without tor (#617)"
for e in "${EXEMPT[@]}"; do
    id="${e%%|*}"
    if printf '%s\n' "${OUT}" | grep -aF "EXEMPT ${id%% *} NetworkPolicy ${id#* } " >/dev/null; then
        echo "  KNOWN ${id} — ${e#*|}"
    else
        bad "stale exemption '${id}': it is no longer served from git after the prune — delete it from EXEMPT"
    fi
done
printf '%s\n' "${OUT}" | grep -a '^INFO' | sed 's/^/  /' | head -40

# The 08b Application exists only on a build that selected tor, and is manual-sync.
[ ! -e "${WORK}/sys-real/var/lib/hugmesh/cluster/apps/08b-networkpolicy-tor.yaml" ] && [ ! -e "${WORK}/sys-real/var/lib/hugmesh/cluster/manifests/networkpolicy-tor" ] \
    && ok "a build without tor bakes no 08b-networkpolicy-tor Application and no networkpolicy-tor overlay" || bad "the tor netpol Application/overlay survived a build without tor"
rm -rf "${WORK}/sys-tor"; mkdir -p "${WORK}/sys-tor/var/lib/hugmesh"; cp -r "${REPO}/specs/cluster" "${WORK}/sys-tor/var/lib/hugmesh/cluster"
( set +u; source "${LIB}"; info() { :; }; warn() { :; }; SYSROOT="${WORK}/sys-tor"; OPTIONAL_SERVICES="tor"; gate_optional_services ) >/dev/null 2>&1
if [ -f "${WORK}/sys-tor/var/lib/hugmesh/cluster/apps/08b-networkpolicy-tor.yaml" ] \
   && kubectl kustomize "${WORK}/sys-tor/var/lib/hugmesh/cluster/manifests/networkpolicy-tor" 2>/dev/null | grep -a '^  name: tor-onion-marked$' >/dev/null; then
    ok "a build WITH tor keeps the 08b Application, and its overlay renders tor-onion-marked"
else
    bad "a tor build lost the 08b Application or its overlay does not render tor-onion-marked"
fi
python3 - "${REPO}/specs/cluster/apps/08b-networkpolicy-tor.yaml" <<'PY' && ok "08b-networkpolicy-tor is MANUAL-sync (egress-axis policy ships dark)" || bad "08b-networkpolicy-tor has an automated sync block (or is unreadable)"
import sys, yaml
d = [x for x in yaml.safe_load_all(open(sys.argv[1])) if x and x.get("kind") == "Application"][0]
sys.exit(0 if ((d.get("spec") or {}).get("syncPolicy") or {}).get("automated") is None else 1)
PY
kubectl kustomize "${REPO}/specs/cluster/manifests/networkpolicy" 2>/dev/null | grep -a 'tor-onion' >/dev/null \
    && bad "the auto-synced manifests/networkpolicy still renders a tor-onion policy" || ok "the auto-synced manifests/networkpolicy renders no tor-onion policy"

echo "== self-test: the check FAILS when the policy is put back where #617 found it =="
selftest() {  # NAME STRIP_LABEL
    local c="${WORK}/repo-$1/specs/cluster"
    rm -rf "${WORK}/repo-$1"; mkdir -p "${WORK}/repo-$1/specs"; cp -r "${REPO}/specs/cluster" "${c}"
    mv "${c}/manifests/networkpolicy-tor/tor-onion-marked.yaml" "${c}/manifests/networkpolicy/tor-onion-marked.yaml"
    printf '  - tor-onion-marked.yaml\n' >> "${c}/manifests/networkpolicy/kustomization.yaml"
    [ "$2" = strip ] && sed -i '/hugmesh.net\/optional-service: tor/d' "${c}/manifests/networkpolicy/tor-onion-marked.yaml"
    # the OLD gate shape: prune the file + its kustomization line from the baked copy
    python3 - "${LIB}" "${WORK}/lib-$1.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = '                rm -f "${apps}/08b-networkpolicy-tor.yaml"\n'
new = old + '                rm -f "${tree}/manifests/networkpolicy/tor-onion-marked.yaml"\n                _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" tor-onion-marked.yaml\n'
if s.count(old) != 1:
    sys.exit("selftest anchor not found in _optional-services-lib.sh")
open(sys.argv[2], "w").write(s.replace(old, new))
PY
    rm -rf "${WORK}/sys-$1"; mkdir -p "${WORK}/sys-$1/var/lib/hugmesh"; cp -r "${c}" "${WORK}/sys-$1/var/lib/hugmesh/cluster"
    ( set +u; source "${WORK}/lib-$1.sh"; info() { :; }; warn() { :; }; SYSROOT="${WORK}/sys-$1"; OPTIONAL_SERVICES=""; gate_optional_services ) >/dev/null 2>&1
    [ ! -e "${WORK}/sys-$1/var/lib/hugmesh/cluster/manifests/networkpolicy/tor-onion-marked.yaml" ] || { bad "self-test $1: the old-shape prune did not run (fixture broken)"; return; }
    check "${c}" "${WORK}/sys-$1"
}
o="$(selftest labelled keep)"
printf '%s\n' "${o}" | grep -a '^VIOLATION 08-networkpolicy.yaml NetworkPolicy hugmesh-backend/tor-onion-marked auto$' >/dev/null \
    && ok "self-test: policy back in the auto-synced directory -> VIOLATION names it" || { bad "self-test: not caught"; printf '%s\n' "${o}" | sed 's/^/      | /'; }
o="$(selftest unlabelled strip)"
printf '%s\n' "${o}" | grep -a '^VIOLATION 08-networkpolicy.yaml NetworkPolicy hugmesh-backend/tor-onion-marked auto$' >/dev/null \
    && ok "self-test: the same with its optional-service label stripped -> still caught (identity, not label)" || { bad "self-test (no label): not caught"; printf '%s\n' "${o}" | sed 's/^/      | /'; }

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
