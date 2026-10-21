# PATH GAP: POST /bff/register/google and POST /bff/register/discord —
# hugmesh-user-bff-api#19 (handlers landed in that repo's PR #20 @ dc34c8b,
# merged 2026-09-18 as b90cd8f; the issue stays OPEN on two admin-bff blockers).
# The compose route table sends both to user-bff (tests/stack/gateway-routes/
# fe/application-routes.yml:341), and no browser flow reaches them: the
# Google/Discord social-login UI was removed from login-ui, and the only
# production caller is tests/qemu/seed-accounts.sh, which curls the
# node-local BFF directly. So the interface that exists for these paths IS a
# terminal, and the transcript is the evidence.
#
# THE ROLE MATRIX, and why "unauthenticated/new-account" is a 401, not a 403:
# the gateway's route-access seed carries
#   ('hugmesh-fe-gateway', '/bff/register/**', 'ROLE_USER', true)
# (specs/cluster/manifests/route-access/initdb/20-schema.sql:627), so an
# anonymous POST is refused AT THE DOOR before any BFF sees it — measured
# 2026-09-23 on the live compose stack: 401 for both paths and for a probe
# path. user-bff's own permitAll on the two exact paths is therefore only
# reachable by a signed-in caller (or, on a device, by the node-local curl
# seed-accounts.sh does). Holding ROLE_USER, the same POST reaches the
# handler, whose invite gate answers 403 for a handle no admin invited —
# never the 404 the docs (docs/LOCAL-STACK.md:452-453) still record as the
# accepted regression, and never a session.
#
# Nothing here creates an account: every handle posted is one no admin
# invited, and the invite gate runs BEFORE ensureAccount. The signed-in
# scenarios read the persona's password from the run-state credentials FILE
# inside the script (a read, never tests/stack/e2e-password.sh) and the
# secrecy step proves the transcript never carries it.
@interface:cli @env:docker @service:gateway @layer:bff
Feature: the invite-gated register paths, driven from a terminal through the front door

  @issue:user-bff-api-19
  Scenario Outline: an anonymous new-account caller cannot reach <path> through the front door
    When I run the shell script:
      """
      set -uo pipefail
      printf 'anon %s -> %s\n' "<path>" "$(curl -sk -o /dev/null -m 20 -w '%{http_code}' -X POST "$HUGMESH_BDD_BASE_URL<path>" -H 'content-type: application/json' -d '<body>')"
      """
    Then the command succeeded
    And the command output contains "anon <path> -> 401"

    Examples:
      | path                   | body                                          |
      | /bff/register/google   | {"email":"bdd-not-invited@example.invalid"}   |
      | /bff/register/discord  | {"username":"bdd-not-invited"}                |
      | /bff/register/_probe   | {}                                            |

  @issue:user-bff-api-19
  Scenario Outline: signed in as <role>, an un-invited handle posted to <path> is refused by the invite gate, never 404 @role:<role>
    When I run the shell script:
      """
      set -uo pipefail
      jar="$HUGMESH_BDD_SCRATCH/cookies.txt"
      pw="$(grep '^E2E_PASSWORD=' "$HUGMESH_BDD_CREDENTIALS_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
      [ -n "$pw" ] || { echo "no E2E_PASSWORD in $HUGMESH_BDD_CREDENTIALS_FILE — run make stack-seed first (never run e2e-password.sh directly)"; exit 3; }
      body="$(U="$HUGMESH_BDD_PERSONA" P="$pw" python3 -c 'import json,os; print(json.dumps({"username": os.environ["U"], "password": os.environ["P"]}))')"
      login="$(printf '%s' "$body" | curl -sk -o /dev/null -m 20 -w '%{http_code}' -c "$jar" -X POST "$HUGMESH_BDD_BASE_URL/bff/login" -H 'content-type: application/json' --data-binary @-)"
      echo "login $HUGMESH_BDD_PERSONA -> $login"
      code="$(curl -sk -o "$HUGMESH_BDD_SCRATCH/body.txt" -m 20 -w '%{http_code}' -b "$jar" -X POST "$HUGMESH_BDD_BASE_URL<path>" -H 'content-type: application/json' -d '<body>')"
      printf 'signed-in %s -> %s\n' "<path>" "$code"
      if grep -a 'not invited' "$HUGMESH_BDD_SCRATCH/body.txt" >/dev/null; then echo "reason: not invited"; else echo "reason: other"; fi
      """
    Then the command succeeded
    And the command output contains "login <role> -> 200"
    And the command output contains "signed-in <path> -> 403"
    And the command output contains "reason: not invited"
    And the command output does not contain the shared e2e persona password

    Examples:
      | role     | path                   | body                                          |
      | e2e-user | /bff/register/google   | {"email":"bdd-not-invited@example.invalid"}   |
      | e2e-user | /bff/register/discord  | {"username":"bdd-not-invited"}                |
