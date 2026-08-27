# The optional-services catalogue must agree with the federation registry about
# the MODULE slug — the key the host shell resolves a remote from.
#
# THE FACT THAT MAKES THIS A REAL FIELD AND NOT A RESTATEMENT: federationModule.slug
# is NOT the catalogue slug. phpbb proves it — catalogue slug `phpbb`, module slug
# `forum`. The seeder consumes these strings VERBATIM and says so
# (tests/stack/seed-e2e.sh: "The slugs are MODULE slugs, NOT catalogue slugs —
# phpbb's module is `forum` — so they are used VERBATIM and never re-derived
# here").
#
# WHAT GOES WRONG WHEN ONE IS MISSPELLED, and why nothing catches it today. The
# seeder does not fail on an unknown slug. It logs
#   leg 4 WARN: no federation_modules row for slug '<x>' — skipped
# and carries on to exit 0. So the operator's toggle silently does nothing, the
# registry row keeps whatever `enabled` it shipped with, and the service is
# invisible in the host shell's menu with every container up and healthy —
# precisely the "running-but-unreachable" failure the catalogue was written to
# prevent, with the one control that could fix it doing nothing.
#
# WHY THIS FILE READS NO SIBLING REPO. The claim was mined from
# hugmesh-federation-api's changesets (023-register-akkoma-module.xml registers
# slug `mastodon`; 024-register-tuwunel-module.xml registers `matrix`), but a
# step that opened them would pass on a box with that checkout and fail
# everywhere else. The same defect is provable from THIS repo alone: the module
# slug is the last segment of the module's own mountAt for every catalogued
# service, and each row NAMES the changeset that registers exactly that string.
# Six rows keep the pairing; two break it, and the two that break it are the two
# whose changesets disagree.
@harness @layer:gateway
Feature: The optional-services catalogue names the module slug the registry is keyed on

  # THE POSITIVE CONTROL, and it is load-bearing. Without it, the two pending
  # rows below could equally mean the invariant itself is invented. phpbb is the
  # sharpest row here: catalogue slug `phpbb`, module slug `forum`, mount
  # /social/forum — the one service where the two spellings provably differ AND
  # the catalogue gets it right.
  Scenario Outline: <service> declares the module slug its mount path is named for @service:<service> @layer:gateway
    Then the federation module slug for this service is the last segment of its mount path
    And the optional-services catalogue registers this service under the federation module slug "<module_slug>"
    And the optional-services catalogue mounts this service at "<mount_at>"

    Examples: six catalogued services, including the one whose slugs deliberately differ
      | service          | module_slug      | mount_at          |
      | phpbb            | forum            | /social/forum     |
      | games            | games            | /games            |
      | tube             | tube             | /tube             |
      | owncast          | owncast          | /owncast          |
      | character-studio | character-studio | /character-studio |
      | character-forge  | character-forge  | /character-forge  |

  # ── THE TWO DIVERGENT ROWS ────────────────────────────────────────────────
  #
  # @fixme, not a red build: the fix is a two-word edit in
  # specs/cluster/optional-services.yaml (:114 and :135), it lives outside this
  # test lane's remit, and asserting the CURRENT value instead would encode the
  # bug as the contract. These scenarios are still listed, still generated, and
  # an undefined step in them still fails `npx bddgen` — they are pending, not
  # decorative. Delete the @fixme when the catalogue is corrected.
  #
  # OBSERVED 2026-08-26, read out of hugmesh-federation-api:
  #   023-register-akkoma-module.xml:55   <column name="slug" value="mastodon"/>
  #   024-register-tuwunel-module.xml:55  <column name="slug" value="matrix"/>
  # against optional-services.yaml:114 `slug: akkoma` and :135 `slug: tuwunel`.
  #
  # NOT YET VERIFIED: whether any live consumer reaches these two rows today.
  # The Studio's federation lane is the only consumer this repo has, and it
  # routes akkoma/tuwunel through COMPOSE PROFILES (MECH_COMPOSE_PROFILE), so
  # its drift probe (studio/tests/test_local_services.py:270) skips exactly these
  # two by construction. That is why the misspelling has survived: the one test
  # that compares the catalogue to the registry cannot see the two rows that
  # disagree.

  @fixme @service:akkoma @layer:gateway
  Scenario: PENDING (optional-services.yaml:114 says `akkoma`) — the Mastodon remote is registered as `mastodon` @service:akkoma @layer:gateway
    Then the optional-services catalogue registers this service under the federation module slug "mastodon"
    And the optional-services catalogue mounts this service at "/social/mastodon"
    And the federation module slug for this service is the last segment of its mount path

  @fixme @service:tuwunel @layer:gateway
  Scenario: PENDING (optional-services.yaml:135 says `tuwunel`) — the Matrix remote is registered as `matrix` @service:tuwunel @layer:gateway
    Then the optional-services catalogue registers this service under the federation module slug "matrix"
    And the optional-services catalogue mounts this service at "/social/matrix"
    And the federation module slug for this service is the last segment of its mount path
