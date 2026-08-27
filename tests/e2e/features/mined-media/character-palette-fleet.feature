# ONE CANONICAL UNSET-REGION PALETTE, ACROSS EVERY SURFACE THAT DRAWS A CHARACTER.
#
# A stored 3D character definition may legitimately carry `null` for a material
# region the wearer never set. Every renderer resolves that null against its OWN
# copy of DEFAULT_MATERIALS, and there are SIX declarations of that table in the
# fleet: the authority (Char3DConfigValidator) plus five mirrors — the shared
# contract fixture, the Angular editor, the Godot maker, the matrix-ui XR-room
# mirror and the games room's procedural assembler.
#
# They once disagreed on accent/detail/iris, so ONE character rendered in
# different colour schemes depending on which surface drew it; the matrix-ui copy
# "used to be a neutral grey ramp of its own invention". Its own header says so.
#
# WHY THE PER-REPO TESTS CANNOT CATCH THIS. The shared fixture
# (server-contract.fixtures.json) is compared against by exactly three consumers
# — the Java ClientContractFixturesTest, the Angular karma server-contract.spec
# and the Godot run_tests.gd. The other TWO copies (matrix-ui's XR mirror and the
# games assembler) live in different repositories and read that fixture never. No
# single repo's CI can see all five, so the drift they exist to prevent is
# invisible to every one of them.
#
# THE SECOND SCENARIO IS THE HALF THAT MATTERS MOST. Comparing five named files
# catches a changed value; it cannot catch a SIXTH surface inventing its own ramp,
# which is exactly how this happened the first time. The census scans the whole
# fleet for palette DECLARATIONS (a non-comment line binding the name — a mention
# in prose and a mere use like DEFAULT_MATERIALS[region] do not count) and pins
# the number, so a new copy fails loudly on the day it appears.
#
# TIER: fleet-source. Reads the sibling hugmesh-* checkouts. Absent fleet root ->
# a skip that NAMES SNAP_FLEET_ROOT and the repos. Present fleet root + a missing
# individual file -> a hard FAILURE, because a renamed repo or a deleted mirror is
# drift and is precisely what this asserts.
@harness @service:character-forge @layer:bff
Feature: One canonical unset-region palette, across every surface that draws a character

  Scenario Outline: the <surface> copy of DEFAULT_MATERIALS is byte-identical to the validator @harness @service:character-forge @layer:bff
    Then the character palette declared in "<path>" matches the Char3DConfigValidator authority

    Examples:
      | surface         | path                                                                                                   |
      | shared-fixture  | hugmesh-character-forge-bff-api/frontend/src/app/character-forge/contract/server-contract.fixtures.json |
      | angular-editor  | hugmesh-character-forge-bff-api/frontend/src/app/character-forge/models/char3d-config.ts                |
      | godot-maker     | hugmesh-character-forge-bff-api/godot/character-forge/scripts/char3d_config.gd                          |
      | matrix-xr-room  | hugmesh-matrix-ui/projects/matrix/src/app/chat3d/char3d-config.ts                                       |
      | games-assembler | hugmesh-games/games/shadows-of-the-net/scripts/character_assembler.gd                                   |

  Scenario: exactly five mirrors exist, so a sixth cannot appear unnoticed @harness @service:character-forge @layer:bff
    Then the fleet declares exactly 5 mirrors of the character palette

  # The other locked vocabularies travel with the palette, and the fixture is the
  # one place all of them are stated once — so a drifted fixture blesses the drift
  # in all three of its consumers at once.
  Scenario Outline: the shared contract fixture pins the validator's <vocabulary> verbatim @harness @service:character-forge @layer:bff
    Then the shared character contract fixture pins the validator vocabulary "<vocabulary>"

    Examples:
      | vocabulary         |
      | families           |
      | styles             |
      | expressions        |
      | packIds            |
      | partKeys           |
      | materialKeys       |
      | maxDefinitionBytes |
      | maxNameLength      |
      | maxSourceSlots     |
      | maxSourcePalette   |
