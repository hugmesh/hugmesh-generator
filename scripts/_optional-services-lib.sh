#!/usr/bin/env bash
# _optional-services-lib.sh — the ONE implementation of the OPTIONAL-SERVICE
# selection gate + its renderers, sourced by EVERY stage4 builder that bakes the
# cluster GitOps tree (build-rpi5-stage4.sh, build-x86-host-stage4.sh).
#
# WHY THIS FILE EXISTS (2026-08-26). Until this commit each builder carried its
# OWN copy of gate_optional_services() and the ~13 _opt_* helpers. They were
# character-for-character identical except for comments — and, silently, three
# real divergences that shipped in x86 images:
#
#   1. build-x86-host-stage4.sh had NO _opt_render_appset_flag at all, while its
#      own comments (line ~1215: "renders it installed:\"false\" in BOTH the
#      ConfigMap and the 13a ApplicationSet"; the --exclude-services help text:
#      "ConfigMap + 13a ApplicationSet flag renders \"false\"") CLAIMED it did.
#      Observed: an x86 image with a deselected slug wrote installed:"false" into
#      manifests/policy/installed-services-configmap.yaml but left the matching
#      apps/13a-optional-services.yaml element at installed:"true". The 13a
#      generator's selector keeps installed=="true" elements, so a repo-synced
#      ArgoCD RE-FORCED the deselected service back on. rpi5 images did not.
#
#   2. build-x86-host-stage4.sh had NO anubis handling whatsoever — no
#      _opt_explicitly_deselected, no _opt_anubis_installed, no
#      _opt_wire_anubis_ingress. Observed: an x86 `--env prod` image shipped the
#      PUBLIC proof-of-work shield OFF (ConfigMap anubis:"false", the safe TEST
#      baseline) and the fe-gateway public Ingress backend un-rerouted, i.e.
#      straight to fe-gateway with no PoW gate in path. "All shields up in prod"
#      held on arm64 nodes and quietly did not hold on the x86 host.
#
#   3. build-x86-host-stage4.sh ran the edge-ai-analysis dependsOn-edge-ai guard
#      at TOP LEVEL, BEFORE the EXCLUDE_SERVICES subtraction. Observed:
#      `--optional-services "edge-ai edge-ai-analysis" --exclude-services edge-ai`
#      shipped the analysis wrapper with no model server behind it (the guard saw
#      edge-ai still selected, then EXCLUDE removed it afterwards). rpi5 runs the
#      same guard INSIDE the gate, i.e. AFTER exclusion, and was correct.
#
# All three are the same failure: a second copy. Grep-based parity tests could not
# see them either — tests/stack/test-optional-services-exclude.sh section 4c
# grepped the x86 file for the selection KNOBS and one case body, and a parity
# test that greps for a FUNCTION NAME is barely better (a name can be present in a
# comment, and a present-but-wrong body still passes). So the fix is structural:
# ONE file, sourced by both, and the parity question stops being askable.
#
# CONTRACT FOR CALLERS. Read from the environment, not from arguments:
#   OPTIONAL_SERVICES  resolved selection, whitespace-separated (the caller applies
#                      its own default / `all` sentinel / opt-in folds /
#                      EXCLUDE_SERVICES subtraction BEFORE calling the gate — the
#                      gate is the LAST word and mutates OPTIONAL_SERVICES only for
#                      the dependsOn drop below).
#   SYSROOT            the baked image root; the tree is
#                      ${SYSROOT}/var/lib/hugmesh/cluster.
#   ENV                prod|test — drives the anubis ENV-conditional decision.
#   EDGE_AI_RUNTIME / EDGE_AI_MODELS / EDGE_AI_MODEL_DEFAULT
#                      OPTIONAL (default empty). Only the x86 host builder defines
#                      these; every read below uses ${VAR:-} so a builder that has
#                      no edge-ai model knobs (rpi5) is a byte-identical no-op.
# The logger functions info/warn are the CALLER's (every builder and every test
# harness that sources this file defines them).
#
# Arch-neutral by construction: the gate only ever touches the shared
# specs/cluster tree that both builders bake. See specs/cluster/optional-services.yaml
# for the DECLARED registry this is the executable twin of.

# ── OPTIONAL-SERVICE gate ───────────────────────────────────────────────────
# Prune every OPTIONAL service (akkoma/tuwunel/phpbb/games) NOT selected in
# OPTIONAL_SERVICES from the baked GitOps tree, enumerated by
# specs/cluster/optional-services.yaml. Same `rm -f` design as gate_env_apps
# (removing a baked Application IS the gate; ArgoCD recurse:true never
# instantiates it). Arch-neutral — identical logic on arm64/amd64; the gate
# operates on the shared specs/cluster tree both builders bake. For each
# unselected slug it removes the owned apps + manifests dir, its per-service ESO
# file (+ kustomization line), its gateway HOST routes + route-access rows (so a
# matched route to a deleted upstream cannot 502 and a leftover role row cannot
# stale-grant). Shared social-ui is removed only when BOTH homeservers go.
#
# ⚠ RUNTIME NOTE: build-time prune only stops the bootstrap seed; the live
# cluster syncs apps/ from the gitops repo. True runtime add/remove uses the
# installed-services ConfigMap + the optional-services ApplicationSet
# (apps/13a-optional-services.yaml). See docs/OPTIONAL-SERVICES.md.
#
# ⚠ CROSS-REPO TODO (gateway wave): CanonicalSeed.java (hugmesh-gateway) +
# the cloudflared configmap reserved hostnames must stay in sync with the rows
# pruned here. NOT edited by this build (separate repo / image rebuild).
_opt_selected() {
    local s; for s in ${OPTIONAL_SERVICES}; do [ "${s}" = "$1" ] && return 0; done
    return 1
}
gate_optional_services() {
    local tree="${SYSROOT}/var/lib/hugmesh/cluster"
    local apps="${tree}/apps"
    [ -d "${apps}" ] || return 0
    local slug
    # edge-ai-analysis dependsOn edge-ai: drop it if the model server is not selected
    # (its prune case then runs) — never ship the wrapper with no upstream.
    case " ${OPTIONAL_SERVICES} " in
        *" edge-ai-analysis "*)
            case " ${OPTIONAL_SERVICES} " in
                *" edge-ai "*) ;;
                *) OPTIONAL_SERVICES="${OPTIONAL_SERVICES//edge-ai-analysis/}"
                   warn "edge-ai-analysis requires edge-ai — dropping it (no model server selected)" ;;
            esac ;;
    esac
    for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge headwind attestation-server egress-vpn tor workloadConsole edge-ai edge-ai-analysis edge-ai-tts; do
        _opt_selected "${slug}" && continue
        info "OPTIONAL_SERVICES: '${slug}' NOT selected — pruning it from the baked tree"
        case "${slug}" in
            akkoma)
                rm -f "${apps}/30-akkoma.yaml"
                rm -rf "${tree}/manifests/akkoma"
                rm -f "${tree}/manifests/external-secrets/akkoma-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" akkoma-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" mastodon-oauth mastodon-api mastodon-web
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/api/v1/pleroma/admin/**' '/api/pleroma/admin/**' '/pleroma/admin/**'
                ;;
            tuwunel)
                rm -f "${apps}/30-tuwunel.yaml"
                rm -rf "${tree}/manifests/tuwunel"
                rm -f "${tree}/manifests/external-secrets/tuwunel-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" tuwunel-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" matrix-api matrix-wellknown matrix
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/_matrix/**' '/.well-known/matrix/**' '/_synapse/**'
                # The front door grants the same Matrix surface on its own gateway
                # (20-schema.sql has a second block of /_matrix rows under
                # hugmesh-fe-gateway). Dropping only the be-gateway leg left
                # three live ROLE_MATRIX/MOD/ADMIN grants pointing at a
                # homeserver that is not installed. See #143.
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/_matrix/**' '/.well-known/matrix/**'
                ;;
            phpbb)
                rm -f "${apps}/30-phpbb.yaml" "${apps}/38-forum-bff-db.yaml" \
                      "${apps}/39-forum-bff-api.yaml" "${apps}/49-forum-ui.yaml"
                rm -rf "${tree}/manifests/forum"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" forum-ui hugmesh-forum-bff-api hugmesh-forum-bff-api-moderation
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/social/forum/**' '/bff/forum/admin/**' '/bff/forum/moderation/**' '/bff/forum/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/api/forum/admin/**'
                ;;
            games)
                rm -f "${apps}/06-casdoor-games.yaml" "${apps}/50-games.yaml"
                rm -rf "${tree}/manifests/games" "${tree}/manifests/casdoor-games"
                _opt_drop_route     "${apps}/20-gateway-be.yaml" games
                _opt_drop_extrahost "${apps}/20-gateway-be.yaml" games.
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/games/api/admin/**' '/games/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/games/admin/**'
                # ── GAMES APP-STORE (games-services control plane) — degrade with games ──
                # The app-store rides the games slug (it needs the games namespace up), so
                # deselecting games prunes the WHOLE control plane: the 13c instances
                # ApplicationSet + the games-instances namespace/isolation manifests, the two
                # intersection-sync Jobs (+ their casdoor/kustomization lines), the be-gateway
                # HTTP-console route, and the games-services route-access rows (be + fe).
                rm -f "${apps}/13c-games-instances.yaml"
                rm -rf "${tree}/manifests/games-instances"
                rm -f "${tree}/manifests/casdoor/games-services-admin-sync-job.yaml" \
                      "${tree}/manifests/casdoor/games-services-runner-sync-job.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" games-services-admin-sync-job.yaml
                _opt_drop_kustomize_line "${tree}/manifests/casdoor/kustomization.yaml" games-services-runner-sync-job.yaml
                _opt_drop_route "${apps}/20-gateway-be.yaml" games-servers-console
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/bff/superadmin/games-services/**' '/bff/games-services/instances/**' \
                    '/bff/games-services/catalog/**' '/games/servers/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/admin/games-services/**'
                ;;
            owncast)
                # Owncast live-streaming — GPU-gated x86 service (DEFAULT-OFF). Owns its
                # bootstrap Application + manifests dir + its fe-gateway BFF route-access
                # rows (no gateway HOST route + no per-service ESO today). When deselected
                # the user/admin live-stream panels grey out (installed-services "false").
                rm -f "${apps}/52-owncast.yaml"
                rm -rf "${tree}/manifests/owncast"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" hugmesh-owncast-bff-api
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/bff/owncast/admin/**' '/bff/owncast/**'
                ;;
            character-studio)
                # Character Studio (VN) — FRONTEND micro-frontend remote (DEFAULT-OFF, admin
                # gate). Owns its bootstrap Application + manifests dir + its ONE fe-gateway
                # path route (character-studio-ui) + its ONE route-access row (no gateway
                # HOST + no per-service ESO + no BFF in this slug). When deselected the host
                # greys the /character-studio entry out (installed-services "false").
                rm -f "${apps}/49b-character-studio-ui.yaml"
                rm -rf "${tree}/manifests/character-studio"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" character-studio-ui
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/character-studio/**'
                ;;
            character-forge)
                # Character Forge (3D) — MULTI-APP slug (DEFAULT-OFF, admin gate): BFF db +
                # BFF api + UI remote (phpbb shape). Owns its three bootstrap Applications +
                # three manifest dirs + its TWO fe-gateway path routes (character-forge-ui +
                # hugmesh-character-forge-bff-api) + its TWO route-access rows (no gateway
                # HOST; its ESO secrets ride the SHARED secretstore/pki files like forum-bff's
                # — inert without their consumer pods, so NOT pruned here). When deselected
                # the host greys the /character-forge entry out (installed-services "false").
                # See docs/XR-CHAT.md.
                rm -f "${apps}/38b-character-forge-bff-db.yaml" \
                      "${apps}/39b-character-forge-bff-api.yaml" \
                      "${apps}/49c-character-forge-ui.yaml"
                rm -rf "${tree}/manifests/character-forge" \
                       "${tree}/manifests/character-forge-bff-api" \
                       "${tree}/manifests/character-forge-bff-db"
                _opt_drop_route "${apps}/20-gateway-fe.yaml" character-forge-ui hugmesh-character-forge-bff-api
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/character-forge/**' '/bff/character-forge/**'
                ;;
            tube)
                # LocalTube (YouTube archive) — GPU-gated x86 service (DEFAULT-OFF). Owns
                # its bootstrap Application + manifests dir + its per-service ESO file
                # (tube-externalsecrets.yaml; standalone, not in the ESO kustomization) +
                # its fe/be route-access rows. When deselected the tube panel greys out.
                rm -f "${apps}/53-tube.yaml"
                rm -rf "${tree}/manifests/tube"
                rm -f "${tree}/manifests/external-secrets/tube-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" tube-externalsecrets.yaml
                _opt_drop_route "${apps}/20-gateway-fe.yaml" hugmesh-tube-bff-api tube-content
                _opt_drop_route "${apps}/20-gateway-be.yaml" tube-content
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-fe-gateway \
                    '/bff/tube/**'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/tube/content/**'
                ;;
            egress-vpn)
                # NODE service (not a cluster Application). Prune the per-service
                # NetworkPolicy interaction (file + kustomization line) so no
                # vpn-egress label is ever honoured; the node-package prune + the
                # reconcile service-link SKIP are handled OUTSIDE this loop
                # (filter_node_packages / link_node_services) since they touch the
                # rootfs, not the GitOps tree.
                rm -f "${tree}/manifests/networkpolicy/egress-vpn-interaction.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" egress-vpn-interaction.yaml
                # AND the runtime config-byte DELIVERY half: the (dark) secret-projector
                # overlay + its MANUAL-sync Application. A tree that never selected the VPN
                # must not carry a DaemonSet that writes VPN key bytes onto node hostPaths,
                # even inert — so the whole dir + app go, not just a kustomize line.
                rm -f "${apps}/13e-egress-vpn.yaml"
                rm -rf "${tree}/manifests/egress-vpn"
                ;;
            tor)
                # NODE service (DISTRO tor daemon + a reconcile agent), not a cluster
                # Application. Prune the per-service NetworkPolicy interaction (file +
                # kustomization line) so no tor-onion label is ever honoured; the
                # net-vpn/tor package omission + the service-link SKIP are handled OUTSIDE
                # this loop (they touch the rootfs, not the GitOps tree).
                rm -f "${tree}/manifests/networkpolicy/tor-onion-marked.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/networkpolicy/kustomization.yaml" tor-onion-marked.yaml
                ;;
            workloadConsole)
                # The WORKLOAD CONSOLE is RBAC + route-access + an admin-bff deployment
                # overlay (the BFF endpoints live in the always-present admin-bff).
                # Deselecting it prunes the two-SA RBAC Application + its manifests (so
                # the SA token Secrets are never minted), the two route-access rows (the
                # gateway 404s the whole /bff/{admin,superadmin}/workloads/** prefix),
                # AND the deployment overlay workload-console-patch.yaml + its single
                # kustomization `- path:` line — so the dark admin-bff renders
                # byte-identical to a tree that never had the feature (no
                # WORKLOAD_CONSOLE_* env, no token mounts, Noop k8s seam). Selected, the
                # overlay survives and lights the gate + k8s seam; the DB master flag +
                # TTL'd grants still keep the console dark (docs/OPTIONAL-SERVICES.md
                # §7.2).
                rm -f "${apps}/14-workload-console-rbac.yaml"
                rm -rf "${tree}/manifests/workload-console-rbac"
                rm -f "${tree}/manifests/admin-bff-api/workload-console-patch.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/admin-bff-api/kustomization.yaml" 'path: workload-console-patch.yaml'
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
                ;;
            headwind)
                # Headwind MDM (managed phones) — DEFAULT-OFF, admin-only devops
                # service (Harbor/superadmin posture). Owns its bootstrap Application +
                # manifests dir + per-service ESO file + TWO routes on the EXISTING
                # tailnet superadmin-gateway (NOT be/fe — no gatewayHost of its own)
                # + their route-access rows. When deselected the superadmin console's
                # Headwind entry greys out (installed-services "false").
                rm -f "${apps}/23-headwind.yaml"
                rm -rf "${tree}/manifests/headwind"
                rm -f "${tree}/manifests/external-secrets/headwind-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" headwind-externalsecrets.yaml
                _opt_drop_route "${apps}/22-gateway-superadmin.yaml" headwind-console headwind-checkin
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-superadmin-gateway \
                    '/hmdm/manage/**' '/hmdm/rest/**'
                ;;
            attestation-server)
                # AttestationServer (GrapheneOS Hardware Trust Root) — DEFAULT-OFF,
                # admin-only devops service (Harbor/superadmin posture). Owns its
                # bootstrap Application + manifests dir + per-service ESO file +
                # THREE routes on the EXISTING tailnet superadmin-gateway (NOT be/fe
                # — no gatewayHost of its own) + their route-access rows. When
                # deselected the superadmin console's AttestationServer entry greys
                # out (installed-services "false").
                rm -f "${apps}/24-attestation-server.yaml"
                rm -rf "${tree}/manifests/attestation-server"
                rm -f "${tree}/manifests/external-secrets/attestation-server-externalsecrets.yaml"
                _opt_drop_kustomize_line "${tree}/manifests/external-secrets/kustomization.yaml" attestation-server-externalsecrets.yaml
                _opt_drop_route "${apps}/22-gateway-superadmin.yaml" attestation-auditor attestation-status attestation-console
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-superadmin-gateway \
                    '/attest/auditor/**' '/attest/api/status' '/attest/api/create-account' '/attest/api/**'
                ;;
            edge-ai)
                # Edge-AI GPU inference service (DEFAULT-OFF, GPU-gated). Owns its
                # bootstrap Application + manifests dir + the ai.<domain> be-gateway
                # host route + its /v1/** route-access row. When deselected the AI
                # panels grey out (installed-services "false"). The nvidia-device-plugin
                # (apps/01d) is NOT optional and is never pruned (harmless w/o GPU nodes).
                rm -f "${apps}/54-edge-ai.yaml"
                rm -rf "${tree}/manifests/edge-ai"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/v1/**'
                ;;
            edge-ai-analysis)
                # Task analysis API in front of edge-ai (DEFAULT-OFF, dependsOn edge-ai).
                # Owns app 55 + manifests/edge-ai-analysis + the /v1/analyze/** route +
                # route-access row. Image is a separate build artifact.
                rm -f "${apps}/55-edge-ai-analysis.yaml"
                rm -rf "${tree}/manifests/edge-ai-analysis"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai-analysis
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/v1/analyze/**'
                ;;
            edge-ai-tts)
                # Piper TTS + viseme timeline (VN voice, B3) — DEFAULT-OFF, NO
                # dependsOn (CPU-only, self-contained; unlike edge-ai-analysis it
                # schedules with or without edge-ai). Owns app 55b +
                # manifests/edge-ai-tts + the /v1/synthesize/** route + route-access
                # row. Image is a separate build artifact.
                rm -f "${apps}/55b-edge-ai-tts.yaml"
                rm -rf "${tree}/manifests/edge-ai-tts"
                _opt_drop_route "${apps}/20-gateway-be.yaml" edge-ai-tts
                _opt_drop_rows  "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
                    '/v1/synthesize/**'
                ;;
        esac
    done
    # Edge-AI model library: when edge-ai SURVIVED the selection, patch the
    # edge-ai-models ConfigMap from the --edge-ai-* flags (the model catalog /
    # preload / runtime knobs exposed to the mesh). Each read is ${VAR:-} so a
    # builder that defines NO edge-ai model knobs at all (build-rpi5-stage4.sh
    # has none) takes the empty branch and leaves the ConfigMap byte-identical —
    # the same no-op it was before this library existed.
    if _opt_selected edge-ai; then
        local mc="${tree}/manifests/edge-ai/models-configmap.yaml"
        if [ -f "${mc}" ]; then
            [ -n "${EDGE_AI_RUNTIME:-}" ]       && sed -i -E "s#^(  runtime: ).*#\\1\"${EDGE_AI_RUNTIME}\"#"             "${mc}"
            [ -n "${EDGE_AI_MODELS:-}" ]        && sed -i -E "s#^(  preload: ).*#\\1\"${EDGE_AI_MODELS}\"#"              "${mc}"
            [ -n "${EDGE_AI_MODEL_DEFAULT:-}" ] && sed -i -E "s#^(  default-model: ).*#\\1\"${EDGE_AI_MODEL_DEFAULT}\"#" "${mc}"
            info "Edge-AI model library: runtime=${EDGE_AI_RUNTIME:-<default>} preload='${EDGE_AI_MODELS:-<default>}' default='${EDGE_AI_MODEL_DEFAULT:-<default>}'"
        fi
    fi
    if ! _opt_selected akkoma && ! _opt_selected tuwunel; then
        rm -f "${apps}/45-social-ui.yaml"
        info "OPTIONAL_SERVICES: both homeservers deselected — pruned shared apps/45-social-ui.yaml"
    fi
    # Repair a possible trailing comma if the LAST VALUES row of an INSERT was pruned.
    _opt_fix_trailing_comma "${tree}/manifests/route-access/initdb/20-schema.sql"
    _opt_render_installed_services
    # Seed each per-slug OptionalService CR's `enabled` from the SAME selection so the
    # (dark-by-default) admin-bff OptionalServiceReconciler's desired-state baseline
    # matches this build (a USB built WITHOUT a slug ships its CR enabled:false).
    _opt_render_optionalservice_cr
}

# Fix the dangling trailing comma left when the LAST VALUES row of an INSERT was
# pruned: rewrite the trailing '),' of the final data row before 'ON CONFLICT' to ')'.
_opt_fix_trailing_comma() {
    local f="$1"
    [ -f "${f}" ] || return 0
    awk '
        { lines[NR]=$0 }
        END {
            oc=0
            for (i=NR; i>=1; i--) { if (lines[i] ~ /ON CONFLICT/) { oc=i; break } }
            if (oc>0) {
                for (i=oc-1; i>=1; i--) {
                    if (lines[i] ~ /^[[:space:]]*\(.*\)[[:space:]]*,([[:space:]]*--.*)?$/) {
                        sub(/\)[[:space:]]*,/, ")", lines[i]); break
                    }
                    if (lines[i] ~ /^[[:space:]]*\(.*\)([[:space:]]*--.*)?$/) break
                }
            }
            for (i=1;i<=NR;i++) print lines[i]
        }
    ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
_opt_drop_kustomize_line() {
    local f="$1" res="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+${res}([[:space:]].*)?\$|d" "${f}"
}
_opt_drop_route() {
    local f="$1"; shift
    [ -f "${f}" ] || return 0
    local rid
    for rid in "$@"; do
        awk -v rid="${rid}" '
            BEGIN { skip=0; ind=-1 }
            {
                line=$0
                match(line, /^ */); cur=RLENGTH
                if (skip) {
                    # Stop skipping once we reach ANY non-blank line at or below the
                    # captured item indent — including a comment, since a trailing
                    # comment block at this indent may document the NEXT surviving
                    # route rather than the one being removed (excluding comments
                    # from this check would silently swallow that documentation).
                    if (line !~ /^ *$/ && cur<=ind) { skip=0 }
                    else { next }
                }
                if (line ~ ("^ *- id: " rid "$")) { skip=1; ind=cur; next }
                print line
            }
        ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
    done
}
_opt_drop_extrahost() {
    local f="$1" prefix="$2"
    [ -f "${f}" ] || return 0
    sed -i -E "\\|^[[:space:]]*-[[:space:]]+\"?${prefix}[^[:space:]\"]*\"?[[:space:]]*\$|d" "${f}"
}
_opt_drop_rows() {
    local f="$1" gw="$2"; shift 2
    [ -f "${f}" ] || return 0
    local pat
    for pat in "$@"; do
        awk -v gw="${gw}" -v pat="${pat}" '
            BEGIN { needle = "(\x27" gw "\x27" }
            {
                line=$0
                t=line; sub(/^[[:space:]]+/, "", t)
                if (index(t, needle)==1) {
                    rest=t; sub(/^\([[:space:]]*\x27[^\x27]*\x27[[:space:]]*,[[:space:]]*\x27/, "", rest)
                    q=index(rest, "\x27")
                    if (q>0 && substr(rest,1,q-1)==pat) { next }
                }
                print line
            }
        ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
    done
}
# An operator can EXPLICITLY DESELECT a slug by listing a negative token in
# OPTIONAL_SERVICES / --optional-services: either "-<slug>" or "no-<slug>". This
# is what lets a PROD build turn OFF an otherwise on-by-default service (anubis):
# absence alone cannot mean "off" in prod, since the default list never names
# anubis. The negative token always loses to nothing (it ONLY suppresses an
# implicit default); an explicit positive "<slug>" still wins (handled by the
# caller checking _opt_selected first).
_opt_explicitly_deselected() {
    local s
    for s in ${OPTIONAL_SERVICES}; do
        [ "${s}" = "-$1" ] && return 0
        [ "${s}" = "no-$1" ] && return 0
    done
    return 1
}
# ENV-aware install decision for anubis (the public PoW shield):
#   * explicit positive selection ("anubis" in the list)  => ON  (operator wins)
#   * explicit deselection ("-anubis"/"no-anubis")          => OFF (operator wins)
#   * otherwise: ENV=prod => ON  (all shields up by default in prod)
#               ENV=test => OFF (PoW interstitial off for local/test builds)
# Mirrors the gate_env_apps ENV=prod vs ENV=test split. Echoes "true"/"false".
_opt_anubis_installed() {
    if _opt_selected anubis; then echo "true"; return 0; fi
    if _opt_explicitly_deselected anubis; then echo "false"; return 0; fi
    if [ "${ENV}" = "prod" ]; then echo "true"; else echo "false"; fi
}
# Mirror a slug's install-state into its optional-services ApplicationSet element
# (apps/13a-optional-services.yaml). This COMPLETES the cut-over: the runtime
# `selector` keeps only installed=="true" elements, so rendering the flag from the
# build-time selection makes the 13a generator agree with both the pruned bootstrap
# apps/ tree AND the installed-services ConfigMap — a deselected slug is therefore
# absent from EVERY path (bootstrap seed pruned + 13a element dropped by the
# selector), so a repo-synced ArgoCD can never re-force a deselected service on.
# Idempotent: rewrites only the `installed: "..."` field of the matching `slug:` element.
_opt_render_appset_flag() {
    local slug="$1" val="$2"
    local appset="${SYSROOT}/var/lib/hugmesh/cluster/apps/13a-optional-services.yaml"
    [ -f "${appset}" ] || return 0
    # Match a list element line `- { slug: <slug>, ..., installed: "true|false" }`
    # and rewrite ONLY its installed value (the slug token is the line anchor).
    sed -i -E "s#(\{[[:space:]]*slug:[[:space:]]*${slug}[[:space:]]*,.*installed:[[:space:]]*\")(true|false)(\")#\\1${val}\\3#" "${appset}"
}
_opt_render_installed_services() {
    local cm="${SYSROOT}/var/lib/hugmesh/cluster/manifests/policy/installed-services-configmap.yaml"
    [ -f "${cm}" ] || return 0
    local slug val
    # The base optional services follow plain presence in OPTIONAL_SERVICES.
    for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge headwind attestation-server workloadConsole edge-ai edge-ai-analysis edge-ai-tts; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        sed -i -E "s#^([[:space:]]*)${slug}:[[:space:]]*\"(true|false)\"#\\1${slug}: \"${val}\"#" "${cm}"
        # Mirror the same flag into the optional-services ApplicationSet element so the
        # runtime selector (installed=="true") agrees with the build-time selection: a
        # deselected slug is dropped from BOTH the bootstrap apps/ tree (pruned above)
        # AND the 13a generator list, so a repo-synced ArgoCD never re-forces it on.
        _opt_render_appset_flag "${slug}" "${val}"
    done
    # anubis is ENV-CONDITIONAL (NOT plain presence): the PUBLIC PoW shield is ON
    # by default in PROD ("all shields up") and OFF by default in TEST, unless the
    # operator explicitly selects/deselects it. The optional-services.yaml baseline
    # stays default:off (safe for test); PROD flips it on here.
    val="$(_opt_anubis_installed)"
    sed -i -E "s#^([[:space:]]*)anubis:[[:space:]]*\"(true|false)\"#\\1anubis: \"${val}\"#" "${cm}"
    _opt_render_appset_flag anubis "${val}"
    # Wire/unwire the PUBLIC ingress PoW reroute to match the install decision so
    # the shield is genuinely in-path when installed (idempotent + reversible).
    _opt_wire_anubis_ingress "${val}"
    info "OPTIONAL_SERVICES: rendered installed-services ConfigMap (selected: ${OPTIONAL_SERVICES:-none}; ENV=${ENV}; anubis=${val})"
}
# Flip the `enabled:` value of ONE OptionalService CR (the block whose `slug: <slug>`)
# in the baked seed file. awk anchors on the slug line then rewrites the FIRST enabled
# line after it, preserving indentation (sub only touches the matched substring). The
# end-anchored slug compare keeps edge-ai distinct from edge-ai-analysis/edge-ai-tts.
_opt_set_cr_enabled() {
    local f="$1" slug="$2" val="$3"
    [ -f "${f}" ] || return 0
    awk -v slug="${slug}" -v val="${val}" '
        /^[[:space:]]*slug:[[:space:]]/ {
            s=$0; sub(/^[[:space:]]*slug:[[:space:]]*/,"",s); sub(/[[:space:]]*$/,"",s)
            arm=(s==slug)
        }
        arm && /^[[:space:]]*enabled:[[:space:]]*(true|false)[[:space:]]*$/ {
            sub(/enabled:[[:space:]]*(true|false)/, "enabled: " val); arm=0
        }
        { print }
    ' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}
# Seed the per-slug OptionalService CRs (manifests/optional-services-operator/
# seed-optionalservices.yaml) from the resolved OPTIONAL_SERVICES selection, mirroring
# _opt_render_installed_services above (the CR is the runtime desired-state twin of the
# installed-services ConfigMap boolean). anubis follows the SAME ENV-conditional
# _opt_anubis_installed decision used for the ConfigMap; coturn stays at its false
# baseline (not in the selection loop, matching the ConfigMap).
_opt_render_optionalservice_cr() {
    local seed="${SYSROOT}/var/lib/hugmesh/cluster/manifests/optional-services-operator/seed-optionalservices.yaml"
    [ -f "${seed}" ] || return 0
    local slug val
    for slug in akkoma tuwunel phpbb games owncast tube character-studio character-forge edge-ai edge-ai-analysis edge-ai-tts; do
        if _opt_selected "${slug}"; then val="true"; else val="false"; fi
        _opt_set_cr_enabled "${seed}" "${slug}" "${val}"
    done
    val="$(_opt_anubis_installed)"
    _opt_set_cr_enabled "${seed}" anubis "${val}"
    info "OPTIONAL_SERVICES: seeded OptionalService CR enabled flags (selected: ${OPTIONAL_SERVICES:-none}; anubis=${val})"
}

# Put the Anubis PoW gate genuinely IN FRONT of public ingress when installed.
# The fe-gateway chart renders the public Ingress (host hugmesh.net +
# *.hugmesh.net) with its backend Service overridable via the new
# `ingress.backendServiceName`/`ingress.backendServicePort` values. When Anubis is
# installed we point that Ingress backend at the anubis Service (:8923); Anubis
# forwards verified requests to the fe-gateway (its TARGET=fe-gateway:8080). When
# NOT installed the values stay absent and the Ingress backend defaults to the
# fe-gateway Service (unchanged direct path). IDEMPOTENT (re-derives the two lines
# from $1 every run) and REVERSIBLE (removes them when $1=false). Only the
# fe-gateway Application carries the public web ingress.
_opt_wire_anubis_ingress() {
    local installed="$1"
    local fe="${SYSROOT}/var/lib/hugmesh/cluster/apps/20-gateway-fe.yaml"
    [ -f "${fe}" ] || return 0
    # 1) Always strip any previously-wired override lines + their marker comment
    #    (idempotent reset, so re-running never accumulates duplicates).
    sed -i -E '/^[[:space:]]*# PoW shield UP: route public ingress THROUGH Anubis/d' "${fe}"
    sed -i -E '/^[[:space:]]*backendServiceName:[[:space:]]*anubis[[:space:]]*(#.*)?$/d' "${fe}"
    sed -i -E '/^[[:space:]]*backendServicePort:[[:space:]]*8923[[:space:]]*(#.*)?$/d' "${fe}"
    [ "${installed}" = "true" ] || { info "ENV=${ENV}: Anubis NOT installed — public ingress routes DIRECT to fe-gateway (no PoW reroute)"; return 0; }
    # 2) Insert the override directly under the fe-gateway `ingress:` block's
    #    `enabled: true` line so the chart points the public Ingress backend at the
    #    anubis Service (:8923) instead of the fe-gateway Service. Anubis then
    #    forwards verified traffic to the fe-gateway (TARGET). The indentation
    #    matches the sibling `className:`/`host:` keys (10 spaces under values |).
    awk '
        BEGIN { done=0 }
        {
            print
            if (!done && $0 ~ /^[[:space:]]*ingress:[[:space:]]*$/) { in_ing=1; next }
            if (in_ing && !done && $0 ~ /^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$/) {
                match($0, /^[[:space:]]*/); pad=substr($0,1,RLENGTH)
                print pad "# PoW shield UP: route public ingress THROUGH Anubis (:8923) -> fe-gateway."
                print pad "backendServiceName: anubis"
                print pad "backendServicePort: 8923"
                done=1; in_ing=0
            }
        }
    ' "${fe}" > "${fe}.tmp" && mv "${fe}.tmp" "${fe}"
    info "ENV=${ENV}: Anubis installed — public ingress REROUTED through the Anubis PoW gate (:8923) -> fe-gateway (all shields up)"
}
