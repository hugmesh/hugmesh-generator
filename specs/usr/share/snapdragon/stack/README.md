# Snapdragon stack in your home

This box was built with `--home-seed-code`, so it can run the whole Snapdragon
stack locally in Docker, or join an existing tailnet as a dockerized mesh node.

```sh
cd ~/snapdragon-stack
./snapdragon-stack fetch      # clone/update the org repos (gh auth login for private)
./snapdragon-stack up         # full stack: Postgres + Casdoor + app services
#   or
TS_AUTHKEY=tskey-... ./snapdragon-stack mesh-up   # join the tailnet as a node
./snapdragon-stack ps         # status
./snapdragon-stack logs admin-bff
./snapdragon-stack down
```

- `docker-compose.yml` — infra (`infra` profile) + app services (`app` profile);
  app services build from the repos fetched next to this file.
- `docker-compose.mesh.yml` — adds a `tailscale` sidecar (`mesh` profile).
- Extend the `app:` block with whichever BFFs/UIs you want to run.

The full source also lives here (or run `./fetch-repos.sh`), so you can rebuild a
fresh customized live ISO from `snapdragon-generator/` whenever you like.
