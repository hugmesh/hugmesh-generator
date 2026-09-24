# shellcheck shell=bash
# go-live-providers.sh — the PROVIDER REGISTRY for the superadmin go-live wizard.
#
# This is a SOURCEABLE data + emit library, not an executable. The shared driver
# (specs/usr/sbin/hugmesh-go-live) sources it, and every thin front-end (the
# CLI today; ncurses/Studio/web LATER) reaches the providers only THROUGH the
# driver — so this file is the single place that describes "what edge providers
# exist and what each one emits". It mirrors how the rest of the platform keeps
# the reconcile agents' shared logic in /usr/lib/hugmesh/*.sh (domain-verify,
# registry-verify, vpn-verify, storage-verify) rather than inlining it.
#
# A provider is described by a row across the parallel associative arrays below
# (id -> label / mechanism / status / deep-link / emits / public-dns) plus ONE
# emit function `glp_emit_<id>` that renders that provider's artifacts into an
# output dir. The driver NEVER hard-codes a provider; it iterates
# GO_LIVE_PROVIDER_IDS and dispatches to glp_emit "<id>".
#
# SCOPE (all v1 providers now FULLY implemented — the #286 engine wins were
# ported onto this registry during the go-live consolidation):
#   * byo-domain (#2, the no-API baseline that covers EVERYONE): record-set +
#     BIND zone + CSV + registrar deep-links.
#   * cloudflare-tunnel: CNAME record set autofilled at the tunnel + a tunnel-token
#     drop into the keys layout + Zero-Trust deep-links (NO full API driver, by design).
#   * duckdns: a REAL thin DuckDNS / Cloudflare-DDNS single-token updater + a
#     cron.d drop-in, with strict single-label subdomain validation so the emitted
#     ROOT cron script can never be a command-injection sink (ported #286 fix).
#   * tailscale-funnel: tailnet-native funnel exposure guidance (no public DNS).
#   * router-portforward: port-forward instructions + router deep-links (no mutation).
#
# MECHANISM taxonomy (GO_LIVE_MECH):
#   deeplink     — the operator provisions the edge in a vendor dashboard we
#                  deep-link to; we may also emit a token-drop guide (Cloudflare Tunnel).
#   files        — we generate copy-paste + downloadable DNS artifacts (record
#                  set / BIND zone / CSV) the operator applies at their registrar (byo-domain).
#   ddns         — a real thin single-token updater/cron config (DuckDNS, Cloudflare-DDNS).
#   funnel       — tailnet-native public exposure, NO public DNS to mutate (Tailscale/Headscale Funnel).
#   instructions — pure guidance + deep-links, NO mutation (router/port-forward).
#
# CONTEXT the emit functions read (globals the driver sets before calling emit;
# same process, so no export needed — the driver SOURCES this file):
#   GL_DOMAIN        the baked cluster domain (apex), e.g. hugmesh.net
#   GL_INGRESS_IP    IPv4 the public A records should point at (may be empty)
#   GL_INGRESS_IPV6  IPv6 for AAAA records (may be empty)
#   GL_TURN_IP       IPv4 of the coturn RELAY node for turn.<domain> (may be empty
#                    -> falls back to GL_INGRESS_IP). Its own knob because the
#                    relay is a hostNetwork pod on a backend node, which is not
#                    necessarily the ingress node the other records point at.
#   GL_TURN_IPV6     IPv6 twin of GL_TURN_IP (may be empty)
#   GL_TUNNEL_CNAME  a tunnel/ALIAS CNAME target for CNAME-style records (may be empty)
#   GL_TTL           record TTL seconds (default 300)
#   GL_SUBDOMAINS    space-separated service sub-labels to publish (default from the driver)
#   GL_DDNS_SUBDOMAIN the DDNS hostname LABEL (duckdns); a strict single DNS label
#   GL_DDNS_SERVICE  duckdns|cloudflare (duckdns default) — which DDNS updater to render
#   GL_KEYS_DIR      keys-layout root the token drops land under (0600 dests)
#   GL_TOKEN_FILE    optional path to a secret token to store into the keys layout
#                    (read from a FILE only — never passed on argv)
#
# The driver derives GL_SUBDOMAINS as the apex plus api./matrix./mastodon. — the
# SAME hostnames apps/12-cloudflared.yaml + the gateway comments already promise —
# plus `turn` when the node carries /etc/hugmesh/coturn-public (coturn PUBLIC
# mode, docs/COTURN.md §5). turn. is the ONE label that can never ride the HTTP
# edge: see _glp_turn_host / _glp_record_for.

# ── Registry rows ──────────────────────────────────────────────────────────────
# Order here is the PRIORITISED v1 list (flagship first). The driver lists in
# this order.
GO_LIVE_PROVIDER_IDS=(cloudflare-tunnel byo-domain duckdns tailscale-funnel router-portforward tor-onion)

declare -gA GO_LIVE_LABEL=(
    [cloudflare-tunnel]="Cloudflare Tunnel"
    [byo-domain]="Bring-your-own domain / generic registrar"
    [duckdns]="DuckDNS / Cloudflare-DDNS (dynamic IP)"
    [tailscale-funnel]="Tailscale / Headscale Funnel"
    [router-portforward]="Router port-forward"
    [tor-onion]="Tor v3 onion (hidden service)"
)
declare -gA GO_LIVE_MECH=(
    [cloudflare-tunnel]="deeplink"
    [byo-domain]="files"
    [duckdns]="ddns"
    [tailscale-funnel]="funnel"
    [router-portforward]="instructions"
    # onion — NO public DNS, NO public IP, NO open inbound ports: the node's local
    # Tor daemon dials OUT and serves a stable v3 .onion. Reachability comes purely
    # from the `--with-tor` node service (docs/TOR-HIDDEN-SERVICE.md); this provider
    # only surfaces the minted address + how to reach it. Its own mechanism value so
    # front-ends can give it distinct UI (it takes NO inputs — not even a domain).
    [tor-onion]="onion"
)
# full = implemented end-to-end. (stub is retained in the taxonomy for any future
# provider added ahead of its emit; all v1 providers are full.)
declare -gA GO_LIVE_STATUS=(
    [cloudflare-tunnel]="full"
    [byo-domain]="full"
    [duckdns]="full"
    [tailscale-funnel]="full"
    [router-portforward]="full"
    [tor-onion]="full"
)
# Deep-link URL TEMPLATE. {domain} is substituted with GL_DOMAIN by glp_deeplink().
declare -gA GO_LIVE_DEEPLINK=(
    [cloudflare-tunnel]="https://one.dash.cloudflare.com/?to=/:account/networks/tunnels"
    [byo-domain]=""   # registrar-specific; the emit writes a deep-link SET, not one URL
    [duckdns]="https://www.duckdns.org/domains"
    [tailscale-funnel]="https://login.tailscale.com/admin/settings/features"
    [router-portforward]="https://portforward.io/"
    [tor-onion]="https://www.torproject.org/download/"   # get Tor Browser to reach the .onion
)
# One-line human summary of what each provider EMITS / does.
declare -gA GO_LIVE_EMITS=(
    [cloudflare-tunnel]="deep-link to the Zero-Trust Tunnels page + a token-drop guide into keys-template/cloudflared/ + autofilled public hostnames"
    [byo-domain]="a copy-paste record set, a downloadable BIND zone + CSV (A/AAAA/CNAME), and registrar DNS deep-links"
    [duckdns]="a single-token DDNS updater + cron drop-in (no dashboard)"
    [tailscale-funnel]="the tailnet-native funnel enable commands (no public DNS records at all)"
    [router-portforward]="printed port-forward instructions + a deep-link to your gateway/portforward.io (no mutation)"
    [tor-onion]="the node's minted .onion address + Tor Browser reachability card (NO public DNS/IP/ports)"
)
# Does this provider mutate PUBLIC DNS? funnel/router do not (tailnet / NAT only).
declare -gA GO_LIVE_PUBLIC_DNS=(
    [cloudflare-tunnel]="yes"
    [byo-domain]="yes"
    [duckdns]="yes"
    [tailscale-funnel]="no"
    [router-portforward]="no"
)

# ── Registry accessors (front-ends + driver use ONLY these) ──────────────────────
glp_known()      { [ -n "${GO_LIVE_LABEL[$1]:-}" ]; }
glp_label()      { printf '%s' "${GO_LIVE_LABEL[$1]:-$1}"; }
glp_mechanism()  { printf '%s' "${GO_LIVE_MECH[$1]:-instructions}"; }
glp_status()     { printf '%s' "${GO_LIVE_STATUS[$1]:-stub}"; }
glp_emits()      { printf '%s' "${GO_LIVE_EMITS[$1]:-}"; }
glp_public_dns() { printf '%s' "${GO_LIVE_PUBLIC_DNS[$1]:-no}"; }
glp_is_full()    { [ "$(glp_status "$1")" = "full" ]; }
# Deep-link URL with {domain} substituted (empty if the provider has none).
glp_deeplink() {
    local url="${GO_LIVE_DEEPLINK[$1]:-}"
    printf '%s' "${url//\{domain\}/${GL_DOMAIN:-}}"
}

# ── Shared render helpers (reused by byo-domain AND future file/ddns providers) ──
# Emit the concrete public hostnames for the current context. The apex is the
# bare GL_DOMAIN; every other sub-label becomes "<sub>.<domain>".
glp_hostnames() {
    local sub
    for sub in ${GL_SUBDOMAINS:-api matrix mastodon}; do
        if [ "${sub}" = "@" ] || [ "${sub}" = "apex" ]; then
            printf '%s\n' "${GL_DOMAIN}"
        else
            printf '%s.%s\n' "${sub}" "${GL_DOMAIN}"
        fi
    done
}

# Is $1 the coturn PUBLIC-mode TURN hostname? Every provider that renders a
# record set must ask, because turn.<domain> is the ONE hostname that cannot ride
# the HTTP edge (see _glp_record_for).
_glp_turn_host() { [ -n "${GL_DOMAIN:-}" ] && [ "$1" = "turn.${GL_DOMAIN}" ]; }

# The one paragraph every record-emitting provider appends to instructions.txt
# when turn. is in the set — the reason turn.<domain> is shaped differently from
# every other row it just printed.
_glp_turn_note() {
    printf '\nTURN (coturn public mode): turn.%s MUST stay a DIRECT,\n' "${GL_DOMAIN}"
    printf 'UNPROXIED A/AAAA record at the RELAY node — TURN is raw UDP/TCP on\n'
    printf '3478/5349 plus the 49152-49200/udp relay window and cannot ride an HTTP\n'
    printf 'tunnel/CDN proxy. The relay is a hostNetwork pod on a BACKEND node, which\n'
    printf 'need not be the ingress node the other rows point at — name it with\n'
    # %s, not a bare format string: this line STARTS with "--", which printf would
    # eat as an end-of-options marker and then fail with no format argument.
    printf '%s\n' '--turn-ip/--turn-ipv6. Keep /etc/hugmesh/coturn-public present on that'
    printf 'node (hugmesh-coturn-firewall opens the ports). See docs/COTURN.md §5.\n'
}

# Decide the record TYPE + VALUE for a given host, from the available context.
# Preference: an ingress IP -> A (+ AAAA if IPv6 present); else a tunnel CNAME.
# The apex can NOT legally be a CNAME (RFC 1912), so when only a CNAME target is
# available we still emit it but the caller annotates it as ALIAS/ANAME/flatten.
# Sets: _GLP_RTYPE _GLP_RVALUE (and, for A+AAAA, _GLP_RTYPE2 _GLP_RVALUE2).
_glp_record_for() {
    local host="$1" is_apex="$2"
    _GLP_RTYPE=""; _GLP_RVALUE=""; _GLP_RTYPE2=""; _GLP_RVALUE2=""
    # turn.<domain> (coturn PUBLIC mode) is raw UDP/TCP (3478/5349 + the relay
    # window), NOT HTTP: a tunnel CNAME / CDN-proxied record can never carry it,
    # so it is ALWAYS a direct A (+AAAA) at the RELAY node — never the tunnel
    # target, and a distinct placeholder when no relay/ingress IP was given.
    # GL_TURN_IP/GL_TURN_IPV6 are taken as a UNIT: once the operator names the
    # relay node explicitly, the ingress node's AAAA is a different host and must
    # not be pasted under turn.'s owner name.
    if _glp_turn_host "${host}"; then
        local v4 v6
        if [ -n "${GL_TURN_IP:-}" ]; then v4="${GL_TURN_IP}"; v6="${GL_TURN_IPV6:-}"
        else                              v4="${GL_INGRESS_IP:-}"; v6="${GL_INGRESS_IPV6:-}"; fi
        _GLP_RTYPE="A"; _GLP_RVALUE="${v4:-REPLACE_WITH_RELAY_NODE_PUBLIC_IP}"
        if [ -n "${v4}" ] && [ -n "${v6}" ]; then
            _GLP_RTYPE2="AAAA"; _GLP_RVALUE2="${v6}"
        fi
        return 0
    fi
    if [ -n "${GL_INGRESS_IP:-}" ]; then
        _GLP_RTYPE="A"; _GLP_RVALUE="${GL_INGRESS_IP}"
        if [ -n "${GL_INGRESS_IPV6:-}" ]; then _GLP_RTYPE2="AAAA"; _GLP_RVALUE2="${GL_INGRESS_IPV6}"; fi
    elif [ -n "${GL_TUNNEL_CNAME:-}" ]; then
        # Apex CNAME is illegal -> flag ALIAS; sub-labels get a real CNAME.
        if [ "${is_apex}" = "1" ]; then _GLP_RTYPE="ALIAS"; else _GLP_RTYPE="CNAME"; fi
        _GLP_RVALUE="${GL_TUNNEL_CNAME}"
    else
        # No target supplied yet — emit a clearly-marked placeholder so the
        # operator sees the SHAPE and the driver's warning tells them to re-run
        # with --ingress-ip or --tunnel-cname.
        _GLP_RTYPE="A"; _GLP_RVALUE="REPLACE_WITH_INGRESS_IP"
    fi
}

# ── EMIT: byo-domain (#2) — FULLY implemented no-API baseline ────────────────────
# Writes into $1 (an output dir already created by the driver):
#   records.txt          human copy-paste table (name / type / value / TTL)
#   records.csv          name,type,value,ttl,proxied  (spreadsheet / bulk import)
#   <domain>.zone        a syntactically-valid BIND zone (SOA + NS + records) so
#                        `named-checkzone` validates it; the operator can import
#                        it wholesale or copy individual records.
#   deeplinks.txt        deep-links to the common registrars' DNS pages
#   instructions.txt     the step-by-step, incl. the RELEASE_STATE tie-in
glp_emit_byo-domain() {
    local out="$1"
    local ttl="${GL_TTL:-300}"
    local serial; serial="$(date -u +%Y%m%d)01"
    local now;    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # --- records.txt (aligned, copy-paste friendly) ---
    {
        printf '# Go-live DNS record set for %s\n' "${GL_DOMAIN}"
        printf '# Generated %s by hugmesh-go-live (provider: byo-domain).\n' "${now}"
        printf '# Add these at your registrar / DNS host. Apex = the bare domain (host "@").\n'
        if [ -z "${GL_INGRESS_IP:-}" ] && [ -z "${GL_TUNNEL_CNAME:-}" ]; then
            printf '# WARNING: no --ingress-ip / --tunnel-cname given; values are PLACEHOLDERS.\n'
        fi
        printf '#\n'
        printf '%-28s %-6s %-40s %-6s\n' "HOST" "TYPE" "VALUE" "TTL"
        local host is_apex
        while IFS= read -r host; do
            [ "${host}" = "${GL_DOMAIN}" ] && is_apex=1 || is_apex=0
            _glp_record_for "${host}" "${is_apex}"
            printf '%-28s %-6s %-40s %-6s\n' "${host}." "${_GLP_RTYPE}" "${_GLP_RVALUE}" "${ttl}"
            [ -n "${_GLP_RTYPE2}" ] && printf '%-28s %-6s %-40s %-6s\n' "${host}." "${_GLP_RTYPE2}" "${_GLP_RVALUE2}" "${ttl}"
        done < <(glp_hostnames)
    } > "${out}/records.txt"

    # --- records.csv ---
    {
        printf 'name,type,value,ttl,proxied\n'
        local host is_apex
        while IFS= read -r host; do
            [ "${host}" = "${GL_DOMAIN}" ] && is_apex=1 || is_apex=0
            _glp_record_for "${host}" "${is_apex}"
            printf '%s,%s,%s,%s,false\n' "${host}" "${_GLP_RTYPE}" "${_GLP_RVALUE}" "${ttl}"
            [ -n "${_GLP_RTYPE2}" ] && printf '%s,%s,%s,%s,false\n' "${host}" "${_GLP_RTYPE2}" "${_GLP_RVALUE2}" "${ttl}"
        done < <(glp_hostnames)
    } > "${out}/records.csv"

    # --- <domain>.zone : a full, valid BIND zone (SOA + NS + the records) ---
    # Uses relative owner names under $ORIGIN. Apex is "@". The NS/SOA use a
    # conventional ns1/hostmaster placeholder the operator replaces with their
    # registrar's nameservers; the ZONE FILE itself is still valid for
    # named-checkzone to parse.
    {
        printf '$TTL %s\n' "${ttl}"
        printf '$ORIGIN %s.\n' "${GL_DOMAIN}"
        printf '@\tIN\tSOA\tns1.%s. hostmaster.%s. (\n' "${GL_DOMAIN}" "${GL_DOMAIN}"
        printf '\t\t%s\t; serial\n' "${serial}"
        printf '\t\t3600\t; refresh\n'
        printf '\t\t600\t; retry\n'
        printf '\t\t604800\t; expire\n'
        printf '\t\t%s )\t; minimum/negative-cache TTL\n' "${ttl}"
        printf '@\tIN\tNS\tns1.%s.\n' "${GL_DOMAIN}"
        # ns1 glue — placeholder nameserver A so the zone is self-consistent for
        # named-checkzone. Replace ns1 with your registrar's nameservers on import.
        # Only emitted with a real ingress IP (a placeholder value is not a valid A).
        [ -n "${GL_INGRESS_IP:-}" ] && printf 'ns1\tIN\tA\t%s\t; placeholder NS glue — replace with your registrar NS\n' "${GL_INGRESS_IP}"
        printf '; --- service records (edit the target if your registrar differs) ---\n'
        local host owner is_apex
        while IFS= read -r host; do
            if [ "${host}" = "${GL_DOMAIN}" ]; then owner="@"; is_apex=1; else owner="${host%.${GL_DOMAIN}}"; is_apex=0; fi
            _glp_record_for "${host}" "${is_apex}"
            # ALIAS is not a standard BIND RR; emit it commented with an A fallback
            # note so named-checkzone stays happy and the operator sees the intent.
            if [ "${_GLP_RTYPE}" = "ALIAS" ]; then
                printf '; %s -> ALIAS/ANAME %s (apex CNAME is illegal; use your host\x27s CNAME-flattening)\n' "${owner}" "${_GLP_RVALUE}"
                printf '; %s\tIN\tA\t<flattened-ip-of-%s>\n' "${owner}" "${_GLP_RVALUE}"
            else
                printf '%s\tIN\t%s\t%s\n' "${owner}" "${_GLP_RTYPE}" "${_GLP_RVALUE}"
                [ -n "${_GLP_RTYPE2}" ] && printf '%s\tIN\t%s\t%s\n' "${owner}" "${_GLP_RTYPE2}" "${_GLP_RVALUE2}"
            fi
        done < <(glp_hostnames)
    } > "${out}/${GL_DOMAIN}.zone"

    # --- deeplinks.txt : common registrar DNS pages ---
    {
        printf '# Registrar DNS management deep-links (open the one you use):\n'
        printf 'Cloudflare DNS      https://dash.cloudflare.com/?to=/:account/%s/dns\n' "${GL_DOMAIN}"
        printf 'Namecheap           https://ap.www.namecheap.com/domains/domaincontrolpanel/%s/advancedns\n' "${GL_DOMAIN}"
        printf 'GoDaddy             https://dcc.godaddy.com/manage/%s/dns\n' "${GL_DOMAIN}"
        printf 'Porkbun             https://porkbun.com/account/dns/%s\n' "${GL_DOMAIN}"
        printf 'Google/Squarespace  https://domains.squarespace.com/\n'
        printf 'Gandi               https://admin.gandi.net/domain/%s/records\n' "${GL_DOMAIN}"
        printf 'AWS Route 53        https://console.aws.amazon.com/route53/v2/hostedzones\n'
    } > "${out}/deeplinks.txt"

    # --- instructions.txt : the flow + the RELEASE_STATE tie-in ---
    {
        printf 'GO-LIVE — bring-your-own domain (%s)\n' "${GL_DOMAIN}"
        printf '====================================%s\n\n' "$(printf '=%.0s' $(seq 1 ${#GL_DOMAIN}))"
        printf '1. Open your registrar/DNS host (see deeplinks.txt).\n'
        printf '2. Add the records from records.txt (or bulk-import records.csv /\n'
        printf '   %s.zone). Point them at your ingress IP or tunnel CNAME.\n' "${GL_DOMAIN}"
        printf '3. Wait for DNS to propagate (dig +short %s from off-network).\n' "${GL_DOMAIN}"
        printf '4. THEN trip go-live:  hugmesh-go-live commit --provider byo-domain\n'
        printf '     -> writes /etc/hugmesh/go-live; hugmesh-firewall-reconcile\n'
        printf '        flips the host to PUBLIC within 60s (no reboot/reflash).\n'
        printf '     -> add --persist-public to also bake release-state=public so it\n'
        printf '        survives a marker delete.\n'
        printf '5. Rollback:  hugmesh-go-live rollback   (deletes the marker; the\n'
        printf '   firewall re-closes to internal within 60s).\n'
        if [ -z "${GL_INGRESS_IP:-}" ] && [ -z "${GL_TUNNEL_CNAME:-}" ]; then
            printf '\nNOTE: record VALUES are placeholders — re-run with --ingress-ip <IP>\n'
            printf '      or --tunnel-cname <name> to autofill the real targets.\n'
        fi
        case " ${GL_SUBDOMAINS:-} " in *" turn "*) _glp_turn_note ;; esac
    } > "${out}/instructions.txt"

    return 0
}

# ── Shared secret + deep-link helpers (used by the ddns/tunnel emits) ────────────
# Store a token FILE into a 0600 keys-layout destination. The token is read from a
# FILE (never argv); the destination dir is created with a tight umask. Returns
# non-zero on failure so the caller can warn without aborting the whole plan.
_glp_store_token() {
    local src="$1" dest="$2"
    [ -r "${src}" ] || return 1
    ( umask 077 && mkdir -p "$(dirname "${dest}")" ) || return 1
    ( umask 077 && tr -d '\n' < "${src}" > "${dest}" ) || return 1
    chmod 0600 "${dest}" 2>/dev/null || true
    return 0
}

# ── EMIT: cloudflare-tunnel (#1) — CNAME autofill + tunnel-token drop, NO API ────
# Deliberately NOT a full Cloudflare API driver (see docs/GO-LIVE-WIZARD.md): the
# operator creates the tunnel in the Zero-Trust dashboard, we render the exact
# CNAME record set (apex + api./matrix./mastodon. — the SAME hostnames
# apps/12-cloudflared.yaml serves; no *.<domain> wildcard) pointed at the tunnel,
# drop the tunnel token into the keys layout (0600), and deep-link the dashboard.
glp_emit_cloudflare-tunnel() {
    local out="$1"
    local ttl="${GL_TTL:-300}"
    local target="${GL_TUNNEL_CNAME:-<TUNNEL-ID>.cfargotunnel.com}"
    local tokdest="${GL_KEYS_DIR:-/etc/hugmesh/keys}/cloudflared/tunnel-token"
    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # records.csv — Cloudflare bulk-import shape. Cloudflare CNAME-flattens the apex,
    # so a proxied CNAME at "@" is legal here (unlike a generic registrar).
    #
    # turn.<domain> is the EXCEPTION: the tunnel + the orange-cloud proxy are an
    # HTTP(S) edge, and TURN is raw UDP/TCP (3478/5349 + the relay window). A
    # proxied CNAME there advertises a relay address that answers no STUN packet
    # at all, so it is emitted as a DIRECT, UNPROXIED A/AAAA at the relay node —
    # the same rule _glp_record_for enforces for every other provider.
    {
        printf '# %s go-live record set for Cloudflare Tunnel (generated %s).\n' "${GL_DOMAIN}" "${now}"
        printf '# Add at Cloudflare -> DNS -> Records (or let cloudflared create them).\n'
        [ "${target}" = "<TUNNEL-ID>.cfargotunnel.com" ] && \
            printf '# NOTE: no --tunnel-cname given — content is a PLACEHOLDER; re-run with --tunnel-cname <id>.cfargotunnel.com\n'
        printf 'type,name,content,ttl,proxied\n'
        local host
        while IFS= read -r host; do
            if _glp_turn_host "${host}"; then
                _glp_record_for "${host}" 0
                printf '%s,%s,%s,%s,false\n' "${_GLP_RTYPE}" "${host}" "${_GLP_RVALUE}" "${ttl}"
                [ -n "${_GLP_RTYPE2}" ] && printf '%s,%s,%s,%s,false\n' "${_GLP_RTYPE2}" "${host}" "${_GLP_RVALUE2}" "${ttl}"
                continue
            fi
            printf 'CNAME,%s,%s,%s,true\n' "${host}" "${target}" "${ttl}"
        done < <(glp_hostnames)
    } > "${out}/records.csv"

    # hostnames.txt — the autofilled public host set (preview).
    glp_hostnames > "${out}/hostnames.txt"

    # deeplinks.txt — the exact Zero-Trust pages.
    {
        printf '# Cloudflare Tunnel deep-links:\n'
        printf 'Zero Trust: Networks -> Tunnels   https://one.dash.cloudflare.com/?to=/:account/networks/tunnels\n'
        printf 'DNS -> Records (add the CNAMEs)   https://dash.cloudflare.com/?to=/:account/%s/dns\n' "${GL_DOMAIN}"
        printf 'Cloudflare Tunnel docs            https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/\n'
    } > "${out}/deeplinks.txt"

    # token-drop guide (+ optional store if --token-file was supplied).
    {
        printf 'CLOUDFLARE TUNNEL TOKEN\n'
        printf '=======================\n'
        printf 'Create the tunnel in the Zero-Trust dashboard, copy its token, and drop it at:\n'
        printf '  %s   (mode 0600, gitignored keys layout)\n' "${tokdest}"
        printf 'The cloudflared app consumes it via ExternalSecrets -> Vault\n'
        printf '(keys-template/cloudflared/README.md). It is NEVER placed in argv or logs.\n'
    } > "${out}/token-drop.txt"
    if [ -n "${GL_TOKEN_FILE:-}" ]; then
        if _glp_store_token "${GL_TOKEN_FILE}" "${tokdest}"; then
            printf 'go-live[cloudflare-tunnel]: token stored -> %s (0600)\n' "${tokdest}" >&2
        else
            printf 'go-live[cloudflare-tunnel]: WARNING could not store token from %s -> %s\n' "${GL_TOKEN_FILE}" "${tokdest}" >&2
        fi
    fi

    # instructions.txt — the flow + the RELEASE_STATE tie-in.
    {
        printf 'GO-LIVE — Cloudflare Tunnel (%s)\n\n' "${GL_DOMAIN}"
        printf '1. Zero Trust dashboard -> Networks -> Tunnels: create a tunnel, copy the token.\n'
        printf '2. Drop the token at %s (see token-drop.txt).\n' "${tokdest}"
        printf '3. Add the CNAMEs from records.csv (apex + api./matrix./mastodon.) pointing at\n'
        printf '   <tunnel-id>.cfargotunnel.com; cloudflared can also create them for you.\n'
        printf '4. THEN trip go-live:  hugmesh-go-live commit --provider cloudflare-tunnel\n'
        printf '     -> writes /etc/hugmesh/go-live; firewall-reconcile flips PUBLIC within 60s.\n'
        printf '5. Rollback:  hugmesh-go-live rollback\n'
        printf '\nNOTE: cloudflared is pruned from ENV=test images — needs an ENV=prod image.\n'
        case " ${GL_SUBDOMAINS:-} " in *" turn "*) _glp_turn_note ;; esac
    } > "${out}/instructions.txt"
    return 0
}

# ── EMIT: duckdns (#3) — REAL thin DuckDNS / Cloudflare-DDNS updater + cron ───────
# The single genuine API driver kept in v1. Renders a runtime updater that reads
# its token from the keys-layout file (never argv/cron mail) + a cron.d drop-in.
#
# SECURITY (ported verbatim from #286 scripts/go-live.sh:131-142): GL_DDNS_SUBDOMAIN
# is interpolated into the EMITTED root-cron updater, so it MUST be a strict single
# lowercase DNS label BEFORE it is used — a dot/metachar/newline would be a
# command-injection sink as root. We reject it here (registry-side last line of
# defence, in addition to the driver arg-parse), AND the updater body is a QUOTED
# heredoc so no build-time value is expanded into its logic at all; the only
# build-time values are shell-quoted with %q into a short config header.
glp_emit_duckdns() {
    local out="$1"
    local svc="${GL_DDNS_SERVICE:-duckdns}"
    local sub="${GL_DDNS_SUBDOMAIN:-}"
    local domain="${GL_DOMAIN:-}"
    local tokdest="${GL_KEYS_DIR:-/etc/hugmesh/keys}/ddns/token"

    case "${svc}" in
        duckdns|cloudflare) ;;
        *) printf 'go-live[duckdns]: --ddns-service must be duckdns or cloudflare\n' >&2; return 1 ;;
    esac
    if [ -n "${sub}" ] && ! [[ "${sub}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        printf 'go-live[duckdns]: --ddns-subdomain must be a single lowercase DNS label ([a-z0-9-], 1-63 chars, no dots)\n' >&2
        return 1
    fi

    local fqdn
    case "${svc}" in
        duckdns)    fqdn="${sub:-<subdomain>}.duckdns.org" ;;
        cloudflare) fqdn="${sub:-<subdomain>}.${domain:-<domain>}" ;;
    esac

    local updater="${out}/ddns-update.sh" cron="${out}/ddns.cron"

    # Updater: validated config header (shell-quoted with %q) + a fully-QUOTED
    # heredoc body (nothing build-time interpolates into the script logic).
    {
        printf '#!/usr/bin/env bash\n'
        printf '# ddns-update.sh — emitted by hugmesh-go-live (provider duckdns, service %s).\n' "${svc}"
        printf '# Re-points %s at the current public IP. The token is read from the keys-layout\n' "${fqdn}"
        printf '# file at RUNTIME — never baked into this script, argv, or cron mail.\n'
        printf 'set -uo pipefail\n'
        printf 'SERVICE=%q\n' "${svc}"
        printf 'SUBDOMAIN=%q\n' "${sub}"
        printf 'DOMAIN=%q\n' "${domain}"
        # tokdest carries GL_KEYS_DIR (operator --keys-dir). It MUST be shell-quoted
        # with %q like the siblings above — but %q-escaping is NOT re-parsed inside a
        # double-quoted ${DDNS_TOKEN_FILE:-...} default, so a %s there let a hostile
        # --keys-dir='$(cmd)' inject a command substitution that fires as root the
        # first time the cron updater dereferences ${TOKEN_FILE}. Emit the default as
        # its own %q assignment (unquoted RHS, where %q IS honoured), then reference it.
        printf 'DDNS_TOKEN_FILE_DEFAULT=%q\n' "${tokdest}"
        printf 'TOKEN_FILE="${DDNS_TOKEN_FILE:-${DDNS_TOKEN_FILE_DEFAULT}}"\n'
        cat <<'UPDATER'
[ -r "${TOKEN_FILE}" ] || { echo "ddns-update: token file not readable: ${TOKEN_FILE}" >&2; exit 1; }
[ -n "${SUBDOMAIN}" ]  || { echo "ddns-update: SUBDOMAIN empty — re-emit with --ddns-subdomain" >&2; exit 1; }
TOK="$(tr -d '\n' < "${TOKEN_FILE}")"
case "${SERVICE}" in
    duckdns)
        # Empty ip= => DuckDNS uses the request's source address. -K - keeps the
        # token OUT of argv (visible in /proc/<pid>/cmdline).
        printf 'url = "https://www.duckdns.org/update?domains=%s&token=%s&ip="\n' "${SUBDOMAIN}" "${TOK}" \
            | curl -sS -m 20 -K - ;;
    cloudflare)
        command -v jq >/dev/null 2>&1 || { echo "ddns-update: jq required for cloudflare" >&2; exit 1; }
        HDR="$(umask 077 && mktemp)"; trap 'rm -f "${HDR}"' EXIT
        printf 'Authorization: Bearer %s\n' "${TOK}" > "${HDR}"
        IP="$(curl -sS -m 20 https://api.ipify.org)" || exit 1
        ZID="$(curl -sS -m 20 -H @"${HDR}" "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" | jq -r '.result[0].id // empty')"
        [ -n "${ZID}" ] || { echo "ddns-update: no Cloudflare zone for ${DOMAIN}" >&2; exit 1; }
        FQDN="${SUBDOMAIN}.${DOMAIN}"
        RID="$(curl -sS -m 20 -H @"${HDR}" "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records?type=A&name=${FQDN}" | jq -r '.result[0].id // empty')"
        BODY="$(jq -nc --arg n "${FQDN}" --arg ip "${IP}" '{type:"A",name:$n,content:$ip,ttl:300,proxied:false}')"
        if [ -n "${RID}" ]; then
            curl -sS -m 20 -X PUT  -H @"${HDR}" -H 'Content-Type: application/json' -d "${BODY}" \
                "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records/${RID}" >/dev/null
        else
            curl -sS -m 20 -X POST -H @"${HDR}" -H 'Content-Type: application/json' -d "${BODY}" \
                "https://api.cloudflare.com/client/v4/zones/${ZID}/dns_records" >/dev/null
        fi ;;
esac
UPDATER
    } > "${updater}" || return 1
    chmod 0755 "${updater}" 2>/dev/null || true

    {
        printf '# %s DDNS refresh — install as /etc/cron.d/hugmesh-ddns (with the emitted\n' "${fqdn}"
        printf '# ddns-update.sh at /usr/local/sbin/hugmesh-ddns-update). 5-minute floor,\n'
        printf '# mirroring the hugmesh-*-reconcile cron convention.\n'
        printf '*/5 * * * * root /usr/local/sbin/hugmesh-ddns-update >/dev/null 2>&1\n'
    } > "${cron}" || return 1

    {
        printf '# Dynamic-DNS deep-links:\n'
        printf 'DuckDNS (subdomain + token)   https://www.duckdns.org/\n'
        printf 'Cloudflare API Tokens         https://dash.cloudflare.com/profile/api-tokens\n'
        printf 'DuckDNS update-endpoint spec  https://www.duckdns.org/spec.jsp\n'
    } > "${out}/deeplinks.txt"

    # Optional token store (only when a --token-file was supplied).
    if [ -n "${GL_TOKEN_FILE:-}" ]; then
        if _glp_store_token "${GL_TOKEN_FILE}" "${tokdest}"; then
            printf 'go-live[duckdns]: token stored -> %s (0600)\n' "${tokdest}" >&2
        else
            printf 'go-live[duckdns]: WARNING could not store token from %s -> %s\n' "${GL_TOKEN_FILE}" "${tokdest}" >&2
        fi
    fi

    {
        printf 'GO-LIVE — Dynamic DNS (%s, service %s)\n\n' "${fqdn}" "${svc}"
        printf '1. %s: create the hostname + copy the token (see deeplinks.txt).\n' \
            "$([ "${svc}" = duckdns ] && echo 'DuckDNS' || echo 'Cloudflare (zone-scoped API token, Zone.DNS Edit)')"
        printf '2. Drop the token at %s (0600).\n' "${tokdest}"
        printf '3. Install the updater:  cp ddns-update.sh /usr/local/sbin/hugmesh-ddns-update\n'
        printf '   and the cron.d snippet:  cp ddns.cron /etc/cron.d/hugmesh-ddns\n'
        printf '4. THEN trip go-live:  hugmesh-go-live commit --provider duckdns\n'
        printf '     -> writes /etc/hugmesh/go-live; firewall-reconcile flips PUBLIC within 60s.\n'
        printf '5. Rollback:  hugmesh-go-live rollback\n'
        [ -z "${sub}" ] && printf '\nNOTE: no --ddns-subdomain given — the updater will refuse until re-emitted with one.\n'
    } > "${out}/instructions.txt"
    return 0
}

# ── EMIT: tailscale-funnel (#4) — tailnet-native exposure, NO public DNS ──────────
glp_emit_tailscale-funnel() {
    local out="$1"
    {
        printf '# Tailscale Funnel deep-links:\n'
        printf 'Enable HTTPS + Funnel (features)  https://login.tailscale.com/admin/settings/features\n'
        printf 'ACLs (grant the funnel attribute) https://login.tailscale.com/admin/acls\n'
        printf 'Tailscale Funnel docs             https://tailscale.com/kb/1223/funnel\n'
    } > "${out}/deeplinks.txt"
    {
        printf 'GO-LIVE — Tailscale Funnel (%s)\n\n' "${GL_DOMAIN}"
        printf 'Tailnet-native public HTTPS with NO public DNS records, NO public IP, and NO\n'
        printf 'open inbound ports — the node is published on its <node>.<tailnet>.ts.net name.\n\n'
        printf '1. Admin -> Settings -> Features: enable HTTPS certificates + Funnel for the tailnet.\n'
        printf '2. Admin -> ACLs: grant this node the funnel node-attribute.\n'
        printf '3. On the node, expose the ingress:\n'
        printf '     tailscale funnel 443 on          # publish the local HTTPS ingress\n'
        printf '     tailscale funnel status          # confirm it is live\n'
        printf '4. THEN trip go-live:  hugmesh-go-live commit --provider tailscale-funnel\n'
        printf '     -> writes /etc/hugmesh/go-live; firewall-reconcile flips PUBLIC within 60s.\n'
        printf '5. Rollback:  hugmesh-go-live rollback   (and: tailscale funnel 443 off)\n\n'
        printf 'CAVEAT: Funnel is a TAILSCALE-HOSTED control-plane feature. The default HugMesh\n'
        printf 'mesh is self-hosted headscale, which does NOT implement Funnel — this applies only\n'
        printf 'to nodes joined to tailscale.com. Behind CGNAT this is often the ONLY option.\n'
        printf 'The public name is <node>.<tailnet>.ts.net, not %s — pair with byo-domain for a\n' "${GL_DOMAIN:-your-domain}"
        printf 'vanity CNAME if you want your brand name in front of it.\n'
    } > "${out}/instructions.txt"
    return 0
}

# ── EMIT: router-portforward (#5) — instructions + deep-links, NO mutation ────────
glp_emit_router-portforward() {
    local out="$1"
    {
        printf '# Router / gateway deep-links:\n'
        printf 'Common router admin (192.168.1.1)  http://192.168.1.1/\n'
        printf 'Common router admin (192.168.0.1)  http://192.168.0.1/\n'
        printf 'Per-vendor port-forward guides     https://portforward.com/router.htm\n'
    } > "${out}/deeplinks.txt"
    {
        printf 'GO-LIVE — Router port-forward (%s)\n\n' "${GL_DOMAIN}"
        printf 'Direct exposure by forwarding WAN 80/443 to the ingress node. This wizard NEVER\n'
        printf 'touches the router (no UPnP, no admin-API drivers) — instructions only.\n\n'
        printf '1. Give the ingress node a STATIC LAN IP (DHCP reservation on the router).\n'
        printf '2. Router admin (see deeplinks.txt) -> Port Forwarding: forward\n'
        printf '     WAN TCP 80  -> <ingress-node-LAN-IP>:80\n'
        printf '     WAN TCP 443 -> <ingress-node-LAN-IP>:443\n'
        printf '3. Point a public name at your WAN IP: use the byo-domain provider (static IP)\n'
        printf '   or duckdns (dynamic IP) so a hostname actually resolves to the forwarded IP.\n'
        printf '4. THEN trip go-live:  hugmesh-go-live commit --provider router-portforward\n'
        printf '     -> writes /etc/hugmesh/go-live; firewall-reconcile flips PUBLIC within 60s.\n'
        printf '5. Rollback:  hugmesh-go-live rollback   (and remove the port-forward rules)\n\n'
        printf 'CAVEAT: behind CGNAT (no reachable public WAN IP) port-forwarding cannot work —\n'
        printf 'use cloudflare-tunnel or tailscale-funnel instead.\n'
    } > "${out}/instructions.txt"
    return 0
}

# ── EMIT: tor-onion (#6) — v3 hidden service, NO public DNS/IP/ports ──────────────
# The onion is served by the node's OWN Tor daemon (the `tor` optional service,
# docs/TOR-HIDDEN-SERVICE.md): the hugmesh-tor-reconcile agent mints + PERSISTS
# the v3 keypair off-git under /var/lib/tor/hugmesh-onion and EXPORTS the public
# hostname to /var/lib/hugmesh/tor/hostname. This provider does NOT mint anything
# and touches NO public edge — it reads that exported hostname (when present) and
# renders the reachability card + Tor Browser guidance. Unlike every other provider,
# reachability is INDEPENDENT of the go-live marker: the onion is live whenever the
# node's tor service is running, with no ports opened. GL_ONION_HOSTNAME overrides
# the file (e.g. a from-a-dev-box preview, or a node queried over the mesh).
#
# WHAT THE NODE PUBLISHES (hugmesh-generator#583 — this card used to say :80/http,
# which a node never served): every onion is `HiddenServicePort 443 -> <upstream>`,
# i.e. HTTPS on the onion's :443, answered by the node's hostNetwork ingress edge with
# a certificate that does NOT carry the .onion name (no onion SAN is minted anywhere),
# so Tor Browser shows a certificate warning the visitor must accept. <upstream>
# defaults to 127.0.0.1:443, which is right only on the node running that edge — the
# hugmesh.net/pki node under RELEASE_STATE=internal (the default), the
# hugmesh.net/backend node once public — and is overridden per node by
# /etc/hugmesh/tor/upstream. KNOWN GAP (hugmesh-generator#614): the fe-gateway Ingress
# does not admit an onion Host yet, so on a hardware node the onion answers
# ingress-nginx's 404, not the login page; the card says so. (The COMPOSE lane's onion
# is different — tests/stack/tor — and is not what this node-side card describes.)
# Per-domain onions (decision 68 = A) are exported beside the primary as
# <slug>.hostname; GL_ONION_EXPORT_DIR overrides that directory.
_GLP_ONION_EXPORT_DIR="${GL_ONION_EXPORT_DIR:-/var/lib/hugmesh/tor}"
_GLP_ONION_HOSTNAME_FILES=("${_GLP_ONION_EXPORT_DIR}/hostname" /var/lib/tor/hugmesh-onion/hostname)
_glp_onion_hostname() {
    if [ -n "${GL_ONION_HOSTNAME:-}" ]; then printf '%s' "${GL_ONION_HOSTNAME}"; return 0; fi
    local f
    for f in "${_GLP_ONION_HOSTNAME_FILES[@]}"; do
        if [ -r "${f}" ]; then tr -d '[:space:]' < "${f}"; return 0; fi
    done
    return 1
}
# _glp_onion_domains — "<slug> <onion>" per exported per-domain hostname, sorted.
_glp_onion_domains() {
    local f slug addr
    for f in "${_GLP_ONION_EXPORT_DIR}"/*.hostname; do
        [ -r "${f}" ] || continue
        slug="$(basename "${f}" .hostname)"
        addr="$(tr -d '[:space:]' < "${f}")"
        [ -n "${addr}" ] && printf '%s %s\n' "${slug}" "${addr}"
    done | sort
}
glp_emit_tor-onion() {
    local out="$1"
    local onion=""
    local domains=""
    onion="$(_glp_onion_hostname || true)"
    domains="$(_glp_onion_domains || true)"

    # onion.txt — the address itself (the ONLY artifact that ever leaves the node).
    {
        if [ -n "${onion}" ]; then
            printf '%s\n' "${onion}"
        else
            printf '# NOT-YET-MINTED — no exported hostname found on THIS host.\n'
            printf '# The v3 .onion is minted on the NODE at first boot by\n'
            printf '# hugmesh-tor-reconcile (needs the `tor` optional service baked:\n'
            printf '# build with --with-tor). Read it ON THE NODE with:\n'
            printf '#   cat /var/lib/hugmesh/tor/hostname\n'
            printf '# then re-run this plan there, or pass GL_ONION_HOSTNAME=<addr>.\n'
        fi
    } > "${out}/onion.txt"

    # domain-onions.txt — one "<domain slug> <onion>" line per Tor domain this node
    # serves (decision 68 = A); absent when the node serves only the primary onion.
    if [ -n "${domains}" ]; then
        printf '%s\n' "${domains}" > "${out}/domain-onions.txt"
    fi

    # deeplinks.txt — how a visitor reaches a .onion.
    {
        printf '# Reaching a .onion (share these with your visitors):\n'
        printf 'Download Tor Browser        https://www.torproject.org/download/\n'
        printf 'What is an onion service    https://community.torproject.org/onion-services/\n'
        printf 'Onion-Location / verifying  https://support.torproject.org/onionservices/\n'
    } > "${out}/deeplinks.txt"

    # instructions.txt — the flow + the posture note (this is the DIFFERENT one).
    {
        printf 'GO-LIVE — Tor v3 onion (hidden service)\n'
        printf '=======================================\n\n'
        printf 'INBOUND reachability with NO public IP, NO public DNS, NO open ports, and\n'
        printf "NO Cloudflare. The node's own Tor daemon dials OUT to the Tor network and\n"
        printf 'publishes the in-cluster fe-gateway as a STABLE v3 .onion.\n\n'
        if [ -n "${onion}" ]; then
            printf 'Your address:  %s\n' "${onion}"
            printf 'Open it:       Tor Browser -> https://%s/\n\n' "${onion}"
        else
            printf 'Your address:  (minted on the node — see onion.txt)\n\n'
        fi
        if [ -n "${domains}" ]; then
            printf 'Per-domain onions (each its own address, the SAME gateway; see\n'
            printf 'domain-onions.txt):\n'
            printf '%s\n' "${domains}" | while read -r _d _a; do
                printf '  %-20s https://%s/\n' "${_d}" "${_a}"
            done
            printf '\n'
        fi
        printf 'CERTIFICATE: the onion serves HTTPS on :443 with the ingress edge'"'"'s\n'
        printf '  certificate — no .onion name is on it — so Tor Browser warns once per\n'
        printf '  visitor. The Tor circuit itself is end-to-end encrypted and the .onion\n'
        printf '  address authenticates the service; accepting the warning is expected.\n\n'
        printf 'KNOWN GAP (hugmesh-generator#614): the gateway Ingress does not admit a\n'
        printf '  .onion Host yet, so today the onion reaches the ingress edge and gets its\n'
        printf '  404 — NOT the login page. Until #614 lands, the onion proves the Tor path\n'
        printf '  (circuit, key custody, torrc, edge) but does not serve the mesh.\n\n'

        printf 'PREREQUISITE (the reachability, not this wizard, comes from it):\n'
        printf '  1. Build the node image with the `tor` service:  --with-tor\n'
        printf '     (Studio: Network & services -> "Tor v3 onion service"; or add `tor`\n'
        printf '      to OPTIONAL_SERVICES / brand.conf). It is a NODE service, DEFAULT-OFF,\n'
        printf '      and a no-op on CLIENT/standalone-desktop roles.\n'
        printf '  2. On first boot hugmesh-tor-reconcile mints + PERSISTS the v3 keypair\n'
        printf '     under /var/lib/tor/hugmesh-onion (off-git, never a Secret) and writes\n'
        printf '     /etc/tor/torrc mapping the onion :443 (HTTPS) -> the ingress edge\n'
        printf '     (127.0.0.1:443 by default — right ONLY on the node running that edge:\n'
        printf '      the pki node under release-state internal (the default), the backend\n'
        printf '      node once public, either on omnibus. On any other node, or a host tor\n'
        printf '      fronting kind (127.0.0.1:8443), write one host:port line to\n'
        printf '      /etc/hugmesh/tor/upstream).\n'
        printf '  3. The .onion is then published — Tor Browser reaches the ingress edge\n'
        printf '     (see KNOWN GAP above for what answers there today).\n\n'
        printf 'POSTURE — this is the one provider that does NOT need the public flip:\n'
        printf '  The onion works with the firewall CLOSED (release-state internal). You do\n'
        printf '  NOT need `hugmesh-go-live commit` to be reachable over Tor. Commit only\n'
        printf '  if you ALSO want a clearnet edge (byo-domain/tunnel/funnel) live alongside\n'
        printf '  the onion — for Tor-only exposure, leave the host internal and just share\n'
        printf '  the .onion. (rollback/commit never touch the onion either way.)\n\n'
        printf 'VERIFY (from any machine with Tor):\n'
        printf '  torsocks curl -skI https://%s/    # answers over Tor (-k: no onion SAN;\n' "${onion:-<your-onion>}"
        printf '                                       # 404 from the edge until #614 lands)\n'
        printf '  # or just open it in Tor Browser.\n'
    } > "${out}/instructions.txt"
    return 0
}

# ── Dispatch: driver calls this ONLY ─────────────────────────────────────────────
# Renders provider $1's artifacts into dir $2. Returns non-zero on an unknown id.
glp_emit() {
    local id="$1" out="$2"
    glp_known "${id}" || return 2
    "glp_emit_${id}" "${out}"
}
