# J-FLEET — the Fleet window and its text twin offer the same superbrand drop-down, and
# choosing 'Create a new superbrand' there writes the same record bytes as the image
# route (hugmesh-generator#654, decision D8; operator decision 71 = A).
#
# WHAT IS DRIVEN, headless (QT_QPA_PLATFORM=offscreen), with ONE script over the same
# inputs (studio/tests/journey/test_brand_fleet_journey.py): the image route's Branding
# page and Brand settings step; the Fleet window's drop-down on Shared options, its
# Superbrand step, Domains and Brand settings steps with the real Next button; and the
# Fleet's text twin (`brand` on the options, then the same screens). The three record
# files are compared byte for byte.
#
# THE WIDTH. The Fleet window opens at 760x700 and scrolled 103 px sideways on every step
# (the 2026-10-01 audit; reproduced on origin/main before this change): the Tor tick-box's
# text was 765 px wide in a 722 px viewport. Every step, the new Superbrand step and the
# four tabs of the Brand settings screen now fit with no sideways scroll, and the
# geometry is measured under two styles at 8 pt too.
#
# The summary line is the LAST line of pytest's output; it is kept only when it names no
# skip, failure or error, and the scenario asks for " passed" (no exact count, so a test
# added later does not turn it red). UNEXERCISED here: running a fleet build.
@interface:studio @issue:generator-654
Feature: The Fleet window and its text twin offer the same superbrand drop-down

  Scenario: J-FLEET the three routes write the same record bytes, the drop-down is the same, and nothing scrolls sideways at 760x700 @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_fleet_journey.py 2>&1 | tail -1 | grep -Ev 'skipped|failed|error|no tests ran' | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " passed"

  Scenario: the Fleet's text twin reaches the superbrand step with one command and keeps its old flow @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_fleet_domains.py tests/test_tui_journey.py -k 'fleet' 2>&1 | tail -1 | grep -Ev 'skipped|failed|error|no tests ran' | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " passed"

  Scenario: the Fleet window's steps and tabs are drawn whole at 760x700 under two styles at the default font and at 8 pt @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_brand_screens_look.py -k 'the_brand_screens_are_drawn_whole_in_a_fresh_interpreter' 2>&1 | tail -1 | grep -Ev 'skipped|failed|error|no tests ran' | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " passed"
