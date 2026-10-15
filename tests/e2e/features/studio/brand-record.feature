# C-RECORD — one brand record drives every brand's look and ways on every start path
# (hugmesh-generator#654, decisions D2, D5 and D10).
#
# WHAT IS DRIVEN: the Studio's Qt-free command line, in a FRESH python process each
# time — the verbs the Docker route's text screens print in their plan command (the
# Makefile has no RECORD knob yet, so a person runs them by hand):
#   python3 -m hugmesh_studio.core.local_mesh_bootstrap show-record --record FILE
#   python3 -m hugmesh_studio.core.local_mesh_bootstrap plan        --record FILE
#   python3 -m hugmesh_studio.core.brand_model          profile     --record FILE
# against a record the scenario writes into a scratch folder: one superbrand with a
# default look, a brand with its own look and Tor address, and a brand that inherits
# everything.
#
# The assertions read the printed record the way a person would: each look value
# carries the source of the value ("this brand's own" / "inherited from the
# superbrand"), each way to reach a brand carries what each start path does with it,
# and the words are the ones docs/BRAND-MODEL.md defines (the step reads the
# document's table, never a copy). The same superbrand id must appear in the Docker
# plan, the kind line of the record and the generated builder profile: one block,
# three paths. The plan is asked for WITHOUT --with-tor: Tor is on because the
# record's superbrand says so, and a flag that contradicts the record is refused.
#
# OFFLINE and Qt-free: no mesh, no cluster, no browser. The kind path is proven only
# as far as the printed plan: nothing here starts a cluster.
@interface:cli @issue:generator-654
Feature: One brand record drives every brand's look and ways on every start path

  Background:
    Given a scratch brand record "acme" with a superbrand and the brands "shop" and "blog"

  Scenario: a fresh process prints every brand's effective look with the source of each value
    When I show the brand record in a fresh Studio process
    Then the command succeeded
    And the record output lists the superbrand "acme" and the brands "shop-mesh-example" and "blog-mesh-example"
    And the record output says the look value "primary" of brand "shop-mesh-example" is "#aa0000" and "this brand's own"
    And the record output says the look value "font" of brand "shop-mesh-example" is "System UI" and "inherited from the superbrand"
    And the record output says the look value "primary" of brand "blog-mesh-example" is "#112233" and "inherited from the superbrand"
    And every look value printed for a brand carries one of the model's two sources

  Scenario: every way to reach a brand is printed with its effect on each start path
    When I show the brand record in a fresh Studio process
    Then the command succeeded
    And for brand "shop-mesh-example" the record output gives the "Tor address" an effect on the "Docker mesh", the "kind cluster" and the "node image"
    And for brand "shop-mesh-example" the record output gives the "internal name" an effect on the "Docker mesh", the "kind cluster" and the "node image"
    And for brand "shop-mesh-example" the record output gives the "public name through a provider" an effect on the "Docker mesh", the "kind cluster" and the "node image"
    And every term the record output uses is a word of the model document
    And the record output uses no word the brand screens forbid

  Scenario: the one superbrand block drives the Docker plan, the kind line and the builder profile
    When I print the Docker mesh plan from the brand record in a fresh Studio process
    Then the command succeeded
    And the command output contains "Brand:      acme  (Acme Mesh)"
    And the command output contains "Domain:     mesh.example"
    And the command output contains "TOR=on"
    And the command output contains "shop.mesh.example: its own onion (key ‘shop-mesh-example’), served as brand ‘shop-mesh-example’"
    When I write the builder profile from the brand record in a fresh Studio process
    Then the command succeeded
    And the generated profile sets "BRAND" to "acme"
    And the generated profile sets "SUPERDOMAIN" to "acme.internal"
    And the generated profile sets "TOR_BRANDS" to "shop-mesh-example=shop-mesh-example"
    When I show the brand record in a fresh Studio process
    Then the command output contains "kind cluster:      brand acme; Tor per brand: shop.mesh.example"

  Scenario: a command-line flag that contradicts the record's Tor way is refused, not obeyed
    Given a scratch brand record "acme" whose superbrand has no Tor address
    When I print the Docker mesh plan from the brand record in a fresh Studio process
    Then the command succeeded
    And the command output contains "TOR=off"
    And the command output contains "NO onion for the Tor domains (shop.mesh.example)"
    When I ask the Docker mesh plan for Tor on the command line against the brand record
    Then the command failed
    And the command output contains "the brand record says this mesh has no Tor address, but --with-tor was given"

  # show-record exists to say what the running mesh does. The stack node publishes
  # each own sign-in on a port by its position in the GIVEN list, so the record must
  # list them in that order too: zed then alpha is 8001 then 8002 in both verbs.
  Scenario: show-record and the plan give each own sign-in the same port, in the order given
    When I show the brand record and print the Docker mesh plan from two own sign-ins named in reverse alphabetical order in fresh Studio processes
    Then the command succeeded
    And the record output and the plan give the same sign-in port to each own sign-in, 8001 then 8002

  # D14 (the production hold) is another lane's and is not built yet. The plan is the
  # confirm-before-run text, so it may say "held" ONLY when the Makefile reads the
  # knob; the step reads the Makefile itself, so this flips the day the hold lands.
  Scenario: the plan tells a production operator the truth about the Tor hold
    When I print the Docker mesh plan for a production mesh from the brand record in a fresh Studio process
    Then the command succeeded
    And the command output contains "TOR=on"
    And the plan says the Tor address is held until Go live exactly when the Makefile reads TOR_HOLD
