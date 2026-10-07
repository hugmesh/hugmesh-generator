# Run the ENTIRE HugMesh stack locally (docker-compose)

This brings up the **whole HugMesh platform on one x86_64 machine** with
docker-compose. It **builds every first-party service from its cloned repo**:
the three gateways, the Spring backends (federation, actions and the
admin / mod / user / forum / wiki / owncast / tube / character-forge BFFs),
the static fragment fleet, and every Angular remote + the host — plus the
datastores (nine Postgres databases, Cassandra) and Casdoor.

It works on **Linux** (`make stack-up`) and on **Docker Desktop for Windows**
(`scripts/stack-up.ps1`), for both **ENV=test** and **ENV=prod** build modes.

This is the dev "everything on my laptop" path. It is **not** the production
deployment, which is the k8s cluster in `specs/cluster/` driven by ArgoCD. The
compose topology translates those manifests faithfully to compose DNS.

---

## Prerequisites

- **Docker** with **Compose v2** (`docker compose version` ≥ v2). Docker Desktop
  on Windows includes it; on Linux install `docker-compose-plugin`.
- **BuildKit / buildx** visible **in the environment you run `make` from**.
  Several service Dockerfiles use BuildKit syntax (`# syntax=docker/dockerfile:1.7`
  + `RUN --mount=type=secret`). The Makefile exports `DOCKER_BUILDKIT=1`, but the
  buildx CLI plugin is often installed **per-user** (`~/.docker/cli-plugins`). A
  `sudo`/systemd/other-`HOME` invocation then falls back to the legacy builder
  without a word and dies with opaque Dockerfile parse errors. `docker buildx version`
  must work as the invoking user.
- **A cold build** (no `hugmesh-local-*` images yet, e.g. a fresh box or a
  wiped docker data-root) also needs the org-private maven artifacts. Run
  **`make stack-m2-bootstrap` once first** (see "Cold builds" below).
- **x86_64 / amd64.** First-party images are amd64 (Temurin JRE, node-alpine,
  nginx). Apple Silicon / arm64 would need emulation, which is out of scope.
- **GitHub access OR internal VPN**, so the repos can be cloned. Either:
  - `gh auth login` (GitHub CLI logged in), or
  - a git credential helper / token (`GH_TOKEN` / `GITHUB_TOKEN`), or
  - the VPN + the internal mirror (`GIT_BASE=https://gitlab.hugmesh.net/hugmesh`).
- **Resources:** the default profile set is 43 compose services, two of them
  one-shot init jobs (`docker compose config --services`): JVM and nginx services,
  nine Postgres databases (one per service plus Casdoor's), Cassandra, Casdoor.
  Budget **~8 GB RAM** for the core and **~12–16 GB** with `SOCIAL=1`
  (tuwunel + the full Mastodon tier). The first build compiles several Maven + Angular
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

`make stack-up` alone seeds **no** personas, so sign-in fails until you
also run `make stack-seed` (`tests/stack/seed-e2e.sh`). It creates the org,
roles and personas behind every login, and it is a **required** follow-up step
(see "Seeding the e2e fixtures" below).

Then open **http://localhost:8088** (the fe-gateway front door), or its HTTPS
twin **https://localhost:8488**, and sign in at the **native login form**
(`/login`). The browser POSTs credentials to `/bff/login` and never touches
Casdoor. Both doors serve the identical platform in ENV=test *and* ENV=prod:
the `https-front` nginx terminator proxies everything to the same fe-gateway,
using a **per-machine** CA + leaf that `make stack-certs` mints automatically
on first `stack-up` (gitignored under `tests/stack/.tls-front/`). Import
`tests/stack/.tls-front/ca.crt` into your browser for a green lock, or accept the
self-signed warning. `rm -rf tests/stack/.tls-front` re-mints.

Casdoor is still published at **http://localhost:8000** in this dev stack, but
ONLY as an admin/seed convenience (the `seed-e2e.sh` provisioning transport). It is
**not** part of the login path and has no browser-facing role. In the cluster
Casdoor gets no public ingress at all.

Useful overrides:

```bash
make stack-up SOCIAL=1                       # also bring up tuwunel + Mastodon
make stack-up PHPBB=1                        # also bring up phpBB (alt forum)
make stack-up AKKOMA=1                       # also bring up Akkoma (alt fediverse)
make stack-up SOCIAL=1 AKKOMA=1              # Mastodon AND Akkoma side by side
make stack-up STACK_NO_CLONE=1               # build .stack-src AS-IS (see below)
make stack-up PUBLIC_HOST_PORT=9090          # publish the front door elsewhere
make stack-up PUBLIC_HTTPS_PORT=9443         # publish the HTTPS front door elsewhere
make stack-up STACK_SRC=/srv/snap-src        # clone/build from a different dir
make stack-clone GIT_BASE=https://gitlab.hugmesh.net/hugmesh  # VPN mirror
make stack-up ENV=prod CASDOOR_ISSUER=https://id.hugmesh.net     # prod mode
```

---

## Cold builds — `make stack-m2-bootstrap` (private maven artifacts)

Every Java service (the BFFs, `federation-api`, `remote-fragment`, the three gateways,
`hugmesh-api`) resolves org-PRIVATE maven artifacts (`net.hugmesh:hugmesh-parent/-commons/-auth-core/
-build-config`) at **image-build** time via a `settings.xml` (committed in the BFFs,
`federation-api` and `remote-fragment`; injected by `scripts/patch-stack-src.sh`
for the three gateways and `hugmesh-api`, which ship none)
(`${env.CI_API_V4_URL}/groups/${env.GITLAB_GROUP_ID}/-/packages/maven` — the
GitLab group registry, unreachable off the VPN). While the built
`hugmesh-local-*` images exist locally you never notice; on a **cold build**
(fresh box, wiped docker data-root) `docker compose build` fails resolving them.

```bash
make stack-m2-bootstrap   # once (idempotent)
make stack-up             # now auto-wires the local registry into the build
```

What it does (`tests/stack/m2-bootstrap.sh`, everything built from SOURCE, nothing
vendored):

1. Clones the four library repos at **pinned commits** into
   `~/.cache/hugmesh-stack-maven/src`, then `mvn install`s them into
   `~/.cache/hugmesh-stack-maven/m2` using the official `maven` Docker image
   (no host JDK/maven needed). The repos carry no git tags, and each SHA's
   `pom.xml` is exactly the version the services require. Today that is
   `hugmesh-build-config` **0.5.0**, `hugmesh-parent` **2.8.0**,
   `hugmesh-commons` **2.1.0**, and **three** `hugmesh-auth-core` pins:
   **2.5.1** (the one coordinate the org release chain publishes; both BFFs move to it),
   **2.4.2** (user-bff) and **2.5.0** (admin-bff). The last two stay until both
   consumers' mains name 2.5.1. The consumers have separate release cadences, so a
   cold build against an older consumer pom needs its jar in the local registry.
   ⚠️ auth-core has been re-cut four times under a released coordinate
   (2.4.0 → 2.4.1 → 2.4.2 → 2.5.0), so read
   [`tests/stack/m2-bootstrap.sh`](../tests/stack/m2-bootstrap.sh), the
   authoritative pin, rather than this sentence. Cached artifacts are skipped:
   no re-clone, no re-build.
2. Serves that m2 repo from a tiny static registry **container**
   (`hugmesh-m2-registry`, busybox httpd) shaped like the GitLab group
   registry URL. It must be a container: on some hosts, host-published ports are
   NOT reachable from `docker build` containers, so the build reaches it by its
   docker-bridge IP.
3. Writes `tests/stack/.m2-registry.env` (gitignored). Whenever that file
   exists, `make stack-up`/`stack-build` auto-include the committed override
   `tests/stack/compose.m2-local.yaml`, threading `CI_API_V4_URL`/
   `GITLAB_GROUP_ID` as build args into every Java service. No token is needed:
   the Dockerfiles' `ci_job_token` secret mount is optional-guarded and the
   static registry ignores auth headers.

Two committed companions make the resolution actually work:

- the Makefile exports `DOCKER_BUILDKIT=1` on every stack compose call (the
  Dockerfiles use BuildKit secret mounts), and
- `scripts/clone-all-repos.sh` runs `scripts/patch-stack-src.sh` after every
  clone/update, the general post-clone patch pass. Its current patch injects a
  `maven-default-http-blocker` mirror override into each consumer repo's
  `settings.xml` (idempotent, marker-scoped). Maven 3.9's bundled
  settings block ALL external `http://` repositories, and the local registry is
  plain HTTP by design.

The registry container survives reboots (`--restart unless-stopped`), but its
bridge IP can change when docker restarts. `make stack-up` and `make stack-build`
notice a stale `.m2-registry.env` (or a missing pinned artifact) and re-run
`stack-m2-bootstrap` themselves; it is cheap and refreshes the file. Remove it with
`docker rm -f hugmesh-m2-registry` once your images are built.

---

## Windows (Docker Desktop) — `scripts/stack-up.ps1`

`make` and `bash` are usually absent on Windows, so a **PowerShell** wrapper does
the same clone → build → run. It needs **only Docker Desktop**. Cloning runs inside
a throwaway `alpine/git` container (the "bootstrap" path), so you need no host git
either. Pass a token for private repos.

```powershell
# From the repo root, in PowerShell:
pwsh -File scripts\stack-up.ps1 -GhToken ghp_yourtoken         # ENV=test (default)
pwsh -File scripts\stack-up.ps1 -GhToken ghp_yourtoken -Social # + tuwunel/Mastodon
pwsh -File scripts\stack-up.ps1 -Env prod -CasdoorIssuer https://id.hugmesh.net
pwsh -File scripts\stack-up.ps1 -Down                          # tear down (-v)
```

On the VPN you can skip the token and point at the mirror:

```powershell
pwsh -File scripts\stack-up.ps1 -GitBase https://gitlab.hugmesh.net/hugmesh
```

If you have git on Windows and prefer it to the container clone, add
`-UseHostGit`.

### One-liner without the script (Docker-only)

With *only* Docker (no PowerShell script), clone via the
same bootstrap container, then drive compose directly. From the repo root
(`cmd`/`pwsh`):

```bat
docker run --rm -v "%cd%\scripts:/scripts:ro" -v "%cd%\.stack-src:/stack-src" ^
  -e STACK_SRC=/stack-src -e GIT_BASE=https://github.com/hugmesh ^
  -e USE_GH=0 -e GH_TOKEN=%GH_TOKEN% alpine/git:latest sh /scripts/clone-all-repos.sh

set STACK_SRC=../../.stack-src
set CASDOOR_ISSUER_URI=http://localhost:8000
set PUBLIC_HOST_PORT=8088
docker compose -f tests\stack\compose.local.yaml build
docker compose -f tests\stack\compose.local.yaml up -d
```

### Windows gotchas (handled)

- **CRLF:** `.gitattributes` forces **LF** on all `*.sh` / `*.yaml` / `*.conf` /
  `Dockerfile*`, so the shell scripts and gateway route configs work inside the
  Linux containers even on a Windows checkout. PowerShell stays CRLF.
- **Path separators:** compose `build.context` paths are **relative** posix paths
  (`../.stack-src/<repo>`), and `STACK_SRC` is passed as `../.stack-src`, so the engine
  resolves them identically on both OSes. Bind mounts use compose-relative paths.
- **Credential passing:** the GitHub token goes into the bootstrap container as an
  **env var**. It is never baked into an image or committed.

---

## ENV = test vs prod

The same `ENV=test|prod` knob the image build uses (see `docs/LOCAL-TESTING.md`)
selects the identity issuer the whole stack trusts:

| | `test` (default) | `prod` |
|---|---|---|
| Casdoor issuer (`CASDOOR_ISSUER_URI`) | `http://localhost:8000` (the local Casdoor) | the **real** issuer. `make` derives `https://id.<DOMAIN>` (`id.hugmesh.net` when `DOMAIN` is unset); `CASDOOR_ISSUER=…` overrides it |
| creds | **dev placeholders** (committed: `gateway`/`federation`/`adminbff` DB passwords, dev Casdoor client ids) | **real** — sourced from **your env / the keys USB**, NOT committed |
| domain-ish env (host MATRIX_URL/MASTODON_URL) | `http://localhost:…` | real `https://…` domain |

**Prod creds source:** `make stack-up ENV=prod` only flips the issuer URL. You
must inject the real Casdoor client secrets, DB passwords and social-tier secrets
at run time (e.g. `CASDOOR_ISSUER=…`, and edit
`tests/stack/.mastodon.env` / a Casdoor app for the fragment-sync + actions
machine accounts). Production proper is the k8s cluster (Vault + External Secrets,
`scripts/gen-cluster-secrets.sh`). This compose stack is a **dev convenience** and
ships only dev placeholders, so nothing secret is committed.

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
| http://localhost:8081 | phpBB (only with `PHPBB=1`) — alternative forum |
| http://localhost:4001 | Akkoma (only with `AKKOMA=1`) — alternative fediverse server |
| (not published) | Cassandra (gateway revocation list + URL registry) — reachable only inside the compose network as `cassandra:9042` |

The fe-gateway routes (`tests/stack/gateway-routes/fe/`) fan out from the front
door to `/admin/**`, `/login/**`, `/social/**` (matrix/mastodon/forum/phpbb),
`/mod/**`, `/user/**`, `/api-docs/**`, `/wiki/**`, `/owncast/**`, `/tube/**`,
`/character-studio/**`, `/character-forge/**`, `/bff/**` (each of
admin/mod/user/forum/wiki/owncast/tube/character-forge-bff, then the admin-bff catch-all), `/_fragments/**` (fragment fleet), and `/be/**`
(the be-gateway → federation + actions). Of the platform services, only the fe-gateway
(and its `https-front` terminator) is published to the host; everything else is
internal compose DNS, exactly as in the cluster only the gateways are
ingress-exposed. Casdoor and the social tier publish ports as dev conveniences
(table above).

---

## Alternative social backends — `PHPBB=1` / `AKKOMA=1`

Two third-party servers are **options** alongside the first-party
stack. Each sits behind its own compose profile in
`tests/stack/compose.alt-social.yaml`. Both are **DEFAULT-OFF** (the
tube/owncast precedent) and independent of `SOCIAL`, so a plain `make stack-up`
is unaffected:

| Knob | Service | Alternative to | Port |
|---|---|---|---|
| `PHPBB=1` | phpBB 3.3 + the `hugmesh/forumapi` extension | the first-party `hugmesh-forum-ui` + `hugmesh-forum-bff-api` | 8081, **and `/social/phpbb/` at the front door** |
| `AKKOMA=1` | Akkoma v3.20.0 | Mastodon (Akkoma is a Pleroma fork with the same ActivityPub + Mastodon-client API surface) | 4001 |

The fe-gateway also mounts phpBB at **`/social/phpbb/`**, a sibling of the
first-party `/social/forum/`, so you can compare the two at the same front door.
Auth gating is identical: `/social/forum/`, `/social/phpbb/`
and `/social/mastodon/` all return 401 unauthenticated. The phpBB route uses
`StripPrefix=2`, like the other `/social/*` routes: the image installs phpBB with
`script_path=/`, so the upstream expects paths rooted at `/`.

Akkoma is reachable on its published port only. The gateway does not route to it,
because unlike Mastodon it has no platform OAuth/BFF integration. Its
Mastodon-compatible API answers directly, e.g.
`curl http://localhost:4001/api/v1/instance`.

```bash
make stack-up PHPBB=1                 # core platform + phpBB
make stack-up SOCIAL=1 AKKOMA=1       # Mastodon AND Akkoma together
make stack-up SOCIAL=1 PHPBB=1 AKKOMA=1
```

Each gets its **own Postgres** rather than sharing `mastodon-db`. Akkoma needs
database-level extensions and phpBB owns its schema outright, so sharing would
couple two otherwise independent teardowns.

`make stack-down` / `stack-clean` pass **every** profile unconditionally, so
they reap these containers even when the `down` invocation does not repeat the
knob that started them.

### Packaging caveats (checked 2026-08-12) — read before copying this pattern

Unlike `mastodon`/`tuwunel`/`postgres`, which this stack pins to maintained
upstream images, **neither project publishes a usable first-party image**. The
upstream-image claims below were last checked on 2026-08-12. The phpBB build was
re-read against `hugmesh-forum-api` and `compose.alt-social.yaml` on 2026-10-07.

- **phpBB** — there is no official image on Docker Hub or ghcr;
  `github.com/phpbb/docker` is CI scaffolding pinned to PHP 5.4–7.0, and
  `bitnami/phpbb` 404s. The stack builds
  `${STACK_SRC}/hugmesh-forum-api` instead, the phpBB image the cluster deploys
  (`specs/cluster/manifests/forum/phpbb.yaml`): official phpBB 3.3 plus the
  `hugmesh/forumapi` headless extension. The extension matters. phpBB ships no
  REST API, and `hugmesh-forum-bff-api` can talk to nothing else; a vanilla
  board answers 401 on every `/api/v1/hugmesh/**` call. The entrypoint
  installs the schema once on an empty DB and enables the extension, so the
  profile comes up as a working forum. Dev-placeholder admin: `sysadmin` /
  `adminadmin` (from the extension repo's `docker/install-config.compose.yml`).
- **Akkoma** — upstream ships **no prebuilt image at all**; its own
  docker-compose builds from source via `docker-resources/build.sh`. A
  from-source Elixir build would add many minutes to a default-off option, so
  the compose file uses an actively-maintained **community mirror**
  (`teslamint/akkoma`) **pinned by digest**, not merely by tag, so the content
  is immutable even if the tag is force-pushed. That image is **unofficial**:
  fine for a local test lane, **not** a pattern to copy into `specs/cluster/`
  for a real deployment, where it should be replaced by a first-party build.

---

## Seeding the e2e fixtures — `tests/stack/seed-e2e.sh` (a.k.a. `make stack-seed`)

The UI e2e suites assume a set of personas, rooms and relationships exists. Since
PR #227 this is also **the required step that makes login work at all**.
A fresh compose Casdoor boots with no org, roles or personas, so without seeding
the native `/bff/login` form (or an e2e persona) has nothing to
authenticate against. Against a
**running** core stack (front door `http://localhost:8088`, Casdoor
`http://localhost:8000`, brought up by `make stack-up`), run:

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
   RBAC reads). A fresh compose Casdoor lacks this entirely. Without
   it, browser SSO login has no application to redirect to.
2. **Personas** (Casdoor org `hugmesh`): the standard matrix
   (`e2e-user`/`e2e-mod`/`e2e-admin`/…) **plus** `e2e-superadmin`, `e2e-banned`
   (ban = the **absence** of the platform access roles, seeded as the post-ban
   state) and the domain-locked pair (`e2e-*-domainlocked`; lock = the
   **presence** of the marker role). The compose Casdoor boots **empty**, so
   the script first creates the org + the `ROLE_*` objects, then applies users +
   role members and pre-mints per-persona JWTs into `tests/stack/.seed-e2e/jwt-cache`
   (usable as `SNAP_PREMINT_DIR`). Default admin creds are the fresh-casdoor dev
   default (`admin`/`123`); override `CASDOOR_ADMIN_PASS` otherwise.
3. **Matrix (tuwunel)**: users `e2e-mod` + `e2e-user`, registered from the
   host over the public CS-API (UIAA `m.login.dummy`; no container exec, because the
   distroless tuwunel image has no shell); **public room X**
   (`#e2e-public-x:localhost`) and **invite-only room Y** (`#e2e-invite-y:localhost`,
   `e2e-user` invited; verified `join_rule=invite`).
4. **Mastodon**: accounts `e2e_usera` + `e2e_userb` (underscore, because Mastodon's
   username validator rejects hyphens); follower relationship
   **`e2e_userb` → `e2e_usera`**; **one pending moderation-queue item** (an
   unresolved report of `e2e_usera` filed by `e2e_userb`).

`make stack-seed` seeds registration **stage 1** (the Casdoor identity) only. Add
`SEED_COMPLETE_REGISTRATION=1` to run stage 2 (`POST /bff/register/complete`) too.
Without it you can sign in, but `GET /bff/session` reports
`registrationComplete=false` and every service route answers 403.

The script is **idempotent** (probe-before-create everywhere; safe to re-run)
and **fail-honest**. Every unmet dependency dies with a message naming it (which
service, which bring-up command). It never prints success for something it did
not verify.

### What remains UNVERIFIABLE on compose (honest limitations)

- **Second tenant**: the standard compose stack runs a **single** Casdoor, so the
  `e2e-tenant2-user` persona / cross-tenant brand-wall scenarios cannot be modeled
  here. The script WARNs loudly (fatal with `SEED_STRICT=1`); set
  `CASDOOR_BRAND_B_URL` (e.g. the pentest two-brand profile) to seed it for real.
- **pleroma-admin-only verbs**: the compose social tier is **tuwunel + mainline
  Mastodon**. The Matrix half runs the same homeserver + image tag as the
  cluster payload (`ghcr.io/matrix-construct/tuwunel:v1.7.0`), though in
  LAN-test posture: open registration, federation off, no mTLS proxy. The
  cluster runs closed registration behind `tuwunel-proxy:4443`. The
  fediverse half is still Mastodon, not Akkoma. mod-bff actions wired to the
  pleroma-admin API (block/ban Akkoma leg: `PATCH /api/v1/pleroma/admin/users/
  deactivate`, `DELETE /api/v1/pleroma/admin/instances/{host}`) will 404 upstream.
  Suites must assert the bff's **honest DEGRADED envelope** here, never a fake
  success. The mod-bff **Matrix block leg is STUBBED BY DESIGN** everywhere:
  tuwunel has no general REST admin API (only the Synapse-compat
  `/_synapse/admin/v1/register` shared-secret shim), and moderation lives in the
  admin room. The leg returns an honest 202/STUBBED envelope, never "OK".
- **Domain-lock enforcement**: the Akkoma `ForceLocalForUsers` MRF + the egress
  backstop do not exist on mainline Mastodon/compose, so the non-federation specs
  (`tests/e2e/specs/19-23`) stay honestly **skipped** here (`SNAP_FEDERATION_PEER`
  / `SNAP_DOMAINLOCK_ENABLED` unset). The domain-locked **personas** are still
  seeded, so the UI surfaces (role badges, disabled+helptext controls) render.

---

## How it maps to the cluster

| compose service | image / build | k8s source |
|---|---|---|
| `hugmesh-{pki,be,fe}-gateway` | build `hugmesh-gateway` (×3, `SPRING_APPLICATION_NAME`) | `apps/20-gateway-*.yaml` + `charts/hugmesh-gateway` |
| `hugmesh-federation-api` | build `hugmesh-federation-api` | `manifests/federation-api` |
| `hugmesh-admin-bff-api` | build `hugmesh-admin-bff-api` | `manifests/admin-bff-api` |
| `hugmesh-mod-bff-api` / `-user-bff-api` | build the respective repos | `manifests/mod-bff-api` / `manifests/user-bff-api` |
| `hugmesh-forum-bff-api` / `-wiki-bff-api` / `-owncast-bff-api` / `-tube-bff-api` | build the respective repos (spring-bff archetype siblings of admin-bff/federation-api) | `manifests/forum-bff-api` / `wiki-bff-api` / (owncast + tube ship co-located in-cluster; no dedicated BFF manifest dir yet) |
| `hugmesh-character-forge-bff-api` | build `hugmesh-character-forge-bff-api` (spring-bff archetype sibling) | `manifests/character-forge-bff-api` |
| `hugmesh-api` | build `hugmesh-actions` | `manifests/hugmesh-apis` |
| `hugmesh-remote-fragment` | build `hugmesh-remote-fragment` (the SYNC image — writes bundles into the shared docroot; its `SERVER_PORT: 8081` listener is actuator-only and serves no bundle bytes) | `manifests/remote-fragment` (the pod's `sync` container) |
| `hugmesh-remote-fragment-web` | `nginxinc/nginx-unprivileged` serving the shared `remote-fragment-bundles` volume; **this is what the fe-gateway's `/_fragments/**` route targets**. Its nginx config is the cluster's own ConfigMap file, bind-mounted so the lanes cannot drift. | `manifests/remote-fragment` (the pod's `web` container + its `nginx.conf`) |
| `hugmesh-host-shell` (service name kept — the fe-gateway route target) | build `hugmesh-host-shell` | `manifests/frontend` |
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
`tests/scripts/test-fe-bff-route-lane-parity.sh` is the offline guard that keeps
the fe pair honest for the `/bff/**` surface: it simulates Spring Cloud Gateway's
first-match-wins ordering over BOTH tables and fails if the same path resolves to
a different BFF on each. The same guard also pins decision 60
(`APP_BFF_EXCHANGE_CACHE_TTL_MS: "0"` for admin-bff-api and mod-bff-api on both
lanes; the gateway's own mirror of that cache is
`tests/stack/test-gateway-auth-flag-parity.sh`'s).

### All five `/bff/{me,provision,register}/*` paths now resolve to user-bff (updated 2026-09-18)

Until 2026-09-17 the two fe route tables disagreed about five `/bff` paths. The
cluster sent them to **user-bff** (via `/bff/register/**`, `/bff/me/**`,
`/bff/provision/**`, all declared above its `/bff/**` admin catch-all). Compose
had no entry for any of them, so all five fell through to its own
`/bff/**` **admin-bff** catch-all. That split is why the compose e2e lane never
saw the cluster's 404s (hugmesh-generator#366).

Operator decision 40 (hugmesh-generator#347) aligned compose onto the cluster:
**all five, both lanes identical**. Two of the five, the `/bff/register/*`
pair, first had no user-bff handler and 404'd on BOTH lanes. That gap
closed on 2026-09-18 (hugmesh/hugmesh-user-bff-api#20, commit `dc34c8b`). This
table was stale about it until this edit (flagged on hugmesh-generator#347
2026-09-18T07:21Z):

| path | before (compose) | after (compose + cluster) | served? |
|---|---|---|---|
| `GET /bff/me/namespaces` | admin-bff | **user-bff** | yes |
| `POST /bff/provision/matrix` | admin-bff | **user-bff** | yes |
| `POST /bff/provision/mastodon` | admin-bff | **user-bff** | yes |
| `POST /bff/register/google` | admin-bff | **user-bff** | yes (since #20) |
| `POST /bff/register/discord` | admin-bff | **user-bff** | yes (since #20) |

user-bff serves all five via `LegacyPathParityController`
(hugmesh/hugmesh-user-bff-api#15 @ `c3d24c4` for the first three;
hugmesh/hugmesh-user-bff-api#20 @ `dc34c8b` added the last two).
`SsoAuthController` still maps the exact path `/bff/register` only, which does
not collide with either. The FIVE table in `tests/scripts/test-fe-bff-route-lane-parity.sh`
asserts `has_handler=True` for every path, so a stale or `False` entry turns the
run red instead of only printing. That guard reads
only this repo's route tables, never user-bff's source. A **genuine** handler
removal in hugmesh-user-bff-api is caught over there, by its
`LegacyPathParityRegisterTest` and `SecurityConfigSsoPathRulesTest`, not by
this guard.

What you will notice on a local stack: nothing different from the
first three. All five behave the same way (seeded `ROLE_USER` in the
gateway's `CanonicalSeed`, so an unauthenticated `POST` is refused before it
reaches any BFF; a signed-in caller reaches a real handler on both register
paths, not a 404).

- **The QEMU seeder never goes through the front door.** `tests/qemu/seed-accounts.sh`
  calls `POST ${BFF}/bff/register/google` **directly at admin-bff on
  `127.0.0.1:8403`, with no gateway in the path**. Neither fe route table
  affects it: it was unaffected while the two paths 404'd and is unaffected now.
- **A stale `./.stack-src` breaks some or all five, depending how stale.** Compose
  builds user-bff from `${STACK_SRC:-./.stack-src}/hugmesh-user-bff-api`. A
  checkout pinned **before `c3d24c4`** has no `LegacyPathParityController` at
  all. `/bff/me/namespaces` and both `/bff/provision/*` 404 too, and
  admin-bff no longer catches them: admin-ui gets empty namespace grants, and
  every sign-in silently fails to provision (login-ui swallows the error). A
  checkout pinned **between `c3d24c4` and `dc34c8b`** has the controller but
  not yet the two register handlers. Only `/bff/register/google` and
  `/bff/register/discord` 404; the other three work. Re-run
  `scripts/clone-all-repos.sh` (`make stack-up` does) so `.stack-src`
  fast-forwards to `main`, then rebuild the `hugmesh-user-bff-api` image.
- **The mock lane is untouched, because it runs no gateway at all.**
  `tests/stack/up.sh` starts `mock-bff.mjs` plus the mock Matrix/Mastodon/UI
  servers as bare node processes ("this never runs a real Spring BFF/gateway").
  Only the compose stack mounts the fe route table
  (`compose.local.yaml`: `./gateway-routes/fe:/config:ro`), so that lane consults no
  route table. Do **not** read the mock lane as evidence that the two
  register paths work somewhere: `mock-bff.mjs` answers three of the five
  itself (`/bff/me/namespaces`, `/bff/provision/matrix`,
  `/bff/provision/mastodon`) plus `/bff/register/complete`, and has never had a
  `/bff/register/google` or `/bff/register/discord` handler.

---

## Honest limitations / what needs creds

- **Casdoor is empty on first boot, and `make stack-up` does NOT run the seeder.**
  `make stack-seed` (`tests/stack/seed-e2e.sh`) is a **required** follow-up step.
  It creates the `app-user-bff` OAuth2 client + the org/roles +
  e2e personas, and once it has run, **real browser SSO login works end-to-end**
  (`/login` with an e2e persona, e.g. `e2e-admin`; see "Seeding the e2e
  fixtures" above). **The password is generated fresh per run, never a fixed
  literal**: `make stack-seed` does not print it (the Studio persists that
  output). Read it from the run-state file (`${E2E_CREDENTIALS_FILE:-.e2e-credentials}`
  at the repo root); the Studio's local-mesh page also shows it in a copyable
  credentials table (or "not seeded yet" if that run hasn't happened). Before
  seeding, and for the Casdoor **apps/users** this
  stack still doesn't provision (the federation manifest's fragment-sync client,
  an `actions` client), expect the UIs to load but those auth-gated
  flows to 401. The cluster seeds those via `manifests/casdoor/init-*`. The
  route-access DB **does** seed from `manifests/route-access/initdb/20-schema.sql`,
  independent of `make stack-seed`.
- **Fragment fleet serves an empty set** until federation has enabled modules +
  a valid `app-fragment-sync` Casdoor client, so `/_fragments/**` is up but
  empty. It is the standalone sync image on `:8081` (in k8s it is nginx + a sync
  sidecar over a shared volume).
- **admin-bff analytics is off:** the local stack runs only the `casdoor`
  profile, not the cluster's `casdoor,clickhouse`. There is no Kafka/ClickHouse
  here, so `/bff/admin/usage` is not exercised. Route-access CRUD works.
- **hugmesh-actions two-Casdoor sync is inert:** both Casdoor URLs point at the
  single local Casdoor with placeholder client creds, so the games sync job does
  nothing locally (no separate games Casdoor in this stack).
- **Social tier is heavy + opt-in.** `SOCIAL=1` pulls tuwunel + Mastodon
  (web/sidekiq/streaming + Postgres/Redis). tuwunel needs no first-run
  step: the `tuwunel` service (`tests/stack/compose.real.yaml`) is
  configured entirely declaratively via `TUWUNEL_*` env, so a fresh volume
  comes up registration-enabled whether you go via `SOCIAL=1` or
  `tests/stack/up-real.sh`. Mastodon's `db:prepare`
  first-run migration runs by itself: the one-shot `mastodon-init` service
  (profile `social`) does it. `tests/stack/up-real.sh` (the dedicated
  real-services bring-up) does the same step by hand.
- **No mTLS / no ingress / no SELinux-MCS.** The cluster's service-to-service
  mTLS, nginx ingress and per-pod SELinux levels are k8s concerns. This stack does
  not reproduce them. The *front door* does offer browser-facing TLS
  (https://localhost:8488 via the `https-front` terminator, ENV=test and
  ENV=prod alike); inter-service traffic inside the compose network stays
  plain HTTP.
- **prod creds are NOT committed.** `ENV=prod` only changes the issuer URL, so you
  must inject real secrets yourself (see ENV section). Nothing secret lives in
  this repo, only dev placeholders matching the cluster's dev placeholders.
- **forum-bff points at `phpbb:8080`, which exists only with `PHPBB=1`.** Without
  that profile the forum BFF boots but has no backend. The owncast streaming pod
  (RTMP ingest) and the tube-media signed-URL Nginx sidecar are out of scope here
  (only the UI+BFF pair for each is wired); `manifests/owncast` / `manifests/tube`
  show the full cluster shape.
- **`ROLE_WIKI` / `ROLE_FORUM` (and the derived `ROLE_FORUM_MOD`) start with no
  members.** `manifests/casdoor/init-data-configmap.yaml` defines the roles, but
  grants them to nobody. The `gateway_route_access` rows that gate
  `/bff/wiki/**`, `/bff/forum/**`, `/social/forum/**` etc. need them. Until a
  persona holds the role (`tests/qemu/seed-accounts.sh` defines an `e2e-forum`
  persona with `ROLE_FORUM`), only an admin/superadmin persona (via the gateway's
  documented admin-bypass) reaches the forum/wiki surfaces end-to-end locally.
  `ROLE_TUBE` and `ROLE_OWNCAST` are seeded the same way, so a persona granted
  those reaches tube/owncast normally.
- **superadmin-service-catalog is intentionally NOT wired to the `:8088` front
  door.** Its cluster design (`specs/cluster/apps/22-gateway-superadmin.yaml`)
  is TAILNET-ONLY behind a dedicated `hugmesh-superadmin-gateway`, "off
  EVERY public-ingress gateway" by design (network isolation is one of its
  three intentional locks). This compose stack has no equivalent third
  gateway, and adding the route to the shared fe-gateway would collapse that
  lock, so it stays unwired here. A real fix is a separate, dedicated
  superadmin-gateway compose service + published port, not a `:8088` route.
  There is likewise no separate "superadmin-appstore" service/repo to wire:
  that name is the design doc's project codename for this same
  service-catalog feature, not a distinct deliverable.
