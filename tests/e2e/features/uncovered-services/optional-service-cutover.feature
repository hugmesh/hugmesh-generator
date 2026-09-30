# The optional-service SELECTION and the two build-time writers that never
# reached the cluster — hugmesh/hugmesh-generator#496 and #508.
#
# WHAT #496 MEASURED (2026-09-17): an image built `--optional-services tuwunel`
# boots with all 15 optional services. The build renders the selection into three
# files (apps/13a-optional-services.yaml, manifests/policy/
# installed-services-configmap.yaml, manifests/optional-services-operator/
# seed-optionalservices.yaml) and NOTHING downstream consumes them: the hardcoded
# per-service Applications (apps/30-akkoma.yaml, apps/50-games.yaml, …) still sit
# in apps/ with automated sync, so the ApplicationSet's selector gates a set that
# is empty either way. Its "Done when" is a CLUSTER-STATE fact ("a selection made
# at build time determines which optional-service Applications exist"), which is
# the @env:kind scenario below. It is @fixme: today it fails, honestly.
#
# WHAT #508 MEASURED: specs/cluster/apps/05b-casdoor-domains.yaml is a real
# ApplicationSet whose element list ships `elements: []`, and the build-time
# writer docs/DOMAIN-IDP.md names — `_domains_render_appset_elements()` — exists
# only in that doc line. Its "Done when" has two halves: a build with an own-IdP
# domain emits a non-empty list (needs the writer, @fixme), and a build with none
# still emits `elements: []` byte-identically (true today, pinned here, and MUST
# stay true after the writer lands — that is the half that keeps this file
# generating while the other is pending).
#
# Running a stage4 build inside a scenario is out of the question (an image build
# on a shared host), so the offline halves read the COMMITTED artefacts — the same
# deploy-oracle stance the route-access features take with 20-schema.sql — and the
# live half reads the kind cluster through kubectl, gated by @env:kind.
@service:gateway @layer:gateway
Feature: An optional-service build selection reaches the cluster, and the casdoor-domain element list is baked

  # ── #496 — the three cardinalities this repo owns, compared as SETS ────────
  # #496 counts five sizes for one supposedly 1:1 slug set (17/14/13/13/12 on
  # 2026-09-17). Three of the five live here; comparing them by SET rather than
  # by count is what catches a renamed slug. Measured green on 2026-09-23 —
  # the 13a elements, the CRD enum and the seed CRs already name the same 14 —
  # so these two are the pins that keep them reconciled, not the fix.
  @issue:generator-496 @harness @interface:cli
  Scenario: the 13a ApplicationSet elements, the OptionalService CRD enum and the seed CRs name the same slug set
    Then the optional-service slug sets agree across the 13a ApplicationSet, the CRD enum and the seed CRs

  @issue:generator-496 @harness @interface:cli
  Scenario: every 13a element has an installed-services ConfigMap boolean the renderer can flip
    Then every 13a optional-service element has an installed-services ConfigMap boolean

  # The renderers' shared implementation. #496's arch-asymmetry finding ("only
  # rpi5 has _opt_render_appset_flag") predates the extraction that
  # scripts/_optional-services-lib.sh records in its own header; today BOTH stage4
  # builders source that one library, and this pair keeps it that way — a builder
  # that stops sourcing it is the x86 regression that header describes.
  @issue:generator-496 @harness @interface:cli
  Scenario Outline: the <builder> stage4 builder renders its optional-service selection through the shared library
    When I run the shell command "grep -c '_optional-services-lib.sh' <builder>"
    Then the command succeeded

    Examples:
      | builder                  |
      | build-rpi5-stage4.sh     |
      | build-x86-host-stage4.sh |

  # ── #496 "Done when" — the selection reaches the CLUSTER ───────────────────
  # The installed-services ConfigMap is the one artefact of the selection that
  # reaches the cluster today (write-only, per #496). The contract: a slug it marks
  # "false" has NO ArgoCD Application — matched by source PATH as well as by name,
  # because the un-cut-over hardcoded Applications differ from the ApplicationSet's
  # in NAME (`akkoma` vs `optional-akkoma`) and agree in the manifests they sync.
  # @fixme: the §10 cut-over has not happened; today every hardcoded Application
  # exists whatever the ConfigMap says. Drop @fixme when #496 lands.
  @issue:generator-496 @fixme @env:kind @interface:cli @role:e2e-superadmin
  Scenario: a service deselected at build time has no ArgoCD Application on the kind cluster
    Then every optional service the installed-services ConfigMap marks false has no ArgoCD Application on the cluster

  # ── #508 — the casdoor-domain ApplicationSet element writer ────────────────
  # The half that is true today and must stay true: a build with no own-IdP
  # domain ships the scaffold `elements: []`, byte-identically (the SCAFFOLD RULE
  # at the top of 05b, guarded by tests/scripts/test-casdoor-domains-appset.sh).
  @issue:generator-508 @harness @interface:cli
  Scenario: with no own-IdP domain the casdoor-domains ApplicationSet ships an empty element list
    When I run the shell command "grep -c '^        elements: \[\]$' specs/cluster/apps/05b-casdoor-domains.yaml"
    Then the command succeeded
    And the command output contains "1"

  # The half that needs the writer: docs/DOMAIN-IDP.md names
  # `_domains_render_appset_elements()` as the stage4 bake and nothing under
  # scripts/ or the root builders defines it (measured 2026-09-23: zero hits
  # outside the doc). A KEYS manifest with one idp:own domain cannot render a
  # non-empty list until it exists. @fixme until #508 lands the writer; the
  # assertion is on the tree the builders execute, not on the doc.
  @issue:generator-508 @fixme @harness @interface:cli
  Scenario: the stage4 domain step carries the build-time ApplicationSet element writer
    When I run the shell command "grep -l '_domains_render_appset_elements' scripts/*.sh build-rpi5-stage4.sh build-x86-host-stage4.sh"
    Then the command succeeded
    And the command output does not contain "docs/"
