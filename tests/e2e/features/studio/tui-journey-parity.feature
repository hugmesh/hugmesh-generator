# THE TUI JOURNEY — issues #517, #518, #519 (children of #51, "everything possible
# in the QT GUI … should be possible in ncurses") and #524 (the stale welcome
# ordinal in the urwid test).
#
# HOW A TUI STEP IS DRIVEN WITHOUT A TERMINAL. hugmesh_studio.tui.journey.Journey
# is the face-independent state machine BOTH faces (urwid and plain) drive; a
# scenario lands on a step by slug exactly as the GUI's --page jump does and
# reads the screen's lines. A step the TUI has not ported renders the honesty
# stub — journey.PENDING_NOTE for a wizard step, PendingSideFlow's sentence for
# a side flow — and both contain "not yet ported to the TUI". That phrase is
# what the @fixme scenarios assert AGAINST: they go green the day a real screen
# lands and the stub stops rendering, with no edit here.
#
# The plain face (`python -m hugmesh_studio.tui --plain`) is driven over a pipe
# for the welcome-menu scenarios, because that is the face a scripted terminal
# gets; it needs neither urwid nor a TTY, and it reads the sessions directory
# without writing to it.
@layer:ui
Feature: The TUI journey ports the wizard's steps, or records which it declined

  # ── the control: a ported step is a real screen ────────────────────────────
  @interface:cli @issue:generator-517
  Scenario: a ported wizard step renders its real screen, not the honesty stub (welcome) @interface:cli
    When I open the Studio TUI journey step "welcome"
    Then the command succeeded
    And the command output contains "Start building"
    And the command output contains "Review prior sessions"
    And the command output does not contain "not yet ported to the TUI"

  @interface:cli @issue:generator-517
  Scenario: the honesty stub is what an unported step renders today, and it says where to go instead @interface:cli
    When I open the Studio TUI journey step "hardware"
    Then the command succeeded
    And the command output contains "python -m hugmesh_studio"

  # ── #517: the seven stubbed wizard steps ───────────────────────────────────
  # _PENDING_STEPS at journey.py:178 still lists all seven (measured on
  # origin/main 9f4d6d30, 2026-09-23). Each row goes green on its own port.
  @interface:cli @issue:generator-517 @fixme
  Scenario Outline: the "<step>" wizard step is a real TUI screen, not the honesty stub @interface:cli
    When I open the Studio TUI journey step "<step>"
    Then the command succeeded
    And the command output does not contain "not yet ported to the TUI"

    Examples:
      | step     |
      | idp      |
      | hardware |
      | network  |
      | keyzip   |
      | home     |
      | launch   |
      | progress |

  # ── #518: image publishing (Cloud deploy) has no TUI route at all ──────────
  # "deploy" is in _SIDE_FLOW_STUB (journey.py:171-176). The parent names this
  # flow explicitly, so a decline is not an outcome here — only a screen is.
  @interface:cli @issue:generator-518 @fixme
  Scenario: image publishing (Cloud deploy) has a TUI screen over the canonical deploy driver @interface:cli
    When I open the Studio TUI journey step "deploy"
    Then the command succeeded
    And the command output does not contain "not yet ported to the TUI"
    And the command output does not contain "Enter returns to the menu of choices"

  # ── #519: localmesh, phone and quest — port OR formally decline ────────────
  # Either outcome satisfies the issue's "Done when": the slug leaves
  # _SIDE_FLOW_STUB behind a real screen, or the dict's own comment block
  # records the decline naming the slug (the DECISION 2(d) precedent). Today all
  # three are stubbed and the block records no decline.
  @interface:cli @issue:generator-519 @fixme
  Scenario Outline: the "<flow>" side flow is either a real TUI screen or a recorded decline @interface:cli
    Then the Studio TUI side flow "<flow>" is ported or formally declined

    Examples:
      | flow      |
      | localmesh |
      | phone     |
      | quest     |

  # ── #524: the two-entry welcome menu ───────────────────────────────────────
  # The PRODUCT is right: DECISION 2(d) cut the menu to two entries, "2" reaches
  # the sessions review and "3" is refused by name. What is stale is the urwid
  # test, which still types "3" — the third scenario pins the fix the issue asks
  # for (select by id), and is @fixme until it lands.
  @interface:cli @issue:generator-524
  Scenario: picking "Review prior sessions" at the plain welcome menu reaches the sessions review, then resumes @interface:cli
    When I drive the plain Studio TUI typing "2;q;q"
    Then the command succeeded
    And the command output contains "previous builds"
    And the command output does not contain "unrecognised choice"

  @interface:cli @issue:generator-524
  Scenario: the stale third ordinal is refused by name at the two-entry welcome menu @interface:cli
    When I drive the plain Studio TUI typing "3;q"
    Then the command succeeded
    And the command output contains "unrecognised choice: '3'"
    And the command output does not contain "previous builds"

  @interface:cli @issue:generator-524 @fixme
  Scenario: the urwid journey test selects the sessions entry by id, not by a stale ordinal @interface:cli
    Then the Studio test "test_journey_sessions_entry_swaps_in_the_review_and_back" in "studio/tests/test_tui_urwid.py" picks the welcome entry "sessions" by id, not by ordinal
