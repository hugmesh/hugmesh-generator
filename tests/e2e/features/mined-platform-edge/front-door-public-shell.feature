# The ANONYMOUS SPA SHELL at the fe front door, decided from the seed.
#
# A 403 on /main-<hash>.js does not render an error. It renders NOTHING: the
# document arrives, the bundle does not, Angular never bootstraps, and any
# assertion waiting for a selector times out somewhere unrelated. So the seed
# grants PUBLIC on six shell surfaces plus the /assets tree, and the gateway
# admits them with no Casdoor JWT at all.
#
# WHY THIS IS NOT ALREADY COVERED. features/rbac/gateway-route-access.feature
# evaluates the hand-written oracle, which carries NONE of these rows and whose
# patternMatch() treats any pattern without a `/**` suffix as an EXACT path — so
# `/*.js` there matches literally no URL a browser ever requests. Every assertion
# in this file therefore reads the SEED and applies the Ant semantics the gateway
# applies (steps/mined-platform-edge.steps.ts), which is the only way the
# single-star rows mean anything.
#
# RUNS OFFLINE — the seed is a committed artefact and the decision is pure.
@harness @layer:gateway @service:gateway
Feature: The anonymous SPA shell is publicly reachable at the fe front door

  Scenario Outline: an anonymous visitor may fetch <what> @layer:gateway @service:gateway
    Given an anonymous caller presenting no roles
    When the seeded route-access table is evaluated for the path "<path>" on the "hugmesh-fe-gateway" gateway
    Then the seeded route-access decision is "ALLOW"

    Examples:
      | what                | path                 |
      | the front page      | /                    |
      | the shell document  | /index.html          |
      | a hashed JS bundle  | /main-ABC123DEF.js   |
      | a hashed CSS bundle | /styles-9F8E7D.css   |
      | the import map      | /importmap.json      |
      | the remote entry    | /remoteEntry.json    |
      | the favicon         | /favicon.ico         |
      | a static asset      | /assets/img/logo.svg |

  # The single-star rows are the ones the oracle cannot express at all, so their
  # SEMANTICS are pinned here rather than assumed: `*` stays inside one path
  # segment. If it were ever read as a `**`, the /assets tree would become public
  # through the webroot-bundle row and nobody would notice, because the symptom of
  # a too-open rule is that everything works.
  Scenario: the webroot bundle patterns match a hashed bundle and nothing deeper @layer:gateway @service:gateway
    Then the seeded pattern "/*.js" on the "hugmesh-fe-gateway" gateway matches the request path "/main-ABC123DEF.js"
    And the seeded pattern "/*.js" on the "hugmesh-fe-gateway" gateway does not match the request path "/assets/vendor.js"
    And the seeded pattern "/*.css" on the "hugmesh-fe-gateway" gateway matches the request path "/styles-9F8E7D.css"
    And the seeded pattern "/assets/**" on the "hugmesh-fe-gateway" gateway matches the request path "/assets/img/logo.svg"

  # The public front door stays public for a signed-in member too. Stated as a
  # decision rather than a row because that is the property that breaks: a new
  # longer pattern over `/` would silently take the front page away from
  # everybody, and the row for `/` would still be sitting there reading fine.
  Scenario: an authenticated member still reaches the public front page @role:e2e-user @layer:gateway @service:gateway
    Given the persona for this scenario presents its effective role set
    When the seeded route-access table is evaluated for the path "/" on the "hugmesh-fe-gateway" gateway
    Then the seeded route-access decision is "ALLOW"
    And the winning seeded pattern for "/" on the "hugmesh-fe-gateway" gateway is "/"

  # The pki front door's own public pair, which nothing in the suite reads today.
  Scenario Outline: the pki gateway admits an anonymous caller at <what> @layer:gateway @service:gateway
    Given an anonymous caller presenting no roles
    When the seeded route-access table is evaluated for the path "<path>" on the "hugmesh-pki-gateway" gateway
    Then the seeded route-access decision is "ALLOW"

    Examples:
      | what                    | path                                  |
      | the login mount         | /login/oauth/authorize                |
      | the OIDC discovery doc  | /.well-known/openid-configuration     |
      | the JWKS                | /.well-known/jwks.json                |
