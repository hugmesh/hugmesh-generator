# MINED FROM: hugmesh-user-mesh-ui/src/app/user-mesh.routes.ts:7-13 —
#             "NOT YET BUILDABLE ... the three component imports above
#             (nodes.component, my-devices.component, channels.component)
#             currently point at files that DO NOT EXIST in this repo"
#             (verified: src/app/ holds neither), while :25-28 of the same file
#             and mesh.guard.ts:11-15 BOTH assert that "ROLE_MESH is enforced
#             upstream by the gateway_route_access row on /user-mesh/**".
#   MEASURED: there is no /user-mesh row in the route-access seed, no /user-mesh
#             Path predicate in the fe-gateway route table, and no /user-mesh
#             mount in hugmesh-host-shell app.routes.ts.
#
# THE ABSENCE IS THE CORRECT STATE and that is precisely why it needs writing
# down. A front door onto a remote that cannot build renders a blank page, and a
# blank page passes almost any assertion anyone would think to write about it.
# Two files in the mesh remote already describe a row that does not exist, so the
# next person to read them will "restore" it.
#
# WHEN THE THREE COMPONENTS LAND, DELETE THIS FEATURE IN THE SAME PR — and pair
# the new route with the ROLE_MESH row those two files already assume.
#
# NOTE ON THE CATCH-ALL: the fe route table ends with `Path=/**` -> host-shell,
# so /user-mesh IS answered — by the Angular shell, which has no such route and
# funnels it through roleHomeGuard. What must not exist is a route of its OWN
# pointing at the remote's container.

@harness @layer:gateway
Feature: The mesh dashboard remote is contractually unmounted while it cannot build

  Scenario: /user-mesh has no dedicated fe-gateway route @layer:gateway
    Then the fe gateway declares no dedicated route for the path prefix "/user-mesh"

  Scenario: /user-mesh has no route-access row, so the seed decides NO_RULE @layer:gateway
    Then the route-access seed has no fe gateway row for "/user-mesh/**"
    And the route-access seed decides "NO_RULE" for a principal holding only "ROLE_MESH" at "/user-mesh"
    And the route-access seed decides "NO_RULE" for a principal holding only "ROLE_MESH" at "/user-mesh/devices"

  # The asymmetry is deliberate and is the thing that makes the two scenarios
  # above a decision rather than an oversight: the mesh BFF prefix IS gated
  # today, with its service-only ingest denied beneath it, while the UI mount is
  # not gated at all because it does not exist.
  #
  # OBSERVED WHILE WRITING THIS, deliberately NOT asserted here because it
  # belongs to another unit: the CLUSTER gateway manifest carries
  # `/bff/mesh/** -> hugmesh-mesh-bff-api` (specs/cluster/apps/20-gateway-fe.yaml
  # :318) but the COMPOSE route table (tests/stack/gateway-routes/fe/
  # application-routes.yml) declares no /bff/mesh route at all, so on the compose
  # lane the prefix falls into the `/bff/**` -> admin-bff catch-all at :316.
  Scenario: the mesh BFF prefix is already gated @layer:gateway
    Then the route-access seed grants "ROLE_MESH" at "/bff/mesh/**" on the fe gateway
    And the route-access seed DENIES "ROLE_USER" at "/bff/mesh/internal/**" on the fe gateway
    And the route-access seed decides "ALLOW" for a principal holding only "ROLE_MESH" at "/bff/mesh/devices"
