# DevOps platform (`devops` namespace, x86_64 host)

All GitOps, CI and forge tooling runs in the **`devops`** namespace. It is pinned to
the x86_64 host (the Pis are arm64) and stores data on the host's local disks plus
attached USB (the `hugmesh-local` StorageClass). It is reachable only over the
headscale/tailscale VPN and is never exposed externally. **No keys are served on any
web interface.**

| Component | What | Access |
|---|---|---|
| **ArgoCD** | GitOps engine; syncs `specs/cluster/apps`. Hard-pinned `kubernetes.io/arch=amd64`. | VPN, Casdoor admins |
| **GitLab** (`apps/03-gitlab.yaml`) | Internal forge; pull-mirrors **every** hugmesh repo; runs CI. Casdoor OIDC, admin-only, no public sign-up. | `gitlab.<domain>` over VPN |
| **GitLab Runner** (`apps/04-gitlab-runner.yaml`) | Privileged CI runner on the x86 host (root + crossdev + qemu) — builds ISOs + images. | in-cluster |
| **Binhost** (`apps/02-binhost.yaml`) | Gentoo binary-package host; serves `/binpkgs/{arm64,amd64}` over the VPN (hostPort 8086). | every Gentoo node |
| **local-path** | StorageClass `hugmesh-local` from device disk (`/mnt/data`) + USB (`/mnt/usb`). | cluster default |

## CI: build + deliver all ISOs and images

`.gitlab-ci.yml` runs these stages on the privileged x86 runner:

1. **iso** — `scripts/build-all-roles.sh` (pki/backend/frontend, aarch64) and
   `build-x86-host-stage4.sh` (x86 host).
2. **images** — The `build:images` job dispatches into the **in-cluster Kaniko
   image-build pipeline** (`specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml`).
   The pipeline is ALWAYS-ON: `specs/cluster/apps/60-image-builder.yaml` is in the
   root app-of-apps' recursed `apps/` set, so the build namespace and NetworkPolicy
   always sync. The Kaniko Job stays a template, so no build pod runs until one is
   dispatched. The job runs on the default branch and release tags only. It REQUIRES
   a cluster `KUBECONFIG` on the runner and the ESO-materialized
   `image-builder-registry` push secret. It no longer no-ops when they are missing: it
   fails (the job is `allow_failure: true`, so the failure stays inside that job). The
   service-catalog Kaniko builder (`apps/54-service-catalog-builder.yaml`) is a
   separate per-`AddService` template, not the general pipeline.
3. **deliver** — on `main`, uploads each ISO to the GitLab generic package registry
   under a stable `…/packages/generic/iso/latest/<name>.iso` path.

**ISOs contain no keys.** KEYS material comes from the USB stick at first boot. It is
never baked into an ISO or published with one.

The **admin UI** (`hugmesh-admin-ui`) shows download links to those latest ISOs
(admin-only; the BFF exposes `/bff/admin/isos`).

## Mirror the org into GitLab

`scripts/gitlab-mirror-org.sh` creates a **pull mirror** in GitLab for every hugmesh
GitHub repo (`mirror_trigger_builds=true`), so CI builds from a complete copy inside
the VPN. Repos hold no secrets (keys are git-ignored and live only on the USB and in
Vault), so the mirror exposes nothing sensitive.

## Forgejo + the GitOps source migration (⏳ PARTIAL — scaffold present, flip live-gated)

The plan is to move from "ArgoCD syncs straight from GitHub" to an **in-cluster
Forgejo** as the source of truth. The scaffold exists. The cut-over has not happened:

- ✅ **Present (Phase 5/6 scaffold):**
  - the Forgejo deploy (`apps/09-forgejo.yaml`);
  - the catalog ApplicationSet (`apps/13-service-catalog.yaml`), already configured
    with an `scmProvider` generator pointing at the **in-cluster Forgejo**
    (`http://forgejo.hugmesh-pki.svc.cluster.local:3000`, `repositoryMatch
    ^hugmesh-`);
  - the deploy contract (`specs/cluster/catalog/hugmesh-deploy.example.yaml`).
- ✅ **Adoption started (9 of the 32 image-producing repos, all ships-dark).**
  The count is over the whole org, not a local tree: `gh repo list hugmesh` returns
  **38** `hugmesh-*` repos, **32** of which ship a root `Dockerfile`. The six that do
  not are `auth-core`, `build-config`, `commons`, `games`, `generator`, `parent`. The
  adopters are registered in `specs/cluster/catalog/adopters.yaml`. Its `spec.sweep`
  block records this provenance and is itself gate-checked:
  - `hugmesh-deploy.yaml` + `deploy/` — `admin-bff-api`, `be-gateway`,
    `character-forge-bff-api`, `federation-api`, `forum-ui`, `mod-bff-api`,
    `remote-fragment`, `user-bff-api`.
  - `snapdragon-deploy.yaml` + `deploy/` (LEGACY_COMPAT, the pre-rebrand descriptor
    name) — `forum-bff-api`, the registry's last legacy row (swept 2026-08-20).
    **Stale:** on 2026-10-07 `hugmesh-forum-bff-api` ships `hugmesh-deploy.yaml` at
    its root (`gh api repos/hugmesh/hugmesh-forum-bff-api/contents/`), so all 9
    adopters use the new name. The registry row and the legacy generator filter need
    the update the registry's header describes. The registry, not this list, is the
    authority, and the gate checks it against the repos.

  The catalog generators filter on **both** filenames (two `filters` entries: the
  scmProvider ORs across entries and ANDs inside one, and `pathsExist` is itself an
  AND-list, so a single entry cannot express the either-or). Until 2026-07-30 they
  matched the legacy name only, and 3 repos were **silently invisible** to the
  catalog. `scripts/validate-catalog-discovery.sh` (CI job
  `lint:catalog-descriptor-discovery`) now fails the pipeline if any adopting repo
  ships a descriptor no generator matches.
- ⏳ **Remaining (live-gated):** the **source flip** needs a booted Forgejo, an admin,
  OIDC, the GitHub→Forgejo org mirror, and a read token in the `forgejo-scm-token`
  Secret (ns `devops`) before the ApplicationSet can scan anything real. The manifest
  itself lists these prerequisites.
- ⏳ **Remaining (NOT gated):** the other **23** image-producing repos have not
  adopted a descriptor and `deploy/` tree. You can prepare them now, with no live
  cluster, using the 9 above as examples. Register each in `catalog/adopters.yaml`
  (and add it to the CI clone list) as it lands. **Re-sweep the org, never your
  checkouts.** `character-forge-bff-api` had adopted the descriptor for months and was
  missed, because the first sweep covered only the 33 repos that happened to be
  cloned locally.

## Fast binary OS updates via the binhost

Each Gentoo node runs `emerge --getbinpkg` against the binhost over the VPN
(`PORTAGE_BINHOST=http://<x86-vpn-ip>:8086/<arch>`, set by keys-provision from the
node inventory). The x86 build emits amd64 binpkgs. The RPi crossdev build emits
arm64 binpkgs. Both are rsynced to the binhost PVC.

### Opt-in host-binary auto-update (default-off)

Every generated host/node **and** client image **bakes** the auto-update plumbing.
It is **off by default**. A superadmin must **opt in**. The baked `hugmesh-update`
poller (`/usr/local/sbin/hugmesh-update`) runs from an `/etc/cron.d/hugmesh-update`
drop-in (cronie, OpenRC, not systemd) on the configured cadence, and once at boot
through the `hugmesh-update` OpenRC oneshot. Each poll **skips** unless the effective
policy is `enabled:true`. When enabled, a poll pulls **only changed packages**
(`emerge --getbinpkgonly --usepkgonly --update --deep --newuse @world`) from the
node's `PORTAGE_BINHOST` subtree. If a package that needs a reboot changed, it drops
the kured sentinel (`/var/run/reboot-required`). kured then drains, cordons and
reboots **one node at a time** inside its own maintenance window. This repo does not
deploy kured (no Application or manifest under `specs/cluster` installs it), so the
cluster must run it for the sentinel to do anything.

`provision_update()` (keys-provision) bakes the cron drop-in as **plumbing** on
every target, so a later opt-in takes effect. The **poller is the runtime gate**. No
policy at all means auto-update is **OFF** (it fails safe to off, never to a pull).

**Superadmin opt-in.** The live `devops/hugmesh-update-policy` ConfigMap (and the
optional KEYS-manifest `.update` block) **enable** and tune it:

| key       | meaning                                              | default        |
|-----------|------------------------------------------------------|----------------|
| `enabled` | master switch; **`true` opts in / enables the pull** | `false` (off)  |
| `cadence` | cron the node runs (rendered into the cron drop-in by keys-provision; the poller treats it as informational) | `0 4 * * *`    |
| `window`  | `HH:MM-HH:MM` local-time gate (live, no re-image)    | `02:00-06:00` in the shipped ConfigMap; empty (any time) in the poller's baked default |
| `reboot`  | `if-needed` \| `never` \| `always` (kured-safe)      | `if-needed`    |
| `staging` | per board/role/`client` cadence (rollout waves)      | `{}`           |

Control-plane nodes read the ConfigMap live on each poll. Worker and client nodes (no
kubeconfig) fall back to the per-node `/etc/hugmesh/update.json`, which is also
default-off. Deleting the ConfigMap reverts every node to the baked default (OFF). A
superadmin sets `enabled:true` to opt a fleet in.
