# Run the ENTIRE HugMesh stack locally (docker-compose)

This brings up the **whole HugMesh platform on one x86_64 machine** via
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
- **BuildKit / buildx** visible **in the environment you run `make` from**.
  Several service Dockerfiles use BuildKit syntax (`# syntax=docker/dockerfile:1.7`
  + `RUN --mount=type=secret`); the Makefile exports `DOCKER_BUILDKIT=1`, but the
  buildx CLI plugin is often installed **per-user** (`~/.docker/cli-plugins`), so a
  `sudo`/systemd/other-`HOME` invocation silently falls back to the legacy builder
  and dies with opaque Dockerfile parse errors. `docker buildx version` must work
  as the invoking user.
- **A cold build** (no `hugmesh-local-*` images yet — e.g. a fresh box or a
  wiped docker data-root) additionally needs the org-private maven artifacts:
  run **`make stack-m2-bootstrap` once first** (see "Cold builds" below).
- **x86_64 / amd64.** First-party images are amd64 (Temurin JRE, node-alpine,
  nginx). On Apple Silicon / arm64 you'd need emulation (out of scope).
- **GitHub access OR internal VPN** so the repos can be cloned. Either:
  - `gh auth login` (GitHub CLI logged in), or
  - a git credential helper / token (`GH_TOKEN` / `GITHUB_TOKEN`), or
  - the VPN + the internal mirror (`GIT_BASE=https://gitlab.hugmesh.systems/hugmesh`).
- **Resources:** the core platform is ~10 JVM/nginx containers + 3 Postgres +
  Cassandra. Budget **~8 GB RAM** for the core, **~12–16 GB** with `SOCIAL=1`
  (tuwunel + the full Mastodon tier). First build compiles several Maven + Angular
  projects and is **slow** (tens of minutes, network-bound).

---

## Linux — `make stack-up`

```bash
make stack-up                 # ENV=test (default): clone -> build -> up -d
make stack-seed               # REQUIRED for real SSO login: seed Casdoor (org+roles+app-user-bff+personas)
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

`make stack-up` alone does **not** seed any personas, so sign-in fails until you
also run `make stack-seed` (`tests/stack/seed-e2e.sh`) — it creates the org/
roles/personas that back every login, and is a **required** follow-up step, not
optional (see "Seeding the e2e fixtures" below).

Then open **http://localhost:8088** (the fe-gateway front door) — or its HTTPS
twin **https://localhost:8488** — and sign in at the **native login form**
(`/login`); the browser POSTs credentials to `/bff/login` and never touches
Casdoor. Both doors serve the identical platform in ENV=test *and* ENV=prod:
the `https-front` nginx terminator proxies everything to the same fe-gateway,
using a **per-machine** CA + leaf that `make stack-certs` mints automatically
on first `stack-up` (gitignored under `tests/stack/.tls-front/`). Import
`tests/stack/.tls-front/ca.crt` into your browser for a green lock, or just
accept the self-signed warning. `rm -rf tests/stack/.tls-front` re-mints. Casdoor is still published at **http://localhost:8000**
in this dev stack, but ONLY as an admin/seed convenience (the `seed-e2e.sh`
provisioning transport); it is **not** part of the login path and has no
browser-facing role. In the cluster Casdoor gets no public ingress at all.

Useful overrides:

```bash
make stack-up SOCIAL=1                       # also bring up tuwunel + Mastodon
make stack-up PUBLIC_HOST_PORT=9090          # publish the front door elsewhere
make stack-up PUBLIC_HTTPS_PORT=9443         # publish the HTTPS front door elsewhere
make stack-up STACK_SRC=/srv/snap-src        # clone/build from a different dir
make stack-clone GIT_BASE=https://gitlab.hugmesh.systems/hugmesh  # VPN mirror
make stack-up ENV=prod CASDOOR_ISSUER=https://id.hugmesh.systems     # prod mode
```

---

## Cold builds — `make stack-m2-bootstrap` (private maven artifacts)

Four Java services (**admin/user/mod-bff, federation-api**) resolve org-PRIVATE
maven artifacts (`systems.hugmesh:hugmesh-parent/-commons/-auth-core/
-build-config`) at **image-build** time via their committed `settings.xml`
(`${env.CI_API_V4_URL}/groups/${env.GITLAB_GROUP_ID}/-/packages/maven` — the
GitLab group registry, unreachable off the VPN). While the built
`hugmesh-local-*` images exist locally you never notice; on a **cold build**
(fresh box, wiped docker data-root) `docker compose build` fails resolving them.

```bash
make stack-m2-bootstrap   # once (idempotent; re-run after a docker restart)
make stack-up             # now auto-wires the local registry into the build
```

What it does (`tests/stack/m2-bootstrap.sh` — everything from SOURCE, nothing
vendored):

1. Clones the four library repos at **pinned commits** (the repos carry no git
   tags; each SHA's `pom.xml` is exactly the version the services require — today
   `hugmesh-build-config` **0.5.0**, `hugmesh-parent` **2.8.0**,
   `hugmesh-commons` **2.1.0** and a single `hugmesh-auth-core` **2.4.2** for both
   user-bff and admin-bff; ⚠️ auth-core has been re-cut twice under a released
   coordinate — 2.4.0 → 2.4.1 → 2.4.2 — so re-check
   [`tests/stack/m2-bootstrap.sh`](../tests/stack/m2-bootstrap.sh), which is the
   authoritative pin, rather than this sentence)
   into `~/.cache/hugmesh-stack-maven/src` and `mvn install`s them into
   `~/.cache/hugmesh-stack-maven/m2` using the official `maven` Docker image
   (no host JDK/maven needed). Cached artifacts are skipped — no re-clone/re-build.
2. Serves that m2 repo from a tiny static registry **container**
   (`hugmesh-m2-registry`, busybox httpd) shaped like the GitLab group
   registry URL. It must be a container: on some hosts, host-published ports are
   NOT reachable from `docker build` containers, so the build reaches it by its
   docker-bridge IP.
3. Writes `tests/stack/.m2-registry.env` (gitignored). Whenever that file
   exists, `make stack-up`/`stack-build` auto-include the committed override
   `tests/stack/compose.m2-local.yaml`, threading `CI_API_V4_URL`/
   `GITLAB_GROUP_ID` as build args into the four services. No token is needed:
   the Dockerfiles' `ci_job_token` secret mount is optional-guarded and the
   static registry ignores auth headers.

Two committed companions make the resolution actually work:

- the Makefile exports `DOCKER_BUILDKIT=1` on every stack compose call (the
  Dockerfiles use BuildKit secret mounts), and
- `scripts/clone-all-repos.sh` runs `scripts/patch-stack-src.sh` after every
  clone/update — the general post-clone patch pass. Its current patch injects a
  `maven-default-http-blocker` mirror override into each consumer repo's
  `settings.xml` (idempotent, marker-scoped), because Maven 3.9's bundled
  settings block ALL external `http://` repositories and the local registry is
  plain HTTP by design.

The registry container survives reboots (`--restart unless-stopped`), but its
bridge IP can change when docker restarts — `make stack-m2-bootstrap` is cheap
to re-run and refreshes `.m2-registry.env`. Remove it with
`docker rm -f hugmesh-m2-registry` once your images are built.

---

## Windows (Docker Desktop) — `scripts/stack-up.ps1`

`make` and `bash` are usually absent on Windows, so a **PowerShell** wrapper does
the same clone → build → run. It needs **only Docker Desktop**: cloning runs inside
a throwaway `alpine/git` container (the "bootstrap" path), so you need no host git
either — just pass a token for private repos.

```powershell
# From the repo root, in PowerShell:
pwsh -File scripts\stack-up.ps1 -GhToken ghp_yourtoken         # ENV=test (default)
pwsh -File scripts\stack-up.ps1 -GhToken ghp_yourtoken -Social # + tuwunel/Mastodon
pwsh -File scripts\stack-up.ps1 -Env prod -CasdoorIssuer https://id.hugmesh.systems
pwsh -File scripts\stack-up.ps1 -Down                          # tear down (-v)
```

On the VPN with public mirrors you can skip the token and point at the mirror:

```powershell
pwsh -File scripts\stack-up.ps1 -GitBase https://gitlab.hugmesh.systems/hugmesh
```

If you DO have git on Windows and prefer it over the container clone, add
`-UseHostGit`.

### One-liner without the script (Docker-only)

A Windows user with *only* Docker (no PowerShell script handy) can clone via the
same bootstrap container, then drive compose directly. From the repo root
(`cmd`/`pwsh`):

```bat
docker run --rm -v "%cd%\scripts:/scripts:ro" -v "%cd%\.stack-src:/stack-src" ^
  -e STACK_SRC=/stack-src -e GIT_BASE=https://github.com/hugmesh-net ^
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
| Casdoor issuer (`CASDOOR_ISSUER_URI`) | `http://localhost:8000` (the local Casdoor) | the **real** issuer, e.g. `https://id.hugmesh.systems` |
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
| https://localhost:8488 | **Front door (HTTPS)** — same fe-gateway via the `https-front` TLS terminator; per-machine CA at `tests/stack/.tls-front/ca.crt` (knob: `PUBLIC_HTTPS_PORT`) |
| http://localhost:8000 | Casdoor (OIDC identity) — **admin/seed transport only**, not the login path; the browser never uses it (in-cluster it has no public ingress) |
| http://localhost:8008 | tuwunel / Matrix (only with `SOCIAL=1`) |
| http://localhost:3000 | Mastodon web (only with `SOCIAL=1`) |
| http://localhost:4000 | Mastodon streaming (only with `SOCIAL=1`) |
| 127.0.0.1:9042 | Cassandra (gateway revocation list + URL registry) |

The fe-gateway routes (`tests/stack/gateway-routes/fe/`) fan out from the front
door to `/admin/**`, `/login/**`, `/social/**` (matrix/mastodon/forum),
`/mod/**`, `/user/**`, `/api-docs/**`, `/wiki/**`, `/owncast/**`, `/tube/**`,
`/character-studio/**`, `/bff/**` (each of admin/mod/user/forum/wiki/owncast/tube-bff,
then the admin-bff catch-all), `/_fragments/**` (fragment fleet), and `/be/**`
(the be-gateway → federation + actions). Only the fe-gateway is published to the
host; everything else is internal compose DNS, exactly as in the cluster only the
gateways are ingress-exposed.

---

## Seeding the e2e fixtures — `tests/stack/seed-e2e.sh` (a.k.a. `make stack-seed`)

The UI e2e suites assume a set of personas/rooms/relationships exists, and —
since PR #227 — this is also **the required step that makes login work at all**:
a fresh compose Casdoor boots with no org/roles/personas, so without seeding
there's nothing for the native `/bff/login` form (or an e2e persona) to
authenticate against. Against a
**running** core stack (front door `http://localhost:8088`, Casdoor
`http://localhost:8000` — `make stack-up`), run:

```bash
make stack-seed                # core identity leg only (org+roles+app-user-bff+personas)
make stack-up SOCIAL=1 && make stack-seed SOCIAL=1   # + Matrix/Mastodon fixtures
```

(equivalently `SEED_CASDOOR_ONLY=1 tests/stack/seed-e2e.sh` / `tests/stack/seed-e2e.sh`
directly). It provisions (reusing `tests/qemu/seed-accounts.sh --roles` + its
Casdoor apply hook — the same machinery the cluster/pentest seeds use):

1. **The `app-user-bff` OAuth2 client** (`ensure_app()`): a confidential client
   mirroring the cluster's `reconcile_app` (authorization_code + refresh_token
   grants, JWT-Custom/RS256 with the roles+permissions token attributes gateway
   RBAC reads). This is the piece a fresh compose Casdoor lacks entirely — without
   it, browser SSO login has no application to redirect to.
2. **Personas** (Casdoor org `hugmesh`): the standard matrix
   (`e2e-user`/`e2e-mod`/`e2e-admin`/…) **plus** `e2e-superadmin`, `e2e-banned`
   (ban = the **absence** of the platform access roles — seeded as the post-ban
   state) and the domain-locked pair (`e2e-*-domainlocked` — lock = the
   **presence** of the marker role). Because the compose Casdoor boots **empty**,
   the script first creates the org + the `ROLE_*` objects, then applies users +
   role members and pre-mints per-persona JWTs into `tests/stack/.seed-e2e/jwt-cache`
   (usable as `SNAP_PREMINT_DIR`). Default admin creds are the fresh-casdoor dev
   default (`admin`/`123`) — override `CASDOOR_ADMIN_PASS` otherwise.
3. **Matrix (tuwunel)**: users `e2e-mod` + `e2e-user` — registered from the
   host over the public CS-API (UIAA `m.login.dummy`; no container exec, the
   distroless tuwunel image has no shell); **public room X**
   (`#e2e-public-x:localhost`) and **invite-only room Y** (`#e2e-invite-y:localhost`,
   `e2e-user` invited; verified `join_rule=invite`).
4. **Mastodon**: accounts `e2e_usera` + `e2e_userb` (underscore — Mastodon's
   username validator rejects hyphens); follower relationship
   **`e2e_userb` → `e2e_usera`**; **one pending moderation-queue item** (an
   unresolved report of `e2e_usera` filed by `e2e_userb`).

The script is **idempotent** (probe-before-create everywhere; safe to re-run)
and **fail-honest**: every unmet dependency dies with a message naming it (which
service, which bring-up command) — it never prints success for something it did
not verify.

### What remains UNVERIFIABLE on compose (honest limitations)

- **Second tenant**: the standard compose stack runs a **single** Casdoor, so the
  `e2e-tenant2-user` persona / cross-tenant brand-wall scenarios cannot be modeled
  here. The script WARNs loudly (fatal with `SEED_STRICT=1`); set
  `CASDOOR_BRAND_B_URL` (e.g. the pentest two-brand profile) to seed it for real.
- **pleroma-admin-only verbs**: the compose social tier is **tuwunel + mainline
  Mastodon** — the Matrix half now runs the same homeserver + image tag as the
  cluster payload (`ghcr.io/matrix-construct/tuwunel:v1.7.0`), though in
  LAN-test posture (open registration, federation off, no mTLS proxy — the
  cluster runs closed registration behind `tuwunel-proxy:4443`), while the
  fediverse half is still Mastodon, not Akkoma. mod-bff actions wired to the
  pleroma-admin API (block/ban Akkoma leg: `PATCH /api/v1/pleroma/admin/users/
  deactivate`, `DELETE /api/v1/pleroma/admin/instances/{host}`) will 404 upstream —
  suites must assert the bff's **honest DEGRADED envelope** here, never a fake
  success. The mod-bff **Matrix block leg is STUBBED BY DESIGN** everywhere
  (tuwunel has no general REST admin API — only the Synapse-compat
  `/_synapse/admin/v1/register` shared-secret shim; moderation lives in the
  admin room) — it returns an honest 202/STUBBED envelope, never "OK".
- **Domain-lock enforcement**: the Akkoma `ForceLocalForUsers` MRF + the egress
  backstop do not exist on mainline Mastodon/compose, so the non-federation specs
  (`tests/e2e/specs/19-23`) stay honestly **skipped** here (`SNAP_FEDERATION_PEER`
  / `SNAP_DOMAINLOCK_ENABLED` unset). The domain-locked **personas** are still
  seeded so the UI surfaces (role badges, disabled+helptext controls) render.

---

## How it maps to the cluster

| compose service | image / build | k8s source |
|---|---|---|
| `hugmesh-{pki,be,fe}-gateway` | build `hugmesh-gateway` (×3, `SPRING_APPLICATION_NAME`) | `apps/20-gateway-*.yaml` + `charts/hugmesh-gateway` |
| `hugmesh-federation-api` | build `hugmesh-federation-api` | `manifests/federation-api` |
| `hugmesh-admin-bff-api` | build `hugmesh-admin-bff-api` | `manifests/admin-bff-api` |
| `hugmesh-mod-bff-api` / `-user-bff-api` | build the respective repos | (not yet in cluster; wired by analogy) |
| `hugmesh-forum-bff-api` / `-wiki-bff-api` / `-owncast-bff-api` / `-tube-bff-api` | build the respective repos (spring-bff archetype siblings of admin-bff/federation-api) | `manifests/forum-bff-api` / `wiki-bff-api` / (owncast + tube ship co-located in-cluster; no dedicated BFF manifest dir yet) |
| `hugmesh-character-forge-bff-api` | build `hugmesh-character-forge-bff-api` (spring-bff archetype sibling) | `manifests/character-forge-bff-api` |
| `hugmesh-api` | build `hugmesh-actions` | `manifests/hugmesh-apis` |
| `hugmesh-remote-fragment` | build `hugmesh-remote-fragment` (sync image) | `manifests/remote-fragment` |
| `snapdragon-systems-web` (service name kept — the fe-gateway route target) | build `hugmesh-host-shell` | `manifests/frontend` |
| `hugmesh-{admin,mod,user,login,mastodon,matrix,forum}-ui`, `-api-docs` | build each UI repo | `manifests/social-ui` + the remote repos |
| `hugmesh-{wiki,owncast,tube}-ui` | build the respective repos | cluster serves these via the module-federation remote-fragment fleet, not a fixed gateway path; this compose stack adds a direct `/<slug>/**` route (mirroring mod-ui/user-ui) for local reachability + e2e |
| `hugmesh-character-studio-ui` | build `hugmesh-character-studio-ui` | `manifests/character-studio` (no dedicated BFF — talks to the existing BFFs over `/bff/**`) |
| `hugmesh-character-forge-ui` | build `hugmesh-character-forge-bff-api/frontend` (the Angular UI ships inside the BFF repo) | `manifests/character-forge` |
| `route-access-db` / `federation-db` / `admin-bff-db` | `postgres:16-alpine` | `manifests/route-access` / `federation-db` / `admin-bff-db` |
| `forum-bff-db` / `wiki-bff-db` / `owncast-bff-db` / `tube-bff-db` | `postgres:16-alpine` | `manifests/forum-bff-db` / `wiki-bff-db` / (owncast/tube: no dedicated DB manifest yet — pre-existing cluster-side gap) |
| `character-forge-bff-db` | `postgres:16-alpine` | `manifests/character-forge-bff-db` |
| `cassandra`, `casdoor`, `casdoor-db` | upstream images | `compose.real.yaml` (included) |
| `tuwunel`, `mastodon-*` | upstream images (`social` profile) | `compose.real.yaml` (included, opt-in) |

The gateway route tables in `tests/stack/gateway-routes/{pki,be,fe}/` are the
compose-DNS translation of the `routes:` in each `apps/20-gateway-*.yaml`.

---

## Honest limitations / what needs creds

- **Casdoor is empty on first boot, but `make stack-up` does NOT run the seeder.**
  `make stack-seed` (`tests/stack/seed-e2e.sh`) is a **required** follow-up step,
  not optional: it creates the `app-user-bff` OAuth2 client + the org/roles +
  e2e personas, and once it has run, **real browser SSO login works end-to-end**
  (`/login` with an e2e persona, e.g. `e2e-admin`/`e2e-pass` — see "Seeding the
  e2e fixtures" above). Before seeding — or for Casdoor **apps/users** this
  stack still doesn't provision (the federation manifest's fragment-sync client,
  an `actions` client) — expect the UIs to load but those specific auth-gated
  flows to 401 (the cluster seeds those via `manifests/casdoor/init-*`). The
  route-access DB **does** seed from `manifests/route-access/initdb/20-schema.sql`
  independent of `make stack-seed`.
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
- **hugmesh-actions two-Casdoor sync is inert:** both Casdoor URLs point at the
  single local Casdoor with placeholder client creds, so the games sync job does
  nothing locally (no separate games Casdoor in this stack).
- **Social tier is heavy + opt-in.** `SOCIAL=1` pulls tuwunel + Mastodon
  (web/sidekiq/streaming + Postgres/Redis). tuwunel needs no first-run
  step at all — the `tuwunel` service (`tests/stack/compose.real.yaml`) is
  configured entirely declaratively via `TUWUNEL_*` env, so a fresh volume
  comes up registration-enabled on every bring-up path, the same whether you
  go via `SOCIAL=1` or `tests/stack/up-real.sh`. Mastodon's `db:prepare`
  first-run migration is NOT run by `SOCIAL=1`, though; for a fully working
  Mastodon (and to skip a manual `rails db:prepare`), use
  `tests/stack/up-real.sh` (the dedicated real-services bring-up), which
  still handles that step.
- **No mTLS / no ingress / no SELinux-MCS.** The cluster's service-to-service
  mTLS, nginx ingress, and per-pod SELinux levels are k8s concerns and are not
  reproduced here. The *front door* does offer browser-facing TLS
  (https://localhost:8488 via the `https-front` terminator, ENV=test and
  ENV=prod alike); inter-service traffic inside the compose network stays
  plain HTTP.
- **prod creds are NOT committed.** `ENV=prod` only changes the issuer URL; you
  must inject real secrets yourself (see ENV section). Nothing secret lives in
  this repo — only dev placeholders matching the cluster's dev placeholders.
- **forum-bff has no phpBB backend here.** `hugmesh-forum` (the isolated
  phpBB pod + its `forum-api` extension) is not wired into this stack, so
  `PHPBB_ENABLED`/`EXTERNAL_FORUM_ENABLED` are forced `"false"` — forum-bff
  boots clean and always-audits instead of failing every call against an
  absent backend (same class of limitation as the admin-bff analytics note
  above). The owncast third-party streaming pod (RTMP ingest) and the
  tube-media signed-URL Nginx sidecar are likewise out of scope here (only the
  UI+BFF pair for each is wired) — `manifests/owncast` / `manifests/tube` show
  the full cluster shape.
- **`ROLE_WIKI` / `ROLE_FORUM` (and the derived `ROLE_FORUM_MOD`) are not yet
  seeded in `manifests/casdoor/init-data-configmap.yaml`** — a pre-existing gap
  predating this compose wiring (the `gateway_route_access` rows that gate
  `/bff/wiki/**`, `/bff/forum/**`, `/social/forum/**` etc. already referenced
  these roles). Until a Casdoor seed grants them, only an admin/superadmin
  persona (via the gateway's documented admin-bypass) reaches the forum/wiki
  surfaces end-to-end locally; `ROLE_TUBE`/`ROLE_OWNCAST` ARE already seeded,
  so a persona granted those reaches tube/owncast normally.
- **superadmin-service-catalog is intentionally NOT wired to the `:8088` front
  door.** Its cluster design (`specs/cluster/apps/22-gateway-superadmin.yaml`)
  is TAILNET-ONLY behind a dedicated `hugmesh-superadmin-gateway` — "off
  EVERY public-ingress gateway" by design (network isolation is one of its
  three intentional locks). This compose stack has no equivalent third
  gateway; adding the route to the shared fe-gateway would collapse that
  lock, so it is left unwired here (a real fix is a separate, dedicated
  superadmin-gateway compose service + published port, not a `:8088` route).
  There is likewise no separate "superadmin-appstore" service/repo to wire —
  that name is the design doc's project codename for this same
  service-catalog feature, not a distinct deliverable.
