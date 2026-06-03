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
2. **images** — builds + pushes app container images to the GitLab registry.
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

## Fast binary OS updates via the binhost

Each Gentoo node `emerge --getbinpkg`s from the binhost over the VPN
(`PORTAGE_BINHOST=http://<x86-vpn-ip>:8086/<arch>`, set by keys-provision from
the node inventory). The x86 build emits amd64 binpkgs; the RPi crossdev build
emits arm64 binpkgs — both rsynced to the binhost PVC.
