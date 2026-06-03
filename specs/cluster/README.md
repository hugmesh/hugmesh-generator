# Snapdragon cluster GitOps payload

This tree is baked into every image at `/var/lib/snapdragon/cluster` and is the
single source of truth ArgoCD syncs from. Everything sits **behind
snapdragon.systems** via the per-namespace Spring Cloud Gateways; Cloudflare
maps the public `snapdragon.systems` / `snapdragon.games` names to the gateways
later (not configured here).

## Topology

| Namespace | Runs on | Front door | Contents |
|---|---|---|---|
| `snapdragon-pki` | pki Pi (control-plane) | `snapdragon-pki-gateway` (`id.snapdragon.systems`) | Casdoor (Google + admin login), Cassandra, headscale/auth |
| `snapdragon-backend` | backend Pis | `snapdragon-be-gateway` (`api.` / `matrix.` / `mastodon.`) | Matrix (Synapse), Mastodon, Spring APIs, DBs |
| `snapdragon-frontend` | frontend Pis | `snapdragon-fe-gateway` (`snapdragon.systems`) | snapdragon.systems Angular host + social-ui micro-frontends |
| `snapdragon-games` | x86_64 GPU worker | (internal) | snapdragon.games (Mesa/Vulkan via `/dev/dri`) |
| `argocd` | x86_64 worker | (internal) | ArgoCD GitOps engine |

The Kubernetes control plane is the **pki Pi**; the x86_64 host joins as a GPU
worker and is where ArgoCD + games are scheduled (via node labels).

## The gateway pattern (`charts/snapdragon-gateway`)

One Helm chart, deployed three times. Each release runs the same
`snapdragon-systems/gateway` image differentiated by `SPRING_APPLICATION_NAME`
(`snapdragon-pki/be/fe-gateway`), validates the **internal Casdoor JWT**, and
appends `External-*` identity headers to downstream requests. Public paths
(`/api/auth`, `/api/login`, `/api/registration`) allow Google-federated sign-up;
everything else requires authentication. The gateway exposes **no external
login UI** — login is internal to Casdoor. Routes per release are rendered into
an `application-routes.yml` ConfigMap and loaded via
`SPRING_CONFIG_ADDITIONAL_LOCATION`.

## Layout

```
cluster/
├── app-of-apps.yaml        root ArgoCD Application (recurses apps/)
├── apps/                   one ArgoCD Application per workload
├── charts/snapdragon-gateway/   the gateway Helm chart (pki/be/fe)
├── manifests/              in-repo kustomize manifests (casdoor, apis, frontend, social-ui, games)
├── namespaces/namespaces.yaml
└── bootstrap/bootstrap.sh  installs ArgoCD + applies the root app
```

## Bootstrapping

Automatic on the pki node when `provision.json` has
`snapdragon.gitops.enabled=true` **and** `kubernetes.bootstrap=true` (so the
control plane exists first). Otherwise run by hand after `kubeadm init`:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
     /var/lib/snapdragon/cluster/bootstrap/bootstrap.sh
```

Point ArgoCD at your own GitOps fork by exporting `SNAPDRAGON_GITOPS_REPO` /
`SNAPDRAGON_GITOPS_REV` before bootstrapping (the per-app `repoURL`s in
`apps/*.yaml` should then be edited to match).

## Notes / TODO before production

- Image tags are `:dev` placeholders — pin real tags (and a private registry +
  imagePullSecret) per app.
- Casdoor uses an `emptyDir` and the all-in-one image — switch to a PVC + an
  external DB, and seed the Google provider (`casdoor-google` Secret) + the
  gateway OAuth2 client.
- Cassandra / Matrix / Mastodon reference upstream charts; pin chart versions
  and supply DB/secret values.
- Secrets belong in sealed-secrets / SOPS or come from the USB KEYS partition —
  never commit them here.
