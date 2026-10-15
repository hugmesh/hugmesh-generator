# #528 — kind halt/resume round trip (live `hugmesh-local`), run 2026-09-30

**Status: PARTIAL. resume leg run and OK; halt leg NOT run (blocked by the session's permission gate).**

- The cluster was ALREADY halted when this run started (halt record `2026-09-30T13:37:35Z`, made by an
  earlier session, 0 of 25 Applications auto-synced, 26 pods). So step 1 of the plan
  ("is NOT halted by this control") could not be observed; `00-preexisting-halted.txt` is the read-only
  status of the halted state instead (the record names all 25 suspended Applications and flags
  `external-secrets-config  health=Degraded  <-- NOT healthy/synced when frozen` — item 4 satisfied).
- `make kind-resume` (01): restored 27 workloads, re-armed 25 Applications, verified, cleared the record; command
  wall time 4 s. Pods 26 -> 69. 25/25 Applications carry syncPolicy.automated again (issue predicted 24; the
  cluster now has 25 — `metrics-server`/`workload-console-rbac` etc. moved it, not a defect).
- Settle time to every pod fully Ready (x/x, excluding Completed): ~116 s from the resume call (04). The only
  non-Healthy Application afterwards is `external-secrets-config` = Degraded (standing red #352).
- **Vault (item 3, the sharpest unknown): PASSED.** `vault status` right after resume (03): `Sealed false`,
  `Initialized true`, HA active, raft index 187 — auto-unseal fired on the way back.
- Replica counts restored are the HPA-chosen ones (admin-bff-api came back at 6), as the halt text warns.
- Item 1 (nothing scaled in kube-system/kyverno/local-path-storage/devops): the halt was made by another session,
  so this run has no scale plan to compare; 00 shows kyverno/local-path on the floor list. Not asserted beyond that.
- **NOT RUN: `make kind-halt` and the second resume.** The auto-mode gate refused `make kind-halt` as
  "Modify Shared Resources" (it stops the operator's live cluster). Left for the operator to run and say so.
- **NOT RUN: item 5, the GUI buttons (Halt/Resume DevOps lane, Delete-lane confirmation).**
- Side effect to know about: this cluster is now RUNNING again (it was halted when I arrived).
