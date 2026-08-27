# The executable Gherkin expression of tests/e2e/specs/08-usage.spec.ts.
#
# WHERE THE VIEW ACTUALLY LIVES. Usage analytics is inside admin-ui's OWN
# per-module menu (admin.component.ts `menu()`), reached through the host's
# Admin profile-menu entry. There is no host-level top-nav shortcut — the
# `nav-usage` testid the spec once assumed exists nowhere in the current UI, so
# every scenario below goes profile-trigger -> menu-admin -> [data-menu=...].
#
# INFRASTRUCTURE DEPENDENCY, DECLARED AS A STEP. The "(ClickHouse-backed)" in
# spec 08's title is the whole point: the aggregates are read back out of the
# ClickHouse analytics warehouse admin-bff writes into via Kafka. The COMPOSE
# lane has NEITHER (compose.local.yaml states it outright), so admin-bff
# degrades to its clearly-marked in-memory fallback, which self-reports
# source="in-memory" and records a NARROWER action vocabulary — there is no
# 'login' row at all. `Given the analytics warehouse is serving ...` asks
# admin-bff which backend served the request and SKIPS LOUDLY on the dependency,
# naming it. The assertions are unchanged and run in full the moment a lane
# serves source="clickhouse".
@service:admin @layer:ui
Feature: Admin usage analytics, and who is kept out of it

  Scenario: an admin reads the warehouse-backed usage aggregates @role:admin@hugmesh.net @service:admin @layer:ui
    Given I am signed in as the persona for this scenario
    And the analytics warehouse is serving the admin usage aggregates
    When I open the admin module "usage"
    Then the element with test id "usage-view" is visible
    And the usage aggregate "usage-total" is not zero
    And the usage aggregate "usage-active" is not zero
    And the usage "module" breakdown lists "login-ui"
    And the usage "action" breakdown lists "login"

  # ROLE × PLATFORM. Both admin-ui modules are gated the same way in BOTH
  # directions — the host hides the Admin profile-menu entry (session.isAdmin())
  # AND direct navigation is blocked server-side — so a plain ROLE_USER persona
  # sees neither view. The two role/module pairs are exactly the ones specs 08
  # and 09 assert (alice on usage, bob on namespaces); the PLATFORM axis is here
  # because this is a whole-stack authz contract that both image targets ship,
  # and SNAP_PLATFORM narrows the run to the target actually brought up.
  Scenario Outline: <role> is kept out of the admin <module> view on <platform> @role:<role> @platform:<platform> @service:admin @layer:ui
    Given I am signed in as the persona for this scenario
    Then the Admin entry is absent from my profile menu
    When I open the path "/admin/<module>"
    Then the element with test id "<view>" is not visible

    Examples:
      | role            | module     | view       | platform |
      | alice@gmail.com | usage      | usage-view | rpi5     |
      | alice@gmail.com | usage      | usage-view | x86      |
      | bob@gmail.com   | namespaces | ns-view    | rpi5     |
      | bob@gmail.com   | namespaces | ns-view    | x86      |
