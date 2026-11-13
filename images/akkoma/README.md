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
- **linux/amd64 and linux/arm64.** Akkoma is selectable on rpi5 and x86 meshes
  (`optional-services.yaml` `buildGate`) and on Jetson, whose builder runs the same
  `gate_optional_services` from `scripts/_optional-services-lib.sh` but does not read
  the `buildGate` column. Unlike the cluster's other first-party images, which it
  builds in-cluster into Harbor for its own architecture, this one is pulled from
  GHCR, so the published index must carry both. The release workflow builds arm64
  under QEMU, and the build stage sets `ERL_FLAGS="+JMsingle true"` because the BEAM
  JIT's dual-mapped code memory crashes under QEMU. Pull requests build and boot-test
  arm64 natively on `ubuntu-24.04-arm`. The release's QEMU leg first ran on the first
  push to `main` (run 43210930759, green) and published an index with both
  architectures; if that leg fails, nothing is pushed. The release boot-tests the
  amd64 image only, so the published arm64 image has been built but never booted
  (see "Jetson and arm64" below).
- **The MRF** (`mrf/force_local_for_users_policy.ex`) is compiled in and enforces
  nothing. See "The MRF" below and [`docs/DOMAIN-LOCK.md`](../../docs/DOMAIN-LOCK.md).

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

Every Akkoma ref in `specs/cluster` names one image by digest. The refs are in
`akkoma.yaml` ×2, `admin-sync-job.yaml`, `domainlock-sync-job.yaml` and
`test-runner/akkoma-peer.yaml` ×2. `tests/scripts/test-akkoma-image-pin.sh` finds every
ref and requires that they all carry the same digest.

**Pinned now (2026-11-12):**
`ghcr.io/hugmesh/hugmesh-akkoma:0.4.0-beta.1@sha256:ad4d894e603cac04df6381d7036c587668bd582c37548aace28d89d6392f9bbf`

- This is the `akkoma-v0.4.0-beta.1` release, run [43364230745](https://github.com/hugmesh/hugmesh-generator/actions/runs/43364230745),
  cut by the 0.5.0-beta.1 org release at `ccdeca49`. It is an OCI index with
  linux/amd64 and linux/arm64 manifests, tagged `0.4.0-beta.1`, `beta` and
  `sha-ccdeca497fa5`. The ref names the release tag; the digest is what the kubelet
  pulls. (images/akkoma/VERSION has since moved to 0.5.0-beta.1, the generator's
  release line; the next release cuts that.)
- Verified, and all three passed:

  ```
  cosign verify ghcr.io/hugmesh/hugmesh-akkoma@sha256:ad4d894e603cac04df6381d7036c587668bd582c37548aace28d89d6392f9bbf \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github.com/hugmesh/hugmesh-generator/\.github/workflows/akkoma-release\.yml@refs/tags/akkoma-v0\.4\.0-beta\.1$'
  gh attestation verify oci://ghcr.io/hugmesh/hugmesh-akkoma@sha256:ad4d894e603cac04df6381d7036c587668bd582c37548aace28d89d6392f9bbf --repo hugmesh/hugmesh-generator
  gh attestation verify oci://ghcr.io/hugmesh/hugmesh-akkoma@sha256:ad4d894e603cac04df6381d7036c587668bd582c37548aace28d89d6392f9bbf --repo hugmesh/hugmesh-generator --predicate-type https://spdx.dev/Document/v2.3
  ```

  The signing certificate's subject is `akkoma-release.yml@refs/tags/akkoma-v0.4.0-beta.1`.
  The attestations are SLSA provenance and an SPDX 2.3 SBOM.
- Booted from GHCR by digest, not from a local build, with the `akkoma-config`
  ConfigMap as shipped and a throwaway Postgres. It migrated, started and answered
  `/api/v1/instance` as `mastodon.hugmesh.net`, version
  `2.7.2 (compatible; Akkoma 3.20.1)`.

To re-pin, for example after a tagged release:

1. Read the digest from the release run's summary, or with
   `docker buildx imagetools inspect ghcr.io/hugmesh/hugmesh-akkoma:<tag>`. Verify it
   with the `cosign verify` and `gh attestation verify` lines the run prints.
2. In one change, replace the ref at every site with
   `ghcr.io/hugmesh/hugmesh-akkoma:<tag>@sha256:<digest>`.
3. Boot it: `bash images/akkoma/smoke-test.sh ghcr.io/hugmesh/hugmesh-akkoma@sha256:<digest> 3.20.1`
   boots both cluster ConfigMaps as shipped.

**Going back to a placeholder.** The guard still accepts the pre-release state: a
repeated-character digest marked `PLACEHOLDER digest` on its line. While a placeholder
is in place, `akkoma` must be OFF in every default source:

- the builder lib;
- the three cluster builders (x86, rpi5, jetson);
- `build-menu.sh`'s `OPT_SERVICES` default and its pre-ticked services;
- Studio's `BUILTIN_DEFAULT_SERVICES`;
- the registry's `default:`, the installed-services baseline, the seed OptionalService
  and the federation `gate.sql`;
- the `akkoma-peer.yaml` line in `specs/cluster/manifests/test-runner/kustomization.yaml`.

That bundle syncs from git on every ENV=test mesh whatever the selection.

**Explicit selection is always allowed.** `--optional-services akkoma`, `all`, a
`brand.conf` list or a ticked box bakes Akkoma whatever the default says (operator
decision, 2026-11-12).

## Settled for default-on (2026-11-12)

### Media host

**Uploads stay on the instance's own host:** `https://<instance host>/media/`, in both
ConfigMaps.

`pleroma start` refuses to run with no `config :pleroma, Pleroma.Upload, base_url: ...`,
so one must be set. The cluster has no media host to move uploads to:

- the be-gateway's `mastodon-web` route already sends every path on the mastodon
  host to Akkoma;
- route-access gates `/media/**` to `ROLE_MASTODON` (and MOD/ADMIN);
- cloudflared, DNS and the certificate already cover that host;
- a `media.<domain>` name would today fall into cloudflared's `*.<domain>` rule, which
  serves public user profiles.

**The trade-off.** Upstream advises a separate host, because an upload served from
the instance's own origin is an XSS risk. Akkoma logs `Your Akkoma Host and your
Upload base_url's host are the same!` at error level on every boot; it only logs.

Measured on the published image with the as-shipped ConfigMap:

| Upload | Served as | Headers |
|---|---|---|
| `.html` | `application/octet-stream` | `content-security-policy: sandbox`, `x-content-type-options: nosniff` |
| `.svg` | `image/svg+xml` | `content-security-policy: sandbox`, `x-content-type-options: nosniff` |

`sandbox` gives the document an opaque origin, so a script in an uploaded file cannot
read the instance's cookies or storage, in any browser that honours CSP.

What remains is a client that ignores the header. A separate media host would close
that too. To make the move:

- reserve the name ahead of the vanity wildcard in cloudflared;
- add DNS and a certificate;
- add a be-gateway route and route-access rows;
- add a `rebrand_sysroot`-safe literal in both ConfigMaps.

### Branded meshes

**Every brand pulls the HugMesh-published image.**

`rebrand_sysroot` in the x86, rpi5 and Jetson builders now hides
`ghcr.io/hugmesh/hugmesh-akkoma` behind `@@SDSYSAKKOMAIMG@@` and restores it last.
Before, it turned the ref into `ghcr.io/<org>/<brand>-akkoma@sha256:...`: the same
digest under a name that does not hold it.

The rewrite only ever hit the baked copy:

- on a branded device, `apps/30-akkoma.yaml` names the brand's own generator repo;
- ArgoCD reads `specs/cluster/manifests/akkoma` from there;
- a fork of this repository carries this ref verbatim.

The exemption makes the baked tree say what the cluster pulls.

The image carries no brand material: the instance name, host and contact come from
the ConfigMap. A brand that wants its own image must publish it, sign it, and pin it
in its own fork. `test-akkoma-image-pin.sh` runs each builder's real
`rebrand_sysroot` with a custom brand and org, and catches the rule's removal from any
one of the three.

### The MRF

**Domain-lock's Mastodon leg is not enforced.** Measured on the published image:

- `ForceLocalForUsersPolicy` is compiled in: `Code.ensure_loaded?` is true.
- It is not running. The active policy list, and nodeinfo's `mrf_policies`, are
  upstream's defaults only: ObjectAge, Tag, Hashtag, InlineQuote, NormalizeMarkup and
  DirectMessageDisabled.

Listing it under `:mrf policies` would still enforce nothing:

- The module reads `[:mrf_force_local, :forced_actors]` as a `MapSet`.
- The commented-out block in `akkoma-config` sets
  `Pleroma.Web.ActivityPub.MRF.ForceLocalForUsersPolicy, forced_actors:`, a different
  key.
- `domainlock-sync-job.yaml` writes with `pleroma_ctl config set ...`. That is not a
  `pleroma_ctl` task in 3.20.1: it raises `FunctionClauseError` in
  `Mix.Tasks.Pleroma.Config.run/1` and exits non-zero.

So the set the module reads is always empty, and `force_local?/1` is false for every
actor. Default-on Akkoma federates normally. Domain-lock for Mastodon users must not
be advertised until all of the following are done and tested against this image:

- the key and the write path are made to agree;
- the module is validated;
- the Job is wired in.

### Jetson and arm64

**No Akkoma-specific Jetson gate is needed.**

`build-jetson-stage4.sh` runs the shared `gate_optional_services`, so a Jetson cluster
image bakes Akkoma only when it is selected, the same as rpi5 and x86. Its default now
includes Akkoma again, like the others.

The published index has a linux/arm64 manifest. It was built under QEMU by the release
and has not been booted anywhere: the release boot-tests amd64 only, and pull requests
boot-test their own native arm64 build, not the published bytes. The first arm64 mesh
that syncs this is the first boot of that image. Verify it with
`smoke-test.sh ghcr.io/hugmesh/hugmesh-akkoma@sha256:<digest> 3.20.1` on an arm64
host.
