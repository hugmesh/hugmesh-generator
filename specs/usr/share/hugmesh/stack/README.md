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

## Who can reach it

The stack is for THIS machine. Every published port (Postgres 5432, Casdoor 8000, admin-bff 8081,
login-ui 4200) listens on `127.0.0.1` only. Casdoor runs with its upstream factory admin login, which
nothing here changes, so `./hugmesh-stack up` refuses a `STACK_BIND_ADDR` that is not loopback. To reach it
from another machine, tunnel (`ssh -L 4200:127.0.0.1:4200 this-box`) instead of opening the ports.

The database password is generated the first time you run `./hugmesh-stack up`, into `.env` next to the
compose file (mode 0600, kept, never printed). Compose requires it: a bare `docker compose up` without
`.env` or an exported `HUGMESH_DB_PASS` stops with a message instead of using a public default. A `pgdata`
volume from an older copy of this file still holds the old password: `./hugmesh-stack down -v` starts clean.

The full source also lives here (or run `./fetch-repos.sh`). Rebuild a customized live ISO
from `hugmesh-generator/` whenever you like.
