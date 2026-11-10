#!/usr/bin/env bash
# save_test.sh — HERMETIC tests for run-qemu-docker.sh's device-save logic.
# Boots nothing, starts no container, talks to no QEMU: the functions under test are
# extracted from the runner and driven with recording stubs.
#
#   bash tests/qemu/save_test.sh
#
# WHY THIS FILE EXISTS. The save path shipped as ~650 lines of shell with no test of
# any kind, and review found three defects in it that only showed up when someone
# ran the thing by hand:
#
#   * a SIGTERM mid-save left the operator's guest PAUSED indefinitely, the copy
#     root-owned, and --list-saves offering the unverified file as a good save;
#   * the failure path fired `block-job-cancel` and `blockdev-del` back to back, but
#     the cancel is ASYNCHRONOUS, so the delete met a busy node, failed silently, and
#     the NEXT save died on "Duplicate nodes" — self-healing only on the third try;
#   * --overwrite and --list-saves disagreed about which file was "the existing
#     copy", so a save made with --save-to <name> was listed but never overwritable,
#     and device x/y could claim x/y-z's saves.
#
# All three are fixed. Each test below fails if its fix is reverted — that is the
# whole point of the file, and mutation was used to confirm it rather than assumed.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${HERE}/run-qemu-docker.sh"
[ -f "${RUNNER}" ] || { echo "cannot find ${RUNNER}" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq() { # eq GOT WANT NAME
    if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── newest_save_for: which file --overwrite replaces ────────────────────────────
echo "newest_save_for — the file --overwrite replaces"
SAVES_DIR="${TMP}/saves"; mkdir -p "${SAVES_DIR}"
sed -n '/^newest_save_for() {/,/^}/p' "${RUNNER}" > "${TMP}/nsf.sh"
grep -q '^newest_save_for() {' "${TMP}/nsf.sh" \
    || { echo "could not extract newest_save_for" >&2; exit 2; }
# shellcheck disable=SC1090
source "${TMP}/nsf.sh"

mk() { # mk FILENAME LABEL_OR_EMPTY AGE_SECONDS
    local f="${SAVES_DIR}/$1"
    : > "${f}"
    [ -n "$2" ] && printf '{"label": "%s"}\n' "$2" > "${f}.json"
    touch -d "@$(( $(date +%s) - $3 ))" "${f}"
}

# A --save-to custom name belongs to the device by its SIDECAR, not by its name.
# Round 1 globbed names only, so this file was listed but could never be overwritten.
mk "rpi5_pki-20260101T000000Z.qcow2" "rpi5/pki" 300
mk "before-upgrade.qcow2"            "rpi5/pki"  60
eq "$(basename "$(newest_save_for rpi5_pki 'rpi5/pki')")" "before-upgrade.qcow2" \
   "picks the newest save the sidecars say is this device's"

# A sibling label must not be swept up by the name glob.
rm -f "${SAVES_DIR:?}"/*
mk "rpi5_pki-20260101T000000Z.qcow2"   "rpi5/pki"   300
mk "rpi5_pki-z-20260102T000000Z.qcow2" "rpi5/pki-z"  60
eq "$(basename "$(newest_save_for rpi5_pki 'rpi5/pki')")" \
   "rpi5_pki-20260101T000000Z.qcow2" \
   "does not steal a sibling device's newer save"

# Saves written before sidecars existed still resolve, by anchored name.
rm -f "${SAVES_DIR:?}"/*
mk "rpi5_pki-20251201T000000Z.qcow2" "" 300
eq "$(basename "$(newest_save_for rpi5_pki 'rpi5/pki')")" \
   "rpi5_pki-20251201T000000Z.qcow2" "still finds a sidecar-less save by name"

# ...but the name fallback is anchored, so x_y cannot claim x_y-z's.
rm -f "${SAVES_DIR:?}"/*
mk "rpi5_pki-z-20260101T000000Z.qcow2" "" 60
eq "$(newest_save_for rpi5_pki 'rpi5/pki')" "" \
   "the name fallback does not match a sibling label"

rm -f "${SAVES_DIR:?}"/*
eq "$(newest_save_for rpi5_pki 'rpi5/pki')" "" "empty when nothing is saved"

# ── save_on_signal: an interrupted save must put the device back ────────────────
echo
echo "save_on_signal — a SIGTERM mid-save"
LOG="${TMP}/actions.log"; : > "${LOG}"
sed -n '/^    save_on_signal() {/,/^    }$/p' "${RUNNER}" | sed 's/^    //' \
    > "${TMP}/handler.sh"
grep -q '^save_on_signal() {' "${TMP}/handler.sh" \
    || { echo "could not extract save_on_signal" >&2; exit 2; }

# A CHILD bash, not a subshell: `$$` stays the parent's PID inside a subshell, so the
# handler's re-raise would kill this test run instead of the process under test.
cat > "${TMP}/run.sh" <<RUNNER_EOF
set -uo pipefail
LOG="${LOG}"
warn() { echo "WARN: \$*" >> "\${LOG}"; }
info() { echo "INFO: \$*" >> "\${LOG}"; }
id()   { echo "1002"; }
qmp_exec() { echo "qmp:\$4 event=\${6:--}" >> "\${LOG}"; return 0; }
docker()   { echo "docker:rename-partial" >> "\${LOG}"; return 0; }
save_restore_state() { echo "restore:prior=\$3" >> "\${LOG}"; return 0; }
label="rpi5/pki"; name="c1"; csock="/work/q.sock"; prior="running"
target="/w/saves/rpi5_pki.qcow2"; ctarget="/work/saves/rpi5_pki.qcow2"
QMP_TIMEOUT=15; SAVE_JOB="hugmesh-save"; SAVE_NODE="hugmesh-save-tgt"
source "${TMP}/handler.sh"
trap 'save_on_signal TERM' TERM
kill -s TERM \$\$
sleep 5
RUNNER_EOF
# The subshell keeps bash's own "Terminated" job notice off this test's output;
# the child really is killed by the handler's re-raise, which is asserted below.
( bash "${TMP}/run.sh" 2>/dev/null ) 2>/dev/null
rc=$?

has() { if grep -q "$1" "${LOG}"; then _ok "$2"; else _bad "$2"; fi; }
# The cancel must be WAITED for. block-job-cancel returns before the job unwinds, so
# a delete fired straight after it meets a busy node and leaks it into the next save.
has 'qmp:block-job-cancel event=BLOCK_JOB_CANCELLED' "waits for BLOCK_JOB_CANCELLED"
has 'qmp:blockdev-del'                               "detaches the save node"
has 'docker:rename-partial'                          "moves the half-written copy aside"
has 'restore:prior=running'                          "restores the PRIOR run state"
if [ "$(grep -n 'restore:' "${LOG}" | cut -d: -f1)" -gt \
     "$(grep -n 'qmp:blockdev-del' "${LOG}" | cut -d: -f1)" ]; then
    _ok "restores only after the node is detached"
else
    _bad "restores before the node is detached"
fi
if [ "${rc}" -ne 0 ]; then _ok "re-raises rather than exiting 0"
else _bad "swallowed the signal (exit ${rc})"; fi

# ══ BOOT FROM A SAVE (FG5) ══════════════════════════════════════════════════════
# The other half of the save: boot a row again from the qcow2 a mesh save wrote.
# What each block below proves, and the mutation it was checked against:
#   * the launchers put the run overlay over the SAVE with -F qcow2 and never
#     resize it, while the golden argv is untouched (mutation: -F qcow2 -> -F raw);
#   * a raw file, a missing --img, or the run's own overlay path is refused before
#     qemu-img runs (mutation: drop the QFI magic check / the overlay guard);
#   * the runner refuses a save outside --work or without its KEYS siblings, maps
#     it to /work/..., and boots ONLY the saved rows (mutations: drop the under-work
#     case, drop the sibling checks, drop the row filter / the unmatched refusal);
#   * the entrypoint restores the SAVED login key, stick and logins instead of
#     minting fresh ones, and refuses a mesh MAC the saved disk was not bound to.
LDIR="${HERE}"
BIN="${TMP}/bin"; mkdir -p "${BIN}"
for q in qemu-system-x86_64 qemu-system-aarch64; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "${QEMU_ARGV}"\nexit 0\n' > "${BIN}/${q}"
    chmod +x "${BIN}/${q}"
done
# qemu-img: every call appended as ONE line (argv joined by '|'); `create`
# also touches its last argument, like the real one leaves an overlay behind.
cat > "${BIN}/qemu-img" <<'STUB'
#!/bin/sh
line=""; for a in "$@"; do line="${line}${line:+|}${a}"; done
printf '%s\n' "${line}" >> "${QEMU_IMG_LOG}"
if [ "${1:-}" = create ]; then out=""; for a in "$@"; do out="$a"; done; : > "${out}"; fi
exit 0
STUB
chmod +x "${BIN}/qemu-img"
GOLD="${TMP}/golden.img";     head -c 4096 /dev/zero > "${GOLD}"
SAVE="${TMP}/rpi5_pki.qcow2"; { printf 'QFI\373'; head -c 4092 /dev/zero; } > "${SAVE}"
CODE="${TMP}/OVMF_CODE.fd"; echo code > "${CODE}"
VARSF="${TMP}/OVMF_VARS.fd"; echo vars > "${VARSF}"
AKERNEL="${TMP}/Image"; echo kernel > "${AKERNEL}"
PKERNEL="${TMP}/kernel_2712.img"; echo pik > "${PKERNEL}"
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
SAVE_SHA="$(sha_of "${SAVE}")"

L_RC=0; L_IMGLOG=""; L_OUT=""
launch() { # launch NAME LAUNCHER [args...]
    local name launcher rdir
    name="$1"; launcher="$2"; shift 2
    rdir="${TMP}/run-${name}"; rm -rf "${rdir}"
    L_IMGLOG="${TMP}/${name}.qemu-img"; : > "${L_IMGLOG}"
    PATH="${BIN}:${PATH}" QEMU_ARGV="${TMP}/${name}.argv" QEMU_IMG_LOG="${L_IMGLOG}" \
        bash "${LDIR}/${launcher}" --run-dir "${rdir}" --work-dir "${TMP}/nowhere" "$@" \
        > "${TMP}/${name}.out" 2>&1
    L_RC=$?
    L_OUT="$(cat "${TMP}/${name}.out")"
}
X86A=(--ovmf-code "${CODE}" --ovmf-vars "${VARSF}" --accel tcg --cpu max)
ARMA=(--platform frite --board la-frite --kernel "${AKERNEL}")
PIA=(--kernel "${PKERNEL}")

echo
echo "launch-*.sh --img-format qcow2 — the run overlay goes over the SAVE"
for spec in "x86:launch-x86.sh:X86A" "arm:launch-arm.sh:ARMA" "pi:launch-pi.sh:PIA"; do
    IFS=: read -r tag launcher arr <<< "${spec}"
    declare -n extra="${arr}"
    # golden default: untouched (-F raw + resize)
    launch "${tag}-gold" "${launcher}" --img "${GOLD}" "${extra[@]}"
    eq "${L_RC}" "0" "${tag}: golden launch exits 0"
    eq "$(head -1 "${L_IMGLOG}")" "create|-f|qcow2|-b|${GOLD}|-F|raw|${TMP}/run-${tag}-gold/run.qcow2" \
       "${tag}: golden overlay is -F raw over the golden (unchanged)"
    eq "$(sed -n 2p "${L_IMGLOG}" | cut -d'|' -f1)" "resize" "${tag}: golden overlay is still resized"
    # boot from a save
    launch "${tag}-save" "${launcher}" --img "${SAVE}" --img-format qcow2 "${extra[@]}"
    eq "${L_RC}" "0" "${tag}: --img-format qcow2 launch exits 0"
    eq "$(head -1 "${L_IMGLOG}")" "create|-f|qcow2|-b|${SAVE}|-F|qcow2|${TMP}/run-${tag}-save/run.qcow2" \
       "${tag}: overlay is created over the SAVE with -F qcow2"
    eq "$(wc -l < "${L_IMGLOG}" | tr -d ' ')" "1" "${tag}: the save-backed overlay is NOT resized (qemu-img would refuse a shrink)"
    grep -qxF "file=${TMP}/run-${tag}-save/run.qcow2,format=qcow2,if=none,id=hd0" "${TMP}/${tag}-save.argv" \
        && _ok "${tag}: qemu boots the run overlay, not the save" || _bad "${tag}: qemu argv does not boot the run overlay"
    if grep -qF "file=${SAVE}" "${TMP}/${tag}-save.argv"; then _bad "${tag}: the save itself is a qemu drive (it would be written)"; else _ok "${tag}: the save is never a qemu drive"; fi
    # refusals, all before qemu-img
    launch "${tag}-raw" "${launcher}" --img "${GOLD}" --img-format qcow2 "${extra[@]}"
    if [ "${L_RC}" -ne 0 ] && [ ! -s "${L_IMGLOG}" ]; then _ok "${tag}: a raw golden passed as qcow2 is refused before qemu-img"; else _bad "${tag}: raw image accepted as a save (rc=${L_RC})"; fi
    launch "${tag}-nofmt" "${launcher}" --img "${SAVE}" --img-format vmdk "${extra[@]}"
    [ "${L_RC}" -ne 0 ] && _ok "${tag}: unknown --img-format refused" || _bad "${tag}: --img-format vmdk accepted"
    launch "${tag}-noimg" "${launcher}" --img-format qcow2 "${extra[@]}"
    case "${L_OUT}" in *"needs an explicit --img"*) _ok "${tag}: qcow2 without --img refused (autodetect finds goldens only)" ;; *) _bad "${tag}: qcow2 without --img not refused by name (rc=${L_RC})" ;; esac
    mkdir -p "${TMP}/self-${tag}"; cp "${SAVE}" "${TMP}/self-${tag}/run.qcow2"
    PATH="${BIN}:${PATH}" QEMU_ARGV="${TMP}/self.argv" QEMU_IMG_LOG="${TMP}/self.log" \
        bash "${LDIR}/${launcher}" --run-dir "${TMP}/self-${tag}" --work-dir "${TMP}/nowhere" \
        --img "${TMP}/self-${tag}/run.qcow2" --img-format qcow2 "${extra[@]}" > /dev/null 2>&1
    if [ $? -ne 0 ] && [ -s "${TMP}/self-${tag}/run.qcow2" ]; then _ok "${tag}: --img = the run's own overlay is refused (and NOT deleted)"; else _bad "${tag}: the run deleted/overwrote the --img it was told to boot"; fi
    unset -n extra
done
launch "pi-kfi" launch-pi.sh --img "${SAVE}" --img-format qcow2 --kernel-from-img
case "${L_OUT}" in *"--kernel-from-img reads the boot partition of a RAW image"*) _ok "pi: --kernel-from-img with a qcow2 save refused by name" ;; *) _bad "pi: --kernel-from-img + qcow2 not refused (rc=${L_RC})" ;; esac
eq "$(sha_of "${SAVE}")" "${SAVE_SHA}" "the save's bytes are unchanged after every launch above"

echo
echo "run-qemu-docker.sh --boot-save — parse, preflight, and the saved-rows-only rule"
BF="${TMP}/runner-bs.sh"; : > "${BF}"
for fn in boot_save_arg boot_save_preflight boot_save_filter_rows; do
    sed -n "/^${fn}() {/,/^}/p" "${RUNNER}" >> "${BF}"
    grep -q "^${fn}() {" "${BF}" || { echo "could not extract ${fn}" >&2; exit 2; }
done
W="${TMP}/w"; mkdir -p "${W}/saves/mesh-1" "${TMP}/arts"
SD="${W}/saves/mesh-1"
for lb in rpi5_pki rpi5_backend; do
    cp "${SAVE}" "${SD}/${lb}.qcow2"; echo stick > "${SD}/${lb}.keys.img"; echo key > "${SD}/${lb}.id_ed25519"
done
cp "${SAVE}" "${TMP}/outside.qcow2"; echo s > "${TMP}/outside.keys.img"; echo k > "${TMP}/outside.id_ed25519"
cp "${SAVE}" "${SD}/nokeys.qcow2"; echo k > "${SD}/nokeys.id_ed25519"
cp "${SAVE}" "${SD}/nologin.qcow2"; echo s > "${SD}/nologin.keys.img"
cp "${SAVE}" "${TMP}/arts/in-arts.qcow2"
bs_run() { # bs_run ROWS_CSV -- ARGS... ; prints "rc=N" + stdout/err + the CPATH map + ROWS
    local rows_csv="$1"; shift
    ( set -u
      info() { echo "INFO: $*"; }; die() { echo "DIE: $*"; exit 1; }
      MODE="golden"; WORK="${W}"; ARTIFACTS="${TMP}/arts"
      declare -A BOOT_SAVE_FOR=() BOOT_SAVE_CPATH=()
      source "${BF}"
      IFS=, read -r -a ROWS <<< "${rows_csv}"
      for a in "$@"; do boot_save_arg "${a}" 2>&1 || { echo "ARGFAIL"; exit 3; }; done
      boot_save_preflight
      boot_save_filter_rows
      for k in "${!BOOT_SAVE_CPATH[@]}"; do echo "CPATH ${k} ${BOOT_SAVE_CPATH[${k}]}"; done
      printf 'ROW %s\n' "${ROWS[@]}" ) 2>&1
}
R2="0|rpi5|pki|t|a.img,0|rpi5|backend|t|b.img,2|x86|fe|t|c.img"
out="$(bs_run "${R2}" "rpi5/pki=${SD}/rpi5_pki.qcow2" "rpi5/backend=${SD}/rpi5_backend.qcow2")"
case "${out}" in *"CPATH rpi5/pki /work/saves/mesh-1/rpi5_pki.qcow2"*) _ok "a save under --work maps to its /work path for the container" ;; *) _bad "no /work mapping: ${out}" ;; esac
if grep -q '^ROW .*x86|fe' <<< "${out}"; then _bad "an unsaved row (x86/fe) is still booted alongside the saved ones"; else _ok "rows no --boot-save names are dropped (saved rows only)"; fi
[ "$(grep -c '^ROW ' <<< "${out}")" = 2 ] && _ok "both saved rows are kept" || _bad "saved rows lost: ${out}"
out="$(bs_run "${R2}" "x86/be=${SD}/rpi5_pki.qcow2")"
case "${out}" in *"DIE: --boot-save x86/be: no runnable row"*) _ok "a --boot-save label matching no row is refused (no silent golden boot)" ;; *) _bad "unmatched label not refused: ${out}" ;; esac
out="$(bs_run "${R2}" "rpi5/pki=${TMP}/outside.qcow2")"
case "${out}" in *"is not under --work"*) _ok "a save outside --work is refused (the container cannot see it)" ;; *) _bad "outside-work save accepted: ${out}" ;; esac
out="$(bs_run "${R2}" "rpi5/pki=${W}/saves/mesh-1/../../../outside.qcow2")"
case "${out}" in *"is not under --work"*) _ok "a ../ escape out of --work is refused after canonicalisation" ;; *) _bad "../ escape accepted: ${out}" ;; esac
out="$(bs_run "${R2}" "rpi5/pki=${SD}/nokeys.qcow2")"
case "${out}" in *"saved KEYS stick"*"is missing"*) _ok "a save without its KEYS stick is refused" ;; *) _bad "missing .keys.img accepted: ${out}" ;; esac
out="$(bs_run "${R2}" "rpi5/pki=${SD}/nologin.qcow2")"
case "${out}" in *"saved login key"*"is missing"*) _ok "a save without its login key is refused" ;; *) _bad "missing .id_ed25519 accepted: ${out}" ;; esac
out="$(bs_run "${R2}" "rpi5/pki=${SD}/rpi5_pki.keys.img")"
case "${out}" in *"is not a .qcow2"*) _ok "a non-.qcow2 path is refused" ;; *) _bad "non-qcow2 accepted: ${out}" ;; esac
out="$(bs_run "${R2}" "rpi5/pki-no-equals")"
case "${out}" in *"wants LABEL=QCOW2"*ARGFAIL*) _ok "--boot-save without LABEL= is a usage error" ;; *) _bad "malformed --boot-save accepted: ${out}" ;; esac
out="$(bs_run "${R2}" "rpi5/pki=${SD}/rpi5_pki.qcow2" "rpi5/pki=${SD}/rpi5_backend.qcow2")"
case "${out}" in *"names rpi5/pki twice"*) _ok "two disks for one row are refused" ;; *) _bad "duplicate label accepted: ${out}" ;; esac
out="$( ( set -u; info() { :; }; die() { echo "DIE: $*"; exit 1; }; MODE="stage4"; WORK="${W}"; ARTIFACTS=""
          declare -A BOOT_SAVE_FOR=([rpi5/pki]="${SD}/rpi5_pki.qcow2") BOOT_SAVE_CPATH=(); source "${BF}"; boot_save_preflight ) 2>&1)"
case "${out}" in *"golden-mode only"*) _ok "--boot-save with --mode stage4 is refused" ;; *) _bad "stage4 + boot-save accepted: ${out}" ;; esac
out="$( ( set -u; info() { :; }; die() { echo "DIE: $*"; exit 1; }; MODE="golden"; WORK="${W}"; ROWS=("0|rpi5|pki|t|a")
          declare -A BOOT_SAVE_FOR=() BOOT_SAVE_CPATH=(); source "${BF}"; boot_save_preflight; boot_save_filter_rows; printf 'ROW %s\n' "${ROWS[@]}" ) 2>&1)"
eq "${out}" "ROW 0|rpi5|pki|t|a" "without --boot-save the rows are untouched"
grep -q '^\s*boot_save_preflight$' "${RUNNER}" && grep -q '^\s*boot_save_filter_rows$' "${RUNNER}" \
    && _ok "the runner calls the preflight and the row filter" || _bad "boot-save preflight/filter defined but never called"
grep -qF '${BOOT_SAVE_CPATH[${label}]:+--boot-save "${BOOT_SAVE_CPATH[${label}]}"}' "${RUNNER}" \
    && [ "$(grep -cF '${BOOT_SAVE_CPATH[${label}]:+--boot-save' "${RUNNER}")" = 2 ] \
    && _ok "both docker-run sites (test run + keep-alive) forward --boot-save" || _bad "a docker-run site does not forward --boot-save"

echo
echo "docker-entrypoint.sh --boot-save — restore the SAVED identity, never mint one"
ENTRY="${HERE}/docker-entrypoint.sh"
EF="${TMP}/entry-bs.sh"; : > "${EF}"
for fn in boot_save_siblings boot_save_check boot_save_restore; do
    sed -n "/^${fn}() {/,/^}/p" "${ENTRY}" >> "${EF}"
    grep -q "^${fn}() {" "${EF}" || { echo "could not extract ${fn}" >&2; exit 2; }
done
CW="${TMP}/cw"; mkdir -p "${CW}/saves/mesh-1/rpi5_pki.keys/network" "${CW}/runs/rpi5_pki"
CS="${CW}/saves/mesh-1"
cp "${SAVE}" "${CS}/rpi5_pki.qcow2"; echo STICK > "${CS}/rpi5_pki.keys.img"
printf 'SAVED-PRIVATE-KEY\n' > "${CS}/rpi5_pki.id_ed25519"; printf 'ssh-ed25519 AAAA saved\n' > "${CS}/rpi5_pki.id_ed25519.pub"
cat > "${CS}/rpi5_pki.keys/users.json" <<'JSON'
{"users": [{"name": "tester"}, {"name": "alice"}], "root": {}}
JSON
printf '[connection]\nid=mesh0\n[802-3-ethernet]\nmac-address=52:54:00:AA:BB:01\n' > "${CS}/rpi5_pki.keys/network/mesh0.nmconnection"
er() { # er MESH_NET MESH_MAC BOOT_SAVE [EXTRA_USER] -> prints the restored state
    ( set -u
      die() { echo "DIE: $*"; exit 1; }; step() { :; }; info() { :; }; warn() { echo "WARN: $*"; }
      MODE="golden"; WORK="${CW}"; RUN_DIR="${CW}/runs/rpi5_pki"
      MESH_NET="$1"; MESH_MAC="$2"; BOOT_SAVE="$3"; SSH_USER="tester"
      EXTRA_USERS=(); [ -z "${4:-}" ] || EXTRA_USERS=("$4"); GUEST_USERS=("${SSH_USER}" "${EXTRA_USERS[@]}")
      source "${EF}"
      boot_save_check
      boot_save_restore
      echo "SSHKEY=$(cat "${SSHKEY}") MODE=$(stat -c %a "${SSHKEY}") PUB=$(cat "${SSHKEY}.pub")"
      echo "KEYS_IMG=$(cat "${KEYS_IMG}") USERS=${GUEST_USERS[*]} SSH_USER=${SSH_USER}"
      [ -f "${RUN_DIR}/keys/users.json" ] && echo "PAYLOAD=copied" ) 2>&1
}
out="$(er "" "" "${CS}/rpi5_pki.qcow2")"
case "${out}" in *"SSHKEY=SAVED-PRIVATE-KEY MODE=600 PUB=ssh-ed25519 AAAA saved"*) _ok "the SAVED login key (0600) is the run's key — no fresh ssh-keygen" ;; *) _bad "login key not restored from the save: ${out}" ;; esac
case "${out}" in *"KEYS_IMG=STICK "*) _ok "the SAVED KEYS stick is the one attached" ;; *) _bad "KEYS stick not restored: ${out}" ;; esac
case "${out}" in *"USERS=tester alice SSH_USER=tester"*) _ok "the record's logins are the SAVED users.json's" ;; *) _bad "logins not taken from the save: ${out}" ;; esac
case "${out}" in *"PAYLOAD=copied"*) _ok "the KEYS payload dir is carried into the run dir (a re-save keeps it)" ;; *) _bad "payload dir not copied: ${out}" ;; esac
out="$(er "" "" "${CS}/rpi5_pki.qcow2" bob)"
case "${out}" in *"WARN: --extra-user bob: not on the SAVED disk"*) _ok "an --extra-user the save never had is named, not claimed" ;; *) _bad "phantom --extra-user not warned: ${out}" ;; esac
case "${out}" in *"USERS=tester alice "*) _ok "...and it is not listed as a login" ;; *) _bad "phantom user listed: ${out}" ;; esac
out="$(er "mcast=230.0.0.1:1234" "52:54:00:aa:bb:01" "${CS}/rpi5_pki.qcow2")"
case "${out}" in *DIE*) _bad "the saved mesh MAC (different case) was refused: ${out}" ;; *) _ok "the saved disk's own mesh MAC is accepted (case-insensitive)" ;; esac
out="$(er "mcast=230.0.0.1:1234" "52:54:00:aa:bb:02" "${CS}/rpi5_pki.qcow2")"
case "${out}" in *"DIE: --boot-save: the saved disk's mesh profile is bound to MAC 52:54:00:aa:bb:01"*) _ok "a mesh NIC MAC the saved disk was not bound to is refused" ;; *) _bad "mesh MAC mismatch booted: ${out}" ;; esac
out="$(er "" "" "${CW}/runs/elsewhere.qcow2")"
case "${out}" in *"DIE: --boot-save ${CW}/runs/elsewhere.qcow2: no such file"*) _ok "a missing save is refused" ;; *) _bad "missing save not refused: ${out}" ;; esac
out="$(er "" "" "/tmp/rpi5_pki.qcow2")"
case "${out}" in *"must be a .qcow2 under ${CW}"*) _ok "a save outside /work is refused in the container too" ;; *) _bad "outside-/work save accepted by the entrypoint: ${out}" ;; esac
rm -f "${CS}/rpi5_pki.keys.img"
out="$(er "" "" "${CS}/rpi5_pki.qcow2")"
case "${out}" in *"saved KEYS stick"*"is missing"*) _ok "the entrypoint refuses a save with no KEYS stick" ;; *) _bad "no-stick save accepted: ${out}" ;; esac
# Wiring: the golden payload (ssh-keygen + make-test-keys) is skipped on a boot-from-save,
# and the launcher is handed the save as qcow2.
gk="$(grep -n 'ssh-keygen -t ed25519' "${ENTRY}" | head -1 | cut -d: -f1)"
ifl="$(grep -n '^if \[ -n "${BOOT_SAVE}" \]; then$' "${ENTRY}" | head -1 | cut -d: -f1)"
fil="$(grep -n '^fi   # golden payload vs boot_save_restore$' "${ENTRY}" | head -1 | cut -d: -f1)"
mk="$(grep -n 'make-test-keys.sh" "${KEYS_SRC}"' "${ENTRY}" | head -1 | cut -d: -f1)"
if [ -n "${ifl}" ] && [ -n "${fil}" ] && [ "${ifl}" -lt "${gk}" ] && [ "${mk}" -lt "${fil}" ]; then
    _ok "ssh-keygen and make-test-keys sit inside the golden-only branch"
else _bad "the fresh-identity payload is not gated off a boot-from-save (if=${ifl} keygen=${gk} mkkeys=${mk} fi=${fil})"; fi
grep -qF 'LAUNCH_DISK=(--img "${BOOT_SAVE}" --img-format qcow2)' "${ENTRY}" \
    && [ "$(grep -cF '"${LAUNCH_DISK[@]}"' "${ENTRY}")" = 3 ] \
    && _ok "all three launcher calls take the save as --img-format qcow2" || _bad "a launcher call still boots the golden on a boot-from-save"

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
