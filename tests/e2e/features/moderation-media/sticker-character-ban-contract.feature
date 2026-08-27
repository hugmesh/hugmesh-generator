# GROUP B of tests/e2e/specs/28-sticker-character-vn-moderation.spec.ts, as
# executable Gherkin.
#
# EVERY SCENARIO IN THIS FILE IS PENDING, ON PURPOSE. The fine-grained
# sticker/character ban DOES NOT EXIST in the codebase. These are CONTRACT
# scenarios: they name the desired endpoint, verb and status so that the day the
# capability lands, deleting one `Given this scenario is PENDING because …` line
# turns it into a live test. They are the Gherkin twin of the spec's
# `test.fixme` describe-block and MUST NOT be read as failing bugs.
#
# They are not decoration: each one is compiled by bddgen, collected by
# Playwright, executed, and reported as SKIPPED WITH ITS REASON PRINTED — so the
# gap is visible in every run's summary rather than living in a comment.
#
# THE GAP, verbatim:
#   (a) Ban a SPECIFIC sticker/character globally/retroactively — NO. The closest
#       is REJECTing one owner's PENDING row via finding resolution, but it is
#       keyed on that owner's row id (not a global asset/pHash ban), it is
#       PENDING-guarded (an already-ACTIVE asset CANNOT be revoked), it is
#       reactive to the auto-filed finding queue, and there is no de-registration
#       from im.ponies.user_emotes on REJECT.
#   (b) Ban a USER from stickers/characters while preserving TEXT — MISSING
#       ENTIRELY. StickerController/CharacterPartController gate only on flat
#       hasRole('USER'); the only per-user levers are whole-platform/whole-account
#       suspensions, and the suspension gate hard-403s the whole session.
#   (c) Ban a ROLE from stickers/characters — MISSING ENTIRELY. No ROLE_STICKER/
#       ROLE_CHARACTER/ROLE_VN, no role->feature deny-map.
#
# SILVER LINING: text and the VN asset library are ALREADY independent surfaces
# (the A6 rows in sticker-character-vn.feature prove text is untouched by any VN
# moderation state), so a correctly-scoped feature ban would naturally leave text
# intact — only the ban MECHANISM is missing.
@pending @service:character-studio @layer:bff
Feature: Fine-grained sticker and character bans (CONTRACT — capability NOT built)

  # B1, gap (a).
  Scenario: an admin bans a SPECIFIC sticker id retroactively @role:e2e-admin @service:character-studio @layer:bff
    Given this scenario is PENDING because "gap (a): no direct, proactive, global asset ban exists. DESIRED: POST /bff/admin/character/stickers/{stickerId}/ban {reason} -> 200, then GET /bff/admin/character/stickers/{stickerId} -> status REJECTED, and the asset is de-registered from the owner's im.ponies.user_emotes pack. Today the closest thing is REJECTing one owner's PENDING row via finding resolution, which cannot revoke an already-ACTIVE asset."
    When I open the path "/admin/stickers"
    Then the element with test id "sticker-ban" is visible

  # B2, gap (b) — the capability the product owner actually asked for.
  Scenario: an admin bans a USER from stickers while their TEXT keeps working @role:e2e-admin @service:character-studio @layer:bff
    Given this scenario is PENDING because "gap (b): there is no per-user feature ban. DESIRED: POST /bff/admin/users/{subject}/feature-ban {feature:'sticker'} -> 200, then as that user POST /bff/user/character/stickers -> 403 and PUT .../send/m.sticker/{txn} -> 403, WHILE PUT .../send/m.room.message/{txn} m.text stays 200. Today the only per-user lever is a whole-platform suspension, which hard-403s the session and kills text too."
    When I open the path "/admin/users"
    Then the element with test id "feature-ban" is visible

  # B3, gap (c).
  Scenario: an admin bans a ROLE from stickers, text preserved @role:e2e-admin @service:character-studio @layer:casdoor
    Given this scenario is PENDING because "gap (c): no role-scoped feature ban exists. DESIRED: a dedicated feature role (ROLE_STICKER/ROLE_CHARACTER/ROLE_VN) or a role->feature deny-map gating the sticker/character path WITHOUT touching the platform-access roles that gate text. GET /bff/session for a banned user would surface that feature role — which is exactly what the A7 rows in sticker-character-vn.feature lock against today."
    When I open the path "/admin/roles"
    Then the element with test id "role-feature-ban" is visible

  # B4, gap (a), character variant.
  Scenario: banning a SPECIFIC character is enforced at send time @role:e2e-admin @service:tuwunel @layer:homeserver
    Given this scenario is PENDING because "gap (a) character variant: there is NO stored per-message character identity and NO send-time enforcement. The only per-message VN field is a free-form vn.expression, and the homeserver forwards custom content verbatim (the A2 scenario proves it round-trips unchecked). DESIRED: a first-class content['net.hugmesh.vn'].characterId, POST /bff/admin/character/{characterId}/ban -> 200, then a send referencing it -> 403 while a plain-text send stays 200."
    When I open the path "/admin/characters"
    Then the element with test id "character-ban" is visible

  # B5 — N/A, not merely pending, and recorded so the cross-platform matrix is
  # explicit rather than silently missing.
  Scenario: Akkoma-side sticker or character moderation @role:e2e-mod @service:akkoma @layer:homeserver
    Given this scenario is PENDING because "N/A rather than unbuilt: Mastodon/Akkoma has ZERO sticker/character/VN feature — the only sticker-like analog is a standard custom_emoji shortcode in status text. There is nothing platform-native to moderate, so a cross-platform sticker/character ban is impossible there until such a feature is built on the Mastodon side. If it ever is, the desired shape mirrors B1/B2 against a Mastodon moderation endpoint."
    When I open the path "/mastodon"
    Then the element with test id "mastodon-character-ban" is visible
