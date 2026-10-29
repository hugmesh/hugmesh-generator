# Superseded branches — closure record

**This file exists so four remote branches can be deleted without losing the
record of what they were.** It is an audit trail, not a plan. Nothing here
deletes anything; the destructive step is left to the operator (see
[Operator checklist](#operator-checklist)).

Baseline for every number below: **`origin/main` = `d8fa271a`**, measured
**2026-08-20**. Counts drift as `main` advances — re-measure before acting.
The [Re-verification](#re-verification) block is copy-pasteable.

## Verdict

All four branches are **SUPERSEDED-CLOSE**: the work they carry is already on
`main` by another route, and merging any of them would *regress* `main`. There
is **no open PR for any of them** — in fact no open PR in the repo at all — so
there is nothing to close in the GitHub UI. The only artifact left is the
remote branch ref.

| Branch | Tip SHA | Ahead | Behind | Merge-base | Namesake PR |
|---|---|---:|---:|---|---|
| `fix/route-access-api-docs-prefix` | `a9ada33b4ed79105a185cebdde3f3d19ebea1e85` | 7 | 222 | `cefae2c0` | [#6](https://github.com/hugmesh/hugmesh-generator/pull/6) **MERGED** |
| `feat/studio-qemu-e2e` | `5cd2c4bbfb58ab085a493ec1936acd3255192829` | 7 | 219 | `575ede90` | [#7](https://github.com/hugmesh/hugmesh-generator/pull/7) **MERGED** |
| `chore/org-move-prep-hugmesh-net` | `22638ba9822e77e8b8be13c5a9e39e5a0a8d8292` | 7 | 259 | `90f5a87e` | none, ever |
| `feat/local-mesh-bringup-and-credentials` | `5630b08bb2ed0b98cea868ee7c45901ad55686a4` | 10 | 247 | `844dc4b0` | none, ever |

Every tip has the same author, dated
**2026-08-14T13:40:40-07:00**, with the identical subject
`docs(tls-front): the self-signed CN follows the cluster domain, not a stale literal`.

## What each branch actually carries

### The shared 7-commit rename series (all four)

Every one of the four ends with the *same seven commits by subject*, in the
same order — a `.systems` → `hugmesh.net` rename pass:

```
docs(tls-front): the self-signed CN follows the cluster domain, not a stale literal
refactor(casdoor): rename the systems realm namespace to platform
fix(m2-bootstrap): repin shared artifacts to the migrated net.hugmesh coordinates
fix(frontend): rename host-shell workload to hugmesh-systems-web; fold image match keys to hugmesh/
chore(rename): games domain <pre-rebrand>.games -> hugmesh.games (resolves to games.hugmesh.net)
chore: land in-flight tree work alongside the hugmesh.net rename
chore(rename): eliminate .systems tokens in favour of hugmesh.net
```

These are **the same series rebased onto four different stale bases**, not four
byte-identical copies. The SHAs differ (four distinct sets), because each was
replayed onto a different 2026-08-12/13 commit. Treat them as one piece of work
with four stale instances.

Note the fourth line: this series *renames the host shell to
`hugmesh-systems-web`* — the **opposite direction** from where `main` ended up.
PR #93 renamed `hugmesh-systems-web` → `hugmesh-host-shell`.

**Superseded on `main` by:**

- PR [#91](https://github.com/hugmesh/hugmesh-generator/pull/91) — merge
  `4e77ec2002d828d1e235a51455ed365cde933224`, merged 2026-08-20T08:12:17Z —
  *chore: finish the pre-rebrand -> HugMesh rename in the generator*
- PR [#93](https://github.com/hugmesh/hugmesh-generator/pull/93) — merge
  `6eae9e51e20f9d4fa8f9c2a52357d26ad141f043`, merged 2026-08-20T08:36:09Z —
  *chore: finish the host-shell rename in the cluster lane*

### The 3 extra commits on `feat/local-mesh-bringup-and-credentials`

Below its rename series this branch carries three more — authored under a
different identity on 2026-08-12, unlike the seven above — none of
which are ancestors of `main`:

| Commit | Files touched | Subject |
|---|---:|---|
| `6129ac81` | 12 | `feat(studio): pick which services run locally, and watch the bring-up by stage` |
| `7b5559a4` | 3 | `fix(stack): /api/** 401'd with a valid session, and the seeder onboarded the specs' fixtures` |
| `34856c89` | 2 | `feat(studio): the credentials dialog hid the one account that opens everything` |

**Superseded on `main` by a single consolidated commit:
`49cc92d6f577af7a5ed0489ed746255791b09034`** — *feat(studio): pick which
services run locally, and show bring-up as a staged tree* — which is an
ancestor of `main` via PR [#1](https://github.com/hugmesh/hugmesh-generator/pull/1)
(merge `fc53063e2521bc258fe94bac1d9d57853e893a32`, merged 2026-08-13T03:20:53Z).

`49cc92d6` is a **strict file-set superset**: the three branch commits touch 17
distinct files between them, and `49cc92d6` touches all 17 plus
`docs/STUDIO-WIZARD-FLOW.md` (18 total). Each of the three is individually
covered — zero uncovered files apiece. This is the one claim in this document
backed by a mechanical containment proof; see
[Re-verification](#re-verification), which includes the negative control that
gives the proof its power.

### Namesake work is already on `main`

For the two branches that had PRs, the feature the branch is *named* after
merged long ago (#6 and #7, both 2026-08-13). Since each branch is ahead of
`main` by exactly its seven rename commits, everything else on those branches
is by definition already an ancestor of `main`. The branches were reused as
scratch bases for the rename pass after their own PRs merged.

`chore/org-move-prep-hugmesh-net` never had a PR and carries *nothing* unique
beyond the rename series.

## Why merging is not an option

A merge is not merely redundant, it is destructive. Test-merging each branch
into `origin/main` (`git merge-tree --write-tree`, no checkout) conflicts:

| Branch | Conflicting paths |
|---|---:|
| `fix/route-access-api-docs-prefix` | 39 |
| `feat/studio-qemu-e2e` | 48 |
| `chore/org-move-prep-hugmesh-net` | 70 |
| `feat/local-mesh-bringup-and-credentials` | 46 |

And the retired tokens are still live on these branches:

| Tree | files matching the pre-rebrand brand (-i) | files matching `hugmesh-systems-web` |
|---|---:|---:|
| `origin/main` | **36** | **1** |
| `fix/route-access-api-docs-prefix` | 132 | 10 |
| `feat/studio-qemu-e2e` | 132 | 10 |
| `chore/org-move-prep-hugmesh-net` | 144 | 10 |
| `feat/local-mesh-bringup-and-credentials` | 134 | 10 |

Resolving 39–70 conflicts in favour of a 219–259-commit-stale branch is how
PR #91 and PR #93 get undone.

## Honest limits of this record

Stating plainly what was **not** proven, so nobody reads more into the verdict
than the evidence supports:

- **The file-set-superset proof covers only the local-mesh trio.** For the
  7-commit rename series the same comparison **fails**: the series touches far
  more files than PR #91 + #93 together, leaving hundreds that the branch
  series touches and those two PRs do not. The rename verdict therefore does
  *not* rest on a superset argument — it rests on `main` having reached the
  intended end state by a different route on a tree 219–259 commits newer, and
  on the branch series pushing the host-shell name *backwards*. That is a
  judgement call about intent, not a mechanical containment proof.
- **No line-level content equivalence was checked**, even for the local-mesh
  trio. "Same files touched" is not "same edits made". The trio's supersede
  rests on file-set containment plus the matching commit-message intent of
  `49cc92d6`.
- Counts are a **2026-08-20 snapshot** against `d8fa271a` and go stale.

## Recovery

Nothing here is irreversible, provided the tip SHAs above survive — which is
the entire point of this file.

At the time of writing, all four SHAs are also held by **clean local
worktrees** (none had uncommitted work; every `HEAD` matched its recorded tip
exactly):

| Worktree path | Branch |
|---|---|
| `<checkout-root>/hugmesh-generator-apidocs-prefix` | `fix/route-access-api-docs-prefix` |
| `<checkout-root>/hugmesh-generator-studio-qemu` | `feat/studio-qemu-e2e` |
| `<checkout-root>/hugmesh-generator-orgmove` | `chore/org-move-prep-hugmesh-net` |
| `<checkout-root>/hugmesh-generator-localmesh` | `feat/local-mesh-bringup-and-credentials` |

To restore a deleted remote branch from any clone that still has the object:

```sh
git push origin <tip-sha>:refs/heads/<branch-name>
```

GitHub also retains the objects of a deleted branch for a period and can serve
them by SHA, so `git fetch origin <tip-sha>` may still work even from a clone
that pruned its tracking ref.

## Operator checklist

Deliberately **not** automated. Order matters — the local worktrees pin these
branches, and a worktree-held branch cannot be deleted locally.

1. Re-run [Re-verification](#re-verification) and confirm the SHAs still match.
2. Remove the local worktree for each branch:
   `git -C <checkout-root>/hugmesh-generator worktree remove <path>`
3. Delete the local branch: `git branch -D <branch>`
4. Delete the remote ref: `git push origin --delete <branch>`

There is **no PR to close** for any of the four.

## Re-verification

```sh
# 1. Tip SHAs + ahead-counts must match the table (7, 7, 7, 10).
for b in fix/route-access-api-docs-prefix feat/studio-qemu-e2e \
         chore/org-move-prep-hugmesh-net feat/local-mesh-bringup-and-credentials; do
  printf '%s %s ahead=%s\n' "$b" \
    "$(git rev-parse "origin/$b")" \
    "$(git rev-list --count "origin/main..origin/$b")"
done

# 2. The strongest supersede claim: MUST print nothing.
comm -23 <(git show --name-only --format= 34856c89 7b5559a4 6129ac81 | sort -u) \
         <(git show --name-only --format= 49cc92d6 | sort -u)

# 3. NEGATIVE CONTROL for step 2. Substitute a commit that is genuinely NOT on
#    main (336ac331, itself one of the rename-series commits, touching a large
#    file set). MUST print files -- 15 of them at the time of writing.
#    If this prints nothing, step 2 is empty by construction and proves nothing.
comm -23 <(git show --name-only --format= 34856c89 7b5559a4 6129ac81 | sort -u) \
         <(git show --name-only --format= 336ac331 | sort -u)

# 4. Conflicting-path counts (39/48/70/46). Note the file-name list ends at the
#    first blank line; everything after it is informational prose, and counting
#    it is how you get a wrong, inflated number.
for b in fix/route-access-api-docs-prefix feat/studio-qemu-e2e \
         chore/org-move-prep-hugmesh-net feat/local-mesh-bringup-and-credentials; do
  printf '%s %s\n' "$b" "$(git merge-tree --write-tree --name-only \
    origin/main "origin/$b" | tail -n +2 | awk '/^$/{exit} {c++} END{print c+0}')"
done
```
