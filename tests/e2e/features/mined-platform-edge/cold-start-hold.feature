# THE GATEWAY'S SECOND REFUSAL, and why this domain does not claim to prove it.
#
# The route-access gate has exactly two refusals and they mean opposite things:
#
#   403 + X-Route-Denied: <gateway>:<path>, empty body
#       "you are not allowed here"   (GatewayRouteAccessFilter.reject)
#   503 + Retry-After: 5, empty body, NO X-Route-Denied
#       "I do not yet know whether you are allowed, so nobody privileged passes"
#       (GatewayRouteAccessFilter.notPrimed, reached only when the privileged MFA
#        floor is enforcing AND the route-access snapshot has never refreshed)
#
# The 503 is a POSITIVE result: the gate refused to guess. Reading it as an outage
# is how a fail-closed design gets "fixed" into a fail-open one.
#
# THE SUITE KNOWS ABOUT IT ONLY AS SOMETHING TO SURVIVE. steps/moderation-media.steps.ts
# and specs/29-mfa-privileged-floor.spec.ts both classify HOLDING, and both use it
# to RIDE OUT the cold start (`primedGet` loops until the verdict stops being
# HOLDING). No scenario in the 51-feature corpus ever asserts HOLDING as an
# outcome — measured, not assumed: the string appears in the two step/spec files
# and in zero .feature files.
#
# WHY IT IS PENDING RATHER THAN TAGGED @env:docker. An @env: tag would skip
# cleanly while the mesh is down and then FAIL the moment one is up, because the
# unprimed window is not a state a running gateway can be asked to enter: it
# exists between process start and the first datastore refresh. Producing it means
# restarting the gateway, which this lane must not do, and the suite's own helper
# is built to hide the window rather than catch it. Saying so is the honest
# artefact; asserting a green HOLDING would claim a proof nobody has run.
@harness @layer:gateway @service:gateway
Feature: The route-access cold-start hold fails closed and says so

  Scenario: an unprimed gateway holds a privileged request rather than guessing @role:e2e-admin @layer:gateway @service:gateway
    Given this scenario is PENDING because "the 503 + Retry-After hold only exists between gateway process start and the first route-access refresh (GatewayRouteAccessFilter.notPrimed, reachable only with the privileged MFA floor enforcing). Catching it requires restarting the gateway, which this lane must not do, and the suite's own primedGet helper is written to LOOP until the verdict stops being HOLDING rather than to observe it. HOLDING is asserted as an outcome in zero of the 51 features today. DESIRED, when a stack with MFA_FLOOR=1 can be cold-started under test: as e2e-admin request an mfa_required surface within the first refresh window, then assert the gateway verdict is HOLDING, the response carries Retry-After, it carries NO X-Route-Denied header (that header is the DENY signature and would misattribute the hold as a refusal), and the body is empty."
    Given the persona for this scenario presents its effective role set
    When I request the governed path "/bff/admin/usage"
    Then the gateway verdict is "HOLDING"
