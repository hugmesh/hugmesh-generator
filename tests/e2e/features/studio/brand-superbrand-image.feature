# J-SUPERBRAND-IMAGE — the image route in mesh mode, from the superbrand drop-down to
# the build command and the builder's own plan, in BOTH faces, including the
# unaffiliated refusal (hugmesh-generator#654, decisions D8 and D20; operator decision
# 71 = A: the window and the text screens offer the same controls).
#
# WHAT IS DRIVEN: the Studio's Branding page headless (QT_QPA_PLATFORM=offscreen) and the
# same step as text, with ONE script (studio/tests/journey/test_brand_superbrand_image.py):
#
#   A. 'Create a new superbrand' is the default; type its id, title, organisation and
#      public name; pick a colour; Next. The configuration then holds them, the Studio's
#      `--print-command` prints a build command carrying `--brand acme --brand-title
#      'Acme Mesh' --org example --cluster-domain mesh.example` (the same command from both
#      faces), and the builder's own `--print-plan` (build-x86-host-stage4.sh resolves and
#      validates every flag and builds nothing) says PLAN_BRAND=acme and
#      PLAN_CLUSTER_DOMAIN=mesh.example.
#   B. On an UNAFFILIATED image the drop-down is disabled with the reason drawn beside it,
#      no 'Create a new superbrand' item is offered, a brand typed in is refused, and the
#      look still takes a colour (identity refused, look allowed). The record writer, the
#      Studio's own check and the builder's `--print-plan` each refuse a brand identity
#      on it, in their own words.
#
# The summary line of each command is the LAST line of pytest's output with a space put in
# front of it, so ' 7 passed in ' cannot also match '17 passed in '. Every scenario
# asserts an exact count: a skipped window half (no Qt binding) is a RED scenario here,
# never a quiet pass.
#
# THE LIVE TIER (press Generate and start on a Docker mesh and assert brand B's sign-in
# and tenancy lines) needs a running Docker mesh: UNEXERCISED here.
@interface:studio @issue:generator-654
Feature: The image route's superbrand drop-down and design step agree in both faces

  Scenario: J-SUPERBRAND-IMAGE the window and the text screens reach the same build command and the builder's plan @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_superbrand_image.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 7 passed in "

  Scenario: the drop-down starts on 'Create a new superbrand', lists the saved designs and profiles after it, and hides it on an unaffiliated image with the reason @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_picker_model.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 21 passed in "

  Scenario: the window's drop-down, design step and Branding page do what the model says @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_screens_window.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 32 passed in "

  Scenario: every control the window offers has a text twin with the same items and the same words @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_tui_gui_parity.py -k 'superbrand or four_tabs or one_editing or summary_is_one or unaffiliated_reason or drop_down or identity_fields or fleet_window' 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 7 passed, "

  Scenario: the drop-down and the design step are drawn whole at 1040x780 and 736x736, under two styles and at 8 and 9 pt @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_brand_screens_look.py -k 'the_brand_screens_are_drawn_whole_in_a_fresh_interpreter' 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 1 passed, "
