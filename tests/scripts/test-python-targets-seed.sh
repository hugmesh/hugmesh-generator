#!/usr/bin/env bash
# ── python-targets seed guard ────────────────────────────────────────────────
# WHAT THIS GUARDS, AND WHY IT NO LONGER GUARDS A VERSION LITERAL.
#
# This guard used to assert the exact string "*/* PYTHON_TARGETS: python3_12" in
# every spec dir, in the ARM copy loops and in Dockerfile.build. That froze a
# python version into the fleet, and the freeze is precisely what broke:
#
#   * 2026-07-16, jetson edge_ai (session 20260715-235432). Seed built for 3.12,
#     tree's profile default already past it -> freshly pulled ebuilds came up
#     with python_targets_python3_12 UNSET -> "The following USE changes are
#     necessary to proceed: >=dev-python/...  python_targets_python3_12".
#     The python3_12 literal fixed that — for that seed.
#
#   * 2026-07-29, the 11-image mesh build (session 20260729-233913-719d4e). The
#     amd64 seed had moved to 3.13+3.14 with NO 3.12, so the SAME literal now
#     pointed at an interpreter the seed did not have. The seed's own installed
#     portage/gemato kept demanding python_targets_python3_13/14 from
#     dev-python/{requests,certifi,charset-normalizer,idna,urllib3,pysocks} while
#     our config forced those slots to 3_12 only ->
#         "!!! Multiple package instances within a single package slot ...
#          resulting in a slot conflict"
#     -> resolution aborted -> "stage4 payload incomplete — missing:
#     grub-install dracut parted jq nmcli kubelet kubeadm containerd".
#
# Same bug, mirror images. A guard that asserts a literal cannot catch the second
# one — it MANDATES it. So this guard now asserts the INVARIANT instead:
#
#   PYTHON_TARGETS must be a SUPERSET of the target set the stage3 seed's own
#   installed packages were built with, derived at build time, never frozen; and
#   PYTHON_SINGLE_TARGET must be exactly one member of it (^^ REQUIRED_USE).
#
# Full analysis, with the portage semantics citations (a USE_EXPAND variable
# assigned in make.conf REPLACES the profile default; the same value in
# package.use is a DELTA that ADDS): docs/PYTHON-TARGETS-SEED-DRIFT.md.
#
# Runs offline, as any user, with no emerge, no network and no root: the
# behavioural half builds synthetic seed sysroots in a tempdir.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

SPEC_DIRS=(specs-frite specs-rpi5 specs-orangepi5 specs-orangepi-zero2 specs-orangepi-zero2w
           specs-orangepi-zero3 specs-orangepi3-lts specs-orangepi4-lts specs-jetson specs-x86)
ARM_BUILDERS=(build-frite-stage4.sh build-rpi5-stage4.sh build-orangepi5-stage4.sh
              build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh
              build-orangepi-zero3-stage4.sh build-orangepi3-lts-stage4.sh
              build-orangepi4-lts-stage4.sh build-jetson-stage4.sh)
ALL_BUILDERS=("${ARM_BUILDERS[@]}" build-x86-host-stage4.sh)

TMP="$(mktemp -d "${TMPDIR:-/tmp}/python-targets-guard.XXXXXX")"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

echo "== python-targets seed guard =="

# ── 1. NO FROZEN VERSION LITERAL WHERE THE SEED DECIDES ──────────────────────
# make.conf is the layer that REPLACES; a python3_NN literal there silently
# narrows every image to whatever was right for the seed of the day.
for d in "${SPEC_DIRS[@]}"; do
    f="${GEN}/${d}/portage/make.conf.tmpl"
    if [ ! -f "${f}" ]; then bad "${d}: make.conf.tmpl missing"; continue; fi
    if grep -vE '^[[:space:]]*#' "${f}" | grep -qE '^[[:space:]]*PYTHON_(TARGETS|SINGLE_TARGET)=.*python3_[0-9]'; then
        bad "${d}/make.conf.tmpl: assigns a FROZEN python3_NN literal — make.conf REPLACES the profile default; derive it from the seed instead (docs/PYTHON-TARGETS-SEED-DRIFT.md)"
    else
        ok "${d}/make.conf.tmpl: no frozen PYTHON_TARGETS/PYTHON_SINGLE_TARGET literal"
    fi
done

# Same rule for the package.use twin: it is the ADDITIVE layer, but a frozen
# literal there still rots (and still drags in an interpreter the seed lacks).
for d in "${SPEC_DIRS[@]}"; do
    f="${GEN}/${d}/portage/package.use/python-targets"
    if [ ! -f "${f}" ]; then bad "${d}: package.use/python-targets missing"; continue; fi
    if grep -vE '^[[:space:]]*#' "${f}" | grep -qE 'PYTHON_TARGETS:.*python3_[0-9]'; then
        bad "${d}/package.use/python-targets: ships a FROZEN python3_NN target list"
    else
        ok "${d}/package.use/python-targets: no frozen target literal"
    fi
done

# ── 2. THE DELTA STAYS A DELTA ───────────────────────────────────────────────
# man 5 portage: a package.use USE_EXPAND line ADDS; "if you need to remove
# earlier assignments or defaults, you need to explicitly specify '-*'". Writing
# '-*' turns the widening back into the replacement that caused the outage.
for d in "${SPEC_DIRS[@]}"; do
    f="${GEN}/${d}/portage/package.use/python-targets"
    [ -f "${f}" ] || continue
    if grep -vE '^[[:space:]]*#' "${f}" | grep -qE 'PYTHON_TARGETS:.*-\*'; then
        bad "${d}/package.use/python-targets: uses '-*' — that makes the delta REPLACE the profile default"
    else
        ok "${d}/package.use/python-targets: additive (no '-*')"
    fi
done

# PYTHON_SINGLE_TARGET must never be force-enabled through a '*/*' wildcard:
# it is ^^ (exactly-one) in REQUIRED_USE and a wildcard delta can enable two.
for d in "${SPEC_DIRS[@]}"; do
    f="${GEN}/${d}/portage/package.use/python-targets"
    [ -f "${f}" ] || continue
    if grep -vE '^[[:space:]]*#' "${f}" | grep -qE '^\s*\*/\*\s+PYTHON_SINGLE_TARGET'; then
        bad "${d}: seed force-enables a global PYTHON_SINGLE_TARGET (REQUIRED_USE ^^ hazard)"
    else
        ok "${d}: no global PYTHON_SINGLE_TARGET override"
    fi
done

# ── 3. EVERY BUILDER DERIVES FROM THE SEED ───────────────────────────────────
LIB="${GEN}/scripts/_python-targets-lib.sh"
if [ -f "${LIB}" ]; then
    ok "scripts/_python-targets-lib.sh present"
else
    bad "scripts/_python-targets-lib.sh missing — nothing derives PYTHON_TARGETS from the seed"
fi
for s in "${ALL_BUILDERS[@]}"; do
    f="${GEN}/${s}"
    if [ ! -f "${f}" ]; then bad "${s}: script missing"; continue; fi
    if grep -q '_python-targets-lib.sh' "${f}" && grep -qE '^[[:space:]]*pt_apply_seed_targets ' "${f}"; then
        ok "${s}: derives PYTHON_TARGETS from the stage3 seed"
    else
        bad "${s}: does NOT call pt_apply_seed_targets — it would inherit whatever literal the template carries"
    fi
done

# ORDER MATTERS, TWICE.
#  * The derivation writes make.conf, so it must run AFTER the render that
#    creates it (otherwise render_template overwrites the derived values).
#  * It reads the seed's vdb, so it must run BEFORE the first emerge INTO THAT
#    SYSROOT — an emerge under a wrong pin installs the wrong interpreter and a
#    later probe would read its own effect back in. Host-side emerges (build
#    container tooling, a different root) do not count; the sysroot-facing calls
#    are cross_emerge on the ARM builders and the chroot emerge on x86.
for s in "${ALL_BUILDERS[@]}"; do
    f="${GEN}/${s}"
    [ -f "${f}" ] || continue
    apply_ln="$(grep -nE '^[[:space:]]*pt_apply_seed_targets ' "${f}" | head -1 | cut -d: -f1)"
    [ -n "${apply_ln}" ] || continue
    render_ln="$(grep -nE '^render_template "\$\{SPECS_DIR\}/portage/make\.conf\.tmpl"' "${f}" | head -1 | cut -d: -f1)"
    if [ -n "${render_ln}" ] && [ "${apply_ln}" -lt "${render_ln}" ]; then
        bad "${s}: pt_apply_seed_targets (line ${apply_ln}) runs BEFORE the make.conf render (line ${render_ln}) — the render would wipe the derived values"
    else
        ok "${s}: seed derivation (line ${apply_ln}) runs after the make.conf render"
    fi
    if [ "${s}" = "build-x86-host-stage4.sh" ]; then
        # Canonical taxonomy banner first ("Emerging @system (hardened, native chroot)"),
        # with the pre-taxonomy "Native emerge inside chroot" wording as a fallback so
        # the ordering probe still anchors on an old checkout/branch.
        emerge_ln="$(grep -nE '^banner "(Emerging @system|Native emerge inside chroot)' "${f}" | head -1 | cut -d: -f1)"
    else
        emerge_ln="$(grep -nE '^[[:space:]]*cross_emerge ' "${f}" | head -1 | cut -d: -f1)"
    fi
    if [ -z "${emerge_ln}" ]; then
        bad "${s}: could not locate the first sysroot-facing emerge — the ordering invariant cannot be checked"
    elif [ "${apply_ln}" -lt "${emerge_ln}" ]; then
        ok "${s}: seed derivation (line ${apply_ln}) runs before the first sysroot emerge (line ${emerge_ln})"
    else
        bad "${s}: pt_apply_seed_targets at line ${apply_ln} runs AFTER the sysroot emerge at line ${emerge_ln} — it would read its own effect back in"
    fi
done

# ── 4. BEHAVIOURAL: THE INVARIANT ITSELF ─────────────────────────────────────
# Synthetic seeds, one per historical failure shape. The derived target set must
# be a SUPERSET of what the seed's own packages carry, and the derived single
# target must be exactly one member of it. This is the only assertion that
# actually encodes the rule; everything above is structure.
if [ -f "${LIB}" ]; then
    # shellcheck source=/dev/null
    source "${LIB}"

    make_seed() {   # $1 fixture name  $2 targets in vdb USE  $3 python versions shipped
        local r="${TMP}/$1" u="" t v
        mkdir -p "${r}/var/db/pkg/dev-python/certifi-1" \
                 "${r}/var/db/pkg/app-portage/gemato-1" \
                 "${r}/var/db/pkg/dev-lang/python-exec-2.4.10" \
                 "${r}/etc/portage/package.use" "${r}/usr/lib"
        for t in $2; do u="${u} python_targets_${t}"; done
        echo "elibc_glibc kernel_linux${u}" > "${r}/var/db/pkg/dev-python/certifi-1/USE"
        echo "gpg${u}"                      > "${r}/var/db/pkg/app-portage/gemato-1/USE"
        # python-exec is built for EVERY implementation it knows — the derivation
        # must ignore it, or it enables freethreading targets with no interpreter.
        echo "native-symlinks python_targets_python3_12 python_targets_python3_13 python_targets_python3_14 python_targets_python3_14t python_targets_python3_15 python_targets_python3_15t" \
            > "${r}/var/db/pkg/dev-lang/python-exec-2.4.10/USE"
        for v in $3; do mkdir -p "${r}/var/db/pkg/dev-lang/python-${v}.9_p1" "${r}/usr/lib/python${v}"; done
        printf 'CHOST="x"\nUSE="foo"\n' > "${r}/etc/portage/make.conf"
        printf '%s\n' "${r}"
    }

    check_fixture() {   # $1 label  $2 fixture dir  $3 targets the seed requires
        local label="$1" root="$2" required="$3" got single t
        if ! got="$(pt_seed_targets "${root}")"; then
            bad "${label}: pt_seed_targets could not read the synthetic seed"; return
        fi
        for t in ${required}; do
            case " ${got} " in
                *" ${t} "*) ;;
                *) bad "${label}: derived '${got}' is NOT a superset of the seed's ${t}"; return ;;
            esac
        done
        ok "${label}: derived '${got}' is a superset of the seed set {${required}}"

        # shellcheck disable=SC2086
        single="$(pt_seed_single_target ${got})"
        if [ "$(printf '%s\n' "${single}" | wc -w)" -ne 1 ]; then
            bad "${label}: PYTHON_SINGLE_TARGET '${single}' is not exactly one value (^^ REQUIRED_USE)"
        else
            case " ${got} " in
                *" ${single} "*) ok "${label}: PYTHON_SINGLE_TARGET=${single} is exactly one member of PYTHON_TARGETS" ;;
                *) bad "${label}: PYTHON_SINGLE_TARGET '${single}' is not a member of '${got}'" ;;
            esac
        fi

        if pt_apply_seed_targets "${root}" "guard" >/dev/null 2>&1; then
            if grep -qF "PYTHON_TARGETS=\"${got}\"" "${root}/etc/portage/make.conf" \
               && grep -qF "PYTHON_SINGLE_TARGET=\"${single}\"" "${root}/etc/portage/make.conf"; then
                ok "${label}: make.conf written with the derived values"
            else
                bad "${label}: make.conf does not carry the derived PYTHON_TARGETS/PYTHON_SINGLE_TARGET"
            fi
            if grep -qE '^\*/\* PYTHON_TARGETS: ' "${root}/etc/portage/package.use/python-targets" \
               && ! grep -qE 'PYTHON_TARGETS:.*-\*' "${root}/etc/portage/package.use/python-targets"; then
                ok "${label}: package.use twin written as an additive delta"
            else
                bad "${label}: package.use twin missing or not additive"
            fi
        else
            bad "${label}: pt_apply_seed_targets failed on a readable synthetic seed"
        fi
    }

    # 2026-07-16 shape: seed built for 3.12 (+3.14), tree default has moved on.
    check_fixture "seed{3_12,3_14} (2026-07-16 jetson shape)" \
        "$(make_seed jetson "python3_12 python3_14" "3.12 3.14")" "python3_12 python3_14"
    # 2026-07-29 shape: seed built for 3.13+3.14, NO 3.12.
    check_fixture "seed{3_13,3_14} (2026-07-29 amd64 shape)" \
        "$(make_seed amd64 "python3_13 python3_14" "3.13 3.14")" "python3_13 python3_14"
    # single-interpreter arm64 seed.
    check_fixture "seed{3_14} (arm64 shape)" \
        "$(make_seed arm64 "python3_14" "3.14")" "python3_14"

    # A ghost target with no interpreter in the seed must be pruned, or it would
    # drag in an interpreter the tree may have removed.
    ghost="$(make_seed ghost "python3_11 python3_14" "3.14")"
    if got="$(pt_seed_targets "${ghost}")" && [ "${got}" = "python3_14" ]; then
        ok "ghost target with no interpreter is pruned (derived '${got}')"
    else
        bad "ghost target NOT pruned: derived '${got:-<none>}'"
    fi

    # An unreadable seed must FAIL CLOSED, never silently guess.
    mkdir -p "${TMP}/empty/etc/portage"; printf 'CHOST="x"\n' > "${TMP}/empty/etc/portage/make.conf"
    if pt_apply_seed_targets "${TMP}/empty" "guard" >/dev/null 2>&1; then
        bad "an unreadable seed did NOT fail closed — pt_apply_seed_targets guessed"
    else
        ok "unreadable seed fails closed (no guessing)"
    fi
else
    bad "behavioural checks skipped — scripts/_python-targets-lib.sh missing"
fi

# ── 5. STRUCTURE THAT IS STILL LOAD-BEARING (version-free) ───────────────────
# Every ARM builder must copy the spec's package.use/* into the sysroot with no
# filtering; the seed's package.use twin rides that copy.
for s in "${ARM_BUILDERS[@]}"; do
    f="${GEN}/${s}"
    if [ ! -f "${f}" ]; then bad "${s}: script missing"; continue; fi
    if grep -qE 'cp "\$\{SPECS_DIR\}/portage/package\.use/"\*' "${f}"; then
        ok "${s}: copies package.use/* into the sysroot unconditionally"
    else
        bad "${s}: unconditional package.use/* sysroot copy not found"
    fi
done

# build-x86 filters some package.use files by role (gpu/desktop/…). The python
# targets file is role-independent and must fall through the case (no filter).
if grep -qE '^\s*python-targets\)' "${GEN}/build-x86-host-stage4.sh"; then
    bad "build-x86: python-targets must NOT be role-filtered in the package.use copy loop"
else
    ok "build-x86: python-targets copied for every role (no case filter)"
fi

# build-x86 excludes sys-apps/portage from both long passes (#479, correct — it
# stops the mid-run self-replace). The standalone portage emerge that compensates
# MUST carry --newuse, or the package manager keeps the SEED's PYTHON_TARGETS
# forever and its gemato collides with the payload's dev-python slots.
if grep -qE '^emerge --oneshot --update --newuse sys-apps/portage' "${GEN}/build-x86-host-stage4.sh"; then
    ok "build-x86: standalone sys-apps/portage emerge carries --newuse"
elif grep -qE '^emerge --oneshot --update sys-apps/portage' "${GEN}/build-x86-host-stage4.sh"; then
    bad "build-x86: standalone sys-apps/portage emerge lacks --newuse — with --exclude sys-apps/portage on the long passes, portage never leaves the seed's PYTHON_TARGETS"
else
    ok "build-x86: no standalone portage --update emerge to check"
fi

# ── 6. HOST/CONTAINER HALF (a DIFFERENT root — shape only, never a version) ──
# The cross-emerge resolves BDEPEND against the BUILD CONTAINER's own
# /etc/portage, which the sysroot seed cannot reach. Each ARM builder writes that
# host-side twin at run time and Dockerfile.build bakes it. That root legitimately
# has its own python, so assert only that the line exists and stays ADDITIVE.
for s in "${ARM_BUILDERS[@]}"; do
    f="${GEN}/${s}"
    [ -f "${f}" ] || continue
    if grep -q 'package.use/hugmesh-host-build-backends' "${f}" \
       && grep -qE '^\*/\* PYTHON_TARGETS: ' "${f}" \
       && ! grep -qE '^\*/\* PYTHON_TARGETS:.*-\*' "${f}"; then
        ok "${s}: writes an additive HOST-side python-targets seed"
    else
        bad "${s}: missing or non-additive HOST-side package.use python-targets pre-seed"
    fi
done
if grep -q 'package.use/hugmesh-host-build-backends' "${GEN}/Dockerfile.build" \
   && grep -qE "'\*/\* PYTHON_TARGETS: " "${GEN}/Dockerfile.build" \
   && ! grep -qE "'\*/\* PYTHON_TARGETS:.*-\*" "${GEN}/Dockerfile.build"; then
    ok "Dockerfile.build: bakes an additive HOST-side python-targets seed"
else
    bad "Dockerfile.build: missing or non-additive baked HOST-side python-targets seed"
fi

# ── 7. pam[audit]: the drift item queued directly behind the python wall ─────
# sys-auth/passwdqc-2.1.0-r1 requires pam[audit]; the resolution only goes fully
# clean (emerge -p rc=0, zero USE-change blocks) with BOTH roots seeded.
for d in "${SPEC_DIRS[@]}"; do
    f="${GEN}/${d}/portage/package.use/pam-audit"
    if [ -f "${f}" ] && grep -qE '^\s*sys-libs/pam\s+audit' "${f}"; then
        ok "${d}: pam-audit seed present"
    else
        bad "${d}: pam-audit seed missing"
    fi
done
for s in "${ARM_BUILDERS[@]}"; do
    if grep -qE '^\s*sys-libs/pam\s+audit' "${GEN}/${s}"; then
        ok "${s}: HOST-side pam[audit] seed present"
    else
        bad "${s}: HOST-side pam[audit] seed missing"
    fi
done
if grep -qF "'sys-libs/pam audit'" "${GEN}/Dockerfile.build"; then
    ok "Dockerfile.build: bakes the HOST-side pam[audit] seed"
else
    bad "Dockerfile.build: missing the baked HOST-side pam[audit] seed"
fi

echo "== python-targets-seed: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
