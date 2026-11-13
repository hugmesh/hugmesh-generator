# CLAUDE.md: working on HugMesh

This file is for anyone, human or agent, picking up work on HugMesh. It records how the work
is done here: the rules, the conventions, the CI and release mechanics, and the traps that
have actually bitten. The longer write-ups live in `docs/`. This page tells you which ones to
read and what not to learn the hard way.

## What HugMesh is, and where things live

HugMesh is a self-hosted social mesh. Hardened Gentoo images (x86, Raspberry Pi, Orange Pi,
Frite, Jetson, desktops) join a headscale/Tailscale mesh, run a Kubernetes cluster, and serve
Matrix (tuwunel), Mastodon-compatible Akkoma, a forum, a wiki, video, games and more behind
BFF services and Angular micro-frontends.

- **This repo (hugmesh-generator)** is the hub. It holds the image builders
  (`build-*-stage4.sh`), the Makefile, the node specs (`specs*/`), the cluster manifests
  (`specs/cluster/manifests/`), the local compose stack (`tests/stack/`), the HugMesh Studio
  desktop app (`studio/`, Qt GUI + text UI + CLI), the release tooling (`scripts/release.sh`)
  and most of the docs.
- **The rest of the org** (about 40 repos, all public except `.github-private`): Java BFFs and
  APIs (`hugmesh-*-bff-api`, `hugmesh-federation-api`), the gateway chain (`hugmesh-gateway`
  plus `be-`/`fe-`/`pki-gateway`), the Maven chain (`hugmesh-build-config` → `hugmesh-parent`
  → `hugmesh-commons` → `hugmesh-auth-core`), Angular UIs (`hugmesh-*-ui`, `hugmesh-host-shell`),
  `hugmesh-games`, `hugmesh-forum-api` (PHP) and the site (`hugmesh.github.io`).
  `scripts/release/repos.tsv` lists them.
- **Start reading at** `docs/README.md`, `docs/ARCHITECTURE.md`, `docs/RUNNING.md`,
  `docs/LOCAL-STACK.md`, `docs/BUILD-MATRIX.md`, `docs/RELEASING.md` and
  `docs/STUDIO-WALKTHROUGH.md`.
- **Work is tracked on the org project board** ("Hugmesh Launch", org project 1). Every
  defect or TODO you find gets an issue there. See "Tracking" below.

## The rules

These are the operator's standing decisions. They hold unless the operator changes them.

1. **Never put anything private in a HugMesh repo.** The repos are public. Use placeholders
   (`mesh.example`, `exampleorg`) in code, tests, fixtures and docs. Never commit local paths
   (`/home/<user>/…`), secrets, tokens, or the operator's own private deployment names.
   Before every push, check the outgoing diff (`git log -p origin/main..HEAD`) for them.
2. **Commits and PRs carry no AI attribution.** No `Co-Authored-By:` trailer naming a model,
   no "Generated with …" footer, no model or tool names in commit messages, PR bodies or
   issue comments. Never write `[skip ci]`-style markers.
3. **Never force-push, never rewrite shared history.** Bring a branch up to date with
   `git merge origin/main`, not a rebase.
4. **A refused command is a stop.** If a merge, push or delete is refused, say so and stop
   that step. Never re-issue the same effect through another tool or the REST API.
5. **Never edit a shared checkout.** Several sessions often work at once. Work in your own
   `git worktree` on your own branch, and commit only files you changed.
6. **Merge only what has been verified, at exactly the commit that was verified.**
   Use `gh pr merge --match-head-commit <sha>`. Draft status protects nothing here: drafts do
   get merged, so a PR that must not land says so in its first line.
7. **No image builds without the operator.** A build takes hours and one host runs one at a
   time. Prove a builder fix with a targeted reproduction instead: one `emerge`, one
   configure step, or one `checkmodule` inside the `hugmesh-builder` image, offline where
   possible. The operator runs the real build and its test plan.
8. **Look at the UI you changed.** For a Studio or web change, render it (offscreen
   `widget.grab().save(...)`, or a headless browser) at the default window size and look at
   the picture. Also assert geometry in a test. Model-only tests have shipped invisible
   controls before.
9. **Studio walks are isolated.** Any test or agent that drives the Studio uses a throwaway
   `HOME` and `XDG_*` dirs, `HUGMESH_STUDIO_STATE_DIR`, `HUGMESH_LOCAL_AI_DIR`,
   `HUGMESH_VIEW_STATE` and `HUGMESH_STUDIO_NO_ELEVATION=1`, and never presses a real
   start/build/stack button. A "walk every screen" sweep once started the operator's real
   local AI service.

## Branches, PRs and landing

- **Branch names:** `fix/<topic>-<yyyymmdd>`, `feat/<topic>-<yyyymmdd>`, `docs/<topic>-<yyyymmdd>`.
- **PR text:** what failed (quote the log line), the root cause, the fix, how it was proven
  (a test that fails before and passes after; say which), and what only a real build or a
  person on a live mesh can confirm. Plain words; no local paths.
- **Every fix carries a test that fails without it.** Prove it by reverting the production
  change, or by mutating it. Mutation-test your guards: a guard that stays green when the
  invariant breaks is not a guard.
- **Review is adversarial and independent.** The reviewer did not write the change, tries to
  prove it wrong, runs probes and reports them. A verdict with no probes behind it is no
  result.
- **After the first merge into a repo, check the merged tree before the next one.** Two PRs
  that were each green against an older main can turn main red together. Merge the next PR
  locally onto the new main, run the suite, then merge. Check which files the two share.
- **Undo PRs:** when the operator chooses "merge now, test the image later", each merge gets
  a draft "WIP (revert if testing fails): Revert …" PR opened at merge time. Never merge
  those as part of a batch.
- **Batches:** many reviewed PRs can land as one integration branch (main plus each PR head
  merged in order, one CI run, merged with a merge commit), so each original PR shows as
  merged and one revert undoes the batch.

### Hand-resolved merges are where main breaks

The worst breakage of 2026-11-12 came from merges resolved by hand in GitHub's UI. One merge
dropped three closing lines (`fi`, `}`, `fi`), so three shell scripts no longer parsed: the
KEYS-folder generator, the first-boot provisioner and the node firewall. Other merges put a
YAML key in a workflow twice, so GitHub silently skipped the whole shell-suites workflow
("This run likely failed because of a workflow file issue"). After any merge that needed
conflict resolution:

- `bash -n` every shell script by shebang, and `python3 -m py_compile` the Python;
- check workflow YAML for duplicate keys (`tests/scripts/test-github-workflows-wellformed.sh`);
- for each file both sides changed, check that every line either side added survived (a
  `difflib` pass over base/ours/theirs/merged is enough);
- watch for "duplicate definitions where the later one silently wins", and for the same file
  added on both sides (add/add): there the newer version, plus only what the other side added,
  is the right result.

## Testing

### Studio (`studio/`)

- Run pytest **one file per process**, offscreen (`QT_QPA_PLATFORM=offscreen`), with isolated
  `HOME`/`XDG_*`. The whole suite in one process segfaults.
- CI runs the Qt tests with **PySide6** (the binding the Studio ships). Locally a PyQt6
  environment hides PySide6-only failures, and the other way round. Use a PySide6 venv
  pinned like `studio/packaging/linux-build-requirements.txt`.
- **Layout tests depend on fonts.** GitHub's Ubuntu runner draws with DejaVu, which is wider
  than many desktop fonts. To reproduce a CI-only layout failure, run the test in
  `ubuntu:24.04` with `libgl1 libegl1 libxkbcommon0 libdbus-1-3 libfontconfig1 libglib2.0-0
  fonts-dejavu-core` and the pinned `pyside6-essentials`. A check box never wraps; a long
  one sets the whole page's minimum width.
- `studio/tests/known-qt-failures.txt` lists tests known to fail on CI's binding. The runner
  reports a known test that now passes ("delete them from the list"); remove it.
- Page logic never opens modal dialogs (`QMessageBox`, `exec()`): they hang the offscreen
  suite silently. Report a refusal inline (a label plus `return False`). A refusal in
  `validatePage` never returns early (the GUI-20 rule): every field below it must still be
  collected.
- A `QThread` must never lose its last Python reference while it runs ("QThread: Destroyed
  while thread is still running" aborts the app). Hold it until `finished`; the
  `own_probe` helper does this.

### Shell suites (`tests/`)

- `.github/workflows/shell-suites.yml` runs every suite on pull requests, in legs (alpine,
  debian/python plus matrix parts, node, tool-heavy, host docker, layer-a). A new suite must be
  named there (and in `.gitlab-ci.yml`), and its leg must install what it needs: alpine has
  no `gpg` unless the leg installs `gnupg`.
- `tests/scripts/test-guard-integrity.sh` checks the CI wiring. `PREMERGE_BASELINE` is a
  **floor**: raise it only to what `GUARD_PREMERGE=0 bash tests/scripts/test-guard-integrity.sh`
  measures on your tree, and add a comment line saying so. Two PRs that both move it conflict
  on that line; resolve by keeping both comment lines and re-measuring.
- A suite raises its failure count into its exit status (`[ "${F}" -eq 0 ]` as the last line);
  guard-integrity rejects one that only prints it.

### Bash traps that have bitten

- bash 5.3: `local a=$1 b=${a}` dies under `set -u` (every name is localised before any
  assignment), yet passes on CI's older bash.
- `cmd | grep -q x` under `set -o pipefail` can report failure on a match once the upstream
  output passes the pipe buffer.
- A single NUL byte makes GNU grep skip a whole file and exit 1, which looks like "found
  nothing", so grep-based audits pass while blind.
- Never edit a shell script while bash is running it: bash re-reads by byte offset.

## CI facts

- **A red check's duration tells you what it is.** A failure after 2-3 seconds never started
  (billing or runner); it says nothing about the code. A failure after minutes is real.
- **A workflow file GitHub rejects runs nothing**, and shows up only as a red run named
  after the file. YAML parsers (PyYAML's `safe_load`) silently accept duplicate keys; GitHub
  does not.
- The debian shell-suite leg needs about 25 minutes of suites; its limit is 40.
- Sibling repos mostly have no pull-request CI, only `release.yml` on main. admin-bff's PR
  job compares its vendored copies of `docs/catalog/image-catalog.json` and
  `packages-catalog.json` with this repo's (`ImageCatalogDriftTest`). When the generator's
  catalog changes, re-vendor it there.

## Releasing

`docs/RELEASING.md` is the full manual. The essentials:

- `scripts/release-beta.sh` (the same as `scripts/release.sh --channel beta`) is a dry run by
  default and prints every repo as DONE / READY / REFUSE / NEEDS-BUMP / RUNNING. `--apply`
  runs the phases (preflight, merge, maven, apps, rerun, gateway, gateway-access, overlays,
  java, studio, visibility, site, verify) and asks before each write. `--from <phase>`
  resumes; re-running skips finished work.
- **Order matters.** The Maven chain publishes build-config → parent → commons → auth-core,
  and only then can the gateway, its overlays, the BFFs, `hugmesh-actions` and
  `remote-fragment` build. If version-bump PRs are merged by hand without running the
  release, every downstream Release/CI run fails with "Non-resolvable parent POM … (absent)"
  or "cannot pull base image hugmesh-gateway:<version>". Running the release fixes that: its
  rerun phase re-runs those red runs once their upstream exists.
- A repo has one release line. Every artifact in this repo (Studio, mesh-node image, Akkoma
  image: `images/akkoma/VERSION`) must be on the generator's X.Y line, or the
  `test-akkoma-image-pin.sh` guard fails.
- GitHub refuses to re-run a run older than 30 days ("cannot be retried"); push a commit
  instead and resume with `--from rerun`.
- After a release changes the Maven chain, the local stack's private Maven bootstrap
  (`tests/stack/m2-bootstrap.sh`, its `PINS` table) needs the new versions at their tagged
  commits, or a cold `make stack-up` dies on the parent POM.

## Images and builders

- The builders cross-compile into a sysroot (`ROOT=` merges) inside the `hugmesh-builder`
  image. Typical cross traps:
  - a postinst that `chown`s by user name (e.g. `nullmailer`) fails on the build host,
    because the user exists only in the sysroot; first boot re-applies it;
  - a Rust crate (e.g. `gnome-base/librsvg`) needs the target's `std` in the container's
    rustc (`hostguard_ensure_cross_rust_std`, landing with #1095);
  - a lockstep-versioned set (`sec-policy/*`, `dev-qt/*`, `kde-frameworks/*`) must be
    keyworded as a whole; keywording some members splits versions (an undefined SELinux
    interface such as `prelink_object_file` is that).
- `[WARNING] _do_sendfile failed unexpectedly` tracebacks during merges are portage noise.
- `--resume` reuses everything the previous run left, including ownership changes made by
  the Makefile. When in doubt, rebuild from a clean tree; it costs an hour, a broken image
  costs more.
- `docs/BUILD-MATRIX.md` says what each board and role supports. riscv64 images ship
  labelled "no SELinux" (operator decision); the macOS host keeps local-login fail-open
  with a warning; BSD and Solaris hosts refuse it.

## Tracking (the project board)

- Org project 1, "Hugmesh Launch", is the tracker. File each issue in the repo where the
  defect lives, add it to the board, and set Status and Priority. Read every field back after
  writing it.
- **Ready for testing** means a person must check it on a running mesh or real hardware.
  Label those `Manual` and `manual-test`. Work proven by automated evidence goes to **Done
  testing**. Operator tasks (credentials, billing, DNS, hardware) stay Todo with `Manual`.
- Fields that record what landed (`Code/branch`) are append-only, and are filled from a
  PR's closing references, never from a regex over PR text.

## Local stack and Studio

- `make stack-up` brings up the compose stack from `.stack-src` checkouts (which may be on
  fix branches, not main). `make view` serves it on `https://127.0.0.1:9080` with a local CA.
  Read `docs/LOCAL-STACK.md` before changing it. A stack "Clean" removes every volume and the
  local Maven registry; the next bring-up is a cold build of over an hour.
- The Studio's Desktop step runs `emerge --pretend` through the builder (`--pretend-only`).
  Its run log must never carry secrets: `desktop_pretend.pretend_config` blanks every
  `config.SECRET_FIELDS` value.

## Where the current work stands

The open pull requests and the board are the source of truth. As of 2026-11-12:

- 0.5.0-beta.1 is being released org-wide. The rerun phase is re-running the BFF and
  gateway runs that failed before the Maven chain was published. Akkoma `0.4.0-beta.1` is
  published and signed (cosign, plus GitHub provenance and SBOM attestations).
- Platform expansion (BSD and Solaris Studio hosts, RISC-V and MIPS images, the remaining
  planned devices) is planned as one tracking issue plus lane issues on the board
  (`docs/design/PLATFORM-EXPANSION.md` holds the design). Decisions so far: the 64-bit Solaris omnibus is the
  x86-64 omnibus as a bhyve guest on illumos; BSD/Solaris guest-VM CI runs as non-required
  checks.
