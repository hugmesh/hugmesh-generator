# J-DESIGN — the superbrand's look is designed once, a brand overrides it field by
# field, and the window and the text screens do the same thing
# (hugmesh-generator#654, decisions D6, D7 and D19; operator decision 71 = A: both
# faces offer the same controls).
#
# WHAT IS DRIVEN: the Studio's look editor, headless (QT_QPA_PLATFORM=offscreen), in
# BOTH faces with ONE script. studio/tests/journey/test_brand_design.py runs it through
# the window's real widgets (a pick list, a path box, the 'Use the superbrand's value'
# button) and through the text screen's command lines, then compares the two records
# byte for byte against the record the script is expected to leave:
#
#   1. choose a preset;
#   2. upload a PNG as the logo   -> accepted, the stylesheet meter moves;
#   3. upload an SVG              -> refused, with the reason, nothing spent;
#   4. upload a picture too big   -> refused, with the numbers (102,400 and its size);
#   5. open a brand and override two fields;
#   6. arm "Use the superbrand's value" on one -> nothing changes -> apply it;
#      the brand's record holds only the other override and it still shows the
#      superbrand's logo.
#
# The window half needs a Qt binding: a host without one reports ONE skipped test, and
# the first scenario below asserts "3 passed", so a skipped window face is a red
# scenario here, never a quiet pass.
#
# THE LIVE EFFECT (a brand's own colours on a running mesh) is the L-LOOK scenario and
# needs the Docker mesh; nothing here starts a mesh or a browser.
@interface:studio @issue:generator-654
Feature: The superbrand design step and a brand's override agree in both faces

  Scenario: J-DESIGN the window and the text screen walk the same script to the same record @interface:studio
    When I run the shell command "cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/journey/test_brand_design.py"
    Then the command succeeded
    And the command output contains "3 passed"

  Scenario: every control of the window's look editor has a text command that writes the same record @interface:studio
    When I run the shell command "cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_look_text.py"
    Then the command succeeded
    And the command output contains "passed"

  Scenario: the stylesheet writer refuses an unlisted property, a url( that is not a data picture, an SVG and an oversize picture @interface:cli
    When I run the shell command "cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_look_model.py tests/test_brand_images.py tests/test_look_edits.py"
    Then the command succeeded
    And the command output contains "passed"

  Scenario: the stylesheet writer refuses the spellings that hide a url( and a picture that is not the re-encoder's own output @interface:cli
    When I run the shell command "cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_look_model.py tests/test_look_edits.py tests/test_brand_images.py -k 'hide_a_url or re_encoder_made or deflate_bomb or cut_short'"
    Then the command succeeded
    And the command output contains "5 passed"

  Scenario: tabbing through a brand's look keeps every inherited field inherited and Clear removes a stored picture @interface:studio
    When I run the shell command "cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q -p no:cacheprovider tests/test_look_editor.py tests/test_look_edits.py -k 'tabbing or emptied or clear_ or already_shows or no_picture'"
    Then the command succeeded
    And the command output contains "passed"
