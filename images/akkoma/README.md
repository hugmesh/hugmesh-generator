# hugmesh-akkoma

Akkoma built from upstream source, with the HugMesh ForceLocalForUsers MRF compiled in.
Published as `ghcr.io/hugmesh/hugmesh-akkoma` by
[`.github/workflows/akkoma-release.yml`](../../.github/workflows/akkoma-release.yml).
Pull requests that touch this directory build it, without pushing, in
[`akkoma-image-ci.yml`](../../.github/workflows/akkoma-image-ci.yml).

## Why HugMesh builds its own

Upstream publishes no container image. Its `docker-compose.yml` builds one locally,
and its CI publishes OTP release zips only. The registry host the cluster manifests
used to name does not resolve. The operator decided on 2026-11-11 to build Akkoma
ourselves from the `v3.20.1` tag.

## What is pinned

| Input | Pin | Where |
|---|---|---|
| Upstream source | commit `98dd958886a8b0ef65d5bd827aba3789f1dc5116`, which is tag `v3.20.1` at `https://akkoma.dev/AkkomaGang/akkoma` | `AKKOMA_COMMIT`, `AKKOMA_VERSION` |
| Elixir 1.19.7 / OTP 28.5.0.8 toolchain | `hexpm/elixir` on Debian trixie, by index digest | `ELIXIR_IMAGE` |
| Runtime | `debian:trixie-20261104-slim`, by index digest | `RUNTIME_IMAGE` |
| Dependencies | upstream's `mix.lock` (hex checksums, git commit ids), with `--check-locked` | build stage |
| Hex | 2.7.0 | `HEX_VERSION` |
| rebar3 | 3.28.0 for OTP 28, from `builds.hex.pm`, checked against its SHA-512 | `REBAR3_VERSION`, `REBAR3_URL`, `REBAR3_SHA512` |

Debian packages float within the pinned base's suite, so security updates arrive on
the next build. The build fetches upstream by commit id. It fails if
`git rev-parse HEAD` is not that commit, or if `mix.exs` at that commit does not
declare `AKKOMA_VERSION`. `check-upstream-pin.sh` refuses a build whose upstream tag
has moved off the pinned commit. The release workflow's version job and the PR build
both run it.

The upstream test matrix covers Elixir 1.15/OTP 25 through 1.19/OTP 28. The toolchain
here is the top of that range.

## What the image is

- **An OTP release** at `/opt/akkoma`, owned by root. The runtime user cannot change
  the code it runs.
- **Runs as `akkoma` (1000:1000).** `/var/lib/akkoma/{uploads,static,modules}` are the
  release defaults and are owned by that user.
- **Config is read from `/etc/akkoma/config.exs`.** The release refuses a config file
  that is world-readable or group-writable. Mount it at mode `0440` and give the pod
  `fsGroup: 1000`. A ConfigMap's default `0644` crash-loops it at boot.
- **No baked Erlang cookie.** The release step writes a random cookie into
  `releases/COOKIE`, and a cookie in a published image is public. The build deletes it.
  `hugmesh-env.sh` (appended to the release's `env.sh`) gives each container its own
  cookie under `RELEASE_TMP=/tmp`, and every command in that container reuses it.
  `RELEASE_COOKIE` overrides this.
- **Distribution and epmd listen on loopback only** (`hugmesh-vm.args`,
  `ERL_EPMD_ADDRESS`). Only `:4000` listens off loopback.
- **`/tmp` must be writable.** The release writes its generated `sys.config` there,
  and the cookie lives there. Under `readOnlyRootFilesystem`, mount an `emptyDir` at
  `/tmp`.
- **`pleroma_ctl` in another pod needs `PLEROMA_CTL_RPC_DISABLED=true`.** It then
  evaluates the task against the shared database instead of making an RPC call to a
  node that does not run there. The admin-sync Job is that case.
- **`python3`** is included for the `akkoma-admin-sync` and `akkoma-domainlock-sync`
  Jobs, which run their stdlib-only script next to `pleroma_ctl`.
- **`HEALTHCHECK`** is `curl` against `/api/v1/instance`.
- **Not included: ffmpeg and ImageMagick.** They are needed only for the media preview
  proxy and the `AnalyzeMetadata` upload filter, and both are off unless configured.
- **linux/amd64 and linux/arm64.** Akkoma is selectable on rpi5, Jetson and x86 meshes
  (`optional-services.yaml` `buildGate`). Unlike the cluster's other first-party
  images, which it builds in-cluster into Harbor for its own architecture, this one is
  pulled from GHCR, so the published index must carry both. The release workflow
  builds arm64 under QEMU, and the build stage sets `ERL_FLAGS="+JMsingle true"`
  because the BEAM JIT's dual-mapped code memory crashes under QEMU. Pull requests
  build and boot-test arm64 natively on `ubuntu-24.04-arm`. The release's QEMU leg
  first runs on the first push to `main`; if it fails, nothing is pushed.
- **The MRF** (`mrf/force_local_for_users_policy.ex`) is compiled in and does nothing
  until config lists it under `:mrf policies`. See
  [`docs/DOMAIN-LOCK.md`](../../docs/DOMAIN-LOCK.md).

## AGPL-3.0

Akkoma is AGPL-3.0, and this image is a derivative work. Its complete corresponding
source is the upstream commit above plus this directory at the release tag. The image
labels (`net.hugmesh.akkoma.upstream-*`) and every GitHub Release name both.

The running server does not yet point its network users at that source. The only
source link Akkoma serves is the `repository` field of nodeinfo 2.1, which is
`Pleroma.Application.repository/0`: `mix.exs`'s `source_url`, compiled in at build
time. At the pinned commit that is upstream's `https://akkoma.dev/AkkomaGang/akkoma`,
and no environment variable changes it. The AGPL §13 offer of this image's own
source is still to do; see [`docs/DOMAIN-LOCK.md`](../../docs/DOMAIN-LOCK.md),
"Custom Akkoma image build + AGPL source publication".

## Testing locally

```
docker buildx build --platform linux/amd64 --load -t hugmesh-akkoma:local images/akkoma
bash images/akkoma/smoke-test.sh hugmesh-akkoma:local 3.20.1
```

`smoke-test.sh` uses throwaway Docker resources only, and removes them on exit. It
checks that:

- the image ships no cookie and runs as uid 1000;
- a 0644 config is refused and a 0440 one is read;
- `pleroma_ctl migrate` succeeds against Postgres with a read-only root, a tmpfs
  `/tmp` and no capabilities;
- `pleroma start` serves `/api/v1/instance` with the expected version, and the
  `HEALTHCHECK` turns healthy;
- `pleroma_ctl` works over RPC from a second process, and in eval mode from a separate
  container;
- only `:4000` listens off loopback;
- `python3` has what the sync Jobs import;
- the cluster's own configs boot. It extracts `config.exs` verbatim from the
  `akkoma-config` ConfigMap in `specs/cluster/manifests/akkoma/akkoma.yaml` and from
  `akkoma-peer-config` in `specs/cluster/manifests/test-runner/akkoma-peer.yaml`, and
  requires each to migrate a fresh database and serve `/api/v1/instance` as the host
  it declares. `SMOKE_AKKOMA_MANIFEST` and `SMOKE_PEER_MANIFEST` point it at other
  copies of those files. The PR build runs when either manifest changes.

## Releasing

The image has its own tag prefix, `akkoma-v`. `images/akkoma/VERSION` is the image's
version, not Akkoma's, and its X.Y must stay on the mesh-node image's line, because
the repository has one `release/X.Y` branch. See
[`docs/RELEASING.md`](../../docs/RELEASING.md), "The Akkoma image".

- A merge to `main` that touches this directory publishes `:main` and
  `:sha-<12>`, signed and attested.
- A tag `akkoma-vX.Y.Z-beta.N` on `main` publishes `:X.Y.Z-beta.N` and `:beta`.

## Pinning

Until the first release, every Akkoma ref in `specs/cluster` carries the placeholder
digest `sha256:000…0`, marked `PLACEHOLDER digest` on its line, and `akkoma` is
DEFAULT-OFF everywhere. `tests/scripts/test-akkoma-image-pin.sh` refuses `akkoma` back
in any default while the placeholder is in place. After a release:

1. Read the digest from the release run's summary, or with
   `docker buildx imagetools inspect ghcr.io/hugmesh/hugmesh-akkoma:<version>`. Verify
   it with the `cosign verify` and `gh attestation verify` lines the run prints.
2. In one change, replace the placeholder in all six refs with
   `ghcr.io/hugmesh/hugmesh-akkoma:<version>@sha256:<digest>`, and drop the
   `PLACEHOLDER digest` comments. The refs are in `akkoma.yaml` ×2,
   `admin-sync-job.yaml`, `domainlock-sync-job.yaml` and
   `test-runner/akkoma-peer.yaml` ×2.
3. Re-wire `akkoma-peer.yaml` in `specs/cluster/manifests/test-runner/kustomization.yaml`.
   It is unwired while the digest is the placeholder, because that bundle syncs from
   git on every ENV=test mesh whatever the selection.
4. Then turn `akkoma` back on in the defaults: the builder lib, the three cluster
   builders (x86, rpi5, jetson), `build-menu.sh`'s pre-ticked services, Studio's
   `BUILTIN_DEFAULT_SERVICES`, the registry's `default:`, the installed-services
   baseline, the seed OptionalService and the federation `gate.sql`. The test-suite
   expectations that this change moved must move back too.

Three things must be settled before the default goes back on:

- **A separate media host, or a decision to keep the shared one.** `pleroma start`
  refuses to run with NO `config :pleroma, Pleroma.Upload, base_url: ...` ("No
  base_url set for uploads"). That is the only refusal: a `base_url` on the
  instance's own host boots, and upstream logs an error-level warning about it
  (`check_uploader_base_url_is_not_base_domain` only logs). Both cluster configs
  therefore set `https://<instance host>/media/`, which the be-gateway's
  `mastodon-web` route, cloudflared and the certificate already serve.
  Upstream advises a separate host because uploads served from the instance's own
  origin are an XSS risk. Moving to `media.<domain>` needs a DNS name, a
  certificate, a cloudflared rule and a gateway route.
- **Branded meshes.** On a non-default brand, `rebrand_sysroot` in both builders turns
  `ghcr.io/hugmesh/hugmesh-akkoma@sha256:...` into
  `ghcr.io/<org>/<brand>-akkoma@sha256:...`, the same digest under a name that does
  not hold it. Either exempt this ref from the rebrand, so every brand pulls the
  HugMesh-published image (a brand-neutrality decision), or have each brand publish
  and pin its own.
- **The MRF is still a skeleton.** See its header. It is inert until listed under
  `:mrf policies`.
