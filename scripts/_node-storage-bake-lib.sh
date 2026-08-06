#!/usr/bin/env bash
# _node-storage-bake-lib.sh — SOURCED helper: bake the NODE-STORAGE reconcile agent
# into an image sysroot. ONE definition, every builder.
#
# WHY THIS IS A LIB AND NOT TEN INLINE COPIES.
# The agent (node-storage PR6) first shipped in specs/ ONLY and was baked into ZERO
# images: an operator could register a pool in the UI and no node would ever reconcile
# it. #525 fixed that by pasting seven lines into all ten build-*-stage4.sh scripts and
# adding a guard that grep'd each builder for those lines. Text presence is not a bake:
# the same seven lines survive being commented out, being retargeted at the wrong path,
# and being moved inside a branch that never runs for a mesh node — all three leave a
# grep-based guard green while the image ships without the agent.
#
# With ONE function the bake is a THING THAT CAN BE EXECUTED. tests/node-storage/
# test-bake-coverage.sh sources this file, runs bake_node_storage against a sandbox
# sysroot and asserts the four files LANDED, at those exact paths, with those modes —
# then runs provision.sh's provision_node_storage against the same sysroot and asserts
# the boot oneshot was enabled and the cron drop-in placed. Effect, not presence.
#
# THE CROSS-FILE CONTRACT. The cron drop-in is NOT baked to /etc/cron.d: it is STAGED
# at ${sysroot}/etc/hugmesh/registry/cron-node-storage-reconcile, and provision.sh's
# provision_node_storage() copies it into /etc/cron.d at first boot (the same staging
# idiom the device-registry sync uses, so cron only ever polls on a provisioned node).
# Both halves of that contract are asserted by running them back to back against one
# sandbox sysroot, so a rename on EITHER side leaves /etc/cron.d empty and goes red.
#
# Callers: every build-*-stage4.sh, unconditionally on any image that joins the mesh.
# The agent is INERT by CONTENT, not by absence — without node.env it exits 0 keeping
# its cache, and a node with no registered pool receives the EMPTY signed export and
# provisions nothing. So there is no role that needs it left out; the only legitimate
# gate is the x86 builder's `! ${UNAFFILIATED}` (a standalone workstation has no mesh
# at all). test-bake-coverage.sh knows that one gate by name and fails closed on any
# other one.

# bake_node_storage <SYSROOT> <SHARED_SPECS>
#
# Installs the four node-storage files into <SYSROOT> and creates the agent's cache
# directory. Returns 0 on success; on a missing source spec it prints the offending
# path and returns 1 (a cp from a missing spec used to fail the build late and
# unattributably).
bake_node_storage() {
    local sysroot="${1:-}" specs="${2:-}"
    if [ -z "${sysroot}" ] || [ -z "${specs}" ]; then
        printf 'bake_node_storage: usage: bake_node_storage <SYSROOT> <SHARED_SPECS>\n' >&2
        return 1
    fi

    # (src-relative-to-specs, dest-relative-to-sysroot, mode)
    #   * the agent + the OpenRC oneshot are EXECUTED  -> 0755
    #   * storage-verify.sh is SOURCED by the agent    -> 0644
    #   * the cron drop-in is STAGED under /etc/hugmesh/registry (NOT /etc/cron.d);
    #     provision_node_storage() places it once the node is provisioned.
    local -a spec_map=(
        "usr/sbin/hugmesh-node-storage-reconcile|usr/sbin/hugmesh-node-storage-reconcile|0755"
        "usr/lib/hugmesh/storage-verify.sh|usr/lib/hugmesh/storage-verify.sh|0644"
        "etc/init.d/hugmesh-node-storage-reconcile|etc/init.d/hugmesh-node-storage-reconcile|0755"
        "etc/cron.d/hugmesh-node-storage-reconcile|etc/hugmesh/registry/cron-node-storage-reconcile|0644"
    )

    local entry src dst mode rc=0
    for entry in "${spec_map[@]}"; do
        src="${specs}/${entry%%|*}"
        dst="${entry#*|}"; mode="${dst#*|}"; dst="${sysroot}/${dst%%|*}"
        if [ ! -r "${src}" ]; then
            printf 'bake_node_storage: missing spec source: %s\n' "${src}" >&2
            rc=1; continue
        fi
        mkdir -p "$(dirname "${dst}")" || { rc=1; continue; }
        install -m "${mode}" "${src}" "${dst}" || { rc=1; continue; }
    done

    # The agent's fail-closed cache (last-good export + generation). Created here so a
    # first boot with no network still has somewhere to keep last-good.
    mkdir -p "${sysroot}/var/lib/hugmesh/node-storage" || rc=1

    [ "${rc}" -eq 0 ] || printf 'bake_node_storage: node-storage bake FAILED for sysroot %s\n' "${sysroot}" >&2
    return "${rc}"
}
