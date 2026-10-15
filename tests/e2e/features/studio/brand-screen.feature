# J-BRAND-SCREEN — a superbrand and two brands, walked end to end in BOTH faces with one
# script (hugmesh-generator#654, decisions D9 and D10; operator decision 71 = A).
#
# WHAT IS DRIVEN: the Studio's Domain services step, which is the per-brand screen
# (Identity | Look | Services | Ways to reach it, and four numbered text sections), on the
# Docker mesh route, headless (QT_QPA_PLATFORM=offscreen), with ONE script
# (studio/tests/journey/test_brand_screen_journey.py) run through the window's real
# widgets and through the text screens' command lines:
#
#   1. design the superbrand (id, title, organisation, public name, a colour and a font);
#   2. add two brands, shop.example and blog.example;
#   3. override the colour and the font of shop.example;
#   4. give the font back with the second click of 'Use the superbrand's value' (the
#      first click arms and changes nothing);
#   5. read its Ways-to-reach-it tab: a read-only summary and one button;
#   6. leave the step: the mesh's brand record is written.
#
# COMPARED: the two faces' record files byte for byte against the record the script is
# expected to leave (a literal written in the test from the model's rules, not built by
# the code under test); then the record read by a FRESH process (C-RECORD: `python -m
# hugmesh_studio.core.brand_model show / validate`) in the model's words — the sources
# 'this brand's own' and 'inherited from the superbrand', and none of the words a brand
# screen never says. A leak of one brand's override into the other turns it red.
#
# The summary line is the LAST line of pytest's output with a space in front, so ' 3 passed
# in ' cannot match '13 passed in '. LIVE TIER (press Generate and start, assert brand B's
# sign-in and tenancy lines): needs a Docker mesh, UNEXERCISED here.
@interface:studio @issue:generator-654
Feature: The per-brand screen with its four tabs and numbered sections agrees in both faces

  Scenario: J-BRAND-SCREEN the window and the text screens leave the same record, and a fresh process reads it @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_screen_journey.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 3 passed in "

  Scenario: the four numbered text sections edit what the four tabs edit and say where everything else is changed @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_screens_text.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 17 passed in "

  Scenario: the Domains step keeps every brand's id, look, ways and port, and shows one read-only summary per brand @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_screens_window.py -k 'table or summary' 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 6 passed, "

  Scenario: no brand page or text screen opens a modal dialog @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_screens_window.py tests/test_tui_journey.py -k 'modal' 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 2 passed, "

  Scenario: every tab, the tab bar and the brands table are drawn whole at 1040x780 and 736x736, under two styles and at 8 and 9 pt @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_brand_screens_look.py -k 'the_brand_screens_are_drawn_whole_in_a_fresh_interpreter' 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 1 passed, "
