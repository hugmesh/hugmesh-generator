# THE RESTRUCTURED STUDIO PAGES — render-level guards for landed GUI work that
# stays open only for a person clicking it on a real display (#334, #335's
# sibling #336, #337, #341), plus the two open pieces whose Studio surface is
# observable offscreen (#515, #538).
#
# WHAT A GRAB PROVES AND WHAT IT DOES NOT. The offscreen driver builds the REAL
# StudioWizard, jumps to a page by slug and grabs it; the result also carries
# the page's visible texts and controls. So a scenario here proves the page
# exists, renders without crashing, and SAYS what the landing claimed (a header,
# a card, a column). It does not click: card ROUTING, the −/+/Apply scale
# interaction, the flash OK/Cancel dialog and a real stop/restart are the
# "Human must verify" lists on the issues, and stay there.
@layer:ui
Feature: The Studio's restructured pages render offscreen and say what they now carry

  # ── #334: the local-mesh tabs became two choice cards + seven wizard steps ──
  @interface:studio @issue:generator-334
  Scenario: the local-mesh entry is the two-card choice page, not a tab widget @interface:studio
    When I grab the Studio wizard page "localmesh_choice"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "localmesh_choice"
    And the Studio control "Join an existing mesh with a key" is enabled
    And the Studio control "Generate a new mesh" is enabled
    And the evidence manifest holds a "widget-grab" artefact for this scenario

  @interface:studio @issue:generator-334
  Scenario Outline: the bootstrap surface is a wizard step of its own: <page> @interface:studio
    When I grab the Studio wizard page "<page>"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "<page>"

    Examples:
      | page                |
      | localmesh_join      |
      | localmesh_env       |
      | localmesh_source    |
      | localmesh_services  |
      | localmesh_idp       |
      | localmesh_overlay   |
      | localmesh_review    |
      | localmesh           |

  @interface:studio @issue:generator-334
  Scenario: the Environment & brand step offers the test and prod cards with test pre-selected @interface:studio
    When I grab the Studio wizard page "localmesh_env"
    Then the Studio grab shows the wizard page "localmesh_env"
    And the Studio page says "Environment"
    And the Studio control "test" is enabled
    And the Studio control "prod" is enabled

  @interface:studio @issue:generator-334
  Scenario: the review step owns the run surface (status, log, stage table) after the restructure @interface:studio
    When I grab the Studio wizard page "localmesh_review"
    Then the Studio grab shows the wizard page "localmesh_review"
    And the Studio page says "Plan preview"
    And the Studio page says "Log"
    And the Studio page says "Stage"

  # ── #336: the pod monitor on both emulation screens, Replicas on the device table ──
  @interface:studio @issue:generator-336
  Scenario: the mesh emulation screen's device table carries the Replicas column, and says its ceiling @interface:studio
    When I grab the Studio wizard page "meshemu"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "meshemu"
    And the Studio page says "Replicas (0/1)"
    And the Studio page says "Device"
    And the Studio page says "State"

  @interface:studio @issue:generator-336
  Scenario: the QEMU device-test screen still renders with the shared monitor mounted @interface:studio
    When I grab the Studio wizard page "qemu"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "qemu"
    And the Studio page says "What should the tests run against?"

  # ── #341: the generate-mesh page's own pod table, scaling wired ───────────
  # The table is collapsed and greyed until a mesh runs, so its Replicas header
  # is not visible offscreen with nothing up; the page must still build and
  # render with `scaling=True` and its receiver connected (pinned by
  # studio/tests/test_localmesh_monitor.py). Render-level only here.
  @interface:studio @issue:generator-341
  Scenario: the generate-mesh page renders with the scaling table mounted @interface:studio
    When I grab the Studio wizard page "localmesh"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "localmesh"
    And the Studio page says "Actions"
    And the Studio page says "Log"

  # ── #337: flash-path validation is one OK/Cancel warning ──────────────────
  # The dialog fires only from the click handler that starts a flash, behind the
  # module-level `confirm_flash` seam (studio/tests/test_flash_targets.py pins
  # it). Offscreen, the progress page must build and render.
  @interface:studio @issue:generator-337
  Scenario: the progress page renders after the flash-check rewrite @interface:studio
    When I grab the Studio wizard page "progress"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "progress"
    And the Studio page says "Log"

  # ── #515: containerized mode + Studio device records (optional phase) ─────
  @interface:studio @issue:generator-515
  Scenario: the emulation screen lists device records per node, with the columns the TUI mirrors @interface:studio
    When I grab the Studio wizard page "meshemu"
    Then the Studio grab shows the wizard page "meshemu"
    And the Studio page says "Device"
    And the Studio page says "Role"
    And the Studio page says "State"
    And the Studio page says "SSH"

  # The other half needs a REAL containerized mesh-cluster run (tests/qemu/
  # docker-entrypoint.sh, HUGMESH_QEMU_MESH=1) that has completed and left its
  # session under out/sessions — a root-capable, hours-long lane no e2e step
  # may start. Recorded here, so the census sees it; never faked.
  @issue:generator-515
  Scenario: a containerized 3-node mesh-cluster run appears as three device records on the emulation screen
    Given this scenario is PENDING because "a completed containerized HUGMESH_QEMU_MESH=1 run is the fixture, and starting one is a privileged, hours-long operator action (the phase is optional per #48 and may be declined instead)"
    When I run the shell command "true"
    Then the command succeeded

  # ── #538: resume into Bring-up-and-monitor when a mesh is already running ──
  # Driveable half: with the docker mesh serving, the wizard should OPEN on the
  # monitor step ("localmesh" — the bring-up & monitor page) rather than on
  # welcome. The driver reports the entry page by slug for exactly this.
  # @env:docker gates it on the compose door actually answering.
  @interface:studio @issue:generator-538 @fixme @env:docker
  Scenario: with a docker mesh already running, the Studio opens on Bring-up-and-monitor, not on Welcome @interface:studio
    When I grab the Studio wizard
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "localmesh"
    And the Studio page says "Log"

  # The backfill half — every option and every domain's configuration read back
  # from the running mesh WITH provenance (read from the mesh / from a saved
  # record / unknown) — has no surface yet in any lane (docker, kind, KEYS).
  @issue:generator-538
  Scenario: the monitor page backfills every domain's configuration from the running mesh, with provenance
    Given this scenario is PENDING because "no Studio surface recovers per-domain config from a running docker, kind or KEYS-provisioned mesh yet (#538 'Done when' boxes 2-5); the driver will read the backfilled fields off the page once one exists"
    When I run the shell command "true"
    Then the command succeeded
