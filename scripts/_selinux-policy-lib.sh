#!/usr/bin/env bash
# _selinux-policy-lib.sh — SOURCED helper: compile the editable node-policy
# modules in specs/selinux/ into .pp ON THE X86 BUILD HOST and install them into
# the TARGET sysroot's policy store, then ship the (DEFAULT-OFF) enforce-gate
# service. Sourced by all ten stage4 builders; one call site each.
#
# WHY THIS EXISTS — THE MODULES WERE BAKED IN SOURCE AND LOADED BY NOBODY.
# specs/selinux/ carries 9 refpolicy modules (7 hugmesh host domains + the 2 k8s
# exemplars) and, before this lib, NOTHING compiled or installed them:
#   git grep 'specs/selinux' -- 'build-*.sh'   =>   no hits.
# The first-boot half of the loader has existed the whole time —
# provision_selinux() (specs/etc/keys-provision/provision.sh:2544) runs, as the
# LAST provisioning step (:2791):
#     semodule -s "${type}" -B
#  || semodule -s "${type}" -i /usr/share/selinux/"${type}"/*.pp     (:2563)
# then setfiles/restorecon (:2568) and `touch /.autorelabel` (:2573).
# So a .pp that lands in ${SYSROOT}/usr/share/selinux/<type>/ at BUILD time is
# loaded automatically at first boot with NO change to provision.sh. This lib is
# the missing build-time half, and only that half.
#
# WHY NEVER ON THE TARGET. checkmodule/semodule_package/m4 are x86 BUILD-host
# binaries; an aarch64 image cannot run them, and the cross sysroot carries no
# guarantee of the refpolicy devel tree being usable in place. This is the SAME
# reason sec-policy/selinux-base builds base.pp on the build host and defers only
# the LOAD to first boot (see the comment at build-rpi5-stage4.sh:2976-2985).
# Every compile below runs with PREFIX/BINDIR pinned to the HOST /usr, so the
# refpolicy Makefile can never reach for a target binary.
#
# WHY THE HEADER TREE COMES FROM THE SYSROOT, NOT THE HOST.
# docs/selinux-module-loading.md's step (b) says to use the build host's
# /usr/share/selinux/devel/Makefile "installed by sec-policy/selinux-base on the
# BUILD host" — but sec-policy/* appears NOWHERE in Dockerfile.build (which
# emerges only checkpolicy, semodule-utils, m4, libselinux, policycoreutils), so
# the refpolicy DEVEL HEADERS are not on the build host at all. They ARE merged
# into the target sysroot by sec-policy/selinux-base, and they are pure
# arch-independent m4/make text. So: SYSROOT headers + HOST binaries. Using the
# sysroot's headers is also strictly more correct — the modules are then compiled
# against the refpolicy version the image will actually load them into.
#
# MANDATORY vs CONDITIONAL MODULES (the honest split).
# The 7 hugmesh_* modules call only BASE refpolicy interfaces (auth_/corecmd_/
# corenet_/dev_/files_/fs_/init_/kernel_/logging_/modutils_/storage_/sysnet_ plus
# the *_pattern macros), all shipped by sec-policy/selinux-base — so wherever the
# devel tree exists they MUST compile, and a failure is a real defect: hard fail.
# localpath_provisioner and otel_collector call container_domain_template /
# kubernetes_container / container_list_log_dirs / container_search_logs, which
# come from the CONTAINER policy headers (sec-policy/selinux-container) that only
# cluster-node images pull in. On a desktop/client image those headers are
# absent, so those two are CONDITIONAL: compiled when the headers are there,
# recorded as skipped-WITH-REASON when they are not. They are never silently
# dropped — the reason lands in the on-image manifest and in the build log.
#
# THE MANIFEST IS THE CONTRACT. Everything installed is listed in
# /usr/share/hugmesh/selinux-modules.list inside the image, and
# specs/etc/init.d/selinux-enforce-gate's check_modules() reads exactly that
# file. The gate can therefore never demand a module this image never built, and
# can never pass while one it did build failed to load.
#
# PERMISSIVE IS AND STAYS THE DEFAULT. This lib installs policy and ships the
# enforce-gate service FILE, but does NOT link it into any runlevel and writes
# /etc/conf.d/selinux-enforce-gate with SELINUX_ENFORCE_GATE="no". The .te files
# still carry rules marked '# INFERRED-WIDE: narrow after QEMU enforcing AVC
# pass'; flipping enforcing on unnarrowed rules risks images that boot into a
# broken state. Permissive + loaded modules + logged AVCs is the safe increment.
# Opt in explicitly with HUGMESH_SELINUX_ENFORCE_GATE=1 at build time.
#
# Pure host-side shell. No emerge, no chroot, no network, no root required beyond
# whatever the caller already has for writing into ${SYSROOT}.

# ── knobs (env only — deliberately NOT builder CLI flags) ────────────────────
# HUGMESH_SELINUX_MODULES=0        skip the whole step (deliberate operator
#                                  choice, loudly logged; mirrors --skip-kernel's
#                                  "kernel-less output is a choice" posture).
# HUGMESH_SELINUX_ENFORCE_GATE=1   ALSO enable the enforce-gate (runlevel link +
#                                  conf.d yes). Default 0 = shipped but inert.
# HUGMESH_SELINUX_TYPE=<name>      override the policy-store type dir
#                                  (default: autodetected, else mcs).

_slx_say()  { echo "[selinux-policy] $*"; }
_slx_fail() { echo "[selinux-policy] FATAL: $*" >&2; }

# ── slx_policy_type <sysroot> → the policy-store type dir name ───────────────
# provision_selinux() defaults type=mcs (provision.sh:2548) and the enforce-gate
# hardcodes TYPE=mcs, so mcs is the fallback. But sec-policy/selinux-base installs
# base.pp under whatever POLICY_TYPES the profile picked, so prefer the type dir
# the sysroot ACTUALLY has — installing next to base.pp is what makes
# `semodule -i /usr/share/selinux/${type}/*.pp` pick our modules up.
slx_policy_type() {
    local sysroot="${1:?slx_policy_type: sysroot required}" d
    if [ -n "${HUGMESH_SELINUX_TYPE:-}" ]; then printf '%s' "${HUGMESH_SELINUX_TYPE}"; return 0; fi
    for d in "${sysroot}"/usr/share/selinux/*/; do
        [ -f "${d}base.pp" ] || continue
        d="${d%/}"; printf '%s' "${d##*/}"; return 0
    done
    printf 'mcs'
}

# ── slx_devel_dir <sysroot> → the refpolicy devel tree to compile against ────
# SYSROOT first (right refpolicy version, arch-independent text), host second.
# Prints nothing and returns 1 when neither exists — the caller decides.
slx_devel_dir() {
    local sysroot="${1:?slx_devel_dir: sysroot required}" d
    for d in "${sysroot}/usr/share/selinux/devel" /usr/share/selinux/devel; do
        [ -f "${d}/Makefile" ] && [ -d "${d}/include" ] && { printf '%s' "${d}"; return 0; }
    done
    return 1
}

# ── slx_have_interface <devel> <name> → 0 iff the header tree defines it ─────
# refpolicy declares interfaces/templates as `interface(`name',...)` /
# `template(`name',...)` inside the .if files. Used to decide whether a
# CONDITIONAL module's prerequisites are present in THIS sysroot.
slx_have_interface() {
    local devel="${1:?}" name="${2:?}"
    grep -rqE "^[[:space:]]*(interface|template)\(\`${name}'" "${devel}/include" 2>/dev/null
}

# ── slx_module_is_conditional <name> → 0 iff container headers are needed ────
# Kept as an explicit two-name list rather than a guess derived from the .te:
# these are the two k8s EXEMPLARS, and the orphaned enforce-gate names them, so
# a reviewer can see the whole conditional surface on one line.
_SLX_CONDITIONAL_MODULES=(localpath_provisioner otel_collector)
_SLX_CONDITIONAL_IFACE=container_domain_template
slx_module_is_conditional() {
    local n="${1:?}" m
    for m in "${_SLX_CONDITIONAL_MODULES[@]}"; do [ "${m}" = "${n}" ] && return 0; done
    return 1
}

# ── slx_compile_module <work> <name> <devel> ─────────────────────────────────
# One refpolicy module -> <name>.pp, in <work>, using the HOST toolchain.
# PREFIX/BINDIR/SBINDIR are pinned to the host /usr so the refpolicy Makefile's
# $(BINDIR)/checkmodule and $(BINDIR)/semodule_package can only ever resolve to
# the x86 build-host binaries, even though HEADERDIR points into the sysroot.
slx_compile_module() {
    local work="${1:?}" name="${2:?}" devel="${3:?}"
    make -C "${work}" -f "${devel}/Makefile" \
        SHAREDIR="${devel%/devel}" HEADERDIR="${devel}/include" \
        PREFIX=/usr BINDIR=/usr/bin SBINDIR=/usr/sbin \
        "${name}.pp"
}

# ── slx_stage_node_policy <sysroot> <shared_specs> ───────────────────────────
# THE ONE CALL SITE. Compiles every specs/selinux module the sysroot can support,
# installs the .pp into the policy store provision_selinux() already loads,
# writes the on-image manifest, and ships the DEFAULT-OFF enforce-gate.
# Idempotent: re-running overwrites in place and rewrites the manifest.
# Returns non-zero (having said why) on any real failure; the builder wraps this
# with `|| { err ...; exit 1; }` so a half-populated store can never ship.
slx_stage_node_policy() {
    local sysroot="${1:?slx_stage_node_policy: sysroot required}"
    local shared_specs="${2:?slx_stage_node_policy: shared_specs required}"
    local src="${shared_specs}/selinux"

    if [ "${HUGMESH_SELINUX_MODULES:-1}" = "0" ]; then
        _slx_say "SKIPPED by HUGMESH_SELINUX_MODULES=0 — this image ships NO hugmesh node policy."
        _slx_say "  The node still boots permissive with only the distro base policy loaded."
        return 0
    fi

    [ -d "${src}" ] || { _slx_fail "policy source dir missing: ${src}"; return 1; }
    [ -d "${sysroot}" ] || { _slx_fail "sysroot missing: ${sysroot}"; return 1; }

    # INVARIANT: every .fc must have a sibling .te. A label-only .fc has nothing
    # for the devel Makefile to compile into a standalone .pp, so it would be
    # SILENTLY DROPPED — which is exactly how hugmesh_breakglass.fc and
    # hugmesh_oidc_token.fc were handled before this lib (they are now folded
    # into hugmesh_authkeys.fc per docs/selinux-module-loading.md option (1)).
    # Fail loudly instead of shipping a policy set that quietly lost a label.
    local fc name orphans=()
    for fc in "${src}"/*.fc; do
        [ -e "${fc}" ] || continue
        name="$(basename "${fc}" .fc)"
        [ -f "${src}/${name}.te" ] || orphans+=("${name}.fc")
    done
    if [ "${#orphans[@]}" -ne 0 ]; then
        _slx_fail "label-only .fc with no sibling .te: ${orphans[*]}"
        echo "  A .fc without a .te is never compiled into a .pp and would ship as a" >&2
        echo "  SILENTLY MISSING label. Fold its lines into a sibling module's .fc" >&2
        echo "  (docs/selinux-module-loading.md, option 1) — do not add a stub .te." >&2
        return 1
    fi

    local tes=("${src}"/*.te)
    [ -e "${tes[0]}" ] || { _slx_fail "no .te modules under ${src} — refusing to ship an empty policy set"; return 1; }

    local devel type store work
    if ! devel="$(slx_devel_dir "${sysroot}")"; then
        _slx_fail "no refpolicy devel tree (Makefile + include/) found."
        echo "  Looked in: ${sysroot}/usr/share/selinux/devel then /usr/share/selinux/devel" >&2
        echo "  It is installed into the SYSROOT by sec-policy/selinux-base, which every" >&2
        echo "  SELinux profile pulls in — its absence means the payload emerge did not" >&2
        echo "  merge selinux-base, so this image would also have no base.pp to load." >&2
        echo "  Set HUGMESH_SELINUX_MODULES=0 to build deliberately without node policy." >&2
        return 1
    fi
    type="$(slx_policy_type "${sysroot}")"
    store="${sysroot}/usr/share/selinux/${type}"

    # HOST toolchain assertion. The builders' HOST_POLICY_TOOLS gate already
    # provisions these; re-assert at the point of use so a builder that loses the
    # gate fails HERE with the exact reason instead of deep inside make.
    local t missing=()
    for t in m4 checkmodule semodule_package; do command -v "${t}" &>/dev/null || missing+=("${t}"); done
    if [ "${#missing[@]}" -ne 0 ]; then
        _slx_fail "missing HOST SELinux policy build tools: ${missing[*]}"
        echo "  Install on the BUILD host (NOT the sysroot):" >&2
        echo "    emerge sys-apps/checkpolicy sys-apps/semodule-utils sys-devel/m4" >&2
        return 1
    fi

    work="$(mktemp -d)" || { _slx_fail "mktemp -d failed"; return 1; }
    cp "${src}"/*.te "${src}"/*.fc "${work}/" || { rm -rf "${work}"; _slx_fail "staging ${src} failed"; return 1; }

    local have_container=1
    slx_have_interface "${devel}" "${_SLX_CONDITIONAL_IFACE}" || have_container=0

    _slx_say "devel headers: ${devel}   policy store: ${store}   container headers: $([ "${have_container}" = 1 ] && echo present || echo absent)"

    local te built=() skipped=() rc=0 log="${work}/compile.log"
    for te in "${work}"/*.te; do
        name="$(basename "${te}" .te)"
        if slx_module_is_conditional "${name}" && [ "${have_container}" = 0 ]; then
            skipped+=("${name}")
            _slx_say "SKIP ${name}: needs the container policy headers (${_SLX_CONDITIONAL_IFACE}); sec-policy/selinux-container is not merged into this image"
            continue
        fi
        if slx_compile_module "${work}" "${name}" "${devel}" >"${log}" 2>&1; then
            [ -f "${work}/${name}.pp" ] || { _slx_fail "${name}: make reported success but ${name}.pp does not exist"; rc=1; break; }
            built+=("${name}")
        else
            _slx_fail "${name}.pp failed to compile"
            sed 's/^/    | /' "${log}" | tail -n 30 >&2
            rc=1; break
        fi
    done
    if [ "${rc}" -ne 0 ]; then
        rm -rf "${work}"
        echo "  REFUSING to install a half-populated policy store (nothing was written to" >&2
        echo "  ${store}). Fix the module above, or set HUGMESH_SELINUX_MODULES=0 to build" >&2
        echo "  deliberately without node policy." >&2
        return 1
    fi
    [ "${#built[@]}" -gt 0 ] || { rm -rf "${work}"; _slx_fail "no module compiled — refusing to ship an empty policy set"; return 1; }

    # ALL-OR-NOTHING install: only reached once every buildable module compiled.
    install -d -m 0755 "${store}" || { rm -rf "${work}"; _slx_fail "cannot create ${store}"; return 1; }
    install -m 0644 "${work}"/*.pp "${store}/" || { rm -rf "${work}"; _slx_fail "installing .pp into ${store} failed"; return 1; }

    # On-image manifest — the single source of truth the enforce-gate reads.
    install -d -m 0755 "${sysroot}/usr/share/hugmesh"
    {
        echo "# hugmesh SELinux node-policy modules installed into /usr/share/selinux/${type}/"
        echo "# Written at build time by scripts/_selinux-policy-lib.sh."
        echo "# Loaded at first boot by provision_selinux() (semodule -i .../*.pp). One name per line."
        printf '%s\n' "${built[@]}"
        for name in ${skipped[*]-}; do
            echo "# skipped: ${name} (container policy headers absent — not a k8s node image)"
        done
    } > "${sysroot}/usr/share/hugmesh/selinux-modules.list"
    chmod 0644 "${sysroot}/usr/share/hugmesh/selinux-modules.list"

    _slx_say "installed ${#built[@]} module(s) into ${store}: ${built[*]}"
    [ "${#skipped[@]}" -eq 0 ] || _slx_say "not applicable to this image: ${skipped[*]-}"
    _slx_say "first boot loads them via provision_selinux() -> semodule -s ${type} -i /usr/share/selinux/${type}/*.pp (PERMISSIVE)"

    rm -rf "${work}"
    slx_ship_enforce_gate "${sysroot}" "${shared_specs}"
}

# ── slx_ship_enforce_gate <sysroot> <shared_specs> ───────────────────────────
# Ship specs/etc/init.d/selinux-enforce-gate the way sibling OpenRC services are
# shipped (cp + chmod +x into ${SYSROOT}/etc/init.d, mirroring the
# hugmesh-firewall-reconcile copy at build-rpi5-stage4.sh:2396-2397), plus a
# conf.d switch. DEFAULT OFF — two independent locks, both must be opened:
#   1. the service is NOT linked into ${SYSROOT}/etc/runlevels/default, so OpenRC
#      never starts it (same symlink mechanism as the DEFAULT_SVCS loop at
#      build-rpi5-stage4.sh:3701);
#   2. /etc/conf.d/selinux-enforce-gate ships SELINUX_ENFORCE_GATE="no", and the
#      service refuses to do anything until that says yes — so even an operator
#      who rc-update's it by hand does not get a surprise flip.
# HUGMESH_SELINUX_ENFORCE_GATE=1 at build time opens both.
slx_ship_enforce_gate() {
    local sysroot="${1:?}" shared_specs="${2:?}"
    local svc="${shared_specs}/etc/init.d/selinux-enforce-gate"
    [ -f "${svc}" ] || { _slx_fail "enforce-gate service missing: ${svc}"; return 1; }

    install -d -m 0755 "${sysroot}/etc/init.d" "${sysroot}/etc/conf.d" "${sysroot}/etc/runlevels/default"
    cp "${svc}" "${sysroot}/etc/init.d/selinux-enforce-gate" || { _slx_fail "cp enforce-gate failed"; return 1; }
    chmod +x "${sysroot}/etc/init.d/selinux-enforce-gate"

    local want="${HUGMESH_SELINUX_ENFORCE_GATE:-0}" enabled=no
    [ "${want}" = "1" ] && enabled=yes
    cat > "${sysroot}/etc/conf.d/selinux-enforce-gate" <<CONFD
# selinux-enforce-gate — DEFAULT OFF.
#
# "yes" lets the gate flip this node permissive -> enforcing, and ONLY after its
# own checks pass (policy modules loaded, relabel clean, no AVCs for the core or
# hugmesh domains, and never on the relabel boot). "no" makes the service a
# no-op: the node stays PERMISSIVE with the policy modules loaded and AVCs
# logged, which is the shipped posture.
#
# Do NOT set this to yes until a real protected build + boot has produced a
# permissive AVC pass and the rules tagged '# INFERRED-WIDE' in
# specs/selinux/*.te have been narrowed against it. Enforcing on unnarrowed
# rules risks a node that boots into a broken state.
SELINUX_ENFORCE_GATE="${enabled}"
CONFD
    chmod 0644 "${sysroot}/etc/conf.d/selinux-enforce-gate"

    if [ "${want}" = "1" ]; then
        ln -sf "/etc/init.d/selinux-enforce-gate" "${sysroot}/etc/runlevels/default/selinux-enforce-gate"
        _slx_say "enforce-gate ENABLED by HUGMESH_SELINUX_ENFORCE_GATE=1 (runlevel default + conf.d yes)"
        _slx_say "  the node still boots permissive; the gate flips only on a later boot once its checks pass"
    else
        rm -f "${sysroot}/etc/runlevels/default/selinux-enforce-gate"
        _slx_say "enforce-gate shipped but INERT (not in any runlevel, conf.d SELINUX_ENFORCE_GATE=no) — node stays PERMISSIVE"
    fi
    return 0
}
