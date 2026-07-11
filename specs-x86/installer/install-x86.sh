#!/bin/bash
# Snapdragon x86_64 installer (hardened Gentoo desktop / k8s node, optional GPU).
# Run as root from a Linux/Gentoo live environment with this ISO mounted. Writes a
# UEFI GPT disk and extracts the stage4 tarball.
#
# Two layouts:
#   PLAINTEXT (default): ESP (fat32) at /boot/efi + ext4 root LAST (growroot can
#     expand it). Mirrors the .img builder: PARTUUID fstab, GRUB-EFI --removable.
#   ENCRYPTED (--encrypt / an 'encrypt-root' marker in this tree — the standalone
#     hardened desktop default): ESP (fat32) at /boot holding kernel/initramfs/GRUB
#     (unencrypted, so a single passphrase unlocks at the initramfs) + a LUKS2
#     container holding the ext4 root. The installer PROMPTS for a system
#     root-unlock passphrase (distinct from the login password) — it is entered
#     here on the target, NEVER baked into any artifact.
#
# Root SSH login is DISABLED by default (the image bakes PermitRootLogin no + locked
# root). To opt in AT INSTALL TIME, set PERMIT_ROOT_LOGIN=yes|prohibit-password (env)
# and this installer rewrites the target's authoritative sshd drop-in. Admin access is
# otherwise the non-root KEYS user, so disabling root never locks you out.
set -euo pipefail
PERMIT_ROOT_LOGIN="${PERMIT_ROOT_LOGIN:-no}"

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: run as root: sudo $0 $*" >&2; exit 1; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# Markers/payloads the build may drop into the installer tree.
ENCRYPT_MARKER="${HERE}/encrypt-root"          # presence => LUKS2 FDE
SEEDED_PASS_FILE="${HERE}/luks-passphrase"     # optional unattended passphrase (0600)
KEYFILE_BOOT="${HERE}/luks-keyfile"            # optional extra LUKS keyslot (keyfile)
FIDO2_MARKER="${HERE}/fido2-enroll"            # optional => systemd-cryptenroll FIDO2
HOME_ARCHIVE="${HERE}/home-archive.tar.xz"     # optional $HOME bundle for the new user

ENCRYPT=false; [ -f "${ENCRYPT_MARKER}" ] && ENCRYPT=true
LUKS_PASS=""
DEV=""
UNATTENDED=false          # --unattended : no confirm prompts; use baked/seeded values
INTERACTIVE=false         # --interactive / --menu : drive the install from an ncurses menu
HOME_MODE_OVERRIDE=""     # --home-mode create|adopt|archive|restore (overrides the baked manifest)
HOME_DEVICE_OVERRIDE=""   # --home-device LABEL=…|UUID=…|/dev/… (adopt)
HOME_BACKUP_OVERRIDE=""   # --home-backup FILE|auto (restore)
while [ $# -gt 0 ]; do
    case "$1" in
        --encrypt)    ENCRYPT=true; shift ;;
        --no-encrypt) ENCRYPT=false; shift ;;
        --luks-pass)  LUKS_PASS="$2"; shift 2 ;;
        --unattended) UNATTENDED=true; shift ;;
        --interactive|--menu) INTERACTIVE=true; shift ;;
        --home-mode)   HOME_MODE_OVERRIDE="$2"; shift 2 ;;
        --home-device) HOME_DEVICE_OVERRIDE="$2"; shift 2 ;;
        --home-backup) HOME_BACKUP_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--encrypt|--no-encrypt] [--luks-pass PASS] [--unattended]"
            echo "          [--interactive] [--home-mode M] [--home-device SPEC] [--home-backup F] /dev/sdX"
            echo "  WARNING: destroys all data on the target device!"
            echo "  --interactive  drive the whole install from an ncurses menu (verify/change everything)"
            echo "  --unattended   no prompts; use the baked manifest + seeded passphrase (kiosk/automation)"
            exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  DEV="$1"; shift ;;
    esac
done

# ── Interactive ncurses menu (verify + change the target/options before writing) ─
run_menu() {
    command -v whiptail >/dev/null || { echo "whiptail not in the live env; using text prompts."; return 0; }
    local items=() n l
    while read -r name size model; do
        items+=("${name}" "${size} ${model:-}")
    done < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | grep -vE '/loop|/sr[0-9]|/zram')
    [ ${#items[@]} -gt 0 ] && DEV="$(whiptail --title "Snapdragon Installer" \
        --menu "Choose the TARGET disk to install onto (it will be ERASED):" 20 70 8 \
        "${items[@]}" 3>&1 1>&2 2>&3)" || true
    whiptail --title "Disk encryption" --yesno "Encrypt the root filesystem with LUKS2 full-disk encryption?\n(You'll set a root-unlock passphrase, separate from your login.)" 11 70 \
        && ENCRYPT=true || ENCRYPT=false
    local hm
    hm="$(whiptail --title "Home directory" --menu "How should the user's home be provisioned?" 18 70 5 \
        create  "Fresh home" \
        archive "Unpack the bundled home archive (if present)" \
        adopt   "Use an existing home already on a disk/USB (no format)" \
        restore "Decrypt + restore an encrypted full-home backup (USB)" 3>&1 1>&2 2>&3)" || hm=""
    [ -n "${hm}" ] && HOME_MODE_OVERRIDE="${hm}"
    case "${hm}" in
        adopt)   HOME_DEVICE_OVERRIDE="$(whiptail --inputbox "Existing home device (LABEL=…|UUID=…|/dev/…):" 9 70 "${HOME_DEVICE_OVERRIDE}" 3>&1 1>&2 2>&3)" || true ;;
        restore) HOME_BACKUP_OVERRIDE="$(whiptail --inputbox "Encrypted backup path (or 'auto' to scan USBs):" 9 70 "auto" 3>&1 1>&2 2>&3)" || true ;;
    esac
    whiptail --title "Confirm" --yesno "Install Snapdragon onto:\n  ${DEV}\n  encrypt=${ENCRYPT}  home=${HOME_MODE_OVERRIDE:-<baked>}\n\nProceed? This ERASES ${DEV}." 13 70 || { echo "Aborted from menu."; exit 1; }
    UNATTENDED=true   # the menu already collected + confirmed everything
}
# snapdragon.install=ncurses on the kernel cmdline (live boot menu) → menu mode.
grep -qs 'snapdragon.install=ncurses' /proc/cmdline && INTERACTIVE=true
${INTERACTIVE} && run_menu

# Unattended / kiosk install with no disk given: auto-select the largest FIXED
# (non-removable) disk, so a hands-free `install-x86.sh --unattended` (or the
# snapdragon.install=unattended boot entry) works without a TTY. Removable media —
# incl. the USB the live env booted from — is excluded (RM=1) so it is never wiped.
auto_select_disk() {
    lsblk -dpnbo NAME,SIZE,TYPE,RM 2>/dev/null \
        | awk '$3=="disk" && $4==0 {print $2, $1}' | sort -rn | head -1 | awk '{print $2}'
}
if ${UNATTENDED} && [ -z "${DEV}" ]; then
    DEV="$(auto_select_disk)"
    [ -n "${DEV}" ] && echo "Unattended: auto-selected target disk ${DEV} (largest fixed disk)." \
                    || echo "Unattended: no fixed disk found to install onto." >&2
fi

[ -n "${DEV}" ] || { echo "Usage: $0 [--interactive] [--unattended] [--encrypt] /dev/sdX" >&2; exit 1; }
[ -b "${DEV}" ] || { echo "ERROR: ${DEV} is not a block device" >&2; exit 1; }

STAGE4="$(find "${HERE}/stage4" -name '*.tar.xz' | head -1)"
[ -n "${STAGE4}" ] || { echo "No stage4 tarball in ${HERE}/stage4/" >&2; exit 1; }

if [[ "${DEV}" =~ (nvme|mmcblk) ]]; then P="${DEV}p"; else P="${DEV}"; fi

# ── SAFETY: never erase the SEPARATE media-data disk (Steam/Vaults) ───────────
# A reinstall on this host keeps that disk attached; refuse if the target carries
# the Steam/ or Vaults/ marker dirs on any of its partitions.
echo "==> Checking ${DEV} is not the media-data disk (Steam/Vaults)…"
probe="$(mktemp -d)"; data_hit=""
for part in $(lsblk -prno NAME,TYPE "${DEV}" | awk '$2=="part"{print $1}'); do
    if mount -o ro "${part}" "${probe}" 2>/dev/null; then
        for m in Steam Vaults; do [ -d "${probe}/${m}" ] && data_hit="${part}:${m}"; done
        umount "${probe}" 2>/dev/null || true
    fi
done
rmdir "${probe}" 2>/dev/null || true
if [ -n "${data_hit}" ]; then
    echo "REFUSING: ${DEV} looks like your DATA disk (found ${data_hit}). Pick the OS target instead." >&2
    exit 1
fi

echo "Target: ${DEV}   Stage4: ${STAGE4}   Encrypt root (LUKS2): ${ENCRYPT}"
if ! ${UNATTENDED}; then
    read -rp "ERASE ${DEV}? type the device path to confirm: " c
    [ "${c}" = "${DEV}" ] || { echo "Aborted."; exit 1; }
fi

# ── Root-unlock passphrase (encrypted layout only) ───────────────────────────
if ${ENCRYPT}; then
    command -v cryptsetup >/dev/null || { echo "ERROR: cryptsetup not in the live environment" >&2; exit 1; }
    if [ -z "${LUKS_PASS}" ] && [ -f "${SEEDED_PASS_FILE}" ]; then
        LUKS_PASS="$(cat "${SEEDED_PASS_FILE}")"
        echo "Using the seeded (unattended) LUKS passphrase from the installer tree."
    fi
    if [ -z "${LUKS_PASS}" ]; then
        # CLI ASKS for the system root-unlock passphrase (distinct from the login pw).
        while :; do
            read -rsp "Enter the SYSTEM ROOT-UNLOCK passphrase (LUKS2, full-disk): " p1; echo
            read -rsp "Confirm passphrase: " p2; echo
            [ -n "${p1}" ] && [ "${p1}" = "${p2}" ] && { LUKS_PASS="${p1}"; break; }
            echo "  Empty or mismatched — try again."
        done
        unset p1 p2
    fi
fi

if ${ENCRYPT}; then
    echo "==> Partitioning (UEFI GPT: ESP at /boot [1GiB, unencrypted] + LUKS2 root)"
    parted -s "${DEV}" mklabel gpt
    parted -s "${DEV}" mkpart ESP fat32 1MiB 1025MiB
    parted -s "${DEV}" set 1 esp on
    parted -s "${DEV}" mkpart root 1025MiB 100%
    partprobe "${DEV}"; sleep 1

    echo "==> Creating LUKS2 container on ${P}2"
    printf '%s' "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
        --batch-mode "${P}2" -
    printf '%s' "${LUKS_PASS}" | cryptsetup open "${P}2" cryptroot -
    ROOT_DM="/dev/mapper/cryptroot"

    # Optional extra unlock factors (keyfile + FIDO2/YubiKey).
    if [ -f "${KEYFILE_BOOT}" ]; then
        echo "==> Adding keyfile as a second LUKS keyslot"
        printf '%s' "${LUKS_PASS}" | cryptsetup luksAddKey "${P}2" "${KEYFILE_BOOT}" -
    fi
    if [ -f "${FIDO2_MARKER}" ] && command -v systemd-cryptenroll >/dev/null; then
        echo "==> Enrolling FIDO2/YubiKey LUKS keyslot (touch your key)…"
        PASSWORD="${LUKS_PASS}" systemd-cryptenroll --fido2-device=auto "${P}2" || \
            echo "    (FIDO2 enroll skipped/failed — passphrase still works)"
    fi

    echo "==> Formatting"
    mkfs.vfat -F 32 -n SNAP_ESP "${P}1"
    mkfs.ext4 -L SNAP_ROOT -F "${ROOT_DM}"

    echo "==> Mount + extract (ESP at /boot so a single passphrase unlocks at initramfs)"
    mkdir -p /mnt/sdhost
    mount "${ROOT_DM}" /mnt/sdhost
    mkdir -p /mnt/sdhost/boot
    mount "${P}1" /mnt/sdhost/boot
    tar -C /mnt/sdhost --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
        tar -C /mnt/sdhost -xJf "${STAGE4}"

    LUKS_UUID="$(blkid -s UUID -o value "${P}2")"
    ESP_PARTUUID="$(blkid -s PARTUUID -o value "${P}1")"

    # crypttab: unlock 'cryptroot' from the LUKS partition (keyfile on the ESP if we
    # added one; otherwise prompt for the passphrase at boot).
    if [ -f "${KEYFILE_BOOT}" ]; then
        install -Dm0400 "${KEYFILE_BOOT}" /mnt/sdhost/boot/cryptroot.key
        printf 'cryptroot UUID=%s /boot/cryptroot.key luks\n' "${LUKS_UUID}" > /mnt/sdhost/etc/crypttab
    else
        printf 'cryptroot UUID=%s none luks\n' "${LUKS_UUID}" > /mnt/sdhost/etc/crypttab
    fi
    chmod 0600 /mnt/sdhost/etc/crypttab

    # fstab: ESP at /boot (not /boot/efi), root via the decrypted mapper by UUID.
    ROOT_FS_UUID="$(blkid -s UUID -o value "${ROOT_DM}")"
    {
        echo "# Snapdragon encrypted-root layout (installer-generated)"
        echo "UUID=${ROOT_FS_UUID}  /      ext4  noatime,errors=remount-ro  0 1"
        echo "PARTUUID=${ESP_PARTUUID}  /boot  vfat  noatime,nosuid,nodev,noexec,fmask=0077,dmask=0077  0 2"
        echo "tmpfs  /tmp  tmpfs  noatime,nosuid,nodev,noexec,size=2G  0 0"
    } > /mnt/sdhost/etc/fstab

    echo "==> Installing GRUB-EFI (--removable) with rd.luks unlock"
    for d in dev proc sys run; do mount --rbind "/$d" "/mnt/sdhost/$d"; done
    chroot /mnt/sdhost /bin/bash -c "
      set -e
      export GRUB_DISABLE_OS_PROBER=true
      # Add the LUKS unlock + mapper-root tokens to the kernel cmdline.
      if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        sed -i 's|^GRUB_CMDLINE_LINUX=\"\\(.*\\)\"|GRUB_CMDLINE_LINUX=\"\\1 rd.luks.uuid=${LUKS_UUID} root=/dev/mapper/cryptroot\"|' /etc/default/grub
      else
        echo 'GRUB_CMDLINE_LINUX=\"rd.luks.uuid=${LUKS_UUID} root=/dev/mapper/cryptroot\"' >> /etc/default/grub
      fi
      echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
      grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable || true
      grub-mkconfig -o /boot/grub/grub.cfg
    "
else
    echo "==> Partitioning (UEFI GPT: ESP + ext4 root; root LAST for growroot)"
    parted -s "${DEV}" mklabel gpt
    parted -s "${DEV}" mkpart ESP fat32 1MiB 513MiB
    parted -s "${DEV}" set 1 esp on
    parted -s "${DEV}" mkpart root ext4 513MiB 100%
    partprobe "${DEV}"; sleep 1

    echo "==> Formatting"
    mkfs.vfat -F 32 -n SNAP_ESP "${P}1"
    mkfs.ext4 -L SNAP_ROOT -F "${P}2"

    echo "==> Mount + extract (ESP at /boot/efi; root on ext4)"
    mkdir -p /mnt/sdhost
    mount "${P}2" /mnt/sdhost
    mkdir -p /mnt/sdhost/boot/efi
    mount "${P}1" /mnt/sdhost/boot/efi
    tar -C /mnt/sdhost --xattrs-include='*.*' -xJf "${STAGE4}" 2>/dev/null || \
        tar -C /mnt/sdhost -xJf "${STAGE4}"

    # PARTUUID identity, matching the .img builder. Prefer the fstab carried in the
    # stage4 (specs-x86/etc/fstab tokens); fall back to the bundled template.
    ESP_PARTUUID="$(blkid -s PARTUUID -o value "${P}1")"
    ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${P}2")"
    if [ -f /mnt/sdhost/etc/fstab ] && grep -q '__ROOT_PARTUUID__' /mnt/sdhost/etc/fstab; then
        : # stage4 already ships the token fstab
    elif [ -f "${HERE}/fstab.template" ]; then
        cp "${HERE}/fstab.template" /mnt/sdhost/etc/fstab
    fi
    sed -i -e "s/__ROOT_PARTUUID__/${ROOT_PARTUUID}/g" -e "s/__ESP_PARTUUID__/${ESP_PARTUUID}/g" \
        /mnt/sdhost/etc/fstab

    echo "==> Installing GRUB-EFI (--removable)"
    for d in dev proc sys run; do mount --rbind "/$d" "/mnt/sdhost/$d"; done
    chroot /mnt/sdhost /bin/bash -c '
      export GRUB_DISABLE_OS_PROBER=true
      grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable || true
      grub-mkconfig -o /boot/grub/grub.cfg
    '
fi

# ── Home provisioning (manifest-driven; CLI/menu overrides win) ──────────────
# The image bakes /etc/snapdragon/home.conf (HOME_MODE/HOME_DEVICE/HOME_BACKUP).
# create  : nothing here — the first-boot helper sets it up.
# archive : unpack the bundled $HOME tarball (only /home/<user> lands).
# adopt   : mount an existing home device at /home (no format) via fstab.
# restore : decrypt + unpack an encrypted full-home backup (USB or path).
HM_MODE="archive"; HM_DEVICE=""; HM_BACKUP=""
if [ -f /mnt/sdhost/etc/snapdragon/home.conf ]; then
    # shellcheck disable=SC1091
    . /mnt/sdhost/etc/snapdragon/home.conf 2>/dev/null || true
    HM_MODE="${HOME_MODE:-archive}"; HM_DEVICE="${HOME_DEVICE:-}"; HM_BACKUP="${HOME_BACKUP:-}"
fi
[ -n "${HOME_MODE_OVERRIDE}" ]   && HM_MODE="${HOME_MODE_OVERRIDE}"
[ -n "${HOME_DEVICE_OVERRIDE}" ] && HM_DEVICE="${HOME_DEVICE_OVERRIDE}"
[ -n "${HOME_BACKUP_OVERRIDE}" ] && HM_BACKUP="${HOME_BACKUP_OVERRIDE}"
target_user="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /mnt/sdhost/etc/passwd 2>/dev/null || true)"

# Decrypt helper: .gpg -> gpg, .enc -> openssl, else cat. Streams plaintext tar.
decrypt_stream() {
    case "$1" in
        *.gpg) gpg --batch --quiet --decrypt "$1" ;;
        *.enc) openssl enc -d -aes-256-cbc -pbkdf2 -in "$1" ;;
        *)     cat "$1" ;;
    esac
}

case "${HM_MODE}" in
    archive)
        if [ -f "${HOME_ARCHIVE}" ]; then
            echo "==> Home(archive): unpacking bundled archive into /home"
            tar -C /mnt/sdhost/home --numeric-owner -xJf "${HOME_ARCHIVE}" 2>/dev/null \
                || tar -C /mnt/sdhost/home -xJf "${HOME_ARCHIVE}" || echo "    (extract had warnings)"
        fi ;;
    adopt)
        if [ -n "${HM_DEVICE}" ]; then
            # FAIL-CLOSED fstab device-spec validation. HM_DEVICE is written as the
            # FIRST FIELD of an /etc/fstab line; it arrives from the baked home.conf
            # (%q-decoded, so it can still carry an embedded newline/whitespace), the
            # --home-device CLI flag, or the whiptail inputbox (the latter two are
            # UNVALIDATED). A value with whitespace would shift the mountpoint/options;
            # a value with a NEWLINE would inject an ENTIRE extra fstab line (a rogue
            # boot-time mount). printf '%s' does NOT neutralize a newline. A legitimate
            # home spec is a tag (LABEL=/PARTLABEL=/UUID=/PARTUUID=) or a /dev/ path —
            # no whitespace, comma or '#'. Reject anything else (skip; do NOT write).
            if [[ ! "${HM_DEVICE}" =~ ^(LABEL=[A-Za-z0-9_.:+-]+|PARTLABEL=[A-Za-z0-9_.:+-]+|UUID=[A-Fa-f0-9-]+|PARTUUID=[A-Fa-f0-9-]+|/dev/[A-Za-z0-9/_.-]+)$ ]]; then
                echo "    (adopt: home device-spec '${HM_DEVICE}' is not a valid fstab device (LABEL=/PARTLABEL=/UUID=/PARTUUID=/dev/…) — skipping, NOT writing fstab)" >&2
            else
                echo "==> Home(adopt): mounting existing ${HM_DEVICE} at /home (NO format)"
                # nofail so a missing/late USB never blocks boot; never wiped by this installer.
                printf '%s  /home  auto  nofail,noatime,nosuid,nodev  0 2\n' "${HM_DEVICE}" >> /mnt/sdhost/etc/fstab
            fi
        else
            echo "    (adopt requested but no home device known — skipping)"
        fi ;;
    restore)
        bk="${HM_BACKUP}"
        if [ "${bk}" = auto ] || [ -z "${bk}" ]; then
            bk="$(find /media /run/media /mnt -maxdepth 4 -name '*home-backup-*' 2>/dev/null | head -1 || true)"
        fi
        if [ -n "${bk}" ] && [ -f "${bk}" ]; then
            echo "==> Home(restore): decrypting + unpacking ${bk} into /home"
            decrypt_stream "${bk}" | tar -C /mnt/sdhost/home --numeric-owner -xJ 2>/dev/null \
                || echo "    (restore had warnings — check the passphrase / backup)"
        else
            echo "    (restore requested but no backup found — skipping)"
        fi ;;
    create) echo "==> Home(create): first-boot helper will provision ${target_user:-the user}'s home" ;;
esac
if [ -n "${target_user}" ] && [ -d "/mnt/sdhost/home/${target_user}" ]; then
    chroot /mnt/sdhost chown -R "${target_user}:${target_user}" "/home/${target_user}" 2>/dev/null || true
fi

# Root SSH login override (env PERMIT_ROOT_LOGIN). The image already ships hardened
# (00-root-login.conf = no); only rewrite it if the installer was told to opt in.
case "${PERMIT_ROOT_LOGIN}" in
    yes|prohibit-password)
        mkdir -p /mnt/sdhost/etc/ssh/sshd_config.d
        printf '# Set by install-x86.sh (PERMIT_ROOT_LOGIN). 00- => authoritative.\nPermitRootLogin %s\n' \
            "${PERMIT_ROOT_LOGIN}" > /mnt/sdhost/etc/ssh/sshd_config.d/00-root-login.conf
        echo "==> Root SSH login set to '${PERMIT_ROOT_LOGIN}' (opted in at install)." ;;
    *) echo "==> Root SSH login DISABLED (hardened default; non-root KEYS user is the admin)." ;;
esac

echo "==> Installing GRUB-EFI (--removable)"
for d in dev proc sys run; do mount --rbind "/$d" "/mnt/sdhost/$d"; done
chroot /mnt/sdhost /bin/bash -c '
  export GRUB_DISABLE_OS_PROBER=true
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable || true
  grub-mkconfig -o /boot/grub/grub.cfg
'
sync
unset LUKS_PASS
for d in run sys proc dev; do umount -lR "/mnt/sdhost/$d" 2>/dev/null || true; done
umount -R /mnt/sdhost 2>/dev/null || true
${ENCRYPT} && cryptsetup close cryptroot 2>/dev/null || true

echo ""
if ${ENCRYPT}; then
    echo "==> Done. The root filesystem is LUKS2-encrypted; you'll be prompted for the"
    echo "    root-unlock passphrase at boot (initramfs). growroot expands root on first boot."
else
    echo "==> Done. Insert a USB KEYS stick and boot. growroot expands root on first boot."
fi
