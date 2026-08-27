# THE FORGE'S SAVE, ACTIVATE AND ID-ADDRESSED READ SURFACES ARE BOUNDED.
#
# The central suite touches this BFF in exactly one place —
# specs/32-matrix-chat3d.spec.ts / steps/chat3d.steps.ts — which POSTs one
# character, PUTs /active and GETs /active as SETUP for a Matrix room scenario.
# grep '/lookup' returns zero and 'MAX_CHARACTERS' returns zero. The bounds
# themselves are unasserted.
#
# The four properties here are each a distinct branch in CharacterForgeService:
#
#   single-active   swapActive clears the sibling in the row's own brand, with a
#                   PARTIAL UNIQUE INDEX as the backstop. Two actives means the
#                   swap stopped clearing AND the index is not covering the case
#                   that reached the DB.
#   the 32 cap      count >= MAX_CHARACTERS_PER_OWNER -> 409 CONFLICT (a state
#                   limit, not a malformed request), and the stored rows are
#                   untouched — a rejected create that still wrote would make the
#                   cap advisory.
#   404-never-403   owned() resolves to empty for a foreign owner, a foreign
#                   BRAND or a malformed uuid, and all three become the same 404.
#                   A 403 on any of them would confirm the row exists under
#                   another owner: a cross-owner existence leak.
#   the lookup bound /characters/lookup is the ONE deliberately cross-user surface
#                   in M4 ("serving foreign users' configs is THE POINT"). Its
#                   size bound is @Size(min=1,max=50) bean validation; without it
#                   one call scans the whole brand.
#
# NOT COVERED, and why. The lookup's BRAND WALL — that a batched lookup returns
# same-brand peers and silently omits everyone else — is the property that most
# deserves a test and is NOT here: it needs a second seeded persona in a
# DIFFERENT brand, and the e2e roster is single-brand. Asserting it with two
# same-brand personas would pass while proving nothing about the wall. Left
# undone and named rather than faked.
#
# NEEDS A MESH. @env:docker; the forge is a ROLE_USER floor, so e2e-user is the
# real audience here and not a stand-in.
@service:character-forge @layer:bff @env:docker @interface:browser
Feature: The forge's save, activate and id-addressed read surfaces are bounded

  Scenario: activating a second character clears the first — there is exactly one active @role:e2e-user @service:character-forge @layer:bff
    Given I am signed in as the persona for this scenario
    And I create and activate a forge character named "e2e first"
    When I create and activate a forge character named "e2e second"
    Then my active forge character is named "e2e second"
    And exactly one of my forge characters is marked active

  Scenario: the 33rd character is refused with 409 and the 32 stored ones are untouched @role:e2e-user @service:character-forge @layer:bff
    Given I am signed in as the persona for this scenario
    And I hold 32 stored forge characters
    When I create one more forge character
    Then the forge create was rejected with HTTP 409
    And I still hold 32 stored forge characters

  Scenario Outline: an id-addressed read of an <id_kind> id is a 404, never a 403 @role:e2e-user @service:character-forge @layer:bff
    Given I am signed in as the persona for this scenario
    When I read the forge character id "<id_kind>"
    Then the forge read was rejected with HTTP 404

    Examples:
      | id_kind        |
      | another-owners |
      | another-brands |
      | not-a-uuid     |

  Scenario Outline: a lookup of <count> subjects is refused at validation @role:e2e-user @service:character-forge @layer:bff
    Given I am signed in as the persona for this scenario
    When I look up the active characters of <count> subjects
    Then the lookup was rejected with HTTP 400

    Examples:
      | count |
      | 0     |
      | 51    |
