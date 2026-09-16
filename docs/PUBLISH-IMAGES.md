# Publishing built images — `scripts/publish-images.sh`

Exports the **shareable** artifacts of one Studio/CLI build session
(`out/sessions/<id>/`) into a flat, verifiable publish tree. It is a
**post-build operator step**, not a build channel and not a matrix axis
([`BUILD-MATRIX.md`](BUILD-MATRIX.md)): the builders' artifacts are unchanged,
this tool only copies (or hardlinks) the ones that are safe to hand to someone
else and writes the manifests that let them verify what they received. It is
Phase 1 of the image-publishing outline recorded on `hugmesh-host-shell#19`;
the later "publish to the mesh" phases build on this same tree, so what leaves
here must already be clean. Its sibling for cloud importers is
[`CLOUD-IMAGE-PACKAGING.md`](CLOUD-IMAGE-PACKAGING.md) (`scripts/cloud-package.sh`).

## Usage

```sh
scripts/publish-images.sh <session-id|session-dir> --dest <dir> \
    [--images id,...] [--hardlink] [--produced-at ISO8601]
```

| Argument | Meaning |
|---|---|
| `<session-id>` / `<session-dir>` | A session id under `HUGMESH_SESSIONS_ROOT` (default `<repo>/out/sessions`) or a path to a session directory. Anything else is a fatal "no such session". |
| `--dest DIR` | Where the publish tree lands. **Refused** if it already exists (no clobber) or sits inside the session directory. Required. |
| `--images id,...` | Only these image ids — `<role>.<platform>`, e.g. `pki.x86`, `be.rpi5` (the mesh manifest's ids; the rpi5 builder's long spellings `backend`/`frontend` normalise to `be`/`fe`). An id that matches nothing is a **fatal typo**, never a silent empty publish. |
| `--hardlink` | Hardlink artifacts instead of copying (same-filesystem fast path; falls back to a copy per file when `ln` fails). |
| `--produced-at TS` | Explicit deterministic `producedAt` stamp. Default: `SOURCE_DATE_EPOCH`, else the newest `builtAt` among the exported files — **never wall-clock `date`**, so a re-run over the same session yields a byte-identical manifest and therefore an identical signature. |
| `-h` / `--help` | Usage. |

Environment:

| Variable | Meaning |
|---|---|
| `HUGMESH_SESSIONS_ROOT` | Session-id lookup root (default `<repo>/out/sessions`). |
| `PROVENANCE_SIGNING_KEY` | Out-of-band Ed25519 private key. When set, `publish-manifest.json` is signed (detached `.sig`, the same family as `scripts/provenance.sh`). When unset the tool **warns and ships unsigned** — production key custody is out-of-band. |
| `SOURCE_DATE_EPOCH` | Deterministic `producedAt` fallback (see `--produced-at`). |

Exit codes: **0** published · **1** refused or error (the staging directory is
deleted, nothing is left half-written at `--dest`) · **2** usage.

## What lands in `--dest`

```
<dest>/
  <brand>-<platform>-<arch>-<role>-<env>-<stamp>.{img.xz,iso,fs.tar.xz,stage4.tar.xz}
  hugmesh-mesh-manifest.json      # the session's own mesh manifest, verbatim
  publish-manifest.json           # schema hugmesh.net/publish-images/v1 (below)
  publish-manifest.json.sig       # detached Ed25519 — only when PROVENANCE_SIGNING_KEY is set
  SHA256SUMS                      # `sha256sum -c`-able, relative names
```

One parseable line per exported file is echoed to stdout — the same line
grammar `cloud-package.manifest` uses, with `IMAGE <id>` in place of
`FORMAT <fmt>`:

```
IMAGE <role>.<platform> FILE <path> BYTES <n> SHA256 <hex>
```

`publish-manifest.json` carries `schema` (`hugmesh.net/publish-images/v1`), the
`session.id`, `producedAt`, and one entry per file with `id`, `role`,
`platform`, `flavor`, `bytes`, `sha256` and `builtAt`. It is self-checked for
well-formedness before the tree is moved into place (a malformed manifest is a
refusal, as in `provenance.sh`).

## What it refuses — by construction, with no override flag

A session tree intermixes publishable images with material that must **never**
leave the machine: `keys-<role>.<platform>/` (device provisioning keys),
`secureboot/` (signing material), `wl-<role>.<platform>/` (build worklists with
full sysroot trees) and build logs. The tool never recurses into the session
tree at all: candidates are **top-level regular files only**, matched against a
closed allow-list of builder artifact suffixes (`*.img.xz`, `*.iso`,
`*.fs.tar.xz`, `*.stage4.tar.xz` — raw `.img` is deliberately absent). The
deny-listed trees are directories, so they are unreachable by construction, not
by filtering. Every candidate must then pass **all** of the following, and the
first miss refuses the **whole** export (never "skip and continue"):

1. a regular file, never a symlink (a link wearing an artifact name could smuggle key bytes out of `keys-*/`);
2. a basename not matching the deny-list (`keys-*`, `secureboot*`, `wl-*`, `*sysroot*`, `*.log`, `*.lock`, `*.pem`, `*.key`, `id_*`, `*secret*`, `*token*`, `*password*`, `*credential*`, `*passwd*`, `shadow*` — deny beats allow by design);
3. the builders' `<brand>-<platform>-<arch>-<role>-<env>-<stamp>.<kind>` naming shape (an artifact-suffixed file of unknown provenance is poison);
4. content magic: xz artifacts must open with the xz magic, `.iso` with ISO9660's `CD001`;
5. non-empty.

The staged output is swept again (no subdirectories, no symlinks, nothing
outside the expected set, deny-list re-checked), and every staged **text** file
(both manifests and `SHA256SUMS`) goes through `scripts/secret-scan.sh`
fail-closed before the move. The binary artifacts are excluded from the entropy
scanner on purpose — compressed images are 100 % high-entropy — their integrity
is `SHA256SUMS`' job and their identity the shape + magic gates' job. A missing
`secret-scan.sh` is a refusal, not a skip.

## Verifying what you received

```sh
cd <dest> && sha256sum -c SHA256SUMS
# with the publisher's public key:
openssl pkeyutl -verify -pubin -inkey publisher.pub -rawin \
    -in publish-manifest.json -sigfile publish-manifest.json.sig
```

## Gate

`tests/scripts/test-publish-images.sh` is the hermetic unit suite (a synthetic
session tree with planted key material next to magic-stamped artifacts), wired
into both `.github/workflows/shell-suites.yml` and `.gitlab-ci.yml`
(`lint:publish-images`). `tests/scripts/test-docs-command-coverage.sh` is what
keeps this page from going missing again: every user-facing `scripts/` command
must be named in `docs/` or a README, and this one was not for three weeks after
it merged (hugmesh-generator#268).
