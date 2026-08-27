# The executable Gherkin form of
# tests/e2e/specs/23-domainlock-mod-ban-interaction.spec.ts.
#
# TWO INDEPENDENT MODERATION AXES THAT MUST COMPOSE WITHOUT LEAKING:
#   * domain-lock = the PRESENCE of ROLE_MASTODON_DOMAINLOCKED — an additive
#     marker; the access role is KEPT, so the user has full LOCAL access and no
#     federation (docs/DOMAIN-LOCK.md).
#   * ban         = access_suspension, the WITHDRAWAL of access, enacted by a MOD
#     through the mod-bff (POST/DELETE /bff/mod/ban).
#
# The gap this closes: the matrix doc's domainlock row only proves the lock ALONE.
# When a domain-locked user is BANNED, the ban must apply LOCALLY, nothing about it
# may federate, and after the ban is LIFTED the lock must SURVIVE.
#
# Subject:  e2e-mastodon-domainlocked   Actor: e2e-mod via the mod-bff
# Observer: the TEST-ONLY akkoma-peer, which FOLLOWS the subject first, so a leak
#           WOULD be observable. Without that follow a green negative proves only
#           that nobody was listening — which is why it is a Given, not a comment.
#
# THE POSITIVE CONTROL IS NOT HERE. That the federation pipe is alive at all is
# spec 22's job (the clock). These negatives are meaningful only next to it, and
# the negative window below is the same 30s bound the control is observed under.
#
# HONESTY. Each Given skips with a precise reason when the peer is absent, the
# domain-lock gate is dark, or the run did not inject the tokens. It never fakes a
# pass, and it never asserts a fake success where the akkoma ban leg cannot apply.
@service:akkoma @layer:homeserver
Feature: Domain-lock and a mod ban are independent axes

  # The DENY half of the ban pair: the surface refuses a plain member outright AND
  # the refusal had no effect — the subject still posts. Real absence-of-effect,
  # not just a status code.
  Scenario: a plain member cannot ban anyone and changes nothing by trying @role:e2e-user @service:akkoma @layer:bff
    Given the federation peer and the domain-lock gate are configured
    And the domain-locked subject token and the "e2e-user" Casdoor JWT are provisioned
    When a plain member calls the mod ban surface for the domain-locked subject
    Then the mod ban surface refuses the plain member
    And the domain-locked subject can still post locally

  Scenario: a mod ban applies locally, never federates, and the lock outlives it @role:e2e-mod @service:akkoma @layer:homeserver
    Given the federation peer and the domain-lock gate are configured
    And the domain-locked subject token and the "e2e-mod" Casdoor JWT are provisioned
    And the peer token is provisioned
    And the peer follows the domain-locked subject
    When the domain-locked subject posts a public status locally
    Then that status is visible on the local public timeline
    And the peer never sees that status within the negative window
    When the moderator bans the domain-locked subject on the mastodon platform
    Then the mod BFF accepts the ban
    And the banned subject can no longer post locally
    And the peer stored view of the subject carries no suspension
    And the peer never sees that status within the negative window
    When the moderator lifts the ban
    Then the subject can post locally again
    And the recovered post still does not reach the peer
