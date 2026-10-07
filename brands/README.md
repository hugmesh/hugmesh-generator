# brands/ — drop-in brand profiles

A **brand profile** is a plain shell file the image builders `source`. It rebrands the
images and selects the brand's **own isolated mesh**. At build time it rewrites every
namespace, hostname, gateway name, image org, ingress host and title in the baked
cluster payload from the HugMesh defaults to your brand and domain, and it points the
node at the brand's own headscale control plane.

## Files here

| File | Committed? | Contains |
|------|-----------|----------|
| `example.conf` | yes | a complete, safe-to-commit example (no secrets) |
| `local.conf` | yes | the **LAN `.test` profile** — `hugmesh.test`, no OAuth/SMTP/Cloudflare, wildcard DNS on. Used by `make local` (ENV=test). |
| `<yourbrand>.conf` | yes | your brand's branding + domain + mesh (no secrets) |
| `example.yaml`, `acme.yaml` | yes | the structured brand schema plus the `repos[]` tenant-set manifest for the templating pipeline (see [`docs/MESH-TEMPLATING.md`](../docs/MESH-TEMPLATING.md)) |
| `domains.conf` | yes | the multi-domain registry for the per-domain CA loop (`scripts/gen-keystores.sh`); every row is commented out, so a stock build provisions one domain |
| `../brand.conf` | **no** (gitignored) | the same vars **with real passwords/tokens** |

> **Local-first:** `make local` builds the whole fleet against `brands/local.conf`
> with `--env test`, so you can test the cluster on a LAN before any public address
> or Cloudflare exists. See [`docs/LOCAL-TESTING.md`](../docs/LOCAL-TESTING.md).

> Never put real secrets (`DEFAULT_USER_PASS`, `ROOT_PASS`, `VAULT_TOKEN`, …) in a
> committed `brands/*.conf`. Real values go in the gitignored `./brand.conf` or in
> the environment.

## Brandable variables

| Var | Meaning |
|-----|---------|
| `BRAND` | short slug used in names (namespaces, gateways, hostnames) |
| `BRAND_TITLE` | human-readable title shown in UIs/messages |
| `ORG` | GitHub org / GitLab gitops-hosting group / Harbor registry project name |
| `RELEASE_STATE` | `internal` (default; matches a `.test` domain) or `public` |
| `MFA` | `1` renders `mfa.enabled: true` into this brand's gateway Applications (default off); read [`docs/MFA-ROLLOUT.md`](../docs/MFA-ROLLOUT.md) before you set it |
| `CLUSTER_DOMAIN` | base domain (`id.`/`matrix.`/`mastodon.`/`api.` derived) |
| `HEADSCALE_URL` | the brand's **own** headscale control server (its own mesh) |
| `MESH_TAG` | brand-unique ACL tag, e.g. `tag:<brand>` (mesh isolation) |
| `ADMIN_EMAILS` | seeded Casdoor admin / BFF allowlist |
| `TIMEZONE`, `HOSTNAME` | system settings (HOSTNAME empty ⇒ `<BRAND>-<role>`) |
| `HEADSCALE_VERSION`, `TAILSCALE_VERSION` | mesh binary versions |
| `VAULT_ADDR`, `VAULT_KV_MOUNT` | cluster-secret delivery (empty ADDR = offline/USB). `VAULT_KV_MOUNT` is the WRITER side only — the reader is pinned at mount `secret` with the literal `hugmesh/<service>` key prefix, so a non-`hugmesh` brand writes where the cluster does not read (pre-existing; see `brand.conf.example`, #285) |
| `CA_CERT` | path to an EXISTING CA cert (PEM) to use as the cert issuer (optional) |
| `CA_KEY` | **(secret — do not commit)** the CA's private key (PEM) |
| `CA_KEY_PASS` | **(secret — do not commit)** passphrase for `CA_KEY`, if encrypted |

### External CA (optional)

By default the cert generator mints a fresh self-signed root CA. To sign every
generated leaf and service cert with an existing CA instead, set `CA_CERT` + `CA_KEY`
(env, `./brand.conf`, a `brands/*.conf` profile, or the `--ca-cert` / `--ca-key` flags
on `scripts/gen-provision-keys.sh` / `scripts/gen-keystores.sh`). The generators
check the key against the cert, bundle the CA into the truststore so verifiers trust
it, and never overwrite or regenerate it. On the `pki` role it is also seeded as the
kubeadm control-plane CA. Leave both unset to keep the self-signed root.

> `CA_KEY` / `CA_KEY_PASS` are **secrets**. Keep them in the gitignored `./brand.conf`
> or the environment, never in a committed `brands/*.conf`. Through `make`, pass them
> on the command line: `make ... CA_CERT=/path/ca.crt CA_KEY=/path/ca.key` (the
> generators read the key and passphrase from the environment and never echo them).

`HEADSCALE_URL` + `MESH_TAG` make each brand a **separate, isolated mesh**: its own
headscale control plane and a brand-unique tag, so brands never share a tailnet. The
mesh setup honors them at provision time. The profile only declares them; it does not
configure headscale itself.

## Usage

Directly with a builder:

```sh
./build-x86-host-stage4.sh --config brands/example.conf --role backend-gpu
./build-rpi5-stage4.sh     --config brands/example.conf --role frontend
```

Through `make` (threads `--config brands/$(BRAND).conf` into every builder):

```sh
make build-all BRAND=example                       # uses brands/example.conf as-is
make build-all BRAND=acme DOMAIN=acme.example      # override the domain
make x86-backend-gpu BRAND=acme DOMAIN=acme.example HEADSCALE_URL=https://hs.acme.example
```

Precedence: **built-in defaults < the profile < explicit CLI flags**, so `DOMAIN=` and
`HEADSCALE_URL=` on the `make` line override whatever the profile sets.

Auto-detection: copy a profile to `./brand.conf` (gitignored) and the builders pick it
up with no `--config` flag.
