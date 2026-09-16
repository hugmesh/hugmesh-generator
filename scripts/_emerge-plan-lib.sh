#!/usr/bin/env bash
# _emerge-plan-lib.sh — SOURCED helper: resolved-plan preview emission for every
# builder that emerges (x86 native chroot + the nine ARM cross builders).
#
# WHY THIS EXISTS — THE PLAN IS NOT SCRAPABLE FROM A NORMAL MERGE.
# The Studio's per-package emerge tree can only create a package row when portage
# prints ">>> Emerging (N of M) atom" — i.e. when the package STARTS. Portage does
# NOT print its resolved plan during a normal merge (the operator's live log
# out/sessions/20260729-223952-9503fa/build-standalone-thick.x86.log carries zero
# "These are the packages that would be merged" and zero "[ebuild" lines), so
# "show the packages that WILL be installed, collapsed, up front" requires a
# deliberate --pretend pass and a pinned wire format the parser can consume.
#
# WIRE FORMAT (CROSS-LANE CONTRACT with the Studio parser,
# studio/hugmesh_studio/core/emerge_packages.py PLAN_BANNER_PREFIX — the same
# both-sides-pinned pattern as the "==> Emerge group: " banner, gated fail-closed
# by tests/build-matrix/check.sh's EPL bucket). Every line starts with the ONE
# prefix below; four shapes, all ANSI-free (--color=n) and greppable:
#
#   ==> Emerge plan: <group> total=<M> binary=<B> ebuild=<E>
#   ==> Emerge plan: <group> <idx>/<M> <atom> via=<binary|ebuild> USE="<flags>"
#   ==> Emerge plan: <group> <idx>/<M> <atom> via=<binary|ebuild>
#   ==> Emerge plan: <group> unavailable reason=<slug>
#
#   * <group> is the emerge-group taxonomy word the following merge belongs to
#     (image|tools|dependencies|system|world) — same vocabulary as the group
#     banners, emitted immediately BEFORE the corresponding group banner.
#   * <atom> is the resolved cat/pn-ver with its slot/subslot and ::repo tails
#     stripped (--verbose renders `cat/pn-ver:SLOT/SUB::repo`; cat/pn-ver itself
#     never contains ':', so everything from the first ':' goes); a cross-merge
#     " to /sysroot/" tail never reaches the atom (field split).
#   * via=<binary|ebuild> is portage's own row kind — [binary ...] rows are
#     merged from the binpkg pool, [ebuild ...] rows are compiled — and the
#     total line carries the two counts (B + E == M). This is the per-group
#     BINPKG REUSE reading issue #46 asked for: the parser used to discard the
#     bracket block, so the distinction never reached the Studio. The lib also
#     prints one human line per group, "[emerge-plan] <group> binpkg reuse: B of
#     M package(s) from the pool (P%), E to compile", so a build log answers
#     "how much did the pool save this image?" without the Studio.
#   * USE="..." is copied verbatim from portage's own --pretend row when the row
#     carries one (the flags column the operator asked for — free from the same
#     output); omitted when portage printed none for that row.
#   * unavailable slugs: opt-out (--no-emerge-plan), pretend-failed (nonzero
#     resolution), pretend-timeout (exceeded EMERGE_PLAN_TIMEOUT), and
#     parse-mismatch (portage's own "Total: N packages" disagrees with the rows
#     we parsed — emit an honest nothing rather than a fabricated list).
#
# READ-ONLY BY CONSTRUCTION. The pass runs the SAME argument vector as the merge
# it precedes (the caller passes the real command + args verbatim; check.sh's EPL
# bucket pins the textual parity) with --pretend --verbose --color=n --nospinner
# --autounmask-write=n appended: nothing merges, nothing is written to portage
# config, and the plan therefore describes exactly the merge that follows —
# including [binary vs [ebuild rows under --usepkg.
#
# WHY --verbose (issue #319, measured on portage 3.0.82.2). Portage prints its
# "Total: N packages" line ONLY under --verbose. Without it, a group with nothing
# to merge and a pretend output whose row shape drifted out from under the parser
# are byte-identical (header + "Calculating dependencies" and no rows), so the
# only honesty guard that could fire in production was the one that mislabels an
# empty group "parse-mismatch" — every `--resume` with @world already satisfied
# hit it, and the message that is supposed to mean "the parser broke" fired on
# healthy builds. With --verbose:
#     empty     -> "Total: 0 packages, Size of downloads: 0 KiB"      -> total=0
#     non-empty -> [ebuild ...] rows + "Total: N package(s) ..."      -> cross-checked
#     drift     -> no rows parsed but "Total: N>0"                    -> parse-mismatch
# The cost is one more column in the atom (the slot tail, stripped above); the
# wire format the Studio consumes is unchanged. Real captures of both verbose
# shapes live in tests/build-matrix/fixtures/emerge-pretend-plan.verbose*.txt.
#
# NEVER BREAKS A BUILD. A cosmetic preview must not cost an image: every failure
# path (mktemp failure, resolution error, timeout, parse drift) emits the
# 'unavailable' shape, WARNs on stderr, and RETURNS 0 — same tooling-failure
# discipline as _payload-gate-lib.sh. The x86 call sites additionally run under
# the chroot's `bash -e`, so the return-0 contract is load-bearing there.
#
# COST. A pretend pass is a SECOND full dependency resolution per planned group —
# it is NOT free, and no wall-time number is quoted here because none was measured
# in a sandboxed checkout (see docs/EMERGE-PLAN-PREVIEW.md for the honest cost
# discussion). Bounds: only the multi-package groups get a plan (single-known-atom
# groups are declared not_planned in progress-tables.json), --no-emerge-plan opts
# a build out entirely, and EMERGE_PLAN_TIMEOUT (default 1800s) caps the worst
# case at a WARN, not a hang.
#
# COEXISTENCE NOTE (badges-Emit): a follow-up phase is queued to emit per-package
# flag badges from `emerge -pv --color=y` plus a description sidecar FILE. That
# emission must use its OWN sentinel blocks ("emerge badges", not "emerge-plan
# preview") and its own output file — this lib's stdout wire format and the
# "==> Emerge plan: " prefix are reserved for the plan lines above.

# The ONE builder-side pin. check.sh's EPL bucket asserts this string equals the
# parser-side PLAN_BANNER_PREFIX constant byte-for-byte.
EMERGE_PLAN_PREFIX="==> Emerge plan: "

# emerge_plan_emit GROUP CMD ARG...
#   GROUP     emerge-group word the following merge is banner'd as
#   CMD ARG...  the REAL merge invocation, verbatim (CMD may be a shell function,
#             e.g. cross_emerge — which is why the timeout is a hand-rolled
#             watchdog: coreutils `timeout`/`setsid` cannot run shell functions)
# Env: EMERGE_PLAN_ENABLED (default true; false => opt-out shape, no resolution)
#      EMERGE_PLAN_TIMEOUT seconds (default 1800)
# Emits the wire format on stdout; ALWAYS returns 0.
emerge_plan_emit() {
    local group="$1"; shift
    local pfx="${EMERGE_PLAN_PREFIX}"
    # Failed-resolution keep-file: when the pretend pass fails, its output is
    # KEPT here (not discarded) so a caller may act on it — the x86 payload
    # fail-fast gate (hugmesh_payload_plan_gate, issue #223) reads it to stop a
    # build the real merge is guaranteed to fail anyway. Cleared up front on
    # EVERY invocation (opt-out included) so a stale file from a previous run or
    # group can never trigger a gate for a plan that resolved — resumed sysroots
    # persist their /tmp across builds. Still ALWAYS returns 0: the keep-file is
    # advisory, the never-breaks-a-build contract above is unchanged.
    local keep="${TMPDIR:-/tmp}/hugmesh-emerge-plan-${group}-pretend-failed.log"
    rm -f "${keep}" 2>/dev/null || true
    if [ "${EMERGE_PLAN_ENABLED:-true}" != "true" ]; then
        printf '%s%s unavailable reason=opt-out\n' "${pfx}" "${group}"
        return 0
    fi
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/hugmesh-emerge-plan.XXXXXX" 2>/dev/null)" || {
        printf '%s%s unavailable reason=pretend-failed\n' "${pfx}" "${group}"
        printf '[emerge-plan] WARN: mktemp failed — %s plan preview skipped (build continues)\n' "${group}" >&2
        return 0
    }
    printf '[emerge-plan] resolving the %s plan (same emerge args + --pretend; opt out with --no-emerge-plan)\n' "${group}"
    # Watchdog-supervised pretend pass. Backgrounded subshell + kill loop instead
    # of `timeout`, because CMD is allowed to be a shell function (cross_emerge).
    # pkill -P sweeps the subshell's direct child (the real emerge process) on
    # timeout — best-effort (guarded: procps may be absent in a minimal chroot).
    local pid rc=0 waited=0 tmo="${EMERGE_PLAN_TIMEOUT:-1800}"
    ( "$@" --pretend --verbose --color=n --nospinner --autounmask-write=n ) >"${tmp}" 2>&1 &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null; do
        if [ "${waited}" -ge "${tmo}" ]; then
            kill -TERM "${pid}" 2>/dev/null || true
            { command -v pkill >/dev/null 2>&1 && pkill -TERM -P "${pid}" 2>/dev/null; } || true
            sleep 2
            kill -KILL "${pid}" 2>/dev/null || true
            { command -v pkill >/dev/null 2>&1 && pkill -KILL -P "${pid}" 2>/dev/null; } || true
            rc=124
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if [ "${rc}" -eq 124 ]; then
        wait "${pid}" 2>/dev/null || true
        printf '%s%s unavailable reason=pretend-timeout\n' "${pfx}" "${group}"
        printf '[emerge-plan] WARN: %s plan pass exceeded %ss — preview skipped, build continues (raise EMERGE_PLAN_TIMEOUT or pass --no-emerge-plan)\n' "${group}" "${tmo}" >&2
        rm -f "${tmp}"
        return 0
    fi
    wait "${pid}" && rc=0 || rc=$?
    if [ "${rc}" -ne 0 ]; then
        printf '%s%s unavailable reason=pretend-failed\n' "${pfx}" "${group}"
        if mv -f "${tmp}" "${keep}" 2>/dev/null; then
            printf '[emerge-plan] WARN: --pretend resolution exited %s — %s preview skipped, build continues (the real merge below reports any real failure itself); resolver output kept at %s\n' "${rc}" "${group}" "${keep}" >&2
        else
            printf '[emerge-plan] WARN: --pretend resolution exited %s — %s preview skipped, build continues (the real merge below reports any real failure itself)\n' "${rc}" "${group}" >&2
            rm -f "${tmp}"
        fi
        return 0
    fi
    # Parse the pretend rows into the wire format. Merge rows are [ebuild ...]
    # and [binary ...]; the atom is the first field after the bracket block with
    # its slot/subslot and ::repo tails stripped; USE="..." is copied verbatim
    # when present.
    # HONESTY GUARDS (parse-mismatch, all emit-nothing-rather-than-lie). All
    # three are LIVE because the pass runs --verbose, which is the only mode in
    # which portage prints the Total line they key on (issue #319):
    #   * zero rows parsed while portage's own "Total: N packages" says N>0
    #     (the row shape drifted out from under this parser);
    #   * zero rows AND no Total line at all (the output shape drifted — under
    #     --verbose portage always prints Total, even "Total: 0 packages", so a
    #     missing line means -v was lost or the framing changed);
    #   * N rows parsed but Total disagrees AND the stream carried no
    #     [uninstall]/[blocks] complication rows that could account for it.
    # A genuine empty merge set ("Total: 0 packages") emits total=0 — a real,
    # expected reading, same as the scheduler's ">>> Jobs: 0 of 0".
    local wire="${tmp}.wire"
    awk -v pfx="${pfx}" -v grp="${group}" '
        { gsub(/\033\[[0-9;]*[A-Za-z]/, "") }   # ANSI belt-and-braces (--color=n already passed)
        /^\[(ebuild|binary)/ {
            line = $0
            # Row kind BEFORE the bracket block is stripped: [binary = merged
            # from the binpkg pool, [ebuild = compiled (issue #46 reuse reading).
            via = (line ~ /^\[binary/) ? "binary" : "ebuild"
            sub(/^\[[^]]*\][[:space:]]*/, "", line)
            split(line, f, /[[:space:]]+/)
            atom = f[1]
            # cat/pn-ver carries no ":" — so the first ":" starts the slot tail
            # (--verbose: "cat/pn-ver:6/6.11.2::gentoo") or the ::repo suffix
            # (non-verbose captures: "cat/pn-ver::gentoo"); drop from there.
            sub(/:.*$/, "", atom)
            use = ""
            if (match(line, /USE="[^"]*"/)) use = substr(line, RSTART, RLENGTH)
            cnt++
            atoms[cnt] = atom
            uses[cnt] = use
            vias[cnt] = via
            if (via == "binary") nbin++; else nebd++
            next
        }
        /^\[(uninstall|blocks)/ { extra++; next }
        /^Total: [0-9]+ package/ {
            tl = $0
            sub(/^Total:[[:space:]]*/, "", tl)
            sub(/[[:space:]].*$/, "", tl)
            total_seen = 1
            total = tl + 0
        }
        END {
            if (cnt == 0 && total_seen && total > 0) { print "__EMERGE_PLAN_PARSE_MISMATCH__"; exit }
            if (cnt == 0 && !total_seen)             { print "__EMERGE_PLAN_PARSE_MISMATCH__"; exit }
            if (cnt > 0 && total_seen && extra == 0 && cnt != total) { print "__EMERGE_PLAN_PARSE_MISMATCH__"; exit }
            printf "%s%s total=%d binary=%d ebuild=%d\n", pfx, grp, cnt, nbin + 0, nebd + 0
            for (i = 1; i <= cnt; i++) {
                if (uses[i] != "")
                    printf "%s%s %d/%d %s via=%s %s\n", pfx, grp, i, cnt, atoms[i], vias[i], uses[i]
                else
                    printf "%s%s %d/%d %s via=%s\n", pfx, grp, i, cnt, atoms[i], vias[i]
            }
        }' "${tmp}" >"${wire}" 2>/dev/null || {
        printf '%s%s unavailable reason=parse-mismatch\n' "${pfx}" "${group}"
        printf '[emerge-plan] WARN: awk parse of the pretend output failed — %s preview skipped (build continues)\n' "${group}" >&2
        rm -f "${tmp}" "${wire}"
        return 0
    }
    if grep -q '^__EMERGE_PLAN_PARSE_MISMATCH__' "${wire}" 2>/dev/null || [ ! -s "${wire}" ]; then
        printf '%s%s unavailable reason=parse-mismatch\n' "${pfx}" "${group}"
        printf '[emerge-plan] WARN: pretend output did not parse as a plan (row/Total drift) — %s preview skipped, build continues\n' "${group}" >&2
    else
        cat "${wire}"
        # Per-group binpkg reuse, human-readable, on stdout next to the wire
        # (issue #46 box 1). Read back off the total line just emitted so the
        # number can never disagree with the wire. Guarded like everything else
        # here: a shape miss prints nothing and the build continues.
        local _tot _bin
        _tot="$(sed -nE 's/^.* total=([0-9]+) binary=([0-9]+) ebuild=[0-9]+$/\1/p' "${wire}" 2>/dev/null | head -n 1)"
        _bin="$(sed -nE 's/^.* total=([0-9]+) binary=([0-9]+) ebuild=[0-9]+$/\2/p' "${wire}" 2>/dev/null | head -n 1)"
        if [ -n "${_tot}" ] && [ -n "${_bin}" ] && [ "${_tot}" -gt 0 ] 2>/dev/null; then
            printf '[emerge-plan] %s binpkg reuse: %s of %s package(s) from the pool (%s%%), %s to compile\n' \
                "${group}" "${_bin}" "${_tot}" "$(( _bin * 100 / _tot ))" "$(( _tot - _bin ))"
        elif [ "${_tot}" = "0" ]; then
            printf '[emerge-plan] %s binpkg reuse: nothing to merge\n' "${group}"
        fi
    fi
    rm -f "${tmp}" "${wire}"
    return 0
}
