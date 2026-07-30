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
# sysroot and a FAKE refpolicy devel tree (the same technique as
# tests/build-arm-payload-gates.sh), so it can prove BEHAVIOUR, not just presence:
# all-or-nothing installs, the label-only .fc trap, the conditional k8s exemplars,
# idempotence, and — the load-bearing one — that a default image ships the
# enforce-gate INERT so it still boots PERMISSIVE.
#
# HONEST SCOPE. The fixture devel tree's Makefile runs the REAL refpolicy
# three-command recipe (m4 -> checkmodule -> semodule_package) with the host's own
# binaries, so section C-real proves a genuine .pp is produced by the genuine
# toolchain. It does NOT prove the real modules compile against real refpolicy
# headers — that needs sec-policy/selinux-base merged into a real sysroot, i.e. a
# real protected build. The real-source passes therefore drive a stub Makefile and
# prove enumeration/skip/install/manifest logic against the REAL specs/selinux set.
#
# Pure static + fake-sysroot execution. No emerge, no chroot, no network, no root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
LIB="${GEN}/scripts/_selinux-policy-lib.sh"
SVC="${GEN}/specs/etc/init.d/selinux-enforce-gate"
SRC="${GEN}/specs/selinux"

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
# The 7 modules that must compile on EVERY image (base refpolicy interfaces only)
MANDATORY=(hugmesh_authkeys hugmesh_device_registry_sync hugmesh_domain_reconcile
           hugmesh_node_storage hugmesh_policy_sync hugmesh_tor hugmesh_vpn)
# The 2 k8s exemplars the orphaned enforce-gate names BY NAME — omitting them
# would guarantee the gate can never pass.
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
grep -qF '/etc/ssh/break-glass\.keys' "${SRC}/hugmesh_authkeys.fc" \
    && ok "break-glass context line survives the fold into hugmesh_authkeys.fc" \
    || bad "break-glass context line LOST in the fold"
grep -qF '/run/user/%{uid}/hugmesh' "${SRC}/hugmesh_authkeys.fc" \
    && ok "oidc-token context line survives the fold into hugmesh_authkeys.fc" \
    || bad "oidc-token context line LOST in the fold"
for m in "${EXEMPLARS[@]}"; do
    [ -f "${SRC}/${m}.te" ] && ok "k8s exemplar ${m}.te present (the enforce-gate names it)" \
                            || bad "k8s exemplar ${m}.te MISSING — the enforce-gate could never pass"
done

# ── fixtures ─────────────────────────────────────────────────────────────────
# A fake refpolicy devel tree. STUB flavour: the Makefile fakes the .pp, so the
# real 9-module set can be enumerated without real refpolicy headers. REAL
# flavour: the Makefile runs the genuine m4 -> checkmodule -> semodule_package
# recipe with the host's own binaries.
mk_devel() {  # mk_devel <dir> <stub|real> <with-container|no-container>
    local d="$1" flavour="$2" container="$3"
    mkdir -p "${d}/include/support" "${d}/include/services"
    cat > "${d}/include/support/loadable_module.spt" <<'SPT'
define(`policy_module',`
	module $1 $2;
')
define(`gen_context',`$1')
SPT
    if [ "${container}" = "with-container" ]; then
        cat > "${d}/include/services/container.if" <<'IF'
## <summary>fixture container policy header</summary>
interface(`container_domain_template',`
	gen_require(`type container_t;')
')
IF
    fi
    if [ "${flavour}" = "stub" ]; then
        cat > "${d}/Makefile" <<'MK'
%.pp:
	@echo "BINDIR=$(BINDIR)" > $(HEADERDIR)/../compile.vars
	@echo "HEADERDIR=$(HEADERDIR)" >> $(HEADERDIR)/../compile.vars
	@printf 'fake-pp %s\n' "$*" > $@
MK
    else
        cat > "${d}/Makefile" <<'MK'
%.pp: %.te
	@echo "BINDIR=$(BINDIR)" > $(HEADERDIR)/../compile.vars
	@echo "HEADERDIR=$(HEADERDIR)" >> $(HEADERDIR)/../compile.vars
	m4 $(HEADERDIR)/support/loadable_module.spt $*.te > $*.tmp
	$(BINDIR)/checkmodule -M -m $*.tmp -o $*.mod
	$(BINDIR)/semodule_package -o $@ -m $*.mod -f $*.fc
MK
    fi
}

mk_sysroot() {  # mk_sysroot <dir> <stub|real> <with-container|no-container>
    local s="$1"
    mkdir -p "${s}/usr/share/selinux/mcs" "${s}/etc/init.d" "${s}/etc/conf.d" "${s}/etc/runlevels/default"
    : > "${s}/usr/share/selinux/mcs/base.pp"        # what selinux-base leaves behind
    mk_devel "${s}/usr/share/selinux/devel" "$2" "$3"
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

# ── C) execution against a fake sysroot ──────────────────────────────────────
echo "-- C) real lib against a fake sysroot --"

# C1/C2: real 9-module source, NO container headers -> 7 installed, 2 skipped.
S="${TMP}/c1/sysroot"; SP="${TMP}/c1/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
out="$(run_lib "${S}" "${SP}")"; rc=$?
if [ "${rc}" -eq 0 ]; then ok "no-container image: lib succeeds (rc=0)"; else bad "no-container image: rc=${rc}"$'\n'"${out}"; fi
missing=""
for m in "${MANDATORY[@]}"; do [ -f "${S}/usr/share/selinux/mcs/${m}.pp" ] || missing="${missing} ${m}"; done
[ -z "${missing}" ] && ok "all 7 mandatory .pp installed into the policy store" \
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

# C3: with container headers -> all 9.
S="${TMP}/c3/sysroot"; SP="${TMP}/c3/specs"; mk_sysroot "${S}" stub with-container; mk_specs "${SP}"
out="$(run_lib "${S}" "${SP}")"; rc=$?
n_pp="$(find "${S}/usr/share/selinux/mcs" -name '*.pp' ! -name base.pp | wc -l)"
{ [ "${rc}" -eq 0 ] && [ "${n_pp}" -eq 9 ]; } \
    && ok "container-capable image: all 9 modules installed (incl. both k8s exemplars)" \
    || bad "container-capable image: rc=${rc} installed=${n_pp} (want rc=0, 9)"$'\n'"${out}"

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
cat > "${S}/usr/share/selinux/devel/Makefile" <<'MK'
%.pp:
	@if [ "$*" = "hugmesh_vpn" ]; then echo "fixture: deliberate compile failure" >&2; exit 1; fi
	@printf 'fake-pp %s\n' "$*" > $@
MK
out="$(run_lib "${S}" "${SP}")"; rc=$?
[ "${rc}" -ne 0 ] && ok "a module that fails to compile fails the step (rc=${rc})" \
                  || bad "compile failure did NOT fail the step"
n_pp="$(find "${S}/usr/share/selinux/mcs" -name '*.pp' ! -name base.pp | wc -l)"
[ "${n_pp}" -eq 0 ] && ok "ALL-OR-NOTHING: nothing installed after a compile failure" \
                    || bad "half-populated store: ${n_pp} .pp installed despite a failure"

# C11/C12: the label-only trap.
S="${TMP}/c11/sysroot"; SP="${TMP}/c11/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
printf '/etc/ghost -- gen_context(system_u:object_r:etc_t,s0)\n' > "${SP}/selinux/ghost_label_only.fc"
out="$(run_lib "${S}" "${SP}")"; rc=$?
[ "${rc}" -ne 0 ] && ok "a label-only .fc (no .te) fails the step instead of vanishing" \
                  || bad "label-only .fc was silently ignored (rc=0)"
n_pp="$(find "${S}/usr/share/selinux/mcs" -name '*.pp' ! -name base.pp | wc -l)"
[ "${n_pp}" -eq 0 ] && ok "label-only .fc: nothing installed" || bad "label-only .fc: ${n_pp} .pp installed anyway"

# C13: the deliberate operator opt-out.
S="${TMP}/c13/sysroot"; SP="${TMP}/c13/specs"; mk_sysroot "${S}" stub with-container; mk_specs "${SP}"
out="$(HUGMESH_SELINUX_MODULES=0 run_lib "${S}" "${SP}")"; rc=$?
n_pp="$(find "${S}/usr/share/selinux/mcs" -name '*.pp' ! -name base.pp | wc -l)"
{ [ "${rc}" -eq 0 ] && [ "${n_pp}" -eq 0 ]; } \
    && ok "HUGMESH_SELINUX_MODULES=0 is a clean, loud no-op (rc=0, nothing installed)" \
    || bad "opt-out misbehaved: rc=${rc} installed=${n_pp}"

# C14: no refpolicy devel tree anywhere -> loud failure, not a silent empty store.
S="${TMP}/c14/sysroot"; SP="${TMP}/c14/specs"; mk_sysroot "${S}" stub no-container; mk_specs "${SP}"
rm -rf "${S}/usr/share/selinux/devel"
if [ -f /usr/share/selinux/devel/Makefile ]; then
    ok "SKIP devel-absent case (this host has its own /usr/share/selinux/devel)"
else
    out="$(run_lib "${S}" "${SP}")"; rc=$?
    { [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -q 'refpolicy devel tree'; } \
        && ok "missing refpolicy devel tree fails loudly with the reason" \
        || bad "missing devel tree did not fail loudly (rc=${rc})"
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
    vars="$(cat "${S}/usr/share/selinux/devel/compile.vars" 2>/dev/null)"
    printf '%s' "${vars}" | grep -q '^BINDIR=/usr/bin$' \
        && ok "compile ran with BINDIR pinned to the HOST /usr/bin (never a target binary)" \
        || bad "BINDIR was not pinned to the host: [${vars}]"
    printf '%s' "${vars}" | grep -q "^HEADERDIR=${S}/usr/share/selinux/devel/include$" \
        && ok "compile ran against the SYSROOT's refpolicy headers" \
        || bad "HEADERDIR did not point at the sysroot devel tree: [${vars}]"
else
    ok "SKIP real-toolchain compile (m4/checkmodule/semodule_package not on this host)"
    ok "SKIP BINDIR pin check (no host toolchain)"
    ok "SKIP HEADERDIR check (no host toolchain)"
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

# ── D) the enforce-gate service itself ───────────────────────────────────────
echo "-- D) specs/etc/init.d/selinux-enforce-gate --"
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
grep -q 'MODULE_MANIFEST=/usr/share/hugmesh/selinux-modules.list' "${SVC}" \
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

echo "== selinux-policy-install: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
