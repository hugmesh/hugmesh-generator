# WHAT THIS ASSERTS. The three governance front-ends refuse in THREE DIFFERENT
# SHAPES, and one of them is a shape the central suite has no example of.
#
#   admin-ui  superadminGuard / fleetAdminGuard / gamesServicesGuard -> '/login'
#   mod-ui    modGuard                                               -> '/login'
#   service-catalog-ui  superadminGuard  -> '/service-catalog/forbidden'
#
# The service-catalog remote is a FEDERATED REMOTE mounted at /service-catalog on
# the host shell. A denial there is a WITHIN-SERVICE privilege boundary, not an
# auth failure — the host already let the user in — so it routes to its own
# MOUNT-PREFIXED forbidden screen. The guard's own comment records that shipping
# the bare '/forbidden' was a real wiki-ui bug: a remote bouncing to a host path
# it does not own. That is exactly the federated-remote trap this estate keeps
# hitting, and nothing central pins it.
#
# The workload console is the fourth shape and the interesting counter-example:
# it bounces an UNAUTHENTICATED caller to '/login' but a merely UNENTITLED one to
# '/admin' — refusing without pretending the session is broken.
#
# THE ONE THING THIS DOES NOT PROVE: that the target renders. That needs the
# remote served, and no environment is up. What it proves is that each guard
# names its own refusal target and never the wrong one — which is the half that
# has ever actually regressed.
#
# NEEDS the three UI checkouts beside this repo (source read only — no ng serve).
# Each scenario SKIPS independently, naming the repo it could not find.
@layer:ui
Feature: Each governance remote refuses to a target it owns

  Scenario Outline: the <repo> guard <guard> refuses to <target> @layer:ui
    Then the guard "src/app/<guard>" in "<repo>" refuses to "<target>"

    Examples:
      | repo                                   | guard                     | target                       |
      | hugmesh-admin-ui                       | superadmin.guard.ts       | /login                       |
      | hugmesh-admin-ui                       | fleet.guard.ts            | /login                       |
      | hugmesh-admin-ui                       | games-services.guard.ts   | /login                       |
      | hugmesh-mod-ui                         | mod.guard.ts              | /login                       |
      | hugmesh-superadmin-service-catalog-ui  | service-catalog.guard.ts  | /service-catalog/forbidden   |

  # THE REGRESSION THIS EXISTS FOR. A federated remote must not bounce to a HOST
  # path it does not own — the bare '/forbidden' was the wiki-ui bug — and must
  # not claim an auth failure for a privilege boundary the host already cleared.
  Scenario: the service-catalog denial is mount-prefixed and is not an auth failure @service:gateway @layer:ui
    Then the guard "src/app/service-catalog.guard.ts" in "hugmesh-superadmin-service-catalog-ui" never refuses to "/forbidden"
    And the guard "src/app/service-catalog.guard.ts" in "hugmesh-superadmin-service-catalog-ui" never refuses to "/login"

  # The counter-example: unauthenticated and unentitled are DIFFERENT refusals in
  # the hidden tier, and conflating them would send an entitled-but-not-yet-probed
  # admin to a login page they are already past.
  Scenario: the workload console separates "not signed in" from "not entitled" @service:admin @layer:ui
    Then the guard "src/app/workload-console.guard.ts" in "hugmesh-admin-ui" refuses to "/login"
    And the guard "src/app/workload-console.guard.ts" in "hugmesh-admin-ui" refuses to "/admin"
