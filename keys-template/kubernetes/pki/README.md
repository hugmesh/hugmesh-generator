# Kubernetes PKI

To make every control-plane and worker node trust the same cluster CA, put the
kubeadm PKI material here (`ca.crt`, `ca.key`, `sa.key`, `sa.pub`,
`front-proxy-ca.*`, `etcd/ca.*`). It is copied to `/etc/kubernetes/pki` at first
boot (the path comes from `kubernetes.pki_dir`).

Generate it once on the PKI node and copy the results onto each KEYS stick:

```bash
kubeadm init phase certs all --config /etc/kubernetes/kubeadm-config.yaml
# then copy /etc/kubernetes/pki/{ca.*,sa.*,front-proxy-ca.*,etcd/ca.*}
```

A worker joins with the `kubernetes.join` block of `provision.json`
(`api_server`, `token`, `ca_cert_hash`). keys-provision takes the discovery hash
from that block, not from `ca.crt`. A second control-plane node needs the full
set plus `join.certificate_key`.

## External CA (shared cluster + mTLS CA)

You can generate the KEYS stick with an **existing CA**. Set `CA_CERT` and
`CA_KEY` in the environment, in `brand.conf` or a brand profile, or pass
`--ca-cert` and `--ca-key` to `scripts/gen-provision-keys.sh`. The `pki` role
(`--role pki`) then drops that CA here as `ca.crt` and `ca.key`. kubeadm then
runs in **external-CA mode**: it skips generating its own root and signs the
apiserver, etcd and other leaf certs with the provided CA. The Kubernetes
control-plane CA is then the **same** CA as the offline mTLS truststore
(`certs/cluster-ca.crt`). Vault PKI shares it only if `certs/cluster-ca.key` is
also on the stick. With an external CA that key is not written there, and Vault
self-generates a DEV root when `certs/cluster-ca.{crt,key}` is missing. The
provided CA is copied, not changed, with one exception: an encrypted `CA_KEY`
(with `CA_KEY_PASS`) is written to `ca.key` DECRYPTED. `ca.key` is written `0600`.

You still supply `sa.*`, `front-proxy-ca.*` and `etcd/ca.*` yourself. Run the
`kubeadm init phase certs` command above and copy them, unless you pre-seed them
another way. Without `CA_CERT`/`CA_KEY`, nothing here changes: generate the
kubeadm PKI by hand as shown above.
