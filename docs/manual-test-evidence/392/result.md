# #392 — plan-body corrections: verification against the live bodies (2026-09-30)

Not a runnable test. Each numbered claim re-checked by fetching the bodies (`gh issue view --json body`). NO issue body was edited.

1. #311 coverage sentence — STALE/ALREADY FIXED: the phrase "Every UI step names the file the capture harness writes" no longer occurs in #311; the "harness produces six of these: 04, 05, 06, 09, 10, 20 … Take every other shot yourself" sentence remains (L68).
2. #310 dropped drift value — ALREADY RESTORED: a `DRIFT` clause is present in #310 (1 match).
3. Stale 2026-09-06 STOPs — STILL PRESENT: #310 P0 "STOP. Do not run this plan yet" (L78) and #292 P1 "Execution blocker … Stack gone 2026-09-06" (L61) are still in the bodies. The stack WAS brought up and seeded on 2026-09-30 (docs/manual-test-evidence/README.md), so the premise of the STOP is now false; lifting/re-dating is left to the issue owner (decision).
4. Sizes — CHANGED: #303 is now 65,521 bytes, 15 bytes under the 65,536 cap (was 64,862). #313 63,788; #295 62,074; #299 62,010; #297 61,540; #302 60,499; #290 52,012. #303 cannot take any further edit without a trim.
5. Doubled `tests/e2e/shots/shots/` — FIXED: 0 occurrences in #292, #297, #303, #310, #314.
