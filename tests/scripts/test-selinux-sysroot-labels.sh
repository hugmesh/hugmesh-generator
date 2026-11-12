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
#      on a disk root it does nothing. G2: it is LOUD — a failing restorecon (upper
#      or /dev), no restorecon, no upperdir all exit non-zero with a FAILED kmsg line
#      and never print 'relabelled'; no call ever carries -n (dry-run mutant).
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
# (static cheap pin; the entry COUNTS are asserted on an executed grub.cfg in section I5)
grep -q 'set default=0' <<<"${img_menu}" && grep -q 'SELinux permissive rescue' <<<"${img_menu}" && grep -q 'SELinux enforcing (test)' <<<"${img_menu}" \
    && ok "B6: .img grub.cfg keeps default=0 and appends permissive rescue + enforcing (test) entries" || bad "B6: .img rescue/test entries missing or default changed"
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
    # ── G2) LOUD ON FAILURE, executed. The #852 hook ended in `exit 0` whatever
    # restorecon returned and printed 'relabelled N' before xargs' status was known,
    # so a relabel that failed read exactly like one that worked. Its refute also
    # left `restorecon -n` (a dry run that relabels nothing) green. Both pinned here.
    HK2="${TMP}/hook2"; mkdir -p "${HK2}/bin" "${HK2}/toolbin" "${HK2}/upper/etc" "${HK2}/upper/usr/libexec"
    : > "${HK2}/upper/etc/inittab"; : > "${HK2}/upper/etc/resolv.conf"
    printf 'LiveOS_rootfs / overlay rw,seclabel,relatime,lowerdir=/run/rootfsbase,upperdir=%s/upper,workdir=/run/ovlwork 0 0\n' "${HK2}" > "${HK2}/m.overlay"
    printf 'LiveOS_rootfs / overlay rw,seclabel,relatime,lowerdir=/run/rootfsbase,workdir=/run/ovlwork 0 0\n' > "${HK2}/m.noupper"
    printf '/dev/sda2 / ext4 rw,seclabel,relatime 0 0\n' > "${HK2}/m.disk"
    # The hook's PATH becomes <stub restorecon>:<these tools> and nothing else, so
    # "no restorecon" is a real absence and never depends on what this host ships.
    for t in awk sed tr tail wc find xargs rm cat; do ln -sf "$(type -P "${t}")" "${HK2}/toolbin/${t}"; done
    # run_hook2 <mounts> <restorecon: ok|fail-upper|fail-dev|absent> -> rc; kmsg -> ${HK2}/kmsg, argv -> ${HK2}/called
    run_hook2() {
        rm -f "${HK2}/called" "${HK2}/bin/restorecon"; : > "${HK2}/kmsg"
        if [ "$2" != absent ]; then
            printf '#!/bin/sh\necho "$*" >> "%s/called"\ncase "%s:$1" in fail-dev:-RFx|fail-upper:-F) exit 1 ;; esac\nexit 0\n' "${HK2}" "$2" > "${HK2}/bin/restorecon"
            chmod +x "${HK2}/bin/restorecon"
        fi
        sed "s|^PATH=/usr/sbin.*|PATH=${HK2}/bin:${HK2}/toolbin|" "${HOOK}" > "${HK2}/hook.sh"
        PROC_MOUNTS="$1" KMSG="${HK2}/kmsg" LIST_DIR="${HK2}" sh "${HK2}/hook.sh" >/dev/null 2>&1
    }
    n_up="$(cd "${HK2}/upper" && find . -xdev | wc -l)"
    run_hook2 "${HK2}/m.overlay" ok; rc=$?
    [ "${rc}" = 0 ] && grep -q "^live-overlay-relabel: relabelled ${n_up} upper-layer path(s) under ${HK2}/upper" "${HK2}/kmsg" \
        && ok "hook G2: success exits 0 and logs 'relabelled N' with N = the upper layer's entry count (${n_up})" \
        || bad "hook G2 success: rc=${rc} kmsg: $(cat "${HK2}/kmsg")"
    grep -E -- '(^| )-[A-Za-z]*n' "${HK2}/called" >/dev/null \
        && bad "hook G2: a restorecon call carries -n (a dry run relabels NOTHING): $(cat "${HK2}/called")" \
        || ok "hook G2: no restorecon call carries -n (the dry-run mutant is red)"
    [ "$(grep -c '^-F ' "${HK2}/called")" -ge 1 ] && [ "$(grep -c '^-RFx /dev$' "${HK2}/called")" = 1 ] \
        && ok "hook G2: both passes ran (restorecon -F <upper paths>, restorecon -RFx /dev)" || bad "hook G2 calls: $(cat "${HK2}/called")"
    run_hook2 "${HK2}/m.overlay" fail-upper; rc=$?
    [ "${rc}" != 0 ] && grep -q '^live-overlay-relabel: FAILED: restorecon returned' "${HK2}/kmsg" && ! grep -q 'relabelled' "${HK2}/kmsg" \
        && ok "hook G2: restorecon failing on the upper layer -> exit ${rc}, a FAILED line, no 'relabelled'" \
        || bad "hook G2 fail-upper: rc=${rc} kmsg: $(cat "${HK2}/kmsg")"
    run_hook2 "${HK2}/m.overlay" fail-dev; rc=$?
    [ "${rc}" != 0 ] && grep -q '^live-overlay-relabel: FAILED: restorecon returned' "${HK2}/kmsg" && ! grep -q 'relabelled' "${HK2}/kmsg" \
        && ok "hook G2: restorecon failing on /dev -> exit ${rc}, a FAILED line, no 'relabelled'" \
        || bad "hook G2 fail-dev: rc=${rc} kmsg: $(cat "${HK2}/kmsg")"
    run_hook2 "${HK2}/m.overlay" absent; rc=$?
    [ "${rc}" != 0 ] && grep -q '^live-overlay-relabel: FAILED: .*no restorecon' "${HK2}/kmsg" \
        && ok "hook G2: an overlay root with no restorecon on PATH -> exit ${rc}, says so" \
        || bad "hook G2 absent: rc=${rc} kmsg: $(cat "${HK2}/kmsg")"
    run_hook2 "${HK2}/m.noupper" ok; rc=$?
    [ "${rc}" != 0 ] && grep -q '^live-overlay-relabel: FAILED: no upperdir=' "${HK2}/kmsg" && [ ! -e "${HK2}/called" ] \
        && ok "hook G2: an overlay root whose options carry no upperdir= -> exit ${rc}, says so, calls nothing" \
        || bad "hook G2 noupper: rc=${rc} kmsg: $(cat "${HK2}/kmsg") called: $(cat "${HK2}/called" 2>/dev/null)"
    # ── G3) the merged-path rewrite FAILING (#863 refute, blocker 5). The hook is
    # /bin/sh with no pipefail; `sed -z ... | xargs -0 -r restorecon -F || rc=$?`
    # saw only xargs' status, so a dead sed meant an empty list, `xargs -r` ran
    # nothing, returned 0, and the hook logged "relabelled N" over a tmpfs_t upper
    # layer. Swap the real sed in the hook's PATH for a stub and run it for real.
    # run_hook2_sed <sed stub body> -> rc; same outputs as run_hook2.
    run_hook2_sed() {
        rm -f "${HK2}/toolbin/sed"
        # Only the hook's `sed -z` (the merged-path rewrite) meets the stub; its other
        # sed (the upperdir= parse) still runs the real one.
        printf '#!/bin/sh\nif [ "$1" = -z ]; then\n%s\nfi\nexec %s "$@"\n' "$1" "$(type -P sed)" > "${HK2}/toolbin/sed"
        chmod +x "${HK2}/toolbin/sed"
        run_hook2 "${HK2}/m.overlay" ok; local r=$?
        rm -f "${HK2}/toolbin/sed"; ln -sf "$(type -P sed)" "${HK2}/toolbin/sed"
        return "${r}"
    }
    # run_hook2's own `sed "s|^PATH=..."` runs in this shell, not in the hook's PATH,
    # so it never meets the stub. Upper-layer restorecon calls are the '-F <path>' lines.
    run_hook2_sed 'exit 4'; rc=$?
    [ "${rc}" != 0 ] && grep -q '^live-overlay-relabel: FAILED: sed could not rewrite' "${HK2}/kmsg" && ! grep -q 'relabelled' "${HK2}/kmsg" \
        && ! grep -q '^-F ' "${HK2}/called" 2>/dev/null \
        && ok "hook G3: sed failing (exit 4) -> exit ${rc}, a FAILED line naming sed, no 'relabelled', no upper-layer restorecon" \
        || bad "hook G3 sed-fails: rc=${rc} kmsg: $(cat "${HK2}/kmsg") called: $(cat "${HK2}/called" 2>/dev/null)"
    # A sed that exits 0 but writes a SHORT list (the ENOSPC/partial-write shape): the
    # entry counts disagree, so the hook must refuse rather than relabel part of it.
    run_hook2_sed 'printf "/\000"; exit 0'; rc=$?
    [ "${rc}" != 0 ] && grep -q '^live-overlay-relabel: FAILED: the merged path list has 1 entries' "${HK2}/kmsg" && ! grep -q 'relabelled' "${HK2}/kmsg" \
        && ! grep -q '^-F ' "${HK2}/called" 2>/dev/null \
        && ok "hook G3: sed exits 0 with a short list (1 of ${n_up}) -> exit ${rc}, FAILED on the count mismatch, no upper-layer restorecon" \
        || bad "hook G3 short-list: rc=${rc} kmsg: $(cat "${HK2}/kmsg") called: $(cat "${HK2}/called" 2>/dev/null)"
    # Positive control for G3: the real sed restored, the same fixture relabels again.
    run_hook2 "${HK2}/m.overlay" ok; rc=$?
    [ "${rc}" = 0 ] && grep -q "relabelled ${n_up} upper-layer" "${HK2}/kmsg" \
        && ok "hook G3 control: with the real sed back the same fixture succeeds (the stub, not the fixture, made G3 red)" \
        || bad "hook G3 control: rc=${rc} kmsg: $(cat "${HK2}/kmsg")"
    grep -vE '^[[:space:]]*#' "${HOOK}" | grep -E 'sed[^|]*\|[[:space:]]*xargs' >/dev/null \
        && bad "hook G3 (static): a 'sed ... | xargs' pipe is back (only xargs' status is seen under /bin/sh)" \
        || ok "hook G3 (static): no 'sed ... | xargs' pipe in the source"
    run_hook2 "${HK2}/m.disk" ok; rc=$?
    [ "${rc}" = 0 ] && grep -q 'not an overlay' "${HK2}/kmsg" && [ ! -e "${HK2}/called" ] \
        && ok "hook G2: a disk root exits 0 and logs why it did nothing" || bad "hook G2 disk: rc=${rc} kmsg: $(cat "${HK2}/kmsg")"
    grep -vE '^[[:space:]]*#' "${HOOK}" | grep -E 'restorecon[^|]*[[:space:]]-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)' >/dev/null \
        && bad "hook G2 (static): a restorecon invocation in the source carries -n" || ok "hook G2 (static): no restorecon -n in the source"
fi
l_lrinst="$(ln_of 'install -D -m 0755 "\$\{SHARED_SPECS\}/usr/libexec/live-overlay-relabel"')"
[ -n "${l_lrinst}" ] && [ "${l_lrinst}" -lt "${l_sto}" ] \
    && ok "builder installs the hook before the label pass (so it is labelled)" \
    || bad "builder does not install live-overlay-relabel before the label pass (install=${l_lrinst:-none} store=${l_sto:-?})"
# The inittab wiring, EXECUTED: cut the builder's own block (hook install .. its order
# guard) and run it on a fixture sysroot. A static grep of the sed line cannot tell
# "inserted before si::" from "appended after it"; running it can.
lr_blk="$(awk '/^install -D -m 0755 "\$\{SHARED_SPECS\}\/usr\/libexec\/live-overlay-relabel"/{f=1} f{print} f&&/live-overlay-relabel is not the sysinit line before OpenRC/{exit}' "${X86}")"
if [ -z "${lr_blk}" ]; then
    bad "could not cut the inittab wiring block out of the builder"
else
    LS="${TMP}/lrsys"; mkdir -p "${LS}/etc"
    printf 'id:3:initdefault:\nsi::sysinit:/usr/bin/openrc sysinit\nrc::bootwait:/usr/bin/openrc boot\n' > "${LS}/etc/inittab"
    lr_run() { SYSROOT="${LS}" SHARED_SPECS="${REPO}/specs" bash -c 'err() { echo "ERR $*"; }; eval "$1"' _ "${lr_blk}" > "${TMP}/lr.out" 2>&1; }
    lr_run; rc=$?
    l1="$(grep -n '^lr::sysinit:/usr/libexec/live-overlay-relabel$' "${LS}/etc/inittab" | cut -d: -f1)"; l2="$(grep -n '^si::sysinit:' "${LS}/etc/inittab" | cut -d: -f1)"
    [ "${rc}" = 0 ] && [ -n "${l1}" ] && [ -n "${l2}" ] && [ "${l1}" -lt "${l2}" ] && [ -x "${LS}/usr/libexec/live-overlay-relabel" ] \
        && ok "builder block, executed: hook installed, lr::sysinit lands BEFORE si::sysinit (OpenRC)" \
        || bad "builder block, executed: rc=${rc} lr=${l1:-none} si=${l2:-none}: $(cat "${TMP}/lr.out") / $(cat "${LS}/etc/inittab")"
    lr_run
    [ "$(grep -c '^lr::sysinit:' "${LS}/etc/inittab")" = 1 ] && ok "builder block is idempotent (a second run adds no second lr:: line)" || bad "builder block duplicated the lr:: line"
    printf 'id:3:initdefault:\nrc::bootwait:/usr/bin/openrc boot\n' > "${LS}/etc/inittab"
    lr_run && bad "builder block PASSED an inittab with no si::sysinit line (the hook would never run)" \
        || { grep -q 'ERR .*not the sysinit line before OpenRC' "${TMP}/lr.out" && ok "builder block refuses an inittab without si::sysinit (exit 1, says why)" || bad "no-si case wrong reason: $(cat "${TMP}/lr.out")"; }
fi

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
# What systemd-tmpfiles-setup would create in "/" (enforcing, 2026-11-04): /srv is
# shipped, portage's tmpdir entry is masked, both BEFORE the label pass. Shipped by
# slx_ship_bootpath_files (executed in section I); here only its x86 placement.
l_srv="$(ln_of '^[0-9]+:slx_ship_bootpath_files "\$\{SYSROOT\}" "\$\{SHARED_SPECS\}"')"
[ -n "${l_srv}" ] && [ "${l_srv}" -lt "${l_sto}" ] \
    && ok "x86 builder ships /srv + the portage-tmpdir.conf mask (slx_ship_bootpath_files) before the label pass" \
    || bad "x86 builder does not call slx_ship_bootpath_files before the label pass (call=${l_srv:-none} store=${l_sto:-?})"
PTM="${REPO}/specs/etc/tmpfiles.d/portage-tmpdir.conf"
[ -f "${PTM}" ] && [ "$(grep -vcE '^[[:space:]]*(#|$)' "${PTM}")" = 0 ] \
    && ok "specs/etc/tmpfiles.d/portage-tmpdir.conf is a mask (comments only — a live line would re-create /var/tmp/portage)" \
    || bad "the portage-tmpdir.conf mask is missing or carries a live tmpfiles line"
grep -q '^    "/srv:var_t"' "${LIB}" && ok "the label gates pin /srv as var_t at every hop" || bad "/srv:var_t is not a core probe"
# /root: a login mapping in the STORE, between the store install and setfiles, pinned at every hop.
l_map="$(ln_of 'slx_map_root_login "\$\{SYSROOT\}" "\$\{SLX_TYPE\}" chroot')"
l_lab1="$(ln_of 'slx_label_tree "\$\{SYSROOT\}" "\$\{SLX_TYPE\}"')"
[ -n "${l_map}" ] && [ -n "${l_lab1}" ] && [ "${l_sto}" -lt "${l_map}" ] && [ "${l_map}" -lt "${l_lab1}" ] \
    && ok "builder maps the root login AFTER the store install and BEFORE setfiles (so .homedirs carries /root when the tree is labelled)" \
    || bad "slx_map_root_login missing or misplaced (store=${l_sto:-?} map=${l_map:-none} setfiles=${l_lab1:-?})"
grep -qE '^slx_map_root_login\(\)' "${LIB}" && ok "lib defines slx_map_root_login()" || bad "lib lost slx_map_root_login()"
grep -q '^    "/root:user_home_dir_t"' "${LIB}" && ok "the label gates pin /root as user_home_dir_t at every hop (default_t = 3 login denials per boot)" || bad "/root:user_home_dir_t is not a core probe"

# ══ I) #863 refute, blockers 3 and 4: every image carries a permissive rescue AND an
# enforcing (test) entry, and the boot-path fixes ship on every builder. Executed
# against fixtures wherever the code can run off-target; the remaining pins are
# placement checks on comment-stripped source.
echo "-- I) SELinux rescue/trial entries + boot-path files on every builder (#863 refute) --"
ALL_BUILDERS=()
for b in "${REPO}"/build-*-stage4.sh; do ALL_BUILDERS+=("${b}"); done
[ "${#ALL_BUILDERS[@]}" = 10 ] && ok "I: ten stage4 builders found" || bad "I: expected 10 stage4 builders, found ${#ALL_BUILDERS[@]}"

# I1) slx_ship_bootpath_files EXECUTED, then its call site in EVERY builder.
BP="${TMP}/bootpath"; mkdir -p "${BP}/sysroot" "${BP}/specs/etc/tmpfiles.d"
cp "${REPO}/specs/etc/tmpfiles.d/portage-tmpdir.conf" "${BP}/specs/etc/tmpfiles.d/"
( . "${LIB}"; slx_ship_bootpath_files "${BP}/sysroot" "${BP}/specs" ) >/dev/null 2>&1; rc=$?
[ "${rc}" = 0 ] && [ -d "${BP}/sysroot/srv" ] && cmp -s "${BP}/sysroot/etc/tmpfiles.d/portage-tmpdir.conf" "${REPO}/specs/etc/tmpfiles.d/portage-tmpdir.conf" \
    && ok "I1: slx_ship_bootpath_files ships /srv and the exact portage-tmpdir.conf mask" \
    || bad "I1: slx_ship_bootpath_files rc=${rc}, /srv=$([ -d "${BP}/sysroot/srv" ] && echo y || echo n)"
rm -f "${BP}/specs/etc/tmpfiles.d/portage-tmpdir.conf"
( . "${LIB}"; slx_ship_bootpath_files "${BP}/sysroot2" "${BP}/specs" ) >/dev/null 2>&1; rc=$?
[ "${rc}" != 0 ] && ok "I1: a missing mask source fails the call (rc=${rc}), never a silent partial ship" || bad "I1: a missing mask source returned 0"
for b in "${ALL_BUILDERS[@]}"; do
    bn="${b##*/}"; bnc="${TMP}/${bn}.nc"; grep -nvE '^[[:space:]]*#' "${b}" > "${bnc}"
    l_call="$({ grep -E -m1 '^[0-9]+:slx_ship_bootpath_files "\$\{SYSROOT\}" "\$\{SHARED_SPECS\}"' "${bnc}" || true; } | cut -d: -f1)"
    l_fail="$({ grep -E -m1 '^[0-9]+:    \|\| \{ err "could not ship the SELinux boot-path files' "${bnc}" || true; } | cut -d: -f1)"
    # The first point the sysroot is frozen: the build-time label store (x86, Frite),
    # else the stage4 tarball pack.
    l_frz="$({ grep -E -m1 '^[0-9]+:slx_store_install_modules "\$\{SYSROOT\}"' "${bnc}" || true; } | cut -d: -f1)"
    [ -n "${l_frz}" ] || l_frz="$({ grep -E -m1 '^[0-9]+:STAGE4(_TARBALL)?="\$\{WORK_DIR\}' "${bnc}" || true; } | cut -d: -f1)"
    [ -n "${l_call}" ] && [ -n "${l_fail}" ] && [ "${l_fail}" = $((l_call + 1)) ] && [ -n "${l_frz}" ] && [ "${l_call}" -lt "${l_frz}" ] \
        && ok "I1: ${bn} ships /srv + the tmpfiles mask (fatal on failure) before its sysroot is labelled/packed" \
        || bad "I1: ${bn}: slx_ship_bootpath_files call=${l_call:-none} fail-line=${l_fail:-none} frozen-at=${l_frz:-?}"
done

# I2) The root login mapping on every image: x86 + Frite at build time (in the label
# chain, between store install and setfiles), the first-boot-labelled ARM images in
# provision_selinux (executed in test-selinux-policy-install.sh, section E-root).
FRITE="${REPO}/build-frite-stage4.sh"; FNC="${TMP}/frite.nc"; grep -nvE '^[[:space:]]*#' "${FRITE}" > "${FNC}"
f_ln() { { grep -E -m1 -- "$1" "${FNC}" || true; } | cut -d: -f1; }
f_sto="$(f_ln 'slx_store_install_modules "\$\{SYSROOT\}" "\$\{SLX_TYPE\}" chroot')"
f_map="$(f_ln 'slx_map_root_login "\$\{SYSROOT\}" "\$\{SLX_TYPE\}" chroot')"
f_lab="$(f_ln 'slx_label_tree "\$\{SYSROOT\}" "\$\{SLX_TYPE\}"')"
[ -n "${f_sto}" ] && [ -n "${f_map}" ] && [ -n "${f_lab}" ] && [ "${f_sto}" -lt "${f_map}" ] && [ "${f_map}" -lt "${f_lab}" ] \
    && ok "I2: Frite maps the root login after its store install and before setfiles (in the qemu chroot chain)" \
    || bad "I2: Frite root login mapping missing or misplaced (store=${f_sto:-?} map=${f_map:-none} setfiles=${f_lab:-?})"
for b in "${ALL_BUILDERS[@]}"; do
    bn="${b##*/}"
    if grep -vE '^[[:space:]]*#' "${b}" | grep -E 'slx_store_install_modules "\$\{SYSROOT\}"' >/dev/null; then
        grep -vE '^[[:space:]]*#' "${b}" | grep -E 'slx_map_root_login "\$\{SYSROOT\}"' >/dev/null \
            && ok "I2: ${bn} builds its store at build time and maps the root login there" \
            || bad "I2: ${bn} builds its store at build time but never maps the root login (/root stays default_t)"
    fi
done
pv_end="$(grep -n '# ── END hugmesh node-policy load ──' "${PROV}" | head -1 | cut -d: -f1)"
pv_map="$(grep -nE '^[[:space:]]+selinux_map_root_login "\$\{type\}" "\$\{aware\}"$' "${PROV}" | head -1 | cut -d: -f1)"
pv_rel="$(grep -n 'log "Relabelling filesystem' "${PROV}" | head -1 | cut -d: -f1)"
[ -n "${pv_end}" ] && [ -n "${pv_map}" ] && [ -n "${pv_rel}" ] && [ "${pv_end}" -lt "${pv_map}" ] && [ "${pv_map}" -lt "${pv_rel}" ] \
    && ok "I2: provision_selinux maps the root login after the node-policy load and before the relabel (first-boot ARM images)" \
    || bad "I2: provision_selinux root mapping missing or misplaced (load-end=${pv_end:-?} map=${pv_map:-none} relabel=${pv_rel:-?})"

# I3) x86: the dracut UKI loop, EXECUTED. The block lives in an unquoted <<CHROOT
# heredoc, so expand it host-side exactly as bash would, then run it with a dracut stub.
UV_LINE="$(grep -E '^UKI_VARIANTS=\(' "${X86}" | head -1)"
[ -n "${UV_LINE}" ] && ok "I3: the builder carries one UKI_VARIANTS table" || bad "I3: no UKI_VARIANTS table in the x86 builder"
DRB="${TMP}/dracut-uki"; mkdir -p "${DRB}"
awk '/^if command -v dracut >\/dev\/null && dracut --help .*--uefi.; then$/{f=1} f{print} f&&/^fi$/{exit}' "${X86}" > "${DRB}/block.raw"
if [ ! -s "${DRB}/block.raw" ]; then
    bad "I3: could not cut the dracut --uefi block out of the x86 builder"
else
    ( eval "${UV_LINE}"; UKI_VARIANTS_CHROOT="${UKI_VARIANTS[*]}"; UKI_NAME=hugmesh.efi
      eval "cat <<CHROOT_X
$(cat "${DRB}/block.raw")
CHROOT_X" ) > "${DRB}/block.sh"
    cat > "${DRB}/run.sh" <<'EOS'
set -eo pipefail
dracut() { if [ "$1" = --help ]; then echo "  --uefi  create a UEFI executable"; return 0; fi
           local a out cmd; for a in "$@"; do out="${a}"; done
           while [ $# -gt 0 ]; do [ "$1" = --kernel-cmdline ] && cmd="$2"; shift; done
           printf '%s\t%s\n' "${out}" "${cmd}" >> "${CALLS}"; }
CMDLINE="root=LABEL=SNAP_ROOT ro lsm=lockdown,yama,selinux,bpf selinux=1 audit=1"; KVER=6.18.52-gentoo
EOS
    cat "${DRB}/block.sh" >> "${DRB}/run.sh"
    CALLS="${DRB}/calls" bash "${DRB}/run.sh" > "${DRB}/out" 2>&1; rc=$?
    n_calls="$(wc -l < "${DRB}/calls" 2>/dev/null || echo 0)"
    def_cmd="$(awk -F'\t' '$1=="/boot/hugmesh-unsigned.efi"{print $2}' "${DRB}/calls" 2>/dev/null)"
    res_cmd="$(awk -F'\t' '$1=="/boot/hugmesh-selinux-rescue-unsigned.efi"{print $2}' "${DRB}/calls" 2>/dev/null)"
    enf_cmd="$(awk -F'\t' '$1=="/boot/hugmesh-selinux-enforcing-test-unsigned.efi"{print $2}' "${DRB}/calls" 2>/dev/null)"
    B="root=LABEL=SNAP_ROOT ro lsm=lockdown,yama,selinux,bpf selinux=1 audit=1"
    [ "${rc}" = 0 ] && [ "${n_calls}" = 3 ] && [ "${def_cmd}" = "${B}" ] && [ "${res_cmd}" = "${B} enforcing=0" ] && [ "${enf_cmd}" = "${B} enforcing=1" ] \
        && ok "I3: the kernel chroot builds three UKIs: default (no enforcing=), -selinux-rescue (enforcing=0 last), -selinux-enforcing-test (enforcing=1 last)" \
        || bad "I3: dracut UKI loop rc=${rc} calls=${n_calls}: $(cat "${DRB}/calls" 2>/dev/null) $(cat "${DRB}/out")"
fi
kci="$(awk '/^kernel_cache_inputs\(\) \{/{f=1} f{print} f&&/^}/{exit}' "${X86}" | grep -vE '^[[:space:]]*#')"
grep -F "printf 'uki-variants=%s\\n' \"\${UKI_VARIANTS_CHROOT}\"" <<<"${kci}" >/dev/null \
    && ok "I3: the kernel-cache key carries the UKI variant table (a pre-twin cache entry cannot HIT and skip the twins)" \
    || bad "I3: kernel_cache_inputs does not fold in UKI_VARIANTS_CHROOT"

# I4) x86: the Secure Boot sign step, EXECUTED with sbsign stubbed, for every branch.
SGB="${TMP}/sign"; mkdir -p "${SGB}"
awk '/^SBDIR="\$\{WORK_DIR\}\/secureboot"$/{f=1} /^# ── 8\. Clean/{exit} f{print}' "${X86}" > "${SGB}/block.sh"
grep -q 'uki_variant_paths' "${SGB}/block.sh" || bad "I4: could not cut the sign step (no uki_variant_paths in it)"
# sign_run <case> <secure_boot> <sbsign: stub|absent> <unsigned twins present: all|no-rescue|none> -> rc; dir ${SGB}/<case>
sign_run() {
    local d="${SGB}/$1"; rm -rf "${d}"; mkdir -p "${d}/sysroot/boot" "${d}/work/secureboot" "${d}/bin"
    : > "${d}/work/secureboot/sb.key"; : > "${d}/work/secureboot/sb.crt"; : > "${d}/work/secureboot/sb.cer"
    case "$4" in
        all)       for n in hugmesh hugmesh-selinux-rescue hugmesh-selinux-enforcing-test; do echo "uki ${n}" > "${d}/sysroot/boot/${n}-unsigned.efi"; done ;;
        no-rescue) for n in hugmesh hugmesh-selinux-enforcing-test; do echo "uki ${n}" > "${d}/sysroot/boot/${n}-unsigned.efi"; done ;;
        none) ;;
    esac
    # A private PATH: the tools the step uses and, for "stub", an sbsign that signs by
    # prefixing SIGNED. Never the host's sbsign/openssl.
    for t in cp rm mkdir cat sh; do ln -sf "$(type -P "${t}")" "${d}/bin/${t}"; done
    [ "$3" = stub ] && { printf '#!/bin/sh\nwhile [ $# -gt 2 ]; do [ "$1" = --output ] && o="$2"; shift; done\n{ echo SIGNED; cat "$2"; } > "$o"; echo "$o" >> "%s/sbsign.calls"\n' "${d}" > "${d}/bin/sbsign"; chmod +x "${d}/bin/sbsign"; }
    ( set -e
      info() { :; }; warn() { :; }; err() { echo "ERR: $*" >&2; }
      PATH="${d}/bin"
      eval "${UV_LINE}"; UKI_NAME=hugmesh.efi
      SYSROOT="${d}/sysroot"; WORK_DIR="${d}/work"; SECUREBOOT_KEY=""; SECUREBOOT_CERT=""
      SECURE_BOOT="$2"; SB_ETC_DIR=/etc/hugmesh/secureboot; ORG=x; BRAND=x; SB_CERT_CN=x; SB_CERT_O=x
      . "${SGB}/block.sh" ) > "${d}/out" 2>&1
}
sign_run sb true stub all; rc=$?
d="${SGB}/sb"; okc=0
for n in hugmesh hugmesh-selinux-rescue hugmesh-selinux-enforcing-test; do
    [ "$(head -1 "${d}/sysroot/boot/${n}.efi" 2>/dev/null)" = SIGNED ] && [ ! -e "${d}/sysroot/boot/${n}-unsigned.efi" ] && okc=$((okc+1))
done
[ "${rc}" = 0 ] && [ "${okc}" = 3 ] && [ "$(wc -l < "${d}/sbsign.calls")" = 3 ] \
    && ok "I4: Secure Boot ON: all three UKIs are signed with the org key (sbsign x3), unsigned copies removed" \
    || bad "I4: sign step rc=${rc}, signed=${okc}/3: $(cat "${d}/out")"
sign_run norescue true stub no-rescue; rc=$?
[ "${rc}" != 0 ] && grep -q 'UKI twin missing: .*hugmesh-selinux-rescue-unsigned.efi' "${SGB}/norescue/out" && [ ! -e "${SGB}/norescue/sysroot/boot/hugmesh.efi" ] \
    && ok "I4: a default UKI without its rescue twin stops the build BEFORE anything is signed" \
    || bad "I4: missing rescue twin: rc=${rc}, out: $(cat "${SGB}/norescue/out")"
sign_run nosb false stub all; rc=$?
d="${SGB}/nosb"; okc=0
for n in hugmesh hugmesh-selinux-rescue hugmesh-selinux-enforcing-test; do [ -f "${d}/sysroot/boot/${n}.efi" ] && [ ! -e "${d}/sysroot/boot/${n}-unsigned.efi" ] && okc=$((okc+1)); done
[ "${rc}" = 0 ] && [ "${okc}" = 3 ] && [ ! -e "${d}/sbsign.calls" ] \
    && ok "I4: --no-secure-boot: all three UKIs land under their final names (unsigned, as the default does)" \
    || bad "I4: --no-secure-boot: rc=${rc} landed=${okc}/3: $(cat "${d}/out")"
sign_run nosbsign true absent all; rc=$?
d="${SGB}/nosbsign"; okc=0
for n in hugmesh hugmesh-selinux-rescue hugmesh-selinux-enforcing-test; do [ -f "${d}/sysroot/boot/${n}.efi" ] && [ ! -e "${d}/sysroot/boot/${n}-unsigned.efi" ] && okc=$((okc+1)); done
[ "${rc}" = 0 ] && [ "${okc}" = 3 ] \
    && ok "I4: no sbsign on the host: all three UKIs land under their final names (the default's posture)" \
    || bad "I4: no sbsign: rc=${rc} landed=${okc}/3: $(cat "${d}/out")"
sign_run nouki true stub none; rc=$?
[ "${rc}" = 0 ] && [ -z "$(ls "${SGB}/nouki/sysroot/boot")" ] \
    && ok "I4: no UKI built at all (dracut without --uefi): the twin check does not fire, nothing is invented" \
    || bad "I4: no UKI at all: rc=${rc} boot=$(ls "${SGB}/nouki/sysroot/boot") out: $(cat "${SGB}/nouki/out")"

# I5) x86 .img: the ESP install loop and the hand-written grub.cfg, EXECUTED.
IMB="${TMP}/img"; mkdir -p "${IMB}"
awk '/^    local uki_src="\$\{SYSROOT\}\/boot\/\$\{UKI_NAME\}"$/{f=1} f{print} f&&/No signed UKI at/{g=1} g&&/^    fi$/{exit}' "${X86}" > "${IMB}/esp.sh"
awk '/^    local cmdline=""$/{f=1} f{print} f&&/> "\$\{root_mnt\}\/boot\/grub\/grub.cfg"$/{exit}' "${X86}" > "${IMB}/grub.sh"
[ -s "${IMB}/esp.sh" ] && [ -s "${IMB}/grub.sh" ] || bad "I5: could not cut the ESP/grub.cfg blocks out of build_img"
# img_run <case> <uki_name> <twins: all|no-rescue|none> -> rc; grub.cfg at ${IMB}/<case>/root/boot/grub/grub.cfg
img_run() {
    local d="${IMB}/$1"; rm -rf "${d}"; mkdir -p "${d}/sysroot/boot" "${d}/root/boot/efi" "${d}/root/etc/default"
    printf 'GRUB_CMDLINE_LINUX="lsm=lockdown,yama,selinux,bpf selinux=1 audit=1"\n' > "${d}/root/etc/default/grub"
    local base="${2%.efi}"
    case "$3" in
        all)       for n in "${base}" "${base}-selinux-rescue" "${base}-selinux-enforcing-test"; do echo x > "${d}/sysroot/boot/${n}.efi"; done ;;
        no-rescue) for n in "${base}" "${base}-selinux-enforcing-test"; do echo x > "${d}/sysroot/boot/${n}.efi"; done ;;
    esac
    { echo 'img_fn() {'; cat "${IMB}/esp.sh" "${IMB}/grub.sh"; echo '}'; } > "${d}/fn.sh"
    ( info() { :; }; warn() { :; }; err() { echo "ERR: $*" >&2; }
      eval "${UV_LINE}"; UKI_NAME="$2"; SYSROOT="${d}/sysroot"; root_mnt="${d}/root"
      SB_ETC_DIR=/nonexistent; SB_EFI_VENDOR=x; BRAND_TITLE="Brand"; ROLE=backend
      esp_fsuuid=ESP-UUID; root_fsuuid=ROOT-UUID; root_uuid=ROOT-PARTUUID; vmlinuz=vmlinuz-6.18.52; initrd=initramfs-6.18.52.img
      . "${d}/fn.sh"; img_fn ) > "${d}/out" 2>&1
}
img_run uki hugmesh.efi all; rc=$?
G5="${IMB}/uki/root/boot/grub/grub.cfg"
if [ "${rc}" != 0 ] || [ ! -s "${G5}" ]; then
    bad "I5: build_img's ESP/grub blocks did not run: rc=${rc} $(cat "${IMB}/uki/out")"
else
    # entry index (0-based) of the first menuentry whose block matches <ERE>
    entry_of() { awk -v re="$1" '/^menuentry /{n++} n>0 && $0 ~ re {print n-1; exit}' "${G5}"; }
    n_ent="$(grep -c '^menuentry ' "${G5}")"
    e_def="$(entry_of 'chainloader /EFI/Linux/hugmesh[.]efi$')"
    e_ures="$(entry_of 'chainloader /EFI/Linux/hugmesh-selinux-rescue[.]efi$')"
    e_uenf="$(entry_of 'chainloader /EFI/Linux/hugmesh-selinux-enforcing-test[.]efi$')"
    e_lres="$(entry_of 'linux .* enforcing=0$')"; e_lenf="$(entry_of 'linux .* enforcing=1$')"
    grep -q '^set default=0$' "${G5}" && [ "${e_def}" = 0 ] \
        && ok "I5: .img default=0 is still the plain Secure Boot UKI" || bad "I5: default entry moved (default UKI is entry ${e_def:-none}): $(cat "${G5}")"
    [ -n "${e_ures}" ] && [ "${e_ures}" -gt 1 ] && [ -f "${IMB}/uki/root/boot/efi/EFI/Linux/hugmesh-selinux-rescue.efi" ] \
        && ok "I5: a signed-chain PERMISSIVE RESCUE entry (chainloads hugmesh-selinux-rescue.efi, installed on the ESP), appended after the defaults" \
        || bad "I5: no UKI rescue entry after the defaults (entry=${e_ures:-none}): $(cat "${G5}")"
    [ -n "${e_uenf}" ] && [ "${e_uenf}" -gt 1 ] && [ -f "${IMB}/uki/root/boot/efi/EFI/Linux/hugmesh-selinux-enforcing-test.efi" ] \
        && ok "I5: a signed-chain ENFORCING (test) entry (chainloads hugmesh-selinux-enforcing-test.efi), appended" \
        || bad "I5: no UKI enforcing (test) entry (entry=${e_uenf:-none})"
    [ -n "${e_lres}" ] && [ -n "${e_lenf}" ] && [ "${e_lres}" -gt 1 ] && [ "${e_lenf}" -gt 1 ] \
        && [ "$(grep -c 'enforcing=0$' "${G5}")" = 1 ] && [ "$(grep -c 'enforcing=1$' "${G5}")" = 1 ] \
        && ok "I5: GRUB+vmlinuz: one permissive rescue (enforcing=0) and one enforcing (test) (enforcing=1) entry, both appended" \
        || bad "I5: GRUB+vmlinuz rescue/test entries wrong (rescue=${e_lres:-none} test=${e_lenf:-none})"
    awk '/^menuentry /{n++} n==2' "${G5}" | grep 'enforcing=' >/dev/null \
        && bad "I5: the plain GRUB+vmlinuz entry (1) carries enforcing=" || ok "I5: entries 0 and 1 carry no enforcing= (default boots stay permissive-by-config)"
    for t in 'Secure Boot UKI, SELinux permissive rescue' 'Secure Boot UKI, SELinux enforcing (test)' '— SELinux permissive rescue' '— SELinux enforcing (test)'; do
        grep -F "${t}" "${G5}" >/dev/null || bad "I5: no menu title containing '${t}'"
    done
    [ "${n_ent}" = 6 ] && ok "I5: six entries in all (UKI, plain, rescue, UKI rescue, UKI test, test)" || bad "I5: ${n_ent} menu entries, want 6: $(grep '^menuentry' "${G5}")"
fi
img_run noukirescue hugmesh.efi no-rescue; rc=$?
[ "${rc}" != 0 ] && grep -q 'UKI twin .*hugmesh-selinux-rescue.efi missing' "${IMB}/noukirescue/out" \
    && ok "I5: build_img refuses to seal an .img whose default UKI has no rescue twin" \
    || bad "I5: missing rescue twin at build_img: rc=${rc} $(cat "${IMB}/noukirescue/out")"
img_run nouki hugmesh.efi none; rc=$?
G5n="${IMB}/nouki/root/boot/grub/grub.cfg"
[ "${rc}" = 0 ] && ! grep -q chainloader "${G5n}" && [ "$(grep -c 'enforcing=0$' "${G5n}")" = 1 ] && [ "$(grep -c 'enforcing=1$' "${G5n}")" = 1 ] \
    && ok "I5: no UKI at all: no chainloader entries, the GRUB+vmlinuz rescue and test entries remain" \
    || bad "I5: no-UKI .img: rc=${rc} $(cat "${G5n}" 2>/dev/null) $(cat "${IMB}/nouki/out")"
img_run neutral gentoo.efi all; rc=$?
[ "${rc}" = 0 ] && grep -q 'chainloader /EFI/Linux/gentoo-selinux-rescue.efi$' "${IMB}/neutral/root/boot/grub/grub.cfg" \
    && ! grep -qi hugmesh "${IMB}/neutral/root/boot/grub/grub.cfg" \
    && ok "I5: UNAFFILIATED: the twins follow UKI_NAME (gentoo-selinux-rescue.efi), no brand string" \
    || bad "I5: unaffiliated twins: rc=${rc} $(grep chainloader "${IMB}/neutral/root/boot/grub/grub.cfg" 2>/dev/null)"

# I6) x86 installed via install-x86.sh (grub-mkconfig): 12_selinux_enforcing_test,
# EXECUTED against the same kind of stand-in 10_linux as section H.
GD12="${REPO}/specs-x86/etc/grub.d/12_selinux_enforcing_test"
if [ ! -x "${GD12}" ]; then
    bad "I6: specs-x86/etc/grub.d/12_selinux_enforcing_test is missing or not executable"
else
    GT12="${TMP}/grubd12"; mkdir -p "${GT12}"; cp "${GD12}" "${GT12}/"
    cat > "${GT12}/10_linux" <<'EOS'
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
    chmod +x "${GT12}/10_linux"
    GRUB_CMDLINE_LINUX="selinux=1 audit=1 enforcing=0" GRUB_CMDLINE_LINUX_DEFAULT="quiet" GRUB_SAVEDEFAULT=true \
        sh "${GT12}/12_selinux_enforcing_test" > "${GT12}/out" 2> "${GT12}/err"
    n_me="$(grep -c '^menuentry ' "${GT12}/out")"
    n_t="$(grep -c "^menuentry '[^']* (SELinux enforcing (test))' .*-selinux-enforcing-test' {" "${GT12}/out")"
    [ "${n_me}" = 2 ] && [ "${n_t}" = 2 ] && ok "I6: grub.d: one enforcing (test) entry per kernel (2/2), titled and id'd as such" \
        || bad "I6: grub.d: want 2 test entries, got menuentry=${n_me} titled=${n_t}: $(cat "${GT12}/out")"
    [ "$(grep -c '^[[:space:]]*linux ' "${GT12}/out")" = 2 ] && [ "$(grep -c -- ' enforcing=1$' "${GT12}/out")" = 2 ] \
        && ok "I6: grub.d: every test linux line ENDS in enforcing=1 (the kernel takes the last)" \
        || bad "I6: grub.d: enforcing=1 not last on every linux line: $(grep 'linux ' "${GT12}/out")"
    grep -Eq '^submenu|recovery mode|savedefault|gnulinux-simple' "${GT12}/out" \
        && bad "I6: grub.d: emitted a submenu / recovery / savedefault / the plain entry" || ok "I6: grub.d: flat test entries only"
    [ ! -s "${GT12}/err" ] && ok "I6: grub.d: quiet on stderr" || bad "I6: grub.d stderr: $(cat "${GT12}/err")"
    rm "${GT12}/10_linux"
    sh "${GT12}/12_selinux_enforcing_test" > "${GT12}/out" 2>&1; rc=$?
    [ "${rc}" = 0 ] && [ ! -s "${GT12}/out" ] && ok "I6: grub.d: no 10_linux -> nothing, exit 0" || bad "I6: grub.d without 10_linux rc=${rc}"
    grep -i hugmesh "${GD12}" >/dev/null && bad "I6: grub.d test snippet carries the brand name" || ok "I6: grub.d test snippet is brand-neutral"
fi
l_gd12="$(ln_of '^[0-9]+:install -D -m 0755 "\$\{SPECS_DIR\}/etc/grub.d/12_selinux_enforcing_test"')"
[ -n "${l_gd12}" ] && [ "${l_gd12}" -lt "${l_sto}" ] && ok "I6: the x86 builder installs 12_selinux_enforcing_test before the label pass" \
    || bad "I6: the x86 builder does not install etc/grub.d/12_selinux_enforcing_test (line=${l_gd12:-none})"

# I7) ARM extlinux images (Frite, Jetson, six Orange Pis): render each template, then
# run that board's OWN installer root= seds over it.
for tmpl in "${REPO}"/specs-*/boot/extlinux.conf.tmpl; do
    brd="${tmpl#"${REPO}"/specs-}"; brd="${brd%%/*}"
    R="${TMP}/ext-${brd}.conf"
    # every @@X_APPEND@@ gets a realistic medium cmdline, every other token a dummy
    sed -E -e 's/@@[A-Z0-9]+_APPEND@@/console=ttyS0 lsm=lockdown,yama,selinux selinux=1 audit=1 root=LABEL=BRD_ROOT/g' \
           -e 's/@@[A-Z0-9]+_INITRD_LINE@@/    INITRD \/initrd.img/g' -e 's/@@[A-Za-z0-9_]+@@/X/g' "${tmpl}" > "${R}"
    def="$(sed -n 's/^DEFAULT[[:space:]]\{1,\}//p' "${R}" | head -1)"
    # label_field <label> <KEY> -> the value of KEY inside LABEL <label>
    label_field() { awk -v L="$1" -v K="$2" '$1=="LABEL"{cur=$2; next} cur==L && $1==K {sub(/^[[:space:]]*[A-Z]+[[:space:]]+/,""); print; exit}' "${R}"; }
    d_app="$(label_field "${def}" APPEND)"; d_lin="$(label_field "${def}" LINUX)"; d_fdt="$(label_field "${def}" FDT)"; d_ini="$(label_field "${def}" INITRD)"
    r_lbl="$(awk '$1=="LABEL"{l=$2} $1=="APPEND" && / enforcing=0$/{print l; exit}' "${R}")"
    t_lbl="$(awk '$1=="LABEL"{l=$2} $1=="APPEND" && / enforcing=1$/{print l; exit}' "${R}")"
    if [ -z "${def}" ] || [ -z "${d_app}" ]; then bad "I7: ${brd}: no DEFAULT label / APPEND in the rendered template"; continue; fi
    case " ${d_app} " in *" enforcing="*) bad "I7: ${brd}: the DEFAULT label's APPEND carries enforcing=" ;; *) ok "I7: ${brd}: DEFAULT ${def} unchanged (no enforcing=)" ;; esac
    if [ -n "${r_lbl}" ] && [ -n "${t_lbl}" ] && [ "${r_lbl}" != "${def}" ] && [ "${t_lbl}" != "${def}" ] \
       && [ "$(label_field "${r_lbl}" APPEND)" = "${d_app} enforcing=0" ] && [ "$(label_field "${t_lbl}" APPEND)" = "${d_app} enforcing=1" ] \
       && [ "$(label_field "${r_lbl}" LINUX)" = "${d_lin}" ] && [ "$(label_field "${t_lbl}" LINUX)" = "${d_lin}" ] \
       && [ "$(label_field "${r_lbl}" FDT)" = "${d_fdt}" ] && [ "$(label_field "${t_lbl}" FDT)" = "${d_fdt}" ] \
       && [ "$(label_field "${r_lbl}" INITRD)" = "${d_ini}" ] && [ "$(label_field "${t_lbl}" INITRD)" = "${d_ini}" ]; then
        ok "I7: ${brd}: a permissive rescue (${r_lbl}) and an enforcing (test) (${t_lbl}) label, same kernel/FDT/initrd/cmdline as the default + one token"
    else
        bad "I7: ${brd}: rescue/test labels missing or diverge from the default (rescue=${r_lbl:-none} test=${t_lbl:-none}): $(grep -E '^(LABEL|    (APPEND|LINUX|FDT|INITRD))' "${R}")"
    fi
    grep -E '^MENU TITLE ' "${R}" >/dev/null && ok "I7: ${brd}: MENU TITLE present (U-Boot's pxe parser sets prompt=1 on it, so the menu is offered)" \
        || bad "I7: ${brd}: no MENU TITLE: U-Boot would boot the default without offering the SELinux labels"
    # The installers re-point root= (PARTUUID / LUKS mapper / Frite's ROOT_ARG). Run
    # every root= sed the board's installer carries, as written, over the rendered file.
    inst="$(ls "${REPO}/specs-${brd}/installer/"install*.sh 2>/dev/null | head -1)"
    [ -n "${inst}" ] || { [ "${brd}" = jetson ] && ok "I7: jetson: no installer (the root= is rendered at build time)"; continue; }
    # Every root= sed, whatever its address (a `0,/root=/` address would rewrite only
    # the first label), and none may hide in a spelling this extraction misses.
    sedx="$(grep -vE '^[[:space:]]*#' "${inst}" | grep -oE 'sed -i -E "[^"]*root=\[\^ \]\+#[^"]*"')"
    [ -n "${sedx}" ] || { bad "I7: ${brd}: no root= sed found in ${inst##*/}"; continue; }
    n_sed_lines="$(grep -vE '^[[:space:]]*#' "${inst}" | grep -E 'sed .*root=' | grep -vcE '^[[:space:]]*(grep|echo|printf)')"
    [ "$(printf '%s\n' "${sedx}" | wc -l)" = "${n_sed_lines}" ] \
        || bad "I7: ${brd}: ${inst##*/} has ${n_sed_lines} sed line(s) touching root= but only $(printf '%s\n' "${sedx}" | wc -l) were extracted and run"
    while IFS= read -r one; do
        expr="${one#sed -i -E }"; IR="${R}.inst"
        ( ROOT_PARTUUID=PU-02 LUKS_UUID=LU ROOT_ARG='root=PARTUUID=PU-02'
          eval "sed -E ${expr}" ) < "${R}" > "${IR}"
        want="$(eval "ROOT_PARTUUID=PU-02 LUKS_UUID=LU ROOT_ARG='root=PARTUUID=PU-02'; printf '%s' ${expr}" | sed -E 's/^.*root=\[\^ \]\+#//; s/#$//')"
        n_new="$(grep -E '^[[:space:]]*APPEND ' "${IR}" | grep -cF -- "${want}")"; n_old="$(grep -E '^[[:space:]]*APPEND ' "${IR}" | grep -c 'root=LABEL=BRD_ROOT')"
        [ "${n_new}" = 3 ] && [ "${n_old}" = 0 ] \
            && ok "I7: ${brd}: installer sed '${want%% *}…' re-points root= on all three labels (default, rescue, test)" \
            || bad "I7: ${brd}: installer sed left ${n_old} label(s) on the medium root= (new root on ${n_new}/3)"
    done <<<"${sedx}"
done

# I8) Raspberry Pi (no boot menu): the rescue/trial FILES, derived from the final
# cmdline.txt/config.txt. The builder's and the installer's functions EXECUTED on one
# fixture; both must agree byte for byte.
RPI="${REPO}/build-rpi5-stage4.sh"; RPII="${REPO}/specs-rpi5/installer/install.sh"
for src in "${RPI}" "${RPII}"; do
    tag="$(basename "${src}")"; RD="${TMP}/rpi-${tag}"; mkdir -p "${RD}"
    awk '/^rpi_selinux_boot_variants\(\) \{/{f=1} f{print} f&&/^}/{exit}' "${src}" > "${RD}/fn.sh"
    printf 'console=serial0,115200 root=PARTUUID=abcd-02 rootfstype=ext4 rootwait selinux=1 audit=1\n' > "${RD}/cmdline.txt"
    printf '[all]\narm_boost=1\n# initramfs disk-initrd.img followkernel\n' > "${RD}/config.txt"
    ( err() { echo "ERR: $*" >&2; }; . "${RD}/fn.sh"; rpi_selinux_boot_variants "${RD}" ) > "${RD}/out" 2>&1; rc=$?
    B='console=serial0,115200 root=PARTUUID=abcd-02 rootfstype=ext4 rootwait selinux=1 audit=1'
    [ "${rc}" = 0 ] && [ "$(cat "${RD}/cmdline-rescue.txt")" = "${B} enforcing=0" ] && [ "$(cat "${RD}/cmdline-enforcing-test.txt")" = "${B} enforcing=1" ] \
        && [ "$(cat "${RD}/cmdline.txt")" = "${B}" ] \
        && ok "I8: ${tag}: cmdline-rescue.txt / cmdline-enforcing-test.txt = the final cmdline.txt + enforcing=0/1; cmdline.txt untouched" \
        || bad "I8: ${tag}: rc=${rc} rescue='$(cat "${RD}/cmdline-rescue.txt" 2>/dev/null)' test='$(cat "${RD}/cmdline-enforcing-test.txt" 2>/dev/null)' $(cat "${RD}/out")"
    head -3 "${RD}/tryboot.txt" 2>/dev/null | cmp -s - "${RD}/config.txt" && [ "$(tail -1 "${RD}/tryboot.txt")" = 'cmdline=cmdline-enforcing-test.txt' ] \
        && [ "$(tail -2 "${RD}/tryboot.txt" | head -1)" = '[all]' ] && ! grep -q '^cmdline=' "${RD}/config.txt" \
        && ok "I8: ${tag}: tryboot.txt = config.txt + an [all] cmdline=cmdline-enforcing-test.txt (config.txt itself never selects a SELinux cmdline)" \
        || bad "I8: ${tag}: tryboot.txt wrong: $(cat "${RD}/tryboot.txt" 2>/dev/null)"
    printf 'root=PARTUUID=abcd-02 enforcing=1\n' > "${RD}/cmdline.txt"
    ( err() { echo "ERR: $*" >&2; }; . "${RD}/fn.sh"; rpi_selinux_boot_variants "${RD}" ) > "${RD}/out2" 2>&1; rc=$?
    [ "${rc}" != 0 ] && ok "I8: ${tag}: refuses a cmdline.txt that already carries enforcing= (a stale rescue would boot enforcing)" \
        || bad "I8: ${tag}: accepted a cmdline.txt with enforcing= already on it"
done
for f in cmdline-rescue.txt cmdline-enforcing-test.txt tryboot.txt; do
    cmp -s "${TMP}/rpi-build-rpi5-stage4.sh/${f}" "${TMP}/rpi-install.sh/${f}" || bad "I8: builder and installer derive different ${f}"
done
cmp -s "${TMP}/rpi-build-rpi5-stage4.sh/tryboot.txt" "${TMP}/rpi-install.sh/tryboot.txt" && ok "I8: builder and installer functions produce identical files"
RNC="${TMP}/rpi.nc"; grep -nvE '^[[:space:]]*#' "${RPI}" > "${RNC}"
r_ln() { { grep -E -- "$1" "${RNC}" || true; } | cut -d: -f1; }
r_ren="$(r_ln 'render_template "\$\{SPECS_DIR\}/boot/cmdline.txt.tmpl"  "\$\{SYSROOT\}/boot/cmdline.txt"' | head -1)"
r_sys="$(r_ln 'rpi_selinux_boot_variants "\$\{SYSROOT\}/boot"' | head -1)"
r_fst="$(r_ln '"\$\{root_mnt\}/etc/fstab"$' | tail -1)"
r_cml="$(r_ln '"\$\{root_mnt\}/boot/cmdline.txt"' | tail -1)"
r_img="$(r_ln 'rpi_selinux_boot_variants "\$\{root_mnt\}/boot"' | head -1)"
r_tar="$(r_ln 'local fs_tar=' | head -1)"
[ -n "${r_ren}" ] && [ -n "${r_sys}" ] && [ "${r_sys}" -gt "${r_ren}" ] && [ "${r_sys}" -lt $((r_ren + 4)) ] \
    && ok "I8: rpi5 builder derives the SELinux boot files right after rendering cmdline.txt into the sysroot (the stage4/installer source)" \
    || bad "I8: rpi5 sysroot derivation missing/misplaced (render=${r_ren:-?} derive=${r_sys:-none})"
[ -n "${r_img}" ] && [ -n "${r_cml}" ] && [ -n "${r_fst}" ] && [ "${r_img}" -gt "${r_cml}" ] && [ "${r_img}" -gt "${r_fst}" ] && [ "${r_img}" -lt "${r_tar}" ] \
    && ok "I8: rpi5 build_img re-derives them AFTER its last cmdline.txt/fstab rewrite and before the fs tarball" \
    || bad "I8: rpi5 build_img derivation missing/misplaced (last-cmdline-edit=${r_cml:-?} fstab=${r_fst:-?} derive=${r_img:-none} tar=${r_tar:-?})"
i_der="$(grep -n '^rpi_selinux_boot_variants /mnt/rpi-boot$' "${RPII}" | head -1 | cut -d: -f1)"
i_last="$(grep -nE '/mnt/rpi-boot/(cmdline|config)\.txt' "${RPII}" | grep -vE '^[0-9]+:[[:space:]]*#' | tail -1 | cut -d: -f1)"
i_sync="$(grep -n '^sync$' "${RPII}" | head -1 | cut -d: -f1)"
[ -n "${i_der}" ] && [ -n "${i_last}" ] && [ -n "${i_sync}" ] && [ "${i_der}" -gt "${i_last}" ] && [ "${i_der}" -lt "${i_sync}" ] \
    && ok "I8: rpi5 installer re-derives them after its last cmdline.txt/config.txt edit (NVMe/LUKS root=) and before sync" \
    || bad "I8: rpi5 installer derivation missing/misplaced (last-edit=${i_last:-?} derive=${i_der:-none} sync=${i_sync:-?})"

# I9) Cross-built python extensions under the BUILD host's suffix (#944 prove lane,
# 2026-11-11): the rpi5 image shipped _semanage.cpython-314-x86_64-linux-gnu.so, an
# aarch64 ELF, so the target python could not import it and `semanage login` (the
# root login mapping) failed on first boot; a Frite sysroot had the same for
# _selinux (a top-level symlink into selinux/). slx_fix_cross_python_ext EXECUTED.
echo "-- I9) cross-built python extensions get the target's suffix --"
PX="${TMP}/pyext"; SP="${PX}/usr/lib/python3.14/site-packages"; mkdir -p "${SP}/selinux"
mk_elf() {  # mk_elf <path> <e_machine-low-byte, octal> [class] [data]
    { printf '\177ELF'; printf "\\$(printf '%03o' "${3:-2}")\\$(printf '%03o' "${4:-1}")\\001"
      printf '\000%.0s' 1 2 3 4 5 6 7 8 9; printf '\003\000'; printf "\\$2\\000"
      head -c 64 /dev/zero; } > "$1"
}
X=cpython-314-x86_64-linux-gnu.so; A=cpython-314-aarch64-linux-gnu.so
mk_elf "${SP}/_semanage.${X}" 267                       # 0xb7 = EM_AARCH64 (183)
mk_elf "${SP}/selinux/_selinux.${X}" 267
ln -s "selinux/_selinux.${X}" "${SP}/_selinux.${X}"
mk_elf "${SP}/_audit.so" 267                            # the plain .so imports already
mk_elf "${SP}/_hostlib.${X}" 076                        # 0x3e = EM_X86_64: a real host ELF
mk_elf "${SP}/_twin.${X}" 267; mk_elf "${SP}/_twin.${A}" 267; cp "${SP}/_twin.${A}" "${PX}/twin.before"
printf 'not an elf\n' > "${SP}/_text.${X}"
mk_elf "${SP}/_be.${X}" 267 2 2                         # big-endian: not ours to judge
ln -s "/usr/lib/python3.14/site-packages/selinux/_selinux.${X}" "${SP}/_abs.${X}"   # absolute = sysroot-relative
ln -s "nowhere.${X}" "${SP}/_dangle.${X}"
o="$( . "${LIB}"; slx_fix_cross_python_ext "${PX}" aarch64 2>&1 )"; rc=$?
[ "${rc}" = 0 ] && ok "I9: slx_fix_cross_python_ext returns 0 on a mixed tree" || bad "I9: rc=${rc}: ${o}"
[ -L "${SP}/_semanage.${A}" ] && [ "$(readlink "${SP}/_semanage.${A}")" = "_semanage.${X}" ] \
    && ok "I9: _semanage (aarch64 ELF, x86_64 suffix) gets its ${A} twin, linked to the original" \
    || bad "I9: no ${A} twin for _semanage: $(ls -la "${SP}" | grep semanage)"
[ -L "${SP}/selinux/_selinux.${A}" ] && [ -L "${SP}/_selinux.${A}" ] && [ -f "$(readlink -f "${SP}/_selinux.${A}")" ] \
    && ok "I9: _selinux: the file in selinux/ AND the top-level symlink both get a twin, and the top-level one resolves" \
    || bad "I9: _selinux twins missing or dangling: $(ls -la "${SP}" "${SP}/selinux" | grep _selinux)"
[ -L "${SP}/_abs.${A}" ] && ok "I9: an absolute symlink is resolved inside the sysroot, not on the build host" || bad "I9: absolute-link entry not handled: ${o}"
[ ! -e "${SP}/_hostlib.${A}" ] && ok "I9: a real x86_64 ELF is left alone (only reported)" || bad "I9: a host-machine ELF got an aarch64 twin"
[ ! -e "${SP}/_text.${A}" ] && [ ! -e "${SP}/_be.${A}" ] && ! [ -L "${SP}/_dangle.${A}" ] \
    && ok "I9: non-ELF, big-endian and dangling entries are left alone" || bad "I9: a non-ELF/big-endian/dangling entry got a twin"
[ ! -L "${SP}/_twin.${A}" ] && cmp -s "${SP}/_twin.${A}" "${PX}/twin.before" \
    && ok "I9: an existing target-suffixed twin is never replaced" || bad "I9: the existing _twin.${A} was replaced"
[ ! -e "${SP}/_audit.cpython-314-aarch64-linux-gnu.so" ] && [ -f "${SP}/_audit.so" ] && [ -e "${SP}/_semanage.${X}" ] \
    && ok "I9: nothing is renamed or removed (plain .so and the originals stay)" || bad "I9: an original was renamed/removed"
n1="$(find "${PX}" | sort | md5sum)"
o="$( . "${LIB}"; slx_fix_cross_python_ext "${PX}" aarch64 2>&1 )"; rc=$?
[ "${rc}" = 0 ] && [ "$(find "${PX}" | sort | md5sum)" = "${n1}" ] \
    && ok "I9: a second run is a no-op (idempotent)" || bad "I9: second run rc=${rc} or changed the tree: ${o}"
( . "${LIB}"; slx_fix_cross_python_ext "${PX}" riscv64 ) >/dev/null 2>&1 \
    && bad "I9: an unsupported target arch returned 0" || ok "I9: an unsupported target arch fails the call"
for b in "${ALL_BUILDERS[@]}"; do
    bn="${b##*/}"; bnc="${TMP}/${bn}.nc9"; grep -nvE '^[[:space:]]*#' "${b}" > "${bnc}"
    l_fix="$({ grep -E -m1 '^[0-9]+:slx_fix_cross_python_ext "\$\{SYSROOT\}" aarch64 \\$' "${bnc}" || true; } | cut -d: -f1)"
    l_ffl="$({ grep -E -m1 '^[0-9]+:    \|\| \{ err "could not give the cross-built python extensions' "${bnc}" || true; } | cut -d: -f1)"
    if [ "${bn}" = build-x86-host-stage4.sh ]; then
        [ -z "${l_fix}" ] && ok "I9: ${bn} (native build) does not call it" || bad "I9: the native x86 builder calls the cross-suffix fix"
        continue
    fi
    l_emg="$({ grep -E '^[0-9]+:[[:space:]]*(if ! )?cross_emerge ' "${bnc}" || true; } | tail -1 | cut -d: -f1)"
    l_frz="$({ grep -E -m1 '^[0-9]+:slx_store_install_modules "\$\{SYSROOT\}"' "${bnc}" || true; } | cut -d: -f1)"
    [ -n "${l_frz}" ] || l_frz="$({ grep -E -m1 '^[0-9]+:STAGE4(_TARBALL)?="\$\{WORK_DIR\}' "${bnc}" || true; } | cut -d: -f1)"
    [ -n "${l_fix}" ] && [ -n "${l_ffl}" ] && [ "${l_ffl}" = $((l_fix + 1)) ] && [ -n "${l_emg}" ] && [ "${l_emg}" -lt "${l_fix}" ] \
        && [ -n "${l_frz}" ] && [ "${l_fix}" -lt "${l_frz}" ] \
        && ok "I9: ${bn} fixes python extension suffixes after its last cross-emerge and before its sysroot is labelled/packed (fatal)" \
        || bad "I9: ${bn}: fix=${l_fix:-none} fail-line=${l_ffl:-none} last-cross-emerge=${l_emg:-?} frozen-at=${l_frz:-?}"
done

echo
echo "== selinux sysroot labels: ${P} passed, ${F} failed, ${S} skipped (skips are NOT passes) =="
[ "${F}" -eq 0 ]
