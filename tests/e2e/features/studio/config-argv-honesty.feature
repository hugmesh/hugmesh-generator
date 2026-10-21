# CONFIG -> ARGV HONESTY — a Studio knob emits exactly the argv (or manifest
# key) a builder parses: no flag the builders ignore, no silent omission of one
# they need. This repo's named failure mode is the GUI knob whose state is not
# what the build does (the selected-services incident; #384's own words), and
# the Qt-free `--print-command --config <json>` channel is the honesty pattern
# the issues themselves invoke: the SAME core the GUI's Review page previews,
# reached with no display, no Qt, no build.
#
# Every fixture is written from the Gherkin so the reader sees exactly which
# fields were set; `--print-specs` is the per-image SPEC channel (what the
# loader kept after load -> materialise -> serialise), which is how a field the
# schema does not carry yet shows up red.
#
# Issues: #335 (Vault internal/external + base CA — LANDED), #384 (anubis
# tri-state — open), #521 (bundle_source unset — open), #482 (per-domain publish
# target / build target / domain type — open), #266 (per-domain external IdP —
# open, decision A: Studio fields wait for a consumer).
@layer:ui
Feature: A Studio config knob only emits what a builder actually parses

  # ── #335: the Vault store, split internal / external ───────────────────────
  @interface:cli @issue:generator-335
  Scenario: an unset Vault store emits no vault flag at all (the byte-identical default) @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test"}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output does not contain "--vault-addr"
    And the command output does not contain "--vault-external-addr"

  @interface:cli @issue:generator-335
  Scenario: the internal and the external Vault addresses both reach the node builder's argv @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test",
       "vault_addr": "https://vault.mesh.internal:8200",
       "vault_external_addr": "https://vault.example.org"}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--vault-addr https://vault.mesh.internal:8200"
    And the command output contains "--vault-external-addr https://vault.example.org"

  # Both builders silently DROPPED an external address without an internal one
  # (a #335 review major); the config now refuses before emission, on stderr,
  # with nothing on the argv channel.
  @interface:cli @issue:generator-335
  Scenario: an external address without an internal one is refused before anything is emitted @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test",
       "vault_external_addr": "https://vault.example.org"}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command exit code was 2
    And the command stdout is empty
    And the command output contains "external address set but no Vault address"

  # The CA surface is RECORDED, NOT YET CONSUMED (labelled so on both faces):
  # a full certificate list and a per-domain choice change the argv by nothing.
  # A PEM path that reached the argv would be a flag no builder parses.
  @interface:cli @issue:generator-335
  Scenario: the base-CA list and the per-domain base-CA choice emit nothing on the argv @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"}],
       "domain_services_reviewed": ["acme.example"],
       "base_ca_certs": ["/etc/pki/tls/certs/fixture-base-ca.pem"],
       "domain_ca": {"acme.example": "/etc/pki/tls/certs/fixture-base-ca.pem"}}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output does not contain "fixture-base-ca"
    And the command output does not contain "--domain-ca"
    And the command output does not contain "--base-ca"

  @interface:studio @issue:generator-335
  Scenario: the Secrets-store page shows the internal/external split and the base-CA surface @interface:studio
    When I grab the Studio wizard page "vault"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "vault"
    And the Studio page says "Internal address"
    And the Studio page says "External address"
    And the Studio page says "Base CA certificates"

  @interface:studio @issue:generator-335
  Scenario: the Domains table carries the per-domain Base CA column @interface:studio
    When I grab the Studio wizard page "domains"
    Then the Studio grab shows the wizard page "domains"
    And the Studio page says "Base CA"

  # ── #384: "anubis off" needs the -anubis token, and a control that can say it ─
  # The CLI arm already can: an explicit "-anubis" in optional_services rides
  # the --optional-services channel untouched (the builders parse the -<slug>
  # deselect there and REFUSE --exclude-services anubis by name).
  @interface:cli @issue:generator-384
  Scenario: the explicit -anubis deselect token rides the optional-services channel untouched @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test",
       "optional_services": ["tuwunel", "-anubis"]}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--optional-services"
    And the command output contains "-anubis"
    And the command output does not contain "--exclude-services anubis"

  # The GUI arm cannot: the anubis row on the Services table is a two-state
  # tick (network.py _service_channel), so a prod image built from the GUI
  # always ships anubis. #384's fix is a tri-state on that row — ENV default /
  # force on / force off. The driver reports each row's box with isTristate().
  @interface:studio @issue:generator-384 @fixme
  Scenario: the Services table's anubis row offers ENV default / force on / force off @interface:studio
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test"}
      """
    When I grab the Studio wizard page "network" with that config fixture
    Then the Studio grab shows the wizard page "network"
    And the Studio services row "anubis" offers a tri-state control

  # ── #521: bundle_source needs an UNSET representation ─────────────────────
  # Controls first: an explicit choice is emitted either way, on any image.
  @interface:cli @issue:generator-521
  Scenario: an explicit bundle_source=true is emitted on a desktop image @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "standalone", "role": "standalone-thick", "platform": "x86",
       "bundle_source": true}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--bundle-source"
    And the command output does not contain "--no-bundle-source"

  @interface:cli @issue:generator-521
  Scenario: an explicit bundle_source=false is emitted as --no-bundle-source on a node build @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "bundle_source": false}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--no-bundle-source"

  # The defect: with NOBODY having said anything, a node build still gets
  # --bundle-source (the 33 MB generator tree baked into an out-of-scope image).
  # Measured on origin/main 9f4d6d30: `--bundle-source` at argv position 60 for
  # this exact fixture. Correct behaviour: neither token is emitted.
  @interface:cli @issue:generator-521 @fixme
  Scenario: an UNSET bundle_source emits neither token on an out-of-scope node build @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "backend", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test"}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output does not contain "--bundle-source"
    And the command output does not contain "--no-bundle-source"

  # ── #482: publish target, build target and domain type per domain ─────────
  # Key names below are THIS scenario's proposal (the issue names the three
  # choices, not their keys); rename them here when the schema lands. The
  # contract that matters is omit-when-default + round-trip: a default domain
  # keeps its bytes, a non-default choice survives load -> materialise.
  @interface:cli @issue:generator-482
  Scenario: a domain left at the defaults keeps its manifest keys as they are today (omit-when-default) @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "laptop", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme"}],
       "domain_services_reviewed": ["acme.example"]}
      """
    When I run the Studio CLI print-specs on that config fixture
    Then the command succeeded
    And the command output is valid JSON
    And the command output contains "\"name\": \"acme.example\""
    And the command output does not contain "publish_target"
    And the command output does not contain "build_target"
    And the command output does not contain "domain_type"

  @interface:cli @issue:generator-482 @fixme
  Scenario: a domain's publish target, build target and domain type survive the load/materialise round trip @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "laptop", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme",
                    "publish_target": "mesh-forge",
                    "build_target": "in-cluster",
                    "domain_type": "shell-host"}],
       "domain_services_reviewed": ["acme.example"]}
      """
    When I run the Studio CLI print-specs on that config fixture
    Then the command succeeded
    And the command output contains "\"publish_target\": \"mesh-forge\""
    And the command output contains "\"build_target\": \"in-cluster\""
    And the command output contains "\"domain_type\": \"shell-host\""

  @interface:studio @issue:generator-482
  Scenario: the Domains table still renders its current columns, where the per-row config will hang @interface:studio
    When I grab the Studio wizard page "domains"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "domains"
    And the Studio page says "Domain"
    And the Studio page says "Title"
    And the Studio page says "Optional services"
    And the Studio page says "Applies to"
    And the Studio page says "Sign-in"

  # ── #266: per-domain external IdPs ─────────────────────────────────────────
  # Today's axis is 2-valued and ENFORCED: an unknown per-domain idp value is
  # refused by name. That is the control; the widening below is decision A's
  # box 2 (Domain gains idp_provider / idp_issuer / idp_client_id / idp_jwks,
  # omit-when-default), which waits for a consumer.
  @interface:cli @issue:generator-266
  Scenario: an unknown per-domain sign-in value is refused naming the legal set @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "laptop", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme", "idp": "own-external"}]}
      """
    When I run the Studio CLI print-specs on that config fixture
    Then the command exit code was 2
    And the command stdout is empty
    And the command output contains "idp must be one of superdomain|own"

  @interface:cli @issue:generator-266 @fixme
  Scenario: a domain configured with an external provider carries issuer, client id and jwks into its spec @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "laptop", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test", "additional_domains": true,
       "domains": [{"name": "acme.example", "title": "Acme", "idp": "own",
                    "idp_provider": "oidc",
                    "idp_issuer": "https://idp.example.org",
                    "idp_client_id": "hugmesh-web",
                    "idp_jwks": "https://idp.example.org/.well-known/jwks.json"}],
       "domain_services_reviewed": ["acme.example"]}
      """
    When I run the Studio CLI print-specs on that config fixture
    Then the command succeeded
    And the command output contains "\"idp_provider\": \"oidc\""
    And the command output contains "\"idp_issuer\": \"https://idp.example.org\""
    And the command output contains "\"idp_client_id\": \"hugmesh-web\""
    And the command output contains "\"idp_jwks\": \"https://idp.example.org/.well-known/jwks.json\""
