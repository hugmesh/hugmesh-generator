#!/usr/bin/env bash
# test-release-beta.sh — scripts/release-beta.sh against a recording gh stub (docs/RELEASING.md).
#
# The release script talks to GitHub through `gh` only. Here `gh` (and `docker`, which the
# script must never need) are stubs on PATH that answer from a JSON fixture, apply the
# script's --jq filters with the real jq, mutate the fixture on writes exactly as GitHub
# would (a tag starts its run, a re-run turns the run green, a merge moves main), and log
# every call. Nothing here reaches the network.
#
# What it proves:
#   A  a dry run makes ZERO write calls (no POST/PATCH/PUT/DELETE or -f/-F api call, no
#      run rerun/cancel, workflow run, pr merge/ready, release create, secret set, docker)
#      -- including through the real scripts/release-studio.sh --dry-run it calls;
#   B  versions are parsed from every kind of version file (pom.xml with a <parent>,
#      package.json, composer.json, VERSION, clients/docker-mesh-node/VERSION);
#   C  DONE / READY / REFUSE / NEEDS-BUMP / RUNNING classification, including the paths
#      filter that keeps mesh-node DONE while main moves on elsewhere;
#   D  the --only fix: selecting one downstream repo does not block its own stage when the
#      unselected dependency stages are already DONE;
#   E  the tag-SHA re-check: when main moves between the check and the tag, nothing is tagged;
#   F  stage ordering of a full --apply: Maven chain, apps, re-runs, gateway, overlays, Java;
#   G  a red main run older than 30 days is never re-run;
#   M  three guards are mutation-tested: each is broken in a copy of the script, the check
#      that covers it must go red, and the copy must really differ from the original.
#
# Needs bash, python3, jq. No network, no docker, no gh login.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${REPO}/scripts/release-beta.sh"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

for t in python3 jq bash; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t is not installed; this suite cannot run (it must not pass vacuously)"; exit 2; }
done
[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT missing"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-release-beta.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# ── the stubs ────────────────────────────────────────────────────────────────
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env python3
import base64, json, os, subprocess, sys, time, urllib.parse
STATE = os.environ["STUB_STATE"]
LOG = os.environ["STUB_LOG"]
argv = sys.argv[1:]
with open(LOG, "a") as f:
    f.write(json.dumps(["gh"] + argv) + "\n")
st = json.load(open(STATE))
def save(): json.dump(st, open(STATE, "w"), indent=1)
VALUED = {"-R", "--repo", "--workflow", "-w", "--branch", "-b", "--event", "-e", "--limit", "-L",
          "--json", "--jq", "-q", "--status", "-s", "-X", "--method", "-f", "-F", "--field",
          "--raw-field", "--ref", "--interval", "--template", "-t", "--org", "--input", "--pattern", "--dir"}
opts = {}; fields = {}; pos = []
i = 0
while i < len(argv):
    a = argv[i]
    if a in VALUED and i + 1 < len(argv):
        v = argv[i + 1]
        if a in ("-f", "-F", "--field", "--raw-field"):
            k, _, val = v.partition("="); fields[k] = val
        else:
            opts[a] = v
        i += 2; continue
    if a.startswith("--") and "=" in a:
        k, _, v = a.partition("="); opts[k] = v; i += 1; continue
    if a.startswith("-"):
        opts[a] = True; i += 1; continue
    pos.append(a); i += 1
def opt(*names, default=None):
    for n in names:
        if n in opts: return opts[n]
    return default
def out(obj):
    jq = opt("--jq", "-q")
    data = json.dumps(obj)
    if jq:
        r = subprocess.run(["jq", "-r", jq], input=data, capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write("stub jq error: " + r.stderr); sys.exit(1)
        sys.stdout.write(r.stdout)
    else:
        sys.stdout.write(data + "\n")
    sys.exit(0)
def notfound(msg="Not Found"):
    sys.stdout.write(json.dumps({"message": msg, "status": "404"}) + "\n")
    sys.stderr.write("gh: %s (HTTP 404)\n" % msg); sys.exit(1)
def repo_of(full): return full.split("/")[-1] if full else None
def R(name):
    r = st["repos"].get(name)
    if r is None: notfound()
    return r
def main_sha(r, advance=True):
    seq = r["main"]
    i = r.get("main_i", 0)
    sha = seq[min(i, len(seq) - 1)]
    if advance:
        r["main_i"] = i + 1; save()
    return sha
def next_id():
    st["next_id"] = st.get("next_id", 9000) + 1; return st["next_id"]
def now(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def jsonsel(obj):
    fields_ = opt("--json")
    if not fields_ or not isinstance(obj, dict): return obj
    return {k: obj.get(k) for k in fields_.split(",")}

cmd = pos[:2]
if pos[:2] == ["auth", "status"]: sys.exit(0)

if pos and pos[0] == "api":
    ep = pos[1].lstrip("/")
    method = opt("-X", "--method", default=("POST" if fields else "GET"))
    path, _, q = ep.partition("?")
    qs = dict(urllib.parse.parse_qsl(q))
    seg = path.split("/")
    if path == "user": out({"login": "operator"})
    if seg[0] == "orgs":
        if seg[2:4] == ["actions", "secrets"]:
            if len(seg) == 4: out({"secrets": st.get("org_secrets", [])})
            notfound()
        if seg[2] == "packages" and len(seg) == 3:
            kind = qs.get("package_type", "container")
            out([{"name": n, "visibility": p["visibility"]} for n, p in st.get("packages", {}).get(kind, {}).items()])
        if seg[2] == "packages":
            kind = seg[3]; name = urllib.parse.unquote(seg[4])
            p = st.get("packages", {}).get(kind, {}).get(name)
            if p is None: notfound()
            if len(seg) == 6 and seg[5] == "versions": out(p.get("versions", []))
            out({"name": name, "visibility": p["visibility"]})
        notfound()
    if seg[0] != "repos": notfound()
    r = R(seg[2])
    rest = seg[3:]
    if not rest: out({"visibility": r.get("visibility", "public")})
    if rest[:3] == ["git", "ref", "heads"]: out({"object": {"type": "commit", "sha": main_sha(r)}})
    if rest[:3] == ["git", "ref", "tags"]:
        t = "/".join(rest[3:])
        if t in r.get("tags", {}): out({"ref": "refs/tags/" + t, "object": {"type": "commit", "sha": r["tags"][t]}})
        notfound()
    if rest[:3] == ["git", "matching-refs", "tags"]:
        p = "/".join(rest[3:])
        out([{"ref": "refs/tags/" + t} for t in sorted(r.get("tags", {})) if t.startswith(p)])
    if rest == ["git", "refs"] and method == "POST":
        ref = fields["ref"]; sha = fields["sha"]; t = ref[len("refs/tags/"):]
        if t in r.get("tags", {}): sys.stderr.write("gh: Reference already exists (HTTP 422)\n"); sys.exit(1)
        r.setdefault("tags", {})[t] = sha
        wf = r.get("tag_workflow", "release.yml")
        r.setdefault("runs", []).append({"databaseId": next_id(), "workflow": wf, "headBranch": t, "headSha": sha,
                                        "event": "push", "status": "completed", "conclusion": r.get("tag_result", "success"), "createdAt": now()})
        for pkg in r.get("publishes", []):
            kind = "container"
            p = st.setdefault("packages", {}).setdefault(kind, {}).setdefault(pkg, {"visibility": "private", "versions": []})
            p["versions"].append({"name": "sha256:%064x" % next_id(), "metadata": {"container": {"tags": [t.split("v", 1)[-1] if t.startswith("v") else t.rsplit("-v", 1)[-1]]}}})
        st.setdefault("tagged", []).append(seg[2]); save()
        out({"ref": ref, "object": {"sha": sha}})
    if rest and rest[0] == "contents":
        fp = "/".join(rest[1:])
        if fp in r.get("files", {}): out({"content": base64.b64encode(r["files"][fp].encode()).decode()})
        notfound()
    if rest and rest[0] == "compare":
        base = "/".join(rest[1:]).split("...")[0]
        c = r.get("compare", {}).get(base)
        if c is None: notfound()
        out({"status": "ahead", "ahead_by": c["ahead_by"], "commits": [{"sha": s} for s in c["commits"]]})
    if rest == ["commits"]:
        out([{"sha": s} for s in r.get("path_commits", {}).get(qs.get("path", ""), [])])
    if rest and rest[0] == "commits" and len(rest) == 2:
        out({"sha": rest[1], "files": [{"filename": f} for f in r.get("commit_files", {}).get(rest[1], [])]})
    notfound()

if pos[:1] == ["run"]:
    sub = pos[1]
    r = R(repo_of(opt("-R", "--repo")))
    runs = r.setdefault("runs", [])
    if sub == "list":
        rows = sorted(runs, key=lambda x: -x["databaseId"])
        wf = opt("--workflow", "-w"); br = opt("--branch", "-b"); ev = opt("--event", "-e"); stt = opt("--status", "-s")
        rows = [x for x in rows if (not wf or x["workflow"] == wf) and (not br or x["headBranch"] == br)
                and (not ev or x["event"] == ev) and (not stt or x["status"] == stt)]
        rows = rows[: int(opt("--limit", "-L", default=20))]
        f = (opt("--json") or "databaseId").split(",")
        out([{k: x.get(k) for k in f} for x in rows])
    rid = int(pos[2])
    run = next((x for x in runs if x["databaseId"] == rid), None)
    if run is None: notfound()
    if sub == "view":
        run.setdefault("jobs", [])
        out(jsonsel(run))
    if sub == "watch":
        sys.exit(0 if run["conclusion"] == "success" else 1)
    if sub == "rerun":
        run["status"] = "completed"; run["conclusion"] = r.get("rerun_result", "success"); save(); sys.exit(0)
    sys.exit(1)

if pos[:2] == ["secret", "list"]:
    out([{"name": n} for n in R(repo_of(opt("-R", "--repo"))).get("secrets", [])])
if pos[:2] == ["variable", "list"]: out([])
if pos[:2] == ["release", "view"]:
    r = R(repo_of(opt("-R", "--repo")))
    if pos[2] in r.get("releases", []): out({"tagName": pos[2], "url": "https://example.invalid/" + pos[2]})
    sys.stderr.write("release not found\n"); sys.exit(1)
if pos[:2] == ["workflow", "run"]:
    r = R(repo_of(opt("-R", "--repo")))
    r.setdefault("runs", []).append({"databaseId": next_id(), "workflow": pos[2], "headBranch": "main", "headSha": main_sha(r, False),
                                     "event": "workflow_dispatch", "status": "completed", "conclusion": "success", "createdAt": now()})
    save(); sys.exit(0)
if pos[:1] == ["pr"]:
    r = R(repo_of(opt("-R", "--repo")))
    pr = r.get("prs", {}).get(pos[2])
    if pr is None: notfound()
    if pos[1] == "view": out(jsonsel(pr))
    if pos[1] == "ready": pr["isDraft"] = False; save(); sys.exit(0)
    if pos[1] == "merge":
        if pr["isDraft"]: sys.stderr.write("draft\n"); sys.exit(1)
        new = pr["merges_to"]
        pr["state"] = "MERGED"; pr["mergeCommit"] = {"oid": new}
        r["main"] = [new]; r["main_i"] = 0
        r.setdefault("commit_files", {})[new] = pr.get("files", [])
        r.setdefault("runs", []).append({"databaseId": next_id(), "workflow": r.get("tag_workflow", "release.yml"), "headBranch": "main",
                                         "headSha": new, "event": "push", "status": "completed", "conclusion": "success", "createdAt": now()})
        save(); sys.exit(0)
sys.stderr.write("stub gh: unhandled: %r\n" % (argv,)); sys.exit(1)
STUB
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(python3 -c 'import json,sys; print(json.dumps(["docker"]+sys.argv[1:]))' "$@")" >> "$STUB_LOG"
exit 1
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/docker"

# ── fixtures ─────────────────────────────────────────────────────────────────
# fixture <scenario> <dir>: writes <dir>/state.json and <dir>/repos.tsv
fixture() {
  mkdir -p "$2"
  python3 - "$1" "$2" <<'PY'
import base64, json, sys, time
scen, d = sys.argv[1], sys.argv[2]
def ago(days): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - days * 86400))
SIGN = "      - run: cosign sign --yes \"$IMG\"\n      - uses: actions/attest-build-provenance@v2\n"
def wf(push_main=True, sign=True, paths=None, extra=""):
    s = "name: Release\non:\n  push:\n"
    if push_main: s += "    branches: [main]\n"
    if paths: s += "    paths:\n" + "".join("      - '%s'\n" % p for p in paths)
    s += "    tags: ['v*']\n  workflow_dispatch: {}\n\njobs:\n  release:\n    steps:\n" + (SIGN if sign else "      - run: docker push \"$IMG\"\n") + extra
    return s
def pom(v): return ('<?xml version="1.0"?>\n<project xmlns="http://maven.apache.org/POM/4.0.0">\n  <parent><groupId>net.hugmesh</groupId>'
                    '<artifactId>hugmesh-parent</artifactId><version>9.9.9-beta.9</version></parent>\n  <artifactId>x</artifactId>\n'
                    '  <version>%s</version>\n</project>\n' % v)
def pj(v): return json.dumps({"name": "x", "version": v}, indent=2) + "\n"
def run(i, wf_="release.yml", br="main", sha="m1", concl="success", status="completed", days=1, ev="push"):
    return {"databaseId": i, "workflow": wf_, "headBranch": br, "headSha": sha, "event": ev, "status": status, "conclusion": concl, "createdAt": ago(days)}
repos = {}; rows = []
def add(stage, name, kind, vfile, prefix, wfname, pkgs, **r):
    rows.append("|".join([str(stage), name, kind, vfile, prefix, wfname, pkgs]))
    r.setdefault("main", ["m-" + name]); r.setdefault("secrets", []); r.setdefault("tag_workflow", wfname)
    repos[name] = r
gen_files = {"studio/hugmesh_studio/__init__.py": '__version__ = "0.9.0-beta.1"\n'}
if scen == "mixed":
    add(1, "fx-lib-a", "mvn", "pom.xml", "v", "release.yml", "net.fx.lib-a",
        files={"pom.xml": pom("1.0.0-beta.1"), ".github/workflows/release.yml": wf(push_main=False)},
        tags={"v1.0.0-beta.1": "m-fx-lib-a"}, runs=[run(101, br="v1.0.0-beta.1", sha="m-fx-lib-a")])
    add(2, "fx-lib-b", "mvn", "pom.xml", "v", "release.yml", "net.fx.lib-b",
        files={"pom.xml": pom("2.0.0-beta.3"), ".github/workflows/release.yml": wf(push_main=False, extra="        env: {T: '${{ secrets.FX_TOKEN }}'}\n")},
        secrets=["FX_TOKEN"], tags={"v2.0.0-beta.1": "old", "v2.0.0-beta.2": "old2"})
    add(5, "hugmesh-gateway", "img", "pom.xml", "v", "release.yml", "hugmesh-gateway",
        files={"pom.xml": pom("0.3.0-beta.1"), ".github/workflows/release.yml": wf()},
        runs=[run(501, sha="m-hugmesh-gateway", concl="failure")])
    add(6, "fx-be", "img", "VERSION", "v", "release.yml", "fx-be",
        files={"VERSION": "0.1.0-beta.1\n", ".github/workflows/release.yml": wf(extra="  env:\n    PINNED_GATEWAY_IMAGE: ghcr.io/hugmesh/hugmesh-gateway:0.3.0-beta.1\n")},
        runs=[run(601, sha="m-fx-be", concl="failure")])
    add(7, "fx-api-old", "img", "pom.xml", "v", "release.yml", "fx-api-old",
        files={"pom.xml": pom("0.2.0-beta.1"), ".github/workflows/release.yml": wf()},
        runs=[run(701, sha="m-fx-api-old", concl="failure", days=40)])
    add(8, "fx-ui-ready", "img", "package.json", "v", "release.yml", "fx-ui-ready",
        files={"package.json": pj("0.3.0-beta.2"), ".github/workflows/release.yml": wf()},
        tags={"v0.3.0-beta.1": "old", "v0.3.1-beta": "odd"}, runs=[run(801, sha="m-fx-ui-ready")])
    add(8, "fx-ui-bump", "img", "package.json", "v", "release.yml", "fx-ui-bump",
        files={"package.json": pj("0.2.0-beta.1"), ".github/workflows/release.yml": wf()},
        tags={"v0.2.0-beta.1": "t-bump"}, runs=[run(811, br="v0.2.0-beta.1", sha="t-bump")],
        compare={"v0.2.0-beta.1": {"ahead_by": 3, "commits": ["c1", "c2", "c3"]}})
    add(8, "fx-ui-nosign", "img", "package.json", "v", "release.yml", "fx-ui-nosign",
        files={"package.json": pj("0.2.0-beta.1"), ".github/workflows/release.yml": wf(sign=False)},
        runs=[run(821, sha="m-fx-ui-nosign")])
    add(8, "fx-ui-badver", "img", "package.json", "v", "release.yml", "fx-ui-badver",
        files={"package.json": pj("1.0.0"), ".github/workflows/release.yml": wf()}, runs=[run(831, sha="m-fx-ui-badver")])
    add(8, "fx-ui-running", "img", "package.json", "v", "release.yml", "fx-ui-running",
        files={"package.json": pj("0.2.0-beta.1"), ".github/workflows/release.yml": wf()},
        tags={"v0.2.0-beta.1": "m-fx-ui-running"}, runs=[run(841, br="v0.2.0-beta.1", sha="m-fx-ui-running", status="in_progress", concl="")])
    add(9, "fx-php", "img", "composer.json", "v", "release.yml", "fx-php",
        files={"composer.json": json.dumps({"name": "fx/php", "version": "0.2.0-beta.1"}), ".github/workflows/release.yml": wf()},
        tags={"v0.2.0-beta.1": "m-fx-php"}, runs=[run(901, br="v0.2.0-beta.1", sha="m-fx-php")])
    gen_files.update({"clients/docker-mesh-node/VERSION": "0.1.0-beta.1\n",
                      ".github/workflows/mesh-node-release.yml": wf(paths=["clients/docker-mesh-node/**", ".github/workflows/mesh-node-release.yml"])})
    add(9, "hugmesh-generator", "img", "clients/docker-mesh-node/VERSION", "mesh-node-v", "mesh-node-release.yml", "hugmesh-mesh-node",
        files=gen_files, tags={"mesh-node-v0.1.0-beta.1": "t-node"},
        runs=[run(911, wf_="mesh-node-release.yml", br="mesh-node-v0.1.0-beta.1", sha="t-node")],
        compare={"mesh-node-v0.1.0-beta.1": {"ahead_by": 5, "commits": ["g1", "g2", "g3", "g4", "g5"]}},
        path_commits={"clients/docker-mesh-node": ["older1"], ".github/workflows/mesh-node-release.yml": ["older2"]},
        releases=["studio-v0.9.0-beta.1"])
    add(9, "fx-node2", "img", "clients/docker-mesh-node/VERSION", "mesh-node-v", "mesh-node-release.yml", "fx-node2",
        files={"clients/docker-mesh-node/VERSION": "0.4.0-beta.2\n",
               ".github/workflows/mesh-node-release.yml": wf(paths=["clients/docker-mesh-node/**"])},
        tags={"mesh-node-v0.4.0-beta.2": "t-n2"}, runs=[run(921, wf_="mesh-node-release.yml", br="mesh-node-v0.4.0-beta.2", sha="t-n2")],
        compare={"mesh-node-v0.4.0-beta.2": {"ahead_by": 4, "commits": ["h1", "h2", "h3", "h4"]}},
        path_commits={"clients/docker-mesh-node": ["h3", "older"]})
    pkgs = {"container": {"hugmesh-gateway": {"visibility": "private", "versions": []}, "fx-php": {"visibility": "public", "versions": []}}, "maven": {}}
elif scen == "release":
    add(1, "fx-lib-a", "mvn", "pom.xml", "v", "release.yml", "net.fx.lib-a",
        files={"pom.xml": pom("1.0.0-beta.1"), ".github/workflows/release.yml": wf(push_main=False)})
    add(2, "fx-lib-b", "mvn", "pom.xml", "v", "release.yml", "net.fx.lib-b",
        files={"pom.xml": pom("2.0.0-beta.1"), ".github/workflows/release.yml": wf(push_main=False)})
    add(5, "hugmesh-gateway", "img", "pom.xml", "v", "release.yml", "hugmesh-gateway", publishes=["hugmesh-gateway"],
        files={"pom.xml": pom("0.3.0-beta.1"), ".github/workflows/release.yml": wf()}, runs=[run(501, sha="m-hugmesh-gateway", concl="failure")])
    add(6, "fx-be", "img", "VERSION", "v", "release.yml", "fx-be",
        files={"VERSION": "0.1.0-beta.1\n", ".github/workflows/release.yml": wf(extra="  env:\n    PINNED_GATEWAY_IMAGE: ghcr.io/hugmesh/hugmesh-gateway:0.3.0-beta.1\n")},
        runs=[run(601, sha="m-fx-be", concl="failure")])
    add(7, "fx-api", "img", "pom.xml", "v", "release.yml", "fx-api",
        files={"pom.xml": pom("0.2.0-beta.1"), ".github/workflows/release.yml": wf()}, runs=[run(701, sha="m-fx-api", concl="failure")])
    add(8, "fx-ui", "img", "package.json", "v", "release.yml", "fx-ui",
        files={"package.json": pj("0.3.0-beta.2"), ".github/workflows/release.yml": wf()}, runs=[run(801, sha="m-fx-ui")],
        prs={"7": {"state": "OPEN", "isDraft": True, "mergeCommit": None, "merges_to": "m-fx-ui-merged", "files": ["src/app.ts"]}})
    gen_files.update({"clients/docker-mesh-node/VERSION": "0.1.0-beta.2\n",
                      ".github/workflows/mesh-node-release.yml": wf(paths=["clients/docker-mesh-node/**"])})
    add(9, "hugmesh-generator", "img", "clients/docker-mesh-node/VERSION", "mesh-node-v", "mesh-node-release.yml", "hugmesh-mesh-node",
        files=gen_files, runs=[run(911, wf_="mesh-node-release.yml", sha="m-hugmesh-generator")])
    pkgs = {"container": {}, "maven": {}}
repos["hugmesh.github.io"] = {"main": ["m-site"], "runs": [], "files": {"release-sources.json": json.dumps({
    "images": [{"repo": "hugmesh/fx-ui", "image": "ghcr.io/hugmesh/fx-ui", "group": "ui", "id": "fx-ui"}],
    "packages": [{"repo": "hugmesh/fx-lib-a", "id": "lib-a"}]})}}
json.dump({"repos": repos, "packages": pkgs, "org_secrets": []}, open(d + "/state.json", "w"), indent=1)
open(d + "/repos.tsv", "w").write("# fixture\n" + "\n".join(rows) + "\n")
PY
}

# run_script <script> <dir> args... -> stdout+stderr in <dir>/out, rc in <dir>/rc; calls in <dir>/calls
run_script() {
  local s=$1 d=$2; shift 2
  : > "$d/calls"
  PATH="$TMP/bin:$PATH" STUB_STATE="$d/state.json" STUB_LOG="$d/calls" RELEASE_BETA_TABLE="$d/repos.tsv" \
    RELEASE_BETA_POLL=0 RELEASE_BETA_TRIES=3 RELEASE_BETA_RETRY_SLEEP=0 TMPDIR="$TMP" \
    bash "$s" "$@" > "$d/out" 2>&1 < "${STDIN_FILE:-/dev/null}"
  echo $? > "$d/rc"
}
# writes <calls file> -> every write call, one per line (empty = none)
writes() {
  python3 - "$1" <<'PY'
import json, sys
W = {("run", "rerun"), ("run", "cancel"), ("workflow", "run"), ("workflow", "enable"), ("workflow", "disable"),
     ("pr", "merge"), ("pr", "ready"), ("pr", "edit"), ("pr", "close"), ("release", "create"), ("release", "edit"),
     ("release", "delete"), ("release", "upload"), ("secret", "set"), ("secret", "delete"), ("variable", "set"),
     ("variable", "delete"), ("repo", "edit")}
for line in open(sys.argv[1]):
    a = json.loads(line)
    if a[0] == "docker": print(" ".join(a)); continue
    a = a[1:]
    pos = [x for x in a if not x.startswith("-")]
    if pos[:1] == ["api"]:
        m = None
        for i, x in enumerate(a):
            if x in ("-X", "--method") and i + 1 < len(a): m = a[i + 1].upper()
            if x.startswith("--method="): m = x.split("=", 1)[1].upper()
        has_field = any(x in ("-f", "-F", "--field", "--raw-field", "--input") or x.startswith(("--field=", "--raw-field=", "--input=")) for x in a)
        if (m and m != "GET") or (m is None and has_field): print("gh " + " ".join(a))
        continue
    if tuple(pos[:2]) in W: print("gh " + " ".join(a))
PY
}
state_of() { # <out file> <repo> -> the state column of that repo's first row line
  awk -v r="$2" '$2==r && $1 ~ /^(DONE|READY|REFUSE|NEEDS-BUMP|RUNNING)$/ {print $1; exit}' "$1"
}

# ── B: version parsing, pure ─────────────────────────────────────────────────
echo "== B version files"
D="$TMP/b"; fixture mixed "$D"
v=$(RELEASE_BETA_TABLE="$D/repos.tsv" RELEASE_BETA_SOURCE_ONLY=1 bash -c '
  s=$1; shift; source "$s"
  printf "%s\n" "<project xmlns=\"http://maven.apache.org/POM/4.0.0\"><parent><version>9.9.9-beta.9</version></parent><version>2.2.0-beta.1</version></project>" | parse_version pom.xml
  printf "%s\n" "{\"name\":\"a\",\"version\":\"0.3.0-beta.2\"}" | parse_version package.json
  printf "%s\n" "{\"name\":\"a/b\",\"version\":\"0.2.0-beta.1\"}" | parse_version composer.json
  printf "0.2.0-beta.2\n\n" | parse_version VERSION
  printf " 0.1.0-beta.1 \n" | parse_version clients/docker-mesh-node/VERSION
  printf "{\"name\":\"a\"}\n" | parse_version package.json
  vercmp 0.3.0-beta.10 0.3.0-beta.2; vercmp 0.3.0-beta.2 0.3.1-beta.1; vercmp 1.0.0-beta.1 1.0.0-beta.1
  is_beta 0.3.0-beta.2 && echo beta-ok; is_beta 0.3.1-beta || echo nonbeta-refused; is_beta 1.0.0 || echo final-refused
  printf "on:\n  push:\n    branches: [main]\n    paths:\n      - \x27a/**\x27\n      - \"!b\"\n    tags: [\x27v*\x27]\njobs: {}\n" | wf_facts
  printf "on:\n  push:\n    tags: [\x27v*\x27]\n" | wf_facts
' _ "$SCRIPT" 2>&1)
want='2.2.0-beta.1
0.3.0-beta.2
0.2.0-beta.1
0.2.0-beta.2
0.1.0-beta.1

gt
lt
eq
beta-ok
nonbeta-refused
final-refused
push_main=yes
a/**
push_main=no'
if [ "$v" = "$want" ]; then ok "pom.xml (project version, not <parent>), package.json, composer.json, VERSION, mesh-node VERSION, vercmp, is_beta, wf_facts"
else bad "pure helpers: got"; printf '%s\n' "$v" | sed 's/^/      /'; fi

# ── A + C: dry run over the mixed fixture ────────────────────────────────────
echo "== A/C dry run classification"
check_classification() { # script -> 0 when every row classifies as expected
  local s=$1 d="$TMP/c.$RANDOM" r want got rc=0
  fixture mixed "$d"; run_script "$s" "$d" --no-studio
  while read -r r want; do
    got=$(state_of "$d/out" "$r")
    if [ "$got" != "$want" ]; then echo "      $r: want $want, got '${got:-<no row>}'"; rc=1; fi
  done <<'EOF'
fx-lib-a DONE
fx-lib-b READY
hugmesh-gateway REFUSE
fx-be REFUSE
fx-api-old REFUSE
fx-ui-ready READY
fx-ui-bump NEEDS-BUMP
fx-ui-nosign REFUSE
fx-ui-badver REFUSE
fx-ui-running RUNNING
fx-php DONE
hugmesh-generator DONE
fx-node2 NEEDS-BUMP
EOF
  cp "$d/out" "$TMP/last-classification.out"; cp "$d/calls" "$TMP/last-classification.calls"
  return "$rc"
}
if check_classification "$SCRIPT"; then ok "DONE/READY/REFUSE/NEEDS-BUMP/RUNNING for 13 fixture rows"; else bad "classification"; fi
O="$TMP/last-classification.out"
grep -a 'fx-ui-bump' "$O" | grep -a '3 commit(s) since it' >/dev/null && grep -a 'fx-ui-bump' "$O" | grep -a 'bumps package.json to 0.2.0-beta.2' >/dev/null \
  && ok "NEEDS-BUMP names the commit count and the next version" || bad "NEEDS-BUMP message: $(grep -a fx-ui-bump "$O" | head -1)"
grep -a 'fx-node2' "$O" | grep -a '1 commit(s) since it under clients/docker-mesh-node/\*\*' >/dev/null \
  && ok "paths filter: only the commit under the workflow's paths counts (1 of 4)" || bad "paths-filter count: $(grep -a fx-node2 "$O" | head -1)"
grep -a 'hugmesh-generator' "$O" | grep -a 'no commit since it that mesh-node-release.yml builds' >/dev/null \
  && ok "mesh-node stays DONE while main moves elsewhere (5 commits, none in its paths)" || bad "mesh-node DONE note"
grep -a 'fx-ui-nosign' "$O" | grep -a 'signing absent' >/dev/null && ok "REFUSE reason: signing absent" || bad "nosign reason"
grep -a 'fx-ui-badver' "$O" | grep -a "not MAJOR.MINOR.PATCH-beta.N" >/dev/null && ok "REFUSE reason: version not -beta.N" || bad "badver reason"
grep -a 'hugmesh-gateway' "$O" | grep -a 'gh run rerun 501 --failed' >/dev/null && ok "REFUSE reason: red main push run, with the rerun command" || bad "red-run reason"
grep -a 'fx-api-old' "$O" | grep -a 'cannot re-run it' >/dev/null && ok "G: a 40-day-old red run is reported as not re-runnable" || bad "old-run reason"
grep -a 'v0.3.1-beta' "$O" >/dev/null && bad "a non-conforming old tag (v0.3.1-beta) must not refuse a release" || ok "a non-conforming old tag (v0.3.1-beta) is ignored by the ordering check"
grep -aE '>> stage 6 needs stage\(s\) ([0-9] )*5 published first' "$O" >/dev/null && ok "overlays shown blocked on the gateway stage" || bad "overlay block line"
w=$(writes "$TMP/last-classification.calls")
n=$(grep -c . "$TMP/last-classification.calls")
if [ -z "$w" ] && [ "$n" -gt 50 ]; then ok "A: dry run made $n gh calls and ZERO writes"; else bad "A: dry run wrote: ${w:-none} (calls: $n)"; fi
writes_probe=$(printf '%s\n' '["gh","api","-X","POST","repos/o/r/git/refs"]' '["gh","api","repos/o/r/git/refs","-f","ref=x"]' '["gh","run","rerun","5"]' '["gh","pr","merge","1"]' '["gh","workflow","run","w"]' '["gh","release","create","t"]' '["docker","push","x"]' '["gh","api","repos/o/r"]' > "$TMP/probe.calls"; writes "$TMP/probe.calls" | grep -c .)
[ "$writes_probe" = 7 ] && ok "the write detector itself flags 7 of 7 planted writes and passes a read" || bad "write detector caught $writes_probe of 7"
grep -a 'fx-api-old' "$O" | grep -a 'would: gh run rerun 701' >/dev/null && bad "G: dry run plans to re-run a 40-day-old run" || ok "G: no re-run planned for the old run"

# Studio through the REAL scripts/release-studio.sh --dry-run, still zero writes
echo "== A studio dry run"
D="$TMP/s"; fixture mixed "$D"; run_script "$SCRIPT" "$D" --from studio --studio 0.9.0-beta.2
if grep -a 'Dry run: stopping here' "$D/out" >/dev/null && [ -z "$(writes "$D/calls")" ] && grep -a '"release", "view", "studio-v0.9.0-beta.2"' "$D/calls" >/dev/null; then
  ok "--studio 0.9.0-beta.2 runs release-studio.sh --dry-run, zero writes"
else bad "studio dry run"; sed 's/^/      /' "$D/out" | grep -a -A12 'phase 10' | head -20; fi

# ── D: the --only fix ────────────────────────────────────────────────────────
echo "== D --only"
check_only() { # script -> 0 when --only fx-lib-b (stage 2) is not blocked by its unselected, DONE stage 1
  local s=$1 d="$TMP/d.$RANDOM"
  fixture mixed "$d"; run_script "$s" "$d" --only fx-lib-b --no-studio          # the plan (dry run)
  grep -a 'would tag: fx-lib-b v2.0.0-beta.3' "$d/out" >/dev/null || return 1
  ! grep -a 'stage 2 would be BLOCKED' "$d/out" >/dev/null || return 1
  fixture mixed "$d"; run_script "$s" "$d" --apply --yes --only fx-lib-b --from maven --no-studio   # the act
  grep -a 'POST' "$d/calls" | grep -a 'repos/hugmesh/fx-lib-b/git/refs' >/dev/null || return 1
  [ "$(writes "$d/calls" | grep -ac 'git/refs')" = 1 ]                          # and nothing else tagged
}
if check_only "$SCRIPT"; then ok "--only fx-lib-b: stage 2 not blocked by the unselected but DONE stage 1 (plan and --apply; only it is tagged)"; else bad "--only blocks its own stage"; fi
D="$TMP/d2"; fixture mixed "$D"; run_script "$SCRIPT" "$D" --only fx-lib-b --no-studio
grep -a 'would tag: fx-ui-ready' "$D/out" >/dev/null && bad "--only acted on an unselected repo" || ok "--only: unselected READY rows are not planned"
D="$TMP/d3"; fixture mixed "$D"; run_script "$SCRIPT" "$D" --only no-such-repo
[ "$(cat "$D/rc")" = 2 ] && ok "--only with an unknown repo is refused (rc 2)" || bad "--only unknown repo rc $(cat "$D/rc")"

# ── E: tag SHA re-check ──────────────────────────────────────────────────────
echo "== E main moves between the check and the tag"
check_main_move() { # script -> 0 when a moved main is NOT tagged
  local s=$1 d="$TMP/e.$RANDOM"
  fixture release "$d"
  # fx-ui's main: read 1 (preflight), read 2 (the apps phase re-check), read 3 (right before tagging) moves
  python3 - "$d/state.json" <<'PY'
import json, sys
p = sys.argv[1]; st = json.load(open(p))
st["repos"]["fx-ui"]["main"] = ["m-fx-ui", "m-fx-ui", "m-fx-ui-moved"]
json.dump(st, open(p, "w"))
PY
  run_script "$s" "$d" --apply --yes --only fx-ui --from apps --no-studio
  grep -a 'STOP fx-ui: main moved' "$d/out" >/dev/null || return 1
  ! grep -a 'git/refs' "$d/calls" | grep -a POST >/dev/null || return 1
  [ "$(cat "$d/rc")" = 1 ]
}
if check_main_move "$SCRIPT"; then ok "main moved after the check: STOP, no tag created, rc 1, resume command printed"; else bad "main move was tagged anyway"; fi

# ── F: a full --apply, stage ordering ────────────────────────────────────────
echo "== F full apply ordering"
D="$TMP/f"; fixture release "$D"
printf '\n\n\n\n\n\n\n\n' > "$TMP/enters"
STDIN_FILE="$TMP/enters" run_script "$SCRIPT" "$D" --apply --yes --merge fx-ui#7 --no-studio
order=$(python3 - "$D/calls" <<'PY'
import json, sys
ev = []
for line in open(sys.argv[1]):
    a = json.loads(line)[1:]
    if a[:1] == ["api"] and "POST" in a and any(x.endswith("/git/refs") for x in a):
        ev.append("tag:" + [x for x in a if x.endswith("/git/refs")][0].split("/")[2])
    elif a[:2] == ["run", "rerun"]:
        ev.append("rerun:" + a[a.index("-R") + 1].split("/")[1])
    elif a[:2] in (["pr", "merge"], ["pr", "ready"], ["workflow", "run"]):
        ev.append(a[0] + "-" + a[1] + ":" + (a[a.index("-R") + 1].split("/")[1] if "-R" in a else "?"))
print(" ".join(ev))
PY
)
want_order="pr-ready:fx-ui pr-merge:fx-ui tag:fx-lib-a tag:fx-lib-b tag:fx-ui tag:hugmesh-generator rerun:hugmesh-gateway rerun:fx-api tag:hugmesh-gateway rerun:fx-be tag:fx-be tag:fx-api workflow-run:hugmesh.github.io"
if [ "$order" = "$want_order" ]; then ok "merge, Maven 1->2, apps, re-runs, gateway, overlay re-run+tag, Java, site: in that order"
else bad "write order"; echo "      want: $want_order"; echo "      got:  $order"; fi
[ "$(cat "$D/rc")" = 0 ] && grep -a '== every artifact is DONE' "$D/out" >/dev/null && ok "the final verification reads every artifact DONE (rc 0)" \
  || { bad "final verify: rc $(cat "$D/rc")"; tail -25 "$D/out" | sed 's/^/      /'; }
grep -a 'Manage Actions access' "$D/out" >/dev/null && grep -a 'Did you grant Read' "$D/out" >/dev/null \
  && ok "gateway-access paused for the private base image and asked about Actions access" || bad "gateway-access pause"
grep -a 'tag:fx-be' <<<"$order" >/dev/null && [[ "$order" == *"tag:hugmesh-gateway"*"tag:fx-be"* ]] && ok "the overlay is tagged only after the gateway it builds FROM" || bad "overlay before gateway"
D="$TMP/f2"; fixture release "$D"
STDIN_FILE="$TMP/enters" run_script "$SCRIPT" "$D" --apply --yes --no-studio
n1=$(grep -ac POST "$D/calls"); STDIN_FILE="$TMP/enters" run_script "$SCRIPT" "$D" --apply --yes --no-studio
if [ -z "$(writes "$D/calls" | grep -v 'workflow run pages.yml')" ] && [ "$(cat "$D/rc")" = 0 ] && [ "$n1" -gt 0 ]; then ok "resumable: a second --apply finds everything DONE and writes nothing but the site refresh"
else bad "second apply wrote: $(writes "$D/calls" | head -3)"; fi
D="$TMP/f3"; fixture release "$D"; printf 'n\n' > "$TMP/no"
STDIN_FILE="$TMP/no" run_script "$SCRIPT" "$D" --apply --no-studio
if [ -z "$(writes "$D/calls")" ] && [ "$(cat "$D/rc")" = 1 ] && grep -a -- '--from maven' "$D/out" >/dev/null; then ok "answering n to the first y/N writes nothing and prints the resume command"
else bad "a declined prompt still wrote: $(writes "$D/calls" | head -3)"; fi

# ── M: mutation battery ──────────────────────────────────────────────────────
echo "== M mutations (break the production guard in a copy; the covering check must go red)"
mutate() { # name sed-expression check-function
  local name=$1 expr=$2 check=$3 m="$TMP/mut-$1.sh"
  sed "$expr" "$SCRIPT" > "$m"
  if cmp -s "$SCRIPT" "$m"; then bad "mutation $name did not change the script (the guard moved?): fix this battery"; return; fi
  if "$check" "$m" >/dev/null 2>&1; then bad "mutation $name SURVIVED: $check stayed green with the guard broken"
  else ok "mutation $name caught by $check"; fi
}
# M1 the main re-check right before tagging
mutate main-recheck 's/if \[ "\$cur" != "\$sha" \]; then/if false; then/' check_main_move
# M2 the --only fix: an unselected dependency row stops counting as published
mutate only-fix 's/^stage_published() { local r; for r in \$(rows_in_stage "\$1"); do published "\$r" || return 1; done; return 0; }/stage_published() { local r; for r in $(rows_in_stage "$1"); do { published "$r" \&\& selected "$r"; } || return 1; done; return 0; }/' check_only
# M2b the same fix in the dry-run plan
mutate only-fix-plan 's/^    published "\$r" \&\& continue$/    published "$r" \&\& selected "$r" \&\& continue/' check_only
# M3 the NEEDS-BUMP boundary: commits since the tag stop counting
mutate needs-bump 's/if \[ "\$n" = 0 \]; then/if true; then/' check_classification

echo
echo "== test-release-beta.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
