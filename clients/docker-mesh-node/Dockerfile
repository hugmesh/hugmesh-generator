# Snapdragon docker mesh-node (FD-09) — a background container that joins the
# Snapdragon tailnet from LOCAL FILE KEYS + a one-line Casdoor login. No OS flash.
# Base = the upstream Tailscale image (ships tailscaled + tailscale, Alpine).
FROM tailscale/tailscale:stable

# bash for the entrypoint, curl+jq for the OIDC device-code Casdoor login.
RUN apk add --no-cache bash curl jq ca-certificates

COPY entrypoint.sh /usr/local/bin/snapdragon-mesh-node
RUN chmod +x /usr/local/bin/snapdragon-mesh-node

# tailscaled state persists in a named volume mounted here (survives restarts so the
# node keeps its identity / approved status).
VOLUME ["/var/lib/tailscale"]

ENTRYPOINT ["/usr/local/bin/snapdragon-mesh-node"]
