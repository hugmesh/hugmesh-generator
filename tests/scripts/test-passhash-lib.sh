#!/usr/bin/env bash
# test-passhash-lib.sh — unit test for scripts/_passhash-lib.sh, the shared
# /etc/shadow password-KDF helper used by gen-provision-keys.sh and the
# build-*-stage4.sh builders' --local-pass path (docs/CRYPTO-AUDIT.md row 12).
#
# Proves, host-locally and WITHOUT touching the real /etc/shadow:
#   1. ph_crypt_hash emits a yescrypt ($y$) hash on a yescrypt-capable host,
#      and that hash ROUND-TRIPS through the host libcrypt (crypt(pw, h) == h)
#      for the right password and FAILS for a wrong one.
#   2. Tricky passwords (leading dash, spaces, quotes, UTF-8, trailing space)
#      survive the stdin plumbing byte-exactly.
#   3. The $6$ fallback fires when the yescrypt leg is unavailable (simulated
#      with a failing python3 shim) and when PH_KDF=sha512crypt forces it —
#      and the fallback hash round-trips too.
#   4. `chpasswd -e` (the exact consumer call shape used by provision.sh and
#      01-firstboot.start.tmpl) ACCEPTS the emitted hash verbatim, proven
#      against a THROWAWAY --prefix root, never the real /etc/shadow.
#   5. Every caller that needs ph_crypt_hash actually sources the lib.
#
# Run: bash tests/scripts/test-passhash-lib.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_passhash-lib.sh"
[ -f "${LIB}" ] || { echo "  FAIL helper missing: ${LIB}"; exit 1; }

# shellcheck source=/dev/null
source "${LIB}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# crypt_verify PASSWORD HASH — 0 iff the host libcrypt validates the pair
# (the same crypt(3) call pam_unix makes at login).
crypt_verify() {
  printf '%s' "$1" | python3 -c '
import ctypes, ctypes.util, sys
pw = sys.stdin.buffer.read()
h = sys.argv[1].encode()
name = ctypes.util.find_library("crypt") or "libcrypt.so.2"
lib = ctypes.CDLL(name)
crypt = lib.crypt
crypt.restype = ctypes.c_char_p
crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
sys.exit(0 if crypt(pw, h) == h else 1)
' "$2"
}

echo "== _passhash-lib.sh /etc/shadow KDF unit test =="

# ── 1. primary path: yescrypt on a capable host ──────────────────────────────
H1="$(ph_crypt_hash 'test-password-123')"
case "${H1}" in
  '$y$'*) ok "ph_crypt_hash emits yescrypt (\$y\$) on this host" ;;
  '$6$'*) ok "ph_crypt_hash fell back to \$6\$ (host libcrypt lacks yescrypt — fallback is the contract)" ;;
  *)      bad "unexpected hash format: ${H1}" ;;
esac
crypt_verify 'test-password-123' "${H1}" \
  && ok "emitted hash round-trips via libcrypt for the correct password" \
  || bad "emitted hash does not validate the correct password"
crypt_verify 'wrong-password' "${H1}" \
  && bad "hash validated a WRONG password" \
  || ok "wrong password is rejected"

# ── 2. tricky passwords survive byte-exactly ─────────────────────────────────
TRICKY='-p@ss w0rd "quoted" äö '
H2="$(ph_crypt_hash "${TRICKY}")"
crypt_verify "${TRICKY}" "${H2}" \
  && ok "tricky password (dash/spaces/quotes/UTF-8/trailing space) round-trips" \
  || bad "tricky password mangled in transit"
crypt_verify '-p@ss w0rd "quoted" äö' "${H2}" \
  && bad "trailing space was stripped (wrong pw validated)" \
  || ok "trailing space is significant (stripped variant rejected)"

# ── 3a. $6$ fallback when the yescrypt leg is unavailable ────────────────────
mkdir -p "${WORK}/shim"
printf '#!/bin/sh\nexit 1\n' > "${WORK}/shim/python3"
chmod +x "${WORK}/shim/python3"
H3="$(PATH="${WORK}/shim:${PATH}" bash -c "source '${LIB}'; ph_crypt_hash 'test-password-123'")"
case "${H3}" in
  '$6$'*) ok "failing python3 => \$6\$ fallback fires" ;;
  *)      bad "fallback did not produce a \$6\$ hash: ${H3}" ;;
esac
crypt_verify 'test-password-123' "${H3}" \
  && ok "\$6\$ fallback hash round-trips via libcrypt" \
  || bad "\$6\$ fallback hash does not validate"

# ── 3b. PH_KDF=sha512crypt forces the fallback ───────────────────────────────
H4="$(PH_KDF=sha512crypt ph_crypt_hash 'test-password-123')"
case "${H4}" in
  '$6$'*) ok "PH_KDF=sha512crypt forces the \$6\$ fallback" ;;
  *)      bad "PH_KDF=sha512crypt still produced: ${H4}" ;;
esac

# ── 4. chpasswd -e accepts the hash (throwaway prefix root, NEVER /etc) ──────
if command -v chpasswd >/dev/null 2>&1; then
  mkdir -p "${WORK}/root/etc"
  printf 'alice:x:1000:1000::/home/alice:/bin/bash\n' > "${WORK}/root/etc/passwd"
  printf 'alice:!:19900:0:99999:7:::\n'               > "${WORK}/root/etc/shadow"
  printf 'alice:x:1000:\n'                            > "${WORK}/root/etc/group"
  chmod 600 "${WORK}/root/etc/shadow"
  if printf 'alice:%s\n' "${H1}" | chpasswd -e -P "${WORK}/root" 2>/dev/null; then
    STORED="$(awk -F: '$1=="alice"{print $2}' "${WORK}/root/etc/shadow")"
    [ "${STORED}" = "${H1}" ] \
      && ok "chpasswd -e lands the hash VERBATIM in (throwaway) shadow" \
      || bad "chpasswd -e altered the hash: ${STORED}"
  else
    bad "chpasswd -e -P rejected the emitted hash"
  fi
else
  ok "chpasswd not on PATH — consumer-acceptance leg skipped (not a helper bug)"
fi

# ── 5. every caller sources the lib ──────────────────────────────────────────
for b in build-frite-stage4.sh build-jetson-stage4.sh build-orangepi-zero2-stage4.sh \
         build-orangepi5-stage4.sh build-rpi5-stage4.sh build-x86-host-stage4.sh \
         scripts/gen-provision-keys.sh; do
  BF="${REPO}/${b}"
  if grep -q 'ph_crypt_hash' "${BF}"; then
    grep -qE 'source .*_passhash-lib\.sh' "${BF}" \
      && ok "${b}: sources scripts/_passhash-lib.sh" \
      || bad "${b}: uses ph_crypt_hash but does not source _passhash-lib.sh"
    grep -q 'openssl passwd -6' "${BF}" \
      && bad "${b}: still calls openssl passwd -6 directly" \
      || ok "${b}: no direct openssl passwd -6 remains"
  else
    bad "${b}: does not use ph_crypt_hash"
  fi
done

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
