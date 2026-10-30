#!/usr/bin/env bash
# release-beta.sh — the org BETA release: scripts/release.sh --channel beta, kept so the
# documented one-liner (docs/RELEASING.md) keeps working. Every option is passed on.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release.sh" --channel beta "$@"
