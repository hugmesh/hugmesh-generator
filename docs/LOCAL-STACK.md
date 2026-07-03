# Run the ENTIRE Snapdragon stack locally (docker-compose)

This brings up the **whole Snapdragon platform on one x86_64 machine** via
docker-compose, **building every first-party service from its cloned repo** —
the three gateways, the Spring backends (federation / admin-bff / mod-bff /
user-bff / actions), the static fragment fleet, and every Angular remote +
the host — plus the datastores (Postgres ×3, Cassandra) and Casdoor.

It works on **Linux** (`make stack-up`) and on **Docker Desktop for Windows**
(`scripts/stack-up.ps1`), for both **ENV=test** and **ENV=prod** build modes.

This is the dev "everything on my laptop" path. It is **not** the production
deployment (that is the k8s cluster in `specs/cluster/` driven by ArgoCD); the
compose topology is a faithful translation of those manifests to compose DNS.

---

## Prerequisites

- **Docker** with **Compose v2** (`docker compose version` ≥ v2). Docker Desktop
  on Windows includes it; on Linux install `docker-compose-plugin`.
- **x86_64 / amd64.** First-party images are amd64 (Temurin JRE, node-alpine,
  nginx). On Apple Silicon / arm64 you'd need emulation (out of scope).
- **GitHub access OR internal VPN** so the repos can be cloned. Either:
  - `gh auth login` (GitHub CLI logged in), or
  - a git credential helper / token (`GH_TOKEN` / `GITHUB_TOKEN`), or
  - the VPN + the internal mirror (`GIT_BASE=https://gitlab.snapdragon.systems/snapdragon`).
- **Resources:** the core platform is ~10 JVM/nginx containers + 3 Postgres +
  Cassandra. Budget **~8 GB RAM** for the core, **~12–16 GB** with `SOCIAL=1`
  (Synapse + the full Mastodon tier). First build compiles several Maven + Angular
  projects and is **slow** (tens of minutes, network-bound).

---

## Linux — `make stack-up`

```bash
make stack-up                 # ENV=test (default): clone -> build -> up -d
make stack-logs               # tail logs
make stack-ps                 # container status
make stack-down               # stop + drop volumes
```

What `make stack-up` does:

1. **`stack-clone`** — `scripts/clone-all-repos.sh` clones/updates every repo into
   `./.stack-src` (idempotent: pulls if already present).
2. **build** — `docker compose -f tests/stack/compose.local.yaml build` builds each
   service from `./.stack-src/<repo>`.
3. **up** — `docker compose ... up -d`.

Then open **http://localhost:8088** (the fe-gateway front door) and sign in at its
**native login form** (`/login`) — the browser POSTs credentials to `/bff/login`
and never touches Casdoor. Casdoor is still published at **http://localhost:8000**
in this dev stack, but ONLY as an admin/seed convenience (the `seed-e2e.sh`
provisioning transport); it is **not** part of the login path and has no
browser-facing role. In the cluster Casdoor gets no public ingress at all.

Useful overrides:

```bash
make stack-up SOCIAL=1                       # also bring up Synapse + Mastodon
make stack-up PUBLIC_HOST_PORT=9090          # publish the front door elsewhere
make stack-up STACK_SRC=/srv/snap-src        # clone/build from a different dir
make stack-clone GIT_BASE=https://gitlab.snapdragon.systems/snapdragon  # VPN mirror
make stack-up ENV=prod CASDOOR_ISSUER=https://id.snapdragon.systems     # prod mode
```

---

## Windows (Docker Desktop) — `scripts/stack-up.ps1`

`make` and `bash` are usually absent on Windows, so a **PowerShell** wrapper does
the same clone → build → run. It needs **only Docker Desktop**: cloning runs inside
a throwaway `alpine/git` container (the "bootstrap" path), so you need no host git
either — just pass a token for private repos.

```powershell
# From the repo root, in PowerShell:
pwsh -File scripts\stack-up.ps1 -GhToken ghp_yourtoken         # ENV=test (default)
pwsh -File scripts\stack-up.ps1 -GhToken ghp_yourtoken -Social # + Synapse/Mastodon
pwsh -File scripts\stack-up.ps1 -Env prod -CasdoorIssuer https://id.snapdragon.systems
pwsh -File scripts\stack-up.ps1 -Down                          # tear down (-v)
```

On the VPN with public mirrors you can skip the token and point at the mirror:

```powershell
pwsh -File scripts\stack-up.ps1 -GitBase https://gitlab.snapdragon.systems/snapdragon
```

If you DO have git on Windows and prefer it over the container clone, add
`-UseHostGit`.

### One-liner without the script (Docker-only)

A Windows user with *only* Docker (no PowerShell script handy) can clone via the
same bootstrap container, then drive compose directly. From the repo root
(`cmd`/`pwsh`):

```bat
docker run --rm -v "%cd%\scripts:/scripts:ro" -v "%cd%\.stack-src:/stack-src" ^
  -e STACK_SRC=/stack-src -e GIT_BASE=https://github.com/Snapdragon-Systems ^
  -e USE_GH=0 -e GH_TOKEN=%GH_TOKEN% alpine/git:latest sh /scripts/clone-all-repos.sh

set STACK_SRC=../../.stack-src
set CASDOOR_ISSUER_URI=http://localhost:8000
set PUBLIC_HOST_PORT=8088
docker compose -f tests\stack\compose.local.yaml build
docker compose -f tests\stack\compose.local.yaml up -d
```

### Windows gotchas (handled)

- **CRLF:** `.gitattributes` forces **LF** on all `*.sh` / `*.yaml` / `*.conf` /
  `Dockerfile*` so the shell scripts and gateway route configs work inside the
  Linux containers even on a Windows checkout. PowerShell stays CRLF.
- **Path separators:** compose `build.context` paths are **relative** posix paths
  (`../.stack-src/<repo>`); `STACK_SRC` is passed as `../.stack-src` so the engine
  resolves them identically on both OSes. Bind mounts use compose-relative paths.
- **Credential passing:** the GitHub token is passed as an **env var** into the
  bootstrap container (never baked into an image or committed).

---

## ENV = test vs prod

The same `ENV=test|prod` knob the image build uses (see `docs/LOCAL-TESTING.md`)
selects the identity issuer the whole stack trusts:

| | `test` (default) | `prod` |
|---|---|---|
| Casdoor issuer (`CASDOOR_ISSUER_URI`) | `http://localhost:8000` (the local Casdoor) | the **real** issuer, e.g. `https://id.snapdragon.systems` |
| creds | **dev placeholders** (committed: `gateway`/`federation`/`adminbff` DB passwords, dev Casdoor client ids) | **real** — sourced from **your env / the keys USB**, NOT committed |
| domain-ish env (host MATRIX_URL/MASTODON_URL) | `http://localhost:…` | real `https://…` domain |

**Prod creds source:** `make stack-up ENV=prod` only flips the issuer URL. Real
Casdoor client secrets, DB passwords, and the social-tier secrets are **your
responsibility to inject** at run time (e.g. `CASDOOR_ISSUER=…`, and edit
`tests/stack/.mastodon.env` / a Casdoor app for the fragment-sync + actions
machine accounts). Production proper is the k8s cluster (Vault + External Secrets,
`scripts/gen-cluster-secrets.sh`); this compose stack is a **dev convenience** and
deliberately ships only dev placeholders so nothing secret is committed.

---

## Service URLs (default ports)

| URL | Service |
|---|---|
| http://localhost:8088 | **Front door** — fe-gateway (Angular host + remotes, /bff, /_fragments, /be) |
| http://localhost:8000 | Casdoor (OIDC identity) — **admin/seed transport only**, not the login path; the browser never uses it (in-cluster it has no public ingress) |
| http://localhost:8008 | Synapse / Matrix (only with `SOCIAL=1`) |
| http://localhost:3000 | Mastodon web (only with `SOCIAL=1`) |
| http://localhost:4000 | Mastodon streaming (only with `SOCIAL=1`) |
| 127.0.0.1:9042 | Cassandra (gateway revocation list + URL registry) |

The fe-gateway routes (`tests/stack/gateway-routes/fe/`) fan out from the front
door to `/admin/**`, `/login/**`, `/social/**`, `/mod/**`, `/user/**`,
`/api-docs/**`, `/bff/**` (admin-bff), `/_fragments/**` (fragment fleet), and
`/be/**` (the be-gateway → federation + actions). Only the fe-gateway is published
to the host; everything else is internal compose DNS, exactly as in the cluster
only the gateways are ingress-exposed.

---

## Seeding the e2e fixtures — `tests/stack/seed-e2e.sh`

The UI e2e suites assume a set of personas/rooms/relationships exists. Against a
**running** stack (front door `http://localhost:8088`, Casdoor
`http://localhost:8000`, social tier up — `make stack-up SOCIAL=1` or, for the
full Synapse/Mastodon first-run setup, `tests/stack/up-real.sh`), run:

```bash
tests/stack/seed-e2e.sh
```

It provisions (reusing `tests/qemu/seed-accounts.sh --roles` + its Casdoor apply
hook — the same machinery the cluster/pentest seeds use):

1. **Personas** (Casdoor org `snapdragon`): the standard matrix
   (`e2e-user`/`e2e-mod`/`e2e-admin`/…) **plus** `e2e-superadmin`, `e2e-banned`
   (ban = the **absence** of the platform access roles — seeded as the post-ban
   state) and the domain-locked pair (`e2e-*-domainlocked` — lock = the
   **presence** of the marker role). Because the compose Casdoor boots **empty**,
   the script first creates the org + the `ROLE_*` objects, then applies users +
   role members and pre-mints per-persona JWTs into `tests/stack/.seed-e2e/jwt-cache`
   (usable as `SNAP_PREMINT_DIR`). Default admin creds are the fresh-casdoor dev
   default (`admin`/`123`) — override `CASDOOR_ADMIN_PASS` otherwise.
2. **Matrix (Synapse)**: users `e2e-mod` + `e2e-user`; **public room X**
   (`#e2e-public-x:localhost`) and **invite-only room Y** (`#e2e-invite-y:localhost`,
   `e2e-user` invited; verified `join_rule=invite`).
3. **Mastodon**: accounts `e2e-usera` + `e2e-userb`; follower relationship
   **`e2e-userb` → `e2e-usera`**; **one pending moderation-queue item** (an
   unresolved report of `e2e-usera` filed by `e2e-userb`).

The script is **idempotent** (probe-before-create everywhere; safe to re-run)
and **fail-honest**: every unmet dependency dies with a message naming it (which
service, which bring-up command) — it never prints success for something it did
not verify.

### What remains UNVERIFIABLE on compose (honest limitations)

- **Second tenant**: the standard compose stack runs a **single** Casdoor, so the
  `e2e-tenant2-user` persona / cross-tenant brand-wall scenarios cannot be modeled
  here. The script WARNs loudly (fatal with `SEED_STRICT=1`); set
  `CASDOOR_BRAND_B_URL` (e.g. the pentest two-brand profile) to seed it for real.
- **pleroma-admin-only verbs**: the compose social tier is **mainline Synapse +
  Mastodon**, not prod tuwunel + Akkoma. mod-bff actions wired to the
  pleroma-admin API (block/ban Akkoma leg: `PATCH /api/v1/pleroma/admin/users/
  deactivate`, `DELETE /api/v1/pleroma/admin/instances/{host}`) will 404 upstream —
  suites must assert the bff's **honest DEGRADED envelope** here, never a fake
  success. The mod-bff **Matrix block leg is STUBBED BY DESIGN** everywhere
  (tuwunel has no REST admin API) — it returns an honest 202/STUBBED envelope,
  never "OK".
- **Domain-lock enforcement**: the Akkoma `ForceLocalForUsers` MRF + the egress
  backstop do not exist on mainline Mastodon/compose, so the non-federation specs
  (`tests/e2e/specs/19-23`) stay honestly **skipped** here (`SNAP_FEDERATION_PEER`
  / `SNAP_DOMAINLOCK_ENABLED` unset). The domain-locked **personas** are still
  seeded so the UI surfaces (role badges, disabled+helptext controls) render.

---

## How it maps to the cluster

| compose service | image / build | k8s source |
|---|---|---|
| `snapdragon-{pki,be,fe}-gateway` | build `snapdragon-gateway` (×3, `SPRING_APPLICATION_NAME`) | `apps/20-gateway-*.yaml` + `charts/snapdragon-gateway` |
| `snapdragon-federation-api` | build `snapdragon-federation-api` | `manifests/federation-api` |
| `snapdragon-admin-bff-api` | build `snapdragon-admin-bff-api` | `manifests/admin-bff-api` |
| `snapdragon-mod-bff-api` / `-user-bff-api` | build the respective repos | (not yet in cluster; wired by analogy) |
| `snapdragon-api` | build `snapdragon-actions` | `manifests/snapdragon-apis` |
| `snapdragon-remote-fragment` | build `snapdragon-remote-fragment` (sync image) | `manifests/remote-fragment` |
| `snapdragon-systems-web` | build `snapdragon.systems` | `manifests/frontend` |
| `snapdragon-{admin,mod,user,login,mastodon,matrix}-ui`, `-api-docs` | build each UI repo | `manifests/social-ui` + the remote repos |
| `route-access-db` / `federation-db` / `admin-bff-db` | `postgres:16-alpine` | `manifests/route-access` / `federation-db` / `admin-bff-db` |
| `cassandra`, `casdoor`, `casdoor-db` | upstream images | `compose.real.yaml` (included) |
| `synapse`, `mastodon-*` | upstream images (`social` profile) | `compose.real.yaml` (included, opt-in) |

The gateway route tables in `tests/stack/gateway-routes/{pki,be,fe}/` are the
compose-DNS translation of the `routes:` in each `apps/20-gateway-*.yaml`.

---

## Honest limitations / what needs creds

- **Casdoor is empty on first boot.** Logins, the federation manifest, and the
  fragment fleet need Casdoor **apps/users** that this stack does NOT seed (the
  cluster seeds them via `manifests/casdoor/init-*`). Expect the UIs to load but
  auth-gated flows to 401 until you configure Casdoor (apps for admin-bff,
  fragment-sync, actions; a test user). The route-access DB **does** seed from
  `manifests/route-access/initdb/20-schema.sql`.
- **Fragment fleet serves an empty set** until federation has enabled modules +
  a valid `app-fragment-sync` Casdoor client — so `/_fragments/**` is up but
  empty. It is the standalone sync image on `:8081` (in k8s it is nginx + a sync
  sidecar over a shared volume).
- **admin-bff analytics is off:** the local stack runs only the `casdoor`
  profile, not the cluster's `casdoor,clickhouse` — there is no Kafka/ClickHouse
  here, so `/bff/admin/usage` is not exercised. Route-access CRUD works.
- **mod-bff / user-bff** have no cluster manifest yet; their env here is wired by
  analogy (Casdoor resource server + federation URL) and may need adjustment when
  their real manifests land.
- **snapdragon-actions two-Casdoor sync is inert:** both Casdoor URLs point at the
  single local Casdoor with placeholder client creds, so the games sync job does
  nothing locally (no separate games Casdoor in this stack).
- **Social tier is heavy + opt-in.** `SOCIAL=1` pulls Synapse + Mastodon
  (web/sidekiq/streaming + Postgres/Redis). It does NOT run the
  Synapse-config / Mastodon `db:prepare` first-run setup that `up-real.sh` does;
  for a fully working social tier use `tests/stack/up-real.sh` (the dedicated
  real-services bring-up) which handles those steps.
- **No TLS / no ingress / no SELinux-MCS.** The cluster's mTLS, nginx ingress,
  and per-pod SELinux levels are k8s concerns and are not reproduced here; the
  front door is plain HTTP on localhost.
- **prod creds are NOT committed.** `ENV=prod` only changes the issuer URL; you
  must inject real secrets yourself (see ENV section). Nothing secret lives in
  this repo — only dev placeholders matching the cluster's dev placeholders.
