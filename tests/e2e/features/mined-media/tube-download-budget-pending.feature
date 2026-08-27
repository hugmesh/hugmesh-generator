# PAUSE-ON-FULL IS ENFORCED AT BOTH GATES — AND NEITHER CAN BE DRIVEN HERE.
#
# hugmesh-tube-bff-api DownloadJobService enforces the storage budget TWICE, and
# the second one is the leg that matters:
#
#   enqueue time  enqueueFromSubscriptions resolves isFull ONCE per run and, when
#                 full, records each job via enqueueSkipped — born failed, never
#                 queued.
#   claim time    claim() re-checks isFull PER JOB and re-marks a just-claimed job
#                 failed with the sentinel "storage budget full (skipped)", then
#                 DROPS it from the worker's batch. This is what stops work that
#                 was queued BEFORE the cap dropped from ever downloading.
#
# tube-ui's own budget-raise-unblocks.feature covers only the ENQUEUE leg. The
# claim-time re-check is covered nowhere.
#
# WHY IT IS PENDING RATHER THAN WRITTEN. It needs TWO identities the roster does
# not have, and they are different kinds of missing:
#
#   ROLE_TUBE         gates /bff/tube/subscriptions/** and /bff/tube/downloads.
#                     access-role-roster.feature already pins that nothing seeds
#                     it.
#   ROLE_TUBE_WORKER  gates /bff/tube/internal/**. This one is not merely
#                     unseeded — it is deliberately OUTSIDE the human role
#                     hierarchy: "no USER/MOD/ADMIN/SUPERADMIN reaches it (a human
#                     must never claim/complete another user's download job)". So
#                     no human persona can ever be given it, and driving the claim
#                     leg needs a SERVICE principal the e2e seeder does not mint.
#
# Writing this against an admin would not be a weaker version of the test; it
# would be a test of a 403 wall, dressed as coverage of a budget gate.
#
# THE ONE FACT THAT IS ASSERTED WITHOUT A MESH sits in upload-serve-posture.feature
# and character-palette-fleet.feature — this file asserts nothing and says so.
#
# *** HARNESS TRAP, MEASURED HERE ON 2026-08-26 — DO NOT REPEAT IT ***
# This file carries NO @fixme tag, deliberately. playwright-bdd emits NOTHING at
# all for a .feature in which EVERY scenario is @fixme: `npx bddgen` still exits
# 0, .features-gen gains no spec for the file, and its scenarios never appear in
# --list. A silent zero that looks exactly like coverage. Measured three ways:
# @fixme on the Feature line -> 0 specs; @fixme on all N scenarios -> 0 specs;
# @fixme on 1 of 3 scenarios -> 1 test.fixme + 2 test(), file generated. That is
# why features/uncovered-services/console-discovery.feature (6 pending rows + 1
# real one) works and a file of pure pending rows does not.
# The PENDING idiom that DOES work everywhere is the step, not the tag:
#   Given this scenario is PENDING because "<reason>"
# which calls $testInfo.skip() and PRINTS the reason — strictly more evidence
# than the tag ever gave. Use the step; add @fixme only when the file also holds
# at least one scenario that really runs.
# The tag also skips a test BEFORE its first step runs, so the PENDING step never
# executes and the skip lands in report.json with an EMPTY reason — a silent skip
# wearing a tag. Measured in this lane's own run5 report.
#
@service:tube @layer:bff
Feature: The tube download budget gates, pending identities that can drive them

  Scenario: PENDING (nothing seeds ROLE_TUBE or ROLE_TUBE_WORKER) — a job queued while under budget is skipped at claim time once the cap drops @role:e2e-admin @service:tube @layer:bff
    Given this scenario is PENDING because "the enqueue leg needs ROLE_TUBE (unseeded — see access-role-roster.feature) and the claim leg needs ROLE_TUBE_WORKER, which is deliberately outside the human role hierarchy so that no USER/MOD/ADMIN/SUPERADMIN can ever hold it: the e2e seeder mints no service principal. DESIRED, once both exist: enqueue while under budget, have an admin POST /bff/tube/admin/storage-budget to 0 bytes, then have the worker POST /bff/tube/internal/download-jobs/claim and assert the batch does NOT contain the job and the job is now failed with the exact sentinel 'storage budget full (skipped)'. Assert the sentinel, not just the status: the enqueue-time and claim-time legs both end at 'failed', and only the reason string distinguishes which gate fired."
    Then the persona named by the role dimension is seeded

  Scenario: PENDING (nothing seeds ROLE_TUBE) — a negative budget clamps to zero rather than wrapping into unlimited @role:e2e-admin @service:tube @layer:bff
    Given this scenario is PENDING because "StorageUsageService.setBudget clamps a negative budget to 0 (`long budget = budgetBytes < 0 ? 0 : budgetBytes`), which immediately makes the user full and pauses all further downloads — the opposite of the unsigned-wrap-into-unlimited a missing clamp would produce. POST /bff/tube/admin/storage-budget is an ADMIN route, so the WRITE half is drivable today; the READ-BACK half (GET the user's usage row and assert budget 0 and full=true) goes through a ROLE_TUBE surface that nothing seeds, so the scenario would be able to set the budget and unable to see what it set."
    Then the persona named by the role dimension is seeded
