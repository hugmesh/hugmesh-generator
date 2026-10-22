# HugMesh Docker mesh-node (FD-09)

Turn **any Linux or Windows machine that already runs Docker** into a background
HugMesh mesh node. **No OS flash, no reinstall.** This is the *third* onboarding
form, after the appliance images (Pi / x86) and the client desktop images (laptop /
chromebook / desktop). It reads the **same local-file keys** the appliance images
read off the KEYS-USB, and adds a **one-line Casdoor login**.

Use it to lend a workstation or laptop to the mesh quickly, or when an admin hands
out a copy-paste `docker run` to onboard a remote box.

---

## What it does

1. Reads keys from a local folder you point it at (mounted read-only at `/keys`).
2. Starts `tailscaled` and runs `tailscale up` with the one-time pre-auth key,
   registering this machine on the HugMesh tailnet (Tailscale SSH enabled).
   - If the node is registered but **not yet approved**, it stays up and keeps
     retrying. It becomes reachable the moment a superadmin admits it
     (register-and-approve admission).
3. Performs a **one-line Casdoor login** (OIDC device-code): it prints a URL + a
   short code; you open the URL over the tailnet, enter the code, done. Without a
   device-code endpoint on the issuer, it prints a browser sign-in URL instead. It polls
   up to 60 times. The node stays up either way.
4. For `superadmin`, it prints the tailnet-only superadmin UI URL
   (`https://superadmin.<domain>/` — no public forward, ADR-17).
5. Stays running in the background (`--restart unless-stopped`). Its tailnet
   identity persists in a named Docker volume across restarts.

TUN vs userspace: with `/dev/net/tun` (most Linux hosts) the node gets full kernel
mesh routing. On Docker Desktop and locked-down hosts it falls back to **userspace
networking** on its own. That is enough to join the tailnet for onboarding.

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

The launchers and installers also take `--name HOST` (`-Name`; the tailnet hostname)
and `--image IMG` (`-Image`; default `hugmesh/mesh-node:latest`).

---

## Published image (BETA)

GitHub Actions builds this folder on a GitHub-hosted runner and publishes it as
`ghcr.io/hugmesh/hugmesh-mesh-node` (workflow `.github/workflows/mesh-node-image.yml`).
The version is in `VERSION`; a release is the git tag `mesh-node-v<VERSION>`, which pushes
`:<VERSION>`, `:beta` and `:sha-<12>`. `:latest` is never pushed. Each pushed digest is signed
with cosign (keyless, GitHub OIDC) and carries a build-provenance and an SPDX SBOM attestation.

Until the first `mesh-node-v*` release exists, build locally (`--build`); the launchers still
default to the local name `hugmesh/mesh-node:latest`. To run the published beta instead:

```sh
docker pull ghcr.io/hugmesh/hugmesh-mesh-node:0.1.0-beta.1
cosign verify ghcr.io/hugmesh/hugmesh-mesh-node:0.1.0-beta.1 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/hugmesh/hugmesh-generator/.github/workflows/mesh-node-image.yml@refs/tags/mesh-node-v'
gh attestation verify oci://ghcr.io/hugmesh/hugmesh-mesh-node:0.1.0-beta.1 --repo hugmesh/hugmesh-generator
./mesh-node.sh --image ghcr.io/hugmesh/hugmesh-mesh-node:0.1.0-beta.1 --keys ./mykeys --role user
```

---

## Install it (app icon, menu/Start shortcuts, autostart, task-bar tray)

For a non-technical user, the installers add a **task-bar icon** and menu or
Start-Menu shortcuts, so the node can be joined and left without a terminal. All of it
is per-user: **no root or admin**. The keys folder and role are recorded once
(`launch.env`) and reused by every shortcut and the tray.

### Linux

```sh
# install launcher + app icon + menu entries (Join / Status / Leave)
./install.sh --keys ./mykeys --role user

# also start the node at login, and add a system-tray indicator
./install.sh --keys ./mykeys --role user --autostart --tray

# remove everything (keeps your keys + config)
./install.sh --uninstall
```

The tray (`tray/hugmesh-mesh-tray.py`) needs an AppIndicator GI typelib —
Debian/Ubuntu `gir1.2-ayatanaappindicator3-0.1 python3-gi`, Fedora
`libayatana-appindicator-gtk3 python3-gobject`. Without it the menu entries +
autostart still work.

### Windows (Docker Desktop)

```powershell
# Start-Menu shortcuts (Join / Status / Leave) with the app icon
.\install.ps1 -Keys .\mykeys -Role user

# also a Desktop shortcut, login autostart, and a task-bar (NotifyIcon) tray
.\install.ps1 -Keys .\mykeys -Role user -Desktop -Autostart -Tray

# remove the shortcuts (keeps your keys + config)
.\install.ps1 -Uninstall
```

The task-bar tray (both platforms) shows the live state — `stopped` /
`registered (awaiting approval)` / `joined` — and offers Join / Logs / Leave.
Icons live in [`icons/`](icons) (`.svg` + `.png` for Linux, `.ico` for Windows).

---

## Keys layout

The keys folder mirrors the KEYS-USB layout the appliance images read
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

> **Never commit real keys.** The pre-auth key is single-use (SEC-08). The Casdoor
> client secret is *not* needed here (device-code is a public-client flow). Keys are
> mounted **read-only** at runtime and never baked into the image.

---

## Admin-generated `docker run` (no scripts)

The launchers above are wrappers. An admin can hand out the raw command instead. It
is what `mesh-node.sh` runs:

**Linux (with kernel TUN):**
```sh
docker run -d --name hugmesh-mesh-node --restart unless-stopped \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v "$PWD/mykeys:/keys:ro" \
  -v hugmesh-meshnode-state:/var/lib/tailscale \
  -e SNAP_ROLE=user \
  hugmesh/mesh-node:latest
```

**Windows / Docker Desktop (userspace networking, no `--device`):**
```powershell
docker run -d --name hugmesh-mesh-node --restart unless-stopped `
  -v "${PWD}\mykeys:/keys:ro" `
  -v hugmesh-meshnode-state:/var/lib/tailscale `
  -e SNAP_ROLE=user `
  hugmesh/mesh-node:latest
```

Then `docker logs -f hugmesh-mesh-node` to follow the join + Casdoor login.

---

## Environment overrides

Env vars override anything in the keys folder (handy for the raw `docker run`
form):

| Var | Meaning |
| --- | --- |
| `SNAP_ROLE` | `user`\|`mod`\|`admin`\|`superadmin` (overrides `/keys/role`) |
| `SNAP_HOSTNAME` | tailnet hostname (default `hugmesh-meshnode-<host>`) |
| `SNAP_AUTHKEY` | pre-auth key (overrides `/keys/tailscale/authkey`) |
| `SNAP_LOGIN_SERVER` | headscale control URL (overrides `/keys/login-server`) |
| `SNAP_MESH_IMAGE` | image tag the launchers run/build (default `hugmesh/mesh-node:latest`) |

---

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | builds the image (`FROM tailscale/tailscale:stable` + bash/curl/jq) |
| `entrypoint.sh` | join + Casdoor login + background run (PID 1) |
| `mesh-node.sh` | Linux launcher (`docker run` wrapper) |
| `mesh-node.ps1` | Windows / Docker Desktop launcher |
| `mesh-node.cmd` | double-clickable cmd.exe wrapper for the `.ps1` |
| `install.sh` | Linux installer: app icon + menu entries + optional autostart/tray |
| `install.ps1` | Windows installer: Start-Menu/Desktop shortcuts + optional autostart/tray |
| `tray/hugmesh-mesh-tray.py` | Linux task-bar tray indicator (AppIndicator) |
| `tray/hugmesh-mesh-tray.ps1` | Windows task-bar tray (NotifyIcon) |
| `icons/` | app icon (`.svg` + `.png` for Linux, `.ico` for Windows) |
| `keys.example/` | worked keys-folder layout (placeholders, no real secrets) |
