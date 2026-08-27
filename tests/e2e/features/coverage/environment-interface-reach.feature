# ─────────────────────────────────────────────────────────────────────────────
# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Emitted by tests/e2e/tools/emit-coverage-matrix.ts from three catalogues:
#   personas   specs/rbac-roles.ts SYSTEMS_SEED_USERS
#              + tests/e2e-extra-personas.sh
#              + tests/qemu/seed-accounts.sh SYSTEMS_ROLE_USERS
#   services   tests/e2e/steps/dimensions.ts SERVICES
#   functions  tests/e2e/steps/coverage-catalogue.ts FUNCTIONS
#
# Regenerate with:  bash tests/e2e/gen-coverage-matrix.sh
# The drift guard tests/scripts/test-e2e-coverage-matrix.sh re-emits into a
# scratch dir and DIFFS against these files, so an edit here — or a catalogue
# change that was never re-emitted — turns the guard RED.
# ─────────────────────────────────────────────────────────────────────────────
#
# THE OPERATOR'S SECOND REQUIREMENT: evidence "in docker, local devops, and qemu
# emulated e2e testing through cli and gui".
#
# 3 environments x 3 interfaces = 9 cells, every one tagged so it either RUNS
# and leaves its own kind of artefact, or SKIPS naming exactly what to start.
# None of them can pass while its environment is down — that is the whole point
# of the @env: gate (steps/world.ts Before), and it is why this lane is honest
# on a laptop with nothing running: 9 skips, 9 named reasons, 0 false greens.
#
# The @interface: axis decides the artefact of record: a PNG for browser, a
# TRANSCRIPT for cli (a terminal has no screenshot), a Qt WIDGET GRAB for the
# Studio GUI. Each Studio cell grabs the wizard page that actually corresponds
# to its environment — localmesh for the compose stack, localcloud for the kind
# devops cluster, qemu for an emulated device — so a grab of the wrong screen
# cannot pass for coverage of the right one.
@layer:ui @coverage-matrix
Feature: Every environment leaves evidence through every interface

  @env:docker @interface:browser
  Scenario: browser evidence in the docker environment @env:docker @interface:browser
    When I open the path "/"
    Then the scenario drives the "docker" environment base URL
    And the evidence manifest holds a "screenshot" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:docker @interface:cli
  Scenario: cli evidence in the docker environment @env:docker @interface:cli
    When I run the shell command "echo hugmesh-coverage-docker-cli"
    Then the command succeeded
    And the command output contains "hugmesh-coverage-docker-cli"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:docker @interface:studio
  Scenario: studio evidence in the docker environment @env:docker @interface:studio
    When I grab the Studio wizard page "localmesh"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "localmesh"
    And the evidence manifest holds a "widget-grab" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:kind @interface:browser
  Scenario: browser evidence in the kind environment @env:kind @interface:browser
    When I open the path "/"
    Then the scenario drives the "kind" environment base URL
    And the evidence manifest holds a "screenshot" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:kind @interface:cli
  Scenario: cli evidence in the kind environment @env:kind @interface:cli
    When I run the shell command "echo hugmesh-coverage-kind-cli"
    Then the command succeeded
    And the command output contains "hugmesh-coverage-kind-cli"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:kind @interface:studio
  Scenario: studio evidence in the kind environment @env:kind @interface:studio
    When I grab the Studio wizard page "localcloud"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "localcloud"
    And the evidence manifest holds a "widget-grab" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:qemu @interface:browser
  Scenario: browser evidence in the qemu environment @env:qemu @interface:browser
    When I open the path "/"
    Then the scenario drives the "qemu" environment base URL
    And the evidence manifest holds a "screenshot" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:qemu @interface:cli
  Scenario: cli evidence in the qemu environment @env:qemu @interface:cli
    When I run the shell command "echo hugmesh-coverage-qemu-cli"
    Then the command succeeded
    And the command output contains "hugmesh-coverage-qemu-cli"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  @env:qemu @interface:studio
  Scenario: studio evidence in the qemu environment @env:qemu @interface:studio
    When I grab the Studio wizard page "qemu"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "qemu"
    And the evidence manifest holds a "widget-grab" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk
