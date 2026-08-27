# THE FORUM FUNCTION SURFACE — phpBB/forum, the service that had a ROUTE
# contract and a mount proof and no function surface at all.
#
# WHY THE FORUM IS THE ODD ONE OUT, THREE TIMES OVER:
#
#   1. Its member plane (/social/forum/**, /bff/forum/**) is gated on ROLE_FORUM,
#      which exactly ONE seeded persona holds (e2e-forum). Every other identity
#      in both rosters is denied by the seed.
#   2. Its MODERATION plane (/bff/forum/moderation/**) is gated on ROLE_FORUM_MOD,
#      which NO persona in either roster holds. That is a real gap, and the
#      drift guard in ../platform/social-function-matrix.feature keeps it visible
#      and goes RED on the day it closes — the same tripwire shape
#      ../uncovered-services/access-role-roster.feature uses for wiki/owncast/tube.
#   3. The phpBB POD itself (/social/phpbb/**) is CONTRACTUALLY ROW-LESS. The
#      gateway is default-deny, so a surface with no seed row is refused to
#      EVERYONE, admin included. The `phpbb-pod` row below pins that as a gate in
#      its own right, so "somebody added the missing row" is a red scenario
#      rather than a silently opened backend.
#
# A NOTE ON THE TWO GUARDS THAT DISAGREE, recorded rather than papered over. The
# SEED gates /social/forum/** on ROLE_FORUM. The shipped forum-ui admits any
# AUTHENTICATED identity (forumGuard, not registeredGuard) — which is why
# ../uncovered-services/forum-console.feature drives e2e-user through the mount
# and expects it to work. These are two different planes (the gateway route vs
# the in-shell micro-frontend guard) and this feature asserts only the first.
# Nothing here should be "fixed" by widening the seed until somebody decides
# which plane is authoritative.
#
# RUNS WITH THE STACK DOWN.
@service:phpbb @layer:gateway @harness
Feature: Every forum function is gated for every seeded persona as the catalogue declares

  Scenario Outline: <function> is gated for the whole roster exactly as the catalogue declares @service:phpbb @layer:gateway
    Then the route-access seed gates the "<function>" function of the service dimension for every seeded persona
    And the "<function>" function of the service dimension is a "<arity>" interaction

    Examples:
      | function             | arity |
      | board-index          | solo  |
      | search               | solo  |
      | view-topic           | pair  |
      | vn-profile           | solo  |
      | list-categories      | solo  |
      | post-topic           | pair  |
      | reply-topic          | pair  |
      | mod-remove-post      | pair  |
      | admin-board-settings | solo  |
      | api-forum-admin      | solo  |
      | phpbb-pod            | solo  |

  # The same sweep in ONE scenario, so a run that lost the rows above still
  # cannot report green with a broken matrix. The rows exist for the REPORT
  # (the reporter pivots perService off the title); this exists for the PROOF.
  Scenario: every phpbb function agrees with the deployed route-access seed for every persona @service:phpbb @layer:gateway
    Then every function of the service dimension agrees with the route-access seed for every seeded persona
    And every catalogued probe path resolves to a real route-access pattern
