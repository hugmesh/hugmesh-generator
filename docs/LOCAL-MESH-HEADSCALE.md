# Headscale in the local docker mesh (`HEADSCALE=1`)

The local docker mesh (`make stack-up`, [LOCAL-STACK.md](LOCAL-STACK.md)) had no tailnet
control server, so it could not mint the headscale pre-auth key a HugMesh token carries
([HUGMESH-TOKEN.md](HUGMESH-TOKEN.md)), and no tray node could join it.
`make stack-up HEADSCALE=1` adds one. With it, admin-bff and the Studio can issue tokens for
the local mesh, and a tray node can join through the stack's HTTPS front door.

It is **opt-in**, like `TOR=1` and `ANUBIS=1`. Without the knob, the stack's environment, its
compose argv and its rendered `docker compose config` are byte for byte what they were before
this change. `tests/stack/test-headscale-local.sh` checks all three.

## Bring it up

```sh
make stack-up HEADSCALE=1            # also mints the issuer key on first use
make stack-mesh-token-key            # prints the issuer's SHA256: fingerprint again
```

With `DOMAIN=acme.example`, the login server is `https://hs.acme.example:8488`. The domain
comes from the same expression `stack-certs` mints the TLS leaf for, so the name is always
one the leaf covers (`DNS:*.<domain>`).

| knob | default | what it does |
|---|---|---|
| `HEADSCALE` | empty | `1` adds the `headscale` profile, the `compose.headscale.yaml` overlay and the env below |
| `DOMAIN` | `hugmesh.net` | the access domain; the login server is `hs.<domain>` |
| `PUBLIC_HTTPS_PORT` | `8488` | the HTTPS front door's port, which is the login server's port too |
| `HEADSCALE_MESH_ID` | `hugmesh-local` | the mesh id tokens name; the policy's superadmin ssh rule targets `tag:mesh_<id>` |

`stack-down`, `stack-halt` and `stack-clean` always reap the `headscale` profile, so a mesh
started with `HEADSCALE=1` is stopped by a plain `make stack-down` as well. `stack-down`
(`down -v`) drops the tailnet database and admin-bff's API key, so the next start is a fresh
tailnet. It does not touch the issuer key (see below).

## What runs

**`hugmesh-headscale`** (compose.local.yaml, profile `headscale`). The image is built from
`tests/stack/headscale/`: alpine plus the binary from `headscale/headscale:0.23.0`, the
release the node image is tested against. At every start its entrypoint does the following:

1. It renders `/etc/headscale/config.yaml` from `config.yaml.tmpl`. The template mirrors the
   node's `specs/etc/headscale/config.yaml` (policy mode `file`, the same prefixes, sqlite,
   the unix socket) with three differences:
   - `server_url` is `https://hs.<domain>:<PUBLIC_HTTPS_PORT>`.
   - Headscale listens plain on `:8080` inside the compose network. TLS ends at the front
     door.
   - The embedded DERP server is on (region 999) and the public DERP map is off. The local
     mesh must not depend on the internet, and headscale 0.23 refuses an empty DERP map.
2. It renders `/etc/headscale/policy.hujson` from the **device** template,
   `specs/etc/headscale/policy.hujson.tmpl`, which is mounted read-only. The render is what
   `specs/usr/sbin/gen-headscale-policy.sh` produces on a node whose signed export is empty:
   - in `ssh[]`, only the always-emitted superadmin rule (`tag:superadmin` to
     `tag:mesh_<id>`);
   - one dynamic tag owner, `"tag:mesh_<id>": []`, which owns nothing.

   That ownerless entry is required. Headscale 0.23 builds no map for any node while the
   policy names a tag that is neither in `tagOwners` nor forced on some node. Measured on
   this image: `invalid tag. tag:mesh_hugmesh-local isn't owned by a TagOwner and no forced
   tags are defined` on every map request, and the node never reaches Running. On a device,
   the force-tag companion puts `tag:mesh_<id>` on the core nodes; the local mesh has no
   such companion. An empty owner list makes the name resolve without letting any node
   self-advertise it.

   The local mesh therefore enforces the device rules. A pre-auth key may carry
   `tag:hugmesh`. The `dom_`, `mesh_`, `dev_` and `superadmin` tags are server-forced. A fix
   to the device template reaches this mesh on its next start.
3. It runs `headscale configtest` and starts `headscale serve`.
4. It creates the user `hugmesh` if that user is missing.
5. It keeps **admin-bff's API key** in `/run/hugmesh-headscale/admin-bff.apikey` in the
   `headscale-admin-key` volume:
   - The file is 0600 and root-owned.
   - Each key is written to a temp file and renamed into place.
   - A new key (90 days) is created when the file is missing, when headscale no longer lists
     its prefix, or when the key expires within 30 days. The old key is then expired.
   - The key is never printed. The guard scans every container log for it.

The container is healthy once the socket answers and the key file exists. It publishes no
port.

**The door.** `tests/stack/tls-front/default.conf` has a `server_name ~^hs\.` block on the
front door's existing `:8443` listener, with the same certificate and no new port. It proxies
to `hugmesh-headscale:8080` with the file's re-resolve idiom, and it passes the
Upgrade/Connection headers through. The tailscale control channel (`/ts2021`) and DERP
(`/derp`) are both HTTP/1.1 upgrades. headscale's REST API (`/api/`) and `/swagger` are
**404 at the door**: only admin-bff calls the API, and it calls it inside the compose network.
With `TOR=1` the onion's `:443` goes through this same door, so the API stays off the onion
too.

There is deliberately **no network alias `hs.<domain>`** on the headscale container. A
token's login server is `https://hs.<domain>:<port>`. Inside the compose network that alias
would resolve to a container that serves plain `:8080`, so an in-network client that follows
a token would be refused instead of reaching the door. In-network callers use the service
name.

**admin-bff** (`tests/stack/compose.headscale.yaml`). The Makefile adds this overlay with
`-f` only under `HEADSCALE=1`. admin-bff is an unprofiled service, so changing it in
compose.local.yaml would change every plain bring-up. A bind mount of a missing key file
would also make Docker create a root-owned directory in its place. The overlay does three
things:

- It mounts the API-key volume **read-only** at `/run/hugmesh-headscale`.
- It mounts the issuer key as the file secret `/run/secrets/mesh_token_issuer`. It is
  read-only, admin-bff alone gets it, and it is not passed as an env var, so it never shows
  in `docker inspect`.
- It sets the mesh-token settings:

  ```
  APP_MESH_TOKEN_ENABLED=true
  APP_MESH_TOKEN_HEADSCALE_BASE_URL=http://hugmesh-headscale:8080
  APP_MESH_TOKEN_HEADSCALE_API_KEY_PATH=/run/hugmesh-headscale/admin-bff.apikey
  APP_MESH_TOKEN_HEADSCALE_USER=hugmesh
  APP_MESH_TOKEN_MESH=<HEADSCALE_MESH_ID>
  APP_MESH_TOKEN_LOGIN_SERVERS=<domain>=https://hs.<domain>:<PUBLIC_HTTPS_PORT>
  APP_MESH_TOKEN_ISSUER_KEY_PATH=/run/secrets/mesh_token_issuer
  ```

Without `HEADSCALE=1` none of this is set, and admin-bff's mesh-token endpoint stays dark.
`APP_REGISTRY_HEADSCALE_ACL_ENABLED` stays false. That leg pushes the policy over the API,
which needs headscale's policy mode `database`. This headscale runs mode `file`, the device's
mode, so the rendered device template stays in force.

## The issuer key

`make stack-mesh-token-key` mints an ed25519 OpenSSH key in `tests/stack/.mesh-token/issuer`.
The file is gitignored and 0600, and its directory is 0700. `stack-up HEADSCALE=1` runs the
target first. The target prints only the key's `SHA256:` fingerprint (as `ssh-keygen -lf`
prints it), which is what a tray asks the operator to confirm the first time
([HUGMESH-TOKEN.md](HUGMESH-TOKEN.md) "Trust").

Like `stack-certs`, the key is minted once and kept after that. `stack-down` does not remove
it, so the fingerprint that trays trust stays the same across rebuilds of the mesh. To rotate
it, delete the directory:

```sh
rm -rf tests/stack/.mesh-token && make stack-mesh-token-key
```

Every tray then has to trust the new fingerprint. If a directory named `issuer` sits where
the key should be, the target refuses to run. That is the leftover of a bind mount made
before the key existed.

**In-cluster**, the same two secrets come from an ExternalSecret `admin-bff-mesh-token`
(namespace `hugmesh-backend`, ClusterSecretStore `hugmesh-vault`, the
`admin-bff-casdoor-client` shape in `specs/cluster/manifests/external-secrets/secretstore.yaml`):

- `issuerKey` from `hugmesh/mesh-token-issuer` property `private-key`
- `headscaleApiKey` from `hugmesh/headscale-admin` property `api-key`

Both are mounted as a secret volume, not as env vars. That manifest belongs to the admin-bff
side of the mesh-token work, not to this file.

## What the API key can do, honestly

Headscale 0.23 API keys are **unscoped admin keys**. One key can do anything the CLI can. The
mitigations are these:

- The key exists only in this volume and admin-bff's read-only mount.
- admin-bff's mesh-token service calls only the pre-auth-key endpoints.
- The API is reachable only on the compose network, because the door 404s `/api/`.
- The key lives 90 days and is replaced before it expires.

The pre-auth keys admin-bff mints are single-use and short-lived, and they carry exactly
`tag:hugmesh`. Role and domain are never mapped to key tags: the mesh decides those
server-side.

Read the tags back after creating a key. In 0.23, `POST /api/v1/preauthkey` with `aclTags`
stores the tags, but the create response echoes `"aclTags": []`. Measured:
`GET /api/v1/preauthkey?user=hugmesh` and `headscale preauthkeys list` both show
`["tag:hugmesh"]` for the same id. A caller that checks the echo would wrongly conclude the
key is untagged.

## For the Studio's auto-detect

Container: `<project>-hugmesh-headscale-1`, which is `hugmesh-local-hugmesh-headscale-1` for
`make stack-up`. Labels:

| label | value |
|---|---|
| `net.hugmesh.role` | `headscale` |
| `net.hugmesh.headscale.user` | `hugmesh` |
| `net.hugmesh.headscale.login-server` | `https://hs.<domain>:<PUBLIC_HTTPS_PORT>` |
| `net.hugmesh.headscale.domain` | `<domain>` |
| `net.hugmesh.headscale.key-tags` | `tag:hugmesh` |

To mint a key the way the guard does, run this from the host:

```sh
docker exec hugmesh-local-hugmesh-headscale-1 \
  headscale preauthkeys create --user hugmesh --tags tag:hugmesh --expiration 1h
```

The Studio's `mesh_token.mint_and_issue` (from #862) works against this container:
`find_headscale_container` finds it by its `net.hugmesh.role=headscale` label, and unless the
admin names a user, the key is minted for its `net.hugmesh.headscale.user` label (`hugmesh`)
with its `net.hugmesh.headscale.key-tags` label (`tag:hugmesh`), using
`docker exec ... headscale preauthkeys create`. The key-tags label is used only for a key
minted for that label's user; a key for any other named user carries no tags unless they
are given. Measured: a token minted and signed with the key from
`make stack-mesh-token-key` passes `mesh_token.verify`, and Studio's `fingerprint()` equals
the one the target prints.

A node on the host reaches the login server at `https://hs.<domain>:<PUBLIC_HTTPS_PORT>`. That
needs two things:

- `hs.<domain>` must resolve to the host (`127.0.0.1` on the host itself; the host's address
  from a container).
- The node must trust the stack's CA, `tests/stack/.tls-front/ca.crt`. Tailscale is a Go
  program, so `SSL_CERT_FILE` pointing at that file is enough.

The guard's probe does exactly this: host networking, `--add-host hs.<domain>:127.0.0.1` and
`SSL_CERT_FILE`.

## Guard

`tests/stack/test-headscale-local.sh` has a static leg, which runs in CI with no docker:
compose, overlay, door, Makefile argv, the key target run for real, the entrypoint's render and
the image pin. Thirty-one negative controls each break one of those and must turn the guard red.

`HUGMESH_HEADSCALE_LIVE=1` adds a live leg. It runs a throwaway compose project with a unique
name, a free high port and its own CA in a temp dir, and never touches `hugmesh-local`. It
brings up only headscale and the door, and checks the following:

- the key file's mode, and that the key appears in no log;
- a `POST /api/v1/preauthkey` with `aclTags: ["tag:hugmesh"]`;
- the API refuses a call without the bearer, and the door answers 404 for `/api/`;
- a real tailscale node joins through the door while self-advertising `tag:superadmin`;
- headscale reports `forced_tags == ["tag:hugmesh"]` and `tag:superadmin` in `invalid_tags`.

That last assertion needs the device template to stop naming the node user `hugmesh` as
`tag:superadmin`'s owner. That is a separate fix in the mesh-token work. Until it lands, the
assertion is red, and its message says so.
