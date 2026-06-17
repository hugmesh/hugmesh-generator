#!/usr/bin/env bash
# test-provision-pool.sh — logic test for the NODE-STORAGE provision_storage changes
# (node-storage PR5). Runs ANYWHERE with bash + jq + sed — NO real disks, NO root.
#
# It EXTRACTS the real provision_storage() + luks_open_or_format() function bodies from
# specs/etc/keys-provision/provision.sh (the script runs main() unconditionally at EOF, so
# we cannot source it whole) and exercises them against a synthetic manifest with stubbed
# block-device commands and temp /etc/fstab + /etc/crypttab. Proves the THREE PR5 invariants:
#
#   1. a `pool:{}` device gets `,nofail` appended to BOTH its fstab options AND its
#      crypttab options (a removed pool disk DEGRADES the pool, not the boot);
#   2. a SYSTEM disk (no pool marker) gets NO `nofail` (a missing system disk still halts
#      the boot — behaviour unchanged);
#   3. `provision_storage --pool` provisions ONLY pool devices and SKIPS system disks;
#      calling with no arg provisions everything (first-boot, unchanged).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/specs/etc/keys-provision/provision.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
# robust line-count of matches (0 when file missing/no match, single integer).
count() { local pat="$1" f="$2"; [ -r "$f" ] || { echo 0; return; }; grep -c -- "$pat" "$f" 2>/dev/null | head -1; }

command -v jq  >/dev/null || { echo "jq required";  exit 2; }
command -v sed >/dev/null || { echo "sed required"; exit 2; }
[ -r "${SRC}" ] || { echo "cannot read ${SRC}"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# Extract the two functions verbatim (brace-balanced: from `name() {` to the first
# column-0 `}`), so the test exercises the REAL shipped logic, never a copy.
extract_fn() {
    local name="$1"
    sed -n "/^${name}() {/,/^}/p" "${SRC}"
}
extract_fn provision_storage  > "${WORK}/fns.sh"
extract_fn luks_open_or_format >> "${WORK}/fns.sh"

# ── Stub harness: replace every privileged / block-device call with a no-op or a
#    deterministic fake so the real branch logic runs unprivileged. fstab/crypttab are
#    redirected to temp files via the FSTAB/CRYPTTAB indirection the functions DON'T use —
#    so we shadow the literal paths by running in a fake root via a wrapper grep/printf.
build_harness() {
    cat > "${WORK}/harness.sh" <<HARNESS
set -uo pipefail
MANIFEST="${WORK}/manifest.json"
FAKEROOT="${WORK}/root"
mkdir -p "\${FAKEROOT}/etc/snapdragon/luks" "\${FAKEROOT}/mnt"
: > "\${FAKEROOT}/etc/fstab"
: > "\${FAKEROOT}/etc/crypttab"

log()  { :; }
warn() { echo "WARN: \$*" >&2; }
have() { case "\$1" in cryptsetup) return 0;; *) command -v "\$1" >/dev/null 2>&1;; esac; }
jqm()  { jq -r "\$1" "\${MANIFEST}" 2>/dev/null; }
jqe()  { jq -e "\$1" "\${MANIFEST}" >/dev/null 2>&1; }

# Block-device + fs stubs.
# Derive a DISTINCT, non-digit-suffixed fake device from the (distinct) match arg so the
# two devices never collide (the part-suffix logic + the fstab UUID dedup both depend on
# distinct devices). A non-digit suffix keeps part==dev (whole-disk fallback path).
resolve_storage_dev() { echo "/dev/fake-\$(printf '%s' "\$1" | tr -dc 'a-z')"; }
luks_keyfile() { echo "\${FAKEROOT}/etc/snapdragon/luks/test.key"; printf 'k' > "\${FAKEROOT}/etc/snapdragon/luks/test.key"; }
parted()    { :; }
wipefs()    { :; }
partprobe() { :; }
mkdir()     { :; }
sleep()     { :; }
rc-service(){ :; }
mount()     { return 0; }
cp()        { :; }
install()   { :; }
# A DETERMINISTIC per-device fake UUID derived from the device path (the last arg),
# subshell-safe (no persisted counter): distinct devices -> distinct UUIDs, so the
# fstab dedup never cross-matches.
blkid()     { echo "UUID-\$(printf '%s' "\${@: -1}" | tr -dc 'a-z0-9')"; }
mkfs.ext4() { :; }
cryptsetup(){ case "\$1" in isLuks) return 1;; *) return 0;; esac; }
ln()        { :; }
luks_try_tpm2_enroll() { :; }
# Redirect the literal /etc/fstab + /etc/crypttab writes/reads into the fake root by
# shadowing the two builtins the functions use against those paths: we cannot easily
# intercept '>>' redirection to a literal path, so instead we pre-symlink them.
HARNESS
    # Make /etc writes land in the fake root (literal-path rewrite), and neutralise the
    # block-device existence guards `[ -b "<x>" ]` (an unprivileged test cannot mknod a
    # real block device; these guards are NOT what this logic test exercises — the
    # pool/nofail branches are). Replace each `[ -b "..." ]` with `true`.
    sed -e "s#/etc/fstab#${WORK}/root/etc/fstab#g" \
        -e "s#/etc/crypttab#${WORK}/root/etc/crypttab#g" \
        -e "s#/etc/snapdragon/luks#${WORK}/root/etc/snapdragon/luks#g" \
        -e 's#\[ -b "[^"]*" \]#true#g' \
        "${WORK}/fns.sh" >> "${WORK}/harness.sh"
}

run_case() {
    # $1 = manifest json, $2 = provision_storage args
    printf '%s' "$1" > "${WORK}/manifest.json"
    rm -rf "${WORK}/root"
    command mkdir -p "${WORK}/root/etc/snapdragon/luks"
    : > "${WORK}/root/etc/fstab"
    : > "${WORK}/root/etc/crypttab"
    build_harness
    ( bash -c "source '${WORK}/harness.sh'; provision_storage ${2}" ) >/dev/null 2>&1
}

FSTAB="${WORK}/root/etc/fstab"
CRYPTTAB="${WORK}/root/etc/crypttab"

# ── Manifests ───────────────────────────────────────────────────────────────────
# One SYSTEM disk (no pool) + one POOL disk (pool:{}), both format+encrypt so both the
# crypttab and fstab branches run.
MANIFEST_MIXED='{"storage":{"devices":[
  {"match":"/dev/sys","mountpoint":"/mnt/data","format":true,"encrypt":true,"filesystem":"ext4"},
  {"match":"/dev/pool","mountpoint":"/mnt/pool0","format":true,"encrypt":true,"filesystem":"ext4","pool":{}}
]}}'

echo "== node-storage PR5: provision_storage pool/,nofail =="

# 1. first-boot (no arg) provisions BOTH; pool line has nofail, system line does NOT.
run_case "${MANIFEST_MIXED}" ""
syscount=$(count "/mnt/data" "${FSTAB}")
poolcount=$(count "/mnt/pool0" "${FSTAB}")
[ "${syscount}" = "1" ] && [ "${poolcount}" = "1" ] \
    && ok "first-boot (no arg) provisions BOTH system and pool devices" \
    || bad "first-boot should provision both (system=${syscount} pool=${poolcount})"

if grep "/mnt/pool0" "${FSTAB}" | grep -q "nofail"; then
    ok "pool fstab line carries ,nofail"
else
    bad "pool fstab line MUST carry ,nofail: $(grep /mnt/pool0 "${FSTAB}")"
fi
if grep "/mnt/data" "${FSTAB}" | grep -q "nofail"; then
    bad "system fstab line must NOT carry nofail: $(grep /mnt/data "${FSTAB}")"
else
    ok "system fstab line has NO nofail (a missing system disk still halts boot)"
fi

# crypttab: the pool's crypttab entry must carry nofail; the system one must not.
poolname=$(grep "nofail" "${CRYPTTAB}" 2>/dev/null | awk '{print $1}')
if grep -q "nofail" "${CRYPTTAB}"; then
    ok "a crypttab entry carries nofail (the pool's): ${poolname}"
else
    bad "pool crypttab entry MUST carry nofail: $(cat "${CRYPTTAB}")"
fi
# exactly ONE crypttab line has nofail (the pool), the other (system) does not.
nofail_lines=$(count "nofail" "${CRYPTTAB}")
total_lines=$(count "cryptdata" "${CRYPTTAB}")
[ "${nofail_lines}" = "1" ] && [ "${total_lines}" = "2" ] \
    && ok "exactly one of two crypttab entries has nofail (pool only)" \
    || bad "expected 2 crypttab entries, 1 with nofail (got total=${total_lines} nofail=${nofail_lines})"

# 2. --pool mode provisions ONLY the pool device (system disk skipped).
run_case "${MANIFEST_MIXED}" "--pool"
syscount=$(count "/mnt/data" "${FSTAB}")
poolcount=$(count "/mnt/pool0" "${FSTAB}")
[ "${syscount}" = "0" ] && [ "${poolcount}" = "1" ] \
    && ok "--pool mode provisions ONLY the pool device (system disk skipped)" \
    || bad "--pool should provision pool only (system=${syscount} pool=${poolcount})"

# 3. inert: a manifest with NO storage.devices is a clean no-op (returns 0, writes nothing).
run_case '{"snapdragon":{}}' "--pool"
[ ! -s "${FSTAB}" ] \
    && ok "no .storage.devices -> inert no-op (today's behaviour exactly)" \
    || bad "empty manifest should write nothing to fstab"

echo
echo "node-storage PR5 provision: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
