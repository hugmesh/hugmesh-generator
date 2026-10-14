# C-PROFILE — the generated builder profile cannot run code in a builder
# (hugmesh-generator#654, decision D5).
#
# WHAT IS DRIVEN: the profile writer of the brand record, in a FRESH python process
# (python3 -m hugmesh_studio.core.brand_model profile --record FILE --out OUT), then
# the REAL consumer shape: a bash harness under `set -eu` that sources whatever
# profile exists, the way an image builder sources brands/<brand>.conf.
#
# The hostile record carries a superbrand title that is a command substitution which
# would create a sentinel file. The writer must refuse it — so no profile exists —
# and the harness, sourcing nothing, must leave no sentinel behind. The control
# scenario shows a safe title reaching the harness verbatim, so the first scenario is
# red for the right reason (the title) and not because the writer is broken for all.
#
# OFFLINE and Qt-free: no mesh, no builder, no root.
@interface:cli @issue:generator-654
Feature: The generated builder profile cannot run code in a builder

  Scenario: a brand title holding a command substitution writes no profile and runs nothing
    Given a scratch brand record whose superbrand title is a command that would create a sentinel file
    When I write the builder profile from the brand record in a fresh Studio process
    Then the command failed
    And the command output contains "BRAND_TITLE"
    And the command output contains "no profile written"
    And no builder profile was written for the brand record
    And the builder harness sources whatever profile exists and the sentinel file does not exist

  Scenario: a safe title reaches the builder harness verbatim and nothing runs
    Given a scratch brand record "acme" with a superbrand and the brands "shop" and "blog"
    When I write the builder profile from the brand record in a fresh Studio process
    Then the command succeeded
    And the builder harness sources the generated profile and reads "BRAND_TITLE" as "Acme Mesh"
    And the builder harness sources the generated profile and reads "BRAND" as "acme"
    And the builder harness sources whatever profile exists and the sentinel file does not exist
