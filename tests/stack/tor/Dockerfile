# hugmesh-tor — a minimal, multi-arch (amd64 + arm64) Tor v3 hidden service for
# the LOCAL docker mesh. Mirrors the NODE `tor` optional service
# (docs/TOR-HIDDEN-SERVICE.md): it publishes the in-compose fe-gateway as a stable
# v3 .onion so the local mesh is reachable over Tor with NO public IP / DNS / ports.
#
# alpine's `tor` package is multi-arch, so this image builds + runs natively on
# Linux docker AND Docker Desktop (Windows/macOS) — no platform pin (unlike the
# amd64-pinned first-party service images), so on an arm64 host it runs native.
FROM alpine:3.20
RUN apk add --no-cache tor
COPY entrypoint.sh /usr/local/bin/hugmesh-tor-entrypoint
RUN chmod +x /usr/local/bin/hugmesh-tor-entrypoint
# tor drops to the packaged `tor` user itself (the `User tor` line in the torrc the
# entrypoint generates), so the container may start as root to fix volume perms.
ENTRYPOINT ["/usr/local/bin/hugmesh-tor-entrypoint"]
