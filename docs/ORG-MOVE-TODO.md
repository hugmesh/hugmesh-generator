# TODO: moving to the HugMesh GitHub org

**Status: LANDED 2026-08-12 (revised plan).** The name question below was settled
by the operator: the new org is **`hugmesh`** (created as `hugmesh-net`, then
renamed in GitHub settings — same org id). The plan CHANGED from a rename of
`Snapdragon-Systems` to a **new-primary topology**: `hugmesh` is the primary org
going forward (repos are created/pushed there), and `Snapdragon-Systems` stays
put permanently as a secondary copy — it is NOT renamed and NOT deleted, so the
step list below (written for the rename plan) is historical. Every URL in this
repo now points at `github.com/hugmesh/...`; the mirror pass COMPLETED on
2026-08-12 — all 40 `Snapdragon-Systems` repos exist in `hugmesh` with content
(verified per-repo via the API), so every flipped URL resolves.

This file is the authoritative inventory and procedure. Code sites that a human
would reach for first carry a `TODO(org-move)` comment pointing here; the other
~260 are mechanical and listed below rather than annotated one by one — comment
noise across 85 ArgoCD manifests would be worse than a single accurate list.

Regenerate the inventory with:

```sh
grep -rn "Snapdragon-Systems" --include='*.sh' --include='*.py' \
     --include='*.yml' --include='*.yaml' --include=Makefile --include='*.md' .
```

## OPEN QUESTION — the new org name is not decided (RESOLVED: `hugmesh`, see Status)

The ask named it "the hugmesh.net github org", but **`hugmesh.net` cannot be a
GitHub org name**: GitHub org logins allow alphanumerics and single hyphens only,
no dots. So the target is one of `hugmesh`, `hugmesh-net`, or something else, and
that choice changes all 268 strings.

**Nothing here guesses.** The draft branch uses a single placeholder so retargeting
is one `sed`, and the flip must not land until the name is fixed AND the org
actually exists.

## The order that matters

Doing these out of order breaks a running cluster:

1. **Rename the org in GitHub settings** (browser).
2. **Verify the redirect.** GitHub redirects the old org's URLs after a rename, so
   existing clones and ArgoCD keep working *for a while*. This is a grace period,
   not a guarantee: the redirect dies the moment anyone re-registers the old org
   name, which is exactly the supply-chain hazard of leaving it half-done.
3. **Re-register the old name defensively** (create an empty `Snapdragon-Systems`
   org and keep it) so nobody else can claim it and inherit our redirects.
4. **Land the flip** (draft branch below) — ArgoCD manifests last, because a
   `repoURL` that 404s makes every Application stop syncing.
5. **Re-point the in-cluster GitLab pull-mirrors** (`scripts/gitlab-mirror-org.sh`),
   which import from `github.com/<org>/…` and are what actually feeds CI.
6. **Rotate any PAT** scoped to the old org name if the scoping is by org.

## What is NOT covered here

The 2026-07 infra-migration plan tracked live identifiers the rebrand left as
`snapdragon.*` — Casdoor, k8s namespaces, Cassandra, Postgres, Vault, the
registry. Those are **runtime data**, not GitHub URLs, and are out of scope for
this file. See the infra-migration plan; that work has its own blocking decisions.

## Inventory

Total occurrences of the legacy org string: **268** across **154** files.

| area | files | occurrences |
|---|---:|---:|
| ArgoCD app manifests (`repoURL:`) | 85 | 86 |
| Cluster manifests / charts / catalog | 19 | 25 |
| Other specs (stack, usr/share) | 1 | 2 |
| Image builders (`build-*.sh`) | 10 | 41 |
| Scripts | 6 | 16 |
| Studio (Python) | 3 | 5 |
| Templates / archetypes | 6 | 7 |
| CI + Makefile | 2 | 3 |
| Tests | 15 | 29 |
| Docs | 7 | 54 |

### ArgoCD app manifests (`repoURL:`)
* `specs/cluster/apps/09-forgejo.yaml` — 2
* `specs/cluster/app-of-apps.yaml` — 1
* `specs/cluster/apps/00-app-of-apps-waved.yaml` — 1
* `specs/cluster/apps/00-prod-hygiene.yaml` — 1
* `specs/cluster/apps/00a-cassandra-hardening.yaml` — 1
* `specs/cluster/apps/00b-cassandra-init.yaml` — 1
* `specs/cluster/apps/01c-autoscaling-latency.yaml` — 1
* `specs/cluster/apps/01d-nvidia-device-plugin.yaml` — 1
* `specs/cluster/apps/02-binhost.yaml` — 1
* `specs/cluster/apps/02-vault.yaml` — 1
* `specs/cluster/apps/03-gitlab.yaml` — 1
* `specs/cluster/apps/03b-harbor-provision.yaml` — 1
* `specs/cluster/apps/04-external-secrets-config.yaml` — 1
* `specs/cluster/apps/05-casdoor.yaml` — 1
* …and 71 more files in this area

### Cluster manifests / charts / catalog
* `specs/cluster/bootstrap/kind-local/bootstrap-kind.sh` — 4
* `specs/cluster/catalog/adopters.yaml` — 3
* `specs/cluster/bootstrap/bootstrap.sh` — 2
* `specs/cluster/bootstrap/kind-local/README.md` — 1
* `specs/cluster/catalog/ci/repo.gitlab-ci.yml` — 1
* `specs/cluster/charts/hugmesh-gateway/Chart.yaml` — 1
* `specs/cluster/manifests/api-docs/deployment.yaml` — 1
* `specs/cluster/manifests/character-forge/FEDERATION-REGISTRATION-TODO.md` — 1
* `specs/cluster/manifests/character-forge/deployment.yaml` — 1
* `specs/cluster/manifests/character-studio/FEDERATION-REGISTRATION-TODO.md` — 1
* `specs/cluster/manifests/character-studio/deployment.yaml` — 1
* `specs/cluster/manifests/forum-ui/deployment.yaml` — 1
* `specs/cluster/manifests/frontend/deployment.yaml` — 1
* `specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml` — 1
* …and 5 more files in this area

### Other specs (stack, usr/share)
* `specs/usr/share/hugmesh/stack/fetch-repos.sh` — 2

### Image builders (`build-*.sh`)
* `build-x86-host-stage4.sh` — 6
* `build-rpi5-stage4.sh` — 5
* `build-frite-stage4.sh` — 4
* `build-orangepi-zero2-stage4.sh` — 4
* `build-orangepi-zero2w-stage4.sh` — 4
* `build-orangepi-zero3-stage4.sh` — 4
* `build-orangepi3-lts-stage4.sh` — 4
* `build-orangepi4-lts-stage4.sh` — 4
* `build-orangepi5-stage4.sh` — 4
* `build-jetson-stage4.sh` — 2

### Scripts
* `scripts/pull-repo-base.sh` — 5
* `scripts/_github-auth-lib.sh` — 3
* `scripts/clone-all-repos.sh` — 3
* `scripts/gitlab-mirror-org.sh` — 2
* `scripts/publish-tenant-set.sh` — 2
* `scripts/secret-scan.sh` — 1

### Studio (Python)
* `studio/hugmesh_studio/core/config.py` — 3
* `studio/hugmesh_studio/core/validate.py` — 1
* `studio/hugmesh_studio/gui/pages/network.py` — 1

### Templates / archetypes
* `templates/archetypes/generator/recipe.yaml` — 2
* `templates/archetypes/angular-host/recipe.yaml` — 1
* `templates/archetypes/angular-mfe/recipe.yaml` — 1
* `templates/archetypes/gateway/recipe.yaml` — 1
* `templates/archetypes/remote-fragment/recipe.yaml` — 1
* `templates/archetypes/spring-bff/recipe.yaml` — 1

### CI + Makefile
* `Makefile` — 2
* `.gitlab-ci.yml` — 1

### Tests
* `tests/scripts/image_builder_always_on.py` — 5
* `tests/scripts/test-image-builder-always-on.sh` — 5
* `studio/tests/test_identity_validation.py` — 3
* `tests/domain-registry/test-foreign-ingest-fuzz.sh` — 2
* `tests/scripts/test-brand-path-validation.sh` — 2
* `tests/scripts/test-x86-identity-injection.sh` — 2
* `tests/stack/m2-bootstrap.sh` — 2
* `studio/tests/test_pages_identity.py` — 1
* `tests/domain-registry/test-templating-rename-pr.sh` — 1
* `tests/pentest/ci/README.md` — 1
* `tests/pentest/ci/pentest-stage.gitlab-ci.yml` — 1
* `tests/pentest/report/merge.py` — 1
* `tests/scripts/test-frite-builder-input-validation.sh` — 1
* `tests/scripts/test-rpi5-builder-input-validation.sh` — 1
* …and 1 more files in this area

### Docs
* `docs/ARCHITECTURE.md` — 42
* `docs/DEVOPS.md` — 3
* `docs/PHASE5-DECISIONS.md` — 3
* `docs/RUNNING.md` — 3
* `README.md` — 1
* `docs/LOCAL-STACK.md` — 1
* `docs/STUDIO-WIZARD-FLOW.md` — 1

