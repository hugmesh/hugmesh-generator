# The FRONT-DOOR contract for the two core social remotes: matrix-ui and
# mastodon-ui.
#
# WHY THIS FILE EXISTS. features/uncovered-services/route-contract.feature proves
# this exact agreement for wiki, owncast, tube, character-studio, character-forge,
# phpbb and forum-ui — and stops there. The two remotes the whole M3 social tier
# is built on, /social/matrix/** and /social/mastodon/**, are named nowhere in it.
# Grepping `the fe gateway routes` across features/ returns five call sites, none
# of them matrix or mastodon. They appear in features/ only as ROUTE-ACCESS
# DECISION rows (rbac/plain-user-and-platform-access.feature, federation/
# cross-realm-authz.feature) — i.e. "may this persona reach that path", which is
# a question about the GATE and says nothing about whether a route exists behind
# it, which upstream answers, how many segments it strips, or whether a refresh
# lands in the shell or in the bare remote.
#
# THE FOUR-WAY FAILURE THIS CATCHES, in this repo's own words:
#   * a route with no gate row is a 403 for everybody (the gateway is default-deny);
#   * a gate row with no route is a 404 that renders as a blank page an assertion
#     will happily pass against;
#   * a wrong StripPrefix serves the upstream's own 404 page, which still returns
#     bytes and still renders on first load;
#   * a missing deep-link route drops a refresh or a shared link into the BARE
#     remote — no menu, no shell chrome, no session UI. Reported on 2026-08-14 as
#     "refreshing takes us into the federated remote instead of just refreshing
#     the view", and fixed by a route that is DEAD CONFIG unless it is declared
#     before the remote's own route AND scoped to `Accept: text/html`.
#
# Runs with EVERY environment down: it reads the committed route table and the
# committed route-access seed. That is the point — this is the half of M3's
# coverage that stays true on a laptop with no mesh.
@harness @layer:gateway
Feature: The Matrix and Mastodon remotes are routed, stripped, deep-linked and gated

  # StripPrefix=2 on both, because the mount is TWO segments (/social/matrix).
  # The remotes are built with --base-href=/social/<x>/ so the browser asks for
  # /social/matrix/main.js; stripping both segments maps that onto the container
  # webroot nginx serves. Strip 1 and Angular never boots; strip 0 and every
  # bundle 404s at the origin root.
  Scenario Outline: the <service> remote is mounted at "<pattern>" and strips its two-segment prefix @service:<service> @layer:gateway
    Then the fe gateway routes "<pattern>" to the "<upstream>" upstream
    And the fe gateway route for "<pattern>" to the "<upstream>" upstream strips 2 path segments
    And html navigations for "<pattern>" reach the host shell before the "<upstream>" upstream

    Examples: the two social remotes route-contract.feature never names
      | service | pattern               | upstream            |
      | tuwunel | /social/matrix/**     | hugmesh-matrix-ui   |
      | akkoma  | /social/mastodon/**   | hugmesh-mastodon-ui |

  # THE GATE, and the asymmetry inside it. Both social remotes are gated at the
  # ROLE_USER floor — the SHELL is reachable by any member; it is the homeserver
  # behind it (/_matrix/** -> ROLE_MATRIX) that carries platform access, which is
  # what makes features/matrix/native-sign-in.feature's distinction real. The
  # forum remote is the odd one out: ROLE_FORUM, not ROLE_USER, because the forum
  # has no separate homeserver leg to carry its access role. Pinning all three
  # together is what stops somebody "harmonising" them.
  Scenario Outline: the <service> remote mount is gated by exactly <access_role> @service:<service> @layer:gateway
    Then the route-access seed grants exactly "<access_role>" at "<pattern>" on the fe gateway

    Examples:
      | service | pattern             | access_role |
      | tuwunel | /social/matrix/**   | ROLE_USER   |
      | akkoma  | /social/mastodon/** | ROLE_USER   |
      | phpbb   | /social/forum/**    | ROLE_FORUM  |
