# DevOps platform (`devops` namespace, x86_64 host)

All GitOps/CI/forge tooling runs in the **`devops`** namespace, pinned to the
x86_64 host (the Pis are arm64) and storing data on the host's local disks +
attached USB (the `snapdragon-local` StorageClass). Reachable only over the
headscale/tailscale VPN — never exposed externally; **no keys are served on any
web interface.**

| Component | What | Access |
|---|---|---|
| **ArgoCD** | GitOps engine; syncs `specs/cluster/apps`. Hard-pinned `kubernetes.io/arch=amd64`. | VPN, Casdoor admins |
| **GitLab** (`apps/03-gitlab.yaml`) | Internal forge; pull-mirrors **every** Snapdragon-Systems repo; runs CI. Casdoor OIDC, admin-only, no public sign-up. | `gitlab.<domain>` over VPN |
| **GitLab Runner** (`apps/04-gitlab-runner.yaml`) | Privileged CI runner on the x86 host (root + crossdev + qemu) — builds ISOs + images. | in-cluster |
| **Binhost** (`apps/02-binhost.yaml`) | Gentoo binary-package host; serves `/binpkgs/{arm64,amd64}` over the VPN (hostPort 8086). | every Gentoo node |
| **local-path** | StorageClass `snapdragon-local` from device disk (`/mnt/data`) + USB (`/mnt/usb`). | cluster default |

## CI: build + deliver all ISOs and images

`.gitlab-ci.yml` (runs on the privileged x86 runner):

1. **iso** — `scripts/build-all-roles.sh` (pki/backend/frontend, aarch64) + `build-x86-host-stage4.sh` (x86 host).
2. **images** — ⏳ **stub.** The `build:images` job is currently an `echo`
   placeholder; the **app** container images (gateway, frontends, BFFs, …) are
   built from **their own repos in the GitLab org mirror**, not by this job. A
   general Argo / in-cluster image-build pipeline is **NOT started**. The one
   in-cluster image builder that IS done is the **service-catalog Kaniko builder**
   (`apps/54-service-catalog-builder.yaml` + `manifests/service-catalog-builder/`,
   merged **PR #110**, ships dark): a per-build Kaniko Job template the admin-bff
   `AddService` task instantiates — it is not the general app-image pipeline.
3. **deliver** — uploads each ISO to the GitLab generic package registry under a
   stable `…/packages/generic/iso/latest/<name>.iso` path.

**ISOs contain no keys** — KEYS material is supplied from the USB stick at first
boot, never baked into or published with an ISO.

The **admin UI** (`snapdragon-admin-ui`) shows download links to those latest
ISO artifacts (admin-only; the BFF exposes `/bff/admin/isos`).

## Mirror the org into GitLab

`scripts/gitlab-mirror-org.sh` creates a **pull mirror** in GitLab for every
Snapdragon-Systems GitHub repo (`mirror_trigger_builds=true`), so CI builds from
a complete in-VPN copy. Repos contain no secrets (keys are git-ignored and live
only on the USB + Vault), so the mirror exposes nothing sensitive.

## Forgejo + the GitOps source migration (⏳ PARTIAL — scaffold present, flip live-gated)

The move from "ArgoCD syncs straight from GitHub" toward an **in-cluster Forgejo**
source-of-truth is **scaffolded but not cut over**:

- ✅ **Present (Phase 5/6 scaffold):** the Forgejo deploy (`apps/09-forgejo.yaml`),
  the catalog ApplicationSet (`apps/13-service-catalog.yaml`) — already configured
  with an `scmProvider` generator pointing at the **in-cluster Forgejo**
  (`http://forgejo.snapdragon-pki.svc.cluster.local:3000`, `repositoryMatch
  ^snapdragon-`) — and the deploy contract
  (`specs/cluster/catalog/snapdragon-deploy.example.yaml`).
- ⏳ **Remaining (live-gated):** the actual GitOps **source flip** needs a booted
  Forgejo + an admin + OIDC + the GitHub→Forgejo org mirror + a read token in the
  `forgejo-scm-token` Secret (ns `devops`) before the ApplicationSet can scan
  anything real (the manifest itself flags these as prerequisites). And **no
  service repo has adopted `snapdragon-deploy.yaml` + a `deploy/` kustomize tree
  yet** — that adoption is prep-able now (no live cluster required), it just hasn't
  been done.

## Fast binary OS updates via the binhost

Each Gentoo node `emerge --getbinpkg`s from the binhost over the VPN
(`PORTAGE_BINHOST=http://<x86-vpn-ip>:8086/<arch>`, set by keys-provision from
the node inventory). The x86 build emits amd64 binpkgs; the RPi crossdev build
emits arm64 binpkgs — both rsynced to the binhost PVC.
