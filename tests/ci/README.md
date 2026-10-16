# Org-mainline integration (build-the-graph-from-source)

A safety net for a failure that **per-repo CI cannot see**. A shared library
(`hugmesh-commons`, `hugmesh-auth-core`) changes its API but is re-published under
the **same version**. A dependent whose tests were not updated keeps passing in CI,
against the stale published jar, while being **red against the library's current
source**. The drift shows only when the whole dependency graph is built from source.

That is how three silent reds reached `main` on 2026-06-26: `hugmesh-mod-bff-api`
(#55), `hugmesh-auth-core` (#21) and `hugmesh-admin-bff-api` (#168). Each was caught
by a manual from-source sweep. None was caught by its own green CI.

## Why per-repo CI misses it

The BFF repos' `.gitlab-ci.yml` test jobs run `./mvnw -B -s settings.xml clean test` or
`verify` (`hugmesh-gateway` runs `./mvnw verify -B` in a JDK container instead). They resolve
`hugmesh-commons` and `hugmesh-auth-core` (including the `tests` classifier) from the
GitLab Maven **registry** via `CI_JOB_TOKEN` (`settings.xml`). Each repo is checked
against the last *published* artifact, alone, never against the live source of its
org dependencies. When the version is not bumped on an API change
("content-bump-without-version-bump"), source and registry drift apart unseen.

## What this does

[`org-mainline-from-source.sh`](./org-mainline-from-source.sh):

1. Builds `hugmesh-commons`, then `hugmesh-auth-core`, from each repo's `origin/main`.
   It installs each into the local `~/.m2` at **both its own `<version>` and its
   `<parent>` version** (deduped). Dependents resolve the libs at whatever coordinate
   their pom names. A coordinate the script does not install is still read from the
   cached or registry jar, and then the tool *reproduces* drift instead of detecting it.
   State on 2026-10-15 (`origin/main`):
   - `hugmesh-parent` is `2.8.0`.
   - `hugmesh-commons` is `2.1.0`. That is also what `hugmesh-parent`'s
     `<hugmesh-commons.version>` and the `commons:2.1.0:tests` pins in
     `hugmesh-user-bff-api` and `hugmesh-mod-bff-api` name, so commons is covered.
   - `hugmesh-auth-core` is `2.5.1` (parent `2.8.0`). Of the default dependents, only
     `hugmesh-admin-bff-api` and `hugmesh-user-bff-api` depend on it, and both pin `2.5.1`,
     so auth-core is covered too. A pin other than `2.5.1` or the parent line `2.8.0`
     would not be installed from source.
2. Runs each dependent's `mvn -o test` against those freshly built libs.
3. Prints a PASS/FAIL table. It exits non-zero if any repo is red against current lib source.

```bash
# everything (default dependent list):
tests/ci/org-mainline-from-source.sh
# a subset:
tests/ci/org-mainline-from-source.sh hugmesh-admin-bff-api hugmesh-user-bff-api
# reuse already-installed libs (faster re-runs):
SKIP_LIB_BUILD=1 tests/ci/org-mainline-from-source.sh hugmesh-mod-bff-api
```

Env: `GITHUB_ROOT` (clones parent dir), `WORK` (scratch), `MVN`, `SKIP_LIB_BUILD`.
Defaults: `GITHUB_ROOT` is the parent of this checkout, `WORK` is
`/var/tmp/portage/hugmesh-mainline-verify`, `MVN` is `mvn`. You need the repos cloned
locally, a JDK matching the parent (`java.version` = 25), and Docker (the BFF
`@SpringBootTest` suites use Testcontainers-Postgres).

## CI wiring

[`org-integration-stage.gitlab-ci.yml`](./org-integration-stage.gitlab-ci.yml) is an
include-able **scheduled** job. It mirrors `tests/pentest/ci/pentest-stage.gitlab-ci.yml`:
one source of truth org-wide. It is a hidden template, `.org-mainline-from-source`, and
a scheduled pipeline opts in with `extends:`. It runs on a schedule, or by hand from
the web UI, in `maven:3.9-eclipse-temurin-25` with a `docker:27-dind` service. It
shallow-clones the graph and runs the script. Run it nightly, not per MR. It is a
cross-repo net, not a per-repo gate.

## The real fix (recommended, not automated here)

This job *detects* drift. It does not *prevent* it. To prevent it, do one of:

- **Bump the artifact version on every API change** of a shared lib. Enforce that a
  published version is never overwritten with different bytes: use a CI-derived version
  such as `2.<line>.${CI_PIPELINE_IID}`, or a release check that fails if the version
  matches a published artifact with a different content hash. Dependents then pin
  explicitly, and a stale pin fails to resolve loudly.
- Or make each shared-lib MR **run its dependents' tests against the new source** before
  merging (a downstream-trigger pipeline).

See the org memory `hugmesh-silent-red-main-rootcause` for the full diagnosis.
