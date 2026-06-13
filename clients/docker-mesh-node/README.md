# Snapdragon Docker mesh-node (FD-09)

Turn **any Linux or Windows machine that already runs Docker** into a background
Snapdragon mesh node — **no OS flash, no reinstall**. This is the *third* onboarding
form, alongside the appliance images (Pi / x86) and the client desktop images
(laptop / chromebook / desktop). It uses the **same local-file keys** the appliance
images consume off the KEYS-USB, plus a **one-line Casdoor login**.

Use it when someone needs to lend a workstation/laptop to the mesh quickly, or when
an admin hands out a copy-paste `docker run` to onboard a remote box.

---

## What it does

1. Reads keys from a local folder you point it at (mounted read-only at `/keys`).
2. Starts `tailscaled` and runs `tailscale up` with the one-time pre-auth key,
   registering this machine on the Snapdragon tailnet (Tailscale SSH enabled).
   - If the node is registered but **not yet approved**, it stays up and keeps
     retrying — it becomes reachable the moment a superadmin admits it
     (register-and-approve admission).
3. Performs a **one-line Casdoor login** (OIDC device-code): it prints a URL + a
   short code; you open the URL over the tailnet, enter the code, done.
4. For `superadmin`, it prints the tailnet-only superadmin UI URL
   (`https://superadmin.<domain>/` — no public forward, ADR-17).
5. Stays running in the background (`--restart unless-stopped`). Its tailnet
   identity persists in a named Docker volume across restarts.

TUN vs userspace: when `/dev/net/tun` is available (most Linux hosts) it gets full
kernel mesh routing. On Docker Desktop / locked-down hosts it falls back to
**userspace networking** automatically — still joins the tailnet for onboarding.

---

## Quick start

### Linux

```sh
# one-time: build the image locally (or pull a published one)
./mesh-node.sh --build

# join the mesh using a local keys folder
./mesh-node.sh --keys ./mykeys --role user

# watch the join + Casdoor login prompt
./mesh-node.sh --logs

# leave the mesh
./mesh-node.sh --stop
```

### Windows (Docker Desktop)

```powershell
# one-time: build the image locally
.\mesh-node.ps1 -Build

# join the mesh using a local keys folder
.\mesh-node.ps1 -Keys .\mykeys -Role user

# watch the logs / leave the mesh
.\mesh-node.ps1 -Logs
.\mesh-node.ps1 -Stop
```

`mesh-node.cmd` is a double-clickable wrapper for `mesh-node.ps1` (same flags).

---

## Keys layout

The keys folder mirrors the KEYS-USB layout the appliance images consume
(see `specs/etc/keys-provision`). A worked example is in [`keys.example/`](keys.example):

```
mykeys/
├── tailscale/
│   └── authkey          one-time headscale pre-auth key (or put it at  mykeys/authkey)
├── login-server         headscale control URL (optional; else --login-server / SNAP_LOGIN_SERVER)
├── casdoor.json         { "issuer", "client_id", "domain" }  (optional — omit for mesh-join only)
└── role                 user | mod | admin | superadmin  (or --role / SNAP_ROLE; default user)
```

To use the example: copy `keys.example/` to `mykeys/`, rename
`tailscale/authkey.example` → `tailscale/authkey` and paste a real one-time key,
then fill in `login-server` and `casdoor.json`.

> **Never commit real keys.** The pre-auth key is single-use (SEC-08) and the
> Casdoor client secret is *not* required here (device-code is a public-client
> flow). Keys are mounted **read-only** at runtime and never baked into the image.

---

## Admin-generated `docker run` (no scripts)

The launchers above are convenience wrappers. An admin can hand out an equivalent
raw command — this is exactly what `mesh-node.sh` runs under the hood:

**Linux (with kernel TUN):**
```sh
docker run -d --name snapdragon-mesh-node --restart unless-stopped \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v "$PWD/mykeys:/keys:ro" \
  -v snapdragon-meshnode-state:/var/lib/tailscale \
  -e SNAP_ROLE=user \
  snapdragon/mesh-node:latest
```

**Windows / Docker Desktop (userspace networking, no `--device`):**
```powershell
docker run -d --name snapdragon-mesh-node --restart unless-stopped `
  -v "${PWD}\mykeys:/keys:ro" `
  -v snapdragon-meshnode-state:/var/lib/tailscale `
  -e SNAP_ROLE=user `
  snapdragon/mesh-node:latest
```

Then `docker logs -f snapdragon-mesh-node` to follow the join + Casdoor login.

---

## Environment overrides

Anything in the keys folder can be overridden by env vars (handy for the raw
`docker run` form):

| Var | Meaning |
| --- | --- |
| `SNAP_ROLE` | `user`\|`mod`\|`admin`\|`superadmin` (overrides `/keys/role`) |
| `SNAP_HOSTNAME` | tailnet hostname (default `snapdragon-meshnode-<host>`) |
| `SNAP_AUTHKEY` | pre-auth key (overrides `/keys/tailscale/authkey`) |
| `SNAP_LOGIN_SERVER` | headscale control URL (overrides `/keys/login-server`) |
| `SNAP_MESH_IMAGE` | image tag the launchers run/build (default `snapdragon/mesh-node:latest`) |

---

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | builds the image (`FROM tailscale/tailscale:stable` + bash/curl/jq) |
| `entrypoint.sh` | join + Casdoor login + background run (PID 1) |
| `mesh-node.sh` | Linux launcher (`docker run` wrapper) |
| `mesh-node.ps1` | Windows / Docker Desktop launcher |
| `mesh-node.cmd` | double-clickable cmd.exe wrapper for the `.ps1` |
| `keys.example/` | worked keys-folder layout (placeholders, no real secrets) |
