# HugMesh stack in your home

This box was built with `--home-seed-code`. It can run the HugMesh stack locally in Docker,
or join an existing tailnet as a dockerized mesh node.

```sh
cd ~/hugmesh-stack
./hugmesh-stack fetch      # clone/update the org repos (gh auth login for private)
./hugmesh-stack up         # Postgres + Casdoor + admin-bff + login-ui
#   or
TS_AUTHKEY=tskey-... ./hugmesh-stack mesh-up   # join the tailnet as a node
./hugmesh-stack ps         # status
./hugmesh-stack logs admin-bff
./hugmesh-stack down
```

- `docker-compose.yml` — infra (`infra` profile) and app services (`app` profile). App
  services build from the repos fetched next to this file. The `app` profile holds only
  `admin-bff` and `login-ui`. Add other BFFs and UIs to the `services:` block as you need them.
- `docker-compose.mesh.yml` — adds a `tailscale` sidecar (`mesh` profile).

The full source also lives here (or run `./fetch-repos.sh`). Rebuild a customized live ISO
from `hugmesh-generator/` whenever you like.
