# KEYS/vault — cluster application secrets

This directory carries the **cluster application secrets** (Casdoor,
ClickHouse, Uptrace) onto the KEYS stick so a device can come up even when no
HashiCorp Vault server is reachable. It is produced by
`scripts/gen-cluster-secrets.sh` and dropped here (or generated straight onto
the stick by `scripts/make-keys-usb.sh`).

## Bundle layout

```
KEYS/vault/
├── secrets.json   the materialized k8s Secrets (namespace -> secretName -> key -> value)
└── token          a Vault token (or AppRole secret-id) for later online sync
```

- **`secrets.json`** is the *offline* path: it already holds the exact k8s
  Secrets the workloads consume, so provisioning can `kubectl create secret`
  them directly with no Vault. See `secrets.example.json` for the (redacted)
  shape.
- **`token`** lets a node that *does* have network reach Vault and reconcile via
  the External Secrets Operator. Treat it as highly sensitive.

## Provisioning order: Vault first, USB second

1. **Vault (online, preferred).** If the cluster can reach `VAULT_ADDR`, the
   External Secrets Operator's `ClusterSecretStore` "snapdragon-vault"
   (provider `vault`, KV v2, mount `secret`, token auth from the k8s Secret
   `vault-token` in the `external-secrets` namespace) reads
   `secret/<brand>/{casdoor,clickhouse,uptrace}` and materializes the k8s
   Secrets below. The `token` file here seeds that `vault-token` Secret.
2. **USB (offline, fallback).** With no Vault reachable, provisioning consumes
   `secrets.json` and creates the same k8s Secrets directly. The result is
   byte-for-byte the Secrets ESO would have produced, so workloads need no
   change either way.

In both cases the workload manifests keep their existing `secretKeyRef` usage
unchanged — only the source of the Secret differs.

## What gets created (FIXED names/keys — do not rename)

| Namespace            | Secret           | Keys                          | Sourced from Vault                              |
|----------------------|------------------|-------------------------------|-------------------------------------------------|
| `<brand>-pki`        | `casdoor-google` | `clientId`, `clientSecret`    | `casdoor.google_client_id` / `google_client_secret` |
| `<brand>-backend`    | `clickhouse-auth`| `password`                    | `clickhouse.password`                           |
| `observability`      | `clickhouse-auth`| `password`                    | `clickhouse.password`                           |
| `observability`      | `uptrace-auth`   | `pg-password`, `project-token`| `uptrace.pg_password` / `project_token`         |

`<brand>` defaults to `snapdragon` (the Vault base path segment equals the
brand slug). Vault stores keys in `snake_case`; the materialized k8s Secrets use
the `camelCase`/`kebab-case` keys above — the generator handles the mapping.

The full Vault contract (superset of what the bundle materializes):

```
secret/<brand>/casdoor    : google_client_id, google_client_secret,
                            client_id, client_secret, admin_password
secret/<brand>/clickhouse : password
secret/<brand>/uptrace    : pg_password, project_token
```

## Regenerating

```bash
# Offline only (no Vault): writes keys-out/vault/{secrets.json,token}
./scripts/gen-cluster-secrets.sh

# Online + offline: also pushes to Vault
VAULT_ADDR=https://vault.snapdragon.systems VAULT_TOKEN=s.xxxx \
  ./scripts/gen-cluster-secrets.sh
```

Then write the stick (the bundle is picked up automatically):

```bash
sudo ./scripts/make-keys-usb.sh /dev/sdX ./keys-out
```

## Security notes

- `secrets.json` and `token` are real credentials — never commit a populated
  bundle. Only `secrets.example.json` (redacted) lives in the repo.
- Keep the KEYS stick offline / in a safe once provisioning is done, and rotate
  the Vault token after the initial sync.
