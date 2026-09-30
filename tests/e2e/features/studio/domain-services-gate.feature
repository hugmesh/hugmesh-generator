# THE PER-DOMAIN SERVICES GATE — issue #494 (its #A box, landed as #495/#497 on
# 2026-09-17/18): "for each domain, the service page needs to be config …
# you have to go through before building or starting a mesh in docker or nodes".
#
# WHAT IS PROVEN HERE, and through which door:
#   * the IMAGE BUILD door (gui/pages/launch.py) — driven through the real
#     offscreen wizard with a KNOWN config loaded through the GUI's own
#     "Load config…" loader. The refusal sentence on the page and the disabled
#     Continue card are read off the page, not off a PNG;
#   * the MESH START doors (gui/pages/localmesh.py _bootstrap_up / _start_saved)
#     are click handlers the offscreen driver cannot click, so their verdict is
#     read through the ONE seam every door calls, core.domain_services.gate_reason
#     — "a test can drive the refusal with a bare ImageConfig", its own words.
#     The Studio-interface scenario above proves that seam is the one the
#     build page renders; the seam scenarios prove the other actions share it.
#
# WHAT IS NOT PROVEN HERE, said out loud (the issue's own #B and #D boxes):
#   * #B — that the selection REACHES the cluster (the §10 cut-over). That needs
#     a built image booted on a cluster; recorded below as PENDING, never faked;
#   * #D — web parity in the superadmin domain console: another repo, another lane.
#
# Nothing here builds, starts or elevates: --print-command style channels and
# an offscreen wizard only.
@layer:ui
Feature: A domain's service configuration is a required step before an image build or a mesh start

  @interface:studio @issue:generator-494
  Scenario: the image build is refused, naming the domain, while its services page was never walked @interface:studio
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"}]}
      """
    When I grab the Studio wizard page "launch" with that config fixture
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "launch"
    And the Studio page says "Cannot build these images"
    And the Studio page says "no recorded service configuration"
    And the Studio page says "acme.example"
    And the Studio control "Continue the build" is disabled
    And the Studio control "Back to the main menu" is enabled
    And the evidence manifest holds a "widget-grab" artefact for this scenario

  @interface:studio @issue:generator-494
  Scenario: walking the domain's services page is what unlocks the build @interface:studio
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"}],
       "domain_services_reviewed": ["acme.example"]}
      """
    When I grab the Studio wizard page "launch" with that config fixture
    Then the Studio grab shows the wizard page "launch"
    And the Studio page does not say "no recorded service configuration"
    And the Studio control "Continue the build" is enabled

  # The build door and BOTH docker mesh-start doors call gate_reason(cfg, action)
  # with their own action literal; the sentence must name the action AND every
  # unconfigured domain, because "configure your domains" scrolls past and
  # "acme.example has no recorded service configuration" can be acted on.
  @interface:cli @issue:generator-494
  Scenario Outline: "<action>" is refused through the shared gate seam, naming the unconfigured domain @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"},
                   {"name": "beta.example", "title": "Beta"}],
       "domain_services_reviewed": ["beta.example"]}
      """
    When I ask the Studio gate seam whether that config fixture may "<action>"
    Then the command succeeded
    And the command output contains "Cannot <action>: 1 domain has no recorded service configuration"
    And the command output contains "acme.example"
    And the command output does not contain "beta.example"

    Examples:
      | action             |
      | build these images |
      | start this mesh    |

  @interface:cli @issue:generator-494
  Scenario Outline: "<action>" proceeds once every domain's services page has been walked @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"},
                   {"name": "beta.example", "title": "Beta"}],
       "domain_services_reviewed": ["acme.example", "beta.example"]}
      """
    When I ask the Studio gate seam whether that config fixture may "<action>"
    Then the command succeeded
    And the command stdout is empty

    Examples:
      | action             |
      | build these images |
      | start this mesh    |

  # FAIL-CLOSED on junk. A hand-edited config carrying a scalar where the list
  # of reviewed domains belongs must read as "nothing reviewed", never as "all
  # reviewed" — the same reading `"domains": null` already gets.
  @interface:cli @issue:generator-494
  Scenario: a junk value in the reviewed list cannot stand in for a walked page @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"}],
       "domain_services_reviewed": "yes"}
      """
    When I ask the Studio gate seam whether that config fixture may "build these images"
    Then the command succeeded
    And the command output contains "acme.example"

  # NO DEAD END. A flow that does not CONTAIN the services step must never be
  # refused by it: a standalone image skips the step outright, so its domains
  # (if a stale config carries any) reach nothing and the gate stays silent.
  @interface:cli @issue:generator-494
  Scenario: a standalone image, which has no services step, is never refused by the gate @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "standalone", "role": "standalone-thick", "platform": "x86",
       "domains": [{"name": "acme.example", "title": "Acme"}]}
      """
    When I ask the Studio gate seam whether that config fixture may "build these images"
    Then the command succeeded
    And the command stdout is empty

  @interface:studio @issue:generator-494
  Scenario: the per-domain services page is a wizard page in the domain flow, and names each choice's scope @interface:studio
    When I grab the Studio wizard page "domain_services"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "domain_services"
    And the Studio page says "Scope"
    And the Studio page says "Where it is set"

  @interface:studio @issue:generator-494
  Scenario: the services page shows the domain it is configuring, one domain at a time @interface:studio
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"}]}
      """
    When I grab the Studio wizard page "domain_services" with that config fixture
    Then the Studio grab shows the wizard page "domain_services"
    And the Studio page says "acme.example"
    And the Studio page does not say "No domains to configure."

  # #494 box #B — the selection must actually reach the cluster. Not driveable
  # from this lane: it needs an image built from the selection and booted on a
  # cluster, then ArgoCD's Application set read back. Recorded, not faked.
  @issue:generator-494
  Scenario: an image built with a domain's service selection runs only that selection
    Given this scenario is PENDING because "the #494 #B cut-over (selection reaches the cluster; renderers fail closed) needs a built image booted on a cluster — no offline interface observes it"
    When I run the shell command "true"
    Then the command succeeded
