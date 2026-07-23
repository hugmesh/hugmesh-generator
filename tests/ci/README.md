# Org-mainline integration (build-the-graph-from-source)

A safety net for a failure mode that **per-repo CI cannot see**: a shared library
(`hugmesh-commons`, `hugmesh-auth-core`) changes its API but is re-published under
the **same version**, so a dependent whose tests weren't updated keeps passing in CI
(against the stale published jar) while being **red against the library's current
source**. The drift only surfaces when the whole dependency graph is built from source.

That is exactly how three silent reds reached `main` on 2026-06-26 — `hugmesh-mod-bff-api`
(#55), `hugmesh-auth-core` (#21), and `hugmesh-admin-bff-api` (#168) — each caught
only by a manual from-source sweep, never by their own green CI.

## Why per-repo CI misses it

Every repo's `.gitlab-ci.yml` `test` job runs `./mvnw -s settings.xml clean test|verify`,
which resolves `hugmesh-commons`/`hugmesh-auth-core` (incl. the `tests` classifier)
from the GitLab Maven **registry** via `CI_JOB_TOKEN`. So each repo is validated against the
last *published* artifact, in isolation — never against the live source of its intra-org
dependencies. When the version isn't bumped on an API change ("content-bump-without-
version-bump"), source and registry drift apart invisibly.

## What this does

[`org-mainline-from-source.sh`](./org-mainline-from-source.sh):

1. Builds `hugmesh-commons` then `hugmesh-auth-core` from each repo's `origin/main`
   and installs each into the local `~/.m2` at **both its own `<version>` and its
   `<parent>` version** (deduped). This matters because dependents resolve the two libs at
   *different* coordinates: the commons MAIN jar resolves at `2.0.0` (its own version,
   pinned by `hugmesh-parent`'s `<hugmesh-commons.version>`, since dependents declare
   commons with no explicit `<version>`), while the auth-core MAIN jar resolves at `2.7.0`
   (the parent line, via the BOM) and some repos pin `commons:2.7.0:tests`. Installing at
   both coordinates guarantees the from-source build is the one actually consumed for every
   dependent's main-jar **and** tests-classifier — otherwise a single (parent-only) install
   leaves dependents on the stale cached jar and the tool *reproduces* drift instead of
   detecting it.
2. Runs each dependent's `mvn -o test` against those freshly-built libs.
3. Prints a PASS/FAIL table and exits non-zero if any repo is red against current lib source.

```bash
# everything (default dependent list):
tests/ci/org-mainline-from-source.sh
# a subset:
tests/ci/org-mainline-from-source.sh hugmesh-admin-bff-api hugmesh-user-bff-api
# reuse already-installed libs (faster re-runs):
SKIP_LIB_BUILD=1 tests/ci/org-mainline-from-source.sh hugmesh-mod-bff-api
```

Env: `GITHUB_ROOT` (clones parent dir), `WORK` (scratch), `MVN`, `SKIP_LIB_BUILD`.
Needs the repos cloned locally, a JDK matching the parent (`java.version` = 25), and Docker
(the BFF `@SpringBootTest` suites use Testcontainers-Postgres).

## CI wiring

[`org-integration-stage.gitlab-ci.yml`](./org-integration-stage.gitlab-ci.yml) is an
include-able **scheduled** job (mirrors `tests/pentest/ci/pentest-stage.gitlab-ci.yml` — one
source of truth org-wide). It clones the graph + runs the script under Docker-in-Docker.
Run it on a schedule (nightly), not per-MR: it is a cross-repo net, not a per-repo gate.

## The real fix (recommended, not automated here)

This job *detects* drift; it doesn't *prevent* it. To prevent it, do one of:

- **Bump the artifact version on every API change** of a shared lib (enforce that the
  published version is never overwritten with different bytes — a CI-derived version such
  as `2.<line>.${CI_PIPELINE_IID}`, or a release check that fails if the version matches a
  published artifact with a different content hash). Dependents then pin explicitly and a
  stale pin fails to resolve loudly.
- Or make each shared-lib MR **run its dependents' tests against the new source** before
  merging (a downstream-trigger pipeline).

See the org memory `hugmesh-silent-red-main-rootcause` for the full diagnosis.
