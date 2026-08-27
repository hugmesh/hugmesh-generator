# The FOUNDATION lane for the environment and interface axes.
#
# Six scenarios, no decoration: three prove that each interface really produces
# its own kind of evidence and that the manifest indexes it, and three prove that
# each environment SKIPS WITH A NAMED REASON when it is not serving — never
# silently passes. Run these with nothing started and you should see 3 passed,
# 3 skipped, and three skip reasons naming three different commands to run.
@layer:ui
Feature: Every interface leaves evidence and every environment says what to start

  # ── browser ────────────────────────────────────────────────────────────────
  # NO @env: tag, deliberately. This is the LEGACY path every one of the 453
  # pre-existing scenarios takes: it resolves playwright.config.ts's own baseURL
  # and is not availability-gated. It navigates nowhere, so it proves the
  # screenshot evidence path without needing a stack.
  @interface:browser
  Scenario: the browser interface screenshots every step @interface:browser
    Then the scenario runs on the "browser" interface
    And the scenario drives the "docker" environment base URL
    And the evidence manifest holds a "screenshot" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # ── cli ────────────────────────────────────────────────────────────────────
  # A terminal has no screenshot. The transcript is the artefact of record, and
  # the exit code in it is the REAL one: this scenario asserts on 7, so a
  # transcript that laundered failures into 0 would fail here rather than pass
  # quietly.
  @interface:cli
  Scenario: the cli interface transcripts the real exit code @interface:cli
    When I run the shell command "echo hugmesh-cli-evidence; exit 7"
    Then the command exit code was 7
    And the command failed
    And the command output contains "hugmesh-cli-evidence"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # The Studio's Qt-free CLI channel — the same --print-specs path
  # docker/build-image.sh drives. Needs no stack and no display.
  @interface:cli
  Scenario: the Studio CLI channel answers offline @interface:cli
    When I run the Studio CLI with "--print-specs --json"
    Then the command succeeded
    And the command output is valid JSON
    And the evidence manifest holds a "transcript" artefact for this scenario

  # ── studio (gui) ───────────────────────────────────────────────────────────
  # The REAL PyQt wizard, offscreen. Grabbing a named page rather than whatever
  # page happens to be current is what stops a plausible PNG of the wrong screen
  # from passing for coverage.
  @interface:studio
  Scenario: the studio interface grabs a named wizard page @interface:studio
    When I grab the Studio wizard page "qemu"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "qemu"
    And the evidence manifest holds a "widget-grab" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk

  # ── the three environments ─────────────────────────────────────────────────
  # Each of these RUNS when its mesh is serving and SKIPS with a reason naming
  # exactly what to start when it is not. None of them can pass while its
  # environment is down — that is the property the mutation battery attacks.
  @env:docker @interface:browser
  Scenario: the docker compose mesh serves its front door @env:docker
    When I open the path "/"
    Then the URL matches "^https?://"

  @env:kind @interface:browser
  Scenario: the local devops cluster serves its ingress @env:kind
    When I open the path "/"
    Then the URL matches "^https?://"

  @env:qemu @interface:browser
  Scenario: the emulated device serves its forwarded UI port @env:qemu
    When I open the path "/"
    Then the URL matches "^https?://"
