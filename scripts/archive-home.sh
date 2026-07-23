#!/usr/bin/env bash
# archive-home.sh — compress a user's home directory into a relocatable archive
# that can ride on the install storage and be unpacked into ONLY that user's home
# on a freshly installed system, leaving the rest of the system unchanged.
#
# The output untars (as root) into /home/, recreating /home/<user>/… — it contains
# NO system paths, so it can never clobber /etc, /usr, etc. The installer
# (install-x86.sh) picks it up when bundled as home-archive.tar.xz, or pass it to
# the builder with --include-home-archive FILE.
#
# Bloat (caches, build trees, VM images, the encrypted Vaults ciphertext) is
# excluded by default to keep the archive transportable; tune with --exclude.
set -euo pipefail

GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; RED=$'\033[0;31m'; RST=$'\033[0m'
info(){ echo "${GREEN}    $*${RST}"; }
warn(){ echo "${YEL}    WARNING: $*${RST}" >&2; }
err(){  echo "${RED}    ERROR: $*${RST}" >&2; }

USER_NAME="${SUDO_USER:-${USER:-$(id -un)}}"
OUTPUT=""
LEVEL=6
FORCE=false
ENCRYPT=false           # --encrypt : symmetric-encrypt the archive (gpg AES256, else openssl)
PASSPHRASE_FILE=""      # --passphrase-file FILE : non-interactive passphrase (else prompt)
PRESET="full"           # --full (config+documents+media, minus cruft) | --config-only (lean)
declare -a EXTRA_EXCLUDES=()

# Default excludes: caches, package/build trees, VCS objects, VM/container blobs,
# trash, and the gocryptfs Vaults ciphertext (encrypted, large, lives on /media).
DEFAULT_EXCLUDES=(
    ".cache" ".ccache" ".cargo/registry" ".cargo/git" ".rustup/toolchains"
    ".npm" "node_modules" ".gradle" ".m2/repository" ".local/share/Steam"
    ".local/share/Trash" ".thumbnails" ".var/app/*/cache"
    "*.iso" "*.qcow2" "*.img" "VirtualBox VMs" ".vagrant.d"
    "Vaults" ".local/share/containers" ".docker"
    "hugmesh-stack" "GitHub" "snap-standalone-build" "snap-home-feature" ".m2" "out"
)
# --config-only adds these so the lean archive that rides INSIDE an installer ISO
# stays small (config + desktop only; no Documents/media/Downloads). --full keeps
# them — your documents, music, anime, etc. ride along (only the cruft above is cut).
LEAN_EXCLUDES=(
    "Downloads" "Videos" "Music" "Pictures" "Documents" "Games" "Movies" "Anime"
    "Steam" ".local/share/Steam" ".var/app"
)

usage(){ cat <<EOF
Usage: $0 [--user NAME] [--output FILE] [--level 1-9] [--exclude PATH]...
          [--full | --config-only] [--encrypt [--passphrase-file FILE]] [--force]
  --user NAME       Home to archive (default: ${USER_NAME}).
  --output FILE     Archive path (default: ./home-<user>.tar.xz, +.gpg/.enc if encrypted).
  --level N         xz compression level 1-9 (default: ${LEVEL}).
  --full            Include documents + media (default) — only build/cache cruft is cut.
  --config-only     Lean archive: also drop Downloads/Videos/Music/Pictures/Documents
                    (good for the small copy that rides INSIDE an installer ISO).
  --encrypt         Symmetric-encrypt the archive (gpg AES256 if present, else
                    openssl aes-256-cbc+pbkdf2). For an encrypted backup on a USB.
  --passphrase-file FILE  Read the passphrase from FILE (else prompt twice).
  --exclude PATH    Extra exclude (relative to the home dir); repeatable.
  --force           Overwrite an existing output file.
Use it as a USB backup to restore later:
  ./archive-home.sh --user ${USER_NAME} --full --encrypt --output /run/media/USB/hugmesh-home-backup-${USER_NAME}.tar.xz
  # then on the new system: install with --home-mode restore --home-backup auto
Or bundle the lean copy into the installer:
  ./archive-home.sh --user ${USER_NAME} --config-only --output home-${USER_NAME}.tar.xz
  ./build-x86-host-stage4.sh --role standalone-thick --include-home-archive home-${USER_NAME}.tar.xz
EOF
exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --user) USER_NAME="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --level) LEVEL="$2"; shift 2 ;;
        --full) PRESET="full"; shift ;;
        --config-only) PRESET="config"; shift ;;
        --encrypt) ENCRYPT=true; shift ;;
        --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
        --exclude) EXTRA_EXCLUDES+=("$2"); shift 2 ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage 0 ;;
        *) err "unknown option: $1"; usage 1 ;;
    esac
done
[ "${PRESET}" = "config" ] && EXTRA_EXCLUDES+=("${LEAN_EXCLUDES[@]}")

HOME_DIR="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
[ -n "${HOME_DIR}" ] && [ -d "${HOME_DIR}" ] || { err "no home directory for user '${USER_NAME}'"; exit 1; }
[ -n "${OUTPUT}" ] || OUTPUT="$(pwd)/home-${USER_NAME}.tar.xz"

# Resolve the encryptor (gpg preferred, openssl fallback) + output suffix.
declare -a ENC_CMD=()
if ${ENCRYPT}; then
    if command -v gpg >/dev/null 2>&1; then
        case "${OUTPUT}" in *.gpg) ;; *) OUTPUT="${OUTPUT}.gpg" ;; esac
        if [ -n "${PASSPHRASE_FILE}" ]; then
            ENC_CMD=(gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file "${PASSPHRASE_FILE}" -o "${OUTPUT}")
        else
            ENC_CMD=(gpg --symmetric --cipher-algo AES256 -o "${OUTPUT}")
        fi
    elif command -v openssl >/dev/null 2>&1; then
        case "${OUTPUT}" in *.enc) ;; *) OUTPUT="${OUTPUT}.enc" ;; esac
        if [ -n "${PASSPHRASE_FILE}" ]; then
            ENC_CMD=(openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:${PASSPHRASE_FILE}" -out "${OUTPUT}")
        else
            ENC_CMD=(openssl enc -aes-256-cbc -pbkdf2 -salt -out "${OUTPUT}")
        fi
    else
        err "--encrypt needs gpg or openssl installed"; exit 1
    fi
fi
[ -e "${OUTPUT}" ] && ! ${FORCE} && { err "output exists: ${OUTPUT} (use --force)"; exit 1; }

# Build tar --exclude args (anchored under ./<user>/).
declare -a TAR_EXCLUDES=()
base="$(basename "${HOME_DIR}")"
for e in "${DEFAULT_EXCLUDES[@]}" "${EXTRA_EXCLUDES[@]}"; do
    TAR_EXCLUDES+=(--exclude="./${base}/${e}")
done

info "Archiving ${HOME_DIR} -> ${OUTPUT} (preset=${PRESET}${ENCRYPT:+, encrypted}, xz -${LEVEL}, relocatable into /home/)"
# -C the PARENT of the home dir so members are ./<user>/… → unpack into /home/.
if ${ENCRYPT}; then
    ( cd "$(dirname "${HOME_DIR}")" \
      && XZ_OPT="-${LEVEL} -T0" tar --numeric-owner --warning=no-file-changed \
            "${TAR_EXCLUDES[@]}" -cJ "./${base}" | "${ENC_CMD[@]}" ) \
      || { rc=$?; [ "${rc}" -eq 1 ] || { err "archive pipe failed (rc=${rc})"; exit "${rc}"; }; warn "some files changed during archive (rc=1) — archive still written"; }
else
    ( cd "$(dirname "${HOME_DIR}")" \
      && XZ_OPT="-${LEVEL} -T0" tar --numeric-owner --warning=no-file-changed \
            "${TAR_EXCLUDES[@]}" -cJf "${OUTPUT}" "./${base}" ) \
      || { rc=$?; [ "${rc}" -eq 1 ] || { err "tar failed (rc=${rc})"; exit "${rc}"; }; warn "some files changed during archive (rc=1) — archive still written"; }
fi

sz="$(du -h "${OUTPUT}" 2>/dev/null | cut -f1)"
info "Done: ${OUTPUT} (${sz})"
${ENCRYPT} && info "Encrypted — restore with: install … --home-mode restore --home-backup ${OUTPUT} (or 'auto' on a USB)"
info "Unpacks into /home/${base}/ only — the rest of the installed system is untouched."
