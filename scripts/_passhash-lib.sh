# _passhash-lib.sh — shared /etc/shadow password-KDF helper for the image
# builders (build-*-stage4.sh `--local-pass`) and scripts/gen-provision-keys.sh
# (KEYS-USB users.json hashes). Sourced, not executed.
#
# Why: these hashes land VERBATIM in the baked image's real /etc/shadow (via
# `chpasswd -e` — specs/etc/keys-provision/provision.sh and
# specs/etc/local.d/01-firstboot.start.tmpl), so their KDF is exactly what an
# attacker who steals a device/image cracks offline. sha512crypt ($6$) is
# CPU-only; yescrypt ($y$) is memory-hard and is what the baked Gentoo images'
# own libxcrypt validates (and what `chpasswd` itself offers via `-c YESCRYPT`).
# See docs/CRYPTO-AUDIT.md row 12 for the empirical round-trip evidence.
#
# ph_crypt_hash PASSWORD
#   Prints a crypt(3) hash of PASSWORD on stdout — yescrypt ($y$) when the host
#   can actually produce AND round-trip-verify it, else SHA-512 crypt ($6$).
#   Never prints the plaintext; the plaintext never enters any external
#   process's argv (bash `printf` is a builtin; python reads it from stdin;
#   the openssl fallback uses `-stdin`), so it is never visible in `ps`.
#
#   KDF choice (strongest-that-provably-works, mirrors gen-keystores.sh's
#   FP_HASH sha3-512→sha512 auto-fallback):
#     1. yescrypt via python3 + ctypes against the host libcrypt
#        (crypt_gensalt/crypt — libxcrypt). The generated hash is SELF-VERIFIED
#        (crypt(pw, hash) == hash) before being emitted; any miss (no python3,
#        glibc-era libcrypt without yescrypt, missing crypt_gensalt symbol,
#        failure token) falls through.
#     2. `openssl passwd -6 -stdin` (SHA-512 crypt) — the pre-2026-07 behavior,
#        kept as the fallback so provisioning still works on hosts whose
#        libcrypt predates yescrypt.
#   Callers can tell which KDF was used from the output prefix ($y$ vs $6$).
#
#   Knob (crypto agility, docs/CRYPTO-AUDIT.md): PH_KDF=sha512crypt forces the
#   $6$ fallback (e.g. to provision a foreign image whose libcrypt predates
#   yescrypt). Default/empty/yescrypt = auto (strongest that round-trips).

# The (non-secret) python program rides in argv via `python3 -c`; the password
# arrives on STDIN as raw bytes. Exit 0 + hash on stdout ONLY after the
# round-trip self-verification passes; any other condition exits 1 so the
# caller falls back to $6$. libxcrypt signals failure with NULL or a "*0"/"*1"
# token — both are rejected by the b"$y$" prefix check.
_PH_YESCRYPT_PY='
import ctypes, ctypes.util, sys
pw = sys.stdin.buffer.read()
if not pw:
    sys.exit(1)
names = []
found = ctypes.util.find_library("crypt")
if found:
    names.append(found)
names += ["libcrypt.so.2", "libcrypt.so.1"]
for name in names:
    try:
        lib = ctypes.CDLL(name)
        gensalt = lib.crypt_gensalt
        crypt = lib.crypt
    except (OSError, AttributeError):
        continue
    gensalt.restype = ctypes.c_char_p
    gensalt.argtypes = [ctypes.c_char_p, ctypes.c_ulong, ctypes.c_char_p, ctypes.c_int]
    crypt.restype = ctypes.c_char_p
    crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    setting = gensalt(b"$y$", 0, None, 0)   # NULL rbytes => OS entropy, 0 => default cost
    if not setting or not setting.startswith(b"$y$"):
        continue
    h = crypt(pw, setting)
    if not h or not h.startswith(b"$y$"):
        continue
    if crypt(pw, h) != h:                   # round-trip self-verification
        continue
    sys.stdout.buffer.write(h + b"\n")
    sys.exit(0)
sys.exit(1)
'

ph_crypt_hash() {
    local pw="$1" h=""
    if [ "${PH_KDF:-}" != "sha512crypt" ] && command -v python3 >/dev/null 2>&1; then
        h="$(printf '%s' "${pw}" | python3 -c "${_PH_YESCRYPT_PY}" 2>/dev/null)" || h=""
        case "${h}" in
            '$y$'*) printf '%s\n' "${h}"; return 0 ;;
        esac
    fi
    # Fallback: SHA-512 crypt. openssl is already a hard dependency of every
    # caller. -stdin keeps the plaintext out of openssl's argv.
    printf '%s\n' "${pw}" | openssl passwd -6 -stdin
}
