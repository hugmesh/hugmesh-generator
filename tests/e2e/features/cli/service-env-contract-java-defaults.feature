# ISSUE hugmesh-generator#507 (finding 26 of docs/KIND-SSO-E2E-FINDINGS.md) —
# "lint:service-env-contract has a structural blind spot". A property whose
# yaml default is EMPTY can still resolve to a hardcoded stale host in JAVA:
# that is exactly how admin-bff's SessionExchangeConfig.DEFAULT_SELF_HOST
# (pre-rebrand, NXDOMAIN) survived the gate and 503'd every /bff/session. The
# blind spot was structural: the CI job sparse-checked `src/main/resources`
# only, so `src/main/java` was never on disk for the checker to read.
#
# CLOSED. The checker now reads src/main/java too ([java-default] in
# tests/scripts/service_env_contract.py; the rules are J1/J2 in
# tests/scripts/service_env_defaults.py), the CI job fetches it, and a service tree
# without it is INCOMPLETE (rc 3), never a quiet pass. Its first run found two REAL
# stale Java defaults in PhoneLockProperties (namespaces `hmdm` and `headscale`, which
# have never existed here), now pinned in the admin-bff Deployment.
#
# The second scenario stages the defect's exact shape into a COPY of the service
# sources (as the gate's own negative controls do — the real checkouts are never
# written) and runs the real checker over it. Its assertions name the artefacts a
# Java-aware checker reports: the stale host it found and the file it found it in.
# The checker resolves service sources from SERVICE_SRC_ROOT, else the siblings of
# this repo (CI clones them). In a linked `git worktree` the siblings are the ones
# beside the MAIN checkout, and the checker looks there last; a COPY of a worktree
# (no back-pointer from git's worktree metadata) gets no such fallback and stays
# INCOMPLETE.
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

  Scenario: a Java DEFAULT_SELF_HOST behind an empty yaml default goes red, naming the file and the stale host
    When I run the shell script:
      """
      set -euo pipefail
      # Resolve the service sources BY ASKING THE CHECKER, so SERVICE_SRC_ROOT,
      # .service-src and a worktree's siblings all resolve exactly as it does.
      src="$( { python3 tests/scripts/service_env_contract.py specs/cluster 2>/dev/null || true; } \
        | sed -n 's/^  --   service sources: \(.*\) (.*$/\1/p' | head -1)"
      [ -n "$src" ] && [ -d "$src" ] || { echo "the checker resolved no service-source tree (set SERVICE_SRC_ROOT)"; exit 3; }
      staged="$HUGMESH_BDD_SCRATCH/service-src"
      n=0
      for y in "$src"/hugmesh-*/src/main/resources/application.yml; do
        [ -f "$y" ] || continue
        repo="$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$y")")")")")"
        mkdir -p "$staged/$repo/src/main/resources"
        cp "$y" "$staged/$repo/src/main/resources/application.yml"
        # the checker reads src/main/java too and refuses a tree without it (INCOMPLETE)
        main="$(dirname "$(dirname "$y")")"
        [ -d "$main/java" ] && cp -r "$main/java" "$staged/$repo/src/main/java"
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
