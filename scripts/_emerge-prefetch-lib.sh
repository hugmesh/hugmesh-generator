#!/usr/bin/env bash
# _emerge-prefetch-lib.sh — SOURCED helper: ONE foreground `emerge --fetchonly`
# of the whole payload BEFORE the first merge.
#
# Issue #322 slice 2; decision 24 on #347, operator 2026-09-16:
#   "A: fetch everything first" — one `emerge --fetchonly` of the whole payload
#   before the first merge, accepting the cold-cache cost (measured ~+30-55 min
#   on this box's 3 MB/s cold DISTDIR; about zero warm).
#
# WHY. Slice 1 (PR #393) put a RATE FLOOR under the fetcher: specs-x86/portage/
# make.conf.tmpl's curl FETCHCOMMAND/RESUMECOMMAND abort a URI that trickles
# below 10 KiB/s for 60 s. That turned an INDEFINITE stall into a bounded
# ~5-minute failure of that URI — but a bounded failure of a single-source
# GitHub archive still DROPS its package under --keep-going, and the drop only
# surfaces hours later at the requested-atom completeness gate. Session
# 20260908T095149Z lost a full standalone-thick run that way: a 1.02 GB
# media-fonts/noto took plasma-integration -> plasma-workspace -> 8 more with
# it, including the REQUESTED atom kde-plasma/plasma-meta.
#
# So: fetch the whole graph up front, in the foreground, with visible retries.
# A file that cannot be downloaded is then a LOUD failure in the first minutes
# of a build instead of a silent package drop discovered after the compile.
#
# NEVER DELETE A PARTIAL. A wedged fetch is cleared by killing the fetcher, not
# by removing its `<distfile>.__download__`: portage respawns the fetcher within
# seconds, so the file removed is usually the one the NEW wget/curl just
# created, and it then writes into an unlinked inode (248 MB went nowhere on
# 2026-09-08) before ending in "Couldn't download". Nothing in this file removes
# anything from DISTDIR, and the failure message says so to the operator.
#
# CONTRACT WITH THE CALLER
#   hugmesh_prefetch_payload <atoms...>   -> 0 = every distfile is in DISTDIR,
#                                            or the pre-fetch could not run and
#                                            said so (see RESOLUTION below);
#                                            1 = at least one distfile is
#                                            genuinely unfetchable.
# The caller decides fatality, so the builder can honour --allow-missing-packages
# exactly as the completeness gate does rather than this lib inventing a policy.
#
# RESOLUTION FAILURE IS NOT A FETCH FAILURE. `emerge --fetchonly` resolves the
# whole dependency graph first, and this pass deliberately runs WITHOUT
# --autounmask-continue: applying USE changes here, before the system group has
# brought sys-apps/portage and sys-apps/baselayout current, would write
# package.use against a portage the payload merge no longer runs and would move
# what the #223 payload-plan gate later sees. So a resolver wall (keyword, mask,
# USE, slot conflict) means "the pre-fetch could not run", NOT "this build is
# doomed" — the payload merge crosses those with --autounmask-continue=y and the
# #223 gate is the thing that judges them. That case WARNS loudly, names the
# wall, and returns 0. Retrying it would be pointless: nothing about the network
# changes a slot conflict.
#
# WHAT THIS DOES NOT PROVE. The pass is a FLOOR, not a completeness proof: it
# resolves before the system/world groups have run, so a handful of distfiles
# pulled in by a post-update resolution can still be fetched later by the merges
# themselves. It is the big, mirror-less, single-source files this exists for,
# and those are in the graph from the start.
#
# HOST TRAPS this file is written against, all measured on the build host:
#   * bash 5.3 localises every name in `local a=$1 b=$a` BEFORE assigning, so
#     that dies under `set -u`. Every `local` here declares ONE name.
#   * `| grep -q` under `set -o pipefail` can report FAILURE on a match it
#     found (SIGPIPE). Every grep here reads a FILE and drains to /dev/null.
#   * grep fails OPEN on a NUL byte — `grep -a` everywhere, since an emerge log
#     can carry one.
#   * the caller may or may not have `set -e`/`set -u`/`pipefail`; nothing here
#     depends on either being set.

# Attempts for a FETCH failure (a resolver wall is never retried).
HUGMESH_PREFETCH_ATTEMPTS="${HUGMESH_PREFETCH_ATTEMPTS:-3}"
# Seconds between attempts. A transient mirror 500 or a dropped route is what a
# retry is for; the rate floor in make.conf already bounds each individual URI.
HUGMESH_PREFETCH_RETRY_DELAY="${HUGMESH_PREFETCH_RETRY_DELAY:-30}"
# Where the captured output lands (also the operator's evidence after a failure).
HUGMESH_PREFETCH_LOG="${HUGMESH_PREFETCH_LOG:-/tmp/hugmesh-prefetch.log}"
# Log-line prefix, matching the builder's own ("build-x86").
HUGMESH_PREFETCH_TAG="${HUGMESH_PREFETCH_TAG:-build-x86}"
# The emerge binary, overridable ONLY so the guard can drive this with a stub.
HUGMESH_PREFETCH_EMERGE="${HUGMESH_PREFETCH_EMERGE:-emerge}"

_hugmesh_prefetch_say() {
    echo "[${HUGMESH_PREFETCH_TAG}] $*"
}

# hugmesh_prefetch_classify <logfile> -> fetch | resolve | unknown
#
# Ordered fetch-first ON PURPOSE: a run that got as far as downloading has, by
# definition, already resolved, and portage's tail summary can mention both.
hugmesh_prefetch_classify() {
    local log
    log="${1:-}"
    [ -n "${log}" ] && [ -r "${log}" ] || { printf '%s' unknown; return 0; }
    if grep -aE "Couldn't download|^!!! Fetch failed for|Fetch failed for the following packages|Digest verification failed|^!!! Fetched file:" \
            "${log}" >/dev/null 2>&1; then
        printf '%s' fetch
        return 0
    fi
    if grep -aE "All ebuilds that could satisfy|there are no ebuilds|The following (keyword|mask|USE|license) changes are necessary|Multiple package instances within a single package slot|Problem resolving dependencies|masked by|slot conflict" \
            "${log}" >/dev/null 2>&1; then
        printf '%s' resolve
        return 0
    fi
    printf '%s' unknown
}

# hugmesh_prefetch_failed_files <logfile> — the distfiles portage named, one per
# line ("" when it named none). Both spellings portage uses.
hugmesh_prefetch_failed_files() {
    local log
    log="${1:-}"
    [ -n "${log}" ] && [ -r "${log}" ] || return 0
    sed -nE "s/.*Couldn't download '?([^'\"]+)'?\..*/\1/p;s/^!!! Fetch failed for '?([^'\", ]+)'?.*/\1/p" \
        "${log}" 2>/dev/null | sort -u
}

# hugmesh_prefetch_payload <atoms...>
hugmesh_prefetch_payload() {
    local attempt
    local rc
    local class
    local files
    if [ "$#" -eq 0 ]; then
        _hugmesh_prefetch_say "WARN: pre-fetch called with no atoms — nothing to fetch"
        return 0
    fi
    attempt=1
    while [ "${attempt}" -le "${HUGMESH_PREFETCH_ATTEMPTS}" ]; do
        _hugmesh_prefetch_say "Pre-fetch attempt ${attempt}/${HUGMESH_PREFETCH_ATTEMPTS}: downloading every distfile the payload needs BEFORE the first merge (decision 24 / issue #322). On a cold DISTDIR this is the long quiet part of the build."
        # tee, not a redirect: a 30-55 minute fetch must stay visible in the live
        # build log. PIPESTATUS[0] is emerge's own status — `tee` always exits 0,
        # so a plain `$?` would report the tee and this gate would fail OPEN.
        # PIPESTATUS[0], read in BOTH branches, and an `if` wrapper. Three traps,
        # each measured:
        #   * `tee` always exits 0, so a plain `$?` with pipefail OFF reports the
        #     tee and this gate fails OPEN — every unfetchable file becomes a pass;
        #   * with pipefail ON a plain `$?` happens to work, which is exactly why
        #     this is worth pinning: the production chroot runs `bash -eo pipefail`,
        #     so the bug would be invisible here and appear the day anything sources
        #     this lib from a plainer shell;
        #   * under `set -e` a bare failing pipeline aborts the caller with no
        #     message at all. The `if` suspends `set -e` for the pipeline, and both
        #     branches read PIPESTATUS so the verdict never depends on pipefail.
        if "${HUGMESH_PREFETCH_EMERGE}" --fetchonly --color=n "$@" 2>&1 | tee "${HUGMESH_PREFETCH_LOG}"; then
            rc="${PIPESTATUS[0]}"
        else
            rc="${PIPESTATUS[0]}"
            [ "${rc}" -eq 0 ] && rc=1
        fi
        if [ "${rc}" -eq 0 ]; then
            _hugmesh_prefetch_say "Pre-fetch OK: every distfile for the payload is in DISTDIR (attempt ${attempt})."
            return 0
        fi
        class="$(hugmesh_prefetch_classify "${HUGMESH_PREFETCH_LOG}")"
        if [ "${class}" = "resolve" ]; then
            _hugmesh_prefetch_say "WARN: PRE-FETCH SKIPPED — portage could not RESOLVE the payload here (rc=${rc}), so nothing was downloaded. This is a keyword/mask/USE/slot wall, not a network problem, and retrying cannot help: the payload merge crosses those with --autounmask-continue=y, and the payload-plan gate (issue #223) is what judges them. The build continues UNPROTECTED by the pre-fetch — a single-source distfile can still drop its package under --keep-going. Resolver output: ${HUGMESH_PREFETCH_LOG}"
            grep -aE "All ebuilds that could satisfy|there are no ebuilds|The following (keyword|mask|USE|license) changes are necessary|Multiple package instances within a single package slot|masked by|slot conflict" \
                "${HUGMESH_PREFETCH_LOG}" 2>/dev/null | head -n 20 || true
            return 0
        fi
        if [ "${attempt}" -lt "${HUGMESH_PREFETCH_ATTEMPTS}" ]; then
            _hugmesh_prefetch_say "WARN: pre-fetch attempt ${attempt} failed (rc=${rc}, ${class}); retrying in ${HUGMESH_PREFETCH_RETRY_DELAY}s. Partial downloads are KEPT — portage resumes them, and deleting a .__download__ makes the respawned fetcher write into an unlinked inode."
            sleep "${HUGMESH_PREFETCH_RETRY_DELAY}"
            attempt=$((attempt + 1))
            continue
        fi
        files="$(hugmesh_prefetch_failed_files "${HUGMESH_PREFETCH_LOG}")"
        _hugmesh_prefetch_say "ERROR: pre-fetch FAILED after ${HUGMESH_PREFETCH_ATTEMPTS} attempts (rc=${rc}, ${class}). Failing NOW, in the first minutes of the build, instead of merging for hours and losing the run at the requested-atom completeness gate."
        if [ -n "${files}" ]; then
            _hugmesh_prefetch_say "ERROR: distfiles portage could not download:"
            printf '%s\n' "${files}" | sed "s/^/[${HUGMESH_PREFETCH_TAG}] ERROR:   /"
        else
            _hugmesh_prefetch_say "ERROR: portage named no specific distfile; read ${HUGMESH_PREFETCH_LOG}."
        fi
        _hugmesh_prefetch_say "ERROR: what to do — check the mirrors for the file (large GitHub archives are usually absent from them, and GitHub answers a Range request with 200 so a resume restarts the whole body), or download it by hand and place it in DISTDIR under its FINAL name after verifying size + BLAKE2B + SHA512 against the ebuild Manifest. Do NOT delete any *.__download__ partial: portage has already respawned a fetcher onto that name."
        return 1
    done
    # unreachable; a loop that somehow exits is a failure, never a silent pass
    _hugmesh_prefetch_say "ERROR: pre-fetch loop ended without a verdict — treating as FAILED"
    return 1
}
