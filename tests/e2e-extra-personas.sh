# shellcheck shell=sh
# e2e-extra-personas.sh — the ONE definition of the e2e personas that are not in
# seed-accounts.sh's default SYSTEMS_ROLE_USERS catalogue.
#
# WHY THIS FILE EXISTS. Two lanes seeded Casdoor from two different lists:
#
#   compose  tests/stack/seed-e2e.sh   BASE_SPECS + its own inlined EXTRA_SPECS
#   kind     bootstrap-kind.sh         seed-accounts.sh --roles, no override at all
#
# so the kind cluster never got `e2e-fleet`, `e2e-superadmin`, `e2e-banned` or the
# ad-hoc UI personas. Live symptom, 2026-08-06, spec 29 against a fully working
# cluster:
#
#     native login e2e-fleet -> 401 — the persona must be seeded
#
# which reads like a broken login and is really a persona that was never created.
# Exactly the same shape as the Cassandra role that did not exist reading as a
# rotated password. The compose lane was right and the cluster lane was behind —
# the recurring theme of docs/KIND-SSO-E2E-FINDINGS.md.
#
# Sourced by BOTH lanes. Adding a persona here reaches compose and kind together,
# which is the entire point; tests/scripts/test-e2e-persona-catalogue.sh fails the
# build if either lane stops consuming it.
#
# Format is seed-accounts.sh's: "username:ROLE_A,ROLE_B:passwordEnv", space
# separated. A passwordEnv that is unset falls back to the shared E2E_PASSWORD,
# which is GENERATED per run (tests/stack/e2e-password.sh) rather than a fixed
# literal — see that file's header for the resolution chain.

# ROLE_SUPERADMIN persona. Defaults to e2e-superadmin so ordinary e2e runs (and
# every UI spec that logs in as e2e-superadmin) are unchanged. The from-scratch
# local-mesh bootstrapper bridges the minted CASDOOR_SUPERADMIN_USERNAME in via env
# so the seeded login matches the username it advertised to the operator. Expected
# to be a simple slug (no '@'/spaces) so the Casdoor legal name equals the login.
SUPERADMIN_PERSONA="${CASDOOR_SUPERADMIN_USERNAME:-e2e-superadmin}"

# e2e-fleet: a PURE fleet owner (ROLE_FLEET_ADMIN + ROLE_USER, deliberately NO
# ROLE_ADMIN) — the one principal among the 9 seeded mfa_required rows that
# decide() can MFA-gate at the compose default (enabled=true, floor off). See
# docs/MFA-ROLLOUT.md §3.1: SUPERADMIN/ADMIN/GAME-MASTER short-circuit BEFORE
# decide() until the privileged floor is on, a pure fleet owner does not — so
# granting this persona ROLE_ADMIN would silently turn the gateway MFA leg of
# tests/e2e/specs/29-mfa-privileged-floor.spec.ts into a vacuous pass. That spec
# asserts the absence of ROLE_ADMIN before it asserts the 403.
#
# e2e-banned / the @gmail.com personas / dragoneer: the ad-hoc UI-suite handles.
# Against a real Casdoor /bff/login validates an existing account only, so each
# must be pre-seeded as a bare ROLE_USER or the login 401s at setup and the
# denial/role assertions never run.
#
# e2e-suspended: the ONE persona a scenario may CURTAIL at run time. A
# "curtailed" account (the state /bff/me/appeal, the host shell's
# session.curtailed() and the gateway revocation fast-path all read) is an
# admin-bff access_suspension row for the PROFILE role, written by a moderator
# banning the account on the `profile` platform — NOT a Casdoor role, so this
# grammar cannot express it and no seeder sets it. The Gherkin step
# 'an admin suspends the persona for this scenario' (tests/e2e/steps/common.steps.ts)
# writes it through the real mod surface, lifts it in After, and REFUSES any
# handle but this one: suspending e2e-user would poison every concurrent
# scenario that signs in as e2e-user. Seeded as a plain ROLE_USER so that,
# between scenarios, it is an ordinary fully-registered member. Deliberately
# NOT e2e-banned: that handle's "ban" is the ABSENCE of platform roles and spec
# 28 A5 pins it as bare ROLE_USER with status active; giving it a real
# suspension would launder away the state spec 28 measures.
E2E_EXTRA_PERSONAS="\
${SUPERADMIN_PERSONA}:ROLE_SUPERADMIN:E2E_SUPERADMIN_PASSWORD \
e2e-banned:ROLE_USER:E2E_BANNED_PASSWORD \
e2e-suspended:ROLE_USER:E2E_SUSPENDED_PASSWORD \
e2e-fleet:ROLE_FLEET_ADMIN,ROLE_USER:E2E_FLEET_PASSWORD \
admin@hugmesh.net:ROLE_ADMIN,ROLE_USER:E2E_PASSWORD \
alice@gmail.com:ROLE_USER:E2E_PASSWORD \
bob@gmail.com:ROLE_USER:E2E_PASSWORD \
carol@gmail.com:ROLE_USER:E2E_PASSWORD \
dave@gmail.com:ROLE_USER:E2E_PASSWORD \
eve@gmail.com:ROLE_USER:E2E_PASSWORD \
frank@gmail.com:ROLE_USER:E2E_PASSWORD \
dragoneer:ROLE_USER:E2E_PASSWORD \
rbac-plain@gmail.com:ROLE_USER:E2E_PASSWORD \
rbac-login-user@gmail.com:ROLE_USER:E2E_PASSWORD \
rbac-pending@gmail.com:ROLE_USER:E2E_PASSWORD \
rbac-approved@gmail.com:ROLE_USER:E2E_PASSWORD \
"
