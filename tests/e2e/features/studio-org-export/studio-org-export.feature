# THE GO-LIVE "EXPORT TO GITHUB ORG" STEP, WALKED AND PRESSED.
#
# The ask: export the repositories a domain needs into a GitHub organisation that
# is configured per domain in the Studio, with a <domain>.github.io site repository
# whose Actions clone and build them all. The design choices under test:
#   * the step is opt-in: it exists only when some domain names an org;
#   * the org is typed on the Domains step, refused inline when it is not a slug,
#     and SURVIVES Next, the saved mesh and a re-open of that mesh;
#   * Plan is the default and touches nothing; Apply is armed only by TYPING the
#     org name; a planted banned marker blocks that repository and names the file,
#     and the Rename map field is the way to drop the file and go on;
#   * Apply leaves exactly one fresh commit per repository plus the site, authored
#     as the person running it, and git is never asked to force, mirror or delete.
#
# Every scenario walks the REAL wizards offscreen from their first page (the
# local-mesh wizard to its Domains step; the Go-Live wizard to its export step)
# through tests/e2e/studio-org-export-driver.py. GitHub is a folder of bare
# repositories; `gh` is a fake that answers from it and logs every call; `git` is
# a logging shim over the real git. Every assertion reads those logs and
# repositories, never the Studio's own say-so. Nothing is started, nothing
# reaches the network, and the operator's saved meshes are never touched (the
# Studio state dir is a scratch folder).
#
# WHY THESE ARE NOT THE WIDGET TESTS AGAIN: studio/tests/test_org_export_gui.py
# drives the pages directly, from a jump to the Generate step. These walk the
# wizards as a person does and read the outcome off the stand-in GitHub.
@layer:ui
Feature: The Studio exports a domain's repositories to its GitHub org

  # ── opt-in: no org, no step ────────────────────────────────────────────────
  @interface:studio
  Scenario: with no domain naming a GitHub org the Go-Live wizard shows no export step @interface:studio
    When I walk the Go-Live wizard from its first page with no saved mesh naming an org
    Then the Go-Live wizard goes from Generate straight to Verify and the export step does not apply
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── the org on the Domains step: refused, or kept all the way round ────────
  @interface:studio
  Scenario: a GitHub org that is not a slug is refused inline on Next and never recorded @interface:studio
    When I type the GitHub org "bad-" on the own row of the local-mesh Domains step and press Next
    Then the local-mesh Domains step refuses Next inline, naming the slug problem
    And the local-mesh record carries no GitHub org
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  @interface:studio
  Scenario: an org typed on the Domains step survives Next, the saved mesh and a re-open @interface:studio
    When I type the GitHub org "exampleorg" on the own row of the local-mesh Domains step and press Next
    Then the local-mesh Domains step accepts Next and the own domain's state carries the org "exampleorg"
    And the saved mesh records the org "exampleorg" on the own domain and the Go-Live step would find it
    And re-opening that saved mesh shows the org "exampleorg" in the own row's cell and records it again on Next
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── Plan touches nothing ───────────────────────────────────────────────────
  @interface:studio
  Scenario: Plan lists every repository and the site and creates and pushes nothing @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg" and press Plan
    Then the export step appeared after Generate for the candidate "mesh.example -> exampleorg"
    And the plan lists the targets "exampleorg/example-actions, exampleorg/example-build-config, exampleorg/example-parent, exampleorg/example-commons, exampleorg/example-auth-core, exampleorg/example-generator, exampleorg/mesh.example.github.io"
    And the stand-in GitHub holds no repository and every gh call during the plan was a repo view
    And git was not asked to push anything during the plan
    And Apply is disarmed until the org name is typed exactly
    And the Studio grab is a non-empty PNG
    And the evidence manifest holds a "widget-grab" artefact for this scenario

  # ── Apply needs the typed name ─────────────────────────────────────────────
  @interface:studio
  Scenario: Apply without the typed org name is refused inline and creates nothing @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg" and press Apply without typing the name
    Then the export step refuses the apply inline and the stand-in GitHub still holds no repository
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── Apply: one fresh commit each, never a force ────────────────────────────
  @interface:studio
  Scenario: Apply with the typed org name leaves one fresh commit per repository plus the site and never forces @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg" and apply it with the name typed
    Then every planned repository and the site hold exactly one commit on main in the stand-in GitHub
    And every snapshot commit is authored as the person running the export
    And the result column reports create for every row and Apply is disarmed again
    And git was never asked to force, mirror, delete or prune
    And the Studio grab is a non-empty PNG

  # ── a banned marker blocks that repository; the Rename map field clears it ─
  @interface:studio
  Scenario: a planted banned marker blocks that repository, names the file, and the Rename map field clears it @interface:studio
    When I walk the Go-Live wizard to the export step with a fake token planted in "hugmesh-commons" and press Plan
    Then the plan is blocked for "hugmesh-commons" naming "tests/fake-token.sh: GitHub fine-grained token" and Apply cannot be armed
    And the stand-in GitHub holds no repository and every gh call during the plan was a repo view
    When I walk the Go-Live wizard to the export step with a fake token planted in "hugmesh-commons", exclude it through the Rename map field, and press Plan
    Then the plan is clean, "tests/fake-token.sh" is listed as excluded for "hugmesh-commons", and Apply arms with the name typed
    And the Studio grab is a non-empty PNG
