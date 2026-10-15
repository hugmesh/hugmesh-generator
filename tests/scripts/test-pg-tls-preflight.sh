#!/usr/bin/env bash
# =============================================================================
# test-pg-tls-preflight.sh — scripts/pg-tls-preflight.sh must refuse a
# PG_TLS_ENABLED flip that would take a database down, and its DB table must be
# the table the manifests actually describe.
#
# THE DEFECT CLASS. All nine dedicated Postgres Deployments mount their server
# cert from the ESO Secret <db>-mtls with `optional: true` and run
# `strategy: Recreate`. Flip PG_TLS_ENABLED to "true" before that Secret exists
# and pg-tls-entrypoint.sh starts Postgres with ssl_cert_file pointing at an
# empty directory: Postgres exits, the old pod is already gone, and the DB is
# down until the flip is reverted in git. Nothing else in the tree notices (the
# volume is optional, the flag is a literal, the ArgoCD app auto-syncs). The
# preflight is the stop, so it has to be the kind of stop that cannot silently
# pass. This suite pins that three ways, offline (no cluster, no network, no
# root, python3 stdlib + openssl only):
#
#   A. THE TABLE IS THE MANIFESTS. The DBs, namespaces and Secret names baked
#      into the script are derived independently from specs/cluster/manifests:
#      every Deployment that carries a PG_TLS_ENABLED env, its pg-tls volume's
#      secretName, fsGroup 70, a Recreate strategy (the reason a failed flip is
#      an outage), the <db>-mtls ExternalSecret + VaultDynamicSecret in the same
#      namespace, and the Vault PKI issuing role. A tenth DB or a renamed Secret
#      turns this red instead of leaving the preflight checking the wrong thing.
#      The jsonpath it sends to kubectl is also run against the REAL manifests
#      with the REAL kubectl --local (skipped loudly where kubectl is absent).
#   B. BEHAVIOUR against a stub kubectl serving JSON fixtures and real openssl
#      certificates: a good fleet passes; each of a dozen ways to be unready
#      (no Secret, ES not Ready, empty key, wrong type, expiring cert, missing
#      SAN, key mismatch, foreign CA, fsGroup 0, wrong volume, not ready, odd
#      gate value) fails ONLY the DB that has it; a kubectl that errors fails
#      closed; a missing openssl is UNVERIFIED (3) not a pass; --post checks the
#      live result; no certificate or key material reaches stdout; the EKU
#      branch (client-auth-only cert refused, no EKU accepted); a Deployment
#      whose name differs from the one asked for; a --post log that carries
#      "Postgres" but not the wrapper's marker; the scratch directory holding the
#      private key is removed on exit. The marker is also pinned to the nine
#      entrypoints that print it.
#   C. MUTATION BATTERY. Each mutation edits one load-bearing line of the
#      script, the suite proves the file really changed, and the scenario that
#      guards that line must then go the other way.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${REPO}/scripts/pg-tls-preflight.sh"
MAN="${REPO}/specs/cluster/manifests"

P=0; F=0; S=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
skip(){ echo "  SKIP $*"; S=$((S+1)); }

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "  FAIL openssl not available (needed to mint test certificates)"; exit 2; }
[ -f "$SCRIPT" ] || { echo "  FAIL ${SCRIPT} is missing"; exit 1; }

TMPROOT="${TMPDIR:-/tmp}"
W="$(mktemp -d "${TMPROOT}/test-pg-tls-preflight.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

echo "== pg-tls preflight: the table, the behaviour, the mutations =="

# ─── A. the table is the manifests ────────────────────────────────────────────
echo "-- A. table pinned to specs/cluster/manifests"

python3 -I - "$MAN" >"$W/derived.tsv" <<'PY'
import os, re, sys
man = sys.argv[1]
rows = []
for d in sorted(os.listdir(man)):
    p = os.path.join(man, d, "deployment.yaml")
    if not os.path.isfile(p):
        continue
    text = open(p, encoding="utf-8").read()
    live = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
    body = "\n".join(live)
    if not re.search(r"name:\s*PG_TLS_ENABLED\b", body):
        continue
    name = re.search(r"^kind: Deployment\s*\nmetadata:\s*\n\s+name:\s*(\S+)\s*\n\s+namespace:\s*(\S+)", body, re.M)
    gate = re.search(r'name:\s*PG_TLS_ENABLED,\s*value:\s*"([^"]*)"', body)
    vol = re.search(r"name:\s*pg-tls\s*\n\s*secret:\s*\n\s*secretName:\s*(\S+)\s*\n(\s*optional:\s*(\S+))?", body)
    fsg = re.search(r"^\s+fsGroup:\s*(\d+)", body, re.M)
    strat = re.search(r"strategy:\s*\{\s*type:\s*(\w+)", body)
    print("\t".join([d, name.group(1) if name else "?", name.group(2) if name else "?",
                     gate.group(1) if gate else "?", vol.group(1) if vol else "?",
                     (vol.group(3) if vol and vol.group(3) else "-"),
                     fsg.group(1) if fsg else "?", strat.group(1) if strat else "?"]))
PY
NDER="$(wc -l <"$W/derived.tsv" | tr -d ' ')"
[ "$NDER" -ge 1 ] && ok "derived ${NDER} PG_TLS_ENABLED Deployments from the manifests" \
                  || bad "derived no PG_TLS_ENABLED Deployments: the derivation is blind"

"$SCRIPT" --list >"$W/list.txt" 2>"$W/list.err"; LRC=$?
[ "$LRC" -eq 0 ] && ok "--list exits 0" || bad "--list exited $LRC"
cut -f2,3 "$W/derived.tsv" | tr '\t' ' ' | sort >"$W/derived.set"
sort "$W/list.txt" >"$W/list.set"
if cmp -s "$W/derived.set" "$W/list.set"; then ok "script table == manifests (${NDER} DBs, names and namespaces)"
else bad "script table differs from the manifests:"; diff "$W/derived.set" "$W/list.set" | sed 's/^/        /'; fi
[ "$(tail -n1 "$W/list.txt" | cut -d' ' -f1)" = "route-access-db" ] \
  && ok "route-access-db (read by every gateway) is last in flip order" \
  || bad "route-access-db is not last in flip order"
[ "$(cut -d' ' -f1 "$W/list.txt" | sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
  && ok "no DB listed twice" || bad "a DB is listed twice in the table"

while IFS=$'\t' read -r dir name ns gate vol opt fsg strat; do
  [ "$name" = "route-access-db" ] || [ "$name" = "$dir" ] || bad "$dir: Deployment is named $name, not $dir"
  [ "$vol" = "${name}-mtls" ] && ok "$name: pg-tls volume mounts ${name}-mtls" || bad "$name: pg-tls volume is '$vol'"
  [ "$opt" = "true" ] && ok "$name: the volume is optional (the reason a preflight is needed)" \
                      || bad "$name: pg-tls volume optional='$opt' — the preflight premise changed, re-read the runbook"
  [ "$fsg" = "70" ] && ok "$name: fsGroup 70" || bad "$name: fsGroup is '$fsg'"
  [ "$strat" = "Recreate" ] && ok "$name: strategy Recreate (old pod is gone before the new one starts)" \
                            || bad "$name: strategy is '$strat'"
  [ "$gate" = "false" ] || [ "$gate" = "true" ] && ok "$name: PG_TLS_ENABLED is a literal \"$gate\"" \
                                                 || bad "$name: PG_TLS_ENABLED value '$gate' is not a literal true/false"
done <"$W/derived.tsv"

# The --post marker is what the wrapper really logs: read it out of the script and find
# it in an echo line of every entrypoint (a reworded log line would make --post fail
# every DB, or, if the marker were loosened, pass a DB that never enabled ssl).
MARK="$(sed -n "s/^MARKER='\(.*\)'\$/\1/p" "$SCRIPT" | head -n1)"
if [ -z "$MARK" ]; then bad "could not read MARKER out of the script"
else
  while IFS=$'\t' read -r dir name _; do
    ep="${MAN}/${dir}/entrypoint/pg-tls-entrypoint.sh"
    [ -f "$ep" ] && grep -v '^[[:space:]]*#' "$ep" >"$W/ep.live"
    if [ -f "$ep" ] && grep -qF -e "echo \"${name}: ${MARK}" "$W/ep.live"; then ok "$name: its entrypoint logs '${MARK}'"
    else bad "$name: ${ep#$REPO/} does not echo '${MARK}' (the --post check would never pass)"; fi
  done <"$W/derived.tsv"
fi

python3 -I - "$MAN" "$W/derived.tsv" <<'PY' >"$W/eso.out"
import os, re, sys
man, tsv = sys.argv[1], sys.argv[2]
es = open(os.path.join(man, "external-secrets", "pki-externalsecrets.yaml"), encoding="utf-8").read()
init = open(os.path.join(man, "vault-pki", "pki-init-configmap.yaml"), encoding="utf-8").read()
docs = [d for d in re.split(r"^---\s*$", es, flags=re.M)]
def find(kind, name):
    for d in docs:
        d2 = "\n".join(l for l in d.splitlines() if not l.lstrip().startswith("#"))
        if re.search(r"^kind:\s*%s\s*$" % kind, d2, re.M) and re.search(r"name:\s*%s\b" % re.escape(name), d2):
            return d2
    return None
for line in open(tsv, encoding="utf-8"):
    dir_, name, ns, *_ = line.rstrip("\n").split("\t")
    sec = name + "-mtls"
    e = find("ExternalSecret", sec)
    g = find("VaultDynamicSecret", sec)
    res = []
    res.append(("ExternalSecret %s in %s" % (sec, ns), bool(e) and re.search(r"namespace:\s*%s\b" % ns, e) is not None))
    res.append(("ExternalSecret target is kubernetes.io/tls named %s" % sec,
                bool(e) and "type: kubernetes.io/tls" in e and re.search(r"target:\s*\n\s+name:\s*%s\b" % re.escape(sec), e) is not None))
    res.append(("ES carries tls.crt, tls.key and ca.crt",
                bool(e) and all(k in e for k in ("tls.crt:", "tls.key:", "ca.crt:"))))
    res.append(("VaultDynamicSecret %s in %s issues pki_int/issue/%s" % (sec, ns, name),
                bool(g) and re.search(r"namespace:\s*%s\b" % ns, g) is not None and ("pki_int/issue/%s\n" % name) in g + "\n"))
    res.append(("CN is %s.%s.svc.cluster.local" % (name, ns),
                bool(g) and ("common_name: %s.%s.svc.cluster.local" % (name, ns)) in g))
    res.append(("pki-init role %s:%s.%s" % (name, name, ns), re.search(r"^\s*%s:%s\.%s\b" % (re.escape(name), re.escape(name), re.escape(ns)), init, re.M) is not None))
    for what, good in res:
        print(("PASS" if good else "FAIL") + "\t" + name + ": " + what)
PY
while IFS=$'\t' read -r v msg; do
  if [ "$v" = "PASS" ]; then ok "$msg"; else bad "$msg"; fi
done <"$W/eso.out"
[ -s "$W/eso.out" ] || bad "the ESO derivation produced nothing"

# The runbook's order table is the script's order table, and its dir/namespace cells are real.
RB="${REPO}/docs/DB-HARDENING-RUNBOOK.md"
if [ -f "$RB" ]; then
  python3 -I - "$RB" "$W/list.txt" "$MAN" <<'PY' >"$W/rb.out"
import os, re, sys
rb, lst, man = sys.argv[1:4]
rows = []
for line in open(rb, encoding="utf-8"):
    m = re.match(r"^\|\s*(\d)\s*\|\s*`([a-z-]+)`\s*\|\s*\*{0,2}`?([a-z-]+)`?\*{0,2}\s*\|\s*\*{0,2}(hugmesh-[a-z]+)\*{0,2}\s*\|", line)
    if m:
        rows.append(m.groups())
want = [l.split() for l in open(lst)]
print(("PASS" if [r[1] for r in rows] == [w[0] for w in want] else "FAIL") + "\trunbook order table lists the DBs in the script's flip order")
print(("PASS" if [r[0] for r in rows] == [str(i + 1) for i in range(len(want))] else "FAIL") + "\trunbook rows are numbered 1..%d" % len(want))
for n, db, d, ns in rows:
    w = dict((x[0], x[1]) for x in want).get(db)
    print(("PASS" if w == ns else "FAIL") + "\trunbook row %s: namespace %s matches the script's (%s)" % (db, ns, w))
    print(("PASS" if os.path.isfile(os.path.join(man, d, "deployment.yaml")) else "FAIL") + "\trunbook row %s: dir %s holds a deployment.yaml" % (db, d))
PY
  while IFS=$'\t' read -r v msg; do if [ "$v" = "PASS" ]; then ok "$msg"; else bad "$msg"; fi; done <"$W/rb.out"
  [ -s "$W/rb.out" ] || bad "the runbook table derivation produced nothing"
else
  bad "docs/DB-HARDENING-RUNBOOK.md is missing"
fi

# The jsonpath the script sends, against the real manifests, with real kubectl.
echo "-- A. jsonpath against real kubectl --local"
jpval(){ sed -n "s/^$1='\\(.*\\)'\$/\\1/p" "$SCRIPT" | head -n1; }
JPG="$(jpval JP_GATE)"; JPF="$(jpval JP_FSGROUP)"; JPV="$(jpval JP_VOLSECRET)"
if [ -z "$JPG" ] || [ -z "$JPF" ] || [ -z "$JPV" ]; then
  bad "could not read the JP_* constants out of the script"
elif ! command -v kubectl >/dev/null 2>&1; then
  skip "kubectl is not installed: jsonpath not cross-checked against the real evaluator"
else
  while IFS=$'\t' read -r dir name ns gate vol _; do
    kubectl kustomize "${MAN}/${dir}" >"$W/k.yaml" 2>"$W/k.err" || { bad "$name: kubectl kustomize failed: $(head -c 200 "$W/k.err")"; continue; }
    python3 -I - "$W/k.yaml" "$W/dep.yaml" <<'PY'
import sys
docs = open(sys.argv[1], encoding="utf-8").read().split("\n---\n")
open(sys.argv[2], "w", encoding="utf-8").write([d for d in docs if "kind: Deployment" in d][0])
PY
    got="$(kubectl label --local --dry-run=client -f "$W/dep.yaml" zz=1 -o "jsonpath=${JPG}|${JPF}|${JPV}" 2>"$W/k.err")"
    if [ "$got" = "${gate}|70|${name}-mtls" ]; then ok "$name: real kubectl reads gate=${gate} fsGroup=70 volume=${name}-mtls"
    else bad "$name: real kubectl read '$got' (want ${gate}|70|${name}-mtls) $(head -c 150 "$W/k.err")"; fi
  done <"$W/derived.tsv"
fi

# ─── B. behaviour against a stub kubectl ──────────────────────────────────────
echo "-- B. behaviour (stub kubectl, real openssl certificates)"

cat >"$W/kubectl" <<'PY'
#!/usr/bin/env python3
# Stub kubectl serving JSON fixtures from $FIX. Implements exactly the verbs the
# preflight uses, with a small jsonpath evaluator (dotted paths, \. escapes,
# [N] and [?(@.f=="v")] filters).
import json, os, re, sys
fix = os.environ["FIX"]
args = sys.argv[1:]
with open(os.path.join(fix, "argv.log"), "a") as f:
    f.write(" ".join(args) + "\n")
if os.environ.get("FIX_FAIL_ALL"):
    sys.stderr.write("The connection to the server was refused\n"); sys.exit(1)
if args[:1] == ["--context"]:
    args = args[2:]
verb = args[0]
def opt(flag):
    return args[args.index(flag) + 1] if flag in args else None
ns = opt("-n")
def jsonpath(doc, expr):
    expr = expr.strip()
    assert expr.startswith("{") and expr.endswith("}"), expr
    toks = re.findall(r'\.((?:\\\.|[^.\[\]])+)|\[(\d+)\]|\[\?\(@\.(\w+)=="([^"]*)"\)\]', expr[1:-1])
    cur = [doc]
    for name, idx, ff, fv in toks:
        nxt = []
        for c in cur:
            if name:
                k = name.replace("\\.", ".")
                if isinstance(c, dict) and k in c: nxt.append(c[k])
            elif idx:
                if isinstance(c, list) and int(idx) < len(c): nxt.append(c[int(idx)])
            else:
                if isinstance(c, list): nxt.extend(x for x in c if isinstance(x, dict) and x.get(ff) == fv)
        cur = nxt
    return " ".join(str(x) for x in cur)
if verb == "get":
    kind, name = args[1], args[2]
    p = os.path.join(fix, kind, ns, name + ".json")
    if not os.path.exists(p):
        sys.stderr.write('Error from server (NotFound): %ss "%s" not found\n' % (kind, name)); sys.exit(1)
    doc = json.load(open(p))
    out = opt("-o")
    assert out.startswith("jsonpath="), out
    sys.stdout.write(jsonpath(doc, out[len("jsonpath="):])); sys.exit(0)
if verb == "logs":
    name = args[1].split("/", 1)[1]
    p = os.path.join(fix, "logs", ns, name + ".txt")
    if not os.path.exists(p):
        sys.stderr.write("Error from server (NotFound): pods not found\n"); sys.exit(1)
    sys.stdout.write(open(p).read()); sys.exit(0)
if verb == "exec":
    name = args[args.index("--") - 1].split("/", 1)[1]
    p = os.path.join(fix, "exec", ns, name + ".txt")
    if not os.path.exists(p):
        sys.stderr.write("error: unable to exec\n"); sys.exit(1)
    sys.stdout.write(open(p).read()); sys.exit(0)
sys.stderr.write("stub kubectl: unsupported verb %s\n" % verb); sys.exit(64)
PY
chmod +x "$W/kubectl"

# Certificates: one CA, one foreign CA, a leaf per DB.
CA="$W/pki"; mkdir -p "$CA"
mkca(){ # name
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -keyout "$CA/$1.key" -out "$CA/$1.crt" -subj "/CN=test $1" >/dev/null 2>&1; }
mkleaf(){ # db ns outprefix signer days [san-override] [eku-override; empty = no EKU extension]
  local db="$1" ns="$2" out="$3" signer="$4" days="$5" san eku
  san="${6-DNS:${db},DNS:${db}.${ns},DNS:${db}.${ns}.svc.cluster.local}"
  eku="${7-serverAuth,clientAuth}"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$out.key" -out "$out.csr" -subj "/CN=${db}.${ns}.svc.cluster.local" >/dev/null 2>&1
  { [ -n "$san" ] && echo "subjectAltName=$san"; [ -n "$eku" ] && echo "extendedKeyUsage=$eku"; true; } >"$out.ext"
  openssl x509 -req -in "$out.csr" -CA "$CA/$signer.crt" -CAkey "$CA/$signer.key" -CAcreateserial \
    -days "$days" -extfile "$out.ext" -out "$out.crt" >/dev/null 2>&1; }
mkca ca; mkca foreign
[ -s "$CA/ca.crt" ] && [ -s "$CA/foreign.crt" ] && ok "minted the test CAs" || bad "could not mint test CAs"

FIX="$W/fix"
b64(){ base64 -w0 <"$1"; }
while read -r db ns; do
  mkleaf "$db" "$ns" "$CA/$db" ca 365
done <"$W/list.txt"

gen_fixtures(){ # builds a fully GOOD fleet under $FIX
  rm -rf "$FIX"; mkdir -p "$FIX"
  python3 -I - "$W/list.txt" "$FIX" "$CA" <<'PY'
import base64, json, os, sys
lst, fix, ca = sys.argv[1:4]
def b(p): return base64.b64encode(open(p, "rb").read()).decode()
def put(kind, ns, name, doc):
    d = os.path.join(fix, kind, ns); os.makedirs(d, exist_ok=True)
    json.dump(doc, open(os.path.join(d, name + ".json"), "w"))
for line in open(lst):
    db, ns = line.split()
    sec = db + "-mtls"
    put("deployment", ns, db, {
        "metadata": {"name": db},
        "spec": {"template": {"spec": {
            "securityContext": {"fsGroup": 70},
            "containers": [{"name": "postgres", "env": [
                {"name": "POSTGRES_DB", "value": "x"},
                {"name": "PG_TLS_ENABLED", "value": "false"}]}],
            "volumes": [{"name": "data"}, {"name": "pg-tls", "secret": {"secretName": sec, "optional": True}}]}}},
        "status": {"readyReplicas": 1}})
    put("externalsecret", ns, sec, {"metadata": {"name": sec},
        "status": {"conditions": [{"type": "Ready", "status": "True"}]}})
    put("secret", ns, sec, {"metadata": {"name": sec}, "type": "kubernetes.io/tls",
        "data": {"tls.crt": b(os.path.join(ca, db + ".crt")), "tls.key": b(os.path.join(ca, db + ".key")),
                 "ca.crt": b(os.path.join(ca, "ca.crt"))}})
PY
}

# fxmod KIND NS NAME 'python statements on d'
fxmod(){
  python3 -I - "$FIX/$1/$2/$3.json" "$4" <<'PY'
import json, sys
p, code = sys.argv[1], sys.argv[2]
d = json.load(open(p)); exec(code); json.dump(d, open(p, "w"))
PY
}
# set a Secret key from a file: fxsec NS DB KEY FILE
fxsec(){ python3 -I - "$FIX/secret/$1/$2-mtls.json" "$3" "$4" <<'PY'
import base64, json, sys
p, k, f = sys.argv[1:4]
d = json.load(open(p)); d["data"][k] = base64.b64encode(open(f, "rb").read()).decode(); json.dump(d, open(p, "w"))
PY
}

RC=0; OUT=""
run(){ # run SCRIPT args... -> RC, OUT (stdout+stderr)
  local s="$1"; shift
  OUT="$(KUBECTL="$W/kubectl" FIX="$FIX" TMPDIR="$W" bash "$s" "$@" 2>&1)"; RC=$?
}
expect(){ # expect NAME WANT_RC [grep-pattern]
  local name="$1" want="$2" pat="${3-}"
  if [ "$RC" -ne "$want" ]; then bad "$name: exit $RC, wanted $want"; printf '%s\n' "$OUT" | grep -E "FAIL|UNVER|READY|OK:" | head -8 | sed 's/^/        /'; return 1; fi
  if [ -n "$pat" ] && ! grep -qE -e "$pat" <<<"$OUT"; then
    bad "$name: exit $RC but output lacks /$pat/"; return 1; fi
  ok "$name: exit $RC${pat:+, output has /$pat/}"; return 0
}
only_fails(){ # only_fails NAME DB — the FAIL lines must all sit under DB's heading
  local name="$1" db="$2" bad_lines
  bad_lines="$(printf '%s\n' "$OUT" | awk -v want="$db" '/^-- /{cur=$2} /^  FAIL/{ if (cur!=want) print cur": "$0 }')"
  if [ -z "$bad_lines" ]; then ok "$name: only $db is reported as failing"
  else bad "$name: failures leaked onto other DBs:"; printf '%s\n' "$bad_lines" | sed 's/^/        /'; fi
}
DB=wiki-bff-db; NS=hugmesh-backend

gen_fixtures
run "$SCRIPT"
expect "good fleet, all nine" 0 "READY: every selected DB"
grep -q "9 DB(s)" <<<"$OUT" && ok "ran all nine DBs by default" || bad "did not run nine DBs by default"
for pat in 'BEGIN' 'PRIVATE KEY' "$(b64 "$CA/$DB.key" | cut -c60-110)"; do
  if grep -qF -e "$pat" <<<"$OUT"; then bad "output leaked key/cert material ($pat)"; else ok "output carries no '${pat:0:14}...'"; fi
done

run "$SCRIPT" --db route-access-db --context some-ctx
expect "single DB with --context" 0 "1 DB\(s\)"
grep -q -e "--context some-ctx" "$FIX/argv.log" && ok "--context reached kubectl" || bad "--context was not passed to kubectl"

run "$SCRIPT" --db no-such-db;            expect "unknown --db is a usage error" 2 "unknown DB"
run "$SCRIPT" --bogus;                    expect "unknown flag is a usage error" 2 "unknown argument"
run "$SCRIPT" --min-days x;               expect "non-numeric --min-days is a usage error" 2
OUT="$(KUBECTL="$W/does-not-exist" bash "$SCRIPT" 2>&1)"; RC=$?
expect "missing kubectl is exit 2, not a pass" 2 "not on PATH"

# 1. the Secret does not exist yet — THE case the script exists for
gen_fixtures; rm -f "$FIX/secret/$NS/$DB-mtls.json"
run "$SCRIPT" --db $DB;  expect "Secret absent" 1 "does not exist"
run "$SCRIPT";           expect "Secret absent in one of nine" 1 "NOT READY"; only_fails "Secret absent" $DB

# 2. ESO says not ready
gen_fixtures; fxmod externalsecret $NS $DB-mtls 'd["status"]["conditions"][0]["status"]="False"'
run "$SCRIPT"; expect "ExternalSecret Ready=False" 1 "Ready='False'"; only_fails "ES not ready" $DB
gen_fixtures; rm -f "$FIX/externalsecret/$NS/$DB-mtls.json"
run "$SCRIPT"; expect "ExternalSecret object absent" 1 "externalsecret/$DB-mtls not readable"; only_fails "ES absent" $DB

# 3. Secret shape
gen_fixtures; fxmod secret $NS $DB-mtls 'd["data"]["tls.key"]=""'
run "$SCRIPT"; expect "empty tls.key" 1 "key tls.key is missing or empty"; only_fails "empty key" $DB
gen_fixtures; fxmod secret $NS $DB-mtls 'del d["data"]["ca.crt"]'
run "$SCRIPT"; expect "ca.crt key absent" 1 "key ca.crt is missing or empty"; only_fails "no ca" $DB
gen_fixtures; fxmod secret $NS $DB-mtls 'd["type"]="Opaque"'
run "$SCRIPT"; expect "wrong Secret type" 1 "want kubernetes.io/tls"; only_fails "type" $DB
gen_fixtures; fxmod secret $NS $DB-mtls 'd["data"]["tls.crt"]="!!notbase64!!"'
run "$SCRIPT"; expect "garbage in tls.crt" 1 "not valid base64"; only_fails "garbage" $DB
gen_fixtures; printf 'not a certificate\n' >"$W/junk.pem"; fxsec $NS $DB tls.crt "$W/junk.pem"
run "$SCRIPT"; expect "tls.crt that is not X.509" 1 "does not parse"; only_fails "junk cert" $DB

# 4. certificate content
mkleaf $DB $NS "$W/short" ca 3
gen_fixtures; fxsec $NS $DB tls.crt "$W/short.crt"; fxsec $NS $DB tls.key "$W/short.key"
run "$SCRIPT"; expect "cert expiring in 3 days (default floor 14)" 1 "expires inside 14 days"; only_fails "expiring" $DB
run "$SCRIPT" --db $DB --min-days 2; expect "same cert passes with --min-days 2" 0 "READY"
mkleaf $DB $NS "$W/nosan" ca 365 ""
gen_fixtures; fxsec $NS $DB tls.crt "$W/nosan.crt"; fxsec $NS $DB tls.key "$W/nosan.key"
run "$SCRIPT"; expect "cert with no SAN" 1 "SAN does not cover"; only_fails "no SAN" $DB
mkleaf $DB $NS "$W/partsan" ca 365 "DNS:${DB}"
gen_fixtures; fxsec $NS $DB tls.crt "$W/partsan.crt"; fxsec $NS $DB tls.key "$W/partsan.key"
run "$SCRIPT"; expect "cert missing the FQDN SAN" 1 "SAN does not cover ${DB}.${NS}.svc.cluster.local"
mkleaf $DB $NS "$W/clientonly" ca 365 "DNS:${DB},DNS:${DB}.${NS},DNS:${DB}.${NS}.svc.cluster.local" "clientAuth"
gen_fixtures; fxsec $NS $DB tls.crt "$W/clientonly.crt"; fxsec $NS $DB tls.key "$W/clientonly.key"
run "$SCRIPT"; expect "cert whose EKU is clientAuth only" 1 "EKU present but lacks"; only_fails "client-only EKU" $DB
mkleaf $DB $NS "$W/noeku" ca 365 "DNS:${DB},DNS:${DB}.${NS},DNS:${DB}.${NS}.svc.cluster.local" ""
gen_fixtures; fxsec $NS $DB tls.crt "$W/noeku.crt"; fxsec $NS $DB tls.key "$W/noeku.key"
run "$SCRIPT" --db $DB; expect "cert with NO EKU extension is accepted" 0 "no EKU restriction"
gen_fixtures; fxsec $NS $DB tls.key "$CA/mesh-bff-db.key"
run "$SCRIPT"; expect "key from a different cert" 1 "does not match"; only_fails "key mismatch" $DB
mkleaf $DB $NS "$W/foreign" foreign 365
gen_fixtures; fxsec $NS $DB tls.crt "$W/foreign.crt"; fxsec $NS $DB tls.key "$W/foreign.key"
run "$SCRIPT"; expect "cert issued by a CA that is not ca.crt" 1 "does not verify against ca.crt"; only_fails "foreign CA" $DB

# 5. the Deployment is not as the flip assumes
gen_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["securityContext"]["fsGroup"]=0'
run "$SCRIPT"; expect "fsGroup 0" 1 "cannot read the 0600 tls.key"; only_fails "fsGroup" $DB
gen_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["volumes"][1]["secret"]["secretName"]="other-mtls"'
run "$SCRIPT"; expect "pg-tls volume names another Secret" 1 "want ${DB}-mtls"; only_fails "volume" $DB
gen_fixtures; fxmod deployment $NS $DB 'd["status"]["readyReplicas"]=0'
run "$SCRIPT"; expect "DB not ready before the flip" 1 "readyReplicas='0'"; only_fails "not ready" $DB
gen_fixtures; fxmod deployment $NS $DB 'del d["status"]["readyReplicas"]'
run "$SCRIPT"; expect "readyReplicas absent (scaled to 0)" 1 "readyReplicas=''"
gen_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["containers"][0]["env"][1]["value"]="maybe"'
run "$SCRIPT"; expect "gate holds an unexpected value" 1 "PG_TLS_ENABLED is 'maybe'"; only_fails "gate" $DB
gen_fixtures; rm -f "$FIX/deployment/$NS/$DB.json"
run "$SCRIPT"; expect "Deployment absent" 1 "not readable"; only_fails "deployment absent" $DB
gen_fixtures; fxmod deployment $NS $DB 'd["metadata"]["name"]="some-other-deployment"'
run "$SCRIPT"; expect "Deployment answers under another name" 1 "not readable"; only_fails "deployment name" $DB
gen_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["containers"][0]["env"][1]["value"]="true"'
run "$SCRIPT" --db $DB; expect "gate already true is reported, not an error" 0 "already \"true\""

# 6. fail closed
gen_fixtures
OUT="$(FIX_FAIL_ALL=1 KUBECTL="$W/kubectl" FIX="$FIX" TMPDIR="$W" bash "$SCRIPT" 2>&1)"; RC=$?
expect "kubectl that errors on everything" 1 "NOT READY"
[ "$(printf '%s\n' "$OUT" | grep -c '^  PASS')" = "0" ] && ok "an erroring kubectl yields zero PASS lines" || bad "PASS lines appeared under an erroring kubectl"

# 7. openssl absent -> UNVERIFIED, and a real failure still wins
mkdir -p "$W/nobin"
for t in bash sh python3 base64 tr cut mktemp rm chmod cat sed awk grep dirname head wc mkdir; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$W/nobin/$t"
done
gen_fixtures
OUT="$(PATH="$W/nobin" KUBECTL="$W/kubectl" FIX="$FIX" TMPDIR="$W" "$W/nobin/bash" "$SCRIPT" 2>&1)"; RC=$?
expect "no openssl: good fleet is UNVERIFIED, not READY" 3 "UNVERIFIED"
grep -q "READY: every" <<<"$OUT" && bad "claimed READY without openssl" || ok "did not claim READY without openssl"
rm -f "$FIX/secret/$NS/$DB-mtls.json"
OUT="$(PATH="$W/nobin" KUBECTL="$W/kubectl" FIX="$FIX" TMPDIR="$W" "$W/nobin/bash" "$SCRIPT" 2>&1)"; RC=$?
expect "no openssl AND a missing Secret: the failure wins (1)" 1 "NOT READY"

# 8. --post
post_fixtures(){
  gen_fixtures
  while read -r db ns; do
    fxmod deployment "$ns" "$db" 'd["spec"]["template"]["spec"]["containers"][0]["env"][1]["value"]="true"'
    mkdir -p "$FIX/logs/$ns" "$FIX/exec/$ns"
    printf 'boot\n%s: PG_TLS_ENABLED=true -> Postgres ssl=on (serving TLS from /etc/postgres-tls)\nready\n' "$db" >"$FIX/logs/$ns/$db.txt"
    printf ' on\n' >"$FIX/exec/$ns/$db.txt"
  done <"$W/list.txt"
}
post_fixtures; run "$SCRIPT" --post
expect "--post on a flipped fleet" 0 "OK: TLS is live"
post_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["containers"][0]["env"][1]["value"]="false"'
run "$SCRIPT" --post; expect "--post, gate still false" 1 "has not synced"; only_fails "post gate" $DB
post_fixtures; printf 'boot\n%s: PG_TLS_ENABLED=false -> ssl off\n' "$DB" >"$FIX/logs/$NS/$DB.txt"
run "$SCRIPT" --post; expect "--post, wrapper did not log ssl=on" 1 "did not log"; only_fails "post log" $DB
post_fixtures; printf 'PostgreSQL init process complete; ready for start up.\n%s: starting Postgres with defaults\n' "$DB" >"$FIX/logs/$NS/$DB.txt"
run "$SCRIPT" --post; expect "--post, log mentions Postgres but not the wrapper's marker" 1 "did not log"; only_fails "post marker" $DB
post_fixtures; printf 'off\n' >"$FIX/exec/$NS/$DB.txt"
run "$SCRIPT" --post; expect "--post, show ssl = off" 1 "show ssl='off'"; only_fails "post ssl" $DB
post_fixtures; rm -f "$FIX/exec/$NS/$DB.txt"
run "$SCRIPT" --post; expect "--post, exec unavailable" 1 "show ssl="; only_fails "post exec" $DB

# 9. the scratch directory holds the private key: it must be gone after the run, on a
#    pass, on a fail and on an early exit
leftovers(){ ls -d "$W"/pg-tls-preflight.* 2>/dev/null | wc -l | tr -d ' '; }
rm -rf "$W"/pg-tls-preflight.*
gen_fixtures; run "$SCRIPT"
[ "$(leftovers)" = "0" ] && ok "no pg-tls-preflight.* scratch directory is left behind after a passing run" || { bad "a passing run left $(leftovers) scratch dir(s) holding key material"; rm -rf "$W"/pg-tls-preflight.*; }
gen_fixtures; rm -f "$FIX/secret/$NS/$DB-mtls.json"; run "$SCRIPT"
[ "$(leftovers)" = "0" ] && ok "no scratch directory is left behind after a failing run" || { bad "a failing run left $(leftovers) scratch dir(s)"; rm -rf "$W"/pg-tls-preflight.*; }
run "$SCRIPT" --db no-such-db
[ "$(leftovers)" = "0" ] && ok "no scratch directory is left behind after a usage error" || { bad "a usage error left $(leftovers) scratch dir(s)"; rm -rf "$W"/pg-tls-preflight.*; }

# ─── C. mutation battery ──────────────────────────────────────────────────────
echo "-- C. mutation battery (each mutation must change the file AND be caught)"
KILLED=0; SURV=0
mutate(){ # mutate NAME OLD NEW SCENARIO WANT_RC [OLD2 NEW2] — the scenario sets up fixtures
  local name="$1" old="$2" new="$3" scen="$4" want="$5" m="$W/mut.sh"
  python3 -I - "$SCRIPT" "$m" "$old" "$new" "${6-}" "${7-}" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
pairs = [(sys.argv[3], sys.argv[4])]
if sys.argv[5]:
    pairs.append((sys.argv[5], sys.argv[6]))
for old, new in pairs:
    if src.count(old) != 1:
        sys.exit(7)
    src = src.replace(old, new)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
  local prc=$?
  if [ "$prc" -ne 0 ]; then bad "mutation '$name': the target text occurs $( [ $prc -eq 7 ] && echo 'not exactly once' || echo '?') — the mutation does not apply"; SURV=$((SURV+1)); return; fi
  cmp -s "$SCRIPT" "$m" && { bad "mutation '$name' did not change the file"; SURV=$((SURV+1)); return; }
  "$scen"
  rm -rf "$W"/pg-tls-preflight.*
  run "$m" $MUT_ARGS
  if [ "$want" = "LEFTOVER" ]; then   # caught iff the scratch directory with the key survives the run
    local left; left="$(leftovers)"; rm -rf "$W"/pg-tls-preflight.*
    if [ "$left" -gt 0 ]; then ok "mutation '$name' caught ($left scratch dir left behind)"; KILLED=$((KILLED+1))
    else bad "mutation '$name' SURVIVED (no scratch dir left behind)"; SURV=$((SURV+1)); fi
    return
  fi
  if [ "$RC" -eq "$want" ]; then
    bad "mutation '$name' SURVIVED (exit $RC, the unmutated script gives something else)"; SURV=$((SURV+1))
  else ok "mutation '$name' caught (exit $RC)"; KILLED=$((KILLED+1)); fi
}
MUT_ARGS=""
s_nosecret(){ gen_fixtures; rm -f "$FIX/secret/$NS/$DB-mtls.json"; MUT_ARGS="--db $DB"; }
s_esfalse(){ gen_fixtures; fxmod externalsecret $NS $DB-mtls 'd["status"]["conditions"][0]["status"]="False"'; MUT_ARGS="--db $DB"; }
s_type(){ gen_fixtures; fxmod secret $NS $DB-mtls 'd["type"]="Opaque"'; MUT_ARGS="--db $DB"; }
s_expiring(){ gen_fixtures; fxsec $NS $DB tls.crt "$W/short.crt"; fxsec $NS $DB tls.key "$W/short.key"; MUT_ARGS="--db $DB"; }
s_nosan(){ gen_fixtures; fxsec $NS $DB tls.crt "$W/nosan.crt"; fxsec $NS $DB tls.key "$W/nosan.key"; MUT_ARGS="--db $DB"; }
s_keymis(){ gen_fixtures; fxsec $NS $DB tls.key "$CA/mesh-bff-db.key"; MUT_ARGS="--db $DB"; }
s_foreign(){ gen_fixtures; fxsec $NS $DB tls.crt "$W/foreign.crt"; fxsec $NS $DB tls.key "$W/foreign.key"; MUT_ARGS="--db $DB"; }
s_fsgroup(){ gen_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["securityContext"]["fsGroup"]=0'; MUT_ARGS="--db $DB"; }
s_volume(){ gen_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["volumes"][1]["secret"]["secretName"]="other-mtls"'; MUT_ARGS="--db $DB"; }
s_notready(){ gen_fixtures; fxmod deployment $NS $DB 'd["status"]["readyReplicas"]=0'; MUT_ARGS="--db $DB"; }
s_gate(){ gen_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["containers"][0]["env"][1]["value"]="maybe"'; MUT_ARGS="--db $DB"; }
s_postlog(){ post_fixtures; printf 'boot\n' >"$FIX/logs/$NS/$DB.txt"; MUT_ARGS="--post --db $DB"; }
s_postssl(){ post_fixtures; printf 'off\n' >"$FIX/exec/$NS/$DB.txt"; MUT_ARGS="--post --db $DB"; }
s_postgate(){ post_fixtures; fxmod deployment $NS $DB 'd["spec"]["template"]["spec"]["containers"][0]["env"][1]["value"]="false"'; MUT_ARGS="--post --db $DB"; }
s_unknown(){ gen_fixtures; MUT_ARGS="--db no-such-db"; }
s_good(){ gen_fixtures; MUT_ARGS="--db $DB"; }
s_clientonly(){ gen_fixtures; fxsec $NS $DB tls.crt "$W/clientonly.crt"; fxsec $NS $DB tls.key "$W/clientonly.key"; MUT_ARGS="--db $DB"; }
s_postmarker(){ post_fixtures; printf 'PostgreSQL init process complete; ready for start up.\n%s: starting Postgres with defaults\n' "$DB" >"$FIX/logs/$NS/$DB.txt"; MUT_ARGS="--post --db $DB"; }
s_depname(){ gen_fixtures; fxmod deployment $NS $DB 'd["metadata"]["name"]="some-other-deployment"'; MUT_ARGS="--db $DB"; }

mutate "a missing Secret is not a failure" \
  'fail "secret/$sec does not exist in $ns — flipping now would crash-loop the DB ($(why))"' \
  'pass "secret/$sec does not exist in $ns"' s_nosecret 1
mutate "ES Ready is not required" \
  'elif [ "$out" = "True" ]; then pass "externalsecret/$sec Ready=True"' \
  'elif [ "$out" != "" ]; then pass "externalsecret/$sec Ready=True"' s_esfalse 1
# (No mutation for the empty-key guard: an empty tls.key is rejected by THREE
# independent checks -- the empty test, the base64/size test and the key-match
# test -- so deleting any one leaves the verdict unchanged. Section B above pins
# the explicit message instead.)
mutate "Secret type not enforced" \
  'if [ "$out" = "kubernetes.io/tls" ]; then pass' \
  'if [ -n "$out" ]; then pass' s_type 1
mutate "expiry floor removed" \
  '-checkend $((MIN_DAYS * 86400))' '-checkend 0' s_expiring 1
mutate "SAN requirement dropped" \
  '*)                           fail "SAN does not cover $want" ;;' \
  '*)                           pass "SAN covers $want" ;;' s_nosan 1
mutate "key/cert match dropped" \
  'if [ -n "$a" ] && [ "$a" = "$b" ]; then' 'if true; then' s_keymis 1
mutate "chain check dropped" \
  'if openssl verify -partial_chain -CAfile "$ca" "$crt" >/dev/null 2>&1; then' 'if true; then' s_foreign 1
mutate "fsGroup compare dropped" \
  'if [ $rc -eq 0 ] && [ "$out" = "$PG_UID_GROUP" ]; then' 'if true; then' s_fsgroup 1
mutate "volume name compare dropped" \
  'if [ $rc -eq 0 ] && [ "$out" = "${db}-mtls" ]; then' 'if true; then' s_volume 1
mutate "readiness requirement dropped" \
  'if [ $rc -eq 0 ] && [ "$out" = "1" ]; then pass' 'if true; then pass' s_notready 1
mutate "unexpected gate value tolerated" \
  '*)     fail "PG_TLS_ENABLED is' '*)     info "PG_TLS_ENABLED is' s_gate 1
mutate "a failure no longer sets a failing exit" \
  '  echo "NOT READY: do not flip PG_TLS_ENABLED for the DB(s) above."
  exit 1' \
  '  echo "NOT READY: do not flip PG_TLS_ENABLED for the DB(s) above."
  exit 0' s_nosecret 1
mutate "fail() stops counting" \
  'fail(){ echo "  FAIL $*"; FAIL=$((FAIL+1)); }' 'fail(){ echo "  FAIL $*"; }' s_nosecret 1
mutate "post: wrapper log not required" \
  '*)           fail "wrapper did not log' '*)           pass "wrapper did not log' s_postlog 1
mutate "post: show ssl not required" \
  'if [ $rc -eq 0 ] && [ "$out" = "on" ]; then pass' 'if true; then pass' s_postssl 1
mutate "post: live gate not required" \
  'if [ "$out" = "true" ]; then pass "live PG_TLS_ENABLED is \"true\""' 'if true; then pass "live PG_TLS_ENABLED is \"true\""' s_postgate 1
mutate "unknown DB no longer a usage error" \
  'done))" >&2; exit 2; }' 'done))" >&2; }' s_unknown 2
mutate "EKU without server auth tolerated" \
  '*) fail "EKU present but lacks TLS Web Server Authentication" ;; esac' \
  '*) pass "EKU present but lacks TLS Web Server Authentication" ;; esac' s_clientonly 1
mutate "post marker weakened to the word Postgres" \
  "MARKER='PG_TLS_ENABLED=true -> Postgres ssl=on'" "MARKER='Postgres'" s_postmarker 1
mutate "deployment name answer not compared" \
  'if [ $rc -ne 0 ] || [ "$out" != "$db" ]; then' 'if [ $rc -ne 0 ]; then' s_depname 1
mutate "the key scratch directory is not removed on exit" \
  "trap 'rm -rf \"\$WORK\"' EXIT" "trap ':' EXIT" s_good LEFTOVER
# control: the unmutated script on the same unmutated scenario is GREEN, so the
# battery above is not catching a harness that is red for another reason
s_good; run "$SCRIPT" $MUT_ARGS
expect "control: unmutated script, good fleet, single DB" 0 "READY"

echo "-- mutations: ${KILLED} caught, ${SURV} survived"
[ "$SURV" -eq 0 ] || bad "${SURV} mutation(s) survived"

echo "== pg-tls preflight: ${P} passed, ${F} failed, ${S} skipped =="
[ "$F" -eq 0 ] || exit 1
exit 0
