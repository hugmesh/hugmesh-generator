# WHAT THIS ASSERTS — three issues on ONE surface, the SUPERADMIN Domains
# console (hugmesh-admin-ui superadmin-domains.component, route
# /admin/superadmin/domains behind superadminGuard) over DomainRegistryController
# (/bff/admin/domains, every method @PreAuthorize hasRole('SUPERADMIN')):
#
#   * hugmesh-admin-ui#10 — the console must offer an EXPLICIT own-Casdoor vs
#     superdomain-Casdoor choice using the generator's DOMAIN_IDP vocabulary.
#     RE-MEASURED 2026-09-23: the BFF half has LANDED (admin-bff e039057,
#     decision 29: DomainIdp {superdomain|own}, CreateDomainRequest.idp,
#     DomainResponse.idp, DomainEntry.idp; absent -> superdomain; anything else
#     -> 400 "idp must be one of superdomain|own"), and it is in the compose
#     stack's admin-bff image (6dc72d1). The UI half has NOT: the component on
#     admin-ui origin/main d5ffdf8a still has zero occurrences of idp, only a
#     free-text "Casdoor org" field. So the API scenarios PASS and the console
#     scenario is @fixme.
#   * hugmesh-admin-ui#9 — config edit and REMOVE (soft-disable via PUT
#     enabled:false, rendered DISTINCTLY rather than hidden) in the console.
#     The BFF arm exists and is unused by the UI ("reachable and simply unused"
#     — the issue's own words), so the API soft-disable PASSES and the console's
#     control is @fixme.
#   * hugmesh-admin-bff-api#83 — publish target / build target / domain type
#     columns on domain_registry, their DTOs and the signed export. NOT landed
#     (DomainRegistration on 6dc72d1 carries idp + the MCS pair and nothing of
#     the kind). Its scenario is @fixme and asserts the shapes the issue names —
#     but the issue also says "concrete column names are a proposal, not a
#     decree", so the field names below (publishTarget, buildTarget, domainType)
#     are that proposal, stated in the step text so the day the contract lands
#     they are re-spelled here in one place rather than guessed at twice.
#
# WHO GETS THROUGH, and by which wall (re-read from the controller header):
# SUPERADMIN on every method; ADMIN clears the coarse /bff/admin/** gate and is
# walled at the per-method hasRole('SUPERADMIN') — a BFF 403 with no
# X-Route-Denied; MOD/USER never clear the gate — a GATEWAY 403 with it.
#
# REACHING THE CONSOLE AS e2e-superadmin. The roster's superadmin holds
# ROLE_SUPERADMIN and NOT ROLE_ADMIN (so the no-down-cascade proofs hold), and
# the host shell's adminGuard (session.isAdmin() = roles includes 'admin')
# bounces it from /admin before the remote's own superadminGuard ever runs. The
# path that works — and the one tests/e2e/shot-harness rows use — is a HARD GET:
# the fe-gateway routes /admin/** to the admin-ui container (StripPrefix), which
# boots standalone under its OWN guard, and that guard admits 'superadmin'.
# `When I open the path` is page.goto, a hard GET. Say so rather than assume.
#
# WRITES, and where they may land. Registering a domain is a real row in
# domain_registry and there is NO delete on this resource (soft-disable only, by
# design). Every registering scenario is therefore @env:kind — the survey's
# environment for this surface — so it never lands rows in the operator's shared
# compose registry; today there is no kind cluster, so they skip naming
# `make kind-images && make kind-up`. The ONE write driven on compose is a
# REFUSED one (idp:"bogus" -> 400 before any row). Registered names are
# e2e-bdd-<slug>-<stamp>.example.test, and their nsPrefix is the same slug
# (decision 29a: nsPrefix IS the namespace and is required — the service
# refuses the slug BEFORE it looks at idp, so every probe carries a valid one).
@service:admin
Feature: The domain registry is superadmin-only, offers an explicit IdP choice, and awaits its per-domain targets

  # ── the rows the cluster loads ─────────────────────────────────────────────
  @issue:admin-ui-9
  Scenario Outline: a principal holding only <granted> is <decision> at the domains surface by the rows alone @layer:gateway
    Given the cluster route-access seed is loaded
    And a principal holding only the role "<granted>"
    When the "hugmesh-fe-gateway" gateway decides "/bff/admin/domains" from the cluster seed
    Then the seed decision is "<decision>"
    And the deciding url pattern is "/bff/admin/**"

    Examples:
      | granted         | decision |
      | ROLE_ADMIN      | ALLOW    |
      | ROLE_SUPERADMIN | DENY     |
      | ROLE_MOD        | DENY     |
      | ROLE_USER       | DENY     |

  # The remote's own guard on the console route — read from admin-ui's source
  # when the sibling checkout is present, skipped with the path otherwise.
  @issue:admin-ui-9
  Scenario: the console route is superadmin-guarded inside the admin remote @layer:ui
    Then the admin console route "superadmin/domains" is guarded by "superadminGuard"

  # ── who reaches the registry, live, read-only ──────────────────────────────
  @issue:admin-ui-9 @env:docker @role:e2e-superadmin
  Scenario: the superadmin lists the registry @role:e2e-superadmin @env:docker @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/domains"
    Then the response status is 200

  @issue:admin-ui-9 @env:docker @role:e2e-admin
  Scenario: a plain admin clears the gateway and is walled at the method @role:e2e-admin @env:docker @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/domains"
    Then the response status is 403
    And the refusal came from the BFF, not the gateway

  @issue:admin-ui-9 @env:docker
  Scenario Outline: <role> is refused the registry at the gateway @role:<role> @env:docker @layer:gateway
    Given an API client signed in as the persona for this scenario
    When the API client GETs "/bff/admin/domains"
    Then the response status is 403
    And the refusal came from the gateway

    Examples:
      | role     |
      | e2e-user |
      | e2e-mod  |

  @issue:admin-ui-9 @env:docker
  Scenario: an anonymous client is unauthenticated at the registry @env:docker @layer:gateway
    Given an anonymous API client
    When the API client GETs "/bff/admin/domains"
    Then the response status is 401

  # ── the IdP vocabulary (BFF half of admin-ui#10 — LANDED) ──────────────────
  # A REFUSED write: the closed vocabulary rejects a third spelling before any
  # row exists, so this one may run against the shared compose stack.
  @issue:admin-ui-10 @env:docker @role:e2e-superadmin
  Scenario: a third IdP spelling is refused before any row is written @role:e2e-superadmin @env:docker @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client registers the domain "idp-bogus" with idp "bogus"
    Then the response status is 400
    And the response error message matches "idp must be one of superdomain\\|own"

  @issue:admin-ui-10 @env:kind @role:e2e-superadmin
  Scenario: registering without choosing an IdP defaults to the superdomain's Casdoor @role:e2e-superadmin @env:kind @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client registers the domain "idp-default" without choosing an IdP
    Then the response status is 201
    And the response JSON field "idp" is "superdomain"
    When the API client reads back the registered domain
    Then the response status is 200
    And the response JSON field "idp" is "superdomain"

  @issue:admin-ui-10 @env:kind @role:e2e-superadmin
  Scenario: choosing own-Casdoor persists explicitly @role:e2e-superadmin @env:kind @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client registers the domain "idp-own" with idp "own"
    Then the response status is 201
    And the response JSON field "idp" is "own"
    When the API client reads back the registered domain
    Then the response status is 200
    And the response JSON field "idp" is "own"

  # ── soft-disable (BFF arm of admin-ui#9 — exists, unused by the console) ───
  @issue:admin-ui-9 @env:kind @role:e2e-superadmin
  Scenario: a superadmin soft-disables a domain and it stays in the registry as disabled @role:e2e-superadmin @env:kind @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client registers the domain "soft-disable" without choosing an IdP
    Then the response status is 201
    And the response JSON field "enabled" is "true"
    When the API client soft-disables the registered domain
    Then the response status is 200
    And the response JSON field "enabled" is "false"
    When the API client reads back the registered domain
    Then the response status is 200
    And the response JSON field "enabled" is "false"

  # ── the console (UI halves of admin-ui#9 and #10 — NOT landed) ─────────────
  # Both drive the real console over a row the API registered a moment earlier.
  # The control ids are this scenario's PROPOSAL to the admin-ui implementer,
  # spelled out so they are reviewable: sd-disable (a per-row control, addressed
  # on THAT row's <li data-cluster-domain> — never a bare getByTestId, which is
  # the strict-mode trap hugmesh-generator#388 recorded), and sd-idp (the choice
  # control, a <select> or radio group whose values are exactly the two
  # DOMAIN_IDP spellings). The status chip `.sd-status.is-disabled` the second
  # assertion reads already exists in the console today.
  @issue:admin-ui-9 @fixme @env:kind @role:e2e-superadmin
  Scenario: the console soft-disables a domain and renders it distinctly, still listed @role:e2e-superadmin @env:kind @layer:ui
    Given an API client signed in as the persona for this scenario
    When the API client registers the domain "console-disable" without choosing an IdP
    Then the response status is 201
    Given I am signed in as the persona for this scenario
    When I open the path "/admin/superadmin/domains"
    Then the element with test id "superadmin-domains-view" is visible
    And the domains list shows the registered domain
    And the domains list renders the registered domain as "enabled"
    When I activate the "sd-disable" control on the registered domain's row
    Then the domains list renders the registered domain as "disabled"

  @issue:admin-ui-10 @fixme @env:kind @role:e2e-superadmin
  Scenario: the console offers the own-Casdoor vs superdomain-Casdoor choice, defaulting to superdomain @role:e2e-superadmin @env:kind @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/admin/superadmin/domains"
    Then the element with test id "superadmin-domains-view" is visible
    And the "sd-idp" control offers exactly the choices "superdomain, own"
    And the "sd-idp" control defaults to "superdomain"

  # ── per-domain targets (admin-bff-api#83 — NOT landed) ─────────────────────
  # Field names are the issue's PROPOSAL (see the header). What is NOT
  # negotiable and is the point of the fence: a registered row reads back
  # carrying all three, so a domain that never opted in reads its defaults
  # rather than an absent key ("defaults must reproduce today's behaviour").
  @issue:admin-bff-api-83 @fixme @env:kind @role:e2e-superadmin
  Scenario: a registered domain reads back with its publish target, build target and domain type @role:e2e-superadmin @env:kind @layer:bff
    Given an API client signed in as the persona for this scenario
    When the API client registers the domain "targets" without choosing an IdP
    Then the response status is 201
    When the API client reads back the registered domain
    Then the response status is 200
    And the response JSON carries the fields "publishTarget, buildTarget, domainType"
