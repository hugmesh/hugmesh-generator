# MINED FROM: hugmesh-login-ui/src/app/bff.service.ts:48
#             (BLOCKED_STATUS_TOKENS = ['account_banned','account_suspended'])
#             and :121-131 classifyRejection(); login.routes.ts:54-58 documents
#             the same contract in prose.
#   AGAINST:  hugmesh-user-bff-api SsoAuthController.java:122-136 — POST
#             /bff/login answers EXACTLY LoginResult | MfaChallenge | 401
#             LoginError("invalid_credentials", …). There is no producer of
#             either blocked token: an org-wide grep for account_banned /
#             account_suspended across .java/.sql/.sh/.yml/.yaml returns NOTHING.
#             The only hits anywhere are login-ui's own source, its own unit
#             tests and its compiled bundles.
#
# SO THE BLOCKED BRANCH IS UNREACHABLE TODAY, and the seeder agrees: seed-e2e.sh
# :11 models a ban as the ABSENCE of the platform access roles, not as an account
# STATUS. No persona anywhere carries status=banned|suspended. The blocked
# scenario is therefore PENDING with that named reason rather than authored as a
# green-looking pass — the honest state of a client branch waiting on a server.
#
# The second scenario is the one that CAN run, and it is the contrast that keeps
# the first from being the only thing written down: an ordinary credential
# failure must NOT route to the appeal page. Ported from
# hugmesh-login-ui/e2e/features/auth/error-a11y.feature, adapted to this suite's
# vocabulary (that file's "a fresh browser context" / "the login view is shown"
# steps do not exist here; `I attempt native sign-in as the unprovisioned
# identity` is this suite's spelling of the same action).

@service:login @layer:bff @env:docker
Feature: A blocked account is told it is blocked, not that its password is wrong

  @role:e2e-banned
  Scenario: a banned account's sign-in is refused with a blocked token, not invalid_credentials @role:e2e-banned @service:login @layer:bff
    Given this scenario is PENDING because "no producer of account_banned/account_suspended exists anywhere in the org (SsoAuthController answers only invalid_credentials), and no seeder sets an admin-bff account STATUS: tests/stack/seed-e2e.sh:11 models a ban as the ABSENCE of platform roles, so e2e-banned is a plain ROLE_USER. Both a status-curtailed persona AND a server that emits the token are needed before this can run."
    When I sign in through the native login form as the persona for this scenario
    Then the sign-in is refused with the message "account_banned"
    And the URL matches "/login/appeal"

  @role:e2e-user
  Scenario: a wrong password stays on the login form and never reaches the appeal page @role:e2e-user @service:login @layer:ui
    When I attempt native sign-in as the unprovisioned identity "e2e-user-wrong-password"
    Then the native sign-in error reports a failed sign-in
    And the URL matches "/login"
    And the element with test id "login-error" is visible

  # PORTED from hugmesh-login-ui/e2e/features/auth/error-a11y.feature. The
  # central suite asserts error TEXT in several places and ARIA wiring nowhere;
  # this establishes the vocabulary the rest of the suite can reuse. A sign-in
  # error that is only VISIBLE is, to a screen-reader user, an error that never
  # happened.
  @role:e2e-user
  Scenario: the sign-in error is announced, not merely displayed @role:e2e-user @service:login @layer:ui
    When I attempt native sign-in as the unprovisioned identity "e2e-user-wrong-password"
    Then the element with test id "login-error" is an assertive live region

  # ── hugmesh-generator#311, step 17: the status gate has nothing to read ──────
  # The curtailed-member plan measured (2026-09-05, this stack) that the host
  # shell's status-gate banner never renders and roleHomeGuard never
  # short-circuits to /login/appeal, because GET /bff/me routes to user-bff here
  # (application-routes.yml exact-path list) and user-bff's session view is
  # ["handle","id","provider","registrationComplete","roles"] — no `status`.
  # hugmesh-host-shell's AccountStatusService fails OPEN to 'active' on an
  # absent field, so session.curtailed() is false for a banned member and the
  # wall the persona is defined by cannot appear. The plan files it as "a wiring
  # gap, not a stack fault"; this is the fence for it. @fixme: no landing on
  # user-bff origin/main (666ab2f) or host-shell adds the field. e2e-user is
  # the control row — an ACTIVE member's view must carry the field too, or the
  # gate would have to infer "active" from its absence, which is the fail-open
  # this issue names.
  @issue:generator-311 @fixme
  Scenario Outline: <role>'s session view carries an account status for the shell's status gate @role:<role> @service:login @layer:bff
    Given I hold an API session as the persona for this scenario
    When the API client GETs "/bff/me"
    Then the response status is 200
    And the response JSON field "status" is present

    Examples:
      | role       |
      | e2e-user   |
      | e2e-banned |
