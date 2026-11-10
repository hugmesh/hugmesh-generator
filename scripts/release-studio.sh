#!/usr/bin/env bash
# release-studio.sh — cut a HugMesh Image Studio release with ONE command.
#
#   scripts/release-studio.sh next                       # the next beta (0.4.1-beta.1 -> 0.4.1-beta.2)
#   scripts/release-studio.sh next-minor                 # a new minor (0.4.1-beta.2 -> 0.5.0-beta.1)
#   scripts/release-studio.sh next-major                 # a new major (0.5.0-beta.3 -> 1.0.0-beta.1)
#   scripts/release-studio.sh --final                    # the stable X.Y.Z of the current beta line
#   scripts/release-studio.sh next-minor --final         # straight to the next minor's X.Y.0
#   scripts/release-studio.sh 0.5.0-beta.2               # any explicit version
#   scripts/release-studio.sh                            # proposes the next beta and asks
#   scripts/release-studio.sh next-minor --dry-run       # read-only preflight + plan
#   scripts/release-studio.sh 0.5.0-beta.2 --republish   # REPLACE a published release's files
#
# THE VERSION. An explicit MAJOR.MINOR.PATCH[-beta.N], or a keyword: next (= next-beta),
# next-minor, next-major. A keyword counts from the newest studio-v* tag on GitHub,
# i.e. what was already released, never from this checkout; when main's __version__
# was bumped past every tag and never released, that pending version is used instead
# (studio/packaging/release_version.py `resolve` holds the rule, and the tests).
#
# THE CHANNEL. A beta (X.Y.Z-beta.N) is a pre-release and is never "latest". A final
# X.Y.Z is the stable channel and becomes the LATEST release, so it needs --final
# (or --channel stable): a final typed without it is refused, and a beta typed with
# it is refused too.
#
# WHAT IT DOES. It preflights read-only against the GitHub API, prints the plan, asks,
# then starts ONE GitHub Actions run: "Cut a Studio release"
# (.github/workflows/studio-release-cut.yml). That run commits the bump of
# __version__ and the Flatpak metainfo to main, creates the tag studio-v<version> ON
# GITHUB, and dispatches studio-release.yml on that tag, which builds, signs and
# publishes the MSI, the Flatpak and the tarball on GitHub-hosted runners. This script
# streams both runs and ends with the release URL and the verify commands.
#
# WHAT IT NEVER DOES. It never creates a tag, never pushes, never needs a clean (or
# current) checkout, and under --dry-run it never reaches `gh workflow run`. Every gh
# call runs with GH_TOKEN and GITHUB_TOKEN unset: on this fleet an exported read-only
# token shadows the keyring login (scripts/_github-auth-lib.sh explains).
#
# REPUBLISH is the loud, explicit way to do what was done by hand on 2026-10-23: it
# replaces every file of an existing release, so every checksum, signature and
# attestation changes and anyone who downloaded earlier can no longer verify what they
# have. The script prints that and makes you type the version back (--yes does not
# skip it). It takes an explicit version, never a keyword. A wrong build gets a new
# version (the next beta N, or the next patch after a final), not a republish.
#
# CLOCKS. The two runs are found by "created after this machine's UTC now"; a local
# clock that runs slow can make the 90 s poll miss them. Nothing is lost: the script
# exits 3 and points at Actions, where the runs are.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
RELEASE_VERSION="$ROOT/studio/packaging/release_version.py"
SITE_REPO="hugmesh/hugmesh.github.io"
WAIT_SECONDS=90

usage() {
    # The header comment, up to the first line that is not one.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    echo
    echo "usage: release-studio.sh [VERSION | next | next-beta | next-minor | next-major] [--final | --channel beta|stable]"
    echo "                         [--republish] [--yes] [--dry-run] [--site] [--repo OWNER/NAME]"
}

VERSION=""; REPUBLISH=false; YES=false; DRY_RUN=false; SITE=false; FINAL=false; REPO="hugmesh/hugmesh-generator"
set_channel() {
    case "$1" in
        stable) FINAL=true ;;
        beta) FINAL=false ;;
        *) echo "release-studio.sh: --channel is beta or stable, not '$1'" >&2; exit 2 ;;
    esac
}
while [ $# -gt 0 ]; do
    case "$1" in
        --final) FINAL=true ;;
        --channel) shift; set_channel "${1:-}" ;;
        --channel=*) set_channel "${1#--channel=}" ;;
        --republish) REPUBLISH=true ;;
        --yes|-y) YES=true ;;
        --dry-run|-n) DRY_RUN=true ;;
        --site) SITE=true ;;
        --repo) shift; REPO="${1:?--repo needs OWNER/NAME}" ;;
        --repo=*) REPO="${1#--repo=}" ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "release-studio.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
        *) if [ -n "$VERSION" ]; then echo "release-studio.sh: one version only" >&2; exit 2; fi; VERSION="$1" ;;
    esac
    shift
done

# ── helpers ─────────────────────────────────────────────────────────────────────
gh_() { env -u GH_TOKEN -u GITHUB_TOKEN gh "$@"; }
say() { printf '%s\n' "$*"; }
stop() { say "release-studio.sh: $*" >&2; exit 2; }
auth_hint() {
    # The one line scripts/_github-auth-lib.sh prints for this case.
    say "[github-auth] No usable GitHub credentials for github.com/$REPO. Fix: gh auth login (an exported read-only GH_TOKEN shadows the keyring; this script already unsets it)." >&2
}

# ── 1-7. preflight, all read-only ───────────────────────────────────────────────
SPEC="$VERSION"
CHANNEL_ARGS=()
[ "$FINAL" = true ] && CHANNEL_ARGS=(--final)
if [ "$FINAL" = true ]; then channel_word="stable"; else channel_word="beta"; fi
say "Preflight for the Studio on $REPO, $channel_word channel (read-only)"

gh_ auth status >/dev/null 2>&1 || { auth_hint; stop "gh is not logged in"; }
visibility=$(gh_ api "repos/$REPO" --jq .visibility 2>/dev/null) || { auth_hint; stop "cannot read $REPO"; }
[ "$visibility" = "public" ] || stop "$REPO is $visibility; attestations fail on a private repository and nothing would be released"
say "  1. $REPO is public"

# What main carries and what was released: the two facts a keyword counts from.
main_version=$(gh_ api "repos/$REPO/contents/studio/hugmesh_studio/__init__.py?ref=main" --jq .content | base64 -d | sed -n 's/^__version__ = "\([^"]*\)"$/\1/p') || stop "could not read main's __version__"
[ -n "$main_version" ] || stop "main's studio/hugmesh_studio/__init__.py has no __version__ line"
tags_all=$(gh_ api "repos/$REPO/git/matching-refs/tags/studio-v" --jq '.[].ref') || stop "could not list tags"

case "$SPEC" in
    ""|next|next-beta|next-minor|next-major)
        [ "$REPUBLISH" = false ] || stop "--republish takes the explicit version of an existing release, not '${SPEC:-a proposal}'"
        word=${SPEC:-next}
        # shellcheck disable=SC2086  # one ref per line, no spaces
        VERSION=$(python3 "$RELEASE_VERSION" resolve "$word" "${CHANNEL_ARGS[@]}" --main "$main_version" --after-tags $tags_all) \
            || stop "could not work out '$word' on the $channel_word channel (main is at $main_version)"
        # shellcheck disable=SC2086  # one ref per line, no spaces
        newest_tag=$(python3 "$RELEASE_VERSION" newest $tags_all) || stop "could not order the studio-v* tags"
        newest_tag=${newest_tag:+studio-v$newest_tag}
        if [ -z "$SPEC" ]; then
            say "Main's __version__ is $main_version, the newest tag is ${newest_tag:-none}; the next $channel_word is $VERSION."
            if [ "$YES" != true ]; then
                printf 'Release %s? [Y/n] ' "$VERSION"
                read -r reply
                case "$reply" in ""|[yY]*) ;; *) say "Nothing done."; exit 0 ;; esac
            fi
        else
            say "  $word on the $channel_word channel is $VERSION (main is at $main_version, the newest tag is ${newest_tag:-none})"
        fi
        ;;
    *)
        python3 "$RELEASE_VERSION" validate "$VERSION" >/dev/null || stop "$VERSION is not a releasable version"
        python3 "$RELEASE_VERSION" resolve "$VERSION" "${CHANNEL_ARGS[@]}" >/dev/null || stop "$VERSION does not fit the $channel_word channel"
        ;;
esac
TAG="studio-v$VERSION"
# What to type to run this again for the same version (the channel flag included).
again="$0 $VERSION${CHANNEL_ARGS[*]:+ ${CHANNEL_ARGS[*]}}"
say "  2. $VERSION is a valid MAJOR.MINOR.PATCH[-beta.N] for the $channel_word channel"

if out=$(gh_ release view "$TAG" --repo "$REPO" --json tagName 2>&1); then
    release_state=present
else
    case "$out" in
        *"release not found"*) release_state=absent ;;
        *) stop "could not tell whether release $TAG exists: $out" ;;
    esac
fi
if [ "$REPUBLISH" = false ] && [ "$release_state" = present ]; then
    stop "release $TAG already exists; nothing was changed. To replace its files on purpose (every checksum changes): $again --republish"
fi
if [ "$REPUBLISH" = true ] && [ "$release_state" = absent ]; then
    stop "republish was requested but release $TAG does not exist; run a normal release"
fi
say "  3. release $TAG is $release_state"

if [ "$REPUBLISH" = false ]; then
    # Every existing studio-v* tag EXCEPT this version's own: a tag with no release is
    # the "build failed, run the same command again" case, and the cut moves it.
    all_tags=$(printf '%s\n' "$tags_all" | grep -vx "refs/tags/$TAG" || true)
    # shellcheck disable=SC2086  # one ref per line, no spaces
    python3 "$RELEASE_VERSION" validate "$VERSION" --after-tags $all_tags >/dev/null || stop "$VERSION does not sort after the newest existing studio-v* tag; choose a later version"
    say "  4. $VERSION sorts after every existing tag"
else
    say "  4. (ordering skipped: republish)"
fi

in_progress() {  # in_progress WORKFLOW [gh run list args...] -> count; a workflow not yet on main counts as 0
    local wf="$1" out; shift
    if out=$(gh_ run list --repo "$REPO" --workflow "$wf" "$@" --status in_progress --json databaseId --jq length 2>&1); then
        printf '%s\n' "$out"
    else
        case "$out" in
            *"not found"*) printf '0\n' ;;
            *) stop "could not list runs of $wf: $out" ;;
        esac
    fi
}
busy=$(in_progress studio-release.yml --branch "$TAG")
[ "$busy" = "0" ] || stop "a studio-release.yml run on $TAG is in progress; wait for it (Actions > Studio release), then run again"
busy=$(in_progress studio-release-cut.yml)
[ "$busy" = "0" ] || stop "a 'Cut a Studio release' run is in progress; wait for it (Actions), then run again"
say "  5. no release run in progress"

if [ "$REPUBLISH" = false ]; then
    case "$(python3 "$RELEASE_VERSION" compare "$main_version" "$VERSION")" in
        eq)
            # __version__ alone is not the whole bump: a hand edit of __init__.py
            # without the metainfo <release> (567a5a60) leaves main half-bumped, and the
            # cut's bump commit adds the missing entry.
            entry="<release version=\"$(printf '%s' "$VERSION" | sed 's/-/~/')\""
            meta=$(gh_ api "repos/$REPO/contents/studio/packaging/flatpak/org.hugmesh.ImageStudio.metainfo.xml?ref=main" --jq .content | base64 -d) || stop "could not read main's Flatpak metainfo"
            if printf '%s\n' "$meta" | grep -F "$entry" >/dev/null; then
                bump="no bump: main is already at $VERSION"
            else
                bump="commit the missing metainfo <release> entry for $VERSION on main (its __version__ was bumped by hand without it)"
            fi ;;
        lt) bump="commit the bump of __version__ from $main_version to $VERSION on main" ;;
        *) stop "main is already at $main_version, which is later than $VERSION; choose a later version" ;;
    esac
    say "  6. main's __version__ is $main_version"
else
    say "  6. (main's version not compared: republish)"
    file_at_tag=$(gh_ api "repos/$REPO/contents/.github/workflows/studio-release.yml?ref=refs/tags/$TAG" --jq .content | base64 -d) || stop "could not read the workflow file at $TAG"
    if ! printf '%s\n' "$file_at_tag" | grep -E '^ {6}republish:[[:space:]]*$' >/dev/null; then
        stop "the workflow file at tag $TAG predates the republish input; this release cannot be re-published through this path (see docs/STUDIO-INSTALLERS.md, 'Releases cut before the republish input')"
    fi
    say "  7. the workflow file at $TAG declares the republish input"
fi

# ── the plan ────────────────────────────────────────────────────────────────────
actor=$(gh_ api user --jq .login 2>/dev/null || echo "you")
echo
if [ "$REPUBLISH" = false ]; then
    say "Plan: will"
    say "  - $bump (as $actor, through the cut workflow's token)"
    say "  - create tag $TAG on that commit, on GitHub"
    say "  - start the signed build on GitHub-hosted runners (studio-release.yml on refs/tags/$TAG)"
    case "$VERSION" in *-*) say "  - publish a PRE-RELEASE (never latest)" ;; *) say "  - publish the release and mark it latest" ;; esac
    say "  - the Downloads page on hugmesh.github.io refreshes within the hour"
else
    say "Plan: will REPLACE every file of release $TAG:"
    say "  every checksum, signature and attestation changes; anyone who downloaded"
    say "  earlier can no longer verify what they have against the new notes."
    say "  The tag stays where it is; the build is dispatched on it."
fi
echo
if [ "$DRY_RUN" = true ]; then
    say "Dry run: stopping here. Nothing was created or changed."
    exit 0
fi

if [ "$REPUBLISH" = true ]; then
    printf 'Type %s to confirm: ' "$VERSION"
    read -r typed
    [ "$typed" = "$VERSION" ] || stop "confirmation did not match; nothing done"
elif [ "$YES" = false ]; then
    printf 'Proceed? [y/N] '
    read -r reply
    case "$reply" in [yY]*) ;; *) say "Nothing done."; exit 0 ;; esac
fi

# ── dispatch the cut and watch it ───────────────────────────────────────────────
ts=$(date -u +%FT%TZ)
if [ "$REPUBLISH" = true ]; then
    gh_ workflow run studio-release-cut.yml --repo "$REPO" --ref main -f "version=$VERSION" -f republish=true -f dry_run=false -f "confirm=$VERSION"
else
    gh_ workflow run studio-release-cut.yml --repo "$REPO" --ref main -f "version=$VERSION" -f republish=false -f dry_run=false
fi
say "Dispatched 'Cut a Studio release' at $ts"

find_run() {  # find_run WORKFLOW [--branch B]  -> prints "id url" of the newest run created after $ts
    local wf="$1"; shift
    local waited=0 found=""
    while [ "$waited" -le "$WAIT_SECONDS" ]; do
        found=$(gh_ run list --repo "$REPO" --workflow "$wf" --event workflow_dispatch "$@" --json databaseId,createdAt,url \
            --jq "[.[] | select(.createdAt >= \"$ts\")] | sort_by(.createdAt) | last | select(. != null) | \"\(.databaseId) \(.url)\"" 2>/dev/null || true)
        [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
        sleep 5; waited=$((waited + 5))
    done
    return 1
}

cut_run=$(find_run studio-release-cut.yml) || { say "The cut run is not found yet: Actions > Cut a Studio release" >&2; exit 3; }
say "Cut run: ${cut_run#* }"
# `cmd || rc=$?` keeps gh's real status; inside `if ! cmd; then`, $? is the negation (0).
rc=0
gh_ run watch "${cut_run%% *}" --repo "$REPO" --exit-status || rc=$?
if [ "$rc" -ne 0 ]; then
    say "The cut failed: ${cut_run#* }" >&2
    say "Fix what it reports, then run the same command again (the cut is idempotent)." >&2
    exit "$rc"
fi

release_run=$(find_run studio-release.yml --branch "$TAG") || { say "The release run is not found yet: Actions > Studio release, branch $TAG" >&2; exit 3; }
say "Release run: ${release_run#* }"
rc=0
gh_ run watch "${release_run%% *}" --repo "$REPO" --exit-status || rc=$?
if [ "$rc" -ne 0 ]; then
    say "The build/publish run failed: ${release_run#* }" >&2
    say "Fix, then run the same command again." >&2
    exit "$rc"
fi

# ── narration ───────────────────────────────────────────────────────────────────
url=$(gh_ release view "$TAG" --repo "$REPO" --json url --jq .url)
echo
say "Released: $url"
tmp="${TMPDIR:-/tmp}/release-studio-$$"
mkdir -p "$tmp"
if gh_ release download "$TAG" --repo "$REPO" --pattern SHA256SUMS --dir "$tmp" >/dev/null 2>&1; then
    echo; cat "$tmp/SHA256SUMS"
fi
rm -rf "$tmp"
workflow="$REPO/.github/workflows/studio-release.yml"
echo
say "Verify a download (the release notes carry the same commands):"
say "  gh attestation verify hugmesh-studio-$VERSION-x64.msi --repo $REPO --signer-workflow $workflow --source-ref refs/tags/$TAG --deny-self-hosted-runners"
say "  cosign verify-blob --bundle SHA256SUMS.sigstore.json --certificate-identity https://github.com/$workflow@refs/tags/$TAG --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS"
say "  sha256sum --check --ignore-missing SHA256SUMS"
echo
if [ "$SITE" = true ]; then
    if gh_ workflow run pages.yml --repo "$SITE_REPO"; then
        say "Downloads page: asked $SITE_REPO to rebuild now (pages.yml, with your token)."
    else
        say "Downloads page: could not dispatch pages.yml on $SITE_REPO with your token; it refreshes within the hour anyway (pages.yml cron)."
    fi
else
    say "Downloads page: refreshed by $SITE_REPO within the hour (pages.yml cron); --site asks for it now."
fi
