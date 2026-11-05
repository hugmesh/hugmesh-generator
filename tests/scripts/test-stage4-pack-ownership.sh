#!/usr/bin/env bash
# test-stage4-pack-ownership.sh — the owners an ARM stage4 TARBALL carries.
#
# WHAT BROKE (2026-11-04). Every ARM builder packed its sysroot with
# `tar --numeric-owner --owner=0 --group=0`, and fills its .img / installer from
# that tarball. The sysroot was right (rpi5 pki build system: /var/lib/tor 43:43
# 0750, net-vpn/tor's fowners/fperms) but all 49,958 members of the shipped
# tarball were 0/0. Tor setuids to `tor` before checking its DataDirectory, so a
# root:root 0750 /var/lib/tor fails `tor --verify-config`: the reconcile kept the
# stock torrc, OpenRC's checkconfig refused it, and the QEMU device run of every
# tor-selected rpi5 node failed 4 tor assertions. The flatten also dropped every
# other package owner (portage, shadow, cron, utmp, mail ...).
#
# THE CONTRACT pinned here (hmr_pack_owner_args, scripts/_builder-resume-lib.sh):
#   1. an owner the TARGET defines (its own etc/passwd / etc/group) survives the
#      pack — tor:tor stays 43:43, root:shadow stays 0:42;
#   2. an id the target does NOT define (a build user's 1002) becomes root:0 —
#      the reason the flatten existed is kept;
#   3. a build system that is not root-owned at its top (chown -R'd) is still
#      flattened, with a warning;
#   4. a census that reads nothing fails CLOSED (flatten), never "no foreign ids";
#   5. every ARM builder packs through it, in both of its tar lines, and no
#      builder carries the unconditional flatten any more; x86 keeps
#      --numeric-owner (it never flattened).
# Legs 1-3 EXECUTE each builder's own pack lines (extracted from its text) with
# GNU tar against a fixture holding real non-root owners. That needs root: real
# root (the CI job runs as root in alpine), else `unshare --map-root-user
# --map-auto`; where neither is possible the suite FAILS (guard_require_capability:
# a pass that never looked is not a pass) unless GUARD_TOOLING_ALLOW_SKIP=1 is set
# on purpose. The root-free legs (a stat shim, the technique
# test-builder-resume-safety.sh uses) additionally drive both census branches as a
# plain user.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_builder-resume-lib.sh"
# shellcheck source=../lib/guard-preflight.sh
. "${REPO}/tests/lib/guard-preflight.sh"
guard_require_tools tar xz find stat awk mktemp
tar --version 2>/dev/null | grep -F 'GNU tar' >/dev/null \
    || guard_require_capability "GNU tar is required (the builders pack with --owner-map / --group-map, which only GNU tar has)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/s4pack.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
ARM_BUILDERS=()
for b in "${REPO}"/build-*-stage4.sh; do
    case "$(basename "$b")" in build-x86-host-stage4.sh) ;; *) ARM_BUILDERS+=("$b") ;; esac
done

# The pack section of a builder: from its hmr_pack_owner_args call through the
# fallback tar's final `-cJf "${STAGE4_TARBALL}" .` line (the one with no `||`).
pack_section() {  # BUILDER -> stdout
    awk '/^hmr_pack_owner_args "\$\{SYSROOT\}"$/ {on=1}
         on {print}
         on && /-cJf "\$\{STAGE4_TARBALL\}" \.$/ {exit}' "$1"
}

# ═════════════════════════════ 5. static pins ═════════════════════════════════
echo "== 5. every ARM builder packs through hmr_pack_owner_args =="
for b in "${ARM_BUILDERS[@]}"; do
    n="$(basename "$b")"
    sec="$(pack_section "$b")"
    if grep -a -F -- '--owner=0 --group=0' "$b" >/dev/null 2>&1; then
        bad "${n}: still carries the unconditional '--owner=0 --group=0' flatten"
    else
        ok "${n}: no unconditional owner flatten"
    fi
    nt="$(printf '%s\n' "${sec}" | grep -c -F 'tar -C "${SYSROOT}"')"
    na="$(printf '%s\n' "${sec}" | grep -c -F '"${HMR_PACK_OWNER_ARGS[@]}"')"
    if [ "${nt}" -eq 2 ] && [ "${na}" -eq 2 ]; then
        ok "${n}: both stage4 tar lines (xattr and fallback) follow hmr_pack_owner_args and use its flags"
    else
        bad "${n}: pack section has ${nt} tar line(s) and ${na} use(s) of HMR_PACK_OWNER_ARGS (want 2 and 2)"
    fi
done
X86="${REPO}/build-x86-host-stage4.sh"
if grep -a -F -- '--owner=0' "${X86}" >/dev/null 2>&1; then
    bad "build-x86-host-stage4.sh: an owner flatten appeared (x86 has always preserved owners; its resume path refuses a user-owned tree instead)"
else
    ok "build-x86-host-stage4.sh: no owner flatten (it packs with --numeric-owner and gates --resume on hmr_owner_gate)"
fi

# ═══════════════════ fixture + the builder's lines, executed ═══════════════════
# mkfix DIR [top-uid] — a sysroot whose target defines root(0) and tor(43) and the
# groups root(0) / shadow(42) / tor(43); one foreign 1002:1002 entry. Run as root.
cat > "${WORK}/mkfix.sh" <<'EOF'
set -eu
d="$1"; top="${2:-0}"
rm -rf "$d"; mkdir -p "$d/etc" "$d/var/lib/tor/data" "$d/usr/lib64" "$d/bin" "$d/var/empty" "$d/var/db/pkg" "$d/home/build"
printf 'root:x:0:0::/root:/bin/sh\ntor:x:43:43:user for tor daemon:/dev/null:/sbin/nologin\n' > "$d/etc/passwd"
printf 'root:x:0:\nshadow:x:42:\ntor:x:43:\n' > "$d/etc/group"
: > "$d/etc/shadow"
chown -R 0:0 "$d"
chown 43:43 "$d/var/lib/tor" "$d/var/lib/tor/data"; chmod 0750 "$d/var/lib/tor"; chmod 0700 "$d/var/lib/tor/data"
chown 0:42 "$d/etc/shadow"; chmod 0640 "$d/etc/shadow"
chown 1002:1002 "$d/home/build"
[ "${top}" = 0 ] || chown "${top}:${top}" "$d" "$d/etc" "$d/usr"
EOF
# run_pack BUILDER SYSROOT OUT — the builder's own pack section, executed.
cat > "${WORK}/runpack.sh" <<'EOF'
set -euo pipefail
LIB="$1"; B="$2"; SYSROOT="$3"; STAGE4_TARBALL="$4"; SEC="$5"
info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }; err(){ echo "ERR: $*" >&2; }
. "${LIB}"
. "${SEC}"
EOF
# owners_of TARBALL -> "member uid/gid" lines, numeric
owners_of() { tar -tvJf "$1" --numeric-owner 2>/dev/null | awk '{m=$NF; sub(/\/$/, "", m); print m, $2}'; }
own() { printf '%s\n' "$2" | awk -v m="$1" '$1==m {print $2; exit}'; }

ROOTRUN=""
if [ "$(id -u)" -eq 0 ]; then
    ROOTRUN="direct"
elif unshare --map-root-user --map-auto true 2>/dev/null \
     && unshare --map-root-user --map-auto bash -c 'd=$(mktemp -d); touch "$d/x"; chown 1002:1002 "$d/x"; r=$?; rm -rf "$d"; exit $r' 2>/dev/null; then
    ROOTRUN="userns"
fi
[ -n "${ROOTRUN}" ] || guard_require_capability "root, or unshare --map-root-user --map-auto, is required to create fixture files owned by uid 43 and 1002"
asroot() {  # CMD... as (namespace) root
    if [ "${ROOTRUN}" = direct ]; then "$@"; else unshare --map-root-user --map-auto "$@"; fi
}

echo "== 1-3. each ARM builder's pack lines, executed against a fixture with real owners =="
{
    echo "  (running as ${ROOTRUN} root)"
    for b in "${ARM_BUILDERS[@]}"; do
        n="$(basename "$b" -stage4.sh)"
        pack_section "$b" > "${WORK}/sec-${n}.sh"
        # 1+2. a root-owned build system: target owners kept, foreign ids -> root.
        SR="${WORK}/sr-${n}"; OUT="${WORK}/${n}.stage4.tar.xz"
        asroot bash "${WORK}/mkfix.sh" "${SR}" 0
        log="$(asroot bash "${WORK}/runpack.sh" "${LIB}" "$b" "${SR}" "${OUT}" "${WORK}/sec-${n}.sh" 2>&1)"; rc=$?
        lst="$(owners_of "${OUT}")"
        if [ "${rc}" -eq 0 ] && [ "$(own ./var/lib/tor "${lst}")" = 43/43 ] && [ "$(own ./var/lib/tor/data "${lst}")" = 43/43 ]; then
            ok "${n}: tor:tor /var/lib/tor survives the pack (43/43)"
        else
            bad "${n}: /var/lib/tor packed as '$(own ./var/lib/tor "${lst}")' (rc=${rc}), want 43/43 — tor cannot reach its DataDirectory"; printf '%s\n' "${log}" | sed 's/^/      | /'
        fi
        [ "$(own ./etc/shadow "${lst}")" = 0/42 ] && ok "${n}: root:shadow /etc/shadow survives (0/42)" \
            || bad "${n}: /etc/shadow packed as '$(own ./etc/shadow "${lst}")', want 0/42"
        if [ "$(own ./home/build "${lst}")" = 0/0 ] && ! printf '%s\n' "${lst}" | awk '{print $2}' | grep -E '(^|/)1002(/|$)' >/dev/null; then
            ok "${n}: the foreign 1002:1002 entry is packed as root (no build-user uid in the tarball)"
        else
            bad "${n}: a uid/gid the target does not define reached the tarball (home/build '$(own ./home/build "${lst}")')"
        fi
        # 3. a chown -R'd build system: the old flatten, with a warning.
        SR2="${WORK}/sr2-${n}"; OUT2="${WORK}/${n}.user.stage4.tar.xz"
        asroot bash "${WORK}/mkfix.sh" "${SR2}" 1002
        log="$(asroot bash "${WORK}/runpack.sh" "${LIB}" "$b" "${SR2}" "${OUT2}" "${WORK}/sec-${n}.sh" 2>&1)"; rc=$?
        nonroot="$(owners_of "${OUT2}" | awk '$2 != "0/0"' | wc -l | tr -d '[:space:]')"
        if [ "${rc}" -eq 0 ] && [ "${nonroot}" -eq 0 ] && printf '%s' "${log}" | grep -F 'not root-owned at its top' >/dev/null; then
            ok "${n}: a build system not root-owned at its top is flattened to 0/0, and says so"
        else
            bad "${n}: user-owned build system: rc=${rc}, ${nonroot} non-root member(s), log: $(printf '%s' "${log}" | tr '\n' ' ')"
        fi
        asroot rm -rf "${SR}" "${SR2}"
    done
}

# ═════════════════ 4 + census both ways, without root ═════════════════════════
echo "== 4. the census, both branches and fail-closed, root-free (stat shim for the top-dir gate only) =="
REAL_STAT="$(command -v stat)"
mkdir -p "${WORK}/bin-gate" "${WORK}/bin-empty"
# The gate calls `stat -L -c %u`; answer 0 for those only, so the census (stat -c
# '%u %g') still reads the REAL owners.
cat > "${WORK}/bin-gate/stat" <<EOF
#!/usr/bin/env bash
[ "\$1" = -L ] && exec echo 0
exec "${REAL_STAT}" "\$@"
EOF
# The same, but the census stat returns nothing — a census that read nothing.
cat > "${WORK}/bin-empty/stat" <<EOF
#!/usr/bin/env bash
[ "\$1" = -L ] && exec echo 0
exit 1
EOF
chmod +x "${WORK}/bin-gate/stat" "${WORK}/bin-empty/stat"
ME="$(id -u)"; MG="$(id -g)"
mk_userfix() {  # DIR DEFINE-ME(yes|no)
    rm -rf "$1"; mkdir -p "$1/etc" "$1/var/lib/tor"
    if [ "$2" = yes ]; then
        printf 'root:x:0:0::/root:/bin/sh\nme:x:%s:%s::/:/bin/sh\n' "${ME}" "${MG}" > "$1/etc/passwd"
        printf 'root:x:0:\nme:x:%s:\n' "${MG}" > "$1/etc/group"
    else
        printf 'root:x:0:0::/root:/bin/sh\n' > "$1/etc/passwd"
        printf 'root:x:0:\n' > "$1/etc/group"
    fi
}
argsof() {  # BIN-DIR SYSROOT -> the flags, one per line, then the log
    PATH="$1:${PATH}" bash -c '. "$1"; info(){ echo "INFO: $*"; }; warn(){ echo "WARN: $*"; }; hmr_pack_owner_args "$2"; printf "ARG %s\n" "${HMR_PACK_OWNER_ARGS[@]}"; [ -n "${HMR_PACK_MAP_DIR}" ] && cat "${HMR_PACK_MAP_DIR}/owner-map" "${HMR_PACK_MAP_DIR}/group-map" | sed "s/^/MAP /"' _ "${LIB}" "$2" 2>&1
}
if [ "${ME}" -eq 0 ]; then
    echo "  SKIP root-free census legs: running as root, the fixture would be root-owned (legs 1-3 above covered both branches with real owners)"
else
    U1="${WORK}/u-defined"; mk_userfix "${U1}" yes
    o="$(argsof "${WORK}/bin-gate" "${U1}")"
    if printf '%s\n' "${o}" | grep -x -F 'ARG --numeric-owner' >/dev/null \
       && ! printf '%s\n' "${o}" | grep -F -e 'ARG --owner=0' -e 'ARG --owner-map' >/dev/null; then
        ok "census: every owner is a target account (uid ${ME} defined) -> --numeric-owner, nothing mapped"
    else
        bad "census (defined): $(printf '%s' "${o}" | tr '\n' ' ')"
    fi
    U2="${WORK}/u-foreign"; mk_userfix "${U2}" no
    o="$(argsof "${WORK}/bin-gate" "${U2}")"
    if printf '%s\n' "${o}" | grep -x -F "MAP +${ME} root:0" >/dev/null \
       && printf '%s\n' "${o}" | grep -F 'ARG --owner-map=' >/dev/null \
       && printf '%s\n' "${o}" | grep -F 'ARG --group-map=' >/dev/null; then
        ok "census: uid ${ME} the target does not define -> owner-map/group-map send it to root:0"
    else
        bad "census (foreign): $(printf '%s' "${o}" | tr '\n' ' ')"
    fi
    flags="$(printf '%s\n' "${o}" | sed -n 's/^ARG //p')"
    mapfile -t fl <<< "${flags}"
    tar -C "${U2}" "${fl[@]}" -cJf "${WORK}/u2.tar.xz" . 2>/dev/null
    lst="$(owners_of "${WORK}/u2.tar.xz")"
    [ "$(own ./var/lib/tor "${lst}")" = 0/0 ] && ok "census: GNU tar applies the map — the foreign-owned member is packed 0/0" \
        || bad "census: the map was not applied by tar (var/lib/tor packed '$(own ./var/lib/tor "${lst}")')"
    o="$(argsof /nonexistent "${U2}")"
    if printf '%s\n' "${o}" | grep -x -F 'ARG --owner=0' >/dev/null \
       && printf '%s\n' "${o}" | grep -F 'not root-owned at its top' >/dev/null; then
        ok "gate: a tree this user owns (real stat) -> the flatten, with the rebuild-without---resume warning"
    else
        bad "gate (user-owned, real stat): $(printf '%s' "${o}" | tr '\n' ' ')"
    fi
    # The numbers the census LOGS must be the numbers the tarball CARRIES. The rpi5
    # make log of 2026-11-04 said "45 of 49203 entries are not root:root" while
    # `tar -tv` of that tarball listed 49190 members, 36 of them non-root: the census
    # walked var/cache (portage-owned distfiles) that every ARM pack line excludes.
    # Here: a fixture with members under the three excluded paths, packed with the
    # builders' own excludes; the census line and the listing must agree exactly.
    U4="${WORK}/u-excl"; mk_userfix "${U4}" yes
    mkdir -p "${U4}/var/cache/distfiles" "${U4}/usr/src/linux" "${U4}/tmp/portage"
    : > "${U4}/var/cache/distfiles/a.tar"; : > "${U4}/usr/src/linux/Makefile"; : > "${U4}/tmp/portage/x"
    o="$(argsof "${WORK}/bin-gate" "${U4}")"
    flags="$(printf '%s\n' "${o}" | sed -n 's/^ARG //p')"
    mapfile -t fl <<< "${flags}"
    tar -C "${U4}" "${fl[@]}" --exclude='./usr/src' --exclude='./var/cache' --exclude='./tmp/*' -cJf "${WORK}/u4.tar.xz" . 2>/dev/null
    lst="$(owners_of "${WORK}/u4.tar.xz")"
    t_all="$(printf '%s\n' "${lst}" | grep -c .)"
    t_nonroot="$(printf '%s\n' "${lst}" | awk '$2 != "0/0"' | grep -c .)"
    c_kept="$(printf '%s\n' "${o}" | sed -n 's/.*package owners (\([0-9]*\) of the \([0-9]*\) entries.*/\1/p' | head -1)"
    c_all="$(printf '%s\n' "${o}" | sed -n 's/.*package owners (\([0-9]*\) of the \([0-9]*\) entries.*/\2/p' | head -1)"
    if [ -n "${c_all}" ] && [ "${c_all}" = "${t_all}" ] && [ "${c_kept}" = "${t_nonroot}" ] && [ "${t_all}" -gt 0 ]; then
        ok "census counts what the tarball carries: ${c_kept} of ${c_all} logged == ${t_nonroot} of ${t_all} listed (usr/src, var/cache, tmp/* pruned like the pack lines)"
    else
        bad "census/tarball disagree: logged '${c_kept:-?} of ${c_all:-?}', tar lists ${t_nonroot} of ${t_all} (log: $(printf '%s' "${o}" | grep -F 'stage4 ownership' | tr '\n' ' '))"
    fi
    printf '%s\n' "${o}" | grep -F 'not packed and not counted' >/dev/null \
        && ok "census log says which paths are outside the count" || bad "census log does not name the unpacked paths: $(printf '%s' "${o}" | grep -F 'stage4 ownership')"
fi

# Runs as ANY user (as root the fixture is simply root's, which the gate passes).
U3="${WORK}/u-empty"; mk_userfix "${U3}" no
o="$(argsof "${WORK}/bin-empty" "${U3}")"
if printf '%s\n' "${o}" | grep -x -F 'ARG --owner=0' >/dev/null \
   && printf '%s\n' "${o}" | grep -F 'could not take an owner census' >/dev/null; then
    ok "census read nothing -> FAILS CLOSED to the flatten (never 'no foreign ids')"
else
    bad "census read nothing but the flags are: $(printf '%s' "${o}" | tr '\n' ' ')"
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
