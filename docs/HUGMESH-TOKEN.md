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
| `login_server` | string | `https://host[:port]` with an optional trailing `/`, nothing else; `host` is the domain or a name under it |
| `auth_key` | string | the headscale pre-auth key; no whitespace |
| `issued` | int | Unix seconds; not before 2020-01-01, not more than 5 minutes in the future |
| `expires` | int | Unix seconds; after `issued`, at most 90 days later |
| `issuer` | string | the issuer's public key, `ssh-ed25519 <base64>` (no comment) |
| `node_name` | string | optional (default `""`); the tray turns it into a DNS label |
| `id` | string | optional (default `""`); random, e.g. 16 hex characters |

No other fields are allowed.

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

The token is a pre-auth key in transit. The authoritative gates are server-side:
create the pre-auth key with the tags for the domain and role, and keep shell access
in the headscale `ssh` policy (`specs/usr/sbin/gen-headscale-policy.sh`) in line with
the `shell` field.

## Issuing from the Studio

```sh
python -m hugmesh_studio.core.mesh_token issue --key ~/.ssh/mesh_issuer \
  --mesh west --domain example.org --role admin --shell \
  --login-server https://hs.example.org --authkey-file key.txt --expires 7d
```
