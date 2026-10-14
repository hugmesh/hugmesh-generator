#!/usr/bin/env bash
# =============================================================================
# test-netpol-egress-scope.sh — the per-namespace egress cutover path must render,
# must cover tier-egress.yaml exactly once, and the overlay must still ship dark.
#
# THE DEFECT. manifests/networkpolicy-egress/kustomization.yaml told the operator
# to enable the tier egress policies by uncommenting
#     - ../networkpolicy/tier-egress.yaml
# kustomize's default load restrictor refuses a FILE outside the kustomization's
# own directory:
#     security; file '.../networkpolicy/tier-egress.yaml' is not in or below
#     '.../networkpolicy-egress'
# so the manual-sync Application would have gone into a ComparisonError at the
# moment an operator followed the documented step (nothing in this tree sets
# ArgoCD's kustomize.buildOptions). It was also the wrong shape: that file carries
# all five tiers, and the cutover is ONE namespace at a time with `devops` last.
# scripts/netpol-egress-scope.py carves one namespace into a file INSIDE the
# overlay directory, which renders under the default restrictor.
#
# WHAT THIS PINS (offline; python3 stdlib, kubectl optional):
#   1. CONTROL: with the real kubectl, the old documented line is REJECTED with the
#      restrictor error (the premise), and each carved file RENDERS.
#   2. COVERAGE: the five namespaces' carved files together hold every policy in
#      tier-egress.yaml exactly once (nothing dropped, nothing doubled), the
#      backend file carries egress-proxy-egress with its tier-egress, devops
#      carries exactly its own one.
#   3. --with-db-egress: backend gets the five Postgres locks, pki gets
#      route-access-db's, the others get none and no empty file is written.
#   4. USAGE: an unknown namespace, a second namespace and a bare call all exit 2.
#   5. DARK: the shipped overlay still renders ZERO objects, no auto-sync app lists
#      an egress file, and apps/08a still has no `automated:` block.
#   6. MUTATIONS: a namespace filter that is off by one, a dropped separator and a
#      source parser that skips a document are each caught.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
TOOL="${REPO}/scripts/netpol-egress-scope.py"
MAN="${REPO}/specs/cluster/manifests"

P=0; F=0; S=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
skip(){ echo "  SKIP $*"; S=$((S+1)); }

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
[ -f "$TOOL" ] || { echo "  FAIL ${TOOL} is missing"; exit 1; }
HAVE_KUBECTL=1; command -v kubectl >/dev/null 2>&1 || HAVE_KUBECTL=0

W="$(mktemp -d "${TMPDIR:-/tmp}/test-netpol-egress-scope.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

echo "== netpol egress scope: the staged cutover path renders and covers the source =="

# Policies in the source, by (namespace, name), derived independently of the tool.
python3 -I - "$MAN/networkpolicy/tier-egress.yaml" "$MAN/networkpolicy/db-egress.yaml" "$W" <<'PY'
import re, sys
def ids(p):
    out = []
    for d in re.split(r"^---\s*$", open(p, encoding="utf-8").read(), flags=re.M):
        body = "\n".join(l for l in d.splitlines() if not l.lstrip().startswith("#"))
        if not re.search(r"^kind:\s*NetworkPolicy\s*$", body, re.M):
            continue
        n = re.search(r"^  name:\s*(\S+)", body, re.M).group(1)
        s = re.search(r"^  namespace:\s*(\S+)", body, re.M).group(1)
        out.append((s, n))
    return out
for tag, p in (("tier", sys.argv[1]), ("db", sys.argv[2])):
    with open("%s/%s.src" % (sys.argv[3], tag), "w") as f:
        for s, n in sorted(ids(p)):
            f.write("%s %s\n" % (s, n))
PY
NTIER="$(wc -l <"$W/tier.src" | tr -d ' ')"; NDB="$(wc -l <"$W/db.src" | tr -d ' ')"
[ "$NTIER" -ge 5 ] && ok "tier-egress.yaml carries ${NTIER} policies (independent count)" || bad "tier-egress.yaml: only ${NTIER} policies found"
[ "$NDB" -ge 6 ] && ok "db-egress.yaml carries ${NDB} policies (independent count)" || bad "db-egress.yaml: only ${NDB} policies found"

"$TOOL" --list >"$W/ns.list" 2>"$W/ns.err"; RC=$?
[ "$RC" -eq 0 ] && ok "--list exits 0" || bad "--list exited $RC"
cut -d' ' -f1 "$W/tier.src" | sort -u >"$W/ns.src"; sort -u "$W/ns.list" >"$W/ns.got"
cmp -s "$W/ns.src" "$W/ns.got" && ok "--list == the namespaces in tier-egress.yaml ($(wc -l <"$W/ns.got" | tr -d ' '))" \
  || { bad "--list differs from the source namespaces"; diff "$W/ns.src" "$W/ns.got" | sed 's/^/        /'; }
grep -qx "devops" "$W/ns.list" && ok "devops is among them (it is the one that goes LAST)" || bad "devops missing from the namespace list"

kust(){ # kust DIR file... -> writes DIR/kustomization.yaml listing files
  local d="$1"; shift
  { printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n'
    for f in "$@"; do printf '  - %s\n' "$f"; done; } >"$d/kustomization.yaml"
}
names_in(){ # names_in FILE... -> "ns name" lines of the NetworkPolicies inside
  python3 -I - "$@" <<'PY'
import re, sys
for p in sys.argv[1:]:
    for d in re.split(r"^---\s*$", open(p, encoding="utf-8").read(), flags=re.M):
        body = "\n".join(l for l in d.splitlines() if not l.lstrip().startswith("#"))
        if re.search(r"^kind:\s*NetworkPolicy\s*$", body, re.M):
            print(re.search(r"^  namespace:\s*(\S+)", body, re.M).group(1), re.search(r"^  name:\s*(\S+)", body, re.M).group(1))
PY
}

# ─── 1/2. carve every namespace, render it, check coverage ────────────────────
OUT="$W/out"; mkdir -p "$OUT"
while read -r ns; do
  "$TOOL" "$ns" --out "$OUT" >"$W/run.out" 2>&1 || bad "$ns: tool failed: $(head -c 200 "$W/run.out")"
  f="$OUT/tier-egress-${ns}.yaml"
  [ -s "$f" ] || { bad "$ns: no carved file written"; continue; }
  names_in "$f" | sort >"$W/got.$ns"
  grep "^$ns " "$W/tier.src" | sort >"$W/want.$ns"
  if cmp -s "$W/want.$ns" "$W/got.$ns"; then ok "$ns: carved file == the source's policies for $ns ($(wc -l <"$W/got.$ns" | tr -d ' '))"
  else bad "$ns: carved policies differ from the source"; diff "$W/want.$ns" "$W/got.$ns" | sed 's/^/        /'; fi
  if grep -qv "^$ns " "$W/got.$ns"; then bad "$ns: the carved file holds a policy for ANOTHER namespace"; else ok "$ns: nothing from another namespace leaked in"; fi
  if [ "$HAVE_KUBECTL" -eq 1 ]; then
    rd="$W/render.$ns"; mkdir -p "$rd"; cp "$f" "$rd/"; kust "$rd" "tier-egress-${ns}.yaml"
    n="$(kubectl kustomize "$rd" 2>"$W/k.err" | grep -c '^kind: NetworkPolicy')"
    [ "$n" -eq "$(wc -l <"$W/got.$ns" | tr -d ' ')" ] && ok "$ns: renders under the DEFAULT load restrictor ($n NetworkPolicy)" \
      || bad "$ns: kubectl kustomize rendered $n objects: $(head -c 200 "$W/k.err")"
  fi
done <"$W/ns.list"
[ "$HAVE_KUBECTL" -eq 1 ] || skip "kubectl is not installed: carved files not rendered with the real kustomize"

cat "$W"/got.* | sort >"$W/union.got"
if cmp -s "$W/tier.src" "$W/union.got"; then ok "union of the carved files == all of tier-egress.yaml, each policy exactly once"
else bad "union of carved files differs from tier-egress.yaml"; diff "$W/tier.src" "$W/union.got" | sed 's/^/        /'; fi
grep -q "^hugmesh-backend egress-proxy-egress$" "$W/got.hugmesh-backend" && ok "backend carries egress-proxy-egress with its tier policy" || bad "backend lost egress-proxy-egress"
[ "$(wc -l <"$W/got.devops" | tr -d ' ')" = "1" ] && ok "devops carves to exactly one policy" || bad "devops does not carve to exactly one policy"

# CONTROL: the line the old header documented, with the real kustomize.
if [ "$HAVE_KUBECTL" -eq 1 ]; then
  old="$W/old"; mkdir -p "$old/networkpolicy-egress" "$old/networkpolicy"
  cp "$MAN/networkpolicy/tier-egress.yaml" "$old/networkpolicy/"
  kust "$old/networkpolicy-egress" "../networkpolicy/tier-egress.yaml"
  if kubectl kustomize "$old/networkpolicy-egress" >"$W/old.out" 2>"$W/old.err"; then
    bad "CONTROL: the old '../networkpolicy/tier-egress.yaml' line now renders — the premise of this tool changed; re-read the kustomization header"
  elif grep -q "is not in or below" "$W/old.err"; then
    ok "CONTROL: the old documented line is rejected by kustomize ('is not in or below') — the defect this tool routes around is real"
  else bad "CONTROL: the old line failed, but not with the load-restrictor error: $(head -c 200 "$W/old.err")"; fi
fi

# ─── 3. --with-db-egress ──────────────────────────────────────────────────────
echo "-- --with-db-egress"
D="$W/dbout"; mkdir -p "$D"
for ns in hugmesh-backend hugmesh-pki hugmesh-games hugmesh-frontend devops; do
  "$TOOL" "$ns" --with-db-egress --out "$D" >"$W/run.out" 2>&1
  want="$(grep -c "^$ns db-egress-" "$W/db.src")"
  if [ "$want" -gt 0 ]; then
    n="$(names_in "$D/db-egress-${ns}.yaml" 2>/dev/null | grep -c "^$ns db-egress-")"
    [ "$n" = "$want" ] && ok "$ns: --with-db-egress carves $want per-DB lock(s)" || bad "$ns: wanted $want per-DB lock(s), carved $n"
  else
    [ ! -e "$D/db-egress-${ns}.yaml" ] && ok "$ns: no per-DB lock exists, and no empty file was written" || bad "$ns: wrote a db-egress file with nothing in it"
  fi
done
[ "$(grep -c '^hugmesh-backend db-egress-' "$W/db.src")" = "5" ] && ok "source has five backend DB locks (admin-bff, mod-bff, user-bff, federation, forum-bff)" || bad "source backend DB lock count moved off five"
[ "$(grep -c '^hugmesh-pki db-egress-route-access-db$' "$W/db.src")" = "1" ] && ok "source has the route-access-db lock in hugmesh-pki" || bad "route-access-db lock missing from hugmesh-pki"

# ─── 4. usage ─────────────────────────────────────────────────────────────────
echo "-- usage"
"$TOOL" no-such-namespace --out "$W/u" >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown namespace exits 2" || bad "unknown namespace did not exit 2"
[ ! -e "$W/u" ] && ok "an unknown namespace wrote nothing" || bad "an unknown namespace created output"
"$TOOL" devops hugmesh-pki --out "$W/u" >/dev/null 2>&1; [ $? -eq 2 ] && ok "two namespaces in one call exits 2 (one at a time)" || bad "two namespaces were accepted"
"$TOOL" >/dev/null 2>&1; [ $? -eq 2 ] && ok "a bare call exits 2" || bad "a bare call did not exit 2"
"$TOOL" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag exits 2" || bad "unknown flag did not exit 2"
before="$(cd "$REPO" && git status --porcelain -- specs 2>/dev/null | wc -l | tr -d ' ')"
"$TOOL" devops --out "$W/u2" >/dev/null 2>&1
after="$(cd "$REPO" && git status --porcelain -- specs 2>/dev/null | wc -l | tr -d ' ')"
[ "$before" = "$after" ] && ok "writing to --out leaves specs/ untouched" || bad "the tool changed files under specs/"

# ─── 5. the shipped overlay is still dark ─────────────────────────────────────
echo "-- the overlay still ships dark"
if [ "$HAVE_KUBECTL" -eq 1 ]; then
  n="$(kubectl kustomize "$MAN/networkpolicy-egress" 2>/dev/null | grep -c '^kind:')"
  [ "$n" = "0" ] && ok "manifests/networkpolicy-egress renders ZERO objects" || bad "manifests/networkpolicy-egress renders $n object(s): the overlay is no longer dark"
fi
python3 -I - "$MAN/networkpolicy-egress/kustomization.yaml" <<'PY' && ok "the overlay's live resources: list is empty" || bad "the overlay's live resources: list is not empty"
import re, sys
live = [l for l in open(sys.argv[1], encoding="utf-8") if not l.lstrip().startswith("#")]
body = "".join(live)
m = re.search(r"^resources:\s*(\[\s*\])?\s*$", body, re.M)
sys.exit(0 if m and m.group(1) and not re.search(r"^\s+-\s", body, re.M) else 1)
PY
APP="${REPO}/specs/cluster/apps/08a-networkpolicy-egress.yaml"
if grep -qE '^[[:space:]]*automated:' "$APP"; then bad "apps/08a-networkpolicy-egress.yaml has an automated: block"; else ok "apps/08a-networkpolicy-egress.yaml has no automated: block (manual sync)"; fi
if python3 -I - "$MAN/networkpolicy/kustomization.yaml" <<'PY'
import re, sys
live = [l for l in open(sys.argv[1], encoding="utf-8") if not l.lstrip().startswith("#")]
sys.exit(0 if re.search(r"tier-egress|db-egress", "".join(live)) else 1)
PY
then
  bad "the AUTO-sync networkpolicy kustomization lists tier-egress/db-egress"
else ok "the AUTO-sync networkpolicy kustomization lists neither tier-egress nor db-egress"; fi
if compgen -G "$MAN/networkpolicy-egress/tier-egress-*.yaml" >/dev/null || compgen -G "$MAN/networkpolicy-egress/db-egress-*.yaml" >/dev/null; then bad "a carved file is committed in the overlay directory: that is an enablement, not a tool"
else ok "no carved file is committed in the overlay (the tool generates them at cutover)"; fi

# ─── 6. mutations ─────────────────────────────────────────────────────────────
echo "-- mutation battery"
KILLED=0; SURV=0
mut(){ # mut NAME OLD NEW CHECK(function name)
  local name="$1" old="$2" new="$3" chk="$4" m="$W/mut.py"
  python3 -I - "$TOOL" "$m" "$old" "$new" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
if s.count(sys.argv[3]) != 1:
    sys.exit(7)
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(sys.argv[3], sys.argv[4]))
PY
  local rc=$?
  [ "$rc" -eq 0 ] || { bad "mutation '$name' does not apply (target occurs not exactly once)"; SURV=$((SURV+1)); return; }
  cmp -s "$TOOL" "$m" && { bad "mutation '$name' did not change the file"; SURV=$((SURV+1)); return; }
  if "$chk" "$m"; then bad "mutation '$name' SURVIVED"; SURV=$((SURV+1)); else ok "mutation '$name' caught"; KILLED=$((KILLED+1)); fi
}
# each check returns 0 when the mutant still behaves like the original (= survived)
chk_cover(){ local o="$W/mo"; rm -rf "$o"; mkdir -p "$o"
  while read -r ns; do python3 -I "$1" --src "$MAN/networkpolicy" "$ns" --out "$o" >/dev/null 2>&1; done <"$W/ns.list"
  names_in "$o"/tier-egress-*.yaml 2>/dev/null | sort >"$W/mu.got"; cmp -s "$W/tier.src" "$W/mu.got"; }
chk_devops(){ local o="$W/md"; rm -rf "$o"; mkdir -p "$o"; python3 -I "$1" --src "$MAN/networkpolicy" devops --out "$o" >/dev/null 2>&1
  [ "$(names_in "$o/tier-egress-devops.yaml" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; }
chk_usage(){ python3 -I "$1" --src "$MAN/networkpolicy" no-such-namespace --out "$W/mu3" >/dev/null 2>&1; [ $? -eq 2 ]; }
chk_db(){ local o="$W/mdb"; rm -rf "$o"; mkdir -p "$o"; python3 -I "$1" --src "$MAN/networkpolicy" hugmesh-backend --with-db-egress --out "$o" >/dev/null 2>&1
  [ "$(names_in "$o/db-egress-hugmesh-backend.yaml" 2>/dev/null | wc -l | tr -d ' ')" = "5" ]; }
chk_sep(){ local o="$W/ms"; rm -rf "$o"; mkdir -p "$o"; python3 -I "$1" --src "$MAN/networkpolicy" hugmesh-backend --out "$o" >/dev/null 2>&1
  [ "$(names_in "$o/tier-egress-hugmesh-backend.yaml" 2>/dev/null | wc -l | tr -d ' ')" = "2" ]; }
# CONTROL: every check is GREEN on the unmutated tool, so a mutant that turns one red
# was caught by the mutation and not by a harness that fails for another reason.
for c in chk_cover chk_devops chk_usage chk_db chk_sep; do
  if "$c" "$TOOL"; then ok "control: $c passes on the unmutated tool"; else bad "control: $c FAILS on the unmutated tool (the battery below would prove nothing)"; fi
done
mut "namespace filter matches every namespace" 'sel = [(n, s, d) for n, s, d in tier if s == want]' 'sel = [(n, s, d) for n, s, d in tier]' chk_devops
mut "source parser drops the last document" '    docs.append("\n".join(cur))
    return docs' '    return docs' chk_cover
mut "unknown namespace accepted" '    if want not in known:' '    if False:' chk_usage
mut "db-egress ignores the namespace" 'for n, s, d in load(os.path.join(src, "db-egress.yaml")) if s == want]' 'for n, s, d in load(os.path.join(src, "db-egress.yaml"))]' chk_db
mut "documents are glued without a separator" 'body = header + "\n---\n".join(d.strip("\n") + "\n" for _, _, d in triples)' 'body = header + "\n".join(d.strip("\n") + "\n" for _, _, d in triples)' chk_sep
echo "-- mutations: ${KILLED} caught, ${SURV} survived"
[ "$SURV" -eq 0 ] || bad "${SURV} mutation(s) survived"

echo "== netpol egress scope: ${P} passed, ${F} failed, ${S} skipped =="
[ "$F" -eq 0 ] || exit 1
exit 0
