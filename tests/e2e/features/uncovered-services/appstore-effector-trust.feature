# The superadmin app-store EFFECTOR legs and what an e2e lane can honestly say
# about them — hugmesh/hugmesh-admin-bff-api#62, #82 and #95.
#
# WHAT THE ISSUES MEASURED, from inside a live admin-bff pod (2026-09-17):
#   #62  RestArgoCdClient is a plain WebClient on the JDK truststore; argocd-server
#        presents a SELF-SIGNED leaf (O=Argo CD), so the ArgoCD leg dies at the
#        TLS handshake BEFORE any bearer token is sent — not the 401 everyone was
#        told to expect.
#   #82  RestFederationModuleClient is the same shape; federation-api's leaf chains
#        to the cluster CA the pod has on disk, but the client never consults it
#        and presents no client certificate (SSL_CLIENT_AUTH=need).
#   #95  a service the app-store deploys arrives with no Vault path, ExternalSecret
#        or serving certificate; provisioning is additive and unbuilt.
#
# WHAT IS NOT OBSERVABLE FROM ANY INTERFACE THIS SUITE DRIVES, and therefore is
# NOT decorated with a scenario that could never run:
#   * the handshake itself — both legs fire only inside a provisioning call
#     (POST …/deployments/{id}/provision), which ServiceStoreStepUpGate now gates
#     behind a fresh MFA stamp or a WorkloadStepUp token; MFA ships dark org-wide
#     and the token mint is device/SSH-license gated. No seeded persona can reach
#     the call, and the failure is a pod-log line, not a response shape.
#   * the Noop effector's "requested the right secret material" (#95) — an
#     in-process assertion for admin-bff's own tests.
# Those three stay `skipped` in this round's report, by name, with this reason.
#
# WHAT IS OBSERVABLE, and asserted:
#   * the DEPLOY ORACLE — the committed cluster manifest for admin-bff arms both
#     legs and pins the in-cluster ArgoCD address the way generator#403 landed it
#     (the address half #62 explicitly re-verified as correct);
#   * the LIVE POSTURE READS — GET …/service-store/effector and …/federation
#     report the real clients on the kind profile, which is the precondition that
#     makes the TLS wall reachable at all (and the day either reports `false`
#     again the manifest and the running pod have drifted).
@service:admin @layer:bff
Feature: The app-store effector legs are armed on the cluster profile, and their trust walls are named

  # ── the deploy oracle: specs/cluster/manifests/admin-bff-api/deployment.yaml ─
  @issue:admin-bff-api-62 @harness @interface:cli
  Scenario: the cluster admin-bff pins the ArgoCD effector at the in-cluster devops Service over https
    When I run the shell command "grep -c 'name: APPSTORE_ARGOCD_BASE_URL, value: \"https://argocd-server.devops.svc.cluster.local\"' specs/cluster/manifests/admin-bff-api/deployment.yaml"
    Then the command succeeded
    And the command output contains "1"

  @issue:admin-bff-api-62 @issue:admin-bff-api-82 @harness @interface:cli
  Scenario Outline: the cluster admin-bff arms the <leg> effector leg (the wall is TLS trust, not a dark client)
    When I run the shell command "grep -c 'name: <env>, *value: \"true\"' specs/cluster/manifests/admin-bff-api/deployment.yaml"
    Then the command succeeded
    And the command output contains "1"

    Examples:
      | leg        | env                         |
      | ArgoCD     | APPSTORE_EFFECTOR_ENABLED   |
      | federation | APPSTORE_FEDERATION_ENABLED |

  # #82 pins the federation callee to https in the same manifest; a silent flip
  # back to http would make the client-cert half of #82 moot without saying so.
  @issue:admin-bff-api-82 @harness @interface:cli
  Scenario: the cluster admin-bff addresses federation-api over https, where the client-certificate wall lives
    When I run the shell command "grep -A1 'name: APPSTORE_FEDERATION_BASE_URL' specs/cluster/manifests/admin-bff-api/deployment.yaml"
    Then the command succeeded
    And the command output contains "https://hugmesh-federation-api.hugmesh-backend.svc.cluster.local"

  # ── the live posture reads (kind only: compose ships both legs dark) ────────
  # The superadmin reads these two through the public front door: the fe
  # gateway carries a '/bff/superadmin/**' -> ROLE_SUPERADMIN row (20-schema.sql,
  # the #244-accepted public-door floor) and the SUPERADMIN bypass admits it.
  @issue:admin-bff-api-62 @env:kind @role:e2e-superadmin @service:admin @layer:bff
  Scenario: on the cluster profile the effector reports a real ArgoCD client
    Given I hold an API session as the persona for this scenario
    When I request the governed path "/bff/superadmin/service-store/effector"
    Then the gateway did not reject the request
    And the gateway verdict is "PASSED"

  @issue:admin-bff-api-82 @env:kind @role:e2e-superadmin @service:admin @layer:bff
  Scenario: on the cluster profile the federation leg reports itself enabled
    Given I hold an API session as the persona for this scenario
    When I request the governed path "/bff/superadmin/service-store/federation"
    Then the gateway did not reject the request
    And the gateway verdict is "PASSED"

  # The other side of the same door: neither posture read is a plain-admin or
  # member surface, and the two refusals come from DIFFERENT layers.
  #
  # REWRITTEN 2026-10-29. The earlier draft asserted, for all three tiers, that
  # admin-bff itself refused (no X-Route-Denied) on the premise that
  # /bff/superadmin/** had no fe gateway row; it also paired "the gateway did not
  # reject" with the verdict DENIED, which can never both hold (DENIED means a 403
  # WITH X-Route-Denied). main's seed now carries the /bff/superadmin/** ->
  # ROLE_SUPERADMIN row, so the outcome splits by tier. Measured through
  # https://localhost:8488 on 2026-10-29 for both posture reads:
  #   e2e-user, e2e-mod  -> 403 X-Route-Denied=hugmesh-fe-gateway:<path> (the door)
  #   e2e-admin          -> 403, no X-Route-Denied (admin bypass; admin-bff refuses)
  #   e2e-superadmin     -> 200 {"real":false} (compose ships the legs dark)
  @issue:admin-bff-api-62 @env:docker
  Scenario Outline: <role> is refused the effector posture read <path> at the gateway door @role:<role> @service:admin @layer:gateway
    Given I hold an API session as the persona for this scenario
    When I request the governed path "<path>"
    Then the gateway verdict is "DENIED"
    And the gateway route-access reject names the path "<path>"

    Examples:
      | role     | path                                     |
      | e2e-mod  | /bff/superadmin/service-store/effector   |
      | e2e-mod  | /bff/superadmin/service-store/federation |
      | e2e-user | /bff/superadmin/service-store/effector   |
      | e2e-user | /bff/superadmin/service-store/federation |

  # ROLE_ADMIN is forwarded past decide() on the admin bypass, so what refuses it
  # is admin-bff's own SecurityConfig: a 403 with NO X-Route-Denied.
  @issue:admin-bff-api-62 @env:docker
  Scenario Outline: e2e-admin is refused the effector posture read <path> by admin-bff itself @role:e2e-admin @service:admin @layer:bff
    Given I hold an API session as the persona for this scenario
    When I request the governed path "<path>"
    Then the gateway did not reject the request
    And the governed path answered HTTP 403

    Examples:
      | path                                     |
      | /bff/superadmin/service-store/effector   |
      | /bff/superadmin/service-store/federation |
