# The executable Gherkin expression of GROUP A of
# tests/e2e/specs/28-sticker-character-vn-moderation.spec.ts — the sticker,
# character-part and VN surfaces that REALLY EXIST today.
#
# HONEST VERDICT, carried over verbatim: the fine-grained capability the product
# owner asked for — "ban USAGE of a specific sticker/character, or ban a USER or
# ROLE from stickers/characters, WITHOUT affecting plain TEXT" — DOES NOT EXIST.
# There is no endpoint, no role, no entitlement/deny-table and no per-message
# character identity. That contract lives in the sibling file
# sticker-character-ban-contract.feature as explicitly PENDING scenarios; nothing
# here fakes it.
#
# @service:character-studio is the accurate service id for this BFF surface, and
# these scenarios give one of the four ZERO-COVERAGE services its first tagged
# e2e rows. Note that NO scenario here uses `When I open the service surface`:
# character-studio is `pinned:false` in steps/dimensions.ts because nobody has
# verified a browser route for it, and that step throws rather than guessing a
# URL that would 404 into a blank page an assertion would happily pass against.
# These are BFF-layer contracts, driven over an API context.
@service:character-studio @layer:bff
Feature: Sticker, character-part and VN surfaces that exist today

  # A1 (save half). A freshly-saved sticker is PENDING in the binary global
  # lifecycle and carries a stub mxc:// url; GET lists it owner + domain scoped.
  Scenario: a member saves a PNG sticker and finds it PENDING in their library @role:e2e-user @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I save a sticker of kind "valid-png" at expression "neutral"
    Then the sticker save was accepted as PENDING with a stub mxc url
    And my sticker library lists that sticker as PENDING

  # A1 (validation half). SVG is text/markup and must trip the magic-byte sniff;
  # >1MB must trip the size cap. Both are 400 BEFORE anything is stored.
  Scenario Outline: a sticker payload of kind <kind> is rejected with HTTP <status> @role:e2e-user @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I save a sticker of kind "<kind>" at expression "<expression>"
    Then the sticker save was rejected with HTTP <status>

    Examples:
      | kind         | expression | status |
      | svg          | happy      | 400    |
      | oversize-png | sad        | 400    |

  # A1 (authz half) — ROLE AXIS, and a correction to this spec's own facts draft.
  # There is NO authenticated "non-USER -> 403" on this surface. EVERY
  # authenticated role reaches it, and NOT because of the Spring RoleHierarchy
  # bean (which only defines SUPERADMIN>{ADMIN,MOD,USER} — there is no MOD>USER
  # edge that would explain a mod reaching a USER-gated endpoint). The real
  # mechanism: CasdoorAuthorities unconditionally grants ROLE_USER to every
  # authenticated principal, so hasRole('USER') here is an "any authenticated
  # user" floor. These three rows are exactly the principals spec 28 drives.
  Scenario Outline: <role> reaches the sticker library because every authenticated principal is floored to ROLE_USER @role:<role> @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    Then the sticker library answers HTTP 200 for this session

    Examples:
      | role           |
      | e2e-user       |
      | e2e-mod        |
      | e2e-superadmin |

  # A1 (the ONLY deny). Anonymous.
  Scenario: an anonymous client cannot save a sticker @service:character-studio @layer:bff
    Given I hold an anonymous API client
    Then an anonymous sticker save is denied with HTTP 401

  # A3. The character-part sanitizer.
  Scenario: a saved character part is sanitized and served as image/svg+xml @role:e2e-user @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I save a character part whose SVG carries a script tag
    Then the character part was stored PENDING with the script stripped
    And the served part SVG is sanitized and typed as SVG

  # A2. The protocol-level send half. Actor is e2e-matrix (ROLE_MATRIX):
  # e2e-user (plain ROLE_USER) is 403 on the hsproxy, because the broad ROLE_USER
  # homeserver floor was removed. The room_id is sent RAW in the CS-API path —
  # Synapse rejected the percent-encoded form (403, verified live) and tuwunel
  # accepts both, so raw is the one portable spelling.
  Scenario: an m.sticker send round-trips the VN content shape verbatim @role:e2e-matrix @service:tuwunel @layer:homeserver
    Given I hold an API session as the persona for this scenario
    And I have created a Matrix room named "A2 sticker send"
    When I send an m.sticker event carrying the VN expression "neutral"
    Then the send was accepted by the service
    And reading the event back shows an m.sticker with an mxc url and the same VN expression

  # A2b — PENDING ON SEED, not a bug. The full-UI picker path exists in matrix-ui
  # (btn-sticker -> composer-sticker-picker -> sticker-<shortcode> -> sendEvent
  # 'm.sticker'), but the pack is never advertised on the stock stack
  # (sticker.matrix.register.enabled=false), so `sticker-empty` renders and no
  # tile is clickable for any seeded persona. Kept as an executable, LOUDLY
  # SKIPPED scenario so the day a pack is seeded the contract is already written.
  @pending
  Scenario: the sticker picker UI sends an m.sticker on click @role:e2e-matrix @service:tuwunel @layer:ui
    Given this scenario is PENDING because "the Matrix sticker pack is never advertised on the stock stack (sticker.matrix.register.enabled=false), so matrix-ui renders sticker-empty and no sticker-<shortcode> tile exists to click. Seed a pack, then replace this step with: open /social/matrix?room=<room>, click btn-sticker, expect sticker-picker visible, click sticker-neutral, expect matrix-log to contain the sticker."
    When I open the path "/social/matrix"
    Then the element with test id "sticker-picker" is visible

  # A4 — the ONLY fine-grained moderation channel that exists: per-ITEM content
  # approval via the mod findings queue. On the stock compose stack the EFFECT
  # round-trip is NOT observable (test-seed 503 with APP_TEST_SEED_ENABLED unset,
  # the FindingActivationReconciler is dark, and GET /bff/mod/findings itself
  # 500s because the federation findings backend is down). What IS observable and
  # stable is the RBAC gate, so that is all these rows assert: "authorized" means
  # NOT 401/403 — a 500 proves authorization succeeded and is not an auth denial.
  # The held -> resolve -> ACTIVE/REJECTED flip is B1, and it is PENDING.
  Scenario Outline: the mod content-approval surface is <outcome> for <role> @role:<role> @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    Then the mod findings queue is "<outcome>" for this session
    And resolving a finding is "<outcome>" for this session

    Examples:
      | role     | outcome    |
      | e2e-mod  | authorized |
      | e2e-user | denied     |

  # A5 (control, half one). The ban surface accepts ONLY platform
  # matrix|mastodon|profile. A feature-scoped target is rejected at VALIDATION,
  # before any effect — so this probe never enacts a real ban on a shared persona.
  Scenario Outline: a moderation ban targeting "<platform>" is rejected at validation @role:e2e-mod @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I attempt a moderation ban on platform "<platform>"
    Then the ban is rejected as an unknown platform target

    Examples:
      | platform  |
      | sticker   |
      | character |

  # A5 (control, half two) — SERVICE AXIS, and the crux of the whole spec. The
  # modelled "banned from the platform" state is a user holding only ROLE_USER
  # (no ROLE_MATRIX/ROLE_MASTODON) — exactly what a whole-platform suspension
  # leaves behind. e2e-banned is 403 on BOTH homeserver surfaces, i.e. it cannot
  # send TEXT either: the only real block the platform has is coarse and takes
  # text with it. e2e-banned is DELIBERATELY left un-onboarded; that gated state
  # is the thing under test and must never be "fixed".
  Scenario Outline: a no-platform-access persona is denied <service> entirely, text included @role:e2e-banned @service:<service> @layer:bff
    Given I hold an API session as the persona for this scenario
    Then I am denied the identity surface of the service for this scenario

    Examples:
      | service |
      | tuwunel |
      | akkoma  |

  # A6 — ROLE × SERVICE, the invariant a correctly-scoped feature ban would have
  # to preserve. Each row drives the platform's real send shape: on tuwunel a raw
  # m.room.message PUT through the hsproxy, on akkoma POST /api/v1/statuses. The
  # roles are the two platform-access personas; the invite-handle personas
  # (alice@…, bob@…) are ROLE_USER only and are denied the homeserver BY DESIGN,
  # which is spec 17's subject — so they are NOT rows here.
  Scenario Outline: <role> sends plain text on <service> and it is accepted @role:<role> @service:<service> @layer:homeserver
    Given I hold an API session as the persona for this scenario
    When I send plain text on the service for this scenario
    Then the send was accepted by the service

    Examples:
      | role         | service |
      | e2e-matrix   | tuwunel |
      | e2e-mastodon | akkoma  |

  # A7 — the negative-space contract LOCK. No role encodes a sticker/character/VN
  # entitlement anywhere. If a role-scoped feature ban is ever built (B3), a
  # ROLE_STICKER/ROLE_CHARACTER/ROLE_VN or a role->feature deny-map appears in the
  # session and this flips RED — which is the signal to promote the PENDING
  # contract scenarios to live ones.
  Scenario Outline: <role> carries no sticker, character or VN feature role @role:<role> @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    Then my session carries no sticker, character or VN feature role

    Examples:
      | role       |
      | e2e-matrix |
      | e2e-admin  |

  Scenario: the ban surface has no sticker-id target @role:e2e-mod @service:character-studio @layer:bff
    Given I hold an API session as the persona for this scenario
    When I attempt a moderation ban on platform "sticker:some-sticker-id"
    Then the ban is rejected with HTTP 400
