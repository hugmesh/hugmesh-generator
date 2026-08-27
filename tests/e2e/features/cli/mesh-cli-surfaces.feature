# THE CLI LANE. Every scenario here drives a real command line of this repo and
# asserts on what really came back, with the transcript evidence the interface
# axis defines (steps/dimensions.ts, features/README.md sections 2e/2f).
#
# THREE PROPERTIES, and nothing decorative:
#   1. the ONE entry point (tests/e2e/run.sh) resolves each of the three meshes
#      to the SAME base URL the harness resolves, forwards the tag expression to
#      the generator and the feature selection to the runner, and refuses an
#      environment it does not know instead of quietly using the default;
#   2. the mesh's own offline CLI surfaces answer for every environment WITHOUT
#      that environment running -- `make help`, the Studio's Qt-free channels,
#      the qemu matrix enumerator, the kind honesty guard;
#   3. this run's evidence is reachable FROM A TERMINAL, summarised per
#      environment and per interface, and an empty summary is an error.
#
# NOTHING HERE STARTS ANYTHING. No @env: tag either: every command below is
# answerable with all three meshes down, so gating them on availability would
# turn honest coverage into permanent skips. The scenarios that genuinely need a
# mesh live in features/platform/env-interface-evidence.feature.
@interface:cli
Feature: the whole mesh is drivable, and leaves evidence, from a terminal

  # ---- 1. the one entry point ----------------------------------------------

  # GENERATIVE over the environment catalogue: adding a mesh to
  # ENVIRONMENT_DEFS and to run.sh's table adds a row here, and a mesh added to
  # only one of the two fails the base-URL assertion below rather than drifting.
  #
  # The column is `mesh`, NOT `env`. An `env` column plus an `@env:<v>` name
  # suffix is the spelling that binds the AVAILABILITY-GATED environment axis;
  # these scenarios ask the CLI *about* a mesh from the default one, so
  # borrowing that spelling would gate them on a cluster they never touch.
  Scenario Outline: the lane CLI resolves the <mesh> mesh and starts nothing
    When I run the e2e CLI with "--print-command --bdd --env <mesh>"
    Then the command succeeded
    And the command output is valid JSON
    And the command output JSON field "env" is "<mesh>"
    And the command output JSON field "baseUrl" is the "<mesh>" environment base URL
    And the command output JSON field "startHint" contains "<start>"
    And the command output JSON field "argv.0" is "npx"

    Examples:
      | mesh   | start             |
      | docker | stack-up          |
      | kind   | kind-up           |
      | qemu   | run-qemu-e2e.sh   |

  # A typo'd environment must die naming the legal set. Falling through to the
  # default would produce a fully green run against the wrong mesh -- the exact
  # failure the environment axis exists to prevent.
  Scenario: the lane CLI refuses a mesh it does not know, naming the ones it does
    When I run the e2e CLI with "--print-command --env kubernetes"
    Then the command failed
    And the command output contains "docker, kind, qemu"

  # A tag expression belongs to the GENERATOR (bddgen --tags) and the feature
  # selection belongs to the RUNNER. Sending either to the other silently runs
  # the whole suite while the operator believes they narrowed it.
  Scenario: a tag expression reaches the generator and the lane reaches the runner
    When I run the e2e CLI with "--print-command --tags @interface:cli"
    Then the command succeeded
    And the command output JSON field "tags" is "@interface:cli"
    And the command output JSON field "generateArgv" contains "--tags"
    And the command output JSON field "argv" contains "--project=bdd"

  # An operator types a SOURCE path; playwright collects the GENERATED mirror.
  # If the translation were dropped, playwright would be handed a path that
  # matches nothing and would report a cheerful "0 tests" instead of an error.
  Scenario: a feature path is translated to the generated mirror the runner collects
    When I run the e2e CLI with "--print-command --features cli/"
    Then the command succeeded
    And the command output JSON field "features.0" is ".features-gen/features/cli/"
    And the command output JSON field "argv" contains ".features-gen/features/cli/"

  # BACKWARD COMPATIBILITY, asserted rather than assumed. tests/e2e/run-all.sh
  # and tests/qemu/run-qemu-e2e.sh both invoke this script with no new flag and
  # must keep getting the legacy run: no bdd project, no generation step.
  Scenario: with no options the lane CLI still plans the legacy run
    When I run the e2e CLI with "--print-command"
    Then the command succeeded
    And the command output JSON field "lane" is "legacy"
    And the command output JSON field "generate" is "false"
    And the command output JSON field "argv" contains "playwright"

  # ---- 2. the mesh's own offline CLI surfaces ------------------------------

  # GENERATIVE over the Makefile targets this lane owns. A target renamed
  # without updating `make help` stops being discoverable, which is how a lane
  # ends up with two divergent invocations again.
  Scenario Outline: make help advertises the Gherkin lane target <target>
    When I run the shell command "make help"
    Then the command succeeded
    And the command output contains "<target>"

    Examples:
      | target                  |
      | stack-e2e-bdd           |
      | stack-e2e-bdd-gen       |
      | stack-e2e-bdd-check     |
      | stack-e2e-bdd-evidence  |

  # The Studio is a Qt GUI, but docker/build-image.sh already drives it through
  # a Qt-FREE channel. Those channels are a supported interface and are asserted
  # as one: they must answer machine-readable JSON with no display, no stack and
  # no device.
  Scenario Outline: the Studio's Qt-free channel <channel> answers with no display
    When I run the Studio CLI with "<channel>"
    Then the command succeeded
    And the command output is valid JSON

    Examples:
      | channel                |
      | --list-sessions --json |
      | --scan-hardware --json |

  # The qemu environment's CLI surface, exercised with NO emulator running and
  # NO root. Enumerating every device row is the honest offline half of a lane
  # whose other half cannot run in this environment at all.
  Scenario: the qemu lane enumerates every device row without booting one
    When I run the shell command "make qemu-matrix-enumerate"
    Then the command succeeded
    And the command output contains "no boot, no build"

  # The kind environment's CLI surface, likewise: the bootstrap honesty guard is
  # designed to run with no cluster, and a lane that cannot be checked offline
  # is a lane nobody checks.
  Scenario: the kind lane's offline honesty guard runs with no cluster
    When I run the shell command "make kind-honesty"
    Then the command succeeded
    And the command output contains "0 failed"

  # ---- 3. evidence, from a terminal ----------------------------------------

  # The manifest is only useful if you can find it. This runs a command (which
  # writes a transcript artefact), then asks the SAME entry point where this
  # run's evidence is -- and the answer must already count the artefact the step
  # above just produced, broken down by the two axes the operator asked for.
  Scenario: this run's evidence is reachable and summarised from the terminal
    When I run the shell command "echo hugmesh-cli-lane-evidence"
    Then the command succeeded
    When I run the e2e CLI with "--evidence --json"
    Then the command succeeded
    And the command output is valid JSON
    And the command output JSON field "counts.artefacts" is at least 1
    And the command output JSON field "counts.byInterface.cli" is at least 1
    And the command output JSON field "counts.missingOnDisk" is "0"

  # A summariser that prints "0 artefacts" and exits 0 is the silent-skip
  # failure this repo keeps paying for: the lane looks like it ran and left
  # nothing worth keeping. It must be an ERROR, and it must say where it looked.
  Scenario: the evidence summary refuses to report an empty success
    When I run the e2e CLI with "--evidence --report-dir /var/tmp/hugmesh-bdd-absent-report-dir --run-id nothing-ran-here"
    Then the command failed
    And the command output contains "no evidence directory"
