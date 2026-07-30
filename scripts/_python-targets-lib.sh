#!/usr/bin/env bash
# _python-targets-lib.sh — SOURCED helper: derive PYTHON_TARGETS /
# PYTHON_SINGLE_TARGET for a target sysroot FROM THE STAGE3 SEED ITSELF.
#
# WHY THIS EXISTS — A FROZEN python3_NN LITERAL WEDGED THE WHOLE MESH BUILD.
# Full analysis: docs/PYTHON-TARGETS-SEED-DRIFT.md. The short version:
#
#   1. A USE_EXPAND variable ASSIGNED in make.conf REPLACES the profile's value;
#      the same value written as a package.use `*/* PYTHON_TARGETS:` line is a
#      DELTA that ADDS to it (man 5 portage: "if you need to remove earlier
#      assignments or defaults, you need to explicitly specify '-*'"; portage's
#      config.regenerate() wipes every accumulated python_targets_* flag before
#      applying a non-incremental USE_EXPAND that a config layer SETS).
#      specs-*/portage/make.conf.tmpl used to assign PYTHON_TARGETS="python3_12",
#      so the effective set was exactly {python3_12} and the additive package.use
#      seed next to it contributed nothing — the opposite of its stated intent.
#
#   2. The stage3 seed's python FLOATS, per arch AND per snapshot:
#         amd64 stage3-...-20260726T160854Z : python 3.13 + 3.14, NO 3.12
#         arm64 (rpi5/frite/opi)            : python 3.14 only
#         jetson, 2026-07 era               : python 3.12 + 3.14
#      No literal can be right for all three, and a literal that is WRONG is not
#      merely stale — it is fatal in both directions:
#         * seed has a target our config drops -> the seed's own installed
#           portage/gemato demand python_targets_python3_1X from dev-python/*
#           slots our config forbids -> "Multiple package instances within a
#           single package slot" -> resolution aborts -> payload never merges.
#           (Session 20260729-233913-719d4e, build-pki.x86.log:105309.)
#         * seed has a target the tree's profile default has dropped -> freshly
#           pulled ebuilds come up without it -> "The following USE changes are
#           necessary to proceed: >=dev-python/... python_targets_python3_12".
#           (Jetson edge_ai fleet failure 2026-07-16, session 20260715-235432.)
#
# THE INVARIANT, which covers both: the sysroot's PYTHON_TARGETS must be a
# SUPERSET of the target set the seed's own installed packages were built with,
# derived at build time. Never a literal. `pt_apply_seed_targets` is that rule.
#
# Read-only against the seed; writes only ${SYSROOT}/etc/portage/{make.conf,
# package.use/python-targets}. No emerge, no network.

# ── pt_seed_targets <sysroot> ────────────────────────────────────────────────
# Print the seed's python target set, space-separated, version-ordered
# (e.g. "python3_13 python3_14"). Returns 1 (printing nothing) when the seed
# cannot be read — callers MUST treat that as fatal rather than guess, because
# every wrong guess is one of the two failure modes above.
#
# The authoritative source is which python_targets_* flags the seed's INSTALLED
# packages actually carry (var/db/pkg/*/*/USE) — that is exactly the set the
# seed's dependency atoms will demand of anything we rebuild. It is then
# INTERSECTED with the interpreters the seed can actually provide
# (var/db/pkg/dev-lang/python-*), so a ghost target left behind by an ancient
# binpkg cannot drag in an interpreter the tree has since removed.
pt_seed_targets() {
    local sysroot="${1:?pt_seed_targets: sysroot required}"
    local vdb_targets installed_targets result

    # dev-lang/python-exec is the multi-implementation WRAPPER: it is built with
    # every python_targets_* its IUSE knows (measured on a 3.14-only arm64 seed:
    # python3_12 python3_13 python3_14 python3_14t python3_15 python3_15t), so
    # its USE describes what python-exec supports, NOT what this seed was built
    # against. Including it would enable freethreading targets whose interpreter
    # the seed's dev-lang/python does not even carry (`freethreaded` is absent
    # from python-3.14.6_p1's USE), forcing a needless interpreter rebuild.
    local vdb_use
    vdb_use="$(
        for _f in "${sysroot}"/var/db/pkg/*/*/USE; do
            case "${_f}" in */dev-lang/python-exec*) continue ;; esac
            [ -f "${_f}" ] && cat "${_f}"
        done 2>/dev/null
    )"
    vdb_targets="$(printf '%s\n' "${vdb_use}" \
        | tr ' \t' '\n\n' \
        | sed -n 's/^python_targets_\(python3_[0-9][0-9]*t\?\)$/\1/p' \
        | sort -u)"

    # Interpreters the seed ships. dev-lang/python-3.14.6_p1 -> python3_14;
    # the freethreading variant is a USE flag on the same package, so the
    # usr/lib probe below is what distinguishes 3_14 from 3_14t if it matters.
    installed_targets="$(ls -d "${sysroot}"/var/db/pkg/dev-lang/python-3.* 2>/dev/null \
        | sed -n 's#.*/python-3\.\([0-9][0-9]*\)[.-].*#python3_\1#p' \
        | sort -u)"
    if [ -z "${installed_targets}" ]; then
        installed_targets="$(ls -d "${sysroot}"/usr/lib/python3.* 2>/dev/null \
            | sed -n 's#.*/python3\.\([0-9][0-9]*\)t\?$#python3_\1#p' \
            | sort -u)"
    fi
    # Flatten to a single space-delimited line: the `case` membership test below
    # matches on " ${x} " and would never fire against newline separators.
    # shellcheck disable=SC2086
    installed_targets="$(printf '%s\n' ${installed_targets} | tr '\n' ' ')"
    installed_targets="${installed_targets% }"

    if [ -n "${vdb_targets}" ] && [ -n "${installed_targets}" ]; then
        # Keep vdb targets whose interpreter the seed actually has (3_14t counts
        # as 3_14's interpreter), falling back to the raw union if the
        # intersection comes out empty (never narrow to nothing).
        result="$(
            for t in ${vdb_targets}; do
                case " ${installed_targets} " in
                    *" ${t%t} "*) printf '%s\n' "${t}" ;;
                esac
            done
        )"
        [ -n "${result}" ] || result="${vdb_targets}"
    else
        result="${vdb_targets}${vdb_targets:+ }${installed_targets}"
    fi

    result="$(printf '%s\n' ${result} | sort -u -V | tr '\n' ' ')"
    result="${result% }"
    [ -n "${result}" ] || return 1
    printf '%s\n' "${result}"
}

# ── pt_seed_single_target <targets...> ───────────────────────────────────────
# PYTHON_SINGLE_TARGET is `^^` (exactly-one) in REQUIRED_USE, so it must be
# exactly one member of the set above. Pick the newest NON-freethreading target
# (a freethreading single-target is not what python-single-r1 consumers expect).
pt_seed_single_target() {
    local t best=""
    for t in "$@"; do
        case "${t}" in *t) continue ;; esac
        best="${t}"
    done
    [ -n "${best}" ] || best="${1:-}"
    [ -n "${best}" ] || return 1
    printf '%s\n' "${best}"
}

# ── pt_apply_seed_targets <sysroot> <tag> ────────────────────────────────────
# Rewrite the rendered ${sysroot}/etc/portage/make.conf and the copied
# package.use/python-targets to the seed-derived values. MUST run after the
# stage3 is extracted and the specs are installed, and BEFORE the first emerge
# touches the sysroot — otherwise it reads its own effect back in (an emerge run
# under a wrong pin installs the wrong interpreter, which then looks like seed
# content).
#
# Returns 1 without touching anything if the seed cannot be read.
pt_apply_seed_targets() {
    local sysroot="${1:?pt_apply_seed_targets: sysroot required}"
    local tag="${2:-python-targets}"
    local mc="${sysroot}/etc/portage/make.conf"
    local pu="${sysroot}/etc/portage/package.use/python-targets"
    local targets single

    if ! targets="$(pt_seed_targets "${sysroot}")"; then
        printf '[%s] ERROR: could not read any python target from the stage3 seed at %s\n' "${tag}" "${sysroot}" >&2
        printf '[%s]        (probed var/db/pkg/*/*/USE and usr/lib/python3.*). Refusing to guess:\n' "${tag}" >&2
        printf '[%s]        a wrong PYTHON_TARGETS wedges the payload emerge in a dev-python slot\n' "${tag}" >&2
        printf '[%s]        conflict. See docs/PYTHON-TARGETS-SEED-DRIFT.md.\n' "${tag}" >&2
        return 1
    fi
    # shellcheck disable=SC2086
    single="$(pt_seed_single_target ${targets})" || return 1

    if [ ! -f "${mc}" ]; then
        printf '[%s] ERROR: %s does not exist — render make.conf before applying seed targets\n' "${tag}" "${mc}" >&2
        return 1
    fi

    # Drop any pre-existing assignment (there should be none — the templates
    # deliberately ship no literal — but a resumed/foreign sysroot may carry one)
    # and append the derived values.
    sed -i -E '/^[[:space:]]*PYTHON_(TARGETS|SINGLE_TARGET)=/d' "${mc}"
    {
        printf '\n# ── DERIVED FROM THE STAGE3 SEED — do not hardcode ───────────────────────────\n'
        printf '# Written by scripts/_python-targets-lib.sh (pt_apply_seed_targets) from the\n'
        printf '# targets this seed'"'"'s own installed packages carry. A frozen python3_NN literal\n'
        printf '# here is what wedged the 2026-07-29 mesh build in a dev-python slot conflict —\n'
        printf '# see docs/PYTHON-TARGETS-SEED-DRIFT.md.\n'
        printf 'PYTHON_TARGETS="%s"\n' "${targets}"
        printf 'PYTHON_SINGLE_TARGET="%s"\n' "${single}"
    } >> "${mc}"

    # package.use twin: an ADDITIVE delta (no '-*'), belt to make.conf's braces.
    # Same derived set, so it can only ever re-affirm, never narrow.
    mkdir -p "$(dirname "${pu}")"
    {
        printf '# DERIVED FROM THE STAGE3 SEED by scripts/_python-targets-lib.sh — do not edit.\n'
        printf '# Additive delta (never "-*"): package.use USE_EXPAND lines ADD to the profile\n'
        printf '# default, they do not replace it. See docs/PYTHON-TARGETS-SEED-DRIFT.md.\n'
        printf '*/* PYTHON_TARGETS: %s\n' "${targets}"
    } > "${pu}"

    printf '[%s] PYTHON_TARGETS="%s" PYTHON_SINGLE_TARGET="%s" (derived from the stage3 seed)\n' \
        "${tag}" "${targets}" "${single}"
    return 0
}
