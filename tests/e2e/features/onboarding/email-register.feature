# POST /bff/register — user-bff's OWN self-registration endpoint for an
# allow-listed email (SsoAuthController:141-154): permitAll app-side, allowlist
# gated BEFORE ensureAccount, "this is a permitAll, mutating surface". Two open
# issues make it unreachable and unusable, in that order:
#
#   hugmesh-gateway#29   the fe gateway's PUBLIC_PATHS carry /bff/login and the
#                        /bff/public/* reads but NO /bff/register, so the coarse
#                        authenticated() floor 401s an anonymous POST before
#                        routing; and the route-access seed grants
#                        /bff/register/** to ROLE_USER (20-schema.sql:627), so
#                        even an open floor would DENY the anonymous caller.
#                        Measured 2026-09-23: anonymous POST /bff/register ->
#                        401 through https://localhost:8488.
#   hugmesh-user-bff-api#13  behind that door the handler calls
#                        allowlistCheck("email", …), and "email" is not a
#                        provider admin-bff's allowlist switch knows (400
#                        "unknown provider") — defect 1 (the {"invited":bool}
#                        decode) was fixed by PR #20, defect 2 is still open.
#
# Both scenarios below are @fixme: neither fix is on origin/main (gateway 22663fe,
# user-bff 666ab2f, re-checked 2026-09-23). Their Then-steps assert the contract
# both issues ask for — registration is PRE-AUTHENTICATION, the refusal for an
# unlisted email is user-bff's own 403, and a listed email gets an account — so
# they turn green unmodified the day the fixes land. The route-shape scenario at
# the bottom is the non-pending control: it is true today and it is what makes
# a green here mean user-bff answered, not the admin-bff catch-all.
#
# WHY NOT DRIVE IT SIGNED-IN "TO MAKE IT WORK". A signed-in POST passes the door,
# but the handler then 400s/500s on defect 2 for every input, so there is no
# green to be had; and asserting a signed-in self-registration would fence in
# the wrong contract (the endpoint's own doc says anonymous). The identity the
# positive row registers is invited per run by admin@hugmesh.net and un-invited
# again afterwards, exactly like register-provider-paths.feature's rows.
@service:login @layer:bff @env:docker
Feature: Anonymous email self-registration reaches user-bff and is gated by the allowlist

  # The unlisted email is refused by user-bff itself — 403, with no
  # X-Route-Denied (that header is the gateway's signature, and a 401 is the
  # floor's). Today the floor answers first.
  @issue:gateway-29 @fixme
  Scenario: an anonymous caller with an email nobody invited is refused by the allowlist, not by the door @service:login @layer:bff
    Given I hold an anonymous API client
    When the API client POSTs "/bff/register" with body "{\"email\":\"never-invited-bdd@example.test\"}"
    Then the response status is 403
    And the response carries no header "X-Route-Denied"
    And the response error message matches "not allowed to register"

  # The invited email is registered: an account plus a minted bff_ session, in
  # the same emitAndSession shape POST /bff/register/google answers. The
  # keying of that account (google: like the invite row, or casdoor: like a
  # native login) is the product question #13 leaves open, so only the shape
  # every answer shares is asserted.
  @issue:gateway-29 @issue:user-bff-api-13 @fixme
  Scenario: an anonymous caller with an invited email registers and receives a session @service:login @layer:bff
    Given I hold an anonymous API client
    And a freshly invited Gmail identity for this scenario
    When the API client registers the invited identity through "/bff/register"
    Then the response status is 200
    And the response JSON field "token" is present
    And the response JSON field "registrationComplete" is "false"
    And the API client holds a cookie named "bff_session"

  # The positive control, offline: BOTH fe route tables already send the exact
  # path to user-bff, so once the door opens the request lands on the handler
  # the two issues describe — not on admin-bff's /bff/** catch-all.
  @harness @issue:gateway-29
  Scenario Outline: /bff/register is routed to user-bff on the <table> table @service:login @layer:gateway
    Then the "<table>" fe gateway routes "/bff/register" to the "hugmesh-user-bff-api" upstream

    Examples:
      | table   |
      | compose |
      | cluster |
