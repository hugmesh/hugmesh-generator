# Releasing a HugMesh beta

The whole org release is one command:

```bash
cd ~/Github/hugmesh-generator && git pull --ff-only && scripts/release-beta.sh --apply --studio <studio version>
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
action is still printed. Two things always wait for you: the two web-UI steps (gateway
package access and package visibility) and the Studio's own `Proceed?`.

The script is [`scripts/release-beta.sh`](../scripts/release-beta.sh). The list of what
gets released is [`scripts/release/repos.tsv`](../scripts/release/repos.tsv): 38
repositories in nine dependency stages. That list holds **no version numbers**.

## Options

| Option | Meaning |
|---|---|
| `--dry-run` (default) / `--apply` | read-only plan / do it |
| `--yes` | answer `y` to every `y/N` (web-UI pauses still wait for Enter) |
| `--merge <repo>#<n>` (repeatable) | before releasing: `gh pr ready` (when draft) and `gh pr merge --squash --delete-branch`, then wait for the new main push run |
| `--studio <version>` / `--studio next` / `--no-studio` | release the Studio through `scripts/release-studio.sh` (see below) |
| `--only <repo>` (repeatable) | act on these repositories only; every repository is still checked |
| `--from <phase>` | resume at a phase (re-running also skips DONE work by itself) |
| `--expect <repo>=<version>` (repeatable) | refuse that repository unless main's version file says exactly this |
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
| `REFUSE` | something would make the release fail or burn the beta number; the reason and the next command are printed | fix that, run again |
| `NEEDS-BUMP` | the tag for main's version is already published, but main has *N* commits since it | merge a PR that bumps the version file to `-beta.N+1`, then run again |
| `RUNNING` | the tag's run is in progress | the script watches it |

A repository is `READY` only if all of these hold. They are read from the GitHub API,
never from a local checkout:

- the version is well-formed and later than every existing `-beta.N` tag;
- the release workflow on main signs (`cosign sign` and `actions/attest-build-provenance`);
- the workflow does not write a private `DOCKER_CONFIG`;
- every required secret is set;
- the **latest push run of the release workflow on main** is green.

For `NEEDS-BUMP`, "commits since the tag" respects the workflow's `paths:` filter. The
mesh-node image only counts commits under `clients/docker-mesh-node/`, so the
generator's other work never makes it look stale.

## The phases

| # | Phase | What it does |
|---|---|---|
| 1 | `preflight` | checks the login, org secrets and `RUNS_ON_PUBLISH`, classifies every repository, prints the Studio's state; always runs, read-only |
| 2 | `merge` | the `--merge` PRs: ready, squash-merge, wait for the new push run on main, re-check everything |
| 3 | `maven` | stages 1-4, the Maven chain build-config -> parent -> commons -> auth-core, one at a time (a failed link stops the chain) |
| 4 | `apps` | stage 8 (Angular UIs) and stage 9 (games, forum-api, mesh-node); no Maven dependency |
| 5 | `rerun` | the gateway's and the Java images' red **main push runs**: `gh run rerun --failed`, watched. They went red only because commons/auth-core were not published yet |
| 6 | `gateway` | tags the gateway base image (stage 5) |
| 7 | `gateway-access` | **pause**: the be/fe/pki overlays build `FROM ghcr.io/hugmesh/hugmesh-gateway:<pinned version>`; see below |
| 8 | `overlays` | re-runs the overlays' red main runs, then tags them (stage 6) |
| 9 | `java` | tags the Java BFF/API images, actions and remote-fragment (stage 7) |
| 10 | `studio` | `scripts/release-studio.sh <version>` |
| 11 | `visibility` | **pause**: lists every package that is not public, waits, re-checks |
| 12 | `site` | `gh workflow run pages.yml -R hugmesh/hugmesh.github.io`, watched |
| 13 | `verify` | every artifact with its state, image visibility, and where it shows on hugmesh.net |

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

   The script can see public visibility but cannot see Actions access, so for the
   second route it asks you to confirm.
2. **Package visibility** (phase 11). Every new GHCR package is created private. The
   Downloads page cannot show an image nobody can pull. Making a package public
   **cannot be undone**, so it is one click per package on its settings page. Phase 11
   (or `--urls`) lists them. Maven packages of a public repository inherit its
   visibility.

## Resume and recovery

- **Run it again.** DONE work is skipped, and a tag run still in progress is watched,
  not re-tagged. Every stop prints the exact `--from <phase>` command. It also prints
  the command that leaves the problem and goes on with the next phase.
- **Answering `n`** stops at that phase and changes nothing.
- **A failed tag run** stops the release, and that beta number stays as it is. A
  published beta is never re-tagged. Read `gh run view <id> --log-failed -R
  hugmesh/<repo>`, fix it on main, bump the version file to `-beta.N+1` and run again.
- **`--only`** never changes what a stage *is*. A stage whose repositories are already
  DONE counts as published even when you did not select them. (The old tooling marked
  them not-OK and blocked the stage.)

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
- **"main moved ... nothing was tagged".** Something merged between the check and the
  tag. Wait for the new push run, then run the printed `--from` command.
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

## Testing the script

`tests/scripts/test-release-beta.sh` runs it against a recording `gh` stub. It proves:

- a dry run makes zero write calls;
- the version parsing, the classification, the `--only` fix and the main-moved re-check;
- the stage order of a full `--apply`;
- a four-mutation battery over those guards.

It runs in the pre-merge `shell suites (debian/python)` job and in GitLab's
`lint:release-beta`.
