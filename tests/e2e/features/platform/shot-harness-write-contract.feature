# WHAT THIS ASSERTS — hugmesh-generator#388, fixed by PR #390 (merged ad06fce0,
# 2026-09-16; re-checked on origin/main 9f4d6d30, 2026-09-23).
#
# tests/e2e/shot-harness/shots.json is the DATA table behind the 17 manual test
# plans' screenshots: capture.spec.ts signs in as a row's persona, opens its
# route and performs its `do` actions. Three rows were wrong in ways the table
# itself can now be held to:
#   1. games-operator-14/15/17 click gs-suspend / gs-resume / gs-terminate, and
#      hugmesh-admin-ui renders each of those data-testids ONCE PER
#      `<li *ngFor="let i of instances()">` (games-services.component.html:110,
#      :119/:125/:131, still true on admin-ui origin/main d5ffdf8a). Playwright's
#      page.getByTestId(id).click() is STRICT: with world1+world2 present it
#      throws a strict-mode violation instead of clicking. The harness gained an
#      optional `"first": true` action field (shot-table.mjs validates it; only
#      `true` is legal; capture.spec.ts then uses locator.first()), and #300 line
#      44 consents to "the first Instances row".
#   2. image-builder-14 granted ROLE_IMAGE_BUILDER to the shared e2e-user
#      fixture and never revoked it, so on any stack with casdoor.admin.enabled
#      every harness run left the fixture 12 other personas sign in as changed.
#      The row now clicks revoke-ROLE_IMAGE_BUILDER after the grant and waits on
#      roles-result again (plan #301 step 14 Do items 3-4).
#   3. curtailed-member-10 files a PENDING appeal as e2e-user, after which
#      admin-20 (expects aa-empty) fails until someone decides it. The table
#      now carries that as an ORDERING CONTRACT: admin runs before
#      curtailed-member in personas[], which is what --all follows.
#
# WHAT IS PINNED HERE, offline, by reading the committed table: each of the three
# rows in its fixed shape, the `first` property as a GENERIC rule over every
# click on a per-instance testid (so a fourth such row lands under the rule
# without anyone editing this file), the persona order, and — through the real
# validator — that the table still validates. The one `@interface:cli` row is
# the only one that runs a command.
#
# NOT COVERED, and why (recorded rather than decorated): the live reproduction —
# two game-server instances on a mesh, then a click on gs-suspend that must act
# on exactly one of them — has no fixture in the compose stack (no games runner
# is deployed there; there is no kind cluster today) and no seeded second
# instance on any e2e mesh. #390's own comment names the same three things as
# "unproven live": first() picking the row a tester expects, the doorLost
# breaker on a real dead door, and the second roles-result wait landing on the
# revoke's message. Those remain a harness run on a SEED_COMPLETE_REGISTRATION=1
# stack (`npm run shots -- --persona games-operator`), not a scenario here.
#
# THIS RUNS OFFLINE (shots.json and shot-table.mjs are files in THIS repository).
@layer:ui @issue:generator-388
Feature: The shot table names every write it makes and scopes per-row clicks to one row

  Background:
    Given the shot table is loaded

  # The RULE, not the three rows: any click on a testid admin-ui renders once per
  # instance row must be scoped, wherever it appears in the table.
  Scenario: every click on a per-instance games-services control is scoped to the first row @layer:ui
    Then every shot-table click on "gs-suspend, gs-resume, gs-terminate" is scoped to the FIRST matching element

  Scenario Outline: games-operator step <step> clicks <testid> on the first Instances row only @layer:ui
    Then the shot row for persona "games-operator" step "<step>" clicks "<testid>" on the FIRST matching element only

    Examples:
      | step | testid       |
      | 14   | gs-suspend   |
      | 15   | gs-resume    |
      | 17   | gs-terminate |

  # Grant THEN revoke: net zero on the shared e2e-user fixture. The second
  # `expect roles-result` is a real wait — run() clears the result and
  # `.result:empty` is display:none, so roles-result is hidden until the revoke
  # answers (#388 item 2).
  Scenario: image-builder step 14 revokes the role it granted @layer:ui
    Then the shot row for persona "image-builder" step "14" performs exactly the actions "fill roles-user, click grant-ROLE_IMAGE_BUILDER, expect roles-result, click revoke-ROLE_IMAGE_BUILDER, expect roles-result"

  # The ordering contract (#388 item 3): curtailed-member-10 leaves a PENDING
  # appeal behind; admin-20 expects the inbox empty. --all follows personas[].
  Scenario: the admin persona runs before the curtailed member whose appeal would empty its inbox @layer:ui
    Then the shot table runs persona "admin" before persona "curtailed-member"

  # The real validator over the real table — the same command a plan author runs
  # after appending a row. `first` is validated there (only `true`, only on a
  # testid-addressing action), so this is where an illegal value would surface.
  @interface:cli
  Scenario: the shot table validates with the harness's own validator @interface:cli @layer:ui
    When I run the shell command "node tests/e2e/shot-harness/shot-table.mjs validate"
    Then the command succeeded
    And the command output contains "shots.json OK"
