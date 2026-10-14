# THE LOCAL AI DOCK — the Studio's persistent prompt bar, driven end to end.
#
# WHAT IS BEING PROVEN, in one sentence each (hugmesh-generator#698):
#   * opening a Studio window puts the Local AI dock on the page: inside the window,
#     along the bottom, covering none of Back/Next/Cancel, with its status line
#     counting the work in the local-AI state folder;
#   * Start local assistant runs the repository's `local-ai.sh start`, detached from
#     the window's own session, and reports inline (no dialog, no work window
#     opening on its own);
#   * a question typed into the dock goes to the model on THIS machine only (one
#     POST /api/chat to a loopback address) and the answer streams into the dock;
#   * the dock asks the model LOCAL_AI_MODEL names — the one `--local-ai-prompt` asks
#     under the same setting — not whatever model happens to be loaded;
#   * Clear pressed while the answer is still arriving empties the answer area and
#     forgets the conversation — and the pieces that arrive afterwards stay gone.
#
# HOW IT RUNS. tests/e2e/studio-local-ai-driver.py opens the REAL Studio window through
# StudioShell.open_window (the call that mounts the dock) under QT_QPA_PLATFORM=offscreen,
# against a model server bound to a free loopback port inside the driver and a stand-in
# `scripts/local-ai.sh` that records its call instead of starting a server and a worker
# on the box running the suite. Everything else — the dock, the snapshot reader, the
# streaming prompt, start_assistant's detached spawn — is the shipped code. The driver
# grabs the window after each act; the manifest indexes the grabs beside the browser's.
#
# EVERY SCENARIO HERE RUNS WITH NOTHING STARTED: no Ollama, no worker, no stack. No @env:
# tag for the same reason the chooser lane has none — this is about the dock, not a mesh.
@layer:ui
Feature: The Studio's Local AI dock starts the assistant, answers a question and forgets on Clear

  @interface:studio
  Scenario: a person opens the Studio, presses Start, asks a question and presses Clear mid-answer @interface:studio
    When I open the Studio and drive its Local AI dock through Start, a prompt and Clear
    Then the Local AI dock is on the page, inside the window, clear of the wizard buttons
    And the dock's status line counts the queued work read from the local-AI state folder
    And pressing Start local assistant ran the local-ai start command detached and said so inline
    And the question went to the loopback model only and its answer streamed into the dock
    And the dock asked the model named by LOCAL_AI_MODEL, the same one the command line asks
    And Clear pressed mid-answer left the answer area empty and the conversation forgotten
    And the Local AI dock opened no modal dialog
    And a grab exists for each act of the Local AI dock scenario
    And the Studio grab is a non-empty PNG
