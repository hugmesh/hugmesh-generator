# KEYS/vault — cluster application secrets

This directory carries the **cluster application secrets** (Casdoor, the
databases, the BFFs, Cassandra, Harbor, ClickHouse, Uptrace and more) on the KEYS
stick, so a device can come up when no HashiCorp Vault server is reachable.
`scripts/gen-cluster-secrets.sh` writes them to `keys-out/vault/`. Drop them here,
or let `scripts/make-keys-usb.sh` copy a `keys-out` directory, `vault/` included,
onto the stick. It does not generate secrets.

## Bundle layout

```
KEYS/vault/
├── secrets.json   the materialized k8s Secrets (namespace -> secretName -> key -> value)
├── token          a Vault token (or AppRole secret-id) for later online sync
└── unseal-key     the Shamir unseal key for the persistent Vault (auto-unseal;
                   you write it after `vault operator init`, the script does not)
```

- **`secrets.json`** is the *offline* path. It holds the exact k8s Secrets the
  workloads consume, so provisioning can `kubectl create secret` them with no
  Vault. See `secrets.example.json` for the (redacted) shape.
- **`token`** lets a node that can reach Vault reconcile through the External
  Secrets Operator. Treat it as highly sensitive. `keys-provision` also copies it
  into the `vault/vault-bootstrap` Secret that the `vault-pki-init` Job
  authenticates with. Without `VAULT_TOKEN` in the environment,
  `gen-cluster-secrets.sh` writes a `PLACEHOLDER-<hex>` string here.
- **`unseal-key`** is the Shamir unseal key for the **persistent** Vault
  (`manifests/vault`: Raft integrated storage on the LUKS `/mnt/data`, TLS
  listener). `keys-provision` copies it into the `vault/vault-unseal` Secret. The
  Vault `vault-unseal` sidecar submits it with `vault operator unseal` on **every
  (re)start**, so Vault comes back **unattended** after a restart. Treat it as
  highly sensitive: with the root token, it opens everything.

## Persistent Vault: ONE-TIME `vault operator init`

The persistent Vault uses **Raft and a Shamir seal**. Initialize it **once** to
mint the unseal key and the root token. After that, auto-unseal needs no operator.
For the single-control-plane offline model, use a single key share:

```bash
# 1) After the Vault pod is Running (sealed, uninitialized), exec into it:
kubectl -n vault exec -it vault-0 -c vault -- sh
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt

# 2) Initialize with a single unseal key share (offline-USB custody model):
vault operator init -key-shares=1 -key-threshold=1
#   -> prints "Unseal Key 1: <KEY>" and "Initial Root Token: <TOKEN>"

# 3) Unseal once now (the sidecar auto-unseals on every later restart):
vault operator unseal <KEY>
```

Then **save both to the offline KEYS stick** so later provisioning is
unattended. Also seed the live cluster Secrets, so the running pod survives a
restart before the next re-provision:

```bash
printf '%s' '<KEY>'   > KEYS/vault/unseal-key
printf '%s' '<TOKEN>' > KEYS/vault/token     # the bootstrap/root token
kubectl -n vault create secret generic vault-unseal   --from-literal=unseal-key='<KEY>'   --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vault create secret generic vault-bootstrap --from-literal=token='<TOKEN>'     --dry-run=client -o yaml | kubectl apply -f -
```

After this, restarting the Vault pod is unattended. It reloads the Raft state from
the LUKS-encrypted PVC, and the sidecar unseals it again from `vault/vault-unseal`.

> The dev Vault kept no durable state, so **re-initialize** the `pki_int` engine
> and the per-app issuing roles **once** on the fresh persistent Vault. The
> `vault-pki-init` Job does this. It is idempotent and re-imports the cluster CA
> from the mounted `cluster-ca` Secret. Let ArgoCD re-run it after init, or run it
> by hand. See `manifests/vault-pki` and `docs/ENCRYPTION-AT-REST.md`.

## Provisioning order: Vault first, USB second

1. **Vault (online, preferred).** If the cluster can reach Vault, the External
   Secrets Operator's `ClusterSecretStore` "hugmesh-vault" (provider `vault`,
   server `https://vault.vault.svc.cluster.local:8200`, KV v2, mount `secret`,
   token auth from the k8s Secret `vault-token` in the `external-secrets`
   namespace) reads `secret/<brand>/...` and materializes the k8s Secrets. The
   `token` file here seeds that `vault-token` Secret when the `.vault` block (or
   the baked `vault.conf`) names a Vault address.
2. **USB (offline, fallback).** With no Vault reachable, provisioning reads
   `secrets.json` and creates the same k8s Secrets directly, so workloads need no
   change either way. The image-pull Secrets (`harbor-registry`,
   `hugmesh-registry-pull`, `image-builder-registry`) cannot come from the bundle,
   because the Harbor robot accounts behind them are minted in-cluster.
   `OFFLINE_UNDELIVERABLE` in `tests/scripts/eso_seed_contract.py` lists them.

Either way the workload manifests keep their `secretKeyRef` usage. Only the
source of the Secret differs.

## What gets created (FIXED names/keys — do not rename)

The table is an excerpt. The bundle also carries the database, BFF, Cassandra,
route-access, Harbor, games, forum, tube and other Secrets, in the namespaces
`<brand>-pki`, `<brand>-backend`, `<brand>-frontend`, `<brand>-games`,
`<brand>-forum`, `<brand>-tube` and `observability`. `scripts/gen-cluster-secrets.sh`
is the full list.

| Namespace            | Secret           | Keys                          | Sourced from Vault                              |
|----------------------|------------------|-------------------------------|-------------------------------------------------|
| `<brand>-pki`        | `casdoor-google` | `clientId`, `clientSecret`    | `casdoor.google_client_id` / `google_client_secret` |
| `<brand>-pki`        | `casdoor-github` | `clientId`, `clientSecret`    | `casdoor.github_client_id` / `github_client_secret` |
| `<brand>-pki`        | `casdoor-discord`| `clientId`, `clientSecret`    | `casdoor.discord_client_id` / `discord_client_secret` |
| `<brand>-pki`        | `casdoor-smtp` *(opt)* | `CASDOOR_SMTP_{HOST,PORT,USER,PASSWORD,FROM}` | `mail.{host,port,user,password,from}` |
| `<brand>-backend`    | `clickhouse-auth`| `password`                    | `clickhouse.password`                           |
| `<brand>-backend`    | `akkoma-smtp` *(opt)*  | `AKKOMA_SMTP_{RELAY,PORT,USER,PASSWORD,TLS,FROM}` | `mail.{host,port,user,password,tls,from}` |
| `observability`      | `clickhouse-auth`| `password`                    | `clickhouse.password`                           |
| `observability`      | `uptrace-auth`   | `pg-password`, `project-token`| `uptrace.pg_password` / `project_token`         |

The `casdoor-github` / `casdoor-discord` providers and the `casdoor-smtp` /
`akkoma-smtp` mail Secrets are **OPTIONAL and absent by default**. OAuth client
ids and secrets default to placeholders (the `casdoor-init` Job skips a provider
whose secret is still a placeholder). The mail Secrets enter the offline bundle
only when a real `mail.user` and `mail.password` resolve. Otherwise Casdoor and
Akkoma stay on native login with admin-approval registration and **no SMTP
wired**. See `scripts/gen-cluster-secrets.sh` and the brand `MAIL_PROVIDER`
knob (`protonmail` default | `gmail` | `outlook` | `smtp` | `none`).

`<brand>` defaults to `hugmesh` (the Vault base path segment equals the brand
slug). Vault stores keys in `snake_case`. The materialized k8s Secrets use the
`camelCase`/`kebab-case` keys above. The generator does the mapping.

The Vault contract, as an excerpt (every path `gen-cluster-secrets.sh` writes is
listed after it):

```
secret/<brand>/casdoor    : google_client_id, google_client_secret,
                            github_client_id, github_client_secret,
                            discord_client_id, discord_client_secret,
                            client_id, client_secret, admin_password (hash),
                            admin_password_plain, db_password_plain
secret/<brand>/casdoor-apps : one key per Casdoor OAuth2 application = that app's
                            client_secret (pki-gateway, be-gateway, fe-gateway,
                            api, admin-bff, user-bff, matrix, mastodon,
                            fragment-sync, signup-gate, harbor, headscale), plus
                            the signup-gate-webhook shared secret.
                            fragment-sync = the app-fragment-sync machine account
                            the remote-fragment sync sidecar uses (client_credentials
                            -> SERVICE JWT for the federation manifest/bundles).
                            Materialized by the casdoor-app-secrets ExternalSecret
                            (dataFrom extract) AND, for the sidecar, the
                            fragment-sync-casdoor ExternalSecret (ns
                            hugmesh-frontend, clientId pinned to app-fragment-sync).
secret/<brand>/clickhouse : password
secret/<brand>/uptrace    : pg_password, project_token
secret/<brand>/cloudflared: tunnel_token     (PROD go-live ONLY — read-if-present)
secret/<brand>/mail       : provider, host, port, tls, user, password, from,
                            dkim_key  (OPTIONAL — empty user/password = disabled)
```

The script also writes: `casdoor-superadmin`, `casdoor-games`, `federation-db`,
`admin-bff-db`, `admin-bff-mfa`, `user-bff-custody-key`, `user-bff-hs-token`,
`bff-internal-token`, `mod-bff-db`, `user-bff-db`, `forum-bff-db`, `wiki-bff-db`,
`mesh-bff-db`, `character-forge-bff-db`, `tube`, `forum`, `forum-db`, `headwind`,
`akkoma`, `route-access-db`, `cassandra-admin`, `cassandra-app-creds`, `harbor`
and `velero` (managed backups, optional). It does not write `cloudflared`.

The `cloudflared` entry is the **PROD-only** go-live edge credential. It is
**read-if-present**: the `cloudflared-tunnel-token` ExternalSecret
(`manifests/cloudflared`) turns it into the `TUNNEL_TOKEN` of the `cloudflared`
Deployment. If it is absent, the tunnel stays down harmlessly. An **ENV=test**
image prunes the cloudflared app at build time, so it never reads this key. No
script copies `KEYS/cloudflared/tunnel-token` into Vault. Store the token at this
path yourself (see that folder's README).

## Regenerating

```bash
# Offline only (no Vault): writes keys-out/vault/{secrets.json,token}
./scripts/gen-cluster-secrets.sh

# Online + offline: also pushes to Vault
VAULT_ADDR=https://vault.hugmesh.net VAULT_TOKEN=s.xxxx \
  ./scripts/gen-cluster-secrets.sh
```

Then write the stick (the bundle is picked up automatically):

```bash
sudo ./scripts/make-keys-usb.sh /dev/sdX ./keys-out
```

## Security notes

- `secrets.json` and `token` are real credentials. Never commit a populated
  bundle. Only `secrets.example.json` (redacted) lives in the repo.
- Keep the KEYS stick offline, in a safe, once provisioning is done. Rotate the
  Vault token after the initial sync.
