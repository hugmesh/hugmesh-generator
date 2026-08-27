# The forum micro-frontend, DRIVEN — previously a route contract only.
#
# /social/forum is the hugmesh-forum-ui remote, and it is unlike its sibling
# social shells in a way that matters: it is gated on forumGuard = any
# AUTHENTICATED identity, NOT on registeredGuard. Matrix and Mastodon need
# registration because that is what mints their per-service tokens; the forum
# reuses our own federated identity, so gating it tighter would bounce exactly
# the authenticated-but-unregistered user the route was written to admit — and
# would make the home-page 'forum' launcher card, which carries no
# requiresRegistration and no requiresRole, a dead link for someone the card told
# was ready.
#
# So the two personas below are chosen to span that boundary: e2e-forum is the
# ROLE_FORUM holder the gateway row is keyed on, and e2e-user is the plain member
# who must ALSO get in because the guard is authentication, not authorization.
# If someone tightens forumGuard, the e2e-user row is what says so.
#
# DEPTH: this proves the remote mounts and renders its own chrome (the search
# entry, and the VN-profile toggle that only a logged-in identity gets). It does
# not post a topic — creating content needs canPost() and a seeded category, and
# a fabricated posting flow would be worth less than an honest mount proof.
@service:phpbb @layer:ui
Feature: The forum remote mounts for any authenticated identity

  Scenario Outline: <role> opens the forum index inside the host shell @role:<role> @service:phpbb @layer:ui
    Given I am signed in as the persona for this scenario
    When I open the path "/social/forum"
    Then the URL matches "/social/forum"
    And the element with test id "forum-search-link" is visible
    And the element with test id "vn-profile-toggle" is visible

    Examples:
      | role      |
      | e2e-forum |
      | e2e-user  |

  @layer:ui
  Scenario: an anonymous visitor is sent to native sign-in from the forum @layer:ui @service:phpbb
    When I open the path "/social/forum"
    Then the URL matches "/login"
    And the element with test id "login-username" is visible

  # ── phpBB, the ALTERNATIVE forum: the one surface here that is genuinely NOT
  #    drivable on a default stack ─────────────────────────────────────────────
  #
  # phpBB lives behind the `phpbb` compose profile and is OFF by default
  # (tests/stack/compose.alt-social.yaml: "Both are DEFAULT-OFF, following the
  # tube/owncast precedent"). With the profile down /social/phpbb has no backend
  # at all — like the mastodon/matrix routes without SOCIAL=1 — so these would
  # fail on a bad gateway rather than on a product defect. They are marked
  # @fixme: still listed, still resolved by the generator (an undefined step here
  # still fails `npx bddgen`), reason and fix written down.
  #
  # TO RUN THEM: `make stack-up PHPBB=1`, seed as usual, delete the @fixme tags.
  # Nothing else about them changes — which is the proof they were written
  # honestly rather than to a shape that could never be executed.
  #
  # The phpBB ROUTE contract is NOT pending: route-contract.feature asserts the
  # two-segment StripPrefix and the deliberate absence of a route-access row for
  # the pod, offline, on every run.
  #
  # NOTE FOR THE NEXT AUTHOR: these scenarios must NOT be split into a file of
  # their own. playwright-bdd drops a .feature whose scenarios are ALL @fixme
  # (generate/index.js filters on file.hasExecutableTests()), so an all-pending
  # feature file silently generates nothing and becomes the decorative artefact
  # this lane exists to prevent. Measured this unit; G1's guard catches it.

  @fixme @role:e2e-forum @service:phpbb
  Scenario: PENDING (needs `make stack-up PHPBB=1`) — a forum member reaches the phpBB board index @layer:ui @role:e2e-forum @service:phpbb
    Given I am signed in as the persona for this scenario
    When I open the path "/social/phpbb/"
    Then the URL matches "/social/phpbb"

  @fixme @role:e2e-user @service:phpbb
  Scenario: PENDING (needs `make stack-up PHPBB=1`) — phpBB is served by the forum image, not the Angular shell @layer:ui @role:e2e-user @service:phpbb
    Given I am signed in as the persona for this scenario
    When I open the path "/social/phpbb/index.php"
    Then the URL matches "/social/phpbb"
