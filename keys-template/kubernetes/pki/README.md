# Kubernetes PKI

To make every control-plane / worker node trust the same cluster CA, drop
the kubeadm PKI material here (`ca.crt`, `ca.key`, `sa.key`, `sa.pub`,
`front-proxy-ca.*`, `etcd/ca.*`). It is copied to `/etc/kubernetes/pki` at
first boot (referenced by `kubernetes.pki_dir`).

Generate once on the PKI node and copy the results onto each KEYS stick:

```bash
kubeadm init phase certs all --config /etc/kubernetes/kubeadm-config.yaml
# then copy /etc/kubernetes/pki/{ca.*,sa.*,front-proxy-ca.*,etcd/ca.*}
```

Worker KEYS sticks only need `ca.crt` (for the discovery hash); a second
control-plane node needs the full set.

## External CA (shared cluster + mTLS CA)

If you generate the KEYS stick with an **existing CA** (set `CA_CERT` + `CA_KEY`
via env, `brand.conf` / a brand profile, or `--ca-cert` / `--ca-key` on
`scripts/gen-provision-keys.sh`), the `pki` role automatically drops that CA here
as `ca.crt` + `ca.key`. kubeadm then runs in **external-CA mode**: it skips
generating its own root and signs the apiserver/etcd/etc. leaf certs off the
provided CA — so the Kubernetes control-plane CA is the **same** CA as the
offline mTLS truststore (`certs/cluster-ca.crt`) and Vault PKI. The provided CA
is copied, never modified. `ca.key` is written `0600`.

You still supply `sa.*`, `front-proxy-ca.*`, and `etcd/ca.*` yourself (run the
`kubeadm init phase certs` above and copy them) unless you also pre-seed those.
Without `CA_CERT`/`CA_KEY`, nothing here changes — generate the kubeadm PKI
manually as documented above.
