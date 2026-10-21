# Pinned refpolicy header tree

`refpolicy-headers-mcs-2.20260616_p1.tar.gz` is a byte-for-byte copy of

    <sysroot>/usr/share/selinux/mcs/include

taken from a real, fully green rpi5 build. It lets the **D-real** leg of
`tests/scripts/test-selinux-policy-install.sh` run in CI instead of skipping.
D-real compiles every `specs/selinux/*.te` with the genuine
`m4 -> checkmodule -> semodule_package` recipe.

## Why this is needed

`D-if` pins interface *names* against `scripts/selinux-interface-index.txt`. It
cannot see a second kind of policy error: a **permission the class does not
define**. On 2026-08-06 exactly that shipped. `create_netlink_socket_perms`
expands to `{ create_socket_perms nlmsg_read nlmsg_write }`, and
`netlink_netfilter_socket` defines no `nlmsg_*` perms. Two `allow` rules in
`hugmesh_vpn.te` aborted the policy stage of a real mesh build. The class and
permission map is compiled into `base.pp`, not shipped as text anyone can index.
The only honest check is `checkmodule` itself.

CI has the toolchain (`selinux-policy-verify` installs `checkpolicy` and
`semodule-utils`) but had no header tree, so D-real skipped on every pipeline and
the bug could have come straight back.

## Why not Debian's `selinux-policy-dev`

The CI image (`python:3-slim`, job `selinux-policy-verify`) is Debian. Debian
packages a refpolicy header tree, but it is a **different** policy tree, not a
cheaper copy of this one. This tree carries `gentoo_tunables.xml` and
Gentoo-specific interfaces. Our modules compiled against Debian's refpolicy would
fail on interfaces that are valid in the builds we ship. A red gate for a non-bug
is worse than no gate.

## Precedence — the fixture always loses to the real thing

The finder tries, in order:

1. `$HUGMESH_SELINUX_HEADERS` (explicit override)
2. a real build sysroot, `out/sessions/*/wl-*/sysroot/usr/share/selinux/*/include`
3. the host's own `/usr/share/selinux/*/include`
4. **this fixture**

A real sysroot is the production article. This is a photograph of one. When the
real thing is present it wins, or the leg would stop tracking what builds
compile against.

## Drift

A pinned mirror has one failure mode. Gentoo bumps `sec-policy`, real builds move
on, and CI keeps compiling against the old policy: green while production
breaks. The **D-drift** leg guards against it:

- the digest must match `refpolicy-headers.sha256`, or the fixture is refused
  outright (a tree that is not what was recorded proves nothing);
- when a real build sysroot is present (`out/sessions/*/wl-*/sysroot` or
  `out/*/sysroot`), its `sec-policy` version is compared with the pin. It fails
  **only when the sysroot is newer**. A months-old local build tree is not a
  defect. A tree that is *ahead* means this fixture has rotted.

CI alone cannot detect drift, because it has no sysroot. Any real build re-checks
it, which is why the leg says so out loud instead of passing silently.

## Regenerating

After any fully green build, from the repo root:

```sh
# D-real finds only out/sessions/<id>/wl-<role>.<board>/sysroot; D-drift also reads out/<dir>/sysroot.
SYSROOT=out/sessions/<id>/wl-pki.rpi5/sysroot      # or out/wl-pki.rpi5/sysroot
VER=$(basename "$SYSROOT"/var/db/pkg/sec-policy/selinux-base-policy-* | sed 's/^selinux-base-policy-//')

tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2026-06-16' \
    -C "$SYSROOT/usr/share/selinux/mcs" -cf - include \
  | gzip -9nc > tests/fixtures/selinux/refpolicy-headers-mcs-"$VER".tar.gz

git rm -q --ignore-unmatch tests/fixtures/selinux/refpolicy-headers-mcs-*.tar.gz \
  --  ':!*'"$VER"'*'
(cd tests/fixtures/selinux && sha256sum refpolicy-headers-mcs-"$VER".tar.gz > refpolicy-headers.sha256)
```

Then set `SLX_FIXTURE_VERSION` in `tests/scripts/test-selinux-policy-install.sh`
to `$VER` and re-run the suite. The flags above (`--sort`, fixed owner and mtime,
`gzip -n`) make the archive reproducible. Regenerating from the same sysroot twice
gives an identical file, so a digest change always means the *policy* changed.

`mcs` is the type used because that is what the builds install. The four
type-trees (`mcs`, `mls`, `strict`, `targeted`) are identical apart from
`include/build.conf`.
