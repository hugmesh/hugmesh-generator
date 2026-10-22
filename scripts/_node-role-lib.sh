# shellcheck shell=bash
# ── _node-role-lib.sh — the cluster NODE plumbing a non-Pi ARM builder reuses ──
#
# Sourced by build-rpi5-stage4.sh (for the headscale rule only) and by the two
# Orange Pi builders that build cluster NODE roles (build-orangepi5-stage4.sh for
# the Orange Pi 5 / 5 Plus, build-orangepi4-lts-stage4.sh for the Orange Pi 4 LTS).
# Both Orange Pi node paths are EXPERIMENTAL: no Orange Pi has booted an image from
# this repo; hardware validation is pending.
#
# WHAT IT DOES. A cluster node needs the same payload on every ARM board: the k8s
# configuration files and init scripts, the cluster GitOps tree with its env /
# optional-service / backing-service / firewall gates, the brand and identity-
# provider rewrites, and the node runlevel. The Raspberry Pi builder
# (build-rpi5-stage4.sh) is the proven owner of that path. Rather than paste a
# THIRD copy of its ~700 lines of gate functions (x86 already carries a second),
# an Orange Pi node build LOADS the Pi builder's own function definitions at run
# time — the exact functions a Pi node build calls — and calls them.
#
# WHY LOAD-FROM-THE-PI-BUILDER and not move the functions here. Moving them is the
# right end state (one file both builders source), and it is the follow-up. It was
# not done in the same change because six test harnesses (the IdP, Vault,
# managed-services, ESO, rebrand and optional-services suites) extract these
# functions from build-rpi5-stage4.sh by name, and rewriting the proven Pi
# builder plus those harnesses is not a change to make on a release night. Loading
# keeps the Pi builder byte-identical and gives the Orange Pi nodes the SAME code,
# not a copy that can drift. It is fail-closed: a function that cannot be found
# or does not parse stops the build at t=0 (before --print-plan returns), and
# tests/scripts/test-role-key-spelling.sh (section E) runs the loader, checks every
# function and default it brings in, the call closure of the loaded functions, and
# runs the whole node bake into a scratch sysroot.
#
# NO `set -e` here: the caller owns its shell options. One `local` per assignment
# (bash 5.3 localises a whole `local a=$1 b=$a` list before assigning).

# The Pi functions an Orange Pi node build calls, plus everything they call that
# the Orange Pi builders do not already define. Order is irrelevant (bash resolves
# a function at call time).
NODE_ROLE_PI_FUNCTIONS="_sed_rep_escape
_mgd_die _mgd_tier3_blocker _mgd_endpoint _mgd_selected _mgd_is_tier12 _mgd_is_tier3
validate_managed_services _mgd_rewrite_env _mgd_pg _mgd_pg_casdoor _mgd_velero
_mgd_fed_bundles _mgd_bake_readme gate_backing_services
parameterize_games_domain gate_env_apps bake_host_firewall rebrand_sysroot
bake_idp_conf bake_vault_conf rewrite_idp_sysroot gate_casdoor_apps write_idp_readme
apply_idp_external"

# Top-level settings the Pi builder declares and those functions read. Each is
# loaded ONLY when the variable is unset, so a brand profile (-c) or the environment
# still wins exactly as it does on the Pi.
NODE_ROLE_PI_SETTINGS="GAMES_DOMAIN USER_LEVEL_SERVICES OPTIONAL_SERVICES EXCLUDE_SERVICES
MANAGED_SERVICES ENABLE_GAMES RELEASE_STATE IDP IDP_ISSUER IDP_CLIENT_ID IDP_JWKS
VAULT_ADDR VAULT_EXTERNAL_ADDR VAULT_KV_MOUNT_FIXED
_MGD_TIER12_IDS _MGD_TIER3_IDS _IDP_URL_RE _IDP_CLIENT_ID_RE _VAULT_PATH_RE"

# The k8s node services every node role links into the default runlevel (the Pi
# list, build-rpi5-stage4.sh `DEFAULT_SVCS+=(hugmesh-firewall-reconcile ...)`;
# tests/scripts/test-role-key-spelling.sh section E asserts the two stay equal).
NODE_ROLE_RUNLEVEL_SVCS="hugmesh-firewall-reconcile hugmesh-coturn-firewall hugmesh-go-live-reconcile containerd kubelet"

# _node_role_extract_fn <name> <file> — print the LAST column-0 `name() {` ... `}`
# block in <file> (bash runs the last definition), nothing when absent.
_node_role_extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) *\\{" { buf = ""; p = 1 }
        p { buf = buf $0 "\n" }
        p && /^\}/ { last = buf; p = 0 }
        END { printf "%s", last }
    ' "$2"
}

# node_role_pi_builder — the Pi builder this lib loads from.
node_role_pi_builder() {
    printf '%s/build-rpi5-stage4.sh\n' "${SCRIPT_DIR}"
}

# node_role_load_pi_settings — set every NODE_ROLE_PI_SETTINGS variable that is
# still unset from the Pi builder's own first top-level assignment of it. rc=1 (with
# a message) when one is missing or does not evaluate.
node_role_load_pi_settings() {
    local _b
    _b="$(node_role_pi_builder)"
    [ -f "${_b}" ] || { printf 'ERROR: node role: %s not found\n' "${_b}" >&2; return 1; }
    local _v
    local _line
    for _v in ${NODE_ROLE_PI_SETTINGS}; do
        if [ -n "${!_v+x}" ]; then
            continue
        fi
        _line="$(grep -a -m1 -E "^${_v}=" "${_b}")"
        if [ -z "${_line}" ]; then
            printf 'ERROR: node role: setting %s not found in %s\n' "${_v}" "${_b}" >&2
            return 1
        fi
        # The Pi lines are plain `NAME="..."` / `NAME="${NAME:-...}"` assignments
        # (some carry a trailing comment). Evaluate the assignment only.
        eval "${_line}" || { printf 'ERROR: node role: setting %s did not evaluate\n' "${_v}" >&2; return 1; }
    done
    return 0
}

# node_role_load_pi_functions — define every NODE_ROLE_PI_FUNCTIONS function from
# the Pi builder (overriding a same-named local one: the Orange Pi builders' own
# lightweight rebrand_sysroot handles no cluster tree). rc=1 on any miss.
node_role_load_pi_functions() {
    local _b
    _b="$(node_role_pi_builder)"
    [ -f "${_b}" ] || { printf 'ERROR: node role: %s not found\n' "${_b}" >&2; return 1; }
    local _fn
    local _src
    for _fn in ${NODE_ROLE_PI_FUNCTIONS}; do
        _src="$(_node_role_extract_fn "${_fn}" "${_b}")"
        if [ -z "${_src}" ]; then
            printf 'ERROR: node role: function %s not found in %s\n' "${_fn}" "${_b}" >&2
            return 1
        fi
        eval "${_src}" || { printf 'ERROR: node role: function %s from %s does not parse\n' "${_fn}" "${_b}" >&2; return 1; }
        declare -F "${_fn}" >/dev/null || { printf 'ERROR: node role: function %s did not load\n' "${_fn}" >&2; return 1; }
    done
    return 0
}

# node_role_runs_headscale <canonical role> — the roles that host the mesh control
# server: the control plane (pki), the one-node cluster (omnibus) and the Pi's
# unbranded all-in-one (generic).
node_role_runs_headscale() {
    case "$1" in
        pki|omnibus|generic) return 0 ;;
    esac
    return 1
}

# node_role_k8s_topology <canonical role> — what kubeadm does with this node:
# control-plane (pki), single-node (omnibus), worker (everything else).
node_role_k8s_topology() {
    case "$1" in
        pki)     printf 'control-plane\n' ;;
        omnibus) printf 'single-node\n' ;;
        *)       printf 'worker\n' ;;
    esac
}

# node_role_bake_k8s_payload <sysroot> <shared-specs> — the k8s modules/sysctl,
# containerd/kubelet/kubeadm configuration, their init scripts and the CNI /
# containerd directories (the Pi's `if ! ${ROLE_CLIENT}` blocks; the file list is
# pinned equal to the Pi's by tests/scripts/test-role-key-spelling.sh section E).
node_role_bake_k8s_payload() {
    local _s="$1"
    local _sh="$2"
    mkdir -p "${_s}/etc/modules-load.d" "${_s}/etc/sysctl.d" "${_s}/etc/containerd" \
             "${_s}/var/lib/kubelet" "${_s}/etc/kubernetes" "${_s}/etc/init.d"
    cp "${_sh}/etc/modules-load.d/kubernetes.conf"   "${_s}/etc/modules-load.d/kubernetes.conf"
    cp "${_sh}/etc/sysctl.d/99-kubernetes.conf"      "${_s}/etc/sysctl.d/99-kubernetes.conf"
    cp "${_sh}/etc/containerd/config.toml"           "${_s}/etc/containerd/config.toml"
    cp "${_sh}/etc/kubernetes/kubelet-config.yaml"   "${_s}/var/lib/kubelet/config.yaml"
    cp "${_sh}/etc/kubernetes/kubeadm-config.yaml"   "${_s}/etc/kubernetes/kubeadm-config.yaml"
    local _svc
    for _svc in containerd kubelet; do
        cp "${_sh}/etc/init.d/${_svc}" "${_s}/etc/init.d/${_svc}"
        chmod +x "${_s}/etc/init.d/${_svc}"
    done
    mkdir -p "${_s}/opt/cni/bin" "${_s}/etc/cni/net.d" "${_s}/etc/containerd/certs.d"
}

# node_role_bake_cluster_tree <sysroot> <shared-specs> — copy the cluster GitOps
# tree and run the Pi's gates over the baked copy, in the Pi's order. Needs
# node_role_load_pi_functions + scripts/_optional-services-lib.sh.
node_role_bake_cluster_tree() {
    local _s="$1"
    local _sh="$2"
    [ -d "${_sh}/cluster" ] || return 0
    mkdir -p "${_s}/var/lib/hugmesh"
    cp -r "${_sh}/cluster" "${_s}/var/lib/hugmesh/cluster"
    case " ${OPTIONAL_SERVICES} " in
        *" games "*) parameterize_games_domain ;;
    esac
    gate_env_apps
    bake_host_firewall
    gate_optional_services
    gate_backing_services
}

# node_role_bake_min_ram <sysroot> <canonical role> — record the role's RAM floor
# on the image as /etc/hugmesh/min-ram-mb (GB x 1024). Absent for roles with no
# floor. Read by a person (and by the first-boot RAM check when it lands).
node_role_bake_min_ram() {
    local _s="$1"
    local _gb
    _gb="$(hugmesh_role_min_ram_gb "$2")" || return 0
    mkdir -p "${_s}/etc/hugmesh"
    printf '%s\n' "$(( _gb * 1024 ))" > "${_s}/etc/hugmesh/min-ram-mb"
}
