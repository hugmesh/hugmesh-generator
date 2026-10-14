#!/usr/bin/env bash
# test-optional-services-cutover-matrix.sh - the 13a ApplicationSet cut-over, DERIVED.
#
# The roadmap item "live ApplicationSet cut-over for optional services" was described as
# "the build-time prune ships; the hardcoded 30-*/50-* Applications still own the
# workloads". True, and not enough to act on: docs/OPTIONAL-SERVICES.md section 10 listed
# the apps to delete by hand, omitted the three edge-ai apps, and said nothing about the
# three slugs (phpbb, games, character-forge) where one 13a element covers ONE manifest
# directory while the slug owns 3-4 Applications. Deleting the owners there orphans the rest.
#
# WHAT THIS PINS (all derived by tests/scripts/optional_services_cutover_matrix.py from
# optional-services.yaml + apps/13a + apps/*.yaml; no slug, path or count is hard-coded):
#   A  the checker's seven invariants hold on the real tree: I1 element dir exists, I2 no
#      cross-slug ownership, I3 registry apps exist and parse, I4 the slug has an owner,
#      I5 namespaces agree, I6 no directory claimed twice (within and across elements),
#      I7 registry entry and template keys present
#   B  the generated matrix block in docs/OPTIONAL-SERVICES.md section 10.3 equals what the
#      tree derives, so the cut-over plan cannot rot into a hand-written list again
#   C  a CORRECT cut-over of one single-app slug (owner deleted, registry apps emptied)
#      still passes the invariants AND makes the real build guard
#      (_opt_appset_cutover_done / _opt_render_appset_flag) flip that slug's element:
#      the guard does not block the work it exists to enable
#   D  negative controls: each breakage, planted in a STAGED copy, must go red. Every
#      invariant has an ISOLATING control, asserted by the exact SET of invariant ids the
#      checker reports: a plant that trips I2 alone proves I2 is live, where a regex that
#      accepts "I2 or I6" is satisfied by whichever invariant happens to survive
#
# It does NOT prove anything about a live ArgoCD (adoption, finalizers, the reconciler
# keystone): that needs a cluster. It does not edit or wire anything under .github/.
#
#   bash tests/scripts/test-optional-services-cutover-matrix.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="${REPO}/tests/scripts/optional_services_cutover_matrix.py"
LIB="${REPO}/scripts/_optional-services-lib.sh"
DOC="${REPO}/docs/OPTIONAL-SERVICES.md"
for b in python3 diff; do
    command -v "${b}" >/dev/null 2>&1 || { echo "FAIL ${b} is required (an absent tool is a FAIL, never a skip)"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL python3 yaml (PyYAML) is required"; exit 1; }
for f in "${CHK}" "${LIB}" "${DOC}"; do [ -f "${f}" ] || { echo "FAIL missing ${f}"; exit 1; }; done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cutover-matrix.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "== A. invariants on the real tree =="
out="$(python3 "${CHK}" --root "${REPO}" check 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then ok "all invariants hold ($(printf '%s\n' "${out}" | sed -n 's/^elements: //p'))"
else bad "invariants violated (rc=${rc})"; printf '%s\n' "${out}" | grep VIOLATION | sed 's/^/      /'; fi
# vacuity: the corpus must be non-trivial, or A proves nothing
n_el="$(printf '%s\n' "${out}" | sed -n 's/^elements: \([0-9]*\) .*/\1/p')"
[ "${n_el:-0}" -ge 5 ] && ok "derived ${n_el} elements (not a vacuous pass)" || bad "derived ${n_el:-0} elements"

echo "== B. docs/OPTIONAL-SERVICES.md section 10.3 equals the derived matrix =="
doc_block() { # $1 = doc file
    python3 - "$1" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
b, e = "<!-- cutover-matrix:begin", "<!-- cutover-matrix:end -->"
if t.count(b) != 1 or t.count(e) != 1:
    print("MARKERS:%d/%d" % (t.count(b), t.count(e))); sys.exit(2)
i = t.index(b); i = t.index("\n", i) + 1
print(t[i:t.index(e)].strip("\n"))
PY
}
want="$(python3 "${CHK}" --root "${REPO}" emit)"
got="$(doc_block "${DOC}")"
if [ "${got}" = "${want}" ]; then ok "the generated block matches the tree"
else
    bad "the block in ${DOC#${REPO}/} drifted from the tree; regenerate with: python3 tests/scripts/optional_services_cutover_matrix.py --root . emit"
    diff <(printf '%s\n' "${got}") <(printf '%s\n' "${want}") | head -10 | sed 's/^/      /'
fi

# ── staging ────────────────────────────────────────────────────────────────
# A staged copy carries apps/, the registry, the doc, and EMPTY directories for every
# manifest path the 13a elements name (invariant I1 only needs the directory to exist).
stage() { # $1 = name -> echoes the staged root
    local d="${WORK}/$1"
    mkdir -p "${d}/specs/cluster" "${d}/docs"
    cp -r "${REPO}/specs/cluster/apps" "${d}/specs/cluster/apps"
    cp "${REPO}/specs/cluster/optional-services.yaml" "${d}/specs/cluster/"
    cp "${DOC}" "${d}/docs/"
    python3 - "${d}" <<'PY'
import os, sys, yaml
d = sys.argv[1]
a = yaml.safe_load(open(os.path.join(d, "specs/cluster/apps/13a-optional-services.yaml")))
for el in a["spec"]["generators"][0]["list"]["elements"]:
    os.makedirs(os.path.join(d, el["path"]), exist_ok=True)
PY
    echo "${d}"
}
APPSET_REL="specs/cluster/apps/13a-optional-services.yaml"
REG_REL="specs/cluster/optional-services.yaml"

# red <name> <why> <expect-regex> : run checker (+ doc block compare) on stage $name
red() {
    local name="$1" why="$2" expect="$3" d="${WORK}/$1" o rc2 blk
    o="$(python3 "${CHK}" --root "${d}" check 2>&1)"; rc2=$?
    blk="$(doc_block "${d}/docs/OPTIONAL-SERVICES.md")"
    if [ "${rc2}" -ne 0 ] && printf '%s\n' "${o}" | grep -E "${expect}" >/dev/null; then
        ok "NC ${name}: ${why} -> checker rc=${rc2}, ${expect}"
    elif [ "${expect}" = "DRIFT" ] && [ "${rc2}" -eq 0 ] \
         && [ "$(python3 "${CHK}" --root "${d}" emit)" != "${blk}" ]; then
        ok "NC ${name}: ${why} -> the doc block no longer matches the tree"
    else
        bad "NC ${name}: ${why} was NOT caught (rc=${rc2}; expected ${expect})"
        printf '%s\n' "${o}" | tail -3 | sed 's/^/      /'
    fi
}
# redset <name> <why> "<ids>" [msg-regex] : the checker must exit 1 and report EXACTLY the
# invariant ids given (space separated, e.g. "I2 I6"), and, when msg-regex is given, at
# least one VIOLATION line matching it. An id outside the set, or a missing one, is a FAIL:
# this is what stops a dead invariant hiding behind a live one.
redset() {
    local name="$1" why="$2" want="$3" msg="${4:-}" d="${WORK}/$1" o rc2 got
    o="$(python3 "${CHK}" --root "${d}" check 2>&1)"; rc2=$?
    got="$(printf '%s\n' "${o}" | sed -n -E 's/^  VIOLATION (I[0-9]+) .*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    want="$(printf '%s\n' ${want} | sort -u | tr '\n' ' ' | sed 's/ $//')"
    if [ "${rc2}" -ne 1 ] || [ "${got}" != "${want}" ]; then
        bad "NC ${name}: ${why}: rc=${rc2}, invariants reported [${got}], expected exactly [${want}]"
        printf '%s\n' "${o}" | grep VIOLATION | head -4 | sed 's/^/      /'
    elif [ -n "${msg}" ] && ! printf '%s\n' "${o}" | grep -E "VIOLATION .*${msg}" >/dev/null; then
        bad "NC ${name}: ${why}: no VIOLATION line matches /${msg}/"
        printf '%s\n' "${o}" | grep VIOLATION | head -4 | sed 's/^/      /'
    else
        ok "NC ${name}: ${why} -> exactly [${got}]${msg:+ ($msg)}"
    fi
}
# sed -i -E over a staged file, then verify the file ACTUALLY changed (a mutation that
# changes nothing makes its control vacuous)
mutate() { # <file> <sed-expr>
    local before; before="$(cksum < "$1")"
    sed -i -E "$2" "$1"
    [ "$(cksum < "$1")" != "${before}" ] || { echo "  FAIL mutation did not change $1 ($2)"; F=$((F+1)); return 1; }
}

echo "== C. a correct single-app cut-over passes, and lifts the real build guard =="
# pick the first slug the checker classes single-app (derived, not named)
slug="$(python3 "${CHK}" --root "${REPO}" emit | awk -F'|' 'NR>2 && $3 ~ /single-app/ {gsub(/ /,"",$2); print $2; exit}')"
if [ -z "${slug}" ]; then bad "no single-app slug derived"; else
    d="$(stage c-cut)"
    owner="$(python3 - "${REPO}" "${slug}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "tests/scripts"))
import optional_services_cutover_matrix as m
rows, _, _ = m.derive(sys.argv[1])
print([r for r in rows if r["slug"] == sys.argv[2]][0]["owners"][0])
PY
)"
    rm -f "${d}/${owner}"
    python3 - "${d}" "${slug}" <<'PY'
import re, sys
d, slug = sys.argv[1:3]
p = d + "/specs/cluster/optional-services.yaml"
t = open(p).read()
# empty the slug's `apps:` list (a real cut-over drops the retired owner from the registry)
pat = re.compile(r"(- slug: %s\n(?:(?!\n    - slug:).)*?\n      apps:\n)((?:        - [^\n]*\n)+)" % re.escape(slug), re.S)
t2, n = pat.subn(lambda m: m.group(1).replace("apps:\n", "apps: []\n"), t, count=1)
assert n == 1, "could not empty apps for " + slug
open(p, "w").write(t2)
PY
    o="$(python3 "${CHK}" --root "${d}" check 2>&1)"; rc2=$?
    if [ "${rc2}" -eq 0 ] && printf '%s\n' "${o}" | grep -E "^\| ${slug} \| runtime-only" >/dev/null; then
        ok "C1 ${slug}: owner ${owner##*/} deleted + registry emptied -> invariants hold, slug is now runtime-only"
    else bad "C1 ${slug}: a correct cut-over was rejected (rc=${rc2})"; printf '%s\n' "${o}" | grep -E 'VIOLATION' | sed 's/^/      /'; fi
    # the REAL build guard: a sysroot-shaped copy of the staged apps, flip "true"
    sys="${WORK}/c-sys/var/lib/hugmesh/cluster"; mkdir -p "${sys}"
    cp -r "${d}/specs/cluster/apps" "${sys}/apps"
    flag() { sed -n -E "s#^.*\\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\"([a-z]+)\".*#\\1#p" "$1"; }
    flip() { ( SYSROOT="${WORK}/c-sys"; info() { :; }; warn() { :; }; set +u
               # shellcheck disable=SC1090
               . "${LIB}"; _opt_render_appset_flag "${slug}" true ) 2>/dev/null; }
    flip
    [ "$(flag "${sys}/apps/13a-optional-services.yaml")" = "true" ] \
        && ok "C2 ${slug}: with the owner gone the real _opt_render_appset_flag flips the element to true" \
        || bad "C2 ${slug}: element still $(flag "${sys}/apps/13a-optional-services.yaml") after a cut-over"
    # control for C2: the SAME flip on the unmodified tree must be held false
    rm -rf "${WORK}/c-sys0"; mkdir -p "${WORK}/c-sys0/var/lib/hugmesh/cluster"
    cp -r "${REPO}/specs/cluster/apps" "${WORK}/c-sys0/var/lib/hugmesh/cluster/apps"
    ( SYSROOT="${WORK}/c-sys0"; info() { :; }; warn() { :; }; set +u; . "${LIB}"; _opt_render_appset_flag "${slug}" true ) 2>/dev/null
    [ "$(flag "${WORK}/c-sys0/var/lib/hugmesh/cluster/apps/13a-optional-services.yaml")" = "false" ] \
        && ok "C3 ${slug}: on the unmodified tree the same call leaves the element false (the guard still holds)" \
        || bad "C3 ${slug}: the double-management guard did not hold on the real tree"
fi

echo "== D. negative controls (each planted in a staged copy) =="
# the first element with an owner, derived
read -r mslug mowner mpath < <(python3 - "${REPO}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "tests/scripts"))
import optional_services_cutover_matrix as m
rows, _, _ = m.derive(sys.argv[1])
r = [r for r in rows if r["owners"]][0]
print(r["slug"], r["owners"][0], r["path"])
PY
)
# a multi-app slug, derived
read -r xslug < <(python3 "${CHK}" --root "${REPO}" emit | awk -F'|' 'NR>2 && $3 ~ /multi-app/ {gsub(/ /,"",$2); print $2; exit}')
# a second slug with an owner (for the cross-slug control)
read -r oslug opath < <(python3 - "${REPO}" "${mslug}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "tests/scripts"))
import optional_services_cutover_matrix as m
rows, _, _ = m.derive(sys.argv[1])
r = [r for r in rows if r["owners"] and r["slug"] != sys.argv[2]][0]
print(r["slug"], r["path"])
PY
)
echo "  (controls use slug ${mslug} owned by ${mowner##*/}; ${oslug}; multi-app ${xslug})"

d="$(stage n1)"; rm -f "${d}/${mowner}"
redset n1 "owner file ${mowner##*/} deleted but still listed in the registry" "I3 I4" 'does not exist as an Application'

d="$(stage n2)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${mslug},[[:space:]]*path: )${mpath//\//\\/}#\\1specs/cluster/manifests/does-not-exist#"
redset n2 "element path retargeted to a directory that does not exist (the owner then owns nothing)" "I1 I4" 'is not a directory'

d="$(stage n3)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${mslug},[[:space:]]*path: )${mpath//\//\\/}#\\1${opath//\//\\/}#"
redset n3 "element ${mslug} retargeted onto ${oslug}'s directory" "I2 I6" 'I2 '

d="$(stage n4)"
mutate "${d}/${APPSET_REL}" "/slug: ${mslug},/ s#installed: \"false\"#installed: \"true\"#"
redset n4 "element ${mslug} installed:true while ${mowner##*/} still owns the dir" "I6" 'claimed 2 times'

d="$(stage n5)"
mutate "${d}/${APPSET_REL}" "/slug: ${mslug},/ s#namespace: [a-z0-9-]+#namespace: wrong-ns#"
redset n5 "element namespace differs from the owner's destination" "I5"

d="$(stage n6)"
cat > "${d}/specs/cluster/apps/99-second-owner.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: second-owner, namespace: devops}
spec:
  project: default
  source: {repoURL: x, targetRevision: main, path: ${mpath}}
  destination: {server: x, namespace: x}
EOF
redset n6 "a second hardcoded Application claims ${mpath}" "I2 I5 I6" 'I6 '

d="$(stage n7)"
mutate "${d}/${REG_REL}" "/slug: ${xslug}\$/,/manifestPath:/ s#^( +apps:)\$#\\1\\n        - apps/does-not-exist.yaml#"
redset n7 "a fourth app added to multi-app slug ${xslug} that has no Application file" "I3" 'does not exist as an Application'

d="$(stage n8)"
python3 - "${d}" "${xslug}" <<'PY'
import re, sys
d, slug = sys.argv[1:3]
p = d + "/specs/cluster/optional-services.yaml"
t = open(p).read()
# add an EXISTING, unrelated Application file as one more app of the multi-app slug
pat = re.compile(r"(- slug: %s\n(?:(?!\n    - slug:).)*?\n      apps:\n)" % re.escape(slug), re.S)
t2, n = pat.subn(lambda m: m.group(1) + "        - apps/45-social-ui.yaml\n", t, count=1)
assert n == 1
open(p, "w").write(t2)
PY
red n8 "an extra registry app on ${xslug} (file exists): matrix gains an orphan the doc does not list" 'DRIFT'

d="$(stage n9)"
python3 - "${d}/${APPSET_REL}" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
a = '      name: "optional-{{ .slug }}"\n'
assert t.count(a) == 1
open(p, "w").write(t.replace(a, a + "      finalizers: [resources-finalizer.argocd.argoproj.io]\n"))
PY
red n9 "a cascade finalizer added to the 13a template (changes what a runtime remove does)" 'DRIFT'

d="$(stage n10)"
mutate "${d}/${mowner}" "s#^(  name: .*)\$#\\1\\n  annotations:\\n    argocd.argoproj.io/sync-wave: \"7\"#"
red n10 "a sync-wave added to ${mowner##*/} (a new thing the cut-over would drop)" 'DRIFT'

d="$(stage n11)"
python3 - "${d}" <<'PY'
import re, sys
p = sys.argv[1] + "/specs/cluster/apps/13a-optional-services.yaml"
t = open(p).read()
t = re.sub(r"(?m)^          - \{.*\}\n", "", t)       # drop every element line
t = t.replace("        elements:\n", "        elements: []\n", 1)
open(p, "w").write(t)
PY
o="$(python3 "${CHK}" --root "${WORK}/n11" check 2>&1)"; rc2=$?
[ "${rc2}" -ne 3 ] && printf "%s\n" "${o}" | tail -3 | sed "s/^/      /"
[ "${rc2}" -eq 3 ] && ok "NC n11: zero derived elements -> rc 3 INCOMPLETE, never a pass" \
                   || bad "NC n11: an empty corpus gave rc=${rc2}"

d="$(stage n12)"
python3 - "${d}" "${mslug}" <<'PY'
import re, sys
d, slug = sys.argv[1:3]
p = d + "/specs/cluster/optional-services.yaml"
t = open(p).read()
t2, n = re.subn(r"(?ms)^    - slug: %s\n.*?(?=^    - slug: )" % re.escape(slug), "", t, count=1)
assert n == 1
open(p, "w").write(t2)
PY
redset n12 "slug ${mslug} removed from the registry while its 13a element stays" "I2 I7" 'has no entry'

d="$(stage n13)"
sed -i "s/<!-- cutover-matrix:begin/<!-- cutover-matrix:gone/" "${d}/docs/OPTIONAL-SERVICES.md"
if [ "$(doc_block "${d}/docs/OPTIONAL-SERVICES.md" | head -1)" = "MARKERS:0/1" ]; then
    ok "NC n13: a missing doc marker is detected (the section-B compare cannot pass vacuously)"
else bad "NC n13: a missing doc marker was not detected"; fi

echo "== D2. one ISOLATING control per invariant (the exact set of ids reported is asserted) =="
# two runtime-only slugs (no owner, no registry apps), derived: with no owner, I2/I4/I5 cannot
# fire, so a plant on them reaches exactly the one invariant under test
read -r rslug rpath rns r2slug r2path < <(python3 - "${REPO}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "tests/scripts"))
import optional_services_cutover_matrix as m
rows, _, _ = m.derive(sys.argv[1])
_, els, _, _ = m.load_corpus(sys.argv[1])
ns = {e["slug"]: e["namespace"] for e in els}
r = [r for r in rows if r["klass"] == "runtime-only"]
if len(r) >= 2:
    print(r[0]["slug"], r[0]["path"], ns[r[0]["slug"]], r[1]["slug"], r[1]["path"])
PY
)
# an orphan Application file of the multi-app slug (a registry app no element owns), derived
orphan="$(python3 - "${REPO}" "${xslug}" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "tests/scripts"))
import optional_services_cutover_matrix as m
rows, _, _ = m.derive(sys.argv[1])
r = [r for r in rows if r["slug"] == sys.argv[2]][0]
print([o for o in r["orphans"] if r["kinds"].get(o) == "Application"][0])
PY
)"
if [ -z "${rslug:-}" ] || [ -z "${r2slug:-}" ] || [ -z "${orphan}" ]; then
    bad "D2: need two runtime-only slugs and a multi-app orphan Application; derived [${rslug:-}] [${r2slug:-}] [${orphan}]"
else
echo "  (isolating controls use runtime-only ${rslug} and ${r2slug}; orphan ${orphan##*/})"

d="$(stage i1a)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${rslug},[[:space:]]*path: )${rpath//\//\\/}#\\1specs/cluster/manifests/does-not-exist#"
redset i1a "runtime-only ${rslug} retargeted to a directory that does not exist" "I1" 'is not a directory'

d="$(stage i1b)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${rslug},[[:space:]]*path: )${rpath//\//\\/}#\\1\"\"#"
redset i1b "runtime-only ${rslug} given an EMPTY path (join(root, '') is the tree root, which isdir)" "I1" 'empty, absolute'

d="$(stage i1c)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${rslug},[[:space:]]*path: )${rpath//\//\\/}#\\1/usr#"
redset i1c "runtime-only ${rslug} given an ABSOLUTE path that exists on the host" "I1" 'empty, absolute'

d="$(stage i1d)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${rslug},[[:space:]]*path: )${rpath//\//\\/}#\\1..#"
redset i1d "runtime-only ${rslug} given path '..' (an existing directory OUTSIDE the tree)" "I1" 'empty, absolute or leaves'

d="$(stage i2)"
cat > "${d}/specs/cluster/apps/99-stray-owner.yaml" <<YML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: stray-owner, namespace: devops}
spec:
  project: default
  source: {repoURL: x, targetRevision: main, path: ${rpath}}
  destination: {server: x, namespace: ${rns}}
YML
redset i2 "a hardcoded Application (right namespace) claims runtime-only ${rslug}'s directory" "I2" 'owns .* but is not among its registry apps'

d="$(stage i2b)"
cat > "${d}/specs/cluster/apps/99-stray-owner.yaml" <<YML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: stray-owner, namespace: devops}
spec:
  project: default
  source: {repoURL: x, targetRevision: main, path: ./${rpath}/}
  destination: {server: x, namespace: ${rns}}
YML
redset i2b "the same stray owner spelled ./path/ (owner matching is on the normalised path)" "I2" 'owns .* but is not among its registry apps'

d="$(stage i3a)"
printf '\n  : : [unbalanced\n' >> "${d}/${orphan}"
redset i3a "registry app ${orphan##*/} of ${xslug} (no element owns it) no longer parses" "I3" 'does not parse'

d="$(stage i4)"
mkdir -p "${d}/specs/cluster/manifests/unclaimed-dir"
mutate "${d}/${mowner}" "s#^(    path: ).*\$#\\1specs/cluster/manifests/unclaimed-dir#"
redset i4 "owner ${mowner##*/} moved to a directory no element names (registry still lists it)" "I4" 'none owns the element path'

d="$(stage i6a)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${rslug},[[:space:]]*path: )${rpath//\//\\/}#\\1${r2path//\//\\/}#"
redset i6a "elements ${rslug} and ${r2slug} name one directory, both still \"false\"" "I6" 'all name manifest dir'

d="$(stage i6c)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${rslug},[[:space:]]*path: )${rpath//\//\\/}#\\1./${r2path//\//\\/}/#"
redset i6c "elements ${rslug} and ${r2slug} name one directory, one spelled ./path/ (the claim key is normalised)" "I6" 'all name manifest dir'

d="$(stage i6b)"
mutate "${d}/${APPSET_REL}" "s#(slug: ${rslug},[[:space:]]*path: )${rpath//\//\\/}#\\1${r2path//\//\\/}#"
mutate "${d}/${APPSET_REL}" "/slug: ${rslug},/ s#installed: \"false\"#installed: \"true\"#"
mutate "${d}/${APPSET_REL}" "/slug: ${r2slug},/ s#installed: \"false\"#installed: \"true\"#"
redset i6b "elements ${rslug} and ${r2slug} on one directory, both installed:true, no owner" "I6" 'all name manifest dir'

d="$(stage i7a)"
mutate "${d}/${APPSET_REL}" "/slug: ${rslug},/ s#namespace: [a-z0-9-]+,[[:space:]]*##"
redset i7a "runtime-only ${rslug} loses the namespace key the template renders (no owner, so I5 cannot mask it)" "I7" 'lacks key'

d="$(stage i7b)"
python3 - "${d}" "${rslug}" <<'PY'
import re, sys
d, slug = sys.argv[1:3]
p = d + "/specs/cluster/optional-services.yaml"
t = open(p).read()
t2, n = re.subn(r"(?ms)^    - slug: %s\n.*?(?=^    - slug: )" % re.escape(slug), "", t, count=1)
assert n == 1
open(p, "w").write(t2)
PY
redset i7b "runtime-only ${rslug} removed from the registry while its element stays" "I7" 'has no entry'
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
