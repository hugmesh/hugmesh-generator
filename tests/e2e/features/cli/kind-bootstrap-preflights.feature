# ISSUES hugmesh-generator#510 and #529 — two states in which bootstrap-kind.sh
# takes its "already exists — reusing it" branch and walks into a bring-up that
# cannot converge, saying nothing:
#
#   #510  the node's OWN resolver times out (2026-09-09: every ImagePullBackOff
#         and every ComparisonError was downstream of `lookup quay.io on
#         172.18.0.1:53: i/o timeout`). Measured on origin/main@9f4d6d30:
#         `grep -n 'getent hosts' bootstrap-kind.sh` -> no match. The existing
#         egress preflight (1b) is a raw TCP connect to literal addresses — by
#         design it does NOT resolve anything inside the node, so it is green on
#         exactly this failure.
#   #529  the lane was HALTED (`make kind-halt`: every Application's auto-sync
#         removed, every workload at 0). The cluster answers, so the reuse
#         branch proceeds; `kubectl -n vault wait … pod/vault-0 || true` cannot
#         succeed and does not stop the run. Nothing anywhere says "halted".
#         Measured: `grep -n 'hugmesh-kind-halt\|kind-resume' bootstrap-kind.sh`
#         -> no match.
#
# HOW THESE ARE PROVEN WITH NO CLUSTER. kind/docker/kubectl STUBS on PATH
# (steps/cli.steps.ts) answer "the cluster exists", satisfy the raw-TCP egress
# preflight, and break exactly one thing: every in-node NAME LOOKUP fails like a
# real dead resolver (no output, exit 2), or a `hugmesh-kind-halt` ConfigMap is
# present in devops. Every kubectl call is recorded, so "before it waits on
# anything" is an assertion, not a hope. The stub prints neither the word
# "resolver" nor an address itself: `cat /etc/resolv.conf` inside the stub node
# answers `nameserver 172.18.0.1` (docker's embedded DNS on the kind network) and
# that is the only place the bring-up can learn it from. The name asserted,
# quay.io, is the one the parent's plan names verbatim ("docker exec … getent
# hosts quay.io").
#
# A pre-fix bring-up does not fail closed: it walks past the missing preflight
# into its wait loops and is killed by the runner's timeout. The transcript
# records that as a SIGNAL, and `the command exited with a non-zero code`
# refuses to read a kill as a refusal — so these cannot pass by accident.
@interface:cli
Feature: bootstrap-kind.sh fails closed on a broken in-node resolver and on a halted lane, before it waits on anything

  # Baseline, green today: the bring-up already refuses states it cannot
  # proceed through, naming the legal set, with no cluster in sight.
  Scenario: the bring-up refuses an unknown profile naming the legal set, with no cluster
    When I run the shell command "KIND_PROFILE=bogus bash specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
    Then the command exit code was 1
    And the command output contains "KIND_PROFILE must be 'core' or 'sso'"

  # The offline honesty guard #510 and #511 both name as the pin for this file.
  # #510's "done when" adds a case that goes red if the DNS preflight is removed
  # or made advisory; a case's NAME is not asserted here (that is the guard's
  # own business) — that the guard is green with no cluster is.
  @issue:generator-511 @issue:generator-510
  Scenario: the kind bootstrap honesty guard is green with no cluster
    When I run the shell command "bash tests/scripts/test-kind-bootstrap-honesty.sh" allowing 10 minutes
    Then the command succeeded
    And the command output contains "0 failed"

  # #510 is fixed on main (issue closed 2026-10-15): the bring-up now refuses
  # here, so this runs un-fixme'd. #529 below is still open and stays @fixme.
  @issue:generator-510
  Scenario: a node whose resolver cannot resolve refuses, naming the resolver and the name, before anything waits
    Given a stub kind node on PATH whose resolver cannot resolve any name
    When I run the kind bootstrap against the stub node
    Then the command exited with a non-zero code
    And the command output contains "quay.io"
    And the command output contains "172.18.0.1"
    And the stub node recorded no mutating or waiting kubectl call

  @issue:generator-529 @fixme
  Scenario: a bring-up over a halted lane refuses and names make kind-resume instead of walking into a reuse that cannot converge
    Given a stub kind node on PATH carrying a halt record
    When I run the kind bootstrap against the stub node
    Then the command exited with a non-zero code
    And the command output contains "kind-resume"
    And the stub node recorded no mutating or waiting kubectl call
