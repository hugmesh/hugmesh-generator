# The executable Gherkin form of tests/e2e/specs/33-console-access-matrix.spec.ts.
#
# WHY IT EXISTS (operator report, 2026-08-14): "this functionality should already
# exist but we can't find it nor any control UIs for any of the services." Every
# console DID exist and work; the only way in was to click your own username and
# hunt through the profile dropdown. An account holding all ten roles saw a
# menubar of exactly Home / Mastodon / Matrix / Forum.
#
# So this asserts the two halves that failure had:
#   (a) DISCOVERY — the console is LISTED for the identities that hold its role and
#       NOT listed for the ones that do not. A console you cannot find is, for the
#       operator, a console that does not exist.
#   (b) REACH — following it renders the console rather than bouncing to /user (the
#       NG04002 redirect shape) or rendering an empty shell. `proof` in
#       steps/rbac.steps.ts is a string only the real console emits, so an empty
#       page cannot satisfy it.
#
# Asserted per IDENTITY, not per route: "which controls does THIS user get" is the
# question an operator actually asks, and the one a role regression breaks. The
# negative rows carry equal weight — a member seeing an admin link is as much a
# defect as an admin not seeing one.
#
# PLATFORM is a real axis on the discovery rows: the host shell is built into each
# image, so rpi5 and x86 are separate artefacts. One sign-in per row, and
# SNAP_PLATFORM halves the matrix on a lane that knows which mesh is up.
@layer:ui
Feature: Console access matrix — discovery and reach, per identity

  Scenario Outline: <role> sees exactly its own consoles on <platform> @role:<role> @platform:<platform> @layer:ui
    Given I am signed in as the persona for this scenario
    Then the "admin" console <admin> in the menubar
    And the "mod" console <mod> in the menubar

    Examples:
      | role      | platform | admin         | mod           |
      | e2e-admin | rpi5     | is listed     | is listed     |
      | e2e-admin | x86      | is listed     | is listed     |
      | e2e-mod   | rpi5     | is not listed | is listed     |
      | e2e-mod   | x86      | is not listed | is listed     |
      | e2e-user  | rpi5     | is not listed | is not listed |
      | e2e-user  | x86      | is not listed | is not listed |

  # REACH. Unpinned on PLATFORM deliberately: a second sign-in per row buys
  # nothing the discovery rows above have not already paid for on both images.
  Scenario Outline: <role> opens the <console> console and it really renders @role:<role> @service:admin @layer:ui
    Given I am signed in as the persona for this scenario
    When I follow the "<console>" console entry in the menubar
    Then the "<console>" console renders its own content

    Examples:
      | role      | console |
      | e2e-admin | admin   |
      | e2e-admin | mod     |
      | e2e-mod   | mod     |

  # The console's panels ARE the moderation controls. Asserting they render for a
  # moderator is what makes "the controls exist for this user" a checked claim
  # rather than a screenshot someone remembers.
  Scenario: the moderation console exposes its wired controls to a moderator @role:e2e-mod @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/mod/console"
    Then the moderation console exposes its wired controls

  # Discovery-gating is presentation; THIS is the one that matters for safety. The
  # guard must hold when the URL is typed, not merely when the link is hidden.
  Scenario: a plain member is denied the moderation console even by direct URL @role:e2e-user @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/mod/console"
    Then after a settling pause the page body still does not match "moderation queue"
