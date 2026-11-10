# Kubernetes PKI

On the **pki** (first control-plane) stick, and on a **control-plane-additional**
stick if you do not use `join.certificate_key`, put the kubeadm PKI material here
(`ca.crt`, `ca.key`, `sa.key`, `sa.pub`, `front-proxy-ca.*`, `etcd/ca.*`). It is
copied to `/etc/kubernetes/pki` at first boot (the path comes from
`kubernetes.pki_dir`).

**Never put a `*.key` here on a worker stick** (backend, frontend, host,
mesh-extension). A worker joins with the token and `ca_cert_hash` below and needs no
private key; `gen-provision-keys.sh` refuses to finish a worker stick that has a
private key under `kubernetes/pki/` or `certs/`. To make a worker trust the cluster
CA, give the CA certificate to `gen-provision-keys.sh --ca-cert` (it writes
`certs/cluster-ca.crt`), or use the Studio's **Domain CA keys** step.

Generate it once on the PKI node and copy the results onto the control-plane
sticks:

```bash
kubeadm init phase certs all --config /etc/kubernetes/kubeadm-config.yaml
# then copy /etc/kubernetes/pki/{ca.*,sa.*,front-proxy-ca.*,etcd/ca.*}
```

A worker joins with the `kubernetes.join` block of `provision.json`
(`api_server`, `token`, `ca_cert_hash`). keys-provision takes the discovery hash
from that block, not from `ca.crt`. A second control-plane node needs the full
set plus `join.certificate_key`.

## External CA (shared cluster + mTLS CA)

The Studio's **Domain CA keys** step passes `--no-kubeadm-ca`: kubeadm keeps its
own CA and the domain CA key goes to `certs/cluster-ca.key` only (for Vault). The
rest of this section is the brand.conf / command-line route without that flag.

You can generate the KEYS stick with an **existing CA**. Set `CA_CERT` and
`CA_KEY` in the environment, in `brand.conf` or a brand profile, or pass
`--ca-cert` and `--ca-key` to `scripts/gen-provision-keys.sh`. The `pki` role
(`--role pki`) then drops that CA here as `ca.crt` and `ca.key`. kubeadm then
runs in **external-CA mode**: it skips generating its own root and signs the
apiserver, etcd and other leaf certs with the provided CA. The Kubernetes
control-plane CA is then the **same** CA as the offline mTLS truststore
(`certs/cluster-ca.crt`). Vault PKI shares it only if `certs/cluster-ca.key` is
also on the stick: add `--ca-key-to-stick` (pki profile only) to write it there.
Without that flag the key is not written there, and Vault self-generates a DEV root
when `certs/cluster-ca.{crt,key}` is missing. The
provided CA is copied, not changed, with one exception: an encrypted `CA_KEY`
(with `CA_KEY_PASS`) is written to `ca.key` DECRYPTED. `ca.key` is written `0600`.

You still supply `sa.*`, `front-proxy-ca.*` and `etcd/ca.*` yourself. Run the
`kubeadm init phase certs` command above and copy them, unless you pre-seed them
another way. Without `CA_CERT`/`CA_KEY`, nothing here changes: generate the
kubeadm PKI by hand as shown above.
