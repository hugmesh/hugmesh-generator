# Executable Gherkin for tests/e2e/specs/02-admin-allowlist.spec.ts.
#
# WHAT THE SPEC ACTUALLY DOES (not an idealised version): admin@hugmesh.net —
# seeded ROLE_ADMIN,ROLE_USER in tests/e2e-extra-personas.sh — onboards, opens the
# admin console THROUGH THE PROFILE MENU (profile-trigger -> menu-admin, NOT a
# top-level `nav-admin`, which no longer exists anywhere in the UI: that stale
# testid is the scar specs 08/09 carry the same fix for), and invites six Gmail
# identities plus one Discord handle, asserting each lands as an allowlist row
# ([data-email=…] / [data-discord=…]).
#
# WHY THE INVITEES ARE A PLAIN Examples COLUMN AND NOT `role`. The `role`
# dimension names WHO IS DRIVING the browser — here, always the admin. The
# invitees are DATA the admin types. Spelling them as `role` would silently
# re-point the sign-in step at each invitee in turn and stop testing the admin
# surface altogether. Only the axes a scenario genuinely varies get an axis
# column; `invitee` is data.
#
# COST NOTE: the Background signs in per scenario, so this feature performs one
# onboarding per invite. specs/helpers.ts onboard() is idempotent (a returning
# account takes the fast nav-user branch), and per-invite isolation is what buys
# the per-row screenshot chain the AfterStep hook writes.
@service:admin @layer:ui @role:admin@hugmesh.net
Feature: Admin allowlist — the admin provisions the identities the rest of the suite signs in as

  Background:
    Given I am signed in as the persona for this scenario
    When I open the admin console from the profile menu
    Then the element with test id "admin-view" is visible

  Scenario Outline: the admin invites the Gmail identity <invitee> @role:admin@hugmesh.net @service:admin @layer:ui
    When I invite the email identity "<invitee>"
    Then the allowlist shows the email identity "<invitee>"

    Examples:
      | invitee          |
      | alice@gmail.com  |
      | bob@gmail.com    |
      | carol@gmail.com  |
      | dave@gmail.com   |
      | eve@gmail.com    |
      | frank@gmail.com  |

  Scenario: the admin invites a Discord identity @role:admin@hugmesh.net @service:admin @layer:ui
    When I invite the Discord identity "dragoneer"
    Then the allowlist shows the Discord identity "dragoneer"
