#!/usr/bin/env bash
# release.sh — ONE command for a full HugMesh org release, beta or stable (docs/RELEASING.md).
#
#   scripts/release.sh                              # = --channel beta --dry-run: read-only plan
#   scripts/release-beta.sh ...                     # the same as scripts/release.sh --channel beta ...
#   scripts/release.sh --channel beta --apply --studio 0.3.0-beta.2
#                                                   # run every phase in order, asking y/N before each write
#   scripts/release.sh --apply --merge hugmesh-games#50 --studio next
#   scripts/release.sh --apply --from java          # resume at a phase (re-running skips DONE work anyway)
#   scripts/release.sh --apply --only hugmesh-admin-ui   # act on these repos only (repeatable);
#                                                   # stages with none of them are skipped, never a stop
#   scripts/release.sh --urls                       # only list the packages that are not public yet
#   scripts/release.sh --channel stable             # dry run of a stable cut: release/X.Y per repo
#   scripts/release.sh --channel stable --apply     # cut, bump PRs, tag, next-beta PRs (asks first)
#   scripts/release.sh --channel stable --version 0.3.1 --only hugmesh-admin-ui
#                                                   # a patch release on the existing release/0.3
#
# Options: --channel beta|stable (default beta)   --dry-run (default) | --apply
#   --yes (answer y to every y/N; each action is still printed)
#   --merge <repo>#<n> (repeatable)   --only <repo> (repeatable)   --from <phase>
#   --studio <version>|next | --no-studio   --expect <repo>=<version> (repeatable pin)
#   --version X.Y.Z (stable only, needs --only: a patch release on release/X.Y)
#
# Phases, beta:   preflight merge maven apps rerun gateway gateway-access overlays java
#                 studio visibility site verify
# Phases, stable: preflight cut bump merge maven apps rerun gateway gateway-access overlays
#                 java studio visibility site next verify
#
# Versions are never typed here (except a stable patch's --version): each repo's version
# is read from its version file (scripts/release/repos.tsv says which file). BETA releases
# main, whose version must be MAJOR.MINOR.PATCH-beta.N. STABLE releases the repo's own
# release/X.Y branch as X.Y.Z, where X.Y.Z is main's beta with the -beta.N dropped (a cut)
# or --version (a patch). Every repo is reported as DONE (tag exists and its run is
# green), READY, REFUSE (with the reason and the next command), NEEDS-BUMP (beta: the
# published tag IS main's version but main has commits since it), RUNNING (its tag run is
# in flight), and on the stable channel NEEDS-CUT (release/X.Y does not exist yet: the
# cut phase creates it) or NEEDS-PR (release/X.Y does not carry X.Y.Z yet: the bump phase
# opens the version-bump PR).
#
# Every gh call goes through GH() with GH_TOKEN/GITHUB_TOKEN unset (an exported read-only
# token shadows the keyring login on this fleet). No secret value is ever read or printed.
# Under --dry-run nothing writes: no POST/PATCH/PUT/DELETE, no run rerun, workflow run,
# pr create/merge/ready or release create (tests/scripts/test-release-beta.sh proves it).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ORG="${RELEASE_BETA_ORG:-hugmesh}"
TABLE="${RELEASE_BETA_TABLE:-$HERE/release/repos.tsv}"
STUDIO_SCRIPT="${RELEASE_BETA_STUDIO_SCRIPT:-$HERE/release-studio.sh}"
SITE_REPO="$ORG/hugmesh.github.io"
POLL="${RELEASE_BETA_POLL:-10}"            # seconds between polls
TRIES="${RELEASE_BETA_TRIES:-30}"          # polls before "no run appeared" (30 x 10 s = 5 min)
RERUN_MAX_DAYS=30                          # GitHub refuses to re-run a run older than this
BETA_PHASES=(preflight merge maven apps rerun gateway gateway-access overlays java studio visibility site verify)
STABLE_PHASES=(preflight cut bump merge maven apps rerun gateway gateway-access overlays java studio visibility site next verify)

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

MODE=dry; YES=false; FROM=preflight; STUDIO=""; URLS_ONLY=false; CHANNEL=beta; PATCH_VERSION=""
ONLY=(); MERGES=(); declare -A EXPECT=()
ORIG_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) shift; CHANNEL="${1:?--channel needs beta or stable}" ;;
    --channel=*) CHANNEL="${1#--channel=}" ;;
    --version) shift; PATCH_VERSION="${1:?--version needs X.Y.Z}"; ORIG_ARGS+=(--version "$1") ;;
    --dry-run|-n) MODE=dry ;;
    --apply) MODE=apply ;;
    --yes|-y) YES=true; ORIG_ARGS+=("$1") ;;
    --urls) URLS_ONLY=true ;;
    --only) shift; ONLY+=("${1:?--only needs a repo}"); ORIG_ARGS+=(--only "$1") ;;
    --merge) shift; MERGES+=("${1:?--merge needs <repo>#<number>}"); ORIG_ARGS+=(--merge "$1") ;;
    --from) shift; FROM="${1:?--from needs a phase}" ;;
    --studio) shift; STUDIO="${1:?--studio needs a version, or next}"; ORIG_ARGS+=(--studio "$1") ;;
    --no-studio) STUDIO=none; ORIG_ARGS+=("$1") ;;
    --expect) shift; e="${1:?--expect needs <repo>=<version>}"; [[ "$e" == *=* ]] || { echo "release.sh: --expect needs <repo>=<version>, got '$e'" >&2; exit 2; }
              EXPECT[${e%%=*}]="${e#*=}"; ORIG_ARGS+=(--expect "$e") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
case "$CHANNEL" in
  beta) PHASES=("${BETA_PHASES[@]}") ;;
  stable) PHASES=("${STABLE_PHASES[@]}") ;;
  *) echo "release.sh: --channel must be beta or stable, got '$CHANNEL'" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }
die() { say "release.sh: $*" >&2; exit 2; }
GH() { env -u GH_TOKEN -u GITHUB_TOKEN gh "$@" </dev/null; }
# ghq: like GH, but prints NOTHING and returns 1 on any error (gh prints the JSON error body
# to stdout on HTTP errors, which must never be mistaken for data). A 404 is an answer; any
# other error (a secondary rate limit, a dropped connection) is retried twice, because an
# empty answer here reads as "no run" / "no tag" and would misreport a repo's state.
RETRY_SLEEP="${RELEASE_BETA_RETRY_SLEEP:-5}"
# ghs: ghq with the 404 told apart: rc 0 data, rc 4 "not found" (HTTP 404, release not
# found), rc 1 anything else (after the retries). For checks that must fail closed.
ghs() {
  local o e i
  e=$(mktemp "${TMPDIR:-/tmp}/release-beta.XXXXXX")
  for i in 1 2 3; do
    if o=$(GH "$@" 2>"$e"); then rm -f "$e"; printf '%s' "$o"; return 0; fi
    if grep -a 'HTTP 404' "$e" >/dev/null || grep -a 'release not found' "$e" >/dev/null; then rm -f "$e"; return 4; fi
    [ "$i" = 3 ] || sleep "$RETRY_SLEEP"
  done
  rm -f "$e"; return 1
}
ghq() { ghs "$@" || return 1; }

# A path as it is safe to paste into a PR or a chat: relative to this checkout, or just
# its file name when it lies outside it (never a home directory).
shown() {
  case "$1" in
    "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
    *) printf '%s (outside the checkout)' "$(basename "$1")" ;;
  esac
}

# The exact command that resumes this run at a phase.
resume_cmd() {
  if [ "$CHANNEL" = beta ]; then printf 'scripts/release-beta.sh --apply'; else printf 'scripts/release.sh --channel %s --apply' "$CHANNEL"; fi
  [ ${#ORIG_ARGS[@]} -eq 0 ] || printf ' %q' "${ORIG_ARGS[@]}"
  printf ' --from %s\n' "$1"
}
next_phase() { local i; i=$(phase_index "$1"); echo "${PHASES[$((i+1))]:-verify}"; }

phase_index() { local i; for i in "${!PHASES[@]}"; do [ "${PHASES[$i]}" = "$1" ] && { echo "$i"; return 0; }; done; return 1; }
FROM_I=$(phase_index "$FROM") || die "--from: unknown phase '$FROM' (phases: ${PHASES[*]})"

# ── the table ────────────────────────────────────────────────────────────────
[ -r "$TABLE" ] || die "cannot read the repo table $TABLE"
ROWS=()
declare -A T_STAGE=() T_KIND=() T_VFILE=() T_PREFIX=() T_WF=() T_PKGS=() T_MIRRORS=()
while IFS='|' read -r st repo kind vfile prefix wf pkgs mirrors; do
  case "$st" in ''|'#'*) continue ;; esac
  case "$st" in [1-9]) ;; *) die "$TABLE: bad stage '$st' for '$repo'" ;; esac
  case "$kind" in mvn|img) ;; *) die "$TABLE: bad kind '$kind' for '$repo'" ;; esac
  [ -n "$repo" ] && [ -n "$vfile" ] && [ -n "$prefix" ] && [ -n "$wf" ] && [ -n "$pkgs" ] || die "$TABLE: incomplete row for '$repo'"
  [ -z "${T_STAGE[$repo]:-}" ] || die "$TABLE: '$repo' is listed twice"
  ROWS+=("$repo")
  T_STAGE[$repo]=$st; T_KIND[$repo]=$kind; T_VFILE[$repo]=$vfile; T_PREFIX[$repo]=$prefix; T_WF[$repo]=$wf; T_PKGS[$repo]=$pkgs; T_MIRRORS[$repo]=${mirrors:-}
done < "$TABLE"
[ ${#ROWS[@]} -gt 0 ] || die "$TABLE has no rows"
for o in "${ONLY[@]}"; do [ -n "${T_STAGE[$o]:-}" ] || die "--only $o: not a repo in $TABLE"; done
for o in "${!EXPECT[@]}"; do [ -n "${T_STAGE[$o]:-}" ] || die "--expect $o: not a repo in $TABLE"; done
for m in "${MERGES[@]}"; do [[ "$m" =~ ^[A-Za-z0-9._-]+#[0-9]+$ ]] || die "--merge '$m': expected <repo>#<number>"; done
if [ -n "$STUDIO" ] && [ "$STUDIO" != none ] && [ "$STUDIO" != next ] && [ "$CHANNEL" = beta ]; then
  [[ "$STUDIO" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] || die "--studio '$STUDIO': expected MAJOR.MINOR.PATCH-beta.N, or next"
fi
if [ -n "$PATCH_VERSION" ]; then
  [ "$CHANNEL" = stable ] || die "--version is for --channel stable (a beta's version is always main's version file)"
  [[ "$PATCH_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version '$PATCH_VERSION': expected MAJOR.MINOR.PATCH"
  [ ${#ONLY[@]} -gt 0 ] || die "--version $PATCH_VERSION needs --only <repo>: every repository has its own version line, so a patch names the repositories it is for"
fi

stage_title() {
  case "$1" in
    1) echo "Maven chain 1/4: build-config" ;;
    2) echo "Maven chain 2/4: parent (needs 1)" ;;
    3) echo "Maven chain 3/4: commons (needs 1-2)" ;;
    4) echo "Maven chain 4/4: auth-core (needs 1-3)" ;;
    5) echo "Gateway base image (needs 1-3)" ;;
    6) echo "Gateway overlays be/fe/pki (FROM the gateway image; need 5)" ;;
    7) echo "Java BFF/API images (need 1-4)" ;;
    8) echo "Angular UI images (no Maven dependency)" ;;
    9) echo "Games, forum-api (PHP), mesh-node (no Maven dependency)" ;;
  esac
}
stage_deps() {
  case "$1" in
    2) echo 1 ;; 3) echo "1 2" ;; 4) echo "1 2 3" ;; 5) echo "1 2 3" ;; 6) echo "1 2 3 5" ;; 7) echo "1 2 3 4" ;;
    *) echo "" ;;
  esac
}
rows_in_stage() { local r; for r in "${ROWS[@]}"; do [ "${T_STAGE[$r]}" = "$1" ] && echo "$r"; done; return 0; }

# --only selects what this run ACTS on. It never changes what a row IS: every row is
# classified, and a dependency stage counts as published when ALL its rows are DONE,
# whether or not they were selected. (release-all-20261022.sh marked every unselected row
# not-OK, so `--only <one downstream repo>` blocked its own stage.) A stage with no
# selected row is reported and skipped, never a stop; a stage with selected rows succeeds
# when its SELECTED rows are published. So `--only <a UI>` tags that UI whatever state the
# Maven chain is in, and `--only <a Java image>` still stops at its own stage when a Maven
# link it builds on is not published.
selected() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local o; for o in "${ONLY[@]}"; do [ "$o" = "$1" ] && return 0; done; return 1
}
stage_has_selected() { local r; for r in $(rows_in_stage "$1"); do selected "$r" && return 0; done; return 1; }

# ── version helpers ──────────────────────────────────────────────────────────
is_beta() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]; }
# vercmp A B -> lt|eq|gt (each MAJOR.MINOR.PATCH-beta.N or MAJOR.MINOR.PATCH; a final sorts
# after every beta of the same MAJOR.MINOR.PATCH)
vercmp() {
  local a b i x y
  IFS='.-' read -r -a a <<<"${1/-beta./.0.}"
  IFS='.-' read -r -a b <<<"${2/-beta./.0.}"
  [[ "$1" == *-beta.* ]] || a[4]=2147483647
  [[ "$2" == *-beta.* ]] || b[4]=2147483647
  for i in 0 1 2 4; do
    x=${a[$i]:-0}; y=${b[$i]:-0}
    if [ "$((10#$x))" -lt "$((10#$y))" ]; then echo lt; return; fi
    if [ "$((10#$x))" -gt "$((10#$y))" ]; then echo gt; return; fi
  done
  echo eq
}
next_beta() { echo "${1%.*}.$(( ${1##*.} + 1 ))"; }
is_stable() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# b64-decoded file at a ref, via the contents API
file_at() { # repo ref path
  local b
  b=$(ghq api "repos/$ORG/$1/contents/$3?ref=$2" --jq .content) || return 1
  printf '%s' "$b" | base64 -d 2>/dev/null
}

# parse_version <version file name>  (file body on stdin) -> the version, or nothing
parse_version() {
  case "$(basename "$1")" in
    pom.xml)
      python3 -I -c '
import sys, xml.etree.ElementTree as E
try:
    r = E.fromstring(sys.stdin.read())
except Exception:
    sys.exit(0)
v = r.find("{http://maven.apache.org/POM/4.0.0}version")
if v is None: v = r.find("version")
print(v.text.strip() if v is not None and v.text else "")' ;;
    package.json|composer.json)
      python3 -I -c '
import json, sys
try:
    v = json.load(sys.stdin).get("version", "")
except Exception:
    v = ""
print(v if isinstance(v, str) else "")' ;;
    *) head -n 1 | tr -d '[:space:]'; echo ;;
  esac
}
read_version() { # repo sha versionfile
  local body
  body=$(file_at "$1" "$2" "$3") || return 1
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | parse_version "$3"
}

# wf_facts (workflow YAML on stdin) -> "push_main=yes|no", then one on.push.paths glob per line.
# Stdlib only (no PyYAML): a line scanner over the `on:` block, which is all it needs.
# wf_branches (workflow YAML on stdin) -> one on.push.branches entry per line.
wf_facts() { python3 -I -c "$WF_PY" facts; }
wf_branches() { python3 -I -c "$WF_PY" branches; }
WF_PY='
import re, sys
ind = lambda l: len(l) - len(l.lstrip(" "))
def items(v): return [x.strip().strip("\x27\"") for x in v.strip()[1:-1].split(",") if x.strip()]
on_i = push_i = key_i = None; key = None; d = {}
for l in sys.stdin.read().splitlines():
    if l.strip().startswith("#"): continue
    s = re.sub(r"\s+#.*$", "", l).strip()
    if not s: continue
    i = ind(l)
    if on_i is None:
        if i == 0 and re.match(r"^[\"\x27]?on[\"\x27]?\s*:\s*$", s): on_i = 0
        continue
    if i <= on_i: break
    if key is not None:
        if s.startswith("- ") and i >= key_i:
            d[key].append(s[2:].strip().strip("\x27\"")); continue
        key = None
    if push_i is not None and i <= push_i: push_i = None
    if push_i is None:
        if re.match(r"^push\s*:\s*$", s): push_i = i
        continue
    m = re.match(r"^([A-Za-z_-]+)\s*:\s*(.*)$", s)
    if m:
        k, v = m.group(1), m.group(2)
        d.setdefault(k, [])
        if v.startswith("["): d[k] += items(v)
        elif v: d[k].append(v.strip("\x27\""))
        else: key = k; key_i = i
if sys.argv[1:] == ["branches"]:
    for b in d.get("branches", []): print(b)
    sys.exit(0)
print("push_main=" + ("yes" if "main" in d.get("branches", []) else "no"))
for p in d.get("paths", []):
    if not p.startswith("!"): print(p)'

# ── org-level facts ──────────────────────────────────────────────────────────
OPTIONAL_SECRETS=" SITE_DISPATCH_TOKEN PACKAGES_READ_ACTOR STUDIO_AUTHENTICODE_PFX_BASE64 STUDIO_AUTHENTICODE_PFX_PASSWORD ADMIN_BFF_READ_TOKEN RELEASE_CHAIN_TOKEN "
ORG_SECRETS_STATE=unknown; ORG_SECRETS=""
load_org_secrets() {
  local out
  if out=$(GH api "/orgs/$ORG/actions/secrets?per_page=100" --jq '.secrets[]|.name+"="+.visibility' 2>&1); then
    ORG_SECRETS_STATE=ok; ORG_SECRETS="$out"
  else
    ORG_SECRETS_STATE="unreadable ($(printf '%s' "$out" | head -1 | cut -c1-80))"
  fi
}
# secret_present repo NAME -> prints where; names only, never a value
secret_present() {
  local repo_secrets line vis
  if ! repo_secrets=$(ghq secret list -R "$ORG/$1" --json name -q '.[].name'); then echo "repo secret list unreadable"; return 1; fi
  if printf '%s\n' "$repo_secrets" | grep -axF -- "$2" >/dev/null; then echo repo; return 0; fi
  if [ "$ORG_SECRETS_STATE" = ok ]; then
    line=$(printf '%s\n' "$ORG_SECRETS" | grep -a "^$2=" || true)
    if [ -n "$line" ]; then
      vis=${line#*=}
      if [ "$vis" = all ] || [ "$vis" = public ]; then echo "org($vis)"; return 0; fi
      if ghq api "/orgs/$ORG/actions/secrets/$2/repositories" --jq '.repositories[].name' | grep -axF -- "$1" >/dev/null; then
        echo "org(selected)"; return 0
      fi
    fi
    echo missing; return 1
  fi
  echo "missing-in-repo; org secrets $ORG_SECRETS_STATE"; return 1
}

# ── classification (read-only) ───────────────────────────────────────────────
# Per repo: S_STATE DONE|READY|REFUSE|NEEDS-BUMP|RUNNING, S_REASON, S_NOTE, S_SHA (main),
# S_VER, S_TAG, S_RERUN (id of a red main push run that a re-run can fix, when that is the
# ONLY reason), S_BUSY (id of a main push run still in flight), S_TAGRUN (the tag's run),
# S_TAGRERUN (id of a red TAG run that published nothing, so re-running it is the fix).
declare -A S_STATE=() S_REASON=() S_NOTE=() S_SHA=() S_VER=() S_TAG=() S_RERUN=() S_BUSY=() S_TAGRUN=() S_OLD=() S_TAGRERUN=()

# tag_commit repo tag -> prints the COMMIT sha; rc 0 found, 1 absent, 2 cannot tell
tag_commit() {
  local out typ sha
  if out=$(GH api "repos/$ORG/$1/git/ref/tags/$2" --jq '.object.type+" "+.object.sha' 2>&1); then
    read -r typ sha <<<"$out"
    if [ "$typ" = tag ]; then sha=$(ghq api "repos/$ORG/$1/git/tags/$sha" --jq .object.sha) || { echo "annotated tag $2 unreadable"; return 2; }; fi
    printf '%s' "$sha"; return 0
  fi
  case "$out" in *'HTTP 404'*|*'"status":"404"'*|*'Not Found'*) return 1 ;; esac
  printf '%s' "$out" | head -1 | cut -c1-120; return 2
}

# commits_since repo base paths... -> number of main commits since base (a tag or a commit
# sha) that the workflow would build (all of them when it has no paths filter)
commits_since() {
  local repo=$1
  local base=$2
  shift 2
  local cmp ahead shas p pfx rel n=0 s
  cmp=$(ghq api "repos/$ORG/$repo/compare/$base...${CS_REF:-main}" --jq '(.ahead_by|tostring), .commits[].sha') || { echo "?"; return 1; }
  ahead=$(printf '%s\n' "$cmp" | head -1)
  if [ $# -eq 0 ]; then echo "$ahead"; return 0; fi
  shas=$(printf '%s\n' "$cmp" | tail -n +2)
  rel=""
  for p in "$@"; do
    pfx=${p%%\**}; pfx=${pfx%/}
    rel="$rel"$'\n'"$(ghq api "repos/$ORG/$repo/commits?sha=${CS_REF:-main}&path=$pfx&per_page=100" --jq '.[].sha' || true)"
  done
  for s in $shas; do printf '%s\n' "$rel" | grep -axF -- "$s" >/dev/null && n=$((n+1)); done
  echo "$n"
}

run_age_days() { # ISO-8601 -> whole days ago
  local t now
  t=$(date -u -d "$1" +%s 2>/dev/null) || { echo 0; return; }
  now=$(date -u +%s)
  echo $(( (now - t) / 86400 ))
}

# pkg_has_version kind package version -> rc 0 listed, 1 absent (no such version, or no such
# package), 2 cannot tell. kind is the repos.tsv kind (img = GHCR image, mvn = Maven).
pkg_has_version() {
  local enc typ jq out rc=0
  enc=$(printf '%s' "$2" | sed 's#/#%2F#g')
  if [ "$1" = img ]; then typ=container; jq='.[].metadata.container.tags[]'; else typ=maven; jq='.[].name'; fi
  out=$(ghs api "/orgs/$ORG/packages/$typ/$enc/versions?per_page=100" --paginate --jq "$jq") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | grep -axF -- "$3" >/dev/null && return 0; return 1 ;;
    4) return 1 ;;
  esac
  return 2
}

# A step that publishes something: a registry push, a package deploy, an attestation or a
# GitHub Release. A tag run that got past one of these has burned its beta number.
PUBLISH_STEP_RE='publish|push|upload|deploy|attest|release'
# A step that checks the world around the commit, not the commit: the version job, the
# cross-repo package-read preflight, the base-image pull check, checkout and setup. Its
# failure is fixed by a re-run once the world is right (an upstream package published).
# A failed test or build step is the tagged commit's own fault, and a re-run repeats it.
PREFLIGHT_JOB_RE='^(version|preflight)'
PREFLIGHT_STEP_RE='preflight|version|cross-repo|package read|pull|set up job|check ?out|log ?in'
# tag_run_unpublished repo run-id created-at -> rc 0 when the tag's run failed in a preflight
# step BEFORE it published anything (no publish step succeeded or failed, no package carries
# the version, there is no GitHub Release for the tag, and it is the run's first attempt),
# so `gh run rerun --failed` is the fix and no bump is needed. Prints the evidence, or why
# not. Anything it cannot read means "no" (the bump advice stays).
tag_run_unpublished() {
  local repo=$1 rid=$2 created=$3 facts att=1 failed="" fjob="" fstep="" pubstep="" con job step p rc age
  local ver=${S_VER[$1]} tag=${S_TAG[$1]}
  age=$(run_age_days "$created")
  if [ "$age" -ge "$RERUN_MAX_DAYS" ]; then echo "it is $age days old, and GitHub cannot re-run it"; return 1; fi
  facts=$(ghq run view "$rid" -R "$ORG/$repo" --json attempt,jobs \
          -q '"attempt\t\(.attempt // 1)", (.jobs[] as $j | $j.steps[]? | "\(.conclusion // "")\t\($j.name)\t\(.name)")') \
    || { echo "its jobs are unreadable"; return 1; }
  while IFS=$'\t' read -r con job step; do
    if [ "$con" = attempt ]; then att=$job; continue; fi
    case "$con" in
      failure|timed_out|cancelled)
        if [[ "${step,,}" =~ $PUBLISH_STEP_RE ]]; then echo "it failed in the publish step '$job / $step'"; return 1; fi
        [ -n "$failed" ] || { failed="$job / $step"; fjob=$job; fstep=$step; } ;;
      success)
        [[ "${step,,}" =~ $PUBLISH_STEP_RE ]] && pubstep="$job / $step" ;;
    esac
  done <<<"$facts"
  if [ -n "$pubstep" ]; then echo "its step '$pubstep' succeeded"; return 1; fi
  if [ -z "$failed" ]; then echo "no failed step is recorded"; return 1; fi
  if [ "${att:-1}" != 1 ]; then echo "it failed in '$failed' again on attempt $att, so a re-run does not fix it"; return 1; fi
  for p in ${T_PKGS[$repo]}; do
    rc=0; pkg_has_version "${T_KIND[$repo]}" "$p" "$ver" || rc=$?
    case "$rc" in
      0) echo "$p:$ver is published"; return 1 ;;
      2) echo "cannot tell whether $p:$ver was published"; return 1 ;;
    esac
  done
  rc=0; ghs release view "$tag" -R "$ORG/$repo" --json tagName >/dev/null || rc=$?
  case "$rc" in
    0) echo "GitHub Release $tag exists"; return 1 ;;
    4) ;;
    *) echo "cannot tell whether GitHub Release $tag exists"; return 1 ;;
  esac
  if ! [[ "${fjob,,}" =~ $PREFLIGHT_JOB_RE ]] && ! [[ "${fstep,,}" =~ $PREFLIGHT_STEP_RE ]]; then
    echo "it published nothing, but it failed in '$failed', a test or build of the tagged commit itself, which a re-run repeats (if it was a flake: gh run rerun $rid --failed -R $ORG/$repo)"
    return 1
  fi
  echo "failed in '$failed' before it published anything (no ${T_PKGS[$repo]// /, } $ver, no GitHub Release $tag)"
}

classify() { if [ "$CHANNEL" = stable ]; then classify_stable "$1"; else classify_beta "$1"; fi; }
classify_beta() {
  local repo=$1
  local vfile=${T_VFILE[$repo]}
  local prefix=${T_PREFIX[$repo]}
  local wf=${T_WF[$repo]}
  local ref=main
  local sha ver tag tc rc wft facts pushref run rid rsha rst rcon rcreated reasons=() s where t pin age n why
  local -a paths=()
  S_REF[$repo]=main
  S_STATE[$repo]=REFUSE; S_REASON[$repo]=""; S_NOTE[$repo]=""; S_SHA[$repo]=""; S_VER[$repo]=""; S_TAG[$repo]=""
  S_RERUN[$repo]=""; S_BUSY[$repo]=""; S_TAGRUN[$repo]=""; S_OLD[$repo]=""; S_TAGRERUN[$repo]=""

  sha=$(ghq api "repos/$ORG/$repo/git/ref/heads/main" --jq .object.sha || true)
  if [ -z "$sha" ]; then S_REASON[$repo]="cannot read main: gh api repos/$ORG/$repo/git/ref/heads/main"; return; fi
  S_SHA[$repo]=$sha
  ver=$(read_version "$repo" "$sha" "$vfile" || true)
  S_VER[$repo]=$ver
  if [ -z "$ver" ]; then S_REASON[$repo]="cannot read a version from $vfile on main"; return; fi
  if ! is_beta "$ver"; then S_REASON[$repo]="main's $vfile says '$ver', not MAJOR.MINOR.PATCH-beta.N: merge a version bump"; return; fi
  pin=""; [ "$CHANNEL" = stable ] || pin=${EXPECT[$repo]:-}
  if [ -n "$pin" ] && [ "$pin" != "$ver" ]; then S_REASON[$repo]="--expect $repo=$pin, but main's $vfile says $ver"; return; fi
  tag="$prefix$ver"; S_TAG[$repo]=$tag

  wft=$(file_at "$repo" "$sha" ".github/workflows/$wf" || true)
  facts=$(printf '%s\n' "$wft" | wf_facts)
  pushref=no; [ "$(printf '%s\n' "$facts" | head -1)" = push_main=yes ] && pushref=yes
  while IFS= read -r t; do [ -n "$t" ] && paths+=("$t"); done < <(printf '%s\n' "$facts" | tail -n +2)

  rc=0; tc=$(tag_commit "$repo" "$tag") || rc=$?
  if [ "$rc" = 2 ]; then S_REASON[$repo]="cannot tell whether tag $tag exists: $tc"; return; fi
  if [ "$rc" = 0 ]; then
    # Published (or being published). A published beta is never re-tagged.
    run=$(ghq run list -R "$ORG/$repo" --workflow "$wf" --branch "$tag" --limit 1 \
          --json databaseId,status,conclusion,createdAt -q '.[]|[(.databaseId|tostring),.status,(.conclusion//""),.createdAt]|join("|")' || true)
    IFS='|' read -r rid rst rcon rcreated <<<"${run:-}"
    if [ -z "${rid:-}" ]; then
      S_REASON[$repo]="tag $tag exists (${tc:0:12}) but no $wf run for it was found: look at https://github.com/$ORG/$repo/actions"; return
    fi
    S_TAGRUN[$repo]=$rid
    if [ "$rst" != completed ]; then
      S_STATE[$repo]=RUNNING; S_NOTE[$repo]="tag $tag run $rid is $rst: gh run watch $rid -R $ORG/$repo"; return
    fi
    if [ "$rcon" != success ]; then
      if why=$(tag_run_unpublished "$repo" "$rid" "${rcreated:-}"); then
        # Nothing went out, so the beta number is not burned: re-run the run, do not bump.
        S_TAGRERUN[$repo]=$rid
        S_REASON[$repo]="tag $tag exists and its run $rid is '$rcon', but it $why. The beta number is not burned, so do NOT bump: gh run rerun $rid --failed -R $ORG/$repo (this stage offers it). That fixes a cause outside the tagged commit (a package that was not published yet, a flaky step); if the cause is in the commit itself, the re-run fails the same way: then fix it on main and bump $vfile to $(next_beta "$ver")"
      else
        S_REASON[$repo]="tag $tag exists and its run $rid is '$rcon' (no re-run: $why). A published beta is never re-tagged: read gh run view $rid --log-failed -R $ORG/$repo, fix it on main, bump $vfile to $(next_beta "$ver") and run this again"
      fi
      return
    fi
    if [ "$tc" = "$sha" ]; then
      S_STATE[$repo]=DONE; S_NOTE[$repo]="tag $tag at main ${sha:0:12}, run $rid green"; return
    fi
    n=$(commits_since "$repo" "$tag" "${paths[@]}" || true)
    if [ "$n" = 0 ]; then
      S_STATE[$repo]=DONE; S_NOTE[$repo]="tag $tag (${tc:0:12}) run $rid green; main has no commit since it that $wf builds (paths: ${paths[*]})"
    else
      S_STATE[$repo]=NEEDS-BUMP
      S_REASON[$repo]="$tag is published and main's $vfile still says $ver, but main has ${n} commit(s) since it$([ ${#paths[@]} -gt 0 ] && printf ' under %s' "${paths[*]}"): merge a PR that bumps $vfile to $(next_beta "$ver"), then run this again"
    fi
    return
  fi

  # Not tagged yet: every check that decides whether tagging main now would publish cleanly.
  local tags old
  tags=$(ghq api "repos/$ORG/$repo/git/matching-refs/tags/$prefix" --jq '.[].ref' || true)
  for t in $tags; do
    old=${t#refs/tags/$prefix}
    is_beta "$old" || continue
    if [ "$(vercmp "$old" "$ver")" = gt ]; then reasons+=("tag $prefix$old already exists and is later than main's $ver: bump $vfile past it"); fi
  done
  check_unreleased "$ref"
  if [ ${#reasons[@]} -gt 0 ]; then
    S_REASON[$repo]=$(printf '%s; ' "${reasons[@]}"); S_REASON[$repo]=${S_REASON[$repo]%; }
    [ ${#reasons[@]} -eq 1 ] || S_RERUN[$repo]=""   # a re-run alone cannot fix several reasons
    return
  fi
  S_STATE[$repo]=READY
  S_NOTE[$repo]="main ${sha:0:12} $vfile=$ver, signing on main, tag $tag free${S_NOTE[$repo]:+; ${S_NOTE[$repo]}}"
}

# check_unreleased ref: the checks that decide whether tagging <ref>'s HEAD now would
# publish cleanly (signing, DOCKER_CONFIG, secrets, check 7: the latest push run of the
# workflow on <ref> is green at <ref>'s HEAD). Called from classify_beta (ref main) and
# classify_stable (ref release/X.Y); it reads and appends to the CALLER's locals (bash
# dynamic scope): repo wf wft sha ver paths pushref reasons.
check_unreleased() {
  local ref=$1
  local ncos natt s where run rid rsha rst rcon rcreated age n
  if [ -z "$wft" ]; then
    reasons+=(".github/workflows/$wf is missing on $ref")
  else
    ncos=$(printf '%s\n' "$wft" | grep -aEc 'cosign sign(-blob)? ' || true)
    natt=$(printf '%s\n' "$wft" | grep -ac 'actions/attest-build-provenance@' || true)
    if [ "${ncos:-0}" -lt 1 ] || [ "${natt:-0}" -lt 1 ]; then
      reasons+=("signing absent in $wf on $ref (cosign sign: ${ncos:-0}, attest-build-provenance: ${natt:-0})")
    fi
    if printf '%s\n' "$wft" | grep -a 'DOCKER_CONFIG=' >/dev/null; then
      reasons+=("$wf writes a private DOCKER_CONFIG: attest-build-provenance then fails 'No credentials found for registry ghcr.io' AFTER :$ver is pushed (burns the beta number)")
    fi
    for s in $(printf '%s\n' "$wft" | grep -aoE 'secrets\.[A-Z_][A-Z0-9_]*' | sed 's/^secrets\.//' | sort -u); do
      [ "$s" = GITHUB_TOKEN ] && continue
      case "$OPTIONAL_SECRETS" in *" $s "*) continue ;; esac
      if [ "$s" = PACKAGES_READ_TOKEN ] && ! printf '%s\n' "$wft" | grep -a 'PACKAGES_READ_TOKEN is not set for this repository' >/dev/null; then
        continue   # this workflow falls back to GITHUB_TOKEN
      fi
      if ! where=$(secret_present "$repo" "$s"); then reasons+=("required secret $s: $where"); fi
    done
  fi
  # The latest PUSH run of the workflow on the ref must be green (a workflow_dispatch run
  # does not count): a red run means the tag run would push :<version> and then die, which
  # burns that version number.
  if [ "$pushref" = yes ]; then
    run=$(ghq run list -R "$ORG/$repo" --workflow "$wf" --branch "$ref" --event push --limit 1 \
          --json databaseId,headSha,status,conclusion,createdAt -q '.[]|[(.databaseId|tostring),.headSha,.status,(.conclusion//""),.createdAt]|join("|")' || true)
    IFS='|' read -r rid rsha rst rcon rcreated <<<"${run:-}"
    if [ -z "${rid:-}" ]; then
      reasons+=("no push-to-$ref run of $wf found: push a commit to $ref (the next merge starts one)")
    elif [ "$rst" != completed ]; then
      S_BUSY[$repo]=$rid
      reasons+=("$ref push run $rid (${rsha:0:8}) is still $rst: wait for it (gh run watch $rid -R $ORG/$repo)")
    elif [ "$rcon" != success ]; then
      age=$(run_age_days "$rcreated")
      if [ "$age" -ge "$RERUN_MAX_DAYS" ]; then
        S_OLD[$repo]=$rid
        reasons+=("last $ref push run $rid (${rsha:0:8}) is $rcon and $age days old: GitHub cannot re-run it. Push a commit to $ref (the next merge creates a new push run)")
      else
        S_RERUN[$repo]=$rid
        reasons+=("last $ref push run $rid (${rsha:0:8}) is $rcon: fix the cause, then gh run rerun $rid --failed -R $ORG/$repo (the rerun phase does this)")
      fi
    elif [ "$rsha" != "$sha" ]; then
      # main's HEAD has no push run of its own. Without a paths filter that run is still to
      # come (just merged, Actions lagging, a [skip ci] commit): tagging now would publish a
      # commit whose release workflow never ran on main. With a paths filter it is fine only
      # when nothing since the green run touches those paths.
      if [ ${#paths[@]} -eq 0 ]; then
        reasons+=("$ref is ${sha:0:8} but the latest $ref push run of $wf ($rid, green) is at ${rsha:0:8}: $ref's HEAD has no push run yet (just merged, Actions lagging, or [skip ci]). Wait for it (https://github.com/$ORG/$repo/actions); if none ever comes, push a commit to $ref")
      else
        n=$(CS_REF=$ref commits_since "$repo" "$rsha" "${paths[@]}" || true)
        if [ "$n" = 0 ]; then
          S_NOTE[$repo]="last $ref push run $rid green at ${rsha:0:8} ($ref is ${sha:0:8}; no commit since it under ${paths[*]}, so no push run is due)"
        else
          reasons+=("$ref is ${sha:0:8} and has ${n} commit(s) under ${paths[*]} since ${rsha:0:8}, where the latest $ref push run $rid is green; their push run has not appeared yet: wait for it (https://github.com/$ORG/$repo/actions)")
        fi
      fi
    else
      S_NOTE[$repo]="last $ref push run $rid green at HEAD"
    fi
  fi
}

published() { case "${S_STATE[$1]:-}" in DONE|NEEDS-BUMP) return 0 ;; esac; return 1; }

# Stage state: "published" (every row DONE/NEEDS-BUMP), or "plan" (dry run: every row is
# published or will be by this run: selected and READY/RUNNING/re-runnable), else "no".
stage_published() { local r; for r in $(rows_in_stage "$1"); do published "$r" || return 1; done; return 0; }
stage_plan_ok() {
  local r
  for r in $(rows_in_stage "$1"); do
    published "$r" && continue
    selected "$r" || return 1
    case "${S_STATE[$r]:-}" in READY|RUNNING) continue ;; esac
    [ -n "${S_RERUN[$r]:-}" ] || [ -n "${S_BUSY[$r]:-}" ] || [ -n "${S_TAGRERUN[$r]:-}" ] || return 1
  done
  return 0
}
# The same two verdicts over the rows --only selected (all rows without --only): what a
# stage that ACTS has to achieve. A dependency stage is always judged on all its rows.
stage_sel_published() {
  local r
  for r in $(rows_in_stage "$1"); do
    selected "$r" || continue
    published "$r" || return 1
  done
  return 0
}
stage_sel_plan_ok() {
  local r
  for r in $(rows_in_stage "$1"); do
    selected "$r" || continue
    if published "$r"; then continue; fi
    case "${S_STATE[$r]:-}" in READY|RUNNING) continue ;; esac
    [ -n "${S_RERUN[$r]:-}" ] || [ -n "${S_BUSY[$r]:-}" ] || [ -n "${S_TAGRERUN[$r]:-}" ] || return 1
  done
  return 0
}
# blocked_by stage plan|real -> the dependency stages that are not (going to be) published.
# A stable PATCH has none: its release branch already pins published stables (a -beta pin
# is refused per repo), and the other repos are not part of the patch.
blocked_by() {
  local d out=""
  if [ -n "$PATCH_VERSION" ]; then echo ""; return 0; fi
  for d in $(stage_deps "$1"); do
    if [ "$2" = plan ]; then
      stage_plan_ok "$d" && [ -z "$(blocked_by "$d" plan)" ] || out="$out $d"
    else
      stage_published "$d" || out="$out $d"
    fi
  done
  echo "${out# }"
}

row_line() {
  local r=$1 detail
  case "${S_STATE[$r]}" in
    DONE|READY|RUNNING|NEEDS-CUT|NEEDS-PR) detail=${S_NOTE[$r]} ;;
    *) detail=${S_REASON[$r]} ;;
  esac
  printf '  %-10s %-38s %-22s %s%s\n' "${S_STATE[$r]}" "$r" "${S_TAG[$r]:-${S_VER[$r]:-?}}" "$detail" "$(selected "$r" || printf ' [not selected by --only]')"
}

# A dry run classifies each row once (in preflight); --apply re-reads before every action.
classify_stage() {
  local r
  for r in $(rows_in_stage "$1"); do
    if [ "$MODE" = dry ] && [ -n "${S_STATE[$r]:-}" ]; then continue; fi
    classify "$r"
  done
}

# ── the stable channel ───────────────────────────────────────────────────────
# A stable release X.Y.Z of a repo is the tag <prefix>X.Y.Z on that repo's OWN branch
# release/X.Y, never on main: main carries the next beta. Each repo has its own X.Y (the
# Maven chain, the gateway and the UIs are versioned independently), so a cut is "every
# repo's main beta X.Y.Z-beta.N, released as X.Y.Z from release/X.Y", and a patch is one
# repo's --version X.Y.(Z+1) on its existing release/X.Y after the operator cherry-picked
# the fix there.
#
# The repo's release workflow has to know channels first (stable tag only from
# release/X.Y, :X.Y and :latest, the GitHub Release marked latest). Those per-repo PRs
# land separately; until the workflow AT THE REF THAT WOULD BE TAGGED carries both
# markers below, stable is REFUSED for that repo with the PR to merge.
#   1. its on.push.branches lists a release/ glob (release/** or release/*), so a
#      release branch gets the same push run that check 7 reads on main;
#   2. the literal CHANNEL_MARKER, written by those PRs next to the channel logic.
CHANNEL_MARKER='hugmesh-release-channels: beta+stable'
CHANNEL_PR_TITLE='Release channels'
# The head branch of a stable version-bump PR. Deliberately NOT under release/: every
# channel-aware workflow runs on pushes to release/**, and a bump branch named
# release/stable-X.Y.Z would start a release-branch run on an unmerged bump.
BUMP_PREFIX=bump
declare -A S_MODE=() S_RB=() S_REF=() S_MSTATE=() S_MWHY=() S_MVER=() S_MSHA=() S_RBVER=() S_PRURL=()
MAIN_NEEDS_BUMP=()

stable_reset() {
  S_MODE[$1]=""; S_RB[$1]=""; S_REF[$1]=main; S_MSTATE[$1]=""; S_MWHY[$1]=""; S_MVER[$1]=""; S_MSHA[$1]=""; S_RBVER[$1]=""; S_PRURL[$1]=""
}

# channel_pr repo -> the URL of the open per-repo "Release channels" PR, or a description
channel_pr() {
  local u
  u=$(ghq pr list -R "$ORG/$1" --state open --search "$CHANNEL_PR_TITLE in:title" --json url -q '.[0].url // empty' || true)
  if [ -n "$u" ]; then printf '%s' "$u"; else printf 'the "%s: beta from main, stable from release/X.Y" PR for %s/%s (none is open yet)' "$CHANNEL_PR_TITLE" "$ORG" "$1"; fi
}
# channel_missing <workflow text> -> prints what is missing; rc 0 when both markers are there
channel_missing() {
  local miss=()
  if ! printf '%s\n' "$1" | wf_branches | grep -a '^release/' >/dev/null; then miss+=("a push trigger on release/**"); fi
  if ! printf '%s\n' "$1" | grep -aF -- "$CHANNEL_MARKER" >/dev/null; then miss+=("the marker '$CHANNEL_MARKER'"); fi
  [ ${#miss[@]} -eq 0 ] && return 0
  printf '%s' "$(printf '%s; ' "${miss[@]}" | sed 's/; $//')"
  return 1
}

# stable_tags repo prefix -> every plain X.Y.Z tag of the repo, one per line
stable_tags() {
  local t v
  for t in $(ghq api "repos/$ORG/$1/git/matching-refs/tags/$2" --jq '.[].ref' || true); do
    v=${t#refs/tags/$2}
    is_stable "$v" && echo "$v"
  done
  return 0
}

# ── bump content (stdlib Python; poms by element path, never by line number) ────
BUMP_PY=$(cat <<'PYEOF'
import json, os, re, sys
# argv: mode (stable|next|check) root spec.json ; prints a JSON result
mode, root, specf = sys.argv[1], sys.argv[2], sys.argv[3]
spec = json.load(open(specf))
own = spec.get("own") or ""
pins = spec.get("pins", {})
images = spec.get("images", {})
org = spec.get("org", "hugmesh")
vfile = spec["vfile"]
wf = spec.get("wf", "")
BETA = re.compile(r"-beta\.[0-9]+$")
res = {"changed": {}, "summary": [], "left": [], "notes": [], "missing": []}

def rd(p):
    fp = os.path.join(root, p)
    if not os.path.isfile(fp):
        return None
    with open(fp, encoding="utf-8", newline="") as f:
        return f.read()

def line_of(text, pos):
    return text.count("\n", 0, pos) + 1

TOKEN = re.compile(r"<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|<![A-Za-z][^>]*>"
                   r"|<(/?)([A-Za-z_][\w.:-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*?)(/?)>", re.S)

def pom(path, text, is_vfile):
    edits = []
    stack = []
    def pin(where, art, v, s, e, gid_ok):
        vs = v.strip()
        if not gid_ok or not vs or vs.startswith("${"):
            return
        ln = line_of(text, s)
        if mode == "check":
            if BETA.search(vs):
                res["left"].append("%s:%d %s is still %s" % (path, ln, where, vs))
            return
        if art in pins:
            if vs != pins[art]:
                edits.append((s, e, v.replace(vs, pins[art])))
                res["summary"].append("%s:%d %s %s -> %s" % (path, ln, where, vs, pins[art]))
        elif mode == "stable" and BETA.search(vs):
            res["left"].append("%s:%d %s is %s, and no repository in the table publishes %s" % (path, ln, where, vs, art))
    for m in TOKEN.finditer(text):
        name = m.group(2)
        if name is None:
            continue
        if m.group(4):
            continue
        if not m.group(1):
            stack.append({"name": name, "start": m.end(), "kids": {}})
            continue
        if not stack or stack[-1]["name"] != name:
            res["left"].append("%s: cannot parse (unbalanced <%s>); edit it by hand" % (path, name))
            return None
        fr = stack.pop()
        if stack:
            stack[-1]["kids"][name] = (text[fr["start"]:m.start()], fr["start"], m.start())
        kids = fr["kids"]
        if not stack and name == "project":
            if is_vfile and "version" in kids:
                v, s, e = kids["version"]
                vs = v.strip()
                if mode == "check":
                    pass
                elif vs != own:
                    edits.append((s, e, v.replace(vs, own)))
                    res["summary"].append("%s:%d project version %s -> %s" % (path, line_of(text, s), vs, own))
            continue
        if name == "properties" and len(stack) == 1 and stack[0]["name"] == "project":
            for k, (v, s, e) in kids.items():
                if not k.endswith(".version"):
                    continue
                art = k[: -len(".version")]
                if art in pins or art.startswith("hugmesh"):
                    pin("property <%s>" % k, art, v, s, e, True)
            continue
        if "version" in kids and "artifactId" in kids:
            gid = kids.get("groupId", ("", 0, 0))[0].strip()
            art = kids["artifactId"][0].strip()
            v, s, e = kids["version"]
            pin("%s net.hugmesh:%s" % (name, art), art, v, s, e, gid == "net.hugmesh")
    if stack:
        res["left"].append("%s: cannot parse (unclosed <%s>); edit it by hand" % (path, stack[-1]["name"]))
        return None
    for s, e, new in sorted(edits, reverse=True):
        text = text[:s] + new + text[e:]
    return text

def detect_indent(text):
    m = re.search(r"\n([ \t]+)\"", text)
    return m.group(1) if m else "  "

def jsonfile(path, text, lock):
    try:
        d = json.loads(text)
    except Exception:
        res["left"].append("%s: not valid JSON; edit it by hand" % path)
        return None
    if not isinstance(d, dict):
        return None
    ind = detect_indent(text)
    nl = "\n" if text.endswith("\n") else ""
    same_shape = json.dumps(d, indent=ind, ensure_ascii=False) + nl == text
    old = d.get("version")
    if mode == "check":
        return text
    changes = []
    if old != own:
        d["version"] = own
        changes.append("version %s -> %s" % (old, own))
    if lock:
        pk = d.get("packages", {}).get("") if isinstance(d.get("packages"), dict) else None
        if isinstance(pk, dict) and "version" in pk and pk["version"] != own:
            changes.append('packages[""].version %s -> %s' % (pk["version"], own))
            pk["version"] = own
    if not changes:
        return text
    if same_shape:
        out = json.dumps(d, indent=ind, ensure_ascii=False) + nl
    else:
        # not in canonical JSON.stringify shape: touch only the top-level "version" value
        pat = re.compile(r'(\n%s"version"\s*:\s*")[^"]*(")' % re.escape(ind))
        out, n = pat.subn(lambda m: m.group(1) + own + m.group(2), text, count=1)
        if n != 1 or lock:
            res["left"].append("%s: not in the JSON.stringify(…, 2) shape npm writes, so it is not rewritten; set its version to %s by hand" % (path, own))
            return None
    res["summary"].append("%s %s" % (path, "; ".join(changes)))
    return out

def versionfile(path, text):
    first, sep, rest = text.partition("\n")
    if mode == "check" or first.strip() == own:
        return text
    res["summary"].append("%s %s -> %s" % (path, first.strip(), own))
    return own + sep + rest if sep else own + "\n"

PIN_RE = re.compile(r"^(\s*(?:PINNED_GATEWAY_IMAGE|GATEWAY_IMAGE_PIN)\s*:\s*[\"']?ghcr\.io/%s/([A-Za-z0-9._/-]+):)([^\s\"'#]+)" % re.escape(org), re.M)

def gatewaypin(path, text):
    out = []
    pos = 0
    for m in PIN_RE.finditer(text):
        img, tag = m.group(2), m.group(3)
        ln = line_of(text, m.start(3))
        if mode == "check":
            if BETA.search(tag):
                res["left"].append("%s:%d FROM pin ghcr.io/%s/%s:%s is a beta" % (path, ln, org, img, tag))
            continue
        if img in images and images[img] != tag:
            out.append((m.start(3), m.end(3), images[img]))
            res["summary"].append("%s:%d FROM pin %s:%s -> %s" % (path, ln, img, tag, images[img]))
        elif img not in images and mode == "stable" and BETA.search(tag):
            res["left"].append("%s:%d FROM pin ghcr.io/%s/%s:%s is a beta and no repository in the table publishes it" % (path, ln, org, img, tag))
    for s, e, new in sorted(out, reverse=True):
        text = text[:s] + new + text[e:]
    return text

def readme_version(path, text):
    m = re.search(r"\*\*Version ([^*\s]+)\*\*", text)
    if not m:
        res["left"].append("%s: no **Version X.Y.Z** line to move; set it by hand" % path)
        return None
    if mode == "check" or m.group(1) == own:
        return text
    res["summary"].append("%s:%d **Version %s** -> %s" % (path, line_of(text, m.start()), m.group(1), own))
    return text[:m.start(1)] + own + text[m.end(1):]

def changelog(path, text):
    if mode != "stable":
        return text
    if re.search(r"^##\s*\[?%s\]?(\s|$)" % re.escape(own), text, re.M):
        return text
    m = re.search(r"^## ", text, re.M)
    stub = ("## %s\n\nTODO: release notes for %s. scripts/release.sh added this heading; "
            "write the prose before merging.\n\n" % (own, own))
    at = m.start() if m else len(text)
    res["summary"].append("%s: new heading ## %s (needs prose)" % (path, own))
    res["notes"].append("%s needs release notes under the new ## %s heading before this PR merges" % (path, own))
    return text[:at] + stub + text[at:]

def handle(path, how):
    text = rd(path)
    if text is None:
        res["missing"].append(path)
        if how in ("vfile", "readme", "changelog", "gwpin"):
            res["left"].append("%s is missing" % path)
        return
    base = os.path.basename(path)
    if how == "gwpin":
        new = gatewaypin(path, text)
    elif how == "readme":
        new = readme_version(path, text)
    elif how == "changelog":
        new = changelog(path, text)
    elif base == "pom.xml":
        new = pom(path, text, how == "vfile")
    elif base == "package-lock.json":
        new = jsonfile(path, text, True)
    elif base in ("package.json", "composer.json"):
        new = jsonfile(path, text, False)
    else:
        new = versionfile(path, text)
    if new is not None and new != text and mode != "check":
        res["changed"][path] = new

todo = [(vfile, "vfile")]
for tok in spec.get("mirrors", []):
    if tok == "gateway-pin":
        todo.append((wf, "gwpin"))
    elif tok.endswith(":Version"):
        todo.append((tok[: -len(":Version")], "readme"))
    elif tok.endswith(":heading"):
        todo.append((tok[: -len(":heading")], "changelog"))
    else:
        todo.append((tok, "mirror"))
for p, how in list(todo):
    if os.path.basename(p) == "package.json":
        lock = os.path.join(os.path.dirname(p), "package-lock.json")
        if rd(lock) is not None:
            todo.append((lock, "mirror"))
for p, how in todo:
    handle(p, how)
print(json.dumps(res))
PYEOF
)
# bump_compute repo ref mode target -> BUMP_JSON (a file): what changes, what is left
# mode: stable (own -> X.Y.Z, org pins -> their stable), next (own -> next beta, pins ->
# their next beta), check (report org pins still -beta; changes nothing).
BUMP_JSON=""
bump_compute() {
  local repo=$1 ref=$2 mode=$3 target=$4 dir p r a pins="" imgs="" mir="" tok
  dir=$(mktemp -d "${TMPDIR:-/tmp}/release-bump.XXXXXX")
  BUMP_JSON="$dir.json"
  local -a fetch=("${T_VFILE[$repo]}")
  for tok in ${T_MIRRORS[$repo]//,/ }; do
    case "$tok" in
      gateway-pin) fetch+=(".github/workflows/${T_WF[$repo]}") ;;
      *:Version|*:heading) fetch+=("${tok%:*}") ;;
      *) fetch+=("$tok") ;;
    esac
  done
  for p in "${fetch[@]}"; do
    case "$(basename "$p")" in package.json) fetch+=("$(dirname "$p")/package-lock.json") ;; esac
  done
  for p in "${fetch[@]}"; do
    p=${p#./}
    mkdir -p "$dir/f/$(dirname "$p")"
    file_at "$repo" "$ref" "$p" > "$dir/f/$p" 2>/dev/null || rm -f "$dir/f/$p"
  done
  # every org artifact and image -> its target in this run
  for r in "${ROWS[@]}"; do
    local tv=""
    case "$mode" in
      stable) tv=${S_VER[$r]:-} ;;
      next) [ -n "${S_VER[$r]:-}" ] && is_stable "${S_VER[$r]}" && tv=$(next_minor_beta "${S_VER[$r]}") ;;
    esac
    [ -n "$tv" ] || continue
    for a in ${T_PKGS[$r]}; do
      if [ "${T_KIND[$r]}" = mvn ]; then pins="$pins\"${a##*.}\":\"$tv\","; else imgs="$imgs\"$a\":\"$tv\","; fi
    done
  done
  for tok in ${T_MIRRORS[$repo]//,/ }; do mir="$mir\"$tok\","; done
  printf '{"own":"%s","pins":{%s},"images":{%s},"org":"%s","vfile":"%s","wf":"%s","mirrors":[%s]}\n' \
    "$target" "${pins%,}" "${imgs%,}" "$ORG" "${T_VFILE[$repo]}" ".github/workflows/${T_WF[$repo]}" "${mir%,}" > "$dir/spec.json"
  python3 -I -c "$BUMP_PY" "$mode" "$dir/f" "$dir/spec.json" > "$BUMP_JSON" || { rm -rf "$dir"; echo '{"changed":{},"summary":[],"left":["the bump helper failed"],"notes":[],"missing":[]}' > "$BUMP_JSON"; return 1; }
  rm -rf "$dir"
}
bump_field() { python3 -I -c 'import json,sys; [print(x) for x in json.load(open(sys.argv[1]))[sys.argv[2]]]' "$BUMP_JSON" "$1"; }
bump_files() { python3 -I -c 'import json,sys; [print(x) for x in json.load(open(sys.argv[1]))["changed"]]' "$BUMP_JSON"; }

# bump_pr repo base-branch head-branch mode target title -> reads base's HEAD, works out the
# bump AT THAT COMMIT, and creates ONE commit on head-branch (parent: that HEAD) with the
# changed files, and a DRAFT PR into base. Idempotent: an open PR from head-branch is
# reported, not duplicated. A bump with anything left over opens nothing.
bump_pr() {
  local repo=$1 base=$2 head=$3 mode=$4 target=$5 title=$6
  local bsha tree commit url body rc=0 tf cf
  url=$(ghq pr list -R "$ORG/$repo" --head "$head" --state open --json url -q '.[0].url // empty' || true)
  if [ -n "$url" ]; then say "    $repo: PR already open: $url"; S_PRURL[$repo]=$url; return 0; fi
  bsha=$(ghq api "repos/$ORG/$repo/git/ref/heads/$base" --jq .object.sha) || { say "  STOP $repo: cannot read $base"; return 1; }
  bump_compute "$repo" "$bsha" "$mode" "$target" || true
  if [ -n "$(bump_field left || true)" ]; then
    say "  STOP $repo: the bump on $base ${bsha:0:12} is not mechanical:"; bump_field left | sed 's/^/      /'; rm -f "$BUMP_JSON"; return 1
  fi
  if [ -z "$(bump_files)" ]; then say "    $repo: $base ${bsha:0:12} already carries $target; no PR needed"; rm -f "$BUMP_JSON"; return 0; fi
  tree=$(ghq api "repos/$ORG/$repo/git/commits/$bsha" --jq .tree.sha) || { say "  STOP $repo: cannot read the tree of $base"; return 1; }
  tf=$(mktemp "${TMPDIR:-/tmp}/release-tree.XXXXXX"); cf=$(mktemp "${TMPDIR:-/tmp}/release-commit.XXXXXX")
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps({"base_tree": sys.argv[2], "tree": [{"path": p, "mode": "100644", "type": "blob", "content": c} for p, c in d["changed"].items()]}))' "$BUMP_JSON" "$tree" > "$tf"
  tree=$(GH api -X POST "repos/$ORG/$repo/git/trees" --input "$tf" --jq .sha) || rc=1
  if [ "$rc" = 0 ]; then
    python3 -I -c 'import json, sys; print(json.dumps({"message": sys.argv[1], "tree": sys.argv[2], "parents": [sys.argv[3]]}))' "$title" "$tree" "$bsha" > "$cf"
    commit=$(GH api -X POST "repos/$ORG/$repo/git/commits" --input "$cf" --jq .sha) || rc=1
  fi
  rm -f "$tf" "$cf"
  [ "$rc" = 0 ] || { rm -f "$BUMP_JSON"; say "  STOP $repo: creating the bump commit failed"; return 1; }
  if ghq api "repos/$ORG/$repo/git/ref/heads/$head" --jq .object.sha >/dev/null; then
    GH api -X PATCH "repos/$ORG/$repo/git/refs/heads/$head" -f "sha=$commit" -F force=true --jq '"    moved "+.ref' || { say "  STOP $repo: moving $head failed"; return 1; }
  else
    GH api -X POST "repos/$ORG/$repo/git/refs" -f "ref=refs/heads/$head" -f "sha=$commit" --jq '"    created "+.ref' || { say "  STOP $repo: creating $head failed"; return 1; }
  fi
  body=$(printf 'Opened by scripts/release.sh --channel stable (hugmesh-generator, docs/RELEASING.md). One mechanical commit:\n\n%s\n' "$(bump_field summary | sed 's/^/- /')")
  if [ -n "$(bump_field notes)" ]; then body=$(printf '%s\n\nBefore merging:\n\n%s\n' "$body" "$(bump_field notes | sed 's/^/- /')"); fi
  body=$(printf '%s\n\nComments and prose that still name a beta version are left for a human. The release script tags this repo only after this PR is merged into %s and its push run there is green.\n' "$body" "$base")
  rm -f "$BUMP_JSON"
  url=$(GH pr create -R "$ORG/$repo" --draft --base "$base" --head "$head" --title "$title" --body "$body") || { say "  STOP $repo: gh pr create failed"; return 1; }
  S_PRURL[$repo]=$url
  say "    $repo: draft PR $url"
}

classify_stable() {
  local repo=$1
  local vfile=${T_VFILE[$repo]}
  local prefix=${T_PREFIX[$repo]}
  local wf=${T_WF[$repo]}
  local msha mver s xy rb rbsha rbrc ver tag tc rc wft facts pushref run rid rst rcon rcreated why t zmax miss pin pr left
  local -a paths=() reasons=()
  S_STATE[$repo]=REFUSE; S_REASON[$repo]=""; S_NOTE[$repo]=""; S_SHA[$repo]=""; S_VER[$repo]=""; S_TAG[$repo]=""
  S_RERUN[$repo]=""; S_BUSY[$repo]=""; S_TAGRUN[$repo]=""; S_OLD[$repo]=""; S_TAGRERUN[$repo]=""
  stable_reset "$repo"

  msha=$(ghq api "repos/$ORG/$repo/git/ref/heads/main" --jq .object.sha || true)
  if [ -z "$msha" ]; then S_REASON[$repo]="cannot read main: gh api repos/$ORG/$repo/git/ref/heads/main"; return; fi
  S_MSHA[$repo]=$msha
  mver=$(read_version "$repo" "$msha" "$vfile" || true)
  S_MVER[$repo]=$mver
  if [ -n "$PATCH_VERSION" ] && selected "$repo"; then
    s=$PATCH_VERSION; S_MODE[$repo]=patch
  else
    S_MODE[$repo]=cut
    if ! is_beta "$mver"; then S_REASON[$repo]="main's $vfile says '${mver:-?}', not MAJOR.MINOR.PATCH-beta.N: a stable cut releases main's beta line as its X.Y.Z (a patch on an existing release branch is --version X.Y.Z --only $repo)"; return; fi
    s=${mver%-beta.*}
  fi
  pin=${EXPECT[$repo]:-}
  if [ -n "$pin" ] && [ "$pin" != "$s" ]; then S_REASON[$repo]="--expect $repo=$pin, but this run would release $s"; return; fi
  xy=${s%.*}; rb="release/$xy"
  S_VER[$repo]=$s; S_RB[$repo]=$rb; tag="$prefix$s"; S_TAG[$repo]=$tag

  # A cut releases what main's beta released: main must be DONE for its beta (published,
  # and no commit since it that the workflow builds). NEEDS-BUMP there means main has
  # code that no beta carried, and stops the cut and the bump for every selected repo.
  if [ "${S_MODE[$repo]}" = cut ]; then
    classify_beta "$repo"
    S_MSTATE[$repo]=${S_STATE[$repo]}
    if [ "${S_STATE[$repo]}" = DONE ]; then S_MWHY[$repo]=${S_NOTE[$repo]}; else S_MWHY[$repo]=${S_REASON[$repo]:-${S_NOTE[$repo]}}; fi
    S_STATE[$repo]=REFUSE; S_REASON[$repo]=""; S_NOTE[$repo]=""; S_SHA[$repo]=""
    S_RERUN[$repo]=""; S_BUSY[$repo]=""; S_TAGRUN[$repo]=""; S_OLD[$repo]=""; S_TAGRERUN[$repo]=""
    S_VER[$repo]=$s; S_TAG[$repo]=$tag; S_REF[$repo]=main
  fi

  rbrc=0; rbsha=$(ghs api "repos/$ORG/$repo/git/ref/heads/$rb" --jq .object.sha) || rbrc=$?
  case "$rbrc" in
    0) ;;
    4) rbsha="" ;;
    *) S_REASON[$repo]="cannot tell whether $rb exists"; return ;;
  esac

  rc=0; tc=$(tag_commit "$repo" "$tag") || rc=$?
  if [ "$rc" = 2 ]; then S_REASON[$repo]="cannot tell whether tag $tag exists: $tc"; return; fi
  if [ "$rc" = 0 ]; then
    [ -n "$rbsha" ] && S_REF[$repo]=$rb
    run=$(ghq run list -R "$ORG/$repo" --workflow "$wf" --branch "$tag" --limit 1 \
          --json databaseId,status,conclusion,createdAt -q '.[]|[(.databaseId|tostring),.status,(.conclusion//""),.createdAt]|join("|")' || true)
    IFS='|' read -r rid rst rcon rcreated <<<"${run:-}"
    if [ -z "${rid:-}" ]; then S_REASON[$repo]="tag $tag exists (${tc:0:12}) but no $wf run for it was found: look at https://github.com/$ORG/$repo/actions"; return; fi
    S_TAGRUN[$repo]=$rid
    if [ "$rst" != completed ]; then S_STATE[$repo]=RUNNING; S_NOTE[$repo]="tag $tag run $rid is $rst: gh run watch $rid -R $ORG/$repo"; return; fi
    if [ "$rcon" != success ]; then
      if why=$(tag_run_unpublished "$repo" "$rid" "${rcreated:-}"); then
        S_TAGRERUN[$repo]=$rid
        S_REASON[$repo]="tag $tag exists and its run $rid is '$rcon', but it $why. Nothing was published, so: gh run rerun $rid --failed -R $ORG/$repo (this stage offers it)"
      else
        S_REASON[$repo]="tag $tag exists and its run $rid is '$rcon' (no re-run: $why). A published version is never re-tagged: fix forward on $rb with --version $xy.$(( ${s##*.} + 1 ))"
      fi
      return
    fi
    S_STATE[$repo]=DONE; S_NOTE[$repo]="tag $tag (${tc:0:12}) run $rid green"
    if [ -n "$rbsha" ] && [ "$tc" != "$rbsha" ]; then S_NOTE[$repo]="${S_NOTE[$repo]}; $rb has moved to ${rbsha:0:12} since: a patch release is --version $xy.$(( ${s##*.} + 1 )) --only $repo"; fi
    return
  fi

  # Not tagged. Which workflow would run: the one on the release branch, or (before the
  # cut) main's, which the cut copies.
  if [ -n "$rbsha" ]; then S_REF[$repo]=$rb; S_SHA[$repo]=$rbsha; wft=$(file_at "$repo" "$rbsha" ".github/workflows/$wf" || true)
  else S_SHA[$repo]=$msha; wft=$(file_at "$repo" "$msha" ".github/workflows/$wf" || true); fi
  if [ -z "$wft" ]; then S_REASON[$repo]=".github/workflows/$wf is missing on ${S_REF[$repo]}"; return; fi
  if ! miss=$(channel_missing "$wft"); then
    pr=$(channel_pr "$repo")
    if [ -n "$rbsha" ]; then reasons+=("$wf on $rb does not support the stable channel (missing: $miss): merge $pr on main, then cherry-pick it into $rb")
    else reasons+=("$wf on main does not support the stable channel (missing: $miss): merge $pr first; the cut copies main into $rb"); fi
  fi

  if [ -z "$rbsha" ]; then
    if [ "${S_MODE[$repo]}" = patch ]; then
      reasons+=("$rb does not exist in $ORG/$repo: a patch release (--version) tags an existing release branch; cut $xy first with scripts/release.sh --channel stable")
    elif [ "${S_MSTATE[$repo]}" != DONE ]; then
      reasons+=("$rb does not exist, and a cut needs main's beta ${mver} published with nothing since it, but main is ${S_MSTATE[$repo]}: ${S_MWHY[$repo]}")
    fi
    if [ ${#reasons[@]} -gt 0 ]; then S_REASON[$repo]=$(printf '%s; ' "${reasons[@]}"); S_REASON[$repo]=${S_REASON[$repo]%; }; return; fi
    S_STATE[$repo]=NEEDS-CUT
    S_NOTE[$repo]="the cut phase creates $rb at main ${msha:0:12} (its beta $prefix$mver is DONE), then the bump phase opens its version-bump PR"
    return
  fi

  # The version order. A cut is later than every stable tag; a patch is exactly the next.
  zmax=-1
  for t in $(stable_tags "$repo" "$prefix"); do
    if [ "${S_MODE[$repo]}" = patch ]; then
      [ "${t%.*}" = "$xy" ] && [ "${t##*.}" -gt "$zmax" ] && zmax=${t##*.}
    elif [ "$(vercmp "$t" "$s")" = gt ]; then
      reasons+=("tag $prefix$t already exists and is later than $s: a stable cut never goes backwards (a fix for an older line is a patch: --version)")
    fi
  done
  if [ "${S_MODE[$repo]}" = patch ]; then
    if [ "$zmax" -lt 0 ]; then
      reasons+=("no $prefix$xy.Z is released yet: the first release of $rb is a cut (scripts/release.sh --channel stable), not --version")
    elif [ "$s" != "$xy.$((zmax + 1))" ]; then
      reasons+=("--version $s is not the next patch on $rb: the newest is $prefix$xy.$zmax, so the next is $xy.$((zmax + 1))")
    fi
  fi

  ver=$(read_version "$repo" "$rbsha" "$vfile" || true)
  S_RBVER[$repo]=$ver
  if [ "$ver" != "$s" ]; then
    pr=$(ghq pr list -R "$ORG/$repo" --head "$BUMP_PREFIX/stable-$s" --state open --json url -q '.[0].url // empty' || true)
    S_PRURL[$repo]=$pr
    if [ ${#reasons[@]} -gt 0 ]; then S_REASON[$repo]=$(printf '%s; ' "${reasons[@]}"); S_REASON[$repo]=${S_REASON[$repo]%; }; return; fi
    S_STATE[$repo]=NEEDS-PR
    if [ -n "$pr" ]; then S_NOTE[$repo]="$rb's $vfile says ${ver:-?}, not $s: merge the version-bump PR $pr, then run this again"
    else S_NOTE[$repo]="$rb's $vfile says ${ver:-?}, not $s: the bump phase opens the version-bump PR into $rb"; fi
    return
  fi

  # Every org pin on the release branch must be stable: a -beta pin builds the stable
  # artifact on a prerelease.
  bump_compute "$repo" "$rbsha" check "$s" || true
  left=$(bump_field left || true)
  rm -f "$BUMP_JSON"
  if [ -n "$left" ]; then
    reasons+=("$rb still pins a beta ($(printf '%s\n' "$left" | paste -sd';' - | sed 's/;/; /g')): merge the version-bump PR, or fix the pin on $rb")
  fi

  facts=$(printf '%s\n' "$wft" | wf_facts)
  while IFS= read -r t; do [ -n "$t" ] && paths+=("$t"); done < <(printf '%s\n' "$facts" | tail -n +2)
  pushref=no
  printf '%s\n' "$wft" | wf_branches | grep -a '^release/' >/dev/null && pushref=yes
  local sha=$rbsha
  check_unreleased "$rb"
  if [ ${#reasons[@]} -gt 0 ]; then
    S_REASON[$repo]=$(printf '%s; ' "${reasons[@]}"); S_REASON[$repo]=${S_REASON[$repo]%; }
    [ ${#reasons[@]} -eq 1 ] || S_RERUN[$repo]=""
    return
  fi
  S_STATE[$repo]=READY
  S_NOTE[$repo]="$rb ${rbsha:0:12} $vfile=$s, channels on $rb, signing on $rb, tag $tag free${S_NOTE[$repo]:+; ${S_NOTE[$repo]}}"
}

# ── stable phases ────────────────────────────────────────────────────────────
# needs_bump_on_main -> rc 1 (and the reason printed) when a selected cut repo's main is
# NEEDS-BUMP: it has commits no beta carried, so a stable of "main's beta" is not what
# main is. The cut and the bump stop for everyone until it is released or reverted.
main_blocks_stable() {
  local r bad=()
  for r in "${ROWS[@]}"; do
    selected "$r" || continue
    [ "${S_MODE[$r]:-}" = cut ] && [ "${S_MSTATE[$r]:-}" = NEEDS-BUMP ] && bad+=("$r")
  done
  [ ${#bad[@]} -eq 0 ] && return 0
  say "  REFUSE: main is NEEDS-BUMP in ${bad[*]}: it has commits that no published beta carries."
  say "    A stable release is cut from a published beta. Release the next beta first (scripts/release-beta.sh), or narrow this run with --only."
  return 1
}

phase_cut() {
  local st r todo=() cur
  if [ -n "$PATCH_VERSION" ]; then say "  --version $PATCH_VERSION: a patch release tags an existing release branch; nothing to cut"; return 0; fi
  for st in 1 2 3 4 5 6 7 8 9; do
    for r in $(rows_in_stage "$st"); do
      selected "$r" || continue
      [ "$MODE" = dry ] || classify "$r"
      [ "${S_STATE[$r]}" = NEEDS-CUT ] && todo+=("$r")
    done
  done
  main_blocks_stable || return 1
  [ ${#todo[@]} -gt 0 ] || { say "  nothing to cut: every selected repo's release branch exists (or the repo is not ready for it, see preflight)"; return 0; }
  if [ "$MODE" = dry ]; then
    for r in "${todo[@]}"; do say "  would create ${S_RB[$r]} in $r at main ${S_MSHA[$r]:0:12} (beta ${S_MVER[$r]} is DONE)"; done
    return 0
  fi
  confirm "Create the release branch in ${#todo[@]} repo(s) (${todo[*]})?" || { say "  skipped. next: $(resume_cmd cut)"; return 1; }
  for r in "${todo[@]}"; do
    # main is read again right before the branch is created: the branch must point at the
    # commit whose beta was checked, never at something merged since.
    cur=$(ghq api "repos/$ORG/$r/git/ref/heads/main" --jq .object.sha || true)
    if [ "$cur" != "${S_MSHA[$r]}" ]; then
      say "  STOP $r: main moved ${S_MSHA[$r]:0:8} -> ${cur:0:8} after it was checked; ${S_RB[$r]} was not created. next: $(resume_cmd cut)"
      return 1
    fi
    GH api -X POST "repos/$ORG/$r/git/refs" -f "ref=refs/heads/${S_RB[$r]}" -f "sha=${S_MSHA[$r]}" --jq '"    created "+.ref+" -> "+.object.sha' \
      || { say "  STOP $r: creating ${S_RB[$r]} failed. next: $(resume_cmd cut)"; return 1; }
    classify "$r"
  done
}

phase_bump() {
  local st r todo=() refused=0 ref left
  for st in 1 2 3 4 5 6 7 8 9; do
    for r in $(rows_in_stage "$st"); do
      selected "$r" || continue
      [ "$MODE" = dry ] || classify "$r"
      case "${S_STATE[$r]}" in
        NEEDS-PR) todo+=("$r") ;;
        NEEDS-CUT) [ "$MODE" = dry ] && todo+=("$r") ;;
      esac
    done
  done
  main_blocks_stable || return 1
  [ ${#todo[@]} -gt 0 ] || { say "  no version-bump PR to open"; return 0; }
  # Work out every bump first; a repo whose bump is not purely mechanical is refused,
  # and nothing is opened while any is (half a cascade is worse than none).
  for r in "${todo[@]}"; do
    ref=${S_RB[$r]}; [ "${S_STATE[$r]}" = NEEDS-CUT ] && ref=${S_MSHA[$r]}
    bump_compute "$r" "$ref" stable "${S_VER[$r]}" || true
    left=$(bump_field left || true)
    if [ -n "$left" ]; then
      refused=1
      say "  REFUSE $r: its bump to ${S_VER[$r]} is not mechanical:"
      printf '%s\n' "$left" | sed 's/^/      /'
    elif [ "$MODE" = dry ]; then
      if [ -n "${S_PRURL[$r]}" ]; then say "  $r: PR already open: ${S_PRURL[$r]}"
      else
        say "  would open a DRAFT PR in $r: $BUMP_PREFIX/stable-${S_VER[$r]} -> ${S_RB[$r]}$([ "${S_STATE[$r]}" = NEEDS-CUT ] && printf ' (after the cut)'):"
        bump_field summary | sed 's/^/      /'
        bump_field notes | sed 's/^/      before merging: /'
      fi
    fi
    rm -f "$BUMP_JSON"
  done
  if [ "$refused" = 1 ]; then say "  Fix those on their release branch (or in this table's mirrors column), then: $(resume_cmd bump)"; return 1; fi
  [ "$MODE" = dry ] && return 0
  confirm "Open ${#todo[@]} draft version-bump PR(s) into their release branches (${todo[*]})?" || { say "  skipped. next: $(resume_cmd bump)"; return 1; }
  for r in "${todo[@]}"; do
    bump_pr "$r" "${S_RB[$r]}" "$BUMP_PREFIX/stable-${S_VER[$r]}" stable "${S_VER[$r]}" "Release ${S_VER[$r]}: version bump on ${S_RB[$r]}" \
      || { say "  next: $(resume_cmd bump)"; return 1; }
  done
  say "  Merge them in stage order (each repo's CI goes green once the stable it pins is published), then: $(resume_cmd maven)"
}

# next: after a repo's stable X.Y.Z is out, its main moves to X.(Y+1).0-beta.1 so the beta
# channel resumes, with every org pin moved to its upstream's next beta.
next_minor_beta() { local x y; IFS=. read -r x y _ <<<"$1"; echo "$x.$((y + 1)).0-beta.1"; }
phase_next() {
  local st r nb todo=() left
  if [ -n "$PATCH_VERSION" ]; then say "  --version $PATCH_VERSION: a patch release does not move main"; return 0; fi
  for st in 1 2 3 4 5 6 7 8 9; do
    for r in $(rows_in_stage "$st"); do
      selected "$r" || continue
      [ "$MODE" = dry ] || classify "$r"
      if [ "${S_STATE[$r]}" != DONE ]; then say "  $r: after ${S_TAG[$r]:-its stable} is published"; continue; fi
      if ! is_beta "${S_MVER[$r]}" || [ "${S_MVER[$r]%-beta.*}" != "${S_VER[$r]}" ]; then
        say "  $r: main is already at ${S_MVER[$r]:-?}; nothing to move"; continue
      fi
      todo+=("$r")
    done
  done
  [ ${#todo[@]} -gt 0 ] || return 0
  for r in "${todo[@]}"; do
    nb=$(next_minor_beta "${S_VER[$r]}")
    bump_compute "$r" "${S_MSHA[$r]}" next "$nb" || true
    left=$(bump_field left || true)
    if [ "$MODE" = dry ] || [ -n "$left" ]; then
      say "  $([ -n "$left" ] && printf 'REFUSE' || printf 'would open a DRAFT PR in') $r: $BUMP_PREFIX/next-beta-$nb -> main:"
      bump_field summary | sed 's/^/      /'
      [ -z "$left" ] || printf '%s\n' "$left" | sed 's/^/      not mechanical: /'
    fi
    rm -f "$BUMP_JSON"
  done
  [ "$MODE" = dry ] && return 0
  confirm "Open ${#todo[@]} draft next-beta PR(s) into main (${todo[*]})?" || { say "  skipped: run $(resume_cmd next) later"; return 0; }
  for r in "${todo[@]}"; do
    nb=$(next_minor_beta "${S_VER[$r]}")
    bump_pr "$r" main "$BUMP_PREFIX/next-beta-$nb" next "$nb" "Next beta: $nb (after ${S_TAG[$r]})" || return 1
  done
}

# The Studio has its own release path (scripts/release-studio.sh), which does not take a
# channel yet, so a stable Studio is refused here until it does.
studio_stable_needs() {
  say "  The Studio has no stable channel in this script yet. What it needs (docs/RELEASING.md, Stable):"
  say "    1. scripts/release-studio.sh: a --final (or --channel stable) that takes 'release_version.py next --final';"
  say "       today it proposes only the next beta, and its usage line and the 'a wrong build gets a new beta N' text say so."
  say "    2. scripts/release.sh: call release-studio.sh with that flag, keep its type-back confirmation, and drop"
  say "       the beta-only --studio pattern for the stable channel."
  say "    3. (cosmetic) studio-release.yml and studio-release-cut.yml headers still say 'beta scheme' and 'next beta N'."
  say "    studio-release.yml already marks a plain X.Y.Z as a full release (prerelease/make_latest follow the '-')."
}

# ── writes (never reached under --dry-run) ───────────────────────────────────
confirm() { # question -> 0 = go
  if [ "$MODE" != apply ]; then return 1; fi
  if [ "$YES" = true ]; then say "  $1 -> yes (--yes)"; return 0; fi
  local a=""
  printf '  %s [y/N] ' "$1"
  IFS= read -r a || a=""
  case "$a" in y|Y|yes|YES) return 0 ;; esac
  return 1
}
pause_for() { # message -> 0 when the operator pressed Enter, 1 on q / EOF
  local a=""
  printf '  %s\n  Press Enter when done (q to stop): ' "$1"
  IFS= read -r a || return 1
  [ "$a" != q ]
}

find_new_run() { # repo workflow branch event since-id -> prints the id of a run newer than since-id
  local repo=$1 wf=$2 br=$3 ev=$4 since=$5 i id
  for i in $(seq 1 "$TRIES"); do
    id=$(ghq run list -R "$ORG/$repo" --workflow "$wf" ${br:+--branch "$br"} ${ev:+--event "$ev"} --limit 5 \
          --json databaseId -q "[.[]|select(.databaseId > ${since:-0})][0].databaseId // empty" || true)
    [ -n "$id" ] && { echo "$id"; return 0; }
    sleep "$POLL"
  done
  return 1
}
watch_run() { # repo id -> 0 when green
  local repo=$1 id=$2 concl
  say "    watching https://github.com/$ORG/$repo/actions/runs/$id"
  GH run watch "$id" -R "$ORG/$repo" --exit-status --interval "$POLL" >/dev/null 2>&1 || true
  concl=$(GH run view "$id" -R "$ORG/$repo" --json conclusion -q .conclusion 2>/dev/null || echo unknown)
  say "    run $id: ${concl:-unknown}"
  if [ "$concl" != success ]; then
    GH run view "$id" -R "$ORG/$repo" --json jobs \
      -q '.jobs[]|select(.conclusion!="success" and .conclusion!="skipped")|"    failed job: "+.name+" ["+(.steps|map(select(.conclusion=="failure"))|map(.name)|join("; "))+"]"' 2>/dev/null || true
    say "    next: gh run view $id --log-failed -R $ORG/$repo"
    return 1
  fi
}

pkg_digest() { # image-package version -> digest or nothing
  local enc
  enc=$(printf '%s' "$1" | sed 's#/#%2F#g')
  ghq api "/orgs/$ORG/packages/container/$enc/versions?per_page=100" \
     --jq ".[]|select(.metadata.container.tags|index(\"$2\"))|.name" | head -1
}
print_artifacts() { # repo version
  local p d
  for p in ${T_PKGS[$1]}; do
    if [ "${T_KIND[$1]}" = img ]; then
      d=$(pkg_digest "$p" "$2" || true)
      say "    ghcr.io/$ORG/$p:$2 ${d:-<digest not visible via the packages API>}"
    else
      if ghq api "/orgs/$ORG/packages/maven/$p/versions?per_page=100" --jq '.[].name' | grep -axF -- "$2" >/dev/null; then
        say "    maven $p:$2 is listed in GitHub Packages"
      else
        say "    maven $p:$2 is NOT listed in GitHub Packages"
      fi
    fi
  done
}

# tag_and_watch repo: tag the RECORDED sha of the branch the channel releases from (main
# for beta, release/X.Y for stable), but only if that branch has not moved since it was
# checked (a move means a new push run and possibly a new version: re-check first).
tag_and_watch() {
  local repo=$1
  local sha=${S_SHA[$repo]}
  local tag=${S_TAG[$repo]}
  local wf=${T_WF[$repo]}
  local ref=${S_REF[$repo]:-main}
  local cur id
  cur=$(ghq api "repos/$ORG/$repo/git/ref/heads/$ref" --jq .object.sha || true)
  if [ "$cur" != "$sha" ]; then
    say "  STOP $repo: $ref moved ${sha:0:8} -> ${cur:0:8} after it was checked; nothing was tagged."
    say "    A new push run starts for ${cur:0:8}. Wait for it, then: $(resume_cmd "$CUR_PHASE")"
    return 1
  fi
  if ! GH api -X POST "repos/$ORG/$repo/git/refs" -f "ref=refs/tags/$tag" -f "sha=$sha" --jq '"    tagged "+.ref+" -> "+.object.sha'; then
    say "  STOP $repo: creating tag $tag failed. next: $(resume_cmd "$CUR_PHASE")"; return 1
  fi
  if ! id=$(find_new_run "$repo" "$wf" "$tag" "" 0); then
    say "  STOP $repo: no $wf run appeared for $tag within $((TRIES * POLL)) s: https://github.com/$ORG/$repo/actions"; return 1
  fi
  watch_run "$repo" "$id" || return 1
  print_artifacts "$repo" "${S_VER[$repo]}"
}

# rerun_tag_run repo: re-run the failed jobs of a tag run that published nothing
# (S_TAGRERUN), watch it, re-classify. 0 when the repo is published afterwards.
rerun_tag_run() {
  local r=$1
  local id=${S_TAGRERUN[$1]}
  local before now i
  before=$(ghq run view "$id" -R "$ORG/$r" --json attempt -q '.attempt // 1' || echo 1)
  say "  -> gh run rerun $id --failed -R $ORG/$r (tag ${S_TAG[$r]})"
  if ! GH run rerun "$id" --failed -R "$ORG/$r"; then
    say "  STOP $r: the re-run of $id was refused: https://github.com/$ORG/$r/actions/runs/$id"; return 1
  fi
  # wait for the new attempt, so the watch does not read the old attempt's result
  for i in $(seq 1 "$TRIES"); do
    now=$(ghq run view "$id" -R "$ORG/$r" --json attempt,status -q '"\(.attempt // 1) \(.status)"' || true)
    [ "${now%% *}" != "${before:-1}" ] || [ "${now#* }" != completed ] && break
    sleep "$POLL"
  done
  watch_run "$r" "$id" || { classify "$r"; return 1; }
  classify "$r"; row_line "$r"
  published "$r" || return 1
  print_artifacts "$r" "${S_VER[$r]}"
}

# tag_stage stage -> 0 when every row of the stage is published afterwards (or would be)
tag_stage() {
  local st=$1 r blk ready=() tagrr=() rc=0
  say
  say "  -- stage $st: $(stage_title "$st")"
  classify_stage "$st"
  for r in $(rows_in_stage "$st"); do row_line "$r"; done
  if ! stage_has_selected "$st"; then
    say "  >> stage $st: none of its repositories is selected by --only; skipped"; return 0
  fi
  if [ "$MODE" = dry ]; then
    blk=$(blocked_by "$st" plan)
    if [ -n "$blk" ]; then say "  >> stage $st would be BLOCKED: stage(s) $blk will not be published by this run"; return 1; fi
  else
    blk=$(blocked_by "$st" real)
    if [ -n "$blk" ]; then say "  >> stage $st is BLOCKED: dependency stage(s) $blk not published. next: $(resume_cmd "$CUR_PHASE") once they are"; return 1; fi
  fi
  for r in $(rows_in_stage "$st"); do
    selected "$r" || continue
    [ -n "${S_TAGRERUN[$r]:-}" ] && tagrr+=("$r")
    case "${S_STATE[$r]}" in
      READY) ready+=("$r") ;;
      RUNNING)
        if [ "$MODE" = dry ]; then say "  would watch $r's tag run ${S_TAGRUN[$r]}"
        else watch_run "$r" "${S_TAGRUN[$r]}" || rc=1; fi ;;
    esac
  done
  # A tag whose run failed before it published anything: re-run that run (no bump needed).
  if [ ${#tagrr[@]} -gt 0 ]; then
    if [ "$MODE" = dry ]; then
      for r in "${tagrr[@]}"; do say "  would: gh run rerun ${S_TAGRERUN[$r]} --failed -R $ORG/$r (tag ${S_TAG[$r]}: its run published nothing), then watch it"; done
    else
      if ! confirm "Re-run the failed jobs of ${#tagrr[@]} tag run(s) that published nothing (${tagrr[*]})?"; then
        say "  stage $st skipped by the operator. next: $(resume_cmd "$CUR_PHASE")"; return 1
      fi
      for r in "${tagrr[@]}"; do
        rerun_tag_run "$r" && continue
        rc=1
        if [ "$st" -le 5 ]; then say "  STOP: a Maven/gateway chain link failed; later chain stages would fail the same way"; return 1; fi
      done
    fi
  fi
  if [ ${#ready[@]} -eq 0 ]; then
    if stage_sel_published "$st"; then say "  >> stage $st: everything$([ ${#ONLY[@]} -gt 0 ] && printf ' selected') DONE"; return 0; fi
    if [ "$MODE" = dry ] && stage_sel_plan_ok "$st"; then
      for r in $(rows_in_stage "$st"); do
        [ -n "${S_RERUN[$r]:-}${S_BUSY[$r]:-}" ] && selected "$r" && say "  would tag: $r ${S_TAG[$r]} once its main push run is green (rerun phase), at main as it is then"
      done
      return 0
    fi
    return 1
  fi
  if [ "$MODE" = dry ]; then
    for r in "${ready[@]}"; do say "  would tag: $r ${S_TAG[$r]} at ${S_SHA[$r]:0:12}, then watch its ${T_WF[$r]} run"; done
    stage_sel_plan_ok "$st"; return
  fi
  if ! confirm "Tag ${#ready[@]} repo(s) in stage $st (${ready[*]})?"; then
    say "  stage $st skipped by the operator. next: $(resume_cmd "$CUR_PHASE")"; return 1
  fi
  for r in "${ready[@]}"; do
    say "  -> $r ${S_TAG[$r]} (${T_WF[$r]})"
    tag_and_watch "$r" || { rc=1; [ "$st" -le 5 ] && { say "  STOP: a Maven/gateway chain link failed; later chain stages would fail the same way"; break; }; }
  done
  classify_stage "$st"
  [ "$rc" = 0 ] && stage_sel_published "$st"
}

# rerun_red stage... : re-run the red main push runs whose only fault is that run
rerun_red() {
  local st r todo=() rc=0 blk has
  for st in "$@"; do
    for r in $(rows_in_stage "$st"); do
      selected "$r" || continue
      [ "$MODE" = dry ] || classify "$r"
      row_line "$r"
      if [ -n "${S_OLD[$r]}" ]; then say "    cannot re-run ${S_OLD[$r]} (older than $RERUN_MAX_DAYS days): push a commit to ${S_REF[$r]:-main}, then: $(resume_cmd "$CUR_PHASE")"; rc=1; fi
      if [ -n "${S_BUSY[$r]}" ]; then
        if [ "$MODE" = dry ]; then say "    would wait for ${S_REF[$r]:-main} push run ${S_BUSY[$r]}"; else watch_run "$r" "${S_BUSY[$r]}" || rc=1; fi
      fi
      [ -n "${S_RERUN[$r]}" ] && todo+=("$r")
    done
  done
  [ ${#todo[@]} -gt 0 ] || { say "  nothing to re-run"; return "$rc"; }
  for st in "$@"; do
    has=0
    for r in "${todo[@]}"; do [ "${T_STAGE[$r]}" = "$st" ] && has=1; done
    [ "$has" = 1 ] || continue
    if [ "$MODE" = dry ]; then blk=$(blocked_by "$st" plan); else blk=$(blocked_by "$st" real); fi
    if [ -n "$blk" ]; then
      say "  >> not re-running stage $st yet: its dependency stage(s) $blk are not published, so the runs would fail again for the same reason"
      return 1
    fi
  done
  if [ "$MODE" = dry ]; then
    for r in "${todo[@]}"; do say "  would: gh run rerun ${S_RERUN[$r]} --failed -R $ORG/$r, then watch it"; done
    return "$rc"
  fi
  confirm "Re-run the failed jobs of ${#todo[@]} red main push run(s) (${todo[*]})?" || { say "  skipped. next: $(resume_cmd "$CUR_PHASE")"; return 1; }
  for r in "${todo[@]}"; do
    say "  -> gh run rerun ${S_RERUN[$r]} --failed -R $ORG/$r"
    if ! GH run rerun "${S_RERUN[$r]}" --failed -R "$ORG/$r"; then
      say "    the re-run was refused (a run older than $RERUN_MAX_DAYS days cannot be re-run): push a commit to main, then $(resume_cmd "$CUR_PHASE")"; rc=1; continue
    fi
    sleep "$POLL"
    watch_run "$r" "${S_RERUN[$r]}" || rc=1
    classify "$r"; row_line "$r"
  done
  return "$rc"
}

# ── gateway package access (the overlays build FROM it) ──────────────────────
GW_REPO=hugmesh-gateway
GW_PKG=hugmesh-gateway
# probe_gateway -> prints one line per overlay; rc 0 when every pinned base image exists and is public
probe_gateway() {
  local r wft pin pver vis tags ok=0
  vis=$(ghq api "/orgs/$ORG/packages/container/$GW_PKG" --jq .visibility || echo not-created-yet)
  tags=$(ghq api "/orgs/$ORG/packages/container/$GW_PKG/versions?per_page=100" --jq '.[].metadata.container.tags[]' || true)
  for r in $(rows_in_stage 6); do
    selected "$r" || continue
    wft=$(file_at "$r" "${S_REF[$r]:-main}" ".github/workflows/${T_WF[$r]}" || true)
    # be/pki call it PINNED_GATEWAY_IMAGE, fe calls it GATEWAY_IMAGE_PIN
    pin=$(printf '%s\n' "$wft" | sed -n -E 's/^ *(PINNED_GATEWAY_IMAGE|GATEWAY_IMAGE_PIN): *([^ #]+).*/\2/p' | head -1)
    pver=${pin##*:}
    if [ -z "$pin" ]; then say "    $r: no PINNED_GATEWAY_IMAGE / GATEWAY_IMAGE_PIN in ${T_WF[$r]} on ${S_REF[$r]:-main}"; ok=1; continue; fi
    if printf '%s\n' "$tags" | grep -axF -- "$pver" >/dev/null; then
      say "    $r: FROM $pin -> published; package visibility: $vis"
    else
      say "    $r: FROM $pin -> NOT published yet (the gateway phase publishes ${S_TAG[$GW_REPO]:-the gateway}); package visibility: $vis"; ok=1
    fi
    if [ -n "${S_VER[$GW_REPO]:-}" ] && [ "$pver" != "${S_VER[$GW_REPO]}" ]; then
      say "      note: it pins $pver but the gateway release is ${S_VER[$GW_REPO]}: raise PINNED_GATEWAY_IMAGE in $r in a PR if it should build on the new one"
    fi
  done
  [ "$vis" = public ] || ok=1
  return "$ok"
}

# ── packages that are not public yet ─────────────────────────────────────────
# One call per package type lists every org package with its visibility.
nonpublic_packages() { # [repo...] -> "kind|package|visibility|settings-url" lines
  local cont mvn r p vis enc
  cont=$(ghq api "/orgs/$ORG/packages?package_type=container&per_page=100" --paginate --jq '.[]|.name+"="+.visibility' || true)
  mvn=$(ghq api "/orgs/$ORG/packages?package_type=maven&per_page=100" --paginate --jq '.[]|.name+"="+.visibility' || true)
  for r in "$@"; do
    for p in ${T_PKGS[$r]}; do
      if [ "${T_KIND[$r]}" = img ]; then
        vis=$(printf '%s\n' "$cont" | sed -n "s#^$p=##p" | head -1); enc=$(printf '%s' "$p" | sed 's#/#%2F#g')
        [ "$vis" = public ] || echo "container|ghcr.io/$ORG/$p|${vis:-not-created-yet}|https://github.com/orgs/$ORG/packages/container/$enc/settings"
      else
        vis=$(printf '%s\n' "$mvn" | sed -n "s#^$p=##p" | head -1)
        [ "$vis" = public ] || echo "maven|$p|${vis:-not-created-yet}|https://github.com/orgs/$ORG/packages/maven/$p/settings"
      fi
    done
  done
}
selected_rows() { local r; for r in "${ROWS[@]}"; do selected "$r" && echo "$r"; done; return 0; }
print_nonpublic() {
  local lines kind name vis url
  lines=$(nonpublic_packages $(selected_rows))
  if [ -z "$lines" ]; then say "  every package of the selected repos is public"; return 0; fi
  say "  Not public yet ($(printf '%s\n' "$lines" | grep -c .)). Each: open the page -> Danger Zone -> Change visibility -> Public (cannot be undone)."
  while IFS='|' read -r kind name vis url; do
    printf '   [%s] %s %s\n       %s\n' "$vis" "$kind" "$name" "$url"
  done <<<"$lines"
  return 1
}

# ── Studio ───────────────────────────────────────────────────────────────────
studio_facts() {
  local mv last rel
  mv=$(ghq api "repos/$ORG/hugmesh-generator/contents/studio/hugmesh_studio/__init__.py?ref=main" --jq .content | base64 -d 2>/dev/null | sed -n 's/^__version__ = "\([^"]*\)"$/\1/p' || true)
  last=$(ghq api "repos/$ORG/hugmesh-generator/git/matching-refs/tags/studio-v" --jq '.[].ref' | sed 's#refs/tags/##' | sort -V | tail -1 || true)
  rel=missing; [ -n "$last" ] && ghq release view "$last" -R "$ORG/hugmesh-generator" --json tagName >/dev/null && rel=published
  say "  Studio: main __version__ ${mv:-?}; newest tag ${last:-none} (GitHub Release: $rel)"
}

# ── the site (hugmesh.net) ───────────────────────────────────────────────────
SITE_MAP=""
load_site_map() { # "repo|image-or-package|group|id" lines from the site's release-sources.json
  SITE_MAP=$(file_at hugmesh.github.io main release-sources.json | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in d.get("images", []):
    print("%s|%s|%s|%s" % (e.get("repo", "").split("/")[-1], e.get("image", "").split("/", 2)[-1], e.get("group", ""), e.get("id", "")))
for e in d.get("packages", []):
    print("%s|%s|maven|%s" % (e.get("repo", "").split("/")[-1], "*", e.get("id", "")))' || true)
}
site_where() { # repo package -> where it shows on hugmesh.net
  local line
  line=$(printf '%s\n' "$SITE_MAP" | awk -F'|' -v r="$1" -v p="$2" '$1==r && ($2==p || $2=="*") {print $3"/"$4; exit}')
  if [ -n "$line" ]; then echo "hugmesh.net/downloads (${line%%/*}: ${line#*/})"; else echo "not listed on hugmesh.net"; fi
}

# ════════════════════════════════════════════════════════════════════════════
# phases
CUR_PHASE=preflight
FAILED=0

phase_preflight() {
  local st r blk pub cnt
  say "release.sh --channel $CHANNEL: mode=$MODE  $(date -u +%FT%TZ)  table=$(shown "$TABLE")  rows=${#ROWS[@]}"
  [ ${#ONLY[@]} -gt 0 ] && say "  --only: ${ONLY[*]} (every row is still checked; only these are acted on)"
  [ ${#EXPECT[@]} -gt 0 ] && say "  --expect: $(for r in "${!EXPECT[@]}"; do printf '%s=%s ' "$r" "${EXPECT[$r]}"; done)"
  GH auth status >/dev/null 2>&1 || die "gh is not logged in (GH_TOKEN/GITHUB_TOKEN are unset for every call): gh auth login"
  load_org_secrets
  say "  org secrets: $ORG_SECRETS_STATE (names only)"
  pub=$(ghq variable list --org "$ORG" --json name -q '.[].name' | grep -ac '^RUNS_ON_PUBLISH$' || true)
  [ "${pub:-0}" -gt 0 ] && say "  WARNING: org variable RUNS_ON_PUBLISH is set: release jobs would ask for a self-hosted runner, which public repos cannot use (they queue forever)."
  if [ "$CHANNEL" = stable ]; then
    if [ -n "$PATCH_VERSION" ]; then say "  stable PATCH $PATCH_VERSION for ${ONLY[*]}: tags release/${PATCH_VERSION%.*} after the fix was cherry-picked there"
    else say "  stable CUT: every repo releases main's beta X.Y.Z-beta.N as X.Y.Z from its own release/X.Y"; fi
  fi
  declare -gA COUNT=([DONE]=0 [READY]=0 [REFUSE]=0 [NEEDS-BUMP]=0 [RUNNING]=0 [NEEDS-CUT]=0 [NEEDS-PR]=0)
  for st in 1 2 3 4 5 6 7 8 9; do
    say
    say "=== stage $st: $(stage_title "$st")"
    classify_stage "$st"
    for r in $(rows_in_stage "$st"); do row_line "$r"; cnt=${COUNT[${S_STATE[$r]}]}; COUNT[${S_STATE[$r]}]=$((cnt+1)); done
    blk=$(blocked_by "$st" real)
    [ -n "$blk" ] && say "  >> stage $st needs stage(s) $blk published first (see the phases below)"
  done
  say
  studio_facts
  say
  if [ "$CHANNEL" = stable ]; then
    say "== Summary: DONE=${COUNT[DONE]} READY=${COUNT[READY]} REFUSE=${COUNT[REFUSE]} NEEDS-CUT=${COUNT[NEEDS-CUT]} NEEDS-PR=${COUNT[NEEDS-PR]} RUNNING=${COUNT[RUNNING]}"
    main_blocks_stable || true
    return 0
  fi
  say "== Summary: DONE=${COUNT[DONE]} READY=${COUNT[READY]} REFUSE=${COUNT[REFUSE]} NEEDS-BUMP=${COUNT[NEEDS-BUMP]} RUNNING=${COUNT[RUNNING]}"
  if [ "${COUNT[NEEDS-BUMP]}" -gt 0 ]; then
    say "   NEEDS-BUMP repos are published at main's version but have unreleased commits; this run leaves them alone. Merge a version bump in each to release them."
  fi
}

phase_merge() {
  local m repo n st draft oid base wft facts pushref pre id
  if [ ${#MERGES[@]} -eq 0 ]; then say "  no --merge given"; return 0; fi
  for m in "${MERGES[@]}"; do
    repo=${m%#*}; n=${m##*#}
    IFS='|' read -r st draft oid base < <(ghq pr view "$n" -R "$ORG/$repo" --json state,isDraft,mergeCommit,baseRefName -q '[.state,(.isDraft|tostring),(.mergeCommit.oid//""),(.baseRefName//"main")]|join("|")' || printf 'UNREADABLE|||main\n')
    base=${base:-main}
    case "$st" in
      MERGED) say "  $m: already merged (${oid:0:12})"; continue ;;
      OPEN) ;;
      *) say "  STOP $m: PR is $st; nothing merged. next: drop --merge $m, then $(resume_cmd merge)"; return 1 ;;
    esac
    if [ "$MODE" = dry ]; then
      say "  would:$([ "$draft" = true ] && printf ' gh pr ready %s -R %s/%s;' "$n" "$ORG" "$repo") gh pr merge $n -R $ORG/$repo --squash --delete-branch, then wait for $base's new push run"
      continue
    fi
    confirm "Merge $m (squash, delete branch)$([ "$draft" = true ] && printf ', marking it ready first')?" || { say "  skipped $m. next: $(resume_cmd merge)"; return 1; }
    pre=0
    if [ -n "${T_WF[$repo]:-}" ]; then
      pre=$(ghq run list -R "$ORG/$repo" --workflow "${T_WF[$repo]}" --branch "$base" --event push --limit 1 --json databaseId -q '.[].databaseId' || echo 0)
    fi
    if [ "$draft" = true ]; then GH pr ready "$n" -R "$ORG/$repo" || { say "  STOP $m: gh pr ready failed"; return 1; }; fi
    GH pr merge "$n" -R "$ORG/$repo" --squash --delete-branch || { say "  STOP $m: gh pr merge failed (checks, review or conflicts): https://github.com/$ORG/$repo/pull/$n"; return 1; }
    oid=$(ghq pr view "$n" -R "$ORG/$repo" --json mergeCommit -q '.mergeCommit.oid' || true)
    say "  merged $m -> ${oid:0:12}"
    [ -n "${T_WF[$repo]:-}" ] || continue
    wft=$(file_at "$repo" "$base" ".github/workflows/${T_WF[$repo]}" || true)
    facts=$(printf '%s\n' "$wft" | wf_facts)
    pushref=no
    if [ "$base" = main ]; then [ "$(printf '%s\n' "$facts" | head -1)" = push_main=yes ] && pushref=yes
    else printf '%s\n' "$wft" | wf_branches | grep -a '^release/' >/dev/null && pushref=yes; fi
    [ "$pushref" = yes ] || continue
    if [ -n "$(printf '%s\n' "$facts" | tail -n +2)" ] && [ -n "$oid" ]; then
      local files hit=no g
      files=$(ghq api "repos/$ORG/$repo/commits/$oid" --jq '.files[].filename' || true)
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        printf '%s\n' "$files" | grep -a "^${g%%\**}" >/dev/null && hit=yes
      done < <(printf '%s\n' "$facts" | tail -n +2)
      [ "$hit" = yes ] || { say "  ${T_WF[$repo]} does not build this merge (paths filter): no push run to wait for"; continue; }
    fi
    if id=$(find_new_run "$repo" "${T_WF[$repo]}" "$base" push "${pre:-0}"); then
      watch_run "$repo" "$id" || say "  (the release checks below will report it)"
    else
      say "  STOP $m: no new ${T_WF[$repo]} push run appeared within $((TRIES * POLL)) s, so $repo cannot be released yet: https://github.com/$ORG/$repo/actions"
      say "    Wait for it, then: $(resume_cmd merge)   (a merged PR is skipped)"
      return 1
    fi
  done
  say "  re-checking every repo after the merges"
  for r in "${ROWS[@]}"; do classify "$r"; done
}

phase_maven() {
  local st rc=0
  for st in 1 2 3 4; do
    tag_stage "$st" && continue
    rc=1; [ "$MODE" = dry ] || return 1   # a chain link that is not published stops the chain
  done
  return "$rc"
}
phase_apps() { local rc=0; tag_stage 8 || rc=1; tag_stage 9 || rc=1; return "$rc"; }
phase_rerun() { rerun_red 5 7; }
phase_gateway() { tag_stage 5; }
overlay_names() { rows_in_stage 6 | paste -sd' ' - | sed 's/ /, /g'; }
phase_gateway_access() {
  local want=0 r
  for r in $(rows_in_stage 6); do selected "$r" && want=1; done
  [ "$want" = 1 ] || { say "  no overlay selected"; return 0; }
  say "  The be/fe/pki overlays build FROM ghcr.io/$ORG/$GW_PKG and their GITHUB_TOKEN must be able to pull it."
  if probe_gateway; then say "  OK: the pinned gateway image is published and public"; return 0; fi
  say "  Give them read access (web UI only; there is no API for either):"
  say "    either make it Public: https://github.com/orgs/$ORG/packages/container/$GW_PKG/settings -> Danger Zone -> Change visibility"
  say "    or on that page, Manage Actions access -> add $(overlay_names) with Read"
  [ "$MODE" = dry ] && return 1
  pause_for "Do that now." || { say "  stopped. next: $(resume_cmd gateway-access)"; return 1; }
  if probe_gateway; then say "  OK: published and public"; return 0; fi
  say "  Still not public. Read access granted through Manage Actions access cannot be checked by any API."
  # --yes never answers this one: it is a click in the web UI that nothing here can see.
  if [ "$YES" = true ]; then
    say "  STOP (--yes does not answer this question): open https://github.com/orgs/$ORG/packages/container/$GW_PKG/settings"
    say "    and make it Public, or add $(overlay_names) with Read under Manage Actions access."
    say "    If you have already granted Read there, go on with: $(resume_cmd overlays)"
    return 1
  fi
  if confirm "Did you grant Read to $(overlay_names)?"; then return 0; fi
  say "  next: $(resume_cmd gateway-access)"; return 1
}
phase_overlays() { rerun_red 6 || true; tag_stage 6; }
phase_java() { tag_stage 7; }

phase_studio() {
  local v=$STUDIO rc=0
  if [ "$CHANNEL" = stable ]; then
    case "$v" in
      ""|none) say "  the Studio is not part of a stable run yet (it stays on its beta line)"; [ "$v" = none ] || studio_stable_needs; return 0 ;;
    esac
    say "  REFUSE --studio $v on the stable channel: scripts/release-studio.sh cannot release a stable Studio yet."
    studio_stable_needs
    return 1
  fi
  case "$v" in
    "") say "  no --studio given: the Studio is not released by this run (pass --studio <version>, --studio next, or --no-studio)"; studio_facts; return 0 ;;
    none) say "  --no-studio: skipped"; return 0 ;;
  esac
  if [ "$v" != next ] && ghq release view "studio-v$v" -R "$ORG/hugmesh-generator" --json tagName >/dev/null; then
    say "  DONE: release studio-v$v exists"; return 0
  fi
  if [ "$MODE" = dry ]; then
    say "  $(shown "$STUDIO_SCRIPT") ${v/next/} --dry-run:"
    if [ "$v" = next ]; then "$STUDIO_SCRIPT" --dry-run --yes 2>&1 | sed 's/^/    | /' || rc=$?
    else "$STUDIO_SCRIPT" "$v" --dry-run 2>&1 | sed 's/^/    | /' || rc=$?; fi
    return "$rc"
  fi
  confirm "Release the Studio ($v) with scripts/release-studio.sh?" || { say "  skipped. next: $(resume_cmd studio)"; return 1; }
  local args=()
  [ "$v" = next ] || args+=("$v")
  [ "$YES" = true ] && args+=(--yes)
  "$STUDIO_SCRIPT" "${args[@]}" || { rc=$?; say "  STOP: release-studio.sh exited $rc. Fix what it said, then: $(resume_cmd studio)"; return 1; }
}

phase_visibility() {
  print_nonpublic && return 0
  say "  New GHCR packages are created private. A package can only be made public in the web UI, and that cannot be undone."
  [ "$MODE" = dry ] && return 0
  pause_for "Make them public now (or leave some private on purpose)." || return 0
  say "  re-checking:"
  print_nonpublic || say "  (still private ones are listed above; the site cannot show an image nobody can pull)"
  return 0
}

phase_site() {
  local pre id
  say "  The release->site repository_dispatch needs SITE_DISPATCH_TOKEN, which is unset, so the site only refreshes on its own cron; this asks for it now."
  if [ "$MODE" = dry ]; then say "  would: gh workflow run pages.yml -R $SITE_REPO, then watch it"; return 0; fi
  confirm "Rebuild hugmesh.net now (gh workflow run pages.yml -R $SITE_REPO)?" || { say "  skipped: it refreshes within the hour anyway"; return 0; }
  pre=$(ghq run list -R "$SITE_REPO" --workflow pages.yml --limit 1 --json databaseId -q '.[].databaseId' || echo 0)
  GH workflow run pages.yml -R "$SITE_REPO" || { say "  could not dispatch pages.yml: it refreshes within the hour (cron)"; return 1; }
  if id=$(find_new_run hugmesh.github.io pages.yml "" workflow_dispatch "${pre:-0}"); then
    watch_run hugmesh.github.io "$id" || return 1
    say "  site rebuilt: https://hugmesh.net/downloads"
  else
    say "  the pages.yml run did not appear: https://github.com/$SITE_REPO/actions"
  fi
}

phase_verify() {
  local r p st=0 vis cont what=artifact
  load_site_map
  cont=$(ghq api "/orgs/$ORG/packages?package_type=container&per_page=100" --paginate --jq '.[]|.name+"="+.visibility' || true)
  say "  state      repo                                   release                where"
  for r in "${ROWS[@]}"; do
    [ "$MODE" = dry ] || classify "$r"
    row_line "$r"
    for p in ${T_PKGS[$r]}; do
      if [ "${T_KIND[$r]}" = img ]; then
        vis=$(printf '%s\n' "$cont" | sed -n "s#^$p=##p" | head -1)
        printf '             %-52s [%s] %s\n' "ghcr.io/$ORG/$p:${S_VER[$r]:-?}" "${vis:-not-created-yet}" "$(site_where "$r" "$p")"
      else
        printf '             %-52s %s\n' "maven $p:${S_VER[$r]:-?}" "$(site_where "$r" "$p")"
      fi
    done
    if selected "$r" && [ "${S_STATE[$r]}" != DONE ]; then st=1; fi
  done
  studio_facts
  say "  The Studio shows at the top of hugmesh.net/downloads."
  [ ${#ONLY[@]} -eq 0 ] || what="selected artifact"
  if [ "$st" = 0 ]; then say "== every $what is DONE"; return 0; fi
  [ "$MODE" = dry ] && return 0
  say "== not everything is DONE (rows above). Re-run: $(resume_cmd preflight)"
  return 1
}

# tests/scripts/test-release-beta.sh sources this file for its pure helpers (parse_version,
# vercmp, wf_facts, the bump helper); nothing below runs then.
if [ "${RELEASE_BETA_SOURCE_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

if [ "$URLS_ONLY" = true ]; then print_nonpublic || true; exit 0; fi

for i in "${!PHASES[@]}"; do
  p=${PHASES[$i]}
  CUR_PHASE=$p
  if [ "$i" -lt "$FROM_I" ] && [ "$p" != preflight ]; then continue; fi
  say
  say "######## phase $((i+1))/${#PHASES[@]}: $p ($MODE)"
  rc=0
  "phase_${p//-/_}" || rc=$?
  if [ "$rc" != 0 ]; then
    FAILED=1
    if [ "$MODE" = apply ]; then
      say
      say "Stopped in phase '$p'. Fix what it reported above, then resume with:"
      say "  $(resume_cmd "$p")"
      [ "$p" = verify ] || say "To leave it as it is and go on with the next phase: $(resume_cmd "$(next_phase "$p")")"
      exit 1
    fi
    say "  (dry run: phase '$p' would stop here; later phases are shown as if it had succeeded)"
  fi
done
say
if [ "$MODE" = dry ]; then
  say "Dry run: nothing was created or changed. To run it: $(resume_cmd preflight | sed 's/ --from preflight$//')"
fi
exit 0
