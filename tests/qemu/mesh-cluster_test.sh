#!/usr/bin/env bash
# mesh-cluster_test.sh — STATIC gate + HERMETIC tests for the 3-node QEMU
# mesh-cluster lane (issue #48, PR B). NOTHING boots here: no QEMU, no root,
# no images — qemu-system-x86_64/qemu-img are PATH stubs that record their
# argv, and the orchestrator runs behind its MESH_LAUNCH_CMD / MESH_SSH_CMD /
# MESH_KEYS_CMD seams (the same seam pattern as avc-workout_test.sh). The real
# boot campaign is post-build and opt-in (HUGMESH_QEMU_MESH=1).
#
# What is pinned/proved:
#   [launch]   launch-x86.sh --mesh-net/--mesh-mac/--mesh-id: the shared-L2 NIC
#              lands on the QEMU argv (socket mcast netdev + derived MAC), the
#              flags are DEFAULT-OFF (no flags -> argv carries no mesh NIC at
#              all), and the argument validation fails closed.
#   [driver]   mesh-cluster.sh end-to-end via stubs: CP first, joiners after,
#              cross-file consistency of the OFFLINE-minted join material
#              (pinned token + ca-cert hash in the workers' KEYS == the CP's
#              kubeadm-config/CA), per-node MAC/IP/port disjointness, PASS/FAIL
#              verdicts, and the SKIP/--dry-run gating (dry-run writes NOTHING).
#   [golden]   neither the launcher nor the driver ever runs `qemu-img commit`
#              on a live line — committing an overlay back silently rewrites
#              the GOLDEN artifact (the qemu-device-save lesson).
#   [wiring]   make qemu-mesh / qemu-mesh-enumerate exist and call the driver;
#              CI carries lint:qemu-mesh-cluster; check.sh runs this file.
#
# NEGATIVE CONTROLS (a guard that cannot be shown failing is not a guard):
# staged sed regressions on COPIES — mesh flag parsing dropped, the mesh netdev
# construction dropped, the default-off guard inverted, the opt-in SKIP gate
# removed, a qemu-img commit planted — must each turn the relevant leg red.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

echo "== [syntax] both lane scripts parse =="
bash -n "${HERE}/launch-x86.sh"    && ok "bash -n launch-x86.sh"    || bad "bash -n launch-x86.sh"
bash -n "${HERE}/mesh-cluster.sh"  && ok "bash -n mesh-cluster.sh"  || bad "bash -n mesh-cluster.sh"

echo "== [launch] static pins on live lines (all THREE launchers — parity) =="
for lsh in launch-x86.sh launch-pi.sh launch-arm.sh; do
    grep -qE '^\s*--mesh-net\)'  "${HERE}/${lsh}" && ok "${lsh}: --mesh-net parse case"  || bad "${lsh}: --mesh-net parse case missing"
    grep -qE '^\s*--mesh-mac\)'  "${HERE}/${lsh}" && ok "${lsh}: --mesh-mac parse case"  || bad "${lsh}: --mesh-mac parse case missing"
    grep -qE '^\s*--mesh-id\)'   "${HERE}/${lsh}" && ok "${lsh}: --mesh-id parse case"   || bad "${lsh}: --mesh-id parse case missing"
    grep -q  'socket,id=mesh0'   "${HERE}/${lsh}" && ok "${lsh}: socket netdev construction present" || bad "${lsh}: socket netdev construction missing"
    grep -q  '52:54:00:6d:65:%02x' "${HERE}/${lsh}" && ok "${lsh}: --mesh-id MAC derivation present" || bad "${lsh}: MAC derivation missing"
done
# Parity is the actual requirement, not "each file has some mesh code": a
# mixed-arch mesh boots rows through different launchers, and one of them
# spelling the SPEC grammar or the MAC rule differently is a node that silently
# lands on another wire. So the three blocks are compared, not just counted.
mesh_block() { sed -n '/^# Optional shared mesh L2/,/^fi$/p' "$1"; }
diff <(mesh_block "${HERE}/launch-x86.sh" | grep -v '^#') \
     <(mesh_block "${HERE}/launch-pi.sh"  | grep -v '^#') >/dev/null 2>&1 \
    && ok "parity: launch-pi.sh's mesh block is launch-x86.sh's, line for line" \
    || bad "parity: launch-pi.sh's mesh block has drifted from launch-x86.sh's"
diff <(mesh_block "${HERE}/launch-x86.sh" | grep -v '^#') \
     <(mesh_block "${HERE}/launch-arm.sh" | grep -v '^#') >/dev/null 2>&1 \
    && ok "parity: launch-arm.sh's mesh block is launch-x86.sh's, line for line" \
    || bad "parity: launch-arm.sh's mesh block has drifted from launch-x86.sh's"

echo "== [golden] no live qemu-img commit in the lane (overlay -> golden rewrite trap) =="
no_commit() { ! grep -qE '^[^#]*qemu-img[[:space:]]+commit' "$1"; }
for gsh in launch-x86.sh launch-pi.sh launch-arm.sh mesh-cluster.sh \
           run-qemu-docker.sh docker-entrypoint.sh; do
    no_commit "${HERE}/${gsh}" && ok "${gsh}: no qemu-img commit" \
        || bad "${gsh}: qemu-img commit on a live line"
done

echo "== [launch] EFFECT: QEMU argv via PATH stubs (no real qemu anywhere) =="
stub="${work}/stub"; mkdir -p "${stub}"
cat > "${stub}/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_ARGV_OUT:?}"
exit 0
EOF
cat > "${stub}/qemu-img" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = create ]; then for last in "$@"; do :; done; : > "${last}"; fi
exit 0
EOF
# The aarch64 launchers (launch-pi.sh / launch-arm.sh) gained the same flags, so
# they get the same treatment: a PATH stub that records argv and a fake kernel/DTB.
cat > "${stub}/qemu-system-aarch64" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_ARGV_OUT:?}"
exit 0
EOF
chmod +x "${stub}/qemu-system-x86_64" "${stub}/qemu-system-aarch64" "${stub}/qemu-img"
: > "${work}/fixture.img"; : > "${work}/OVMF_CODE.fd"; : > "${work}/OVMF_VARS.fd"
: > "${work}/Image"; : > "${work}/board.dtb"

run_launch() { # <script> <argv-out> [extra flags...]
    local script="$1" out="$2"; shift 2
    PATH="${stub}:${PATH}" STUB_ARGV_OUT="${out}" \
    bash "${script}" --img "${work}/fixture.img" \
        --ovmf-code "${work}/OVMF_CODE.fd" --ovmf-vars "${work}/OVMF_VARS.fd" \
        --run-dir "${work}/launch-run" --keep "$@" >/dev/null 2>&1
}

run_launch_pi() { # <script> <argv-out> [extra flags...]
    local script="$1" out="$2"; shift 2
    PATH="${stub}:${PATH}" STUB_ARGV_OUT="${out}" \
    bash "${script}" --img "${work}/fixture.img" --kernel "${work}/Image" \
        --run-dir "${work}/launch-pi-run" --keep "$@" >/dev/null 2>&1
}

run_launch_arm() { # <script> <argv-out> [extra flags...]
    local script="$1" out="$2"; shift 2
    PATH="${stub}:${PATH}" STUB_ARGV_OUT="${out}" \
    bash "${script}" --platform frite --board la-frite \
        --img "${work}/fixture.img" --kernel "${work}/Image" --dtb "${work}/board.dtb" \
        --run-dir "${work}/launch-arm-run" --keep "$@" >/dev/null 2>&1
}

run_launch "${HERE}/launch-x86.sh" "${work}/argv-mesh.txt" \
    --mesh-net 239.118.72.9:47391 --mesh-id 2 \
    && ok "launch: --mesh-net + --mesh-id exits 0" || bad "launch: --mesh-net + --mesh-id failed"
grep -q '^socket,id=mesh0,mcast=239.118.72.9:47391$' "${work}/argv-mesh.txt" \
    && ok "launch: bare ADDR:PORT becomes an mcast socket netdev" || bad "launch: mcast netdev missing from argv"
grep -q '^virtio-net-pci,netdev=mesh0,mac=52:54:00:6d:65:02$' "${work}/argv-mesh.txt" \
    && ok "launch: mesh NIC device with the --mesh-id-derived MAC" || bad "launch: mesh NIC/derived MAC missing from argv"
grep -q 'hostfwd=tcp' "${work}/argv-mesh.txt" \
    && ok "launch: slirp user NIC + hostfwds kept alongside the mesh NIC" || bad "launch: user NIC hostfwds lost"

run_launch "${HERE}/launch-x86.sh" "${work}/argv-listen.txt" \
    --mesh-net listen=127.0.0.1:47392 \
    && ok "launch: listen= point-to-point spelling accepted" || bad "launch: listen= spelling rejected"
grep -q '^socket,id=mesh0,listen=127.0.0.1:47392$' "${work}/argv-listen.txt" \
    && ok "launch: listen= passes through verbatim" || bad "launch: listen= not passed through"

run_launch "${HERE}/launch-x86.sh" "${work}/argv-mac.txt" \
    --mesh-net 239.118.72.9:47391 --mesh-mac 52:54:00:aa:bb:cc \
    && ok "launch: explicit --mesh-mac accepted" || bad "launch: explicit --mesh-mac failed"
grep -q 'mac=52:54:00:aa:bb:cc' "${work}/argv-mac.txt" \
    && ok "launch: explicit --mesh-mac lands on the argv" || bad "launch: explicit MAC not honoured"

run_launch "${HERE}/launch-x86.sh" "${work}/argv-off.txt" \
    && ok "launch: no mesh flags exits 0" || bad "launch: flagless run failed"
[ -f "${work}/argv-off.txt" ] && ! grep -q 'mesh0' "${work}/argv-off.txt" \
    && ok "launch: DEFAULT-OFF — flagless argv carries no mesh NIC" || bad "launch: mesh NIC leaked into the flagless argv"

echo "== [launch] EFFECT on the aarch64 launchers (mixed-arch mesh parity) =="
run_launch_pi "${HERE}/launch-pi.sh" "${work}/argv-pi-mesh.txt" \
    --mesh-net 239.118.72.9:47391 --mesh-id 2 \
    && ok "launch-pi: --mesh-net + --mesh-id exits 0" || bad "launch-pi: --mesh-net + --mesh-id failed"
grep -q '^socket,id=mesh0,mcast=239.118.72.9:47391$' "${work}/argv-pi-mesh.txt" \
    && ok "launch-pi: bare ADDR:PORT becomes an mcast socket netdev" || bad "launch-pi: mcast netdev missing from argv"
grep -q '^virtio-net-pci,netdev=mesh0,mac=52:54:00:6d:65:02$' "${work}/argv-pi-mesh.txt" \
    && ok "launch-pi: mesh NIC device with the --mesh-id-derived MAC" || bad "launch-pi: mesh NIC/derived MAC missing from argv"
grep -q 'hostfwd=tcp' "${work}/argv-pi-mesh.txt" \
    && ok "launch-pi: slirp user NIC + hostfwds kept alongside the mesh NIC" || bad "launch-pi: user NIC hostfwds lost"
run_launch_arm "${HERE}/launch-arm.sh" "${work}/argv-arm-mesh.txt" \
    --mesh-net 239.118.72.9:47391 --mesh-mac 52:54:00:aa:bb:cc \
    && ok "launch-arm: --mesh-net + explicit --mesh-mac exits 0" || bad "launch-arm: --mesh-net + --mesh-mac failed"
grep -q '^socket,id=mesh0,mcast=239.118.72.9:47391$' "${work}/argv-arm-mesh.txt" \
    && ok "launch-arm: mcast socket netdev on the argv" || bad "launch-arm: mcast netdev missing from argv"
grep -q '^virtio-net-pci,netdev=mesh0,mac=52:54:00:aa:bb:cc$' "${work}/argv-arm-mesh.txt" \
    && ok "launch-arm: mesh NIC carries the explicit MAC" || bad "launch-arm: explicit MAC not honoured"
run_launch_pi "${HERE}/launch-pi.sh" "${work}/argv-pi-x1.txt" --mesh-mac 52:54:00:aa:bb:cc \
    && bad "launch-pi: --mesh-mac without --mesh-net was accepted" || ok "launch-pi: --mesh-mac without --mesh-net dies"
run_launch_arm "${HERE}/launch-arm.sh" "${work}/argv-arm-x1.txt" --mesh-net 239.1.1.1:1 --mesh-mac 53:54:00:aa:bb:cc \
    && bad "launch-arm: multicast (odd first octet) MAC was accepted" || ok "launch-arm: multicast MAC dies"

echo "== [launch] DEFAULT-OFF is BYTE-IDENTITY, proved against a mesh-less copy =="
# "no mesh0 in the argv" only proves the NIC is absent. The promise is stronger:
# a run without the flags must produce the argv it produced before these flags
# existed. So the block is cut out of a copy, both are run flagless with the SAME
# run dir, and the two argv files must be byte-for-byte equal.
# The copies live in a MIRROR of the checkout, not loose in the tmpdir: every
# launcher resolves REPO_DIR from its own path, and launch-arm.sh reads the real
# specs-<platform>/boot/cmdline.base through it (it refuses to boot with a
# hardcoded security posture). A copy in a bare tmpdir dies there instead of
# producing the argv this comparison exists to make. Nothing is written into the
# checkout itself — sibling sessions are working in it.
mutrepo="${work}/mutrepo"
mkdir -p "${mutrepo}/tests/qemu" "${mutrepo}/specs-frite/boot" "${mutrepo}/scripts"
cp "${REPO}/specs-frite/boot/cmdline.base" "${mutrepo}/specs-frite/boot/" 2>/dev/null || true
# The x86/pi launchers source the ONE role vocabulary through REPO_DIR (they fold
# `--role be`/`host` and glob an artifact under every older spelling of its role), so
# the mirror needs it too. Without it the mesh-less copy dies on a missing source and
# the byte-identity comparison reports "copy failed to run" — a launcher-mirror
# omission that reads exactly like a real regression in the mesh block.
cp "${REPO}/scripts/_roles-lib.sh" "${mutrepo}/scripts/" 2>/dev/null || true

strip_mesh_block() { # <script> -> path to a copy with the whole mesh block gone
    local out="${mutrepo}/tests/qemu/nomesh-$(basename "$1")"
    sed -e '/^# Optional shared mesh L2/,/^fi$/d' "$1" > "${out}"
    cmp -s "${out}" "$1" && { echo ""; return; }
    printf '%s\n' "${out}"
}
byte_identical_default() { # <name> <runner-fn> <script>
    local name="$1" fn="$2" script="$3" stripped
    stripped="$(strip_mesh_block "${script}")"
    if [ -z "${stripped}" ]; then bad "byte-identity[${name}]: could not cut the mesh block out"; return; fi
    "${fn}" "${script}"    "${work}/bi-${name}-with.txt"    || { bad "byte-identity[${name}]: flagless run failed"; return; }
    "${fn}" "${stripped}"  "${work}/bi-${name}-without.txt" || { bad "byte-identity[${name}]: mesh-less copy failed to run"; return; }
    if cmp -s "${work}/bi-${name}-with.txt" "${work}/bi-${name}-without.txt"; then
        ok "byte-identity[${name}]: flagless argv == argv of a copy with no mesh code at all"
    else
        bad "byte-identity[${name}]: the mesh block changes the flagless argv"
        diff "${work}/bi-${name}-without.txt" "${work}/bi-${name}-with.txt" | head -6 | sed 's/^/    | /' >&2
    fi
}
byte_identical_default x86 run_launch     "${HERE}/launch-x86.sh"
byte_identical_default pi  run_launch_pi  "${HERE}/launch-pi.sh"
byte_identical_default arm run_launch_arm "${HERE}/launch-arm.sh"
# ...and the control for the control: the comparison must be able to FAIL, or a
# broken strip_mesh_block would make every line above green for free.
run_launch "${HERE}/launch-x86.sh" "${work}/bi-x86-flagged.txt" --mesh-net 239.1.1.1:47301 --mesh-id 1
cmp -s "${work}/bi-x86-with.txt" "${work}/bi-x86-flagged.txt" \
    && bad "control[byte-identity]: a FLAGGED argv compared equal to the flagless one" \
    || ok "control[byte-identity]: a flagged argv does differ (the comparison is live)"

echo "== [launch] validation fails closed =="
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x1.txt" --mesh-mac 52:54:00:aa:bb:cc \
    && bad "launch: --mesh-mac without --mesh-net was accepted" || ok "launch: --mesh-mac without --mesh-net dies"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x2.txt" --mesh-net not-a-spec \
    && bad "launch: colon-less --mesh-net was accepted" || ok "launch: colon-less --mesh-net dies"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x3.txt" --mesh-net 239.1.1.1:1 --mesh-id 0 \
    && bad "launch: --mesh-id 0 was accepted" || ok "launch: --mesh-id 0 dies"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x4.txt" --mesh-net 239.1.1.1:1 --mesh-id 1 --mesh-mac 52:54:00:aa:bb:cc \
    && bad "launch: --mesh-id + --mesh-mac together were accepted" || ok "launch: --mesh-id + --mesh-mac together die"
run_launch "${HERE}/launch-x86.sh" "${work}/argv-x5.txt" --mesh-net 239.1.1.1:1 --mesh-mac 53:54:00:aa:bb:cc \
    && bad "launch: multicast (odd first octet) MAC was accepted" || ok "launch: multicast MAC dies"

echo "== [launch] NEGATIVE CONTROLS: staged regressions must go red =="
launch_mutant() { # <name> <sed-expr>  -> path on stdout, empty if sed matched nothing
    local m="${work}/mut-launch-$1.sh"
    sed -e "$2" "${HERE}/launch-x86.sh" > "${m}"
    cmp -s "${m}" "${HERE}/launch-x86.sh" && { echo ""; return; }
    echo "${m}"
}
m="$(launch_mutant drop-parse '/--mesh-net)/d')"
if [ -n "${m}" ]; then
    run_launch "${m}" "${work}/argv-m1.txt" --mesh-net 239.118.72.9:47391 --mesh-id 2 \
        && bad "control[drop-parse]: mutant still accepted --mesh-net" \
        || ok "control[drop-parse]: dropping the parse case goes red"
else bad "control[drop-parse]: sed matched nothing"; fi
m="$(launch_mutant drop-netdev '/socket,id=mesh0/d')"
if [ -n "${m}" ]; then
    if run_launch "${m}" "${work}/argv-m2.txt" --mesh-net 239.118.72.9:47391 --mesh-id 2 \
            && grep -q 'socket,id=mesh0' "${work}/argv-m2.txt" 2>/dev/null; then
        bad "control[drop-netdev]: mutant still emitted the mesh netdev"
    else
        ok "control[drop-netdev]: dropping the netdev construction goes red"
    fi
else bad "control[drop-netdev]: sed matched nothing"; fi
m="$(launch_mutant always-on 's|if \[ -z "${MESH_NET}" \]; then|if false; then|')"
if [ -n "${m}" ]; then
    if run_launch "${m}" "${work}/argv-m3.txt" \
            && [ -f "${work}/argv-m3.txt" ] && ! grep -q 'mesh0' "${work}/argv-m3.txt"; then
        bad "control[always-on]: default-off leg stayed green on the inverted guard"
    else
        ok "control[always-on]: inverting the default-off guard goes red"
    fi
else bad "control[always-on]: sed matched nothing"; fi

echo "== [driver] gating: SKIP-clean + --dry-run boots nothing =="
grep -q 'HUGMESH_QEMU_MESH' "${HERE}/mesh-cluster.sh" \
    && ok "driver: opt-in gate reads HUGMESH_QEMU_MESH" || bad "driver: opt-in env gate missing"
grep -q 'command -v qemu-system-x86_64' "${HERE}/mesh-cluster.sh" \
    && ok "driver: qemu presence gate exists" || bad "driver: qemu presence gate missing"
out="$(HUGMESH_QEMU_MESH= bash "${HERE}/mesh-cluster.sh" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: no-env run exits 0" || bad "driver: no-env run exited ${rc}"
echo "${out}" | grep -q 'SKIP' && ok "driver: no-env run says SKIP" || bad "driver: no-env run did not SKIP"
out="$(bash "${HERE}/mesh-cluster.sh" --dry-run --run-dir "${work}/dryrun-dir" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: --dry-run exits 0" || bad "driver: --dry-run exited ${rc}"
[ "$(echo "${out}" | grep -c '^NODE ')" -eq 3 ] && ok "driver: --dry-run plans exactly 3 nodes" || bad "driver: --dry-run node rows != 3"
echo "${out}" | grep -q 'nothing booted' && ok "driver: --dry-run says nothing booted" || bad "driver: --dry-run verdict line missing"
for mac in 52:54:00:6d:65:01 52:54:00:6d:65:02 52:54:00:6d:65:03; do
    echo "${out}" | grep -q "${mac}" && ok "driver: --dry-run plans MAC ${mac}" || bad "driver: MAC ${mac} missing from the plan"
done
[ ! -e "${work}/dryrun-dir" ] && ok "driver: --dry-run wrote NOTHING (no run dir, no keys)" || bad "driver: --dry-run created files"

echo "== [driver] hermetic end-to-end via the MESH_*_CMD seams =="
cat > "${work}/launch-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Record the call, then emit the canned console a real boot would produce.
printf '%s\n' "$*" >> "${STUB_CALLS:?}"
rundir=""; prev=""
for a in "$@"; do [ "${prev}" = "--run-dir" ] && rundir="${a}"; prev="${a}"; done
mkdir -p "${rundir}"
case "${rundir}" in
    *node1-*)
        { echo "Running kubeadm init (first control-plane) --upload-certs"
          echo "First control plane initialised; join material in /etc/hugmesh/kubeadm-join.cmd"
          echo "=== keys-provision complete ==="; } > "${rundir}/console.log" ;;
    *node3-*)
        if [ "${STUB_JOIN_FAIL:-0}" = "1" ]; then
            echo "kubeadm join failed against 10.87.72.11:6443" > "${rundir}/console.log"
        else
            { echo "Joined cluster (10.87.72.11:6443)"
              echo "=== keys-provision complete ==="; } > "${rundir}/console.log"
        fi ;;
    *)
        { echo "Joined cluster (10.87.72.11:6443)"
          echo "=== keys-provision complete ==="; } > "${rundir}/console.log" ;;
esac
exit 0
EOF
cat > "${work}/keys-stub.sh" <<'EOF'
#!/usr/bin/env bash
: > "$2"
EOF
cat > "${work}/ssh-stub.sh" <<'EOF'
#!/usr/bin/env bash
argv="$*"
case "${argv}" in
    *"kubectl get nodes"*)
        n="${STUB_NODES:-3}"
        echo "hugmesh-mesh-cp   Ready      control-plane   2m    v1.30.0"
        [ "${n}" -ge 2 ] && echo "hugmesh-mesh-w2   NotReady   <none>          20s   v1.30.0"
        [ "${n}" -ge 3 ] && echo "hugmesh-mesh-w3   NotReady   <none>          10s   v1.30.0"
        exit 0 ;;
    *poweroff*) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "${work}/launch-stub.sh" "${work}/keys-stub.sh" "${work}/ssh-stub.sh"

run_driver() { # <run-subdir> [extra driver args...] (env overrides via caller export)
    local sub="$1"; shift
    HUGMESH_QEMU_MESH=1 \
    MESH_LAUNCH_CMD="bash ${work}/launch-stub.sh" \
    MESH_SSH_CMD="bash ${work}/ssh-stub.sh" \
    MESH_KEYS_CMD="bash ${work}/keys-stub.sh" \
    MESH_POLL_INTERVAL=1 MESH_VERIFY_INTERVAL=1 \
    STUB_CALLS="${work}/${sub}.calls" \
        bash "${HERE}/mesh-cluster.sh" --run-dir "${work}/${sub}" \
            -t 20 --join-timeout 5 "$@" 2>&1
}

: > "${work}/run-pass.calls"
out="$(run_driver run-pass)"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: PASS leg exits 0" || { bad "driver: PASS leg exited ${rc}"; echo "${out}" | tail -20 | sed 's/^/    | /' >&2; }
echo "${out}" | grep -q 'MESH-CLUSTER RESULT: PASS' && ok "driver: reports PASS" || bad "driver: PASS verdict missing"
[ "$(grep -c . "${work}/run-pass.calls")" -eq 3 ] && ok "driver: exactly 3 launcher calls" || bad "driver: launcher call count != 3"
[ "$(grep -c -- '--mesh-net 239.118.72.1:47301' "${work}/run-pass.calls")" -eq 3 ] \
    && ok "driver: every node joins the SAME shared L2" || bad "driver: nodes not on one L2 spec"
[ "$(grep -o -- '--mesh-mac [^ ]*' "${work}/run-pass.calls" | sort -u | wc -l)" -eq 3 ] \
    && ok "driver: 3 DISTINCT mesh MACs" || bad "driver: mesh MACs collide"
[ "$(grep -o -- '--ssh-port [^ ]*' "${work}/run-pass.calls" | sort -u | wc -l)" -eq 3 ] \
    && ok "driver: 3 DISTINCT ssh forwards" || bad "driver: ssh forwards collide"
head -1 "${work}/run-pass.calls" | grep -q -- 'node1-cp' \
    && ok "driver: control plane boots FIRST" || bad "driver: CP was not the first launch"

echo "== [driver] offline join material is CONSISTENT across the three KEYS payloads =="
cpj="${work}/run-pass/node1-cp/keys/provision.json"
w2j="${work}/run-pass/node2-worker/keys/provision.json"
w3j="${work}/run-pass/node3-worker/keys/provision.json"
cfg="${work}/run-pass/node1-cp/keys/kubernetes/kubeadm-config.yaml"
cacrt="${work}/run-pass/node1-cp/keys/kubernetes/pki/ca.crt"
grep -q '"first": true' "${cpj}" && ok "CP payload: kubernetes.first=true (init, never split-brain)" || bad "CP payload: first:true missing"
grep -q '"pki_dir": "kubernetes/pki"' "${cpj}" && ok "CP payload: shared-CA pki_dir staged" || bad "CP payload: pki_dir missing"
grep -q 'controlPlaneEndpoint: "10.87.72.11:6443"' "${cfg}" && ok "CP kubeadm-config: controlPlaneEndpoint = mesh IP" || bad "CP kubeadm-config: endpoint not the mesh IP"
grep -q 'advertiseAddress: 10.87.72.11' "${cfg}" && ok "CP kubeadm-config: advertises the mesh NIC (not slirp)" || bad "CP kubeadm-config: advertiseAddress missing"
grep -qE '^\s+- 10\.87\.72\.11$' "${cfg}" && ok "CP kubeadm-config: mesh IP in certSANs (joiners dial it)" || bad "CP kubeadm-config: mesh IP not a certSAN"
tok="$(sed -n 's/.*"token": "\([a-z0-9.]*\)".*/\1/p' "${w2j}" | head -1)"
[[ "${tok}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] && ok "worker payload: kubeadm-format pinned token" || bad "worker payload: token malformed: '${tok}'"
grep -q "token: \"${tok}\"" "${cfg}" && ok "pinned token: worker join == CP bootstrapTokens" || bad "pinned token: worker/CP token mismatch"
grep -q '"api_server": "10.87.72.11:6443"' "${w2j}" && grep -q '"api_server": "10.87.72.11:6443"' "${w3j}" \
    && ok "worker payloads: join api_server pinned to the CP mesh IP" || bad "worker payloads: api_server not pinned"
want_hash="sha256:$(openssl x509 -pubkey -noout -in "${cacrt}" 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
grep -q "\"ca_cert_hash\": \"${want_hash}\"" "${w2j}" \
    && ok "worker payload: ca_cert_hash == hash of the STAGED CA (recomputed here)" || bad "worker payload: ca_cert_hash does not match the staged CA"
grep -q 'mac-address=52:54:00:6d:65:02' "${work}/run-pass/node2-worker/keys/network/mesh0.nmconnection" \
    && grep -q 'address1=10.87.72.12/24' "${work}/run-pass/node2-worker/keys/network/mesh0.nmconnection" \
    && ok "worker payload: static mesh IP bound to the node's mesh MAC" || bad "worker payload: nmconnection MAC/IP wrong"
grep -q 'never-default=true' "${work}/run-pass/node2-worker/keys/network/mesh0.nmconnection" \
    && ok "worker payload: mesh NIC never steals the default route" || bad "worker payload: never-default missing"
grep -q '"enabled": false' "${w2j}" && ok "worker payload: headscale/tailscale off (phase-2 LAN cluster)" || bad "worker payload: mesh services unexpectedly on"

echo "== [driver] MUTATIONS: each gate must be able to FAIL the run =="
: > "${work}/run-joinfail.calls"
out="$(STUB_JOIN_FAIL=1 run_driver run-joinfail)"; rc=$?
[ "${rc}" -ne 0 ] && ok "driver: a failed join fails the run" || bad "MUTATION missed: join failure did not fail the driver"
echo "${out}" | grep -q 'node3-join' && ok "driver: NAMES the failed joiner" || bad "driver: failed joiner not named"

: > "${work}/run-short.calls"
out="$(STUB_NODES=2 run_driver run-short)"; rc=$?
[ "${rc}" -ne 0 ] && ok "driver: a missing registration fails the run" || bad "MUTATION missed: 2/3 nodes did not fail the driver"
echo "${out}" | grep -q 'node-count:2' && ok "driver: NAMES the node-count shortfall" || bad "driver: node-count shortfall not named"

echo "== [driver] NEGATIVE CONTROLS: staged regressions must go red =="
m="${work}/mut-driver-nogate.sh"
sed -e 's|"${HUGMESH_QEMU_MESH:-}" != "1"|1 -eq 0|' "${HERE}/mesh-cluster.sh" > "${m}"
if cmp -s "${m}" "${HERE}/mesh-cluster.sh"; then
    bad "control[drop-skip-gate]: sed matched nothing"
else
    out="$(HUGMESH_QEMU_MESH= \
        MESH_LAUNCH_CMD="bash ${work}/launch-stub.sh" \
        MESH_SSH_CMD="bash ${work}/ssh-stub.sh" \
        MESH_KEYS_CMD="bash ${work}/keys-stub.sh" \
        MESH_POLL_INTERVAL=1 MESH_VERIFY_INTERVAL=1 \
        STUB_CALLS="${work}/mut-nogate.calls" \
        bash "${m}" --run-dir "${work}/mut-nogate" -t 20 --join-timeout 5 2>&1)"
    echo "${out}" | grep -q 'SKIP' \
        && bad "control[drop-skip-gate]: mutant still SKIPs without the opt-in env" \
        || ok "control[drop-skip-gate]: removing the opt-in gate goes red (no SKIP)"
fi
m="${work}/mut-driver-commit.sh"
{ cat "${HERE}/mesh-cluster.sh"; echo 'qemu-img commit "${RUN_DIR}/node1-cp/launch/run.qcow2"'; } > "${m}"
no_commit "${m}" \
    && bad "control[plant-commit]: the no-commit pin missed a live qemu-img commit" \
    || ok "control[plant-commit]: a planted qemu-img commit turns the pin red"

echo "== [identity] ONE reader, shared by both lanes =="
bash -n "${HERE}/mesh-identities.sh" && ok "bash -n mesh-identities.sh" || bad "bash -n mesh-identities.sh"
for consumer in mesh-cluster.sh run-qemu-docker.sh; do
    grep -q '\. "${SCRIPT_DIR}/mesh-identities.sh"' "${HERE}/${consumer}" \
        && ok "${consumer}: sources the shared identity reader" \
        || bad "${consumer}: does not source mesh-identities.sh"
    # The parser must exist in ONE place. A second copy is how one lane comes to
    # accept a file shape the other rejects — with both claiming to read "the"
    # identity file.
    grep -q 'doc.get("devices")' "${HERE}/${consumer}" \
        && bad "${consumer}: carries its OWN copy of the identity parser" \
        || ok "${consumer}: has no parser of its own (one reader, not two)"
done
grep -c 'doc.get("devices")' "${HERE}/mesh-identities.sh" >/dev/null \
    && ok "mesh-identities.sh: is where the parser lives" || bad "mesh-identities.sh: no parser"
# Sourcing must be inert — it is pulled into two long-running drivers.
out="$(bash -c '. "'"${HERE}"'/mesh-identities.sh"; echo READY' 2>&1)"
[ "${out}" = "READY" ] && ok "mesh-identities.sh: sourcing it does nothing but define functions" \
    || bad "mesh-identities.sh: sourcing produced output/side effects: ${out}"

echo "== [driver] --identities: the PLANNER's file is the identity source =="
cat > "${work}/identities.json" <<'EOF'
[
  {"label": "rpi5/pki", "mac": "52:54:00:d0:a3:00", "ip": "10.77.0.11", "prefix_len": 24, "subnet": "10.77.0.0/24", "mesh_net": "239.118.72.67:47312"},
  {"label": "x86/be",   "mac": "52:54:00:d0:a3:01", "ip": "10.77.0.12", "prefix_len": 24, "subnet": "10.77.0.0/24", "mesh_net": "239.118.72.67:47312"},
  {"label": "x86/fe",   "mac": "52:54:00:d0:a3:02", "ip": "10.77.0.13", "prefix_len": 24, "subnet": "10.77.0.0/24", "mesh_net": "239.118.72.67:47312"}
]
EOF
out="$(bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/identities.json" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: --identities --dry-run exits 0" || bad "driver: --identities --dry-run exited ${rc}"
for want in 52:54:00:d0:a3:00 52:54:00:d0:a3:01 52:54:00:d0:a3:02 \
            10.77.0.11 10.77.0.12 10.77.0.13 239.118.72.67:47312; do
    echo "${out}" | grep -q "${want}" && ok "driver: plan carries the file's ${want}" \
        || bad "driver: ${want} from the identity file is missing from the plan"
done
for gone in 52:54:00:6d:65:01 10.87.72.11 239.118.72.1:47301; do
    echo "${out}" | grep -q "${gone}" \
        && bad "driver: built-in default ${gone} survived alongside the identity file" \
        || ok "driver: the built-in ${gone} is REPLACED, not merged"
done
# An explicit flag still beats the file — the operator on the command line is the
# last word, or --mesh-net would be a lie whenever an identity file is passed.
out="$(bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/identities.json" \
        --mesh-net 239.9.9.9:47399 2>&1)"
echo "${out}" | grep -q '239.9.9.9:47399' && ok "driver: an explicit --mesh-net still wins over the file" \
    || bad "driver: the file overrode an explicit --mesh-net"

echo "== [driver] --identities is OPT-IN: a flagless plan is BYTE-UNCHANGED =="
# This is the promise `make qemu-mesh` standalone depends on. The plan text is
# compared whole, not sampled: a default that drifted by one octet is exactly
# the kind of change a spot-check misses.
bash "${HERE}/mesh-cluster.sh" --dry-run > "${work}/plan-default.txt" 2>&1
grep -q '^NODE 1 cp     role=pki      hostname=hugmesh-mesh-cp  mac=52:54:00:6d:65:01 ip=10.87.72.11/24 ssh=2281 ' "${work}/plan-default.txt" \
    && ok "driver: the flagless plan still spells node1 exactly as it always did" \
    || bad "driver: the flagless node1 row changed"
grep -q 'shared L2 239.118.72.1:47301, subnet 10.87.72.0/24' "${work}/plan-default.txt" \
    && ok "driver: the flagless L2/subnet defaults are untouched" || bad "driver: flagless L2/subnet defaults changed"
grep -q 'identities: built-in table' "${work}/plan-default.txt" \
    && ok "driver: the flagless plan SAYS which identity source it used" || bad "driver: plan does not name its identity source"
for gone in 52:54:00:d0:a3:00 10.77.0.11 239.118.72.67:47312; do
    grep -q "${gone}" "${work}/plan-default.txt" \
        && bad "driver: identity-file value ${gone} leaked into a flagless plan" \
        || ok "driver: no identity-file value (${gone}) in a flagless plan"
done
# NEGATIVE CONTROL: default IDENTITIES on, and the leg above must go red.
m="${work}/mut-driver-identities.sh"
sed -e 's|^IDENTITIES=""$|IDENTITIES="'"${work}/identities.json"'"|' \
    "${HERE}/mesh-cluster.sh" > "${m}"
if cmp -s "${m}" "${HERE}/mesh-cluster.sh"; then
    bad "control[default-identities]: sed matched nothing"
else
    mout="$(bash "${m}" --dry-run 2>&1)"
    echo "${mout}" | grep -q '52:54:00:6d:65:01' \
        && bad "control[default-identities]: mutant still planned the built-in MACs" \
        || ok "control[default-identities]: defaulting the file ON turns the unchanged-plan leg red"
fi

echo "== [driver] --identities fails CLOSED on a file it cannot trust =="
printf '[{"label":"a","mac":"not-a-mac","ip":"10.77.0.11","prefix_len":24,"mesh_net":"239.1.1.1:1"}]\n' > "${work}/id-badmac.json"
out="$(bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/id-badmac.json" 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ok "driver: a malformed MAC is refused" || bad "driver: a malformed MAC was accepted"
echo "${out}" | grep -q 'not a MAC address' && ok "driver: says WHAT was wrong with the row" || bad "driver: refusal does not name the defect"
printf '[{"label":"a","mac":"53:54:00:00:00:01","ip":"10.77.0.11","prefix_len":24,"mesh_net":"239.1.1.1:1"}]\n' > "${work}/id-mcastmac.json"
bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/id-mcastmac.json" >/dev/null 2>&1 \
    && bad "driver: a multicast MAC was accepted from the file" || ok "driver: a multicast MAC in the file is refused"
head -3 "${work}/identities.json" | sed '$ s/,$//' > "${work}/id-short.json"; echo ']' >> "${work}/id-short.json"
out="$(bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/id-short.json" 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ok "driver: a file with fewer than 3 devices is refused" || bad "driver: a short identity file was accepted"
bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/nope.json" >/dev/null 2>&1 \
    && bad "driver: a missing identity file was accepted" || ok "driver: a missing identity file is refused"
printf '[{"label":"a","mac":"52:54:00:00:00:01","ip":"10.77.0.11","prefix_len":24,"mesh_net":"239.1.1.1:1"},\n {"label":"b","mac":"52:54:00:00:00:02","ip":"10.77.0.12","prefix_len":24,"mesh_net":"239.2.2.2:2"},\n {"label":"c","mac":"52:54:00:00:00:03","ip":"10.77.0.13","prefix_len":24,"mesh_net":"239.2.2.2:2"}]\n' > "${work}/id-2nets.json"
bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/id-2nets.json" >/dev/null 2>&1 \
    && bad "driver: rows on TWO different L2s were accepted as one cluster" \
    || ok "driver: rows naming different mesh_nets are refused (one cluster, one wire)"

echo "== [driver] hermetic end-to-end THROUGH the identity file =="
: > "${work}/run-ident.calls"
out="$(run_driver run-ident --identities "${work}/identities.json")"; rc=$?
[ "${rc}" -eq 0 ] && ok "driver: identities PASS leg exits 0" \
    || { bad "driver: identities leg exited ${rc}"; echo "${out}" | tail -20 | sed 's/^/    | /' >&2; }
[ "$(grep -c -- '--mesh-net 239.118.72.67:47312' "${work}/run-ident.calls")" -eq 3 ] \
    && ok "driver: all three launches join the FILE's L2" || bad "driver: launches not on the file's L2"
grep -q -- '--mesh-mac 52:54:00:d0:a3:00' "${work}/run-ident.calls" \
    && grep -q -- '--mesh-mac 52:54:00:d0:a3:02' "${work}/run-ident.calls" \
    && ok "driver: each launch carries its row's minted MAC" || bad "driver: minted MACs not passed to the launcher"
grep -q 'mac-address=52:54:00:d0:a3:01' "${work}/run-ident/node2-worker/keys/network/mesh0.nmconnection" \
    && grep -q 'address1=10.77.0.12/24' "${work}/run-ident/node2-worker/keys/network/mesh0.nmconnection" \
    && ok "driver: the KEYS profile binds the minted IP to the minted MAC" || bad "driver: nmconnection does not carry the minted identity"
grep -q 'controlPlaneEndpoint: "10.77.0.11:6443"' "${work}/run-ident/node1-cp/keys/kubernetes/kubeadm-config.yaml" \
    && ok "driver: the CP advertises the MINTED address the joiners will dial" || bad "driver: CP endpoint is not the minted address"
grep -q '"api_server": "10.77.0.11:6443"' "${work}/run-ident/node2-worker/keys/provision.json" \
    && ok "driver: the workers dial the minted CP address" || bad "driver: worker join target is not the minted address"

echo "== [fleet] run-qemu-docker.sh --mesh-net: the flags fail CLOSED =="
RUNNER="${HERE}/run-qemu-docker.sh"
bash -n "${RUNNER}" && ok "bash -n run-qemu-docker.sh" || bad "bash -n run-qemu-docker.sh"
runner_err() { bash "${RUNNER}" "$@" 2>&1; }
runner_err --mesh-net 239.1.1.1:47301 --identities "${work}/identities.json" | grep -q 'keep-alive lane' \
    && ok "fleet: --mesh-net without --keep-alive is refused" || bad "fleet: --mesh-net outside the keep-alive lane was accepted"
runner_err --keep-alive --mesh-net 239.1.1.1:47301 | grep -q 'needs --identities' \
    && ok "fleet: --mesh-net without --identities is refused (no identity is invented here)" \
    || bad "fleet: --mesh-net ran without an identity file"
runner_err --identities "${work}/identities.json" | grep -q 'does nothing without --mesh-net' \
    && ok "fleet: --identities alone is refused rather than silently ignored" || bad "fleet: --identities alone was accepted"
runner_err --keep-alive --mesh-net not-a-spec --identities "${work}/identities.json" | grep -q 'mesh-net wants' \
    && ok "fleet: a colon-less SPEC is refused before docker is touched" || bad "fleet: a bad SPEC was accepted"
grep -q -- '--network "${MESH_NET_NAME}"' "${RUNNER}" \
    && ok "fleet: device containers join the shared bridge" || bad "fleet: no --network on the device container"
grep -q -e '-e MESH_MAC=' "${RUNNER}" && grep -q -e '-e MESH_IP=' "${RUNNER}" \
    && ok "fleet: the row's identity is handed to the entrypoint" || bad "fleet: MESH_MAC/MESH_IP not forwarded"
grep -q 'mesh_args=()' "${RUNNER}" \
    && ok "fleet: the mesh additions live in ONE array (empty = unchanged docker run)" \
    || bad "fleet: mesh docker-run additions are not isolated in one array"
grep -q 'sweep_mesh_networks' "${RUNNER}" \
    && ok "fleet: --stop-all-devices sweeps mesh networks" || bad "fleet: no mesh-network sweep on stop-all"
grep -q 'mesh0.nmconnection' "${HERE}/docker-entrypoint.sh" \
    && ok "entrypoint: writes the static-IP profile into the KEYS payload" || bad "entrypoint: no KEYS network profile"
grep -q 'never-default=true' "${HERE}/docker-entrypoint.sh" \
    && ok "entrypoint: the mesh NIC never steals the default route (ssh/UI forwards intact)" \
    || bad "entrypoint: mesh profile may steal the default route"
grep -q '"mesh_ip"' "${HERE}/docker-entrypoint.sh" \
    && ok "entrypoint: the device record carries the live mesh address" || bad "entrypoint: record has no mesh address"

echo "== [fleet] the mesh BRIDGE lifecycle, against a fake docker =="
# The functions are lifted out of the runner and driven directly (devices_test.sh's
# technique): no daemon, no container, no image — just the create/attach/remove
# reasoning, which is the part that can quietly delete somebody else's network.
netfns="${work}/netfns.sh"; : > "${netfns}"
for fn in mesh_network_name own_network mesh_network_ensure mesh_network_members \
          sweep_mesh_networks; do
    sed -n "/^${fn}() {/,/^}/p" "${RUNNER}" >> "${netfns}"
    grep -q "^${fn}() {" "${netfns}" || bad "fleet: could not extract ${fn} from the runner"
done
fakedir="${work}/fakenet"; mkdir -p "${fakedir}/bin" "${fakedir}/state"
cat > "${fakedir}/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
S="${FAKE_NET_STATE:?}"
case "$1 ${2:-}" in
  "info ") exit 0 ;;
  "network create")
      shift 2; name=""; for a in "$@"; do name="${a}"; done
      [ -e "${S}/${name}" ] && exit 1
      echo "0" > "${S}/${name}"; echo "${name}" >> "${S}/.creates"; exit 0 ;;
  "network inspect")
      shift 2
      if [ "${1:-}" = "-f" ]; then fmt="$2"; name="$3"; else fmt=""; name="$1"; fi
      [ -f "${S}/${name}" ] || exit 1
      [ -n "${fmt}" ] && cat "${S}/${name}"
      exit 0 ;;
  "network ls") for f in "${S}"/*; do [ -f "${f}" ] || continue
                    case "$(basename "${f}")" in .*) continue ;; esac
                    basename "${f}"; done; exit 0 ;;
  "network rm") shift 2; rm -f "${S}/$1"; exit 0 ;;
  *) exit 0 ;;
esac
FAKEDOCKER
chmod +x "${fakedir}/bin/docker"
(
    MESH_NAME_PREFIX="hugmesh-qemu-mesh-"
    MESH_NET_LABEL="hugmesh-qemu-mesh=1"
    info() { :; }; warn() { :; }; die() { echo "$*" >&2; exit 1; }
    export FAKE_NET_STATE="${fakedir}/state"
    PATH="${fakedir}/bin:${PATH}"
    # shellcheck disable=SC1090
    source "${netfns}"

    n1="$(mesh_network_name 20260810-101010-mesh)"
    n1b="$(mesh_network_name 20260810-101010-mesh)"
    n2="$(mesh_network_name 20260811-999999-other)"
    [[ "${n1}" =~ ^hugmesh-qemu-mesh-[0-9a-f]{8}$ ]] && echo "OK name shape" || echo "BAD name shape: ${n1}"
    [ "${n1}" = "${n1b}" ] && echo "OK name deterministic" || echo "BAD name not deterministic"
    [ "${n1}" != "${n2}" ] && echo "OK two sessions, two wires" || echo "BAD two sessions share a wire"

    mesh_network_ensure "${n1}" && echo "OK ensure creates" || echo "BAD ensure failed"
    mesh_network_ensure "${n1}" && echo "OK ensure is idempotent" || echo "BAD second ensure failed"
    [ "$(grep -c . "${fakedir}/state/.creates" 2>/dev/null || echo 0)" -eq 1 ] \
        && echo "OK created exactly once" || echo "BAD created more than once"

    echo "1" > "${fakedir}/state/${n1}"          # one device attached
    sweep_mesh_networks
    [ -f "${fakedir}/state/${n1}" ] && echo "OK a network with members survives the sweep" \
        || echo "BAD swept a network that still had members"

    echo "0" > "${fakedir}/state/${n1}"          # last device gone
    # The operator's OWN network, ALSO empty: only the name test stands between
    # this sweep and disconnecting the live stack, so the fixture must not let a
    # member count take the credit.
    echo "0" > "${fakedir}/state/hugmesh-local_default"
    sweep_mesh_networks
    [ -f "${fakedir}/state/${n1}" ] && echo "BAD empty network survived the sweep" \
        || echo "OK the empty mesh network is removed"
    [ -f "${fakedir}/state/hugmesh-local_default" ] \
        && echo "OK a foreign network is NEVER removed" || echo "BAD swept a foreign network"
) > "${work}/netlife.txt" 2>&1
while IFS= read -r line; do
    case "${line}" in
        OK*)  ok "bridge: ${line#OK }" ;;
        BAD*) bad "bridge: ${line#BAD }" ;;
    esac
done < "${work}/netlife.txt"

echo "== [contract] the PLANNER mints the file the driver CONSUMES =="
# The cross-language half of "one identity source": python writes the file, bash
# reads it. Pinning each side separately would let the two drift on the shape of
# the very thing they share.
if command -v python3 >/dev/null 2>&1; then
    gen="${work}/gen"; sess="${gen}/out/sessions/20260810-101010-mesh"
    mkdir -p "${sess}"
    for n in hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz \
             hugmesh-x86-amd64-be-test-20260807T172418Z.img \
             hugmesh-x86-amd64-fe-test-20260807T172419Z.img; do : > "${sess}/${n}"; done
    if PYTHONPATH="${REPO}/studio" python3 -m hugmesh_studio.core.mesh_emulation \
            identities --generator-dir "${gen}" --session 20260810-101010-mesh \
            --out "${work}/planned.json" >/dev/null 2>&1; then
        ok "planner: minted an identity file for the session"
        pmac="$(sed -n 's/.*"mac": "\([^"]*\)".*/\1/p' "${work}/planned.json" | head -1)"
        pip="$(sed -n 's/.*"ip": "\([^"]*\)".*/\1/p' "${work}/planned.json" | head -1)"
        pnet="$(sed -n 's/.*"mesh_net": "\([^"]*\)".*/\1/p' "${work}/planned.json" | head -1)"
        out="$(bash "${HERE}/mesh-cluster.sh" --dry-run --identities "${work}/planned.json" 2>&1)"
        echo "${out}" | grep -q "${pmac}" && ok "contract: the driver plans the MAC the planner minted (${pmac})" \
            || bad "contract: the driver did not use the planner's MAC"
        echo "${out}" | grep -q "${pip}" && ok "contract: ...and its IP (${pip})" || bad "contract: the driver did not use the planner's IP"
        echo "${out}" | grep -q "${pnet}" && ok "contract: ...on the L2 the planner chose (${pnet})" || bad "contract: the driver did not use the planner's L2"
        # Determinism is what makes a re-boot rejoin the same wire at the same
        # address; a re-mint that reshuffles would be a new mesh every time.
        PYTHONPATH="${REPO}/studio" python3 -m hugmesh_studio.core.mesh_emulation \
            identities --generator-dir "${gen}" --session 20260810-101010-mesh \
            --out "${work}/planned2.json" >/dev/null 2>&1
        cmp -s "${work}/planned.json" "${work}/planned2.json" \
            && ok "contract: replanning the same session mints the SAME identities" \
            || bad "contract: identities reshuffle between plans"
    else
        bad "planner: python3 -m hugmesh_studio.core.mesh_emulation identities failed"
    fi
else
    echo "  note: python3 absent — the planner/driver contract legs did not run"
fi

echo "== [wiring] make targets + CI + check.sh =="
grep -qE '^qemu-mesh:' "${REPO}/Makefile" && ok "Makefile: qemu-mesh target" || bad "Makefile: qemu-mesh target missing"
grep -qE '^qemu-mesh-enumerate:' "${REPO}/Makefile" && ok "Makefile: qemu-mesh-enumerate target" || bad "Makefile: qemu-mesh-enumerate target missing"
sed -n '/^qemu-mesh:/,/^$/p' "${REPO}/Makefile" | grep -q 'tests/qemu/mesh-cluster.sh' \
    && ok "Makefile: qemu-mesh drives tests/qemu/mesh-cluster.sh" || bad "Makefile: qemu-mesh recipe wrong"
sed -n '/^qemu-mesh-enumerate:/,/^$/p' "${REPO}/Makefile" | grep -q -- '--dry-run' \
    && ok "Makefile: qemu-mesh-enumerate is the --dry-run lane" || bad "Makefile: enumerate recipe lacks --dry-run"
grep -qE '^\s+.*\bqemu-mesh qemu-mesh-enumerate\b' "${REPO}/Makefile" \
    && ok "Makefile: both targets are .PHONY" || bad "Makefile: qemu-mesh targets not in the .PHONY list"
grep -qE '^lint:qemu-mesh-cluster:' "${REPO}/.gitlab-ci.yml" \
    && ok "CI: lint:qemu-mesh-cluster job exists" || bad "CI: lint:qemu-mesh-cluster job missing"
grep -q 'tests/qemu/mesh-cluster_test.sh' "${REPO}/.gitlab-ci.yml" \
    && ok "CI: the job runs this gate" || bad "CI: gate not wired into the job"
grep -q 'qemu-mesh-cluster:.*mesh-cluster_test.sh' "${REPO}/tests/build-matrix/check.sh" \
    && ok "check.sh: gate registered in the smoke walk" || bad "check.sh: gate not registered"

echo
echo "== mesh-cluster gate: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
