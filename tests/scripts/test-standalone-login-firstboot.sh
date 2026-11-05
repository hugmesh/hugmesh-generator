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
# make_root DIR — a throwaway root with the image's group set (no `games`) and the
# account-tool shims on DIR/bin. The shims keep their state under DIR only.
make_root() {
    local r="$1"
    mkdir -p "${r}/etc" "${r}/bin" "${r}/var/lib"
    printf '%s\n' 'root:x:0:' 'wheel:x:10:root' 'audio:x:18:' 'video:x:27:' \
        'usb:x:85:' 'plugdev:x:440:' > "${r}/etc/group"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' > "${r}/etc/passwd"
    : > "${r}/etc/sudoers"
    : > "${r}/log"
    # getent group|passwd NAME
    cat > "${r}/bin/getent" <<EOF
#!/usr/bin/env bash
db="\$1"; key="\$2"
grep -E "^\${key}:" "${r}/etc/\${db}"
EOF
    cat > "${r}/bin/groupadd" <<EOF
#!/usr/bin/env bash
echo "groupadd \$*" >> "${r}/log"
[ "\${GROUPADD_FAIL:-0}" = 1 ] && exit 10
g="\${@: -1}"
echo "\${g}:x:900:" >> "${r}/etc/group"
EOF
    # useradd: shadow's rule — every -G group must exist, else exit 6, NO user.
    cat > "${r}/bin/useradd" <<EOF
#!/usr/bin/env bash
echo "useradd \$*" >> "${r}/log"
if [ "\${USERADD_FAIL_ONCE:-0}" = 1 ] && [ ! -e "${r}/useradd.failed" ]; then
    : > "${r}/useradd.failed"; echo "useradd: cannot lock /etc/passwd" >&2; exit 1
fi
groups=""; user=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -G) groups="\$2"; shift 2 ;;
        -s|-u|-g|-d|-c) shift 2 ;;
        -*) shift ;;
        *) user="\$1"; shift ;;
    esac
done
IFS=, read -r -a gl <<< "\${groups}"
for g in "\${gl[@]}"; do
    grep -qE "^\${g}:" "${r}/etc/group" || { echo "useradd: group '\${g}' does not exist" >&2; exit 6; }
done
echo "\${user}:x:1000:1000::/home/\${user}:/bin/bash" >> "${r}/etc/passwd"
echo "\${user}:\${groups}" > "${r}/groups.\${user}"
EOF
    cat > "${r}/bin/id" <<EOF
#!/usr/bin/env bash
grep -qE "^\${@: -1}:" "${r}/etc/passwd"
EOF
    # chpasswd [-e]: records exactly what it was handed; fails for an unknown user.
    cat > "${r}/bin/chpasswd" <<EOF
#!/usr/bin/env bash
mode=plain; [ "\${1:-}" = -e ] && mode=hash
line="\$(cat)"
echo "chpasswd \${mode}" >> "${r}/log"
[ "\${CHPASSWD_FAIL:-0}" = 1 ] && exit 1
grep -qE "^\${line%%:*}:" "${r}/etc/passwd" || { echo "chpasswd: user '\${line%%:*}' does not exist" >&2; exit 1; }
printf '%s\n' "\${line}" > "${r}/shadow.\${mode}"
EOF
    for t in passwd chage; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/log"\n' "${t}" "${r}" > "${r}/bin/${t}"
    done
    for t in locale-gen eselect; do printf '#!/bin/sh\nexit 0\n' > "${r}/bin/${t}"; done
    printf '#!/bin/sh\nexit 1\n' > "${r}/bin/env-update"   # skips `source /etc/profile`
    chmod +x "${r}"/bin/*
}

# render ROOT HASH STANDALONE — the real template, rendered the way the builders do,
# cut before the Kubernetes section (host-mutating), plus the template's own
# self-delete line, with absolute paths moved under ROOT.
render() {
    local r="$1" hash="$2" sa="$3" body tail_line
    body="$(sed -n '1,/^# ── Kubernetes kernel modules/p' "${TMPL}")"
    tail_line="$(grep -E 'rm -f /etc/local.d/01-firstboot.start$' "${TMPL}")"
    printf '%s\n%s\n' "${body}" "${tail_line}" \
      | sed -e "s|@@STANDALONE@@|${sa}|g" -e 's|@@DEFAULT_USER@@|magus|g' \
            -e "s|@@LOCAL_PASSHASH@@|${hash}|g" -e 's|@@[A-Z_]*@@|x|g' \
            -e "s|/var/lib/keys-provision|${r}/var/lib/keys-provision|g" \
            -e "s|/etc/sudoers|${r}/etc/sudoers|g" \
            -e "s|/dev/console|${r}/console|g" \
            -e "s|/etc/local.d/01-firstboot.start|${r}/self|g" > "${r}/self"
    chmod +x "${r}/self"
    cp "${r}/self" "${r}/rendered"
}

run_fb() { local r="$1"; shift; ( cd "${r}" && env "$@" PATH="${r}/bin:${PATH}" bash "${r}/self" ) > "${r}/out" 2>&1; }

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
grep -Eq '^%wheel ALL=\(ALL\) ALL$' "${R}/etc/sudoers" && ok "wheel may sudo" || bad "no %wheel sudoers line"

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

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
