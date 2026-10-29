# ISSUES hugmesh-generator#512, #513 and #514 — the three execution phases of
# "K8s working on a QEMU-emulated node device — and multiple emulated nodes
# forming a cluster" (#48 box 2):
#   phase 1  (#512) one emulated pki node: kubeadm init completes, 1 node Ready
#   phase 2  (#513) HUGMESH_QEMU_MESH=1 tests/qemu/mesh-cluster.sh -w out:
#                   3 registered nodes over the host-local shared L2
#   phase 3  (#514) the same three nodes over headscale/tailscale MagicDNS with
#                   a reusable pre-auth key
#
# NOTHING HERE BOOTS A VM. The runners refuse to be the thing that starts an
# environment (steps/runners.ts), and a 3-node emulated boot is hours on a
# shared box. Each phase is a one-time, operator-run milestone (decision 16 on
# #347) whose "done when" is a RUN DIRECTORY with a named verdict. So the
# @fixme scenarios below are EVIDENCE READERS: they open the newest run
# directory the driver left under out/qemu-runs/ and grade exactly the
# artefacts the driver writes — `kubectl-get-nodes.txt`, per-node
# `launch/console.log`, `keys/provision.json` — against the markers the driver
# itself gates on. They are red today because, measured on origin/main
# @9f4d6d30, `out/qemu-runs/mesh/` does not exist and the only pki runs on
# disk logged "K8s config staged; skipping live bootstrap". They go green the
# day the operator's run lands, unmodified. They carry no @env:qemu on
# purpose: reading a run directory needs no booted device answering :8443,
# and gating on one would hide a finished run behind an unrelated skip.
#
# The markers are the driver's own (mesh-cluster.sh --dry-run prints them) and
# provision.sh's (`tailscale up succeeded`, `Published MagicDNS CP record`), so
# a driver that changes its contract changes the dry-run scenario first.
@interface:cli
Feature: the emulated k8s cluster phases leave run directories a terminal can grade

  # Baseline, green today: the driver plans three nodes and names the markers it
  # gates on, with no root, no boot, no keys.
  @issue:generator-513
  Scenario: the mesh driver plans three nodes and the markers it gates on without booting anything
    When I run the shell command "tests/qemu/mesh-cluster.sh --dry-run"
    Then the command succeeded
    And the command output contains "RESULT:  DRY-RUN planned 3 nodes (nothing booted)"
    And the command output contains "'Running kubeadm init' -> 'First control plane initialised' -> '=== keys-provision complete ==='"
    And the command output contains "workers='Joined cluster (' (fail: 'kubeadm join failed against')"
    And the command output contains "kubectl get nodes lists 3 registered nodes"

  # A skip is not a pass. Without the opt-in the driver must say so on stdout
  # in the same RESULT: shape as a verdict — the survey that graded this box
  # done on a commit was wrong for exactly this reason.
  @issue:generator-513
  Scenario: without the opt-in the mesh driver reports a machine-readable skip and boots nothing
    When I run the shell command "tests/qemu/mesh-cluster.sh"
    Then the command succeeded
    And the command output contains "RESULT:  SKIP reason=no-opt-in"
    And the command output contains "NOTHING WAS BOOTED OR ASSERTED"
    And the command output does not contain "MESH-CLUSTER RESULT: PASS"

  # Phase 1. The kubeadm-init half is graded from the serial markers the issue
  # names. The "1 node Ready" half needs a CNI-without-internet decision
  # (sibling child) AND a driver artefact carrying `kubectl get nodes` for a
  # single-node run — the pki matrix runs collect keys-provision.log but no
  # node listing — so it is NOT asserted here rather than asserted against an
  # artefact nothing writes.
  @issue:generator-512 @fixme
  Scenario: the newest emulated pki run reached kubeadm init and completed provisioning
    When I run the shell script:
      """
      set -euo pipefail
      run="$(ls -1dt out/qemu-runs/runs/*pki*/ 2>/dev/null | head -1)"
      [ -n "$run" ] || { echo "no pki run directory under out/qemu-runs/runs/"; exit 3; }
      echo "run=$run"
      log="$run/guest_var_log_keys-provision.log"
      [ -f "$log" ] || { echo "no guest_var_log_keys-provision.log in $run"; exit 3; }
      for m in 'Running kubeadm init' 'First control plane initialised' '=== keys-provision complete ==='; do
        if grep -aF -- "$m" "$log" >/dev/null; then echo "marker-ok: $m"; else echo "marker-missing: $m"; fi
      done
      if grep -aF 'kubeadm init failed' "$log" >/dev/null; then echo "kubeadm-init: failed"; else echo "kubeadm-init: clean"; fi
      if grep -aF 'skipping live bootstrap' "$log" >/dev/null; then echo "bootstrap: skipped"; else echo "bootstrap: ran"; fi
      """
    Then the command succeeded
    And the command output contains "marker-ok: Running kubeadm init"
    And the command output contains "marker-ok: First control plane initialised"
    And the command output contains "marker-ok: === keys-provision complete ==="
    And the command output does not contain "marker-missing"
    And the command output contains "kubeadm-init: clean"
    And the command output contains "bootstrap: ran"

  # Phase 2. The driver's own gate: 3 registered nodes (Ready is reported, not
  # gated — it needs the CNI decision), both joiners logged a clean join.
  @issue:generator-513 @fixme
  Scenario: the newest 3-node mesh run registered all three nodes and both joiners logged a clean join
    When I run the shell script:
      """
      set -euo pipefail
      run="$(ls -1dt out/qemu-runs/mesh/*/ 2>/dev/null | head -1)"
      [ -n "$run" ] || { echo "no run directory under out/qemu-runs/mesh/ — HUGMESH_QEMU_MESH=1 tests/qemu/mesh-cluster.sh -w out has never produced one"; exit 3; }
      echo "run=$run"
      nodes="$run/kubectl-get-nodes.txt"
      [ -f "$nodes" ] || { echo "no kubectl-get-nodes.txt in $run"; exit 3; }
      echo "registered=$(grep -acE '^[[:alnum:]]' "$nodes" || true)"
      for n in 2 3; do
        c="$(ls -1d "$run"/node${n}-*/launch/console.log 2>/dev/null | head -1)"
        [ -f "$c" ] || { echo "node$n: no console.log"; exit 3; }
        if grep -aF 'Joined cluster (' "$c" >/dev/null; then echo "node$n: joined"; else echo "node$n: not-joined"; fi
        if grep -aF 'kubeadm join failed against' "$c" >/dev/null; then echo "node$n: join-failed"; else echo "node$n: join-clean"; fi
      done
      """
    Then the command succeeded
    And the command output contains "registered=3"
    And the command output contains "node2: joined"
    And the command output contains "node3: joined"
    And the command output contains "node2: join-clean"
    And the command output contains "node3: join-clean"

  # Phase 3. Same run-directory shape, different transport: the node1 KEYS
  # payload must have headscale+tailscale ENABLED (phase 2 writes both false),
  # every node must have joined the tailnet, and the control plane must have
  # published its MagicDNS record — provision.sh's own log lines.
  @issue:generator-514 @fixme
  Scenario: the newest mesh run formed over headscale and tailscale MagicDNS rather than the host-local L2
    When I run the shell script:
      """
      set -euo pipefail
      run="$(ls -1dt out/qemu-runs/mesh/*/ 2>/dev/null | head -1)"
      [ -n "$run" ] || { echo "no run directory under out/qemu-runs/mesh/"; exit 3; }
      echo "run=$run"
      pj="$(ls -1d "$run"/node1-*/keys/provision.json 2>/dev/null | head -1)"
      [ -f "$pj" ] || { echo "node1: no keys/provision.json"; exit 3; }
      python3 -c 'import json,sys
      m = json.load(open(sys.argv[1]))
      print("headscale=%s" % str(m.get("headscale", {}).get("enabled")).lower())
      print("tailscale=%s" % str(m.get("tailscale", {}).get("enabled")).lower())' "$pj"
      echo "registered=$(grep -acE '^[[:alnum:]]' "$run/kubectl-get-nodes.txt" || true)"
      for n in 1 2 3; do
        c="$(ls -1d "$run"/node${n}-*/launch/console.log 2>/dev/null | head -1)"
        [ -f "$c" ] || { echo "node$n: no console.log"; exit 3; }
        if grep -aF 'tailscale up succeeded' "$c" >/dev/null; then echo "node$n: tailnet-joined"; else echo "node$n: tailnet-missing"; fi
      done
      c1="$(ls -1d "$run"/node1-*/launch/console.log | head -1)"
      if grep -aF 'Published MagicDNS CP record' "$c1" >/dev/null; then echo "magicdns: cp-record-published"; else echo "magicdns: cp-record-missing"; fi
      """
    Then the command succeeded
    And the command output contains "headscale=true"
    And the command output contains "tailscale=true"
    And the command output contains "registered=3"
    And the command output contains "node1: tailnet-joined"
    And the command output contains "node2: tailnet-joined"
    And the command output contains "node3: tailnet-joined"
    And the command output contains "magicdns: cp-record-published"
