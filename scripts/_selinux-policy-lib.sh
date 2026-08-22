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
# Most of the first-boot half has existed the whole time — provision_selinux()
# (specs/etc/keys-provision/provision.sh) runs as the LAST provisioning step,
# builds/loads the policy store and then relabels.
#
# BUT ITS EXISTING LOAD DOES NOT COVER US, AND THIS LIB DOES NOT PRETEND IT DOES.
# The pre-existing block is guarded by `if ! ls /etc/selinux/<type>/policy/policy.*`
# and, inside it, tries `semodule -B` FIRST with `semodule -i .../*.pp` only as a
# fallback. `-B` rebuilds the policy from the module STORE; the .pp this lib
# installs into /usr/share/selinux/<type>/ are PACKAGE files that are not in the
# store until `semodule -i` runs. So on any image whose policy store is already
# built (a native x86 merge, or a cross merge whose sec-policy postinst ran the
# host semodule with `-p ${SYSROOT} -n`), or on any image where `-B` simply
# succeeds, the hugmesh modules would never be loaded. provision_selinux()
# therefore carries a small explicit block — delimited by
# `BEGIN/END hugmesh node-policy load` — that installs exactly the modules THIS
# build recorded in /usr/share/hugmesh/selinux-modules.list, before the relabel.
# Search for that sentinel; the two halves are a matched pair.
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
# BUILD host" — that is wrong twice over. (1) sec-policy/* appears NOWHERE in
# Dockerfile.build (which emerges only checkpolicy, semodule-utils, m4,
# libselinux, policycoreutils), so no refpolicy headers exist on the build host
# at all. (2) `/usr/share/selinux/devel` is the FEDORA layout; Gentoo's
# selinux-base installs the module-build headers per POLICY_TYPE under
# /usr/share/selinux/<type>/include and puts NOTHING but doc/policy.xml in
# devel/ — see the block above slx_header_dir() for the ebuild/refpolicy cites.
# The headers ARE merged into the target sysroot, and they are pure
# arch-independent m4/make text. So: SYSROOT headers + HOST binaries. Using the
# sysroot's headers is also strictly more correct — the modules are then compiled
# against the refpolicy version the image will actually load them into.
#
# MANDATORY vs CONDITIONAL MODULES (the honest split).
# The 7 hugmesh_* modules call only BASE refpolicy interfaces (auth_/corecmd_/
# corenet_/dev_/files_/fs_/init_/kernel_/logging_/modutils_/storage_/sysnet_ plus
# the *_pattern macros), all shipped by sec-policy/selinux-base — so wherever the
# header tree exists they MUST compile, and a failure is a real defect: hard fail.
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

# ── WHERE THE REFPOLICY MODULE-BUILD HEADERS REALLY ARE ──────────────────────
# refpolicy's `make install-headers` — which sec-policy/selinux-base runs
# verbatim (`emake DESTDIR="${D}" install-headers`,
# /var/db/repos/gentoo/sec-policy/selinux-base/selinux-base-2.20260616_p1.ebuild:134)
# — installs the module-build headers to
#     $(prefix)/share/selinux/$(NAME)/include        [refpolicy Makefile:191-193]
# and drops support/Makefile.devel in AS the module Makefile:
#     $(INSTALL) -m 644 $(support)/Makefile.devel $(headerdir)/Makefile   [:615]
# next to build.conf (:601-614), support/*.spt (:592-596) and the per-layer .if
# trees (:597-600). So on a POLICY_TYPES="mcs" image — and every one of the ten
# specs-*/portage/make.conf.tmpl sets exactly POLICY_TYPES="mcs" — the tree is
#     <sysroot>/usr/share/selinux/mcs/include/{Makefile,build.conf,support/…}
#
# IT IS **NOT** <sysroot>/usr/share/selinux/devel. That is the FEDORA
# selinux-policy-devel convention. The only thing Gentoo ever puts there is
# doc/policy.xml (same ebuild, :147-148 `insinto /usr/share/selinux/devel;` /
# `doins doc/policy.xml;`) — corroborated by
# `grep -rn 'share/selinux/devel' /var/db/repos/gentoo --include=*.ebuild
#  --include=*.eclass`, which returns that insinto and an app-crypt/adcli comment
# noting the Fedora path does not exist on Gentoo, and nothing else. An earlier
# revision of this lib probed only devel/{Makefile,include}; on a real Gentoo
# sysroot that can never match, so every builder's `|| exit 1` fired at the very
# end of the build. That is the bug this block exists to prevent recurring.
#
# The Fedora layout (devel/Makefile + devel/include/) is still accepted, second,
# so a Fedora-ish build host keeps working.

# ── slx_devel_makefile <headerdir> → the refpolicy module Makefile to use ────
# refpolicy install-headers puts it INSIDE the header dir; Fedora's
# selinux-policy-devel puts it one level up, next to include/. Both, in order.
slx_devel_makefile() {
    local h="${1:?slx_devel_makefile: headerdir required}"
    [ -f "${h}/Makefile" ] && { printf '%s' "${h}/Makefile"; return 0; }
    if [ "${h%/include}" != "${h}" ] && [ -f "${h%/include}/Makefile" ]; then
        printf '%s' "${h%/include}/Makefile"; return 0
    fi
    return 1
}

# A candidate is usable only if it can actually drive support/Makefile.devel:
# that Makefile does `include $(HEADERDIR)/build.conf` (unconditional — a missing
# build.conf is a hard make error) and `m4support = $(wildcard
# $(HEADERDIR)/support/*.spt)`, and we need a Makefile to point `make -f` at.
_slx_headerdir_ok() {
    local h="${1:?}"
    [ -f "${h}/build.conf" ] || return 1
    [ -d "${h}/support" ]    || return 1
    slx_devel_makefile "${h}" >/dev/null || return 1
    return 0
}

# ── slx_header_dir <sysroot> [<type>] → HEADERDIR to compile against ─────────
# SYSROOT first (right refpolicy version, and the headers are arch-independent
# m4/make text), host second. Prints the HEADERDIR; prints nothing and returns 1
# when no usable tree exists — the caller decides. Every path tried is left in
# _SLX_HEADER_CANDIDATES so the failure message can be specific.
_SLX_HEADER_CANDIDATES=()
slx_header_dir() {
    local sysroot="${1:?slx_header_dir: sysroot required}" type="${2:-}" root h
    _SLX_HEADER_CANDIDATES=()
    for root in "${sysroot}" ""; do
        [ -n "${type}" ] && _SLX_HEADER_CANDIDATES+=("${root}/usr/share/selinux/${type}/include")
        for h in "${root}"/usr/share/selinux/*/include; do _SLX_HEADER_CANDIDATES+=("${h}"); done
        _SLX_HEADER_CANDIDATES+=("${root}/usr/share/selinux/devel/include" "${root}/usr/share/selinux/devel")
    done
    for h in "${_SLX_HEADER_CANDIDATES[@]}"; do
        _slx_headerdir_ok "${h}" && { printf '%s' "${h}"; return 0; }
    done
    return 1
}

# ── slx_name_of / slx_sharedir_of <headerdir> ────────────────────────────────
# support/Makefile.devel computes HEADERDIR ?= $(SHAREDIR)/$(NAME)/include, so
# NAME/SHAREDIR are the inverse of the header path. They matter because that
# Makefile's default for NAME is
#     NAME ?= $(strip $(shell $(AWK) -F= '/^SELINUXTYPE/{ print $$2 }' /etc/selinux/config))
# i.e. it reads the BUILD HOST's /etc/selinux/config — a file the builder
# container does not have. Passing NAME (and SHAREDIR, and HEADERDIR) explicitly
# is exactly what Gentoo's own module recipe does:
#     emake NAME=$1 SHAREDIR="${ESYSROOT}"/usr/share/selinux
#     (/var/db/repos/gentoo/eclass/selinux-policy-2.eclass:282)
slx_name_of()     { local h="${1:?}"; h="${h%/include}"; printf '%s' "${h##*/}"; }
slx_sharedir_of() { local h="${1:?}"; h="${h%/include}"; printf '%s' "${h%/*}"; }

# ── slx_have_interface <headerdir> <name> → 0 iff the tree defines it ────────
# refpolicy declares interfaces/templates as `interface(`name',...)` /
# `template(`name',...)` inside the .if files, which install-headers copies to
# $(headerdir)/<layer>/*.if. Used to decide whether a CONDITIONAL module's
# prerequisites are present in THIS sysroot.
slx_have_interface() {
    local hdr="${1:?}" name="${2:?}"
    grep -rqE "^[[:space:]]*(interface|template)\(\`${name}'" "${hdr}" 2>/dev/null
}

# ── slx_module_deps <name> → the upstream policy MODULES it needs loaded ─────
#
# WHY THIS IS A STORE CHECK AND NOT A HEADER CHECK.
# This used to gate on an INTERFACE being present in the refpolicy headers
# (`container_domain_template`). That test is close to vacuous:
# sec-policy/selinux-base installs the WHOLE refpolicy include tree, so every
# services/*.if is on disk no matter which .pp modules the image actually
# merged. A module therefore COMPILED happily and then could not LOAD, because
# the types its interfaces expand to live in a .pp that was never installed.
#
# Measured on hugmesh-x86-amd64-pki-test-20260814T112817Z, booted:
#   FAIL hugmesh_tor            :: Failed to resolve typeattributeset ... cil:11
#   FAIL localpath_provisioner  :: Failed to resolve typeattributeset ... cil:20
#   FAIL otel_collector         :: Failed to resolve typeattributeset ... cil:20
# The image had services/kubernetes.if (from selinux-base) but no kubernetes.pp,
# so `kubernetes_container()` expanded to the attribute kubernetes_container_domain
# that nothing defines. hugmesh_tor requires tor_t and no tor.pp was merged.
#
# That is not a cosmetic failure. specs/etc/init.d/selinux-enforce-gate's
# check_modules() requires EVERY module named in the on-image manifest to be
# loaded, so three unloadable modules meant the gate could never flip — setting
# HUGMESH_SELINUX_ENFORCE_GATE=1 would have shipped an image that refuses to go
# enforcing on every boot, silently. See issue #45.
#
# Gating on the STORE fixes both halves: a module whose dependency is absent is
# SKIPPED (so the manifest never names it, so check_modules() never demands it),
# and a module that IS installed is one whose dependencies are provably present.
#
# The map is explicit rather than derived from the .te: a reviewer can see the
# whole conditional surface at once, and a wrong entry fails loudly at build
# time instead of at first boot.
_SLX_MODULE_DEPS=(
    "localpath_provisioner:container kubernetes"   # container_domain_template + kubernetes_container
    "otel_collector:container kubernetes"          # ditto, plus container_log_t
    "hugmesh_tor:tor"                              # require { type tor_t; tor_var_lib_t; tor_etc_t; }
)

# slx_module_deps <name> -> space-separated upstream module names ("" if none)
slx_module_deps() {
    local n="${1:?}" e
    for e in "${_SLX_MODULE_DEPS[@]}"; do
        [ "${e%%:*}" = "${n}" ] && { printf '%s' "${e#*:}"; return 0; }
    done
    printf ''
}

# slx_missing_deps <name> <store> -> space-separated deps whose .pp is NOT in the store
slx_missing_deps() {
    local n="${1:?}" store="${2:?}" d missing=""
    for d in $(slx_module_deps "${n}"); do
        [ -f "${store}/${d}.pp" ] || missing="${missing}${missing:+ }${d}"
    done
    printf '%s' "${missing}"
}

# Retained: a module with ANY declared dependency is conditional by definition.
slx_module_is_conditional() {
    local n="${1:?}"
    [ -n "$(slx_module_deps "${n}")" ]
}

# ── slx_compile_module <work> <name> <headerdir> ─────────────────────────────
# One refpolicy module -> <name>.pp, in <work>, using the HOST toolchain.
# Every variable support/Makefile.devel would otherwise resolve against the BUILD
# HOST is pinned here:
#   NAME      — else `awk … /etc/selinux/config` on the build host (absent).
#   SHAREDIR  — else /usr/share/selinux, i.e. the host's store.
#   HEADERDIR — the sysroot header tree we located; also what `include
#               $(HEADERDIR)/build.conf` and $(wildcard $(HEADERDIR)/support/*.spt)
#               resolve against.
#   PREFIX/BINDIR/SBINDIR — pinned to the host /usr so $(BINDIR)/checkmodule and
#               $(BINDIR)/semodule_package can only ever resolve to the x86
#               build-host binaries, never an aarch64 target binary, even though
#               HEADERDIR points into the sysroot.
slx_compile_module() {
    local work="${1:?}" name="${2:?}" hdr="${3:?}" mk
    mk="$(slx_devel_makefile "${hdr}")" || {
        _slx_fail "no refpolicy module Makefile for header tree ${hdr}"; return 1; }
    make -C "${work}" -f "${mk}" \
        NAME="$(slx_name_of "${hdr}")" \
        SHAREDIR="$(slx_sharedir_of "${hdr}")" \
        HEADERDIR="${hdr}" \
        PREFIX=/usr BINDIR=/usr/bin SBINDIR=/usr/sbin \
        "${name}.pp"
}

# ── slx_mark_selinux_built <sysroot> [<detail>] ──────────────────────────────
# BUILD-TIME MARKER: /usr/share/hugmesh/selinux-built states "this image was
# built with selinux-aware userland — first boot MUST end with a loaded
# policy". provision_selinux() keys its hard postcondition off this file (with
# base.pp presence as the fallback for images that predate it): on a marked
# image the old fail-open seams ('[ -d /etc/selinux ] || return 0',
# '2>/dev/null || warn') no longer let a broken SELinux userland provision
# "normally" — they record /var/lib/keys-provision/selinux-load-failed, which
# /etc/init.d/selinux-enforce-gate refuses on. Written ONLY when the sysroot
# really carries a base policy to load (base.pp), so a deliberately
# non-SELinux image is never held to a postcondition it cannot meet.
# Content is DETERMINISTIC (no timestamps): re-runs must be byte-identical.
slx_mark_selinux_built() {
    local sysroot="${1:?slx_mark_selinux_built: sysroot required}" detail="${2:-}" type
    type="$(slx_policy_type "${sysroot}")"
    if [ ! -f "${sysroot}/usr/share/selinux/${type}/base.pp" ]; then
        _slx_say "NOT marking selinux-built: no ${type}/base.pp in the sysroot — not a selinux-aware image, first boot stays fail-open"
        return 0
    fi
    install -d -m 0755 "${sysroot}/usr/share/hugmesh" || { _slx_fail "cannot create ${sysroot}/usr/share/hugmesh"; return 1; }
    {
        echo "# This image was built with selinux-aware userland (base.pp present at build time)."
        echo "# Written by scripts/_selinux-policy-lib.sh. provision_selinux() (keys-provision)"
        echo "# treats a first boot that ends WITHOUT a loaded policy as a FAILURE on this image:"
        echo "# it records /var/lib/keys-provision/selinux-load-failed, and"
        echo "# /etc/init.d/selinux-enforce-gate refuses to flip to enforcing while that exists."
        echo "type=${type}"
        [ -n "${detail}" ] && echo "${detail}"
    } > "${sysroot}/usr/share/hugmesh/selinux-built"
    chmod 0644 "${sysroot}/usr/share/hugmesh/selinux-built"
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
        # Still selinux-aware when base.pp exists: the DISTRO policy must load
        # at first boot even with the hugmesh modules deliberately omitted.
        slx_mark_selinux_built "${sysroot}" "node_modules=0 (HUGMESH_SELINUX_MODULES=0)"
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

    local hdr type store work c
    type="$(slx_policy_type "${sysroot}")"
    store="${sysroot}/usr/share/selinux/${type}"
    if ! hdr="$(slx_header_dir "${sysroot}" "${type}")"; then
        _slx_fail "no refpolicy module-build header tree found."
        echo "  Wanted a directory holding build.conf + support/ + the refpolicy module" >&2
        echo "  Makefile (support/Makefile.devel). sec-policy/selinux-base's" >&2
        echo "  \`emake install-headers\` puts it at" >&2
        echo "      ${sysroot}/usr/share/selinux/<POLICY_TYPES>/include" >&2
        echo "  and POLICY_TYPES is \"mcs\" in every specs-*/portage/make.conf.tmpl." >&2
        echo "  NOTE: /usr/share/selinux/devel is the FEDORA layout — on Gentoo that dir" >&2
        echo "  holds only doc/policy.xml, so its presence or absence proves nothing." >&2
        echo "  Looked in:" >&2
        for c in "${_SLX_HEADER_CANDIDATES[@]}"; do echo "    ${c}" >&2; done
        if [ -f "${store}/base.pp" ]; then
            echo "  ${store}/base.pp EXISTS, so selinux-base IS merged — its headers were" >&2
            echo "  stripped after the merge. Check the sysroot clean." >&2
        else
            echo "  ${store}/base.pp is absent too, so the payload emerge did not merge" >&2
            echo "  sec-policy/selinux-base at all — this image would have no policy to load." >&2
        fi
        echo "  Set HUGMESH_SELINUX_MODULES=0 to build deliberately without node policy." >&2
        return 1
    fi

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

    _slx_say "refpolicy headers: ${hdr}   policy store: ${store}"

    local te built=() skipped=() rc=0 log="${work}/compile.log"
    for te in "${work}"/*.te; do
        name="$(basename "${te}" .te)"
        local miss; miss="$(slx_missing_deps "${name}" "${store}")"
        if [ -n "${miss}" ]; then
            skipped+=("${name}")
            local pkgs="" d
            for d in ${miss}; do pkgs="${pkgs}${pkgs:+ }sec-policy/selinux-${d}"; done
            _slx_say "SKIP ${name}: upstream policy module(s) not in ${store}: ${miss// /.pp }.pp"
            _slx_say "     merge ${pkgs} into this image to install it. Skipping is CORRECT here:"
            _slx_say "     the module would compile and then fail to load, and the enforce-gate"
            _slx_say "     requires every manifest module to load before it will flip."
            continue
        fi
        if slx_compile_module "${work}" "${name}" "${hdr}" >"${log}" 2>&1; then
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

    # PRUNE WITHDRAWN MODULES. On a --resume / --skip-clean sysroot the store may
    # still hold a .pp from a previous run whose .te has since been deleted from
    # specs/selinux. provision_selinux() and `semodule -B` both work off what is
    # in the store, so a withdrawn policy module would keep being loaded while the
    # manifest (the enforce-gate's contract) no longer lists it. Prune strictly by
    # the PREVIOUS manifest, never by a glob: the distro's own base.pp and any
    # sec-policy/* module must not be touched.
    local prev="${sysroot}/usr/share/hugmesh/selinux-modules.list" stale=() pm keep
    if [ -r "${prev}" ]; then
        while read -r pm; do
            case "${pm}" in ''|'#'*) continue ;; esac
            keep=0
            for name in "${built[@]}"; do [ "${name}" = "${pm}" ] && { keep=1; break; }; done
            [ "${keep}" = 0 ] && [ -e "${store}/${pm}.pp" ] && stale+=("${pm}")
        done < "${prev}"
    fi
    if [ "${#stale[@]}" -ne 0 ]; then
        for pm in "${stale[@]}"; do rm -f "${store}/${pm}.pp"; done
        _slx_say "pruned ${#stale[@]} withdrawn module(s) from ${store}: ${stale[*]}"
    fi

    install -m 0644 "${work}"/*.pp "${store}/" || { rm -rf "${work}"; _slx_fail "installing .pp into ${store} failed"; return 1; }

    # On-image manifest — the single source of truth the enforce-gate reads.
    install -d -m 0755 "${sysroot}/usr/share/hugmesh"
    {
        echo "# hugmesh SELinux node-policy modules installed into /usr/share/selinux/${type}/"
        echo "# Written at build time by scripts/_selinux-policy-lib.sh."
        echo "# Read at first boot by provision_selinux()'s hugmesh node-policy load block,"
        echo "# and at runtime by /etc/init.d/selinux-enforce-gate. One module name per line."
        printf '%s\n' "${built[@]}"
        for name in ${skipped[*]-}; do
            echo "# skipped: ${name} (container policy headers absent — not a k8s node image)"
        done
    } > "${sysroot}/usr/share/hugmesh/selinux-modules.list"
    chmod 0644 "${sysroot}/usr/share/hugmesh/selinux-modules.list"

    _slx_say "installed ${#built[@]} module(s) into ${store}: ${built[*]}"
    [ "${#skipped[@]}" -eq 0 ] || _slx_say "not applicable to this image: ${skipped[*]-}"
    _slx_say "first boot loads them via provision_selinux()'s 'hugmesh node-policy load' block -> semodule -s ${type} -i <each module from the manifest> (PERMISSIVE)"

    rm -rf "${work}"
    slx_mark_selinux_built "${sysroot}" "node_modules=${#built[@]}" || return 1
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
