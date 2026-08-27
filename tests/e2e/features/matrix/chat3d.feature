# Executable form of tests/e2e/specs/32-matrix-chat3d.spec.ts — the Matrix 3D chat
# room (the shadows-of-the-net Godot WASM export) and character generation.
#
# THREE SEPARATE CLAIMS, three scenarios, so a failure names which one broke:
#   A. DELIVERY  — the exported bundle is served intact, and index.wasm carries the
#      application/wasm MIME. That MIME is load-bearing, not cosmetic:
#      octet-stream forces Godot onto the slow NON-streaming instantiation path.
#   B. BOOT      — the room boots headless and the host publishes my avatar as room
#      state. The loading banner clears on the FIRST validated game->host envelope,
#      which only the real wasm running inside the iframe can send, so a banner that
#      clears is proof the bundle actually ran.
#   C. GENERATION— a character created and activated through the character-forge BFF
#      is OFFERED BY NAME in the join menu (not greyed — an invalid definition would
#      null out and disable the radio) and its distinctive config values are found in
#      the published avatar state.
#
# B and C use DIFFERENT personas on purpose, so C's active forge character can never
# bleed into B's join menu and make a guest-mode assertion pass for the wrong reason.
#
# LANE GATING, NEVER SILENT. When the bundle was not assembled the scenarios skip
# naming the exact up.sh warning and the build command; when the lane has no
# /_remotes/** URL space at all (the compose gateway routes /_fragments/** and
# answers 403) they skip naming that instead. Both reasons are printed; neither
# degrades into a pass.
# NOTE ON TAGS: the @service: axis is declared per SCENARIO here, never on the
# Feature, because the three scenarios genuinely sit on different services (the
# games bundle, the Matrix room, the character-forge BFF). A Feature-level tag plus
# a differing Scenario-level one would leave the resolved dimension depending on
# tag ORDER, which is not a contract playwright-bdd makes.
@layer:ui
Feature: The Matrix 3D chat room boots and wears a generated character

  @service:games @layer:gateway
  Scenario: the shadows-of-the-net wasm bundle is delivered intact
    Given the shadows-of-the-net wasm bundle is served on this lane
    Then the wasm bundle file "index.html" is served with status 200
    And the wasm bundle file "index.js" is served with status 200
    And the wasm bundle file "index.wasm" is served with status 200
    And the wasm bundle file "index.pck" is served with status 200
    And the wasm bundle file "index.wasm" is served as "application/wasm"

  @role:e2e-matrix @service:tuwunel
  Scenario: entering as a guest boots the wasm and publishes a guest avatar as room state
    Given the shadows-of-the-net wasm bundle is served on this lane
    And I am signed in as the persona for this scenario
    And I create a fresh Matrix room named "e2e chat3d boot" with the 3D chamber enabled
    When I open the 3D room join menu
    And I choose the guest avatar source
    And I enter the 3D room and wait for the wasm to boot
    Then no chat3d avatar publish note is shown
    And my published chat3d avatar state has mode "guest"

  @role:e2e-matrix-groupchat @service:character-forge
  Scenario: a generated forge character is offered by name and rides the published avatar
    Given the shadows-of-the-net wasm bundle is served on this lane
    And I am signed in as the persona for this scenario
    And I create and activate a forge character named "E2E Forge Dragon"
    And I create a fresh Matrix room named "e2e chat3d forge" with the 3D chamber enabled
    When I open the 3D room join menu
    Then the 3D join menu offers my forge character by name
    When I choose the forge avatar source
    And I enter the 3D room and wait for the wasm to boot
    Then my published chat3d avatar state has mode "forge"
    And my published chat3d avatar carries the forge character
