#!/usr/bin/env bash
# test-sec-policy-keyword-coherence.sh — every sec-policy/* package in a spec tree
# resolves from the SAME refpolicy release.
#
# WHY. sec-policy/selinux-base installs the refpolicy interface headers
# (/usr/share/selinux/<type>/include) and every other sec-policy/selinux-<module>
# compiles its .te against them, so all of them must come from one refpolicy
# release. specs-x86 is stable-keyworded (make.conf ACCEPT_KEYWORDS="amd64") but
# its package.accept_keywords/selinux carried
#     sec-policy/selinux-base ~amd64
#     sec-policy/selinux-base-policy ~amd64
# and nothing for the modules. Once refpolicy 2.20260922_p1 reached ~amd64 the
# base pair resolved to it while selinux-xserver stayed on stable 2.20260616_p1.
# 2.20260922 dropped the prelink module, 2.20260616's xserver.te still calls
# prelink_object_file(), and the 2026-11-12 standalone-unaffiliated x86 build died:
#     xserver.te:240:ERROR 'syntax error' at token 'prelink_object_file'
# leaving the stage4 payload without grub-install, dracut, parted, nmcli, Xorg,
# lightdm or openbox.
#
# THE RULE, per specs-*/portage tree:
#   1. When make.conf.tmpl's ACCEPT_KEYWORDS is stable-only, a sec-policy line in
#      package.accept_keywords may only be the whole-category wildcard
#      (sec-policy/*). A single atom moves that one package off the release the
#      rest of the category resolves to.
#   2. In any tree, no sec-policy keyword line may accept live ebuilds (**) or
#      name a version, and package.mask / package.unmask may not name a single
#      sec-policy atom: each one pins part of the category to a different release.
# Static: no gentoo tree, no network, no root. Section B runs the same checker
# against fixtures, including the exact pre-fix lines, so the guard is proven to
# go red on the defect it was written for.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${SEC_POLICY_GUARD_ROOT:-$(cd "${HERE}/../.." && pwd)}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

# Non-comment, non-blank lines of a portage config path (file or directory).
cfg_lines() {
    local p="$1"
    [ -e "${p}" ] || return 0
    if [ -d "${p}" ]; then
        find "${p}" -type f ! -name '.*' -print0 | sort -z | xargs -0 -r cat
    else
        cat "${p}"
    fi | sed -e 's/#.*$//' -e 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' || true
}

# check_tree <specs-*/portage dir> — prints one line per violation, nothing when clean.
check_tree() {
    local portage="$1" ak stable=true line atom kws
    ak="$(grep -h '^[[:space:]]*ACCEPT_KEYWORDS=' "${portage}"/make.conf* 2>/dev/null | tail -1 || true)"
    case "${ak}" in *'~'*) stable=false ;; esac
    while IFS= read -r line; do
        read -r atom kws <<<"${line}"
        case "${atom}" in
            sec-policy/*|[\<\>=~]*sec-policy/*) ;;
            *) continue ;;
        esac
        if [ "${atom}" = 'sec-policy/*' ]; then
            case " ${kws} " in *' ** '*) echo "accept_keywords: ${line} (accepts live ebuilds)" ;; esac
            continue
        fi
        case "${atom}" in
            [\<\>=~]*) echo "accept_keywords: ${line} (versioned sec-policy atom)"; continue ;;
        esac
        case " ${kws} " in *' ** '*) echo "accept_keywords: ${line} (accepts live ebuilds)"; continue ;; esac
        if ${stable}; then
            echo "accept_keywords: ${line} (single atom in a stable-keyworded tree; use sec-policy/*)"
        fi
    done < <(cfg_lines "${portage}/package.accept_keywords")
    local f
    for f in package.mask package.unmask; do
        while IFS= read -r line; do
            read -r atom _ <<<"${line}"
            case "${atom}" in
                'sec-policy/*') ;;
                sec-policy/*|[\<\>=~]*sec-policy/*) echo "${f}: ${line} (pins one sec-policy atom)" ;;
            esac
        done < <(cfg_lines "${portage}/${f}")
    done
}

echo "== A. every spec tree in the repository =="
found=0
for portage in "${REPO}"/specs*/portage; do
    [ -d "${portage}" ] || continue
    found=$((found + 1))
    name="${portage#"${REPO}"/}"
    out="$(check_tree "${portage}")"
    if [ -z "${out}" ]; then
        pass "${name}: sec-policy keywording is coherent"
    else
        fail "${name}: sec-policy packages can resolve from different refpolicy releases:"
        printf '         %s\n' "${out}" | sed 's/^ *//; s/^/         /'
    fi
done
[ "${found}" -ge 2 ] && pass "scanned ${found} spec trees" || fail "found only ${found} spec trees under ${REPO} — wrong root?"

# specs-x86 must actually be scanned (the tree the 2026-11-12 build died in).
[ -f "${REPO}/specs-x86/portage/make.conf.tmpl" ] \
    && grep -q '^ACCEPT_KEYWORDS="amd64"' "${REPO}/specs-x86/portage/make.conf.tmpl" \
    && pass "specs-x86 is stable-keyworded, so rule 1 applies to it" \
    || fail "specs-x86 make.conf.tmpl no longer carries ACCEPT_KEYWORDS=\"amd64\" — re-read this guard's premise"

echo "== B. the checker against fixtures =="
FIX="$(mktemp -d "${TMPDIR:-/tmp}/sec-policy-kw.XXXXXX")"
trap 'rm -rf "${FIX}"' EXIT
# fixture <name> <ACCEPT_KEYWORDS> <accept_keywords body> [<package.mask body>]
fixture() {
    local d="${FIX}/$1/portage"
    mkdir -p "${d}/package.accept_keywords"
    printf 'ACCEPT_KEYWORDS="%s"\n' "$2" > "${d}/make.conf.tmpl"
    printf '%b' "$3" > "${d}/package.accept_keywords/selinux"
    [ $# -ge 4 ] && printf '%b' "$4" > "${d}/package.mask"
    echo "${d}"
}
expect() {  # expect red|green <label> <dir>
    local out; out="$(check_tree "$3")"
    if [ "$1" = red ] && [ -n "${out}" ]; then pass "red: $2"
    elif [ "$1" = green ] && [ -z "${out}" ]; then pass "green: $2"
    else fail "expected $1: $2 — checker said: ${out:-<nothing>}"; fi
}
expect red "the pre-fix specs-x86 lines (base + base-policy ~amd64, stable tree)" \
    "$(fixture prefix amd64 '# SELinux core\nsys-libs/libselinux ~amd64\nsec-policy/selinux-base ~amd64\nsec-policy/selinux-base-policy ~amd64\nsys-libs/libsepol ~amd64\n')"
expect red "one module keyworded alone (selinux-xserver ~amd64)" \
    "$(fixture onemod amd64 'sec-policy/selinux-xserver ~amd64\n')"
expect red "a versioned pin (=sec-policy/selinux-base-2.20260922_p1)" \
    "$(fixture versioned 'amd64 ~amd64' '=sec-policy/selinux-base-2.20260922_p1 ~amd64\n')"
expect red "live ebuilds accepted (** on selinux-base)" \
    "$(fixture live 'arm64 ~arm64' 'sec-policy/selinux-base **\n')"
expect red "a single sec-policy atom masked" \
    "$(fixture masked amd64 'sys-libs/libselinux ~amd64\n' '>=sec-policy/selinux-base-2.20260922_p1\n')"
expect red "single atom with trailing comment and tab separator" \
    "$(fixture tabbed amd64 'sec-policy/selinux-base\t~amd64   # still testing\n')"
expect green "the fixed specs-x86 shape (libraries only)" \
    "$(fixture fixed amd64 '# NO sec-policy line\n# sec-policy/selinux-base ~amd64\nsys-libs/libselinux ~amd64\nsys-libs/libsepol ~amd64\n')"
expect green "the whole category keyworded at once" \
    "$(fixture wildcard amd64 'sec-policy/* ~amd64\n')"
expect green "per-atom ~arm64 lines in a tree that accepts ~arm64 globally" \
    "$(fixture armglobal 'arm64 ~arm64' 'sec-policy/selinux-base ~arm64\nsec-policy/selinux-base-policy ~arm64\n')"

echo "== sec-policy keyword coherence: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
