# Superadmin mesh client — join & SSH reach (v1)

How a platform **superadmin** joins the tailnet mesh and reaches nodes over SSH.
This is the operator runbook for the bootstrap superadmin identity that
`casdoor-init` seeds (`reconcile_superadmin()` in
[`specs/cluster/manifests/casdoor/init-job.yaml`](../specs/cluster/manifests/casdoor/init-job.yaml)).

State key: **✅ shipped** · **🔭 planned / deferred**.

## What the platform seeds for you (✅)

`casdoor-init` (`reconcile_superadmin()`) provisions the bootstrap superadmin from the
optional Vault-sourced Secret `casdoor-superadmin`
(`/secrets/superadmin/{username,password}`). When that Secret is present, it:

1. **creates/updates the Casdoor user** in org `hugmesh`,
2. **assigns `ROLE_SUPERADMIN`** (control-plane authority — the
   superadmin infra console + arch/core image-build surface at the be-gateway), and
3. **grants `hugmesh/headscale` Casdoor group membership** on the user record
   (`user.groups`), the field the OIDC `groups` claim reads, and creates the
   `headscale` group if it does not exist yet. It ALSO tries to record the member on
   the group object itself (`update-group`'s `users` field) so the Casdoor console
   shows it. On casbin/casdoor:3.80.0 that write is a confirmed no-op (Casdoor honors
   `users` only when it *creates* a group, not on later updates). So **the Casdoor
   admin UI's group members page may show `headscale` as empty even though mesh-join
   works**. This is cosmetic. An empty group page does not mean the gate is broken.
   Check the user's own `groups` field (`/api/get-user`) instead.

Step 3 is what makes OIDC mesh-join possible. headscale gates node-join on
`allowed_groups: [hugmesh/headscale]`
([`keys-template/headscale/config.yaml`](../keys-template/headscale/config.yaml)),
so **`ROLE_SUPERADMIN` alone is not enough**. The user must be in that group for the
OIDC `groups` claim to admit the node. The claim value is the group's internal
`<owner>/<name>` id string (`hugmesh/headscale`), NOT a bare `/headscale` path. This
is LIVE-VERIFIED against a real minted token (`tests/casdoor/test-jwt-custom-token.sh`).
An earlier draft of this page and of `reconcile_superadmin()`'s comments assumed the
bare-path form, which was never minted. If no `casdoor-superadmin` Secret was
generated, `reconcile_superadmin()` skips without error, and the operator provisions
the superadmin (user + `ROLE_SUPERADMIN` + `hugmesh/headscale` group) by hand in
Casdoor.

Mesh-join also needs the **Casdoor OAuth2 Application** that headscale logs in as
(`clientId: app-headscale`, `keys-template/headscale/config.yaml` `oidc.client_id`)
to be registered. `casdoor-init` seeds it (the `"headscale"` entry in reconcile.py's
`APPS` dict), so you create no Application by hand, even in the manual-fallback path
above. Before that was wired, headscale had no registered OIDC client, and mesh-join
failed whatever the group membership.

## Step 1 — join the mesh over OIDC (✅)

> See also: [`MDM.md`](MDM.md) (✅ shipped) — the same headscale join for an MDM-managed **phone** (pre-auth key or Casdoor OIDC, ADR-14 register-and-approve), driven by `scripts/phone-wizard.sh enroll`.

On the superadmin's device (laptop or console), with the Tailscale client installed,
log in to the platform headscale and request SSH:

```sh
tailscale up \
  --login-server=https://<headscale-url> \
  --ssh
```

Resolve `<headscale-url>` the way the fleet does. In order of precedence:
`provision.json .headscale.server_url`, then the DHCP/registry-advertised endpoint,
then the baked brand var `HEADSCALE_URL` (`/etc/hugmesh/headscale-url`). See
[`keys-template/headscale/config.yaml`](../keys-template/headscale/config.yaml)
and `specs/etc/keys-provision/provision.sh` for endpoint resolution.

`tailscale up` prints an authentication URL. Open it and complete the **Casdoor OIDC
login** with the superadmin's generated credential (the salted and hashed bootstrap
credential from the key-USB key-generation flow; never committed). The user is in
`hugmesh/headscale`, so headscale admits the node and the device joins the tailnet.

The node now has **data-plane membership**. It is on the mesh and gets
`tag:mesh_<MESH_ID>` from the control node (the destination of the always-emitted
superadmin mesh rule). It does **not yet** have SSH reach.

## Step 2 — get SSH reach (`tag:superadmin`) — REMAINING MANUAL STEP (🔭 deferred)

SSH destinations in the generated headscale policy key on **server-forced** tags, not
self-advertised ones. `tag:superadmin` grants the superadmin operator SSH reach.
Only [`hugmesh-headscale-forcetags`](../specs/usr/sbin/hugmesh-headscale-forcetags)
assigns it, and it reads a manual allowlist on the **control (pki) node**:

```
/etc/hugmesh/registry/superadmin-machines.txt   # one machine key per line
```

To give the newly joined device SSH reach, do this on the control node:

1. **Find the device's machine key** as headscale reports it:

   ```sh
   headscale nodes list -o json    # match your node; copy its machine key string
   ```

   (Check which JSON field holds it on your headscale version. The script tries
   `.machineKey` / `.machine_key` / `.nodeKey`. The value in the allowlist must be
   **byte-identical** to what headscale reports, or the tag lands on the wrong node or
   none.)

2. **Add that machine key** as its own line in
   `/etc/hugmesh/registry/superadmin-machines.txt`.

3. **Run the force-tag pass** (or let the scheduled `gen-headscale-policy.sh` run it
   after the next verified export):

   ```sh
   hugmesh-headscale-forcetags
   ```

   It force-assigns `tag:superadmin` on every machine key in the allowlist. Once set,
   the tag **overrides** any `--advertise-tags` the node sent, so nobody can forge
   the SSH destination.

## Why the allowlist step is deliberately manual (not a bug)

v1 **deliberately leaves** the `superadmin-machines.txt` step manual. It is the
control that keeps `tag:superadmin` **non-forgeable** (hardening ref:
**FIX-SERVERTAG**). Before the hardening, nodes applied their own tags at join
(`--advertise-tags=tag:...`), so any node could advertise `tag:superadmin` and pose as
a privileged SSH destination. Forcing the tag from a **manual allowlist that only the
control node holds**, keyed to a **known machine**, closes that hole. Filling the
allowlist from anything the joining node asserts would reopen it. So OIDC mesh-join
(Step 1) is automated. Binding SSH reach to a specific operator machine (Step 2)
stays a deliberate control-node admin action, until a source of superadmin-operator
identity exists that the node cannot assert for itself.

## Summary

| Capability | How | State |
| --- | --- | --- |
| Casdoor user + `ROLE_SUPERADMIN` | `casdoor-init` `reconcile_superadmin()` | ✅ automated |
| `hugmesh/headscale` group membership (OIDC mesh-join gate) | `casdoor-init` `reconcile_superadmin()` | ✅ automated |
| headscale's Casdoor OAuth2 Application (`app-headscale`) | `casdoor-init` reconcile.py `APPS` dict | ✅ automated |
| Mesh join over OIDC | `tailscale up --login-server=… --ssh` + Casdoor login | ✅ automated |
| Data-plane membership (`tag:mesh_*`) | forced on every approved node by the control node | ✅ automated |
| SSH reach (`tag:superadmin`) | add machine key to `superadmin-machines.txt` + `hugmesh-headscale-forcetags` | 🔭 deliberately manual (FIX-SERVERTAG) |
