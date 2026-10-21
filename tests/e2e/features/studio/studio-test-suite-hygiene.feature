# THE PRE-MERGE STUDIO JOB'S BLIND SPOT — issue #537. The job installs NO Qt
# binding on purpose; a MODULE-LEVEL `pytest.importorskip("hugmesh_studio.gui.qt")`
# therefore skips the WHOLE file, including every Qt-free test above it, and
# `-q` reports it as one tidy SKIPPED. Measured on main: 40 Qt-free tests in two
# files never run in the job that gates a merge, and nothing is red.
#
# Two guards, both the issue's own "Done when":
#   * the executable rule — no test file may put a module-level importorskip
#     below a `def test_` (inside a fixture is the in-repo idiom and is fine);
#   * proof by EXECUTION — the file run with every Qt binding MISSING still
#     reports passing tests. A sitecustomize meta-path blocker on PYTHONPATH
#     makes PyQt6/PySide6 absent (the job's condition, and the issue's repro).
#     Skips loudly, naming what to install, when pytest itself is absent from
#     the Studio interpreter — never a green for a run that did not happen.
@layer:ui @harness
Feature: The Studio's Qt-free tests run in the job that gates a merge

  @interface:cli @issue:generator-537
  Scenario: the job's rule is on record: no Qt binding is installed on purpose @interface:cli
    When I run the shell command "grep -c 'NO Qt binding is installed on purpose' .github/workflows/studio-tests.yml"
    Then the command succeeded
    And the command output contains "1"

  @interface:cli @issue:generator-537 @fixme
  Scenario: no test file hides Qt-free tests below a module-level importorskip @interface:cli
    Then no Studio test file puts a module-level importorskip above a test function

  @interface:cli @issue:generator-537 @fixme
  Scenario Outline: <file> still runs its Qt-free tests with no Qt binding importable @interface:cli
    When I run the Studio test file "<file>" with no Qt binding on the path
    Then the command succeeded
    And the command output contains " passed"

    Examples:
      | file                                    |
      | studio/tests/test_flash_targets.py      |
      | studio/tests/test_local_mesh_stages.py  |
