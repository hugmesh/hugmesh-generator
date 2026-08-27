# Executable Gherkin for tests/e2e/specs/03-register-gating.spec.ts, plus the
# deliberately-gated personas the whole suite depends on staying gated.
#
# WHAT SPEC 03 ACTUALLY DOES. Native login has NO self-registration surface:
#   * an identity no admin provisioned simply fails to sign in — Casdoor answers
#     401 invalid_credentials and login-ui renders "Sign-in failed" in
#     `login-error`. There is no register form to be denied at.
#   * a PROVISIONED but not-yet-completed identity signs in (stage 1) and is held
#     on login-ui's OWN "Complete registration" card (complete-view /
#     register-display-name / a DISABLED login-complete). It never reaches the
#     host shell, so there is no nav-matrix/nav-mastodon to click — which is how
#     "Matrix/Mastodon stay locked" is actually proven.
#
# WHAT SPEC 03 DELIBERATELY DOES NOT DO, AND THIS FEATURE THEREFORE DOES NOT
# EITHER: it does not `goto('/social/matrix')` and assert a redirect. Verified
# live (generator#297): matrix-ui's raw gateway path serves only the
# <hug-matrix-root> custom-element shell for the HOST to mount, and renders
# matrix-view for NOBODY navigating there directly — complete-registration or
# not. That assertion was checking a redirect that does not exist. It was dropped
# rather than replaced with an invented mechanism, and re-adding it here would
# resurrect a green-looking check of nothing.
@service:login @layer:ui
Feature: Two-stage registration gating

  # ── the un-provisioned identity ────────────────────────────────────────────
  # mallory@gmail.com is the handle spec 03 relies on NOBODY seeding. It travels
  # as step DATA, not as `@role:` — the role vocabulary only accepts handles a
  # seeder creates (steps/dimensions.ts persona()), which is precisely the
  # property being asserted about mallory in the negative.
  @harness @layer:casdoor
  Scenario: the identity the denial scenario uses is provisioned by no seeder @service:login @layer:casdoor
    Then no seeder provisions the identity "mallory@gmail.com"

  Scenario: native sign-in is denied for an identity no admin provisioned @service:login @layer:ui
    When I attempt native sign-in as the unprovisioned identity "mallory@gmail.com"
    Then the sign-in is refused with the message "Sign-in failed"

  # ── the provisioned-but-incomplete identity ────────────────────────────────
  # ROLE axis. Both rows are seeded native Casdoor accounts held at stage 1:
  #   frank@gmail.com       spec 03's subject (tests/e2e-extra-personas.sh, ROLE_USER)
  #   rbac-pending@gmail.com spec 17's subject — additionally pinned onto
  #                          seed-e2e.sh's SEED_REGISTRATION_SKIP default, so the
  #                          optional SEED_COMPLETE_REGISTRATION=1 sweep cannot
  #                          launder its gated state away. frank is NOT on that
  #                          list, exactly as spec 03 leaves it.
  Scenario Outline: <role> signs in but is held on the complete-registration card @role:<role> @service:login @layer:ui
    Given I have registered but not completed onboarding as the persona for this scenario
    Then the element with test id "complete-view" is visible
    And the element with test id "register-display-name" is visible
    And the element with test id "login-complete" is disabled
    And my session registration is not complete

    Examples:
      | role                   |
      | frank@gmail.com        |
      | rbac-pending@gmail.com |

  # ── personas whose GATED state is load-bearing ─────────────────────────────
  # tests/stack/seed-e2e.sh names these three in SEED_REGISTRATION_SKIP with a
  # reason each. They are NOT failures to fix: onboarding them deletes the state
  # specs 17/28/29 assert. The step reads that default out of the shell script
  # (never a copy), and folds the login handle to the Casdoor legal name the list
  # spells (rbac-pending@gmail.com -> rbac-pending-gmail-com).
  @harness @layer:casdoor
  Scenario Outline: <role> is deliberately left un-onboarded @role:<role> @service:login @layer:casdoor
    Then the persona named by the role dimension is seeded
    And the persona is deliberately left un-onboarded by the seeder

    Examples:
      | role                   |
      | e2e-pending            |
      | rbac-pending@gmail.com |
      | e2e-banned             |

  @harness @layer:casdoor
  Scenario: e2e-pending is the one catalogue entry modelling awaiting-approval @role:e2e-pending @service:login @layer:casdoor
    Then the seed catalogue models the persona as registration-incomplete with no roles

  # These two role sets are load-bearing and documented as such in
  # tests/e2e-extra-personas.sh: widening either turns a real assertion vacuous.
  @harness @layer:casdoor
  Scenario Outline: <role> keeps exactly the roles that keep its proof honest @role:<role> @service:login @layer:casdoor
    Then the persona holds exactly the seeded roles "<roles>"

    Examples:
      | role       | roles                        |
      | e2e-banned | ROLE_USER                    |
      | e2e-fleet  | ROLE_FLEET_ADMIN,ROLE_USER   |
