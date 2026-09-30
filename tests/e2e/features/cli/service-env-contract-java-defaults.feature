# ISSUE hugmesh-generator#507 (finding 26 of docs/KIND-SSO-E2E-FINDINGS.md) —
# "lint:service-env-contract has a structural blind spot". A property whose
# yaml default is EMPTY can still resolve to a hardcoded stale host in JAVA:
# that is exactly how admin-bff's SessionExchangeConfig.DEFAULT_SELF_HOST
# (pre-rebrand, NXDOMAIN) survived the gate and 503'd every /bff/session. The
# blind spot is structural: the CI job sparse-checks `src/main/resources` only,
# so `src/main/java` is never on disk for the checker to read. Measured on
# origin/main@9f4d6d30: `grep -n 'src/main/java\|\.java' tests/scripts/
# service_env_contract.py tests/scripts/service_env_defaults.py` -> no match.
#
# Findings 20 (Playwright apiRequestContext ignores --host-resolver-rules) and
# 25 (four non-Spring callers never got the mTLS wave) are the same card but
# are fixes to the harness and to test-job TLS plumbing with no persona-facing
# or terminal-facing acceptance shape; they are not covered here.
#
# The @fixme scenario stages the defect's exact shape into a COPY of the
# service sources (as the gate's own negative controls do — the real checkouts
# are never written) and runs the real checker over it. Its assertions name
# the artefacts a Java-aware checker would report: the stale host it found and
# the file it found it in. The checker resolves service sources from
# SERVICE_SRC_ROOT, else the siblings of this repo (CI clones them; a worktree
# has no siblings, so set SERVICE_SRC_ROOT there).
@interface:cli @issue:generator-507
Feature: the service env-contract gate sees a stale Java hardcode hiding behind an empty yaml default

  # Baseline, green today: the committed cluster tree satisfies the contract
  # against the real first-party service sources. INCOMPLETE (rc 3, sources
  # not found) is a FAIL here by the checker's own design.
  Scenario: the checker is green over the committed cluster tree and the first-party service sources
    When I run the shell command "python3 tests/scripts/service_env_contract.py specs/cluster"
    Then the command succeeded
    And the command output contains "0 failed"
    And the command output does not contain "INCOMPLETE"

  @fixme
  Scenario: a Java DEFAULT_SELF_HOST behind an empty yaml default goes red, naming the file and the stale host
    When I run the shell script:
      """
      set -euo pipefail
      # Resolve the service sources the way the checker itself does.
      src="${SERVICE_SRC_ROOT:-$(dirname "$HUGMESH_BDD_REPO_ROOT")}"
      staged="$HUGMESH_BDD_SCRATCH/service-src"
      n=0
      for y in "$src"/hugmesh-*/src/main/resources/application.yml; do
        [ -f "$y" ] || continue
        repo="$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$y")")")")")"
        mkdir -p "$staged/$repo/src/main/resources"
        cp "$y" "$staged/$repo/src/main/resources/application.yml"
        n=$((n + 1))
      done
      [ "$n" -gt 0 ] || { echo "no first-party service sources under $src (set SERVICE_SRC_ROOT)"; exit 3; }
      [ -d "$staged/hugmesh-admin-bff-api" ] || { echo "hugmesh-admin-bff-api is not among the staged sources"; exit 3; }
      # Finding 26's exact shape: the yaml default is EMPTY, the Java fallback is a
      # stale in-cluster FQDN naming a namespace this cluster has never had.
      cat >> "$staged/hugmesh-admin-bff-api/src/main/resources/application.yml" <<'YAML'

federation-session-exchange:
  self-host: "${FEDERATION_SESSION_EXCHANGE_SELF_HOST:}"
YAML
      j="$staged/hugmesh-admin-bff-api/src/main/java/net/hugmesh/adminbff/federation"
      mkdir -p "$j"
      cat > "$j/SessionExchangeConfig.java" <<'JAVA'
package net.hugmesh.adminbff.federation;

/** Fixture for finding 26: an empty yaml default (federation-session-exchange.self-host) falls back to a stale host here. */
public class SessionExchangeConfig {
    private static final String DEFAULT_SELF_HOST =
            "hugmesh-admin-bff-api.hugmesh-nowhere.svc.cluster.local";
    private final String selfHost;
    public SessionExchangeConfig(String selfHost) { this.selfHost = selfHost; }
    public String selfHost() {
        return (selfHost == null || selfHost.isBlank()) ? DEFAULT_SELF_HOST : selfHost;
    }
}
JAVA
      echo "staged=$n repos under $staged"
      SERVICE_SRC_ROOT="$staged" python3 tests/scripts/service_env_contract.py specs/cluster
      """
    Then the command exited with a non-zero code
    And the command output does not contain "INCOMPLETE"
    And the command output contains "hugmesh-admin-bff-api.hugmesh-nowhere.svc.cluster.local"
    And the command output contains "SessionExchangeConfig.java"
