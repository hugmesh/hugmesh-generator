# THE STUDIO'S "CODE FOLDERS" BLOCK, WALKED AND PRESSED (issue #689).
#
# The local hosted mesh wizard lists each domain of the mesh and, under it, the
# apps that domain runs; every app has an Open folder button on the git checkout
# the BUILD reads, every domain has Open all, and the block has Open source root.
# Every scenario here builds the REAL StudioWizard offscreen, walks it from the
# first page to the Repo source step (a second domain is added on the Domains
# step, and two optional services are ticked for it only), and presses the real
# buttons. The file manager is a one-line stand-in on PATH that logs the folder it
# is handed, so "opened" is read from what was handed over, not from the Studio's
# own say-so. Nothing is started, built or opened on the desktop; no mesh needed.
#
# WHY THESE ARE NOT WIDGET TESTS AGAIN: the widget tests (studio/tests/
# test_code_folders*.py) drive the block directly. These drive the wizard as a
# person does and check the choices the operator asked for:
#   * the folder behind a button is the folder the build reads, in BOTH source modes;
#   * a folder that does not exist yet is a disabled control that says why;
#   * an open that nothing took, or that nothing confirmed, says so inline and
#     offers the path — and never raises a dialog;
#   * Open all on a file manager that never exits does not freeze the window.
@layer:ui
Feature: The Studio opens the git checkout behind every app of every domain

  # ── the folder is the one the build reads ──────────────────────────────────
  @interface:studio
  Scenario: with my own source tree every row is the folder the build reads @interface:studio
    When I walk the Studio to the Repo source step in "existing" mode with "some" checkouts and a file manager that "ok"
    Then the Code folders block lists the domains "hugmesh.net, chat.example.org"
    And every domain has an Open all button and an Open folder button for each app it runs
    And the domain "chat.example.org" runs more apps than the domain "hugmesh.net"
    And every Code folders row is the folder the build reads
    And the Code folders root is the "typed" folder
    And the Code folders row "hugmesh-gateway" under "hugmesh.net" is enabled
    And the Code folders row "hugmesh-forum-api" under "chat.example.org" is enabled
    And the Studio grab is a non-empty PNG
    And the evidence manifest holds a "widget-grab" artefact for this scenario

  @interface:studio
  Scenario: in download mode every row is under .stack-src and nothing is openable yet @interface:studio
    When I walk the Studio to the Repo source step in "clone" mode with "none" checkouts and a file manager that "ok"
    Then every Code folders row is the folder the build reads
    And the Code folders root is the "stack-src" folder
    And no Code folders row is enabled
    And the Code folders row "hugmesh-gateway" under "hugmesh.net" is disabled and says "not downloaded yet"
    And the Studio grab is a non-empty PNG

  @interface:studio
  Scenario: once the download has made the checkouts the same rows become openable @interface:studio
    When I walk the Studio to the Repo source step in "clone" mode with "none" checkouts and a file manager that "ok"
    And the checkouts "hugmesh-gateway,hugmesh-forum-api" appear on disk and the run that made them finishes
    Then the Code folders row "hugmesh-gateway" under "hugmesh.net" is enabled
    And the Code folders row "hugmesh-forum-api" under "chat.example.org" is enabled
    And the Code folders row "hugmesh-admin-ui" under "hugmesh.net" is disabled and says "not downloaded yet"

  # ── a missing folder is a disabled control that says why ───────────────────
  @interface:studio
  Scenario: a folder that is not in my tree is disabled with the reason and opens nothing @interface:studio
    When I walk the Studio to the Repo source step in "existing" mode with "some" checkouts and a file manager that "ok"
    Then the Code folders row "hugmesh-federation-api" under "hugmesh.net" is disabled and says "no hugmesh-federation-api checkout in"
    When I press "open:hugmesh.net:hugmesh-federation-api" in the Code folders block
    Then the file manager was handed nothing

  # ── pressing the buttons ───────────────────────────────────────────────────
  @interface:studio
  Scenario: Open folder hands exactly that folder to the file manager @interface:studio
    When I walk the Studio to the Repo source step in "existing" mode with "some" checkouts and a file manager that "ok"
    And I press "open:chat.example.org:hugmesh-forum-api" in the Code folders block
    Then the file manager was handed exactly the folder "hugmesh-forum-api"
    And the Studio says it opened the folder, in green
    And no dialog is open in the Studio
    And the Studio grab is a non-empty PNG

  @interface:studio
  Scenario: Open all hands every existing folder of that domain over once @interface:studio
    When I walk the Studio to the Repo source step in "existing" mode with "some" checkouts and a file manager that "ok"
    And I press "all:chat.example.org" in the Code folders block
    Then the file manager was handed every existing folder of "chat.example.org" once
    And the Studio says it opened the folder, in green

  @interface:studio
  Scenario: Open source root hands over the root of the tree @interface:studio
    When I walk the Studio to the Repo source step in "existing" mode with "some" checkouts and a file manager that "ok"
    And I press "root" in the Code folders block
    Then the file manager was handed exactly the folder ""
    And the Studio says it opened the folder, in green

  # ── an open that nothing takes says so ─────────────────────────────────────
  @interface:studio
  Scenario: with no file manager on the machine the Studio says so and offers the path @interface:studio
    When I walk the Studio to the Repo source step in "existing" mode with "some" checkouts and a file manager that "none"
    And I press "open:hugmesh.net:hugmesh-gateway" in the Code folders block
    Then the Studio says inline that no file manager took the request and offers the folder to copy
    And the path offered for copying is the folder "hugmesh-gateway"
    And the file manager was handed nothing
    And no dialog is open in the Studio
    And the Studio grab is a non-empty PNG

  # ── a file manager that never exits must not freeze the window ─────────────
  @interface:studio
  Scenario: Open all with a file manager that never answers returns promptly and claims nothing @interface:studio
    When I walk the Studio to the Repo source step in "existing" mode with "all" checkouts and a file manager that "stay"
    And I press "all:chat.example.org" in the Code folders block
    Then the Studio answered within 6 seconds
    And the Studio does not claim the open was confirmed
    And no dialog is open in the Studio
