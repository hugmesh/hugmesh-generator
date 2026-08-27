# WHAT THIS ASSERTS. features/rbac/console-access-matrix.feature proves that the
# two TOP-LEVEL consoles (admin, mod) are discoverable and reachable per role.
# One level down, inside the admin console, the same defect class is live and
# unasserted: a route can exist, be guarded, and appear in NO menu for ANY role —
# reachable only by someone who already knows the URL.
#
# MEASURED (2026-08-26, both files parsed comment-stripped):
#   * admin.routes.ts declares 40 route entries; admin.component.ts's allMenu
#     holds 33 items. Every menu item names a real route (no dangling links).
#   * SEVEN routes appear in no menu: the '' landing route, backing-services,
#     oidc-providers, games-services, superadmin/anubis, and the two workload
#     child views (workloads/logs, workloads/terminal, which are reached FROM the
#     workload console rather than from the menu).
#   * of those, backing-services and superadmin/anubis are superadminGuard'ed and
#     games-services is gamesServicesGuard'ed — three guarded consoles a fully
#     entitled principal cannot navigate to. oidc-providers is routed with NO
#     guard at all and no menu entry.
#   * the three menu tiers hold exactly what their flags name: superadminOnly 6,
#     fleetOnly 1, hidden 1.
#
# THE LISTS BELOW ARE PINNED IN BOTH DIRECTIONS. A NEW orphan fails here; so does
# closing an existing one. That is deliberate — either change should be a
# conscious edit to this feature, not a silent drift.
#
# NEEDS the hugmesh-admin-ui checkout beside this repo (source read only — no
# ng build, no served remote). Absent, every scenario SKIPS naming the path.
@service:admin @layer:ui
Feature: Every guarded admin console is discoverable by someone

  Background:
    Given the admin console route table and menu model are loaded

  Scenario: the route table and the menu model are the sizes the console ships @layer:ui
    Then the admin console routes 40 paths and lists 33 menu items
    And every menu item names a real route

  Scenario: the admin routes reachable only by typing a URL are exactly the recorded set @layer:ui
    Then the admin routes reachable only by typing a URL are exactly "backing-services, oidc-providers, games-services, superadmin/anubis, workloads/logs, workloads/terminal"

  # The three tiers the menu model implements, each pinned to its exact members
  # rather than to a count — a count passes after a swap.
  Scenario Outline: the <tier> tier holds exactly the modules its flag names @layer:ui
    Then the "<tier>" menu tier holds exactly the modules "<modules>"

    Examples:
      | tier           | modules                                                                                     |
      | superadminOnly | device-licenses, device-pending, phone-fleet, fleet-entitlements, egress-vpn, superadmin/domains |
      | fleetOnly      | my-fleet                                                                                    |
      | hidden         | workloads                                                                                   |

  # A superadmin-guarded route that IS in the menu must be flagged superadminOnly,
  # or a plain admin is shown a door that bounces them to /login.
  Scenario: no superadmin-guarded console is offered to a plain admin @layer:ui
    Then every route guarded by "superadminGuard" is either flagged "superadminOnly" in the menu or absent from it

  # ...and the ones absent from the menu entirely are the two recorded here: even
  # a superadmin has no way to navigate to them.
  Scenario: the superadmin-guarded consoles no menu lists are exactly the recorded two @layer:ui
    Then the routes guarded by "superadminGuard" that no menu lists are exactly "backing-services, superadmin/anubis"

  # The fleet tier's route guard and its menu flag must agree, or the "My fleet"
  # owner console is offered to principals the guard will bounce.
  Scenario: the fleet console is offered exactly where its guard admits @layer:ui
    Then every route guarded by "fleetAdminGuard" is either flagged "fleetOnly" in the menu or absent from it

  # The hidden tier is the one whose ROUTE guard is authoritative and whose menu
  # entry is only discoverability, so the flag and the guard must line up too.
  Scenario: the workload console is the hidden tier, guarded and flagged @layer:ui
    Then every route guarded by "workloadConsoleGuard" is either flagged "hidden" in the menu or absent from it

  # KNOWN-OPEN. The property the whole feature exists to state.
  Scenario: no guarded admin console is reachable only by typing its URL @layer:ui
    Given this scenario is PENDING because "three GUARDED admin consoles are in no menu for any role: backing-services and superadmin/anubis (superadminGuard) and games-services (gamesServicesGuard). A fourth, oidc-providers, is routed with no guard and no menu entry at all. Each is real, guarded work that only a URL-typer can reach — give each a menu item at its own tier, or say in admin.routes.ts that it is a child view reached from another console (the pattern workloads/logs and workloads/terminal already follow)."
    Then the admin routes reachable only by typing a URL are exactly "workloads/logs, workloads/terminal"
