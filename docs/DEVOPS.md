# DevOps platform (`devops` namespace, x86_64 host)

All GitOps/CI/forge tooling runs in the **`devops`** namespace, pinned to the
x86_64 host (the Pis are arm64) and storing data on the host's local disks +
attached USB (the `hugmesh-local` StorageClass). Reachable only over the
headscale/tailscale VPN — never exposed externally; **no keys are served on any
web interface.**

| Component | What | Access |
|---|---|---|
| **ArgoCD** | GitOps engine; syncs `specs/cluster/apps`. Hard-pinned `kubernetes.io/arch=amd64`. | VPN, Casdoor admins |
| **GitLab** (`apps/03-gitlab.yaml`) | Internal forge; pull-mirrors **every** Snapdragon-Systems repo; runs CI. Casdoor OIDC, admin-only, no public sign-up. | `gitlab.<domain>` over VPN |
| **GitLab Runner** (`apps/04-gitlab-runner.yaml`) | Privileged CI runner on the x86 host (root + crossdev + qemu) — builds ISOs + images. | in-cluster |
| **Binhost** (`apps/02-binhost.yaml`) | Gentoo binary-package host; serves `/binpkgs/{arm64,amd64}` over the VPN (hostPort 8086). | every Gentoo node |
| **local-path** | StorageClass `hugmesh-local` from device disk (`/mnt/data`) + USB (`/mnt/usb`). | cluster default |

## CI: build + deliver all ISOs and images

`.gitlab-ci.yml` (runs on the privileged x86 runner):

1. **iso** — `scripts/build-all-roles.sh` (pki/backend/frontend, aarch64) + `build-x86-host-stage4.sh` (x86 host).
2. **images** — The `build:images` job dispatches into the **in-cluster Kaniko image-build pipeline** (`specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml`). It is OPT-IN (guarded by `IMAGE_BUILDER_ENABLED`; no-ops until an operator enables `apps-optional/60-image-builder.yaml` and provides a cluster `KUBECONFIG`). The service-catalog Kaniko builder (PR #110) is a separate per-`AddService` template, not the general pipeline.
3. **deliver** — uploads each ISO to the GitLab generic package registry under a
   stable `…/packages/generic/iso/latest/<name>.iso` path.

**ISOs contain no keys** — KEYS material is supplied from the USB stick at first
boot, never baked into or published with an ISO.

The **admin UI** (`hugmesh-admin-ui`) shows download links to those latest
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
  (`http://forgejo.hugmesh-pki.svc.cluster.local:3000`, `repositoryMatch
  ^hugmesh-`) — and the deploy contract
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

### Opt-in host-binary auto-update (default-off)

Every generated host/node **and** client image **bakes** the auto-update plumbing,
but it is **off by default** — a superadmin must **opt in** to activate it. A baked
`hugmesh-update` poller (`/usr/local/sbin/hugmesh-update`) runs from an
`/etc/cron.d/hugmesh-update` drop-in (cronie, OpenRC — not systemd) on the
configured cadence, plus once at boot via the `hugmesh-update` OpenRC oneshot, but
each poll **skips** unless the effective policy is `enabled:true`. When enabled, a
poll pulls **only changed packages**
(`emerge --getbinpkgonly --usepkgonly --update --deep --newuse @world`) from the
node's `PORTAGE_BINHOST` subtree, then — when a reboot-requiring package changed —
drops the kured sentinel (`/var/run/reboot-required`) so kured drains+cordons+reboots
**one node at a time** inside its own maintenance window.

`provision_update()` (keys-provision) bakes the cron drop-in as **plumbing** on every
target (so a later opt-in actually fires), and the **poller is the runtime gate**. The
**absence** of any policy means auto-update is **OFF** (fail-safe to off, never to a
pull).

**Superadmin opt-in** — the live `devops/hugmesh-update-policy` ConfigMap (and the
optional KEYS-manifest `.update` block) **enable** and tune it:

| key       | meaning                                              | default        |
|-----------|------------------------------------------------------|----------------|
| `enabled` | master switch; **`true` opts in / enables the pull** | `false` (off)  |
| `cadence` | cron the node runs                                   | `0 4 * * *`    |
| `window`  | `HH:MM-HH:MM` local-time gate (live, no re-image)    | `02:00-06:00`  |
| `reboot`  | `if-needed` \| `never` \| `always` (kured-safe)      | `if-needed`    |
| `staging` | per board/role/`client` cadence (rollout waves)      | `{}`           |

Control-plane nodes read the ConfigMap live each poll; worker/client nodes (no
kubeconfig) fall back to the per-node `/etc/hugmesh/update.json` — still
default-off. Deleting the ConfigMap reverts every node to the baked default (OFF); a
superadmin sets `enabled:true` to opt a fleet in.
