#!/usr/bin/env bash
# display_door_test.sh — HERMETIC guard for the emulated-desktop display door
# (docker-entrypoint.sh --display, run-qemu-docker.sh --display/--open-display).
# Boots nothing, starts no container, needs no viewer: the functions under test
# are sed-extracted from the two scripts and driven with fakes on PATH.
#
#   bash tests/qemu/display_door_test.sh
#
# WHAT IT PINS, and why each is a guard rather than a smoke test:
#   1. THE HOST SIDE BINDS 127.0.0.1 ONLY. The `docker run` the runner builds
#      publishes the door as `-p 127.0.0.1:<ssh+100>:5930` and nothing else —
#      an emulated desktop is never reachable off this workstation. Checked by
#      EXECUTING start_device_row against a fake docker that records its argv,
#      not by reading the source.
#   2. THE DOOR REQUIRES THE PER-RUN SECRET. The launcher flags always carry
#      --display-secret FILE; the file is 0600, 48 hex, fresh per call; no qemu
#      `password=` spelling exists anywhere in the entrypoint.
#   3. THE SECRET IS NEVER LOGGED. The device record, the announce line, the
#      --open-display output and the viewer's argv all carry the file's PATH and
#      never its contents (a sentinel value is planted and grepped for).
#   4. THE FLAGS ARE WIRED: auto => spice only for a keep-alive desktop row, each
#      launcher call takes DISPLAY_ARGS, non-Pi ARM gets --virt-dtb, the derived
#      port claims are made with the ssh claim and released with it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${HERE}/run-qemu-docker.sh"
ENTRYPOINT="${HERE}/docker-entrypoint.sh"
[ -f "${RUNNER}" ] || { echo "cannot find ${RUNNER}" >&2; exit 2; }
[ -f "${ENTRYPOINT}" ] || { echo "cannot find ${ENTRYPOINT}" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required (the runner's record reader uses it)" >&2; exit 2; }

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq()   { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }
# has HAYSTACK NEEDLE MSG / lacks HAYSTACK NEEDLE MSG — fixed-string, no pipe.
has()   { case "$1" in *"$2"*) _ok "$3" ;; *) _bad "$3 (missing: $2)" ;; esac; }
lacks() { case "$1" in *"$2"*) _bad "$3 (found: $2)" ;; *) _ok "$3" ;; esac; }

TMP="$(mktemp -d)"; trap 'cleanup' EXIT
cleanup() {
    [ -n "${LPID:-}" ] && kill "${LPID}" 2>/dev/null
    rm -rf "${TMP}"
}

extract() { # extract FILE FUNCNAME OUT
    sed -n "/^$2() {/,/^}/p" "$1" >> "$3"
    grep -q "^$2() {" "$3" || { echo "could not extract $2 from $1" >&2; exit 2; }
}
# write_device_record's JSON heredoc closes with a '}' at column 0, so the plain
# range above would truncate it; same awk as verdict_test.sh.
extract_record_fn() { # FILE OUT
    awk '
        $0 == "write_device_record() {" { infn = 1 }
        infn { print; if ($0 == "}" && prev == "    return 0") exit; prev = $0 }
    ' "$1" >> "$2"
    grep -q '^write_device_record() {' "$2" && grep -q '^}$' "$2" \
        || { echo "could not extract write_device_record from $1" >&2; exit 2; }
}

# A value that must never appear anywhere but inside the secret file itself.
SENTINEL="deadbeefcafef00d0123456789abcdef0123456789abcdef"

# ══ 1. entrypoint: when is a door wanted ════════════════════════════════════
echo "docker-entrypoint.sh — display_wanted reads KEEP_ALIVE + the kubernetes.role classification"
EF="${TMP}/entry-fns.sh"; : > "${EF}"
for fn in display_wanted launcher_supports_display make_display_secret \
          display_launcher_args display_announce host_path json_str; do
    extract "${ENTRYPOINT}" "${fn}" "${EF}"
done
extract_record_fn "${ENTRYPOINT}" "${EF}"
# shellcheck disable=SC1090
source "${EF}"
info() { echo "$*"; }
warn() { echo "WARN: $*" >&2; }

wanted() { ( DISPLAY_MODE="$1"; KEEP_ALIVE="$2"; K8S_ROLE="$3"; display_wanted ) && echo yes || echo no; }
eq "$(wanted auto true none)"    yes "auto + keep-alive + desktop (role none)  => door"
eq "$(wanted auto false none)"   no  "auto + a TEST run (no keep-alive)          => no door"
eq "$(wanted auto true worker)"  no  "auto + keep-alive + a worker role          => no door"
eq "$(wanted auto true control-plane)" no "auto + keep-alive + control-plane     => no door"
eq "$(wanted none true none)"    no  "none + keep-alive + desktop                => no door"
eq "$(wanted spice false worker)" yes "spice is unconditional"
eq "$(wanted bogus true none)"   no  "an unknown mode is no door, not a door"

echo
echo "launcher_supports_display — a launcher without the flags must not be handed them"
printf '#!/bin/bash\ncase "$1" in\n  --display-secret) ;;\n  --display-listen) ;;\n  *) usage 1 ;;\nesac\n' > "${TMP}/launch-ok.sh"
printf '#!/bin/bash\ncase "$1" in\n  --qmp) ;;\n  *) echo "Unknown arg: $1"; usage 1 ;;\nesac\n' > "${TMP}/launch-old.sh"
printf '#!/bin/bash\n# --display-secret is mentioned only in prose here\ncase "$1" in\n  --display-secret) ;;\nesac\n' > "${TMP}/launch-half.sh"
launcher_supports_display "${TMP}/launch-ok.sh"  && _ok "a launcher with both flags is detected" || _bad "launcher with both flags NOT detected"
launcher_supports_display "${TMP}/launch-old.sh" && _bad "a launcher WITHOUT the flags was reported as supporting them" || _ok "a launcher without the flags is refused"
launcher_supports_display "${TMP}/launch-half.sh" && _bad "a launcher with only --display-secret was accepted" || _ok "both flags are required, not one"
launcher_supports_display "${TMP}/no-such-file" && _bad "a missing launcher was accepted" || _ok "a missing launcher file is refused"

# ══ 2. entrypoint: the secret ═══════════════════════════════════════════════
echo
echo "make_display_secret — fresh, 0600, 48 hex, silent"
S1="${TMP}/run/launch/display.secret"; mkdir -p "$(dirname "${S1}")"
umask 022   # the function must NOT depend on the caller's umask
out="$(make_display_secret "${S1}" 2>&1)"; rc=$?
eq "${rc}" 0 "make_display_secret returns 0"
eq "${out}" "" "make_display_secret prints NOTHING (the value never reaches stdout/stderr)"
mode="$(stat -c %a "${S1}" 2>/dev/null || stat -f %Lp "${S1}")"
eq "${mode}" 600 "the secret file is 0600 under a permissive umask"
v1="$(cat "${S1}")"
[[ "${v1}" =~ ^[0-9a-f]{48}$ ]] && _ok "48 lowercase hex chars (under SPICE's 60, no base64 '+')" || _bad "secret is not 48 hex: '${v1}'"
# A re-run of the same row reuses the run dir: the file must be replaced, and a
# wider mode left by an older run must not survive.
chmod 644 "${S1}"
make_display_secret "${S1}" >/dev/null 2>&1
v2="$(cat "${S1}")"
[ "${v1}" != "${v2}" ] && _ok "a second call mints a DIFFERENT secret" || _bad "two calls produced the same secret"
eq "$(stat -c %a "${S1}" 2>/dev/null || stat -f %Lp "${S1}")" 600 "a pre-existing 0644 file comes back 0600"

# ══ 3. entrypoint: the launcher flags ═══════════════════════════════════════
echo
echo "display_launcher_args — the secret goes by FILE, the listen address is the container's, --virt-dtb only off-Pi ARM"
args_for() { ( PLATFORM="$1"; VNC_SOCK="${2:-}"; DISPLAY_SECRET="/work/runs/x/launch/display.secret"
               DISPLAY_LISTEN="0.0.0.0"; DISPLAY_SPICE_PORT=5930; DISPLAY_ARGS=()
               display_launcher_args; printf '%s\n' "${DISPLAY_ARGS[@]}" ); }
x86="$(args_for x86)"
has "${x86}" $'--display\nspice' "x86: --display spice"
has "${x86}" $'--display-listen\n0.0.0.0' "x86: --display-listen is the container namespace (the HOST side is the runner's -p 127.0.0.1)"
has "${x86}" $'--spice-port\n5930' "x86: --spice-port 5930"
has "${x86}" $'--display-secret\n/work/runs/x/launch/display.secret' "x86: the password travels as --display-secret FILE"
lacks "${x86}" "--virt-dtb" "x86: no --virt-dtb"
lacks "${x86}" "--vnc-socket" "x86: no --vnc-socket unless the web fallback was armed"
lacks "${x86}" "password=" "x86: no qemu password= spelling in the flags"
pi="$(args_for rpi5)"
lacks "${pi}" "--virt-dtb" "rpi5: no --virt-dtb (the Pi launcher is not the virt machine)"
frite="$(args_for frite)"
has "${frite}" "--virt-dtb" "frite (non-Pi ARM): --virt-dtb so qemu generates the virt DTB that can describe the virtio-gpu"
opi="$(args_for orangepi5 /work/runs/x/launch/vnc.sock)"
has "${opi}" $'--vnc-socket\n/work/runs/x/launch/vnc.sock' "web fallback armed: --vnc-socket PATH is added"

# The three launcher calls in the entrypoint must all take the array, and the
# entrypoint must never spell a qemu password inline.
calls="$(grep -c '"${DISPLAY_ARGS\[@\]}" 2>&1 | tee "${RUN_DIR}/launch.log"' "${ENTRYPOINT}")"
eq "${calls}" 3 "all three launcher invocations (pi, x86, arm) carry DISPLAY_ARGS"
inline_pw="$(grep -v '^[[:space:]]*#' "${ENTRYPOINT}" | grep -c 'password=')"
eq "${inline_pw}" 0 "no non-comment 'password=' anywhere in the entrypoint (argv/launch.log would show it)"

# ══ 4. entrypoint: the record and the announce line ═════════════════════════
echo
echo "write_device_record — display_* fields name the password file's HOST path and never its value"
printf '%s' "${SENTINEL}" > "${TMP}/run/launch/display.secret"
(
    set -uo pipefail
    WORK="/work"; HOST_WORK="/home/op/qemu-runs"
    ARTIFACTS="/artifacts"; HOST_ARTIFACTS="/home/op/sessions/s1"
    DEVICES_DIR="${TMP}/devices"; DEVICE_JSON="${DEVICES_DIR}/x86_desktop.json"
    LABEL="x86/desktop"; PLATFORM="x86"; ROLE="desktop"; BOARD=""
    CONTAINER_NAME="hugmesh-qemu-dev-x86_desktop"; SSH_HOST_PORT=22307
    SSH_USER="tester"; GUEST_USERS=(tester)
    SSHKEY="/work/runs/x86_desktop/id_ed25519"; QMP_SOCK="/work/runs/x86_desktop/launch/qmp.sock"
    IMG="/work/images/hugmesh-x86-amd64-desktop-test-20261104T000000Z.img"
    STARTED_AT="2026-11-04T00:00:00Z"; HOST_UID=""
    DISPLAY_PROTOCOL="spice"; DISPLAY_HOST_PORT=22407; DISPLAY_WEB_PORT=0
    DISPLAY_SECRET="/work/runs/x86_desktop/launch/display.secret"; DISPLAY_RESIZE="scale"
    warn() { :; }
    write_device_record booting
) || _bad "write_device_record (display fields) failed outright"
python3 - "${TMP}/devices/x86_desktop.json" "${SENTINEL}" <<'PY' && _ok "record: display_protocol/port/password_file(HOST path)/resize present, value absent" || _bad "record display fields wrong or the secret leaked (see python assertion)"
import json, sys
raw = open(sys.argv[1]).read()
assert sys.argv[2] not in raw, "SECRET VALUE IN THE RECORD"
rec = json.loads(raw)
assert rec["display_protocol"] == "spice", rec
assert rec["display_port"] == 22407 and isinstance(rec["display_port"], int), rec
assert rec["display_web_port"] == 0, rec
assert rec["display_password_file"] == "/home/op/qemu-runs/runs/x86_desktop/launch/display.secret", rec
assert rec["display_resize"] == "scale", rec
assert rec["ssh_host_port"] == 22307, rec
PY
# An older driver (verdict_test.sh's harness, or a caller that never heard of the
# door) sets none of the DISPLAY_* variables: the record must still be JSON.
(
    set -uo pipefail
    WORK="/work"; HOST_WORK=""; ARTIFACTS="/artifacts"; HOST_ARTIFACTS=""
    DEVICES_DIR="${TMP}/devices"; DEVICE_JSON="${DEVICES_DIR}/rpi5_pki.json"
    LABEL="rpi5/pki"; PLATFORM="rpi5"; ROLE="pki"; BOARD=""; CONTAINER_NAME=""; SSH_HOST_PORT=0
    SSH_USER="tester"; GUEST_USERS=(tester); SSHKEY="/work/k"; QMP_SOCK=""; IMG="/work/i.img"
    STARTED_AT="2026-11-04T00:00:00Z"; HOST_UID=""
    warn() { :; }
    write_device_record running
) || _bad "write_device_record with no DISPLAY_* set aborted under set -u"
python3 - "${TMP}/devices/rpi5_pki.json" <<'PY' && _ok "record with no door: display_protocol '', ports 0, resize 'scale' — still valid JSON" || _bad "record without display vars is not tolerant JSON"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["display_protocol"] == "" and rec["display_port"] == 0 and rec["display_web_port"] == 0, rec
assert rec["display_password_file"] == "" and rec["display_resize"] == "scale", rec
PY

echo
echo "display_announce — the path, the port, the open command; never the value"
ann="$( DISPLAY_PROTOCOL=spice DISPLAY_HOST_PORT=22407 DISPLAY_WEB_PORT=22507 DISPLAY_RESIZE=scale \
        DISPLAY_SECRET="${TMP}/run/launch/display.secret" DISPLAY_SPICE_PORT=5930 LABEL="x86/desktop" HOST_WORK="" WORK="/work" HOST_ARTIFACTS="" ARTIFACTS="/artifacts" \
        display_announce 2>&1 )"
has "${ann}" "127.0.0.1:22407" "announce names the loopback door"
has "${ann}" "${TMP}/run/launch/display.secret" "announce names the password FILE"
has "${ann}" "--open-display x86/desktop" "announce names the open command"
has "${ann}" "http://127.0.0.1:22507/vnc.html" "announce names the browser fallback on an IP literal"
lacks "${ann}" "${SENTINEL}" "announce never prints the secret"
lacks "${ann}" "localhost" "announce never says 'localhost' (HSTS pin trap)"
none="$( DISPLAY_PROTOCOL="" DISPLAY_HOST_PORT=0 DISPLAY_WEB_PORT=0 DISPLAY_SECRET="" LABEL=x display_announce 2>&1 )"
eq "${none}" "" "no door => announce prints nothing"

# ══ 5. runner: the derived ports and the docker run ═════════════════════════
echo
echo "run-qemu-docker.sh — display_publish_args: 127.0.0.1 only, the env halves, web only when asked"
RF="${TMP}/runner-fns.sh"; : > "${RF}"
for fn in safe_label docker_published_ports claim_port port_claim_is_stale release_port \
          port_free candidate_ports claim_display_ports display_ports_for \
          release_display_ports display_publish_args release_port_for_record \
          record_field need_python container_is_running start_device_row \
          device_record_path display_viewer_hint cmd_open_display; do
    extract "${RUNNER}" "${fn}" "${RF}"
done
# A fake docker: `ps --format {{.Names}}` lists a stranger plus every container a
# `run --name` created (so a held claim is NOT mistaken for a stale one),
# `ps --format {{.Ports}}` publishes 22301 for someone else, `run` records its
# whole argv and prints an id, `inspect` says running, `rm`/`logs` succeed.
mkdir -p "${TMP}/bin"
: > "${TMP}/running-names"
cat > "${TMP}/bin/docker" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  ps)   if [[ "\${3:-}" == *Ports* ]]; then echo "127.0.0.1:22301->2222/tcp"
        else echo "some-other-container"; cat "${TMP}/running-names"; fi; exit 0 ;;
  info) exit 0 ;;
  run)  printf '%s\\n' "\$@" > "${TMP}/docker-run.argv"
        while [ \$# -gt 0 ]; do [ "\$1" = "--name" ] && echo "\$2" >> "${TMP}/running-names"; shift; done
        echo "0123456789ab"; exit 0 ;;
  inspect) echo true; exit 0 ;;
  rm|logs) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${TMP}/bin/docker"
PATH="${TMP}/bin:${PATH}"
# shellcheck disable=SC1090
source "${RF}"
die()  { echo "ERROR: $*" >&2; exit 1; }
sleep() { :; }   # start_device_row's `sleep 1` after docker run

DEV_PORT_MIN=22300; DEV_PORT_MAX=22399
DISPLAY_PORT_OFFSET=100; WEB_PORT_OFFSET=200; GUEST_SPICE_PORT=5930; GUEST_WEB_PORT=6080
GUEST_SSH_PORT=2222; DEV_NAME_PREFIX="hugmesh-qemu-dev-"
PORTLOCK_DIR="${TMP}/locks"; DEVICES_DIR="${TMP}/devices"; WORK="${TMP}/work"
REPO_DIR="${TMP}/repo"; ARTIFACTS="${TMP}/artifacts"; IMAGE_TAG="fake:latest"
MODE=golden; MEM=2048; SMP=2; TIMEOUT=600; ASSERT_TIMEOUT=""; KVM_ARGS=()
EXTRA_USER_ARGS=(); MESH_NET=""; MESH_NET_NAME=""
declare -A MESH_MAC_FOR=() MESH_IP_FOR=() MESH_PLEN_FOR=()
DEV_PORTS_TAKEN=()

DISPLAY_MODE=auto; DISPLAY_WEB=false
pub="$(display_publish_args 22300)"
has "${pub}" $'-p\n127.0.0.1:22400:5930' "ssh 22300 => the door is -p 127.0.0.1:22400:5930"
has "${pub}" $'-e\nDISPLAY_HOST_PORT=22400' "...and the entrypoint is told the host number"
has "${pub}" $'-e\nDISPLAY_MODE=auto' "...and the mode"
lacks "${pub}" "22500" "no web port unless --display-web"
lacks "${pub}" "0.0.0.0" "no 0.0.0.0 on the host side"
# Every -p the helper emits binds loopback: count -p lines vs -p lines followed by 127.0.0.1:
np="$(printf '%s\n' "${pub}" | grep -c '^-p$')"
nl="$(printf '%s\n' "${pub}" | grep -A1 '^-p$' | grep -c '^127\.0\.0\.1:')"
eq "${nl}" "${np}" "every -p the door publishes starts with 127.0.0.1:"
DISPLAY_WEB=true
pubw="$(display_publish_args 22300)"
has "${pubw}" $'-p\n127.0.0.1:22500:6080' "--display-web: noVNC is -p 127.0.0.1:22500:6080"
has "${pubw}" $'-e\nDISPLAY_WEB_PORT=22500' "...and the entrypoint is told that number too"
has "${pubw}" $'-e\nDISPLAY_WEB=1' "...and that the web fallback is armed"
np="$(printf '%s\n' "${pubw}" | grep -c '^-p$')"
nl="$(printf '%s\n' "${pubw}" | grep -A1 '^-p$' | grep -c '^127\.0\.0\.1:')"
eq "${nl}" "${np}" "with the web port too, every -p starts with 127.0.0.1:"
DISPLAY_WEB=false
DISPLAY_MODE=none
pubn="$(display_publish_args 22300)"
eq "${pubn}" $'-e\nDISPLAY_MODE=none' "--display none publishes nothing and tells the entrypoint so"
DISPLAY_MODE=auto

echo
echo "claim_display_ports — claimed with the ssh port, released as a unit"
rm -rf "${PORTLOCK_DIR}"
claim_display_ports 22300 hugmesh-qemu-dev-a && _ok "22400 claimed for the row on 22300" || _bad "could not claim 22400"
[ -d "${PORTLOCK_DIR}/22400" ] && _ok "the claim is the mkdir lock the ssh ports use" || _bad "no lock dir for 22400"
eq "$(cat "${PORTLOCK_DIR}/22400/owner")" "hugmesh-qemu-dev-a" "the claim names the container"
# A rival already holds 22401's door: the row on 22301 must be refused (and docker
# publishes 22301 for someone else anyway — the helper is about the DERIVED port).
mkdir -p "${PORTLOCK_DIR}/22402"; echo some-other-container > "${PORTLOCK_DIR}/22402/owner"
claim_display_ports 22302 hugmesh-qemu-dev-b && _bad "a door held by a live container was claimed again" || _ok "a door held by another container refuses the row"
# With the web port armed, a LISTENER on <ssh+200> must refuse the row AND give
# back the <ssh+100> claim it had just made (a row is one triple, not a mix).
python3 - "${TMP}/listening" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 22503)); s.listen(1)
open(sys.argv[1], "w").close()
time.sleep(30)
PY
LPID=$!
for _ in $(seq 40); do [ -e "${TMP}/listening" ] && break; command sleep 0.1; done
DISPLAY_WEB=true
claim_display_ports 22303 hugmesh-qemu-dev-c && _bad "a row whose web port is in use was admitted" || _ok "a listener on <ssh+200> refuses the row"
[ -d "${PORTLOCK_DIR}/22403" ] && _bad "the <ssh+100> claim leaked after the <ssh+200> refusal" || _ok "...and the <ssh+100> claim it made is given back"
DISPLAY_WEB=false
release_display_ports 22300 hugmesh-qemu-dev-a
[ -d "${PORTLOCK_DIR}/22400" ] && _bad "release_display_ports left the claim" || _ok "release_display_ports drops the row's door claim"
DISPLAY_MODE=none
claim_display_ports 22300 hugmesh-qemu-dev-a
[ -d "${PORTLOCK_DIR}/22400" ] && _bad "--display none claimed a door port" || _ok "--display none claims nothing"
DISPLAY_MODE=auto

echo
echo "release_port_for_record — a stopped device gives back all three claims, only its own"
mkdir -p "${DEVICES_DIR}"
for p in 22310 22410 22510; do mkdir -p "${PORTLOCK_DIR}/${p}"; echo hugmesh-qemu-dev-x86_desktop > "${PORTLOCK_DIR}/${p}/owner"; done
mkdir -p "${PORTLOCK_DIR}/22411"; echo hugmesh-qemu-dev-other > "${PORTLOCK_DIR}/22411/owner"
cat > "${DEVICES_DIR}/x86_desktop.json" <<EOF
{"label":"x86/desktop","container":"hugmesh-qemu-dev-x86_desktop","ssh_host_port":22310,
 "display_protocol":"spice","display_port":22410,"display_web_port":22510,
 "display_password_file":"${TMP}/run/launch/display.secret","display_resize":"scale","state":"running"}
EOF
release_port_for_record "${DEVICES_DIR}/x86_desktop.json"
for p in 22310 22410 22510; do
    [ -d "${PORTLOCK_DIR}/${p}" ] && _bad "claim ${p} not released with the record" || _ok "claim ${p} released with the record"
done
[ -d "${PORTLOCK_DIR}/22411" ] && _ok "another container's claim is untouched" || _bad "release_port_for_record stole another container's claim"
cat > "${DEVICES_DIR}/old.json" <<'EOF'
{"label":"rpi5/pki","container":"hugmesh-qemu-dev-rpi5_pki","ssh_host_port":22311,"state":"running"}
EOF
mkdir -p "${PORTLOCK_DIR}/22311"; echo hugmesh-qemu-dev-rpi5_pki > "${PORTLOCK_DIR}/22311/owner"
release_port_for_record "${DEVICES_DIR}/old.json" && _ok "a record from before the door (no display_* fields) is still handled" || _bad "release_port_for_record failed on an old record"
[ -d "${PORTLOCK_DIR}/22311" ] && _bad "old record's ssh claim not released" || _ok "...and its ssh claim is released"

echo
echo "start_device_row — EXECUTED: the docker run binds 127.0.0.1 for ssh AND the door"
rm -rf "${PORTLOCK_DIR}" "${TMP}/docker-run.argv"; DEV_PORTS_TAKEN=()
info() { :; }; warn() { echo "WARN: $*" >&2; }
row="$(start_device_row x86 desktop "${ARTIFACTS}/hugmesh-x86-amd64-desktop-test-1.img")"; rc=$?
eq "${rc}" 0 "start_device_row returns 0 against the fake docker"
argv="$(cat "${TMP}/docker-run.argv" 2>/dev/null)"
has "${argv}" $'-p\n127.0.0.1:22300:2222' "ssh published on 127.0.0.1:22300"
has "${argv}" $'-p\n127.0.0.1:22400:5930' "the door published on 127.0.0.1:22400 -> container 5930"
has "${argv}" $'-e\nDISPLAY_HOST_PORT=22400' "DISPLAY_HOST_PORT=22400 handed to the entrypoint"
has "${argv}" $'-e\nDISPLAY_MODE=auto' "DISPLAY_MODE=auto handed to the entrypoint"
has "${argv}" $'-e\nSSH_HOST_PORT=22300' "SSH_HOST_PORT still handed down"
lacks "${argv}" "0.0.0.0" "nothing in the docker run names 0.0.0.0"
lacks "${argv}" "localhost" "nothing in the docker run names 'localhost'"
np="$(printf '%s\n' "${argv}" | grep -c '^-p$')"
nl="$(printf '%s\n' "${argv}" | grep -A1 '^-p$' | grep -c '^127\.0\.0\.1:')"
eq "${np}" 2 "exactly two -p publishes (ssh + door; no web port without --display-web)"
eq "${nl}" "${np}" "every -p in the real docker run binds 127.0.0.1"
[ -d "${PORTLOCK_DIR}/22300" ] && [ -d "${PORTLOCK_DIR}/22400" ] && _ok "both claims (22300, 22400) are held for the container" || _bad "claims missing after a successful start"
has "${row}" "127.0.0.1:22400 (open:" "the start line names the door and how to open it"
has "${row}" "--open-display x86/desktop" "...with the exact label"
# A second row: the first row's ports are DEV_PORTS_TAKEN, and docker already
# publishes 22301 for a stranger, so it must land on 22302/22402.
rm -f "${TMP}/docker-run.argv"
start_device_row x86 standalone-thick "${ARTIFACTS}/hugmesh-x86-amd64-standalone-thick-test-1.img" >/dev/null
argv2="$(cat "${TMP}/docker-run.argv" 2>/dev/null)"
has "${argv2}" $'-p\n127.0.0.1:22302:2222' "second row skips the taken 22300 and docker's 22301"
has "${argv2}" $'-p\n127.0.0.1:22402:5930' "...and its door is derived from ITS ssh port"
# --display none: no door publish, no claim, no env beyond the mode.
rm -rf "${PORTLOCK_DIR}" "${TMP}/docker-run.argv"; DEV_PORTS_TAKEN=(); DISPLAY_MODE=none
start_device_row rpi5 pki "${ARTIFACTS}/hugmesh-rpi5-arm64-pki-test-1.img" >/dev/null
argv3="$(cat "${TMP}/docker-run.argv" 2>/dev/null)"
lacks "${argv3}" "5930" "--display none: no door publish"
has "${argv3}" $'-e\nDISPLAY_MODE=none' "--display none: the entrypoint is told"
[ -d "${PORTLOCK_DIR}/22400" ] && _bad "--display none claimed 22400" || _ok "--display none claims no door port"
DISPLAY_MODE=auto
# A docker run that fails to bind must give back the DOOR claim too (the ssh
# claim already was), or a crashed start burns 22400 until someone deletes WORK.
rm -rf "${PORTLOCK_DIR}" "${TMP}/docker-run.argv"; DEV_PORTS_TAKEN=()
cat > "${TMP}/bin/docker" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  ps)   exit 0 ;;
  info) exit 0 ;;
  run)  echo "docker: Error response from daemon: driver failed programming external connectivity: Bind for 127.0.0.1:22400 failed: port is already allocated" >&2; exit 125 ;;
  *) exit 0 ;;
esac
FAKE
start_device_row x86 desktop "${ARTIFACTS}/img.img" >/dev/null 2>&1
held="$(ls "${PORTLOCK_DIR}" 2>/dev/null | tr '\n' ' ')"
eq "${held}" "" "after 100 bind failures no ssh OR door claim is left behind (got: '${held}')"

# ══ 6. runner: --open-display ═══════════════════════════════════════════════
echo
echo "cmd_open_display — the password goes to a 0600 .vv file or a prompt, never to argv or stdout"
info() { echo "$*"; }
printf '%s' "${SENTINEL}" > "${TMP}/run/launch/display.secret"; chmod 600 "${TMP}/run/launch/display.secret"
cat > "${DEVICES_DIR}/x86_desktop.json" <<EOF
{"label":"x86/desktop","container":"hugmesh-qemu-dev-x86_desktop","ssh_host_port":22310,
 "display_protocol":"spice","display_port":22410,"display_web_port":22510,
 "display_password_file":"${TMP}/run/launch/display.secret","display_resize":"scale","state":"running"}
EOF
# print: endpoint + path only.
out="$( cd "${TMP}" && PATH="${TMP}/bin:/usr/bin:/bin" cmd_open_display x86/desktop print 2>&1 )"; rc=$?
eq "${rc}" 0 "--viewer print succeeds on a running record"
has "${out}" "127.0.0.1:22410" "print names the loopback door"
has "${out}" "${TMP}/run/launch/display.secret" "print names the password FILE"
has "${out}" "http://127.0.0.1:22510/vnc.html" "print names the noVNC URL on an IP literal"
lacks "${out}" "${SENTINEL}" "print never shows the secret"
lacks "${out}" "localhost" "print never says 'localhost'"
# remote-viewer: a fake on PATH records its argv and copies the .vv it was given.
cat > "${TMP}/bin/remote-viewer" <<FAKE
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "${TMP}/rv.argv"
stat -c %a "\$1" > "${TMP}/rv.mode" 2>/dev/null || stat -f %Lp "\$1" > "${TMP}/rv.mode"
cp "\$1" "${TMP}/rv.vv"
exit 0
FAKE
chmod +x "${TMP}/bin/remote-viewer"
export XDG_RUNTIME_DIR="${TMP}/xdg"; mkdir -p "${XDG_RUNTIME_DIR}"
out="$( cmd_open_display x86/desktop remote-viewer 2>&1 )"; rc=$?
eq "${rc}" 0 "--viewer remote-viewer runs the viewer"
rvargv="$(cat "${TMP}/rv.argv" 2>/dev/null)"
lacks "${rvargv}" "${SENTINEL}" "the secret is NOT on remote-viewer's argv"
case "${rvargv}" in "${XDG_RUNTIME_DIR}"/*.vv) _ok "remote-viewer gets a .vv under XDG_RUNTIME_DIR" ;; *) _bad "remote-viewer argv is not a .vv under XDG_RUNTIME_DIR: '${rvargv}'" ;; esac
eq "$(cat "${TMP}/rv.mode" 2>/dev/null)" 600 "the .vv file is 0600"
vv="$(cat "${TMP}/rv.vv" 2>/dev/null)"
has "${vv}" "[virt-viewer]" ".vv: [virt-viewer] section"
has "${vv}" $'type=spice\nhost=127.0.0.1\nport=22410' ".vv: type=spice, host=127.0.0.1, port=22410"
has "${vv}" "password=${SENTINEL}" ".vv: carries the password (that is its job: it is the ONLY place the value goes)"
has "${vv}" "delete-this-file=1" ".vv: delete-this-file=1"
has "${vv}" "title=hugmesh x86/desktop" ".vv: title names the device"
lacks "${out}" "${SENTINEL}" "the remote-viewer path prints nothing of the secret"
[ -z "$(ls "${XDG_RUNTIME_DIR}" 2>/dev/null)" ] && _ok "the .vv is removed after the viewer returns (even if the viewer did not delete it)" || _bad ".vv left behind: $(ls "${XDG_RUNTIME_DIR}")"
# browser: a fake xdg-open records what it was asked to open.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/xdg.argv"\n' "${TMP}" > "${TMP}/bin/xdg-open"
chmod +x "${TMP}/bin/xdg-open"
out="$( cmd_open_display x86/desktop browser 2>&1 )"
command sleep 0.3   # xdg-open is backgrounded
has "${out}" "http://127.0.0.1:22510/vnc.html?host=127.0.0.1&port=22510&resize=scale&autoconnect=1" "browser: the noVNC URL on an IP literal with resize=scale"
eq "$(cat "${TMP}/xdg.argv" 2>/dev/null)" "http://127.0.0.1:22510/vnc.html?host=127.0.0.1&port=22510&resize=scale&autoconnect=1" "browser: xdg-open is handed exactly that URL"
lacks "${out}" "${SENTINEL}" "browser: no password in the URL or the output"
lacks "${out}" "password=" "browser: no password= query parameter"
# Refusals.
cat > "${DEVICES_DIR}/stopped.json" <<EOF
{"label":"x86/stopped","container":"hugmesh-qemu-dev-x86_stopped","display_protocol":"spice","display_port":22412,"display_password_file":"${TMP}/run/launch/display.secret","state":"stopped"}
EOF
( cmd_open_display x86/stopped print >/dev/null 2>&1 ) && _bad "a stopped device opened" || _ok "a stopped device is refused"
cat > "${DEVICES_DIR}/nodoor.json" <<'EOF'
{"label":"rpi5/pki","container":"hugmesh-qemu-dev-rpi5_pki","display_protocol":"","display_port":0,"state":"running"}
EOF
( cmd_open_display rpi5/pki print >/dev/null 2>&1 ) && _bad "a device with no door opened" || _ok "a device with no door is refused, by name"
cat > "${DEVICES_DIR}/nopw.json" <<EOF
{"label":"x86/nopw","container":"hugmesh-qemu-dev-x86_nopw","display_protocol":"spice","display_port":22413,"display_password_file":"${TMP}/missing.secret","state":"running"}
EOF
( cmd_open_display x86/nopw print >/dev/null 2>&1 ) && _bad "an unreadable password file was accepted" || _ok "an unreadable password file is refused"
( cmd_open_display no/such print >/dev/null 2>&1 ) && _bad "a missing record opened" || _ok "a missing record is refused"

# ══ 7. the runner's own wiring, read once ═══════════════════════════════════
echo
echo "run-qemu-docker.sh — wiring"
grep -q 'open-display) cmd_open_display "${DEV_LABEL}" "${DEV_VIEWER}"' "${RUNNER}" \
    && _ok "--open-display is dispatched" || _bad "--open-display not dispatched"
grep -q 'claim_display_ports "${port}" "${name}" || { release_port "${port}" "${name}"; continue; }' "${RUNNER}" \
    && _ok "a door claim failure gives the ssh port back and moves the row on" || _bad "the claim loop does not release the ssh port on a door claim failure"
grep -q '"${display_args\[@\]}" \\' "${RUNNER}" \
    && _ok "the docker run expands the door's -p/-e lines" || _bad "docker run does not take display_args"
# Publish spellings only: a `docker run` continuation line `    -p "...` or the
# helper's `"-p" "...` — not ssh's/spicy's `-p "${port}"` or `mkdir -p`.
host_pub="$(grep -v '^[[:space:]]*#' "${RUNNER}" | grep -cE '^[[:space:]]*-p "127\.0\.0\.1:|"-p" "127\.0\.0\.1:')"
host_any="$(grep -v '^[[:space:]]*#' "${RUNNER}" | grep -cE '^[[:space:]]*-p "|"-p" "')"
eq "${host_pub}" "${host_any}" "every docker -p publish the runner spells binds 127.0.0.1 (${host_any} of them)"
[ "${host_any}" -ge 3 ] && _ok "...and the count is the ssh publish plus the two door publishes (${host_any})" || _bad "expected at least 3 publish spellings, found ${host_any}"

echo
echo "display_door_test.sh: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
