#!/usr/bin/env bash
# test-selinux-sysroot-labels.sh — SELinux labels are BUILD ARTIFACTS (#503).
#
# THE DEFECT. The 2026-10-30 x86 backend live ISO loaded its policy at pid 1 and
# still confined nothing: security.selinux sat on 1,124 of 159,376 squashfs
# entries (only policy-store files), 101 of 101 processes were kernel_t,
# `restorecon -RFn` wanted to change 158,282 paths, and file_contexts had 0 hugmesh
# lines. Nothing labelled the sysroot at build time, the 8 hugmesh .pp were never
# put in the store, and the only relabeler (provision_selinux) is KEYS-gated.
#
# Sections:
#   A  slx_label_gate EXECUTED against fixture trees, with getfattr stubbed on PATH
#      (CI's shell-suite containers cannot write security.* xattrs): all-correct
#      passes; 'kernel', unlabelled, unlabeled_t, wrong type, missing probe, a 98%
#      census, no getfattr all FAIL; a NUL-terminated value (what the kernel
#      returns) is read correctly; the 99% boundary passes.
#   B  slx_write_selinux_config EXECUTED: default permissive, enforcing accepted,
#      'disabled' / typos / a bad type rejected.
#   C  slx_store_install_modules + slx_label_tree EXECUTED with chroot/semodule/
#      setfiles stubbed: postconditions are read from the STORE, not exit codes.
#   D  slx_tar_label_gate EXECUTED on a real tar (user.* xattrs carry the census
#      marker; skipped LOUDLY where the filesystem refuses user xattrs).
#   E  REAL security.selinux lane: only where this process can write security.*
#      (root with CAP_SYS_ADMIN, e.g. the privileged builder container). Elsewhere
#      it SKIPS LOUDLY and the skip is not counted as a pass.
#   F  build-x86-host-stage4.sh wiring, in order: store -> config -> setfiles ->
#      probe table -> gate, before the stage4 tar; a gate at every pack hop; GRUB
#      opt-in entries appended (default=0 unchanged); no silent no-xattr tar
#      fallback on any x86 pack hop or in install-x86.sh; Makefile forwards the
#      knobs; provision.sh skips the full relabel on an overlay root.
#   G  specs/usr/libexec/live-overlay-relabel EXECUTED (restorecon stubbed): on an
#      overlay root it relabels exactly the upper layer (merged spellings) + /dev;
#      on a disk root it does nothing.
#   H  specs-x86/etc/grub.d/11_selinux_permissive_rescue EXECUTED against a stand-in
#      10_linux: one flat enforcing=0 entry per kernel, never the default; installed
#      by the builder. /var/log/wtmp + lastlog exist before the label pass.
#
# Offline, no network. bash + coreutils + findutils + awk (gawk or mawk) + GNU tar
# (+ setfattr for D, + CAP_SYS_ADMIN for E).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_selinux-policy-lib.sh"
X86="${REPO}/build-x86-host-stage4.sh"
INST="${REPO}/specs-x86/installer/install-x86.sh"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
MK="${REPO}/Makefile"
GRUBDEF="${REPO}/specs-x86/etc/default/grub"
GRUBD="${REPO}/specs-x86/etc/grub.d/11_selinux_permissive_rescue"
LRHOOK="${REPO}/specs/usr/libexec/live-overlay-relabel"

P=0; F=0; S=0
ok()   { echo "  PASS $*"; P=$((P+1)); }
bad()  { echo "  FAIL $*"; F=$((F+1)); }
skip() { echo "  SKIP $* (NOT counted as a pass)"; S=$((S+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A file with a NUL byte makes grep treat it as binary and a "no match" becomes
# indistinguishable from a real miss (grep fails OPEN). Refuse such inputs first.
for f in "${LIB}" "${X86}" "${INST}" "${PROV}" "${MK}" "${GRUBDEF}" "${GRUBD}" "${LRHOOK}"; do
    [ -f "${f}" ] || continue   # a missing file is reported by its own section
    if [ "$(tr -d '\000' < "${f}" | wc -c)" -ne "$(wc -c < "${f}")" ]; then
        bad "${f#"${REPO}"/} contains a NUL byte — every grep below would fail open on it"
    fi
done

# ── stub getfattr: labels come from ${STUB_MAP} ('<rel path><TAB><value>'), matched
# on the path SUFFIX so any extraction root works. --only-values prints the value
# NUL-terminated (as the kernel stores it); the dump form prints getfattr's format.
STUB="${TMP}/stub"; mkdir -p "${STUB}"
cat > "${STUB}/getfattr" <<'EOS'
#!/usr/bin/env bash
only=0; paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --only-values) only=1 ;;
    -n) shift ;;
    -h|--absolute-names|-d|-m) ;;
    --) shift; paths+=("$@"); break ;;
    -*) ;;
    *) paths+=("$1") ;;
  esac; shift
done
rc=0
for p in "${paths[@]}"; do
  v="$(awk -F'\t' -v p="${p}" 'length(p) >= length($1)+1 && substr(p, length(p)-length($1)) == "/" $1 {print $2; exit}' "${STUB_MAP}")"
  if [ -z "${v}" ]; then echo "${p}: security.selinux: No such attribute" >&2; rc=1; continue; fi
  if [ "${only}" = 1 ]; then printf '%s\0' "${v}"; else printf '# file: %s\nsecurity.selinux="%s"\n\n' "${p}" "${v}"; fi
done
exit "${rc}"
EOS
chmod +x "${STUB}/getfattr"

ctx() { printf 'system_u:object_r:%s:s0' "$1"; }
CORE="usr/bin/init:init_exec_t usr/bin/bash:shell_exec_t usr/bin/sshd:sshd_exec_t usr/bin/openrc:rc_exec_t etc/shadow:shadow_t etc/fstab:etc_t usr/bin/hugmesh-authorized-keys-lookup:hugmesh_authkeys_exec_t"

# mk_fixture <dir> <map> <n filler files> <n of them unlabelled>
mk_fixture() {
    local d="$1" map="$2" n="$3" un="$4" e rel i
    rm -rf "${d}"; mkdir -p "${d}"/{proc,sys,dev,run,etc,usr/bin,var/lib}
    : > "${map}"; : > "${d}.table"
    for e in ${CORE}; do
        rel="${e%%:*}"; : > "${d}/${rel}"
        printf '%s\t%s\n' "${rel}" "$(ctx "${e##*:}")" >> "${map}"
        printf '%s\t%s\n' "${rel}" "${e##*:}" >> "${d}.table"
    done
    for rel in etc usr usr/bin var var/lib; do printf '%s\t%s\n' "${rel}" "$(ctx usr_t)" >> "${map}"; done
    for i in $(seq 1 "${n}"); do
        : > "${d}/var/lib/f${i}"
        [ "${i}" -le "${un}" ] || printf '%s\t%s\n' "var/lib/f${i}" "$(ctx var_lib_t)" >> "${map}"
    done
    : > "${d}/proc/unlabelled-but-excluded"
    printf '%s\t%s\n' "." "$(ctx root_t)" >> "${map}"
}
# the root dir itself: map it by its basename suffix
fix_root_label() { printf '%s\t%s\n' "$(basename "$1")" "$(ctx root_t)" >> "$2"; }

gate() { # gate <dir> <args...> -> rc, output in ${TMP}/gate.out
    PATH="${STUB}:${PATH}" STUB_MAP="${MAP}" bash -c '. "$1"; shift; slx_label_gate "$@"' _ "${LIB}" "$@" > "${TMP}/gate.out" 2>&1
}
set_label() { # set_label <rel> <value|""> — rewrite one map line
    awk -F'\t' -v r="$1" -v v="$2" 'BEGIN{OFS="\t"} $1==r {if (v=="") next; $2=v} {print}' "${MAP}" > "${MAP}.n" && mv "${MAP}.n" "${MAP}"
}

echo "-- A) slx_label_gate, executed (stubbed getfattr) --"
FX="${TMP}/fx"; MAP="${TMP}/map"
mk_fixture "${FX}" "${MAP}" 100 0; fix_root_label "${FX}" "${MAP}"
if gate "${FX}" sysroot "${FX}.table" --census; then
    grep -q 'census 1[0-9][0-9]/1[0-9][0-9] files+dirs labelled' "${TMP}/gate.out" \
        && grep -q '/usr/bin/init system_u:object_r:init_exec_t:s0' "${TMP}/gate.out" \
        && ok "all-correct tree passes, census printed, every probe's label printed" \
        || bad "all-correct tree passed without printing the census/probe labels: $(cat "${TMP}/gate.out")"
else bad "all-correct tree FAILED the gate: $(cat "${TMP}/gate.out")"; fi
grep -q 'unlabelled-but-excluded' "${TMP}/gate.out" && bad "census looked inside proc/" || ok "census skips proc/sys/dev/run"

cp "${MAP}" "${MAP}.good"
set_label usr/bin/init kernel
gate "${FX}" sysroot "${FX}.table" && bad "literal 'kernel' on /usr/bin/init PASSED" \
    || { grep -q "literal 'kernel'" "${TMP}/gate.out" && ok "literal 'kernel' fails, and says so" || bad "kernel case failed for the wrong reason: $(cat "${TMP}/gate.out")"; }
cp "${MAP}.good" "${MAP}"; set_label usr/bin/init ""
gate "${FX}" sysroot "${FX}.table" && bad "unlabelled /usr/bin/init PASSED" \
    || { grep -q '/usr/bin/init has NO security.selinux' "${TMP}/gate.out" && ok "unlabelled /usr/bin/init fails" || bad "unlabelled case wrong reason: $(cat "${TMP}/gate.out")"; }
cp "${MAP}.good" "${MAP}"; set_label usr/bin/bash "$(ctx unlabeled_t)"
gate "${FX}" sysroot "${FX}.table" && bad "unlabeled_t PASSED" \
    || { grep -q 'unlabeled_t' "${TMP}/gate.out" && ok "unlabeled_t fails" || bad "unlabeled_t wrong reason"; }
cp "${MAP}.good" "${MAP}"; set_label etc/shadow "$(ctx etc_t)"
gate "${FX}" sysroot "${FX}.table" && bad "etc_t on /etc/shadow PASSED" \
    || { grep -q '/etc/shadow is .*want type shadow_t' "${TMP}/gate.out" && ok "wrong type on /etc/shadow fails (exact type, not 'any label')" || bad "wrong-type case wrong reason: $(cat "${TMP}/gate.out")"; }
cp "${MAP}.good" "${MAP}"; set_label usr/bin/hugmesh-authorized-keys-lookup "$(ctx bin_t)"
gate "${FX}" sysroot "${FX}.table" && bad "hugmesh entrypoint left bin_t PASSED (store install missing would look like this)" \
    || ok "hugmesh entrypoint labelled bin_t fails"
cp "${MAP}.good" "${MAP}"; mv "${FX}/etc/shadow" "${TMP}/shadow.away"
gate "${FX}" sysroot "${FX}.table" && bad "a probe missing from the carrier PASSED" || ok "a probe missing from the carrier fails"
mv "${TMP}/shadow.away" "${FX}/etc/shadow"
: > "${TMP}/empty.table"
gate "${FX}" sysroot "${TMP}/empty.table" && bad "an empty probe table PASSED" || ok "an empty probe table fails"
# NUL handling: the stub emits value\0 (as the kernel does); a reader that kept the
# NUL would compare 'init_exec_t' against a different string or warn under bash.
gate "${FX}" sysroot "${FX}.table"; rc=$?
[ "${rc}" -eq 0 ] && ! grep -qi 'null byte' "${TMP}/gate.out" \
    && ok "a NUL-terminated security.selinux value is read cleanly (no 'ignored null byte' warning)" \
    || bad "NUL-terminated value mishandled (rc=${rc}): $(cat "${TMP}/gate.out")"
# 98% census fails; 99% boundary passes (106 dirs/files total in the fixture).
mk_fixture "${FX}" "${MAP}" 200 6; fix_root_label "${FX}" "${MAP}"
tot=$(find "${FX}" -xdev \( -path "${FX}/proc" -o -path "${FX}/sys" -o -path "${FX}/dev" -o -path "${FX}/run" \) -prune -o \( -type f -o -type d \) -print | wc -l)
gate "${FX}" sysroot "${FX}.table" --census && bad "census with 6/${tot} unlabelled (<99%) PASSED" \
    || { grep -q 'below 99%' "${TMP}/gate.out" && ok "census at $(( (tot-6)*100/tot ))% (6 of ${tot} unlabelled) fails" || bad "98% case wrong reason: $(cat "${TMP}/gate.out")"; }
mk_fixture "${FX}" "${MAP}" 200 2; fix_root_label "${FX}" "${MAP}"
gate "${FX}" sysroot "${FX}.table" --census && ok "census with 2 unlabelled of ~${tot} (>=99%) passes (boundary)" || bad "99% boundary FAILED: $(cat "${TMP}/gate.out")"
gate "${FX}" sysroot "${FX}.table" && ok "probes-only gate ignores the census when --census is not passed" || bad "probes-only gate failed"
# no getfattr at all -> FAIL, never a silent pass
PATH="/nonexistent" "$(command -v bash)" -c '. "$1"; slx_label_gate "$2" t "$3"' _ "${LIB}" "${FX}" "${FX}.table" > "${TMP}/gate.out" 2>&1 \
    && bad "gate PASSED with no getfattr on PATH" || ok "gate FAILS when no getfattr is available (cannot look = cannot pass)"

echo "-- B) slx_write_selinux_config, executed --"
SR="${TMP}/sr"; mkdir -p "${SR}"
cfg() { HUGMESH_SELINUX_MODE="$1" bash -c '. "$1"; [ "$2" = __unset__ ] && unset HUGMESH_SELINUX_MODE; slx_write_selinux_config "$3" "$4"' _ "${LIB}" "$1" "${SR}" "$2" >/dev/null 2>&1; }
cfg __unset__ mcs && grep -qx 'SELINUX=permissive' "${SR}/etc/selinux/config" && grep -qx 'SELINUXTYPE=mcs' "${SR}/etc/selinux/config" \
    && grep -q '^# written at build time by _selinux-policy-lib.sh' "${SR}/etc/selinux/config" \
    && ok "default config: SELINUX=permissive SELINUXTYPE=mcs, marked as build-time" || bad "default config wrong: $(cat "${SR}/etc/selinux/config" 2>&1)"
cfg enforcing mcs && grep -qx 'SELINUX=enforcing' "${SR}/etc/selinux/config" && ok "HUGMESH_SELINUX_MODE=enforcing accepted" || bad "enforcing rejected"
for m in disabled Enforcing permissive2 ''; do
    rm -f "${SR}/etc/selinux/config"
    if [ -z "${m}" ]; then HUGMESH_SELINUX_MODE='' bash -c '. "$1"; slx_write_selinux_config "$2" mcs' _ "${LIB}" "${SR}" >/dev/null 2>&1
       grep -qx 'SELINUX=permissive' "${SR}/etc/selinux/config" 2>/dev/null && ok "empty HUGMESH_SELINUX_MODE falls back to permissive" || bad "empty mode did not fall back to permissive"
       continue; fi
    cfg "${m}" mcs && bad "mode '${m}' was ACCEPTED" || { [ ! -e "${SR}/etc/selinux/config" ] && ok "mode '${m}' rejected, nothing written" || bad "mode '${m}' rejected but a config was written"; }
done
cfg permissive 'mcs;rm' && bad "a bad SELINUXTYPE was accepted" || ok "a bad SELINUXTYPE is rejected"

echo "-- C) store install + label tree, executed (stubbed chroot/semodule/setfiles) --"
mk_sysroot() {
    local r="$1"; rm -rf "${r}"
    mkdir -p "${r}/usr/share/hugmesh" "${r}/usr/share/selinux/mcs" "${r}/etc/selinux/mcs/policy" "${r}/etc/selinux/mcs/contexts/files" "${r}/store" "${r}/usr/sbin"
    printf '# header\nhugmesh_authkeys\nhugmesh_vpn\n# skipped: hugmesh_tor\n' > "${r}/usr/share/hugmesh/selinux-modules.list"
    : > "${r}/usr/share/selinux/mcs/hugmesh_authkeys.pp"; : > "${r}/usr/share/selinux/mcs/hugmesh_vpn.pp"
    printf 'base-policy-bytes\n' > "${r}/etc/selinux/mcs/policy/policy.35"
    printf '/usr/bin(/.*)?\tsystem_u:object_r:bin_t:s0\n' > "${r}/etc/selinux/mcs/contexts/files/file_contexts"
    printf '#!/bin/sh\n' > "${r}/usr/sbin/setfiles"; chmod +x "${r}/usr/sbin/setfiles"
}
# The stubs act on the sysroot the way the real tools would, controlled by MODE:
#   good     install records each module, appends hugmesh_ to the policy + fc
#   lie      semodule -i exits 0 and installs NOTHING
#   batchbad batched -i fails, per-module -i works
#   nofc     installs but file_contexts never gains hugmesh lines
#   nopol    installs but the compiled policy has no hugmesh_ symbol
cat > "${STUB}/c-stubs.sh" <<'EOS'
chroot() { local r="$1"; shift; SR_ROOT="${r}" "$@"; }
semodule() {
  local args=("$@") i=0 a pps=()
  case " $* " in *" -l "*) cat "${SR_ROOT}/store/list" 2>/dev/null; return 0 ;; esac
  for a in "${args[@]}"; do case "${a}" in *.pp) pps+=("${a}") ;; esac; done
  [ "${MODE}" = batchbad ] && [ "${#pps[@]}" -gt 1 ] && { echo "batch boom" >&2; return 1; }
  [ "${MODE}" = lie ] && return 0
  for a in "${pps[@]}"; do a="${a##*/}"; echo "${a%.pp}" >> "${SR_ROOT}/store/list"; done
  [ "${MODE}" = nopol ] || echo "hugmesh_authkeys_t" >> "${SR_ROOT}/etc/selinux/mcs/policy/policy.35"
  [ "${MODE}" = nofc ] || printf '/usr/bin/hugmesh-x\t--\tsystem_u:object_r:hugmesh_authkeys_exec_t:s0\n' >> "${SR_ROOT}/etc/selinux/mcs/contexts/files/file_contexts"
  return 0
}
setfiles() {
  echo "setfiles $*" >> "${SR_ROOT}/setfiles.calls"
  case " $* " in *" -n "*) local i; for i in $(seq 1 "${DRY:-0}"); do echo "Relabeled /x${i} from a to b"; done; return "${DRYRC:-0}" ;; esac
  return "${SETFILES_RC:-0}"
}
EOS
SR="${TMP}/srC"
store() { # store <MODE> -> rc
    mk_sysroot "${SR}"
    MODE="$1" bash -c '. "$1"; . "$2"; slx_store_install_modules "$3" mcs chroot' _ "${LIB}" "${STUB}/c-stubs.sh" "${SR}" > "${TMP}/c.out" 2>&1
}
store good && grep -qx 'hugmesh_authkeys loaded' "${SR}/usr/share/hugmesh/selinux-modules.build-status" && grep -qx 'hugmesh_vpn loaded' "${SR}/usr/share/hugmesh/selinux-modules.build-status" \
    && ! grep -q hugmesh_tor "${SR}/usr/share/hugmesh/selinux-modules.build-status" \
    && ok "store install: every manifest module installed, build-status '<module> loaded', comment lines skipped" || bad "store install good path: $(cat "${TMP}/c.out")"
store lie && bad "semodule exit 0 with NOTHING installed PASSED (exit code trusted over the store)" \
    || { grep -qx 'hugmesh_vpn failed' "${SR}/usr/share/hugmesh/selinux-modules.build-status" && ok "semodule that lies (rc=0, nothing in the store) fails, status says 'failed'" || bad "lie case: $(cat "${TMP}/c.out")"; }
store batchbad && grep -q 'retrying per module' "${TMP}/c.out" && ok "batched failure retries per module and then passes from the store" || bad "batchbad: $(cat "${TMP}/c.out")"
store nofc && bad "store install with NO hugmesh file_contexts lines PASSED" || ok "no hugmesh lines in file_contexts after install fails"
store nopol && bad "store install with NO hugmesh_ symbol in policy.N PASSED" || ok "no hugmesh_ symbol in the compiled policy fails"
mk_sysroot "${SR}"; : > "${SR}/etc/selinux/mcs/policy/policy.34"
MODE=good bash -c '. "$1"; . "$2"; slx_store_install_modules "$3" mcs chroot' _ "${LIB}" "${STUB}/c-stubs.sh" "${SR}" >/dev/null 2>&1 \
    && bad "two policy.* files PASSED" || ok "two policy.* files in the store fail (exactly one is required)"
mk_sysroot "${SR}"; rm "${SR}/usr/share/selinux/mcs/hugmesh_vpn.pp"
MODE=good bash -c '. "$1"; . "$2"; slx_store_install_modules "$3" mcs chroot' _ "${LIB}" "${STUB}/c-stubs.sh" "${SR}" >/dev/null 2>&1 \
    && bad "a manifest module with no .pp PASSED" || ok "a manifest module with no .pp fails"
label() { # label <DRY> <SETFILES_RC> [<DRYRC>]
    mk_sysroot "${SR}"
    DRY="$1" SETFILES_RC="$2" DRYRC="${3:-0}" bash -c '. "$1"; . "$2"; slx_label_tree "$3" mcs' _ "${LIB}" "${STUB}/c-stubs.sh" "${SR}" > "${TMP}/c.out" 2>&1
}
label 0 0 && grep -q -- '^setfiles -m -F -c /etc/selinux/mcs/policy/policy.35 -e /proc -e /sys -e /dev -e /run /etc/selinux/mcs/contexts/files/file_contexts /$' "${SR}/setfiles.calls" \
    && ok "label: in-chroot setfiles -m -F -c policy.35 with root-relative excludes (the Step 0 argv)" || bad "label argv: $(cat "${SR}/setfiles.calls" 2>&1) $(cat "${TMP}/c.out")"
grep -q '^setfiles -n -v' "${SR}/setfiles.calls" && ok "label: a dry run is the postcondition" || bad "label: no dry-run postcondition"
label 49 0 && ok "label: 49 remaining changes pass (< 50)" || bad "label: 49 remaining failed"
label 50 0 && bad "label: 50 remaining changes PASSED" || ok "label: 50 remaining changes fail (setfiles no-op'd)"
label 0 1 && bad "label: setfiles rc=1 PASSED" || ok "label: a failing setfiles fails"
# The dry run is a postcondition only if it can fail: one that errors out prints no
# "Relabeled" line, and counting that silence as "0 remaining" passed (audit 11-04).
label 0 0 1 && bad "label: a dry run that ERRORED (rc=1, no output) PASSED as '0 remaining'" \
    || { grep -q 'dry-run postcondition .* itself failed' "${TMP}/c.out" && ok "label: a failing dry run fails the label pass (cannot count = cannot pass)" || bad "label: failing dry run, wrong reason: $(cat "${TMP}/c.out")"; }
mk_sysroot "${SR}"; rm -f "${SR}/usr/sbin/setfiles"
DRY=0 bash -c '. "$1"; . "$2"; slx_label_tree "$3" mcs' _ "${LIB}" "${STUB}/c-stubs.sh" "${SR}" >/dev/null 2>&1 \
    && bad "label with no setfiles in the sysroot PASSED" || ok "label: no setfiles inside the sysroot fails (never falls back to the host)"
grep -vE '^[[:space:]]*#' "${LIB}" | grep -E '\brestorecon\b' >/dev/null \
    && bad "the lib runs restorecon (keys on is_selinux_enabled(), no-ops on the build host)" || ok "the lib never runs restorecon on the build host"
grep -vE '^[[:space:]]*#' "${LIB}" | awk '/^slx_label_tree\(\)|^slx_store_install_modules\(\)|^slx_label_gate\(\)/{f=1} f&&/^}/{f=0} f' | grep -E '\btrap\b' >/dev/null \
    && bad "a label function arms a trap (it would replace the live pack's live_fstab_restore EXIT trap)" || ok "no label function arms a trap"

echo "-- D) slx_tar_label_gate on a real tar --"
TD="${TMP}/tarsrc"; mkdir -p "${TD}"
if command -v setfattr >/dev/null && : > "${TD}/probe" && setfattr -n user.t -v 1 "${TD}/probe" 2>/dev/null; then
    rm -f "${TD}/probe"
    mk_fixture "${TD}" "${MAP}" 50 0; fix_root_label "${TD}" "${MAP}"
    while read -r f; do setfattr -h -n user.t -v 1 "${f}"; done < <(find "${TD}" \( -type f -o -type d \))
    tar -C "${TD}" --xattrs --xattrs-include='*' -cf "${TMP}/good.tar.xz" .   # uncompressed: CI images may lack xz
    # CI cannot write security.*, so this lane names user.t as the census attribute.
    SLX_TAR_CENSUS_XATTR=user.t PATH="${STUB}:${PATH}" STUB_MAP="${MAP}" bash -c '. "$1"; slx_tar_label_gate "$2" stage4 "$3"' _ "${LIB}" "${TMP}/good.tar.xz" "${TD}.table" > "${TMP}/t.out" 2>&1 \
        && grep -q 'archive census [0-9]*/[0-9]* files+dirs carry user.t' "${TMP}/t.out" && ok "stage4 gate: xattr tarball passes (probes extracted, census by attribute name from tar -tvv)" || bad "stage4 good: $(cat "${TMP}/t.out")"
    # The SAME tarball under the shipped default (security.selinux): every entry has
    # an xattr, none has a label. A '*'-marker census passed this (audit 11-04).
    PATH="${STUB}:${PATH}" STUB_MAP="${MAP}" bash -c 'unset SLX_TAR_CENSUS_XATTR; . "$1"; slx_tar_label_gate "$2" stage4 "$3"' _ "${LIB}" "${TMP}/good.tar.xz" "${TD}.table" > "${TMP}/t.out" 2>&1 \
        && bad "stage4 gate PASSED a tarball whose entries carry xattrs but NO security.selinux" \
        || { grep -q 'archive census 0/[0-9]* files+dirs carry security.selinux' "${TMP}/t.out" && ok "stage4 gate: xattrs that are not security.selinux count for nothing (census 0)" || bad "other-xattr tar, wrong reason: $(cat "${TMP}/t.out")"; }
    tar -C "${TD}" -cf "${TMP}/bare.tar.xz" .
    SLX_TAR_CENSUS_XATTR=user.t PATH="${STUB}:${PATH}" STUB_MAP="${MAP}" bash -c '. "$1"; slx_tar_label_gate "$2" stage4 "$3"' _ "${LIB}" "${TMP}/bare.tar.xz" "${TD}.table" > "${TMP}/t.out" 2>&1 \
        && bad "stage4 gate PASSED a tarball packed WITHOUT --xattrs" || { grep -q 'archive census 0/' "${TMP}/t.out" && ok "stage4 gate fails a tarball packed without xattrs (census 0)" || bad "bare tar wrong reason: $(cat "${TMP}/t.out")"; }
else
    skip "D: this filesystem refuses user.* xattrs (or no setfattr) — the tar census case did not run"
fi

echo "-- E) REAL security.selinux lane --"
RD="${TMP}/real"; mkdir -p "${RD}"; : > "${RD}/x"
if command -v setfattr >/dev/null && command -v getfattr >/dev/null && setfattr -n security.selinux -v "$(ctx etc_t)" "${RD}/x" 2>/dev/null; then
    mk_fixture "${RD}" "${MAP}" 20 0; fix_root_label "${RD}" "${MAP}"
    while IFS=$'\t' read -r rel v; do
        if [ "${rel}" = "$(basename "${RD}")" ]; then setfattr -h -n security.selinux -v "${v}" "${RD}"; continue; fi
        [ -e "${RD}/${rel}" ] && setfattr -h -n security.selinux -v "${v}" "${RD}/${rel}"
    done < "${MAP}"
    bash -c '. "$1"; slx_label_gate "$2" real "$3" --census' _ "${LIB}" "${RD}" "${RD}.table" > "${TMP}/r.out" 2>&1 \
        && ok "REAL xattrs: all-correct fixture passes" || bad "REAL all-correct failed: $(cat "${TMP}/r.out")"
    setfattr -h -n security.selinux -v kernel "${RD}/usr/bin/init"
    bash -c '. "$1"; slx_label_gate "$2" real "$3"' _ "${LIB}" "${RD}" "${RD}.table" >/dev/null 2>&1 && bad "REAL 'kernel' PASSED" || ok "REAL xattrs: 'kernel' on /usr/bin/init fails"
    setfattr -h -x security.selinux "${RD}/usr/bin/init"
    bash -c '. "$1"; slx_label_gate "$2" real "$3"' _ "${LIB}" "${RD}" "${RD}.table" >/dev/null 2>&1 && bad "REAL unlabelled PASSED" || ok "REAL xattrs: unlabelled /usr/bin/init fails"
    setfattr -h -n security.selinux -v "$(ctx etc_t)" "${RD}/etc/shadow"; setfattr -h -n security.selinux -v "$(ctx init_exec_t)" "${RD}/usr/bin/init"
    bash -c '. "$1"; slx_label_gate "$2" real "$3"' _ "${LIB}" "${RD}" "${RD}.table" >/dev/null 2>&1 && bad "REAL wrong type PASSED" || ok "REAL xattrs: etc_t on /etc/shadow fails"
else
    skip "E: cannot write security.* xattrs here (needs CAP_SYS_ADMIN; run inside the privileged hugmesh-builder container) — the real-xattr cases did not run"
fi

echo "-- F) build-x86-host-stage4.sh wiring --"
NC="${TMP}/x86.nc"; grep -nvE '^[[:space:]]*#' "${X86}" > "${NC}"   # 'N:code' with comment lines dropped
ln_of() { { grep -E -m1 -- "$1" "${NC}" || true; } | cut -d: -f1; }   # first matching line number, '' if none
l_unq="$(ln_of 'pcs_unquiet_sendfile_noise "\$\{SYSROOT\}"')"
l_rmp="$(ln_of 'rm -f "\$\{SYSROOT\}/tmp/hugmesh-patch-portage-file-copy.py"')"
l_sto="$(ln_of 'slx_store_install_modules "\$\{SYSROOT\}"')"
l_cfg="$(ln_of 'slx_write_selinux_config "\$\{SYSROOT\}"')"
l_lab="$(ln_of 'slx_label_tree "\$\{SYSROOT\}" "\$\{SLX_TYPE\}" \\$')"
l_tab="$(ln_of 'slx_write_probe_table "\$\{SYSROOT\}"')"
l_gat="$(ln_of 'slx_label_gate "\$\{SYSROOT\}" sysroot .*--census')"
l_ban="$(ln_of 'banner "Packaging stage4 tarball"')"
l_s4="$(ln_of 'xz -T0 -6 > "\$\{STAGE4\}"')"
l_s4g="$(ln_of 'slx_tar_label_gate "\$\{STAGE4\}" stage4')"
if [ -n "${l_unq}" ] && [ -n "${l_rmp}" ] && [ -n "${l_sto}" ] && [ -n "${l_cfg}" ] && [ -n "${l_lab}" ] && [ -n "${l_tab}" ] && [ -n "${l_gat}" ] && [ -n "${l_ban}" ] \
   && [ "${l_unq}" -lt "${l_rmp}" ] && [ "${l_rmp}" -lt "${l_sto}" ] && [ "${l_sto}" -lt "${l_cfg}" ] && [ "${l_cfg}" -lt "${l_lab}" ] \
   && [ "${l_lab}" -lt "${l_tab}" ] && [ "${l_tab}" -lt "${l_gat}" ] && [ "${l_gat}" -lt "${l_ban}" ]; then
    ok "B1: sendfile revert -> patcher rm -> store install -> config -> setfiles -> probe table -> gate(--census) -> stage4 banner (lines ${l_unq}..${l_ban})"
else
    bad "B1 order broken (unquiet=${l_unq:-?} rm=${l_rmp:-?} store=${l_sto:-?} config=${l_cfg:-?} label=${l_lab:-?} table=${l_tab:-?} gate=${l_gat:-?} banner=${l_ban:-?}) — file_contexts only gains the hugmesh rules after the store install"
fi
# the B1 chain must be one && chain ending in an exit 1
awk -v a="${l_sto}" -v b="$((l_gat+1))" 'NR>=a && NR<=b' "${X86}" | grep -c 'exit 1' | grep -x 1 >/dev/null \
    && ok "B1 chain ends in one fatal '|| { err ...; exit 1; }'" || bad "B1 chain is not fatal"
s4="$(awk -F: -v l="${l_s4}" '$1>=l-4 && $1<=l {sub(/^[0-9]+:/, ""); print}' "${NC}")"
grep -q -- "--xattrs --xattrs-include='\*\.\*'" <<<"${s4}" && ! grep -q '2>/dev/null' <<<"${s4}" \
    && ok "B2: the stage4 tar is ONE xattr tar with no stderr discard" || bad "B2: stage4 tar lost --xattrs or discards stderr: ${s4}"
awk -F: -v a="${l_s4}" '$1>a && $1<a+4' "${NC}" | grep '^[0-9]*:  || tar' >/dev/null && bad "B2: a no-xattr '|| tar' fallback follows the stage4 tar" || ok "B2: no fallback tar after the stage4 tar"
[ -n "${l_s4g}" ] && [ "${l_s4g}" -gt "${l_s4}" ] && ok "B2: slx_tar_label_gate reads the stage4 back" || bad "B2: no stage4 label gate after the tar"
l_img_ex="$(ln_of 'tar -C "\$\{root_mnt\}" --xattrs --xattrs-include=.*-xpf "\$\{STAGE4\}"')"
l_grubcfg="$(ln_of '\} > "\$\{root_mnt\}/boot/grub/grub.cfg"')"
l_growfs="$(ln_of 'write_growfs_conf "\$\{root_mnt\}/boot/efi/growfs.conf"')"
l_imglab="$(ln_of 'slx_label_tree "\$\{root_mnt\}" "\$\{SLX_TYPE\}" boot/efi')"
l_imggat="$(ln_of 'slx_label_gate "\$\{root_mnt\}" img .*--census --exclude boot/efi')"
l_fstar="$(ln_of 'tar -C "\$\{root_mnt\}" --xattrs --xattrs-include=.*-cpf - \.')"
l_umnt="$(ln_of '^[0-9]+:    umount "\$\{root_mnt\}"$')"
if [ -n "${l_img_ex}" ] && [ -n "${l_imglab}" ] && [ -n "${l_imggat}" ] && [ -n "${l_fstar}" ] && [ -n "${l_umnt}" ] \
   && [ "${l_grubcfg}" -lt "${l_imglab}" ] && [ "${l_growfs}" -lt "${l_imglab}" ] && [ "${l_imglab}" -lt "${l_imggat}" ] \
   && [ "${l_imggat}" -lt "${l_fstar}" ] && [ "${l_fstar}" -lt "${l_umnt}" ]; then
    ok "B3: .img extract keeps xattrs; relabel + gate AFTER grub.cfg/growfs writes, BEFORE fs.tar and the umount"
else
    bad "B3 order broken (extract=${l_img_ex:-?} grub.cfg=${l_grubcfg:-?} growfs=${l_growfs:-?} label=${l_imglab:-?} gate=${l_imggat:-?} fs.tar=${l_fstar:-?} umount=${l_umnt:-?})"
fi
l_ldr="$(ln_of '--kver "\$\{KVER\}" /boot/initramfs-live.img')"
l_llab="$({ grep -E -- 'slx_label_tree "\$\{SYSROOT\}" "\$\{SLX_TYPE\}"' "${NC}" || true; } | cut -d: -f1 | awk -v d="${l_ldr:-0}" '$1>d {print; exit}')"
l_mksq="$(ln_of 'mksquashfs "\$\{SYSROOT\}" "\$\{ISO_DIR\}/LiveOS/squashfs.img"')"
l_t2s="$(ln_of 'tar2sqfs -q')"
l_lrg="$(ln_of 'live_root_gate "\$\{ISO_DIR\}/LiveOS/squashfs.img"')"
l_llg="$(ln_of 'live_label_gate "\$\{ISO_DIR\}/LiveOS/squashfs.img"')"
if [ -n "${l_ldr}" ] && [ -n "${l_llab}" ] && [ -n "${l_mksq}" ] && [ -n "${l_llg}" ] \
   && [ "${l_ldr}" -lt "${l_llab}" ] && [ "${l_llab}" -lt "${l_mksq}" ] && [ "${l_llab}" -lt "${l_t2s}" ] && [ "${l_lrg}" -lt "${l_llg}" ]; then
    ok "B4/B5: live relabel after the live dracut, before both squash paths; live_label_gate after live_root_gate"
else
    bad "B4/B5 order broken (dracut=${l_ldr:-?} relabel=${l_llab:-?} mksquashfs=${l_mksq:-?} tar2sqfs=${l_t2s:-?} root_gate=${l_lrg:-?} label_gate=${l_llg:-?})"
fi
awk -F: -v l="${l_mksq}" '$1>=l && $1<=l+2' "${NC}" | grep -- '-no-xattrs\|-no-xattr' >/dev/null \
    && bad "B5: mksquashfs is told -no-xattrs" || ok "B5: mksquashfs keeps xattrs (no -no-xattrs)"
awk -F: -v l="${l_t2s}" '$1>=l-3 && $1<=l' "${NC}" | grep -- "--xattrs --xattrs-include='\*\.\*'" >/dev/null \
    && ok "B5: the tar2sqfs fallback's tar carries --xattrs" || bad "B5: tar2sqfs fallback tar lost --xattrs"
llg_body="$(awk '/^live_label_gate\(\) \{/{f=1} f{print} f&&/^}/{exit}' "${X86}" | grep -vE '^[[:space:]]*#')"
[ -n "${llg_body}" ] && ! grep -q 'return 0' <<<"${llg_body}" && grep -q 'slx_label_gate .*--census' <<<"${llg_body}" \
    && grep -q 'command -v unsquashfs' <<<"${llg_body}" \
    && ok "B5: live_label_gate reads the packed image, censuses it, and has no 'cannot look, return 0' branch" \
    || bad "B5: live_label_gate missing, lacks the census, or can return 0 without looking"
# B6: GRUB opt-in entries, appended; default and cmdline unchanged
live_menu="$(awk '/_LBASE="root=live:CDLABEL=/{f=1} f{print} f&&/> "\$\{ISO_DIR\}\/boot\/grub\/grub.cfg"/{exit}' "${X86}")"
grep -q 'set default=0' <<<"${live_menu}" && ok "B6: live menu default=0 unchanged" || bad "B6: live menu default changed"
first_entry="$(grep -m1 'menuentry' <<<"${live_menu}")"
grep -q 'enforcing=' <<<"$(awk '/menuentry/{n++} n==1' <<<"${live_menu}")" && bad "B6: the DEFAULT live entry carries enforcing=" || ok "B6: the default live entry (${first_entry#*echo }) carries no enforcing="
n_enf="$(grep -c 'enforcing=1' <<<"${live_menu}")"; n_res="$(grep -c 'enforcing=0' <<<"${live_menu}")"
grep -q 'SELinux enforcing (test)' <<<"${live_menu}" && grep -q 'SELinux permissive rescue' <<<"${live_menu}" && [ "${n_enf}" = 1 ] && [ "${n_res}" = 1 ] \
    && ok "B6: live menu has exactly one 'SELinux enforcing (test)' (enforcing=1) and one 'permissive rescue' (enforcing=0)" || bad "B6: live opt-in entries missing (enforcing=1 x${n_enf}, enforcing=0 x${n_res})"
img_menu="$(awk '/^    mkdir -p "\$\{root_mnt\}\/boot\/grub"$/{f=1} f{print} f&&/> "\$\{root_mnt\}\/boot\/grub\/grub.cfg"/{exit}' "${X86}")"
grep -q 'set default=0' <<<"${img_menu}" && grep -q 'SELinux permissive rescue' <<<"${img_menu}" && [ "$(grep -c 'enforcing=0' <<<"${img_menu}")" = 1 ] \
    && ok "B6: .img grub.cfg keeps default=0 and appends one permissive rescue entry" || bad "B6: .img rescue entry missing or default changed"
grep -vE '^[[:space:]]*#' "${GRUBDEF}" | grep 'enforcing=' >/dev/null && bad "B6: specs-x86/etc/default/grub now forces enforcing=" || ok "B6: specs-x86/etc/default/grub carries no enforcing= (default stays permissive)"
# B7: the false "UNLABELED at pack time" comment is gone
grep -q 'sysroot is UNLABELED at pack time' "${X86}" && bad "B7: builder still claims the sysroot is unlabelled at pack time" || ok "B7: builder comment no longer claims an unlabelled pack"

# ── the silent no-xattr fallback guard (x86 pack hops + install-x86.sh) ──
# Pattern: an xattr tar whose stderr is discarded and which falls back on failure.
# SCOPE: the x86 builder and install-x86.sh. The x86 STAGE3 seed extract is exempt
# BY NAME: it runs before the B1 setfiles pass, which relabels every path, so a
# stage3 that lost its xattrs costs nothing. The ARM builders/installers still carry
# the same fallback (no build-time labelling there yet — the host semodule runner in the
# lib is the ARM follow-up); the file count is printed, not hidden.
hits="$(grep -nE -- "--xattrs-include[^|]*2>/dev/null" "${X86}" "${INST}" | grep -v 'STAGE3_LOCAL' | wc -l)"
[ "${hits}" -eq 0 ] && ok "no '--xattrs-include ... 2>/dev/null ||' fallback on any x86 pack hop or in install-x86.sh" \
    || bad "${hits} silent no-xattr tar fallback(s): $(grep -nE -- "--xattrs-include[^|]*2>/dev/null" "${X86}" "${INST}" | grep -v STAGE3_LOCAL)"
s3="$(grep -cE -- "--xattrs-include[^|]*2>/dev/null" "${X86}")"
[ "${s3}" -eq 1 ] && ok "exactly one exempt hit in the x86 builder (the stage3 seed extract)" || bad "x86 builder has ${s3} xattr-tar-with-2>/dev/null lines, expected exactly the 1 exempt stage3 extract"
arm="$(cd "${REPO}" && grep -lE -- "--xattrs-include[^|]*2>/dev/null" build-*.sh specs-*/installer/*.sh 2>/dev/null | grep -vc -e build-x86-host-stage4.sh -e install-x86.sh)"
echo "  INFO ARM builders/installers still carrying the fallback: ${arm} file(s) (out of scope for the x86 PR)"
inst_calls="$(grep -c '^    extract_stage4_labelled /mnt/sdhost$' "${INST}")"
[ "${inst_calls}" = 2 ] && grep -q '\*:init_exec_t:\*)' "${INST}" \
    && ok "install-x86.sh: both install paths extract via extract_stage4_labelled, which aborts unless /usr/bin/init is init_exec_t" \
    || bad "install-x86.sh: ${inst_calls}/2 paths use extract_stage4_labelled or the init_exec_t check is gone"
grep -nvE '^[[:space:]]*#' "${INST}" | grep -E -- '-xJf "\$\{STAGE4\}"' | grep -v -- '--xattrs --xattrs-include' >/dev/null \
    && bad "install-x86.sh still extracts the stage4 without --xattrs somewhere" || ok "install-x86.sh: every stage4 extract carries --xattrs"
# Makefile forwards the knobs into the builder container (D4)
dr="$(awk '/^DOCKER_RUN := /{f=1} f{print} f&&!/\\$/{exit}' "${MK}")"
miss=""; for v in HUGMESH_SELINUX_MODE HUGMESH_SELINUX_MODULES HUGMESH_SELINUX_TYPE HUGMESH_SELINUX_ENFORCE_GATE; do grep -q -- "-e ${v}\b" <<<"${dr}" || miss="${miss} ${v}"; done
[ -z "${miss}" ] && ok "Makefile DOCKER_RUN forwards all four HUGMESH_SELINUX_* knobs" || bad "Makefile DOCKER_RUN does not forward:${miss}"
# provision.sh: overlay root skips the full walk, the #152 probe still runs after it
pb="$(awk '/^provision_selinux\(\) \{/{f=1} f{print} f&&/^}/{exit}' "${PROV}" | grep -vE '^[[:space:]]*#')"
l_ov="$(grep -n 'findmnt -no FSTYPE / .*= overlay' <<<"${pb}" | head -1 | cut -d: -f1)"
l_rc="$(grep -n 'restorecon -RF /' <<<"${pb}" | head -1 | cut -d: -f1)"
l_pr="$(grep -n 'restorecon -nv "\${_relabel_probe}"' <<<"${pb}" | head -1 | cut -d: -f1)"
[ -n "${l_ov}" ] && [ -n "${l_rc}" ] && [ -n "${l_pr}" ] && [ "${l_ov}" -lt "${l_rc}" ] && [ "${l_rc}" -lt "${l_pr}" ] \
    && ok "provision.sh: an overlay root skips 'restorecon -RF /' (copy-up storm) and still runs the #152 probe postcondition" \
    || bad "provision.sh overlay skip missing or misplaced (overlay=${l_ov:-?} restorecon=${l_rc:-?} probe=${l_pr:-?})"

echo "-- G) live overlay relabel hook, executed --"
HOOK="${REPO}/specs/usr/libexec/live-overlay-relabel"
if [ ! -x "${HOOK}" ]; then
    bad "specs/usr/libexec/live-overlay-relabel is missing or not executable"
else
    HK="${TMP}/hook"; mkdir -p "${HK}/bin" "${HK}/upper/etc/selinux" "${HK}/upper/usr/libexec"
    : > "${HK}/upper/etc/inittab"
    printf '#!/bin/sh\necho "$*" >> "%s/called"\n' "${HK}" > "${HK}/bin/restorecon"; chmod +x "${HK}/bin/restorecon"
    run_hook() { # run_hook <mounts file> -> ${HK}/called
        rm -f "${HK}/called"
        # the hook's PATH puts /usr/sbin first; a restorecon stub must win, so run a copy with the stub dir prepended
        sed "s|^PATH=/usr/sbin|PATH=${HK}/bin:/usr/sbin|" "${HOOK}" > "${HK}/hook.sh"
        PROC_MOUNTS="$1" sh "${HK}/hook.sh" >/dev/null 2>&1
    }
    printf 'LiveOS_rootfs / overlay rw,seclabel,relatime,lowerdir=/run/rootfsbase,upperdir=%s/upper,workdir=/run/ovlwork,uuid=on 0 0\n' "${HK}" > "${HK}/m.overlay"
    printf '/dev/sda2 / ext4 rw,seclabel,relatime 0 0\n' > "${HK}/m.disk"
    run_hook "${HK}/m.overlay"
    called="$(tr '\n' ' ' < "${HK}/called" 2>/dev/null)"
    case " ${called} " in *" -RFx /dev "*) ok "hook: relabels /dev without crossing into its submounts" ;; *) bad "hook: no 'restorecon -RFx /dev' (got: ${called})" ;; esac
    grep -E -- '^-F ' "${HK}/called" 2>/dev/null > "${HK}/up"
    for w in / /etc /etc/inittab /etc/selinux /usr /usr/libexec; do
        grep -- " ${w}\( \|\$\)" "${HK}/up" >/dev/null && ok "hook: relabels upper-layer path ${w} (merged-path spelling)" || bad "hook: did not relabel ${w} (got: $(cat "${HK}/up"))"
    done
    grep -- "${HK}/upper" "${HK}/up" >/dev/null && bad "hook: passed an UPPER path to restorecon, not the merged path" || ok "hook: never passes the raw upper path to restorecon"
    run_hook "${HK}/m.disk"
    [ ! -e "${HK}/called" ] && ok "hook: a disk root is a no-op" || bad "hook: ran restorecon on a disk root: $(cat "${HK}/called")"
    grep -vE '^[[:space:]]*#' "${HOOK}" | grep -- '-R[^ ]* /\( \|$\)' >/dev/null && bad "hook: a recursive walk of / (copy-up storm)" || ok "hook: no recursive walk of / (it only touches the upper layer)"
    grep -i hugmesh "${HOOK}" >/dev/null && bad "hook carries the brand name (it ships on unaffiliated images too)" || ok "hook: brand-neutral"
fi
l_lrinst="$(ln_of 'install -D -m 0755 "\$\{SHARED_SPECS\}/usr/libexec/live-overlay-relabel"')"
l_lrsed="$(ln_of "sed -i 's\\\|\\^si::sysinit:\\\|lr::sysinit:/usr/libexec/live-overlay-relabel")"
{ [ -n "${l_lrinst}" ] && [ -n "${l_lrsed}" ] && [ "${l_lrinst}" -lt "${l_sto}" ] && [ "${l_lrsed}" -lt "${l_sto}" ]; } \
    && ok "builder installs the hook and puts it before OpenRC's sysinit line, before the label pass labels both" \
    || bad "builder wiring for live-overlay-relabel missing (install=${l_lrinst:-?} inittab=${l_lrsed:-?} store=${l_sto:-?})"

echo "-- H) grub-mkconfig rescue snippet (EXECUTED against a stand-in 10_linux) + login records --"
GD="${REPO}/specs-x86/etc/grub.d/11_selinux_permissive_rescue"
if [ ! -x "${GD}" ]; then
    bad "specs-x86/etc/grub.d/11_selinux_permissive_rescue is missing or not executable"
else
    GT="${TMP}/grubd"; mkdir -p "${GT}"; cp "${GD}" "${GT}/"
    # Stand-in for the image's 10_linux: honours the same variables the real one reads
    # (submenu, recovery, savedefault, both cmdline halves) and prints its stderr chatter.
    cat > "${GT}/10_linux" <<'EOS'
#!/bin/sh
echo "Found linux image: /boot/vmlinuz-6.18.52-gentoo" >&2
for k in 6.18.52-gentoo 6.18.51-gentoo; do
  if [ "${GRUB_DISABLE_SUBMENU}" != true ] && [ "${k}" = 6.18.52-gentoo ]; then
    echo "menuentry 'Gentoo GNU/Linux' --class os \$menuentry_id_option 'gnulinux-simple-abc' {"
    echo "	linux /boot/vmlinuz-${k} root=UUID=abc ro ${GRUB_CMDLINE_LINUX} ${GRUB_CMDLINE_LINUX_DEFAULT}"; echo "}"
    echo "submenu 'Advanced options for Gentoo GNU/Linux' \$menuentry_id_option 'gnulinux-advanced-abc' {"
  fi
  echo "menuentry 'Gentoo GNU/Linux, with Linux ${k}' --class os \$menuentry_id_option 'gnulinux-${k}-advanced-abc' {"
  [ "${GRUB_SAVEDEFAULT}" = true ] && echo "	savedefault"
  echo "	linux /boot/vmlinuz-${k} root=UUID=abc ro ${GRUB_CMDLINE_LINUX} ${GRUB_CMDLINE_LINUX_DEFAULT}"; echo "}"
  [ "${GRUB_DISABLE_RECOVERY}" != true ] && { echo "menuentry 'Gentoo GNU/Linux, with Linux ${k} (recovery mode)' {"; echo "	linux /boot/vmlinuz-${k} single"; echo "}"; }
done
[ "${GRUB_DISABLE_SUBMENU}" != true ] && echo "}"
exit 0
EOS
    chmod +x "${GT}/10_linux"
    GRUB_CMDLINE_LINUX="selinux=1 audit=1 enforcing=1" GRUB_CMDLINE_LINUX_DEFAULT="quiet" GRUB_SAVEDEFAULT=true \
        sh "${GT}/11_selinux_permissive_rescue" > "${GT}/out" 2> "${GT}/err"
    n_me="$(grep -c '^menuentry ' "${GT}/out")"; n_lin="$(grep -c '^[[:space:]]*linux ' "${GT}/out")"
    n_res="$(grep -c "^menuentry '[^']* (SELinux permissive rescue)' .*-selinux-permissive-rescue' {" "${GT}/out")"
    [ "${n_me}" = 2 ] && [ "${n_res}" = 2 ] && ok "grub.d: one rescue entry per kernel 10_linux boots (2/2), each titled and id'd as rescue" \
        || bad "grub.d: want 2 rescue entries, got menuentry=${n_me} rescue-titled=${n_res}: $(cat "${GT}/out")"
    [ "${n_lin}" = 2 ] && [ "$(grep -c -- ' enforcing=0$' "${GT}/out")" = 2 ] \
        && ok "grub.d: every rescue linux line ENDS in enforcing=0 (after GRUB_CMDLINE_LINUX's enforcing=1 — the kernel takes the last)" \
        || bad "grub.d: enforcing=0 not last on every linux line: $(grep 'linux ' "${GT}/out")"
    grep -q 'selinux=1 audit=1' "${GT}/out" && grep -q 'quiet' "${GT}/out" && ok "grub.d: keeps the image's own cmdline (both halves)" || bad "grub.d: lost the image cmdline"
    grep -Eq '^submenu|recovery mode|savedefault|gnulinux-simple' "${GT}/out" \
        && bad "grub.d: emitted a submenu / recovery / savedefault / the plain simple entry" || ok "grub.d: flat rescue entries only (no submenu, recovery, savedefault or a duplicate default entry)"
    [ ! -s "${GT}/err" ] && ok "grub.d: does not repeat 10_linux's 'Found linux image' chatter" || bad "grub.d: stderr: $(cat "${GT}/err")"
    rm "${GT}/10_linux"
    sh "${GT}/11_selinux_permissive_rescue" > "${GT}/out" 2>&1; rc=$?
    [ "${rc}" = 0 ] && [ ! -s "${GT}/out" ] && ok "grub.d: no 10_linux -> prints nothing, exits 0 (grub-mkconfig never fails on it)" || bad "grub.d: without 10_linux rc=${rc} out=$(cat "${GT}/out")"
    case "${GD##*/}" in 1[1-9]_*|[2-9][0-9]_*) ok "grub.d: sorts after 10_linux, so default=0 stays the normal entry" ;; *) bad "grub.d: ${GD##*/} does not sort after 10_linux" ;; esac
    grep -i hugmesh "${GD}" >/dev/null && bad "grub.d snippet carries the brand name (it ships on unaffiliated images too)" || ok "grub.d: brand-neutral"
fi
l_gdi="$(ln_of 'install -D -m 0755 "\$\{SPECS_DIR\}/etc/grub.d/11_selinux_permissive_rescue"')"
[ -n "${l_gdi}" ] && [ "${l_gdi}" -lt "${l_sto}" ] && ok "builder installs the grub.d rescue snippet into the sysroot (before the label pass)" \
    || bad "builder does not install etc/grub.d/11_selinux_permissive_rescue (line=${l_gdi:-none} store=${l_sto:-?})"
# login records: pre-created before the label pass, and pinned as a gate probe
l_wtmp="$(ln_of '\[ -e "\$\{SYSROOT\}/var/log/\$\{_lrec\}" \] \|\| : > "\$\{SYSROOT\}/var/log/\$\{_lrec\}"')"
l_wtl="$(ln_of '^[0-9]+:for _lrec in wtmp lastlog; do$')"
[ -n "${l_wtmp}" ] && [ -n "${l_wtl}" ] && [ "${l_wtmp}" -lt "${l_sto}" ] \
    && ok "builder creates /var/log/wtmp and /var/log/lastlog before the label pass (else bootmisc/login make them var_log_t)" \
    || bad "login records not pre-created before the label pass (create=${l_wtmp:-none} loop=${l_wtl:-none} store=${l_sto:-?})"
grep -q '^    "/var/log/wtmp:wtmp_t"' "${LIB}" && ok "the label gates pin /var/log/wtmp as wtmp_t at every hop" || bad "/var/log/wtmp:wtmp_t is not a core probe"

echo
echo "== selinux sysroot labels: ${P} passed, ${F} failed, ${S} skipped (skips are NOT passes) =="
[ "${F}" -eq 0 ]
