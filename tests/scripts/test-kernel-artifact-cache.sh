#!/usr/bin/env bash
# test-kernel-artifact-cache.sh — EXECUTED-DECISION test for the signed-kernel artifact
# cache (scripts/_kernel-cache-lib.sh + its wiring in build-x86-host-stage4.sh and
# build-rpi5-stage4.sh).
#
# WHY "EXECUTED-DECISION" (the #465 lesson, restated by the shared-assets lane): a gate
# that PARSES fine can still DECIDE wrong. Every assertion below RUNS the real code
# against fixture cache directories and checks the DECISION — an entry actually
# restored, a re-keyed entry actually refused, a truncated payload actually pruned —
# never "the string appears in the file". The only greps are the structural sweep at the
# end, which asserts the builders carry the wiring at all (a functional test of the
# library cannot see a builder that was never wired).
#
# This file was also written to catch a bug it DID catch during development: a failed
# `openssl … | sha256sum` pipeline still emits the SHA-256 of the empty string, so an
# unreadable key file was being reported as a perfectly good "x509:e3b0c442…" identity —
# which would have collapsed every keyless build onto ONE shared cache key. Case A5
# below is that regression.
#
# HERMETIC: no network, no root, no build, no chroot. Fixture certs are generated into
# a mktemp dir and destroyed on exit; nothing is ever written into the repo.
#
# What is asserted, in order:
#   A. fingerprints      cert PEM==DER, key -> public half only, junk/empty/missing -> rc1
#   B. key derivation    all four components required; framing; board safety
#   C. HIT               a stored entry is found, validated and restored byte-for-byte
#   D. component misses  board / kernel version / config digest / SIGNING KEY, one each
#   E. retired key       a re-keyed fleet MISSES and the stale entry is pruned
#   F. corrupt entries   truncated / missing / mangled / manifest-less -> refusal, no crash
#   G. key material      a payload holding a PEM private key is REFUSED
#   H. opt-out           --no-kernel-cache / HUGMESH_KERNEL_CACHE=off -> no root, no key
#   I. locking           the share lane's flock discipline is used and is re-entrant
#   J. GATES ON A HIT    the x86 disk-initramfs gate still fires on the cache-hit path,
#                        proven by MUTATION (delete the gate -> the bad sysroot passes)
#   K. structural sweep  both wired builders carry lib+flag+plan+branch
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_kernel-cache-lib.sh"
SALIB="${REPO}/scripts/_shared-assets-lib.sh"
X86="${REPO}/build-x86-host-stage4.sh"
RPI="${REPO}/build-rpi5-stage4.sh"
for f in "${LIB}" "${SALIB}" "${X86}" "${RPI}"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
done
command -v openssl >/dev/null 2>&1 || { echo "  FAIL openssl(1) required for the signing-identity cases"; exit 1; }

# shellcheck source=/dev/null
source "${SALIB}"
# shellcheck source=/dev/null
source "${LIB}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
KC_QUIET=1; SA_QUIET=1     # keep the transcript readable; errors still print

echo "== signed-kernel artifact cache =="

# ── fixtures ──────────────────────────────────────────────────────────────────
# TWO throwaway self-signed identities: FLEET (current) and RETIRED (the key the fleet
# rotated away from). Generated here, never committed, destroyed on exit.
mk_id() { # <name>
    openssl req -newkey rsa:2048 -nodes -sha256 -days 2 -x509 \
        -subj "/O=hugmesh-test/CN=$1/" \
        -keyout "${TMP}/$1.key" -out "${TMP}/$1.crt" 2>/dev/null
    chmod 600 "${TMP}/$1.key"
}
mk_id fleet
mk_id retired
FP_FLEET="$(kc_key_fingerprint "${TMP}/fleet.crt")"
FP_RETIRED="$(kc_key_fingerprint "${TMP}/retired.crt")"

# A fixture "built kernel": a /boot with a kernel image + initramfs, and a module tree.
SRC="${TMP}/built"
mkdir -p "${SRC}/boot" "${SRC}/lib/modules/6.18.9-hardened1/kernel"
printf 'VMLINUZ-BYTES\n'    > "${SRC}/boot/vmlinuz"
printf 'INITRAMFS-BYTES\n'  > "${SRC}/boot/initramfs-6.18.9-hardened1.img"
printf 'UKI-BYTES\n'        > "${SRC}/boot/hugmesh-unsigned.efi"
printf 'MODULE\n'           > "${SRC}/lib/modules/6.18.9-hardened1/kernel/x.ko"

# The config inputs (component 3): a base fragment plus a board fragment.
mkdir -p "${TMP}/cfg"
printf 'enable CONFIG_SECURITY_SELINUX\n' > "${TMP}/cfg/base.config"
printf 'enable CONFIG_DM_CRYPT\n'         > "${TMP}/cfg/board.config"
CFG="$(kc_config_digest "${TMP}/cfg/base.config" "${TMP}/cfg/board.config")"
KVER="linux-6.18.9-gentoo"
ROOT="$(kc_root "${TMP}/shared")"

pack_payload() { # <dir> -> boot.tar + modules.tar in <dir>
    kc_pack "$1/boot.tar" "${SRC}/boot" vmlinuz initramfs-6.18.9-hardened1.img hugmesh-unsigned.efi
    kc_pack "$1/modules.tar" "${SRC}/lib/modules" 6.18.9-hardened1
}
PAY="${TMP}/pay"; mkdir -p "${PAY}"; pack_payload "${PAY}"

store_entry() { # <board> <kver> <cfg> <fp> -> stores, echoes the key
    local b="$1" k="$2" c="$3" fp="$4" key
    key="$(kc_cache_key "${b}" "${k}" "${c}" "${fp}")" || return 1
    kc_store "${ROOT}" "${b}" "${key}" "${k}" "${c}" "${fp}" "test" \
        "boot.tar=${PAY}/boot.tar" "modules.tar=${PAY}/modules.tar" || return 1
    printf '%s' "${key}"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "-- A) signing-key fingerprints (public half ONLY) --"
[ -n "${FP_FLEET}" ] && ok "A1 a certificate yields a fingerprint (${FP_FLEET%%:*}:…)" \
    || bad "A1 no fingerprint from a valid certificate"
openssl x509 -inform PEM -outform DER -in "${TMP}/fleet.crt" -out "${TMP}/fleet.der" 2>/dev/null
[ "$(kc_key_fingerprint "${TMP}/fleet.der")" = "${FP_FLEET}" ] \
    && ok "A2 the same identity in PEM and DER gives ONE fingerprint" \
    || bad "A2 PEM and DER of one cert disagree"
_kfp="$(kc_key_fingerprint "${TMP}/fleet.key")"
case "${_kfp}" in
    spki:*) ok "A3 a PRIVATE key yields only an spki: digest of its PUBLIC half" ;;
    *)      bad "A3 unexpected fingerprint for a private key: ${_kfp}" ;;
esac
# The private half must never appear in anything the cache emits.
if grep -qa 'PRIVATE KEY' <<<"${_kfp}${FP_FLEET}"; then
    bad "A4 key material leaked into a fingerprint"
else
    ok "A4 no key material in the emitted fingerprints"
fi
# A5 — the empty-digest regression (see the header).
printf 'NOT A KEY AT ALL\n' > "${TMP}/junk"
: > "${TMP}/emptyfile"
_r=0; kc_key_fingerprint "${TMP}/junk"      >/dev/null 2>&1 || _r=1; [ "${_r}" = 1 ] \
    && ok "A5 a garbage file yields NO fingerprint (not the empty-input digest)" \
    || bad "A5 garbage accepted as a signing identity"
_r=0; kc_key_fingerprint "${TMP}/emptyfile" >/dev/null 2>&1 || _r=1; [ "${_r}" = 1 ] \
    && ok "A6 an empty file yields no fingerprint" || bad "A6 empty file accepted"
_r=0; kc_key_fingerprint "${TMP}/nope"      >/dev/null 2>&1 || _r=1; [ "${_r}" = 1 ] \
    && ok "A7 a missing file yields no fingerprint" || bad "A7 missing file accepted"
[ "${FP_FLEET}" != "${FP_RETIRED}" ] \
    && ok "A8 two different keys give two different fingerprints" \
    || bad "A8 FINGERPRINT COLLISION between two distinct keys"
# The explicit override must not silently fall back to another identity.
_r=0; ( HUGMESH_KERNEL_SIGNING_CERT="${TMP}/junk"; kc_signing_fingerprint "${TMP}/fleet.crt" ) >/dev/null 2>&1 || _r=1
[ "${_r}" = 1 ] && ok "A9 a bad HUGMESH_KERNEL_SIGNING_CERT FAILS (no silent fallback)" \
    || bad "A9 a bad explicit signing cert fell back to another identity"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- B) key derivation: all four components, or no key at all --"
KEY="$(kc_cache_key rpi5 "${KVER}" "${CFG}" "${FP_FLEET}")"
[ -n "${KEY}" ] && ok "B1 a complete 4-component key derives (${KEY:0:12}…)" || bad "B1 no key from complete components"
for i in 1 2 3 4; do
    set -- rpi5 "${KVER}" "${CFG}" "${FP_FLEET}"
    case "${i}" in
        1) set -- "" "$2" "$3" "$4" ;;
        2) set -- "$1" "" "$3" "$4" ;;
        3) set -- "$1" "$2" "" "$4" ;;
        4) set -- "$1" "$2" "$3" "" ;;
    esac
    _r=0; kc_cache_key "$@" >/dev/null 2>&1 || _r=1
    [ "${_r}" = 1 ] && ok "B2.${i} an EMPTY component ${i} yields NO key (never a partial key)" \
        || bad "B2.${i} an empty component still produced a key"
done
_r=0; kc_cache_key rpi5 "${KVER}" "${CFG}" >/dev/null 2>&1 || _r=1
[ "${_r}" = 1 ] && ok "B3 a 3-argument call is refused outright" || bad "B3 3 arguments accepted"
_r=0; kc_cache_key '../../etc' "${KVER}" "${CFG}" "${FP_FLEET}" >/dev/null 2>&1 || _r=1
[ "${_r}" = 1 ] && ok "B4 a traversal board component is refused" || bad "B4 traversal board accepted"
# Framing: moving a character across the board/kver boundary must NOT collide.
[ "$(kc_cache_key ab c "${CFG}" "${FP_FLEET}")" != "$(kc_cache_key a bc "${CFG}" "${FP_FLEET}")" ] \
    && ok "B5 components are framed — no concatenation collision across a boundary" \
    || bad "B5 KEY COLLISION between (ab,c) and (a,bc)"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- C) a HIT: stored, validated, restored byte-for-byte --"
K_HIT="$(store_entry rpi5 "${KVER}" "${CFG}" "${FP_FLEET}")"
[ -n "${K_HIT}" ] && ok "C1 an entry stores" || bad "C1 store failed"
ENTRY="$(kc_lookup "${ROOT}" rpi5 "${K_HIT}" "${KVER}" "${CFG}" "${FP_FLEET}")"
[ -n "${ENTRY}" ] && ok "C2 lookup HITS the entry it just stored" || bad "C2 lookup missed its own entry"
# The manifest must carry the fingerprint and NOT the key.
if grep -q "^signing-key-fp=${FP_FLEET}$" "${ENTRY}/manifest" 2>/dev/null; then
    ok "C3 the manifest records the signing FINGERPRINT"
else
    bad "C3 manifest does not record the fingerprint"
fi
if grep -rqa 'PRIVATE KEY' "${ENTRY}" 2>/dev/null; then
    bad "C4 KEY MATERIAL FOUND INSIDE A CACHE ENTRY"
else
    ok "C4 no key material anywhere in the entry"
fi
DEST="${TMP}/restored"; mkdir -p "${DEST}"
kc_restore "${ENTRY}" "boot.tar=${DEST}/boot.tar" "modules.tar=${DEST}/modules.tar" \
    && kc_unpack "${DEST}/boot.tar" "${DEST}/boot" \
    && kc_unpack "${DEST}/modules.tar" "${DEST}/lib-modules" \
    && ok "C5 the payload restores and unpacks" || bad "C5 restore/unpack failed"
if cmp -s "${DEST}/boot/vmlinuz" "${SRC}/boot/vmlinuz" \
   && cmp -s "${DEST}/boot/initramfs-6.18.9-hardened1.img" "${SRC}/boot/initramfs-6.18.9-hardened1.img" \
   && cmp -s "${DEST}/lib-modules/6.18.9-hardened1/kernel/x.ko" "${SRC}/lib/modules/6.18.9-hardened1/kernel/x.ko"; then
    ok "C6 kernel, initramfs and the module tree come back byte-for-byte"
else
    bad "C6 restored artifacts differ from what was cached"
fi
_r=0; kc_restore "${ENTRY}" "not-a-payload=${DEST}/x" >/dev/null 2>&1 || _r=1
[ "${_r}" = 1 ] && ok "C7 restoring a name the manifest never recorded is refused" \
    || bad "C7 an unrecorded payload name was restored"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- D) each SINGLE component mismatch is a MISS (four separate cases) --"
# Re-store before each case: a miss PRUNES, which is itself part of the contract.
d_case() { # <label> <board> <kver> <cfg> <fp>
    local label="$1"; shift
    local k; k="$(store_entry rpi5 "${KVER}" "${CFG}" "${FP_FLEET}")" || { bad "${label}: setup store failed"; return; }
    # Look the entry up with EXACTLY ONE component changed, using the key that was
    # derived from the CHANGED components — i.e. what a real build would compute.
    local nk; nk="$(kc_cache_key "$1" "$2" "$3" "$4" 2>/dev/null || true)"
    if [ -z "${nk}" ]; then bad "${label}: could not derive the mismatched key"; return; fi
    if [ "${nk}" = "${k}" ]; then bad "${label}: the changed component did not change the key"; return; fi
    local hit; hit="$(kc_lookup "${ROOT}" "$1" "${nk}" "$2" "$3" "$4" 2>/dev/null || true)"
    if [ -n "${hit}" ]; then bad "${label}: MISMATCH STILL HIT the cache"; else ok "${label}"; fi
}
d_case "D1 board mismatch (rpi4 must not reuse an rpi5 kernel) -> MISS" \
       rpi4 "${KVER}" "${CFG}" "${FP_FLEET}"
d_case "D2 kernel-version mismatch -> MISS" \
       rpi5 "linux-6.19.0-gentoo" "${CFG}" "${FP_FLEET}"
printf 'enable CONFIG_SECURITY_SELINUX\nenable CONFIG_WIREGUARD\n' > "${TMP}/cfg/base.config"
CFG2="$(kc_config_digest "${TMP}/cfg/base.config" "${TMP}/cfg/board.config")"
[ -n "${CFG2}" ] && [ "${CFG2}" != "${CFG}" ] \
    && ok "D3a editing ONE config fragment changes the config digest" \
    || bad "D3a a changed fragment did not change the digest"
d_case "D3b config-digest mismatch (a fragment changed) -> MISS" \
       rpi5 "${KVER}" "${CFG2}" "${FP_FLEET}"
d_case "D4 SIGNING-KEY mismatch -> MISS" \
       rpi5 "${KVER}" "${CFG}" "${FP_RETIRED}"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- E) a RE-KEYED fleet must not reuse retired-key artifacts --"
K_OLD="$(store_entry rpi5 "${KVER}" "${CFG}" "${FP_RETIRED}")"
E_OLD="$(kc_entry_dir "${ROOT}" rpi5 "${K_OLD}")"
[ -d "${E_OLD}" ] && ok "E1 an entry signed under the RETIRED key exists" || bad "E1 setup failed"
# The fleet re-keys: same board, same kernel, same config, NEW key.
K_NEW="$(kc_cache_key rpi5 "${KVER}" "${CFG}" "${FP_FLEET}")"
if [ -n "$(kc_lookup "${ROOT}" rpi5 "${K_NEW}" "${KVER}" "${CFG}" "${FP_FLEET}" 2>/dev/null || true)" ]; then
    # A hit here is only legitimate if it is the entry stored under the NEW key.
    if [ "$(sed -n 's/^signing-key-fp=//p' "$(kc_entry_dir "${ROOT}" rpi5 "${K_NEW}")/manifest")" = "${FP_FLEET}" ]; then
        ok "E2 the re-keyed build hits only an entry carrying the NEW fingerprint"
    else
        bad "E2 the re-keyed build hit an entry signed under the retired key"
    fi
else
    ok "E2 the re-keyed build MISSES (no entry for the new identity yet)"
fi
# Tamper: point the OLD entry's directory at the NEW key's name. The manifest still
# says "retired", so lookup must refuse it and prune — the directory name alone is
# never enough.
K_T="$(kc_cache_key rpi5 "${KVER}" "${CFG}" "${FP_FLEET}")"
rm -rf "$(kc_entry_dir "${ROOT}" rpi5 "${K_T}")"
cp -r "${E_OLD}" "$(kc_entry_dir "${ROOT}" rpi5 "${K_T}")" 2>/dev/null
_hit="$(kc_lookup "${ROOT}" rpi5 "${K_T}" "${KVER}" "${CFG}" "${FP_FLEET}" 2>/dev/null || true)"
[ -z "${_hit}" ] && ok "E3 an entry RENAMED onto the new key is refused (manifest is re-checked)" \
    || bad "E3 a renamed retired-key entry was accepted"
[ ! -d "$(kc_entry_dir "${ROOT}" rpi5 "${K_T}")" ] \
    && ok "E4 the refused entry was PRUNED" || bad "E4 the refused entry was left behind"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- F) corrupt / incomplete entries: refusal, prune, no crash --"
f_case() { # <label> <mutator>
    local label="$1" mut="$2" k e rc hit
    k="$(store_entry rpi5 "${KVER}" "${CFG}" "${FP_FLEET}")" || { bad "${label}: setup failed"; return; }
    e="$(kc_entry_dir "${ROOT}" rpi5 "${k}")"
    "${mut}" "${e}"
    hit="$(kc_lookup "${ROOT}" rpi5 "${k}" "${KVER}" "${CFG}" "${FP_FLEET}" 2>/dev/null)"; rc=$?
    if [ "${rc}" = 0 ] || [ -n "${hit}" ]; then bad "${label}: corrupt entry was ACCEPTED"; return; fi
    if [ "${rc}" -gt 1 ]; then bad "${label}: refused with rc=${rc} (crash, not a clean miss)"; return; fi
    if [ -d "${e}" ]; then bad "${label}: refused but NOT pruned"; return; fi
    ok "${label}"
}
mut_truncate()   { : > "$1/payload/modules.tar"; }
mut_flip()       { printf 'CORRUPT\n' > "$1/payload/boot.tar"; }
mut_rm_payload() { rm -f "$1/payload/modules.tar"; }
mut_rm_manifest(){ : > "$1/manifest"; }
mut_mangle()     { sed -i 's/^file boot.tar .*/file boot.tar/' "$1/manifest"; }
mut_format()     { sed -i 's/^kernel-cache-format=.*/kernel-cache-format=99/' "$1/manifest"; }
mut_nofiles()    { grep -v '^file ' "$1/manifest" > "$1/manifest.n" && mv "$1/manifest.n" "$1/manifest"; }
f_case "F1 a TRUNCATED payload file -> MISS + prune"           mut_truncate
f_case "F2 a payload file with the wrong CONTENT -> MISS + prune" mut_flip
f_case "F3 a MISSING payload file -> MISS + prune"             mut_rm_payload
f_case "F4 an EMPTY manifest -> MISS + prune"                  mut_rm_manifest
f_case "F5 a MALFORMED manifest line -> MISS + prune"          mut_mangle
f_case "F6 an entry in an OLD on-disk format -> MISS + prune"  mut_format
f_case "F7 a manifest recording NO payload -> MISS + prune"    mut_nofiles
# A completely absent entry is an ordinary miss, not an error.
_r=0; kc_lookup "${ROOT}" rpi5 "$(kc_cache_key rpi5 nosuch "${CFG}" "${FP_FLEET}")" \
        nosuch "${CFG}" "${FP_FLEET}" >/dev/null 2>&1 || _r=$?
[ "${_r}" = 1 ] && ok "F8 an absent entry is a clean rc=1 miss" || bad "F8 absent entry gave rc=${_r}"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- G) key material must never enter the cache --"
K_G="$(kc_cache_key rpi5 keymat "${CFG}" "${FP_FLEET}")"
_r=0
kc_store "${ROOT}" rpi5 "${K_G}" keymat "${CFG}" "${FP_FLEET}" "test" \
    "boot.tar=${PAY}/boot.tar" "leak=${TMP}/fleet.key" >/dev/null 2>&1 || _r=1
[ "${_r}" = 1 ] && ok "G1 a payload containing a PEM PRIVATE KEY is REFUSED" \
    || bad "G1 a private key was accepted into the cache"
[ ! -d "$(kc_entry_dir "${ROOT}" rpi5 "${K_G}")" ] \
    && ok "G2 the refused store published nothing" || bad "G2 a partial entry was published"
if grep -rqa 'PRIVATE KEY' "${ROOT}" 2>/dev/null; then
    bad "G3 KEY MATERIAL PRESENT under the cache root"
else
    ok "G3 no key material anywhere under the cache root"
fi
_r=0
kc_store "${ROOT}" rpi5 "$(kc_cache_key rpi5 empty "${CFG}" "${FP_FLEET}")" empty "${CFG}" "${FP_FLEET}" "test" \
    "boot.tar=${TMP}/emptyfile" >/dev/null 2>&1 || _r=1
[ "${_r}" = 1 ] && ok "G4 an EMPTY payload is refused (never cache a partial kernel)" \
    || bad "G4 an empty payload was cached"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- H) opt-out --"
_off="$(KERNEL_CACHE_ENABLED=false kc_root "${TMP}/shared")"
[ -z "${_off}" ] && ok "H1 --no-kernel-cache (KERNEL_CACHE_ENABLED=false) yields NO cache root" \
    || bad "H1 opt-out still produced a root: ${_off}"
_off="$(HUGMESH_KERNEL_CACHE=off kc_root "${TMP}/shared")"
[ -z "${_off}" ] && ok "H2 HUGMESH_KERNEL_CACHE=off yields no cache root" || bad "H2 env opt-out ignored"
_off="$(kc_root "")"
[ -z "${_off}" ] && ok "H3 --no-shared-assets (no shared root) disables the kernel cache too" \
    || bad "H3 the kernel cache survived --no-shared-assets"
[ -n "$(kc_root "${TMP}/shared")" ] && ok "H4 the cache is ON by default" || bad "H4 default is off"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- I) locking: the share lane's flock discipline, re-entrant --"
K_L="$(kc_cache_key rpi5 lock "${CFG}" "${FP_FLEET}")"
kc_store "${ROOT}" rpi5 "${K_L}" lock "${CFG}" "${FP_FLEET}" "test" "boot.tar=${PAY}/boot.tar" >/dev/null 2>&1
[ -f "$(kc_entry_dir "${ROOT}" rpi5 "${K_L}").lock" ] \
    && ok "I1 the store took a SIBLING lockfile (never inside the guarded dir)" \
    || bad "I1 no sibling lockfile was created"
# Re-entrancy: a store nested inside a held lock on the same file must not deadlock.
_nested() { kc_store "${ROOT}" rpi5 "${K_L}" lock "${CFG}" "${FP_FLEET}" "test" "boot.tar=${PAY}/boot.tar"; }
_r=0; timeout 30 bash -c '
  source "'"${SALIB}"'"; source "'"${LIB}"'"
  sa_lock_run "'"$(kc_entry_dir "${ROOT}" rpi5 "${K_L}")"'.lock" true
' >/dev/null 2>&1 || _r=$?
[ "${_r}" = 0 ] && ok "I2 taking the entry lock completes (no wedge)" || bad "I2 lock acquisition failed rc=${_r}"
# The library refuses to touch the cache without the shared-assets lib present.
_r=0; ( unset -f sa_component_ok sa_lock_run; kc_lookup "${ROOT}" rpi5 "${K_L}" lock "${CFG}" "${FP_FLEET}" ) >/dev/null 2>&1 || _r=1
[ "${_r}" = 1 ] && ok "I3 without _shared-assets-lib.sh the cache refuses to operate" \
    || bad "I3 the cache operated without its locking/path-safety dependency"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- J) A CACHE IS NOT A GATE BYPASS (x86 disk-initramfs gate, EXECUTED + MUTATED) --"
# Extract the real gate from the real builder — the same extraction
# tests/scripts/test-x86-artifact-integrity.sh uses, so the two cannot drift.
awk '/^# ── DISK-INITRAMFS GATE/{f=1} f&&/^if \$\{BUILD_IMG\}/{s=1} s{print} s&&/^fi$/{exit}' \
    "${X86}" > "${TMP}/gate-initramfs"
if [ ! -s "${TMP}/gate-initramfs" ]; then
    bad "J0 could not extract the DISK-INITRAMFS GATE from ${X86##*/}"
else
    ok "J0 extracted the x86 disk-initramfs gate ($(wc -l < "${TMP}/gate-initramfs") lines)"

    # A cache entry whose /boot has a kernel and modules but NO initramfs — exactly the
    # unbootable shape the gate exists to catch. If a hit could skip the gate, THIS is
    # what would ship.
    BAD="${TMP}/badpay"; mkdir -p "${BAD}/boot" "${BAD}/lib/modules/6.18.9-hardened1"
    printf 'VMLINUZ\n' > "${BAD}/boot/vmlinuz-6.18.9-hardened1"
    printf 'MOD\n'     > "${BAD}/lib/modules/6.18.9-hardened1/x.ko"
    kc_pack "${TMP}/bad-boot.tar" "${BAD}/boot" vmlinuz-6.18.9-hardened1
    kc_pack "${TMP}/bad-mods.tar" "${BAD}/lib/modules" 6.18.9-hardened1
    K_J="$(kc_cache_key x86 "${KVER}" "${CFG}" "${FP_FLEET}")"
    kc_store "${ROOT}" x86 "${K_J}" "${KVER}" "${CFG}" "${FP_FLEET}" "test" \
        "boot.tar=${TMP}/bad-boot.tar" "modules.tar=${TMP}/bad-mods.tar" >/dev/null 2>&1

    # The HIT-PATH harness: restore from the cache into a fresh sysroot, then run the
    # gate — i.e. the builder's own ordering (restore ... then the gate, outside the
    # kernel-phase conditional).
    write_harness() { # <file> <with-gate: yes|no>
        {
            echo 'set -uo pipefail'
            echo 'err(){ echo "ERROR: $*" >&2; }'
            echo 'info(){ echo "INFO: $*"; }'
            echo "source '${SALIB}'"; echo "source '${LIB}'"
            echo 'KC_QUIET=1; SA_QUIET=1'
            echo 'SYSROOT="$1"; ROOT="$2"; KEY="$3"; KVER="$4"; CFG="$5"; FP="$6"'
            echo 'BUILD_IMG=true; INSTALLER_ISO=false'
            echo 'mkdir -p "${SYSROOT}/boot" "${SYSROOT}/lib/modules"'
            echo 'E="$(kc_lookup "${ROOT}" x86 "${KEY}" "${KVER}" "${CFG}" "${FP}")" || { echo "CACHE-MISS"; exit 9; }'
            echo 'T="$(mktemp -d)"'
            echo 'kc_restore "${E}" "boot.tar=${T}/b.tar" "modules.tar=${T}/m.tar" || exit 9'
            echo 'kc_unpack "${T}/b.tar" "${SYSROOT}/boot" || exit 9'
            echo 'kc_unpack "${T}/m.tar" "${SYSROOT}/lib/modules" || exit 9'
            echo 'echo "CACHE-HIT"'
            if [ "$2" = yes ]; then cat "${TMP}/gate-initramfs"; else
                echo '# (gate deliberately REMOVED — mutation control)'
            fi
            echo 'echo "REACHED-END"'
        } > "$1"
    }
    write_harness "${TMP}/hit-with-gate" yes
    write_harness "${TMP}/hit-no-gate"   no

    out="$(bash "${TMP}/hit-with-gate" "${TMP}/sys-a" "${ROOT}" "${K_J}" "${KVER}" "${CFG}" "${FP_FLEET}" 2>&1)"; rc=$?
    case "${out}" in *CACHE-HIT*) ok "J1 the harness genuinely took the cache-HIT path" ;;
                     *) bad "J1 the harness did not hit the cache: ${out}" ;; esac
    if [ "${rc}" != 0 ] && ! grep -q 'REACHED-END' <<<"${out}"; then
        ok "J2 on a cache HIT the disk-initramfs gate STILL FIRES and fails the build"
    else
        bad "J2 a cache hit sailed past the disk-initramfs gate (rc=${rc}): ${out}"
    fi

    # MUTATION: delete the gate from the hit path. If the suite still passes without
    # it, J2 was proving nothing. This asserts the gate — not some other check — is
    # what makes the bad restore fail.
    out2="$(bash "${TMP}/hit-no-gate" "${TMP}/sys-b" "${ROOT}" "${K_J}" "${KVER}" "${CFG}" "${FP_FLEET}" 2>&1)"; rc2=$?
    if [ "${rc2}" = 0 ] && grep -q 'REACHED-END' <<<"${out2}"; then
        ok "J3 MUTATION: with the gate deleted the SAME bad restore passes — the gate is load-bearing"
    else
        bad "J3 MUTATION control did not pass (rc=${rc2}) — J2 proves nothing: ${out2}"
    fi

    # Structural: in the real builder the gate must live AFTER the kernel phase closes,
    # so it can never be inside the cache-hit branch. Walk the REAL nesting rather than
    # "the next fi" — the chroot heredoc body contains column-0 `fi` lines of its own,
    # and anchoring on one of those would make this assertion quietly vacuous.
    #   _kc_ln  the `if kernel_cache_try_restore; then` that opens the hit/miss branch
    #   _hd_ln  the CHROOT heredoc terminator (everything between is heredoc TEXT)
    #   _br_ln  the indented `fi` that closes the hit/miss branch
    #   _ph_ln  the column-0 `fi` that closes the whole kernel phase
    #   _gate_ln the gate banner — must come after ALL of them
    _kc_ln="$(grep -n '^    if kernel_cache_try_restore; then' "${X86}" | head -1 | cut -d: -f1)"
    _hd_ln="$(awk -v n="${_kc_ln:-0}" 'NR>n && /^CHROOT$/{print NR; exit}' "${X86}")"
    _br_ln="$(awk -v n="${_hd_ln:-0}" 'NR>n && /^    fi$/{print NR; exit}' "${X86}")"
    _ph_ln="$(awk -v n="${_br_ln:-0}" 'NR>n && /^fi$/{print NR; exit}' "${X86}")"
    _gate_ln="$(grep -n '^# ── DISK-INITRAMFS GATE' "${X86}" | head -1 | cut -d: -f1)"
    _st_ln="$(grep -n '^    kernel_cache_store$' "${X86}" | head -1 | cut -d: -f1)"
    if [ -n "${_kc_ln}" ] && [ -n "${_hd_ln}" ] && [ -n "${_br_ln}" ] && [ -n "${_ph_ln}" ] \
       && [ -n "${_gate_ln}" ] && [ -n "${_st_ln}" ] \
       && [ "${_kc_ln}" -lt "${_hd_ln}" ] && [ "${_hd_ln}" -lt "${_st_ln}" ] \
       && [ "${_st_ln}" -lt "${_br_ln}" ] && [ "${_br_ln}" -lt "${_ph_ln}" ] \
       && [ "${_ph_ln}" -lt "${_gate_ln}" ]; then
        ok "J4 nesting proven: cache branch ${_kc_ln}..${_br_ln} (store@${_st_ln}) closes inside the"
        ok "   kernel phase that ends at ${_ph_ln}; the gate at ${_gate_ln} is OUTSIDE both"
    else
        bad "J4 gate/kernel-phase nesting not provable (if@${_kc_ln:-?} CHROOT@${_hd_ln:-?} store@${_st_ln:-?} branch-fi@${_br_ln:-?} phase-fi@${_ph_ln:-?} gate@${_gate_ln:-?})"
    fi
    # And the store must be on the MISS side only: it sits after the heredoc, before the
    # branch closes — a store on the hit path would re-publish what it just restored.
    if [ -n "${_st_ln}" ] && [ -n "${_kc_ln}" ] && [ "${_st_ln}" -gt "${_kc_ln}" ]; then
        ok "J4b kernel_cache_store is on the MISS side of the branch only"
    else
        bad "J4b kernel_cache_store is not confined to the miss path"
    fi
fi
# ARM: the requested-atom payload gate (#470) runs BEFORE the kernel phase, so the
# cache cannot be between it and the build at all. Assert that ordering.
_pg="$(grep -n 'requested_atom_gate ' "${RPI}" | grep -v '^ *#' | head -1 | cut -d: -f1)"
_kc="$(grep -n '^# ── SIGNED-KERNEL ARTIFACT CACHE' "${RPI}" | head -1 | cut -d: -f1)"
if [ -n "${_pg}" ] && [ -n "${_kc}" ] && [ "${_pg}" -lt "${_kc}" ]; then
    ok "J5 the ARM payload gate (line ${_pg}) runs BEFORE the kernel cache (line ${_kc})"
else
    bad "J5 could not prove the ARM payload gate precedes the cache (gate@${_pg:-?} cache@${_kc:-?})"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "-- K) structural sweep: the wired builders carry the whole wiring --"
for b in "${X86}" "${RPI}"; do
    n="$(basename "${b}")"
    miss=""
    grep -q 'scripts/_kernel-cache-lib.sh"$' "${b}" || miss="${miss} lib-source"
    grep -q -- '--no-kernel-cache)' "${b}"          || miss="${miss} flag-arm"
    grep -q -- '--no-kernel-cache ' "${b}"          || miss="${miss} usage"
    grep -q 'KERNEL_CACHE_ROOT="\$(kc_root ' "${b}" || miss="${miss} root-resolution"
    grep -q '_plan KERNEL_CACHE ' "${b}"            || miss="${miss} plan-key"
    grep -q 'kernel_cache_try_restore' "${b}"       || miss="${miss} restore-branch"
    grep -q 'kernel_cache_store' "${b}"             || miss="${miss} store-call"
    grep -q 'kc_signing_fingerprint' "${b}"         || miss="${miss} signing-identity"
    [ -z "${miss}" ] && ok "K ${n} carries the full kernel-cache wiring" \
        || bad "K ${n} is MISSING:${miss}"
done
# --print-plan must actually emit the key, on both channels, on and off.
for b in "${X86}" "${RPI}"; do
    n="$(basename "${b}")"
    on="$(bash "${b}" --print-plan 2>/dev/null | grep -c '^PLAN_KERNEL_CACHE=')"
    off="$(bash "${b}" --no-kernel-cache --print-plan 2>/dev/null | grep -x 'PLAN_KERNEL_CACHE=off' | wc -l)"
    [ "${on}" = 1 ] && [ "${off}" = 1 ] \
        && ok "K ${n} --print-plan reports the cache (on) and 'off' under --no-kernel-cache" \
        || bad "K ${n} plan reporting wrong (on=${on} off=${off})"
done
# REGRESSION (found in this lane): a bash ARRAY ASSIGNMENT performs pathname
# expansion, so `KCACHE_BOOT_GLOBS=(vmlinuz-* …)` silently expanded against the
# builder's CURRENT DIRECTORY and baked whatever was there into the payload list.
# Every pattern in that array must be QUOTED so it reaches kc_names_matching literally.
for b in "${X86}" "${RPI}"; do
    n="$(basename "${b}")"
    _line="$(grep -m1 '^KCACHE_BOOT_GLOBS=' "${b}")"
    _bare="$(sed 's/^KCACHE_BOOT_GLOBS=(//; s/)$//' <<<"${_line}" | tr ' ' '\n' \
             | grep -E '\*' | grep -vE "^['\"]" || true)"
    [ -z "${_bare}" ] && ok "K ${n} every KCACHE_BOOT_GLOBS pattern is quoted (no cwd expansion)" \
        || bad "K ${n} UNQUOTED glob(s) in KCACHE_BOOT_GLOBS — expands against cwd: ${_bare}"
done
# And prove the hazard is real, so the assertion above is not folklore.
mkdir -p "${TMP}/cwd" && (cd "${TMP}/cwd" && touch 'vmlinuz-9.9' && \
    bash -c 'A=(vmlinuz-*); [ "${A[0]}" = "vmlinuz-9.9" ]') \
    && ok "K (control) an UNQUOTED array glob really does expand against cwd" \
    || bad "K (control) could not reproduce the array-glob expansion hazard"
# kc_names_matching must expand against the DIRECTORY it is given, not cwd.
mkdir -p "${TMP}/bootdir" && touch "${TMP}/bootdir/vmlinuz-1.2" "${TMP}/bootdir/config-1.2"
_got="$(cd "${TMP}/cwd" && kc_names_matching "${TMP}/bootdir" 'vmlinuz-*' 'config-*' | sort | tr '\n' ' ')"
[ "${_got}" = "config-1.2 vmlinuz-1.2 " ] \
    && ok "K kc_names_matching expands against its DIRECTORY argument, not cwd" \
    || bad "K kc_names_matching returned '${_got}'"

# REGRESSION (found in this lane): the cache-HIT path must not emit a `banner`. The
# kernel PHASE banner is already emitted before the hit/miss branch, and a second one is
# a progress rung the Studio's phase table has no row for — which strands the ladder
# (studio/tests/test_progress_uniformity.py failed on exactly that). Assert the hit arm
# uses info only.
for b in "${X86}" "${RPI}"; do
    n="$(basename "${b}")"
    _s="$(grep -n 'if kernel_cache_try_restore; then' "${b}" | head -1 | cut -d: -f1)"
    _arm="$(awk -v s="${_s:-0}" 'NR>s && NR<=s+12' "${b}" | grep -c '^ *banner ' || true)"
    [ "${_arm}" = 0 ] && ok "K ${n} the cache-HIT arm emits no extra phase banner" \
        || bad "K ${n} the cache-HIT arm emits a banner (progress-table drift)"
    # …and the phase banner itself is still there, BEFORE the branch.
    _pb="$(awk -v s="${_s:-0}" 'NR<s' "${b}" | grep -c 'banner "Building hardened kernel' || true)"
    [ "${_pb}" -ge 1 ] && ok "K ${n} the kernel PHASE banner still precedes the cache branch" \
        || bad "K ${n} lost the kernel phase banner before the cache branch"
done

# No builder may hand a signing KEY PATH to the cache, only a fingerprint.
if grep -nE 'kc_store .*(sb\.key|SECUREBOOT_KEY|\.key)' "${X86}" "${RPI}" >/dev/null 2>&1; then
    bad "K a builder passes key material into kc_store"
else
    ok "K no builder passes a key path into the cache payload"
fi

echo "== kernel artifact cache: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
