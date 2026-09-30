# ISSUE hugmesh-generator#509 — "Image CLI: --domain-idp on the ten stage4 builders".
# Three of the four domain-creation surfaces (Qt GUI, TUI, Studio CLI) can say
# "this domain hosts its OWN Casdoor" (config.py DOMAIN_IDP_CHOICES = superdomain
# | own). The IMAGE CLI cannot: `--domains` is a bare name list and no builder has
# a `--domain-idp`-shaped flag. Measured on origin/main@9f4d6d30 (2026-09-23):
#     grep -l -- '--domain-idp' build-*-stage4.sh   -> nothing, 0 of 10
#     ./build-rpi5-stage4.sh --print-plan --domain-idp brand-a=own
#         -> rc=1  ERROR: Unknown option: --domain-idp
# so every scenario below that names the flag is @fixme, and each asserts the
# behaviour the issue's "Done when" asks for — accepted on ALL ten, repeatable,
# `own|superdomain` validated — never today's "Unknown option".
#
# WHAT IS ASSERTED AND WHAT IS NOT. `--print-plan` is the unprivileged resolver
# every builder exposes (it exits before the root gate and writes nothing, and
# PLAN_BUILDER names the script), so "the flag is accepted and its value reaches
# the resolved plan" is checkable in seconds with no image build. The other half
# of the done-when — "threads into the same KEYS-manifest field
# core/worklist_driver.py writes, omitting the default so pre-#47 manifest bytes
# are unchanged" — is a property of the emitted manifest on a multi-hour build,
# not of --print-plan, and is NOT claimed here. The literal this file pins for the
# plan is the flag's own spelling, `brand-a=own`; a fixer who renders the plan
# line differently updates exactly that one literal.
#
# GENERATIVE over the builders: one row per stage4 script, so a builder that is
# missed goes red by name rather than "9 of 10" reading as done.
@interface:cli @issue:generator-509
Feature: --domain-idp is a real, validated flag on every stage4 builder

  # Baseline, green today: every builder has an unprivileged resolver, so the
  # flag has somewhere to land and something to be asserted against.
  Scenario Outline: <builder> resolves a build plan unprivileged and names itself
    When I run the shell command "./<builder> --print-plan"
    Then the command succeeded
    And the command output contains "PLAN_BUILDER=<builder>"
    And the command output does not contain "Run as root"

    Examples:
      | builder                          |
      | build-frite-stage4.sh            |
      | build-jetson-stage4.sh           |
      | build-orangepi-zero2-stage4.sh   |
      | build-orangepi-zero2w-stage4.sh  |
      | build-orangepi-zero3-stage4.sh   |
      | build-orangepi3-lts-stage4.sh    |
      | build-orangepi4-lts-stage4.sh    |
      | build-orangepi5-stage4.sh        |
      | build-rpi5-stage4.sh             |
      | build-x86-host-stage4.sh         |

  # The x86 builder is the only one with a `--domains` tie today, and only a
  # client role honours it, so its row names a domain and a client role; the
  # other nine take the flag on their default role.
  @fixme
  Scenario Outline: <builder> accepts a repeatable --domain-idp and the own choice reaches the resolved plan
    When I run the shell command "./<builder> <extra> --domain-idp brand-a=own --domain-idp brand-b=superdomain --print-plan"
    Then the command succeeded
    And the command output does not contain "Unknown option"
    And the command output contains "brand-a=own"

    Examples:
      | builder                          | extra                              |
      | build-frite-stage4.sh            |                                    |
      | build-jetson-stage4.sh           |                                    |
      | build-orangepi-zero2-stage4.sh   |                                    |
      | build-orangepi-zero2w-stage4.sh  |                                    |
      | build-orangepi-zero3-stage4.sh   |                                    |
      | build-orangepi3-lts-stage4.sh    |                                    |
      | build-orangepi4-lts-stage4.sh    |                                    |
      | build-orangepi5-stage4.sh        |                                    |
      | build-rpi5-stage4.sh             |                                    |
      | build-x86-host-stage4.sh         | --role desktop --domains brand-a,brand-b |

  # Validation at the boundary, like every other flag: a value outside
  # own|superdomain is refused NAMING the legal set. Today the refusal is
  # "Unknown option", which names nothing.
  @fixme
  Scenario Outline: <builder> refuses an idp choice outside own|superdomain and names the legal set
    When I run the shell command "./<builder> <extra> --domain-idp brand-a=ldap --print-plan"
    Then the command exited with a non-zero code
    And the command output does not contain "Unknown option"
    And the command output contains "superdomain"

    Examples:
      | builder                          | extra                              |
      | build-frite-stage4.sh            |                                    |
      | build-jetson-stage4.sh           |                                    |
      | build-orangepi-zero2-stage4.sh   |                                    |
      | build-orangepi-zero2w-stage4.sh  |                                    |
      | build-orangepi-zero3-stage4.sh   |                                    |
      | build-orangepi3-lts-stage4.sh    |                                    |
      | build-orangepi4-lts-stage4.sh    |                                    |
      | build-orangepi5-stage4.sh        |                                    |
      | build-rpi5-stage4.sh             |                                    |
      | build-x86-host-stage4.sh         | --role desktop --domains brand-a   |
