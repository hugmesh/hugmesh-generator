# The forum's THREE-TIER front door, and the federation front door beside it.
#
# WHAT IS ASSERTED, and why "contains" was not enough. The forum BFF is gated by
# three stacked rows on the fe gateway, and Spring Cloud Gateway resolves them
# LONGEST-PATTERN-WINS:
#
#   /bff/forum/admin/**       ROLE_ADMIN      the admin-console seam
#   /bff/forum/moderation/**  ROLE_FORUM_MOD  the DERIVED composite (MOD n FORUM)
#   /bff/forum/**             ROLE_FORUM      the forum-access floor
#
# features/uncovered-services/route-contract.feature asserts the FLOOR row only.
# Grepping features/ for `forum/moderation` or `forum/admin` returns zero hits.
# The two upper tiers do appear in specs/26-rbac-cross-realm-matrix.spec.ts — as
# a HAND COPY, labelled at :59 "Copied 1:1 from 20-schema.sql", used to drive
# live probes and never once compared against the file it was copied from. That
# is the failure mode this repo has already been bitten by (three divergent
# persona lists): the copy stays green while the source drifts.
#
# So these scenarios READ 20-schema.sql, and they assert the EXACT allow set at
# each pattern rather than mere membership. Membership cannot see a collapse:
# add ROLE_FORUM to /bff/forum/admin/** and every "contains ROLE_ADMIN"
# assertion still passes while the admin seam opens to every forum member.
# ROLE_FORUM_MOD is not a Casdoor grant anyone holds directly — it is
# materialised by the forum reconcile Job as MOD n FORUM, exactly like
# ROLE_GAMES_ADMIN — so a plain ROLE_MOD is default-deny on the moderation tier
# and that is a property worth keeping unmerged.
#
# Runs with EVERY environment down.
@harness @layer:gateway
Feature: The forum and federation front doors are seeded at the tier each one enforces

  @service:phpbb @layer:bff
  Scenario Outline: the forum BFF sub-path "<pattern>" is gated by exactly <role> @service:phpbb @layer:bff
    Then the route-access seed grants exactly "<role>" at "<pattern>" on the fe gateway

    Examples: longest-pattern-wins — a collapsed stack silently promotes forum members
      | pattern                   | role           |
      | /bff/forum/admin/**       | ROLE_ADMIN     |
      | /bff/forum/moderation/**  | ROLE_FORUM_MOD |
      | /bff/forum/**             | ROLE_FORUM     |

  # THE FEDERATION FRONT DOOR. The capability projection is the one federation
  # surface that is deliberately PUBLIC — the host shell fetches it before any
  # session exists, to decide which optional services to grey out. The manifest
  # next to it is NOT public: it is the logged-in home page's module list.
  # Asserting them as a PAIR is what keeps the distinction deliberate; asserting
  # the ABSENCE of a glob row is what keeps the public hole exactly one path wide.
  @service:gateway @layer:gateway
  Scenario: the capability projection is PUBLIC at the front door and the manifest is not @service:gateway @layer:gateway
    Then the route-access seed grants exactly "PUBLIC" at "/api/federation/capabilities" on the fe gateway
    And the route-access seed grants exactly "ROLE_USER" at "/api/federation/manifest" on the fe gateway

  # The fe gateway exposes federation by EXACT PATH ONLY (vanity, vanity/**,
  # capabilities, manifest). A `/api/federation/**` row on this door would hand
  # the whole registry — module rows, bundles, the moderation queue — to whatever
  # role it named, on the SAME door the anonymous capability read uses. The
  # authenticated floor belongs on the be-gateway, and it is there.
  @service:gateway @layer:gateway
  Scenario: the public federation door is one path wide, and the authenticated floor is on the other gateway @service:gateway @layer:gateway
    Then the route-access seed has no fe gateway row for "/api/federation/**"
    And the route-access seed grants "ROLE_USER" at "/api/federation/**" on the be gateway
