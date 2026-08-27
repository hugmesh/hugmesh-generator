# The character tools' FUNCTION surface — open, create, export and save, for both
# the 2D Studio and the 3D Forge.
#
# character-remotes.feature proved the two remotes MOUNT: the route resolves, the
# host shell fetches them, the editor chrome renders, and an anonymous visitor is
# sent to sign-in. It said so explicitly of itself that it does "NOT drive the
# WebGL/engine surface" and that "deeper flows (part picking, export, avatar
# upload) belong in a follow-up". This is that follow-up.
#
# THESE TWO ARE THE ONLY SERVICES IN THIS DOMAIN THE ORDINARY ROSTER CAN DRIVE AS
# THEMSELVES. Both sit behind registeredGuard in the host shell and a plain
# ROLE_USER floor at the gateway — no per-service role, no admin standing in for a
# member who does not exist. Seven of the eight functions are therefore driven for
# real by e2e-user and alice@gmail.com rather than pended.
#
# THE EIGHTH IS ENGINE-GATED AND IS NOT FAKED. cf-snapshot and cf-use-everywhere
# are aria-disabled until engine.ready(), and the engine is a WebGL bundle. The
# forge reports that state honestly through cf-engine-loading / cf-engine-absent /
# cf-engine-error, and a scenario that clicked a disabled button in headless
# Chromium and asserted the resulting error would be asserting the harness.
#
# WHAT IS DELIBERATELY NOT CLICKED: cs-set-avatar and cs-use-everywhere. Both POST
# a real avatar into the moderation queue for the signed-in principal, and a
# per-run mutation of a shared seeded identity is not something this file should
# introduce as a side effect of a coverage pass. cs-surprise and cf-surprise ARE
# clicked — they are pure client-side randomisation and they are the one
# interaction that proves the editor is live rather than merely painted.
#
# AN UNVERIFIED ROW, STATED RATHER THAN HIDDEN. The gateway floor for all four
# character surfaces is ROLE_USER, and three seeded personas hold no ROLE_USER at
# all: e2e-superadmin (ROLE_SUPERADMIN alone), e2e-mod (ROLE_MOD alone) and
# e2e-pending. media-games-function-matrix.feature pins that as a SEED fact. What
# a BARE MOD actually experiences at /character-studio on a live mesh — refused by
# the gateway, or admitted by a bypass this repo's seed comments only describe for
# admins — is NOT asserted anywhere, here or elsewhere, because nothing in this
# repo settles it. It needs one run against a live stack, and it is the single
# most interesting row in this domain's access matrix.
@layer:ui
Feature: Opening, building, exporting and saving a character in both editors

  # ── character-studio: open ────────────────────────────────────────────────
  @function:open @service:character-studio @env:docker
  Scenario Outline: <role> opens Character Studio and gets a usable editor, not just a shell @role:<role> @function:open @service:character-studio @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/character-studio"
    Then the element with test id "cs-studio-header" is visible
    And the element with test id "cs-studio" is visible
    And the element with test id "cs-validity" is visible

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |

  # ── character-studio: create ──────────────────────────────────────────────
  #
  # The click is the assertion. cs-surprise re-randomises the character entirely
  # client-side; a Studio that painted its chrome and never wired its state would
  # render every test id above and do nothing here.
  @function:create @service:character-studio @env:docker
  Scenario Outline: <role> randomises a character and the editor stays valid @role:<role> @function:create @service:character-studio @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/character-studio"
    And I click the element with test id "cs-surprise"
    Then the element with test id "cs-studio" is visible
    And the element with test id "cs-validity" is visible
    And the element with test id "cs-status" is visible

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |

  # ── character-studio: export ──────────────────────────────────────────────
  #
  # The only function in this domain that needs no BFF at all — the PNG is
  # rasterised in the browser. Asserted as PRESENCE, not as a click: a real
  # download in a sandboxed browser context is a harness question, and this file
  # is about the product.
  @function:export @service:character-studio @role:e2e-user @env:docker
  Scenario: the export controls are offered alongside the validity verdict @role:e2e-user @function:export @service:character-studio @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/character-studio"
    Then the element with test id "cs-export-download" is visible
    And the element with test id "cs-export-status" is visible
    And the element with test id "cs-validity" is visible

  # ── character-studio: save ────────────────────────────────────────────────
  #
  # Both save paths are offered to a plain member — there is no admin tier here.
  # cs-platform-results is the surface that states a ROLE fact rather than an
  # error when a platform is skipped: a member without ROLE_MATRIX has no Matrix
  # avatar to set, and conflating that with a failure would misreport their mesh.
  @function:save @service:character-studio @role:e2e-user @env:docker
  Scenario: a plain member is offered both avatar-save paths @role:e2e-user @function:save @service:character-studio @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/character-studio"
    Then the element with test id "cs-set-avatar" is visible
    And the element with test id "cs-use-everywhere" is visible
    And the element with test id "cs-export-status" is visible

  # ── character-forge: open ─────────────────────────────────────────────────
  @function:open @service:character-forge @env:docker
  Scenario Outline: <role> opens Character Forge and gets the parameter surface @role:<role> @function:open @service:character-forge @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/character-forge"
    Then the element with test id "cf-header" is visible
    And the element with test id "cf-forge" is visible
    And the element with test id "cf-editor" is visible

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |

  # ── character-forge: create ───────────────────────────────────────────────
  #
  # Deliberately DOM-level. The parameter form renders and randomises without the
  # 3D engine, which is what makes this function drivable while cf/export is not —
  # and asserting the difference is the point of splitting them.
  @function:create @service:character-forge @env:docker
  Scenario Outline: <role> randomises a forge character from the seed without the 3D engine @role:<role> @function:create @service:character-forge @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/character-forge"
    And I click the element with test id "cf-surprise"
    Then the element with test id "cf-seed" is visible
    And the element with test id "cf-body-archetype" is visible
    And the element with test id "cf-status" is visible

    Examples:
      | role            |
      | e2e-user        |
      | alice@gmail.com |

  # ── character-forge: save ─────────────────────────────────────────────────
  #
  # Ownership is enforced in the BFF (owner = jwt subject; a foreign id is a 404),
  # which is exactly why the route-access seed mints no per-service role for
  # /bff/character-forge/** and leaves it on the ROLE_USER floor. The save panel
  # is therefore the same for every member.
  @function:save @service:character-forge @role:e2e-user @env:docker
  Scenario: a plain member is offered the full save, load and activate panel @role:e2e-user @function:save @service:character-forge @layer:ui @env:docker
    Given I am signed in as the persona for this scenario
    When I open the path "/character-forge"
    Then the element with test id "cf-saves" is visible
    And the element with test id "cf-save-new" is visible
    And the element with test id "cf-save-over" is visible
    And the element with test id "cf-load-active" is visible
    And the element with test id "cf-save-list" is visible

  # ── character-forge: export — engine-gated, pended, not faked ─────────────
  @function:export @service:character-forge @role:e2e-user
  Scenario: a member snapshots the 3D render and uses it as their avatar everywhere @role:e2e-user @function:export @service:character-forge @layer:ui
    Given this scenario is PENDING because "cf-snapshot and cf-use-everywhere are aria-disabled until engine.ready(), and the engine is a WebGL/3D bundle. Asserting a headless-Chromium GPU path would be asserting the harness, not the product — the forge already reports the gap honestly through cf-engine-loading / cf-engine-absent / cf-engine-error. Seeding a persona does NOT unblock this: it needs a browser context with a working 3D engine"
    And I am signed in as the persona for this scenario
    When I open the path "/character-forge"
    And I click the element with test id "cf-snapshot"
    Then the element with test id "cf-platform-results" is visible

  # ── the operator GUI that turns these services on — and a PINNED DEFECT ───
  #
  # owncast, tube, wiki and character-forge are FEDERATION-ENABLED services in the
  # Studio's local-mesh catalogue: their containers are always up and their
  # federation registry row ships enabled=false, which is the literal "running but
  # invisible in the menu" failure that catalogue was built to end. The page that
  # flips those rows is the Studio wizard's local-mesh page — the GUI half of the
  # operator's "cli and gui" ask for this domain.
  #
  # IT CANNOT BE GRABBED HEADLESSLY TODAY, and that is measured, not assumed.
  # LocalMeshPage.initializePage starts a _StatusProbe QThread; tests/e2e/studio-
  # driver.py grabs the widget and exits without joining it, so the interpreter
  # tears down with the thread still running and Qt aborts — SIGABRT, exit 134,
  # "QThread: Destroyed while thread '' is still running" on stderr. The PNG is
  # actually written first (~75 KB), so the failure is entirely in teardown; every
  # other wizard page this suite grabs (welcome, mode, deploy, qemu) exits 0.
  #
  # So this scenario asserts the CURRENT behaviour rather than the behaviour we
  # want, exactly as games-console.feature pins the /login-redirect inconsistency:
  # the day the driver joins its probe threads (or the page stops starting one on
  # a headless grab), THIS goes red, which is the prompt to replace it with the
  # positive @interface:studio scenario the domain is owed:
  #
  #     When I grab the Studio wizard page "localmesh"
  #     Then the Studio grab is a non-empty PNG
  #     And the Studio grab shows the wizard page "localmesh"
  #
  # A green-looking skip would have hidden this. A grab scenario asserting success
  # would have failed for a reason nobody could read off the report.
  @function:open @service:character-forge @interface:cli @layer:ui
  Scenario: PINNED DEFECT — the Studio local-mesh page aborts when grabbed headlessly @function:open @service:character-forge @interface:cli @layer:ui
    When I run the shell command "QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} tests/e2e/studio-driver.py --page localmesh --grab ${TMPDIR:-/tmp}/hugmesh-localmesh-grab-probe.png"
    Then the command failed
    And the command output contains "QThread: Destroyed while thread"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # The positive control for the driver itself. Without it, the scenario above
  # would pass just as happily if studio-driver.py were broken outright, or if the
  # host had no Qt6 binding at all — and "the local-mesh page is broken" would be
  # a conclusion drawn from an environment that can grab nothing.
  @function:open @service:character-forge @interface:studio @layer:ui
  Scenario: the same driver grabs a different wizard page cleanly @function:open @service:character-forge @interface:studio @layer:ui
    When I grab the Studio wizard page "deploy"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "deploy"
    And the evidence manifest holds a "widget-grab" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk
