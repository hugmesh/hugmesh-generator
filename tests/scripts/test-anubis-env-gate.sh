#!/usr/bin/env bash
# test-anubis-env-gate.sh — unit test for the Anubis PUBLIC PoW-shield ENV policy
# in build-rpi5-stage4.sh (PR #107).
#
# REQUIREMENT (maintainer): the Anubis PoW shield is ALL-UP + ENABLED BY DEFAULT in
# PROD (ENV=prod) and DISABLED BY DEFAULT in TEST (ENV=test); an explicit operator
# selection/deselection ALWAYS wins. "All shields up" means the public fe-gateway
# Ingress is rerouted THROUGH the Anubis PoW gate (:8923) when installed.
#
# Proves this WITHOUT a full cross-build by sourcing the REAL helper functions
# (_opt_selected, _opt_explicitly_deselected, _opt_anubis_installed,
# _opt_render_installed_services, _opt_wire_anubis_ingress) extracted from the
# builder and exercising them against a sandbox baked tree:
#   * ENV=prod default        => installed-services ConfigMap anubis: "true"
#                                + fe-gateway public Ingress routed THROUGH anubis;
#   * ENV=test default        => anubis: "false" + DIRECT path (no reroute);
#   * explicit "anubis"/"-anubis"/"no-anubis" override either ENV;
#   * the reroute is IDEMPOTENT (re-run adds no duplicates) and REVERSIBLE.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
info(){ :; }   # silence the builder's logger inside the extracted functions

echo "== anubis ENV-policy gate unit test =="

# ── Load the REAL helper functions AS THE BUILDER RESOLVES THEM ───────────────
# These moved out of the builder into the SHARED scripts/_optional-services-lib.sh
# on 2026-08-26 — build-x86-host-stage4.sh had NO anubis handling at ALL (no
# _opt_explicitly_deselected, no _opt_anubis_installed, no _opt_wire_anubis_ingress),
# so every x86 --env prod image shipped the PUBLIC PoW shield off and the fe-gateway
# ingress un-rerouted while this suite was green against rpi5. opt_gate_load walks the
# builder's own source chain (libs first, builder last, last definition winning), so a
# re-added builder-local override is still what this suite would execute.
info(){ :; }; warn(){ :; }
source "${REPO}/tests/lib/opt-gate-source.sh"
opt_gate_load "${BUILDER}" _opt_selected _opt_explicitly_deselected _opt_anubis_installed \
              _opt_render_installed_services _opt_wire_anubis_ingress _opt_render_appset_flag || exit 1
ok "loaded the real builder functions (decision + render + ingress reroute)"

# ── Seed a sandbox baked tree (ConfigMap + fe-gateway app) ────────────────────
seed_tree() {
    SYSROOT="${WORK}/sysroot-$1"; rm -rf "${SYSROOT}"
    local pol="${SYSROOT}/var/lib/hugmesh/cluster/manifests/policy"
    local apps="${SYSROOT}/var/lib/hugmesh/cluster/apps"
    mkdir -p "${pol}" "${apps}"
    cp "${REPO}/specs/cluster/manifests/policy/installed-services-configmap.yaml" \
       "${pol}/installed-services-configmap.yaml"
    cp "${REPO}/specs/cluster/apps/20-gateway-fe.yaml" "${apps}/20-gateway-fe.yaml"
}
cm()  { echo "${SYSROOT}/var/lib/hugmesh/cluster/manifests/policy/installed-services-configmap.yaml"; }
fe()  { echo "${SYSROOT}/var/lib/hugmesh/cluster/apps/20-gateway-fe.yaml"; }
anubis_flag() { grep -E '^[[:space:]]*anubis:[[:space:]]*"(true|false)"' "$(cm)" | head -1 | grep -oE '(true|false)'; }
routed_through_anubis() { grep -qE '^[[:space:]]*backendServiceName:[[:space:]]*anubis' "$(fe)"; }

run_render() {  # $1=ENV  $2=OPTIONAL_SERVICES ; renders into the current SYSROOT
    ENV="$1"; OPTIONAL_SERVICES="$2"
    _opt_render_installed_services
}

# ── 1) ENV=prod default => ON + ingress routed through Anubis ─────────────────
seed_tree prod-default
run_render prod "akkoma tuwunel phpbb games"
[ "$(anubis_flag)" = "true" ] && ok "ENV=prod default: ConfigMap anubis: \"true\" (shields up)" \
                              || bad "ENV=prod default: anubis flag not true (got $(anubis_flag))"
routed_through_anubis && ok "ENV=prod default: public fe-gateway Ingress ROUTED THROUGH anubis (:8923)" \
                       || bad "ENV=prod default: ingress NOT rerouted through anubis"
grep -qE '^[[:space:]]*backendServicePort:[[:space:]]*8923' "$(fe)" \
    && ok "ENV=prod default: reroute targets the PoW gate port :8923" || bad "reroute missing :8923 port"
python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$(fe)'))); list(yaml.safe_load_all(open('$(cm)')))" \
    && ok "ENV=prod: rewritten ConfigMap + fe-gateway app still parse as YAML" || bad "rewrite produced invalid YAML"

# ── 2) ENV=test default => OFF + DIRECT path (no reroute) ─────────────────────
seed_tree test-default
run_render test "akkoma tuwunel phpbb games"
[ "$(anubis_flag)" = "false" ] && ok "ENV=test default: ConfigMap anubis: \"false\" (shield off)" \
                               || bad "ENV=test default: anubis flag not false (got $(anubis_flag))"
routed_through_anubis && bad "ENV=test default: ingress wrongly rerouted through anubis" \
                       || ok "ENV=test default: public ingress DIRECT to fe-gateway (no reroute)"
# the unrelated base slugs still resolve from presence
grep -qE '^[[:space:]]*games:[[:space:]]*"true"' "$(cm)" && ok "ENV=test: unrelated slug (games) rendered from presence" \
                                                          || bad "base slug render regressed"

# ── 3) explicit selection/deselection ALWAYS wins ────────────────────────────
seed_tree prod-deselect
run_render prod "akkoma -anubis"
[ "$(anubis_flag)" = "false" ] && ok "ENV=prod + '-anubis': explicit deselect wins (OFF)" \
                               || bad "explicit '-anubis' did not turn anubis off in prod"
routed_through_anubis && bad "prod -anubis: ingress wrongly rerouted" || ok "prod -anubis: no reroute (direct path)"

seed_tree prod-deselect-noform
run_render prod "akkoma no-anubis"
[ "$(anubis_flag)" = "false" ] && ok "ENV=prod + 'no-anubis': alt deselect token wins (OFF)" \
                               || bad "'no-anubis' did not turn anubis off in prod"

seed_tree test-select
run_render test "akkoma anubis"
[ "$(anubis_flag)" = "true" ] && ok "ENV=test + 'anubis': explicit select wins (ON)" \
                              || bad "explicit 'anubis' did not turn anubis on in test"
routed_through_anubis && ok "test + anubis: reroute wired on explicit select" || bad "explicit select did not wire the reroute"

# ── 4) idempotent + reversible reroute ───────────────────────────────────────
seed_tree idem
run_render prod "akkoma tuwunel phpbb games"     # ON  -> wires reroute
run_render prod "akkoma tuwunel phpbb games"     # ON again -> must NOT duplicate
n="$(grep -cE '^[[:space:]]*backendServiceName:[[:space:]]*anubis' "$(fe)")"
[ "${n}" -eq 1 ] && ok "reroute is IDEMPOTENT (single backendServiceName after re-render)" \
                 || bad "reroute duplicated on re-render (count=${n})"
nc="$(grep -cE 'PoW shield UP: route public ingress THROUGH Anubis' "$(fe)")"
[ "${nc}" -eq 1 ] && ok "reroute marker comment not duplicated" || bad "marker comment duplicated (count=${nc})"
run_render test "akkoma tuwunel phpbb games"     # flip OFF -> must REMOVE the reroute
routed_through_anubis && bad "reroute NOT reversed when anubis flipped off" \
                       || ok "reroute is REVERSIBLE (removed when anubis flips off)"

# ── 5) the wiring is GATED, not hardcoded — asserted on EFFECT, not on grep ──
# This block used to be `grep -q '_opt_wire_anubis_ingress' "${BUILDER}"` and
# `grep -q '_opt_anubis_installed()' "${BUILDER}"`. Both are function-NAME greps,
# which is the weakest possible form: the name is satisfied by a comment, and by a
# present-but-wrong body. So instead: render once with the reroute stripped out of
# the tree beforehand and prove the RENDER PATH puts it back (i.e. the render calls
# the reroute), and prove the decision genuinely varies with ENV alone.
seed_tree wired-by-render
sed -i -E '/backendServiceName:|backendServicePort:|PoW shield UP/d' "$(fe)"
run_render prod "akkoma tuwunel phpbb"
routed_through_anubis \
    && ok "the RENDER path itself wires the reroute (stripped tree came back rerouted)" \
    || bad "render did not wire the reroute — _opt_wire_anubis_ingress is not called by the render"
# ENV is the ONLY thing that differs between these two; the decision must differ too.
ENV=prod; OPTIONAL_SERVICES="akkoma tuwunel phpbb"; _prod="$(_opt_anubis_installed)"
ENV=test; OPTIONAL_SERVICES="akkoma tuwunel phpbb"; _test="$(_opt_anubis_installed)"
[ "${_prod}" = "true" ] && [ "${_test}" = "false" ] \
    && ok "the decision is ENV-CONDITIONAL (prod=>true, test=>false, same selection)" \
    || bad "decision is not ENV-conditional (prod=${_prod} test=${_test} for the same selection)"

# ── 6) the BOT POLICY is mounted and named by POLICY_FNAME (hugmesh-fe-gateway#4) ──
# Setting POLICY_FNAME REPLACES Anubis's built-in policy, so the file has to be
# there, parse, and be reachable at the path the env names. This leg reads the
# manifests (PyYAML) and proves the WIRING; it does not run Anubis, so it cannot say
# that Anubis accepts the policy. Pinned below: the file is, byte for byte, the
# upstream default policy of the pinned tag, so introducing the ConfigMap changes no
# rule; the next change that edits a rule updates the sha on purpose.
ANUBIS_DIR="${ANUBIS_DIR:-${REPO}/specs/cluster/manifests/anubis}"
POLICY_SRC_TAG="v1.25.0"
POLICY_SRC_SHA256="51189000be995b59fb1354acd94c826bdb0d76743ed06f18c2a3811fb7f62855"
POLICY_SRC_URL="https://github.com/TecharoHQ/anubis/blob/${POLICY_SRC_TAG}/data/botPolicies.yaml"
policy_wiring() {
    python3 - "${ANUBIS_DIR}" "${POLICY_SRC_TAG}" "${POLICY_SRC_SHA256}" <<'PY'
import hashlib, os, sys
import yaml
d, tag, sha = sys.argv[1:4]
fails = []
def bad(m): fails.append(m)
kust = yaml.safe_load(open(os.path.join(d, "kustomization.yaml")))
dep = [x for x in yaml.safe_load_all(open(os.path.join(d, "deployment.yaml")))
       if x and x.get("kind") == "Deployment"][0]
spec = dep["spec"]["template"]["spec"]
ctr = [c for c in spec["containers"] if c["name"] == "anubis"][0]
env = {e["name"]: e.get("value") for e in ctr.get("env", [])}
fname = env.get("POLICY_FNAME")
if not fname:
    bad("the anubis container sets no POLICY_FNAME")
else:
    mdir, base = os.path.dirname(fname), os.path.basename(fname)
    mounts = [m for m in (ctr.get("volumeMounts") or []) if m.get("mountPath") == mdir]
    if not mounts:
        bad("no volumeMount at %s, the directory POLICY_FNAME=%s lives in" % (mdir, fname))
    else:
        m = mounts[0]
        if m.get("readOnly") is not True:
            bad("the policy mount is not readOnly: true")
        if m.get("subPath"):
            bad("the policy mount uses subPath, which never sees a policy edit")
        vols = [v for v in (spec.get("volumes") or []) if v["name"] == m["name"]]
        if not vols or "configMap" not in vols[0]:
            bad("volume %r is not a configMap volume" % m["name"])
        else:
            cm = vols[0]["configMap"]["name"]
            gens = [g for g in kust.get("configMapGenerator", []) if g.get("name") == cm]
            if not gens:
                bad("no configMapGenerator named %r in kustomization.yaml" % cm)
            else:
                files = [str(f).split("=")[0] if "=" in str(f) else os.path.basename(str(f))
                         for f in gens[0].get("files", [])]
                if base not in files:
                    bad("the ConfigMap %r has no key %r (has %r)" % (cm, base, files))
                src = os.path.join(d, base)
                if not os.path.isfile(src):
                    bad("%s is named by the generator but absent" % src)
                else:
                    raw = open(src, "rb").read()
                    pol = yaml.safe_load(raw)
                    if not isinstance(pol, dict) or not isinstance(pol.get("bots"), list) or not pol["bots"]:
                        bad("the policy has no non-empty bots list")
                    if not isinstance(pol, dict) or not pol.get("thresholds"):
                        bad("the policy has no thresholds")
                    # hugmesh's own rules live between two marker lines (and the one
                    # blank line after the end marker); without them the file is the
                    # upstream default policy of the pinned tag.
                    lines = raw.decode().split("\n")
                    if sum(l.strip().startswith("# hugmesh-local:begin") for l in lines) != \
                       sum(l.strip() == "# hugmesh-local:end" for l in lines):
                        bad("unbalanced hugmesh-local:begin / hugmesh-local:end markers")
                    kept, skipping, eat_blank = [], False, False
                    for l in lines:
                        if l.strip().startswith("# hugmesh-local:begin"):
                            skipping = True
                        if skipping:
                            if l.strip() == "# hugmesh-local:end":
                                skipping, eat_blank = False, True
                            continue
                        if eat_blank and not l.strip():
                            eat_blank = False
                            continue
                        eat_blank = False
                        kept.append(l)
                    if hashlib.sha256("\n".join(kept).encode()).hexdigest() != sha:
                        bad("outside the hugmesh-local markers the policy is not the pinned upstream %s default (sha256 differs); a rule edit belongs between the markers, a re-sync from a new tag updates POLICY_SRC_SHA256" % tag)
if ctr["securityContext"].get("readOnlyRootFilesystem") is not True:
    bad("readOnlyRootFilesystem is no longer true on the anubis container")
tags = [i.get("newTag") for i in kust.get("images", []) if i.get("name") == "ghcr.io/techarohq/anubis"]
if tags != [tag]:
    bad("the image pin is %r but the policy was taken from %s: re-sync botPolicies.yaml from the new tag, then update POLICY_SRC_TAG and POLICY_SRC_SHA256" % (tags, tag))
for f in fails:
    print(f)
sys.exit(1 if fails else 0)
PY
}
echo "-- (6) bot policy ConfigMap: mount + POLICY_FNAME + parseable policy (source ${POLICY_SRC_URL}) --"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    out="$(policy_wiring 2>&1)" && ok "POLICY_FNAME -> read-only configMap dir mount -> generated ConfigMap key; policy parses and, outside the hugmesh-local markers, is the pinned ${POLICY_SRC_TAG} default" \
                               || bad "bot policy wiring: ${out}"
else
    bad "bot policy leg needs python3 + PyYAML (the CI images carry both)"
fi
# The render leg needs kubectl; absent, it is reported as SKIPPED (not as a pass)
# and the static leg above still gates.
if command -v kubectl >/dev/null 2>&1; then
    rendered="$(kubectl kustomize "${ANUBIS_DIR}" 2>&1)" || { bad "kubectl kustomize failed: ${rendered}"; rendered=""; }
    if [ -n "${rendered}" ]; then
        printf '%s' "${rendered}" | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms = [d for d in docs if d["kind"] == "ConfigMap"]
dep = [d for d in docs if d["kind"] == "Deployment"][0]
vol = [v for v in dep["spec"]["template"]["spec"]["volumes"] if v["name"] == "policy"][0]["configMap"]["name"]
ok = (len(cms) == 1 and cms[0]["metadata"]["name"] == vol
      and cms[0]["metadata"]["name"].startswith("hugmesh-anubis-policy-")
      and "botPolicies.yaml" in cms[0]["data"])
sys.exit(0 if ok else 1)' \
            && ok "kubectl kustomize renders the ConfigMap with a content-hash name and points the Deployment volume at it" \
            || bad "rendered ConfigMap/volume mismatch (the Deployment would mount a ConfigMap that does not exist)"
    fi
else
    echo "  SKIPPED kubectl absent: the render leg of (6) did not run (not a pass)"
fi

# ── 7) login, BFF login and health paths skip the challenge; / does not ──────────
# (hugmesh-fe-gateway roadmap: "validate /login/**, /bff/login and /actuator/health
# bypass the Anubis challenge"). This replays the INLINE rules of the policy file in
# order, then its thresholds, for a browser user agent. It is a model of how Anubis
# applies rules (first ALLOW/DENY/CHALLENGE wins, WEIGH adds to a weight that the
# thresholds turn into an action); it is NOT Anubis. The (data)/ imports are upstream
# files that are not in this repo, so they are skipped, and their ORDER relative to
# the new rule is asserted instead. Whether a real pod stops challenging these paths
# is open and needs a running ANUBIS=1 mesh.
policy_paths() {
    python3 - "${ANUBIS_DIR}/botPolicies.yaml" <<'PY'
import re, sys
import yaml
pol = yaml.safe_load(open(sys.argv[1]))
bots, thresholds = pol["bots"], pol["thresholds"]
fails = []
def bad(m): fails.append(m)

def decide(path, ua):
    weight = 0
    for b in bots:
        if "import" in b:
            continue
        if "path_regex" in b and not re.search(b["path_regex"], path):
            continue
        if "user_agent_regex" in b and not re.search(b["user_agent_regex"], ua):
            continue
        if "geoip" in b or "asns" in b:      # needs the client address; none in this model
            continue
        if b["action"] == "WEIGH":
            weight += b["weight"]["adjust"]
            continue
        return b["action"]
    for t in thresholds:
        e = t["expression"]
        conds = e["all"] if isinstance(e, dict) else [e]
        for c in conds:
            if not re.fullmatch(r"weight\s*(<=|>=|<|>|==)\s*-?\d+", c.strip()):
                bad("threshold %r uses an expression this model does not evaluate" % t["name"])
                return None
        if all(eval(c, {"__builtins__": {}}, {"weight": weight}) for c in conds):
            return t["action"]
    return "NO-THRESHOLD"

BROWSER = "Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/130.0"
for path in ("/login", "/login/", "/login/assets/app.js", "/bff/login", "/actuator/health",
             "/actuator/health/liveness"):
    got = decide(path, BROWSER)
    if got != "ALLOW":
        bad("%s gets %s, not ALLOW" % (path, got))
for path in ("/", "/index.html", "/loginx", "/logins/x", "/bff/loginx", "/bff/login/x",
             "/bff/session", "/actuator/env", "/actuator/healthx", "/x/login"):
    got = decide(path, BROWSER)
    if got != "CHALLENGE":
        bad("%s gets %s, but only the three exempt paths may skip the challenge (want CHALLENGE)" % (path, got))

names = [b.get("name") or b.get("import") for b in bots]
rule = "hugmesh-login-and-health-paths"
if rule not in names:
    bad("the %s rule is missing" % rule)
else:
    at = names.index(rule)
    imp = lambda frag: [i for i, n in enumerate(names) if frag in str(n)]
    for frag in ("_deny-pathological", "aggressive-brazilian-scrapers", "ai-block-aggressive", "_allow-good"):
        idx = imp(frag)
        if not idx:
            bad("the upstream import %s is gone" % frag)
        elif idx[0] > at:
            bad("the import %s sits AFTER the path allow, so the allow would shadow it" % frag)
    weighs = [i for i, b in enumerate(bots) if b.get("action") == "WEIGH"]
    if not weighs or min(weighs) < at:
        bad("a WEIGH rule sits before the path allow, so those paths would be weighed first")
for f in fails:
    print(f)
sys.exit(1 if fails else 0)
PY
}
echo "-- (7) login, BFF login and health paths are allowed; / and near-miss paths still challenged --"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    out="$(policy_paths 2>&1)" && ok "policy replay: /login/**, /bff/login, /actuator/health[/**] ALLOW; /, /loginx, /bff/loginx, /actuator/env ... CHALLENGE; rule sits after the deny imports and before every WEIGH rule" \
                              || bad "login/health path allow: ${out}"
else
    bad "login/health path leg needs python3 + PyYAML (the CI images carry both)"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
