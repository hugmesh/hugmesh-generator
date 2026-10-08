# Certificates

Place certificates and keys referenced by the `files[]` array of
`provision.json` here, plus any `*.crt`/`*.pem` you want added to the
system trust store and `*.key` files (installed to `/etc/ssl/keys`,
mode 0600).

Typical contents for the HugMesh cluster:

| File | Purpose |
|---|---|
| `cluster-ca.crt` | Shared Kubernetes / cluster CA (trusted on every node) |
| `cluster-ca.key` | Cluster CA private key. pki stick only. Vault PKI imports it with the cert. The `*.key` copy above also puts it in `/etc/ssl/keys` |
| `registry-ca.crt` | Private container-registry CA |
| `casdoor-tls.crt` / `casdoor-tls.key` | Casdoor identity-provider TLS (example name; no script reads it) |
| `wildcard.hugmesh.local.crt` / `.key` | Gateway ingress TLS (example name; no script reads it) |

keys-provision builds the Java truststore from `certs/cluster-ca.crt` and every
other `certs/*.crt` on the stick. Joining the cluster is a separate step: it
uses the `kubernetes.join` block of `provision.json`.
