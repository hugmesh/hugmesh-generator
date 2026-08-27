# The CSP NONCE CHAIN in the two committed Angular archetypes.
#
# THE FAILURE THIS GUARDS. The hugmesh-gateway fallback CSP (SecurityConfig) is
# `script-src 'self'; style-src 'self'` with no nonce and no blob:. That is a
# correct policy for an API and a fatal one for an Angular SPA: the styles and the
# native-federation bootstrap are both blocked, the app never mounts, and the
# response is STILL 200. A blank page is not a 404; no status assertion will ever
# see it, and a selector wait times out somewhere unrelated.
#
# THE CHAIN IS THREE PARTS and any two of them is strictly worse than none:
#   map $request_id $cspnonce   defines the per-request value
#   sub_filter … sub_filter_once off   puts it on EVERY script tag
#   add_header Content-Security-Policy … 'nonce-$cspnonce'   demands it
# A config carrying the header and no sub_filter serves a policy demanding a nonce
# that no script tag has — every bootstrap script blocked, blank at 200. The same
# happens if index.html is ever served precompressed, because sub_filter cannot
# rewrite a compressed body.
#
# SCOPE, STATED RATHER THAN IMPLIED. Exactly TWO Angular nginx configs are
# committed to THIS repo — the angular-host and angular-mfe archetype skeletons
# every generated UI starts from. The ~20 per-UI nginx.conf files live in their
# own repos and are deliberately not read from here: a step reaching into a
# sibling checkout passes on a developer box and fails in CI. The archetypes are
# the higher-leverage half in any case, because they are the multiplier.
#
# RUNS OFFLINE. Comments are stripped before every assertion, so a directive named
# only in a comment can never satisfy a check that it is configured.
@harness @layer:ui @service:gateway
Feature: The committed Angular archetypes ship a complete CSP nonce chain

  Scenario: the angular-host archetype wires all three parts of the nonce chain @layer:ui @service:gateway
    Then the "angular-host" nginx archetype emits its own Content-Security-Policy header
    And the "angular-host" nginx archetype defines the nonce source from $request_id
    And the "angular-host" nginx archetype injects the nonce into every script tag
    And the "angular-host" nginx archetype does not serve html precompressed

  Scenario Outline: the angular-host CSP allows <token> in <directive> @layer:ui @service:gateway
    Then the "angular-host" nginx archetype Content-Security-Policy allows "<token>" in "<directive>"

    Examples:
      | directive  | token           |
      | script-src | 'nonce-$cspnonce' |
      | script-src | blob:           |
      | worker-src | blob:           |
      | style-src  | 'unsafe-inline' |

  # A nonce plus 'unsafe-inline' in script-src is weaker than no CSP at all:
  # browsers that honour the nonce IGNORE 'unsafe-inline', and browsers that do
  # not, honour it.
  Scenario: the angular-host CSP does not weaken its own nonce @layer:ui @service:gateway
    Then the "angular-host" nginx archetype Content-Security-Policy carries no "'unsafe-inline'" in "script-src"

  # THE TRIPWIRE. angular-mfe records the omission as a deliberate deferral while
  # its angular-host sibling ships the full chain, so every MFE generated from it
  # starts out inheriting the gateway fallback. Closing that gap fails this
  # scenario, whose message names the follow-up.
  Scenario: the angular-mfe archetype still defers its own CSP @layer:ui @service:gateway
    Then the "angular-mfe" nginx archetype still emits no Content-Security-Policy of its own
