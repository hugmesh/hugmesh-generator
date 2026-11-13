# HugMesh token format (v1)

A HugMesh token lets a mesh admin share **"join this mesh, in this access domain, as this
role, with or without shell access"** as one line of text. The Studio tray imports it
and runs a mesh node exactly as granted (`studio/hugmesh_studio/core/mesh_token.py` is
the reference implementation, issuing and verifying). Anything else that issues tokens
(the mesh's web admin UI, a server-side endpoint) must produce byte-for-byte the same
format, or the tray refuses the token.

## Wire format

```
hugmesh-token-v1.<payload>.<signature>
```

- `<payload>`: base64url, **no padding**, of the canonical payload bytes (below).
- `<signature>`: base64url, no padding, of an OpenSSH **SSHSIG** armored signature
  (the full `-----BEGIN SSH SIGNATURE-----` text that `ssh-keygen -Y sign` writes)
  over exactly the payload bytes, with namespace **`hugmesh-mesh-token@hugmesh.org`**.
- Whitespace inside the token (line wrapping when pasted) is ignored by the verifier.

## Payload

UTF-8 JSON, **canonical**: keys sorted, separators `,` and `:` with no spaces, ASCII
only (`json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)`).
The verifier re-serialises and refuses a payload that is not already canonical.

| field | type | rule |
|---|---|---|
| `format` | string | exactly `hugmesh-token-v1` |
| `mesh` | string | `^[a-z0-9][a-z0-9-]{0,62}$` |
| `domain` | string | lower-case DNS name with at least two labels (the access domain) |
| `role` | string | one of `user`, `mod`, `admin`, `superadmin` |
| `shell` | bool | shell access; only `admin` and `superadmin` may be `true` |
| `login_server` | string | `https://host[:port]` with an optional trailing `/`, nothing else; `host` is the domain or a name under it. Or a Tor v3 onion, `http://` or `https://<56 characters>.onion[:port]` (see below) |
| `auth_key` | string | the headscale pre-auth key; no whitespace |
| `issued` | int | Unix seconds; not before 2020-01-01, not more than 5 minutes in the future |
| `expires` | int | Unix seconds; after `issued`, at most 90 days later |
| `issuer` | string | the issuer's public key, `ssh-ed25519 <base64>` (no comment) |
| `node_name` | string | optional (default `""`); the tray turns it into a DNS label |
| `id` | string | optional (default `""`); random, e.g. 16 hex characters |

No other fields are allowed.

### An onion login server

A `login_server` may be a Tor v3 onion address. It is checked as one: exactly 56
characters of the onion alphabet (`a-z`, `2-7`) before `.onion`, with the v3 version byte
and checksum (Tor rend-spec-v3, "Encoding onion addresses"), so a mistyped character is
refused instead of naming another service. A v2 (16-character) address and anything
after the port are refused, each with its own sentence. Names in front of the address
(`hs.<onion>.onion`) are accepted, as Tor accepts them: they reach the same service and
arrive in its `Host` header. `http://` is accepted for an onion only: Tor encrypts and authenticates
the connection to the onion's key. An onion has no place in DNS, so the
"inside the access domain" rule does not apply to it; the issuer's signature is what
binds it to the token.

The token carries an onion as written, and the tray passes it to `tailscale up
--login-server=` unchanged. Joining through it needs two things the token cannot supply:
the joining computer's tailscale needs a route into Tor (the Studio's own mesh node does
not set one up), and headscale must be published on that onion. The local Docker
mesh's own `.onion` (`TOR=1`) is not such a door: its `:80` is the web front door, and
its `:443` does pass `hs.<onion>.onion` to headscale, but the stack's certificate names
only the domain (its CA is name-constrained to it), so tailscale refuses the TLS
handshake. Headscale there is reachable as `hs.<domain>`. The Studio therefore does not
offer that onion as a fill-in. The window, the text interface and the command line say
so beside an onion login server. A Studio from before onion login servers were accepted
refuses such a token when it verifies it.

## Trust

The signature is checked against the `issuer` key inside the payload, and then the tray
requires that key to be in its trusted-issuer list. The first time, the operator is
shown the issuer's `SHA256:` fingerprint (as `ssh-keygen -lf` prints it) and must
confirm it matches one the issuer gave them out of band. Issuers should therefore
display their fingerprint wherever they hand out tokens.

## What the tray does with a token

- Re-verifies it at every start, and stops a running node whose token has expired, been
  forgotten, or whose issuer is no longer trusted.
- Runs `tailscale up` with `--login-server=<login_server> --accept-routes` plus `--ssh`
  when shell is granted, `--ssh=false` otherwise; nothing from the environment widens it.
- Drops the node's saved tailnet state when the credentials change, so a new key, role
  or domain registers afresh.

## What the server must still do

The token is a pre-auth key in transit. Role and domain are labels; the mesh decides
what this node may do. The pre-auth key only lets it join. The authoritative gates are
server-side, in the mesh's headscale policy (`specs/usr/sbin/gen-headscale-policy.sh`):
keep shell access in its `ssh` policy in line with the `shell` field.

## Issuing from the Studio

```sh
python -m hugmesh_studio.core.mesh_token issue --key ~/.ssh/mesh_issuer \
  --mesh west --domain example.org --role admin --shell \
  --login-server https://hs.example.org --authkey-file key.txt --expires 7d
```

For a mesh created locally with the Studio, the admin needs no SSH key of their own.
The pre-auth key is pasted or read from a file (`--authkey-file`), which always works,
or minted with `--mint`. Minting needs a running headscale container, such as the
one the Studio's local Docker mesh runs.

```sh
# the Studio's own issuer key for the mesh (created on first use, trusted locally)
python -m hugmesh_studio.core.mesh_token issuer --mesh west
# sign with it, and mint a single-use pre-auth key in a running headscale container
python -m hugmesh_studio.core.mesh_token issue --mesh west --domain example.org \
  --role admin --shell --login-server https://hs.example.org --mint --expires 7d
```

- Without `--key`, the token is signed with the Studio issuer key kept under the
  Studio state dir (`mesh-issuers/<mesh>/issuer_ed25519`, no passphrase; mode 0600
  on Linux and macOS; on Windows its ACL is narrowed to the user if OpenSSH refuses it
  as readable by others). Creating it also trusts it on this computer. Give recipients
  the fingerprint that `issuer --mesh` and `issue` print.
- `--mint` runs `docker exec <container> headscale preauthkeys create --user <user>
  --expiration <token lifetime>` (single-use). The container is the one running
  container labelled `net.hugmesh.role=headscale`, as the local Docker mesh's headscale
  is; otherwise the running container named like `headscale` (when several match, the
  one that is headscale itself, such as `hugmesh-headscale` beside `headscale-ui`),
  unless `--headscale-container` names it.
  The headscale user defaults to the one the container's `net.hugmesh.headscale.user`
  label names (`hugmesh` on the local Docker mesh), else `hugmesh`: the membership user
  HugMesh's headscale provisioning creates, which owns only the membership tags
  (`tag:hugmesh` and the role tags) and no access tag. `--headscale-user` names another;
  never mint for a user the policy lets own an access tag. The issuer key signs
  once before the key is minted; if signing still fails after the mint, the minted key
  is expired (`headscale preauthkeys expire`) and the error says whether that worked.
  The key reaches the container on stdin, so it is not on the `docker exec` command
  line, but inside the container it is an argument of `headscale preauthkeys expire`
  while that runs, so it is briefly visible in the docker host's process list. The
  tags the key asks for default to the container's `net.hugmesh.headscale.key-tags`
  label (`tag:hugmesh` on the local Docker mesh) when the key is for that container's
  labelled user, else none: the mesh policy gives the
  access tags (`tag:dom_*`, `tag:dev_*`, `tag:mesh_*`, `tag:superadmin`) no owner and
  forces them server-side, so the server tags the node. A label that names an access
  tag is ignored. `--tag` asks for a membership or role tag explicitly (one tag per
  `--tag`); an access tag is refused, because headscale forces a key's tags on whoever
  joins with it.
- The Studio's own command forwards everything after `--mesh-token` to this CLI:
  `python -m hugmesh_studio --mesh-token issue ...`, `hugmesh-studio --mesh-token
  issue ...` when installed with pip, and on Windows the MSI's console twin
  `hugmesh-studio-cli.exe --mesh-token issue ...` (the windowed `hugmesh-studio.exe`
  prints nothing).

The same issuing is in the Studio's window and text interface, on Linux, Windows and
macOS alike, over the same core (same field checks before anything is created or
minted, same Studio issuer key, same `issue()`):

- **GUI**: **Issue a HugMesh token…** in the tray's mesh menu and in the Local mesh
  Actions box (`studio/hugmesh_studio/gui/mesh_token_issue_dialog.py`). The pre-auth
  key is pasted into a hidden field (cleared once the token is issued) or minted with
  **Mint from the local headscale**, for the container under **Headscale container**
  (the running one found, one picked from several, or a typed name). **Headscale user**
  is optional: its placeholder shows the default (the found container's label, else
  `hugmesh`), and an empty field mints for it. The dialog shows the token and the
  issuer fingerprint.
- **TUI**: `t` on the Local Docker mesh screens
  (`studio/hugmesh_studio/tui/mesh_token_step.py`). The pre-auth key is read from a
  file (`k PATH`), never typed on screen. The screen does not start docker: `mint`
  prints the `--mesh-token issue --mint` command line to run instead, and says which
  headscale user it mints for. `u USER` names one (it adds `--headscale-user`; without
  it the CLI uses the default above), and `c NAME` adds `--headscale-container`.
- **The mesh's web admin UI**: an issuer there is being added on the mesh side. It
  must produce this same v1 format, and should show its issuer fingerprint beside the
  tokens it hands out (see Trust above). If it mints the pre-auth key itself, it mints
  for the membership user `hugmesh` with no access tag on the key (`--mint` refuses an
  access tag too): headscale forces a key's tags on whoever joins with it, and the policy keeps
  the access tags (`tag:superadmin`, `tag:mesh_*`, `tag:dev_*`, `tag:dom_*`) ownerless
  so that only the control node's force-tag pass can assign them.
