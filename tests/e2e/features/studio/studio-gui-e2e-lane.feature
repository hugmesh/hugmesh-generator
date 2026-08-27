# THE STUDIO AS AN E2E DRIVER — the "gui" half of "through cli and gui".
#
# WHAT IS BEING PROVEN, in one sentence each:
#   * the Studio can CHOOSE which mesh an e2e run drives (docker | kind | qemu);
#   * that choice reaches the spawned run on the SAME channel a terminal uses
#     (SNAP_ENV), so the GUI and the CLI can never target different meshes;
#   * driving the Studio leaves a Qt WIDGET GRAB per Gherkin step, indexed in the
#     evidence manifest beside the browser's PNGs and the cli's transcripts;
#   * the Studio's own evidence READER accepts the run that just produced it.
#
# WHY THERE IS NO @env: TAG ON THE OUTLINES BELOW, AND WHY THAT IS DELIBERATE.
# `@env:` opts a scenario INTO availability gating: it skips when that mesh is
# not serving. These scenarios are about the CHOOSER, not about the mesh — the
# Studio must be able to plan a kind run on a box with no cluster, and that plan
# must still be correct. Gating them would make the whole lane vanish on a
# developer box, which is the decoration this suite forbids. So the environment
# under test rides in an Examples column named `chosen` (NOT `env`), which is
# ordinary data rather than the dimension axis. The three availability-gated
# environment scenarios already exist, once, in
# features/platform/env-interface-evidence.feature; duplicating them here would
# fragment the vocabulary for no coverage.
#
# EVERY SCENARIO HERE RUNS WITH NOTHING STARTED. Nothing in this file brings up
# a stack, a cluster or a device — 'the e2e plan starts no environment' asserts
# that against the Python module's own BOOT_COMMANDS list.
@layer:ui
Feature: The Studio drives e2e runs, chooses their environment, and photographs itself

  # ── one contract, two front-ends ───────────────────────────────────────────
  # The GUI's plan and the CLI's plan are compared FIELD BY FIELD. "Both mention
  # kind" is satisfied by two mechanisms that agree today and drift tomorrow.
  @interface:studio
  Scenario Outline: the Studio GUI and its CLI plan the same run for <chosen> @interface:studio
    When I drive the Studio e2e chooser to "<chosen>"
    Then the Studio reports the "<chosen>" e2e environment
    And the Studio grab is a non-empty PNG
    When I ask the Studio CLI for the e2e plan for "<chosen>"
    Then the command succeeded
    And the command output is valid JSON
    And the Studio GUI and the Studio CLI plan the same e2e run
    And the e2e plan pins "SNAP_ENV" to "<chosen>"
    And the e2e plan runs "make stack-e2e-bdd-env"
    And the e2e plan starts no environment
    And the e2e plan is runnable

    Examples:
      | chosen |
      | docker |
      | kind   |
      | qemu   |

  # ── the per-environment pins ───────────────────────────────────────────────
  # SNAP_ENV alone is not enough for kind: its ingress matches on Host and
  # hugmesh.net does not resolve on a developer box, which is why `make kind-e2e`
  # passes chromium host-resolver rules rather than editing /etc/hosts. A plan
  # that carried only SNAP_ENV would send every kind scenario into a DNS failure
  # that reads like "kind is broken" instead of "a variable is missing".
  @interface:cli
  Scenario: the kind plan carries the host-resolver rules, not just the environment @interface:cli
    When I ask the Studio CLI for the e2e plan for "kind"
    Then the command succeeded
    And the e2e plan pins "SNAP_ENV" to "kind"
    And the e2e plan pins "SNAP_BASE_URL" to "https://hugmesh.net:8443"
    And the e2e plan pins "SNAP_HOST_RESOLVER" to "MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1"
    And the evidence manifest holds a "transcript" artefact for this scenario

  # ── the refusal ────────────────────────────────────────────────────────────
  # Asking the Studio to BRING A MESH UP is refused, and the refusal is a
  # sentence naming what to type. For qemu the reason is specific and expensive:
  # its launcher needs root, and on this box an unanswerable password prompt does
  # not fail — it hangs as a root process only a human can clear. A refusal that
  # merely said "not supported" would send the reader to the source.
  @interface:cli
  Scenario: the Studio refuses to bring an environment up, and says what to run instead @interface:cli
    When I run the Studio CLI with "--e2e-plan --e2e-env qemu --e2e-boot --json"
    Then the command succeeded
    And the command output is valid JSON
    And the command output contains "requires root"
    And the command output contains "run-qemu-e2e.sh"

  # An unknown environment is refused LOUDLY, naming every legal value — the same
  # rule steps/dimensions.ts holds the harness to. A near-twin ('compose', 'k8s',
  # 'vm') is rejected on purpose: a second spelling for one mesh fragments the
  # vocabulary worse than a hard error does.
  @interface:cli
  Scenario: an unknown environment is refused naming the legal set @interface:cli
    When I run the Studio CLI with "--e2e-plan --e2e-env compose --json"
    Then the command failed
    And the command output contains "docker, kind, qemu"
    And the command output contains "near-twin"

  # ── the GUI photographs itself, per step ───────────────────────────────────
  # THIS is what "take screenshots ... through gui" means: the Studio's own
  # surfaces, grabbed offscreen as the scenario walks them. Three consecutive
  # driving steps, three separate grabs, all three indexed — a single
  # end-of-scenario picture would not show which step changed what.
  @interface:studio
  Scenario: walking the Studio leaves one Qt widget grab per step @interface:studio
    When I drive the Studio e2e chooser to "docker"
    And I drive the Studio e2e chooser to "kind"
    And I drive the Studio e2e chooser to "qemu"
    Then the Studio reports the "qemu" e2e environment
    And a Qt widget grab exists on disk for every Studio step so far
    And the evidence manifest holds a "widget-grab" artefact for this scenario
    And every evidence artefact recorded for this scenario exists on disk
    And every evidence row for this scenario names an environment and an interface

  # A named wizard page still grabs, unchanged — the pre-existing capability this
  # lane builds on. Reuses common.steps.ts verbatim rather than restating it.
  @interface:studio
  Scenario: the Studio still grabs a named wizard page @interface:studio
    When I grab the Studio wizard page "localmesh"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "localmesh"
    And the evidence manifest holds a "widget-grab" artefact for this scenario

  # ── the consumer contract ──────────────────────────────────────────────────
  # The Studio's evidence browser reads manifest.json. Here the reader it is
  # built on is run over THIS run's own directory, so the producer and the
  # consumer are exercised against each other rather than each against a fixture
  # that agrees with itself. A row pointing at an absent file, or a file with no
  # row, fails this — in both directions.
  @interface:cli
  Scenario: the Studio's evidence reader accepts the run that produced the evidence @interface:cli
    When I run the shell command "echo studio-evidence-reader-probe"
    Then the command output contains "studio-evidence-reader-probe"
    And the evidence manifest holds a "transcript" artefact for this scenario
    And the Studio evidence reader verifies this run
