# shellcheck shell=bash
# go-live-providers.sh — the PROVIDER REGISTRY for the superadmin go-live wizard.
#
# This is a SOURCEABLE data + emit library, not an executable. The shared driver
# (specs/usr/sbin/snapdragon-go-live) sources it, and every thin front-end (the
# CLI today; ncurses/Studio/web LATER) reaches the providers only THROUGH the
# driver — so this file is the single place that describes "what edge providers
# exist and what each one emits". It mirrors how the rest of the platform keeps
# the reconcile agents' shared logic in /usr/lib/snapdragon/*.sh (domain-verify,
# registry-verify, vpn-verify, storage-verify) rather than inlining it.
#
# A provider is described by a row across the parallel associative arrays below
# (id -> label / mechanism / status / deep-link / emits / public-dns) plus ONE
# emit function `glp_emit_<id>` that renders that provider's artifacts into an
# output dir. The driver NEVER hard-codes a provider; it iterates
# GO_LIVE_PROVIDER_IDS and dispatches to glp_emit "<id>".
#
# v1 SCOPE (deliberate — see docs/GO-LIVE-WIZARD.md):
#   * byo-domain (#2, the no-API baseline that covers EVERYONE) is FULLY
#     implemented: record-set + BIND zone + CSV + registrar deep-links.
#   * cloudflare-tunnel / duckdns / tailscale-funnel / router-portforward are
#     STUBS: real registry rows (label/mechanism/deep-link) + an emit that
#     writes a clearly-marked TODO placeholder, so the framework is exercised
#     end-to-end by at least one real provider while the others are visible,
#     selectable, and honestly labelled "(stub)".
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
#   GL_DOMAIN        the baked cluster domain (apex), e.g. snapdragon.systems
#   GL_INGRESS_IP    IPv4 the public A records should point at (may be empty)
#   GL_INGRESS_IPV6  IPv6 for AAAA records (may be empty)
#   GL_TUNNEL_CNAME  a tunnel/ALIAS CNAME target for CNAME-style records (may be empty)
#   GL_TTL           record TTL seconds (default 300)
#   GL_SUBDOMAINS    space-separated service sub-labels to publish (default from the driver)
#
# The driver derives GL_SUBDOMAINS as the apex plus api./matrix./mastodon. — the
# SAME hostnames apps/12-cloudflared.yaml + the gateway comments already promise.

# ── Registry rows ──────────────────────────────────────────────────────────────
# Order here is the PRIORITISED v1 list (flagship first). The driver lists in
# this order.
GO_LIVE_PROVIDER_IDS=(cloudflare-tunnel byo-domain duckdns tailscale-funnel router-portforward)

declare -gA GO_LIVE_LABEL=(
    [cloudflare-tunnel]="Cloudflare Tunnel"
    [byo-domain]="Bring-your-own domain / generic registrar"
    [duckdns]="DuckDNS / Cloudflare-DDNS (dynamic IP)"
    [tailscale-funnel]="Tailscale / Headscale Funnel"
    [router-portforward]="Router port-forward"
)
declare -gA GO_LIVE_MECH=(
    [cloudflare-tunnel]="deeplink"
    [byo-domain]="files"
    [duckdns]="ddns"
    [tailscale-funnel]="funnel"
    [router-portforward]="instructions"
)
# full  = implemented end-to-end in v1.  stub = registry row + TODO placeholder emit.
declare -gA GO_LIVE_STATUS=(
    [cloudflare-tunnel]="stub"
    [byo-domain]="full"
    [duckdns]="stub"
    [tailscale-funnel]="stub"
    [router-portforward]="stub"
)
# Deep-link URL TEMPLATE. {domain} is substituted with GL_DOMAIN by glp_deeplink().
declare -gA GO_LIVE_DEEPLINK=(
    [cloudflare-tunnel]="https://one.dash.cloudflare.com/?to=/:account/networks/tunnels"
    [byo-domain]=""   # registrar-specific; the emit writes a deep-link SET, not one URL
    [duckdns]="https://www.duckdns.org/domains"
    [tailscale-funnel]="https://login.tailscale.com/admin/settings/features"
    [router-portforward]="https://portforward.io/"
)
# One-line human summary of what each provider EMITS / does.
declare -gA GO_LIVE_EMITS=(
    [cloudflare-tunnel]="deep-link to the Zero-Trust Tunnels page + a token-drop guide into keys-template/cloudflared/ + autofilled public hostnames"
    [byo-domain]="a copy-paste record set, a downloadable BIND zone + CSV (A/AAAA/CNAME), and registrar DNS deep-links"
    [duckdns]="a single-token DDNS updater + cron drop-in (no dashboard)"
    [tailscale-funnel]="the tailnet-native funnel enable commands (no public DNS records at all)"
    [router-portforward]="printed port-forward instructions + a deep-link to your gateway/portforward.io (no mutation)"
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

# Decide the record TYPE + VALUE for a given host, from the available context.
# Preference: an ingress IP -> A (+ AAAA if IPv6 present); else a tunnel CNAME.
# The apex can NOT legally be a CNAME (RFC 1912), so when only a CNAME target is
# available we still emit it but the caller annotates it as ALIAS/ANAME/flatten.
# Sets: _GLP_RTYPE _GLP_RVALUE (and, for A+AAAA, _GLP_RTYPE2 _GLP_RVALUE2).
_glp_record_for() {
    local host="$1" is_apex="$2"
    _GLP_RTYPE=""; _GLP_RVALUE=""; _GLP_RTYPE2=""; _GLP_RVALUE2=""
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
        printf '# Generated %s by snapdragon-go-live (provider: byo-domain).\n' "${now}"
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
        printf '4. THEN trip go-live:  snapdragon-go-live commit --provider byo-domain\n'
        printf '     -> writes /etc/snapdragon/go-live; snapdragon-firewall-reconcile\n'
        printf '        flips the host to PUBLIC within 60s (no reboot/reflash).\n'
        printf '     -> add --persist-public to also bake release-state=public so it\n'
        printf '        survives a marker delete.\n'
        printf '5. Rollback:  snapdragon-go-live rollback   (deletes the marker; the\n'
        printf '   firewall re-closes to internal within 60s).\n'
        if [ -z "${GL_INGRESS_IP:-}" ] && [ -z "${GL_TUNNEL_CNAME:-}" ]; then
            printf '\nNOTE: record VALUES are placeholders — re-run with --ingress-ip <IP>\n'
            printf '      or --tunnel-cname <name> to autofill the real targets.\n'
        fi
    } > "${out}/instructions.txt"

    return 0
}

# ── EMIT: STUBS (registry rows are real; emit is a marked TODO placeholder) ──────
# Each stub still produces a file so the framework is exercised uniformly and the
# operator gets the deep-link + a precise description of the follow-up PR's job.
_glp_emit_stub() {
    local id="$1" out="$2"
    {
        printf 'PROVIDER: %s  (%s)\n' "$(glp_label "${id}")" "${id}"
        printf 'STATUS:   STUB — not implemented in the go-live wizard v1 foundation.\n'
        printf 'MECHANISM: %s\n' "$(glp_mechanism "${id}")"
        printf 'WOULD EMIT: %s\n' "$(glp_emits "${id}")"
        local dl; dl="$(glp_deeplink "${id}")"
        [ -n "${dl}" ] && printf 'DEEP-LINK: %s\n' "${dl}"
        printf 'DOMAIN:    %s\n' "${GL_DOMAIN}"
        printf '\nTODO(go-live v2): implement glp_emit_%s in\n' "${id}"
        printf '  specs/usr/lib/snapdragon/go-live-providers.sh. See docs/GO-LIVE-WIZARD.md\n'
        printf '  for the per-provider spec. The shared driver + commit gate already work;\n'
        printf '  only this provider\x27s artifact emit is outstanding.\n'
    } > "${out}/STUB-${id}.txt"
    return 0
}
glp_emit_cloudflare-tunnel()  { _glp_emit_stub cloudflare-tunnel  "$1"; }
glp_emit_duckdns()            { _glp_emit_stub duckdns            "$1"; }
glp_emit_tailscale-funnel()   { _glp_emit_stub tailscale-funnel   "$1"; }
glp_emit_router-portforward() { _glp_emit_stub router-portforward "$1"; }

# ── Dispatch: driver calls this ONLY ─────────────────────────────────────────────
# Renders provider $1's artifacts into dir $2. Returns non-zero on an unknown id.
glp_emit() {
    local id="$1" out="$2"
    glp_known "${id}" || return 2
    "glp_emit_${id}" "${out}"
}
