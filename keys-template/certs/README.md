# Certificates

Place certificates and keys referenced by the `files[]` array of
`provision.json` here, plus any `*.crt`/`*.pem` you want added to the
system trust store and `*.key` files (installed to `/etc/ssl/keys`,
mode 0600).

Typical contents for the HugMesh cluster:

| File | Purpose |
|---|---|
| `cluster-ca.crt` | Shared Kubernetes / cluster CA (trusted on every node) |
| `registry-ca.crt` | Private container-registry CA |
| `casdoor-tls.crt` / `casdoor-tls.key` | Casdoor identity-provider TLS |
| `wildcard.hugmesh.local.crt` / `.key` | Gateway ingress TLS |

The same certs + the same `cluster_domain` on every node are what let the
backend and frontend Pis join the PKI node's cluster and trust each other.
