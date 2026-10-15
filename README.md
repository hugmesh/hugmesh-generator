# hugmesh-generator

Crossdev / native build scripts that produce **hardened Gentoo images** for the
HugMesh cluster — three Raspberry Pi 5 (aarch64) role images plus an x86_64
GPU host — and the **GitOps payload** that runs Casdoor, tuwunel (Matrix) + Akkoma (fediverse), the
Spring APIs and hugmesh.games on them. Everything connects **behind
`hugmesh.net`** through per-namespace Spring Cloud Gateways.

Every image boots, then provisions itself at first boot from a USB **FAT32
`KEYS` partition** (users, SSH keys, passwords, certificates, headscale/k8s
config, attached storage, backups) — see [`keys-template/`](keys-template/).

Every build is stamped with a **build ENV** — `test` (default, LAN-only) or
`prod` (real public domain) — baked into the image at creation. The simplest
way in is `make local` (a LAN `.test` fleet) or `make prod`; see
**[Build ENV](#build-env-testprod-baked-at-image-creation)** below.

> **New operator? Start with [`docs/RUNNING.md`](docs/RUNNING.md)** — the
> end-to-end runbook (prerequisites → clone → `brand.conf` + build knobs → build
> → keys + KEYS USB → flash → provision → cluster). Then read
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full topology and
> [`docs/LOCAL-TESTING.md`](docs/LOCAL-TESTING.md) for LAN testing. To generate a
> whole platform from scratch and **serve it** — locally, then publicly over a Tor
> `.onion` / a Dynamic-DNS host / a tunnel — follow
> [`docs/SERVE-YOUR-MESH.md`](docs/SERVE-YOUR-MESH.md).

All build output lands in a **git-ignored** work directory (`./out` by default,
for both `make` and the scripts called directly; override with `WORK_DIR=` /
`-w`). The finished **products** (`.img`, `.iso`, `.fs.tar.xz`, `stage4-*`,
`keys-<role>/`) land directly in the work dir. Each arch's **heavy build tree**
(sysroot, distfiles, pkgdir, ISO staging) lives in a **per-arch subdirectory**
under it — `out/snap-build-pi5` (aarch64) and `out/snap-build-x86` (amd64) — so
the Pi and x86 builds **never share a sysroot**, even when the whole fleet builds
into one work dir via `make build-all`. Override a subdir name with
`--build-subdir NAME` (or `BUILD_SUBDIR=NAME`). `make clean` wipes the work dir,
subdirs included.

## Current State

_As of 2026-08-05, except the kind SSO e2e bullets, re-measured 2026-10-14. State key: **✅ shipped** (on `main`) · **🚧 in-flight** · **🔭 planned**._

> **"Ships dark" counts as shipped.** Several capabilities below are complete on
> `main` and deliberately inert behind a documented default-off flag — that is a
> deployment posture, not an unfinished feature. Every such entry names the flag
> or runbook that lights it, and the honest caveats that survive the flip.

- **✅ Hardened image fleet** — three RPi 5 role images (pki / backend / frontend)
  + the x86_64 GPU host, built compact and grown on first boot, plus the client /
  appliance families that ride the same arm64 cross path + mesh/KEYS provisioning:
  the opt-in **Frite** light desktop, the **Jetson Orin** edge-AI family, and the
  **Orange Pi** platform family (see below). All images build the **MCS** SELinux
  policy with per-pod/per-app category isolation — but ⚠️ **nodes boot
  PERMISSIVE**, not enforcing: `provision.json`'s `.selinux.mode` defaults to
  `permissive`, and the enforce-gate (`specs/etc/init.d/selinux-enforce-gate`)
  ships **inert** (in no runlevel, `SELINUX_ENFORCE_GATE="no"`) unless an
  operator sets `HUGMESH_SELINUX_ENFORCE_GATE=1` at build time. That is
  deliberate — the node-policy `.te` rules are still tagged `INFERRED-WIDE` and
  can only be narrowed against a real AVC pass. See
  [`docs/selinux-module-loading.md`](docs/selinux-module-loading.md).
- **✅ SELinux node policy compiled + loaded (all ten builders)** — the hugmesh
  node-policy modules are compiled against the *sysroot's* refpolicy headers,
  installed into every image and loaded at first boot from
  `/usr/share/hugmesh/selinux-modules.list`; seven modules are mandatory (a
  compile failure fails the build) and the two k8s exemplars are conditional on
  `selinux-container` headers. Gated by `tests/scripts/test-selinux-policy-install.sh`
  (the `SLX` bucket of the build matrix). Flipping the fleet to **enforcing** is
  the honest remaining step — see [Roadmap](#roadmap).
- **✅ Boot + kernel hardening (both arches)** — kernel lockdown (`lsm=lockdown,
  yama,selinux,bpf` + `lockdown=integrity` on x86 + rpi5; `lsm=lockdown,yama,selinux`
  + `lockdown=integrity` on the 8 ARM boards), Secure Boot **UKI** signing on x86
  (dracut `--uefi` → org-key `sbsign`), and sysctl/SSH hardening, plus the x86
  build fixes that supersede the earlier kernel-config changes. The **x86 k8s
  netfilter/NAT/eBPF kernel surface** the Service/kube-proxy/CNI path needs is now
  carried in the amd64 fragment with a **fail-closed build guard** + a CI lint
  (`lint:x86-kernel-net-symbols`) that keeps it from re-truncating (the standalone
  fix PR is superseded; the symbols + guard + test landed on `main` with the
  hardening pass). **Host firewall differs by arch:** x86 ships `firewalld`
  (test/prod zone profiles); on the cross-compiled **rpi5** arm64 platform
  firewalld is a **deliberate, gate-pinned exclusion** — the 2026-08-05 real build
  proved `glib[introspection]`'s in-source gobject-introspection bootstrap does
  not cross-compile — so `nftables` + `iptables` +
  `specs/usr/sbin/hugmesh-firewall-reconcile` carry the host firewall there, and
  `requested-atoms-resolvable.sh` fails the build if either half of that decision
  is quietly reverted.
- **✅ Unified Spring baseline** — the baked GitOps payload now targets **Spring
  Boot 4.0.7 / Spring Cloud 2025.1.2** on Java 25, with the shared Maven artifacts
  **`hugmesh-parent`** (metapom, **2.8.0**), **`hugmesh-commons`** (shared
  security/tenancy, `net.hugmesh.commons.*`, **2.1.0**),
  **`hugmesh-auth-core`** (shared account/session/MFA/Casdoor-admin infra;
  depends on commons; consumed by **user-bff + admin-bff only** — **two pins,
  by design**: **2.4.2** for user-bff main, **2.5.0** for admin-bff main, since
  the two consumers are on separate release cadences) and
  **`hugmesh-build-config`** (**0.5.0** — the shared PMD/Checkstyle/SpotBugs
  rulesets the parent references). The groupId is `net.hugmesh:*` after the
  rebrand. `federation-api` was migrated onto this baseline. The authoritative
  pins live in [`tests/stack/m2-bootstrap.sh`](tests/stack/m2-bootstrap.sh)
  (SHA-pinned — the org repos carry no git tags); ⚠️ auth-core has drifted four
  times (2.4.0 → 2.4.1 → 2.4.2 → 2.5.0) because a released coordinate was
  re-cut, which is why the pin-drift guard exists and must run after every
  auth-core release.
- **✅ SSO auth model wired into the cluster payload (data plane)** — Casdoor is
  the SSO IdP, reached **only from inside the cluster**. Login is a **native,
  first-party form**: `login-ui` POSTs username/password (and any MFA passcode) to
  **user-bff** `POST /bff/login`; user-bff generates PKCE + state server-side, POSTs
  the credentials to the **internal** Casdoor `/api/login`, exchanges the returned
  code, and holds per-session JWT custody/refresh. The browser only ever holds an
  **OPAQUE `bff_`-prefixed** session — it never sees a Casdoor JWT, the
  `code_verifier`, the `state`, or any Casdoor URL. The gateway is a pure
  Casdoor-JWT OAuth2 resource server: a pre-security exchange filter swaps
  `bff_` → the internal custody JWT so JWT validation + the role gate run
  unchanged. Authorization is **data-driven by the `gateway_route_access`
  Postgres table** (source of truth) via `GatewayRouteAccessFilter` —
  ADMIN/GAME-MASTER bypass within own domain, SUPERADMIN cross-domain. Because there
  is no front-channel redirect, **Casdoor needs no public ingress**; Cloudflare
  fronts only the platform front door in prod. **Login/session/account logic has
  RELOCATED from admin-bff → user-bff** (the shared core lives in
  `hugmesh-auth-core`); account/session **data stays in admin-bff-db**, reached
  by user-bff via admin-bff `/bff/internal` over mTLS + `X-Internal-Token`. The
  generator leg of this relocation — the user-bff Casdoor confidential client with
  the internal redirect-uri, the relocated `/bff/login|register|me|session|provision`
  fe-gateway routes, the permitAll `/bff/login` route-access seed, and retiring the
  dead `/bff/auth/callback` OAuth-redirect route the old browser-driven model used
  — is **on `main` and lit by default**: `APP_BFF_OIDC_ENABLED` /
  `APP_SESSION_COOKIE_ENABLED` / `APP_BFF_EXCHANGE_ENABLED` are all baked `"true"`
  in `specs/cluster/manifests/{user,admin,mod}-bff-api/deployment.yaml`; only the
  Casdoor client secret and the AES custody key remain ESO-secret-gated
  (`optional: true`, populated from Vault before real logins work). Covered
  end-to-end by [`tests/e2e/specs/27-native-login.spec.ts`](tests/e2e/specs/27-native-login.spec.ts),
  which drives the real form and asserts the browser never navigates to a Casdoor
  origin.
- **✅ Casdoor MFA (TOTP + WebAuthn + recovery codes)** — enrollment/challenge live
  in admin-bff via `hugmesh-auth-core`: `APP_CASDOOR_MFA_ENABLED` is baked
  `"true"`, `APP_MFA_FACTOR_KEY` (ESO/Vault) encrypts enrolled TOTP secrets at
  rest, and `APP_MFA_WEBAUTHN_RP_ID`/`_ORIGINS` are branded per-tenant (not left
  on the dev-only `localhost` default); `login-ui`/`admin-ui` ship the
  enroll/challenge/security pages. `mfa_satisfied` is stamped into the opaque
  `bff_` session. **The privileged-MFA floor is also shipped and ships dark** —
  the `mfa_required` column + the `UPDATE` that seeds it on every allow row under
  `/bff/admin/**` + `/bff/superadmin/**`
  ([`specs/cluster/manifests/route-access/initdb/20-schema.sql`](specs/cluster/manifests/route-access/initdb/20-schema.sql)),
  the shared gateway chart's `mfa:` values block rendering `APP_MFA_ENABLED` /
  `APP_MFA_FRESHNESS_WINDOW` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` into every
  gateway pod, both CI gates (`lint:mfa-required-rules`, `lint:gateway-mfa-env`
  with pinned fail-closed `helm` + `REQUIRE_HELM=1`), the compose-stack defaults
  (dev stack `APP_MFA_ENABLED=true`, floor still off) and e2e coverage
  ([`tests/e2e/specs/29-mfa-privileged-floor.spec.ts`](tests/e2e/specs/29-mfa-privileged-floor.spec.ts))
  are all on `main`. On a **cluster** the chart default is `mfa.enabled: false` /
  `enforcePrivilegedFloor: false`, so the seeded rows are inert. What remains is
  the **live-cluster operator flip**, in the order and with the lockout
  preconditions in [`docs/MFA-ROLLOUT.md`](docs/MFA-ROLLOUT.md) — see also
  [`docs/ROUTE-ACCESS.md`](docs/ROUTE-ACCESS.md).
- **✅ SCG-5 route config** — Spring Cloud Gateway 5.0 moved route config from
  `spring.cloud.gateway.routes` to `spring.cloud.gateway.server.webflux.routes`
  (the legacy prefix silently binds nothing). The `hugmesh-gateway` chart
  templates + every generator route file render the corrected namespace; the
  `routes:` lists in `apps/2x-gateway-*.yaml` are chart **values** the chart maps
  onto the new prefix.
- **✅ Multi-tenancy / multi-brand + superadmin** — per-domain CA loop
  (`brands/domains.conf`), per-domain namespace + mTLS isolation, and a real
  code-enforced **superadmin → admin → mod → user** role cascade enforced at the
  gateway. A **domain-registry → brand-repo bridge** (signed-export reconcile
  agent: mTLS `GET /bff/admin/domains/export` → fail-closed **Ed25519** verify →
  synth a `domains.conf` row + CA + brand repo per registered-not-provisioned
  domain) is baked as the **4th** instance of the device-registry / egress-VPN /
  node-storage reconcile triad, and **ships DARK/inert** (optional-service gate,
  placeholder-pubkey crypto-fail-closed, `.domain_registry.enabled=false` default).
  See `specs/usr/sbin/hugmesh-domain-reconcile`,
  `specs/etc/init.d|cron.d/hugmesh-domain-reconcile`, the
  `hugmesh_domain_reconcile` SELinux module, and `provision_domain_registry()`
  in the KEYS engine.
- **✅ Optional services (add/remove)** — **19 slugs** in
  [`specs/cluster/optional-services.yaml`](specs/cluster/optional-services.yaml):
  akkoma / tuwunel / phpBB / games / owncast / LocalTube (`tube`) /
  **character-studio** (VN character-creator + chat remote, default-off;
  registered as a federation module via hugmesh-federation-api's
  `040-register-character-studio-module.xml`)
  / **character-forge** (3D character forge — BFF + DB + federated UI, apps
  `38b`/`39b`/`49c`; likewise registered via hugmesh-federation-api's
  `038`/`039` changesets) / **edge-AI**
  (+ `edge-ai-analysis`, `edge-ai-tts`; GPU inference, OpenAI model API to the
  mesh — [docs/EDGE-AI.md](docs/EDGE-AI.md)) / **coturn** / **meshbridge**
  (Meshtastic LoRa mesh ↔ Matrix bridge, DEFAULT-OFF runtime-only,
  `dependsOn: tuwunel` — [docs/MESHTASTIC-BRIDGE.md](docs/MESHTASTIC-BRIDGE.md)) /
  and the non-user-level node slugs **egress-vpn** / **tor** /
  **workloadConsole** / **anubis** / **headwind** / **attestation-server**. The UI
  greys out when a service is absent, games defaults to `games.<domain>`.
  Build-time prune ships; the **🚧 live ApplicationSet cut-over is pending**.
- **✅ A/V relay via coturn (TURN/STUN) — ships dark** — the `coturn` slug is a
  DEFAULT-OFF optional service running RFC-5766 REST long-term-credential mode
  against a single ESO/Vault-sourced secret shared with tuwunel (which mints the
  time-limited credential on `GET /_matrix/client/v3/voip/turnServer`). A default
  build deploys no coturn pod and clients keep `iceServers: []`. Enabling the slug
  gives an in-cluster `ClusterIP` relay; **public reachability is a separate,
  operator-deferred opt-in overlay** (`manifests/coturn-public`: `hostNetwork`
  relay pod, the `coturn-public-config` public-IP/URI knobs, a
  `/etc/hugmesh/coturn-public` firewall marker, an unproxied A/AAAA record, and a
  public cert for non-fleet clients). ⚠️ **No SFU exists** — coturn is a 1:1/mesh
  relay only; scalable group calls (MatrixRTC / Element Call / LiveKit) are
  genuinely not built. See [`docs/COTURN.md`](docs/COTURN.md).
- **✅ Encrypted versioned backups — ships dark** — Velero server + node-agent
  (Kopia filesystem/PV backups) as `apps/55-velero.yaml`, and the
  BackupStorageLocation + ESO-sourced object-store credentials + least-privilege
  RBAC + status-sweep CronJob as `apps/56-velero-config.yaml`. Per-domain +
  superadmin, step-up gated in the admin-bff `cloudbackup` package
  (`BackupStepUpGate` / `BackupAdminController` / `BackupService`);
  **two independent OFFs** keep it dark — both Applications are
  NON-automated (manual superadmin sync) and the admin-bff effector stays on the
  `NoopBackupEffector` until `app.backups.effector.enabled=true`, so a created
  `backup_set` sits at `pending` and emits no Velero CR. Kopia repository
  passwords are provisioned, not upstream defaults. See
  [`docs/CLOUD-BACKUPS.md`](docs/CLOUD-BACKUPS.md).
- **✅ Egress-VPN drop-in** — admin-supplied WireGuard/OpenVPN `.conf` for node
  public egress with split-tunnel keeping the tailnet direct
  (`specs/usr/sbin/hugmesh-egress-vpn`, the `egress-vpn` node slug, its
  secret-projector delivery app `13e`). Default-off per node. See
  [`docs/EGRESS-VPN.md`](docs/EGRESS-VPN.md).
- **✅ Per-node attached storage** — attach + register extra storage to a node,
  node-pinned local PV / local-path (FDE), capacity-aware scheduling and graceful
  degrade (`apps/13b-node-storage.yaml` + the
  `specs/usr/sbin/hugmesh-node-storage-reconcile` agent, now baked and enabled by
  every builder). See [`docs/NODE-STORAGE.md`](docs/NODE-STORAGE.md).
- **✅ Desktop app governance — ships dark** — per-license SSO-enforced sudo, an
  admin-curated Plasma Discover store (default-NONE, domain-locked Flatpak/OCI),
  user install-requests and admin remote-install over the device-SSH-license
  transport. The client side is `specs/etc/hugmesh/desktop-governance/` (polkit
  rule, the root claim→group `desktop-sudo-mapper` + its 60 s cron,
  Discover/Flatpak wiring, autostart SSO deposit scripts); the server side is a
  full controller set in `hugmesh-admin-bff-api`. Dark behind
  `app.desktop.registry.enabled=false` / `app.desktop.remote-install.enabled=false`.
  ⚠️ **Honest gap:** the SSO token **producer** (FD-07 increment 2) is now code
  (`hugmesh-sso-token`, an RFC 8628 device-flow client) and unit-tested against
  the real deposit and mapper, but it has never run against a live Casdoor or on
  an image, so the sudo leg stays inert until the flags flip on a governed image. (The original SSSD `id_provider = oidc` design
  was retracted — that syntax exists in no released SSSD.) See
  [`docs/CLIENT-IMAGES.md`](docs/CLIENT-IMAGES.md) §7.
- **✅ Workload Console — ships dark (the WHOLE console, not just an RBAC
  backstop)** — the pod-management + live-log + exec + port-forward surface exists
  end to end: the `/bff/{admin,superadmin}/workloads/**` module in the
  always-present admin-bff, the **hidden-tier federated admin-ui remote** the host
  loads only when the grant guard passes, and this repo's `workloadConsole` slug
  (the two-SA least-privilege RBAC app `apps/14-workload-console-rbac.yaml`, the
  superadmin cluster-read SA/ClusterRole, the deploy-provenance Kyverno policy,
  the admin-bff deployment overlay that lights `WORKLOAD_CONSOLE_ENABLED` +
  `WORKLOAD_CONSOLE_K8S_ENABLED` and mounts both SA tokens, and the two
  route-access rows). **Three independent OFFs:** the generator slug (default-off,
  and deselected the admin-bff renders byte-identical), the k8s seam (absent token
  → the fail-closed `NoopWorkloadClient`, 503 on every call), and the runtime
  `workload_console_config` DB master flag plus a per-admin TTL'd grant. Exec is
  restricted to a read-only first-token allowlist, port-forward to a curated
  app-tier triple list, and namespaces to an allowlist that mirrors the RBAC
  bindings. See [`docs/OPTIONAL-SERVICES.md`](docs/OPTIONAL-SERVICES.md) §7.2.
  **For "how do I see stats / which versions are running?"** — the four gates
  counted separately, the exact order to open them, and the missing aggregate
  version surface — see
  [`docs/WORKLOAD-CONSOLE-STATS-AND-VERSIONS.md`](docs/WORKLOAD-CONSOLE-STATS-AND-VERSIONS.md),
  and read your own posture with `scripts/workload-console-posture.sh`.
- **✅ Games App-Store control plane**, **✅ Device-license registry** (per-node
  sshd obeys the signed export), **✅ Superadmin Service Catalog** (data layer +
  tailnet superadmin-gateway + Kaniko builder, ships dark), **✅ Pen-test CI**
  (OWASP ZAP + Dependency-Check + nuclei + k6 as a **GitLab** pipeline stage, not
  a deployed CronJob).
- **✅ Binhost auto-update — ships dark (default-off, superadmin opt-in)** —
  `provision_update()` bakes the poller cron on every target as plumbing; the
  **absence** of a policy means auto-update is OFF (fail-safe to off, never to a
  pull). A superadmin opts a fleet in via the live `devops/hugmesh-update-policy`
  ConfigMap (`enabled` / `cadence` / `window` / `reboot` / `staging`); changed
  packages pull from the node's `PORTAGE_BINHOST` subtree and kured drains +
  reboots one node at a time. See [`docs/DEVOPS.md`](docs/DEVOPS.md).
- **✅ Data-access standard** — the Spring services use **Spring Data R2DBC
  reactive repositories** (no raw SQL strings / inline `@Query`).
- **✅ Wiki service (hugmesh-wiki-bff-api + hugmesh-wiki-ui)** — fully deployed; manifests in `specs/cluster/manifests/wiki-bff-api/` + `manifests/wiki-ui/`, ArgoCD apps `34a-wiki-bff-db`, `34b-wiki-bff-api`, `49a-wiki-ui`; fe-gateway routes `/bff/wiki/**` (#173, #176).
- **✅ MDM phone MDM (fourth onboarding form)** — `scripts/phone-wizard.sh`
  flashes verified GrapheneOS onto a USB-connected Pixel (or onboards an
  existing GrapheneOS/stock-Android phone with no reflash), attests it to a
  self-hosted **GrapheneOS AttestationServer**, device-owner-enrolls it into
  **Headwind MDM** (both merged, default-off, tailnet-only cluster
  optional-services), joins it to the mesh tailnet, and escrows an enterprise
  profile. Real pre-deploy gaps remain (Casdoor SSO for Headwind, an
  automated attestation-verdict API, `make phone-mdm-enroll`/`phone-attest`
  targets) — see [`docs/MDM.md`](docs/MDM.md)
  "Deferred".
- **✅ Orange Pi platform family (EXPERIMENTAL)** — six boards across three SoC
  vendors, each with its own `specs-<platform>/` tree, builder and `make` target:
  **Orange Pi 5 / 5 Plus** (Rockchip RK3588/RK3588S, light desktop, `--board`
  axis), **Orange Pi 4 LTS** (Rockchip RK3399, light desktop, single-board,
  blob-free boot chain), and the headless appliance line **Orange Pi Zero 2**
  (Allwinner H616), **Zero 2W** + **Zero 3** (H618 — no mainline display-engine
  driver, so headless is a hard constraint, not a choice) and **Orange Pi 3 LTS**
  (H6, headless by scope). Each is `live | installer | both` and carries the
  standard mesh/KEYS provisioning. ⚠️ **Hardware validation pending on every one
  of them** — no physical Orange Pi has booted an image from this repo; the
  board facts are researched against upstream Linux/U-Boot/ATF source, and the
  ports are `--print-plan`-clean and matrix-gated, not hardware-proven. See
  [`docs/BUILD-MATRIX.md`](docs/BUILD-MATRIX.md) and each `specs-orangepi*/README.md`.
- **✅ Shared per-arch build assets (binpkg pools, distfiles, stage3 seed)** —
  one shared asset root (`<WORK_DIR>/shared` by default, overridable with
  `--shared-assets DIR` / `HUGMESH_SHARED_ASSETS`, opt-out with
  `--no-shared-assets`) holding the stage3 seed cache, fleet-wide read-only
  distfiles and **per-BOARD** binpkg pools, resolved in one place
  (`scripts/_shared-assets-lib.sh`). Closes the produce→consume loop the cross
  builders never had (`FEATURES=buildpkg` always produced; four of five never
  consumed), adds a compile-once `--packages-only` prebuild phase (make:
  `prebuild-binaries`; also on the ncurses menu), and — load-bearing — a **pool
  fingerprint guard**, because `--binpkg-respect-use=y` compares USE only and
  every aarch64 board shares a CHOST while differing in `-mcpu` (the SIGILL
  class portage cannot catch). ⚠️ The mechanism + guard are shipped; the
  **compile-once speedup itself is still owed a real cross-build to prove**. See
  [`docs/SHARED-BINPKG.md`](docs/SHARED-BINPKG.md).
- **✅ mesh-bff platform wiring** — the LoRa/Meshtastic BFF is a first-class
  cluster service: `apps/34c-mesh-bff-db.yaml` + `apps/34d-mesh-bff-api.yaml`,
  manifests, the fe-gateway `/bff/mesh/**` route behind a `ROLE_MESH` floor (with
  an explicit DENY row on `/bff/mesh/internal/**`, which is SERVICE-only
  bridge-sync ingest), the Casdoor role, ESO secrets and PKI wiring. Owns the
  `mesh_node_directory` / `mesh_room` tables; `meshbridge` and matrix-ui are its
  producers, the `hugmesh-user-mesh-ui` remote its future consumer.
- **✅ In-cluster Kaniko image-builder (ALWAYS-ON)** — `apps/60-image-builder.yaml`
  moved out of `apps-optional/` into the app-of-apps' recursed `apps/` tree, so
  ArgoCD now always syncs the `hugmesh-image-builds` namespace (PSS `restricted`)
  + its default-deny-ingress NetworkPolicy — **and nothing else**: the per-build
  Kaniko Job stays a template that is deliberately absent from the kustomization,
  so no workload runs until the GitLab `build:images` job (or another driver)
  dispatches one. Gated by `lint:image-builder-always-on`. ⚠️ **Live validation of
  an actual in-cluster build is still pending** a kernel-fixed x86 image. The
  service-catalog Kaniko builder (`apps/54`) remains the separate per-catalog path.
- **✅ Repo-templating archetypes + runnable federation examples** — six
  archetypes under [`templates/archetypes/`](templates/archetypes/)
  (`spring-bff`, `angular-mfe`, `angular-host`, `remote-fragment`, `gateway`,
  `generator`), four of them with a runnable `_skeleton/` example codebase that
  renders when the Tier-2 base repo is unpullable (two-tier fallback), so a whole
  host-shell + remote + API trio can be instantiated for a brand with no base
  clone. See [`docs/MESH-TEMPLATING.md`](docs/MESH-TEMPLATING.md) (render engine +
  guardrails) and [`docs/FEDERATION-EXAMPLES.md`](docs/FEDERATION-EXAMPLES.md)
  (the runtime host↔remote walkthrough).
- **🚧 Kind SSO e2e harness** — `KIND_PROFILE=sso` plus `make kind-images` /
  `kind-up` / `kind-doctor` / `kind-e2e` / `kind-down` stand up a real kind cluster and drive the
  native-login path against it. **Not yet proven end to end** — see
  [Roadmap](#roadmap) and
  [`docs/KIND-SSO-E2E-FINDINGS.md`](docs/KIND-SSO-E2E-FINDINGS.md).
- **🚧 Cloud deploy (Studio/ncurses/`make deploy-*` side-flow)** — publish an
  already-built, cloud-packaged x86 image to AWS/Azure/OpenShift/any-qcow2 host
  via offline-rendered plans (x86-only, no real-cloud CI verification) — see
  [`docs/CLOUD-DEPLOY.md`](docs/CLOUD-DEPLOY.md).

> The auth model is documented in depth in [`docs/SECURITY.md`](docs/SECURITY.md)
> and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); the application-side login
> relocation + OIDC token-handler live in `hugmesh-user-bff-api`,
> `hugmesh-admin-bff-api`, `hugmesh-auth-core` and the `hugmesh-gateway`
> repos. A mesh node can validate tokens against the built-in **Casdoor** (the
> default) or an external OIDC provider (Azure Entra ID / AWS Cognito / generic
> OIDC) — see [`docs/IDENTITY-PROVIDERS.md`](docs/IDENTITY-PROVIDERS.md) for the
> `--idp` flags, the wizard/ncurses pickers, and the honest limits of external
> mode.

## Roadmap

_What is genuinely NOT done. Everything that ships dark by design has moved up
into [Current State](#current-state) — a default-off flag is a posture, not an
unfinished feature. See also the Roadmap section of
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)._

_Re-audited against the tree and the 2026-08-14 build/boot artifacts. Each bullet
carries the evidence for its own state. Items whose remaining step is only
provable on a running cluster are marked **(needs a live cluster)** — this
workstation has the compose mesh up but no kind cluster (`kind get clusters` →
none), and compose green is not evidence for the cluster._

- **🚧 SSO kind-cluster e2e — harness shipped, payload blockers 1–16 and the
  in-cluster signing-key fix merged, the live proof not run.** The `KIND_PROFILE=sso` harness +
  `make kind-images|kind-up|kind-doctor|kind-e2e|kind-down` are on `main`. The
  first real run (2026-08-05) hit 16 fresh-cluster payload blockers because the
  GitOps payload had never been run end to end; every one of 1–16 is now fixed
  on `main` (item 1 for kind only, item 16 in the admin-bff source) and re-measured
  on 2026-10-14 against the tree and the offline guards, with commit evidence per
  item in
  [`docs/KIND-SSO-E2E-FINDINGS.md`](docs/KIND-SSO-E2E-FINDINGS.md#re-measured-2026-10-14).
  The 2026-08-06 live run passed specs `01-frontpage` and `27-native-login`, but
  spec 27 only proves the cookie is minted. The `GET /bff/session` 500 on kind
  (the BFF manifests gave the signing-key fetch a public host that does not
  resolve in-cluster) is fixed on `main`: pull requests #709 and #736 merged on
  2026-10-14 and #693 is closed. The BFF manifests now set an in-cluster
  `CASDOOR_JWKS_URI`
  (e.g. [`admin-bff-api/deployment.yaml`](specs/cluster/manifests/admin-bff-api/deployment.yaml)),
  pinned offline by
  [`tests/scripts/test-bff-jwks-in-cluster.sh`](tests/scripts/test-bff-jwks-in-cluster.sh).
  **Open:** that guard reads manifests, not a cluster, so the fix has no live
  proof; the kind lane still side-loads every image so the Harbor pull path is
  unexercised (finding 17); and findings 20, 25 and 26. No kind run is recorded
  after the 2026-10-07 rebuild. Compose green is **not** evidence for the cluster, and
  `make kind-up` is the prerequisite for this and for every **(needs a live
  cluster)** item below.
- **🔭 MFA privileged-floor — the live operator flip. (needs a live cluster)**
  Seeds, gateway env wiring, the `gateway_route_access.mfa_required` column and
  its fail-closed enforcement, the per-feature step-up legs (SSH key issuance,
  phone-fleet `FLEET_ADMIN`, superadmin lockout with `SUPERADMIN` **not** exempt),
  CI gates, e2e and runbook all shipped and the route-access rows were verified
  against the running compose mesh (see [Current State](#current-state)); what is
  left is not code. On a real cluster an operator must verify every privileged
  principal can produce a fresh `mfa_satisfied` stamp, then flip `mfa.enabled` →
  `true`, then (separately — `enforce-privileged-floor` is **not** a sub-flag of
  `enabled`) `enforcePrivilegedFloor` → `true`, moving the posture-gate
  expectations in lockstep (three suites for the first flip, two for the second —
  measured, listed in the runbook's §3 steps 6-7). Order, lockout preconditions and
  the exact operator commands:
  [`docs/MFA-ROLLOUT.md`](docs/MFA-ROLLOUT.md) §3 and §9.
- **🚧 SELinux — both acknowledged load defects are FIXED; enforcing now waits
  on an AVC workout that has not run yet.** Updated 2026-08-19; this section
  previously acknowledged that the modules bake and the loader is wired "but
  nothing actually loads". Both root causes are closed. **The silent load
  failure (fixed, PR #68):** the manifest-driven loader ran one batched
  `semodule -i … 2>/dev/null || warn`, so all four 2026-08-14 QEMU runs shipped
  green ("33 passed, 0 failed") while every node kept base policy only.
  `provision.sh` now captures `semodule`'s stderr into the provision log,
  retries per module on batch failure (per-module stderr too), and derives
  per-module verdicts from the store (`semodule -l`, not exit codes) into
  `/var/lib/keys-provision/selinux-modules.status`; any manifest module that
  ends up not loaded records the `/var/lib/keys-provision/selinux-load-failed`
  marker, and the enforce-gate refuses to flip while it stands.
  `tests/qemu/assertions.sh` no longer stops at `getenforce`: it asserts every
  name in `/usr/share/hugmesh/selinux-modules.list` appears in the store, the
  status file is clean, the marker is down, and the mode matches the *expected*
  mode — and it harvests AVCs into every `assertions.log`. **The x86
  profile-binding no-op (fixed, PR #44):** `build-x86-host-stage4.sh` *copied*
  `specs-x86/portage/profile/parent` into `/etc/portage/profile/`, a placement
  portage silently ignores, so every x86 image built against plain `hardened`
  and shipped SELinux-inert userland (no policy loader in PID 1,
  selinux-unaware pam/sudo/dbus) while the summary banner claimed
  `hardened/selinux`. The builder now derives an absolute `make.profile`
  symlink from the spec's `profile/parent` — the pattern the ARM builders had
  all along — gated by `tests/requested-atoms-resolvable.sh` section E, and
  confirmed live: the first post-fix x86 image completed with
  `Profile: default/linux/amd64/23.0/hardened/selinux`. (Two earlier seams stay
  closed: `provision_selinux()` clears `/.autorelabel` after its own successful
  relabel so `check_relabel_clean()` can pass, and first boot still never fails
  outright — degrade loudly, never brick.) **What honestly remains** is the
  issue #45 roadmap: the AVC workout harness shipped with PR #68
  (`make avc-workout` boots an image behind a qcow2 overlay, drives the
  workloads the nine `specs/selinux/*.te` modules confine, and groups denials
  by owning `.te` file) but has **not yet been run** against the rebuilt
  images; until it has, the `INFERRED-WIDE` rules in `specs/selinux/*.te` stay
  unnarrowed; and the enforce-gate flip (`HUGMESH_SELINUX_ENFORCE_GATE=1`)
  stays pending until an **enforcing** workout pass comes back AVC-clean —
  nodes still boot **PERMISSIVE** with the gate inert.
- **🔭 bpf-LSM enforcement beyond a registered hook layer.** The LSM stack each
  image advertises is now the one it runs — `yama` and `bpf` were named in
  `CONFIG_LSM`, the cmdline, the generated `grub.cfg` and the signed UKI while the
  kernel silently initialized only `lockdown,capability,selinux`; x86 + rpi5 now
  build `CONFIG_SECURITY_YAMA` + `CONFIG_BPF_LSM`, the 8 ARM boards dropped the
  `bpf` name they never built, and `tests/scripts/test-lsm-posture-honesty.sh`
  fails the build if the two ever diverge again. **Kernel lockdown is now a
  fleet posture:** all 10 boards build `CONFIG_SECURITY_LOCKDOWN_LSM` (+ `_EARLY`),
  list `lockdown` first in `CONFIG_LSM`/`lsm=` and pass `lockdown=integrity`; the
  lint pins that for every board, not only agreement between fragment and cmdline.
  **bpf-LSM attach prerequisites (x86 + rpi5):** attaching a `BPF_PROG_TYPE_LSM`
  program needs BTF, so both fragments now carry the BTF block
  (`CONFIG_DEBUG_INFO_BTF`, `_BTF_MODULES`, the DWARF choice) and `dev-util/pahole`
  is provided where each kernel is linked (x86: package list plus the chroot top-up;
  rpi5: `Dockerfile.build`, since that kernel is cross-linked on the builder host).
  Both builders fail the build if `olddefconfig` drops BTF,
  `tests/scripts/test-btf-pahole-pairing.sh` pins the pairing, and
  `tests/scripts/test-btf-kconfig-resolve.sh <kernel-tree>` shows the x86 symbols
  survive a real Kconfig resolve. BTF and struct layout randomisation are mutually
  exclusive in Kconfig (`DEBUG_INFO_BTF` depends on it being off); it is off today.
  What remains: a **booted-image proof** that a bpf-LSM program really attaches (the
  build proves the kernel config, not a boot, and the rpi5 resolve is only enforced by
  its builder guard on the real tree), and the ARM boards, which also need
  `CONFIG_BPF_LSM` plus its deps before `bpf` may return to their `lsm=`. The ARM
  lockdown change is **proven only by a Kconfig resolve and the
  offline lint, not by a boot:** an image build plus the in-guest
  `/sys/kernel/security/lockdown` assertion on real boards (or `launch-arm.sh`)
  is still owed.
- **🔭 Group-call SFU.** coturn gives 1:1/mesh TURN relay only. Scalable group
  calls (MatrixRTC / Element Call / LiveKit) do not exist in any form.
- **🔭 Desktop-governance go-live — three dark flags, zero dial rows, no image.**
  All three governance flags still default off (`DEVICE_TERMINAL_ENABLED`,
  `DEVICE_TERMINAL_DIAL_ENABLED`, `DESKTOP_REMOTE_INSTALL_ENABLED`), but they are
  no longer invisible: each has an admin-BFF `application.yml` entry
  (`app.desktop.remote-install.enabled` previously existed only as a
  `matchIfMissing = true` bean condition), is declared `"false"` in the cluster
  Deployment and read through `${NAME:-false}` in compose, and
  `tests/desktop-governance/test-governance-flags-visible.sh` pins that. What
  remains is not a flag flip: flipping the dial flag needs a mandatory security
  re-review **and** `device_ssh_dial` rows (zero on the mesh audited 2026-08; the
  pinned channel factory refuses without an ACTIVE row carrying a matching
  `host_key_fp`, TOFU forbidden), **and** the per-device dial-key Secrets mounted
  into the BFF pod, which no manifest does today. No laptop / chromebook /
  desktop image has ever been built (the default `X86_ROLE_LIST` is `pki backend
  frontend backend-gpu`, and 28 build sessions contain no such artifact), so the
  desktop boot-verify (Qt6/KF6 Discover pull, the `hugmesh-desktop` PKCE client,
  the desktop-sudo claim → polkit path) has never run. Preconditions in full:
  [`docs/CLIENT-IMAGES.md`](docs/CLIENT-IMAGES.md) §7 "Go-live preconditions".
- **🚧 Desktop-governance SSO token producer** (FD-07 increment 2) — the producer
  is written and unit-tested (`specs/etc/hugmesh/desktop-governance/sso/`), but
  unproven against a live Casdoor device endpoint and on a desktop image; the
  lightdm-greeter / password-grant PAM login is not built.
- **🔭 Notifications external channels** — Matrix DM + Akkoma feed + phpBB +
  email adapters on top of the shipped in-app MVP + SSE push.
- **🚧 Live ApplicationSet cut-over for optional services** — the build-time
  prune ships; the hardcoded `30-*/50-*` Applications still own the workloads.
- **🔭 Headscale ACL — the BFF push leg is dark, and the fleet is still file-mode.**
  The write seam landed (`HeadscalePolicyClient`, `GET`/`PUT /api/v1/policy`, real
  impl + Noop default, leader-gated reconciler) and stays dark behind
  `app.registry.headscale-acl.enabled=false`. Decision 101 = B made the BFF the only
  policy writer, which needs headscale in `policy.mode: database`; the fleet as built
  still runs `mode: file` with the node renderer writing, tracked in
  hugmesh-generator#634 (switch the mode, seed the stored policy so the tailnet does
  not fall to allow-all, retire the node-side writer; needs a live control node to
  confirm). Until then **nobody may flip `enabled`**. The BFF now refuses to wire the
  push client unless it declares `policy-mode: database`
  (`HeadscaleAclConfig.requireDbPolicyMode`, hugmesh-admin-bff-api), but headscale's
  API does not report its mode, so the guard can only check the declaration.
  The `gen-headscale-policy.sh` apply leg now captures the `policy set` refusal,
  restarts headscale to load the rewritten file (as `provision.sh` does since
  `e1743555`), waits for it to answer before forcing tags, and retries an apply that
  failed. `tests/device-registry/test-layer-a-headscale-acl.sh` runs against the
  `net/hugmesh` BFF tree; its two policy-mode checks stay red against a `database` BFF
  until #634 lands, by design.
- **🔭 Live in-cluster image build. (needs a live cluster)** The Kaniko manifests,
  the namespace + NetworkPolicy, the ESO wiring, the always-on ArgoCD Application
  (out of `apps-optional/`) and the `ROLE_IMAGE_BUILDER` seed + gateway route row
  all landed; the pipeline is correct-by-construction and lint-gated but has never
  run a real build, blocked behind bringing a cluster up. `APPSTORE_EFFECTOR_ENABLED`
  and `APPSTORE_FEDERATION_ENABLED` are now **`true`** in the admin-BFF deployment
  (the ArgoCD and federation seams are the real clients, not the Noop ones), but
  neither leg can send its bearer token yet. Both tokens now have a source
  (`external-secrets/appstore-effector-externalsecrets.yaml` ->
  Secret `appstore-effector-tokens`, read by the deployment as `optional: true`
  secretKeyRefs), but the VALUES are operator-seeded in Vault
  (`secret/<brand>/appstore-effector-tokens`: the ArgoCD token is minted by ArgoCD,
  the federation token is a Casdoor superadmin JWT) and until then the ExternalSecret
  reports SecretSyncedError by design. Neither leg gets as far as a 401 today: both
  fail at the TLS handshake (admin-bff-api #62, #82), so the token is the second
  wall. `APPSTORE_BUILDER_ENABLED` is deliberately still **`false`**. The push
  credential the Kaniko build pod mounts is now created: Secret
  `service-catalog-registry-credentials` (Opaque, key `config.json`, the name and key
  the template `KanikoBuildLauncher` loads from the admin-BFF classpath asks for)
  in **`hugmesh-service-catalog-builds`**, and this repo's own template carries the
  same name and key. The builder stays off because that credential is not the only
  wall: the runtime template names a `serviceAccountName: service-catalog-builder`
  that no manifest creates, its pod spec cannot pass the namespace's `restricted`
  PodSecurity level, and no Role lets the admin-BFF ServiceAccount create Jobs there
  (all three live in the admin-BFF repo or its RBAC; see
  `manifests/service-catalog-builder/README.md`). The mount is NOT `optional`, so a
  missing Secret leaves the build pod wedged in `ContainerCreating` for 1800s rather
  than failing, and a pod can only mount a Secret from its own namespace, so copying
  `external-secrets/image-builder-externalsecrets.yaml` and leaving its
  `namespace: hugmesh-image-builds` in place reproduces the wedge with every name and
  key correct. `tests/scripts/test-appstore-effector-flags.sh` derives the contract from
  both templates, requires them to agree and the Secret to exist in that namespace from
  a manifest the kustomization actually applies (flag false or true), requires both
  token refs to be optional refs to a Secret created in the admin-BFF's namespace, and
  turns RED on the ServiceAccount / PodSecurity walls if the builder flag is flipped.
  Nothing here has run a build. `CASDOOR_ADMIN_ENABLED`
  is still absent from the deployment (the per-service role leg stays skipped).
- **🔭 DB-hardening flips. (needs a live cluster)** Merged dark, awaiting an
  operator: PG in-cluster TLS is implemented but `PG_TLS_ENABLED` is `"false"` on
  all 9 DB deployments (flip per DB only after each `<db>-mtls` ESO Secret
  materializes); Cassandra **auth already ships ON** — only TLS stage 2 is open;
  and the tier-egress default-deny NetworkPolicies are manual-sync with an overlay
  whose `resources: []` renders **zero objects** by design, needing per-namespace
  staged enablement with the devops namespace last (ArgoCD self-wedge risk).
- **🔭 Real cross-build proof for the shared binpkg pools** — the mechanism and
  the fingerprint guard are shipped; the compile-once speedup is unmeasured.

## Platform capabilities

Beyond the build/keys/DNS story below, the GitOps payload this repo bakes now
ships a full multi-tenant platform. State key: **✅ shipped** (on `main`) ·
**🚧 in-flight** · **🔭 planned**.

- **✅ Multi-tenancy / multi-brand + superadmin** — per-domain CA loop
  (`brands/domains.conf`), per-domain namespace + mTLS isolation, and a real
  code-enforced **superadmin → admin → mod → user** role cascade enforced at the
  gateway. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/SECURITY.md`](docs/SECURITY.md).
- **✅ Optional services (add/remove)** — 19 slugs: akkoma / tuwunel / phpBB /
  games / owncast / tube / character-studio / character-forge / edge-ai (+
  edge-ai-analysis / edge-ai-tts) (+ egress-vpn / tor / workloadConsole /
  anubis / coturn / meshbridge / headwind / attestation-server); the UI greys
  out when a service is absent, games defaults to
  `games.<domain>`. Build-time prune ships; the **🚧 live ApplicationSet
  cut-over is pending**. See
  [`docs/OPTIONAL-SERVICES.md`](docs/OPTIONAL-SERVICES.md).
- **✅ Managed backing services** — point in-mesh datastores (Postgres, object
  store, Kafka, ClickHouse, SMTP) at a hosted AWS/Azure equivalent per image
  (`--managed-service id=endpoint`); self-hosted stays the byte-identical default.
  [`docs/MANAGED-SERVICES.md`](docs/MANAGED-SERVICES.md).
- **✅ Egress-VPN** — admins drop provider WireGuard/OpenVPN `.conf` for outgoing
  public egress, split-tunnel keeps the tailnet direct. [`docs/EGRESS-VPN.md`](docs/EGRESS-VPN.md).
- **✅ Node storage** — attach + register extra storage to a node, node-pinned
  local PV / local-path (FDE), capacity-aware scheduling. [`docs/NODE-STORAGE.md`](docs/NODE-STORAGE.md).
- **✅ Games App-Store control plane**, **✅ owncast** + **✅ tube** (GPU-dependent
  video), **✅ notifications in-app MVP + SSE real-time push** — notification bell (60 s polling) + `SseNotificationBus` per-user multicast stream (`GET /bff/user/notifications/events`, user-bff PR #72) + `NotificationToastService` bearer-fetch SSE toast (hugmesh.net PR #104) are all shipped. And the **✅ superadmin Service Catalog**
  (data layer + tailnet superadmin-gateway + Kaniko builder, PR #110).
  [`docs/GAMES-APPSTORE.md`](docs/GAMES-APPSTORE.md).
- **✅ Device-license registry** — physical-ownership / domain-residency / SSH
  operate-licenses; per-node sshd obeys the signed export. [`docs/DEVICE-REGISTRY-KEY-ROTATION.md`](docs/DEVICE-REGISTRY-KEY-ROTATION.md).
- **✅ Pen-test CI** — continuous OWASP (ZAP + Dependency-Check + nuclei + k6) as a
  GitLab pipeline stage, not a deployed CronJob. [`docs/PENTEST-SCHEDULES.md`](docs/PENTEST-SCHEDULES.md).
- **✅ Ships-dark platform surfaces** — encrypted versioned backups (Velero +
  Kopia), the **whole** Workload Console (admin-bff module + hidden-tier admin-ui
  remote + two-SA RBAC), desktop app governance, coturn TURN relay, and the
  gateway MFA privileged floor are all on `main` behind documented default-off
  flags. See [Current State](#current-state) for each flag and its caveats.
- **🚧 / 🔭 Roadmap** — the kind-cluster SSO e2e (harness shipped, blockers 1-16 and the in-cluster signing-key fix (#693) merged, the live proof not run),
  SELinux node-policy modules that bake and wire but **fail to load on every
  boot**, the live MFA operator flip, desktop-governance go-live (three dark
  flags, no dial rows, no image ever built), the broken node-side headscale ACL
  reload, the DB-hardening flips, a group-call SFU, the desktop-governance SSO
  token producer (written, unproven on a live IdP or an image), notifications external channels, and the live
  optional-services ApplicationSet cut-over. See
  [Roadmap](#roadmap) and the Roadmap section of
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Images

| Image | Build command | Runs |
|---|---|---|
| **pki** (RPi 5) | `./build-rpi5-stage4.sh --role pki` | k8s control plane, headscale, Casdoor, Cassandra, pki-gateway |
| **backend** (RPi 5) | `./build-rpi5-stage4.sh --role backend` | tuwunel (Matrix) + Akkoma (fediverse), Spring APIs, DBs, be-gateway, LAN wildcard DNS (test) |
| **frontend** (RPi 5) | `./build-rpi5-stage4.sh --role frontend` | hugmesh.net Angular host + login/matrix/mastodon/wiki remotes, fe-gateway |
| **host** (x86_64) | `sudo ./build-x86-host-stage4.sh` | GPU worker: ArgoCD, hugmesh.games, backend capacity |
| **edge-ai** (x86_64 / Jetson) | `./build-x86-host-stage4.sh --role edge-ai` | GPU inference node: serves an OpenAI-compatible model API (Ollama) to the mesh over k8s + tailnet; NVIDIA + CUDA + nvidia-device-plugin. See [docs/EDGE-AI.md](docs/EDGE-AI.md) |
| **Frite light desktop** (Libre Computer, arm64) — *opt-in client* | `make frite` (or `./build-frite-stage4.sh`) | LEAN LXDE desktop on the Amlogic La Frite / Le Potato SBC; joins the tailnet + Casdoor login. LIVE + INSTALLER flavors, `--desktop light\|none` |
| **Jetson Orin edge-AI** (NVIDIA Tegra234, arm64) — **EXPERIMENTAL** | `make jetson` (or `./build-jetson-stage4.sh --role edge-ai\|backend-gpu\|full\|desktop`) | arm64 edge-AI node family on the Jetson Orin Nano/NX: same mesh + KEYS provisioning + shared cluster tree; mainline kernel (NO CUDA yet — the L4T/CUDA flavor is a documented stub). **Hardware validation pending** — see [`specs-jetson/README.md`](specs-jetson/README.md) |
| **Orange Pi family** (6 boards, arm64) — **EXPERIMENTAL** | `make orangepi5` / `orangepi4-lts` / `orangepizero2` / `orangepizero2w` / `orangepizero3` / `orangepi3-lts` (each `-live` / `-installer` too) | Light desktops on Rockchip (**Orange Pi 5 / 5 Plus** RK3588/RK3588S, `--board` axis; **Orange Pi 4 LTS** RK3399, single-board, blob-free boot chain) and headless appliances on Allwinner (**Zero 2** H616; **Zero 2W** + **Zero 3** H618 — headless is forced, no mainline display-engine driver; **3 LTS** H6, headless by scope). Same mesh + KEYS provisioning. **Hardware validation pending on all six** — see [`docs/BUILD-MATRIX.md`](docs/BUILD-MATRIX.md) and each `specs-orangepi*/README.md` |

> The friendlier path is the **Makefile** (`make local` / `make prod` /
> `make build-all`), which dispatches the same builders inside a self-contained
> Docker builder — no host toolchain, no host sudo. See
> [Quick start](#quick-start) and [Build options](#build-options).

> The **Frite light desktop** is an *opt-in client appliance*, not a cluster
> node — it is **not** part of the default fleet. It reuses the arm64 cross path
> and the SAME mesh + KEYS-USB provisioning + hardened key-only SSH as the other
> client images. See [Frite light desktop](#frite-light-desktop-libre-computer-lela-frite).

> **Cloud targets:** `scripts/cloud-package.sh` re-packages a built **x86** raw `.img` as `qcow2` / fixed `VHD` / checksummed raw for KubeVirt, Azure and AWS import — see [`docs/CLOUD-IMAGE-PACKAGING.md`](docs/CLOUD-IMAGE-PACKAGING.md).

## Build ENV (`test`|`prod`) — baked at image creation

Each image is stamped with a **build ENV** at creation time, written to
`/etc/hugmesh/env` in the image and threaded through the whole build
(`--env test|prod` on every builder, `ENV=test|prod` through `make`). The ENV
bakes the right posture into the image — you do **not** flip it at runtime.

| | **`test`** (default) | **`prod`** |
|---|---|---|
| domain | `<brand>.test` (e.g. `hugmesh.test`) | the **real** domain (e.g. `hugmesh.net`) |
| DNS mode | in-cluster **wildcard DNS** (`apps/09-lan-dns.yaml` kept — **only for a `.test` domain**) | public DNS / Cloudflare (`apps/12-cloudflared.yaml` kept) |
| the other DNS app | `12-cloudflared.yaml` **pruned** from the baked tree (and `09-lan-dns.yaml` is **also** pruned if the domain is **not** `.test`, so an `ENV=test` build on a real domain keeps neither edge) | `09-lan-dns.yaml` **pruned** from the baked tree |
| cloudflared / external-DNS / ACME | off | on (go-live edge; creds from the keys USB) |
| TLS | internal cluster CA only (Vault-PKI / self-signed root) | cluster CA **+** ACME/public (ACME is **additive**) |
| OAuth / SMTP | optional / absent → Casdoor **native** login, admin-approval registration | creds **expected** from the keys USB (still optional if absent) |
| build banner | quiet | **LOUD announced** (`BUILDING PROD IMAGE for <domain>`) |

The default is **`test`** (local-first / safe). `prod` is explicit and
announced because it bakes the real public domain. The builders prune the
ENV-irrelevant ArgoCD app from `/var/lib/hugmesh/cluster/apps` so ArgoCD only
ever syncs the right one for the baked ENV.

```bash
make local                                  # ENV=test + brands/local.conf (hugmesh.test) — LAN fleet
make prod                                   # ENV=prod, real domain (announced)
make build-all ENV=test BRAND=acme          # any brand, test
make build-all ENV=prod BRAND=acme DOMAIN=acme.example
./build-x86-host-stage4.sh --env test --config brands/local.conf --role backend-gpu
./scripts/build-all-roles.sh --env prod
```

> Full reference: [`docs/LOCAL-TESTING.md`](docs/LOCAL-TESTING.md).

## LAN testing (no public internet, no Cloudflare)

An `ENV=test` fleet is **fully testable on a LAN before any public address**.
Two pieces make that work with zero internet:

1. **Cluster-served wildcard DNS.** Cluster *nodes* already resolve each other
   (`provision.sh` writes `/etc/hosts`), but LAN *clients* (your browser, the
   Playwright runner) are not on the mesh and have no record for `id.<domain>`,
   `api.<domain>`, `matrix.<domain>`, `mastodon.<domain>` or the apex.
   `apps/09-lan-dns.yaml` deploys a **CoreDNS** resolver (`manifests/lan-dns`)
   that runs `hostNetwork` on the **backend node** (the same node ingress-nginx
   binds `:80/:443` on) and binds host **`:53` (udp+tcp)**, answering every name
   under the brand domain with that node's LAN IP (injected by `bootstrap.sh`).
   Point your **router's DHCP DNS** (fleet-wide) or a single client's resolver
   at the **backend/ingress node `:53`** once, and every LAN device resolves
   `*.<domain>` → the cluster.

   ```bash
   # backend node IP (the one your router forwards 80/443 to):
   kubectl get node -l hugmesh.net/backend=true \
     -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
   # point a client at it, then:
   dig @<BACKEND_IP> id.hugmesh.test +short      # -> the backend node IP
   curl -k https://id.hugmesh.test/              # reaches Casdoor via ingress
   ```

2. **Internal cluster-CA TLS.** All certs chain to the internal cluster CA
   (Vault-PKI / self-signed root) — **no ACME, no public CA, no internet**. This
   is the *same* offline issuer prod uses; prod merely **adds** the public edge.

So `ENV=test` needs **no public internet, no Cloudflare, no OAuth, no SMTP** —
just Casdoor's native login, the internal cluster CA, and the in-cluster
wildcard resolver. See [`docs/LOCAL-TESTING.md`](docs/LOCAL-TESTING.md).

## Rebranding (brand profiles in `brands/`)

Everything is **string-independent**: the default naming is `hugmesh` /
`hugmesh.net`, but you can build images for any brand/domain. A **brand
profile** is a plain shell file the builders `source` (via `--config FILE`, or an
auto-detected `./brand.conf`). Precedence is **built-in defaults < profile < CLI
flags**, so an absent file changes nothing. See [`brands/README.md`](brands/).

Committed profiles live in [`brands/`](brands/):

| File | Contains |
|---|---|
| [`brands/local.conf`](brands/local.conf) | the **LAN `.test` profile** — `hugmesh.test`, `MAIL_PROVIDER=none`, OAuth/Cloudflare off, local-first mesh. Used by `make local`. |
| [`brands/example.conf`](brands/example.conf) | a complete, safe-to-commit example (`example.test`) to copy. |
| `brands/<yourbrand>.conf` | your brand's `BRAND` / `BRAND_TITLE` / `ORG` / `CLUSTER_DOMAIN` / `MAIL_PROVIDER` / mesh (no secrets). |
| `../brand.conf` *(gitignored)* | the same vars **with** real passwords/tokens. |

```bash
cp brands/example.conf brands/acme.conf   # edit BRAND / BRAND_TITLE / ORG / CLUSTER_DOMAIN / MAIL_PROVIDER
make build-all BRAND=acme                  # threads --config brands/acme.conf into every builder
make build-all BRAND=acme DOMAIN=acme.example   # DOMAIN= overrides the profile's CLUSTER_DOMAIN
# or directly, no make:
./build-rpi5-stage4.sh --config brands/acme.conf --role backend
./build-rpi5-stage4.sh --role backend --brand acme --domain acme.example --org Acme-Inc --brand-title "Acme Corp"
```

At build time the baked cluster payload is rewritten — every namespace
(`acme-pki`/`acme-backend`/…), gateway name, ingress host (`matrix.acme.example`),
image org (`acme-inc/…`), title and hostname — from the hugmesh defaults to
your brand. (Internal install paths like `/var/lib/hugmesh` and the
provisioning JSON key are kept as the tool's vendor namespace.) Never put real
secrets in a committed `brands/*.conf`; those go in the gitignored `./brand.conf`
or the environment.

## Frite light desktop (Libre Computer Le/La Frite)

An **opt-in, lean desktop client image** for the Amlogic arm64 **Libre Computer**
SBCs, built by `build-frite-stage4.sh`. It is a *desktop appliance*, **not** a
cluster node — it is **not** in the default fleet. It reuses the same aarch64
cross path as the Pi5 image, and the **same** mesh + KEYS-USB provisioning +
hardened key-only SSH, so a Frite **joins the same Tailscale/headscale tailnet**
and does **Casdoor login** exactly like every other client image (and honors the
device-license SSH posture — no broad SSH access is baked in).

**Light** here means a **lean LXDE-class desktop** (Openbox + LXpanel + PCManFM +
a small browser), explicitly **not** the full Plasma + gaming stage4 — sized for
the low-end SBC.

```bash
make frite                                   # La Frite, BOTH live + installer (default)
make frite FRITE_BOARD=le-potato             # the pricier S905X sibling (has microSD)
make frite-live                              # LIVE image only (boots ephemerally off USB/SD)
make frite-installer                         # INSTALLER image only (writes to onboard eMMC/SD)
FRITE=1 ./scripts/build-all-roles.sh         # ALSO build the Frite alongside the fleet
FRITE_ONLY=1 ./scripts/build-all-roles.sh    # ONLY the Frite
# or directly:
./build-frite-stage4.sh --board la-frite --flavor both
```

**Board variants** (`--board` / `FRITE_BOARD`):

| Board | Board id | SoC | microSD? | LIVE root | INSTALLER target |
|---|---|---|---|---|---|
| `la-frite` (default) | AML-S805X-AC | Amlogic S805X | **no** | **USB** | **eMMC** module |
| `le-potato` | AML-S905X-CC | Amlogic S905X | yes | SD or USB | eMMC or SD |
| `sweet-potato` | AML-S905X-CC-V2 | Amlogic S905X | yes | SD or USB | eMMC or SD |

> **La Frite has NO microSD slot.** Its u-boot lives in **SPI NOR**; the LIVE
> image boots off **USB** and the INSTALLER writes to the **eMMC** module. The
> 512 MB and 1 GB **RAM SKUs are the SAME image** (RAM is auto-detected; the
> 512 MB SKU leans on a zram swap configured at first boot).

**Two flavors** (`--flavor` / `FRITE_FLAVOR`, default `both`): **`live`** boots
and runs ephemerally (squashfs in RAM, no persistence); **`installer`** is a live
medium that *also* carries `install-frite.sh` + the stage4 to write the desktop
to onboard storage.

> **u-boot caveat (honest):** Amlogic GXL u-boot needs Amlogic's **proprietary
> FIP/BL31 blobs** to be flashable — mainline u-boot alone is not. The builder
> does **not** vendor those blobs; pass a prebuilt, signed board image with
> `--uboot-url` (e.g. a [Tow-Boot](https://tow-boot.org) release) or flash u-boot
> separately. See [`docs/RUNNING.md`](docs/RUNNING.md#frite-light-desktop-image)
> for the VERIFIED-vs-NEEDS-HARDWARE matrix.

## OAuth + mail (optional; native login by default)

Both OAuth and mail are **optional and absent by default**. With neither, the
platform falls back to its **native username/password login** (the first-party
`login-ui` form → `POST /bff/login` → user-bff → internal Casdoor credentials) and
**admin-approval** registration (no email verification) — exactly what an
`ENV=test` LAN fleet uses.

> **Where login runs.** Casdoor is the SSO IdP, reached **only internally**.
> `login-ui` renders a **native username/password form** and POSTs it to
> **user-bff** (not admin-bff) `POST /bff/login`; user-bff does the PKCE + internal
> Casdoor `/api/login` + code exchange server-side and holds the per-session JWT,
> handing the browser only an opaque `bff_` session (never a Casdoor JWT or URL).
> The gateway swaps `bff_` → the custody JWT before its JWT/role checks.
> Login/session/account logic is relocating from admin-bff → user-bff (shared in
> `hugmesh-auth-core`); see [Current State](#current-state).

**OAuth federation providers (seeded into Casdoor when creds are present).**
The provider seeding in the Casdoor init jobs is **read-if-present, else
skipped** — an absent client secret no-ops the provider:

- **Systems realm** (`manifests/casdoor/init-job.yaml`): the **Google** OAuth
  provider, seeded from the `casdoor-google` Secret
  (Vault `secret/<brand>/casdoor: google_client_id/google_client_secret`).
- **Games realm** (`manifests/casdoor-games/init-job.yaml`): a **GitHub** OAuth
  provider that creates native games `player`s, seeded from `casdoor-games-github`
  (Vault `casdoor-games: github_client_id/github_client_secret`).

> The games realm is a **separate Casdoor** (org `threewizards`, issuer
> `id.<domain.games>`) from the platform realm (org `hugmesh`); see
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

**Mail (SMTP).** A `MAIL_PROVIDER` brand knob selects the mail posture;
`none` (the `brands/local.conf` default) disables mail entirely, which is the
typical local/test setting — registration stays admin-approval rather than
email-verify. Set it in your `brands/<x>.conf`:

```sh
MAIL_PROVIDER="none"       # none | smtp   (none = no mail; the LAN/test default)
```

**Credentials flow.** OAuth client IDs/secrets, cluster app secrets and the
Cloudflare go-live token are produced by
[`scripts/gen-cluster-secrets.sh`](scripts/gen-cluster-secrets.sh) and delivered
either online via **Vault → External Secrets Operator** or offline via the
**KEYS USB** (`KEYS/vault/secrets.json`, plus `KEYS/cloudflared/tunnel-token` for
the prod edge) — Vault first, USB fallback, all **read-if-present**. See
[`keys-template/vault/README.md`](keys-template/vault/) and
[`keys-template/cloudflared/README.md`](keys-template/cloudflared/).

## Prerequisites (build host)

- **RPi 5 images** (cross-compiled, run with **sudo** — cross-emerge merges into
  the sysroot + writes host caches; fakeroot is not enough): `crossdev` with
  `aarch64-unknown-linux-gnu` built, plus `curl`, `tar`, `file`, `xorrisofs`
  (`dev-libs/libisoburn`). `crossdev --stable --target aarch64-unknown-linux-gnu`.
- **x86_64 host image** (native, **root** required): an amd64 Gentoo host with
  `grub`, `squashfs-tools`, `libisoburn` (for `grub-mkrescue`/`xorriso`).
- **QEMU test**: `app-emulation/qemu` (aarch64 target), `dosfstools`, `e2fsprogs`.

## Quick start

> For a step-by-step walkthrough of the **whole** pipeline (configure → build →
> keys → flash → boot → cluster), with every flag and the per-arch recipes, see
> the operator runbook: **[`docs/RUNNING.md`](docs/RUNNING.md)**.

### The easy path — `make` (Docker builder; no host toolchain, no sudo)

The Makefile is the front door. Its **default** build path runs inside a
self-contained Gentoo builder image (`Dockerfile.build`), so the host needs no
cross-toolchain and no sudo. Build the builder image once (LONG — it compiles
the aarch64 cross-toolchain), then build images:

```bash
make docker-image       # one-time: build the self-contained Gentoo builder image (LONG)

make local              # LAN .test fleet: ENV=test + brands/local.conf (hugmesh.test)
make prod               # PROD fleet: ENV=prod, real domain (announced)

make build-all          # the default fleet (3 Pi + x86 pki/backend/frontend/backend-gpu), ENV defaults to test
make rpi                # all 3 Pi roles        make rpi-frontend     # one Pi role
make x86                # the 4 x86 roles       make x86-backend-gpu       # one x86 role
make omnibus            # opt-in x86 all-in-one node
```

Products land in `./out` (gitignored). Run `make help` for every target. Use
`NATIVE=1` to run the scripts directly on a local Gentoo host instead of Docker.

### The native path — build on Gentoo (copy-paste)

Run the builds as **root** (the cross-emerge merges into the sysroot's package DB
and writes host caches; fakeroot is not enough). Artifacts land in the git-ignored
`./rpi5-stage4-build/` and `./x86-host-build/`.

Every artifact of one build run is **brand- and timestamp-named** so test vs prod
images are distinguishable and runs never clobber each other:

```
<brand>-<arch>-<role>-<env>-<UTC-stamp>.<ext>

# e.g. (test)  hugmesh-rpi5-arm64-frontend-test-20260610T193045Z.img
#      (prod)  hugmesh-x86-amd64-host-prod-20260610T193045Z.img
```

`<arch>` is `rpi5-arm64` or `x86-amd64`; `<env>` is `test` or `prod`; `<UTC-stamp>`
is `date -u +%Y%m%dT%H%M%SZ`, computed once per run so the `.img`, `.iso`,
`.stage4.tar.xz` and `.fs.tar.xz` all share it. The `make flash` / `make qemu`
targets and `flash-disk.sh` autodetect the newest matching image, so you rarely
type the full name.

```bash
# 0. Build-host prerequisites (one-time). RPi5 cross-toolchain + ISO tooling:
sudo emerge -an dev-libs/libisoburn app-arch/tar sys-apps/file net-misc/curl
sudo crossdev --stable --target aarch64-unknown-linux-gnu
#    x86_64 host image also needs:  sys-boot/grub sys-fs/squashfs-tools
#    QEMU integration test also needs:  app-emulation/qemu sys-fs/dosfstools sys-fs/e2fsprogs

# 1. Build the images (--env defaults to test; add --env prod for a go-live image)
sudo ./scripts/build-all-roles.sh -j "$(nproc)"          # all three Pi roles: pki, backend, frontend
sudo ./build-rpi5-stage4.sh --role pki -j "$(nproc)"     # …or just one Pi role
sudo ./build-x86-host-stage4.sh -j "$(nproc)"            # x86_64 GPU host (native amd64 Gentoo)

# 2. Cluster secrets + a per-node KEYS provisioning stick (users, SSH, certs, k8s join, GitOps)
./scripts/gen-cluster-secrets.sh                         # cluster-wide secrets (Vault + USB fallback) — once
./scripts/gen-provision-keys.sh -r pki -o keys-pki       # also: -r backend | -r frontend | -r host
sudo ./scripts/make-keys-usb.sh /dev/sdY keys-pki        # FAT32 stick labelled KEYS (one per node)

# 3. Flash the OS to each node's SD/NVMe (boot a Linux live env, mount the role's ISO)
sudo mount -o loop rpi5-stage4-build/hugmesh-rpi5-arm64-pki-*.iso /mnt/iso
sudo /mnt/iso/install.sh /dev/sdX                        # SD card, or /dev/nvme0n1
sudo umount /mnt/iso
#    x86 host: boot the hugmesh-x86-amd64-*.iso live image, then run  install-x86.sh /dev/sdX  from it.

# 4. Boot each node with its KEYS stick inserted — first boot self-provisions.

# 5. (optional) Integration-test an image under QEMU before flashing (root)
sudo ./tests/qemu/run-qemu-test.sh --role pki
```

## Generate the cluster

Boot the **pki** node first — it is the Kubernetes control plane. If its KEYS
manifest sets `hugmesh.gitops.enabled=true`, `keys-provision` runs `kubeadm init`
and the GitOps bootstrap automatically; otherwise run the bootstrap by hand on the
pki node:

```bash
# On the pki node, after kubeadm init:
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo -E /var/lib/hugmesh/cluster/bootstrap/bootstrap.sh   # installs ArgoCD + the root app-of-apps

# Backend / frontend / x86-host nodes join automatically at first boot (the kubeadm
# join token rides on their KEYS stick) — or run  kubeadm join <pki>:6443 …  manually.

# Watch ArgoCD converge the platform (Calico, Vault+ESO, Casdoor, Cassandra, the three
# gateways behind ingress-nginx, Akkoma, tuwunel, Forgejo, the Spring APIs, the
# frontends, hugmesh.games):
kubectl -n devops get applications
kubectl get pods -A
# ArgoCD admin password:
kubectl -n devops get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

> `bootstrap.sh` also injects the backend node's LAN IP into the resolver
> Corefile (`ENV=test` only) so the in-cluster wildcard DNS answers
> `*.<domain>` → that node. After bootstrap, point your router/clients at the
> backend node `:53` — see [LAN testing](#lan-testing-no-public-internet-no-cloudflare).

## Disk growth on first boot (growable USB)

The `.img` artifacts are built **compact** — only as large as the ext4 root
(`--img-size`, default 9216 MiB on the Pi / 8192 MiB on x86) plus the 512 MiB
boot/ESP partition and alignment. They are **never padded** to the size of the
target USB, so they flash fast and a small image can be written to a large
medium. The root (ext4) partition is the **LAST** partition in the table.

On first boot the `growroot` OpenRC service expands that last partition — and its
filesystem — to fill the medium, then disables itself (a `/var/lib/growroot.done`
marker makes it idempotent and re-run safe; it is strictly non-fatal so a quirk
never blocks boot). Device detection is dynamic (`findmnt` → `/sys/class/block`
→ `lsblk PKNAME`), so the **same image** works on Pi SD/USB (`mmcblk*`, `sda`)
and on x86 SATA/USB/NVMe (`sd*`, `nvme*`) with no hard-coded device name.

**Grow policy — default `fill`, configurable.** "Fill the whole USB, or use as
little of it as needed unless specified":

| value | effect |
|---|---|
| `fill` (default) | expand the root to fill the **whole** USB/SD/NVMe |
| `none` (`--no-grow`) | do not grow — keep the compact flashed layout |
| `<size>` | cap the root filesystem, e.g. `16G`, `12000M`, `50%` (% of device); the rest is left free for a separate data partition |

Set it at **build time** with `--grow <value>` / `--no-grow`, or `GROW_POLICY=`
in `brand.conf`. It is baked to `/etc/growfs.conf` and a copy is dropped on the
FAT `/boot` (Pi) / ESP (x86) as `growfs.conf` so you can **retune a single
flashed medium without a rebuild**. Runtime precedence (first wins):

1. kernel cmdline token `growfs=<value>` (`cmdline.txt` on the Pi, the GRUB line on x86)
2. `growfs.conf` on the boot/ESP partition (`GROW=<value>`)
3. `/etc/growfs.conf` baked from `--grow` / `GROW_POLICY`
4. built-in `fill`

> **Encryption-at-rest note.** The encrypted volumes (LUKS2) are the *attached*
> data partitions provisioned by `keys-provision` (`.storage.devices[]`), which
> are created at `100%` of their device already; the **root** that `growroot`
> expands is plaintext ext4, so the grow never touches LUKS today. `growroot` is
> nonetheless LUKS-aware: if `/` is ever mounted from a `/dev/mapper/*` LUKS
> device it grows the backing partition, runs `cryptsetup resize`, then
> `resize2fs` (partition → crypt container → filesystem). See
> [`docs/ENCRYPTION-AT-REST.md`](docs/ENCRYPTION-AT-REST.md).

## USB KEYS provisioning

At first boot the `keys-provision` service finds the FAT32 `KEYS` partition,
mounts it read-only, and applies (all optional):

- **users** from `users.json` (groups, sudo, SSH keys, SHA-512 password hashes)
- **SSH** host keys + per-user `authorized_keys` (login is key-only)
- **hostname / timezone / Wi-Fi / NetworkManager** profiles
- **certificates** and arbitrary **files** at given paths
- **headscale** (control server) + **tailscale** (client, preauth-key join)
- **Kubernetes** PKI + kubeadm config; stage or run `kubeadm init`/`join`
- **attached storage** — mount M.2/NVMe or USB, relocate containerd/kubelet data
- **backups** — schedule etcd + PostgreSQL dumps to attached storage and/or
  an NFS/CIFS share
- **GitOps** — on the pki control plane, bootstrap ArgoCD + the app-of-apps

If no KEYS stick is present the image still boots and creates a fallback user so
you are never locked out. Full schema + examples: [`keys-template/`](keys-template/).

## Cluster / GitOps

The cluster manifests live in [`specs/cluster/`](specs/cluster/) and are baked
into every image at `/var/lib/hugmesh/cluster`. The pki node installs ArgoCD
and a root app-of-apps; ArgoCD syncs the `hugmesh-gateway` Helm chart (one
release per namespace, fronted by an **ingress-nginx** facade on the backend node),
Casdoor, Cassandra, **Akkoma** (fediverse) + **tuwunel** (Matrix), **Forgejo**
(in-cluster git on pki), the Spring APIs, the Angular host + federated remotes
(login/matrix/mastodon/admin/wiki) and hugmesh.games. In `ENV=test` it also syncs
the in-cluster wildcard-DNS resolver (`apps/09-lan-dns.yaml`); in `ENV=prod` the
cloudflared go-live edge instead. See
[`specs/cluster/README.md`](specs/cluster/README.md).

> **Gateway route config (SCG 5.0).** The `hugmesh-gateway` chart renders its
> `routes:` values into the **`spring.cloud.gateway.server.webflux.routes`**
> namespace required by Spring Cloud Gateway 5.0 (the legacy
> `spring.cloud.gateway.routes` prefix silently binds nothing). Authorization is
> not in the route YAML — it is data-driven by the `gateway_route_access`
> Postgres table (`manifests/route-access/initdb/20-schema.sql`) read by the
> gateway's `GatewayRouteAccessFilter`.

### Vanity subdomains (`<username>.hugmesh.net`)

A user can serve their PUBLIC profile at `https://<username>.hugmesh.net`.
The routing is:

```
*.hugmesh.net  ──►  backend ingress  ──►  fe-gateway
   (wildcard DNS:                                  │  (apps/20-gateway-fe.yaml)
    lan-dns in test,                               │
    Cloudflare wildcard in prod)                   ▼
   Host=*.hugmesh.net route  ──►  federation-api  (direct, no be-gateway)
   (SetPath=/api/federation/vanity,        GET /api/federation/vanity
    Host header preserved)                 resolves the PUBLIC profile fragment
                                           by the first DNS label of the Host
```

Three baked-in pieces make this work:

1. **Wildcard DNS already points `*.hugmesh.net` at the backend ingress** —
   `manifests/lan-dns` answers the whole brand zone (apex + every subdomain) with
   the ingress IP in `ENV=test`; the Cloudflare wildcard does so in `ENV=prod`.
   The reserved service subdomains (`id. api. matrix. mastodon. scale. headscale.`)
   are fronted by the **be-gateway** ingress + cloudflared, not the fe-gateway.

2. **fe-gateway ingress admits the wildcard** — `apps/20-gateway-fe.yaml` adds
   `ingress.extraHosts: ["*.hugmesh.net"]`, so the nginx Ingress accepts the
   vanity hosts and hands them to the gateway.

3. **A `Host=*.hugmesh.net` gateway route, ordered for PRECEDENCE.** Spring
   Cloud Gateway matches routes **first-in-declared-order**, so the route is placed
   **after** the apex/path routes and **before** the `frontend-host` `Path=/**`
   catch-all. The `Host=*.<domain>` predicate matches `alice.<domain>` but **not**
   the apex `<domain>` (the `*` needs ≥1 label), so the apex still falls through to
   `frontend-host`; the reserved hosts never reach this gateway. The route rewrites
   the path to `/api/federation/vanity` (via `SetPath`) and forwards **directly to
   federation-api** (NOT via the be-gateway) with the **Host header preserved**, so
   federation extracts the username from the first DNS label
   (`VanityController.resolveByHost`) and returns the public profile-fragment
   descriptor. Direct (not via be-gateway) because the resolve is a **public read**
   (no JWT — it IS the public profile) and federation-api already `permitAll`s
   `GET /api/federation/vanity/**`; interposing the be-gateway would add an auth
   layer that 401s the anonymous request.

**Precedence summary (first-match wins, top to bottom):** the reserved service
subdomains (`id. api. matrix. mastodon. scale. headscale.`) are claimed by the
**be-gateway** ingress + the cloudflared rules *above* the wildcard, so they never
reach the fe-gateway. The apex `hugmesh.net` is not matched by
`Host=*.<domain>` and falls through to `frontend-host`. Only the remaining
`<username>.<domain>` hosts hit the vanity route. The cloudflared `*.<domain>` rule
(`manifests/cloudflared`) is likewise ordered **after** the reserved hostnames and
**before** the 404 catch-all.

**Honest cross-service deferral (a THIRD repo).** The shared gateway image
(`hugmesh-gateway`) ends its `SecurityConfig` with `anyExchange().authenticated()`
and permits only a hardcoded `PUBLIC_PATHS` allowlist (`/api/auth`,
`/api/registration`, `/api/login`, the login/registration/banned remotes).
`/api/federation/vanity/**` is **not** in it, so the fe-gateway pod would itself
401 the anonymous vanity request before proxying. **To make the public vanity host
reachable, `/api/federation/vanity/**` (or a `Host=*.<domain>` public rule) must be
added to the gateway `PUBLIC_PATHS` in the `hugmesh-gateway` repo** — out of
scope for this generator/federation-api pass and documented as a deferral. The
generator side here (wildcard DNS already in place, fe-gateway ingress wildcard
host, the ordered `Host=*.<domain>` route to federation-api, the cloudflared
wildcard rule) is complete and renders clean (`helm template` /
`kubectl kustomize`).

The PUBLISH path (marking a user's profile fragment `visibility=public` when they
enable vanity in user-bff-api) and the SERVING page (the host shell that renders
the resolved fragment) are documented — including the honest cross-service
deferrals — in the
[hugmesh-federation-api README](https://github.com/hugmesh/hugmesh-federation-api)
("Vanity subdomains" + "Deferred / stubbed").

## Secrets (Vault + USB)

Cluster secrets are generated by
[`scripts/gen-cluster-secrets.sh`](scripts/gen-cluster-secrets.sh) and pushed to
**HashiCorp Vault** (KV v2, mount `secret/`, base path `hugmesh/`, tracking
the brand slug). The **External Secrets Operator** syncs them into k8s via the
ClusterSecretStore **`hugmesh-vault`** (one ExternalSecret per Secret,
refreshed hourly) — the workloads keep their existing `secretKeyRef`s
(`casdoor-google`, `clickhouse-auth`, `uptrace-auth`). The same values are also
written to the KEYS stick at `vault/secrets.json` (with `vault/token` for online
sync) so `keys-provision` can create the Secrets offline — **Vault first, USB
fallback** — if Vault is unreachable. See [`specs/cluster/`](specs/cluster/).

## QEMU integration test

[`tests/qemu/run-qemu-test.sh`](tests/qemu/) boots a built image under
`qemu-system-aarch64 -M virt` with a synthetic FAT32 KEYS disk and asserts that
provisioning worked end-to-end (users, sshd, headscale, the k8s stack, the role
marker). See [`tests/qemu/README.md`](tests/qemu/README.md).

## Integration tests (UI E2E + boot emulation)

Two rootless test suites run on this machine with Docker:

### A. UI end-to-end (Playwright + generated certs)

Brings up a rootless stack — generated TLS certs + runtime values, plus
multi-user **mock** Matrix/Mastodon/BFF servers — serves the built Angular host
over HTTPS, and drives it with Playwright (browsers come from the local
`hugmeshgames-e2e` image, so no browser download). It proves, with
screenshots in `tests/e2e/screenshots/`:

1. front page loads over the **generated certs + values**,
2. an admin (Casdoor admin role) manages the **Gmail + Discord allowlist**,
3. registration is **Google/Discord-only and allowlist-gated** (denied otherwise),
4. **two-stage registration** — Matrix/Mastodon stay locked until registration completes,
5. **five users** fully register and reach both services,
6. users **chat with each other** over Matrix and **post** to Mastodon through our UI.

```bash
# one-shot: build host, gen certs, up stack, run Playwright, screenshot, tear down
./tests/e2e/run-all.sh

# or, against an already-running stack (tests/stack/up.sh):
./tests/e2e/run.sh

# the GHERKIN lane, against any of the three meshes (NOTHING is started for you):
./tests/e2e/run.sh --bdd --env docker      # the compose stack above
./tests/e2e/run.sh --bdd --env kind        # the local devops cluster
./tests/e2e/run.sh --bdd --env qemu        # an emulated device
./tests/e2e/run.sh --print-command --env kind   # the plan as JSON; executes nothing
./tests/e2e/run.sh --evidence              # where this run's screenshots/transcripts went
```

`run.sh` is the single entry point: `make stack-e2e-bdd [BDD_ENV=…] [BDD_TAGS=…]
[BDD_FEATURES=…]` and `make stack-e2e-bdd-evidence` delegate to it, so there is
one way to spell a run rather than several that drift. `tests/e2e/features/README.md`
§4d has the whole flag set; `tests/scripts/test-e2e-cli-lane.sh` is its gate.

> `tests/stack/mock-*.mjs` are fast in-memory test doubles. `tests/stack/up-real.sh`
> brings up real tuwunel + Casdoor + Mastodon (+ the platform Cassandra) from
> `compose.real.yaml` — it preps Mastodon's DB, then `docker compose up -d`
> (tuwunel needs no first-run step at all: it is configured entirely
> declaratively via `TUWUNEL_*` env on its service, so a fresh volume comes
> up registration-enabled). Point the suite at it with `SNAP_BASE_URL=...`
> (and `REAL_MATRIX=1` for the UI). This is **not** full fidelity, though: the
> UI is still served by `tests/stack/up.sh`'s `mock-bff.mjs`, a hand-written
> stand-in for the Spring BFF that never calls Casdoor and has no "real
> Mastodon" mode — only the tuwunel leg becomes real. For the UI to talk to
> the REAL gateway + Spring BFFs + Casdoor OAuth login, use `make stack-up`
> instead (see `docs/LOCAL-STACK.md`). Tear the real-services stack down with
> `tests/stack/down-real.sh`.

### B. First-boot provisioning emulation (one of each node kind)

Runs the **real** `keys-provision` engine inside a container against a generated
KEYS directory (no block device needed) for each role — `pki`, `backend`,
`frontend`, `host` — asserting users/SSH-keys/sudoers/host-keys/hostname/markers:

```bash
./tests/boot/emulate-firstboot.sh                 # all four roles
./tests/boot/emulate-firstboot.sh pki backend     # specific roles
```

> This validates the boot-time provisioning the images run; it does not boot the
> aarch64 kernel (that needs a built stage4 — see the QEMU section, which boots
> the produced Image under `-M virt`).

## Build options

Run `./build-rpi5-stage4.sh --help` (and `./build-x86-host-stage4.sh --help`)
for the full man-style reference. Highlights:

| Flag | Default | Description |
|---|---|---|
| `-r, --role` | `generic` | `pki` \| `backend` \| `frontend` (RPi). Sets hostname, services, GitOps payload. |
| `--env test\|prod` | `test` | **Build ENV, baked into `/etc/hugmesh/env`.** `test` = LAN-only (wildcard DNS kept, cloudflared/ACME pruned, internal CA); `prod` = real public domain (cloudflared/ACME kept, announced banner). See [Build ENV](#build-env-testprod-baked-at-image-creation). |
| `-C, --config FILE` | auto `./brand.conf` | Source a brand profile (e.g. `brands/local.conf`). |
| `--cluster-domain` | `hugmesh.net` | Base domain for gateways / Casdoor. |
| `-w, --work-dir` | `./rpi5-stage4-build` | Git-ignored output directory. |
| `-j, --jobs` | `$(nproc)` | Parallel emerge/make jobs. |
| `--headscale-version` / `--tailscale-version` | pinned | Mesh binary versions. |
| `--skip-mesh` / `--skip-tailscale` | off | Omit mesh VPN / tailscale client. |
| `--skip-kernel` / `--skip-iso` / `--skip-clean` / `--resume` | off | Build phases. |
| `--pcie-gen3` | off | Force PCIe Gen 3 for NVMe (RPi, test your drive). |
| `--print-plan` | off | **Dry run** (all four builders): resolve + validate every flag, print the machine-greppable build plan (`PLAN_KEY=VALUE` lines) and exit 0 — no root, no writes, no network. Invalid role/flag combinations exit non-zero; secrets print as `REDACTED`. The build-matrix harness verifies every cell through it. |

### `make` targets

`make` is the front door over the builders + tooling (run `make help` for the
live list). Common overrides: `ENV=test|prod`, `BRAND=`, `DOMAIN=`,
`HEADSCALE_URL=`, `WORK_DIR=`, `JOBS=`, `ROLE=`, `ARCH=x86|arm64`, `DEV=/dev/sdX`,
`IMG_FLAGS='--no-iso'`, `NATIVE=1`, `CA_CERT=`/`CA_KEY=`.

| Target | What it does |
|---|---|
| `make docker-image` (alias `docker`) | build the self-contained Gentoo builder image (LONG first time). |
| `make menu` | interactive console build menu (`scripts/build-menu.sh`) — pick images with live progress; quit without stopping the build. On NixOS/SteamOS/no-`make` hosts, `scripts/studio-launch.sh --menu` reaches it too (see [`docs/NIXOS-STEAMOS.md`](docs/NIXOS-STEAMOS.md)). |
| `make local` | ENV=test + `brands/local.conf` → the LAN `hugmesh.test` fleet. |
| `make prod` | ENV=prod, real domain (announced; creds from the keys USB). |
| `make build-all` / `make rebuild` | the default fleet (3 Pi + x86 pki/backend/frontend/backend-gpu); `rebuild` wipes first. |
| `make rpi` / `make rpi-<role>` | all 3 Pi roles / one Pi role (`rpi-frontend`). |
| `make x86` / `make x86-<role>` | the 4 x86 roles / one (`x86-backend-gpu`, `x86-pki`, `x86-omnibus`). |
| `make omnibus` | the opt-in x86 all-namespaces-on-one-node image. |
| `make frite` / `frite-live` / `frite-installer` | the opt-in Frite client (`FRITE_BOARD=`, `FRITE_FLAVOR=`, `FRITE_DESKTOP=light\|none`). |
| `make jetson` / `make jetson-<role>` | the **EXPERIMENTAL** Jetson Orin edge-AI platform (`jetson-edge-ai`, `jetson-backend-gpu`, `jetson-omnibus`, `jetson-desktop`; `JETSON_BOARD=`, `JETSON_KERNEL_FLAVOR=`). Hardware validation pending. |
| `make build-everything` | the **FULL documented matrix**: 3 Pi + all 11 x86 roles (nodes + omnibus + edge-ai + clients + standalone) + Frite + all 4 Jetson roles (honors `ENV=test\|prod`). |
| `make matrix-check` | **dry-run validate the whole build matrix** across all four channels via the builders' `--print-plan` (no root, no writes; `tests/build-matrix/check.sh`). |
| `make flash DEV=/dev/sdX ROLE=frontend ARCH=arm64` | write a role image to a disk (`.img` preferred). |
| `make qemu` (`qemu-rpi` / `qemu-x86`) | boot a role image under QEMU (`ARCH=arm64`→Pi, `x86`→q35+OVMF). |
| `make e2e` | boot a role VM under QEMU and run the Playwright e2e with seeded accounts. |
| `make ci` / `make ci-quick` | full pipeline (rebuild fleet → e2e) / fast (build x86 backend-gpu → e2e). |
| `make clean` | wipe the work dir. |

### Build channels — all options in all menus

Every documented image option is reachable from **every build front-end
("channel")**: the **CLI** builders (`build-{rpi5,x86-host,frite,jetson}-stage4.sh`),
the **make** targets, the **ncurses menu** (`make menu`) and the **Studio GUI**
(`studio/`), each crossed with the build ENV (`test`|`prod`). That is a standing
rule ([`specs-jetson/README.md`](specs-jetson/README.md)), and it is **enforced,
not aspirational**: [`tests/build-matrix/`](tests/build-matrix/) carries the
canonical 78-cell matrix (platform × role × env × board/flavor/desktop) and
`make matrix-check` proves all four channels agree on every cell — via the
builders' `--print-plan` dry run, `make -n` recipe inspection, the menu's
composed command and the Studio's headless `--print-command` — plus negative
checks that invalid combinations fail loudly. See
[`docs/BUILD-MATRIX.md`](docs/BUILD-MATRIX.md).

> **On NixOS / SteamOS (Steam Deck) / Arch / Debian / Fedora**, where `python3` or
> `make` may be absent or the layout is non-FHS, an **additive** Nix flake
> (`flake.nix` / `shell.nix`) and a portable launcher
> (`scripts/studio-launch.sh` — detects the distro, bootstraps a project-local venv,
> and works when `make` is absent by shelling the builder scripts directly) bring up
> the Studio wizard and the menu. They add nothing to the build engine and leave the
> `make` targets untouched. See [`docs/NIXOS-STEAMOS.md`](docs/NIXOS-STEAMOS.md).

## Spec files

The specs are split by architecture, mirroring the same pattern for both
builders: `specs-rpi5/` (aarch64/RPi5-specific) and `specs-x86/` (amd64-specific)
each hold that arch's portage/kernel/boot/installer specs, while `specs/` holds
the **arch-agnostic** specs both builds share (the `etc/` services, the KEYS
provisioning engine, the backup engine, and the `cluster/` GitOps payload).

| Path | Purpose |
|---|---|
| `specs-rpi5/portage/*` | RPi5 portage config (make.conf, packages, profile, keywords, USE) |
| `specs-rpi5/kernel/hardened-k8s.config` | RPi kernel fragment (hardened + k8s + USB/VFAT + virtio); **reference** for the arch-neutral k8s netfilter/NAT/eBPF symbols both arches share |
| `specs-x86/kernel/hardened-k8s.config` | amd64 kernel fragment (hardened + k8s). **Boot-critical:** carries the full netfilter/NAT/eBPF surface k8s Service networking needs — xtables match/target layer, `NF_NAT_MASQUERADE`, nft `NAT/MASQ/CT`, IPv6 nf tables, `IP_NF_MANGLE` (was a truncated copy that left ClusterIP/kube-proxy/MASQUERADE/dual-stack/NetworkPolicy dead). A **fail-closed build guard** in `build-x86-host-stage4.sh` (mirrored in `build-rpi5-stage4.sh`) asserts the load-bearing subset survives `make olddefconfig`; `tests/scripts/test-x86-kernel-net-symbols.sh` (CI `lint:x86-kernel-net-symbols`) keeps the fragment from re-truncating. BTF (bpf-LSM attach, eBPF CO-RE) is built too, paired with `dev-util/pahole` — see the BTF note in the fragment. |
| `specs-rpi5/boot/{config.txt.tmpl,cmdline.txt}` | RPi firmware boot config + kernel command line |
| `specs-rpi5/etc/fstab` | RPi filesystem table (mounts the `/boot` firmware partition) |
| `specs-rpi5/installer/install.sh` | SD/NVMe installer (ships in the RPi5 ISO) |
| `specs-x86/**` | amd64 host portage/kernel/installer/grub specs |
| `specs/etc/keys-provision/provision.sh` | USB KEYS provisioning engine (shared) |
| `specs/etc/init.d/{containerd,kubelet,headscale,tailscaled,keys-provision}` | OpenRC services (shared) |
| `specs/etc/init.d/growroot` | First-boot disk-grow service (fill the medium / `growfs.conf` cap; shared) |
| `specs/etc/headscale/config.yaml` | Default headscale config (shared) |
| `specs/etc/kubernetes/*`, `specs/etc/containerd/config.toml` | k8s + CRI config (shared) |
| `specs/etc/local.d/01-firstboot.start.tmpl` | First-boot finaliser (fallback user, shared) |
| `specs/usr/local/sbin/hugmesh-backup` | etcd + PostgreSQL backup engine (shared) |
| `specs/cluster/**` | ArgoCD app-of-apps, gateway Helm chart, manifests, bootstrap (shared) |
| `keys-template/**` | The KEYS USB template + schema docs |

## Repositories

This repo is the image/infra layer; application code lives in sibling repos —
see the full table in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). The
`hugmesh.net` host shell federates the per-feature remotes
(`hugmesh-login-ui`, `hugmesh-matrix-ui`, `hugmesh-mastodon-ui`,
`hugmesh-admin-ui`, `hugmesh-mod-ui`, `hugmesh-user-ui`,
`hugmesh-forum-ui`, `hugmesh-wiki-ui`) over module federation, backed by the
`hugmesh-{admin,mod,user,forum,wiki}-bff-api` Spring BFFs and
`hugmesh-federation-api` (vanity-subdomain / public-profile resolver).

The Spring services share a unified Maven baseline — **Spring Boot 4.0.7 /
Spring Cloud 2025.1.2** on Java 25 — built on three shared artifacts: **`hugmesh-parent`**
(metapom), **`hugmesh-commons`** (shared security/tenancy,
`net.hugmesh.commons.*`) and **`hugmesh-auth-core`** (shared
account/session/MFA/Casdoor-admin infra, consumed by **user-bff + admin-bff**).
SSO login/session/account ownership is being **relocated from admin-bff →
user-bff** (`login-ui` native form → `POST /bff/login` → user-bff PKCE + internal
Casdoor login/exchange → opaque `bff_` session; the gateway swaps `bff_` → custody
JWT). Account/session **data stays in
admin-bff-db**; user-bff reaches it via admin-bff `/bff/internal` over mTLS +
`X-Internal-Token`. See [Current State](#current-state).

## CI

Continuous integration runs on **GitLab** ([`.gitlab-ci.yml`](.gitlab-ci.yml)):
GitHub is pull-mirrored into an in-cluster GitLab, and a privileged runner on
the x86 node builds the role ISOs and delivers them as generic-package release
assets (latest-link path) for the admin UI's download links. ISOs carry **no
keys** — KEYS material is supplied from the USB at first boot, never baked in or
published. The **app** container images (gateway, frontends, BFFs, …) are built
from their own repos in the GitLab org mirror — the `build:images` job dispatches into the in-cluster Kaniko image-build pipeline (`specs/cluster/manifests/image-builder/`), which is **always-on**: `specs/cluster/apps/60-image-builder.yaml` is synced by the root app-of-apps, so the `hugmesh-image-builds` namespace + its default-deny NetworkPolicy always exist (the per-build Kaniko Job stays a template, so nothing runs until a build is dispatched). The `build:images` job itself is default-branch/tag-only and requires a cluster `KUBECONFIG` on the runner plus the ESO-materialized `image-builder-registry` push credential. The service-catalog Kaniko builder (PR #110) is the separate per-service-catalog build path. The OWASP pen-test suite (ZAP + Dependency-Check
+ nuclei + k6) runs as a GitLab pipeline stage, not a deployed CronJob. The
pipeline also runs **fail-closed lint/verify gates** before any build:
`lint:x86-kernel-net-symbols` (the k8s netfilter/NAT fragment can't re-truncate),
the **`casdoor-jwt-custom-gate`** (mints a real RS256 token against
`casbin/casdoor` and asserts the JWT-Custom token shape — the leaked secrets stay
ABSENT and the authz/MFA claims present — before that config can flip live), and
`domain-registry-reconcile-verify` (the signed-export domain bridge fails closed
on a bad/placeholder key). See [`docs/DEVOPS.md`](docs/DEVOPS.md).

> **CI lives in GitLab; GitHub Actions is additive.** `.gitlab-ci.yml` (83 jobs,
> in-cluster privileged runner) is the real pipeline and remains so — it is the only
> lane that can build ISOs and images.
>
> This repository previously said Actions was billing-blocked org-wide and that
> `.github/workflows` must not be added. **That is no longer true**:
> `gh api repos/hugmesh/<repo>/actions/permissions` returns
> `{"enabled":true,"allowed_actions":"all"}`, and sibling repositories have run
> `ubuntu-latest` jobs successfully. Two workflows now exist, both narrow and both on
> GitHub-hosted runners:
>
> | Workflow | What it does |
> |---|---|
> | [`studio-tests.yml`](.github/workflows/studio-tests.yml) | Runs the Qt-free `studio/` test subset on a pull request that touches `studio/`. A fast pre-merge answer, not a replacement for GitLab's fuller `test:studio-suite`. |
> | [`studio-release.yml`](.github/workflows/studio-release.yml) | Builds the Studio's Windows MSI and Linux Flatpak and publishes them as a GitHub Release. Dispatch- or tag-triggered only. |
>
> **Never target `[self-hosted, hugmesh-x86]` from a GitHub workflow.** No self-hosted
> runners are registered against this org, so such a job queues for 24 hours and is
> cancelled. Use `ubuntu-latest` / `windows-latest`.

## Security notes

- SSH is key-only; provide a key via KEYS or use the console fallback user.
- Prefer `password_hash` over plaintext; generate with `gen-provision-keys.sh`.
- The KEYS stick holds the cluster CA, preauth and backup credentials — keep it
  offline once provisioning is done. Generated secrets and build output are
  git-ignored.
- Nodes run the hardened/selinux **MCS** policy with per-app/per-pod MCS
  identities and the hugmesh node-policy modules loaded — but they boot
  **PERMISSIVE** by default (`.selinux.mode`), and the enforce-gate ships inert
  until an operator opts in; API-to-API traffic is mTLS; per-app SCRAM Postgres
  roles; secrets via Vault/ESO. See [`docs/SECURITY.md`](docs/SECURITY.md) and
  [`docs/selinux-module-loading.md`](docs/selinux-module-loading.md).
- The kernel boots with **lockdown** (`lsm=lockdown,yama,selinux,bpf`,
  `lockdown=integrity`; the 8 ARM boards carry `lsm=lockdown,yama,selinux` with the same
  `lockdown=integrity`, no `bpf`); x86 ships a **Secure Boot UKI** signed with the org key
  (`sbsign`) and runs **firewalld** (test/prod zone profiles), while the
  cross-compiled rpi5 arm64 platform excludes firewalld deliberately (the
  `glib[introspection]` cross bootstrap does not compile) and uses `nftables` +
  `iptables` + `hugmesh-firewall-reconcile`. Both arches get sysctl/SSH
  hardening.

## License

MIT
