# brands/ — drop-in brand profiles

A **brand profile** is a plain shell file the image builders `source` to rebrand
the images and select the brand's **own isolated mesh**. It rewrites every
namespace, hostname, gateway name, image org, ingress host and title in the
baked cluster payload from the HugMesh defaults to your brand/domain at build
time, and points the node at the brand's own headscale control plane.

## Files here

| File | Committed? | Contains |
|------|-----------|----------|
| `example.conf` | yes | a complete, safe-to-commit example (no secrets) |
| `local.conf` | yes | the **LAN `.test` profile** — `hugmesh.test`, no OAuth/SMTP/Cloudflare, wildcard DNS on. Used by `make local` (ENV=test). |
| `<yourbrand>.conf` | yes | your brand's branding + domain + mesh (no secrets) |
| `../brand.conf` | **no** (gitignored) | the same vars **with real passwords/tokens** |

> **Local-first:** `make local` builds the whole fleet against `brands/local.conf`
> with `--env test`, so the cluster is LAN-testable before any public address or
> Cloudflare. See [`docs/LOCAL-TESTING.md`](../docs/LOCAL-TESTING.md).

> Never put real secrets (`DEFAULT_USER_PASS`, `ROOT_PASS`, `VAULT_TOKEN`, …) in
> a committed `brands/*.conf`. Real values go in the gitignored `./brand.conf`
> or in the environment.

## Brandable variables

| Var | Meaning |
|-----|---------|
| `BRAND` | short slug used in names (namespaces, gateways, hostnames) |
| `BRAND_TITLE` | human-readable title shown in UIs/messages |
| `ORG` | GitHub org / container-image namespace |
| `CLUSTER_DOMAIN` | base domain (`id.`/`matrix.`/`mastodon.`/`api.` derived) |
| `HEADSCALE_URL` | the brand's **own** headscale control server (its own mesh) |
| `MESH_TAG` | brand-unique ACL tag, e.g. `tag:<brand>` (mesh isolation) |
| `ADMIN_EMAILS` | seeded Casdoor admin / BFF allowlist |
| `TIMEZONE`, `HOSTNAME` | system settings (HOSTNAME empty ⇒ `<BRAND>-<role>`) |
| `HEADSCALE_VERSION`, `TAILSCALE_VERSION` | mesh binary versions |
| `VAULT_ADDR`, `VAULT_KV_MOUNT` | cluster-secret delivery (empty ADDR = offline/USB). `VAULT_KV_MOUNT` is the WRITER side only: `gen-cluster-secrets.sh` writes to `<VAULT_KV_MOUNT>/<BRAND>/<service>`, while the cluster's ExternalSecrets read mount `secret` and the literal key prefix `hugmesh/<service>`. So a profile with a non-`hugmesh` `BRAND`, or a non-`secret` mount, writes where the cluster does not read; the base path is NOT derived from the brand on the reading side (pre-existing; see `brand.conf.example` and `scripts/gen-cluster-secrets.sh`, #285) |
| `CA_CERT` | path to an EXISTING CA cert (PEM) to use as the cert issuer (optional) |
| `CA_KEY` | **(secret — do not commit)** the CA's private key (PEM) |
| `CA_KEY_PASS` | **(secret — do not commit)** passphrase for `CA_KEY`, if encrypted |

### External CA (optional)

By default the cert generator mints a fresh self-signed root CA. Set `CA_CERT` +
`CA_KEY` (env, `./brand.conf`, a `brands/*.conf` profile, or the `--ca-cert` /
`--ca-key` flags on `scripts/gen-provision-keys.sh` / `scripts/gen-keystores.sh`)
to sign **every** generated leaf/service cert with that existing CA instead. The
provided CA is validated (the key must match the cert), bundled into the
truststore so verifiers trust it, and is **never** overwritten or regenerated.
On the `pki` role it is also seeded as the kubeadm control-plane CA. Leave them
unset to keep the self-signed-root behavior.

> `CA_KEY` / `CA_KEY_PASS` are **secrets** — keep them in the gitignored
> `./brand.conf` or the environment, never in a committed `brands/*.conf`.
> Through `make`, pass them on the command line:
> `make ... CA_CERT=/path/ca.crt CA_KEY=/path/ca.key` (the key/passphrase are
> read from the environment by the generators, never echoed).

`HEADSCALE_URL` + `MESH_TAG` make each brand a **separate, isolated mesh**: its
own headscale control plane and a brand-unique tag, so brands never share a
tailnet. (The mesh setup honors these at provision time; this profile only
declares them — it does not configure headscale itself.)

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

Precedence: **built-in defaults < the profile < explicit CLI flags**, so
`DOMAIN=`/`HEADSCALE_URL=` on the `make` line override whatever the profile sets.

Auto-detection: if you copy a profile to `./brand.conf` (gitignored), the
builders pick it up with no `--config` flag.

## The brand record and the generated profile

The Studio does not write into this folder. Its one description of a mesh's brands —
the superbrand and the brands under it, with their looks and the ways to reach them —
is the **brand record** (`brand-record.json` in the Studio state folder; see
[`../docs/BRAND-MODEL.md`](../docs/BRAND-MODEL.md)). From it the Studio **generates**
a profile in this file's format (`python3 -m hugmesh_studio.core.brand_model profile
--record FILE --out PROFILE`): every value single-quoted and limited to a safe
character set, re-parsed strictly before a builder sources it, so a brand title can
never run code in a builder. A hand-written `brands/<yourbrand>.conf` still works as
before. A *brand's* id must not name a profile here (`make BRAND=<id>` would source a
whole-mesh profile for one brand, and the record refuses it); the *superbrand's* id is
the builder's `BRAND` and may match a profile — `example` and `local` are exactly such
files — in which case the builder sources that hand-written file as it always has and
the generated profile is a second description of the same brand, written to the path
the Studio is told, never into this folder.
