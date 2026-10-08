# HugMesh stack in your home

This box was built with `--home-seed-code`, so it can run the whole HugMesh
stack locally in Docker, or join an existing tailnet as a dockerized mesh node.

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

- `docker-compose.yml` — infra (`infra` profile) + app services (`app` profile);
  app services build from the repos fetched next to this file.
- `docker-compose.mesh.yml` — adds a `tailscale` sidecar (`mesh` profile).
- `docker-compose.yml` ships only `admin-bff` and `login-ui` in the `app` profile. Extend the
  `services:` block with whichever other BFFs/UIs you want to run.

The full source also lives here (or run `./fetch-repos.sh`), so you can rebuild a
fresh customized live ISO from `hugmesh-generator/` whenever you like.
