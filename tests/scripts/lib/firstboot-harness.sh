#!/usr/bin/env bash
# firstboot-harness.sh — run the REAL first-boot finaliser template
# (specs/etc/local.d/01-firstboot.start.tmpl) offline, without root, against a
# throwaway root. Sourced by tests/scripts/test-standalone-login-firstboot.sh and
# driven by studio/tests/test_login_field_reaches_firstboot.py (which asks, for
# every Studio (mode, role, platform), whether the Login Password's hash lands).
#
# Needs TMPL set to the template path before render() is called.
#
# Probe entry (used by the Studio test), when executed rather than sourced:
#   bash firstboot-harness.sh probe STANDALONE HASH KEYS ADMIN
# prints one line per fact:  hash=<applied|absent> wheel=<y|n> sudoers_d=<y|n>
#   root_locked=<y|n> keyless_banner=<y|n> random=<y|n>
# KEYS=true pre-creates a KEYS user (alice) and users.created, as keys-provision does.

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

# render ROOT HASH STANDALONE [ADMIN] — the real template, rendered the way the builders do,
# cut before the Kubernetes section (host-mutating), plus the template's own
# self-delete line, with absolute paths moved under ROOT.
render() {
    local r="$1" hash="$2" sa="$3" admin="${4:-false}" body tail_line
    body="$(sed -n '1,/^# ── Kubernetes kernel modules/p' "${TMPL}")"
    tail_line="$(grep -E 'rm -f /etc/local.d/01-firstboot.start$' "${TMPL}")"
    printf '%s\n%s\n' "${body}" "${tail_line}" \
      | sed -e "s|@@STANDALONE@@|${sa}|g" -e 's|@@DEFAULT_USER@@|magus|g' \
            -e "s|@@LOCAL_ADMIN@@|${admin}|g" \
            -e "s|@@LOCAL_PASSHASH@@|${hash}|g" -e 's|@@[A-Z_]*@@|x|g' \
            -e "s|/var/lib/keys-provision|${r}/var/lib/keys-provision|g" \
            -e "s|/etc/sudoers|${r}/etc/sudoers|g" \
            -e "s|/dev/console|${r}/console|g" \
            -e "s|/etc/local.d/01-firstboot.start|${r}/self|g" > "${r}/self"
    chmod +x "${r}/self"
    cp "${r}/self" "${r}/rendered"
}

run_fb() { local r="$1"; shift; ( cd "${r}" && env "$@" PATH="${r}/bin:${PATH}" bash "${r}/self" ) > "${r}/out" 2>&1; }

# keys_provisioned ROOT [USER] [governed|ungoverned] — what keys-provision leaves behind:
# a KEYS user (default alice) in passwd, the users.created marker, and its own
# keys-users.created marker (provision.sh mark_keys_users).
keys_provisioned() {
    local r="$1"
    local u="${2:-alice}"
    mkdir -p "${r}/var/lib/keys-provision"
    echo "${u}:x:1001:1001::/home/${u}:/bin/bash" >> "${r}/etc/passwd"
    : > "${r}/var/lib/keys-provision/users.created"
    echo "${3:-ungoverned}" > "${r}/var/lib/keys-provision/keys-users.created"
}

# render_extra ROOT [SCRIPT] — the Studio's extra-accounts first-boot script
# (scripts/desktop-config/02-extra-local-users.start), absolute paths moved under ROOT,
# at ROOT/extra. It runs in the SAME boot as 01, right after it (local.d order).
render_extra() {
    local r="$1" src="${2:-${EXTRA_SRC}}"
    sed -e "s|/etc/hugmesh/|${r}/etc/hugmesh/|g" \
        -e "s|/var/lib/keys-provision|${r}/var/lib/keys-provision|g" \
        -e "s|/etc/sudoers|${r}/etc/sudoers|g" \
        -e "s|/dev/console|${r}/console|g" "${src}" > "${r}/extra"
    chmod +x "${r}/extra"
}

run_extra() { local r="$1"; ( cd "${r}" && PATH="${r}/bin:${PATH}" sh "${r}/extra" ) > "${r}/extra.out" 2>&1; }

# can_sudo ROOT USER -> y|n: the EFFECTIVE sudo path, not the useradd arguments: an
# active sudoers.d line for USER, or membership of wheel WITH an active %wheel line.
can_sudo() {
    local r="$1" u="$2" f
    for f in "${r}"/etc/sudoers.d/*; do
        [ -f "${f}" ] && grep -qE "^${u}[[:space:]]+ALL=\(ALL\) ALL" "${f}" && { echo y; return; }
    done
    if grep -qE '(^|[:,])wheel(,|$)' "${r}/groups.${u}" 2>/dev/null \
       && grep -qE '^%wheel[[:space:]]+ALL=\(ALL\) ALL' "${r}/etc/sudoers" 2>/dev/null; then
        echo y; return
    fi
    echo n
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = probe ]; then
    set -u
    TMPL="${TMPL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/specs/etc/local.d/01-firstboot.start.tmpl}"
    PR="$(mktemp -d)"
    trap 'rm -rf "${PR}"' EXIT
    make_root "${PR}"
    [ "${4:-false}" = true ] && keys_provisioned "${PR}"
    render "${PR}" "${3:-}" "${2:-false}" "${5:-false}"
    run_fb "${PR}"
    if [ -n "${3:-}" ] && [ "$(cat "${PR}/shadow.hash" 2>/dev/null)" = "magus:${3}" ]; then h=applied; else h=absent; fi
    w=n; grep -q 'wheel' "${PR}/groups.magus" 2>/dev/null && w=y
    sd=n; [ -n "$(ls -A "${PR}/etc/sudoers.d" 2>/dev/null)" ] && sd=y
    rl=n; grep -q '^passwd -l root' "${PR}/log" && rl=y
    kb=n; grep -q 'KEYLESS BOOT' "${PR}/out" && kb=y
    rd=n; [ -e "${PR}/shadow.plain" ] && rd=y
    echo "hash=${h} wheel=${w} sudoers_d=${sd} root_locked=${rl} keyless_banner=${kb} random=${rd}"
fi
