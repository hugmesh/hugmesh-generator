# THE STUDIO'S "WORK ON THIS MESH WITH A LOCAL AI AGENT" CARD (issue #695).
#
# WHAT IS BEING PROVEN, one sentence each:
#   * the card sits on the Bring-up page, where both the Docker mesh and the kind
#     (Running DevOps) build screens end;
#   * each missing prerequisite is named in plain words and keeps Start disabled;
#   * nothing starts without a press;
#   * after a press the page shows the exact lines to run, and those lines work when run
#     against the copy that was just made (this once showed lines that failed three
#     times with "already exists" / "No such remote");
#   * no auto-approve flag is ever in the command, and the copy has no remote.
#
# WHAT IS A STAND-IN, said plainly. The machine probe is a stand-in (the scenario picks
# whether Ollama, the server, a model with tools and an agent command exist) and the
# terminal is "none installed". The Studio, the Bring-up page, the card, its text, the
# buttons, the scratch copy (a real git clone) and the shown command are the real ones.
# NOT run here, and awaiting a live run on a desktop with Ollama: a real terminal window
# opening, and a real model answering inside it.
#
# EVERY SCENARIO RUNS WITH NOTHING STARTED: no stack, no cluster, no Ollama, no window.
# There is no @env: tag, for the reason studio-gui-e2e-lane.feature gives: these are
# about the Studio's chooser and card, not about a serving mesh.
@layer:ui
Feature: The Studio offers a local AI agent on the Bring-up page and says what is missing

  @interface:studio
  Scenario: the card is on the Bring-up page, drawn whole, and starts nothing by itself @interface:studio
    When I open the Studio Bring-up page on a machine that is "ready"
    Then the Studio grab is a non-empty PNG
    And the Studio shows the local agent card on the Bring-up page
    And the card offers both the Docker mesh and the kind cluster lanes
    And Start local agent chat is enabled
    And Start local agent chat is drawn inside the card and wide enough for its label
    And nothing was started
    And the evidence manifest holds a "widget-grab" artefact for this scenario

  # The first thing missing is the one named, in words a person can act on, and Start
  # says why it is off.
  @interface:studio
  Scenario Outline: a missing prerequisite is named and Start stays off: <machine> @interface:studio
    When I open the Studio Bring-up page on a machine that is "<machine>"
    Then the Studio grab is a non-empty PNG
    And the card status says "<status>"
    And Start local agent chat is disabled and its tooltip says "<tooltip>"
    And Start local agent chat is drawn inside the card and wide enough for its label
    And nothing was started

    Examples:
      | machine        | status                                       | tooltip                      |
      | no-ollama      | Ollama is not installed                      | Ollama is not installed      |
      | server-down    | server is not answering on 127.0.0.1:11434   | server is not answering      |
      | no-tools-model | has the tools capability                     | has the tools capability     |
      | no-agent       | command is not installed                     | command is not installed     |

  @interface:studio
  Scenario: Start with no terminal installed shows lines that run, and the copy has no remote @interface:studio
    When I open the Studio Bring-up page on a "ready" machine and press Start local agent chat with no terminal installed
    Then the Studio grab is a non-empty PNG
    And the card says no window was opened and shows the lines to run
    And the lines shown carry no auto-approve flag
    And the lines shown run in bash against the copy and start the agent there without a git error
    And the copy of the repository has no remote
    And the agent brief names "no single-service rebuild target"

  @interface:studio
  Scenario: on the kind lane the same press tells the agent how to rebuild on kind @interface:studio
    When I open the Studio Bring-up page on the kind lane and press Start local agent chat with no terminal installed
    Then the Studio grab is a non-empty PNG
    And the card says no window was opened and shows the lines to run
    And the lines shown carry no auto-approve flag
    And the copy of the repository has no remote
    And the agent brief names "make kind-images ONLY="

  @interface:studio
  Scenario: Copy command shows the lines that make the copy first and starts nothing @interface:studio
    When I open the Studio Bring-up page on a ready machine and press Copy command
    Then the Studio grab is a non-empty PNG
    And the lines the Copy command button shows make the copy first
