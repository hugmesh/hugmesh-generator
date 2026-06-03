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
