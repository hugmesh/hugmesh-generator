#!/usr/bin/env bash
# test-kind-tor.sh — offline guard for the kind lane's .onion front door
# (scripts/kind-tor.sh, `make kind-tor`; hugmesh-generator#577, decision 67 = B).
#
# No cluster, no network, no docker, no real tor daemon, no sudo. What it pins:
#
#   A. the script parses (bash -n);
#   B. THE DOOR. The torrc that `kind-tor.sh torrc` AND `kind-tor.sh up --dry-run`
#      render publish exactly `HiddenServicePort 443 127.0.0.1:8443` and
#      `HiddenServicePort 80 127.0.0.1:8080` — asserted on the rendered OUTPUT, never
#      by grepping the source — with a loopback-only SocksPort, no `User` directive
#      (a user-run tor, which is what needs no sudo), and every path under the state
#      dir;
#   C. the doors are the kind node's REAL host ports: read from kind-local.yaml's
#      extraPortMappings (containerPort 443 -> hostPort, 80 -> hostPort), not
#      restated here;
#   D. the state dir is gitignored (git check-ignore), so onion keys cannot be
#      committed;
#   E. --dry-run starts, writes and patches NOTHING (stubbed tor/kubectl/curl/sudo
#      record any call);
#   F. THE PATCH. `kind-tor.sh params` over an Application built from the committed
#      apps/20-gateway-fe.yaml plus the helm parameters bootstrap-kind.sh really
#      writes (its GW_FE_PARAMS lines, evaluated with MFA=1) keeps every existing
#      parameter in order and appends ingress.extraHosts[N] with N = the committed
#      extraHosts length; a second add REPLACES rather than stacks; --remove restores
#      the original list exactly; a non-onion value is refused;
#   G. THE INGRESS. helm renders the fe-gateway chart with the Application's own
#      values and those parameters (ArgoCD's --set / --set-string split) into an
#      Ingress that admits the onion with the SAME backend as the hugmesh.net rule,
#      keeps *.hugmesh.net, and keeps class nginx-internal + force-ssl-redirect;
#   H. `up` end to end against stubs: tor is launched as `tor -f <state>/torrc`,
#      every kubectl call carries --context kind-hugmesh-local, sudo is never
#      called, a re-run reuses the running tor and still leaves ONE onion parameter,
#      `down` stops it, keeps the keys and drops the parameter, and afterwards
#      `onion`/`status` REFUSE the leftover hostname; `up` refuses a busy SOCKS port
#      and a cluster that does not answer, without launching tor;
#      `up` probes the door ONLY after the Ingress lists the onion, and declares
#      the door UP only when the probe got a status line (a 000 dies naming the tor
#      log); `status` names the RUNNING tor's port and refuses to vouch for the
#      Ingress without kubectl; the state/data/hs dirs are 0700;
#   I. the Makefile wiring and the @env:kind @via:onion feature exist and agree,
#      and the feature's steps reach the mesh ONLY through the proxied onion
#      context (no `page`/`context`/`request`/`baseURL` fixture, no unproxied
#      request route) — the same static rule tor_flip_wiring.py T15 holds for the
#      compose lane's onion steps;
#   J. tests/e2e/run.sh --env kind --via onion (what `make kind-e2e-tor` runs)
#      plans and EXECUTES the kind onion lane: onion + proxy from the live
#      kind-tor.sh, the local kind door kept as the probe base, exactly the
#      @via:onion @env:kind tags, and a run that skipped FAILS.
#
# Exit: 0 all pass, 1 any failure, 2 a required tool is missing (never a pass).
set -uo pipefail

REPO="${KIND_TOR_TEST_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT="${REPO}/scripts/kind-tor.sh"
KIND_YAML="${REPO}/specs/cluster/bootstrap/kind-local/kind-local.yaml"
BOOT="${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
GW_APP_YAML="${REPO}/specs/cluster/apps/20-gateway-fe.yaml"
CHART="${REPO}/specs/cluster/charts/hugmesh-gateway"
FEATURE="${REPO}/tests/e2e/features/platform/tor-onion-kind.feature"
STEPS="${REPO}/tests/e2e/steps/kind-onion.steps.ts"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for t in bash python3 helm git; do
  command -v "${t}" >/dev/null 2>&1 || { echo "FATAL: ${t} required — refusing to report a pass without it" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required — refusing to report a pass without it" >&2; exit 2; }
for f in "${SCRIPT}" "${KIND_YAML}" "${BOOT}" "${GW_APP_YAML}" "${CHART}/Chart.yaml"; do
  [ -r "${f}" ] || { echo "FATAL: cannot read ${f}" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kind-tor-test.XXXXXX")"
STUB_PIDS=""
cleanup() {
  local p
  for p in ${STUB_PIDS}; do kill "${p}" 2>/dev/null || true; done
  rm -rf "${WORK}"
}
trap cleanup EXIT

ONION_A="$(python3 -c "print(('abcdefghijklmnopqrstuvwxyz234567'*2)[:56]+'.onion')")"
ONION_B="$(python3 -c "print(('234567abcdefghijklmnopqrstuvwxyz'*2)[:56]+'.onion')")"

echo "== A. syntax =="
if bash -n "${SCRIPT}"; then ok "bash -n scripts/kind-tor.sh"; else bad "bash -n scripts/kind-tor.sh"; fi

echo "== B. the rendered torrc is the door =="
ST="${WORK}/state-b"
KIND_TOR_STATE_DIR="${ST}" bash "${SCRIPT}" torrc > "${WORK}/torrc.out" 2>"${WORK}/torrc.err"
rc=$?
KIND_TOR_STATE_DIR="${ST}" bash "${SCRIPT}" up --dry-run > "${WORK}/dry.out" 2>"${WORK}/dry.err"
drc=$?
[ "${rc}" = 0 ] && ok "torrc renders (rc=0)" || bad "torrc rc=${rc}: $(head -c 300 "${WORK}/torrc.err")"
[ "${drc}" = 0 ] && ok "up --dry-run renders (rc=0)" || bad "up --dry-run rc=${drc}: $(head -c 300 "${WORK}/dry.err")"
for src in torrc.out dry.out; do
  verdict="$(ST="${ST}" python3 - "${WORK}/${src}" <<'PY'
import os, re, sys
st = os.environ["ST"]
lines = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.lstrip().startswith("#")]
kv = [l.split(None, 1) for l in lines]
problems = []
hsp = [v for k, v in kv if k == "HiddenServicePort"]
if sorted(hsp) != sorted(["443 127.0.0.1:8443", "80 127.0.0.1:8080"]):
    problems.append("HiddenServicePort set is %r, want exactly 443->127.0.0.1:8443 and 80->127.0.0.1:8080" % hsp)
socks = [v for k, v in kv if k == "SocksPort"]
if len(socks) != 1 or not re.fullmatch(r"127\.0\.0\.1:\d+", socks[0]):
    problems.append("SocksPort must be exactly one loopback listener, got %r" % socks)
if any(k == "User" for k, _ in kv):
    problems.append("a User directive means a root-started tor (sudo); this tor runs as the invoking user")
if any("0.0.0.0" in l or "[::]" in l for l in lines):
    problems.append("a wildcard bind address appears: %r" % [l for l in lines if "0.0.0.0" in l or "[::]" in l])
for key in ("DataDirectory", "HiddenServiceDir", "PidFile"):
    vals = [v for k, v in kv if k == key]
    if len(vals) != 1 or not vals[0].startswith(st + "/"):
        problems.append("%s must be one path under the state dir %s, got %r" % (key, st, vals))
if ("HiddenServiceVersion", "3") not in [tuple(x) for x in kv]:
    problems.append("HiddenServiceVersion 3 missing")
if ("ControlPort", "0") not in [tuple(x) for x in kv]:
    problems.append("ControlPort 0 missing (no control port on a user tor)")
print("OK" if not problems else "; ".join(problems))
PY
)"
  [ "${verdict}" = OK ] && ok "${src}: 443->127.0.0.1:8443 + 80->127.0.0.1:8080, loopback SOCKS, no User, paths under the state dir" \
                        || bad "${src}: ${verdict}"
done

echo "== C. the doors are kind-local.yaml's host ports =="
verdict="$(python3 - "${KIND_YAML}" "${WORK}/torrc.out" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
maps = {}
for n in cfg.get("nodes") or []:
    for m in n.get("extraPortMappings") or []:
        maps[int(m["containerPort"])] = (str(m.get("listenAddress", "")), int(m["hostPort"]))
want = {}
for l in open(sys.argv[2]):
    p = l.split()
    if len(p) == 3 and p[0] == "HiddenServicePort":
        host, port = p[2].rsplit(":", 1)
        want[int(p[1])] = (host, int(port))
problems = []
for cport in (443, 80):
    if cport not in maps:
        problems.append("kind-local.yaml maps no containerPort %d" % cport)
        continue
    if cport not in want:
        problems.append("torrc publishes no HiddenServicePort %d" % cport)
        continue
    if want[cport][1] != maps[cport][1]:
        problems.append("HiddenServicePort %d targets :%d but kind-local.yaml publishes containerPort %d on hostPort %d"
                        % (cport, want[cport][1], cport, maps[cport][1]))
    if maps[cport][0] not in ("", "0.0.0.0", "127.0.0.1"):
        problems.append("kind-local.yaml binds containerPort %d on %s, which 127.0.0.1 would not reach" % (cport, maps[cport][0]))
print("OK" if not problems else "; ".join(problems))
PY
)"
[ "${verdict}" = OK ] && ok "HiddenServicePort 443/80 target kind-local.yaml's hostPorts for containerPort 443/80" || bad "${verdict}"

echo "== D. the state dir is gitignored =="
if git -C "${REPO}" check-ignore -q "tests/stack/.run/kind-tor/hs/hs_ed25519_secret_key" 2>/dev/null; then
  ok "tests/stack/.run/kind-tor/ is gitignored (onion keys cannot be committed)"
else
  bad "tests/stack/.run/kind-tor/hs/hs_ed25519_secret_key is NOT gitignored"
fi
if grep -aF 'tests/stack/.run/kind-tor' "${SCRIPT}" >/dev/null; then
  ok "kind-tor.sh defaults its state under tests/stack/.run/kind-tor"
else
  bad "kind-tor.sh no longer defaults its state to tests/stack/.run/kind-tor (the gitignored dir D checks)"
fi

# ── stubs shared by E and H ──────────────────────────────────────────────────
STUB="${WORK}/bin"; mkdir -p "${STUB}"
CALLS="${WORK}/calls.log"; : > "${CALLS}"
FIX="${WORK}/fixture"; mkdir -p "${FIX}"

# The Application the stub kubectl serves: the committed 20-gateway-fe.yaml with
# exactly the parameter list bootstrap-kind.sh writes under MFA=1. The GW_FE_PARAMS
# lines are EVALUATED from the real script so this cannot drift from it.
grep -aE '^[[:space:]]*GW_FE_PARAMS=' "${BOOT}" > "${WORK}/gwparams.sh"
if [ "$(wc -l < "${WORK}/gwparams.sh")" -lt 3 ]; then
  bad "could not find bootstrap-kind.sh's GW_FE_PARAMS assignments (found $(wc -l < "${WORK}/gwparams.sh"))"
fi
BOOT_PARAMS="$(MFA=1 bash -c '. "$1"; printf "[%s]" "${GW_FE_PARAMS}"' _ "${WORK}/gwparams.sh")"
BOOT_PARAMS="${BOOT_PARAMS}" python3 - "${GW_APP_YAML}" "${FIX}/app.json" <<'PY' || bad "building the Application fixture failed"
import json, os, sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
app["spec"]["source"]["helm"]["parameters"] = json.loads(os.environ["BOOT_PARAMS"])
json.dump(app, open(sys.argv[2], "w"))
PY
cp "${FIX}/app.json" "${FIX}/app.orig.json"
NBASE="$(python3 -c '
import json,sys,yaml
a=json.load(open(sys.argv[1])); v=yaml.safe_load(a["spec"]["source"]["helm"]["values"])
print(len(v["ingress"]["extraHosts"]))' "${FIX}/app.json")"
python3 -c 'import json,sys; ps=json.load(open(sys.argv[1]))["spec"]["source"]["helm"]["parameters"]; sys.exit(0 if any(p["name"]=="mfa.enabled" for p in ps) and any(p["name"]=="ingress.className" for p in ps) else 1)' "${FIX}/app.json" \
  && ok "fixture carries bootstrap-kind.sh's real parameters (className + force-ssl-redirect + MFA=1's mfa.enabled)" \
  || bad "fixture lacks bootstrap-kind.sh's parameters"

cat > "${STUB}/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "${KT_CALLS}"
ctx=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --context) ctx="$2"; shift 2 ;;
    -n) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${ctx}" = "kind-hugmesh-local" ] || { echo "stub: refusing a call without --context kind-hugmesh-local" >&2; exit 97; }
set -- "${args[@]}"
case "$1 ${2:-}" in
  "get --raw") [ "${KT_CLUSTER_UP:-1}" = 1 ] && { echo ok; exit 0; } || exit 1 ;;
  "get application") cat "${KT_FIX}/app.json" ;;
  "patch application")
    body=""; while [ $# -gt 0 ]; do [ "$1" = "-p" ] && body="$2"; shift; done
    printf '%s\n' "${body}" >> "${KT_FIX}/patches.log"
    BODY="${body}" python3 -c '
import json,os,sys
a=json.load(open(sys.argv[1])); p=json.loads(os.environ["BODY"])
a["spec"]["source"]["helm"]["parameters"]=p["spec"]["source"]["helm"]["parameters"]
json.dump(a,open(sys.argv[1],"w"))' "${KT_FIX}/app.json" ;;
  "annotate application") exit 0 ;;
  "get ingress")
    # KT_INGRESS_LAG=N: the first N reads do not list the onion yet (ArgoCD has not
    # rendered it); KT_INGRESS_NEVER=1: it never does.
    n=0; [ -f "${KT_FIX}/ingress-reads" ] && n="$(cat "${KT_FIX}/ingress-reads")"
    n=$((n+1)); echo "${n}" > "${KT_FIX}/ingress-reads"
    if [ "${KT_INGRESS_NEVER:-0}" = 1 ] || [ "${n}" -le "${KT_INGRESS_LAG:-0}" ]; then
      printf 'hugmesh.net *.hugmesh.net'; exit 0
    fi
    # What ArgoCD would render: the committed hosts + every extraHosts parameter.
    python3 -c '
import json,sys,yaml
a=json.load(open(sys.argv[1])); h=a["spec"]["source"]["helm"]
v=yaml.safe_load(h["values"]); hosts=[v["ingress"]["host"]]+list(v["ingress"]["extraHosts"])
hosts+= [p["value"] for p in h.get("parameters") or [] if p["name"].startswith("ingress.extraHosts[")]
print(" ".join(hosts), end="")' "${KT_FIX}/app.json" ;;
  *) echo "stub kubectl: unexpected $*" >&2; exit 98 ;;
esac
EOF
cat > "${STUB}/tor" <<'EOF'
#!/usr/bin/env bash
printf 'tor %s\n' "$*" >> "${KT_CALLS}"
[ "$1" = "--verify-config" ] && exit 0
[ "$1" = "-f" ] || { echo "stub tor: unexpected $*" >&2; exit 98; }
torrc="$2"
hs="$(awk '$1=="HiddenServiceDir"{print $2}' "${torrc}")"
pidf="$(awk '$1=="PidFile"{print $2}' "${torrc}")"
[ -s "${hs}/hostname" ] || printf '%s\n' "${KT_ONION}" > "${hs}/hostname"
# A long-lived process whose cmdline names the torrc, as a real daemonised tor's does.
nohup python3 -c 'import time; time.sleep(600)' kind-tor-stub "${torrc}" >/dev/null 2>&1 &
echo $! > "${pidf}"
echo $! >> "${KT_FIX}/stub-pids"
exit 0
EOF
cat > "${STUB}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${KT_CALLS}"
# KT_CURL_CODE=000 is curl's "no answer" (the onion never came up over Tor).
printf '%s' "${KT_CURL_CODE:-308}"
EOF
cat > "${STUB}/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${KT_CALLS}"
exit 1
EOF
chmod +x "${STUB}"/*
export KT_CALLS="${CALLS}" KT_FIX="${FIX}" KT_ONION="${ONION_A}"
SPATH="${STUB}:${PATH}"
reap_stubs() { local p; [ -f "${FIX}/stub-pids" ] && for p in $(cat "${FIX}/stub-pids"); do STUB_PIDS="${STUB_PIDS} ${p}"; done; }

echo "== E. --dry-run touches nothing =="
ST="${WORK}/state-e"
: > "${CALLS}"
PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST}" bash "${SCRIPT}" up --dry-run >/dev/null 2>&1; r1=$?
PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST}" bash "${SCRIPT}" down --dry-run >/dev/null 2>&1; r2=$?
[ "${r1}${r2}" = 00 ] && ok "up/down --dry-run exit 0" || bad "dry-run rc up=${r1} down=${r2}"
if [ -s "${CALLS}" ]; then bad "dry-run invoked: $(tr '\n' ';' < "${CALLS}")"; else ok "dry-run invoked no tor, kubectl, curl or sudo"; fi
[ -e "${ST}" ] && bad "dry-run created ${ST}" || ok "dry-run created no state dir"

echo "== F. the helm parameters patch is read-modify-write =="
PATCH1="$(bash "${SCRIPT}" params "${ONION_A}" < "${FIX}/app.orig.json" 2>"${WORK}/p.err")"; prc=$?
[ "${prc}" = 0 ] || bad "params add rc=${prc}: $(head -c 300 "${WORK}/p.err")"
verdict="$(PATCH="${PATCH1}" ONION="${ONION_A}" N="${NBASE}" python3 - "${FIX}/app.orig.json" <<'PY'
import json, os, sys
orig = json.load(open(sys.argv[1]))["spec"]["source"]["helm"]["parameters"]
new = json.loads(os.environ["PATCH"])
want = orig + [{"name": "ingress.extraHosts[%s]" % os.environ["N"], "value": os.environ["ONION"]}]
print("OK" if new == want else "got %r want %r" % (new, want))
PY
)"
[ "${verdict}" = OK ] && ok "add keeps every bootstrap parameter in order and appends ingress.extraHosts[${NBASE}]=<onion>" || bad "add: ${verdict}"
python3 -c '
import json,sys
a=json.load(open(sys.argv[1])); a["spec"]["source"]["helm"]["parameters"]=json.loads(sys.argv[2]); json.dump(a,open(sys.argv[3],"w"))' \
  "${FIX}/app.orig.json" "${PATCH1}" "${WORK}/app.with-a.json"
PATCH2="$(bash "${SCRIPT}" params "${ONION_B}" < "${WORK}/app.with-a.json" 2>/dev/null)"
verdict="$(PATCH="${PATCH2}" A="${ONION_A}" B="${ONION_B}" python3 -c '
import json,os
p=json.loads(os.environ["PATCH"]); vals=[x["value"] for x in p]
ok = vals.count(os.environ["B"])==1 and os.environ["A"] not in vals and sum(1 for x in p if x["name"].startswith("ingress.extraHosts["))==1
print("OK" if ok else repr(p))')"
[ "${verdict}" = OK ] && ok "a second add REPLACES the onion parameter (exactly one, the new one)" || bad "re-add stacked or lost: ${verdict}"
PATCH3="$(bash "${SCRIPT}" params x --remove < "${WORK}/app.with-a.json" 2>/dev/null)"
verdict="$(PATCH="${PATCH3}" python3 -c '
import json,os,sys
orig=json.load(open(sys.argv[1]))["spec"]["source"]["helm"]["parameters"]
print("OK" if json.loads(os.environ["PATCH"])==orig else "got %s" % os.environ["PATCH"])' "${FIX}/app.orig.json")"
[ "${verdict}" = OK ] && ok "--remove restores the bootstrap parameter list exactly" || bad "--remove: ${verdict}"
for badval in "evil.example.com" "${ONION_A^^}" "${ONION_A:1}" "${ONION_A}.evil.com" $'x\nHiddenServicePort 22 127.0.0.1:22' "${ONION_A}\"}]"; do
  if bash "${SCRIPT}" params "${badval}" < "${FIX}/app.orig.json" >/dev/null 2>&1; then
    bad "params accepted a non-onion value: $(printf '%q' "${badval}")"
  else
    ok "params refuses $(printf '%q' "${badval}" | head -c 60)"
  fi
done
python3 -c '
import json,sys
a=json.load(open(sys.argv[1])); a["spec"]["source"]["helm"]["parameters"].append({"name":"ingress.extraHosts[%s]" % sys.argv[3],"value":"someone-else.example"}); json.dump(a,open(sys.argv[2],"w"))' \
  "${FIX}/app.orig.json" "${WORK}/app.foreign.json" "${NBASE}"
if bash "${SCRIPT}" params "${ONION_A}" < "${WORK}/app.foreign.json" >/dev/null 2>&1; then
  bad "params overwrote a foreign ingress.extraHosts[${NBASE}] parameter"
else
  ok "params refuses when another writer already extended ingress.extraHosts"
fi

echo "== G. helm renders an Ingress that admits the onion =="
python3 -c '
import json,sys
a=json.load(open(sys.argv[1])); open(sys.argv[2],"w").write(a["spec"]["source"]["helm"]["values"])' "${FIX}/app.orig.json" "${WORK}/values.yaml"
# ArgoCD's split: forceString -> --set-string, otherwise --set.
mapfile -t SETS < <(PATCH="${PATCH1}" python3 -c '
import json,os
for p in json.loads(os.environ["PATCH"]):
    print(("--set-string" if p.get("forceString") else "--set"))
    print("%s=%s" % (p["name"], p["value"]))')
if helm template hugmesh-fe-gateway "${CHART}" -f "${WORK}/values.yaml" "${SETS[@]}" > "${WORK}/render.yaml" 2>"${WORK}/render.err"; then
  ok "helm template rc=0 with the Application values + the patched parameters"
else
  bad "helm template failed: $(head -c 400 "${WORK}/render.err")"
fi
verdict="$(ONION="${ONION_A}" python3 - "${WORK}/render.yaml" <<'PY'
import os, sys, yaml
onion = os.environ["ONION"]
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
ings = [d for d in docs if d.get("kind") == "Ingress"]
svcs = [d for d in docs if d.get("kind") == "Service"]
problems = []
if len(ings) != 1:
    print("expected one Ingress, got %d" % len(ings)); sys.exit()
ing = ings[0]
rules = {r["host"]: r for r in ing["spec"].get("rules", [])}
def backend(r):
    b = r["http"]["paths"][0]["backend"]["service"]
    return (b["name"], b["port"]["number"])
if onion not in rules:
    problems.append("no rule for the onion; hosts=%r" % list(rules))
if "hugmesh.net" not in rules or "*.hugmesh.net" not in rules:
    problems.append("lost a committed host; hosts=%r" % list(rules))
if onion in rules and "hugmesh.net" in rules and backend(rules[onion]) != backend(rules["hugmesh.net"]):
    problems.append("onion backend %r != hugmesh.net backend %r" % (backend(rules[onion]), backend(rules["hugmesh.net"])))
if onion in rules:
    p = rules[onion]["http"]["paths"][0]
    if p.get("path") != "/" or p.get("pathType") != "Prefix":
        problems.append("onion rule is not a / Prefix rule: %r" % p)
svc = [(s["metadata"]["name"], s["spec"]["ports"][0]["port"]) for s in svcs]
if onion in rules and backend(rules[onion]) not in svc:
    problems.append("onion backend %r is not a Service the chart renders %r" % (backend(rules[onion]), svc))
if ing["spec"].get("ingressClassName") != "nginx-internal":
    problems.append("ingressClassName %r, kind needs nginx-internal" % ing["spec"].get("ingressClassName"))
ann = (ing["metadata"].get("annotations") or {}).get("nginx.ingress.kubernetes.io/force-ssl-redirect")
if ann != "true":
    problems.append("force-ssl-redirect annotation is %r, want the STRING 'true'" % (ann,))
print("OK" if not problems else "; ".join(problems))
PY
)"
[ "${verdict}" = OK ] && ok "rendered Ingress: onion rule -> the gateway Service (same as hugmesh.net), *.hugmesh.net kept, nginx-internal, force-ssl-redirect" || bad "${verdict}"

echo "== H. up/status/onion/down against stubs =="
ST="${WORK}/state-h"
: > "${CALLS}"; rm -f "${FIX}/patches.log"; cp "${FIX}/app.orig.json" "${FIX}/app.json"
# A free SOCKS port, so a real listener on this box cannot make the test flaky.
SP="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
RUN=(env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST}" KIND_TOR_SOCKS_PORT="${SP}" KIND_TOR_WAIT=5 TOR_BIN="${STUB}/tor")
"${RUN[@]}" bash "${SCRIPT}" up > "${WORK}/up1.out" 2>&1; urc=$?; reap_stubs
[ "${urc}" = 0 ] && ok "up rc=0 against the stubs" || bad "up rc=${urc}: $(tail -c 400 "${WORK}/up1.out")"
grep -aF "tor -f ${ST}/torrc" "${CALLS}" >/dev/null && ok "tor launched as 'tor -f <state>/torrc'" || bad "tor was not launched with the state torrc: $(grep -a '^tor' "${CALLS}" | tr '\n' ';')"
grep -axF "HiddenServicePort 443 127.0.0.1:8443" "${ST}/torrc" >/dev/null && ok "the WRITTEN torrc publishes 443 -> 127.0.0.1:8443" || bad "the written torrc lacks 'HiddenServicePort 443 127.0.0.1:8443'"
if grep -a '^kubectl' "${CALLS}" | grep -av -- '--context kind-hugmesh-local' >/dev/null; then
  bad "a kubectl call ran without --context kind-hugmesh-local: $(grep -a '^kubectl' "${CALLS}" | grep -av -- '--context kind-hugmesh-local' | head -2 | tr '\n' ';')"
else
  ok "every kubectl call pins --context kind-hugmesh-local ($(grep -ac '^kubectl' "${CALLS}") calls)"
fi
grep -a '^sudo' "${CALLS}" >/dev/null && bad "sudo was invoked" || ok "sudo was never invoked"
grep -a "^curl .*--socks5-hostname 127.0.0.1:${SP} .*https://${ONION_A}/" "${CALLS}" >/dev/null \
  && ok "the door is probed through the kind tor's own SOCKS port" || bad "no curl probe through 127.0.0.1:${SP} to https://<onion>/"
o="$("${RUN[@]}" bash "${SCRIPT}" onion 2>/dev/null)"
[ "${o}" = "${ONION_A}" ] && ok "onion prints the live onion" || bad "onion printed '${o}'"
# The keys dir is what makes the address; tor itself refuses a group/world-readable
# HiddenServiceDir, and the docs promise 0700. Checked on disk, not in the source.
perms="$(stat -c '%a' "${ST}" "${ST}/data" "${ST}/hs" 2>/dev/null | tr '\n' ' ')"
[ "${perms}" = "700 700 700 " ] && ok "state, data and hs dirs are 0700" || bad "state/data/hs modes are '${perms}', want 700 700 700"
"${RUN[@]}" bash "${SCRIPT}" status >/dev/null 2>&1 && ok "status rc=0 while tor is alive and the Ingress admits the onion" || bad "status non-zero on a live door"
# `make kind-up` re-run: bootstrap-kind.sh merge-patches the gateway's parameters
# WHOLESALE, which drops the onion extraHost while tor keeps running. status must
# say so rather than report a live door the Ingress no longer admits.
cp "${FIX}/app.json" "${WORK}/app.live.json"; cp "${FIX}/app.orig.json" "${FIX}/app.json"
"${RUN[@]}" bash "${SCRIPT}" status > "${WORK}/status.wiped" 2>&1 \
  && bad "status rc=0 after a kind-up wiped the onion extraHost" \
  || { grep -aq "does NOT admit" "${WORK}/status.wiped" && ok "status non-zero, naming the missing Ingress rule, after a kind-up wiped it" \
       || bad "status failed without naming the Ingress rule: $(tr '\n' ' ' < "${WORK}/status.wiped")"; }
# A changed KIND_TOR_SOCKS_PORT while tor is running must not make `socks` (what
# kind-e2e-tor hands the browser) or the reuse probe name a port nothing serves.
OTHER="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
s_live="$(env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST}" KIND_TOR_SOCKS_PORT="${OTHER}" bash "${SCRIPT}" socks 2>/dev/null)"
[ "${s_live}" = "socks5://127.0.0.1:${SP}" ] && ok "socks names the RUNNING tor's port, not a changed KIND_TOR_SOCKS_PORT" \
  || bad "socks printed '${s_live}' while the live tor listens on ${SP}"
st_live="$(env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST}" KIND_TOR_SOCKS_PORT="${OTHER}" bash "${SCRIPT}" status 2>/dev/null | head -1)"
case "${st_live}" in
  *"SOCKS 127.0.0.1:${SP}") ok "status names the RUNNING tor's port, not a changed KIND_TOR_SOCKS_PORT" ;;
  *) bad "status printed '${st_live}' while the live tor listens on ${SP}" ;;
esac
# Without kubectl the Ingress half of `status` cannot be answered — it must say so
# and fail, never report a live door it did not check. A PATH holding only what the
# tor/onion half needs (no kubectl anywhere on it).
NOKUBE="${WORK}/nokube"; mkdir -p "${NOKUBE}"
for t in tr grep awk cat; do ln -sf "$(command -v "${t}")" "${NOKUBE}/${t}"; done
env PATH="${NOKUBE}" KIND_TOR_STATE_DIR="${ST}" "$(command -v bash)" "${SCRIPT}" status > "${WORK}/status.nokube" 2>&1 \
  && bad "status rc=0 with no kubectl on PATH (the Ingress was never checked)" \
  || { grep -aq "UNCHECKED" "${WORK}/status.nokube" && grep -aq "running (pid" "${WORK}/status.nokube" \
         && ok "status without kubectl fails, saying the Ingress is UNCHECKED" \
         || bad "status without kubectl: $(tr '\n' ' ' < "${WORK}/status.nokube")"; }
cp "${CALLS}" "${WORK}/calls.before-reuse"
env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST}" KIND_TOR_SOCKS_PORT="${OTHER}" KIND_TOR_WAIT=5 TOR_BIN="${STUB}/tor" \
  bash "${SCRIPT}" up > "${WORK}/up-other.out" 2>&1; reap_stubs
# (diff exits 1 on any difference, so it must not sit in a pipeline under pipefail)
diff "${WORK}/calls.before-reuse" "${CALLS}" > "${WORK}/calls.reuse.diff"
if grep -a "^> curl .*--socks5-hostname 127.0.0.1:${SP} " "${WORK}/calls.reuse.diff" >/dev/null; then
  ok "a reusing up probes through the live tor's port even when KIND_TOR_SOCKS_PORT changed"
else
  bad "a reusing up did not probe through the live port ${SP}: $(grep -a '^> curl' "${WORK}/calls.reuse.diff" | head -1)"
fi
"${RUN[@]}" bash "${SCRIPT}" up > "${WORK}/up2.out" 2>&1; reap_stubs
"${RUN[@]}" bash "${SCRIPT}" status >/dev/null 2>&1 && ok "a second up re-admits the onion after the wipe" || bad "status still non-zero after re-running up"
n_launch="$(grep -ac "^tor -f " "${CALLS}")"
[ "${n_launch}" = 1 ] && ok "a second up reuses the running tor (one launch)" || bad "tor launched ${n_launch} times"
n_onion="$(python3 -c '
import json,sys
ps=json.load(open(sys.argv[1]))["spec"]["source"]["helm"]["parameters"]
print(sum(1 for p in ps if p["name"].startswith("ingress.extraHosts[")))' "${FIX}/app.json")"
[ "${n_onion}" = 1 ] && ok "after two ups the Application carries exactly one onion extraHost" || bad "Application carries ${n_onion} onion extraHosts"
pid="$(cat "${ST}/tor.pid" 2>/dev/null || true)"
"${RUN[@]}" bash "${SCRIPT}" down > "${WORK}/down.out" 2>&1; drc=$?
[ "${drc}" = 0 ] && ok "down rc=0" || bad "down rc=${drc}: $(tail -c 300 "${WORK}/down.out")"
if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then bad "down left tor (pid ${pid}) running"; else ok "down stopped the tor it started"; fi
[ -s "${ST}/hs/hostname" ] && ok "down KEEPS the onion keys dir (stable address)" || bad "down removed the hostname/keys"
cmp -s <(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["spec"]["source"]["helm"]["parameters"])' "${FIX}/app.json") \
       <(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["spec"]["source"]["helm"]["parameters"])' "${FIX}/app.orig.json") \
  && ok "down restores the Application's parameter list exactly" || bad "down left the parameters changed"
"${RUN[@]}" bash "${SCRIPT}" onion >/dev/null 2>&1 && bad "onion answered from a leftover hostname with tor stopped" || ok "onion REFUSES a leftover hostname when tor is not running"
"${RUN[@]}" bash "${SCRIPT}" status >/dev/null 2>&1 && bad "status rc=0 with tor stopped" || ok "status non-zero with tor stopped"
# A pidfile naming a LIVE process that is not this tor (a recycled pid, another
# user's tor) must not count as the door being up.
echo "$$" > "${ST}/tor.pid"
"${RUN[@]}" bash "${SCRIPT}" onion >/dev/null 2>&1 && bad "onion trusted a pidfile naming a live process that is not the kind tor" \
  || ok "onion refuses a pidfile whose live process does not run this torrc"
rm -f "${ST}/tor.pid"

# THE TWO READINESS GATES OF `up`. (1) The door is probed only after the Ingress
# SERVES the onion rule — before that ingress-nginx answers the onion Host from
# its default server, and a 404 would read as "the door answered". (2) Only a
# status line counts as an answer; curl's 000 means the onion never came up.
ST2="${WORK}/state-lag"; : > "${CALLS}"; rm -f "${FIX}/ingress-reads"; cp "${FIX}/app.orig.json" "${FIX}/app.json"
env PATH="${SPATH}" KT_INGRESS_LAG=2 KIND_TOR_POLL_S=0 KIND_TOR_STATE_DIR="${ST2}" KIND_TOR_SOCKS_PORT="${SP}" \
  KIND_TOR_WAIT=5 TOR_BIN="${STUB}/tor" bash "${SCRIPT}" up > "${WORK}/up-lag.out" 2>&1; lrc=$?; reap_stubs
first_curl="$(grep -an '^curl ' "${CALLS}" | head -1 | cut -d: -f1)"
reads_before="$(head -n "$(( ${first_curl:-1} - 1 ))" "${CALLS}" | grep -ac 'get ingress')"
[ "${lrc}" = 0 ] && [ -n "${first_curl}" ] && [ "${reads_before}" -ge 3 ] \
  && ok "up waits for the Ingress to list the onion before probing it (${reads_before} Ingress reads, 2 without it, then the probe)" \
  || bad "Ingress lag: rc=${lrc}, ${reads_before} Ingress reads before the first curl (line ${first_curl:-none}); want >=3"
env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST2}" bash "${SCRIPT}" down >/dev/null 2>&1
ST3="${WORK}/state-never"; : > "${CALLS}"; rm -f "${FIX}/ingress-reads"; cp "${FIX}/app.orig.json" "${FIX}/app.json"
env PATH="${SPATH}" KT_INGRESS_NEVER=1 KIND_TOR_INGRESS_WAIT=1 KIND_TOR_POLL_S=0 KIND_TOR_STATE_DIR="${ST3}" \
  KIND_TOR_SOCKS_PORT="${SP}" KIND_TOR_WAIT=5 TOR_BIN="${STUB}/tor" bash "${SCRIPT}" up > "${WORK}/up-never.out" 2>&1; vrc=$?; reap_stubs
[ "${vrc}" != 0 ] && grep -aq "still does not list" "${WORK}/up-never.out" && ! grep -a '^curl ' "${CALLS}" >/dev/null \
  && ! grep -aq "is UP" "${WORK}/up-never.out" \
  && ok "up dies naming the Ingress when it never lists the onion, and never probes" \
  || bad "Ingress never admits: rc=${vrc}, curl calls $(grep -ac '^curl ' "${CALLS}"), out: $(tail -c 200 "${WORK}/up-never.out")"
env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST3}" bash "${SCRIPT}" down >/dev/null 2>&1
ST4="${WORK}/state-000"; : > "${CALLS}"; rm -f "${FIX}/ingress-reads"; cp "${FIX}/app.orig.json" "${FIX}/app.json"
env PATH="${SPATH}" KT_CURL_CODE=000 KIND_TOR_POLL_S=0 KIND_TOR_STATE_DIR="${ST4}" KIND_TOR_SOCKS_PORT="${SP}" \
  KIND_TOR_WAIT=1 TOR_BIN="${STUB}/tor" bash "${SCRIPT}" up > "${WORK}/up-000.out" 2>&1; zrc=$?; reap_stubs
[ "${zrc}" != 0 ] && grep -aqF "${ST4}/tor.log" "${WORK}/up-000.out" && ! grep -aq "is UP" "${WORK}/up-000.out" \
  && [ ! -e "${ST4}/onion" ] && grep -a '^curl ' "${CALLS}" >/dev/null \
  && ok "up dies naming the tor log when the onion never answers (curl 000), and never declares the door UP" \
  || bad "onion never answers: rc=${zrc}, onion file $( [ -e "${ST4}/onion" ] && echo written || echo absent), out: $(tail -c 200 "${WORK}/up-000.out")"
env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST4}" bash "${SCRIPT}" down >/dev/null 2>&1
rm -f "${FIX}/ingress-reads"; cp "${FIX}/app.orig.json" "${FIX}/app.json"

# Refusals that must happen BEFORE tor is launched.
: > "${CALLS}"
python3 -c '
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1",0)); s.listen(5)
print(s.getsockname()[1], flush=True); time.sleep(60)' > "${WORK}/busy.port" &
BUSY_PID=$!; STUB_PIDS="${STUB_PIDS} ${BUSY_PID}"
for _ in $(seq 1 50); do [ -s "${WORK}/busy.port" ] && break; sleep 0.1; done
BP="$(head -1 "${WORK}/busy.port")"
env PATH="${SPATH}" KIND_TOR_STATE_DIR="${WORK}/state-busy" KIND_TOR_SOCKS_PORT="${BP}" KIND_TOR_WAIT=5 TOR_BIN="${STUB}/tor" \
  bash "${SCRIPT}" up > "${WORK}/busy.out" 2>&1; brc=$?
[ "${brc}" != 0 ] && grep -aq "already in use" "${WORK}/busy.out" && ! grep -a '^tor -f' "${CALLS}" >/dev/null \
  && ok "up refuses a busy SOCKS port without launching tor" || bad "busy SOCKS port: rc=${brc}, $(tail -c 200 "${WORK}/busy.out"), tor calls: $(grep -ac '^tor -f' "${CALLS}")"
: > "${CALLS}"
env PATH="${SPATH}" KT_CLUSTER_UP=0 KIND_TOR_STATE_DIR="${WORK}/state-down" KIND_TOR_SOCKS_PORT="${SP}" TOR_BIN="${STUB}/tor" \
  bash "${SCRIPT}" up > "${WORK}/nocluster.out" 2>&1; nrc=$?
[ "${nrc}" != 0 ] && ! grep -a '^tor' "${CALLS}" >/dev/null && grep -aq "make kind-up" "${WORK}/nocluster.out" \
  && ok "up refuses (naming make kind-up) when the kind context does not answer, before any tor call" \
  || bad "no-cluster: rc=${nrc}, tor calls $(grep -ac '^tor' "${CALLS}"), out: $(tail -c 200 "${WORK}/nocluster.out")"

echo "== I. Makefile + feature wiring =="
MK="$(make -s -C "${REPO}" -n kind-tor kind-tor-down kind-tor-status kind-e2e-tor 2>/dev/null)"
printf '%s\n' "${MK}" | grep -axF 'bash scripts/kind-tor.sh up' >/dev/null && ok "make kind-tor runs 'kind-tor.sh up'" || bad "make kind-tor does not run 'bash scripts/kind-tor.sh up'"
printf '%s\n' "${MK}" | grep -axF 'bash scripts/kind-tor.sh down' >/dev/null && ok "make kind-tor-down runs 'kind-tor.sh down'" || bad "make kind-tor-down does not run 'bash scripts/kind-tor.sh down'"
printf '%s\n' "${MK}" | grep -axF 'bash scripts/kind-tor.sh status' >/dev/null && ok "make kind-tor-status runs 'kind-tor.sh status'" || bad "make kind-tor-status does not run 'bash scripts/kind-tor.sh status'"
for needle in 'onion="$(bash scripts/kind-tor.sh onion)" || exit 1;' 'bash scripts/kind-tor.sh status || exit 1;' 'SNAP_ONION_BASE_URL="https://${onion}"' 'SNAP_PROXY="${socks}"' 'bash tests/e2e/run.sh --bdd --env kind --via onion'; do
  printf '%s\n' "${MK}" | grep -aF -- "${needle}" >/dev/null && ok "make kind-e2e-tor carries: ${needle}" || bad "make kind-e2e-tor lacks: ${needle}"
done
# NEGATIVE: the @env:kind baseURL must stay the LOCAL kind door. world.ts's
# availability probe is an unproxied Node request; pointed at the onion it can
# never answer and the scenario would SKIP against a running cluster.
if printf '%s\n' "${MK}" | grep -aF 'SNAP_ENV_KIND_BASE_URL' >/dev/null || printf '%s\n' "${MK}" | grep -aE 'SNAP_BASE_URL=[^ ]*onion' >/dev/null; then
  bad "make kind-e2e-tor points the @env:kind baseURL at the onion (the availability probe cannot reach it)"
else
  ok "make kind-e2e-tor leaves the @env:kind baseURL at the local kind door"
fi
if [ -r "${FEATURE}" ]; then
  tags="$(grep -aE '^[[:space:]]*@' "${FEATURE}" | tr '\n' ' ')"
  for t in '@env:kind' '@via:onion' '@issue:generator-577'; do
    printf '%s' "${tags}" | grep -aF -- "${t}" >/dev/null && ok "feature tagged ${t}" || bad "feature lacks ${t}"
  done
  grep -aF "every request the kind onion browser made stayed on the onion" "${FEATURE}" >/dev/null \
    && ok "the feature asserts no request left the onion" || bad "the feature lost the no-leak assertion"
  # EVERY step of the scenario must be defined in kind-onion.steps.ts, and that file
  # must reach the mesh only through onionContext(): a shared step, or a step that
  # takes the `page`/`context`/`request`/`baseURL` fixture, drives the UNPROXIED
  # local kind door and would pass without Tor.
  kv="$(python3 - "${FEATURE}" "${REPO}/tests/e2e/steps" "${STEPS}" <<'KV'
import os, re, sys
feature, steps_dir, mine = sys.argv[1], sys.argv[2], sys.argv[3]
STEP_KW = re.compile(r"^\s*(Given|When|Then|And|But)\s+(.+?)\s*$")
used = [m.group(2) for m in map(STEP_KW.match, open(feature, encoding="utf-8").read().splitlines()) if m]
DEF_RE = re.compile(r"\b(?:Given|When|Then)\(\s*'((?:[^'\\]|\\.)*)'")
defs = {}
for fn in sorted(os.listdir(steps_dir)):
    if fn.endswith(".ts"):
        for m in DEF_RE.finditer(open(os.path.join(steps_dir, fn), encoding="utf-8").read()):
            defs.setdefault(m.group(1).replace("\\'", "'"), []).append(fn)
problems = []
if len(used) < 6:
    problems.append("the scenario has only %d steps" % len(used))
for st in used:
    where = defs.get(st)
    if where != [os.path.basename(mine)]:
        problems.append("step %r is defined in %r, not (only) in %s" % (st, where, os.path.basename(mine)))
code = re.sub(r"//[^\n]*", "", open(mine, encoding="utf-8").read())
for token in ("apiContext(", "request.newContext(", "request.get(", "request.post(", "chromium.launch("):
    if token in code:
        problems.append("%s calls %s — an unproxied route to the mesh" % (os.path.basename(mine), token))
if code.count("newContext(") and "onionContext(" not in code:
    problems.append("a context is built without onionContext()")
for need in ("onionFrontDoor()", "onionContext(browser, door"):
    if need not in code:
        problems.append("%s never calls %s" % (os.path.basename(mine), need))
# A Tor-sized budget: the config's 90 s cannot hold a cold descriptor plus the
# sign-in chain over circuits (the compose lane's steps use the same 10 min).
bm = re.search(r"const SCENARIO_BUDGET_MS = ([0-9_ *]+);", code)
budget = eval(bm.group(1).replace("_", "")) if bm else 0
if budget < 5 * 60_000 or "$testInfo.setTimeout(SCENARIO_BUDGET_MS)" not in code:
    problems.append("the scenario has no Tor-sized budget (SCENARIO_BUDGET_MS=%s, setTimeout %s)"
                    % (budget, "$testInfo.setTimeout(SCENARIO_BUDGET_MS)" in code))
FIXTURE_RE = re.compile(r"\b(?:Given|When|Then)\(\s*'(?:[^'\\]|\\.)*'\s*,\s*async\s*\(\s*\{([^}]*)\}")
n = 0
for m in FIXTURE_RE.finditer(code):
    n += 1
    names = {x.strip().split(":")[0].strip() for x in m.group(1).split(",")}
    leaked = sorted(names & {"page", "context", "request", "baseURL"})
    if leaked:
        problems.append("a step takes the unproxied fixture(s) %s" % ",".join(leaked))
if n < len(set(used)):
    problems.append("only %d step definitions parsed for %d steps" % (n, len(set(used))))
print("OK" if not problems else "; ".join(problems))
KV
)"
  [ "${kv}" = OK ] && ok "every scenario step is kind-onion.steps.ts's own, and it reaches the mesh only via onionContext()" || bad "${kv}"
else
  bad "missing ${FEATURE}"
fi

echo "== J. run.sh --env kind --via onion (what make kind-e2e-tor runs) =="
RUNSH="${REPO}/tests/e2e/run.sh"
JB="${WORK}/j-bin"; mkdir -p "${JB}"
printf '#!/bin/sh\ncat\n' > "${JB}/node"            # print-plan.mjs -> the plan lines verbatim
printf '#!/bin/sh\nexit 1\n' > "${JB}/docker"        # no bundled-browser image
cat > "${JB}/npx" <<'NPX'
#!/bin/sh
echo "ARGV $*" >> "$KT_NPX_LOG"
case "$*" in
  *"playwright test"*)
    {
      echo "ENV SNAP_ONION_BASE_URL=${SNAP_ONION_BASE_URL-<unset>}"
      echo "ENV SNAP_PROXY=${SNAP_PROXY-<unset>}"
      echo "ENV SNAP_BASE_URL=${SNAP_BASE_URL-<unset>}"
      echo "ENV SNAP_ENV=${SNAP_ENV-<unset>}"
    } >> "$KT_NPX_LOG"
    if [ -n "${KT_SUMMARY:-}" ]; then printf '%s' "$KT_SUMMARY" > "$SNAP_REPORT_DIR/summary.json"; fi
    exit 0 ;;
esac
exit 0
NPX
chmod +x "${JB}"/*
plan_of() { # <label> <env assignments...> -- prints TAB plan lines of --print-command
  env -u SNAP_ONION_BASE_URL -u SNAP_PROXY -u SNAP_ENV_KIND_BASE_URL -u SNAP_BASE_URL -u SNAP_HOST_RESOLVER -u E2E_VIA \
    PATH="${JB}:${SPATH}" E2E_PASSWORD=x "$@" bash "${RUNSH}" --env kind --via onion --print-command 2>&1
}
field() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2; exit}'; }
# (1) explicit onion + proxy, the way the Makefile passes them
P1="$(plan_of SNAP_ONION_BASE_URL="https://${ONION_A}" SNAP_PROXY="socks5://127.0.0.1:${SP}")"
[ "$(field "${P1}" ENV_ID)" = kind ] && ok "--env kind --via onion plans the kind environment" || bad "ENV_ID='$(field "${P1}" ENV_ID)': $(printf '%s' "${P1}" | tail -c 200)"
[ "$(field "${P1}" TAGS)" = '@via:onion and @env:kind' ] && ok "it runs exactly '@via:onion and @env:kind'" || bad "tags '$(field "${P1}" TAGS)'"
[ "$(field "${P1}" BASE_URL)" = 'https://hugmesh.net:8443' ] && ok "SNAP_BASE_URL stays the LOCAL kind door (the unproxied probe's target)" || bad "BASE_URL '$(field "${P1}" BASE_URL)'"
[ "$(field "${P1}" ONION_BASE_URL)" = "https://${ONION_A}" ] && [ "$(field "${P1}" PROXY)" = "socks5://127.0.0.1:${SP}" ] \
  && ok "the onion and the proxy reach the plan" || bad "onion '$(field "${P1}" ONION_BASE_URL)' proxy '$(field "${P1}" PROXY)'"
[ -n "$(field "${P1}" HOST_RESOLVER)" ] && ok "SNAP_HOST_RESOLVER is set (world.ts skips @env:kind browser scenarios without it)" || bad "no HOST_RESOLVER in the kind onion plan"
# (2) nothing passed in: the onion and the port come from the LIVE kind tor
ST5="${WORK}/state-j"; : > "${CALLS}"; rm -f "${FIX}/ingress-reads"; cp "${FIX}/app.orig.json" "${FIX}/app.json"
env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST5}" KIND_TOR_SOCKS_PORT="${SP}" KIND_TOR_WAIT=5 KIND_TOR_POLL_S=0 TOR_BIN="${STUB}/tor" \
  bash "${SCRIPT}" up > "${WORK}/up-j.out" 2>&1; reap_stubs
P2="$(plan_of KIND_TOR_STATE_DIR="${ST5}" KIND_TOR_SOCKS_PORT="${OTHER}")"
[ "$(field "${P2}" ONION_BASE_URL)" = "https://${ONION_A}" ] && [ "$(field "${P2}" PROXY)" = "socks5://127.0.0.1:${SP}" ] \
  && ok "with nothing passed in, run.sh reads the onion and the RUNNING tor's port from kind-tor.sh" \
  || bad "live read: onion '$(field "${P2}" ONION_BASE_URL)' proxy '$(field "${P2}" PROXY)'"
env PATH="${SPATH}" KIND_TOR_STATE_DIR="${ST5}" bash "${SCRIPT}" down >/dev/null 2>&1
P3="$(plan_of KIND_TOR_STATE_DIR="${ST5}")"
[ -z "$(field "${P3}" ONION_BASE_URL)" ] && printf '%s' "$(field "${P3}" ONION_NOTE)" | grep -aF 'make kind-tor' >/dev/null \
  && ok "with the kind tor stopped, the leftover hostname is NOT used and the note names make kind-tor" \
  || bad "stopped tor: onion '$(field "${P3}" ONION_BASE_URL)' note '$(field "${P3}" ONION_NOTE)'"
# (3) EXECUTED against a stub npx: the env reaches playwright, and a skip FAILS
KT_NPX_LOG="${WORK}/npx.log"; JREP="${WORK}/j-report"; mkdir -p "${JREP}"
run_j() { # <summary-json>
  rm -f "${KT_NPX_LOG}" "${JREP}/summary.json"
  env -u SNAP_ENV_KIND_BASE_URL -u SNAP_BASE_URL -u E2E_VIA PATH="${JB}:${SPATH}" E2E_PASSWORD=x KT_NPX_LOG="${KT_NPX_LOG}" \
    SNAP_REPORT_DIR="${JREP}" SNAP_EVIDENCE_SUMMARY=0 KT_SUMMARY="$1" \
    SNAP_ONION_BASE_URL="https://${ONION_A}" SNAP_PROXY="socks5://127.0.0.1:${SP}" \
    bash "${RUNSH}" --bdd --env kind --via onion > "${WORK}/j-run.out" 2>&1
}
run_j '{"testTotals":{"passed":1,"failed":0,"skipped":0,"total":1},"tests":[]}'; jrc=$?
[ "${jrc}" = 0 ] && ok "an executed kind onion run whose scenario PASSED exits 0" || bad "passed run rc=${jrc}: $(tail -c 300 "${WORK}/j-run.out")"
grep -axF "ENV SNAP_ONION_BASE_URL=https://${ONION_A}" "${KT_NPX_LOG}" >/dev/null && grep -axF "ENV SNAP_PROXY=socks5://127.0.0.1:${SP}" "${KT_NPX_LOG}" >/dev/null \
  && grep -axF "ENV SNAP_BASE_URL=https://hugmesh.net:8443" "${KT_NPX_LOG}" >/dev/null && grep -axF "ENV SNAP_ENV=kind" "${KT_NPX_LOG}" >/dev/null \
  && ok "playwright's environment carries the onion, the proxy, the local kind door and SNAP_ENV=kind" \
  || bad "playwright env: $(grep -a '^ENV' "${KT_NPX_LOG}" 2>/dev/null | tr '\n' ' ')"
grep -axF "ARGV bddgen test --tags @via:onion and @env:kind" "${KT_NPX_LOG}" >/dev/null \
  && ok "bddgen generated exactly the @via:onion @env:kind scenarios" || bad "bddgen argv: $(grep -a 'bddgen' "${KT_NPX_LOG}" | tr '\n' ' ')"
run_j '{"testTotals":{"passed":0,"failed":0,"skipped":1,"total":1},"tests":[{"status":"skipped","skipReason":"KT-SKIP"}]}'; jrc=$?
[ "${jrc}" != 0 ] && grep -aq "KT-SKIP" "${WORK}/j-run.out" \
  && ok "a kind onion run that only SKIPPED fails, naming the skip reason" || bad "skipped run rc=${jrc}: $(tail -c 300 "${WORK}/j-run.out")"
env PATH="${JB}:${SPATH}" E2E_PASSWORD=x bash "${RUNSH}" --env qemu --via onion --print-command > "${WORK}/j-qemu.out" 2>&1 \
  && bad "--env qemu --via onion was accepted (qemu has no Tor front door)" || ok "--env qemu --via onion is refused"

echo "== kind onion door: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
