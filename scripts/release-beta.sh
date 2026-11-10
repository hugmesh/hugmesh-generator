#!/usr/bin/env bash
# release-beta.sh — the org BETA release: scripts/release.sh --channel beta, kept so the
# old one-liner (scripts/release-beta.sh --apply --studio <version>) keeps working. Every
# option is passed on, a VERSION and the group selectors included; the direct command is
# scripts/release.sh <VERSION> [--all|--apps|...] (docs/RELEASING.md).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release.sh" --channel beta "$@"
