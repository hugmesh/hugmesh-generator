# POST /bff/register — user-bff's OWN self-registration endpoint for an
# allow-listed email (SsoAuthController:141-154): permitAll app-side, allowlist
# gated BEFORE ensureAccount, "this is a permitAll, mutating surface".
#
# THE DECIDED CONTRACT: the front door keeps it CLOSED to anonymous callers.
# hugmesh-gateway#29 asked whether /bff/register should be opened; the operator
# chose "document register as an authenticated surface, keep it closed" on
# 2026-10-15 (hugmesh-gateway docs/decisions/002-bff-register-authenticated.md).
# The decision record's reason, taken from the code: user-bff's handler mints a
# session for an allow-listed email with no proof the caller owns that address.
# The gateway holds the decision in two layers: /bff/register is not in the fe
# gateway's PUBLIC_PATHS (the coarse authenticated() floor answers 401), and the
# route-access seed grants /bff/register/** to ROLE_USER only. The gateway repo
# pins both with unit tests; this file is the front-door half.
#
# An earlier draft of this file fenced the OPPOSITE contract (an anonymous
# caller reaching user-bff's allowlist and receiving a session) as @fixme rows
# waiting for #29 to open the door. Decision 002 closed that question, so those
# rows were replaced by the refusal below. Reopening registration to anonymous
# callers needs a proof-of-email-ownership step in user-bff first; see the
# decision record's "Reopening" section.
#
# @env:docker sits on the live scenario only, NOT on the Feature line: a
# Feature-level @env:docker is inherited by every row, so the two offline
# routing rows below were skipped whenever no docker stack answered — which is
# every run of `make stack-e2e-bdd-check` — and the cluster row's false
# assertion stayed hidden from 2026-09-23 to 2026-10-21.
@service:login @layer:bff
Feature: Email self-registration stays closed to anonymous callers at the front door

  # The door answers first: 401 from the authenticated() floor (measured as 401
  # through https://localhost:8488 on 2026-09-23). The body names an address
  # nobody invited, so a regression that opened the door cannot mint a session
  # for a real invite while this row is failing.
  @issue:gateway-29 @env:docker
  Scenario: an anonymous POST /bff/register is refused at the door @service:login @layer:gateway
    Given I hold an anonymous API client
    When the API client POSTs "/bff/register" with body "{\"email\":\"never-invited-bdd@example.test\"}"
    Then the response status is 401
    And the API client holds no cookie named "bff_session"

  # The offline control: BOTH fe route tables send /bff/register to user-bff,
  # so a signed-in caller (the decided audience) lands on the handler, not on
  # admin-bff's /bff/** catch-all. The two tables declare it differently: compose
  # lists the EXACT path in user-bff's Path= list; the cluster table declares the
  # SUBTREE /bff/register/** (route hugmesh-user-bff-api-register), which also
  # claims the bare /bff/register under Spring's Ant matching. The routes-to step
  # compares DECLARED patterns literally, so each row names the pattern its table
  # actually declares, and the claims-before step then proves that the bare path
  # is claimed ahead of the admin-bff catch-all on that table.
  @harness @issue:gateway-29
  Scenario Outline: /bff/register is routed to user-bff on the <table> table @service:login @layer:gateway
    Then the "<table>" fe gateway routes "<declared>" to the "hugmesh-user-bff-api" upstream
    And the "<table>" fe gateway claims "/bff/register" before the "hugmesh-admin-bff-api" catch-all

    Examples:
      | table   | declared          |
      | compose | /bff/register     |
      | cluster | /bff/register/**  |
