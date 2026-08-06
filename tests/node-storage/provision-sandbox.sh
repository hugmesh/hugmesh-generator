#!/usr/bin/env bash
# provision-sandbox.sh — SOURCED harness: run the REAL specs/etc/keys-provision/
# provision.sh end-to-end against a throwaway fake root, unprivileged, no disks,
# no cluster, no docker.
#
# WHY THIS EXISTS. Two node-storage defects that shipped to main were invisible to
# every gate in the tree because every gate was a grep:
#
#   * the enable half (provision_node_storage: rc-update the boot oneshot + place the
#     staged cron into /etc/cron.d) was only ever asserted as "these strings appear in
#     provision.sh". Strings appear in dead branches too.
#   * `provision.sh --pool` — the command the reconcile agent literally runs — entered
#     main(), found no KEYS media, and returned 0 before ANY pool work. Every string a
#     grep could look for was present and correct.
#
# Both are EFFECTS, so the harness produces effects: it stages a rewritten copy of the
# real script whose absolute paths point into a sandbox root, runs it under a CLOSED
# PATH of stubs, and lets the caller assert on what appeared in the fake root.
#
# THE TWO REWRITES, AND WHY THEY DO NOT WEAKEN THE TEST (both are counted, and the
# staging function fails if a count is 0 — a refactor that changes the shape must come
# back here rather than silently turn the test vacuous):
#
#   1. absolute path prefixes (/etc /var /usr /run /opt /srv) -> ${SB}/...  An
#      unprivileged process cannot write /etc/cron.d; this is the ordinary fake-root
#      relocation, and it is exactly what makes the effects observable.
#   2. `[ -b "$x" ]` -> `[ -e "$x" ]` (2 sites, both in provision_storage).  A test that
#      is not root cannot mknod a block device. The guard's MEANING — "the resolved
#      device must exist, otherwise skip it fail-closed" — is preserved: a manifest
#      naming a device that is not there still takes the skip branch (asserted).
#
# Everything else — the control flow, the branch conditions, the jq programs, the fstab
# and crypttab writes, main()'s dispatch — is the shipped code, byte for byte.
#
# PATH IS CLOSED, NOT AUGMENTED. ${SB}/bin is the ENTIRE PATH: a small allowlist of
# symlinked coreutils plus the stubs below. Any other command is simply absent, which
# is both safe (no privileged binary can be reached) and honest (provision.sh's own
# `have()` is `command -v`, so an absent tool takes the same branch it would take on a
# node that does not ship it). Nothing here can touch a real disk, mount, or cluster.

# ── ps_stage <sandbox-dir> <provision.sh source path> ───────────────────────────
# Builds the sandbox root, the stub PATH, and ${sandbox}/provision.sh (the rewritten
# copy). Returns non-zero if either rewrite matched nothing.
ps_stage() {
    local sb="$1" src="$2"
    [ -r "${src}" ] || { echo "ps_stage: cannot read ${src}" >&2; return 1; }
    rm -rf "${sb}"
    mkdir -p "${sb}"/{bin,etc/init.d,etc/cron.d,etc/hugmesh/registry,usr/sbin,usr/lib/hugmesh} \
             "${sb}"/{var/lib/keys-provision,var/log,var/lib/hugmesh/node-storage,run/keys,dev,mnt,log} \
        || return 1
    : > "${sb}/etc/fstab"
    : > "${sb}/etc/crypttab"

    SB="${sb}" python3 - "${src}" "${sb}/provision.sh" <<'PY' || return 1
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
sb = os.environ["SB"]
txt = open(src, encoding="utf-8").read()

# (1) absolute path prefixes -> the fake root. Not preceded by a word char, '$', '}'
# or '/', so "${BASE}/etc/x", "https://h/etc" and "//etc" are untouched, while the
# shapes that matter — "/etc/cron.d/x", "${KEYS_MOUNT:-/run/keys}", bare
# `[ -x /usr/sbin/… ]`, and resolve_storage_dev's `/dev/*)` case arm — are relocated.
# The kernel's own device nodes are EXCLUDED: relocating /dev/null would turn every
# `2>/dev/null` into a file write inside the sandbox.
KERNEL_NODES = ("null", "zero", "full", "random", "urandom", "tty", "console",
                "stdin", "stdout", "stderr", "fd", "ptmx", "shm", "log")
path_re = re.compile(
    r"(?<![\w$}/])/(etc|var|usr|run|opt|srv)/"
    r"|(?<![\w$}/])/dev/(?!(?:" + "|".join(KERNEL_NODES) + r")(?![\w.-]))")
def _reloc(m):
    return sb + m.group(0)
txt, n_paths = path_re.subn(_reloc, txt)

# (2) block-device existence guards -> plain existence (see the header).
blk_re = re.compile(r"\[ -b ")
txt, n_blk = blk_re.subn("[ -e ", txt)

if n_paths == 0 or n_blk == 0:
    print(f"ps_stage: rewrite matched nothing (paths={n_paths} blockdev={n_blk}) — "
          "provision.sh changed shape; fix the harness rather than the count",
          file=sys.stderr)
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(txt)
print(f"ps_stage: rewrote {n_paths} absolute paths, {n_blk} block-device guards",
      file=sys.stderr)
PY

    ps_make_stubs "${sb}" || return 1
    return 0
}

# ── ps_make_stubs <sandbox-dir> ────────────────────────────────────────────────
# The CLOSED PATH: allowlisted real tools + recording stubs.
ps_make_stubs() {
    local sb="$1" bindir="${sb}/bin" t p
    mkdir -p "${bindir}" || return 1
    # Real tools provision.sh legitimately needs to do its file work.
    for t in bash sh env jq python3 grep egrep sed awk gawk cat cp mv rm mkdir rmdir \
             chmod chown ln ls find sort head tail tr wc cut date tee id stat touch \
             mktemp dirname basename readlink realpath uname install printf true false \
             openssl base64 xxd od comm uniq; do
        # `type -P` (PATH search only), NOT `command -v`: on a developer shell grep/find
        # are often shell functions or aliases, and `command -v` then answers with the
        # bare name — which would make `ln -sf grep ${bindir}/grep` a symlink to itself
        # and silently remove grep from the sandbox PATH.
        p="$(type -P "${t}" 2>/dev/null)" || continue
        case "${p}" in /*) ln -sf "${p}" "${bindir}/${t}" ;; esac
    done
    for t in bash jq python3 grep sed awk cat cp mv rm mkdir chmod date tee install sort; do
        [ -x "${bindir}/${t}" ] || { echo "ps_make_stubs: required tool missing: ${t}" >&2; return 1; }
    done

    # Recording stubs: every one appends its argv to ${sb}/log/<name>.log so a test can
    # assert the call HAPPENED, and none of them touches anything real.
    for t in rc-update rc-service mount kubectl parted wipefs partprobe modprobe \
             sysctl hostname logger sync swapoff mkfs.ext4 mkfs.xfs mkfs.btrfs; do
        cat > "${bindir}/${t}" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${sb}/log/${t}.log"
exit 0
STUB
        chmod +x "${bindir}/${t}"
    done

    # blkid: deterministic per-device fake UUIDs so the fstab dedup never cross-matches.
    cat > "${bindir}/blkid" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${sb}/log/blkid.log"
last="\${@: -1}"
case " \$* " in
    *" -s UUID -o value "*) printf 'UUID-%s\n' "\$(printf '%s' "\${last}" | tr -dc 'a-z0-9')" ;;
    *) exit 1 ;;    # no KEYS-labelled media in the sandbox
esac
STUB
    chmod +x "${bindir}/blkid"

    # cryptsetup: isLuks says "not LUKS yet" so the format path runs; everything else ok.
    cat > "${bindir}/cryptsetup" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${sb}/log/cryptsetup.log"
case "\$1" in isLuks) exit 1 ;; *) exit 0 ;; esac
STUB
    chmod +x "${bindir}/cryptsetup"

    # lsblk / findmnt: an empty machine (no disks, nothing mounted).
    for t in lsblk findmnt; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "${bindir}/${t}"; chmod +x "${bindir}/${t}"
    done
    # sleep: the sandbox never waits for hardware to settle.
    printf '#!/usr/bin/env bash\nexit 0\n' > "${bindir}/sleep"; chmod +x "${bindir}/sleep"
    return 0
}

# ── ps_run <sandbox-dir> [args…] ───────────────────────────────────────────────
# Runs the staged provision.sh with the CLOSED PATH. Extra environment goes through
# the caller's env (e.g. `KEYS_PREMOUNTED=1 ps_run "${SB}"`).
ps_run() {
    local sb="$1"; shift
    ( PATH="${sb}/bin"; export PATH; bash "${sb}/provision.sh" "$@" ) \
        > "${sb}/log/run.out" 2>&1
    return $?
}

# ps_log <sandbox> <stub name> — the recorded argv lines for a stub (empty if never run)
ps_log() { cat "${1}/log/${2}.log" 2>/dev/null; }
