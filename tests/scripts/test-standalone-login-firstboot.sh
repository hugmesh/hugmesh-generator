#!/usr/bin/env bash
# test-standalone-login-firstboot.sh — the password typed in the Studio/TUI for a
# STANDALONE image must become a working login on first boot.
#
# Operator report (2026-10-30 standalone-thick x86, unaffiliated, eCryptfs home):
# the password typed in the GUI did not log in. The build baked its hash correctly;
# first boot threw it away, through two defects that each lock the image on its own:
#
#   1. specs/etc/local.d/01-firstboot.start.tmpl ran
#      `useradd -G wheel,audio,video,usb,plugdev,games` unchecked. The image has no
#      `games` group, so useradd exited 6 and created nobody; `chpasswd -e` had no
#      user; `touch /var/lib/keys-provision/users.created` failed (no such dir); the
#      keyless fallback then made the user with a RANDOM password whose banner went
#      to /dev/null, and the script deleted itself.
#   2. specs/usr/sbin/hugmesh-home-setup put `auth optional pam_ecryptfs.so unwrap`
#      directly after pambase's `[success=1 ...] pam_unix.so`, so a CORRECT password
#      skipped it and landed on `[default=die] pam_faillock.so authfail`: every
#      password login (lightdm, login, su, sudo, sshd) failed.
#
# What this runs, offline and without root:
#   A. the REAL rendered firstboot template, up to its Kubernetes section, against a
#      throwaway root: /etc/group WITHOUT `games` (the image's), PATH shims for the
#      account tools that enforce useradd's real rule (exit 6 on an unknown group)
#      and record what chpasswd received.
#   B. home-setup's REAL wire_pam_ecryptfs function over the image's own pambase
#      system-auth (fixtures/pam/), checked structurally (no success=N jump target
#      moves) and, where libpam is present, EXECUTED through libpam's
#      pam_start_confdir with pam_unix swapped for pam_permit/pam_deny.
#   C. static pins: the finaliser is root-only in every builder, and the Calamares
#      `users` page (whose answers nothing consumed) is not shown.
#
# Run: bash tests/scripts/test-standalone-login-firstboot.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPL="${REPO}/specs/etc/local.d/01-firstboot.start.tmpl"
HOMESETUP="${REPO}/specs/usr/sbin/hugmesh-home-setup"
PAMFIX="${REPO}/tests/scripts/fixtures/pam/system-auth.gentoo-pambase"
CALA="${REPO}/specs/etc/calamares/settings.conf"

P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }

for f in "${TMPL}" "${HOMESETUP}" "${PAMFIX}" "${CALA}"; do
    [ -f "${f}" ] || { echo "  FAIL missing ${f}"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── A. first boot: the standalone account ──────────────────────────────────────
# make_root / render / run_fb: shared with studio/tests/test_login_field_reaches_firstboot.py.
# shellcheck source=tests/scripts/lib/firstboot-harness.sh
source "${REPO}/tests/scripts/lib/firstboot-harness.sh"


HASH6="$(openssl passwd -6 -salt 'Abc.def/123' 'correct horse' 2>/dev/null)"
case "${HASH6}" in '$6$'*) ;; *) echo "  FAIL openssl passwd -6 unavailable"; exit 1 ;; esac

echo "== A1. standalone + password: the build-time hash lands on a real account =="
R="${WORK}/a1"; make_root "${R}"; render "${R}" "${HASH6}" true; run_fb "${R}"
grep -q '^groupadd .*games$' "${R}/log" && ok "missing 'games' group is created before useradd" \
    || bad "no groupadd for the missing 'games' group (useradd exits 6 and creates nobody)"
grep -qE '^magus:x:1000:' "${R}/etc/passwd" && ok "account magus created" \
    || bad "account magus NOT created: $(grep useradd "${R}/out" | head -1)"
[ "$(cat "${R}/shadow.hash" 2>/dev/null)" = "magus:${HASH6}" ] \
    && ok "chpasswd -e received exactly magus:<the build-time hash>" \
    || bad "chpasswd -e did not receive the build-time hash"
[ ! -e "${R}/shadow.plain" ] && ok "no random/plaintext password was set" \
    || bad "a plaintext (random fallback) password was set over the build-time one"
[ -f "${R}/var/lib/keys-provision/users.created" ] && ok "users.created marked (dir created)" \
    || bad "users.created not written — the keyless fallback will run"
grep -q 'KEYLESS BOOT' "${R}/out" && bad "keyless fallback ran after a working standalone setup" \
    || ok "keyless fallback did not run"
grep -q '^passwd -l root' "${R}/log" && ok "root stays locked" || bad "root not locked"
grep -q 'ready (password set at build time)' "${R}/out" && ok "'ready' reported" || bad "no 'ready' line"
[ ! -e "${R}/self" ] && ok "finaliser removed itself after success" || bad "finaliser left in place after success"
grep -Eq '^%wheel ALL=\(ALL\) ALL$' "${R}/etc/sudoers" && ok "%wheel sudoers line written (wheel = the admin group)" || bad "no %wheel sudoers line"
grep -q 'wheel' "${R}/groups.magus" 2>/dev/null && bad "standalone account put in wheel WITHOUT --local-admin (admin must be opt-in)" \
    || ok "standalone account is not in wheel without --local-admin"
grep -q 'magus is NOT an administrator' "${R}/console" 2>/dev/null && ok "console says nobody local can sudo" \
    || bad "silent: a standalone box with no administrator, and the console never says so"

echo "== A1a. standalone + password + --local-admin: the account is the administrator =="
R="${WORK}/a1a"; make_root "${R}"; render "${R}" "${HASH6}" true true; run_fb "${R}"
grep -q 'wheel' "${R}/groups.magus" 2>/dev/null && ok "--local-admin puts the standalone account in wheel" \
    || bad "--local-admin did not make the standalone account an administrator"
[ "$(grep -c '^%wheel ALL=(ALL) ALL$' "${R}/etc/sudoers")" = 1 ] && ok "exactly one %wheel line" \
    || bad "expected exactly one %wheel line, got $(grep -c '^%wheel' "${R}/etc/sudoers")"
grep -q 'NOT an administrator' "${R}/console" 2>/dev/null && bad "console claims no administrator although --local-admin was given" \
    || ok "no 'NOT an administrator' line with --local-admin"
[ -z "$(ls -A "${R}/etc/sudoers.d" 2>/dev/null)" ] && ok "no sudoers.d grant on a keyless shape (wheel is the path)" \
    || bad "sudoers.d grant written on a standalone image"
grep -q '^passwd -l root' "${R}/log" && ok "root still locked" || bad "root not locked"

echo "== A2. a hash made only of word characters after its \$-segments survives quoting =="
# Inside double quotes the template's `$y$`/`$6$` segments are parameter
# expansions: '$6$salt$Word' expands to "" and silently takes the random branch.
WEIRD='$6$abcdefgh$ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi'
R="${WORK}/a2"; make_root "${R}"; render "${R}" "${WEIRD}" true; run_fb "${R}"
[ "$(cat "${R}/shadow.hash" 2>/dev/null)" = "magus:${WEIRD}" ] \
    && ok "word-character hash applied verbatim" \
    || bad "word-character hash was expanded away (double-quoted placeholder?)"

echo "== A3. groupadd unavailable: the account is still made with the groups that exist =="
R="${WORK}/a3"; make_root "${R}"; render "${R}" "${HASH6}" true; run_fb "${R}" GROUPADD_FAIL=1
[ "$(cat "${R}/shadow.hash" 2>/dev/null)" = "magus:${HASH6}" ] \
    && ok "hash applied without 'games'" || bad "hash NOT applied when 'games' could not be created"
grep -q ',games' "${R}/groups.magus" 2>/dev/null && bad "asked useradd for a group that does not exist" \
    || ok "useradd only asked for existing groups"

echo "== A4. password could not be set: no random fallback, retry next boot =="
R="${WORK}/a4"; make_root "${R}"; render "${R}" "${HASH6}" true; run_fb "${R}" CHPASSWD_FAIL=1
[ ! -f "${R}/var/lib/keys-provision/users.created" ] && ok "not marked done" || bad "marked done although chpasswd failed"
grep -q 'ready (password set at build time)' "${R}/out" && bad "'ready' printed although chpasswd failed" \
    || ok "no false 'ready' line"
[ "$(grep -c '^chpasswd' "${R}/log")" = 1 ] && ok "keyless fallback did not overwrite with a random password" \
    || bad "a second (fallback) chpasswd ran: $(grep '^chpasswd' "${R}/log" | tr '\n' ' ')"
[ -e "${R}/self" ] && ok "finaliser kept for a retry on the next boot" || bad "finaliser deleted itself after a failure"
grep -q 'FAILED to set up local user magus' "${R}/console" 2>/dev/null && ok "failure written to the console" \
    || bad "failure not written to the console"

echo "== A4b. the account could not be made: still no random-password fallback =="
R="${WORK}/a4b"; make_root "${R}"; render "${R}" "${HASH6}" true; run_fb "${R}" USERADD_FAIL_ONCE=1
[ ! -e "${R}/shadow.plain" ] && ok "fallback did not create the user with a random password" \
    || bad "fallback replaced the build-time password with a random one after a failed useradd"
[ -e "${R}/self" ] && ok "finaliser kept for a retry" || bad "finaliser deleted itself after useradd failed"

echo "== A5. no password given: the one-time password reaches the console =="
R="${WORK}/a5"; make_root "${R}"; render "${R}" "" true; run_fb "${R}"
[ -s "${R}/shadow.plain" ] && [ ! -e "${R}/shadow.hash" ] && ok "random password set" || bad "no random password set"
grep -q '^chage -d 0 magus' "${R}/log" && ok "forced change at first login" || bad "no chage -d 0"
pw="$(cut -d: -f2- "${R}/shadow.plain" 2>/dev/null)"
[ -n "${pw}" ] && grep -qF "pass: ${pw}" "${R}/console" 2>/dev/null \
    && ok "one-time password shown on /dev/console (OpenRC local discards stdout)" \
    || bad "one-time password never reaches the console"

# ── A6+. the Login Password on a NON-standalone image (cloud/mesh desktops) ────
# The Studio shows the Login Password on cloud/mesh x86 laptops/desktops, rpi5 and
# jetson desktops, and the standalone-MODE chromebook/frite/orangepi5/-4-lts flows
# without the box; none of those sets STANDALONE=true. The hash must land there too.
echo "== A6. STANDALONE=false + password, keyless boot: the hash lands, the account is the login =="
R="${WORK}/a6"; make_root "${R}"; render "${R}" "${HASH6}" false; run_fb "${R}"
[ "$(cat "${R}/shadow.hash" 2>/dev/null)" = "magus:${HASH6}" ] \
    && ok "chpasswd -e received exactly magus:<the build-time hash>" \
    || bad "the build-time hash was dropped on a non-standalone image"
[ ! -e "${R}/shadow.plain" ] && ok "no random password" || bad "a random password was set although a password was given"
grep -q 'KEYLESS BOOT' "${R}/out" && bad "keyless random-password fallback ran although a password was given" \
    || ok "keyless fallback did not run"
grep -q '^passwd -l root' "${R}/log" && ok "root locked" || bad "root not locked"
grep -q 'wheel' "${R}/groups.magus" 2>/dev/null && bad "keyless boot put the local account in wheel WITHOUT --local-admin (the 2026-11-09 prover defect)" \
    || ok "keyless boot: local account is not in wheel without --local-admin"
grep -q 'magus is NOT an administrator' "${R}/console" 2>/dev/null && ok "console says no local account can sudo" \
    || bad "silent: keyless box with no administrator, and the console never says so"
[ -f "${R}/var/lib/keys-provision/users.created" ] && ok "users.created marked" || bad "users.created not marked"
[ ! -e "${R}/self" ] && ok "finaliser removed itself" || bad "finaliser left in place"

echo "== A6a. STANDALONE=false + password + --local-admin, keyless boot: in wheel =="
R="${WORK}/a6a"; make_root "${R}"; render "${R}" "${HASH6}" false true; run_fb "${R}"
grep -q 'wheel' "${R}/groups.magus" 2>/dev/null && ok "--local-admin on a keyless boot puts the account in wheel" \
    || bad "--local-admin ignored on a keyless boot"
grep -Eq '^%wheel ALL=\(ALL\) ALL$' "${R}/etc/sudoers" && ok "%wheel line present" || bad "no %wheel line"
grep -q 'NOT an administrator' "${R}/console" 2>/dev/null && bad "false 'NOT an administrator' with --local-admin" || ok "no false no-admin line"

echo "== A6b. a %wheel line already there is not duplicated (local account and fallback) =="
R="${WORK}/a6b"; make_root "${R}"; printf '%%wheel ALL=(ALL) ALL\n' > "${R}/etc/sudoers"
render "${R}" "${HASH6}" false true; run_fb "${R}"
[ "$(grep -c '^%wheel' "${R}/etc/sudoers")" = 1 ] && ok "local-account path: one %wheel line" \
    || bad "local-account path duplicated %wheel ($(grep -c '^%wheel' "${R}/etc/sudoers") lines)"
R="${WORK}/a6c"; make_root "${R}"; printf '%%wheel ALL=(ALL) ALL\n' > "${R}/etc/sudoers"
render "${R}" "" false; run_fb "${R}"
[ "$(grep -c '^%wheel' "${R}/etc/sudoers")" = 1 ] && ok "fallback path: one %wheel line" \
    || bad "fallback path duplicated %wheel ($(grep -c '^%wheel' "${R}/etc/sudoers") lines)"

echo "== A7. STANDALONE=false + password, KEYS provisioned users: an ADDITIONAL account, no wheel =="
R="${WORK}/a7"; make_root "${R}"; keys_provisioned "${R}"; printf '%%wheel ALL=(ALL) ALL  # hugmesh: governed\n' > "${R}/etc/sudoers"
sed -i 's/^%wheel/# %wheel/' "${R}/etc/sudoers"
cp "${R}/etc/sudoers" "${R}/sudoers.before"
render "${R}" "${HASH6}" false; run_fb "${R}"
[ "$(cat "${R}/shadow.hash" 2>/dev/null)" = "magus:${HASH6}" ] \
    && ok "hash applied to the additional local account" || bad "hash not applied on a KEYS-provisioned image"
grep -q 'wheel' "${R}/groups.magus" 2>/dev/null && bad "additional local account was put in wheel" \
    || ok "additional local account is not in wheel"
cmp -s "${R}/etc/sudoers" "${R}/sudoers.before" && ok "/etc/sudoers untouched (governance's commented %wheel stays commented)" \
    || bad "/etc/sudoers changed on a KEYS image: $(diff "${R}/sudoers.before" "${R}/etc/sudoers" | tr '\n' ' ')"
[ -z "$(ls -A "${R}/etc/sudoers.d" 2>/dev/null)" ] && ok "no sudoers.d grant without --local-admin" \
    || bad "sudoers.d grant written without --local-admin"
grep -q '^passwd -l root' "${R}/log" && bad "root re-locked on a KEYS image (KEYS decides root)" || ok "root left to KEYS"
grep -qE '^alice:' "${R}/etc/passwd" && ok "KEYS user still there" || bad "KEYS user gone"
grep -q 'KEYLESS BOOT' "${R}/out" && bad "keyless fallback ran on a KEYS image" || ok "keyless fallback did not run"

echo "== A7b. KEYS already created an account with this NAME: KEYS wins, nothing changed =="
R="${WORK}/a7b"; make_root "${R}"; keys_provisioned "${R}" magus
render "${R}" "${HASH6}" false; run_fb "${R}"
[ ! -e "${R}/shadow.hash" ] && [ ! -e "${R}/shadow.plain" ] && ok "KEYS account's password left alone" \
    || bad "the build-time password overwrote a KEYS-created account's password"
grep -q 'KEYS provisioning already created magus' "${R}/console" 2>/dev/null && ok "console says why" \
    || bad "silent skip: the console does not say the Login Password was not applied"
[ ! -e "${R}/self" ] && ok "finaliser removed itself (nothing to retry)" || bad "finaliser kept for a skip"

echo "== A7c. our own account from a failed attempt is retried, not mistaken for a KEYS one =="
R="${WORK}/a7c"; make_root "${R}"; keys_provisioned "${R}"
render "${R}" "${HASH6}" false; run_fb "${R}" CHPASSWD_FAIL=1
[ -e "${R}/self" ] && ok "kept for a retry after chpasswd failed" || bad "deleted itself after a failed chpasswd"
render "${R}" "${HASH6}" false; run_fb "${R}"
[ "$(cat "${R}/shadow.hash" 2>/dev/null)" = "magus:${HASH6}" ] && ok "second boot applied the hash" \
    || bad "second boot treated our own account as a KEYS account and skipped it"

echo "== A8. --local-admin on a KEYS image: sudo via sudoers.d, never the shared %wheel line =="
R="${WORK}/a8"; make_root "${R}"; keys_provisioned "${R}"
render "${R}" "${HASH6}" false true; run_fb "${R}"
grep -qx 'magus ALL=(ALL) ALL' "${R}"/etc/sudoers.d/* 2>/dev/null && ok "sudoers.d grant for magus" \
    || bad "no sudoers.d grant with --local-admin"
grep -q '%wheel' "${R}/etc/sudoers" && bad "%wheel line written on a KEYS image" || ok "no %wheel line"

echo "== A9. STANDALONE=false, no password: the keyless fallback is unchanged =="
R="${WORK}/a9"; make_root "${R}"; render "${R}" "" false; run_fb "${R}"
grep -q 'KEYLESS BOOT' "${R}/console" 2>/dev/null && ok "keyless fallback banner on the console" \
    || bad "keyless fallback did not run with no password"
[ -s "${R}/shadow.plain" ] && ok "random one-time password set" || bad "no random password"
grep -q 'wheel' "${R}/groups.magus" 2>/dev/null && bad "keyless fallback put in wheel WITHOUT --local-admin" \
    || ok "keyless fallback is not in wheel without --local-admin"
grep -q 'magus is NOT an administrator' "${R}/console" 2>/dev/null && ok "fallback banner says it is not an administrator" \
    || bad "silent: the fallback banner does not say nobody can sudo"
grep -q '^passwd -l root' "${R}/log" && ok "root stays locked (never unlocked to make up for it)" || bad "root not locked"
R="${WORK}/a9a"; make_root "${R}"; render "${R}" "" false true; run_fb "${R}"
grep -q 'wheel' "${R}/groups.magus" 2>/dev/null && ok "--local-admin: keyless fallback in wheel" \
    || bad "--local-admin ignored by the keyless fallback"
grep -q 'NOT an administrator' "${R}/console" 2>/dev/null && bad "false no-admin banner with --local-admin" || ok "no false no-admin banner"
R="${WORK}/a9k"; make_root "${R}"; keys_provisioned "${R}"; render "${R}" "" false; run_fb "${R}"
[ ! -e "${R}/shadow.plain" ] && [ ! -e "${R}/shadow.hash" ] && ! grep -qE '^magus:' "${R}/etc/passwd" \
    && ok "KEYS image, no password: no local account at all" || bad "KEYS image with no password got a local account"

echo "== A10. hugmesh-home-setup's log() reaches the console (OpenRC local discards stdout) =="
LOGFN="$(sed -n '/^log() {/,/^}/p' "${HOMESETUP}")"
if [ -z "${LOGFN}" ]; then
    bad "log() not found in ${HOMESETUP}"
else
    LW="${WORK}/hslog"; mkdir -p "${LW}"
    ( eval "$(printf '%s\n' "${LOGFN}" | sed "s|/dev/console|${LW}/console|g")"
      log "run ecryptfs-migrate-home -u magus as root" ) > "${LW}/out" 2>&1
    grep -q 'ecryptfs-migrate-home -u magus' "${LW}/console" 2>/dev/null \
        && ok "home-setup log line written to the console" || bad "home-setup log() never reaches the console"
fi

# ── B. home-setup's PAM wiring ─────────────────────────────────────────────────
echo "== B. pam_ecryptfs wiring keeps every pam_unix jump target =="
FN="$(sed -n '/^wire_pam_ecryptfs() {/,/^}/p' "${HOMESETUP}")"
[ -n "${FN}" ] || { bad "wire_pam_ecryptfs() not found in ${HOMESETUP}"; FN='wire_pam_ecryptfs() { return 1; }'; }
eval "${FN}"
W="${WORK}/pam"; mkdir -p "${W}"
cp "${PAMFIX}" "${W}/wired"
wire_pam_ecryptfs "${W}/wired" && ok "wire_pam_ecryptfs ran" || bad "wire_pam_ecryptfs failed"
cp "${W}/wired" "${W}/wired.once"; wire_pam_ecryptfs "${W}/wired"
cmp -s "${W}/wired" "${W}/wired.once" && ok "idempotent" || bad "a second run changed the file"
[ "$(grep -c pam_ecryptfs "${W}/wired")" = 3 ] && ok "auth/password/session each wired once" \
    || bad "expected 3 pam_ecryptfs lines, got $(grep -c pam_ecryptfs "${W}/wired")"

# jumps CHECK — for every `[... success=N ...]` line, the line N+1 further down the
# SAME stack must be identical before and after wiring.
jump_targets() {
    awk '
        { t = $1; sub(/^-/, "", t); n[t]++; L[t, n[t]] = $0 }
        END {
            for (t in n) for (i = 1; i <= n[t]; i++)
                if (match(L[t, i], /success=[0-9]+/)) {
                    k = substr(L[t, i], RSTART + 8, RLENGTH - 8) + 0
                    printf "%s#%d -> %s\n", t, i, L[t, i + k + 1]
                }
        }' "$1" | sort
}
[ "$(jump_targets "${PAMFIX}")" = "$(jump_targets "${W}/wired")" ] \
    && ok "every success=N jump lands on the same line as before wiring" \
    || bad "a success=N jump now lands on a different line: $(diff <(jump_targets "${PAMFIX}") <(jump_targets "${W}/wired") | tr '\n' ' ')"
ai="$(grep -n '^auth.*pam_ecryptfs' "${W}/wired" | cut -d: -f1)"
fi_="$(grep -n '^auth.*pam_faillock.so authfail' "${W}/wired" | cut -d: -f1)"
[ -n "${ai}" ] && [ -n "${fi_}" ] && [ "${ai}" -gt "${fi_}" ] \
    && ok "auth pam_ecryptfs sits after the faillock authfail line" \
    || bad "auth pam_ecryptfs (line ${ai:-none}) is not after faillock authfail (line ${fi_:-none})"

# The defect, reproduced on the same fixture, so the checks above are known to bite.
sed '/^auth.*pam_unix\.so/a auth\t\toptional\tpam_ecryptfs.so unwrap' "${PAMFIX}" > "${W}/old"
[ "$(jump_targets "${PAMFIX}")" != "$(jump_targets "${W}/old")" ] \
    && ok "control: the pre-fix placement IS caught by the jump check" \
    || bad "control: the jump check cannot see the pre-fix placement (vacuous)"

echo "== B2. executed through libpam (pam_unix -> pam_permit/pam_deny stand-ins) =="
PAMPY="${WORK}/pam.py"
cat > "${PAMPY}" <<'PY'
import ctypes, ctypes.util, sys
confdir, service = sys.argv[1], sys.argv[2]
libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
libc = ctypes.CDLL(None)
libc.calloc.restype = ctypes.c_void_p
class Resp(ctypes.Structure): _fields_ = [("resp", ctypes.c_char_p), ("rc", ctypes.c_int)]
CONV = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.c_void_p,
                        ctypes.POINTER(ctypes.POINTER(Resp)), ctypes.c_void_p)
class Conv(ctypes.Structure): _fields_ = [("conv", CONV), ("appdata", ctypes.c_void_p)]
@CONV
def conv(n, msgs, resp, app):
    resp[0] = ctypes.cast(libc.calloc(n, ctypes.sizeof(Resp)), ctypes.POINTER(Resp))
    return 0
h = ctypes.c_void_p(); c = Conv(conv, None)
libpam.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(Conv),
                                     ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
rc = libpam.pam_start_confdir(service.encode(), b"nobody", ctypes.byref(c),
                              confdir.encode(), ctypes.byref(h))
if rc != 0:
    sys.exit(100)
rc = libpam.pam_authenticate(h, 0)
libpam.pam_end(h, rc)
print(rc)
PY
# stack VARIANT FILE UNIX_STAND_IN -> a confdir whose service "t" is FILE with the
# password check replaced and every module path made executable here.
stack() {
    local d="${W}/cd-$1"; mkdir -p "${d}" "${W}/tally-$1"
    sed -e "s/pam_unix\.so/$3/" -e 's/pam_ecryptfs\.so/pam_permit.so/' -e 's/pam_cap\.so/pam_permit.so/' \
        -e "s|pam_faillock\.so \(preauth\|authfail\)|pam_faillock.so \1 dir=${W}/tally-$1|" \
        -e "s|^\(account.*pam_faillock\.so\)$|\1 dir=${W}/tally-$1|" "$2" > "${d}/t"
    echo "${d}"
}
probe="$(python3 "${PAMPY}" "$(stack probe "${PAMFIX}" pam_permit.so)" t 2>/dev/null)"
if [ "${probe}" = "0" ]; then
    [ "$(python3 "${PAMPY}" "$(stack good "${W}/wired" pam_permit.so)" t)" = 0 ] \
        && ok "wired stack: correct password authenticates (rc=0)" \
        || bad "wired stack: correct password REJECTED"
    [ "$(python3 "${PAMPY}" "$(stack wrong "${W}/wired" pam_deny.so)" t)" != 0 ] \
        && ok "wired stack: wrong password still rejected" \
        || bad "wired stack: wrong password ACCEPTED"
    [ "$(python3 "${PAMPY}" "$(stack old "${W}/old" pam_permit.so)" t)" != 0 ] \
        && ok "control: the pre-fix stack rejects a correct password (the defect reproduces)" \
        || bad "control: pre-fix stack accepted — this layer cannot see the defect"
elif [ "${HUGMESH_REQUIRE_LIBPAM:-0}" = 1 ] || [ "${GITHUB_ACTIONS:-}" = true ]; then
    bad "libpam execution unavailable here (probe='${probe}') and it is required in CI (GITHUB_ACTIONS) or with HUGMESH_REQUIRE_LIBPAM=1"
else
    echo "  NOTE libpam execution layer not runnable here (probe='${probe}'); the jump check above is the gate"
fi

# ── C. static pins ─────────────────────────────────────────────────────────────
echo "== C. the finaliser holding the hash is root-only in every builder =="
for b in "${REPO}"/build-*-stage4.sh; do
    n="$(basename "${b}")"
    awk '/^render_template "\$\{SHARED_SPECS\}\/etc\/local.d\/01-firstboot.start.tmpl"/ { r = 1 }
         r && /^chmod go-rwx "\$\{SYSROOT\}\/etc\/local.d\/01-firstboot.start"$/ { found = 1 }
         END { exit !found }' "${b}" \
        && ok "${n}: chmod go-rwx after rendering" || bad "${n}: rendered finaliser stays world-readable"
done
echo "== C2. Calamares does not ask for an account it throws away =="
if awk '/^sequence:/ { s = 1 } s && /^[a-z]/ && !/^sequence:/ { s = 0 } s' "${CALA}" | grep -E '^[[:space:]]*-[[:space:]]*users[[:space:]]*$' >/dev/null; then
    bad "Calamares shows the 'users' page, but nothing applies what is typed there"
else
    ok "no 'users' page in the Calamares sequence"
fi

echo "== C3. every builder renders @@LOCAL_ADMIN@@ (the harness's @@*@@ catch-all would hide a miss) =="
for b in "${REPO}"/build-*-stage4.sh; do
    n="$(basename "${b}")"
    grep -q 's|@@LOCAL_ADMIN@@|' "${b}" && grep -q -- '--local-admin)' "${b}" && grep -q -- '--local-pass-file)' "${b}" \
        && ok "${n}: --local-admin/--local-pass-file parsed, @@LOCAL_ADMIN@@ rendered" \
        || bad "${n}: missing --local-admin/--local-pass-file arm or @@LOCAL_ADMIN@@ substitution"
done
echo "== C3b. admin is opt-in in every builder and in the template (static guard) =="
# The template: nothing grants wheel except @@LOCAL_ADMIN@@.
if sed '/^[[:space:]]*#/d' "${TMPL}" | grep -E 'useradd[^#]*-G[[:space:]]*"?wheel' >/dev/null; then
    bad "template: a useradd with a literal wheel group (admin must come from @@LOCAL_ADMIN@@)"
else
    ok "template: no useradd with a literal wheel group"
fi
grep -qx '    LL_WHEEL=false' "${TMPL}" && ok "template: LL_WHEEL defaults to false" \
    || bad "template: LL_WHEEL does not default to false"
[ "$(grep -c '"@@LOCAL_ADMIN@@" = "true"' "${TMPL}")" -ge 3 ] && ok "template: local account, KEYS grant and fallback all read @@LOCAL_ADMIN@@" \
    || bad "template: some account path does not read @@LOCAL_ADMIN@@"
for b in "${REPO}"/build-*-stage4.sh; do
    n="$(basename "${b}")"
    grep -q '^LOCAL_ADMIN=false ' "${b}" && ok "${n}: LOCAL_ADMIN defaults to false" || bad "${n}: LOCAL_ADMIN does not default to false"
    grep -q 'KEYS-provisioned image too' "${b}" && bad "${n}: help still says --local-admin only matters on a KEYS image" \
        || ok "${n}: help does not limit --local-admin to KEYS images"
    grep -qE '^ +--local-admin +Make the local|^ +--local-admin$' "${b}" && ok "${n}: usage documents --local-admin" \
        || bad "${n}: usage does not document --local-admin"
done
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh build-frite-stage4.sh \
         build-orangepi5-stage4.sh build-orangepi4-lts-stage4.sh \
         build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh \
         build-orangepi3-lts-stage4.sh; do
    awk '/^if ! \$\{LOCAL_ADMIN\}; then$/ { a = 1; next }
         a && /warn "No --local-admin: the local login account will NOT be an administrator\./ { f = 1 }
         a && /^fi$/ { a = 0 }
         END { exit !f }' "${REPO}/${b}" \
        && ok "${b}: warns at build time when there is no --local-admin" \
        || bad "${b}: builds an image with no administrator silently (no --local-admin warning)"
done

echo "== C3c. the template carries no password token (x86 used to render --user-password/--root-password into a comment) =="
grep -qE '@@(DEFAULT_USER_PASS|ROOT_PASS)@@' "${TMPL}" \
    && bad "template: still carries a @@DEFAULT_USER_PASS@@/@@ROOT_PASS@@ token" \
    || ok "template: no password token for a builder to render"
grep -q 'never locked out' "${TMPL}" && bad "template: still promises 'never locked out'" \
    || ok "template: no 'never locked out' promise"

echo "== C4. a standalone DESKTOP builder refuses a real build with no password =="
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh build-frite-stage4.sh \
         build-orangepi5-stage4.sh build-orangepi4-lts-stage4.sh; do
    grep -q 'standalone desktop build with no --local-pass/--local-pass-file' "${REPO}/${b}" \
        && ok "${b}: refuses" || bad "${b}: still builds a standalone desktop with no login password"
done
for b in build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh build-orangepi-zero3-stage4.sh \
         build-orangepi3-lts-stage4.sh; do
    grep -q 'standalone desktop build with no --local-pass/--local-pass-file' "${REPO}/${b}" \
        && bad "${b}: headless appliance refuses (its serial console IS the login surface)" || ok "${b}: appliance keeps the console one-time password"
done

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
