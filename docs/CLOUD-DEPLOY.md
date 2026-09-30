# Cloud deploy — publish a built x86 image to a cloud provider (the third side-flow)

> **Status: 🚧 in-flight** — the Studio DeployPage, the ncurses `deploy_screen`, the
> `make deploy-*` delegates and the shared Qt-free entrypoint
> (`hugmesh_studio.core.cloud_deploy`) are in this tree; they all front the ONE
> canonical driver **`specs/usr/sbin/hugmesh-cloud-deploy`** (built in the
> parallel deploy-driver lane, together with its provider registry
> `specs/usr/lib/hugmesh/cloud-deploy-providers.sh` and the packaging script
> `scripts/cloud-package.sh`). Until that lane merges, every face reports
> "driver not found" honestly — nothing pretends to deploy.
>
> State key: **✅ shipped** · **🚧 in-flight** · **🔭 planned / deferred**.

This is the **third non-image side-flow** (after the Local Docker mesh and the MDM
phone): it never builds an image and never touches `cfg.mode` / the builder argv.
It takes the **output** of a normal x86 build and walks it into a cloud:

```
(1) generate            (2) cloud-package                (3) deploy
build-x86-host-stage4   scripts/cloud-package.sh         hugmesh-cloud-deploy
  -> <name>.img           --img <raw.img>                  plan   (offline render)
                          --format qcow2|vhd-fixed|raw     apply  (confirmed)
                          --out-dir <dir>                  status (reads hints)
                        -> .qcow2 / .vhd / .img + manifest destroy (confirmed)
```

## 1. Generate — build the x86 image as usual

Any existing x86 channel works (`make x86`, the Studio wizard, ncurses, CLI). The
cloud track deploys the ARTIFACT; it changes nothing about how images are built.

## 2. Cloud-package — convert the raw artifact for the target

`scripts/cloud-package.sh --img <raw.img> --format qcow2|vhd-fixed|raw --out-dir <dir>`
(operator-facing, standalone — NOT wired into the builders' hot path):

- **qcow2** — for OpenShift Virtualization (CNV/KubeVirt), plain libvirt/RHEL
  hosts, and any qcow2-taking PaaS.
- **vhd-fixed** — for Azure: virtual size rounded UP to a whole MiB, then a
  `subformat=fixed,force_size` VPC conversion (both hard Azure requirements).
- **raw** — for AWS EC2 `import-snapshot` (takes RAW as-is).

Each artifact gets a `FORMAT … FILE … BYTES … SHA256 …` manifest line. The script
**refuses non-x86 artifacts** — see the limits below.

## 3. Deploy — one driver, four interchangeable faces

The driver's verbs: `list` (TAB-separated provider registry — the parseable API) ·
`plan` (DEFAULT: renders the provider's artifacts OFFLINE into `--out-dir`) ·
`apply` (executes the plan's emitted `apply.sh` after checking creds are present;
TTY-confirmed) · `status` (reads emitted state hints / prints the provider check
commands — never calls a cloud API itself) · `destroy` (runs the emitted
`destroy.sh`; TTY-confirmed). Flags, in the pinned order every face emits:
`--provider --image --domain --region --creds-file --out-dir --keys-dir`.

Initial providers (all "full"): `aws-ec2` (S3 upload → import-snapshot →
register-image, vmimport policies, ENA checklist) · `azure-image` (blob upload →
Gen2 image, VM Image Builder template, Entra notes) · `openshift-cnv`
(DataVolume + VM YAML, SCC/vanilla-delta notes, RHEL virt-install notes) ·
`generic-qcow2` (libvirt XML + PaaS upload notes).

- **Studio GUI** — first screen → **Cloud deploy** (sixth choice; a terminal
  side-flow page like MDM phone). Provider picker comes live from `list`; a pure
  plan preview live-refreshes as you type (knobs + the exact plan command + a
  BLOCKERS tail); **Apply is double-gated** — an explicit ack checkbox in the GUI
  *and* the driver's own confirmation (never bypassed); **Destroy opens a real
  terminal** so the driver's prompt runs there. "Open artifacts folder" shows the
  rendered plan.
- **ncurses** — `make menu` → Build → **Cloud deploy**. Same knobs; `apply`/
  `destroy` run foreground with the terminal attached so the driver's own
  confirmation prompts reach you.
- **Makefile** —
  `make deploy-plan PROVIDER=aws-ec2 DEPLOY_IMAGE=work/x86.img.qcow2 REGION=… OUT_DIR=…`
  then `deploy-apply` / `deploy-status` / `deploy-destroy` with the same knobs
  (`DEPLOY_IMAGE`, because `IMAGE` is the builder-container knob).
- **Python module** — `PYTHONPATH=studio python3 -m hugmesh_studio.core.cloud_deploy
  plan --provider … --image …` (what ncurses/Make actually shell).

### Credential custody (the phone-wizard bar)

- `--creds-file` forwards a **path** to your own `chmod 600` credentials file —
  the contents never ride argv, this repo never reads them, and a
  group/world-readable creds file is a validation **blocker**.
- Creds *pasted* into the Studio page / ncurses masked prompt are staged into a
  0600 tempfile for exactly one run and **shredded in `finally`** — never on the
  process table, never persisted, never in a saved config or `menu.conf`.
- There is deliberately **no `--yes` / bypass knob** on any face; `CD_ASSUME_YES`
  is the driver's hermetic-test seam only.

## Honest limits

- **x86-only.** The ARM images (rpi5 / frite / jetson / orangepi*) boot via
  u-boot / L4T board bundles — not cloud-viable images; `cloud-package.sh`
  refuses them by design rather than emitting something that cannot boot.
- **No real-cloud verification.** Everything below `apply` is proven ONLY against
  hermetic stubs (recorded argv, fabricated drivers) — CI never contacts AWS/
  Azure/OpenShift, uploads nothing, and boots nothing. The rendered plans are
  readable scripts you audit and run under your own account; treat the first
  apply per provider as unverified territory.
- **Kernel caveats are checklists, not proofs.** AWS needs ENA
  (`CONFIG_ENA_ETHERNET`) for register-image `--ena-support`; Azure needs
  `hv_storvsc`/`hv_netvsc` and is **Gen2/UEFI-only** (Gen1/BIOS is impossible by
  design here). The emitted checklists say so; nothing in this repo has
  live-booted the images on either hypervisor yet.
- **`status` never calls a cloud API** — it reads emitted state hints and prints
  the provider's own check commands for you to run.
- The Studio page's **streamed Apply** runs the driver without a TTY: if the
  driver insists on its interactive confirmation there, it fails **closed** with
  its own message (use the ncurses/Makefile face on a real terminal) — the GUI
  never injects an answer.

## Identity provider passthrough

Every deploy face carries the same IdP picker the node and local-mesh setups
offer: the built-in IdP (Casdoor) is the default and adds **nothing** to the
plan; picking an external provider (`--idp entra|aws|oidc` + `--idp-issuer`,
optional `--idp-client-id`/`--idp-jwks`; GUI combo; ncurses "Identity provider"
entry; `make deploy-plan IDP= IDP_ISSUER=…`) makes the plan additionally emit
`idp/idp.conf` + `idp/README.md` — the same shape the node builders bake as
`/etc/hugmesh/idp.conf`, so the deployed VM and its operator agree on the
issuer. Deploying an image *built* with external-IdP flags? Pick the same
provider here. Entra's JWKS defaults to `/discovery/v2.0/keys` (it does not
serve `/.well-known/jwks`); Cognito's group claims arrive as `cognito:groups`.
See `docs/IDENTITY-PROVIDERS.md` for what external mode does and does not
change.

For the **local docker stack**, the same override rides the Makefile seam:
`make stack-up OIDC_ISSUER=https://login.microsoftonline.com/<tenant>/v2.0`
replaces the derived Casdoor issuer in `STACK_ENV`; empty/unset leaves today's
behavior byte-for-byte. The azure plan's `entra/env/` fragments reference this
seam too.

## Where things live

| Piece | Path |
| --- | --- |
| Qt-free core (all faces shell this) | `studio/hugmesh_studio/core/cloud_deploy.py` |
| Studio page + standalone dialog | `studio/hugmesh_studio/gui/pages/deploy.py` |
| ncurses screen | `scripts/build-menu.sh` (`deploy_screen` / `_deploy_run`) |
| Make delegates | `Makefile` (`deploy-plan/apply/status/destroy`) |
| Driver + registry (parallel lane) | `specs/usr/sbin/hugmesh-cloud-deploy`, `specs/usr/lib/hugmesh/cloud-deploy-providers.sh` |
| Packaging (parallel lane) | `scripts/cloud-package.sh` |
| Tests (hermetic, stub driver) | `studio/tests/test_cloud_deploy.py`, `studio/tests/test_cloud_deploy_cli.py` (real argparse, Qt-free), `tests/menu/build_menu_cmd_test.sh` (deploy block) |

The env seam `SNAP_CLOUD_DEPLOY_CMD` points every face at a stub driver in tests —
the exact `SNAP_PHONE_WIZARD` pattern.
