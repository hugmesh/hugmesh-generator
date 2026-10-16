#!/usr/bin/env bash
# =============================================================================
# test-tuwunel-instance-block-sync.sh — the Matrix instance-block reconciler
# (hugmesh-generator#564): the config-edit script embedded in
# manifests/tuwunel/instance-block-sync-job.yaml, and the manifest around it.
#
# Offline: python3 (PyYAML, tomllib) and bash; kubectl is optional (its legs SKIP
# loudly without it). The script under test is EXTRACTED from the manifest, so a
# test cannot pass against a copy that is not the shipped one.
#
# WHAT THIS PINS
#   1. The edit against the REAL tuwunel-config toml: the key lands inside
#      [global] (not in [global.well_known], which the file requires to stay last),
#      exactly one line is added and none is removed or changed.
#   2. Each entry is an anchored, escaped regex (tuwunel reads the key as a
#      RegexSet): it matches the blocked host and not a look-alike or a suffix.
#   3. Idempotent: a second run over its own output changes nothing.
#   4. Additive: operator-written entries, in a multi-line array with a comment,
#      survive in value and order (the array becomes one line); an empty approved list changes nothing.
#   5. Refusals (exit 2, no output file): a malformed name, an IP, a port, a regex
#      smuggled in as a name, this server's own name in any spelling.
#   6. A missing approved file means nothing approved, not an error.
#   7. The manifest: dark (not in the tuwunel kustomization, and the shipped
#      kustomization renders none of it), renders under kustomize, and the Job holds
#      no Secret, no ServiceAccount token, a read-only root and no capabilities.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
MAN="${REPO}/specs/cluster/manifests/tuwunel"
JOB="${MAN}/instance-block-sync-job.yaml"

P=0; F=0; S=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
skip(){ echo "  SKIP $*"; S=$((S+1)); }

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
python3 -I -c 'import yaml, tomllib' 2>/dev/null || { echo "  FAIL python3 needs PyYAML and tomllib (3.11+)"; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/test-tuwunel-instance-block-sync.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

echo "== tuwunel instance-block reconciler =="

# --- extract the shipped script and the shipped config -----------------------
python3 -I - "$JOB" "${MAN}/tuwunel.yaml" "$W" <<'PY' || { echo "  FAIL cannot extract the script/config"; exit 2; }
import sys, yaml
job, tuw, w = sys.argv[1:]
for d in yaml.safe_load_all(open(job)):
    if d and d["kind"] == "ConfigMap":
        open(w + "/sync.py", "w").write(d["data"]["sync.py"])
for d in yaml.safe_load_all(open(tuw)):
    if d and d["kind"] == "ConfigMap" and d["metadata"]["name"] == "tuwunel-config":
        open(w + "/real.toml", "w").write(d["data"]["tuwunel.toml"])
PY
[ -s "$W/sync.py" ] && [ -s "$W/real.toml" ] || { echo "  FAIL extraction produced an empty file"; exit 2; }

SYNC="$W/sync.py"
run(){ python3 -I "$SYNC" "$@"; }

printf 'evil.example\nBad.Example.\n# a comment\n\nbad.example\n' > "$W/approved.txt"

# --- 1. the real config ------------------------------------------------------
run "$W/real.toml" "$W/approved.txt" --out "$W/real.out" > "$W/real.diff" 2> "$W/real.err"; rc=$?
[ "$rc" = 0 ] && ok "1 real config: exit 0" || bad "1 real config: exit $rc: $(head -c 300 "$W/real.err")"
python3 -I - "$W/real.toml" "$W/real.out" <<'PY' && ok "1 key lands in [global], well_known intact, one added line only" || bad "1 placement"
import sys, tomllib
old, new = (open(p).read() for p in sys.argv[1:3])
o, n = tomllib.loads(old), tomllib.loads(new)
key = "forbidden_remote_server_names"
assert n["global"][key] == [r"^bad\.example$", r"^evil\.example$"], n["global"].get(key)
assert key not in n["global"]["well_known"]
assert n["global"]["well_known"] == o["global"]["well_known"]
n["global"].pop(key)
assert n == o, "something other than the key changed"
ol, nl = old.splitlines(), new.splitlines()
assert len(nl) == len(ol) + 1
assert [l for l in nl if l not in ol] == [l for l in nl if l.startswith(key)] and len([l for l in ol if l not in nl]) == 0
PY

# --- 2. anchored + escaped ---------------------------------------------------
python3 -I - "$W/real.out" <<'PY' && ok "2 patterns are anchored and escaped" || bad "2 patterns"
import re, sys, tomllib
rx = [re.compile(p) for p in tomllib.loads(open(sys.argv[1]).read())["global"]["forbidden_remote_server_names"]]
hit = lambda h: any(r.search(h) for r in rx)
assert hit("evil.example") and hit("bad.example")
for h in ("notevil.example", "evil.example.org", "evilXexample", "xevil.example", "evil.examples"):
    assert not hit(h), h
PY

# --- 3. idempotent -----------------------------------------------------------
run "$W/real.out" "$W/approved.txt" --out "$W/real.out2" > "$W/idem.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && cmp -s "$W/real.out" "$W/real.out2" && grep -q "no change" "$W/idem.out"; then
  ok "3 idempotent: second run is byte-identical and says no change"
else bad "3 idempotent (rc=$rc)"; fi

# --- 4. additive, operator entries survive ------------------------------------
cat > "$W/ops.toml" <<'TOML'
[global]
server_name = "hugmesh.net"
forbidden_remote_server_names = [
  'badserver\.tld$',   # operator entry (the next one has a ] inside a quoted class)
  "[a-z]+\\.spam",
  "badphrase",
]
allow_federation = true

[global.well_known]
client = "https://matrix.hugmesh.net"
TOML
run "$W/ops.toml" "$W/approved.txt" --out "$W/ops.out" > /dev/null 2>"$W/ops.err"; rc=$?
python3 -I - "$W/ops.out" <<'PY' && [ "$rc" = 0 ] && ok "4 operator entries kept, in order, new ones appended" || bad "4 additive (rc=$rc)"
import sys, tomllib
c = tomllib.loads(open(sys.argv[1]).read())
assert c["global"]["forbidden_remote_server_names"] == [
    r"badserver\.tld$", r"[a-z]+\.spam", "badphrase", r"^bad\.example$", r"^evil\.example$"]
assert c["global"]["allow_federation"] is True and c["global"]["well_known"]["client"]
PY
if [ "$(grep -c '^forbidden_remote_server_names = \[.*\]$' "$W/ops.out")" = 1 ] && ! grep '# operator entry' "$W/ops.out" >/dev/null; then
  ok "4 an existing array is rewritten as one line (its inner comment is lost)"
else bad "4 the rewritten array is not one line"; fi
: > "$W/empty.txt"
run "$W/ops.toml" "$W/empty.txt" --out "$W/ops.empty" > "$W/ops.empty.log" 2>&1
if cmp -s "$W/ops.toml" "$W/ops.empty" && grep -q "no change" "$W/ops.empty.log"; then
  ok "4 an empty approved list leaves the config untouched"
else bad "4 empty approved list changed the config"; fi

# --- 5. refusals --------------------------------------------------------------
refuse(){ # name, approved-line, [config]
  rm -f "$W/ref.out"; cfg="${3:-$W/real.toml}"
  printf 'fine.example\n%s\n' "$2" > "$W/ref.txt"
  run "$cfg" "$W/ref.txt" --out "$W/ref.out" > "$W/ref.stdout" 2> "$W/ref.stderr"; rc=$?
  if [ "$rc" = 2 ] && [ ! -e "$W/ref.out" ] && [ ! -s "$W/ref.stdout" ] && grep -q REFUSED "$W/ref.stderr"; then
    ok "5 refuses $1"
  else bad "5 $1: rc=$rc out=$([ -e "$W/ref.out" ] && echo written || echo none) stdout=$(head -c 80 "$W/ref.stdout")"; fi
}
refuse "an underscore name"        'evil_example.com'
refuse "an IPv4 address"           '192.0.2.7'
refuse "a name with a port"        'evil.example:8448'
refuse "a regex posing as a name"  'evil.com$|.*'
refuse "a single label"            'localhost'
refuse "a leading hyphen"          '-evil.example'
refuse "this server's own name"    'hugmesh.net'
refuse "its own name, upper case"  'HUGMESH.NET'
refuse "its own name, trailing dot" 'hugmesh.net.'

# --- 6. missing approved file -------------------------------------------------
run "$W/real.toml" "$W/does-not-exist.txt" --out "$W/miss.out" > "$W/miss.log" 2>&1; rc=$?
if [ "$rc" = 0 ] && cmp -s "$W/real.toml" "$W/miss.out"; then ok "6 a missing approved file means nothing approved"
else bad "6 missing approved file (rc=$rc)"; fi

# --- 7. the manifest ----------------------------------------------------------
if grep -v '^\s*#' "${MAN}/kustomization.yaml" | grep "instance-block-sync" >/dev/null; then
  bad "7 the tuwunel kustomization lists the dark Job"
else ok "7 dark: the tuwunel kustomization does not list the Job"; fi

python3 -I - "$JOB" <<'PY' && ok "7 Job: no Secret, no SA token, non-root, read-only root, caps dropped, mounts read-only" || bad "7 Job hardening"
import sys, yaml, json
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
job = next(d for d in docs if d["kind"] == "Job")
spec = job["spec"]["template"]["spec"]
assert spec["automountServiceAccountToken"] is False
assert "serviceAccountName" not in spec
assert spec["securityContext"]["runAsNonRoot"] is True
text = json.dumps(job)
for forbidden in ("secretName", "secretRef", "secretKeyRef", "envFrom"):
    assert forbidden not in text, forbidden
for c in spec["containers"]:
    sc = c["securityContext"]
    assert sc["readOnlyRootFilesystem"] is True and sc["allowPrivilegeEscalation"] is False
    assert sc["capabilities"]["drop"] == ["ALL"]
    assert all(m.get("readOnly") is True for m in c["volumeMounts"]), c["volumeMounts"]
assert job["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PostSync"
PY

if command -v kubectl >/dev/null 2>&1; then
  mkdir "$W/k" && cp "$JOB" "$W/k/" && printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - instance-block-sync-job.yaml\n' > "$W/k/kustomization.yaml"
  n="$(kubectl kustomize "$W/k" 2>"$W/k.err" | grep -c '^kind: \(Job\|ConfigMap\)$')"
  [ "$n" = 2 ] && ok "7 the Job and its script ConfigMap render under kustomize" || bad "7 kustomize rendered $n of 2 objects: $(head -c 200 "$W/k.err")"
  if kubectl kustomize "$MAN" 2>"$W/k2.err" | grep 'tuwunel-instance-block-sync' >/dev/null; then
    bad "7 the shipped tuwunel kustomization renders the dark Job"
  else ok "7 the shipped tuwunel kustomization renders none of it"; fi
else
  skip "7 kustomize legs (no kubectl in this image)"
fi

echo "== $P passed, $F failed, $S skipped =="
[ "$F" -eq 0 ] || exit 1
exit 0
