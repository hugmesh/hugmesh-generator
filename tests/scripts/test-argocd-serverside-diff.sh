#!/usr/bin/env bash
# test-argocd-serverside-diff.sh — an ArgoCD Application that syncs with
# ServerSideApply=true and renders a StatefulSet carrying volumeClaimTemplates
# MUST also opt into Server-Side Diff, or it is PERMANENTLY OutOfSync and
# nothing anywhere says why.
#
# WHY THIS EXISTS (hugmesh-generator#354, diagnosed and independently
# reproduced 2026-09-16 on kind-hugmesh-local).
#
#   kube-apiserver v1.34 stamps `apiVersion: v1` / `kind: PersistentVolumeClaim`
#   onto every nested spec.volumeClaimTemplates[] entry at conversion time
#   (kubernetes#87583). ArgoCD v3.5.3 picks its diff strategy in
#   controller/state.go:910-911: any Application with ServerSideApply=true gets
#   Structured-Merge Diff, a strategy the vendor's own
#   docs/user-guide/diff-strategies.md marks "Feature Discontinued". SMD builds
#   predictedLive with CLIENT-side scheme defaults, so volumeMode and
#   status.phase appear but the SERVER-side conversion is never reproduced —
#   predictedLive lacks apiVersion/kind, live has them, and the two StatefulSets
#   differ forever. (The legacy three-way path has statefulSetWorkaround at
#   gitops-engine pkg/diff/diff.go:796 for exactly this, which is why vault's
#   StatefulSet — same live shape, no SSA — is Synced.)
#
#   MEASURED CONSEQUENCE, not theory: harbor sat OutOfSync/Healthy on
#   StatefulSet/harbor-database and StatefulSet/harbor-redis with
#   generation == observedGeneration == 1 (so NOT the HPA-style rewrite loop of
#   the hpa/gitops fight), and ArgoCD's own managed-resources diff was exactly
#   two leaf paths on each object: .spec.volumeClaimTemplates[0].apiVersion and
#   .kind. autoHealAttemptsCount read 8 at 10:22 PT and 83 at 16:37 PT — a
#   permanent every-five-minutes server-side-apply write loop that can never
#   converge, because the thing it is trying to remove was put there by the
#   apiserver.
#
#   The fix is one annotation, `argocd.argoproj.io/compare-options:
#   ServerSideDiff=true`: SSD predicts from a dry-run SSA response, which HAS
#   been through the conversion, so predicted == live. Verified read-only with
#   `kubectl diff --server-side --field-manager=argocd-controller` fed ArgoCD's
#   own rendered targetState — exit 0 and zero bytes for both StatefulSets, and
#   the probe was mutation-tested (replicas 1->2 correctly returns exit 1).
#
# WHY A GUARD AND NOT JUST THE FIX. This repo's stated doctrine is that a
# permanently-red surface is a defect in the SIGNAL, and the exemption list is
# the point rather than an escape hatch (tests/scripts/kind_route_closure.py
# says so outright). Two ways the fix rots silently:
#
#   * SOMEONE DELETES THE ANNOTATION while ServerSideApply=true stays. The
#     cluster goes red again and the only record was a comment nobody re-reads.
#   * SOMEONE FIXES specs/ AND FORGETS templates/. The reference deployment is
#     green and every generated brand inherits the permanent red — the exact
#     shape of the spec/template drift this repo has hit before.
#
# AND THE CONVERSE ROT RULE, which is what keeps the list honest: an entry here
# whose file no longer carries ServerSideApply=true is DEAD and must be removed,
# because the gap it describes is closed. An entry naming a file that does not
# exist is dead too. Neither is forgiven — that is the anti-rot pair the
# unwired-suite allowlist in tests/scripts/test-guard-integrity.sh uses, applied
# to this axis.
#
# NOT CLAIMED HERE. This guard cannot tell you WHICH Applications render a
# StatefulSet with volumeClaimTemplates — harbor's source is an upstream Helm
# chart, so the answer lives outside the repo. It pins the apps that are KNOWN
# to need SSD (by measurement, one so far, in both of its two spellings) and
# refuses to let a new SSD opt-in land WITHOUT a recorded reason. Another SSA
# app that turns out to need it gets an entry the day it is measured.
#
# Offline and hermetic: bash + python3 stdlib only. No PyYAML (the .hbs half is
# not valid YAML — `name: {{BRAND}}-harbor` opens a flow mapping), no cluster,
# no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# The analysed tree. An ENV var, because the negative controls below must point
# the same analyser at synthesised trees carrying each defect on purpose.
# Capture what was INHERITED before any defaulting — the check below is
# worthless if it runs after the assignment that always sets these.
SSD_INHERITED=""
for v in SSD_ROOT SSD_REQUIRE SSD_APP_FLOOR SSD_SSA_FLOOR SSD_TPL_FLOOR; do
  [ -n "${!v+x}" ] && SSD_INHERITED="${SSD_INHERITED} ${v}"
done
SSD_ROOT="${SSD_ROOT:-${REPO}}"

# Whether this invocation is a control run is a POSITIONAL ARGUMENT, never an
# environment variable: an inherited env var would silently downgrade a real CI
# run to a control run — skipping the controls AND relaxing the floors — and
# nothing would say so. (Lesson taken from
# tests/scripts/test-kind-profile-app-closure.sh, which records the same trap.)
CHILD=no
[ "${1:-}" = "--analyse-only" ] && CHILD=yes

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards; this repo has shipped several.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }

# ── THE PINNED SET ───────────────────────────────────────────────────────────
# path<TAB>reason. Both spellings of the same Application are listed separately
# and on purpose: fixing one and not the other is a defect this file exists to
# catch, so they cannot share an entry.
SSD_REQUIRED=(
"specs/cluster/apps/03a-harbor.yaml	the Harbor chart's bundled Postgres+Redis subcharts render StatefulSets with volumeClaimTemplates; measured permanently OutOfSync without SSD (#354)"
"templates/apps/03a-harbor.yaml.hbs	1:1 brand mirror of the spec above; without the same annotation every generated brand inherits the permanent red"
)

# Vacuity floors. If the scanner goes blind — the apps tree moves, the filename
# convention changes, the syncOptions spelling changes — it must FAIL rather
# than report a tidy green over a set it is no longer computing. MEASURED on
# this tree 2026-09-16, not guessed: 93 files under specs/cluster/apps carry
# `kind: Application`, 10 of them ServerSideApply=true (calico, keda,
# autoscaling-latency, gitlab, harbor, ingress-nginx, ingress-nginx-internal,
# kyverno, velero, velero-config), and templates/apps holds 14 Applications of
# which 1 is SSA (the harbor mirror). The floors sit below those so ordinary
# growth does not trip them, while a scanner reading NOTHING still fails.
SSD_APP_FLOOR="${SSD_APP_FLOOR:-60}"
SSD_SSA_FLOOR="${SSD_SSA_FLOOR:-8}"
SSD_TPL_FLOOR="${SSD_TPL_FLOOR:-1}"

# A REAL run must not be able to inherit relaxed floors, a different tree, or a
# rewritten pin set from its environment. The controls below set these
# deliberately and pass --analyse-only; a CI run that inherited them would be a
# downgraded guard reporting a full-strength green.
if [ "${CHILD}" = "no" ] && [ -n "${SSD_INHERITED}" ]; then
  echo "FATAL: a NON-control run inherited${SSD_INHERITED} from its environment — that would relax this guard silently; unset and re-run" >&2
  exit 1
fi

if [ -n "${SSD_REQUIRE+x}" ]; then REQUIRE_TEXT="${SSD_REQUIRE}"
else REQUIRE_TEXT="$(printf '%s\n' "${SSD_REQUIRED[@]}")"; fi

# ── THE ANALYSER ─────────────────────────────────────────────────────────────
OUT="$(mktemp)"
SSD_ROOT="${SSD_ROOT}" SSD_REQUIRE_TEXT="${REQUIRE_TEXT}" \
SSD_APP_FLOOR="${SSD_APP_FLOOR}" SSD_SSA_FLOOR="${SSD_SSA_FLOOR}" SSD_TPL_FLOOR="${SSD_TPL_FLOOR}" \
python3 - >"${OUT}" 2>&1 <<'PY'
import os, re, sys

root      = os.environ["SSD_ROOT"]
req_text  = os.environ.get("SSD_REQUIRE_TEXT", "")
APP_FLOOR = int(os.environ.get("SSD_APP_FLOOR", "0"))
SSA_FLOOR = int(os.environ.get("SSD_SSA_FLOOR", "0"))
TPL_FLOOR = int(os.environ.get("SSD_TPL_FLOOR", "0"))

P = [0]; F = [0]
def ok(m):  print("  PASS %s" % m); P[0] += 1
def bad(m): print("  FAIL %s" % m); F[0] += 1

SPEC_DIR = "specs/cluster/apps"
TPL_DIR  = "templates/apps"
ANNO_KEY = "argocd.argoproj.io/compare-options"

def indent(line):
    return len(line) - len(line.lstrip(" "))

def parse(path):
    """Everything this guard needs to know about one Application manifest."""
    txt   = open(path, encoding="utf-8", errors="replace").read()
    lines = txt.split("\n")
    d = {
        "is_app": False, "ssa": False,
        "anno_line": None,        # 1-indexed line of the compare-options key, in metadata.annotations
        "anno_value": None,
        "anno_elsewhere": [],     # the key found OUTSIDE metadata.annotations — a silent no-op
        "reason": "",             # the comment run directly above the key
    }
    for l in lines:
        if re.match(r"^kind:\s*Application\s*$", l):
            d["is_app"] = True
        # syncOptions in flow OR block form; a bare list item counts too.
        if "ServerSideApply=true" in l and not l.lstrip().startswith("#"):
            d["ssa"] = True

    # metadata: block == the col-0 `metadata:` key and every indented line under
    # it, up to the next col-0 key. Deliberately structural: an annotation
    # written under `spec:` is a string the controller never reads, and that has
    # to be a FAILURE rather than a match.
    meta = []
    i = 0
    while i < len(lines):
        if re.match(r"^metadata:\s*$", lines[i]):
            j = i + 1
            while j < len(lines):
                s = lines[j]
                if s.strip() == "" or indent(s) > 0:
                    meta.append((j, s)); j += 1; continue
                break
            break
        i += 1

    anno_body = []
    k = 0
    while k < len(meta):
        if re.match(r"^\s*annotations:\s*$", meta[k][1]) and indent(meta[k][1]) == 2:
            m = k + 1
            while m < len(meta):
                s = meta[m][1]
                if s.strip() == "" or indent(s) >= 4:
                    anno_body.append(meta[m]); m += 1; continue
                break
            break
        k += 1

    for n, (lineno, s) in enumerate(anno_body):
        mm = re.match(r"^\s*%s:\s*(.*?)\s*$" % re.escape(ANNO_KEY), s)
        if mm:
            d["anno_line"]  = lineno + 1
            d["anno_value"] = mm.group(1).strip().strip('"').strip("'")
            run = []
            p = n - 1
            while p >= 0 and anno_body[p][1].lstrip().startswith("#"):
                run.insert(0, anno_body[p][1]); p -= 1
            d["reason"] = "\n".join(run)
            break

    in_anno = set(x[0] for x in anno_body)
    for idx, s in enumerate(lines):
        if ANNO_KEY in s and not s.lstrip().startswith("#") and idx not in in_anno:
            d["anno_elsewhere"].append(idx + 1)
    return d

# ── census ───────────────────────────────────────────────────────────────────
apps = {}
for d in (SPEC_DIR, TPL_DIR):
    p = os.path.join(root, d)
    if not os.path.isdir(p):
        continue
    for fn in sorted(os.listdir(p)):
        if not (fn.endswith(".yaml") or fn.endswith(".yaml.hbs")):
            continue
        rel = "%s/%s" % (d, fn)
        info = parse(os.path.join(p, fn))
        if info["is_app"]:
            apps[rel] = info

spec_apps = [k for k in apps if k.startswith(SPEC_DIR + "/")]
tpl_apps  = [k for k in apps if k.startswith(TPL_DIR + "/")]
ssa_spec  = [k for k in spec_apps if apps[k]["ssa"]]
ssa_tpl   = [k for k in tpl_apps if apps[k]["ssa"]]

# ── 0) VACUITY FLOOR ─────────────────────────────────────────────────────────
# Checked FIRST and hard: every leg below is a statement about this census, so a
# census that has gone blind must not be allowed to make any of them.
blind = False
if len(spec_apps) < APP_FLOOR:
    bad("census: found %d Application manifests under %s, floor is %d — the scanner has gone blind and every leg below would be vacuous"
        % (len(spec_apps), SPEC_DIR, APP_FLOOR)); blind = True
if len(ssa_spec) < SSA_FLOOR:
    bad("census: found %d ServerSideApply=true Applications under %s, floor is %d — the syncOptions spelling this guard keys on has drifted"
        % (len(ssa_spec), SPEC_DIR, SSA_FLOOR)); blind = True
if len(ssa_tpl) < TPL_FLOOR:
    bad("census: found %d ServerSideApply=true Applications under %s, floor is %d — the brand-template half of this guard is reading nothing"
        % (len(ssa_tpl), TPL_DIR, TPL_FLOOR)); blind = True
if not blind:
    ok("census: %d Applications under %s (%d ServerSideApply=true) + %d under %s (%d SSA)"
       % (len(spec_apps), SPEC_DIR, len(ssa_spec), len(tpl_apps), TPL_DIR, len(ssa_tpl)))

# ── the pinned set ───────────────────────────────────────────────────────────
required = []
for line in req_text.split("\n"):
    if not line.strip() or line.strip().startswith("#"):
        continue
    parts = line.split("\t", 1)
    required.append((parts[0].strip(), parts[1].strip() if len(parts) > 1 else ""))

if not required:
    bad("the pinned set is EMPTY — this guard would assert nothing")

for rel, reason in required:
    full = os.path.join(root, rel)

    # 1) ENTRY ROT: the file must still exist.
    if not os.path.isfile(full):
        bad("%s is pinned as needing ServerSideDiff but does not exist — a dead entry rots this list into a blanket amnesty; delete it" % rel)
        continue

    # 2) ENTRY ROT, the other half: the gap must still be open.
    info = apps.get(rel)
    if info is None or not info["is_app"]:
        bad("%s is pinned here but is not an ArgoCD Application manifest (kind: Application not found) — the entry is stale" % rel)
        continue
    if not info["ssa"]:
        bad("%s no longer syncs with ServerSideApply=true, so the Structured-Merge-Diff trap this entry describes is CLOSED — remove the entry (and, if you like, the annotation) rather than leaving a rule nobody can explain" % rel)
        continue

    # 3) THE PIN ITSELF.
    if info["anno_line"] is None:
        if info["anno_elsewhere"]:
            bad("%s: %s appears at line(s) %s but NOT under metadata.annotations — ArgoCD never reads it there, so this is a no-op that looks exactly like a fix"
                % (rel, ANNO_KEY, ",".join(str(x) for x in info["anno_elsewhere"])))
        else:
            bad("%s syncs with ServerSideApply=true and has NO %s annotation: ArgoCD v3.5.x hands it Structured-Merge Diff, which cannot reproduce the apiserver's volumeClaimTemplates conversion, and the app sits permanently OutOfSync (#354)"
                % (rel, ANNO_KEY))
        continue

    val = info["anno_value"] or ""
    opts = [o.strip() for o in val.split(",") if o.strip()]
    if "ServerSideDiff=true" not in opts:
        bad("%s line %d: %s is %r — it must contain ServerSideDiff=true (ServerSideDiff=false, or the option merely being mentioned, leaves the app on the discontinued SMD path)"
            % (rel, info["anno_line"], ANNO_KEY, val))
        continue

    # 4) A WRITTEN REASON, not a magic string. The next person to read this
    #    manifest must be able to reach the diagnosis and the upstream fix
    #    without excavating git history.
    r = info["reason"]
    missing = []
    if "354" not in r:                                      missing.append("the issue (#354)")
    if "29103" not in r:                                    missing.append("the upstream fix (argo-cd PR #29103)")
    if not re.search(r"1\.34|volumeClaimTemplates", r):     missing.append("the cause (k8s 1.34 volumeClaimTemplates conversion)")
    if not re.search(r"Structured-Merge|SMD", r):           missing.append("the strategy it works around (Structured-Merge Diff)")
    if missing:
        bad("%s line %d: the ServerSideDiff annotation carries no comment naming %s — an unexplained magic option is the failure mode #354 exists to stop"
            % (rel, info["anno_line"], "; ".join(missing)))
        continue

    ok("%s: ServerSideApply=true AND %s=ServerSideDiff=true, with a reason naming the cause, the issue and the upstream fix" % (rel, ANNO_KEY))

# ── 5) SPEC <-> TEMPLATE PARITY ──────────────────────────────────────────────
# A fix applied to specs/ and not to templates/ ships a green reference
# deployment and a permanently red brand. Computed over every pair that exists
# in both trees, not just the pinned ones.
pairs = 0; drift = 0
for rel in sorted(spec_apps):
    stem = os.path.basename(rel)
    twin = "%s/%s.hbs" % (TPL_DIR, stem)
    if twin not in apps:
        continue
    pairs += 1
    a = apps[rel]["anno_line"] is not None and "ServerSideDiff=true" in (apps[rel]["anno_value"] or "")
    b = apps[twin]["anno_line"] is not None and "ServerSideDiff=true" in (apps[twin]["anno_value"] or "")
    if a != b:
        drift += 1
        bad("spec/template DRIFT: %s has ServerSideDiff=%s but its brand twin %s has ServerSideDiff=%s — one of the two is permanently OutOfSync and only the other gets noticed"
            % (rel, a, twin, b))
if pairs == 0:
    bad("parity leg found ZERO spec/template Application pairs — it is asserting nothing")
elif drift == 0:
    ok("spec/template parity: %d Application(s) exist in both trees and agree on ServerSideDiff" % pairs)

# ── 6) THE CONVERSE: no unrecorded SSD opt-in ────────────────────────────────
# An Application that opts into Server-Side Diff without an entry here is a
# second unexplained magic option. Either it was measured — in which case it
# gets an entry with its reason — or it was cargo-culted.
pinned = set(r for r, _ in required)
stray  = sorted(k for k, v in apps.items()
                if v["anno_line"] is not None
                and "ServerSideDiff=true" in (v["anno_value"] or "")
                and k not in pinned)
if stray:
    for k in stray:
        bad("%s opts into ServerSideDiff but is not pinned in SSD_REQUIRED — add it with the measurement that justified it, so the option is not a rule nobody can explain" % k)
else:
    ok("no unrecorded ServerSideDiff opt-in: every Application carrying the annotation is pinned with a written reason")

print()
print("== argocd server-side diff: %d passed, %d failed ==" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
arc=$?
cat "${OUT}"
# Re-raise the analyser's verdict into this script's counters. Counting its FAIL
# lines rather than trusting only $? means a python traceback (which prints no
# FAIL line at all) still lands as a failure, via arc.
nfail="$(grep -c '^  FAIL ' "${OUT}" || true)"
npass="$(grep -c '^  PASS ' "${OUT}" || true)"
pass=$((pass + npass))
fail=$((fail + nfail))
if [ "${arc}" -ne 0 ] && [ "${nfail}" -eq 0 ]; then
  bad "the analyser exited ${arc} without printing a single FAIL line — it crashed, and a crash must not read as green"
fi
rm -f "${OUT}"

if [ "${CHILD}" = "yes" ]; then
  [ "${fail}" -eq 0 ]
  exit $?
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Every leg above is re-run against synthesised trees carrying each defect ON
# PURPOSE. Without these the green over the real repo is unfalsifiable: a guard
# that would pass on a broken tree is not a guard, and this repo has shipped
# that shape more than once (see tests/scripts/test-guard-integrity.sh's
# taxonomy). Each control is a PAIR — the defect must be caught AND its clean
# twin must not be — because a check that fails on everything is just as blind
# as one that fails on nothing.
echo
echo "-- negative controls --"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

mkspec() { mkdir -p "$1/specs/cluster/apps" "$1/templates/apps"; }

# A minimal, faithful pair: the annotation, its reason comment, and SSA.
write_app() {
  # $1 tree  $2 relpath  $3 anno-block(or empty)  $4 syncOptions line
  local tree
  local rel
  local anno
  local sync
  tree="$1"; rel="$2"; anno="$3"; sync="$4"
  mkdir -p "$(dirname "${tree}/${rel}")"
  {
    echo "apiVersion: argoproj.io/v1alpha1"
    echo "kind: Application"
    echo "metadata:"
    echo "  name: harbor"
    echo "  namespace: devops"
    [ -n "${anno}" ] && printf '%s\n' "${anno}"
    echo "spec:"
    echo "  project: default"
    echo "  destination: { server: https://kubernetes.default.svc, namespace: hugmesh-pki }"
    echo "  syncPolicy:"
    echo "    automated: { prune: false, selfHeal: true }"
    echo "    syncOptions: [${sync}]"
  } > "${tree}/${rel}"
}

GOOD_ANNO='  annotations:
    # k8s 1.34 stamps apiVersion/kind onto spec.volumeClaimTemplates[]; ArgoCD
    # Structured-Merge Diff cannot reproduce it, so this app is permanently
    # OutOfSync (#354). No-op once argo-cd PR #29103 reaches stable.
    argocd.argoproj.io/compare-options: ServerSideDiff=true'

REQ='specs/cluster/apps/03a-harbor.yaml	measured
templates/apps/03a-harbor.yaml.hbs	measured mirror'

build_tree() {
  # $1 tree  $2 spec-anno  $3 tpl-anno  $4 spec-sync
  local tree
  tree="$1"
  mkspec "${tree}"
  write_app "${tree}" "specs/cluster/apps/03a-harbor.yaml" "$2" "$4"
  write_app "${tree}" "templates/apps/03a-harbor.yaml.hbs" "$3" "CreateNamespace=true, ServerSideApply=true"
}

run_probe() {
  SSD_ROOT="$1" SSD_REQUIRE="${REQ}" SSD_APP_FLOOR=1 SSD_SSA_FLOOR=1 SSD_TPL_FLOOR=1 \
    bash "${BASH_SOURCE[0]}" --analyse-only >/dev/null 2>&1
}

control() {
  # $1 label  $2 expect(caught|clean)  $3 tree
  local label
  local expect
  local tree
  label="$1"; expect="$2"; tree="$3"
  if run_probe "${tree}"; then
    if [ "${expect}" = "clean" ]; then ok "control (${label}): the clean twin passes"
    else bad "control (${label}): the defect was NOT caught — the leg that should see it is blind"; fi
  else
    if [ "${expect}" = "caught" ]; then ok "control (${label}): caught, as it must be"
    else bad "control (${label}): the CLEAN tree failed — this guard fails on everything, which is as useless as failing on nothing"; fi
  fi
}

# (a) the no-defect twin.
build_tree "${T}/clean" "${GOOD_ANNO}" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
control "no defect" clean "${T}/clean"

# (b) annotation deleted while SSA stays — the original #354 state.
build_tree "${T}/missing" "" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
control "annotation removed from the spec" caught "${T}/missing"

# (c) the brand template forgotten — green reference, red brand.
build_tree "${T}/drift" "${GOOD_ANNO}" "" "CreateNamespace=true, ServerSideApply=true"
control "template half forgotten (spec/template drift)" caught "${T}/drift"

# (d) ServerSideDiff=false — present, mentioned, and still on the SMD path.
build_tree "${T}/false" "$(printf '%s' "${GOOD_ANNO}" | sed 's/ServerSideDiff=true/ServerSideDiff=false/')" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
control "ServerSideDiff=false" caught "${T}/false"

# (e) the annotation nested under spec: instead of metadata.annotations. It
#     greps clean and ArgoCD never reads it — the reason leg 3 is structural.
mkspec "${T}/misplaced"
write_app "${T}/misplaced" "templates/apps/03a-harbor.yaml.hbs" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
cat > "${T}/misplaced/specs/cluster/apps/03a-harbor.yaml" <<'MIS'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: harbor
  namespace: devops
spec:
  project: default
  annotations:
    # k8s 1.34 volumeClaimTemplates conversion vs Structured-Merge Diff, #354,
    # fixed upstream by argo-cd PR #29103.
    argocd.argoproj.io/compare-options: ServerSideDiff=true
  syncPolicy:
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
MIS
control "annotation under spec: instead of metadata.annotations" caught "${T}/misplaced"

# (f) the magic string with no reason.
build_tree "${T}/noreason" "  annotations:
    argocd.argoproj.io/compare-options: ServerSideDiff=true" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
control "annotation with no written reason" caught "${T}/noreason"

# (g) ENTRY ROT, both halves. An entry whose file is gone, and an entry whose
#     app no longer uses ServerSideApply — a closed gap must retire its rule.
build_tree "${T}/rot" "${GOOD_ANNO}" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
rm -f "${T}/rot/specs/cluster/apps/03a-harbor.yaml"
control "pinned file deleted (dead entry)" caught "${T}/rot"

build_tree "${T}/nossa" "${GOOD_ANNO}" "${GOOD_ANNO}" "CreateNamespace=true"
control "pinned app no longer uses ServerSideApply (closed gap, stale rule)" caught "${T}/nossa"

# (h) THE CONVERSE: an unpinned app that opts into SSD anyway.
build_tree "${T}/stray" "${GOOD_ANNO}" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
write_app "${T}/stray" "specs/cluster/apps/99-other.yaml" "${GOOD_ANNO}" "CreateNamespace=true, ServerSideApply=true"
control "unrecorded ServerSideDiff opt-in on another app" caught "${T}/stray"

# (i) THE BLIND-CENSUS control. An empty apps tree must FAIL on the floor, not
#     pass over zero files. Run with the REAL floors, which is the only way to
#     exercise the floor at all.
mkspec "${T}/empty"
if SSD_ROOT="${T}/empty" SSD_REQUIRE="${REQ}" bash "${BASH_SOURCE[0]}" --analyse-only >/dev/null 2>&1; then
  bad "control (blind census): an EMPTY apps tree passed — the vacuity floor is inert and this guard could go green while reading nothing"
else
  ok "control (blind census): an empty apps tree fails the floor rather than passing over zero files"
fi

# (j) THE SABOTAGE CONTROL. Remove the leg that catches a missing annotation
#     from a COPY of this file and require that the defect then passes. If it
#     still fails, the controls above are measuring something other than the
#     property under test — the state adversarial review has repeatedly found
#     guards in.
#
#     It runs against a tree where BOTH halves lack the annotation, NOT against
#     ${T}/missing: with only the spec half missing the PARITY leg catches it
#     too, so deleting leg 3 would not make it pass and this control would
#     report a failure that says nothing about leg 3. Isolate the leg under test.
build_tree "${T}/bothmissing" "" "" "CreateNamespace=true, ServerSideApply=true"
control "annotation absent from BOTH halves (the original #354 state)" caught "${T}/bothmissing"
# (j) THE SABOTAGE CONTROL. Delete the leg that catches (b) from a COPY of this
#     file and require that (b) then passes. If it still fails, the controls
#     above are measuring something other than the property under test — the
#     state adversarial review has repeatedly found guards in.
sed 's|bad("%s syncs with ServerSideApply=true and has NO %s annotation|ok("%s syncs with ServerSideApply=true and has NO %s annotation|' \
  "${BASH_SOURCE[0]}" > "${T}/sabotage.sh"
# CONFIRM THE SABOTAGE LANDED. A sed whose pattern has drifted no-ops and still
# exits 0, leaving a byte-identical "sabotaged" copy: the defect is caught
# exactly as it should be and this control reports FAIL for a reason that has
# nothing to do with the property under test. Assert the difference.
if cmp -s "${T}/sabotage.sh" "${BASH_SOURCE[0]}"; then
  bad "control (sabotage): the sabotage sed changed NOTHING — its pattern no longer matches the missing-annotation line, so this control is inert"
else
  # The copy runs from ${T}, NOT from tests/scripts/. A sibling precedent writes
  # its sabotage copy back beside itself, which dies the moment the checkout is
  # mounted read-only — and dies as a FAILING control, i.e. a red that says
  # nothing about the property under test. Nothing here needs the copy to sit in
  # the repo: SSD_ROOT and the pin set are both passed explicitly, so the copy's
  # own REPO is never consulted.
  if SSD_ROOT="${T}/bothmissing" SSD_REQUIRE="${REQ}" SSD_APP_FLOOR=1 SSD_SSA_FLOOR=1 SSD_TPL_FLOOR=1 \
       bash "${T}/sabotage.sh" --analyse-only >/dev/null 2>&1; then
    ok "control (sabotage): with the missing-annotation leg removed, the both-halves-missing defect is NO LONGER caught — so that leg really is what catches it"
  else
    bad "control (sabotage): the both-halves-missing defect still fails with its leg removed — the controls are measuring something else"
  fi
fi

echo
echo "== argocd server-side diff guard: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
