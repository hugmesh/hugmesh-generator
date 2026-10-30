# Releasing HugMesh: beta and stable

The whole org release is one script, [`scripts/release.sh`](../scripts/release.sh), run
from a checkout of `hugmesh-generator` on `main`. `--channel beta` (the default) releases
every repository's `main`; `--channel stable` releases each repository's own
`release/X.Y` branch ([Stable releases](#stable-releases)). The beta one-liner is
unchanged, because `scripts/release-beta.sh` is `scripts/release.sh --channel beta`:

```bash
git pull --ff-only && scripts/release-beta.sh --apply --studio <studio version>
```

On 2026-10-29 that was `--studio 0.3.0-beta.2`. Use `--studio next` to take the next
beta after the checkout's `__version__`, or `--no-studio` to leave the Studio alone.

Run it bare first. With no flags it is a **dry run**. It reads GitHub and changes nothing.
It prints every repository's state, what each phase would do, and the web-UI steps
you will be asked for:

```bash
scripts/release-beta.sh                         # dry run, read-only
scripts/release-beta.sh --studio 0.3.0-beta.2   # dry run, including the Studio preflight
```

`--apply` runs the phases in order and asks `y/N` before every phase that writes: a
merge, a tag, a re-run, a dispatch. `--yes` answers those prompts for you, and each
action is still printed, and it is passed on to `release-studio.sh`, so the Studio's
`Proceed?` is skipped too. The two web-UI steps (gateway package access and package
visibility) always wait for Enter. `--yes` never answers the gateway step's "Did you
grant Read?" question either: that is a click in the web UI that no API can see, so under
`--yes` the script checks the package again and, if it is still not public, stops with
its settings page (see [the manual steps](#the-two-manual-steps-and-why-they-are-manual)).

The dry-run text names files relative to the checkout, never with a local path, so it
can be pasted into a PR or a chat as it is.

The script is [`scripts/release.sh`](../scripts/release.sh);
[`scripts/release-beta.sh`](../scripts/release-beta.sh) only runs it with `--channel beta`.
The list of what gets released is [`scripts/release/repos.tsv`](../scripts/release/repos.tsv):
38 repositories in nine dependency stages. That list holds **no version numbers**.

## How channels work

The **tag decides the channel**. A tag with `-beta.N` is a beta; a plain `X.Y.Z` is
stable. Each repository's release workflow reads the tag and publishes accordingly; this
script decides which commit gets which tag.

| | Beta | Stable cut | Stable patch |
|---|---|---|---|
| Released from | `main` | the repo's `release/X.Y`, which the cut creates from `main` | the existing `release/X.Y`, after the fix is cherry-picked there |
| Version | `main`'s version file: `X.Y.Z-beta.N` | `main`'s beta without `-beta.N`: `X.Y.Z` | `--version X.Y.(Z+1)` |
| Git tag | `vX.Y.Z-beta.N` on `main` | `vX.Y.Z` on `release/X.Y` | `vX.Y.(Z+1)` on `release/X.Y` |
| Image tags | `:X.Y.Z-beta.N` and the floating `:beta` | `:X.Y.Z`, the floating `:X.Y`, and `:latest` | `:X.Y.(Z+1)` and `:X.Y`; `:latest` only if `X.Y` is the newest stable line |
| GitHub Release | prerelease, never marked Latest | full release, marked Latest | marked Latest only if `X.Y` is the newest stable line |
| Never moves | `:X.Y.Z-beta.N` | `:X.Y.Z` | `:X.Y.(Z+1)` |
| Afterwards | the next beta bumps `main` | the `next` phase opens PRs moving `main` to `X.(Y+1).0-beta.1` | `main` is not touched |

Every pushed image tag is signed, the floating ones included. Each repository has its own
`X.Y`: build-config, parent, commons, auth-core, the gateway and the UIs are versioned
independently, so a cut is "each repository's current beta, released as its stable".

## Options

| Option | Meaning |
|---|---|
| `--channel beta` (default) / `--channel stable` | release `main` as betas / each repository's `release/X.Y` as stables ([Stable releases](#stable-releases)) |
| `--version X.Y.Z` | stable only, with `--only`: a patch release on the existing `release/X.Y` |
| `--dry-run` (default) / `--apply` | read-only plan / do it |
| `--yes` | answer `y` to every `y/N` except "Did you grant Read?" (web-UI pauses still wait for Enter) |
| `--merge <repo>#<n>` (repeatable) | before releasing: `gh pr ready` (when draft) and `gh pr merge --squash --delete-branch`, then wait for the new main push run (if none appears, it stops there) |
| `--studio <version>` / `--studio next` / `--no-studio` | release the Studio through `scripts/release-studio.sh` (see below; beta only for now) |
| `--only <repo>` (repeatable) | act on these repositories only; every repository is still checked, and a stage with none of them is skipped |
| `--from <phase>` | resume at a phase (re-running also skips DONE work by itself) |
| `--expect <repo>=<version>` (repeatable) | refuse that repository unless the version this run would release is exactly this (beta: main's version file; stable: the computed `X.Y.Z`) |
| `--urls` | only list the packages that are not public yet, with their settings pages |

## Where versions come from, and what each state means

Each repository's version is read **from its version file on main**:

- `pom.xml` (the project's own `<version>`, never the `<parent>` one)
- `package.json`
- `composer.json`
- `VERSION`
- for the mesh-node image, `clients/docker-mesh-node/VERSION`

The version must be `MAJOR.MINOR.PATCH-beta.N`. The release is the tag
`<prefix><version>`: `v0.3.0-beta.2`, or `mesh-node-v0.1.0-beta.1` for the mesh node.

| State | Meaning | What to do |
|---|---|---|
| `DONE` | the tag exists and its release run is green; main has nothing since it that the workflow builds | nothing |
| `READY` | the tag is free and every check passed; this run will tag it | nothing |
| `REFUSE` | something would make the release fail or burn the beta number; the reason and the next command are printed | fix that, run again. One `REFUSE` fixes itself: a tag whose run failed in a preflight step before it published anything says "do NOT bump", and its stage re-runs that run (see [Resume and recovery](#resume-and-recovery)) |
| `NEEDS-BUMP` | the tag for main's version is already published, but main has *N* commits since it | merge a PR that bumps the version file to `-beta.N+1`, then run again |
| `RUNNING` | the tag's run is in progress | the script watches it |

A repository is `READY` only if all of these hold. They are read from the GitHub API,
never from a local checkout:

- the version is well-formed and later than every existing `-beta.N` tag;
- the release workflow on main signs (`cosign sign` and `actions/attest-build-provenance`);
- the workflow does not write a private `DOCKER_CONFIG`;
- every required secret is set;
- the **latest push run of the release workflow on main** is green, and it ran on
  main's current commit. If main has moved past it (a merge seconds ago, Actions lagging,
  a `[skip ci]` commit), the repository is `REFUSE` until that commit's own push run
  appears. The one exception is a workflow with a `paths:` filter (mesh-node): there the
  green run counts when no commit since it touches those paths, because none is coming.

For `NEEDS-BUMP`, "commits since the tag" respects the workflow's `paths:` filter. The
mesh-node image only counts commits under `clients/docker-mesh-node/`, so the
generator's other work never makes it look stale.

## The phases

The last column is what declining does. **Stops** means: nothing more is written, the
script exits 1 and prints the `--from` command that resumes there (and the one that goes
on with the next phase). **Goes on** means the run continues with the next phase.

| # | Phase | What it does | `n` at its `y/N`, or `q` at its pause |
|---|---|---|---|
| 1 | `preflight` | checks the login, org secrets and `RUNS_ON_PUBLISH`, classifies every repository, prints the Studio's state; always runs, read-only | (no prompt) |
| 2 | `merge` | the `--merge` PRs: ready, squash-merge, wait for the new push run on main, re-check everything | `n`: stops |
| 3 | `maven` | stages 1-4, the Maven chain build-config -> parent -> commons -> auth-core, one at a time (a failed link stops the chain) | `n`: stops |
| 4 | `apps` | stage 8 (Angular UIs) and stage 9 (games, forum-api, mesh-node); no Maven dependency | `n`: stops |
| 5 | `rerun` | the gateway's and the Java images' red **main push runs**: `gh run rerun --failed`, watched. They went red only because commons/auth-core were not published yet | `n`: stops |
| 6 | `gateway` | tags the gateway base image (stage 5) | `n`: stops |
| 7 | `gateway-access` | **pause**: the be/fe/pki overlays build `FROM ghcr.io/hugmesh/hugmesh-gateway:<pinned version>`; see below | `q`: stops. `n` at "Did you grant Read?": stops. Under `--yes`, a package still not public after Enter: stops, with its settings page |
| 8 | `overlays` | re-runs the overlays' red main runs, then tags them (stage 6) | `n` (either prompt): stops |
| 9 | `java` | tags the Java BFF/API images, actions and remote-fragment (stage 7) | `n`: stops |
| 10 | `studio` | `scripts/release-studio.sh <version>` | `n`: stops. No at `release-studio.sh`'s own `Proceed?` (asked only without `--yes`): **goes on**, because it exits 0 with "Nothing done." |
| 11 | `visibility` | **pause**: lists every package that is not public, waits, re-checks | `q`: **goes on** (packages left private stay listed; nothing to undo) |
| 12 | `site` | `gh workflow run pages.yml -R hugmesh/hugmesh.github.io`, watched | `n`: **goes on** (the site's cron refreshes it within the hour) |
| 13 | `verify` | every artifact with its state, image visibility, and where it shows on hugmesh.net | (no prompt) |

In phases 3, 4, 6, 8 and 9 the same `n` also declines the re-run of a tag run that
published nothing (below); that stops too.

Every tag is created with the git refs API on the main SHA that was checked. Right
before the tag, main is read again. If main moved, nothing is tagged and the script
stops with the command to resume. A merge starts a new push run, and the new commit may
carry a different version.

## The two manual steps, and why they are manual

GitHub has **no API** for either of these. The script prints the exact page, waits for
Enter, and checks again.

1. **Gateway package access** (phase 7). The overlays' release runs pull the gateway
   image with their own `GITHUB_TOKEN`. A new GHCR package is private, so that pull
   fails until you do one of two things:
   - make it **Public**: <https://github.com/orgs/hugmesh/packages/container/hugmesh-gateway/settings>,
     then Danger Zone, then Change visibility;
   - or, on the same page, open **Manage Actions access** and add `hugmesh-be-gateway`,
     `hugmesh-fe-gateway` and `hugmesh-pki-gateway` with **Read**.

   The script can see public visibility but cannot see Actions access. After you press
   Enter it checks again. If the package is still not public it asks "Did you grant Read
   to ...?"; `y` goes on, `n` stops. Under `--yes` it does **not** answer that question
   for you: it stops with the settings page. Once you have made the package public, or
   granted Read, run the printed `--from gateway-access` command (or `--from overlays`
   when you granted Read, which the script cannot see).
2. **Package visibility** (phase 11). Every new GHCR package is created private. The
   Downloads page cannot show an image nobody can pull. Making a package public
   **cannot be undone**, so it is one click per package on its settings page. Phase 11
   (or `--urls`) lists them. Maven packages of a public repository inherit its
   visibility.

## Resume and recovery

- **Run it again.** DONE work is skipped, and a tag run still in progress is watched,
  not re-tagged. Every stop prints the exact `--from <phase>` command. It also prints
  the command that leaves the problem and goes on with the next phase.
- **Answering `n` or `q`** stops the run at that phase without writing anything, except
  in two phases where it goes on: `q` at the visibility pause and `n` at the site
  rebuild. The table in [The phases](#the-phases) lists each one.
- **A tag run that failed before it published anything** is re-run, not bumped. This
  happens, for example, when commons' tag run fails in "Preflight - cross-repo package
  read" because build-config/parent were not readable yet. The repository then shows
  `REFUSE` with "do NOT bump: gh run rerun <id> --failed", and its stage asks to re-run
  it, watches it and goes on. All of these must hold:
  - the failed step is a preflight step (the `version` job, a preflight, a base-image
    pull check, checkout or setup);
  - no publish, push, upload, deploy, attest or release step ran;
  - no package carries the version;
  - there is no GitHub Release for the tag;
  - it is the run's first attempt;
  - it is younger than 30 days.

  If any of these is unreadable, the script falls back to the bump advice.
- **Any other failed tag run** stops the release, and that beta number stays as it is.
  A published beta is never re-tagged. This includes a failed test or build step, which
  is the tagged commit's own fault and which a re-run repeats. Read `gh run view <id>
  --log-failed -R hugmesh/<repo>`, fix it on main, bump the version file to `-beta.N+1`
  and run again. The reason says when the run published nothing, so a flaky test can
  still be re-run by hand.
- **`--only`** never changes what a repository *is*: every row is still checked and
  printed. It changes what a stage has to achieve:
  - A stage with none of your repositories is reported and skipped. It is never a stop.
    So `--apply --only hugmesh-admin-ui` tags that UI even while a Maven link is red.
  - A stage with some of your repositories succeeds when *those* are published. Other
    rows in it that are not ready do not stop the run.
  - A **dependency** stage is still judged on all its rows. A stage whose repositories
    are all DONE counts as published even when you did not select them. (The old
    tooling marked them not-OK and blocked the stage.) But `--only hugmesh-admin-bff-api`
    stops at stage 7 while any Maven link it builds on is not published.

## Bumping a version for the next beta

1. In the repository, change only its version file: `0.3.0-beta.1` -> `0.3.0-beta.2`.
   A Maven repository may also need a dependency bump on what it consumes.
2. Open a PR and merge it. Pass `--merge <repo>#<n>` if you want the script to merge
   it and wait for the push run.
3. Run `scripts/release-beta.sh`. The repository moves from `NEEDS-BUMP` (or `DONE`) to
   `READY`.

A gateway release also needs each overlay's `PINNED_GATEWAY_IMAGE` (fe-gateway calls it
`GATEWAY_IMAGE_PIN`) in its `release.yml` raised in a PR. Phase 7 reports a mismatch.

## The Studio

The Studio has its own release path, [`scripts/release-studio.sh`](../scripts/release-studio.sh)
([`STUDIO-INSTALLERS.md`](STUDIO-INSTALLERS.md)). It dispatches "Cut a Studio release",
which bumps `__version__` on main, tags `studio-v<version>` and builds the signed MSI,
Flatpak and tarball. `release-beta.sh` only calls it:

- `--studio 0.3.0-beta.2` releases that version;
- `--studio next` lets it propose the next beta from your checkout's `__version__`;
- `--no-studio` skips it.

In a dry run it calls `release-studio.sh --dry-run`. If release `studio-v<version>`
already exists, the phase is DONE.

## The site (hugmesh.net)

[hugmesh.net/downloads](https://hugmesh.net/downloads) is built by `pages.yml` in
`hugmesh/hugmesh.github.io`. It reads versions from the published GitHub Releases and
the registry, and what it lists comes from that repository's `release-sources.json`.
Each release workflow's "notify hugmesh.github.io" step needs the secret
`SITE_DISPATCH_TOKEN`, which is not set. So the site refreshes only on its own cron
unless phase 12 dispatches it. Phase 13 prints, per artifact, which Downloads group it
appears in, or "not listed".

## Troubleshooting (the real failures from the 2026-10-29 release)

- **Gateway and every Java image REFUSE: "last main push run ... is failure".** Their
  main runs failed because `hugmesh-commons` / `hugmesh-auth-core` were not on GitHub
  Packages yet. That is phase 5's job, after phase 3 has published the chain. A red run
  for any *other* reason must be fixed first: read the log.
- **"no push-to-main run of release.yml found"** or **"... days old: GitHub cannot re-run
  it".** Runs older than about 30 days cannot be re-run. Push a commit to main; the
  next merge creates a new push run. A `workflow_dispatch` run on main does **not**
  count: only push runs do, because only they publish what the tag run builds on.
- **Overlays fail with a pull error on the gateway image.** Phase 7 was skipped or the
  package is still private. See the manual steps above.
- **"tag vX exists and its run N is 'failure', but it failed in '... / Preflight ...'
  before it published anything".** This is the 2026-10-29 commons case: the tag run
  started before its Maven parents were readable. Do not bump. Run the release again
  (or `--from <phase>`), and that stage offers `gh run rerun N --failed`. When the
  reason instead says "a re-run does not fix it" or "is published", bump.
- **"STOP (--yes does not answer this question)" in gateway-access.** The gateway
  package is still private after the pause. Make it public, or grant the overlays Read
  under Manage Actions access, then run the printed `--from` command.
- **"main moved ... nothing was tagged".** Something merged between the check and the
  tag. Wait for the new push run, then run the printed `--from` command.
- **"main's HEAD has no push run yet".** Main moved past the last green push run, and
  the run for the new commit has not appeared. Usually a merge landed a moment ago, so
  wait for it and run again. If it never comes (a `[skip ci]` commit, or Actions
  disabled), push a commit to main.
- **"STOP <repo>#<n>: no new ... push run appeared".** The `--merge` went through, but
  its push run did not start within five minutes. Watch the printed Actions page, then
  run the printed `--from merge` command. The merged PR is skipped on that run.
- **A merge does not seem to start a run.** Workflows with a `paths:` filter (mesh-node)
  only run for commits that touch those paths. The merge phase says so, and does not
  wait.
- **A stray non-conforming tag** such as host-shell's `v0.3.1-beta` (its run failed) is
  ignored by the ordering check. Only `X.Y.Z-beta.N` tags count.
- **Everything shows REFUSE "cannot read main" or flips between runs.** That is GitHub's
  secondary rate limit, or the egress tunnel is down. Reads retry twice on any error
  other than a 404. Wait a minute and run again.
- **The `RUNS_ON_PUBLISH` warning.** That org variable sends release jobs to a
  self-hosted runner, which public repositories cannot use, so the jobs queue forever.
  Unset it before releasing.
- **`release-studio.sh` stops with "already exists".** That Studio version is out. Pick
  a later one, or use `--no-studio`.

## Stable releases

```bash
scripts/release.sh --channel stable                  # dry run: every repo's state and the plan
scripts/release.sh --channel stable --apply          # cut, bump PRs, tag in stage order, next-beta PRs
scripts/release.sh --channel stable --version 0.3.1 --only hugmesh-admin-ui --apply   # a patch
```

A stable release is the tag `vX.Y.Z` on the repository's own `release/X.Y` branch, never
on `main`. The flow takes more than one run, because the version-bump PRs it opens have
to be merged by a person:

1. **Run 1** cuts the release branches and opens the bump PRs, then stops at the first
   stage whose PR is not merged yet.
2. **Merge the bump PRs in stage order.** A downstream PR goes green only once the stable
   it pins is published, exactly like the beta cascade.
3. **Run again.** Every merged stage is tagged and watched. A red release-branch push run
   is re-run in the `rerun` phase once its dependency stages are out. After a stable is
   published, the `next` phase opens one PR per repository moving `main` to
   `X.(Y+1).0-beta.1`.

The stable phases are the beta ones with three more: `preflight cut bump merge maven apps
rerun gateway gateway-access overlays java studio visibility site next verify`. `cut`,
`bump` and `next` ask `y/N` like every other writing phase, `--from` resumes at any of
them, and `--merge <repo>#<n>` merges a bump PR and waits for the push run on the PR's
base branch (`release/X.Y`), not `main`.

### Stable states

| State | Meaning | What to do |
|---|---|---|
| `NEEDS-CUT` | `release/X.Y` does not exist yet, and `main`'s beta `X.Y.Z-beta.N` is `DONE` | the `cut` phase creates the branch at `main`'s checked SHA |
| `NEEDS-PR` | `release/X.Y` exists but its version file is not `X.Y.Z` yet | the `bump` phase opens the PR; merge it, then run again |
| `READY` | everything below holds; this run tags `release/X.Y` | nothing |
| `DONE` | `vX.Y.Z` exists and its run is green | nothing. If `release/X.Y` moved since, the row says which `--version` the patch is |
| `REFUSE` | the reason and the next step are printed | fix it, run again |

A repository is `READY` for stable only if all of these hold, read from the GitHub API:

- **its release workflow supports channels**, read at the ref that would be tagged
  (`release/X.Y`, or `main` before the cut). Two markers must both be there:
  - `on.push.branches` lists a `release/` glob (`release/**`), so a release branch gets
    the same push run that the script checks on `main`;
  - the literal line `hugmesh-release-channels: beta+stable` (a comment next to the
    channel logic).

  Without them the repository is refused, with the open "Release channels: beta from
  main, stable from release/X.Y" PR to merge. If the branch was cut before the PR
  merged, cherry-pick it into `release/X.Y`;
- `release/X.Y`'s version file says `X.Y.Z`;
- no `net.hugmesh` pin, `<hugmesh-*.version>` property or overlay `FROM` pin on
  `release/X.Y` is still a `-beta.N`;
- `X.Y.Z` is later than every stable tag (a cut), or exactly the next patch after the
  newest `vX.Y.*` (a patch);
- the beta checks also pass on `release/X.Y`: signing, no private `DOCKER_CONFIG`, the
  required secrets, and the latest **`release/X.Y` push run** is green at its HEAD;
- every dependency stage is published at its stable (a patch has no dependency stages:
  its pins are already stable).

### What stops a stable run

- **A selected repository whose `main` is `NEEDS-BUMP`.** It has commits that no
  published beta carries, so its "current beta" is not what `main` is. `cut` and `bump`
  stop for every selected repository until that beta is released (`scripts/release-beta.sh`)
  or the repository is left out with `--only`.
- **A cut over a beta that is not `DONE`.** The cut releases what the beta released.
- **A bump that is not mechanical.** If any selected repository would keep a beta pin
  that no row of `repos.tsv` publishes, or a file is not in the shape the rules expect,
  the `bump` phase opens **no PR at all** and lists what to fix.
- **A branch that moved.** `main` is read again right before the cut creates
  `release/X.Y`, and `release/X.Y` right before it is tagged. If either moved, nothing is
  created and the run stops with the resume command.
- **A published version is never re-tagged.** A stable tag whose run failed after
  publishing is fixed forward with `--version X.Y.(Z+1)`.

### The version bump, mechanically

Each bump is one commit on the branch `bump/stable-X.Y.Z` and one **draft** PR into
`release/X.Y`. Its head branch is deliberately not under `release/`: every
channel-aware workflow runs on pushes to `release/**`. The PR is opened from the
release branch's current HEAD, and a re-run finds the open PR instead of opening a
second one. What moves:

| File | Rule |
|---|---|
| `pom.xml` | the project's own `<version>`; every `<parent>`, dependency, plugin or extension with `groupId` `net.hugmesh` whose artifact a row of `repos.tsv` publishes, to that artifact's stable from the same run; every `<artifact>.version` property of such an artifact. Found by element, never by line number. Comments are left alone |
| `package.json` | `version`, and its `package-lock.json` (`version` and `packages[""].version`) |
| `composer.json`, `VERSION` | the version |
| `repos.tsv` `mirrors` column | `frontend/package.json` (character-forge), `README.md:Version` and `CHANGELOG.md:heading` (auth-core), `gateway-pin` (the be/fe/pki `PINNED_GATEWAY_IMAGE` / `GATEWAY_IMAGE_PIN`, to the gateway's stable) |

Left for a person, and said in the PR: auth-core's `CHANGELOG.md` gets a `## X.Y.Z`
heading with a TODO line where the release notes go (its metadata test needs the prose),
and comments or docs that still name a beta.

The `next` phase uses the same rules on `main`: the version moves to
`X.(Y+1).0-beta.1`, and every org pin to its upstream's next beta, so the beta channel
picks up where it left off.

### Patch releases

1. Fix it on `main` first.
2. Cherry-pick the fix into the repository's `release/X.Y` in a PR. The bump to
   `X.Y.(Z+1)` can be part of that PR, or `--apply` opens it.
3. Run `scripts/release.sh --channel stable --version X.Y.(Z+1) --only <repo> --apply`.

`--version` needs `--only`, because each repository has its own version line. It is
refused when `X.Y.(Z+1)` is not the next patch after the newest `vX.Y.*`, or when
`release/X.Y` does not exist. A patch on an older line moves `:X.Y` and never
`:latest`; the repository's release workflow decides that from its own tags.

### The Studio on the stable channel

The Studio is not released by a stable run yet. `--channel stable --studio <version>` is
refused, with what is missing:

1. `scripts/release-studio.sh` needs a `--final` (or `--channel stable`) that takes
   `release_version.py next --final`. Today it only proposes the next beta, and its
   usage line and "a wrong build gets a new beta N" say so.
2. `scripts/release.sh` then calls it with that flag, keeping its type-back
   confirmation.
3. Cosmetic: the `studio-release.yml` and `studio-release-cut.yml` headers still say
   "beta scheme" and "next beta N".

The rest already handles a plain `X.Y.Z`: `release_version.py` accepts it and
`studio-release.yml` marks it as a full release.

### Before the first stable cut

1. Merge each repository's "Release channels" PR (the dry run lists those still
   missing).
2. Release a beta, so every `main` is `DONE`.
3. Run `scripts/release.sh --channel stable` and read the plan: zero `REFUSE` before
   `--apply`.

## Testing the script

`tests/scripts/test-release-beta.sh` runs it against a recording `gh` stub. It proves:

- a dry run makes zero write calls, on both channels. That is checked twice: the stub
  refuses every write (exit 97) whenever the script runs without `--apply`, and the call
  log is searched for writes afterwards;
- `scripts/release-beta.sh` classifies every row exactly like `release.sh --channel beta`;
- the stable channel: every state (`NEEDS-CUT`, `NEEDS-PR`, `READY`, `DONE`, `REFUSE`), the
  channel-marker refusal with the PR to merge, the beta-pin refusal, the cut at the
  checked `main` SHA (and its refusal over a `NEEDS-BUMP` main or a `main` that moved),
  the bump's rewrite rules and its idempotence, a bump that is not mechanical opening
  nothing, the tag on the release branch's re-read SHA, the patch rules, the next-beta
  PR, and the Studio refusal;
- the version parsing and the classification;
- the `--only` fix: `--apply --only <a UI>` tags it while a Maven stage is unpublished,
  and `--only <a Java image>` still stops at its own stage;
- the main-moved re-check, the "push run at main's HEAD" check (with and without a
  `paths:` filter), and a `--merge` whose push run never appears;
- a tag run that failed in a preflight step with nothing published is re-run, not
  bumped. When the run did publish, has a Release, failed in a publish or test step, or
  already failed a re-run, it keeps the bump advice;
- under `--yes` the gateway-access question is never answered: the run stops with the
  settings page. Without `--yes` it is asked;
- the dry-run text carries no checkout or temp paths;
- the stage order of a full `--apply`;
- a mutation battery over those guards, beta and stable. Each guard is broken in a copy
  of the script, and the check that covers it must go red.

It runs in the pre-merge `shell suites (debian/python, release)` job and in GitLab's
`lint:release-beta`.
