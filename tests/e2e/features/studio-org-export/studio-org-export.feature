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
#     as the person running it, and git is never asked to force, mirror or delete;
#   * the repositories planned for a domain include what its selected optional
#     services add, for the mesh's own domain too — whether the service was picked
#     on its own row or on the mesh-wide Services step (what the mesh actually runs);
#   * the Terminal line the step shows is the SAME export: run from a terminal it
#     plans exactly the repositories the step's table lists;
#   * an existing repository that already holds something is refused and left
#     untouched — whatever branch its content is on, main or not.
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
    And Apply is disarmed until the org name is typed, in any letter case
    And the terminal line the export step shows plans the same repositories as its table
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
    And the result column reports create for every row and Apply stays disarmed when the name is typed again
    And git was never asked to force, mirror, delete or prune
    And the Studio grab is a non-empty PNG

  # ── the own domain's selected services add their repositories ─────────────
  @interface:studio
  Scenario: the own domain's selected service puts its repository on the plan @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh whose own domain selects "phpbb" and press Plan
    Then the plan lists "exampleorg/example-forum-api" for the own domain's selected service and marks it "missing source"
    And the stand-in GitHub holds no repository and every gh call during the plan was a repo view
    And the terminal line the export step shows plans the same repositories as its table
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── ... and so does a service picked on the mesh-wide Services step ────────
  # The per-row selection is recorded, not enforced: the compose profiles the mesh
  # runs come from the Services step. The ordinary local mesh types the org on the
  # own row and picks its services there, so that list must reach the export too.
  @interface:studio
  Scenario: a service picked on the mesh-wide Services step puts its repository on the own domain's plan @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh whose Services step picked "phpbb" and press Plan
    Then the plan lists "exampleorg/example-forum-api" for the own domain's selected service and marks it "missing source"
    And the stand-in GitHub holds no repository and every gh call during the plan was a repo view
    And the terminal line the export step shows plans the same repositories as its table
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── the Angular build: kind detection for the other half of the org ───────
  # The domain's selected service names a repository; here its checkout is an
  # Angular application (an angular.json, no pom). The site list must record the
  # npm build for it, which is what switches the workflow's npm steps on, and the
  # Java repositories beside it must keep theirs.
  @interface:studio
  Scenario: the published site list gives an Angular repository the npm build @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh whose own domain selects "phpbb" with "hugmesh-forum-api" an Angular application, apply it with the name typed, and read the published site list
    Then the published site list records the "angular" build for "example-forum-api" and the "java" build for "example-parent", and the build workflow switches the npm steps on for it
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── an existing repository with content on another branch is refused ──────
  @interface:studio
  Scenario: an existing repository holding content on another branch is refused by Apply and left untouched @interface:studio
    When I walk the Go-Live wizard to the export step with "example-parent" already holding content on its "master" branch in the stand-in GitHub, and apply it with the name typed
    Then the plan marks "exampleorg/example-parent" as "exists (compared at apply)" and Apply refuses it as an existing non-empty repository
    And that repository still holds only its "master" branch at the same commit and git never pushed to it
    And every other planned repository and the site hold exactly one commit on main in the stand-in GitHub
    And no dialog opened in the org-export walk
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

  # ── the Maven settings file each Java repository's build uses ─────────────
  # The repository-root settings.xml is the GitLab registry file and cannot work
  # from GitHub; only the CI settings file under .github reads the GitHub Packages
  # login. The choice is recorded per repository in the site's repos.json, which
  # is what the generated build workflow reads.
  @interface:studio
  Scenario: the published site list carries each Java repository's Maven settings file @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg", apply it with the name typed, and read the published site list
    Then the published site list records ".github/maven-ci-settings.xml" for "example-parent" and no settings file for "example-commons"
    And the plan notes that "example-commons" has only the GitLab registry file
    And the exported "example-parent" holds ".github/maven-ci-settings.xml" and the exported "example-commons" holds no CI settings file
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── the Maven wrapper: not every Java repository has one ──────────────────
  # hugmesh-build-config is a plain jar with a pom and no mvnw (its own release
  # workflow runs `mvn`): the generated build must not call ./mvnw for it.
  @interface:studio
  Scenario: a Java repository without a Maven wrapper is built with plain mvn @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg", apply it with the name typed, and read the published site list
    Then the published site list records no Maven wrapper for "example-build-config" and one for "example-parent", and the build workflow falls back to plain mvn
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── a picker changed after Plan drops the plan ────────────────────────────
  # Apply runs the plan it was armed by; a picker flipped afterwards must not leave
  # that plan armed under a screen that now says something else.
  @interface:studio
  Scenario: flipping the visibility picker after Plan drops the plan and nothing is created until a fresh Plan @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg", plan it as public, flip the visibility picker to private and press Apply with the name typed
    Then the flipped picker dropped the plan, Apply stayed disarmed and the stand-in GitHub still holds no repository
    And a fresh Plan after the flip creates only private repositories when applied
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── an .npmrc is dropped when it holds a login, kept when it does not ─────
  @interface:studio
  Scenario: an .npmrc holding a login placeholder is dropped and a token-free one is published @interface:studio
    When I walk the Go-Live wizard to the export step with a token-free ".npmrc" and a placeholder-login "web/.npmrc" planted in "hugmesh-parent", apply it with the name typed, and read the published ".npmrc"
    Then the plan lists "web/.npmrc" as excluded for "hugmesh-parent" because of an npm login and does not list ".npmrc"
    And the exported "example-parent" holds ".npmrc" with the text "legacy-peer-deps=true" and no "web/.npmrc"
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── a rename that would leave the work folder is refused inline ───────────
  @interface:studio
  Scenario: a rename map sending a repository outside the work folder is refused inline and touches nothing @interface:studio
    When I walk the Go-Live wizard to the export step and point the Rename map field at a file renaming "hugmesh-commons" to "../../escape" and press Plan
    Then the export step refuses the plan inline naming the bad repository rename
    And nothing was created in the stand-in GitHub, no gh call was made and no repository folder was written
    And the folder the rename pointed at still holds only its untouched file
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── an .npmrc with a login written into a URL is dropped too ──────────────
  # `registry=https://user:token@host/` is a login as much as an _authToken line.
  @interface:studio
  Scenario: an .npmrc with a login written into its registry address is dropped @interface:studio
    When I walk the Go-Live wizard to the export step with a token-free ".npmrc" and a URL-login "web/.npmrc" planted in "hugmesh-parent", apply it with the name typed, and read the published ".npmrc"
    Then the plan lists "web/.npmrc" as excluded for "hugmesh-parent" because of an npm login and does not list ".npmrc"
    And the exported "example-parent" holds ".npmrc" with the text "legacy-peer-deps=true" and no "web/.npmrc"
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── a token is found in a file whatever its encoding ──────────────────────
  # A file that is not UTF-8 text, or holds a NUL byte, used to be skipped by the
  # scan and published with the token in it.
  @interface:studio
  Scenario: a token hidden in a latin-1 file or a binary file blocks that repository @interface:studio
    When I walk the Go-Live wizard to the export step with a fake token hidden in a latin-1 file and in a binary file of "hugmesh-commons" and press Plan
    Then the plan is blocked for "hugmesh-commons" naming "latin.txt: GitHub token" and "nul.bin: GitHub token" and Apply cannot be armed
    And the stand-in GitHub holds no repository and every gh call during the plan was a repo view
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── a private key is found in the shapes real tools write ─────────────────
  # A passphrase-protected OpenSSL key has two header lines and a blank line between
  # its BEGIN line and the base64; a key pasted into Java source is split across
  # string pieces. A rule that wanted the base64 straight after the header published
  # both.
  @interface:studio
  Scenario: a passphrase-protected private key and a key split across Java strings block that repository @interface:studio
    When I walk the Go-Live wizard to the export step with an encrypted private key and a Java-string private key planted in "hugmesh-commons" and press Plan
    Then the plan is blocked for "hugmesh-commons" naming "notes/legacy.txt: private key header" and "src/Keys.java: private key header" and Apply cannot be armed
    And the stand-in GitHub holds no repository and every gh call during the plan was a repo view
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── the commit holds exactly the files the plan counted ───────────────────
  # `git add -A` honoured the snapshot's own .gitignore and the person's global
  # ignore file, so a tracked file could be counted by the plan and left out.
  @interface:studio
  Scenario: a tracked file that an ignore rule names is still published @interface:studio
    When I walk the Go-Live wizard to the export step with "keep.log" tracked in "hugmesh-commons" next to a ".gitignore" that ignores it, under a global git ignore of "*.log", and apply it with the name typed
    Then the exported "example-commons" holds "keep.log" and ".gitignore"
    And every exported repository holds exactly as many files as its plan counted
    And git was never asked to force, mirror, delete or prune
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── the typed name belongs to the plan it was typed for ───────────────────
  @interface:studio
  Scenario: a name typed for a private plan does not arm a later public plan @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg", plan it as private with the name typed, flip the picker to public and press Plan again
    Then the name typed for the private plan was cleared, the public plan is not armed and nothing is created until the name is typed again
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── a config file's values have the right types ───────────────────────────
  # A number for the brand, "no" for a switch (truthy!) and a string for a list
  # used to crash the CLI or be read the wrong way round, and aborted the GUI.
  @interface:studio
  Scenario Outline: a config file whose <key> has the wrong type is refused inline and by the CLI @interface:studio
    When I walk the Go-Live wizard to the export step and add a config file whose "<key>" is "<value>"
    Then the export step refuses that config file inline naming "<key>", the CLI exits 2 with no traceback and nothing is exported
    And the step still plans the saved mesh afterwards
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

    Examples:
      # a plain value is JSON (123 is a number); "text:" makes it a string
      | key               | value                |
      | brand             | 123                  |
      | include_generator | text:no              |
      | skip_repos        | text:hugmesh-parent  |

  # ── two repositories sent to one target are refused ───────────────────────
  # Both snapshots would be written to one folder and only the second repository
  # would ever be exported, with nothing said.
  @interface:studio
  Scenario: two repositories renamed to one target are refused inline and nothing is exported @interface:studio
    When I walk the Go-Live wizard to the export step and point the Rename map field at a file sending "hugmesh-actions" and "hugmesh-commons" to the one name "dup" and press Plan
    Then the export step refuses the plan inline saying two repositories share the target "dup"
    And nothing was created in the stand-in GitHub, no gh call was made and no repository folder was written
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── login files and private keys by name ──────────────────────────────────
  @interface:studio
  Scenario: a login file, a docker login file and a private PGP key are not published and a public PGP key is @interface:studio
    When I walk the Go-Live wizard to the export step with a login file, a private PGP key file and a public PGP key file planted in "hugmesh-parent", apply it with the name typed, and read what was published
    Then the plan lists the login file, the docker login file and the private PGP key file as excluded for "hugmesh-parent" and lists neither the public PGP key file nor the other config.json
    And the exported "example-parent" holds the public PGP key file and the other config.json and none of the dropped files
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG

  # ── a plan that never asked GitHub says so ────────────────────────────────
  @interface:studio
  Scenario: a plan made from a terminal with --no-probe says not looked at and calls no gh @interface:studio
    When I walk the Go-Live wizard to the export step for a saved mesh naming the org "exampleorg", plan it from a terminal with --no-probe and read what it printed
    Then the terminal plan exited 0 with "not looked at" on every repository row and the site row and made no gh call
    And no dialog opened in the org-export walk
    And the Studio grab is a non-empty PNG
