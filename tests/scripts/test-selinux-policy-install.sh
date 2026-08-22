#!/usr/bin/env bash
# ── SELinux node-policy compile+install gate ─────────────────────────────────
# Guards the wiring that makes specs/selinux/*.te actually reach an image.
#
# THE FAILURE THIS EXISTS TO CATCH. For its whole life specs/selinux/ carried 9
# refpolicy modules that NOTHING compiled or installed — the source was reviewed,
# matrix-documented and completely inert, and no test noticed. The same is true of
# specs/etc/init.d/selinux-enforce-gate, which no builder shipped and whose
# check_modules() demanded two modules that were never built. A builder silently
# losing the install step again would be invisible in exactly the same way.
#
# Unlike a pure grep gate, this EXECUTES the real shared lib against a FAKE target
# sysroot and a FAKE refpolicy header tree, and EXECUTES the real enforce-gate
# service's start() against stubbed system tools (the same technique as
# tests/build-arm-payload-gates.sh), so it can prove BEHAVIOUR, not just presence:
# all-or-nothing installs, the label-only .fc trap, the conditional k8s exemplars,
# idempotence, and — the load-bearing one — that a default image ships the
# enforce-gate INERT so it still boots PERMISSIVE.
#
# ── THE FIXTURE SYSROOT IS THE SHAPE sec-policy/selinux-base REALLY PRODUCES ──
# An earlier revision of this gate built the fixture as
# <sysroot>/usr/share/selinux/devel/{Makefile,include/} — the FEDORA
# selinux-policy-devel convention, and a layout Gentoo never creates. It reported
# 80/0 while the real step returned rc=1 on every image, because the lib probed
# the same non-existent path. mk_sysroot() now reproduces what
# `emake DESTDIR=... install-headers` actually leaves behind:
#     usr/share/selinux/mcs/base.pp                       (emake install)
#     usr/share/selinux/mcs/include/Makefile              (support/Makefile.devel)
#     usr/share/selinux/mcs/include/build.conf
#     usr/share/selinux/mcs/include/support/*.spt
#     usr/share/selinux/devel/policy.xml                  (the ONLY devel/ file)
# refpolicy Makefile:191-193 + :601-615; selinux-base-2.20260616_p1.ebuild:134
# (install-headers) and :147-148 (the policy.xml insinto). C-gentoo asserts the
# fixture keeps that shape, so it cannot silently drift back.
#
# The fixture Makefile is not a bare stub: it reproduces support/Makefile.devel's
# VARIABLE CONTRACT verbatim (NAME defaulted from the build host's
# /etc/selinux/config, SHAREDIR/NAME composing HEADERDIR, `include
# $(HEADERDIR)/build.conf`) and $(error)s when the caller gets it wrong — which is
# what makes the NAME/SHAREDIR/HEADERDIR pins a real assertion rather than a
# comment.
#
# HONEST SCOPE — WHAT THIS GATE STILL DOES NOT PROVE. Section C-real runs the
# genuine m4 -> checkmodule -> semodule_package recipe with the host's own
# binaries, so a genuine .pp is produced by the genuine toolchain. It does NOT
# compile any hugmesh module against REAL refpolicy headers: that needs
# sec-policy/selinux-base merged into a real sysroot (a real protected build), and
# this repo deliberately vendors no refpolicy header tree. The real-source passes
# therefore drive the contract Makefile and prove enumeration/skip/install/
# manifest/pin logic against the REAL specs/selinux set.
#
# Pure static + fake-sysroot execution. No emerge, no chroot, no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
LIB="${GEN}/scripts/_selinux-policy-lib.sh"
SVC="${GEN}/specs/etc/init.d/selinux-enforce-gate"
SRC="${GEN}/specs/selinux"
PROV="${GEN}/specs/etc/keys-provision/provision.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

BUILDERS=(build-frite-stage4.sh build-jetson-stage4.sh
          build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh
          build-orangepi-zero3-stage4.sh build-orangepi3-lts-stage4.sh
          build-orangepi4-lts-stage4.sh build-orangepi5-stage4.sh
          build-rpi5-stage4.sh build-x86-host-stage4.sh)
# The 6 modules that install on EVERY image: they reference base-refpolicy types
# only, so nothing beyond selinux-base has to be merged for them to LOAD.
#
# hugmesh_tor USED TO BE LISTED HERE and that was wrong, proven by booting
# hugmesh-x86-amd64-pki-test-20260814T112817Z: it requires tor_t/tor_var_lib_t/
# tor_etc_t, which live in tor.pp (sec-policy/selinux-tor). With no tor.pp merged
# it compiled fine and then died on load with
#     Failed to resolve typeattributeset ... hugmesh_tor/cil:11
# It is a DEPENDENT module, not a mandatory one.
MANDATORY=(hugmesh_authkeys hugmesh_device_registry_sync hugmesh_domain_reconcile
           hugmesh_node_storage hugmesh_policy_sync hugmesh_vpn)
# Modules that need an upstream policy MODULE (a .pp in the store) — not merely
# an interface in the headers. selinux-base ships the WHOLE refpolicy include
# tree, so "the interface exists" is nearly always true and gates nothing; what
# decides loadability is whether the .pp defining those types was merged.
DEPENDENT=(hugmesh_tor localpath_provisioner otel_collector)
EXEMPLARS=(localpath_provisioner otel_collector)

echo "== SELinux node-policy compile+install gate =="

# ── A) the shared lib + its ten call sites ───────────────────────────────────
echo "-- A) shared lib and builder wiring --"
[ -f "${LIB}" ] && ok "scripts/_selinux-policy-lib.sh exists" || bad "shared lib MISSING"
bash -n "${LIB}" 2>/dev/null && ok "lib is valid bash" || bad "lib does not parse"
grep -qE '^slx_stage_node_policy\(\)' "${LIB}" \
    && ok "lib defines slx_stage_node_policy()" || bad "lib lost slx_stage_node_policy()"

for b in "${BUILDERS[@]}"; do
    f="${GEN}/${b}"
    if [ ! -f "${f}" ]; then
        bad "${b}: builder missing"; bad "${b}: (source)"; bad "${b}: (call)"; bad "${b}: (guard)"
        continue
    fi
    grep -qF 'source "${SCRIPT_DIR}/scripts/_selinux-policy-lib.sh"' "${f}" \
        && ok "${b}: sources the shared lib" \
        || bad "${b}: does NOT source scripts/_selinux-policy-lib.sh"

    n_call="$(grep -cE '^slx_stage_node_policy "' "${f}")"
    [ "${n_call}" -eq 1 ] \
        && ok "${b}: calls slx_stage_node_policy exactly once" \
        || bad "${b}: slx_stage_node_policy call sites = ${n_call} (want exactly 1)"

    # ORDER is the substance: the modules must land while the sysroot is complete
    # and BEFORE anything is packaged or imaged. `banner "Packaging stage4
    # tarball"` is the one late banner all ten share.
    call_ln="$(grep -nE '^slx_stage_node_policy "' "${f}" | head -1 | cut -d: -f1)"
    pack_ln="$(grep -nF 'banner "Packaging stage4 tarball"' "${f}" | head -1 | cut -d: -f1)"
    if [ -n "${call_ln}" ] && [ -n "${pack_ln}" ] && [ "${call_ln}" -lt "${pack_ln}" ]; then
        ok "${b}: call site (line ${call_ln}) precedes stage4 packaging (line ${pack_ln})"
    else
        bad "${b}: call site must precede 'Packaging stage4 tarball' (call=${call_ln:-none} pack=${pack_ln:-none})"
    fi

    # A bare call would let a policy-less image ship on a soft failure.
    if [ -n "${call_ln}" ] && sed -n "$((call_ln)),$((call_ln + 2))p" "${f}" | grep -q 'exit 1'; then
        ok "${b}: call site is guarded (exit 1 on failure)"
    else
        bad "${b}: call site is NOT guarded with exit 1"
    fi
done

# ── B) the policy source set ─────────────────────────────────────────────────
echo "-- B) specs/selinux source set --"
n_te="$(find "${SRC}" -maxdepth 1 -name '*.te' | wc -l)"
n_fc="$(find "${SRC}" -maxdepth 1 -name '*.fc' | wc -l)"
[ "${n_te}" -ge 9 ] && ok "specs/selinux carries ${n_te} .te modules (>=9)" \
                    || bad "specs/selinux has only ${n_te} .te modules"
orphan=""
for fc in "${SRC}"/*.fc; do
    [ -e "${fc}" ] || continue
    nm="$(basename "${fc}" .fc)"
    [ -f "${SRC}/${nm}.te" ] || orphan="${orphan} ${nm}.fc"
done
[ -z "${orphan}" ] && ok "every .fc has a sibling .te (${n_fc} pairs — no label-only module can be silently dropped)" \
                   || bad "label-only .fc with no .te:${orphan}"
# NON-VACUITY: the two that WERE label-only must be gone, and their context lines
# must be present in the sibling they were folded into.
for gone in hugmesh_breakglass hugmesh_oidc_token; do
    [ -e "${SRC}/${gone}.fc" ] && bad "${gone}.fc still exists as a label-only file" \
                               || ok "${gone}.fc folded away (no standalone label-only file)"
done
# Both folded-in labels are asserted on the CONTEXT LINE, never on prose. The
# earlier oidc assertion was `grep -qF '/run/user/%{uid}/hugmesh'`, and that exact
# literal also appears in the explanatory comment above the rule — so deleting the
# real context line left the suite green. Both patterns below now require the
# line-leading path AND the gen_context() that makes it a label.
grep -qE '^/etc/ssh/break-glass\\\.keys[[:space:]].*gen_context\(' "${SRC}/hugmesh_authkeys.fc" \
    && ok "break-glass CONTEXT LINE survives the fold into hugmesh_authkeys.fc" \
    || bad "break-glass context line LOST in the fold (a comment mentioning it is not a label)"
grep -qE '^/run/user/[^[:space:]]+/hugmesh\(/\.\*\)\?[[:space:]].*gen_context\(' "${SRC}/hugmesh_authkeys.fc" \
    && ok "oidc-token CONTEXT LINE survives the fold into hugmesh_authkeys.fc" \
    || bad "oidc-token context line LOST in the fold (a comment mentioning it is not a label)"
# ...and the oidc path must be a regex that can match a REAL /run/user/<uid> path.
# `%{uid}` is not a libselinux substitution (refpolicy uses %{USERID}, and only in
# the genhomedircon template); as a plain file_contexts regex it can only ever
# match the literal directory "%{uid}", i.e. nothing. Prove liveness, not spelling.
oidc_pat="$(grep -E '^/run/user/.*hugmesh.*gen_context\(' "${SRC}/hugmesh_authkeys.fc" | head -1 | awk '{print $1}')"
if [ -n "${oidc_pat}" ] && printf '%s\n' '/run/user/1000/hugmesh/oidc-token' | grep -qE "^${oidc_pat}$"; then
    ok "the oidc file-context regex actually matches /run/user/1000/hugmesh/oidc-token"
else
    bad "the oidc file-context regex [${oidc_pat:-<none>}] matches NO real /run/user/<uid> path"
fi
for m in "${EXEMPLARS[@]}"; do
    [ -f "${SRC}/${m}.te" ] && ok "k8s exemplar ${m}.te present (the enforce-gate names it)" \
                            || bad "k8s exemplar ${m}.te MISSING — the enforce-gate could never pass"
done

# ── fixtures ─────────────────────────────────────────────────────────────────
# mk_headers <headerdir> <stub|real> <with-container|no-container>
# Writes a refpolicy HEADER tree in the layout `make install-headers` produces:
# Makefile (= support/Makefile.devel) + build.conf + support/*.spt + <layer>/*.if,
# all INSIDE the header dir.
#
# The Makefile reproduces support/Makefile.devel's variable contract verbatim, so
# a caller that gets NAME/SHAREDIR/HEADERDIR wrong FAILS here instead of silently
# resolving against the build host:
#   NAME ?= $(strip $(shell $(AWK) -F= '/^SELINUXTYPE/{print $2}' /etc/selinux/config))
#   SHAREDIR ?= /usr/share/selinux
#   HEADERDIR ?= $(SHAREDIR)/$(NAME)/include
#   include $(HEADERDIR)/build.conf
mk_headers() {
    local h="$1" flavour="$2" container="$3"
    mkdir -p "${h}/support" "${h}/services"
    cat > "${h}/support/loadable_module.spt" <<'SPT'
define(`policy_module',`
	module $1 $2;
')
define(`gen_context',`$1')
SPT
    # What refpolicy's install-headers writes (Makefile:601-614).
    cat > "${h}/build.conf" <<'BC'
TYPE ?= mcs
NAME ?= mcs
DISTRO ?= gentoo
MONOLITHIC ?= n
DIRECT_INITRC ?= n
SYSTEMD ?= y
CUSTOM_BUILDOPT ?=
override UBAC := n
override MLS_SENS := 16
override MLS_CATS := 1024
override MCS_CATS := 1024
BC
    if [ "${container}" = "with-container" ]; then
        cat > "${h}/services/container.if" <<'IF'
## <summary>fixture container policy header</summary>
interface(`container_domain_template',`
	gen_require(`type container_t;')
')
IF
    fi
    # The variable contract — identical in both flavours.
    cat > "${h}/Makefile" <<'MK'
# Mirrors refpolicy support/Makefile.devel's variable contract.
AWK ?= awk
NAME ?= $(strip $(shell $(AWK) -F= '/^SELINUXTYPE/{ print $$2 }' /etc/selinux/config 2>/dev/null))
SHAREDIR ?= /usr/share/selinux
HEADERDIR ?= $(SHAREDIR)/$(NAME)/include
ifeq "$(strip $(NAME))" ""
$(error Makefile.devel contract: NAME is empty — the caller passed no NAME and this build host has no /etc/selinux/config to derive it from)
endif
ifneq "$(abspath $(SHAREDIR)/$(NAME)/include)" "$(abspath $(HEADERDIR))"
$(error Makefile.devel contract: $$(SHAREDIR)/$$(NAME)/include = "$(SHAREDIR)/$(NAME)/include" does not resolve to HEADERDIR = "$(HEADERDIR)")
endif
include $(HEADERDIR)/build.conf
PREFIX := /usr
BINDIR := $(PREFIX)/bin
SBINDIR := $(PREFIX)/sbin
$(shell printf 'BINDIR=%s\nSBINDIR=%s\nHEADERDIR=%s\nNAME=%s\nSHAREDIR=%s\nTYPE=%s\n' '$(BINDIR)' '$(SBINDIR)' '$(HEADERDIR)' '$(NAME)' '$(SHAREDIR)' '$(TYPE)' > $(HEADERDIR)/compile.vars)
MK
    if [ "${flavour}" = "stub" ]; then
        cat >> "${h}/Makefile" <<'MK'
%.pp:
	@printf 'fake-pp %s\n' "$*" > $@
MK
    else
        cat >> "${h}/Makefile" <<'MK'
%.pp: %.te
	m4 $(HEADERDIR)/support/loadable_module.spt $*.te > $*.tmp
	$(BINDIR)/checkmodule -M -m $*.tmp -o $*.mod
	$(BINDIR)/semodule_package -o $@ -m $*.mod -f $*.fc
MK
    fi
}

# mk_sysroot <dir> <stub|real> <with-container|no-container>
# THE GENTOO LAYOUT — what sec-policy/selinux-base really leaves in a sysroot.
mk_sysroot() {
    local s="$1"
    mkdir -p "${s}/usr/share/selinux/mcs" "${s}/usr/share/selinux/devel" \
             "${s}/etc/init.d" "${s}/etc/conf.d" "${s}/etc/runlevels/default"
    : > "${s}/usr/share/selinux/mcs/base.pp"                 # emake install
    printf '<policy/>\n' > "${s}/usr/share/selinux/devel/policy.xml"  # the ONLY devel/ file
    mk_headers "${s}/usr/share/selinux/mcs/include" "$2" "$3"
    # The DEPENDENT modules load only when the upstream .pp is in the STORE.
    # Headers alone are not enough and never were — that is the bug this suite
    # now pins. A "with-container" image is one that merged the container AND
    # kubernetes AND tor policy modules.
    if [ "$3" = "with-container" ]; then
        : > "${s}/usr/share/selinux/mcs/container.pp"
        : > "${s}/usr/share/selinux/mcs/kubernetes.pp"
        : > "${s}/usr/share/selinux/mcs/tor.pp"
    fi
}

# mk_sysroot_fedora — the second-choice layout the lib still accepts, so a
# Fedora-ish build host (selinux-policy-devel: devel/Makefile + devel/include/)
# keeps working. NOTE: no <type>/include here, so the Gentoo probe must miss.
mk_sysroot_fedora() {
    local s="$1"
    mkdir -p "${s}/usr/share/selinux/mcs" "${s}/etc/init.d" "${s}/etc/conf.d" "${s}/etc/runlevels/default"
    : > "${s}/usr/share/selinux/mcs/base.pp"
    mk_headers "${s}/usr/share/selinux/devel/include" "$2" "$3"
    mv "${s}/usr/share/selinux/devel/include/Makefile" "${s}/usr/share/selinux/devel/Makefile"
}

# A fake ${SHARED_SPECS}: real specs/selinux, plus the real enforce-gate.
mk_specs() {  # mk_specs <dir> [<selinux-src-dir>]
    local sp="$1" from="${2:-${SRC}}"
    mkdir -p "${sp}/selinux" "${sp}/etc/init.d"
    cp "${from}"/*.te "${from}"/*.fc "${sp}/selinux/" 2>/dev/null
    cp "${SVC}" "${sp}/etc/init.d/selinux-enforce-gate"
}

run_lib() {  # run_lib <sysroot> <shared_specs> -> rc, output on stdout
    # `set -u` but NOT `set -e`: a builder calls the lib as
    # `slx_stage_node_policy ... || { err ...; exit 1; }`, and bash disables
    # errexit for the whole body of a function invoked in a `||` context — so
    # this is the accurate emulation of the real call site.
    ( set -u
      # shellcheck disable=SC1090
      source "${LIB}"
      slx_stage_node_policy "$1" "$2" ) 2>&1
}

# Count OUR modules only. base.pp is the distro's, and container/kubernetes/tor
# .pp are the upstream DEPENDENCIES a with-container fixture ships so the
# DEPENDENT modules can load — counting those would make "installed" mean
# "files in the store", which is not what any assertion here is about.
n_mods() { find "$1/usr/share/selinux/mcs" -maxdepth 1 -name '*.pp' \
             ! -name base.pp ! -name container.pp ! -name kubernetes.pp ! -name tor.pp | wc -l; }

# ── C) execution against a fake sysroot ──────────────────────────────────────
echo "-- C) real lib against a fake sysroot --"

# C1/C2: real 9-module source, NO container headers -> 7 installed, 2 skipped.
S="${TMP}/c1/sysroot"; SP="${TMP}/c1/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
out="$(run_lib "${S}" "${SP}")"; rc=$?
if [ "${rc}" -eq 0 ]; then ok "no-container image: lib succeeds (rc=0)"; else bad "no-container image: rc=${rc}"$'\n'"${out}"; fi
missing=""
for m in "${MANDATORY[@]}"; do [ -f "${S}/usr/share/selinux/mcs/${m}.pp" ] || missing="${missing} ${m}"; done
[ -z "${missing}" ] && ok "all 6 mandatory .pp installed into the policy store" \
                    || bad "mandatory .pp missing from the store:${missing}"
extra=""
for m in "${EXEMPLARS[@]}"; do [ -f "${S}/usr/share/selinux/mcs/${m}.pp" ] && extra="${extra} ${m}"; done
[ -z "${extra}" ] && ok "k8s exemplars correctly NOT built without container headers:${extra:-  none}" \
                  || bad "exemplar built without its headers:${extra}"
MAN="${S}/usr/share/hugmesh/selinux-modules.list"
if [ -f "${MAN}" ]; then
    got="$(grep -vE '^#|^$' "${MAN}" | sort | tr '\n' ' ')"
    want="$(printf '%s\n' "${MANDATORY[@]}" | sort | tr '\n' ' ')"
    [ "${got}" = "${want}" ] && ok "manifest lists exactly the installed set" \
                             || bad "manifest drift: got [${got}] want [${want}]"
    grep -q '^# skipped: localpath_provisioner' "${MAN}" \
        && ok "manifest records the skipped exemplar WITH a reason (never a silent drop)" \
        || bad "manifest does not record the skipped exemplar"
else
    bad "manifest ${MAN} not written"; bad "manifest skip-reason (no manifest)"
fi
# The build-time awareness marker: written next to the manifest whenever the
# sysroot carries a base.pp (this fixture does), so provision_selinux() can
# tell "built selinux-aware" from "never had SELinux" and hold the former to
# its policy-loaded postcondition.
[ -f "${S}/usr/share/hugmesh/selinux-built" ] \
    && ok "selinux-built marker written next to the manifest (base.pp present)" \
    || bad "selinux-built marker NOT written — provision_selinux() cannot detect a selinux-aware image"

# ── C-gentoo) THE REGRESSION FOR THE FEDORA-PATH BUG ─────────────────────────
# The fixture above must BE the Gentoo shape, and the lib must resolve to the
# per-type include dir. If mk_sysroot ever drifts back to a hand-made
# usr/share/selinux/devel/{Makefile,include}, these two fail.
echo "-- C-gentoo) the sec-policy/selinux-base sysroot shape --"
devel_files="$(cd "${S}/usr/share/selinux/devel" && ls -A | tr '\n' ' ')"
[ "${devel_files}" = "policy.xml " ] \
    && ok "fixture devel/ holds ONLY policy.xml, exactly like selinux-base's insinto" \
    || bad "fixture devel/ is not the selinux-base shape: [${devel_files}]"
printf '%s' "${out}" | grep -qF "refpolicy headers: ${S}/usr/share/selinux/mcs/include" \
    && ok "lib compiled against <sysroot>/usr/share/selinux/mcs/include (the install-headers path)" \
    || bad "lib did not use the per-type include dir"$'\n'"${out}"
# And the pins the contract Makefile records — NAME/SHAREDIR must compose to it.
cv="${S}/usr/share/selinux/mcs/include/compile.vars"
if [ -f "${cv}" ]; then
    grep -q '^NAME=mcs$' "${cv}" && ok "make was passed NAME=mcs (never derived from the build host's /etc/selinux/config)" \
                                 || bad "NAME not passed: [$(tr '\n' ' ' < "${cv}")]"
    grep -q "^SHAREDIR=${S}/usr/share/selinux$" "${cv}" \
        && ok "make was passed SHAREDIR=<sysroot>/usr/share/selinux" \
        || bad "SHAREDIR wrong: [$(tr '\n' ' ' < "${cv}")]"
else
    bad "contract Makefile never ran (no compile.vars)"; bad "(SHAREDIR check skipped)"
fi

# C-fedora: the second-choice layout still works.
S2="${TMP}/cfed/sysroot"; SP2="${TMP}/cfed/specs"; mk_sysroot_fedora "${S2}" stub no-container; mk_specs "${SP2}"
out2="$(run_lib "${S2}" "${SP2}")"; rc2=$?
{ [ "${rc2}" -eq 0 ] && [ "$(n_mods "${S2}")" -eq 6 ]; } \
    && ok "Fedora devel/ layout (devel/Makefile + devel/include) still compiles all 6" \
    || bad "Fedora layout regressed: rc=${rc2} installed=$(n_mods "${S2}")"$'\n'"${out2}"

# C3: with container headers -> all 9.
S="${TMP}/c3/sysroot"; SP="${TMP}/c3/specs"; mk_sysroot "${S}" stub with-container; mk_specs "${SP}"
out="$(run_lib "${S}" "${SP}")"; rc=$?
n_pp="$(n_mods "${S}")"
{ [ "${rc}" -eq 0 ] && [ "${n_pp}" -eq 9 ]; } \
    && ok "container-capable image: all 9 modules installed (incl. both k8s exemplars)" \
    || bad "container-capable image: rc=${rc} installed=${n_pp} (want rc=0, 9)"$'\n'"${out}"

# C3b: THE REGRESSION THIS MODEL EXISTS FOR — headers PRESENT, .pp ABSENT.
# The old gate asked "is the container_domain_template interface in the headers?"
# sec-policy/selinux-base installs the WHOLE refpolicy include tree, so that is
# true on images that merged no container/kubernetes/tor MODULE at all. Those
# modules therefore compiled, got written into the manifest, and then failed to
# load on the real node:
#     Failed to resolve typeattributeset ... localpath_provisioner/cil:20
# because kubernetes_container() expands to the attribute kubernetes_container_domain
# which only kubernetes.pp defines. check_modules() demands every manifest module,
# so the enforce-gate could never flip. Measured on
# hugmesh-x86-amd64-pki-test-20260814T112817Z (issue #45).
#
# This fixture is the exact shape: full headers, NO dependency .pp.
S="${TMP}/c3b/sysroot"; SP="${TMP}/c3b/specs"; mk_sysroot "${S}" stub with-container; mk_specs "${SP}"
rm -f "${S}/usr/share/selinux/mcs/container.pp" \
      "${S}/usr/share/selinux/mcs/kubernetes.pp" \
      "${S}/usr/share/selinux/mcs/tor.pp"
out="$(run_lib "${S}" "${SP}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "C3b headers-without-modules: the step still succeeds" \
                  || bad "C3b: rc=${rc}"$'\n'"${out}"
built_dep=""
for m in "${DEPENDENT[@]}"; do [ -f "${S}/usr/share/selinux/mcs/${m}.pp" ] && built_dep="${built_dep} ${m}"; done
[ -z "${built_dep}" ] \
    && ok "C3b a module whose upstream .pp is ABSENT is skipped even though its headers are present" \
    || bad "C3b built module(s) that cannot load:${built_dep} — the header gate is back"
MAN3B="${S}/usr/share/hugmesh/selinux-modules.list"
named=""
for m in "${DEPENDENT[@]}"; do grep -qx "${m}" "${MAN3B}" 2>/dev/null && named="${named} ${m}"; done
[ -z "${named}" ] \
    && ok "C3b the manifest never names an unloadable module (so check_modules() can pass)" \
    || bad "C3b manifest names unloadable module(s):${named} — the enforce-gate could never flip"
printf '%s' "${out}" | grep -q 'sec-policy/selinux-kubernetes' \
    && ok "C3b the skip message names the package that would fix it" \
    || bad "C3b skip message does not name sec-policy/selinux-kubernetes"$'\n'"${out}"

# C3c: USRMERGE — a /usr/sbin .fc rule can never match on these images.
# Measured in the booted guest: /usr/sbin is a symlink to bin (and /sbin to
# usr/bin), and libselinux canonicalises a path through symlinks BEFORE matching
# file contexts. So a rule written for /usr/sbin/x never applies:
#     matchpathcon /usr/sbin/hugmesh-authorized-keys-lookup -> bin_t
#     matchpathcon /usr/bin/hugmesh-authorized-keys-lookup  -> bin_t
# while semanage fcontext -l happily lists the /usr/sbin rule. The entrypoint
# executable therefore keeps bin_t, and a domain transition into
# hugmesh_*_exec_t -> hugmesh_*_t CANNOT HAPPEN. Every one of these 9 rules is an
# entrypoint, so this silently disabled every hugmesh domain.
#
# Adding the /usr/bin spelling was verified live in the guest:
#     Relabeled /usr/bin/hugmesh-authorized-keys-lookup
#       from system_u:object_r:bin_t:s0 to system_u:object_r:hugmesh_authkeys_exec_t:s0
#
# Both spellings are kept: on a non-usrmerge image /usr/sbin is a real directory
# and its rule is the one that matches. Neither is redundant, and dropping the
# /usr/bin one silently re-disables the domains.
echo "-- C3c) every /usr/sbin exec rule has a /usr/bin sibling (usrmerge) --"
orphans=""
for fc in "${SRC}"/*.fc; do
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        sib="/usr/bin/${path#/usr/sbin/}"
        grep -qF "${sib}" "${fc}" || orphans="${orphans} $(basename "${fc}"):${path}"
    done < <(grep -oE '^/usr/sbin/[^[:space:]]+' "${fc}" 2>/dev/null)
done
[ -z "${orphans}" ] \
    && ok "C3c every /usr/sbin exec rule also labels the /usr/bin path it resolves to" \
    || bad "C3c /usr/sbin rule(s) with no /usr/bin sibling — the domain can never be entered:${orphans}"

# C4-C6: THE PERMISSIVE-BY-DEFAULT PROOF.
[ -x "${S}/etc/init.d/selinux-enforce-gate" ] \
    && ok "enforce-gate service shipped executable into /etc/init.d" \
    || bad "enforce-gate service NOT shipped"
grep -q '^SELINUX_ENFORCE_GATE="no"$' "${S}/etc/conf.d/selinux-enforce-gate" \
    && ok "DEFAULT OFF: /etc/conf.d/selinux-enforce-gate says no" \
    || bad "conf.d does not default the enforce-gate to no"
# NB: the runlevel entry is a symlink to the ABSOLUTE in-image path
# /etc/init.d/selinux-enforce-gate, so from the build host it DANGLES — `-e`
# follows symlinks and would be false even when the link exists (this exact
# vacuity was caught by mutating the lib's default to ON). Test -L too.
if [ -L "${S}/etc/runlevels/default/selinux-enforce-gate" ] || [ -e "${S}/etc/runlevels/default/selinux-enforce-gate" ]; then
    bad "enforce-gate linked into the default runlevel by DEFAULT (would flip nodes enforcing)"
else
    ok "DEFAULT OFF: enforce-gate is in NO runlevel — OpenRC never starts it"
fi

# C7/C8: the explicit opt-in.
S="${TMP}/c7/sysroot"; SP="${TMP}/c7/specs"; mk_sysroot "${S}" stub with-container; mk_specs "${SP}"
out="$(HUGMESH_SELINUX_ENFORCE_GATE=1 run_lib "${S}" "${SP}")"; rc=$?
grep -q '^SELINUX_ENFORCE_GATE="yes"$' "${S}/etc/conf.d/selinux-enforce-gate" \
    && ok "opt-in HUGMESH_SELINUX_ENFORCE_GATE=1 flips conf.d to yes" \
    || bad "opt-in did not flip conf.d (rc=${rc})"
[ -L "${S}/etc/runlevels/default/selinux-enforce-gate" ] \
    && ok "opt-in links the service into the default runlevel" \
    || bad "opt-in did not link the service into the default runlevel"

# C9/C10: ALL-OR-NOTHING. A module that fails to compile must fail the build and
# leave the policy store untouched — never a half-populated store.
S="${TMP}/c9/sysroot"; SP="${TMP}/c9/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
cat >> "${S}/usr/share/selinux/mcs/include/Makefile" <<'MK'
hugmesh_vpn.pp:
	@echo "fixture: deliberate compile failure" >&2; exit 1
MK
out="$(run_lib "${S}" "${SP}")"; rc=$?
[ "${rc}" -ne 0 ] && ok "a module that fails to compile fails the step (rc=${rc})" \
                  || bad "compile failure did NOT fail the step"
n_pp="$(n_mods "${S}")"
[ "${n_pp}" -eq 0 ] && ok "ALL-OR-NOTHING: nothing installed after a compile failure" \
                    || bad "half-populated store: ${n_pp} .pp installed despite a failure"

# C10b: a Makefile that EXITS 0 but produces no .pp must still fail. Without the
# post-make existence check the lib would record the module as built and then
# install nothing under that name — the manifest would name a .pp the image lacks
# and the enforce-gate would wait forever for a module that can never load.
S="${TMP}/c10b/sysroot"; SP="${TMP}/c10b/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
cat >> "${S}/usr/share/selinux/mcs/include/Makefile" <<'MK'
hugmesh_policy_sync.pp:
	@echo "fixture: silent no-op, exits 0, writes nothing"
MK
out="$(run_lib "${S}" "${SP}")"; rc=$?
{ [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -q 'make reported success but hugmesh_policy_sync.pp does not exist'; } \
    && ok "a make that succeeds without writing the .pp fails loudly and names the module" \
    || bad "a silent no-op make was accepted (rc=${rc})"$'\n'"${out}"
[ "$(n_mods "${S}")" -eq 0 ] && ok "silent no-op make: nothing installed" \
                             || bad "silent no-op make: $(n_mods "${S}") .pp installed anyway"

# C11/C12: the label-only trap.
S="${TMP}/c11/sysroot"; SP="${TMP}/c11/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
printf '/etc/ghost -- gen_context(system_u:object_r:etc_t,s0)\n' > "${SP}/selinux/ghost_label_only.fc"
out="$(run_lib "${S}" "${SP}")"; rc=$?
[ "${rc}" -ne 0 ] && ok "a label-only .fc (no .te) fails the step instead of vanishing" \
                  || bad "label-only .fc was silently ignored (rc=0)"
[ "$(n_mods "${S}")" -eq 0 ] && ok "label-only .fc: nothing installed" || bad "label-only .fc: $(n_mods "${S}") .pp installed anyway"

# C13: the deliberate operator opt-out.
S="${TMP}/c13/sysroot"; SP="${TMP}/c13/specs"; mk_sysroot "${S}" stub with-container; mk_specs "${SP}"
out="$(HUGMESH_SELINUX_MODULES=0 run_lib "${S}" "${SP}")"; rc=$?
{ [ "${rc}" -eq 0 ] && [ "$(n_mods "${S}")" -eq 0 ]; } \
    && ok "HUGMESH_SELINUX_MODULES=0 is a clean, loud no-op (rc=0, nothing installed)" \
    || bad "opt-out misbehaved: rc=${rc} installed=$(n_mods "${S}")"
[ -e "${S}/etc/conf.d/selinux-enforce-gate" ] \
    && bad "opt-out still shipped the enforce-gate conf.d" \
    || ok "opt-out ships no enforce-gate at all"

# C14: NO refpolicy header tree anywhere -> loud failure, not a silent empty
# store. NOTE this is the EXCEPTIONAL branch: a real image always has the
# per-type include dir (C-gentoo above is the always-taken case).
S="${TMP}/c14/sysroot"; SP="${TMP}/c14/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
rm -rf "${S}/usr/share/selinux/mcs/include"
if [ -d /usr/share/selinux ]; then
    ok "SKIP header-absent case (this host has its own /usr/share/selinux)"
    ok "SKIP header-absent diagnostic (this host has its own /usr/share/selinux)"
else
    out="$(run_lib "${S}" "${SP}")"; rc=$?
    { [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -q 'no refpolicy module-build header tree found'; } \
        && ok "missing refpolicy header tree fails loudly with the reason" \
        || bad "missing header tree did not fail loudly (rc=${rc})"$'\n'"${out}"
    # The old message blamed a missing selinux-base even when base.pp was right
    # there. It must now name the real cause.
    printf '%s' "${out}" | grep -q 'base.pp EXISTS, so selinux-base IS merged' \
        && ok "the diagnostic distinguishes 'headers stripped' from 'selinux-base absent'" \
        || bad "the diagnostic still misattributes the cause"$'\n'"${out}"
fi

# D-if) every interface/macro a module calls must EXIST in real refpolicy.
# The 2026-08-05 real ARM build proved the fixture legs cannot catch an
# INVENTED interface name (four shipped: auth_read_all_files_except_shadow x2,
# modutils_domtrans_insmod, files_pid_filetrans, plus a connect_socket_perms
# perm-set typo) — checkmodule only sees them with real headers. This leg is
# the hermetic version of that proof: scripts/selinux-interface-index.txt is
# the interface/template/perm-set census of a REAL sysroot refpolicy tree
# (generated from wl-pki.rpi5 @ sec-policy/selinux-base-2.20260616_p1; the
# regeneration recipe is in the index header comment). Every identifier a .te
# calls as a statement must be in the index or be a local definition.
echo "-- D-if) called interfaces exist in real refpolicy (index) --"
IDX="${GEN}/scripts/selinux-interface-index.txt"
if [ ! -f "${IDX}" ]; then
    bad "scripts/selinux-interface-index.txt missing — the invented-interface class is unguarded"
else
    for te in "${SRC}"/*.te; do
        mod="$(basename "${te}" .te)"
        bad_names=""
        while IFS= read -r name; do
            case "${name}" in
                policy_module|gen_require|gen_tunable|tunable_policy|optional_policy|require|type|attribute|class|role|bool|ifdef|ifndef|refpolicywarn|interface|template) continue ;;
            esac
            grep -qx "${name}" "${IDX}" && continue
            # locally-defined interface/template in the module's own .if? none shipped; treat as invented
            bad_names="${bad_names} ${name}"
        done < <(grep -oE '^[a-z][a-z0-9_]*\(' "${te}" | sed 's/($//;s/(//' | sort -u)
        # perm-set macros used inside allow rules (the *_perms class)
        while IFS= read -r pname; do
            grep -qx "${pname}" "${IDX}" && continue
            bad_names="${bad_names} ${pname}"
        done < <(grep -oE '[a-z][a-z0-9_]*_perms' "${te}" | sort -u)
        if [ -n "${bad_names}" ]; then
            bad "${mod}: calls interface/macro name(s) NOT in real refpolicy:${bad_names} — checkmodule will fail at build time (the 2026-08-05 class)"
        else
            ok "${mod}: every called interface/perm-set exists in the real refpolicy index"
        fi
    done
fi

# D-real) compile EVERY shipped module against a REAL refpolicy header tree.
# D-if (above) pins interface NAMES against a committed index. It cannot see a
# second class of policy-language error: a PERMISSION that the class does not
# define. 2026-08-06 shipped exactly that — `create_netlink_socket_perms` expands
# to `{ create_socket_perms nlmsg_read nlmsg_write }`, and netlink_netfilter_socket
# defines no nlmsg_* perms, so two allow rules in hugmesh_vpn.te aborted the policy
# stage of a real mesh build. The class/permission map is compiled into base.pp,
# not shipped as indexable text, so the honest oracle is checkmodule itself.
#
# Header trees are searched in this order; the FIRST usable one wins:
#   $HUGMESH_SELINUX_HEADERS            explicit override (CI can point at anything)
#   out/sessions/*/wl-*/sysroot/usr/share/selinux/*/include   a real build's sysroot
#   /usr/share/selinux/*/include        the host, when sec-policy is installed
#   tests/fixtures/selinux/*.tar.gz     the PINNED fixture — last resort, see below
#
# THE FIXTURE IS LAST ON PURPOSE. A real sysroot is the production article; the
# fixture is a photograph of one. Whenever the real thing is present it must win,
# or this leg would quietly stop tracking what builds actually compile against.
#
# Why a committed fixture at all: until now CI reached none of the first three and
# SKIPped, so the permission-class bug that #545 fixed could have walked straight
# back in. Debian's `selinux-policy-dev` is NOT a substitute — this tree carries
# gentoo_tunables.xml and Gentoo-only interfaces, so compiling against Debian's
# refpolicy would fail on interfaces that are perfectly valid for our builds.
# ${SLX_FIXTURE_VERSION} below records what it is a photograph OF; the drift leg
# (D-drift) fails when a real sysroot has moved past it.
SLX_FIXTURE_VERSION="2.20260616_p1"
SLX_FIXTURE="${GEN}/tests/fixtures/selinux/refpolicy-headers-mcs-${SLX_FIXTURE_VERSION}.tar.gz"
echo "-- D-real) every module compiles against a real refpolicy header tree --"
_slx_find_headers() {
    local h
    if [ -n "${HUGMESH_SELINUX_HEADERS:-}" ]; then
        [ -f "${HUGMESH_SELINUX_HEADERS}/Makefile" ] && { printf '%s' "${HUGMESH_SELINUX_HEADERS}"; return 0; }
    fi
    for h in "${GEN}"/out/sessions/*/wl-*/sysroot/usr/share/selinux/*/include \
             /usr/share/selinux/*/include; do
        [ -f "${h}/Makefile" ] && { printf '%s' "${h}"; return 0; }
    done
    # Last resort: unpack the pinned fixture. Verify the digest first — a fixture
    # that unpacks to something other than what was recorded is not a header tree
    # we know anything about, and compiling against it would prove nothing.
    if [ -f "${SLX_FIXTURE}" ] && command -v sha256sum >/dev/null; then
        if (cd "$(dirname "${SLX_FIXTURE}")" && sha256sum -c --status refpolicy-headers.sha256) 2>/dev/null; then
            mkdir -p "${TMP}/fixture-hdr"
            if tar -xzf "${SLX_FIXTURE}" -C "${TMP}/fixture-hdr" 2>/dev/null \
               && [ -f "${TMP}/fixture-hdr/include/Makefile" ]; then
                printf '%s' "${TMP}/fixture-hdr/include"; return 0
            fi
        else
            echo "  WARNING: ${SLX_FIXTURE##*/} does not match refpolicy-headers.sha256 — refusing to use it" >&2
        fi
    fi
    return 1
}
if ! command -v checkmodule >/dev/null || ! command -v semodule_package >/dev/null || ! command -v m4 >/dev/null; then
    echo "  SKIP D-real: policy toolchain absent (checkmodule/semodule_package/m4) — NOT a pass;"
    echo "               ${SRC}/*.te were not compiled. Install sys-apps/checkpolicy + policycoreutils."
elif ! HDR="$(_slx_find_headers)"; then
    echo "  SKIP D-real: no refpolicy header tree found — NOT a pass; ${SRC}/*.te were not compiled."
    echo "               Point HUGMESH_SELINUX_HEADERS at a <sysroot>/usr/share/selinux/<type>/include,"
    echo "               or run this after any real build (its sysroot carries one)."
else
    _SLX_SHARE="$(dirname "${HDR}")"; _SLX_NAME="$(basename "${_SLX_SHARE}")"
    case "${HDR}" in
        "${TMP}"/fixture-hdr/*) echo "  using headers: the PINNED FIXTURE (sec-policy ${SLX_FIXTURE_VERSION})" ;;
        *)                      echo "  using headers: ${HDR}" ;;
    esac
    for _te in "${SRC}"/*.te; do
        _m="$(basename "${_te}" .te)"
        _w="${TMP}/dreal/${_m}"; mkdir -p "${_w}"
        cp "${_te}" "${_w}/"
        [ -f "${SRC}/${_m}.fc" ] && cp "${SRC}/${_m}.fc" "${_w}/"
        if make -s -C "${_w}" -f "${HDR}/Makefile" NAME="${_SLX_NAME}" \
                SHAREDIR="$(dirname "${_SLX_SHARE}")" HEADERDIR="${HDR}" \
                "${_m}.pp" >"${_w}/build.log" 2>&1; then
            ok "${_m}: compiles against real refpolicy headers"
        else
            bad "${_m}: FAILS to compile against real refpolicy headers — $(grep -oE "(ERROR|error)[^\n]*" "${_w}/build.log" | head -1)"
        fi
    done
fi

# D-drift) the fixture is a photograph — this leg notices when reality moves past it.
#
# CI compiles against the pinned fixture, so if Gentoo bumps sec-policy and our
# builds start using a newer refpolicy, CI would keep compiling against the OLD
# one and stay green while real builds broke. That is precisely the failure mode
# a pinned mirror invites, so it gets its own guard rather than a comment.
#
# The comparison is deliberately one-directional: it fails only when a real
# sysroot is NEWER than the fixture. A developer with a months-old build tree is
# not a defect and must not be punished for it — but a build tree ahead of the
# fixture means the fixture has rotted and CI is now testing the wrong policy.
echo "-- D-drift) the pinned fixture still matches what real builds install --"
_slx_sysroot_secpolicy_version() {
    local d v
    for d in "${GEN}"/out/sessions/*/wl-*/sysroot/var/db/pkg/sec-policy/selinux-base-policy-* \
             "${GEN}"/out/*/sysroot/var/db/pkg/sec-policy/selinux-base-policy-*; do
        [ -d "${d}" ] || continue
        v="$(basename "${d}")"; v="${v#selinux-base-policy-}"
        printf '%s' "${v}"; return 0
    done
    return 1
}
if [ ! -f "${SLX_FIXTURE}" ]; then
    bad "the pinned header fixture is missing: ${SLX_FIXTURE#"${GEN}"/}"
elif ! command -v sha256sum >/dev/null; then
    echo "  SKIP D-drift digest check: sha256sum absent — NOT a pass"
elif ! (cd "$(dirname "${SLX_FIXTURE}")" && sha256sum -c --status refpolicy-headers.sha256) 2>/dev/null; then
    bad "the fixture does not match refpolicy-headers.sha256 — it was edited or corrupted"
else
    ok "fixture digest matches refpolicy-headers.sha256"
    if ! _SLX_SYS_VER="$(_slx_sysroot_secpolicy_version)"; then
        echo "  SKIP D-drift version compare: no built sysroot on this host to compare against — NOT a pass;"
        echo "               the fixture is pinned at sec-policy ${SLX_FIXTURE_VERSION} and nothing here can"
        echo "               confirm that is still what builds install. Any real build re-checks it."
    elif [ "${_SLX_SYS_VER}" = "${SLX_FIXTURE_VERSION}" ]; then
        ok "a real build sysroot carries sec-policy ${_SLX_SYS_VER} — the fixture is current"
    else
        # Sort the two versions; if the sysroot sorts LAST it is the newer one.
        _SLX_NEWEST="$(printf '%s\n%s\n' "${SLX_FIXTURE_VERSION}" "${_SLX_SYS_VER}" | sort -V | tail -1)"
        if [ "${_SLX_NEWEST}" = "${_SLX_SYS_VER}" ]; then
            bad "FIXTURE HAS ROTTED: builds now install sec-policy ${_SLX_SYS_VER}, the fixture is pinned at ${SLX_FIXTURE_VERSION}."$'\n'\
"       CI is compiling every module against a refpolicy that real builds no longer use."$'\n'\
"       Regenerate — see tests/fixtures/selinux/README.md."
        else
            ok "the sysroot here (${_SLX_SYS_VER}) is older than the fixture (${SLX_FIXTURE_VERSION}) — stale tree, not stale fixture"
        fi
    fi
fi

# C15/C16: the REAL host toolchain, driven through the lib's own make invocation.
echo "-- C-real) the genuine m4 -> checkmodule -> semodule_package recipe --"
if command -v m4 >/dev/null && command -v checkmodule >/dev/null && command -v semodule_package >/dev/null; then
    FIX="${TMP}/fixsrc"; mkdir -p "${FIX}"
    cat > "${FIX}/slxfix.te" <<'TE'
policy_module(slxfix, 1.0.0)
require {
	type unlabeled_t;
	class file { read };
}
allow unlabeled_t unlabeled_t:file read;
TE
    cat > "${FIX}/slxfix.fc" <<'FC'
/usr/sbin/slxfix    --    gen_context(system_u:object_r:unlabeled_t,s0)
FC
    S="${TMP}/creal/sysroot"; SP="${TMP}/creal/specs"
    mk_sysroot "${S}" real no-container; mk_specs "${SP}" "${FIX}"
    out="$(run_lib "${S}" "${SP}")"; rc=$?
    pp="${S}/usr/share/selinux/mcs/slxfix.pp"
    if [ "${rc}" -eq 0 ] && [ -s "${pp}" ] && grep -qa 'slxfix' "${pp}"; then
        ok "real toolchain: the lib's make invocation produced a genuine .pp ($(stat -c%s "${pp}") bytes)"
    else
        bad "real toolchain compile failed: rc=${rc}"$'\n'"${out}"
    fi
    # CROSS-SAFETY: the refpolicy Makefile must be pinned to the HOST /usr/bin, or
    # a cross build would try to run aarch64 checkmodule/semodule_package.
    vars="$(cat "${S}/usr/share/selinux/mcs/include/compile.vars" 2>/dev/null)"
    printf '%s' "${vars}" | grep -q '^BINDIR=/usr/bin$' \
        && ok "compile ran with BINDIR pinned to the HOST /usr/bin (never a target binary)" \
        || bad "BINDIR was not pinned to the host: [${vars}]"
    printf '%s' "${vars}" | grep -q "^HEADERDIR=${S}/usr/share/selinux/mcs/include$" \
        && ok "compile ran against the SYSROOT's refpolicy headers" \
        || bad "HEADERDIR did not point at the sysroot header tree: [${vars}]"
else
    ok "SKIP real-toolchain compile (m4/checkmodule/semodule_package not on this host)"
    ok "SKIP BINDIR pin check (no host toolchain)"
    ok "SKIP HEADERDIR check (no host toolchain)"
fi

# C-pin: THE CROSS-BUILD TRAP. The Makefile we run comes FROM THE TARGET SYSROOT,
# so its PREFIX/BINDIR/SBINDIR are whatever that image's refpolicy shipped — a
# vendored or relocated Makefile.devel can hardcode paths that on the x86 build
# host resolve to nothing, or on a cross sysroot to unexecutable target binaries.
# Only the command-line pin stops it. Model that by giving the sysroot Makefile
# hardcoded target tool dirs and proving the pin wins.
#
# NOTE ON WHICH PINS THIS KILLS: BINDIR and SBINDIR are load-bearing and proven
# here. PREFIX=/usr is deliberately kept as well, but it is REDUNDANT whenever
# BINDIR/SBINDIR are pinned — it only matters for the upstream shape where
# BINDIR := $(PREFIX)/bin. Removing PREFIX alone therefore survives this suite by
# construction, not by oversight.
echo "-- C-pin) the sysroot Makefile's own tool dirs must never win --"
if command -v m4 >/dev/null && command -v checkmodule >/dev/null && command -v semodule_package >/dev/null; then
    S="${TMP}/cpin/sysroot"; SP="${TMP}/cpin/specs"
    mk_sysroot "${S}" real no-container; mk_specs "${SP}" "${TMP}/fixsrc"
    HMK="${S}/usr/share/selinux/mcs/include/Makefile"
    sed -i -e 's|^PREFIX := /usr$|PREFIX := /nonexistent-target-sysroot/usr|' \
           -e 's|^BINDIR := \$(PREFIX)/bin$|BINDIR := /nonexistent-target-sysroot/usr/bin|' \
           -e 's|^SBINDIR := \$(PREFIX)/sbin$|SBINDIR := /nonexistent-target-sysroot/usr/sbin|' "${HMK}"
    n_armed="$(grep -c '^\(PREFIX\|BINDIR\|SBINDIR\) := /nonexistent-target-sysroot/' "${HMK}")"
    [ "${n_armed}" -eq 3 ] \
        && ok "C-pin fixture armed (sysroot Makefile hardcodes 3 target tool dirs)" \
        || bad "C-pin fixture did not arm (${n_armed}/3) — the trap is inert"
    out="$(run_lib "${S}" "${SP}")"; rc=$?
    vars="$(cat "${S}/usr/share/selinux/mcs/include/compile.vars" 2>/dev/null)"
    { [ "${rc}" -eq 0 ] && printf '%s' "${vars}" | grep -q '^BINDIR=/usr/bin$'; } \
        && ok "the BINDIR pin overrides the sysroot Makefile — checkmodule came from the HOST" \
        || bad "the sysroot Makefile's target BINDIR won: rc=${rc} vars=[${vars}]"$'\n'"${out}"
    printf '%s' "${vars}" | grep -q '^SBINDIR=/usr/sbin$' \
        && ok "the SBINDIR pin overrides the sysroot Makefile too" \
        || bad "SBINDIR was not pinned to the host: [${vars}]"
else
    ok "SKIP C-pin fixture (no host toolchain)"
    ok "SKIP C-pin BINDIR override proof (no host toolchain)"
    ok "SKIP C-pin SBINDIR override proof (no host toolchain)"
fi

# C17/C18: permissions + idempotence.
S="${TMP}/c17/sysroot"; SP="${TMP}/c17/specs"; mk_sysroot "${S}" stub with-container; mk_specs "${SP}"
out="$(run_lib "${S}" "${SP}")"; rc=$?
mode="$(stat -c '%a' "${S}/usr/share/selinux/mcs/hugmesh_vpn.pp" 2>/dev/null)"
[ "${mode}" = "644" ] && ok ".pp installed 0644" || bad ".pp mode is ${mode:-<missing>} (want 644)"
before="$(cd "${S}" && find usr/share/selinux/mcs usr/share/hugmesh etc/conf.d etc/init.d -type f | sort | xargs -r md5sum | md5sum)"
out="$(run_lib "${S}" "${SP}")"; rc2=$?
after="$(cd "${S}" && find usr/share/selinux/mcs usr/share/hugmesh etc/conf.d etc/init.d -type f | sort | xargs -r md5sum | md5sum)"
{ [ "${rc2}" -eq 0 ] && [ "${before}" = "${after}" ]; } \
    && ok "idempotent: a second run succeeds and changes nothing" \
    || bad "not idempotent (rc=${rc2}, digest ${before} -> ${after})"

# C19: a WITHDRAWN module must not survive a --resume/--skip-clean re-run. The
# store is globbed and the manifest is the gate's contract, so a stale .pp would
# be loaded at first boot while being absent from the manifest.
rm -f "${SP}/selinux/hugmesh_tor.te" "${SP}/selinux/hugmesh_tor.fc"
out="$(run_lib "${S}" "${SP}")"; rc=$?
{ [ "${rc}" -eq 0 ] && [ ! -e "${S}/usr/share/selinux/mcs/hugmesh_tor.pp" ]; } \
    && ok "a module withdrawn from specs/selinux is removed from an existing store" \
    || bad "withdrawn module still in the store (rc=${rc})"
[ -f "${S}/usr/share/selinux/mcs/base.pp" ] \
    && ok "the prune never touches the distro's own base.pp" \
    || bad "the prune deleted base.pp"

# ── D) the enforce-gate service — static shape ───────────────────────────────
echo "-- D) specs/etc/init.d/selinux-enforce-gate (static) --"
bash -n "${SVC}" 2>/dev/null && ok "enforce-gate service is valid shell" || bad "enforce-gate does not parse"
grep -q 'SELINUX_ENFORCE_GATE:=no' "${SVC}" \
    && ok "service defaults SELINUX_ENFORCE_GATE to no in-script (belt AND braces)" \
    || bad "service does not default the switch to no"
# The opt-in must be checked BEFORE the settle marker is written, or a default
# image would still walk the first step of the flip path.
en_ln="$(grep -n 'if ! check_enabled; then' "${SVC}" | head -1 | cut -d: -f1)"
mk_ln="$(grep -n 'touch "${MARKER}"' "${SVC}" | head -1 | cut -d: -f1)"
{ [ -n "${en_ln}" ] && [ -n "${mk_ln}" ] && [ "${en_ln}" -lt "${mk_ln}" ]; } \
    && ok "opt-in is checked (line ${en_ln}) BEFORE the settle marker is written (line ${mk_ln})" \
    || bad "opt-in is not checked before the marker write (enabled=${en_ln:-none} marker=${mk_ln:-none})"
grep -q 'MODULE_MANIFEST:=/usr/share/hugmesh/selinux-modules.list' "${SVC}" \
    && ok "check_modules reads the build-time manifest" \
    || bad "service does not read /usr/share/hugmesh/selinux-modules.list"
grep -qE 'for m in base container otel_collector localpath_provisioner' "${SVC}" \
    && bad "the old unsatisfiable hardcoded module list is still there" \
    || ok "the old unsatisfiable hardcoded module list is gone"
grep -q 'Refusing to flip' "${SVC}" \
    && ok "a manifest-less (pre-wiring) image refuses to flip" \
    || bad "service does not refuse to flip without a manifest"
grep -q 'hugmesh_authkeys_t' "${SVC}" \
    && ok "check_avc_clean covers the hugmesh domains this wiring now loads" \
    || bad "check_avc_clean does not cover the hugmesh domains"

# ── D-run) the enforce-gate's start() actually EXECUTED ──────────────────────
# The static block above is greps and line numbers; it constrains nothing about
# behaviour. Five separate mutations to the flip path (dropping check_modules,
# dropping the relabel/AVC checks, `if true`, removing the settle-marker guard,
# and — worst — deleting `eend 0; return 0` from the disabled branch so
# SELINUX_ENFORCE_GATE=no falls THROUGH into the flip path) all left the suite
# green. So: source the real service file, override only its path variables
# (plain assignments, so the override happens AFTER sourcing and the shipped
# bytes are unmodified), stub the system tools, and call start() for real.
echo "-- D-run) enforce-gate start() executed against stubbed system tools --"

# gate_run <scratch> <gate-value> ; fixture knobs come from the FX_* env vars.
# Prints the service's own output; records every privileged call in <scratch>/calls.
gate_run() {
    ( set +u
      local G="$1"
      export SELINUX_ENFORCE_GATE="$2"
      : > "${G}/calls"
      # OpenRC vocabulary
      ebegin() { :; }; eend() { return 0; }
      einfo()  { echo "einfo: $*"; }
      ewarn()  { echo "ewarn: $*"; }
      eerror() { echo "eerror: $*"; }
      # System tools — ALL stubbed as shell functions so `command -v` finds them
      # and the real /usr/bin/{setenforce,ausearch,...} on this host can never run.
      selinuxenabled() { return "${FX_SELINUX_ENABLED_RC:-0}"; }
      getenforce()     { printf '%s\n' "${FX_GETENFORCE:-Permissive}"; }
      setenforce()     { echo "setenforce $*" >> "${G}/calls"; return 0; }
      semodule()       { echo "semodule $*" >> "${G}/calls"; printf '%s' "${FX_SEMODULE_L:-}"; return "${FX_SEMODULE_RC:-0}"; }
      restorecon()     { printf '%s' "${FX_RESTORECON_OUT:-}"; return 0; }
      ausearch()       { printf '%s' "${FX_AUSEARCH_OUT:-}"; return 0; }
      rc-update()      { echo "rc-update $*" >> "${G}/calls"; return 0; }
      # shellcheck disable=SC1090
      source "${SVC}"
      # Redirect the service's absolute paths at the fixture. These are plain
      # assignments in the shipped file, so overriding them here (after sourcing)
      # exercises the file byte-for-byte as shipped.
      MARKER="${G}/marker"; CONFIG="${G}/config"; TYPE=mcs
      MODULE_MANIFEST="${G}/manifest"; AUTORELABEL="${G}/autorelabel"
      CONTAINERD_INITD="${G}/containerd-initd"   # absent unless a case creates it
      PROVISION_FAILED="${G}/selinux-load-failed"   # absent unless a case creates it
      start ) 2>&1
}

# gate_fixture <scratch> — a sysroot-ish scratch where EVERY check passes.
gate_fixture() {
    local G="$1"; mkdir -p "${G}"
    printf 'SELINUX=permissive\nSELINUXTYPE=mcs\n' > "${G}/config"
    printf '# manifest\nhugmesh_authkeys\nhugmesh_vpn\n' > "${G}/manifest"
    rm -f "${G}/marker" "${G}/autorelabel" "${G}/containerd-initd" "${G}/selinux-load-failed"
    # `semodule -l` output shape: one "name<TAB>version" line per loaded module.
    export FX_SEMODULE_L=$'base\t1.0.0\nhugmesh_authkeys\t1.0.0\nhugmesh_vpn\t1.0.0\n'
    export FX_SEMODULE_RC=0 FX_GETENFORCE=Permissive FX_SELINUX_ENABLED_RC=0
    export FX_RESTORECON_OUT="" FX_AUSEARCH_OUT=""
}
gate_flipped()  { grep -q '^setenforce 1' "$1/calls" 2>/dev/null; }
gate_enforcing() { grep -q '^SELINUX=enforcing' "$1/config" 2>/dev/null; }

# D-run1 — POSITIVE CONTROL. Without this the negative cases below prove nothing:
# they could all be passing because the harness simply cannot flip.
G="${TMP}/g1"; gate_fixture "${G}"; touch "${G}/marker"
o="$(gate_run "${G}" yes)"
{ gate_flipped "${G}" && gate_enforcing "${G}"; } \
    && ok "POSITIVE CONTROL: opted in + settled + all checks green => setenforce 1 and SELINUX=enforcing persisted" \
    || bad "the harness cannot flip at all, so every negative case below is vacuous"$'\n'"${o}"
grep -q '^rc-update del selinux-enforce-gate' "${G}/calls" \
    && ok "after a successful flip the service removes itself from the runlevel" \
    || bad "the service did not rc-update del itself after flipping"

# D-run2 — THE DEFAULT-OFF LOCK. This is the load-bearing claim of the whole
# change: an image with the opt-in OFF behaves exactly as today.
G="${TMP}/g2"; gate_fixture "${G}"
o="$(gate_run "${G}" no)"; rc=$?
o2="$(gate_run "${G}" no)"     # and again — a fall-through would flip on run 2
[ "${rc}" -eq 0 ] && ok "disabled gate returns success (never fails the boot)" \
                  || bad "disabled gate returned rc=${rc}"
gate_flipped "${G}" && bad "SELINUX_ENFORCE_GATE=no still called setenforce" \
                    || ok "SELINUX_ENFORCE_GATE=no never calls setenforce, across two boots"
gate_enforcing "${G}" && bad "SELINUX_ENFORCE_GATE=no rewrote /etc/selinux/config to enforcing" \
                      || ok "SELINUX_ENFORCE_GATE=no leaves SELINUX=permissive in the config"
[ -e "${G}/marker" ] && bad "SELINUX_ENFORCE_GATE=no still wrote the settle marker (it walked into the flip path)" \
                     || ok "SELINUX_ENFORCE_GATE=no does not even write the settle marker"
printf '%s' "${o}${o2}" | grep -q 'node stays PERMISSIVE' \
    && ok "the disabled gate says so out loud" || bad "the disabled gate is silent"

# D-run3 — the settle-marker guard: never flip on the relabel (first) boot.
G="${TMP}/g3"; gate_fixture "${G}"
o="$(gate_run "${G}" yes)"
{ [ -e "${G}/marker" ] && ! gate_flipped "${G}" && ! gate_enforcing "${G}"; } \
    && ok "opted in, first boot: records the settle marker and does NOT flip" \
    || bad "opted in, first boot flipped (marker=$([ -e "${G}/marker" ] && echo y || echo n))"$'\n'"${o}"
o="$(gate_run "${G}" yes)"
gate_flipped "${G}" && ok "opted in, second boot: flips once the marker exists" \
                    || bad "opted in, second boot did not flip"$'\n'"${o}"

# D-run4..D-run9 — every individual check must be able to BLOCK the flip.
gate_blocks() {  # gate_blocks <label> <setup-fn>
    local label="$1" setup="$2" g="${TMP}/gb$((++GB))"
    gate_fixture "${g}"; touch "${g}/marker"; "${setup}" "${g}"
    local o; o="$(gate_run "${g}" yes)"
    if gate_flipped "${g}" || gate_enforcing "${g}"; then
        bad "${label}: the gate flipped anyway"$'\n'"${o}"
    else
        ok "${label}: blocks the flip"
    fi
}
GB=0
fx_no_manifest()   { rm -f "$1/manifest"; }
fx_module_absent() { export FX_SEMODULE_L=$'base\t1.0.0\n'; }
fx_semodule_fail() { export FX_SEMODULE_RC=1; }
fx_autorelabel()   { touch "$1/autorelabel"; }
fx_mislabel()      { export FX_RESTORECON_OUT='Would relabel /mnt/data/local-path from a to b'; }
fx_avc()           { export FX_AUSEARCH_OUT='type=AVC msg=audit(0.0:1): avc: denied { read } scontext=system_u:system_r:hugmesh_authkeys_t:s0 tcontext=system_u:object_r:etc_t:s0'; }
fx_already_enf()   { export FX_GETENFORCE=Enforcing; }
fx_selinux_off()   { export FX_SELINUX_ENABLED_RC=1; }
# A container image additionally requires the `container` module — which the
# manifest never lists, because sec-policy/selinux-container provides it.
fx_container_node() { printf '#!/sbin/openrc-run\n' > "$1/containerd-initd"; chmod +x "$1/containerd-initd"; }
# provision_selinux()'s hard postcondition failed on a selinux-aware image: it
# left /var/lib/keys-provision/selinux-load-failed behind. The gate must refuse.
fx_provision_failed() { echo "2026-08-19T00:00:00Z no policy loaded after provisioning (fixture)" > "$1/selinux-load-failed"; }
gate_blocks "check_modules: no build manifest"            fx_no_manifest
gate_blocks "check_modules: a manifest module not loaded" fx_module_absent
gate_blocks "check_modules: semodule -l fails"            fx_semodule_fail
gate_blocks "check_relabel_clean: /.autorelabel present"  fx_autorelabel
gate_blocks "check_relabel_clean: restorecon finds drift" fx_mislabel
gate_blocks "check_avc_clean: an AVC on a hugmesh domain" fx_avc
gate_blocks "check_mode_sane: already Enforcing"          fx_already_enf
gate_blocks "check_mode_sane: SELinux disabled"           fx_selinux_off
gate_blocks "check_modules: container node without the container module" fx_container_node
gate_blocks "check_provision_ok: first-boot policy load failed (marker present)" fx_provision_failed

# ── E) the first-boot loader half in provision.sh ────────────────────────────
# The .pp land in the directory provision_selinux() knows about, but its
# pre-existing load is `if ! ls /etc/selinux/<type>/policy/policy.*` around a
# `semodule -B || semodule -i .../*.pp`. `-B` rebuilds from the module STORE, and
# a freshly installed .pp is not in the store until `-i` runs — so on an image
# whose store is already built, or where -B succeeds, our modules would never
# load. The explicit block must exist and must run BEFORE the relabel.
echo "-- E) provision.sh loads the manifest modules explicitly --"
if [ -f "${PROV}" ]; then
    grep -q 'BEGIN hugmesh node-policy load' "${PROV}" \
        && ok "provision.sh carries the explicit hugmesh node-policy load block" \
        || bad "provision.sh has NO explicit load — the .pp would depend on semodule -B"
    ld_ln="$(grep -n 'BEGIN hugmesh node-policy load' "${PROV}" | head -1 | cut -d: -f1)"
    rl_ln="$(grep -n 'Relabelling filesystem' "${PROV}" | head -1 | cut -d: -f1)"
    { [ -n "${ld_ln}" ] && [ -n "${rl_ln}" ] && [ "${ld_ln}" -lt "${rl_ln}" ]; } \
        && ok "the explicit load (line ${ld_ln}) runs BEFORE the relabel (line ${rl_ln})" \
        || bad "the explicit load does not precede the relabel (load=${ld_ln:-none} relabel=${rl_ln:-none})"
    sed -n "${ld_ln},${rl_ln}p" "${PROV}" | grep -q 'selinux-modules.list' \
        && ok "the explicit load is driven by the build-time manifest, not a blind glob" \
        || bad "the explicit load does not read /usr/share/hugmesh/selinux-modules.list"
    sed -n "${ld_ln},${rl_ln}p" "${PROV}" | grep -qE 'semodule .*-i ' \
        && ok "the explicit load uses semodule -i (installs into the store)" \
        || bad "the explicit load does not call semodule -i"
    # ── the per-module visibility layer (issue #45) ───────────────────────────
    # The original block ran ONE batched `semodule -i ... 2>/dev/null || warn`,
    # so a failing module vanished: no reason, no per-module verdict, green run.
    # All four 2026-08-14 QEMU rows shipped base-policy-only nodes behind
    # exactly that warn. These assertions pin the layer that fixed it.
    blk="$(sed -n "${ld_ln},${rl_ln}p" "${PROV}")"
    # Comments are excluded: the block's own rationale QUOTES the old defective
    # spelling ("semodule -i ... 2>/dev/null || warn") and must not trip this.
    if printf '%s\n' "${blk}" | grep -v '^[[:space:]]*#' | grep -E 'semodule .*-i ' | grep -q '2>/dev/null'; then
        bad "a semodule -i in the load block still discards stderr to /dev/null — a failing module is invisible again"
    else
        printf '%s\n' "${blk}" | grep -qE 'semodule -s "\$\{type\}" -i \$\{hm_mods\} 2>"' \
            && ok "the manifest load CAPTURES semodule stderr (per-batch, into the provision log)" \
            || bad "the manifest load no longer captures semodule stderr"
    fi
    printf '%s\n' "${blk}" | grep -qE 'for hm_pp in \$\{hm_mods\}' \
        && ok "batch failure falls back to a per-module retry (isolates the offender, stderr per module)" \
        || bad "no per-module retry loop — a batch failure cannot name the offending module"
    # The WRITE itself (the > redirect), not any line that merely mentions the
    # file name — a warn string naming the path must not keep this green.
    { printf '%s\n' "${blk}" | grep -v '^[[:space:]]*#' | grep -qE '> "\$\{STATE_DIR\}/selinux-modules.status"' \
      && printf '%s\n' "${blk}" | grep -v '^[[:space:]]*#' | grep -qE 'semodule -s "\$\{type\}" -l'; } \
        && ok "per-module verdicts are derived from the STORE (semodule -l) and written machine-readably (selinux-modules.status)" \
        || bad "the machine-readable per-module status (selinux-modules.status, derived from semodule -l) is gone"
    # Non-comment lines only: the block's rationale comment NAMES the function,
    # and a grep that matches prose would survive the call being deleted.
    printf '%s\n' "${blk}" | grep -v '^[[:space:]]*#' | grep -q 'selinux_provision_failed' \
        && ok "a non-loaded manifest module records the selinux-load-failed marker (enforce-gate refuses on it)" \
        || bad "module-load failure no longer records the selinux-load-failed marker"
    # Matched pair: provision.sh writes selinux-modules.status, the QEMU
    # assertions read it. Either half alone is a silent regression.
    QASRT="${GEN}/tests/qemu/assertions.sh"
    { grep -q 'selinux-modules.status' "${PROV}" && grep -q 'selinux-modules.status' "${QASRT}" 2>/dev/null; } \
        && ok "selinux-modules.status is a matched pair (provision.sh writes, tests/qemu/assertions.sh asserts)" \
        || bad "selinux-modules.status halves diverged (provision=$(grep -c 'selinux-modules.status' "${PROV}"), assertions=$(grep -c 'selinux-modules.status' "${QASRT}" 2>/dev/null || echo 0))"
    # ── the first-boot postcondition + autorelabel semantics (issue #45 a/c) ──
    # /.autorelabel REQUESTS a relabel and is removed by whoever completes one.
    # provision_selinux() is the relabeler here, so it must CONSUME the flag on
    # success (it used to `touch` it unconditionally AFTER its own relabel, so
    # check_relabel_clean() could never pass on any provisioned node).
    grep -q 'rm -f /.autorelabel' "${PROV}" \
        && ok "a successful relabel CONSUMES /.autorelabel (standard request-flag semantics)" \
        || bad "provision.sh never clears /.autorelabel — check_relabel_clean() can never pass"
    # The hard postcondition: on a selinux-aware image, provisioning must end
    # with a policy actually loaded — defined AND called, not just defined.
    [ "$(grep -c 'selinux_policy_loaded' "${PROV}")" -ge 2 ] \
        && ok "provision.sh checks the policy-loaded postcondition (selinux_policy_loaded defined + called)" \
        || bad "provision.sh lost the selinux_policy_loaded postcondition"
    # The failure marker is a matched pair: provision.sh writes it, the
    # enforce-gate refuses on it. Either half alone is a silent regression.
    { grep -q 'selinux-load-failed' "${PROV}" && grep -q 'selinux-load-failed' "${SVC}"; } \
        && ok "selinux-load-failed marker is a matched pair (provision.sh writes, enforce-gate refuses)" \
        || bad "selinux-load-failed marker halves diverged (provision=$(grep -c 'selinux-load-failed' "${PROV}"), gate=$(grep -c 'selinux-load-failed' "${SVC}"))"
    # The build-time awareness marker is a matched pair too: the shared lib
    # writes /usr/share/hugmesh/selinux-built, provision_selinux() keys its
    # fail-open-vs-fail-visible split off it.
    { grep -q 'selinux-built' "${LIB}" && grep -q 'selinux-built' "${PROV}"; } \
        && ok "selinux-built marker is a matched pair (build lib writes, provision.sh detects)" \
        || bad "selinux-built marker halves diverged (lib=$(grep -c 'selinux-built' "${LIB}"), provision=$(grep -c 'selinux-built' "${PROV}"))"
else
    bad "provision.sh missing"; bad "(order)"; bad "(manifest-driven)"; bad "(semodule -i)"
    bad "(stderr capture)"; bad "(per-module retry)"; bad "(per-module status)"
    bad "(failure marker on non-loaded module)"; bad "(status matched pair)"
    bad "(autorelabel consumption)"; bad "(policy-loaded postcondition)"
    bad "(selinux-load-failed pair)"; bad "(selinux-built pair)"
fi

echo "== selinux-policy-install: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
