#!/usr/bin/env bash
# actions-kvm-smoke_test.sh — the runner for tests/qemu/features/actions-kvm-smoke.feature.
#
#   bash tests/qemu/actions-kvm-smoke_test.sh --image ISO --sha256 HEX [--out DIR]
#   bash tests/qemu/actions-kvm-smoke_test.sh --image ISO --sha256 HEX --tcg
#   bash tests/qemu/actions-kvm-smoke_test.sh --self-test
#
# WHY A RUNNER OF ITS OWN. The repo's executable-Gherkin lane is playwright-bdd
# under tests/e2e (tests/scripts/test-e2e-gherkin-harness.sh guards it). It needs
# tests/e2e/node_modules and a browser, and compiles features into Playwright
# tests; a QEMU boot has no page to drive. So this file is a deliberately small
# Gherkin interpreter in the style of the other tests/qemu suites: it reads the
# .feature, runs Background + each Scenario's steps in order, and matches every
# step line against the step definitions in step(). There is no keyword magic and
# no fallback: a step with no definition FAILS its scenario (the playwright-bdd
# lane's missingSteps:'fail-on-gen', restated), and the remaining steps of that
# scenario are printed as SKIPPED, never silently dropped.
#
# FAILS CLOSED. No /dev/kvm is a FAIL of the first scenario, not a skip. The KVM
# boot uses `-accel kvm` (never `kvm:tcg`), so a silent fall-back to emulation
# cannot pass the boot scenario — and the third scenario asks QEMU's own monitor.
# A run that selects zero scenarios exits 2: a green run that ran nothing is the
# failure this repo keeps finding.
#
# WHAT IT WRITES under --out (the workflow uploads it): serial-<accel>.log,
# monitor-<accel>.txt, qemu-<accel>.stderr, timings.env (KEY=VALUE, ms) and
# results.txt (one line per step).
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURE="${HERE}/features/actions-kvm-smoke.feature"
IMAGE=""; IMAGE_SHA256=""; OUT="${PWD}/qemu-bdd-out"; MODE="kvm"
MEM_MB="${QEMU_MEM_MB:-512}"; SMP="${QEMU_SMP:-2}"

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image)     IMAGE="$2"; shift 2 ;;
    --sha256)    IMAGE_SHA256="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --feature)   FEATURE="$2"; shift 2 ;;
    --tcg)       MODE="tcg"; shift ;;
    --self-test) MODE="self-test"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

now_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$(( t / 1000 ))"; }

# ── QEMU state shared across scenarios (scenario 3 inspects scenario 2's guest) ──
VM_PID=""; VM_ACCEL=""; VM_START_MS=""; VM_SERIAL=""; VM_MON=""; VM_DIR=""
BOOT_MS=""; LAST_MONITOR=""

stop_vm() {
  if [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null; then
    kill "${VM_PID}" 2>/dev/null
    local i; for i in $(seq 1 50); do kill -0 "${VM_PID}" 2>/dev/null || break; sleep 0.1; done
    kill -9 "${VM_PID}" 2>/dev/null
  fi
  wait "${VM_PID}" 2>/dev/null
  VM_PID=""
}
cleanup() { stop_vm; [ -n "${VM_DIR}" ] && rm -rf "${VM_DIR}"; }
trap cleanup EXIT

# OVMF: the Ubuntu runner ships /usr/share/OVMF/*_4M.fd; Gentoo and Fedora use
# other directories. OVMF_CODE / OVMF_VARS override. CODE and VARS must come from
# the SAME directory and size class, so they are resolved as a pair.
resolve_ovmf() {
  if [ -n "${OVMF_CODE:-}" ] && [ -n "${OVMF_VARS:-}" ]; then return 0; fi
  local d c v
  for d in /usr/share/OVMF /usr/share/edk2/OvmfX64 /usr/share/edk2-ovmf /usr/share/edk2/ovmf /usr/share/qemu; do
    for c in OVMF_CODE_4M.fd OVMF_CODE.fd; do
      v="${c/CODE/VARS}"
      if [ -f "${d}/${c}" ] && [ -f "${d}/${v}" ]; then
        OVMF_CODE="${d}/${c}"; OVMF_VARS="${d}/${v}"; return 0
      fi
    done
  done
  return 1
}

boot_vm() { # accel
  local accel="$1" cpu
  stop_vm
  resolve_ovmf || { echo "    no OVMF CODE/VARS pair found (set OVMF_CODE and OVMF_VARS)"; return 1; }
  [ "${accel}" = kvm ] && cpu=host || cpu=max
  VM_DIR="$(mktemp -d)"
  cp "${OVMF_VARS}" "${VM_DIR}/vars.fd"
  VM_SERIAL="${OUT}/serial-${accel}.log"; VM_MON="${VM_DIR}/mon.sock"
  : > "${VM_SERIAL}"
  echo "    firmware: ${OVMF_CODE} (+ per-run copy of ${OVMF_VARS##*/})"
  echo "    qemu: -machine q35 -accel ${accel} -cpu ${cpu} -m ${MEM_MB} -smp ${SMP}"
  VM_START_MS="$(now_ms)"
  qemu-system-x86_64 \
    -machine q35 -accel "${accel}" -cpu "${cpu}" -m "${MEM_MB}" -smp "${SMP}" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${VM_DIR}/vars.fd" \
    -cdrom "${IMAGE}" -boot d -nic none -no-reboot \
    -display none -vga none \
    -serial "file:${VM_SERIAL}" \
    -monitor "unix:${VM_MON},server,nowait" \
    2>"${OUT}/qemu-${accel}.stderr" &
  VM_PID=$!; VM_ACCEL="${accel}"; BOOT_MS=""
  sleep 0.5
  kill -0 "${VM_PID}" 2>/dev/null || { echo "    qemu exited at once:"; sed 's/^/      /' "${OUT}/qemu-${accel}.stderr"; return 1; }
  return 0
}

wait_login() { # seconds
  local limit_ms=$(( $1 * 1000 )) elapsed
  while :; do
    elapsed=$(( $(now_ms) - VM_START_MS ))
    if grep -a 'login:' "${VM_SERIAL}" >/dev/null 2>&1; then
      BOOT_MS="${elapsed}"
      echo "    login prompt after ${BOOT_MS} ms"
      return 0
    fi
    if ! kill -0 "${VM_PID}" 2>/dev/null; then
      echo "    qemu died before a login prompt; serial tail:"; tail -5 "${VM_SERIAL}" | sed 's/^/      /'
      return 1
    fi
    if [ "${elapsed}" -ge "${limit_ms}" ]; then
      echo "    no login prompt within $1 s; serial tail:"; tail -5 "${VM_SERIAL}" | sed 's/^/      /'
      return 1
    fi
    sleep 0.1
  done
}

ask_monitor() { # command
  [ -S "${VM_MON}" ] || { echo "    no monitor socket at ${VM_MON}"; return 1; }
  command -v socat >/dev/null || { echo "    socat is required to talk to the QEMU monitor"; return 1; }
  LAST_MONITOR="${OUT}/monitor-${VM_ACCEL}.txt"
  # The HMP monitor echoes the line with terminal escapes; strip them and CRs so
  # the answer line reads as text.
  printf '%s\n' "$1" | socat -t2 - "UNIX-CONNECT:${VM_MON}" 2>&1 \
    | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r' > "${LAST_MONITOR}"
  echo "    monitor answered:"; sed 's/^/      /' "${LAST_MONITOR}"; echo
  return 0
}

# ── step definitions. Return 0 pass, 1 fail, 127 undefined. ─────────────────────
step() {
  local s="$1"
  if [[ "${s}" == "the pinned image is present and matches its pinned sha256" ]]; then
    [ -n "${IMAGE}" ] && [ -f "${IMAGE}" ] || { echo "    no image (pass --image)"; return 1; }
    [[ "${IMAGE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || { echo "    no pinned sha256 (pass --sha256)"; return 1; }
    local got; got="$(sha256sum "${IMAGE}")"; got="${got%% *}"
    [ "${got}" = "${IMAGE_SHA256}" ] || { echo "    sha256 MISMATCH: got ${got}"; return 1; }
    return 0
  elif [[ "${s}" == "the host exposes /dev/kvm as a character device" ]]; then
    ls -l /dev/kvm 2>&1 | sed 's/^/    /'
    [ -c /dev/kvm ]
  elif [[ "${s}" == "the runner user can open /dev/kvm for reading and writing" ]]; then
    # Opening it is the real test; -r/-w only read the mode bits.
    ( exec 3<>/dev/kvm ) 2>/dev/null || { echo "    open(/dev/kvm, O_RDWR) failed for $(id -un)"; return 1; }
  elif [[ "${s}" == "the CPU advertises hardware virtualisation" ]]; then
    local n; n="$(grep -c -w -E 'vmx|svm' /proc/cpuinfo 2>/dev/null)"
    echo "    vmx/svm flags on ${n:-0} logical CPU(s)"
    [ "${n:-0}" -gt 0 ]
  elif [[ "${s}" == "qemu-system-x86_64 starts a machine with -accel kvm" ]]; then
    local o
    o="$(printf 'info kvm\nquit\n' | timeout 30 qemu-system-x86_64 -machine q35 -accel kvm -cpu host \
          -m 64 -nodefaults -display none -S -monitor stdio 2>&1 | tr -d '\r')"
    printf '%s\n' "${o}" | grep -a 'kvm support' | sed 's/^/    /'
    printf '%s\n' "${o}" | grep -a 'kvm support: enabled' >/dev/null
  elif [[ "${s}" =~ ^the\ image\ is\ booted\ with\ -accel\ (kvm|tcg)\ on\ q35\ with\ UEFI\ firmware\ and\ a\ serial\ log$ ]]; then
    boot_vm "${BASH_REMATCH[1]}"
  elif [[ "${s}" =~ ^the\ serial\ console\ shows\ a\ login\ prompt\ within\ ([0-9]+)\ seconds$ ]]; then
    [ -n "${VM_PID}" ] || { echo "    no guest was booted"; return 1; }
    wait_login "${BASH_REMATCH[1]}"
  elif [[ "${s}" =~ ^the\ boot\ time\ is\ recorded\ as\ \"(kvm|tcg)\"$ ]]; then
    [ -n "${BOOT_MS}" ] || { echo "    no boot time to record"; return 1; }
    printf 'BOOT_MS_%s=%s\n' "${BASH_REMATCH[1]^^}" "${BOOT_MS}" >> "${OUT}/timings.env"
    echo "    BOOT_MS_${BASH_REMATCH[1]^^}=${BOOT_MS}"
  elif [[ "${s}" =~ ^the\ guest\ from\ the\ previous\ scenario\ is\ still\ running\ under\ \"(kvm|tcg)\"$ ]]; then
    [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null || { echo "    no guest is running"; return 1; }
    [ "${VM_ACCEL}" = "${BASH_REMATCH[1]}" ] || { echo "    the running guest uses ${VM_ACCEL}"; return 1; }
  elif [[ "${s}" =~ ^the\ QEMU\ monitor\ is\ asked\ \"([^\"]+)\"$ ]]; then
    [ -n "${VM_PID}" ] && kill -0 "${VM_PID}" 2>/dev/null || { echo "    no guest is running"; return 1; }
    ask_monitor "${BASH_REMATCH[1]}"
  elif [[ "${s}" =~ ^the\ monitor\ answers\ \"([^\"]+)\"$ ]]; then
    [ -n "${LAST_MONITOR}" ] && [ -f "${LAST_MONITOR}" ] || { echo "    the monitor was never asked"; return 1; }
    grep -a -x -F "${BASH_REMATCH[1]}" "${LAST_MONITOR}" >/dev/null
  # --self-test only: a step that always fails, so the self-test can prove a
  # failing step fails its scenario.
  elif [[ "${MODE}" == self-test && "${s}" == "a step that fails" ]]; then
    return 1
  elif [[ "${MODE}" == self-test && "${s}" == "a step that passes" ]]; then
    return 0
  else
    return 127
  fi
}

# ── the interpreter ──────────────────────────────────────────────────────────────
RESULTS=""; SC_RUN=0; SC_PASS=0; SC_FAIL=0

run_feature() { # feature-file selected-tag ("" = untagged scenarios only)
  local file="$1" want="$2" line text kw tags="" in_bg=0
  local -a bg=() names=() bodies=() stags=()
  local cur=-1
  while IFS= read -r line || [ -n "${line}" ]; do
    text="${line#"${line%%[![:space:]]*}"}"
    case "${text}" in
      ''|'#'*) continue ;;
      @*) tags="${tags} ${text}"; continue ;;
      'Feature:'*) continue ;;
      'Background:'*) in_bg=1; continue ;;
      'Scenario:'*)
        in_bg=0; cur=$((cur+1))
        names[cur]="${text#Scenario:}"; names[cur]="${names[cur]# }"
        bodies[cur]=""; stags[cur]="${tags}"; tags=""; continue ;;
      'Scenario Outline:'*|'Examples:'*|'Rule:'*|'|'*|'"""'*)
        echo "unsupported Gherkin construct (this runner is deliberately small): ${text}" >&2
        return 2 ;;
    esac
    kw="${text%% *}"
    case "${kw}" in
      Given|When|Then|And|But) ;;
      *) continue ;;   # free-text description under a Feature or Scenario
    esac
    if [ "${in_bg}" = 1 ]; then bg+=("${text}"); else bodies[cur]+="${text}"$'\n'; fi
  done < "${file}"

  local i st rc failed sel
  for i in "${!names[@]}"; do
    if [ -z "${want}" ]; then
      [ -z "${stags[i]// /}" ] || continue
    else
      case " ${stags[i]} " in *" @${want} "*) ;; *) continue ;; esac
    fi
    SC_RUN=$((SC_RUN+1)); failed=0
    echo; echo "Scenario: ${names[i]}"
    local -a steps=("${bg[@]}")
    while IFS= read -r st; do [ -n "${st}" ] && steps+=("${st}"); done <<< "${bodies[i]}"
    for st in "${steps[@]}"; do
      if [ "${failed}" = 1 ]; then
        echo "  SKIPPED ${st}"; RESULTS+="SKIPPED|${names[i]}|${st}"$'\n'; continue
      fi
      step "${st#* }"; rc=$?
      case "${rc}" in
        0)   echo "  PASS    ${st}"; RESULTS+="PASS|${names[i]}|${st}"$'\n' ;;
        127) echo "  UNDEFINED ${st}  (no step definition — the scenario FAILS)"; failed=1
             RESULTS+="UNDEFINED|${names[i]}|${st}"$'\n' ;;
        *)   echo "  FAIL    ${st}"; failed=1; RESULTS+="FAIL|${names[i]}|${st}"$'\n' ;;
      esac
    done
    if [ "${failed}" = 0 ]; then SC_PASS=$((SC_PASS+1)); else SC_FAIL=$((SC_FAIL+1)); fi
  done
  return 0
}

verdict() {
  echo
  echo "RESULT: ${SC_RUN} scenario(s) run, ${SC_PASS} passed, ${SC_FAIL} failed"
  [ "${SC_RUN}" -gt 0 ] || { echo "RESULT: VACUOUS — no scenario was selected; that is not a pass"; return 2; }
  [ "${SC_FAIL}" -eq 0 ]
}

# ── --self-test: the interpreter's own negative controls. No QEMU, no image. ─────
if [ "${MODE}" = self-test ]; then
  T="$(mktemp -d)"; P=0; F=0
  ok()  { P=$((P+1)); echo "  ok   $1"; }
  bad() { F=$((F+1)); echo "  FAIL $1"; }
  cat > "${T}/f.feature" <<'EOF'
Feature: self-test
  Scenario: passes
    Given a step that passes
  Scenario: undefined step fails
    Given a step that passes
    When a step nobody defined
    Then a step that passes
  Scenario: failing step fails
    Given a step that fails
    Then a step that passes
  @other
  Scenario: tagged, not selected by default
    Given a step that fails
EOF
  OUT="${T}"; run_feature "${T}/f.feature" "" > "${T}/log" 2>&1
  [ "${SC_RUN}" = 3 ] && ok "untagged selection runs 3 of 4 scenarios" || bad "selected ${SC_RUN}, want 3"
  [ "${SC_PASS}" = 1 ] && [ "${SC_FAIL}" = 2 ] && ok "undefined and failing steps both FAIL their scenario" \
    || bad "got ${SC_PASS} pass / ${SC_FAIL} fail, want 1 / 2"
  grep -c '^  SKIPPED' "${T}/log" | grep -x 2 >/dev/null && ok "steps after a failure are reported SKIPPED" \
    || bad "SKIPPED count wrong";
  SC_RUN=0; SC_PASS=0; SC_FAIL=0
  run_feature "${T}/f.feature" "nosuchtag" > "${T}/log" 2>&1
  verdict > "${T}/v" 2>&1; rc=$?
  [ "${rc}" = 2 ] && ok "zero selected scenarios exits 2 (VACUOUS), not 0" || bad "vacuous run exited ${rc}"
  printf 'Feature: x\n  Scenario Outline: y\n    Given a step that passes\n' > "${T}/o.feature"
  run_feature "${T}/o.feature" "" > "${T}/log" 2>&1; rc=$?
  [ "${rc}" = 2 ] && ok "an unsupported construct (Scenario Outline) is refused, not skipped" || bad "outline rc=${rc}"
  # The real feature must parse to exactly the scenarios it declares: 3 untagged + 1 @tcg.
  n_decl="$(grep -c -E '^[[:space:]]*Scenario:' "${HERE}/features/actions-kvm-smoke.feature")"
  [ "${n_decl}" = 4 ] && ok "the real feature declares 4 scenarios" || bad "real feature declares ${n_decl}"
  rm -rf "${T}"
  echo "self-test: ${P} passed, ${F} failed"
  [ "${F}" -eq 0 ]; exit $?
fi

# ── a real run ──────────────────────────────────────────────────────────────────
command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 is not installed" >&2; exit 2; }
[ -f "${FEATURE}" ] || { echo "no feature file at ${FEATURE}" >&2; exit 2; }
mkdir -p "${OUT}"
echo "== ${FEATURE##*/} (mode: ${MODE}) =="
echo "   image: ${IMAGE}"
if [ "${MODE}" = tcg ]; then run_feature "${FEATURE}" tcg; else run_feature "${FEATURE}" ""; fi
rc=$?; [ "${rc}" = 0 ] || exit "${rc}"
stop_vm
printf '%s' "${RESULTS}" >> "${OUT}/results.txt"
verdict
