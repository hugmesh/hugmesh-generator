# J-SUPERBRAND, the SLICE the Docker route's page owns — the local-mesh route's brand box is
# the superbrand drop-down, and choosing ‘Create a new superbrand’ opens the design, in BOTH
# faces (hugmesh-generator#654, decision D8; operator decision 71 = A: the window and the
# text screens offer the same controls).
#
# WHAT IS DRIVEN, headless (QT_QPA_PLATFORM=offscreen), with ONE script over the same
# inputs (studio/tests/test_brand_docker_route_journey.py):
#
#   1. From the first page choose the local mesh and generate.
#   2. Leave the brand box on its default. ‘Create a new superbrand’ is the first item and
#      is selected; the design is open under it.
#   3. Design the superbrand: an id, a title, an organisation and a colour.
#   4. Add a second brand with its own sign-in on the Domains step.
#   5. Go on to the review. The configuration the bring-up reads carries the brand and the
#      designed block, the plan names it, and the record file the window saved is byte for
#      byte the record file the text screens saved (a design alone), with the same brand
#      list when a brand is added. The text screens' printed command
#      (`hugmesh-mesh-bootstrap plan --brand acme --record FILE`) is then RUN and its plan
#      names the superbrand.
#
# Picking an existing profile instead skips the design and shows a read-only summary with a
# ‘Change it’ click; a flow that never touches the brand writes no record and hands the
# bring-up exactly what it handed it before the drop-down existed.
#
# WHAT THIS DOES NOT COVER, and why (the full J-SUPERBRAND of the design is bigger):
#   - a PNG and a font in the design: the brand record cannot hold them yet (the page says
#     so under the design), so there is nothing to assert;
#   - overriding the second brand's colour: the Brand settings tabs are not mounted on the
#     Docker route's Domain services step yet (DomainServicesWidget.set_brand_session and
#     DomainsTableWidget.set_brand_session are not called from this route);
#   - the live tier — `hugmesh-mesh-bootstrap up --record FILE` on a running Docker mesh and
#     the asserts on the second brand's sign-in and tenancy lines. UNEXERCISED here: it needs
#     a Docker mesh. The brand's own look reaching the running Docker mesh is the start
#     path's work and is not built; the page says so under the design.
#
# The summary line of each command is the LAST line of pytest's output (colour switched off:
# a Playwright worker forces colour codes into it) with a space put in front of it, so
# ' 6 passed in ' cannot also match '16 passed in '. Every scenario asserts an exact count:
# a skipped window half (no Qt binding) is a RED scenario here, never a quiet pass.
@interface:studio @issue:generator-654
Feature: The Docker route's brand drop-down and design step agree in both faces

  Scenario: J-SUPERBRAND (Docker route slice) from the first page to a written record, the same bytes from the window and the text screens @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q --color=no -p no:cacheprovider tests/test_brand_docker_route_journey.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 6 passed in "

  Scenario: the window's drop-down starts on ‘Create a new superbrand’, an existing profile skips the design, and a design reaches the bring-up @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q --color=no -p no:cacheprovider tests/test_brand_docker_route.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 25 passed in "

  Scenario: the text screens offer the same drop-down with one command and print a command that carries the record @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q --color=no -p no:cacheprovider tests/test_brand_docker_route_text.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 15 passed in "

  Scenario: the step is drawn whole at 1040x780 and 736x736, under two styles, at 8 and 9 pt, with a long design name @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q --color=no -p no:cacheprovider tests/test_brand_docker_route_look.py -k 'the_docker_route_brand_step_is_drawn_whole_in_a_fresh_interpreter' 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 1 passed, "

  Scenario: the steps that were there before keep their behaviour @interface:studio
    When I run the shell command "set -o pipefail; cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen ${SNAP_STUDIO_PYTHON:-python3} -m pytest -q --color=no -p no:cacheprovider tests/test_localmesh_steps.py tests/test_tui_localmesh_domains.py tests/test_local_mesh_bootstrap_config_roundtrip.py 2>&1 | tail -1 | sed 's/^/ /'"
    Then the command succeeded
    And the command output contains " 78 passed in "
