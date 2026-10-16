# #392 — plan-body corrections: verification against the live bodies (2026-09-30)

Not a runnable test. Each numbered claim re-checked by fetching the bodies (`gh issue view --json body`). NO issue body was edited.

1. #311 coverage sentence — ALREADY FIXED: the contradicting sentence now reads (L54) "The harness writes six of these steps' files; every other UI step still names the file you must capture yourself" (L68 unchanged).
2. #310 dropped drift value — ALREADY RESTORED: the clause "DRIFT: CanonicalSeed.java differs between the repo checkout and .stack-src (414 vs 440 lines; …)" is present in #310.
3. Stale 2026-09-06 STOPs — STILL PRESENT: #310 P0 "STOP. Do not run this plan yet" (L78) and #292 P1 "Execution blocker … Stack gone 2026-09-06" (L61) are still in the bodies. The stack WAS brought up and seeded on 2026-09-30 (docs/manual-test-evidence/README.md), so the premise of the STOP is now false; lifting/re-dating is left to the issue owner (decision).
4. Sizes — CHANGED: #303 is now 65,521 bytes, 15 bytes under the 65,536 cap (was 64,862). #313 63,788; #295 62,074; #299 62,010; #297 61,540; #302 60,499; #290 52,012. #303 cannot take any further edit without a trim.
5. Doubled `tests/e2e/shots/shots/` — FIXED: 0 occurrences in #292, #297, #303, #310, #314.
