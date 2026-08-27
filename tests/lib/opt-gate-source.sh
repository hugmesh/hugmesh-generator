# shellcheck shell=bash
# opt-gate-source.sh — resolve WHERE a given stage4 builder's optional-service
# gate actually comes from, and load THAT.
#
# WHY THIS EXISTS (2026-08-26)
# ---------------------------
# Every suite that exercises the optional-service gate used to reach into ONE
# builder with
#
#     extract_fn() { awk "/^$1\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "${BUILDER}"; }
#
# and that is fine only while the function is defined IN that file. Three real
# defects shipped in x86 images precisely because build-x86-host-stage4.sh's copy
# of the gate had DRIFTED from build-rpi5-stage4.sh's (missing 13a ApplicationSet
# flag render, no anubis handling at all, and the edge-ai-analysis dependsOn guard
# running BEFORE EXCLUDE_SERVICES subtracted). The gate now lives in ONE shared
# file, scripts/_optional-services-lib.sh, that both builders source — so an
# awk-the-builder extractor finds nothing and the suite dies with "could not
# extract", which is loud but useless.
#
# WHAT THIS DOES INSTEAD
# ----------------------
# For a given builder it reproduces BASH'S OWN resolution order:
#
#     1. every scripts/*-lib.sh the builder `source`s, in source order;
#     2. the builder file itself, LAST.
#
# Definitions later in that order win, exactly as they would at run time. So:
#
#   * today, both builders resolve the gate to the shared lib — the parity
#     question is structurally answered;
#   * if someone re-adds a LOCAL copy of _opt_render_appset_flag (or any other
#     _opt_* function, or a `case` arm) to one builder, that copy is what bash
#     would run, and it is therefore what these suites load and execute. A
#     behavioural assertion on the rendered artefact then goes RED for the
#     builder that regressed. A test that merely grepped for the function NAME
#     would stay green — the name is present in both files either way.
#
# CONTRACT: the caller defines info()/warn() (the builders' logger) before
# calling any loaded function. Loading itself never calls them.

# opt_gate_sources <builder> — print, one per line, every file that can define
# the builder's gate, in bash resolution order (libs first, builder last).
opt_gate_sources() {
    local builder="$1"
    local dir lib
    dir="$(cd "$(dirname "${builder}")" && pwd)"
    # Only the literal `source "${SCRIPT_DIR}/scripts/<name>"` form is used by
    # these builders; comment-stripped so a line of PROSE naming a lib cannot
    # add a phantom source (prose naming a token has inverted greps in this repo
    # four times — see the house rules).
    while IFS= read -r lib; do
        [ -f "${dir}/${lib}" ] && printf '%s\n' "${dir}/${lib}"
    done < <(sed -e 's/#.*$//' "${builder}" \
             | grep -oE '^[[:space:]]*(source|\.)[[:space:]]+"\$\{SCRIPT_DIR\}/(scripts/[A-Za-z0-9_.-]+)"' \
             | grep -oE 'scripts/[A-Za-z0-9_.-]+')
    printf '%s\n' "${builder}"
}

# THREE SPELLINGS, NOT ONE. bash accepts every one of these as a definition of
# NAME, and runs whichever comes LAST:
#
#     NAME() { … }            NAME ()  { … }          function NAME { … }
#     function NAME() { … }     …and any of them indented.
#
# The first version of this file matched only `NAME() {` anchored at column 1.
# MEASURED (2026-08-26, adversarial review): injecting
# `_opt_render_appset_flag ()  {\n    return 0\n}` — or the `function` form, or an
# indented copy — into build-x86-host-stage4.sh immediately after its `source` line
# left ALL SEVEN suites GREEN (parity 64/0, exclude 165/0, workload-console 55/0)
# while bash really did run the no-op override, i.e. defect D1 reproduced verbatim
# and undetected. Only the one spelling the old regex happened to be written
# against went red. A resolver that resolves like bash for ONE spelling out of four
# is not a resolver; the matcher below takes all of them.
#
# LAST DEFINITION WINS **WITHIN** A FILE TOO, not just across the chain: bash keeps
# the last one it executed, so a file that defines NAME twice resolves to the
# second. The awk below therefore keeps scanning and remembers the last complete
# block rather than exiting on the first.
#
# WHERE THE DEFINITION *ENDS* IS PART OF THE SAME BUG (2026-08-26, second review
# pass). Widening the definition regex was necessary and NOT sufficient: the first
# fix still terminated the block on `^<the exact indent of the def line>}`. bash
# does not care where a closing brace sits, so
#
#       _opt_render_appset_flag() {     <- indented two spaces
#         return 0
#     }                                 <- closed at column 0
#
# is a perfectly good override that bash runs — and the matcher above HAPPILY
# matched its definition line, then scanned to EOF looking for `^  }`, found none,
# and returned the EMPTY string. Empty means "this file does not define it", so the
# LIBRARY copy won and the override was invisible all over again. MEASURED: that
# spelling left parity 71/0 and exclude 185/0 GREEN while the other four went red,
# i.e. the same class of hole the first fix was written to close, one layer down.
# The terminator is now "the first `}` indented no deeper than the definition line",
# which is identical to the old behaviour for a column-0 definition and correct for
# an indented one. Seven spellings are now exercised by the battery, TAB-indented
# and indented-`function` included.
#
# _opt_gate_defre <fn> — the ERE that matches any bash spelling of `<fn>`'s
# definition line. Kept in ONE place so the extractor and any caller that needs to
# ask "is this line a definition?" cannot drift apart.
_opt_gate_defre() {
    local fn="$1"
    printf '%s' "^[[:space:]]*((function[[:space:]]+${fn}[[:space:]]*([(][[:space:]]*[)])?)|(${fn}[[:space:]]*[(][[:space:]]*[)]))[[:space:]]*([{]|$)"
}

# opt_gate_extract_fn <builder> <fn> — print the definition of <fn> as the given
# builder would resolve it (LAST definition in resolution order wins). Empty
# output means no file in that builder's chain defines it — a real absence, which
# is itself one of the three defects this guards.
opt_gate_extract_fn() {
    local builder="$1" fn="$2" f found=""
    local defre; defre="$(_opt_gate_defre "${fn}")"
    while IFS= read -r f; do
        local body
        # `indent` is captured from the definition line so an INDENTED definition
        # terminates on its own matching-indent `}` rather than running to EOF.
        body="$(awk -v defre="${defre}" '
            !p && $0 ~ defre {
                p=1; buf=$0 "\n"
                # dind = the indent WIDTH of the definition line. The block ends at
                # the first `}` whose indent is <= dind: the brace of a nested block is
                # always deeper, and an indented definition may legally close at
                # column 0 (bash does not care). Matching `^<indent>}` EXACTLY —
                # what this did before — ran such a definition to EOF and returned
                # NOTHING, so the builder-local override lost to the library copy
                # and the suites stayed green. See the MEASURED note below.
                dind = match($0, /[^[:space:]]/) - 1
                if ($0 ~ /[}][[:space:]]*$/) { last=buf; p=0 }
                next
            }
            p {
                buf = buf $0 "\n"
                cind = match($0, /[^[:space:]]/)
                if (cind > 0 && substr($0, cind, 1) == "}" && (cind - 1) <= dind) { last=buf; p=0 }
                next
            }
            END { printf "%s", last }
        ' "${f}")"
        [ -n "${body}" ] && found="${body}"
    done < <(opt_gate_sources "${builder}")
    printf '%s' "${found}"
}

# opt_gate_load <builder> [fn...] — eval the named functions into the CURRENT
# shell as that builder resolves them. Dies loudly (rc 1, named function) rather
# than leaving a suite to run against an undefined name.
opt_gate_load() {
    local builder="$1"; shift
    local fn src
    for fn in "$@"; do
        src="$(opt_gate_extract_fn "${builder}" "${fn}")"
        if [ -z "${src}" ]; then
            echo "  FAIL ${fn} is not defined ANYWHERE in $(basename "${builder}")'s source chain" >&2
            return 1
        fi
        eval "${src}"
        type "${fn}" >/dev/null 2>&1 || {
            echo "  FAIL ${fn} failed to eval from $(basename "${builder}")'s source chain" >&2
            return 1
        }
    done
}

# opt_gate_case_body <builder> <label> — the body of the `<label>)` arm of the
# gate's per-slug case, as that builder resolves it. Used by suites that want to
# execute ONE slug's prune without running the whole gate.
#
# Like opt_gate_extract_fn above, this takes every spelling bash accepts for the
# arm — a leading `(` (`(games)`), and the label as one alternative of a pattern
# list (`games|foo)`, `foo|games)`) — and keeps the LAST matching arm in a file
# rather than the first. Matching only `games)` would let a re-spelled arm hide
# from the suite exactly the way a re-spelled function definition did.
opt_gate_case_body() {
    local builder="$1" lbl="$2" f found=""
    while IFS= read -r f; do
        local body
        body="$(awk -v lbl="${lbl}" '
            BEGIN { re = "^[[:space:]]*[(]?[[:space:]]*([^)]*[|][[:space:]]*)?" lbl "([[:space:]]*[|][^)]*)?[[:space:]]*[)][[:space:]]*$" }
            !p && $0 ~ re { p=1; buf=""; next }
            p && $0 ~ /^[[:space:]]*;;[[:space:]]*$/ { last=buf; p=0; next }
            p { buf = buf $0 "\n"; next }
            END { if (p) last=buf; printf "%s", last }
        ' "${f}")"
        [ -n "${body}" ] && found="${body}"
    done < <(opt_gate_sources "${builder}")
    printf '%s' "${found}"
}
