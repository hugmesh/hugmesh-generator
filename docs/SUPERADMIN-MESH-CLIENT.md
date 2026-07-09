# Superadmin mesh client — join & SSH reach (v1)

How a platform **superadmin** joins the tailnet mesh and reaches nodes over
SSH. This is the operator runbook for the bootstrap superadmin identity seeded
by `casdoor-init` (`reconcile_superadmin()` in
[`specs/cluster/manifests/casdoor/init-job.yaml`](../specs/cluster/manifests/casdoor/init-job.yaml)).

State key: **✅ shipped** · **🚧 in-flight** · **🔭 planned / deferred**.

## What the platform seeds for you (✅)

`casdoor-init` (`reconcile_superadmin()`) provisions the bootstrap superadmin
from the optional Vault-sourced Secret `casdoor-superadmin`
(`/secrets/superadmin/{username,password}`). When that Secret is present it:

1. **creates/updates the Casdoor user** in org `snapdragon`,
2. **assigns `ROLE_SUPERADMIN`** (control-plane authority — the
   superadmin infra console + arch/core image-build surface at the be-gateway), and
3. **grants `/headscale` Casdoor group membership** — both on the group
   (`update-group`) and on the user record (`user.groups`), and it **creates the
   `/headscale` group if it does not exist yet**.

Step 3 is what makes OIDC mesh-join possible. headscale's node-join is gated on
`allowed_groups: [/headscale]`
([`keys-template/headscale/config.yaml`](../keys-template/headscale/config.yaml)),
so **`ROLE_SUPERADMIN` alone is not enough** — the user must be in the
`/headscale` group for the OIDC `groups` claim to admit the node. If no
`casdoor-superadmin` Secret was generated, `reconcile_superadmin()` skips
gracefully and the operator provisions the superadmin (user + `ROLE_SUPERADMIN`
+ `/headscale` group) by hand in Casdoor.

## Step 1 — join the mesh over OIDC (✅)

On the superadmin's device (laptop/console), with the Tailscale client
installed, log in against the platform headscale, requesting SSH:

```sh
tailscale up \
  --login-server=https://<headscale-url> \
  --ssh
```

Resolve `<headscale-url>` the same way the fleet does — precedence:
`provision.json .headscale.server_url` → the DHCP/registry-advertised endpoint →
the baked brand var `HEADSCALE_URL` (`/etc/snapdragon/headscale-url`). See
[`keys-template/headscale/config.yaml`](../keys-template/headscale/config.yaml)
and `specs/etc/keys-provision/provision.sh` for endpoint resolution.

`tailscale up` prints an authentication URL. Open it and complete the **Casdoor
OIDC login** with the superadmin's generated credential (the salted+hashed
bootstrap credential produced by the key-USB key-generation flow — never
committed). Because the user is in `/headscale`, headscale admits the node and
the device joins the tailnet.

At this point the node has **data-plane membership** — it is on the mesh and
gets `tag:mesh_<MESH_ID>` from the control node (which is the destination of the
always-emitted superadmin mesh rule). It does **not yet** have SSH reach.

## Step 2 — get SSH reach (`tag:superadmin`) — REMAINING MANUAL STEP (🔭 deferred)

SSH destinations in the generated headscale policy key on **server-forced**
tags, not self-advertised ones. `tag:superadmin` is the tag that grants the
superadmin operator SSH reach, and it is force-assigned **only** by
[`snapdragon-headscale-forcetags`](../specs/usr/sbin/snapdragon-headscale-forcetags)
reading a manual allowlist on the **control (pki) node**:

```
/etc/snapdragon/registry/superadmin-machines.txt   # one machine key per line
```

To grant the freshly-joined device SSH reach, the operator must, on the control
node:

1. **Find the device's machine key** as headscale reports it:

   ```sh
   headscale nodes list -o json    # match your node; copy its machine key string
   ```

   (Confirm which JSON field holds it on your headscale version — the script
   tries `.machineKey` / `.machine_key` / `.nodeKey`; the value in the allowlist
   must be **byte-identical** to what headscale reports, or the tag lands on the
   wrong/no node.)

2. **Add that machine key** as its own line in
   `/etc/snapdragon/registry/superadmin-machines.txt`.

3. **Run the force-tag pass** (or let the scheduled
   `gen-headscale-policy.sh` invoke it after the next verified export):

   ```sh
   snapdragon-headscale-forcetags
   ```

   It force-assigns `tag:superadmin` on every machine key in the allowlist. Once
   set, the tag **overrides** any `--advertise-tags` the node sent, so the SSH
   destination is non-forgeable.

## Why the allowlist step is deliberately manual (not a bug)

Automating the `superadmin-machines.txt` step is **intentionally deferred** for
v1 — it is the exact control that keeps `tag:superadmin` **non-forgeable**
(hardening ref: **FIX-SERVERTAG**). On the pre-hardening design, tags were
self-applied at join (`--advertise-tags=tag:...`), so any node could advertise
`tag:superadmin` and masquerade as a privileged SSH destination. Forcing the tag
from a **control-node-only manual allowlist**, keyed to a **known machine**, is
what removes that forgery path. Auto-populating the allowlist from anything the
joining node asserts would re-introduce exactly the hole FIX-SERVERTAG closed.
So OIDC mesh-join (Step 1) is automated; binding SSH reach to a specific
operator machine (Step 2) stays a deliberate control-node admin action until a
trustworthy, non-self-asserted source of superadmin-operator identity exists.

## Summary

| Capability | How | State |
| --- | --- | --- |
| Casdoor user + `ROLE_SUPERADMIN` | `casdoor-init` `reconcile_superadmin()` | ✅ automated |
| `/headscale` group membership (OIDC mesh-join gate) | `casdoor-init` `reconcile_superadmin()` | ✅ automated (this change) |
| Mesh join over OIDC | `tailscale up --login-server=… --ssh` + Casdoor login | ✅ automated |
| Data-plane membership (`tag:mesh_*`) | forced on every approved node by the control node | ✅ automated |
| SSH reach (`tag:superadmin`) | add machine key to `superadmin-machines.txt` + `snapdragon-headscale-forcetags` | 🔭 deliberately manual (FIX-SERVERTAG) |
