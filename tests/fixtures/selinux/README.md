# Pinned refpolicy header tree

`refpolicy-headers-mcs-2.20260616_p1.tar.gz` is a byte-for-byte copy of

    <sysroot>/usr/share/selinux/mcs/include

taken from a real, fully green rpi5 build. It exists so that
`tests/scripts/test-selinux-policy-install.sh`'s **D-real** leg — which compiles
every `specs/selinux/*.te` with the genuine `m4 -> checkmodule -> semodule_package`
recipe — can run in CI instead of skipping.

## Why this is needed

`D-if` pins interface *names* against `scripts/selinux-interface-index.txt`. It
cannot see a second class of policy-language error: a **permission the class does
not define**. On 2026-08-06 exactly that shipped — `create_netlink_socket_perms`
expands to `{ create_socket_perms nlmsg_read nlmsg_write }`, and
`netlink_netfilter_socket` defines no `nlmsg_*` perms, so two `allow` rules in
`hugmesh_vpn.te` aborted the policy stage of a real mesh build. The class and
permission map is compiled into `base.pp`, not shipped as indexable text, so the
only honest oracle is `checkmodule` itself.

CI carries the toolchain (`selinux-policy-verify` installs `checkpolicy` and
`semodule-utils`) but had no header tree, so D-real SKIPped on every pipeline.
The bug class it exists to catch could have walked straight back in.

## Why not Debian's `selinux-policy-dev`

The CI image is Debian, and Debian packages a refpolicy header tree — but it is a
**different** policy tree, not a cheaper copy of this one. This tree carries
`gentoo_tunables.xml` and Gentoo-specific interfaces. Compiling our modules against
Debian's refpolicy would fail on interfaces that are perfectly valid in the builds
we actually ship: a red gate for a non-bug, which is worse than no gate at all.

## Precedence — the fixture always loses to the real thing

The finder tries, in order:

1. `$HUGMESH_SELINUX_HEADERS` (explicit override)
2. a real build sysroot under `out/`
3. the host's own `/usr/share/selinux/*/include`
4. **this fixture**

A real sysroot is the production article; this is a photograph of one. Whenever
the real thing is present it wins, or the leg would quietly stop tracking what
builds actually compile against.

## Drift

A pinned mirror invites exactly one failure mode: Gentoo bumps `sec-policy`, real
builds move on, and CI keeps compiling against the old policy — green while
production breaks. The **D-drift** leg guards it:

- the digest must match `refpolicy-headers.sha256`, else the fixture is refused
  outright (a tree that is not what was recorded proves nothing);
- when a real build sysroot is present, its `sec-policy` version is compared with
  the pin. It fails **only when the sysroot is newer**. A months-old local build
  tree is not a defect and is not punished for being behind; a tree that is *ahead*
  means this fixture has rotted.

CI alone cannot detect drift — it has no sysroot. Any real build re-checks it,
which is why the leg says so out loud rather than passing silently.

## Regenerating

After any fully green build, from the repo root:

```sh
SYSROOT=out/wl-pki.rpi5/sysroot          # or out/sessions/<id>/wl-<role>.<board>/sysroot
VER=$(basename "$SYSROOT"/var/db/pkg/sec-policy/selinux-base-policy-* | sed 's/^selinux-base-policy-//')

tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2026-06-16' \
    -C "$SYSROOT/usr/share/selinux/mcs" -cf - include \
  | gzip -9nc > tests/fixtures/selinux/refpolicy-headers-mcs-"$VER".tar.gz

git rm -q --ignore-unmatch tests/fixtures/selinux/refpolicy-headers-mcs-*.tar.gz \
  --  ':!*'"$VER"'*'
(cd tests/fixtures/selinux && sha256sum refpolicy-headers-mcs-"$VER".tar.gz > refpolicy-headers.sha256)
```

Then update `SLX_FIXTURE_VERSION` in `tests/scripts/test-selinux-policy-install.sh`
to `$VER` and re-run the suite. The flags above (`--sort`, fixed owner/mtime,
`gzip -n`) make the archive reproducible: regenerating from the same sysroot twice
produces an identical file, so a digest change always means the *policy* changed.

`mcs` is the type used because that is what the builds install into; the four
type-trees (`mcs`, `mls`, `strict`, `targeted`) are identical apart from
`include/build.conf`.
