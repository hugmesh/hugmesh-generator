# ISSUES hugmesh-generator#511 and #528 — the kind DevOps lane on the REAL
# cluster, read and driven from a terminal. Every scenario here needs the
# cluster answering, so the file is @env:kind and availability-gated: with no
# cluster the Before hook skips each scenario naming `make kind-images && make
# kind-up`. Nothing here starts a cluster — bringing one up is the operator's
# action, and `make kind-up` is exactly the kind of command this suite's
# runners refuse to be the thing that runs (steps/runners.ts).
#
#   #511  "reach a fully Synced and Healthy cluster". Across four looks the
#         cluster failed four different ways; the box's own word, "totally
#         working", has never been true. The scenarios assert the converged
#         state the issue's "done when" names — EVERY Application in devops
#         Synced AND Healthy, EVERY ExternalSecret SecretSynced — and carry
#         @fixme while the two standing reds (#352 external-secrets-config,
#         #354 harbor) are open. The issue permits "a remaining red named with
#         its own issue"; this file does not encode an allowlist for it,
#         because an allowlist is where a third red hides. When those close,
#         drop @fixme and the pin holds.
#   #528  "Manual test: the halt/resume round trip on the real cluster". The
#         pair ships in PR #489, proven against fakes and one write-blocked
#         run; nobody has pressed the button. The round trip MUTATES the shared
#         lane, so it runs ONLY when a person opts in with SNAP_KIND_MUTATE=1
#         and skips loudly otherwise — this is "run the existing automation and
#         read its output", which is what the Manual label asks a person to do:
#           SNAP_KIND_MUTATE=1 bash tests/e2e/run.sh --bdd --env kind --tags '@issue:generator-528'
#         It is NOT @fixme: nothing is known to be broken, it is untested.
#
# Two things the issue lists that this file does not do: the GUI's Halt/Resume/
# Delete buttons (a Studio-interface walk, not a terminal's), and timing how
# long the resume takes to settle (write it down when you run it).
@interface:cli @env:kind
Feature: the kind DevOps lane, read and driven from a terminal against the real cluster

  # Read-only, whichever state the lane is in: the control answers 0 both
  # ways and is REFUSED (exit 5) only when it cannot READ the record — an
  # errored read is not an absent record.
  @issue:generator-528
  Scenario: the halt control answers read-only whether or not the lane is halted
    When I run the shell command "make kind-halt-status"
    Then the command succeeded
    And the command output contains "halted"
    And the command output does not contain "REFUSED"

  @issue:generator-511 @fixme
  Scenario: every Application in devops is Synced and Healthy
    When I run the shell script:
      """
      set -euo pipefail
      kubectl --context kind-hugmesh-local -n devops get applications \
        -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}'
      """
    Then the command succeeded
    And every non-empty line of the command's stdout matches "=Synced/Healthy$"

  @issue:generator-511 @fixme
  Scenario: every ExternalSecret in the cluster reports SecretSynced
    When I run the shell script:
      """
      set -euo pipefail
      kubectl --context kind-hugmesh-local get externalsecrets -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.conditions[?(@.type=="Ready")].reason}{"\n"}{end}'
      """
    Then the command succeeded
    And every non-empty line of the command's stdout matches "=SecretSynced$"

  # The whole "what to run, in order" block of #528, with the issue's expected
  # substrings, plus its two sharpest checks: no workload in a floor namespace
  # was scaled, and Vault comes back UNSEALED after the resume (its auto-unseal
  # sidecar surviving a scale-to-0 was read from the spec, never exercised).
  @issue:generator-528
  Scenario: halting and resuming the lane round-trips: the record names what it suspended, the floor is untouched, Vault comes back unsealed
    Given this scenario mutates the "kind" lane and the operator opted in with "SNAP_KIND_MUTATE=1"
    When I run the shell command "make kind-halt-status"
    Then the command succeeded
    And the command output contains "is NOT halted by this control"
    When I run the shell command "make kind-halt" allowing 15 minutes
    Then the command succeeded
    And the command output contains "Suspended"
    When I run the shell command "make kind-halt-status"
    Then the command succeeded
    And the command output contains "is HALTED"
    And the command output contains "ArgoCD auto-sync SUSPENDED by this halt"
    And the command output contains "Workloads scaled to 0 by this halt"
    And the command output contains "Resume with:  make kind-resume"
    When I run the shell script:
      """
      set -euo pipefail
      # Every workload the record says THIS halt scaled (skipped == null), one per line,
      # so a scaled row in kube-system / kyverno / local-path-storage / devops is a red line.
      kubectl --context kind-hugmesh-local -n devops get configmap hugmesh-kind-halt -o jsonpath='{.data.halt\.json}' \
        | python3 -c 'import json,sys
      r = json.load(sys.stdin)
      rows = [w for w in r["workloads"] if w.get("skipped") is None]
      print("scaled-total %d" % len(rows))
      for w in rows:
          print("scaled %s %s %s" % (w["namespace"], w["kind"], w["name"]))'
      """
    Then the command succeeded
    And every non-empty line of the command's stdout matches "^scaled(-total [1-9][0-9]*| (?!kube-system |kyverno |local-path-storage |devops ))"
    When I run the shell command "make kind-resume" allowing 20 minutes
    Then the command succeeded
    When I run the shell command "make kind-halt-status"
    Then the command succeeded
    And the command output contains "is NOT halted by this control"
    When I run the shell script allowing 5 minutes:
      """
      set -euo pipefail
      # `vault status` exits 2 while sealed, so with -e a sealed Vault fails this step on its own;
      # the printed line makes the reason legible in the transcript.
      kubectl --context kind-hugmesh-local -n vault exec vault-0 -- vault status -format=json \
        | python3 -c 'import json,sys; print("vault sealed=%s" % str(json.load(sys.stdin)["sealed"]).lower())'
      """
    Then the command succeeded
    And the command output contains "vault sealed=false"
