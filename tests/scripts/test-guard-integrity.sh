#!/usr/bin/env bash
# test-guard-integrity.sh — the guard over the guards.
#
# THE DISEASE THIS REPO KEEPS RELAPSING INTO IS A GUARD THAT CANNOT FAIL.
# It has shipped in three distinct shapes, all of them found only by hand:
#
#   (1) AN HONEST SUITE WITH A DISHONEST EXIT STATUS.
#       tests/node-storage/test-appset.sh printed its verdict and then ended on
#           echo "---EXIT $?---"
#       With no `set -e`, a script's status is its LAST command's status, and
#       echo always succeeds. The suite printed "---EXIT 1---" and exited 0, so
#       node-storage-verify's fourth leg was structurally incapable of failing
#       from the day it was wired.
#
#   (2) A SUITE NOTHING RUNS.
#       tests/desktop-governance/test-desktop-sudo-mapper.sh — the ONLY coverage
#       of the desktop-sudo mapper's JWKS signature verification, iss/aud/exp
#       checks, identity binding, alg=none and rogue-key rejection — landed with
#       PR #530 wired into neither .gitlab-ci.yml nor the Makefile. Roughly forty
#       other suites were in the same state.
#
#   (3) A LOOP THAT THROWS THE STATUS AWAY.
#       A CI leg that iterates suites must accumulate a failure code; a bare
#       `for t in …; do bash "$t"; done` exits with the LAST suite's status and
#       silently forgives every earlier one.
#
# Each of those was fixed once, by hand, after it had already shipped. This suite
# makes all three fail-closed and mechanical, so the NEXT instance is caught by a
# pipeline instead of by an audit.
#
# Pure static analysis of the repo's own files. No network, no root, no docker,
# no cluster, python3 stdlib only (no PyYAML) so it runs in python:3-slim.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# ── The unwired allowlist ────────────────────────────────────────────────────
# A suite may sit outside every pipeline ONLY with a recorded reason. The
# allowlist is itself guarded below: an entry naming a file that no longer
# exists, or naming a suite that IS now wired, FAILS — so it cannot rot into a
# blanket amnesty. Nothing may be added here because it is red; a red suite is a
# bug report, not an exemption.
ALLOW_UNWIRED=(
)

# GUARD_ROOT lets the negative-control section below re-run this ANALYSER against
# a synthesised tree carrying each defect on purpose, so a green run over the real
# repo cannot be vacuous. GUARD_ALLOW overrides the allowlist for those runs.
GUARD_ROOT="${GUARD_ROOT:-${REPO}}"
if [ -n "${GUARD_ALLOW+x}" ]; then ALLOW_TEXT="${GUARD_ALLOW}"
else ALLOW_TEXT="$(printf '%s\n' "${ALLOW_UNWIRED[@]}")"; fi

# How many suites are wired into a pull_request-triggered workflow (check 7).
# GUARD_PREMERGE overrides it for the negative-control children below, exactly as
# GUARD_ALLOW does for the allowlist: this number describes THE REAL REPO, and a
# synthesised one-suite tree cannot be measured against it.
#
# 117 -> 125 on 2026-08-26, and the DENOMINATOR moved 126 -> 134 in the same
# commit. Both moved for one reason: the census above matched `test-*.sh` only, so
# the eight `*_test.sh` suites in tests/qemu/ and tests/menu/ were neither counted
# nor countable. This number is MEASURED, never estimated — run this file, read the
# "N of M suites are named by a pull_request-triggered workflow" line, and set it to
# N. Guessing it defeats the check: a baseline nobody derived from the tree is a
# number that only ever agrees with itself.
#
# 130 -> 134 / denominator 138 -> 144 on 2026-08-26 (integrate/services-and-keystones).
# EVERY ONE OF THE FOUR MERGED BRANCHES CARRIED ITS OWN NUMBER — 118, 118, 130 —
# each correct against its own base and none correct against the merged tree, and
# each conflicted on exactly this line. All four were resolved to OURS and then
# reconciled ONCE, HERE, by running this file and reading the number it MEASURES:
#     134 of 144 suites are named by a pull_request-triggered workflow
# +6 suites, +4 gated: test-bootstrap-applies-baked-apps.sh (C1),
# test-federation-modules-selection.sh (C3), test-kind-addon-channel.sh (A1) and
# tests/qemu/role_topology_test.sh's siblings' census correction, with
# test-kind-metrics-api.sh (A1) landing UNGATED and recorded below. Letting any
# branch's number win would have pinned a cardinality nobody derived from this tree.
# 130 -> 133 on merge with fix/profile-password-flows: that branch wires
# test-password-reset-front-door.sh, test-kind-profile-route-closure.sh and
# test-route-access-oracle.sh into the pull_request workflow. MEASURED at the
# merge, not carried over from either side -- the branch itself said 120, main
# said 130, and neither number is true of the merged tree.
#
# 134 -> 139 / denominator 144 -> 151 across two merges of main (which had moved
# to 135/146 via the tube signed-media gate, the fragment route gate and the
# password-reset front door, then to 135/147 via the federation module-slug gate).
# BOTH comment blocks above are kept because both record a real reconciliation;
# no branch's number was true of this tree. MEASURED here, by running this file and
# reading the line it prints:
#     139 of 151 suites are named by a pull_request-triggered workflow
# The GATED count did not move on the second merge -- the slug gate lands UNGATED,
# recorded in PREMERGE_UNGATED below with its reason -- so only the denominator did.
# 133 -> 135 on integrate/studio-e2e, and for the same reason a third time. That
# integration wires two more: tests/scripts/test-stack-e2e-argv.sh (from
# feat/stack-e2e-argv-passthrough, which listed it itself) and
# tests/qemu/qemu-e2e-lane_test.sh (from feat/studio-qemu-e2e-lane, which did
# NOT -- its own copy of this file predates the *_test.sh census and could not
# see its own new suite). NO branch's number was correct for the merged tree:
# the two e2e branches both said 118, main said 133. This is the number this
# file printed when run against the merged tree, and nothing else.
#
# 135 -> 137 / denominator 145 -> 148 when main was merged in. Main had moved
# under this branch three times (the tube signed-media gate, the fragment route
# target gate, the password-reset front door, the federation module-slug gate).
# MEASURED on the merged tree by running this file and reading its own line:
#     137 of 148 suites are named by a pull_request-triggered workflow
#
# 137/139 -> 141, denominator -> 153, when the studio-e2e integration and this one
# met on main. BOTH histories above are kept: each records a real reconciliation,
# and deleting either erases why a number moved. Four branches have now written
# their own value into this one line (118, 133, 137, 139) and not one of them was
# true of the tree that resulted. MEASURED, by running this file:
#     141 of 153 suites are named by a pull_request-triggered workflow
# 135 -> 135 at the 2026-08-26 gherkin/e2e integration, and the number staying put
# is the finding, not a non-event: the merged tree gained NINE suites and the
# DENOMINATOR moved 146 -> 155 while the gated count did not move at all, because
# not one of the nine is named by a pull_request workflow. MEASURED by running
# this file on the merged tree; the branches said 117 and main said 135, and
# 117 was true of neither.
#
# 141 / 135 -> 141, denominator 153 / 155 -> 163, when the two independently built
# gherkin/e2e integrations met. BOTH histories above are kept, for the reason the
# block above already gives: each records a real reconciliation, and deleting
# either erases why a number moved. Seven values have now been written into this
# one line by branches that each believed theirs (117, 118, 133, 135, 137, 139,
# 141) and not one of them was true of the tree that resulted -- the two sides of
# THIS merge said 135 and 141 over denominators of 155 and 153, and the merged
# tree is 141 over 163. The GATED count is unchanged here and the denominator is
# what moved: every suite the merge added lands ungated and is recorded in
# PREMERGE_UNGATED below. MEASURED by running this file against the merged tree
# and reading the line it prints:
#     141 of 163 suites are named by a pull_request-triggered workflow
# and by nothing else.
#
# 141 -> 142 when test-e2e-enumeration-without-credentials.sh was gated, and
# 141 -> 142 again, independently, when test-url-embedded-credentials.sh was gated
# on a sibling branch. BOTH measured 142, and both were right about the tree they
# measured and wrong about the merge: each was looking at a tree containing only
# its OWN addition. This block exists because that keeps happening.
#
# The value below is MEASURED on the integrated tree, not carried over from either
# branch — the merge measured 144, which is neither branch's 142 nor the 143 main
# carried in. Re-run this file after any merge that adds a suite; do not reason about
# what the number "should" be.
#
# 144 -> 146, denominator 165 -> 167, when fix/argocd-dashboard-honesty landed. This
# branch wires TWO new suites into shell-suites.yml
# (tests/platform-capability-rbac/test-probe-rbac-namespaces.sh and
# test-argocd-route-honesty.sh) and has now been re-measured THREE times against three
# different mains: it wrote 119 for its own base, then 145 when main was 143/164, and
# 146 here, because main moved to 144/165 underneath it when test-url-embedded-credentials.sh
# was gated. Every one of those three was correct about the tree it measured. That is
# the ninth value a branch has believed on this line, and the eighth time this exact
# line has conflicted.
#
# Resolved as a union, per the rule the blocks above already state: main's record and
# this branch's are complementary, not competing, so BOTH are kept. Note that the first
# resolution of this conflict had to take main's side WHOLESALE rather than line-wise --
# main did not merely hold a bigger number, it added the PREMERGE_UNGATED set-pin below,
# which this branch's side predates entirely, and a line-wise keep of 119 would have
# silently dropped that mechanism.
#
# MEASURED on the integrated tree by running this file and reading the line it prints:
#     146 of 167 suites are named by a pull_request-triggered workflow
# +2 gated, +2 total: both of this branch's suites are named by shell-suites.yml, which
# is why the gated count and the denominator moved together and the ungated SET pin
# below was untouched (it stays 21). That this agrees with 144+2 is a CHECK on the
# measurement, not a substitute for it -- the seven entries above are all cases where
# the arithmetic and the measurement disagreed.
#
# 146 -> 147, denominator 167 -> 168, when feat/appstore-effector-enable landed. This
# branch has now met main FOUR times and written a different number each time: 118
# against its own base of 117, then 142, then 144, and 147 here. Every one of the four
# was correct about the tree in front of it and wrong about the merge, because main
# gained suites underneath it each time -- most recently the two from
# fix/argocd-dashboard-honesty.
#
# The shape of this merge is the benign one and is STILL not a free pass: each side
# gates suites the other does not have (tests/scripts/test-appstore-effector-flags.sh
# here; main's argocd pair and the url-credentials suite), so the merged tree sits above
# the higher of the two and neither side's number describes it. Adding the deltas by hand
# would have been right by luck.
#
# Note also why main's side is taken WHOLESALE rather than line-wise: main's half carries
# the PREMERGE_UNGATED set-pin, which the branch's half predates. A resolution that kept
# only the branch's number would have deleted that mechanism while looking like a
# one-line change -- the same trap the first appstore reconciliation recorded.
#
# MEASURED by running this file against the merged tree and reading the line it prints:
#     147 of 168 suites are named by a pull_request-triggered workflow
# +1 gated, +1 total: the branch's single new suite is named by shell-suites.yml, so it
# lands GATED and does not belong in PREMERGE_UNGATED -- which is why that list is
# unchanged at 21 and check 7's set assertion stayed green across this merge.
#
# 147 -> 148, denominator 168 -> 169, when feat/workload-console-versions landed. This
# branch has now written three numbers into this line: 144 of 165, then 147 of 168, and
# 148 of 169 here. Each was measured and each was correct about the tree in front of it.
#
# THE PREVIOUS ENTRY IS THE WORKED EXAMPLE, so it is left standing above rather than
# tidied away. When this branch measured 147/168, feat/appstore-effector-enable ALSO sat
# at 147/168 -- both add exactly one gated suite to a main at 146/167, so both were right
# and the two were mutually exclusive. That branch landed first, main became 147/168, and
# this one had to be re-measured at 148/169. The prediction was written into this file
# before it happened and is what made the re-measure routine instead of a surprise.
#
# Main's side is taken WHOLESALE rather than line-wise, and both comment blocks are kept
# as a union, for the reasons the entries above give: main's half carries the
# PREMERGE_UNGATED set-pin that older branch halves predate, so a line-wise keep would
# delete that mechanism while looking like a number change.
#
# MEASURED on the integrated tree by running this file and reading the line it prints:
#     148 of 169 suites are named by a pull_request-triggered workflow
# +1 gated, +1 total: this branch's suite is named by shell-suites.yml, so it lands GATED
# and never enters PREMERGE_UNGATED, which stays 21.
#
# RE-MEASURED 2026-08-27 on fix/anubis-compose-knob-and-wg-perms, exactly as the
# worked example above prescribes: this branch adds tests/stack/test-anubis-flip-wiring.sh
# and names it in shell-suites.yml's debian job, so it lands GATED. Running this
# file on the integrated tree printed
#     149 of 170 suites are named by a pull_request-triggered workflow
# +1 gated, +1 total; PREMERGE_UNGATED is untouched and stays 21.
#
# RE-MEASURED 2026-08-27 on fix/e2e-docker-base-url-parity, same procedure again:
# this branch adds tests/scripts/test-e2e-docker-base-url-parity.sh and names it in
# shell-suites.yml's NODE job (it evaluates the TypeScript fallbacks in node, which
# is the only job image that has one). Running this file on the integrated tree
# printed
#     150 of 171 suites are named by a pull_request-triggered workflow
# +1 gated, +1 total; PREMERGE_UNGATED is untouched and stays 21.
#
# RE-MEASURED 2026-08-27 on sync3/selected-services-gate-v3, which carries the
# never-pushed local commit 85f868ca onto main at 6ba15d35. This branch lands ONE
# new suite, tests/scripts/test-selected-services-only.sh, and lands it UNGATED:
# five of its checks are RED on main by design (A4 B2 B3 C5b C7 -- the
# selected-services cut-over has not happened), and a red suite in the
# pull_request workflow blocks every PR in the repo. It is recorded in
# PREMERGE_UNGATED below with that reason and gated post-merge by .gitlab-ci.yml's
# lint:selected-services-only-chain. So the GATED count does not move and only
# the denominator does. Running this file on a clean
# `git archive origin/main | tar -x` extract of 6ba15d35 printed
#     150 of 171 suites are named by a pull_request-triggered workflow
# and on the integrated tree it printed
#     150 of 172 suites are named by a pull_request-triggered workflow
# +0 gated, +1 total; PREMERGE_UNGATED grows 21 -> 22, and the SET pin below moves
# with it -- the new entry is NAMED, which is what a set pin is for.
#
# The commit being carried had written "141 of 155" into this line, measured
# against main at db8d7697 the same morning (and had itself corrected main's then
# recorded denominator, 153, to a measured 154). Both were true of that tree and
# neither describes this one: the entries above record how main moved underneath
# it. Carried by re-running this file, not by arithmetic on either side's number.
#
# RE-MEASURED 2026-08-27 on fix/rebrand-sentinel-eq-and-fetch-repos, same procedure:
# that branch adds tests/scripts/test-rebrand-frozen-label-keys.sh (drives the REAL
# rebrand_sysroot of all ten builders over a fixture sysroot; bash + sed + awk) and
# tests/scripts/test-stack-fetch-repos.sh (pins the home-seeded stack's repo list
# against the org listing and exercises fetch-repos.sh against file:// bases; bash
# + git), both named in shell-suites.yml's ALPINE job. On its base (8165b81a) this
# file printed 150 of 171; with the two suites, 152 of 173.
#
# RE-MEASURED 2026-08-27 on the MERGE of that branch with main at f14e2949 (which
# carried the ungated test-selected-services-only.sh above: +0 gated, +1 total,
# PREMERGE_UNGATED 21 -> 22). Running this file on the merged tree printed
#     152 of 174 suites are named by a pull_request-triggered workflow
# +2 gated from this branch, +1 total from main; PREMERGE_UNGATED stays at
# main's 22. Carried by re-running this file, not by arithmetic.
#
# RE-MEASURED 2026-08-27 on the MERGE of fix/e2e-toolchain-readiness with main at
# 5c5c6320 (which carried 152 of 174 above). This branch adds ONE gated suite,
# tests/scripts/test-e2e-toolchain-readiness.sh (the guard over
# tests/e2e/check-toolchain.sh, the probe every e2e make target and every Gherkin
# guard now runs in place of `[ -d tests/e2e/node_modules ]`), named in
# shell-suites.yml's NODE job — it builds its fixtures with node and needs no
# node_modules (its real-tree leg SKIPS LOUDLY without one, counted as a skip).
# On its own base (f1c41bb3) this file printed 151 of 172; on the merged tree it
# printed
#     153 of 175 suites are named by a pull_request-triggered workflow
# +1 gated, +1 total; PREMERGE_UNGATED stays at main's 22. Carried by re-running
# this file, not by arithmetic on either side's number.
#
# RE-MEASURED 2026-08-27 on fix/coverage-check-runtime, same procedure: this
# branch adds tests/scripts/test-e2e-coverage-matrix-harness.sh — the guard OVER
# test-e2e-coverage-matrix.sh (which itself STAYS in PREMERGE_UNGATED below: it
# needs node_modules and a real chromium no shell-suites image carries). The
# harness needs only node+npx, python3, git, md5sum and a STUB playwright it
# writes itself (~25s, no browser, no npm install), so it is named in
# shell-suites.yml's NODE job and run first by `make stack-e2e-coverage-check`.
# Running this file on the merged tree (origin/main at a8015e81) printed
#     153 of 175 suites are named by a pull_request-triggered workflow
# +1 gated, +1 total; PREMERGE_UNGATED is untouched and stays 22.
#
# RE-MEASURED 2026-08-27 on the MERGE of fix/coverage-check-runtime with main at
# 91fefe05 (which carried the toolchain-readiness suite above: 153 of 175 on its
# own merged tree, exactly as this branch's 153 of 175 on ITS pre-#216 base —
# each side added one gated NODE-job suite to the same 152/174). The union is
# both: running this file on THIS merged tree printed
#     154 of 176 suites are named by a pull_request-triggered workflow
# +1 gated +1 total from each side; PREMERGE_UNGATED stays 22. Carried by
# re-running this file, not by arithmetic — but the arithmetic agrees.
# RE-MEASURED 2026-08-27 on the MERGE of fix/seed-password-contract-on-recreated-
# stack with main at 91fefe05 (which carried the 153 of 175 above). This branch
# adds ONE gated suite, tests/scripts/test-seed-password-reconcile.sh (stub
# Casdoor + stub front door + a `make -n` probe; named in shell-suites.yml's
# ALPINE job and, with its mutation battery, in .gitlab-ci.yml's
# lint:seed-password-reconcile). Both sides had independently written 153 on
# this line — each measuring its OWN suite against a base that lacked the
# other's — so the textual merge was CLEAN and still wrong: the merged tree
# really gates both. Running this file on the merged tree printed
#     154 of 176 suites are named by a pull_request-triggered workflow
# +1 gated, +1 total from each side; PREMERGE_UNGATED stays at main's 22.
# Carried by re-running this file, not by arithmetic on either side's number —
# a clean auto-merge of this line is exactly how a baseline goes silently stale.
#
# RE-MEASURED 2026-08-27 on the MERGE of fix/coverage-check-runtime with main at
# 0e904b7a (which carried the seed-password-reconcile suite above: 154 of 176 on
# its own merged tree, exactly as this branch's 154 of 176 on ITS 91fefe05
# merge — each side added one gated suite to the same 153/175). The union is
# both again, and again the VALUE line under this comment auto-merged CLEAN at
# 154 while the merged tree really gates more — the exact silently-stale shape
# the block above warns about, caught because check 7 stays red until the
# baseline is raised to what this file MEASURES. Running this file on THIS
# merged tree printed
#     155 of 177 suites are named by a pull_request-triggered workflow
# +1 gated +1 total from each side; PREMERGE_UNGATED stays 22. Carried by
# re-running this file, not by arithmetic - but the arithmetic agrees.
#
# 2026-08-27, the one-role-vocabulary branch: adding
# tests/scripts/test-role-key-spelling.sh (gated in shell-suites.yml alongside
# test-platform-key-spelling.sh, its template) made this file MEASURE
#     156 of 178 suites are named by a pull_request-triggered workflow
# so the baseline is 156. Taken from the run, not computed: if this file conflicts
# on merge, RE-MEASURE by running it rather than trusting either side's number.
# PREMERGE_UNGATED is unchanged at 22 — the new suite is gated, not exempted.
#
# 2026-08-27, fix/route-access-scanner-and-404-claim: +1 gated +1 total for
# tests/scripts/test-route-access-coverage-scanner.sh (the guard over
# tests/scripts/route_access_coverage.py, added in the same change). MEASURED by
# running this file on that tree: "156 of 178 suites are named by a
# pull_request-triggered workflow". PREMERGE_UNGATED is unchanged -- the new suite
# is gated, so it does not join the complement.
#
# RE-MEASURED 2026-09-01 on the MERGE of fix/one-role-vocabulary with main at
# 7abab12d (which carried the route-access-coverage-scanner suite above). The
# two blocks above are BOTH true and both measured 156 — each side added one
# gated suite to a base that lacked the other's, so this value line was a
# CONFLICT here (not even the clean-but-wrong auto-merge of the earlier
# entries) and neither side's 156 covers the union. Running this file on THIS
# merged tree printed
#     157 of 179 suites are named by a pull_request-triggered workflow
# +1 gated +1 total from each side; PREMERGE_UNGATED stays 22. Carried by
# re-running this file, not by arithmetic on either side's number — but the
# arithmetic agrees.
#
# RE-MEASURED 2026-09-01 on the MERGE of fix/standalone-stage4-keyword-preseeds
# with main at 0727650b (which carried the one-role-vocabulary and
# route-access-coverage-scanner suites above: 157 of 179 on main). This branch
# adds ONE gated suite, tests/scripts/test-qt6-keyword-preseeds.sh (named in
# shell-suites.yml's ALPINE job and in .gitlab-ci.yml). The branch was cut
# before main's two newest suites, so its own line said 156 and this value line
# CONFLICTED on merge — per the doctrine above, the number is taken from
# running this file on THIS merged tree, which printed
#     158 of 180 suites are named by a pull_request-triggered workflow
# +1 gated +1 total from the branch on top of main's 157/179; PREMERGE_UNGATED
# stays 22. Carried by re-running this file, not by arithmetic on either
# side's number — but the arithmetic agrees.
#
# RE-MEASURED AGAIN 2026-09-01 on the merge of the same branch with main at
# 2e24b4d5 (PR #247, docs-only), and once more with main at c6b788fe (PRs #239
# and #248 — no suite added or gated by either): running this file on EACH of
# those merged trees printed the same
#     158 of 180 suites are named by a pull_request-triggered workflow
# and the ungated set is unchanged at 22 — no conflict either time, re-run anyway.
#
# RAISED TO 159, 2026-09-06, on the merge of fix/e2e-residue-stack-2-branch with
# main at 27871641. One suite was ADDED AND GATED in that branch:
# tests/scripts/test-e2e-shell-nav-entry.sh, the offline drift guard for the host
# shell's Matrix nav entry. It is the only test-e2e-* suite that is CI-gated rather
# than sitting in the ungated list below with its eight siblings, and the reason is
# the same measure-by-execution rule that put them there: those eight need
# tests/e2e/node_modules and a chromium that no shell-suites image carries, and
# this one is pure static analysis of tests/e2e — it was RUN in python:3.12-slim,
# the debian job's own image, with the checkout mounted read-only and
# --network=none, and printed 3 passed / 0 failed rc=0 with its negative-control
# battery 9 caught / 0 survived. MEASURED on the merged tree, not computed: this
# file printed "159 of 181 suites" there, and the ungated SET is unchanged at 22.
#
# RAISED TO 160, 2026-09-08, on fix/lxde-intltool-preseed cut from main at
# 81a7c125. One suite was ADDED AND GATED: tests/scripts/test-intltool-preseed.sh,
# the build-order guard for the dev-util/intltool pre-seed that lxde-base/
# lxde-common needs and does not declare. It is named in shell-suites.yml's
# ALPINE job and in .gitlab-ci.yml. MEASURED, not computed: this file printed
#     160 of 182 suites are named by a pull_request-triggered workflow
# on this tree, and the ungated SET is unchanged at 22. The suite was also RUN
# in alpine:3 — the alpine job's own image, checkout mounted read-only, busybox
# grep and busybox sed — and printed 8 passed / 0 failed rc=0, with its negative
# controls re-verified there rather than only on the GNU host, because busybox
# is exactly where a negative guard fails open.
# ── 2026-09-16, THIRD reconciliation of this line in one day ──────────────────
# Both sides of this conflict said 166 and both were RIGHT about the tree they
# measured, and both are WRONG about this one — the failure mode this whole comment
# stack exists to document. main reached 166/188 by gating
# tests/scripts/test-casdoor-login-budget.sh (#396); this branch reached 166/188 by
# gating tests/scripts/test-superadmin-bff-reachability.sh (#351). The merged tree
# has BOTH, so it is neither number. Taken, as always, by RUNNING this file here:
#     167 of 189 suites are named by a pull_request-triggered workflow
# Taking either side verbatim would have pinned a cardinality nobody derived from
# this tree, and the "both sides agree" shape is the one most likely to be waved
# through. The three notes below are kept as a union: complementary records.
#
#
# 165 -> 166 / denominator 187 -> 188 on 2026-09-16, merging `integrate/superadmin`
# (#351, operator decision 20 "land the whole branch"). That branch carried
# `PREMERGE_BASELINE=135`, correct against its own 2026-08-26 base and 540 commits
# stale; main carried 165. NEITHER number is true of the merged tree, so, as every
# reconciliation above did, this one was MEASURED by running this file and reading
# the line it prints:
#     166 of 188 suites are named by a pull_request-triggered workflow
# The +1/+1 is tests/scripts/test-superadmin-bff-reachability.sh, the ONE file the
# branch contributes that main did not already have, wired into
# .github/workflows/shell-suites.yml by the same merge. Resolving this hunk to
# EITHER side would have pinned a cardinality nobody derived from this tree.

# 165 -> 166 on 2026-09-16, RESOLVING THIS LINE'S CONFLICT on the merge of
# fix/kind-casdoor-init-converges with main at 8ae7b727. Both sides had measured
# 165 of 187 and both were right about the tree they measured — main had gated
# test-argocd-serverside-diff.sh, this branch had gated
# tests/scripts/test-casdoor-login-budget.sh, and neither number survives having
# BOTH. Per the doctrine above the value was taken by RUNNING this file on THIS
# merged tree, which printed
#     166 of 188 suites are named by a pull_request-triggered workflow
# and the ungated SET is unchanged at 22. The two notes below are kept as a union:
# they are complementary records, not competing ones.
#
# test-casdoor-login-budget.sh is the ordering + login-budget pin for the four
# Casdoor bootstrap hook Jobs that share one built-in/admin account
# (hugmesh-generator#396 — un-waved ArgoCD PostSync hooks raced, tripped casdoor's
# sign-in throttle, and killed a bring-up on a cluster that then converged by
# itself 7m37s later). Named in shell-suites.yml's DEBIAN job, not the alpine one:
# it uses `grep -a`, which busybox grep does not have. RUN on this host: 31 passed
# / 0 failed rc=0, thirteen negative controls 13 caught / 0 survived, and on the
# PRE-FIX tree the same suite prints 22 failures and reproduces the live cluster's
# failure message byte-for-byte.
#
# 164 -> 165 on 2026-09-16: tests/scripts/test-argocd-serverside-diff.sh joined the
# gate with the harbor Server-Side Diff annotation (hugmesh-generator#354). MEASURED
# by RUNNING this file both ways on the same tree, not assumed:
#     165 of 187 suites are named by a pull_request-triggered workflow   (with it)
#     164 of 186 suites are named by a pull_request-triggered workflow   (without)
# — "without" meaning the suite file deleted AND both its wirings removed, so the
# denominator moves too. It is named in shell-suites.yml's DEBIAN job (python:3.12-
# slim): it is a negative guard whose controls must fail on a planted defect, and
# busybox grep/sed is where a negative guard fails open. The ungated SET pin is
# unchanged at 22 in both measurements.
#
# 168 -> 169 on 2026-09-17: tests/scripts/test-e2e-spec-symbol-resolution.sh joined
# the gate with the #305 fix (spec 15 called loginPassword() without importing it,
# and nothing in the lane could see it). MEASURED by RUNNING this file on the same
# tree before and after the two wirings, not computed:
#     168 of 191 suites are named by a pull_request-triggered workflow   (suite on
#                                                                         disk, not
#                                                                         yet wired)
#     169 of 191 suites are named by a pull_request-triggered workflow   (wired)
# The DENOMINATOR does not move here, unlike the entries above, and that is the
# check on the measurement: the suite file was already on disk and already counted
# when the first number was taken, so only the gated half could move. It is named
# in shell-suites.yml's DEBIAN job (python:3.12-slim) and in .gitlab-ci.yml. It is
# the SECOND test-e2e-* suite in that DEBIAN JOB, joining test-e2e-shell-nav-entry.sh
# there — and the EIGHTH test-e2e-* suite in shell-suites.yml overall. COUNTED on
# 2026-09-17, not assumed, because the 2026-09-06 note above calls shell-nav-entry
# "the one e2e guard that belongs in CI" and that was already imprecise when written.
# By JOB, never by line number (those shift on any edit to that file):
#     alpine  test-e2e-enumeration-without-credentials.sh
#             test-e2e-persona-catalogue.sh
#     debian  test-e2e-shell-nav-entry.sh
#             test-e2e-spec-symbol-resolution.sh   <- this one
#     node    test-e2e-coverage-matrix-harness.sh
#             test-e2e-docker-base-url-parity.sh
#             test-e2e-reporter-shape.sh
#             test-e2e-toolchain-readiness.sh
# all eight in pull_request-triggered jobs; recount with
# `grep -c '^ *tests/scripts/test-e2e-' .github/workflows/shell-suites.yml`
# (anchored: an unanchored grep also matches these prose lines and answers 11).
# Do NOT read "second" as "six suites fell out of the gate" — the gated NUMBER
# above is the measurement; the list is only context. The suite needs python3 and
# nothing else (no node_modules, no chromium); the alpine job installs python3
# too, so the debian placement is a choice of ONE job, not a constraint. The
# ungated SET pin is unchanged at 22. This file conflicts on nearly every merge;
# if it conflicts here, RE-MEASURE on the merged tree per the doctrine above
# rather than taking 169, 170, 171 or any one side's number.
#
# 170 (this branch) and 171 (main) -> RE-MEASURED on 2026-09-17 while merging
# origin/main into iss/366-fe-gateway-cluster-route-table-404s-five-bff-pat. Both
# sides moved the baseline for DIFFERENT suites and neither number is true of the
# merged tree: main reached 171 by gating tests/scripts/test-kind-halt.sh (#356)
# AND tests/scripts/test-eso-remoteref-brand.sh (#285), this branch reached 170 by
# gating tests/scripts/test-fe-bff-route-lane-parity.sh (#366, decision 40 = B on
# #347). The merged tree has all three, so — as every reconciliation below did —
# the number was taken by RUNNING this file on the MERGED tree and reading the
# line it prints, not by adding 1 to either side. Every note either side of this
# one is kept: they are complementary records, none supersedes another.
# THE MEASUREMENT on the merged tree, taken by running this file:
#     172 of 194 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 22.
#
# 169 -> 170 on 2026-09-17: tests/scripts/test-fe-bff-route-lane-parity.sh joined
# the gate with operator decision 40 (hugmesh-generator#347 answers comment;
# tracked on hugmesh-generator#366). It reads BOTH fe route tables — the compose
# one (tests/stack/gateway-routes/fe/application-routes.yml) and the cluster one
# (specs/cluster/apps/20-gateway-fe.yaml) — simulates Spring Cloud Gateway's
# first-match-wins ordering over each, and asserts the five #366 paths resolve to
# the SAME BFF on both. Two of the five have no handler anywhere and 404 by
# ACCEPTED decision, so the guard also has to stop a well-meaning revert.
# MEASURED by RUNNING this file both ways on the same tree, not assumed:
#     170 of 192 suites are named by a pull_request-triggered workflow   (with it)
#     169 of 191 suites are named by a pull_request-triggered workflow   (without)
# — "without" meaning the suite file deleted AND both its wirings removed, so the
# denominator moves too, exactly like the 164 -> 165 entry above. Named in
# shell-suites.yml's DEBIAN job (python:3.12-slim) because it needs PyYAML, which
# only the debian and extras jobs install; the alpine job has no yaml module and
# the suite would die on the import rather than skip. The ungated SET pin is
# unchanged at 22 in both measurements. RUN on this host after the landing pass
# added nine asserted matcher cases: 19 passed / 0 failed rc=0 with six negative
# controls 6 caught / 0 survived, and against the PRE-CHANGE compose table
# (origin/main's copy dropped in on disk) it prints 14 passed / 5 failed rc=1,
# one failure per #366 path.
# ADDENDUM 2026-09-23 (the note above is kept verbatim, as every note is): its
# "two of the five have no handler anywhere and 404 by ACCEPTED decision" was
# true when written and is not any more — hugmesh-user-bff-api#20 (dc34c8b,
# landed 2026-09-18) added the /bff/register/{google,discord} handlers, and the
# parity suite now ASSERTS has_handler=True for all five (hugmesh-generator#568).
# The suite count is unchanged: no suite was added or removed by that change.
# ADDENDUM 2026-09-23, second: the same suite has owned decision 60 since PR #570
# (2026-09-18) — it also asserts APP_BFF_EXCHANGE_CACHE_TTL_MS == "0" for
# admin-bff-api and mod-bff-api on both lanes (tests/stack/compose.local.yaml +
# specs/cluster/manifests/{admin,mod}-bff-api/). Anyone reading the description above as the suite's whole
# scope and "simplifying" it back to route tables would delete decision 60's only
# guard. Suite count unchanged.
#
# 170 -> RE-MEASURED on 2026-09-17 while merging origin/main into
# iss/285-vault-brand-remoteref. BOTH sides of this merge said 170 and NEITHER is
# true of the merged tree: main reached 170 by gating tests/scripts/test-kind-halt.sh
# (#356), this branch reached 170 by gating tests/scripts/test-eso-remoteref-brand.sh
# (#285, decision 38 = B on #347). The merged tree has BOTH suites, so, as every
# reconciliation above did, the number below was taken by RUNNING this file on the
# merged tree and reading the line it prints. The two notes either side of this one
# are kept as a union: complementary records, neither one superseding the other.
# NOTE on placement: test-eso-remoteref-brand.sh is gated in the GitHub `extras` job
# rather than `guards`, because it renders what ArgoCD renders and needs kubectl +
# PyYAML, which only that job installs and preflights. It is NOT in
# PREMERGE_UNGATED: it is offline, touches no cluster, and runs in ~12s.
# THE MEASUREMENT on the merged tree, taken by running this file:
#     171 of 193 suites are named by a pull_request-triggered workflow
# so the baseline below is 171, not either side's 170. The ungated SET pin is
# unchanged at 22.
# 169 -> 170 / denominator 192 (unchanged -> 192) on iss/356-kind-lane-halt, which
# adds ONE suite and gates it: tests/scripts/test-kind-halt.sh, the offline guard
# over `make kind-halt` / `make kind-resume` (the kind lane's non-destructive stop).
# MEASURED, not incremented — this is the number this file printed when run against
# that tree:
#     170 of 192 suites are named by a pull_request-triggered workflow
# It is deliberately NOT in PREMERGE_UNGATED: the suite is offline, stubs kind,
# docker and kubectl on PATH, touches no cluster and runs in a few seconds, so it
# has no reason to sit outside the gate. Recording a false exemption here is how
# rot has stayed hidden for weeks before.


# 169 -> 170 on 2026-09-17: tests/scripts/test-eso-remoteref-brand.sh joined the
# gate with the ExternalSecret remoteRef brand rule (hugmesh-generator#285,
# decision 38 = B on #347). MEASURED by RUNNING this file on the tree with the
# suite wired and unwired, not assumed: unwired it printed "all 192 suites are
# invoked ... (0 allowlisted)" and the gated count 169; wired it printed
# "pre-merge suite coverage rose to 170, baseline still says 169". The ungated
# SET pin is unchanged at 22.
# 169 -> 170 on 2026-09-17: tests/scripts/test-backing-service-endpoints-closure.sh
# joined the gate. It is the manifest-side guard for operator DECISION 34a/34b — the
# one that goes RED when the per-namespace backing-service-endpoints fan-out is
# reverted to the single hugmesh-backend object the operator DECLINED. It was added
# because an adversarial review measured five manifest mutations surviving every
# suite the shipping PR cited as verification. MEASURED, not assumed: with the suite
# named in shell-suites.yml's DEBIAN job this file printed
# "170 of 192 suites are named by a pull_request-triggered workflow" and with the
# name removed it printed 169, so the raise is this one suite and nothing else. The
# ungated SET pin is unchanged — the suite landed INSIDE the gate, so PREMERGE_UNGATED
# gains no entry.
#
# 172 (main) and 170 (this branch) -> RE-MEASURED on 2026-09-17 while merging
# origin/main into iss/decision34-backing-service-endpoints. This file conflicts on
# nearly every merge and BOTH sides' numbers were true only of their own tree: main
# reached 172 by gating test-kind-halt.sh (#356), test-eso-remoteref-brand.sh (#285)
# and test-fe-bff-route-lane-parity.sh (#366); this branch reached 170 by gating
# test-backing-service-endpoints-closure.sh (#486). The merged tree has all four, so
# — as every reconciliation above did — the number below was taken by RUNNING this
# file on the MERGED tree and reading the line it prints, never by adding 1 to either
# side. Every note either side of this one is kept: they are complementary records,
# none supersedes another.
# THE MEASUREMENT on the merged tree, taken by running this file:
#     173 of 195 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 22.
#
# 173 -> 174 on 2026-09-18: tests/scripts/test-no-literal-vault-brand-prose.sh
# joined the gate (wired into shell-suites.yml's alpine job), guarding
# specs/cluster prose against re-drifting to the literal default-brand Vault
# path `secret/hugmesh/...` (hugmesh-generator#490). MEASURED by RUNNING this
# file on the tree with the new suite wired, not assumed:
#     174 of 196 suites are named by a pull_request-triggered workflow
#
# 173 -> 174 on 2026-09-18: tests/scripts/test-stack-clone-credential.sh (#535)
# landed on disk in the same commit that wires it into shell-suites.yml's alpine
# job, so the denominator moves too (195 -> 196, tracking check 1's new-file
# count) and the gated count moves with it, not independently — MEASURED by
# running this file on the merged tree before and after the wiring line landed,
# not computed:
#     173 of 196 suites are named by a pull_request-triggered workflow   (suite on
#                                                                         disk, not
#                                                                         yet wired)
#     174 of 196 suites are named by a pull_request-triggered workflow   (wired)
# The ungated SET pin is unchanged at 22 — the new suite was never in it.
#
# 174 (#490) and 174 (#535) -> RE-MEASURED on 2026-09-18 while merging origin/main
# into land/490-vault-prose. Same shape as the 172/170 reconciliation above: both
# notes above reached 174 independently and only of their own tree, each gating a
# DIFFERENT new suite (test-no-literal-vault-brand-prose.sh here,
# test-stack-clone-credential.sh from #535 on main) — the merged tree gates BOTH, so
# the true number is not 174, it is whatever running this file on the merged tree
# prints. The number below was taken that way, never by adding 1 to either side.
# THE MEASUREMENT on the merged tree, taken by running this file (GUARD_PREMERGE=0
# to see the raw count without the assignment below tripping int() on a stale
# value):
#     175 of 197 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 22 — neither new suite was ever in it.
#
# 175 -> 176 on 2026-09-18: tests/scripts/test-deeplink-remote-coverage.sh
# joined the gate (wired into shell-suites.yml's debian job and .gitlab-ci.yml's
# lint:deeplink-remote-coverage), guarding the SPA deep-link fallback route's
# coverage of every in-shell `*-ui` remote — derived from each fe route table's
# own routes, never hardcoded — against hugmesh-generator#381 (the /admin, /mod,
# /user gap) regressing, or the next remote repeating it. MEASURED by RUNNING
# this file on the tree with the new suite wired, not assumed (GUARD_PREMERGE=0):
#     176 of 198 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 22 — the new suite was never in it.
#
# 176 -> 177 on 2026-09-23: tests/scripts/test-tor-node-contract.sh (hugmesh-generator
# #583, decision 70 = B on #347) landed on disk in the same commit that wires it into
# shell-suites.yml's alpine job (beside the other builder --print-plan suites), so the
# denominator moves too (198 -> 199). MEASURED by RUNNING this file on the tree with the
# suite wired (GUARD_PREMERGE=0), not computed:
#     177 of 199 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 22 — the new suite was never in it.
#
# 177 -> 178 on 2026-09-23 (RE-MEASURED on the MERGE of tor/compose-e2e-20260923,
# hugmesh-generator PR #598, with origin/main b5901697 — which already carried the
# 177 above): tests/stack/test-tor-flip-wiring.sh (#576/#581/#586) joined the gate in
# shell-suites.yml's debian job, and tests/stack/test-tor-onion-mechanism.sh (#585)
# landed on disk OUTSIDE it (recorded in PREMERGE_UNGATED below), so the denominator
# moves by two (199 -> 201). MEASURED by RUNNING this file on that merged tree, not
# computed:
#     178 of 201 suites are named by a pull_request-triggered workflow
# The ungated SET pin moves 22 -> 23 (the mechanism wrapper).
#
# 178 -> 179 on 2026-09-23 (RE-MEASURED on the MERGE of tor/saved-mesh-bridge-20260923,
# hugmesh-generator PR #600, with origin/main f3963e86 — which already carried the 178
# above): tests/scripts/test-studio-tor-domain-pins.sh (#591) joined the gate, named in
# .github/workflows/studio-tests.yml's pytest job (a pull_request workflow), so the
# denominator moves by one (201 -> 202). MEASURED by RUNNING this file on that merged
# tree (GUARD_PREMERGE=0), not computed:
#     179 of 202 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 23 — the new suite was never in it.
#
# (kind-tor, recorded as 176 -> 177 on its own branch before the merge below)
# tests/scripts/test-kind-tor.sh joined the gate (wired into shell-suites.yml's extras job, which carries helm + make, and .gitlab-ci.yml's
# lint:kind-tor), pinning the kind lane's .onion front door — scripts/kind-tor.sh's
# `HiddenServicePort 443 127.0.0.1:8443`, its read-modify-write helm-parameter patch
# and the fe-gateway Ingress that patch renders (hugmesh-generator#577, decision
# 67 = B). MEASURED by RUNNING this file on the tree with the new suite wired, not
# assumed (GUARD_PREMERGE=0):
#     177 of 199 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 22 — the new suite was never in it.
#
# 179 -> 180 on 2026-09-23 (RE-MEASURED on the MERGE of iss/577-kind-tor-host-onion,
# hugmesh-generator PR #613, with origin/main 2e7d089d — which already carried the 179
# above from #600; #613 had independently written 179 against f3963e86):
# tests/scripts/test-kind-tor.sh is the one new gated suite, so the denominator moves
# 202 -> 203. MEASURED by RUNNING this file on that merged tree (GUARD_PREMERGE=0), not
# computed:
#     180 of 203 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 23 — the new suite was never in it.
#
# 180 -> 182 on 2026-09-24 (iss/614-node-onion-ingress, on origin/main e6838857 — which
# already carried the 180 above): two new suites, both wired into shell-suites.yml's
# extras job (helm + kubectl): tests/scripts/test-tor-onion-ingress.sh (#614 — a
# hardware node's .onion admitted as an fe-gateway Ingress host, rendered with a real
# `helm template`) and tests/scripts/test-optional-netpol-autosync.sh (#617 — no
# optional-service NetworkPolicy served from git by an Application every build keeps,
# via `kubectl kustomize`). The denominator moves 203 -> 205. MEASURED by RUNNING this
# file on that tree (GUARD_PREMERGE=0), not computed:
#     182 of 205 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 23 — neither new suite was ever in it.
# 192 -> 194 (denominator 215 -> 218, ungated SET 23 -> 24) on 2026-09-30 for
# hugmesh-generator#659 (iss/659-x86-builder-resume-static-restore, on origin/main
# 5c5ae084 — which already carried the 192 above): three new suites landed on
# disk in the same commit that wires two of them. tests/scripts/
# test-builder-resume-safety.sh (the --resume owner gate, seed choice, static
# restore, link test, stale-mount refusal and umount_chroot, executed against
# fixtures and stubs, with a mutation battery) and tests/scripts/
# test-makefile-reown-skips-sysroot.sh (the Makefile's chown-artifacts never
# descends into a build system) joined the gate in shell-suites.yml's alpine job
# and .gitlab-ci.yml's orphan-guards-verify (which gained xz for the .tar.xz seed
# fixtures). tests/scripts/test-builder-unmount-real.sh (the same unmount against
# REAL stacked binds in a user+mount namespace) is ungated with its reason in
# PREMERGE_UNGATED below and runs from `make builder-unmount-real-check`.
# MEASURED by RUNNING this file on that tree (GUARD_PREMERGE=0), not computed:
#     194 of 218 suites are named by a pull_request-triggered workflow
#     PASS the ungated SET matches its pin exactly (24 suite(s))
#
# Gated count unchanged, denominator +1 and ungated SET 24 -> 25, on 2026-10-14 for
# #693: every signed-in call on kind answered 500 because the BFF manifests set only CASDOOR_ISSUER_URI and
# the key fetch went to the public issuer host, which does not resolve in-cluster.
# tests/scripts/test-bff-jwks-in-cluster.sh pins the in-cluster CASDOOR_JWKS_URI, its
# Service closure and the NetworkPolicy admission offline. It is NOT yet named by
# shell-suites.yml — the lane that wrote it could not edit .github — so it lands in
# PREMERGE_UNGATED below with that reason (the set pin moves 24 -> 25) and is run
# post-merge by .gitlab-ci.yml's lint:bff-jwks-in-cluster. MEASURED by RUNNING this
# file on this branch merged with origin/main c0c46601:
#     196 of 221 suites are named by a pull_request-triggered workflow
#     PASS the ungated SET matches its pin exactly (25 suite(s))
# When the shell-suites.yml line lands: delete that entry and raise the baseline by one.

# 192 -> 193 (denominator 215 -> 216) on 2026-09-30 for #663: the kind sign-in
# answered 500 because the BFF autoscalers' maxReplicas (6) times the unconfigured
# R2DBC pool (10) exceeded the app role's CONNECTION LIMIT (20).
# tests/scripts/test-db-connection-budget.sh pins that inequality offline over
# specs/cluster/manifests and joined shell-suites.yml's debian job (PyYAML).
# MEASURED by RUNNING this file on the tree, not computed:
#     suite added and wired                193 of 216
# The ungated SET pin is unchanged at 23: the new suite was never in it.
#
# 194 / 193 -> 195 (denominator 219) on 2026-10-07: RE-MEASURED on the MERGE of
# iss/659-x86-builder-resume-static-restore with origin/main f4a6a899, which carried
# the 193 above from #663 while the branch carried the 194 above from #659 (both
# written against 192 on 5c5ae084). The three suites are disjoint, so the gated count
# is 192 + 2 + 1 and the denominator 215 + 3 + 1. MEASURED by RUNNING this file on
# that merged tree (GUARD_PREMERGE=0), not computed:
#     195 of 219 suites are named by a pull_request-triggered workflow
#     PASS the ungated SET matches its pin exactly (24 suite(s))
#
# 195 -> 196 (denominator 219 -> 220) on 2026-10-07: re-measured on the merge of this
# branch with origin/main e14a94a7, which gained tests/scripts/test-edge-ai-ollama-pin.sh
# (gated, baseline 193 -> 194 on main) after the 195 above was measured. MEASURED by
# RUNNING this file on that merged tree (GUARD_PREMERGE=0), not computed:
#     196 of 220 suites are named by a pull_request-triggered workflow
#     PASS the ungated SET matches its pin exactly (24 suite(s))
#
# 196 -> 197 (denominator 220 -> 221) on 2026-10-14: re-measured on the LANDING merge
# of iss/582-per-domain-tor with origin/main c0c46601 (#708 landed after the branch's
# last merge). This value line CONFLICTED: main said 196 of 220 (the #659 / #663 /
# edge-ai-ollama-pin steps above, ungated SET 24) and the branch said 195 of 218
# (its own 193 -> 194 -> 195 steps for tests/scripts/test-gateway-vanity-domains.sh,
# written below, ungated SET 23). Main's block and its 24-entry PREMERGE_UNGATED are
# kept; the branch adds exactly one gated suite, tests/scripts/
# test-gateway-vanity-domains.sh (shell-suites.yml's extras job, helm). MEASURED by
# RUNNING this file on the merged tree (GUARD_PREMERGE=0), not computed:
#     197 of 221 suites are named by a pull_request-triggered workflow
#     PASS the ungated SET matches its pin exactly (24 suite(s))
#
# 197 -> 198 (denominator 221 -> 222) on 2026-10-14 for #629 (iss/629-tor-reconcile-
# apply-export-report-onions, from origin/main 702b590d): one new suite,
# tests/scripts/test-tor-export-sync.sh (the signed Tor export consumer + onion report),
# landed on disk in the same commit that wires it into shell-suites.yml's alpine job
# (beside tests/scripts/test-tor-node-contract.sh, which pins its wiring). MEASURED by
# RUNNING this file on the tree with the suite wired (GUARD_PREMERGE=0), not computed:
#     198 of 222 suites are named by a pull_request-triggered workflow
#     PASS the ungated SET matches its pin exactly (24 suite(s))
# 198 of 224 -> 198 of 225 and ungated SET 26 -> 27 on 2026-10-14 for the 13a cut-over
# matrix (origin/main e3e95369 measures 224 / 26 when run; the 222 / 24 above is the figure
# at #629's own merge): tests/scripts/test-optional-services-cutover-matrix.sh
# is a new suite that is NOT named by a pull_request workflow (it is wired post-merge by .gitlab-ci.yml and
# recorded in PREMERGE_UNGATED above), so the denominator rose and the gated count did
# not. MEASURED by RUNNING this file on the merge with e3e95369 (GUARD_PREMERGE=0), not computed:
#     198 of 225 suites are named by a pull_request-triggered workflow
#     PASS the ungated SET matches its pin exactly (27 suite(s))
# Re-measured on the merge with origin/main fc498f8a (GUARD_PREMERGE=0), after other suites
# landed on main: 198 of 230 suites are named by a pull_request-triggered workflow, and
# the ungated SET matches its pin exactly (32 suite(s)). The baseline 198 is unchanged.
# tests/scripts/run-ungated-lane.sh's header counts (32 of 32, 8 of 32) were taken from
# its E2E_UNGATED_DRY_RUN=1 output for both sets. The "stays 21/22" lines in the entries
# above are history and are left as written.
PREMERGE_BASELINE="${GUARD_PREMERGE:-198}"

# 182 -> 192 (denominator 205 -> 215) on 2026-09-30 for #385: the census gained a
# THIRD spelling, bare `tests/*.sh` at depth 1, and the ten suites it exposed were
# wired into shell-suites.yml's alpine job. MEASURED by RUNNING this file on the
# tree, not computed, at each step:
#     census widened, ten suites unwired   182 of 215   (+ checks 3 and 7 red,
#                                                        naming all ten)
#     ten suites wired                     192 of 215
# The ungated SET pin is unchanged at 23: none of the ten is in PREMERGE_UNGATED.
# tests/e2e-extra-personas.sh is NOT counted: it is a sourced data library named
# in NOT_SUITES, verified to be sourced.
#
# 193 -> 194 (denominator 216 -> 217) on 2026-10-07 for #582 (iss/582-per-domain-tor,
# merged onto origin/main f4a6a899, which carried the 193 above for #663; this branch
# had earlier written the same 192 -> 193 step for its own suite against 20178822,
# before #663 landed on main, so the two met in a merge conflict on this line and
# the branch's step is re-measured here on top of main's): one new suite, wired into
# shell-suites.yml's extras job (helm): tests/scripts/test-gateway-vanity-domains.sh
# — the fe-gateway's vanity-subdomain route and Ingress hosts per brand domain,
# rendered with a real `helm template`. MEASURED by RUNNING this file on the merged
# tree (GUARD_PREMERGE=0), not computed:
#     194 of 217 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 23 — the new suite was never in it.
#
# 194 -> 195 (denominator 217 -> 218) on 2026-10-07, the merge of origin/main
# e14a94a7 into iss/582-per-domain-tor. Main and this branch had EACH raised the value
# line above from 193 to 194, for a different new suite, so git merged the identical
# one-line edit with no conflict and the file said 194 for a tree that now holds two
# new suites: main's tests/scripts/test-edge-ai-ollama-pin.sh and this branch's
# tests/scripts/test-gateway-vanity-domains.sh. Each side measured green alone
# (194 of 217); the merged tree printed
#     FAIL pre-merge suite coverage rose to 195, baseline still says 194
# MEASURED by RUNNING this file on the merged tree (GUARD_PREMERGE=0), not computed:
#     195 of 218 suites are named by a pull_request-triggered workflow
# The ungated SET pin is unchanged at 23 — neither suite was ever in it. A merge that
# lands another suite after this one must re-measure again: a silent clean merge of
# this line is exactly how the number went stale.

# 164 -> 165 on 2026-09-16: tests/scripts/test-argocd-serverside-diff.sh joined the
# gate with the harbor Server-Side Diff annotation (hugmesh-generator#354). MEASURED
# by RUNNING this file both ways on the same tree, not assumed:
#     165 of 187 suites are named by a pull_request-triggered workflow   (with it)
#     164 of 186 suites are named by a pull_request-triggered workflow   (without)
# — "without" meaning the suite file deleted AND both its wirings removed, so the
# denominator moves too. It is named in shell-suites.yml's DEBIAN job (python:3.12-
# slim): it is a negative guard whose controls must fail on a planted defect, and
# busybox grep/sed is where a negative guard fails open. The ungated SET pin is
# unchanged at 22 in both measurements.
#
# 163 -> 164 on 2026-09-16, on the MERGE of decisions/20260910/generator with
# main at 8f355e41 (hugmesh-generator#246). One suite was ADDED AND GATED:
# tests/scripts/test-run-ungated-lane.sh, the stub-and-mutation pin for the
# `make e2e-ungated` runner (tests/scripts/run-ungated-lane.sh, which is a
# run-*.sh and so is NOT counted here). Named in shell-suites.yml's DEBIAN job
# (the runner uses `grep -a`, which busybox grep in the alpine job lacks). It
# was RUN in python:3.12-slim — that job's own image, checkout mounted
# read-only, --network=none — and printed 75 passed / 0 failed rc=0 with its
# seven runner mutations 7 caught / 0 survived. This value line CONFLICTED on
# merge (the branch had measured 161 -> 162 against main at ad06fce0; main had
# since gained #322's and #268's suites, 161 -> 163); per the doctrine above the
# number was taken by RUNNING this file on THIS merged tree, which printed
#     164 of 186 suites are named by a pull_request-triggered workflow
# and the ungated SET is unchanged at 22.
#
# 167 -> 168 on 2026-09-16: tests/scripts/test-x86-prefetch-gate.sh joined the gate
# with the payload PRE-FETCH pass (scripts/_emerge-prefetch-lib.sh + its call in
# build-x86-host-stage4.sh) -- hugmesh-generator#322 slice 2, decision 24 on #347.
# MEASURED on THIS tree, not assumed: with the suite named in shell-suites.yml's
# alpine job this file printed
#     168 of 190 suites are named by a pull_request-triggered workflow
# and '167 of 190' with that one line deleted from the workflow and nothing else
# changed; the ungated SET pin is unchanged at 22.

# 162 -> 163 on 2026-09-16: tests/scripts/test-docs-command-coverage.sh joined the
# gate -- every user-facing scripts/ command must be reachable from docs/ or a
# README (hugmesh-generator#268). MEASURED: '163 of 185 suites are named by a
# pull_request-triggered workflow' with it named in shell-suites.yml's debian job,
# '162 of 184' without; the ungated SET pin is unchanged at 22.

# 161 -> 162 on 2026-09-16: tests/scripts/test-x86-fetchcommand-bound.sh joined the
# gate with the curl FETCHCOMMAND/RESUMECOMMAND rate floor in
# specs-x86/portage/make.conf.tmpl (hugmesh-generator#322). MEASURED, not assumed:
# with the suite named in shell-suites.yml's alpine job this file printed
#     162 of 184 suites are named by a pull_request-triggered workflow
# and '161 of 183' without it; the ungated SET pin is unchanged at 22.

# 160 -> 161 on 2026-09-10: tests/scripts/test-kind-doctor.sh joined the gate
# with scripts/kind-doctor.sh (hugmesh-generator#349). MEASURED, not assumed:
# the analyser printed '161 of 183 suites' with the new suite wired and '160 of
# 182' without it, and the ungated SET pin is unchanged at 22.
#

# ── WHICH suites are ungated, not merely HOW MANY ────────────────────────────
# PREMERGE_BASELINE alone pins a CARDINALITY, and a cardinality is blind to a
# one-for-one swap. MEASURED on this repo (2026-08-26, an adversarial review's
# reproduction, re-run here before this block existed): delete
# `tests/stack/test-tls-front.sh` from .github/workflows/shell-suites.yml and add
# one new wired suite in the SAME edit, and the analyser printed
#     125 of 135 suites are named by a pull_request-triggered workflow
#     PASS pre-merge suite coverage pinned at 125/135
# rc=0, fully green. A suite that used to block a bad merge no longer did, and the
# guard whose failure message exists to say exactly that said nothing. Check 3 was
# silent too, because test-tls-front.sh is still named in .gitlab-ci.yml.
#
# So pin the SET. This list is the COMPLEMENT — the suites that are NOT named by
# any pull_request workflow. The complement is pinned rather than the 125 gated
# paths for two reasons: it is nine lines instead of a hundred and twenty-five,
# and it only changes when someone lands a suite the pre-merge gate does not run,
# which is precisely the event that wants a human to look. It is exactly as
# strong: `gated = suites - ungated`, so pinning `len(gated)` (above) AND this
# complement determines the gated set element by element, and determines the
# denominator too (total == n + len(ungated), by construction).
#
# Delisting a gated suite now NAMES it, whatever else lands in the same commit.
#
# MEASURED, never hand-written: run this file and read the "ungated:" lines it
# prints on mismatch, or `GUARD_PREMERGE_UNGATED=x bash tests/scripts/test-guard-integrity.sh`
# to have it print the whole corrected list. Nothing is exempted by being here —
# an entry is a statement that the suite does not gate a PR, not permission.
#
# THE NINE test-e2e-* ENTRIES (added 2026-08-26 at the gherkin/e2e integration).
# Every one of them is RUN — the Makefile's stack-e2e-bdd-check / -guards /
# e2e-reporter-check targets invoke all nine, which is why check 3 above is green
# — but a make target gates nothing, so they belong here and the reason is stated
# per suite rather than as a shrug.
#
# EIGHT of the nine REFUSE TO RUN without tests/e2e/node_modules/playwright-bdd
# and a Playwright browser: they exit 2 with "SKIPPED-LOUDLY ... this guard
# checked NOTHING" rather than 0. MEASURED, not read: each was executed on this
# tree with tests/e2e/node_modules moved aside and each exited 2 — which was true
# of only seven of them when the measurement started: test-e2e-func-media-games.sh
# had no such preflight and exited 1, indistinguishable from a real drift finding,
# so it was given the block its eight siblings already carried. No image the
# shell-suites workflow runs carries that install — alpine:3, python:3.12-slim
# (x2) and node:24-alpine — and THREE of the eight additionally build the REAL
# PyQt wizard offscreen and need a Qt6 binding (the three marked '+ Qt6' below). Listing them would gate a job
# that can only ever skip, which is the failure mode
# .github/workflows/shell-suites.yml's header describes at length.
#
#   test-e2e-cli-lane.sh                 needs node_modules + a chromium
#   test-e2e-coverage-matrix.sh          needs node_modules + a chromium
#   test-e2e-env-interface-dimensions.sh needs node_modules + chromium + Qt6
#   test-e2e-func-media-games.sh         needs node_modules + chromium + Qt6
#   test-e2e-gherkin-harness.sh          needs node_modules + a chromium
#   test-e2e-governance-function-matrix.sh needs node_modules + a chromium
#   test-e2e-social-function-matrix.sh   needs node_modules + a chromium
#   test-e2e-studio-gui-lane.sh          needs node_modules + chromium + Qt6
#
# THE NINTH WAS DIFFERENT, AND IS NOW WIRED. tests/scripts/test-e2e-reporter-shape.sh
# needs NOTHING but node >= 23.6 and python3 -- its own header says "OFFLINE, NO
# STACK, NO ROOT, NO node_modules". The session that merged the gherkin lanes
# recorded it here instead of gating it because it could not run containers to
# measure it, and named the follow-up out loud rather than dressing it up as an
# exemption. THAT FOLLOW-UP IS NOW DONE: MEASURED in node:24-alpine under that
# job's own apk set, with tests/e2e/node_modules absent from the tree entirely
# rather than merely moved aside -- 30 passed, 0 failed, rc=0 -- and added to that
# job's SUITES list. Nothing about the other eight changed; they still need a
# node_modules and a chromium no shell-suites image carries.
PREMERGE_UNGATED=(
  # Lands outside the pull_request gate ONLY because wiring it there means an edit under
  # .github/workflows/shell-suites.yml, which the change that added it (#368) was not
  # permitted to make. It is NOT an exemption on the merits: it needs bash, python3 and
  # ssh-keygen, no root and no network, and runs the real docker/build-image.sh against
  # fake builders. It was MEASURED only on a developer host, NOT in a shell-suites image
  # (ssh-keygen may be absent from the python:3.12-slim job). It also runs inside
  # `make matrix-check` as a non-gating smoke and as `make build-image-dial-identity-check`.
  # Wire it into shell-suites.yml, measure it there, DELETE this entry and raise
  # PREMERGE_BASELINE by one.
  tests/build-image-dial-identity.sh
  tests/casdoor/test-jwt-custom-token.sh
  # NOT an exemption, a wiring gap: this suite is offline (bash + python3 + PyYAML)
  # and WOULD run in the shell-suites image, but wiring it into
  # .github/workflows/shell-suites.yml is an edit the author of this suite was not
  # permitted to make. It is gated post-merge today by .gitlab-ci.yml's
  # desktop-governance-verify. TO CLOSE THIS: add the path to the SUITES list in
  # shell-suites.yml (with py3-yaml in that job's apk set), delete this entry and
  # raise PREMERGE_BASELINE by one to the number this file then prints.
  tests/desktop-governance/test-governance-flags-visible.sh
  # NOT a claim that it cannot gate: it needs only bash + python3 + openssl, the
  # tool set its three siblings in tests/desktop-governance/ already run under in
  # shell-suites.yml. It is listed solely because the change that added it could
  # not edit .github/workflows/shell-suites.yml. It IS run post-merge, by
  # .gitlab-ci.yml's desktop-governance-verify. WIRE IT into that SUITES list, then
  # delete this entry and raise PREMERGE_BASELINE by one.
  tests/desktop-governance/test-sso-token-producer.sh
  tests/device-registry/test-layer-a-headscale-acl.sh
  tests/egress-vpn/test-secret-contract.sh
  # Offline, bash + python3 only, 48 passed / 0 failed on 2026-10-14 (#654 D12:
  # the driver refuses `commit` for a Tor address; its three-mutation battery is
  # inside). It belongs in shell-suites.yml's ALPINE job beside
  # tests/go-live/test-go-live-driver.sh, and .gitlab-ci.yml's
  # orphan-guards-verify already runs it post-merge. Listed here, not gated,
  # only because the lane that added it may not edit .github/: the operator adds
  # the one line there, raises PREMERGE_BASELINE by one and drops this entry.
  tests/go-live/test-onion-refuse.sh
  tests/pentest/nuclei/test-templates.sh
  # NOT UNGATEABLE, JUST NOT GATED YET: python3 + bash over synthetic fixture logs, no
  # network, no root, no docker -- it would run in any shell-suites image. It sits
  # here only because naming it in shell-suites.yml is an edit under .github/, which
  # the change that added it was not allowed to make. THE FOLLOW-UP IS TO ADD IT TO
  # THAT WORKFLOW'S SUITES LIST, DELETE THIS ENTRY AND RAISE PREMERGE_BASELINE BY ONE. It is
  # run today by `make binpkg-reuse-report-check`.
  tests/scripts/test-binpkg-reuse-report.sh
  # NOT an exemption, a wiring gap: the lane that added this suite (#509) may not
  # edit .github/. It runs every stage4 builder with --print-plan and needs only
  # bash, sed, paste and timeout, but is UNMEASURED in the shell-suites images
  # (ALPINE/python:3.12-slim), so check that before gating it. The operator adds the
  # one line to shell-suites.yml, raises PREMERGE_BASELINE by one and drops this
  # entry. .gitlab-ci.yml's lint:domain-idp-flag runs it post-merge meanwhile.
  tests/scripts/test-domain-idp-flag.sh
  # Needs `unshare -Urm` (a private user+mount namespace) to stack REAL bind
  # mounts under a scratch build system and drive the x86 builder's own
  # umount_chroot, stale-mount listing and printed umount commands against the
  # kernel, through eight spellings of the build system's path (#659). Docker's
  # default seccomp profile blocks those namespaces, so in every shell-suites
  # image it exits 2 SKIPPED-LOUDLY having run ZERO assertions — MEASURED in
  # alpine:3 with that job's apk set before it was listed here. Gating it would
  # raise the coverage number by one and gate nothing. `make
  # builder-unmount-real-check` runs it on a developer host (16 passed there,
  # 2026-09-30); the same code paths are proven against a fixture table,
  # pre-merge, by tests/scripts/test-builder-resume-safety.sh.
  tests/scripts/test-builder-unmount-real.sh
  # NOT YET IN THE PULL_REQUEST GATE, and that is the only reason it is here: it is
  # offline, PyYAML-only, ~12 s, and belongs beside test-db-connection-budget.sh in
  # shell-suites.yml's debian job. The lane that wrote it (hugmesh-generator#693,
  # 2026-10-07) was forbidden to edit anything under .github, so until that one
  # line lands it runs post-merge in .gitlab-ci.yml's lint:bff-jwks-in-cluster and
  # locally under `make e2e-ungated`. When the line lands: delete this entry and
  # raise PREMERGE_BASELINE 196 -> 197 (check 7 will say so).
  tests/scripts/test-bff-jwks-in-cluster.sh
  tests/scripts/test-e2e-cli-lane.sh
  tests/scripts/test-e2e-coverage-matrix.sh
  tests/scripts/test-e2e-env-interface-dimensions.sh
  tests/scripts/test-e2e-func-media-games.sh
  tests/scripts/test-e2e-gherkin-harness.sh
  tests/scripts/test-e2e-governance-function-matrix.sh
  tests/scripts/test-e2e-social-function-matrix.sh
  tests/scripts/test-e2e-studio-gui-lane.sh
  tests/scripts/test-eso-target-collisions.sh
  # LIVE-CLUSTER ONLY, and MEASURED in the shell-suites job image before being
  # listed here: alpine:3 + that job's apk set prints "SKIP kubectl is not on PATH"
  # and exits 0 having run ZERO assertions. Gating it would raise the coverage
  # number by one and gate nothing. Not a claim that it passes — on a box with a
  # kind cluster up but no metrics-server synced it goes RED with 2 failures.
  # See the "NOT LISTED HERE" entry in .github/workflows/shell-suites.yml.
  tests/scripts/test-kind-metrics-api.sh
  # Pure offline derivation (python3 + PyYAML + bash), wired post-merge by .gitlab-ci.yml's
  # lint:optional-services-cutover-matrix. It is NOT in the pull_request gate only because
  # adding it to .github/workflows/shell-suites.yml is an edit that PR did not make; gate it
  # there (the job image needs PyYAML) and delete this entry.
  tests/scripts/test-optional-services-cutover-matrix.sh
  tests/scripts/test-federation-module-slugs.sh
  tests/scripts/test-liquibase-grant-roles.sh
  # RED ON MAIN, and the reds are real defects rather than suite bugs: a jetson
  # builder that bakes the cluster tree without resolving the gate at all, two
  # selection-rendered artefacts the boot path still sources from git, a git
  # baseline that ships three services ON, the reconciler master switch
  # deliberately off pending the hardcoded-app cut-over, and a missing ArgoCD
  # resources-finalizer — A4 B2 B3 C5b C7. (Its C8 leg was ALSO red under the
  # entry written on 2026-08-26; that text was stale. hugmesh-admin-bff-api PR #43
  # merged 2026-08-27 07:04 UTC, the handler is on that repo's main, and C8
  # measures green. It had been reading a working tree 9 commits behind its own
  # origin/main.) Gating a red suite in the pull_request workflow blocks every PR
  # in the repo, so it is gated post-merge by .gitlab-ci.yml's
  # lint:selected-services-only-chain instead. It ALSO needs the
  # hugmesh-admin-bff-api checkout for its C8 leg and reports UNVERIFIED + exits 3
  # without it, which a hosted runner cannot satisfy. Not an exemption: EACH of the
  # five reds has a control that plants the fix and requires it to go green
  # (A4 NC10e, B2 NC21, B3 NC22, C5b NC23, C7 NC14).
  tests/scripts/test-selected-services-only.sh
  # RED ON MAIN on real cross-repo defects (re-measured 2026-09-23, #584):
  # meshbridge is in the generator's CRD enum + seed CRs while the controller's
  # OptionalServiceRegistry keeps it NOT_TOGGLEABLE for a reason (NOT_IN_CRD_ENUM)
  # that has been false since 2026-08-26, and character-forge's selfHeal flag is
  # stale — both filed as hugmesh-admin-bff-api#106; control 20 plants that fix and
  # goes green. The text that stood here until 2026-09-23 gave only the checkout
  # reason and HID a dead parser: the gate had exited 3 INCOMPLETE on every run
  # since admin-bff b8ed324 widened the Java Entry record from 3 to 5 fields, 23
  # minutes after the checker landed, and nothing moved its regex with it. That
  # parser is now pinned by a fixture self-test (section P) that needs no checkout.
  # It STILL needs the hugmesh-admin-bff-api checkout for its fifth surface, which a
  # hosted pre-merge runner cannot clone. Its only automated runner is
  # .gitlab-ci.yml's lint:optional-service-slug-closure — nothing on the GitHub side
  # runs it; `make e2e-ungated` runs it locally. Leave it listed until #106 lands.
  tests/scripts/test-optional-service-slug-closure.sh
  # Lands outside the pull_request gate ONLY because wiring it there means an edit
  # under .github/workflows/shell-suites.yml, which the change that added it was
  # not permitted to make (operator action, 2026-10-14). It is NOT an exemption on
  # the merits: both suites are offline (python3 + openssl + bash; the netpol one also
  # takes kubectl when present). They were MEASURED only on a developer host, NOT in a
  # shell-suites image, and are run post-merge by .gitlab-ci.yml's lint:pg-tls-preflight
  # and lint:netpol-egress-scope. Wire both into shell-suites.yml's DEBIAN job, measure
  # them there, and DELETE both entries (PREMERGE_BASELINE then moves 198 -> 200). Added
  # ungated: denominator +2 and the ungated SET +2, baseline unchanged at 198
  # (RE-MEASURED on this branch merged with origin/main 9b1b733c, GUARD_PREMERGE=0: this
  # file prints "198 of 228" and "(30 suite(s))").
  tests/scripts/test-netpol-egress-scope.sh
  tests/scripts/test-pg-tls-preflight.sh
  tests/scripts/test-service-env-contract.sh
  # Lands outside the pull_request gate for the reason given above
  # tests/scripts/test-netpol-egress-scope.sh and tests/scripts/test-pg-tls-preflight.sh:
  # wiring it there is an edit under .github/workflows/shell-suites.yml, which the
  # change that added it was not permitted to make. It is offline (python3 with PyYAML
  # and tomllib, bash; kubectl optional) and is run post-merge by .gitlab-ci.yml's
  # lint:tuwunel-instance-block-sync. Wire it into shell-suites.yml and DELETE this
  # entry (PREMERGE_BASELINE then moves 198 -> 199).
  tests/scripts/test-tuwunel-instance-block-sync.sh
  tests/stack/test-gateway-auth-flag-parity.sh
  tests/stack/test-m2-bootstrap.sh
  # Needs a host tor binary and the PUBLIC Tor network for minutes (it mints a real
  # v3 onion and fetches it back over Tor); no shell-suites image carries tor.
  # Without them it exits 2 SKIPPED-LOUDLY, never 0. Run it with
  # `make stack-tor-mechanism-check`. Its own exit-code contract IS gated: T14 of
  # tests/stack/test-tor-flip-wiring.sh drives it against stub harnesses (#585).
  tests/stack/test-tor-onion-mechanism.sh
  tests/stack/test-web-locales-wiring.sh
)
if [ -n "${GUARD_PREMERGE_UNGATED+x}" ]; then UNGATED_TEXT="${GUARD_PREMERGE_UNGATED}"
else UNGATED_TEXT="$(printf '%s\n' "${PREMERGE_UNGATED[@]}")"; fi

echo "== guard integrity: every guard can fail, and something runs it =="

REPO="${GUARD_ROOT}" ALLOW_UNWIRED="${ALLOW_TEXT}" PREMERGE_BASELINE="${PREMERGE_BASELINE}" PREMERGE_UNGATED="${UNGATED_TEXT}" python3 - <<'PY'
import os, re, sys

repo = os.environ["REPO"]
allow = {}
for line in os.environ["ALLOW_UNWIRED"].splitlines():
    line = line.strip()
    if not line:
        continue
    path, _, reason = line.partition("|")
    allow[path] = reason

P = [0]; F = [0]
def ok(m):  print("  PASS " + m); P[0] += 1
def bad(m): print("  FAIL " + m); F[0] += 1

# ── collect the suites ───────────────────────────────────────────────────────
# TWO NAMING CONVENTIONS, and for months this walker only knew one.
#
# WHAT WAS OBSERVED (2026-08-26). Check 7 printed "117 of 126 suites are named by
# a pull_request-triggered workflow" and passed. Both numbers were computed from a
# walk that matched `test-*.sh` ONLY. tests/qemu/ and tests/menu/ use the OTHER
# convention this repo writes, `*_test.sh`, and every file with that name was
# outside the census entirely: not counted in the 126, not eligible to be counted
# in the 117, and — because checks 1, 2, 3 and 7 iterate THIS list — not analysed
# by any of those four either. Eight suites were in that hole, among them
# tests/qemu/verdict_test.sh, which exists specifically to stop the harness
# reporting false PASSes and was itself gating nothing.
#
# WHICH CHECKS THE CENSUS ACTUALLY FEEDS — MEASURED, and narrower than the first
# version of this comment claimed. That version said checks 1/2/3/6/8 iterate this
# list; an adversarial review disproved it, and re-running the PRE-change file and
# the POST-change file against this same repo confirms the correction:
#
#   checks 1, 2, 3, 7  iterate `suites`. These four, and only these four, are what
#                      widening the census extended. 126 -> 134 suites analysed.
#
#   check 6            does NOT. Its per-suite silent-skip analysis iterates
#                      `batch`, which is built from .gitlab-ci.yml alone (the
#                      re.finditer over `ci` in check 6 below). Batch-run suites:
#                      40 BEFORE, 40 AFTER — unchanged. None of the eight is in
#                      any SUITES= list: seven appear in no GitLab job at all, and
#                      mesh-cluster_test.sh appears only as a bare
#                      `- bash tests/qemu/mesh-cluster_test.sh` script line
#                      (.gitlab-ci.yml:578), which is not a batch list. The eight
#                      are gated in GitHub Actions and check 6 keys on GitLab, so
#                      they were outside check 6 before this change and STILL ARE.
#                      Check 6's section touches `suites` in exactly one place —
#                      the tail guard asking whether ANY suite calls
#                      guard_require_*, which only decides whether the
#                      guard-preflight.sh check runs — not in the silent-skip
#                      analysis, which is the part that matters.
#                      Consequence worth stating plainly: check 6 IS the
#                      silent-skip guard, and this change's own headline finding
#                      (ncurses_charset_test.sh recording 20 passed / 0 failed on
#                      busybox grep while a real regression was planted) is a
#                      textbook check-6 defect that check 6 did not and cannot
#                      report. It was found BY HAND. The route around it is the
#                      node job's `grep -P` preflight, not this walker.
#
#   check 8            never used the census at all. It runs its OWN os.walk over
#                      tests/ AND scripts/ for every *.sh (see check 8 below), so
#                      the eight were always inside it: 250 .sh files scanned
#                      BEFORE, 250 AFTER — unchanged.
#
# This is the identical "in NEITHER place" defect the 2026-08-22 sweep closed for
# test-*.sh (see the header of .github/workflows/shell-suites.yml). It reopened
# purely through a naming difference, which is the argument for matching on BOTH
# spellings here rather than on the one that happened to be typed first.
#
# Matching is deliberately broad: `test-*.sh` OR `*_test.sh`. A third convention
# would slip through again, so the rule to keep is "add the spelling here the day
# someone introduces it", and the negative control (j) below is what proves this
# walker actually reaches the second one.
#
# THE THIRD SPELLING (#385): a suite sitting DIRECTLY in tests/ with a bare name
# (tests/posix-sh-no-arrays.sh, tests/build-image-idp.sh ...). Ten of them matched
# neither rule, so they were outside check 7's numerator AND denominator and ran in
# no CI job; seven were reachable only through `make matrix-check`, which no CI file
# invokes. Depth is what identifies them — every file at tests/*.sh is a suite
# EXCEPT the named, verified non-suites in NOT_SUITES below.
#
# NOT_SUITES is a NAMED exemption, not a filter: each entry must be a sourced
# library (nothing executes it as a test) and is verified to still be sourced by
# something, so a stale entry — or a real suite renamed into it — cannot hide.
NOT_SUITES = {
    # Data library: defines the e2e persona list that seed-e2e.sh and
    # bootstrap-kind.sh `source`. It runs no assertion.
    "tests/e2e-extra-personas.sh",
}
suites = []
for root, dirs, files in os.walk(os.path.join(repo, "tests")):
    dirs[:] = [d for d in dirs if d not in (".git", "node_modules")]
    for fn in files:
        if not fn.endswith(".sh"):
            continue
        rel = os.path.relpath(os.path.join(root, fn), repo)
        if rel in NOT_SUITES:
            continue
        top_level = os.path.dirname(rel) == "tests"
        if fn.startswith("test-") or fn.endswith("_test.sh") or top_level:
            suites.append(rel)
suites.sort()

import re as _re
for _ns in sorted(NOT_SUITES):
    _base = os.path.basename(_ns)
    _sourced = False
    for _r, _d, _f in os.walk(repo):
        _d[:] = [d for d in _d if d not in (".git", "node_modules", ".stack-src")]
        for _fn in _f:
            if not _fn.endswith((".sh", ".bash", "Makefile")) and _fn != "Makefile":
                continue
            try:
                _txt = open(os.path.join(_r, _fn), errors="replace").read()
            except OSError:
                continue
            if _re.search(r"^\s*(\.|source)\s+[^#\n]*" + _re.escape(_base), _txt, _re.M):
                _sourced = True
                break
        if _sourced:
            break
    if not os.path.isfile(os.path.join(repo, _ns)):
        pass    # nothing on disk to hide; a stale entry is inert, not a hole
    elif not _sourced:
        bad("NOT_SUITES exempts %s as a sourced library, but nothing sources it — it is "
            "either dead or a real suite hiding behind an exemption" % _ns)

if not suites:
    bad("found ZERO test-*.sh / *_test.sh suites under tests/ — this guard would be vacuous")
    print()
    print("== guard integrity: %d passed, %d failed ==" % (P[0], F[0]))
    sys.exit(1)
_dash  = sum(1 for s in suites if os.path.basename(s).startswith("test-"))
_top   = sum(1 for s in suites if os.path.dirname(s) == "tests"
             and not os.path.basename(s).startswith("test-")
             and not os.path.basename(s).endswith("_test.sh"))
_under = len(suites) - _dash - _top
ok("enumerated %d suites under tests/ (%d test-*.sh + %d *_test.sh + %d bare tests/*.sh)"
   % (len(suites), _dash, _under, _top))

# ── "what is the last thing this script actually runs?" ──────────────────────
# Read BACKWARD from EOF. A forward heredoc-state machine is the obvious design
# and it is wrong here: these suites embed awk and python programs, and a `<<`
# inside a quoted awk regex (`/<<CHROOT/`), a `<<'"'"'PY'"'"'` opener, or a `<<<`
# herestring all fool a regex scanner into thinking a heredoc opened and never
# closed — after which it swallows the rest of the file, including the verdict it
# came to inspect. Backward is exact for the only question asked: valid bash
# cannot end INSIDE a heredoc body, so the last non-blank/non-comment line is
# either the final statement or a heredoc TERMINATOR, and the terminator case is
# decidable by looking for its opener.
HEREDOC_OPEN = r"(?<!<)<<(?!<)-?\s*['\"]?%s['\"]?\s*$"
SET_E        = re.compile(r"^set\s+-[a-zA-Z]*e")   # column 0: the repo's convention
BAREWORD     = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

def last_statement(text):
    """(lineno, source) of the last line bash executes, or None."""
    lines = text.split("\n")
    i = len(lines) - 1
    while i >= 0 and (not lines[i].strip() or lines[i].strip().startswith("#")):
        i -= 1
    if i < 0:
        return None
    s = lines[i].strip()
    if BAREWORD.match(s):
        # Could be a heredoc terminator (`PY`, `EOF`, …). If an opener exists
        # above it, the statement is the OPENER line, not the delimiter.
        pat = re.compile(HEREDOC_OPEN % re.escape(s))
        for j in range(i - 1, -1, -1):
            if pat.search(lines[j]):
                return (j + 1, lines[j].strip())
    return (i + 1, s)

def has_set_e(text):
    return any(SET_E.match(l) for l in text.split("\n"))

# The last SIMPLE command on a line decides the line's exit status: `echo x; exit 1`
# is honest, a bare `echo x` is not. Split on ';' only — '&&'/'||' chains still end
# on their last command, and `a && b` with b an echo is just as dishonest.
STATUS_BLIND = re.compile(r"^(echo|printf|:|true|cat)\b")

def last_command(line):
    parts = [p.strip() for p in line.split(";")]
    parts = [p for p in parts if p]
    return parts[-1] if parts else line

# ── 1) EXIT STATUS: no suite may end on a status-blind command without set -e ─
print()
print("-- 1) every suite's exit status carries its verdict --")
blind = []
for rel in suites:
    text = open(os.path.join(repo, rel), encoding="utf-8", errors="replace").read()
    st = last_statement(text)
    if st is None:
        blind.append((rel, 0, "<empty>", "no executable line at all"))
        continue
    lineno, line = st
    tail = last_command(line)
    if STATUS_BLIND.match(tail) and not has_set_e(text):
        blind.append((rel, lineno, tail, "ends on a status-blind command and does not `set -e`"))
if blind:
    bad("suite(s) whose exit status cannot express failure:")
    for rel, lineno, tail, why in blind:
        print("         %s:%d: %s  <- %s" % (rel, lineno, tail[:70], why))
else:
    ok("all %d suites end on a real verdict (or run under `set -e`)" % len(suites))

# ── 2) A FAILURE COUNTER MUST BE RE-RAISED ───────────────────────────────────
# The repo idiom is `F=0; bad(){ …; F=$((F+1)); }` closed by `[ "${F}" -eq 0 ]`.
# Counting failures and then exiting 0 anyway is the same defect wearing a
# different hat: the suite prints FAIL lines nobody's pipeline ever notices.
#
# Deliberately asks a WHOLE-FILE question ("does any expression turn this counter
# into an exit status?") rather than "is it in the last N lines". Position needs a
# parser to get right; existence does not, and a gate must not invent failures.
print()
print("-- 2) a suite that COUNTS failures must also RAISE them --")
FUNC  = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
INCR  = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=\$\(\(\s*\1\s*\+\s*1\s*\)\)")
FAILY = re.compile(r"^(bad|fail|failed|neg_bad|err|error|nope|ko)$", re.I)

def raises(text, var):
    v = re.escape(var)
    return re.search(
        r"(\[\[?\s*\"?\$\{?%s\}?\"?\s*-(eq|ne|gt|lt|ge|le)\b"    # [ "${F}" -eq 0 ]
        r"|exit\s+\"?\$\{?%s\}?"                                  # exit "${F}"
        # `return $(( fails > 0 ))` / `exit $(( F != 0 ))`: an arithmetic
        # expansion handed straight to return/exit IS the status. Omitting this
        # made the analyser red on tests/node-storage/test-bake-coverage.sh —
        # a guard-guard failing a guard that is in fact correct, which is the
        # "red for a reason that is not a defect" half of the same disease.
        r"|(return|exit)\s+\"?\$\(\([^)]*\b%s\b"
        r"|\(\(\s*%s\s*\)\))" % (v, v, v, v),                     # (( F ))
        text)

unraised = []
for rel in suites:
    text = open(os.path.join(repo, rel), encoding="utf-8", errors="replace").read()
    # NO `has_set_e` EXEMPTION. `set -e` aborts on a command that FAILS; it does
    # nothing at all for `bad(){ echo FAIL; F=$((F+1)); }`, which succeeds every
    # time it runs. A counting suite under `set -euo pipefail` that loses its
    # closing `[ "${F}" -eq 0 ]` therefore prints its FAIL lines and exits 0 — the
    # exact "dishonest exit status" this file's own header names, sailing straight
    # through the check meant to catch it. Found 2026-08-27 by mutating the new
    # tests/scripts/test-role-key-spelling.sh: replacing its final verdict with
    # `exit 0`, over a planted Makefile defect, left this analyser GREEN.
    pass
    counters, cur = set(), None
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith("#"):
            continue
        m = FUNC.match(line)
        if m:
            cur = m.group(1)
        if cur and FAILY.match(cur):
            for c in INCR.finditer(line):
                counters.add(c.group(1))
        if s.startswith("}"):
            cur = None
    missing = sorted(c for c in counters if not raises(text, c))
    if missing:
        unraised.append((rel, missing))
if unraised:
    bad("suite(s) that increment a failure counter nothing turns into an exit status:")
    for rel, counters in unraised:
        print("         %s: counter(s) %s counted but never raised" % (rel, ",".join(counters)))
else:
    ok("every failure counter feeds an exit-status expression")

# ── 3) WIRING: something must actually run each suite ────────────────────────
print()
print("-- 3) every suite is invoked by a pipeline job, a make target, or the gate --")
ci_path = os.path.join(repo, ".gitlab-ci.yml")
mk_path = os.path.join(repo, "Makefile")
ci = open(ci_path, encoding="utf-8", errors="replace").read() if os.path.isfile(ci_path) else ""
mk = open(mk_path, encoding="utf-8", errors="replace").read() if os.path.isfile(mk_path) else ""
if not ci:
    bad(".gitlab-ci.yml is missing or empty — wiring cannot be verified")
if not mk:
    bad("Makefile is missing or empty — wiring cannot be verified")
# The GitHub workflows count too. When this check was written they ran no shell
# suite at all, so "wired" could only mean GitLab or the Makefile; since the
# pre-merge gate exists, a suite it names is run by the STRONGEST runner of the
# three, and calling that "nothing runs it" is simply false.
#
# COMMENT LINES ARE STRIPPED, and that is not tidiness. shell-suites.yml carries
# a NOT-LISTED-HERE block that names, in prose, every suite it deliberately does
# NOT run. Matching raw file text would read those names as wiring and mark the
# deliberately-excluded suites as covered — the exact inversion this check exists
# to catch. (Check 7 strips comments for the same reason.)
gh_dir = os.path.join(repo, ".github", "workflows")
gh = ""
if os.path.isdir(gh_dir):
    for fn in sorted(os.listdir(gh_dir)):
        if fn.endswith((".yml", ".yaml")):
            t = open(os.path.join(gh_dir, fn), encoding="utf-8", errors="replace").read()
            gh += "\n".join(l for l in t.split("\n")
                            if not l.lstrip().startswith("#")) + "\n"
runners = ci + "\n" + mk + "\n" + gh

# A `bash <path>` mention, or a directory glob that sweeps the suite in.
def wired(rel):
    if rel in runners:
        return True
    glob = os.path.dirname(rel) + "/*.sh"
    return glob in runners

orphans  = [s for s in suites if not wired(s)]
unlisted = [s for s in orphans if s not in allow]
if unlisted:
    bad("suite(s) nothing runs — neither .gitlab-ci.yml nor the Makefile invokes them:")
    for s in unlisted:
        print("         %s" % s)
    print("         (wire them, or add them to ALLOW_UNWIRED with a reason)")
else:
    ok("all %d suites are invoked by a pipeline job, a make target or the pre-merge "
       "gate (%d allowlisted)" % (len(suites), len(allow)))

# ── 4) THE ALLOWLIST ITSELF MUST NOT ROT ─────────────────────────────────────
print()
print("-- 4) the ALLOW_UNWIRED allowlist stays honest --")
stale = [p for p in allow if not os.path.isfile(os.path.join(repo, p))]
nolonger = [p for p in allow if os.path.isfile(os.path.join(repo, p)) and wired(p)]
noreason = [p for p, r in allow.items() if len(r.strip()) < 20]
if stale:
    bad("ALLOW_UNWIRED names file(s) that do not exist: %s" % ", ".join(sorted(stale)))
else:
    ok("every allowlisted path exists")
if nolonger:
    bad("ALLOW_UNWIRED still exempts suite(s) that ARE wired now — drop them: %s"
        % ", ".join(sorted(nolonger)))
else:
    ok("no allowlist entry shadows a suite that is already wired")
if noreason:
    bad("ALLOW_UNWIRED entr(y/ies) carry no real reason: %s" % ", ".join(sorted(noreason)))
else:
    ok("every allowlist entry records why the suite is unrunnable in a verify job")

# ── 5) A CI LOOP OVER SUITES MUST ACCUMULATE ITS EXIT CODES ──────────────────
# `for t in …; do bash "$t"; done` exits with the LAST suite's status: every
# earlier failure is forgiven. Any loop in .gitlab-ci.yml that runs tests/ files
# must either accumulate an rc or abort on the first failure.
print()
print("-- 5) CI loops over suites do not swallow failures --")
# Match on the loop VARIABLE being handed to bash, not on the word "tests/"
# appearing in the `for` header: an explicit suite list is usually built in a
# variable above the loop (`for t in ${SUITES}`), and a header-only match would
# skip exactly those jobs.
loops = []
lines = ci.split("\n")
for i, line in enumerate(lines):
    m = re.search(r"^\s*for\s+(\w+)\s+in\s+", line)
    if not m:
        continue
    var = m.group(1)
    body = []
    for j in range(i, min(i + 20, len(lines))):
        body.append(lines[j])
        if re.match(r"^\s*done\b", lines[j]):
            break
    text = "\n".join(body)
    runs_suite = re.search(r"bash\s+\"?\$\{?%s\}?\"?" % re.escape(var), text) \
                 or re.search(r"tests/\S*\.sh", line)
    if runs_suite:
        loops.append((i + 1, text))
if not loops:
    ok("no shell loop in .gitlab-ci.yml iterates suites (nothing to swallow)")
else:
    swallowing = []
    for lineno, body in loops:
        # honest shapes: `|| rc=1` / `|| { rc=1; … }` (+ a later `exit "${rc}"`),
        # or `|| exit` (abort on the first failing suite).
        accumulates = re.search(r"\|\|\s*\{?\s*(rc|RC|fail|FAIL|failed|status)\s*=", body)
        aborts      = re.search(r"\|\|\s*exit\b", body)
        if not (accumulates or aborts):
            swallowing.append((lineno, body.strip().split("\n")[0].strip()))
    if swallowing:
        bad("CI loop(s) over tests/ suites that discard a failing suite's status:")
        for lineno, first in swallowing:
            print("         .gitlab-ci.yml:%d: %s" % (lineno, first[:80]))
    else:
        ok("all %d CI loop(s) over tests/ suites accumulate or abort on failure" % len(loops))

# ── 6) A SUITE A CI BATCH JOB RUNS MAY NOT SKIP ITSELF ───────────────────────
# The FOURTH shape of "this guard cannot fail", and the one that shipped inside
# the very job that was supposed to end the disease. orphan-guards-verify ran on
# `alpine:3`, which has no JDK, so the three tests/keystores suites hit
#     for t in openssl keytool python3; do
#       command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done
# and reported green while checking nothing — and the fourth keytool consumer,
# test-headscale-oidc-secret-staging.sh, went hard RED for the same missing
# binary. On a workstation `SKIP … exit 0` is honest; in a CI job the image
# decides which tools exist, so it silently converts "this runner is
# under-provisioned" into "the property holds".
#
# The rule, mechanical: any suite named in a `SUITES="…"` batch list in
# .gitlab-ci.yml must be fail-closed on tooling. Adding a suite to such a job
# enrols it automatically — there is no registry to forget to update.
print()
print("-- 6) suites a CI batch job runs cannot silently skip themselves --")
OPT_OUT = "GUARD_TOOLING_ALLOW_SKIP"
LIB_REL = "tests/lib/guard-preflight.sh"

# Any shell variable in the CI file whose body is nothing but tests/… .sh paths
# IS a batch list, whatever it is called. Keying on the literal name `SUITES`
# would let the next job named LEGS= or GUARDS= walk straight out of this check.
batch = []
for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_]*)="\s*\n(.*?)\n\s*"', ci, re.S):
    entries = [l.strip() for l in m.group(2).splitlines() if l.strip()]
    if entries and all(e.startswith("tests/") and e.endswith(".sh") for e in entries):
        batch.extend(entries)
batch = sorted(set(batch))

SKIPWORD = re.compile(r"SKIP", re.I)
PROBE    = re.compile(r"command -v\b")

def silent_skips(text):
    """(lineno, source) for every `exit 0` reachable from a tooling/SKIP probe.

    Looks BACKWARD three non-blank/non-comment lines as well as at the line
    itself, so the two-line shape
        echo "SKIP: need bash >= 4.4"
        exit 0
    is caught as surely as the one-liner. Everything named here is a place the
    suite hands back exit 0 without having checked what it exists to check."""
    found = []
    ls = text.split("\n")
    for i, l in enumerate(ls):
        s = l.strip()
        if s.startswith("#") or not re.search(r"\bexit\s+0\b", s):
            continue
        ctx, j, back = [s], i - 1, 0
        while j >= 0 and back < 3:
            p = ls[j].strip()
            if p and not p.startswith("#"):
                ctx.append(p)
                back += 1
            j -= 1
        joined = "\n".join(ctx)
        if SKIPWORD.search(joined) or PROBE.search(joined):
            found.append((i + 1, s))
    return found

if not batch:
    ok("no .gitlab-ci.yml job runs a SUITES batch list (nothing to check here)")
else:
    offenders = []
    unsourced = []
    for rel in batch:
        path = os.path.join(repo, rel)
        if not os.path.isfile(path):
            bad("SUITES batch list names a file that does not exist: %s" % rel)
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        for lineno, src in silent_skips(text):
            offenders.append((rel, lineno, src))
        # A helper call that was never sourced is worse than the skip it replaced:
        # `guard_require_tools` would be a 127 command-not-found and, with no
        # `set -e`, the suite would sail straight past its own preflight.
        if re.search(r"\bguard_require_(tools|capability)\b", text) \
           and "guard-preflight.sh" not in text.replace("guard_require", ""):
            unsourced.append(rel)
    if offenders:
        bad("suite(s) a CI batch job runs that hand back exit 0 instead of a verdict:")
        for rel, lineno, src in offenders:
            print("         %s:%d: %s" % (rel, lineno, src[:78]))
        print("         (use tests/lib/guard-preflight.sh: guard_require_tools / "
              "guard_require_capability)")
    else:
        ok("all %d batch-run suite(s) are fail-closed on tooling — none can exit 0 unchecked"
           % len(batch))
    if unsourced:
        bad("suite(s) calling guard_require_* without sourcing %s (127 would be ignored): %s"
            % (LIB_REL, ", ".join(unsourced)))
    else:
        ok("every suite calling guard_require_* sources %s" % LIB_REL)

# The escape hatch must be a LOCAL one. This is the same control (t3) that
# tests/scripts/test-eso-seed-contract.sh runs on its own opt-out: a promise that
# "CI never sets it" is worth nothing unless something fails when CI does.
if OPT_OUT in ci:
    bad(".gitlab-ci.yml mentions %s — CI could switch every tooling preflight off:" % OPT_OUT)
    for i, line in enumerate(ci.split("\n")):
        if OPT_OUT in line:
            print("         .gitlab-ci.yml:%d: %s" % (i + 1, line.strip()[:78]))
else:
    ok(".gitlab-ci.yml never mentions %s — the CI path cannot opt out of a preflight" % OPT_OUT)

# And the helper itself must not become an unconditional skip.
lib_path = os.path.join(repo, LIB_REL)
if any(re.search(r"\bguard_require_(tools|capability)\b",
                 open(os.path.join(repo, r), encoding="utf-8", errors="replace").read())
       for r in suites if os.path.isfile(os.path.join(repo, r))):
    if not os.path.isfile(lib_path):
        bad("suites call guard_require_* but %s does not exist" % LIB_REL)
    else:
        lib = open(lib_path, encoding="utf-8", errors="replace").read()
        body = "\n".join(l for l in lib.split("\n") if not l.strip().startswith("#"))
        if OPT_OUT not in body:
            bad("%s no longer gates its skip on %s — it is an unconditional skip" % (LIB_REL, OPT_OUT))
        elif not re.search(r"exit\s+1", body):
            bad("%s never exits 1 — a missing tool would not fail anything" % LIB_REL)
        else:
            ok("%s skips ONLY under %s and otherwise exits 1" % (LIB_REL, OPT_OUT))

# ── 7) HOW MANY SUITES ACTUALLY GATE A PULL REQUEST ──────────────────────────
# Check 3 asks "does ANYTHING run this suite?" and answers it honestly. It is not
# the same question as "can this suite stop a bad merge", and conflating the two
# is how 123 guards came to gate nothing at all while this analyser printed green.
#
# Both runners check 3 accepts are POST-merge or no-merge:
#   * .gitlab-ci.yml — GitLab here is an in-cluster PULL MIRROR
#     (mirror_trigger_builds:true). Its pipelines run on the mirrored commit,
#     i.e. AFTER the merge that introduced the defect.
#   * the Makefile — a local target. It gates nothing; it is a convenience.
#
# Measured 2026-08-21 on this repo: 123 suites on disk, ZERO named by any
# GitHub Actions workflow. The one pull_request-triggered workflow
# (studio-tests.yml) runs the Studio pytest suite only — path-filtered, with
# tests/known-failures.txt deselected.
#
# This check does NOT demand the 123 be wired: which of them can even run in a
# hosted runner (docker, qemu, kind, node) is a real design question, not
# something a static analyser should force. What it refuses to allow is the
# number being INVISIBLE. It prints the ratio on every run and pins it, so the
# gap is a stated fact rather than an inference nobody draws, and so neither
# direction of drift is silent: unwiring a gated suite fails, and gating a new
# one fails until the baseline is raised to match (the same honesty rule check 4
# already applies to ALLOW_UNWIRED).
print()
print("-- 7) how many suites actually gate a pull request --")
PREMERGE_BASELINE = int(os.environ.get("PREMERGE_BASELINE", "0"))
wf_dir = os.path.join(repo, ".github", "workflows")
pr_wf, wf_text = [], ""
if os.path.isdir(wf_dir):
    for fn in sorted(os.listdir(wf_dir)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        t = open(os.path.join(wf_dir, fn), encoding="utf-8", errors="replace").read()
        # Scan the top-level `on:` block WITHOUT PyYAML (python:3-slim has no yaml).
        # A trigger counts only inside that block, so a `pull_request` mentioned in
        # a job name, a comment or an `if:` does not fool this.
        on_block, in_on = [], False
        for line in t.split("\n"):
            if re.match(r"^(on|True)\s*:", line):
                in_on = True
                on_block.append(line)
                continue
            if in_on:
                if line.strip() and not line.startswith((" ", "\t")):
                    break
                on_block.append(line)
        if re.search(r"\bpull_request\b", "\n".join(on_block)):
            pr_wf.append(fn)
            # Comment lines are STRIPPED before matching. A workflow that documents
            # which suites it deliberately does NOT run — and it should — would
            # otherwise have those names counted as gated, so the number would grow
            # by writing prose. This check must measure what CI executes, not what
            # the file mentions.
            wf_text += "\n".join(
                l for l in t.split("\n") if not l.lstrip().startswith("#")
            ) + "\n"

gated = [s for s in suites
         if s in wf_text or (os.path.dirname(s) + "/*.sh") in wf_text]
n, total = len(gated), len(suites)
print("         %d of %d suites are named by a pull_request-triggered workflow"
      % (n, total))
print("         pull_request workflows: %s"
      % (", ".join(pr_wf) if pr_wf else "NONE"))
if n == PREMERGE_BASELINE:
    if n == 0:
        ok("pre-merge suite coverage pinned at 0/%d — no shell guard blocks a merge, "
           "and that fact is now asserted rather than implied" % total)
    else:
        ok("pre-merge suite coverage pinned at %d/%d" % (n, total))
elif n < PREMERGE_BASELINE:
    bad("pre-merge suite coverage DROPPED to %d, baseline is %d — a suite that used "
        "to block a bad merge no longer does" % (n, PREMERGE_BASELINE))
else:
    bad("pre-merge suite coverage rose to %d, baseline still says %d — raise "
        "PREMERGE_BASELINE to %d so the recorded number stays true"
        % (n, PREMERGE_BASELINE, n))

# ── 7b) WHICH suites are ungated, not merely how many ────────────────────────
# The count above cannot see a ONE-FOR-ONE SWAP: delist a gated suite and gate a
# different one in the same commit and n is unchanged, so the check that exists to
# say "a suite that used to block a bad merge no longer does" says nothing. That
# was reproduced against this file on 2026-08-26 — rc=0, fully green, while
# tests/stack/test-tls-front.sh had just been removed from the workflow.
#
# `gated = suites - ungated`, so pinning this complement pins the gated SET
# element by element, and pins `total` with it (total == n + len(ungated) by
# construction — the denominator can no longer drift unremarked either).
#
# SKIPPED when the tree has no pull_request workflow at all: there is then nothing
# to compare, and the case is not a hole because n would be 0 and the cardinality
# check above already goes loudly RED. It is also what lets the miniature trees in
# the negative-control section below stay clean.
pinned_ungated = sorted(
    l.strip() for l in os.environ.get("PREMERGE_UNGATED", "").splitlines() if l.strip()
)
actual_ungated = sorted(set(suites) - set(gated))
if not pr_wf:
    ok("no pull_request workflow in this tree — the ungated SET has nothing to be "
       "compared against (the count above is what speaks here)")
else:
    delisted = [s for s in actual_ungated if s not in pinned_ungated]
    regated  = [s for s in pinned_ungated if s not in actual_ungated]
    if delisted:
        bad("suite(s) outside the pre-merge gate that PREMERGE_UNGATED does not "
            "record — either one that used to block a bad merge and now does not, "
            "or a new suite that landed outside the gate:")
        for s in delisted:
            print("         %s" % s)
    if regated:
        bad("PREMERGE_UNGATED names suite(s) that ARE gated now (or no longer "
            "exist) — the recorded list has rotted:")
        for s in regated:
            print("         %s" % s)
    if delisted or regated:
        print("         the pin must be REPLACED with the measured list below "
              "(and PREMERGE_BASELINE set to %d):" % n)
        for s in actual_ungated:
            print("           %s" % s)
    else:
        ok("the ungated SET matches its pin exactly (%d suite(s)) — a one-for-one "
           "swap cannot hide a delisting behind an unchanged count" % len(pinned_ungated))

# ── 8) `| grep -q` UNDER pipefail IS A COIN FLIP ─────────────────────────────
# `grep -q` exits the instant it matches and closes its end of the pipe. If the
# stage upstream has not finished writing, the kernel kills it with SIGPIPE and
# that stage's status is 141. Under `set -o pipefail` the PIPELINE then reports
# 141 — so a predicate that FOUND WHAT IT WAS LOOKING FOR reads as failure.
#
# Measured on this repo, GNU grep, `set -uo pipefail`:
#   upstream output > the 64 KiB pipe buffer  ->  200/200 runs report failure
#   upstream output that fits in one write    ->  0/3000 (both stages buffer,
#                                                 so the writer is already gone)
# The class is therefore REAL but load-bearing only where a stage streams more
# than it can buffer — which no static reader can tell by looking. That is the
# argument for removing it everywhere rather than triaging site by site.
#
# THE FIX IS TO DRAIN: drop -q, redirect to /dev/null. Plain grep reads to EOF so
# nothing is ever signalled, and the status is identical (0 match/1 none/2 error).
#     BAD :   awk '...' f | grep -vE '^#' | grep -qE 'PAT'
#     GOOD:   awk '...' f | grep -vE '^#' | grep -E  'PAT' >/dev/null
#
# Escape hatch: `# sigpipe-ok` on the line, for a site that genuinely wants the
# early exit, or for prose that merely quotes the shape (this check's own
# messages do). It has to be a conscious, reviewable act — that is the point.
GQ = "`| grep -q`"   # sigpipe-ok: prose, not a pipeline
print()
print("-- 8) no %s in a pipefail script (SIGPIPE races the assertion) --" % GQ)
scan, offenders = [], []
for sub in ("tests", "scripts"):
    for root, dirs, files in os.walk(os.path.join(repo, sub)):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules")]
        for fn in files:
            if fn.endswith(".sh"):
                scan.append(os.path.relpath(os.path.join(root, fn), repo))
scan.sort()
PIPE_Q = re.compile(r'(?<!\|)\|(?!\|)\s*grep\s+(?:-(?!-)[A-Za-z]*q[A-Za-z]*\b|--quiet\b)')
# pipefail can be INHERITED. `tests/menu/build_menu_cmd_test.sh` sets only `set -u`
# and then `source`s scripts/build-menu.sh, which sets `set -uo pipefail` — so the
# whole suite runs under pipefail while containing the string nowhere. Keying on a
# file's OWN text skipped it entirely and left 17 sites invisible, one of them
# deterministically RED in the alpine job and three of them NEGATIVE guards that
# fail OPEN (SIGPIPE makes `... | grep -q setsid` report "no setsid" at the exact
# moment a setsid IS present). Resolve `source`/`.` by basename over the same
# census and take the transitive closure, so an inherited `set -o pipefail` counts.
SOURCE_RE = re.compile(r'^\s*(?:source|\.)\s+[^\n]*?([A-Za-z0-9._-]+\.sh)', re.M)
_text = {}
for rel in scan:
    try:
        _text[rel] = open(os.path.join(repo, rel), encoding="utf-8", errors="replace").read()
    except OSError:
        _text[rel] = ""
_by_base = {}
for rel, txt in _text.items():
    _by_base.setdefault(os.path.basename(rel), []).append(rel)
_pf = {rel: ("pipefail" in txt) for rel, txt in _text.items()}
for _ in range(4):                       # transitive: a lib that sources a lib
    changed = False
    for rel, txt in _text.items():
        if _pf[rel]:
            continue
        for base in SOURCE_RE.findall(txt):
            if any(_pf.get(t) for t in _by_base.get(base, ())):
                _pf[rel] = True
                changed = True
                break
    if not changed:
        break
for rel in scan:
    txt = _text[rel]
    if not _pf[rel]:
        continue
    for i, line in enumerate(txt.split("\n"), 1):
        if line.lstrip().startswith("#") or "sigpipe-ok" in line:
            continue
        if PIPE_Q.search(line):
            offenders.append("%s:%d" % (rel, i))
if not scan:
    bad("check 8 found ZERO .sh files to scan — it would be vacuous")
elif offenders:
    bad("%d %s site(s) in a pipefail script — each can report FAILURE on a match "
        "it actually found, whenever upstream is still writing (drop -q, add "
        ">/dev/null): %s" % (len(offenders), GQ,
                             " ".join(offenders[:12]) + (" ..." if len(offenders) > 12 else "")))
else:
    ok("no %s under pipefail across %d .sh file(s) — no assertion here can be lost "
       "to a SIGPIPE race" % (GQ, len(scan)))

print()
print("== guard integrity: %d passed, %d failed ==" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
rc=$?

# Re-raise the python verdict. (The very defect this suite exists to catch: the
# status has to survive the last line of the script.)
if [ "${rc}" -eq 0 ]; then ok "static guard-integrity analysis clean"; else bad "guard-integrity analysis reported defects (above)"; fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# The whole point of this suite is that a guard which cannot go red is worthless,
# so it must demonstrate its OWN red. Synthesise a miniature repo carrying one
# deliberate instance of each defect and re-run the analyser against it via
# GUARD_ROOT; every case must FAIL, with the message that names it. A green run
# above therefore means "clean", never "the analyser silently did nothing".
if [ -z "${GUARD_SELFTEST_CHILD:-}" ]; then
  echo
  echo "-- negative controls: the analyser must go RED on planted defects --"
  SELF="${BASH_SOURCE[0]}"
  NEG="$(mktemp -d "${TMPDIR:-/tmp}/guard-integrity-neg.XXXXXX")"
  trap 'rm -rf "${NEG}"' EXIT

  # neg_case NAME EXPECTED_SUBSTRING  (tree already built in ${NEG}/tree)
  neg_case() {
    local name="$1" want="$2" out crc
    out="$(GUARD_SELFTEST_CHILD=1 GUARD_ROOT="${NEG}/tree" GUARD_ALLOW="" GUARD_PREMERGE=0 bash "${SELF}" 2>&1)"; crc=$?
    if [ "${crc}" -ne 0 ] && printf '%s' "${out}" | grep -F "${want}" >/dev/null; then
      ok "negative control bites: ${name}"
    else
      bad "negative control did NOT bite (rc=${crc}): ${name} — wanted '${want}'"
      printf '%s\n' "${out}" | sed 's/^/           /'
    fi
  }

  build_tree() { # build_tree SUITE_BODY [LIB_BODY] -> a minimal repo whose only
                 # suite is that body; LIB_BODY, when given, lands in
                 # scripts/probe-lib.sh for the suite to source.
    rm -rf "${NEG}/tree"
    mkdir -p "${NEG}/tree/tests/probe" "${NEG}/tree/scripts"
    printf '%s\n' "$1" > "${NEG}/tree/tests/probe/test-probe.sh"
    if [ "$#" -ge 2 ]; then printf '%s\n' "$2" > "${NEG}/tree/scripts/probe-lib.sh"; fi
    printf 'probe-job:\n  script:\n    - bash tests/probe/test-probe.sh\n' > "${NEG}/tree/.gitlab-ci.yml"
    printf 'all:\n\t@true\n' > "${NEG}/tree/Makefile"
  }

  # (a) status-blind ending — the test-appset.sh shape, but a DIFFERENT instance:
  #     a `printf` verdict line rather than `echo "---EXIT $?---"`, and the
  #     verdict is produced by an awk program (so a naive scanner reading the
  #     last line of the embedded program would see something else entirely).
  build_tree 'F=0
awk "BEGIN{ print \"checking\" }" </dev/null
if ! grep -q nothing /dev/null; then F=1; fi
printf "probe: %s failed\n" "${F}"'
  neg_case "a suite ending on printf with no set -e" "ends on a status-blind command"

  # (b) counted-but-never-raised: bad() increments F, nothing turns F into a status.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
bad "something is wrong"
echo "== ${P} passed, ${F} failed =="
exit 0'
  neg_case "a failure counter nothing raises" "counted but never raised"

  # (c) the ORPHAN case: a second suite that no job and no make target names.
  build_tree 'echo ok
exit 0'
  printf 'echo orphan\nexit 0\n' > "${NEG}/tree/tests/probe/test-orphan.sh"
  neg_case "a suite nothing runs" "tests/probe/test-orphan.sh"

  # (d) a CI loop that runs suites and throws their status away.
  build_tree 'echo ok
exit 0'
  printf 'probe-job:\n  script:\n    - |\n      for t in tests/probe/*.sh; do\n        bash "${t}"\n      done\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "a CI loop that discards a failing suite's status" "discard a failing suite"

  # (f) THE SILENT SELF-SKIP, in a shape nobody here wrote the check around:
  #     not `command -v`, not a one-liner, and the word SKIP is on a DIFFERENT
  #     line from the exit. A `[ -x … ]` probe on an absolute interpreter path is
  #     how a suite most naturally excuses itself without ever saying "command -v".
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
if [ ! -x /opt/java/openjdk/bin/keytool ]; then
  echo "  SKIP no JDK in this image"
  exit 0
fi
ok "checked something"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'batch-job:\n  script:\n    - |\n      SUITES="\n        tests/probe/test-probe.sh\n      "\n      rc=0\n      for t in ${SUITES}; do bash "$t" || rc=1; done\n      exit "${rc}"\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "a batch-run suite that skips itself when the image lacks a tool" \
           "hand back exit 0 instead of a verdict"

  # (g) the escape hatch turned into a CI-wide off switch.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "fine"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'variables:\n  GUARD_TOOLING_ALLOW_SKIP: "1"\nbatch-job:\n  script:\n    - |\n      SUITES="\n        tests/probe/test-probe.sh\n      "\n      rc=0\n      for t in ${SUITES}; do bash "$t" || rc=1; done\n      exit "${rc}"\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "CI setting the deliberate-local-opt-out variable" \
           "CI could switch every tooling preflight off"

  # (h) the helper called but never sourced: `guard_require_tools` would be a 127
  #     command-not-found and, with no `set -e`, execution walks straight past the
  #     preflight it was supposed to enforce.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
guard_require_tools openssl keytool
ok "fine"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'batch-job:\n  script:\n    - |\n      SUITES="\n        tests/probe/test-probe.sh\n      "\n      rc=0\n      for t in ${SUITES}; do bash "$t" || rc=1; done\n      exit "${rc}"\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "guard_require_* called without sourcing the helper" \
           "without sourcing tests/lib/guard-preflight.sh"

  # (i) check 7's own red: a suite that IS pull_request-gated while the recorded
  #     PREMERGE_BASELINE still says none is. The tree is otherwise CLEAN, so this
  #     case can only be biting on check 7. Without it the baseline could be pinned
  #     at a number nothing ever compares against — a check that only ever agrees
  #     with itself is the exact shape this file exists to catch.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  mkdir -p "${NEG}/tree/.github/workflows"
  printf 'name: pr\non:\n  pull_request:\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/probe/test-probe.sh\n' \
    > "${NEG}/tree/.github/workflows/pr.yml"
  neg_case "a pre-merge-gated suite the baseline does not record" \
           "raise PREMERGE_BASELINE"

  # (j) THE BLIND SPOT ITSELF: an orphaned suite named in the OTHER convention.
  #     Until 2026-08-26 the census walked for `test-*.sh` only, so a file called
  #     `<something>_test.sh` was not merely ungated — it was not a suite at all as
  #     far as this analyser was concerned, and checks 1, 2, 3 and 7 all skipped
  #     it in silence. (NOT 6 or 8: check 8 walks every *.sh itself and always saw
  #     them; check 6 keys on .gitlab-ci.yml batch lists and still does not — see
  #     the measured breakdown in the census header.) Eight real suites lived in
  #     that hole, tests/qemu/verdict_test.sh
  #     among them. THIS CONTROL IS THE PROOF THE WALKER REACHES THE SECOND NAME:
  #     reverting the census to `fn.startswith("test-")` makes it stop biting
  #     (measured — the child then goes green and this case reports "did NOT bite"),
  #     which is exactly what a regression on the collector looks like.
  #
  #     The tree is otherwise CLEAN — test-probe.sh is wired by the generated
  #     .gitlab-ci.yml — so nothing but the *_test.sh file can be producing the red.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  # Body kept counter-free ON PURPOSE, and it is the same shape control (c) plants.
  # An `ok(){ P=$((P+1)); }` written inline here would be read by check 2's
  # LINE-BASED function tracker as belonging to the enclosing `bad()` of the
  # build_tree body above it, and this analyser would then flag ITSELF for a
  # "counter P counted but never raised". Observed while writing this control.
  printf 'echo orphan\nexit 0\n' > "${NEG}/tree/tests/probe/orphan_test.sh"
  neg_case "an orphaned suite using the *_test.sh convention" \
           "tests/probe/orphan_test.sh"

  # (j2) THE THIRD SPELLING (#385): a suite directly in tests/ with a bare name.
  #      Until 2026-09-30 neither rule matched `tests/<name>.sh`, so ten suites sat
  #      outside check 3 and check 7 entirely. Reverting the census to its two-rule
  #      form makes this case stop biting. Counter-free body, for control (j)'s reason.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'echo orphan\nexit 0\n' > "${NEG}/tree/tests/orphan-top.sh"
  neg_case "an orphaned suite sitting directly in tests/ with a bare name" \
           "tests/orphan-top.sh"

  # (j3) THE EXEMPTION MUST NOT BE A HIDING PLACE. tests/e2e-extra-personas.sh is
  #      exempt from the census only because it is a SOURCED library. Plant a file
  #      of that name that nothing sources and the census must refuse the
  #      exemption rather than quietly drop an unwired file out of every check.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'echo not-a-library\nexit 0\n' > "${NEG}/tree/tests/e2e-extra-personas.sh"
  neg_case "a NOT_SUITES exemption for a file nothing sources" \
           "nothing sources it"

  # (k) THE ONE-FOR-ONE SWAP — the hole check 7's CARDINALITY pin cannot see, and
  #     the reason 7b exists. Reproduced against the real repo on 2026-08-26:
  #     removing tests/stack/test-tls-front.sh from shell-suites.yml while adding
  #     one new gated suite in the same edit printed "pinned at 125/135" and
  #     exited 0. Check 3 stayed quiet too — test-tls-front.sh is still named in
  #     .gitlab-ci.yml, so "something runs it" remained true; what stopped being
  #     true is that it blocks a merge.
  #
  #     The tree below is that edit in miniature. THREE suites, all three wired in
  #     .gitlab-ci.yml (so checks 1/2/3 are clean and only check 7 can be red).
  #     Before the swap the workflow gated probe+second; here it gates probe+THIRD.
  #     The count is IDENTICAL — GUARD_PREMERGE=2 is the honest pre-swap baseline
  #     and it still agrees — so check 7's cardinality line PASSES, and 7b is the
  #     only thing that can name tests/probe/test-second.sh. If the count alone
  #     could catch this, this control would bite with 7b deleted; it does not
  #     (measured: with the pin check removed the child exits 0).
  #
  #     The clean body goes through build_tree, NOT through an inline one-line
  #     printf. Writing `ok(){ …; P=$((P+1)); }` and the `[ "${F}" -eq 0 ]` raise
  #     on a SINGLE line of this file makes check 2's line-based counter tracker
  #     read them as one unit and flag THIS file for "counter P counted but never
  #     raised" — observed while writing this control, and the same class of
  #     self-flagging that control (j) records just above.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  mkdir -p "${NEG}/tree/.github/workflows"
  # Counter-free bodies, for the reason control (j) records above.
  printf 'echo second\nexit 0\n' > "${NEG}/tree/tests/probe/test-second.sh"
  printf 'echo third\nexit 0\n'  > "${NEG}/tree/tests/probe/test-third.sh"
  printf 'probe-job:\n  script:\n    - bash tests/probe/test-probe.sh\n    - bash tests/probe/test-second.sh\n    - bash tests/probe/test-third.sh\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  printf 'all:\n\t@true\n' > "${NEG}/tree/Makefile"
  printf 'name: pr\non:\n  pull_request:\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/probe/test-probe.sh\n      - run: bash tests/probe/test-third.sh\n' \
    > "${NEG}/tree/.github/workflows/pr.yml"
  swap_out="$(GUARD_SELFTEST_CHILD=1 GUARD_ROOT="${NEG}/tree" GUARD_ALLOW="" \
              GUARD_PREMERGE=2 GUARD_PREMERGE_UNGATED="tests/probe/test-third.sh" \
              bash "${SELF}" 2>&1)"; swap_rc=$?
  if [ "${swap_rc}" -ne 0 ] \
     && printf '%s' "${swap_out}" | grep -F "tests/probe/test-second.sh" >/dev/null \
     && printf '%s' "${swap_out}" | grep -F "pre-merge suite coverage pinned at 2/3" >/dev/null; then
    ok "negative control bites: a one-for-one swap that leaves the gated COUNT unchanged"
  else
    bad "negative control did NOT bite (rc=${swap_rc}): a one-for-one swap that leaves the gated COUNT unchanged"
    printf '%s\n' "${swap_out}" | sed 's/^/           /'
  fi

  # (h) `| grep -q` in a pipefail suite. The literal is ASSEMBLED here so this
  #     file does not itself carry the shape its own check 8 forbids — writing it
  #     out would make the guard flag its own negative control.
  Q='-q'
  build_tree "set -uo pipefail
P=0; F=0
ok(){ echo \"  PASS \$*\"; P=\$((P+1)); }
bad(){ echo \"  FAIL \$*\"; F=\$((F+1)); }
if cat /etc/hostname | grep ${Q} .; then ok \"host\"; else bad \"host\"; fi
echo \"== \${P} passed, \${F} failed ==\"
[ \"\${F}\" -eq 0 ]"
  neg_case "a pipe into a quiet grep under pipefail" "site(s) in a pipefail script"

  # (h2) the same shape, but the suite NEVER SAYS "pipefail" — it inherits the
  #      option from a library it sources. This is the real instance: the suite
  #      sets only `set -u`, so keying on its own text skipped the whole file and
  #      left every site in it unscanned. Without this control the resolver added
  #      for that case could rot to a no-op and (h) above would still pass.
  build_tree "set -u
source \"\$(dirname \"\$0\")/../../scripts/probe-lib.sh\"
P=0; F=0
ok(){ echo \"  PASS \$*\"; P=\$((P+1)); }
bad(){ echo \"  FAIL \$*\"; F=\$((F+1)); }
if cat /etc/hostname | grep ${Q} .; then ok \"host\"; else bad \"host\"; fi
echo \"== \${P} passed, \${F} failed ==\"
[ \"\${F}\" -eq 0 ]" "set -uo pipefail"
  neg_case "a quiet grep whose pipefail is INHERITED from a sourced library" \
           "site(s) in a pipefail script"

  # (e) POSITIVE control: the same miniature repo, all defects removed, must PASS.
  #     Without this, cases (a)-(d) could be passing because the child ALWAYS fails.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  if GUARD_SELFTEST_CHILD=1 GUARD_ROOT="${NEG}/tree" GUARD_ALLOW="" GUARD_PREMERGE=0 bash "${SELF}" >/dev/null 2>&1; then
    ok "positive control: a clean miniature repo passes (the analyser is not just always-red)"
  else
    bad "positive control FAILED — the analyser rejects a clean tree, so (a)-(d) prove nothing"
    GUARD_SELFTEST_CHILD=1 GUARD_ROOT="${NEG}/tree" GUARD_ALLOW="" GUARD_PREMERGE=0 bash "${SELF}" 2>&1 | sed 's/^/           /'
  fi

  # ── DYNAMIC control: the real suites, really missing a real tool ────────────
  # Sections above are static analysis of source text. This runs three of the
  # actual guards with keytool genuinely absent from PATH and requires the
  # behaviour, not the shape: exit non-zero, naming keytool. It is the direct
  # re-enactment of what orphan-guards-verify did on alpine:3, where all three
  # printed "SKIP: need keytool" and exited 0.
  echo
  echo "-- dynamic control: a keytool-less PATH must make the keystore guards RED --"
  NOKT="${NEG}/nokeytool-bin"
  mkdir -p "${NOKT}"
  # openssl and python3 stay reachable so the failure message names keytool ALONE
  # — a message listing all three would not prove the JDK was what was missed.
  for b in bash env dirname mktemp rm openssl python3 cat sed grep awk; do
    src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${NOKT}/${b}"
  done
  if [ -x "${NOKT}/openssl" ] && [ -x "${NOKT}/python3" ] && [ -x "${NOKT}/dirname" ]; then
    for ks in test-keystores.sh test-keystores-external-ca.sh test-keystores-multidomain.sh; do
      KSP="${REPO}/tests/keystores/${ks}"
      [ -f "${KSP}" ] || { bad "dynamic control: ${KSP} missing"; continue; }
      KO="$(env -u GUARD_TOOLING_ALLOW_SKIP PATH="${NOKT}" bash "${KSP}" 2>&1)"; KRC=$?
      if [ "${KRC}" -ne 0 ] && printf '%s' "${KO}" | grep -F "missing required tool(s): keytool" >/dev/null; then
        ok "dynamic: ${ks} FAILS (rc=${KRC}) with keytool absent — no silent green"
      else
        bad "dynamic: ${ks} did not fail closed without keytool (rc=${KRC}): ${KO}"
      fi
      KO="$(env GUARD_TOOLING_ALLOW_SKIP=1 PATH="${NOKT}" bash "${KSP}" 2>&1)"; KRC=$?
      if [ "${KRC}" -eq 0 ] && printf '%s' "${KO}" | grep -F "GUARD_TOOLING_ALLOW_SKIP=1 was set" >/dev/null; then
        ok "dynamic: ${ks} honours the DELIBERATE local opt-out (rc=0, loud SKIP line)"
      else
        bad "dynamic: ${ks} ignored the explicit opt-out (rc=${KRC}): ${KO}"
      fi
    done
  else
    bad "dynamic control could not be set up (no openssl/python3/dirname to symlink) — not proven"
  fi
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
