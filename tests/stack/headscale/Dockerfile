# hugmesh-headscale — the local docker mesh's tailnet control server (OPT-IN,
# `make stack-up HEADSCALE=1`, compose profile `headscale`).
#
# The binary is the fleet pin, headscale 0.23.0 (the same release the node image
# ships and specs/etc/headscale/config.yaml is tested against), copied out of the
# upstream image. That image is distroless (no shell), and the entrypoint here
# renders the config and the device policy, creates the `hugmesh` user and keeps
# admin-bff's API key, so it needs a shell, jq and coreutils: alpine, the same
# base as ./tor. The upstream binary is static, so it runs on musl unchanged.
# Both images are multi-arch (amd64/arm64/arm), so no platform pin: it runs native
# on Linux docker, Docker Desktop and arm64 hosts.
FROM headscale/headscale:0.23.0 AS hs

FROM alpine:3.20
RUN apk add --no-cache bash jq ca-certificates
COPY --from=hs /ko-app/headscale /usr/local/bin/headscale
COPY config.yaml.tmpl /etc/hugmesh/headscale/config.yaml.tmpl
COPY entrypoint.sh /usr/local/bin/hugmesh-headscale-entrypoint
RUN chmod 0755 /usr/local/bin/hugmesh-headscale-entrypoint \
 && mkdir -p /etc/headscale /var/lib/headscale /run/headscale /run/hugmesh-headscale
# Runs as root: it writes the API key into a volume admin-bff mounts read-only,
# and headscale itself binds only the in-network :8080 and the unix socket.
ENTRYPOINT ["/usr/local/bin/hugmesh-headscale-entrypoint"]
