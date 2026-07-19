# shellcheck shell=bash
# cloud-deploy-providers.sh — the PROVIDER REGISTRY for the cloud-deploy driver.
#
# This is a SOURCEABLE data + emit library, not an executable. The shared driver
# (specs/usr/sbin/snapdragon-cloud-deploy) sources it, and every thin front-end
# reaches the providers only THROUGH the driver — so this file is the single
# place that describes "what cloud targets exist and what each one emits". It is
# the deliberate SIBLING of go-live-providers.sh (same parallel-assoc-array +
# one-emit-fn-per-provider shape, same accessor discipline), NOT an extension of
# it: go-live's lifecycle is "emit artifacts -> operator applies edge -> commit
# writes a local marker", while cloud-deploy needs plan/apply/status/destroy
# against REMOTE state — a different lifecycle that must not leak into the
# go-live registry's contract (see the go-live consolidation notes).
#
# A provider is described by a row across the parallel associative arrays below
# (id -> label / input format / cloud CLI / creds / status / deep-link / emits /
# check hint) plus ONE emit function `cdp_emit_<id>` that renders that
# provider's artifacts into an output dir. The driver NEVER hard-codes a
# provider; it iterates CLOUD_DEPLOY_PROVIDER_IDS and dispatches to cdp_emit.
#
# THE CUSTODY / SAFETY CONTRACT (same bar as go-live + the phone wizard):
#   * plan (the only registry entry point) is PURE: it renders FILES into the
#     out dir and mutates NOTHING else — no cloud calls, no state, no creds
#     reads. Every artifact is operator-readable before anything runs.
#   * apply.sh / destroy.sh (oc-apply.sh for openshift-cnv) are the ONLY
#     executables emitted, and BOTH re-confirm on their own TTY before mutating
#     anything remote — they stay fail-safe even when run directly, outside the
#     driver's own confirmation gate.
#   * Secrets NEVER ride argv and are NEVER copied/baked: the creds file is
#     referenced by PATH only (AWS_SHARED_CREDENTIALS_FILE / KUBECONFIG / a
#     sourced non-secret env fragment). azure-image goes further: the emitted
#     script REFUSES to handle credentials at all and requires an existing
#     `az login` session (device-code/browser — never a password on argv).
#   * Every operator-supplied value baked into a script is %q-shell-quoted into
#     a config header, and the script BODY is a quoted heredoc — the same
#     root-cron injection defence the duckdns emit ported from #286/#338.
#
# CONTEXT the emit functions read (globals the driver sets before calling emit;
# same process, so no export needed — the driver SOURCES this file):
#   CD_DOMAIN        the baked cluster domain (apex), e.g. snapdragon.systems
#   CD_IMAGE         the PACKAGED artifact path from scripts/cloud-package.sh
#                    (raw for aws-ec2, fixed VHD for azure-image, qcow2 for
#                    openshift-cnv/generic-qcow2) — may be empty; the emitted
#                    apply script then refuses until re-planned with --image
#   CD_REGION        cloud region/location (us-east-1, westeurope, …; may be empty)
#   CD_CREDS_FILE    credentials FILE path (0600; referenced by path only,
#                    contents never read here and never placed on argv)
#   CD_KEYS_DIR      keys-layout root referenced by the KEYS-volume guidance
#   CD_ENTRA_TENANT  Entra tenant id for the azure-image entra/ emits (defaults
#                    to a <TENANT-ID> placeholder the operator substitutes)

# ── Registry rows ──────────────────────────────────────────────────────────────
# Order here is the PRIORITISED v1 list (flagship first). The driver lists in
# this order.
CLOUD_DEPLOY_PROVIDER_IDS=(aws-ec2 azure-image openshift-cnv generic-qcow2)

declare -gA CLOUD_DEPLOY_LABEL=(
    [aws-ec2]="AWS EC2 (RAW import-snapshot -> UEFI AMI)"
    [azure-image]="Azure managed image (fixed VHD, Gen2) + Entra ID notes"
    [openshift-cnv]="OpenShift Virtualization / KubeVirt CNV (qcow2 via CDI)"
    [generic-qcow2]="Generic qcow2 (libvirt/virt-install + any qcow2 PaaS)"
)
# The PACKAGED input format each provider consumes — the scripts/cloud-package.sh
# (I1) output that feeds --image. This is the cloud-deploy analogue of go-live's
# mechanism taxonomy: front-ends key their input pickers off it.
declare -gA CLOUD_DEPLOY_FORMAT=(
    [aws-ec2]="raw"
    [azure-image]="vhd-fixed"
    [openshift-cnv]="qcow2"
    [generic-qcow2]="qcow2"
)
# Which cloud CLI the EMITTED apply/destroy scripts drive (empty = none: the
# generic provider is pure guidance + local libvirt, no cloud CLI at all).
declare -gA CLOUD_DEPLOY_CLI=(
    [aws-ec2]="aws"
    [azure-image]="az"
    [openshift-cnv]="oc"
    [generic-qcow2]=""
)
# Does apply/destroy REQUIRE --creds-file? azure-image deliberately says "no":
# its scripts refuse to handle credentials and demand an existing az session
# (the optional --creds-file there is a NON-secret env fragment of defaults).
declare -gA CLOUD_DEPLOY_CREDS=(
    [aws-ec2]="yes"
    [azure-image]="no"
    [openshift-cnv]="yes"
    [generic-qcow2]="no"
)
# The apply-phase executable each emit renders (empty = no apply script at all:
# generic-qcow2 mutates nothing remote — the operator runs virt-install locally).
declare -gA CLOUD_DEPLOY_APPLY_SCRIPT=(
    [aws-ec2]="apply.sh"
    [azure-image]="apply.sh"
    [openshift-cnv]="oc-apply.sh"
    [generic-qcow2]=""
)
# full = implemented end-to-end. (stub is retained in the taxonomy for any future
# provider added ahead of its emit; all v1 providers are full.)
declare -gA CLOUD_DEPLOY_STATUS=(
    [aws-ec2]="full"
    [azure-image]="full"
    [openshift-cnv]="full"
    [generic-qcow2]="full"
)
# Deep-link URL TEMPLATE. {domain} is substituted with CD_DOMAIN by cdp_deeplink().
declare -gA CLOUD_DEPLOY_DEEPLINK=(
    [aws-ec2]="https://console.aws.amazon.com/ec2/home#Images:"
    [azure-image]="https://portal.azure.com/#browse/Microsoft.Compute%2Fimages"
    [openshift-cnv]="https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html"
    [generic-qcow2]="https://libvirt.org/manpages/virt-install.html"
)
# One-line human summary of what each provider EMITS / does.
declare -gA CLOUD_DEPLOY_EMITS=(
    [aws-ec2]="apply.sh (s3 cp -> import-snapshot -> register-image, UEFI+ENA) + vmimport IAM policies + keys-volume.md + status.sh + destroy.sh + checklist.md"
    [azure-image]="apply.sh (group -> blob upload -> az image create Gen2) + image-builder template + entra/ (app registrations, env fragments, claims-mapping) + keys-disk.md + destroy.sh + checklist.md"
    [openshift-cnv]="datavolume.yaml + vm.yaml (CDI-sourced KubeVirt VM) + oc-apply.sh + scc-notes.md + rhel-notes.md + destroy.sh"
    [generic-qcow2]="libvirt domain.xml + a virt-install one-liner + PaaS upload notes + destroy.sh (no cloud CLI at all)"
)
# The status-verb CHECK COMMAND hint per provider. The driver's `status` verb
# PRINTS these (and any state hints apply.sh recorded) — it never runs them.
declare -gA CLOUD_DEPLOY_CHECK=(
    [aws-ec2]="bash <out-dir>/status.sh   # aws ec2 describe-import-snapshot-tasks / describe-images"
    [azure-image]="az image show --resource-group <rg> --name <image>   # see checklist.md"
    [openshift-cnv]="oc get dv,vm,vmi -n <namespace>   # DataVolume import progress + VM phase"
    [generic-qcow2]="virsh list --all && virsh dominfo <name>   # local libvirt only"
)

# ── Registry accessors (front-ends + driver use ONLY these) ────────────────────
cdp_known()        { [ -n "${CLOUD_DEPLOY_LABEL[$1]:-}" ]; }
cdp_label()        { printf '%s' "${CLOUD_DEPLOY_LABEL[$1]:-$1}"; }
cdp_format()       { printf '%s' "${CLOUD_DEPLOY_FORMAT[$1]:-qcow2}"; }
cdp_cli()          { printf '%s' "${CLOUD_DEPLOY_CLI[$1]:-}"; }
cdp_needs_creds()  { [ "${CLOUD_DEPLOY_CREDS[$1]:-no}" = "yes" ]; }
cdp_apply_script() { printf '%s' "${CLOUD_DEPLOY_APPLY_SCRIPT[$1]:-}"; }
cdp_status()       { printf '%s' "${CLOUD_DEPLOY_STATUS[$1]:-stub}"; }
cdp_emits()        { printf '%s' "${CLOUD_DEPLOY_EMITS[$1]:-}"; }
cdp_check()        { printf '%s' "${CLOUD_DEPLOY_CHECK[$1]:-}"; }
cdp_is_full()      { [ "$(cdp_status "$1")" = "full" ]; }
# Deep-link URL with {domain} substituted (empty if the provider has none).
cdp_deeplink() {
    local url="${CLOUD_DEPLOY_DEEPLINK[$1]:-}"
    printf '%s' "${url//\{domain\}/${CD_DOMAIN:-}}"
}

# ── Shared render helpers ──────────────────────────────────────────────────────
# A cloud-safe resource-name slug from the domain: lowercase [a-z0-9-], which is
# legal for S3 buckets, Azure resource groups AND (hyphens stripped by callers
# that need it) storage accounts. Falls back to "snapdragon" when no domain.
_cdp_name_slug() {
    local slug
    slug="$(printf '%s' "${CD_DOMAIN:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
    slug="${slug%%-}"; slug="${slug##-}"
    printf '%s' "${slug:-snapdragon}"
}

# The standalone TTY confirmation gate INLINED into every emitted apply/destroy
# script. It re-confirms even when the driver already confirmed — the scripts
# are operator-runnable on their own, so each one carries its own fail-safe.
# CD_ASSUME_YES=1 is honoured ONLY for hermetic tests (mirrors GL_ASSUME_YES).
_cdp_gate() {
    cat <<'GATE'
confirm() {
    [ "${CD_ASSUME_YES:-0}" = "1" ] && return 0
    if [ ! -t 0 ]; then
        echo "refusing: this script MUTATES cloud state and stdin is not a TTY." >&2
        echo "Run it interactively and confirm (CD_ASSUME_YES=1 exists for hermetic tests only)." >&2
        exit 1
    fi
    local ans=""
    read -r -p "$1 [y/N] " ans || exit 1
    case "${ans}" in y|Y|yes|YES) return 0 ;; *) echo "aborted — nothing mutated." >&2; exit 1 ;; esac
}
GATE
}

# ── EMIT: aws-ec2 (#1) — RAW upload -> import-snapshot -> UEFI+ENA AMI ─────────
# Writes into $1 (an output dir already created by the driver):
#   apply.sh                     upload-and-import (the ONLY aws-mutating script)
#   vmimport-trust-policy.json   the vmimport service-role trust policy
#   vmimport-role-policy.json    the vmimport role policy (S3 read + EC2 snapshot)
#   status.sh                    read-only progress checks (import task / AMI)
#   destroy.sh                   deregister the AMI + delete snapshot/S3 object
#   keys-volume.md               how the node finds its KEYS volume on EC2
#   checklist.md                 the honest caveats (ENA kernel config, UEFI, …)
cdp_emit_aws-ec2() {
    local out="$1"
    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local slug; slug="$(_cdp_name_slug)"
    local bucket="${slug}-snapdragon-import"
    local key; key="$(basename "${CD_IMAGE:-snapdragon-x86.img}")"
    local ami_name="snapdragon-${slug}-$(date -u +%Y%m%d)"

    # --- apply.sh : %q config header + quoted-heredoc body (injection-safe) ---
    {
        printf '#!/usr/bin/env bash\n'
        printf '# apply.sh — emitted %s by snapdragon-cloud-deploy (provider aws-ec2).\n' "${now}"
        printf '# Uploads the RAW image to S3, imports it as an EBS snapshot, and registers a\n'
        printf '# UEFI+ENA AMI. Credentials are referenced by FILE PATH only\n'
        printf '# (AWS_SHARED_CREDENTIALS_FILE) — never on argv, never baked in here.\n'
        printf '# Re-run safe: s3 mb tolerates an existing bucket; the vmimport role is\n'
        printf '# create-if-missing; a fresh import task + AMI is minted per run.\n'
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        printf 'IMAGE=%q\n'  "${CD_IMAGE:-}"
        printf 'REGION=%q\n' "${CD_REGION:-}"
        printf 'CREDS=%q\n'  "${CD_CREDS_FILE:-}"
        printf 'BUCKET="${CD_BUCKET:-%s}"\n'   "${bucket}"
        printf 'KEY="${CD_S3_KEY:-%s}"\n'      "${key}"
        printf 'AMI_NAME="${CD_AMI_NAME:-%s}"\n' "${ami_name}"
        _cdp_gate
        cat <<'BODY'
die() { echo "apply[aws-ec2]: $*" >&2; exit 1; }
[ -n "${IMAGE}" ]  || die "no image baked — re-plan with --image <packaged .img from cloud-package.sh>"
[ -r "${IMAGE}" ]  || die "image not readable: ${IMAGE}"
[ -n "${REGION}" ] || die "no region baked — re-plan with --region (e.g. us-east-1)"
if [ -n "${CREDS}" ]; then
    [ -r "${CREDS}" ] || die "creds file not readable: ${CREDS}"
    export AWS_SHARED_CREDENTIALS_FILE="${CREDS}"
fi
confirm "Upload ${IMAGE} to s3://${BUCKET}/${KEY} and register AMI '${AMI_NAME}' in ${REGION}?"

# 1. Staging bucket (create-if-missing; mb on an existing own bucket errors -> tolerated).
aws --region "${REGION}" s3 mb "s3://${BUCKET}" 2>/dev/null || true
aws --region "${REGION}" s3 cp "${IMAGE}" "s3://${BUCKET}/${KEY}" || die "s3 upload failed"

# 2. The vmimport SERVICE ROLE (AWS's fixed name; create-if-missing from the
#    emitted policy JSONs sitting beside this script).
if ! aws iam get-role --role-name vmimport >/dev/null 2>&1; then
    aws iam create-role --role-name vmimport \
        --assume-role-policy-document "file://${HERE}/vmimport-trust-policy.json" \
        || die "vmimport role create failed"
    aws iam put-role-policy --role-name vmimport --policy-name vmimport \
        --policy-document "file://${HERE}/vmimport-role-policy.json" \
        || die "vmimport role policy attach failed"
fi

# 3. Import the RAW image as an EBS snapshot and wait for it.
TASK="$(aws --region "${REGION}" ec2 import-snapshot \
    --description "snapdragon cloud-deploy ${KEY}" \
    --disk-container "Format=RAW,UserBucket={S3Bucket=${BUCKET},S3Key=${KEY}}" \
    --query 'ImportTaskId' --output text)" || die "import-snapshot failed"
[ -n "${TASK}" ] || die "import-snapshot returned no task id"
SNAP=""
for _ in $(seq 1 "${CD_WAIT_MAX:-360}"); do
    read -r STATUS SNAP <<EOF2
$(aws --region "${REGION}" ec2 describe-import-snapshot-tasks --import-task-ids "${TASK}" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.[Status,SnapshotId]' --output text)
EOF2
    case "${STATUS}" in
        completed) break ;;
        deleted|deleting) die "import task ${TASK} failed (${STATUS})" ;;
        *) sleep "${CD_WAIT_SLEEP:-10}" ;;
    esac
done
[ "${STATUS:-}" = "completed" ] && [ -n "${SNAP}" ] && [ "${SNAP}" != "None" ] \
    || die "import task ${TASK} did not complete (last status: ${STATUS:-unknown})"

# 4. Register the AMI: UEFI boot + ENA — the two hard requirements from the
#    checklist (the x86 image is a UEFI/GPT stage4; ENA needs CONFIG_ENA_ETHERNET).
AMI="$(aws --region "${REGION}" ec2 register-image \
    --name "${AMI_NAME}" \
    --architecture x86_64 --virtualization-type hvm \
    --boot-mode uefi --ena-support \
    --root-device-name /dev/xvda \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=${SNAP},DeleteOnTermination=true}" \
    --query 'ImageId' --output text)" || die "register-image failed"

# 5. State hints for `snapdragon-cloud-deploy status` + destroy.sh (paths only).
mkdir -p "${HERE}/state"
printf '%s\n' "${TASK}" > "${HERE}/state/import-task-id"
printf '%s\n' "${SNAP}" > "${HERE}/state/snapshot-id"
printf '%s\n' "${AMI}"  > "${HERE}/state/ami-id"
echo "apply[aws-ec2]: DONE — AMI ${AMI} (snapshot ${SNAP}) in ${REGION}."
echo "Launch it with an EBS KEYS volume attached — see keys-volume.md."
BODY
    } > "${out}/apply.sh" || return 1
    chmod 0755 "${out}/apply.sh" 2>/dev/null || true

    # --- vmimport-trust-policy.json (AWS's documented vmimport trust) ---
    cat > "${out}/vmimport-trust-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "vmie.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "sts:Externalid": "vmimport" } }
    }
  ]
}
EOF

    # --- vmimport-role-policy.json (S3 read on the staging bucket + EC2 snapshot) ---
    cat > "${out}/vmimport-role-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${bucket}", "arn:aws:s3:::${bucket}/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["ec2:ModifySnapshotAttribute", "ec2:CopySnapshot", "ec2:RegisterImage", "ec2:Describe*"],
      "Resource": "*"
    }
  ]
}
EOF

    # --- status.sh : READ-ONLY progress checks (safe to run any time) ---
    {
        printf '#!/usr/bin/env bash\n'
        printf '# status.sh — READ-ONLY aws-ec2 progress checks (no mutation; emitted %s).\n' "${now}"
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        printf 'REGION=%q\n' "${CD_REGION:-}"
        printf 'CREDS=%q\n'  "${CD_CREDS_FILE:-}"
        cat <<'BODY'
[ -n "${CREDS}" ] && [ -r "${CREDS}" ] && export AWS_SHARED_CREDENTIALS_FILE="${CREDS}"
if [ -r "${HERE}/state/import-task-id" ]; then
    aws --region "${REGION}" ec2 describe-import-snapshot-tasks \
        --import-task-ids "$(cat "${HERE}/state/import-task-id")"
fi
if [ -r "${HERE}/state/ami-id" ]; then
    aws --region "${REGION}" ec2 describe-images --image-ids "$(cat "${HERE}/state/ami-id")"
fi
[ -e "${HERE}/state" ] || echo "status[aws-ec2]: no state hints yet — apply.sh has not completed here."
BODY
    } > "${out}/status.sh" || return 1
    chmod 0755 "${out}/status.sh" 2>/dev/null || true

    # --- destroy.sh : deregister AMI + delete snapshot + S3 object ---
    {
        printf '#!/usr/bin/env bash\n'
        printf '# destroy.sh — emitted %s by snapdragon-cloud-deploy (provider aws-ec2).\n' "${now}"
        printf '# Deregisters the AMI and deletes the imported snapshot + staged S3 object.\n'
        printf '# Reads the ids from state/ (written by apply.sh) — refuses when absent.\n'
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        printf 'REGION=%q\n' "${CD_REGION:-}"
        printf 'CREDS=%q\n'  "${CD_CREDS_FILE:-}"
        printf 'BUCKET="${CD_BUCKET:-%s}"\n' "${bucket}"
        printf 'KEY="${CD_S3_KEY:-%s}"\n'    "${key}"
        _cdp_gate
        cat <<'BODY'
die() { echo "destroy[aws-ec2]: $*" >&2; exit 1; }
[ -n "${REGION}" ] || die "no region baked — re-plan with --region"
[ -n "${CREDS}" ] && { [ -r "${CREDS}" ] || die "creds file not readable: ${CREDS}"; export AWS_SHARED_CREDENTIALS_FILE="${CREDS}"; }
AMI="";  [ -r "${HERE}/state/ami-id" ]      && AMI="$(cat "${HERE}/state/ami-id")"
SNAP=""; [ -r "${HERE}/state/snapshot-id" ] && SNAP="$(cat "${HERE}/state/snapshot-id")"
[ -n "${AMI}${SNAP}" ] || die "no state hints under ${HERE}/state — nothing recorded to destroy"
confirm "Deregister ${AMI:-<no ami>} + delete snapshot ${SNAP:-<none>} + s3://${BUCKET}/${KEY}?"
[ -n "${AMI}" ]  && { aws --region "${REGION}" ec2 deregister-image --image-id "${AMI}" || die "deregister-image failed"; }
[ -n "${SNAP}" ] && { aws --region "${REGION}" ec2 delete-snapshot --snapshot-id "${SNAP}" || die "delete-snapshot failed"; }
aws --region "${REGION}" s3 rm "s3://${BUCKET}/${KEY}" 2>/dev/null || true
rm -f "${HERE}/state/ami-id" "${HERE}/state/snapshot-id" "${HERE}/state/import-task-id"
echo "destroy[aws-ec2]: DONE — AMI/snapshot/object removed (bucket + vmimport role kept; delete manually if unwanted)."
BODY
    } > "${out}/destroy.sh" || return 1
    chmod 0755 "${out}/destroy.sh" 2>/dev/null || true

    # --- keys-volume.md : the KEYS media story on EC2 ---
    {
        printf '# KEYS volume on AWS EC2\n\n'
        printf 'On hardware the node provisioner (specs/etc/keys-provision/provision.sh) finds a\n'
        printf 'removable volume LABELLED `KEYS` (blkid -L KEYS, vfat/exfat) and provisions from\n'
        printf 'it. On EC2 there is no USB port — use a small EBS DATA VOLUME instead:\n\n'
        printf '1. Create a 1 GiB EBS volume in the SAME availability zone as the instance.\n'
        printf '2. Attach it (device e.g. /dev/sdf), then from any Linux box or the instance:\n'
        printf '     mkfs.vfat -n KEYS /dev/xvdf        # the LABEL is the contract\n'
        printf '     mount /dev/xvdf /mnt && cp -r <keys-bundle>/* /mnt/ && umount /mnt\n'
        printf '   (the bundle is the gen-provision-keys.sh output for this node.)\n'
        printf '3. Boot: provision.sh discovers the volume by label exactly as it would a USB.\n\n'
        printf 'ALTERNATIVE — `KEYS_PREMOUNTED`: if you bake or cloud-attach the bundle to a\n'
        printf 'known path instead, set KEYS_PREMOUNTED=1 with the bundle mounted at the\n'
        printf "provisioner's expected mount point; it then skips block-device discovery\n"
        printf '(same hook the hermetic tests use). Keys dir referenced at plan time: %s\n\n' "${CD_KEYS_DIR:-/etc/snapdragon/keys}"
        printf 'CUSTODY: the KEYS volume carries private key material — treat the EBS volume\n'
        printf 'like the USB stick: encrypt it (EBS encryption on), detach after first boot,\n'
        printf 'and NEVER snapshot it into an AMI.\n'
    } > "${out}/keys-volume.md"

    # --- checklist.md : the honest caveats ---
    {
        printf '# aws-ec2 deploy checklist (%s)\n\n' "${CD_DOMAIN:-unset-domain}"
        printf -- '- [ ] Image is the PACKAGED RAW x86 artifact from scripts/cloud-package.sh\n'
        printf '      (`--format raw`). ARM board images (rpi5/jetson/frite/orangepi) are\n'
        printf '      u-boot/L4T trees and are NOT cloud-viable — the packager refuses them.\n'
        printf -- '- [ ] KERNEL/ENA — HONEST CAVEAT: `register-image --ena-support` only FLAGS the\n'
        printf '      AMI. The guest kernel must actually carry the ENA driver: verify\n'
        printf '      CONFIG_ENA_ETHERNET=y (or =m, in the initramfs) in the x86 kernel config\n'
        printf '      BEFORE relying on a modern instance type — without it the instance has NO\n'
        printf '      network and no way in. Nitro instances also want CONFIG_BLK_DEV_NVME.\n'
        printf -- '- [ ] UEFI: the x86 stage4 image boots UEFI/GPT; `--boot-mode uefi` matches it.\n'
        printf '      Legacy-BIOS-only instance families will not boot this AMI.\n'
        printf -- '- [ ] vmimport role: apply.sh creates it if missing from the two emitted policy\n'
        printf '      JSONs; an org SCP may require an admin to pre-create it instead.\n'
        printf -- '- [ ] Creds file (%s) stays 0600 and OFF argv — apply.sh exports\n' "${CD_CREDS_FILE:-<unset>}"
        printf '      AWS_SHARED_CREDENTIALS_FILE (a PATH) and nothing else.\n'
        printf -- '- [ ] KEYS volume attached before first boot (keys-volume.md).\n'
        printf -- '- [ ] After launch: the node needs the SAME go-live flow as any host — deploy\n'
        printf '      does NOT open the firewall; posture stays internal until go-live commit.\n'
        printf -- '- [ ] Console: %s\n' "$(cdp_deeplink aws-ec2)"
    } > "${out}/checklist.md"
    return 0
}

# ── EMIT: azure-image (#2) — fixed VHD -> Gen2 managed image + Entra ID notes ──
# Writes into $1:
#   apply.sh                     group -> blob upload -> az image create (Gen2)
#   image-builder-template.json  Azure VM Image Builder template over the VHD
#   entra/README.md              the Entra track overview + the OIDC_ISSUER seam
#   entra/app-registrations.md   az ad app create / Graph equivalents + redirects
#   entra/env/*.env              per-service issuer/JWKS override fragments
#   entra/claims-mapping.md      the HONEST 3 architectural blockers
#   keys-disk.md                 Azure data disk labelled KEYS
#   destroy.sh                   delete the image + staged blob
#   checklist.md                 Gen2-only + hv_* kernel caveats
cdp_emit_azure-image() {
    local out="$1"
    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local slug; slug="$(_cdp_name_slug)"
    local rg="${slug}-snapdragon-rg"
    # Storage-account names: [a-z0-9]{3,24}, no hyphens.
    local sa; sa="$(printf '%s' "${slug}" | tr -d -- '-' | cut -c1-18)vhd"
    local vhd; vhd="$(basename "${CD_IMAGE:-snapdragon-x86.vhd}")"
    local img_name="snapdragon-${slug}-$(date -u +%Y%m%d)"
    local tenant="${CD_ENTRA_TENANT:-<TENANT-ID>}"
    local entra_issuer="https://login.microsoftonline.com/${tenant}/v2.0"
    local entra_jwks="https://login.microsoftonline.com/${tenant}/discovery/v2.0/keys"

    # --- apply.sh : NO credential handling AT ALL — an existing az session is
    #     required. A --creds-file here is a NON-secret env fragment of defaults
    #     (subscription/resource-group overrides) that gets sourced, never a secret.
    {
        printf '#!/usr/bin/env bash\n'
        printf '# apply.sh — emitted %s by snapdragon-cloud-deploy (provider azure-image).\n' "${now}"
        printf '# Uploads the FIXED VHD and creates a Gen2 managed image. This script REFUSES\n'
        printf '# to handle credentials: it requires an EXISTING `az login` session (device\n'
        printf '# code / browser). No password or client secret ever touches argv or this file.\n'
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        printf 'IMAGE=%q\n'    "${CD_IMAGE:-}"
        printf 'LOCATION=%q\n' "${CD_REGION:-}"
        printf 'ENVFILE=%q\n'  "${CD_CREDS_FILE:-}"
        printf 'RG="${CD_AZ_RG:-%s}"\n'        "${rg}"
        printf 'SA="${CD_AZ_SA:-%s}"\n'        "${sa}"
        printf 'CONTAINER="${CD_AZ_CONTAINER:-vhds}"\n'
        printf 'BLOB="${CD_AZ_BLOB:-%s}"\n'    "${vhd}"
        printf 'IMG="${CD_AZ_IMAGE:-%s}"\n'    "${img_name}"
        _cdp_gate
        cat <<'BODY'
die() { echo "apply[azure-image]: $*" >&2; exit 1; }
[ -n "${IMAGE}" ]    || die "no image baked — re-plan with --image <fixed .vhd from cloud-package.sh>"
[ -r "${IMAGE}" ]    || die "image not readable: ${IMAGE}"
[ -n "${LOCATION}" ] || die "no location baked — re-plan with --region (e.g. westeurope)"
# Optional NON-SECRET defaults fragment (subscription id, name overrides). It is
# sourced, so it must never contain secrets — the checklist says so too.
if [ -n "${ENVFILE}" ]; then
    [ -r "${ENVFILE}" ] || die "env fragment not readable: ${ENVFILE}"
    # shellcheck source=/dev/null
    . "${ENVFILE}"
fi
az account show >/dev/null 2>&1 \
    || die "no active Azure session — run 'az login' (device code/browser) first; this script never handles your password"
confirm "Upload ${IMAGE} to ${SA}/${CONTAINER}/${BLOB} and create Gen2 image '${IMG}' in ${LOCATION}?"

az group create --name "${RG}" --location "${LOCATION}" --output none || die "group create failed"
# Storage account create-if-missing (name is globally unique; an existing own
# account in this group is fine — the error from a re-run is tolerated).
az storage account create --name "${SA}" --resource-group "${RG}" \
    --location "${LOCATION}" --sku Standard_LRS --allow-blob-public-access false \
    --output none 2>/dev/null || true
az storage container create --account-name "${SA}" --name "${CONTAINER}" \
    --auth-mode login --output none || die "container create failed"
# --type page: Azure images REQUIRE page blobs (the fixed-VHD packaging already
# rounded the size to whole MiB for exactly this).
az storage blob upload --account-name "${SA}" --container-name "${CONTAINER}" \
    --name "${BLOB}" --file "${IMAGE}" --type page --auth-mode login \
    --overwrite --output none || die "blob upload failed"
az image create --resource-group "${RG}" --name "${IMG}" \
    --os-type Linux --hyper-v-generation V2 \
    --source "https://${SA}.blob.core.windows.net/${CONTAINER}/${BLOB}" \
    --output none || die "image create failed"

mkdir -p "${HERE}/state"
printf '%s\n' "${RG}"  > "${HERE}/state/resource-group"
printf '%s\n' "${IMG}" > "${HERE}/state/image-name"
printf 'https://%s.blob.core.windows.net/%s/%s\n' "${SA}" "${CONTAINER}" "${BLOB}" > "${HERE}/state/blob-url"
echo "apply[azure-image]: DONE — image ${IMG} in ${RG} (${LOCATION})."
echo "Create a VM from it with a KEYS data disk attached — see keys-disk.md."
BODY
    } > "${out}/apply.sh" || return 1
    chmod 0755 "${out}/apply.sh" 2>/dev/null || true

    # --- image-builder-template.json : Azure VM Image Builder over the VHD ---
    cat > "${out}/image-builder-template.json" <<EOF
{
  "type": "Microsoft.VirtualMachineImages/imageTemplates",
  "apiVersion": "2024-02-01",
  "location": "${CD_REGION:-<LOCATION>}",
  "properties": {
    "source": {
      "type": "PlatformImage-OR-vhd",
      "_comment": "Set type to 'vhd' and uri to the uploaded fixed VHD (state/blob-url after apply.sh). Azure Image Builder ('image customizer') then layers customizations without a rebuild.",
      "uri": "https://${sa}.blob.core.windows.net/vhds/${vhd}"
    },
    "customize": [
      {
        "type": "Shell",
        "name": "noop-placeholder",
        "inline": ["echo snapdragon image-builder placeholder — add per-tenant customizations here"]
      }
    ],
    "distribute": [
      {
        "type": "ManagedImage",
        "imageId": "/subscriptions/<SUBSCRIPTION-ID>/resourceGroups/${rg}/providers/Microsoft.Compute/images/${img_name}-custom",
        "location": "${CD_REGION:-<LOCATION>}",
        "runOutputName": "snapdragon-managed-image"
      }
    ]
  }
}
EOF

    # --- entra/ : the Entra ID (Azure AD) track — I4 ---
    mkdir -p "${out}/entra/env"
    {
        printf '# Entra ID for a Snapdragon mesh on Azure — READ ME FIRST\n\n'
        printf 'Generated %s. These files are GUIDANCE + config fragments, not an installer.\n\n' "${now}"
        printf 'What works TODAY with zero service-repo changes:\n'
        printf '* Pointing the LOCAL STACK at a different issuer: the generator Makefile has an\n'
        printf '  `OIDC_ISSUER` seam — `make stack-up OIDC_ISSUER=%s`\n' "${entra_issuer}"
        printf '  overrides the derived CASDOOR_ISSUER and threads it into every service via the\n'
        printf '  existing CASDOOR_ISSUER_URI env (the CASDOOR_* env NAMES are cross-repo\n'
        printf '  bindings and are deliberately NOT renamed). Empty/unset = unchanged behavior.\n'
        printf '* Resource-server token VALIDATION against Entra JWTs, for services that accept\n'
        printf '  an issuer+JWKS pair by env (env/ fragments here) — with the CAVEATS below.\n\n'
        printf 'What does NOT work without service-repo changes: see claims-mapping.md — it\n'
        printf 'documents the 3 ARCHITECTURAL blockers honestly. Do not plan an Entra cutover\n'
        printf 'from these fragments alone.\n\n'
        printf 'Files:\n'
        printf '  app-registrations.md   the az ad app create / Graph registration commands\n'
        printf '  env/*.env              per-service issuer/JWKS override fragments\n'
        printf '  claims-mapping.md      Casdoor-claim -> Entra-claim map + the 3 blockers\n'
    } > "${out}/entra/README.md"

    {
        printf '# Entra app registrations for the Snapdragon services\n\n'
        printf 'Tenant: %s\n\n' "${tenant}"
        printf 'One registration per confidential client (mirrors the Casdoor app-per-service\n'
        printf 'model minted by gen-cluster-secrets.sh + casdoor-init). CLI shape (Graph\n'
        printf 'equivalents in brackets):\n\n'
        printf '## user-bff (the browser-facing auth broker)\n'
        printf '    az ad app create --display-name "snapdragon-user-bff" \\\n'
        printf '        --sign-in-audience AzureADMyOrg \\\n'
        printf '        --web-redirect-uris "https://%s/login/callback"\n' "${CD_DOMAIN:-<domain>}"
        printf '    # [Graph: POST /applications {displayName, web.redirectUris}]\n'
        printf '    # Mint the client credential in the PORTAL or via\n'
        printf '    # `az ad app credential reset --id <appId>` — the output is shown ONCE;\n'
        printf '    # store it in your keys layout (0600), NEVER in these artifacts or argv.\n\n'
        printf '## admin-bff\n'
        printf '    az ad app create --display-name "snapdragon-admin-bff" \\\n'
        printf '        --sign-in-audience AzureADMyOrg \\\n'
        printf '        --web-redirect-uris "https://admin.%s/callback"\n' "${CD_DOMAIN:-<domain>}"
        printf '\n## gateways (pki/be/fe) — resource servers, no redirect URIs needed\n'
        printf '    az ad app create --display-name "snapdragon-gateway" --sign-in-audience AzureADMyOrg\n'
        printf '    # Expose an API (Application ID URI) + app roles per service; assign via\n'
        printf '    # [Graph: POST /servicePrincipals/<id>/appRoleAssignedTo].\n\n'
        printf '## desktop / device PKCE public client (snapdragon-desktop analogue)\n'
        printf '    az ad app create --display-name "snapdragon-desktop" \\\n'
        printf '        --is-fallback-public-client true \\\n'
        printf '        --public-client-redirect-uris "http://127.0.0.1/callback"\n\n'
        printf 'Redirect-URI contract: the platform terminates ALL browser auth at user-bff\n'
        printf '(https://%s/login/callback) — under Entra the browser MUST reach\n' "${CD_DOMAIN:-<domain>}"
        printf 'login.microsoftonline.com (see claims-mapping.md blocker 3); the internal-only\n'
        printf 'Casdoor posture does not carry over.\n'
    } > "${out}/entra/app-registrations.md"

    # env fragments — issuer/JWKS overrides per service class. NON-SECRET by
    # construction; client credentials live in the keys layout, never here.
    {
        printf '# stack.env — generator-level Entra override (local stack / Makefile seam)\n'
        printf '# Usage: make stack-up OIDC_ISSUER=%s\n' "${entra_issuer}"
        printf 'OIDC_ISSUER=%s\n' "${entra_issuer}"
    } > "${out}/entra/env/stack.env"
    {
        printf '# gateway.env — pki/be/fe gateway resource-server leg under Entra.\n'
        printf '# NOTE the JWKS path: Entra serves /discovery/v2.0/keys, NOT /.well-known/jwks —\n'
        printf '# every baked /.well-known/jwks pin must move to this value.\n'
        printf 'CASDOOR_ISSUER_URI=%s\n' "${entra_issuer}"
        printf 'CASDOOR_JWKS_URI=%s\n'   "${entra_jwks}"
    } > "${out}/entra/env/gateway.env"
    {
        printf '# user-bff.env — resource-server leg only. The NATIVE login leg\n'
        printf '# (APP_BFF_OIDC_LOGIN_BASE -> Casdoor POST /api/login) has NO Entra equivalent\n'
        printf '# — see claims-mapping.md blocker 3 before enabling any of this.\n'
        printf 'CASDOOR_ISSUER_URI=%s\n' "${entra_issuer}"
        printf 'CASDOOR_JWKS_URI=%s\n'   "${entra_jwks}"
        printf 'APP_BFF_OIDC_ISSUER=%s\n' "${entra_issuer}"
        printf '# APP_BFF_OIDC_CLIENT_ID=<the user-bff app registration appId (a GUID, not app-user-bff)>\n'
        printf '# APP_BFF_OIDC_CLIENT_SECRET stays in your secret store (ESO/Vault) — NEVER here.\n'
    } > "${out}/entra/env/user-bff.env"
    {
        printf '# admin-bff.env — resource-server + session-exchange legs under Entra.\n'
        printf '# APP_CASDOOR_MFA_ENABLED has no Entra analogue (claims-mapping.md blocker 3).\n'
        printf 'CASDOOR_ISSUER_URI=%s\n' "${entra_issuer}"
        printf 'CASDOOR_JWKS_URI=%s\n'   "${entra_jwks}"
        printf 'APP_BFF_OIDC_ISSUER=%s\n' "${entra_issuer}"
    } > "${out}/entra/env/admin-bff.env"

    # --- claims-mapping.md : THE honest document — 3 architectural blockers ---
    {
        printf '# Casdoor -> Entra ID claims mapping — and the 3 blockers that make this\n'
        printf '# a SERVICE-REPO project, not a config swap\n\n'
        printf 'Prod tokens today are Casdoor JWT-Custom with a pinned allow-list (tokenFields\n'
        printf 'Id/Name/Email/IsAdmin/Properties.mfa_satisfied*, tokenAttributes roles/\n'
        printf 'permissions/groups as `<owner>/<name>` strings; `preferred_username` is\n'
        printf 'deliberately NEVER minted — regression-guarded by tests/casdoor/).\n\n'
        printf '| Casdoor claim | Entra v2.0 claim | Compatible? |\n'
        printf '|---|---|---|\n'
        printf '| `sub` (user Id, IDENTICAL across all apps) | `sub` (PAIRWISE per client) | NO — fold on `oid` instead |\n'
        printf '| `name` (identity carrier) | `preferred_username` / `name` | Partial — and `preferred_username` REAPPEARS |\n'
        printf '| `roles` (full platform set, one token) | `roles` (per-app appRole, audience-scoped) | NO — model mismatch |\n'
        printf '| `groups` (`<owner>/<name>` strings) | `groups` (GUIDs, overage -> Graph) | NO — string consumers break |\n'
        printf '| `isAdmin`, `permissions` | (none) | NO equivalent |\n'
        printf '| `mfa_satisfied`/`_at` (Properties stamp) | `acr`/`amr` (different names/types/flow) | NO — flow is Casdoor-API-coupled |\n'
        printf '| JWKS at `/.well-known/jwks` | `/discovery/v2.0/keys` | Path move in every pin |\n\n'
        printf '## Blocker 1 — pairwise `sub`: the canonical identity fold must move to `oid`\n\n'
        printf 'Casdoor mints ONE `sub` per human across all 12 registered apps; the platform\n'
        printf 'folds identity as `casdoor:<subject>` (user-bff CanonicalIdentityResolver — the\n'
        printf 'structural fix that closed the preferred_username takeover class). Entra v2.0\n'
        printf '`sub` is PAIRWISE PER CLIENT: user-bff and admin-bff would derive DIFFERENT\n'
        printf 'canonical keys for the same human, silently splitting accounts. The fold must\n'
        printf 'move to Entra `oid` (tenant-stable object id) — a user-bff/auth-core\n'
        printf 'CanonicalIdentityResolver change with a provider-prefixed key, NOT a config\n'
        printf 'value. Also note: Entra ALWAYS emits `preferred_username`; the config-level\n'
        printf 'mitigation (claim never minted) evaporates — only the structural resolver fix\n'
        printf 'protects you, and the no-preferred-username guard tests will (correctly) fail\n'
        printf 'their premise.\n\n'
        printf '## Blocker 2 — roles/groups model: one-token-all-roles does not exist in Entra\n\n'
        printf 'Casdoor emits the FULL role set (ROLE_ADMIN … desktop-sudo, 20+) and\n'
        printf '`<owner>/<name>` group strings in EVERY token. Entra app roles are audience-\n'
        printf 'scoped (per app registration) and groups are GUIDs with Graph overage. Breaks\n'
        printf 'concretely: headscale `allowed_groups: [snapdragon/headscale]`\n'
        printf '(keys-template/headscale/config.yaml), Harbor `oidc_group_claim_name: "roles"`\n'
        printf '(harbor-provision-job), and sssd `oidc_group_claim = roles` +\n'
        printf '`oidc_groups_allowlist = desktop-sudo` (desktop-governance). Each consumer\n'
        printf 'needs either per-app appRole assignments + a claims-mapping policy, or a\n'
        printf 'Graph-driven sync replacing the Casdoor get-role Jobs. The BFF-chain\n'
        printf 'token-forwarding model (mod-bff -> admin-bff -> federation-api) additionally\n'
        printf 'violates Entra per-resource audiences — every hop needs On-Behalf-Of (OBO),\n'
        printf 'a service-repo change in the custody/exchange chain.\n\n'
        printf '## Blocker 3 — native login + MFA stamping are Casdoor-API-coupled\n\n'
        printf 'The native-login track made Casdoor INTERNAL-ONLY: user-bff drives Casdoor'"'"'s\n'
        printf 'proprietary `POST /api/login` + code exchange server-side; admin-bff stamps\n'
        printf '`mfa_satisfied` into Casdoor user Properties via the Casdoor API for the\n'
        printf 'gateway step-up checks. Entra has NO headless credentials API (ROPC is legacy\n'
        printf 'and blocks MFA/federated users): the browser MUST front-channel to\n'
        printf 'login.microsoftonline.com — i.e. re-introducing the redirect model the\n'
        printf 'native-login track explicitly removed — and the MFA analogue is `acr`/`amr`/\n'
        printf 'auth-context claims with a different shape. Both legs are service-repo work\n'
        printf '(user-bff login flow, admin-bff MFA step-up, gateway claim checks).\n\n'
        printf '## What this emit gives you anyway\n\n'
        printf '* The issuer/JWKS env fragments (env/) for resource-server-only validation\n'
        printf '  experiments, plus the Makefile `OIDC_ISSUER` seam for the local stack.\n'
        printf '* The app-registration commands (app-registrations.md).\n'
        printf '* This document, so the remaining work is scoped honestly: resolver fold on\n'
        printf '  `oid`, per-app roles/OBO, browser-redirect login, Graph-based sync Jobs.\n'
    } > "${out}/entra/claims-mapping.md"

    # --- keys-disk.md : the KEYS media story on Azure ---
    {
        printf '# KEYS disk on Azure\n\n'
        printf 'Same contract as EC2 (keys-volume.md there): the provisioner finds a volume\n'
        printf 'LABELLED `KEYS`. On Azure attach a small DATA DISK:\n\n'
        printf '1. az disk create --resource-group %s --name snapdragon-keys --size-gb 4\n' "${rg}"
        printf '2. Attach to the VM, then format WITH THE LABEL:  mkfs.vfat -n KEYS /dev/sdc\n'
        printf '3. Copy the gen-provision-keys.sh bundle onto it; first boot provisions from it.\n\n'
        printf 'Or pre-mount the bundle and set KEYS_PREMOUNTED=1 (provision.sh hook).\n'
        printf 'CUSTODY: enable server-side encryption on the disk, detach after first boot,\n'
        printf 'never capture it into an image.\n'
    } > "${out}/keys-disk.md"

    # --- destroy.sh ---
    {
        printf '#!/usr/bin/env bash\n'
        printf '# destroy.sh — emitted %s by snapdragon-cloud-deploy (provider azure-image).\n' "${now}"
        printf '# Deletes the managed image + staged VHD blob. Requires an existing az session.\n'
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        printf 'RG="${CD_AZ_RG:-%s}"\n'     "${rg}"
        printf 'SA="${CD_AZ_SA:-%s}"\n'     "${sa}"
        printf 'CONTAINER="${CD_AZ_CONTAINER:-vhds}"\n'
        printf 'BLOB="${CD_AZ_BLOB:-%s}"\n' "${vhd}"
        printf 'IMG="${CD_AZ_IMAGE:-%s}"\n' "${img_name}"
        _cdp_gate
        cat <<'BODY'
die() { echo "destroy[azure-image]: $*" >&2; exit 1; }
az account show >/dev/null 2>&1 || die "no active Azure session — run 'az login' first"
[ -r "${HERE}/state/image-name" ] && IMG="$(cat "${HERE}/state/image-name")"
[ -r "${HERE}/state/resource-group" ] && RG="$(cat "${HERE}/state/resource-group")"
confirm "Delete image ${IMG} (group ${RG}) and blob ${CONTAINER}/${BLOB}?"
az image delete --resource-group "${RG}" --name "${IMG}" --output none || die "image delete failed"
az storage blob delete --account-name "${SA}" --container-name "${CONTAINER}" \
    --name "${BLOB}" --auth-mode login --output none 2>/dev/null || true
rm -f "${HERE}/state/image-name" "${HERE}/state/resource-group" "${HERE}/state/blob-url"
echo "destroy[azure-image]: DONE — image + blob removed (resource group kept; 'az group delete -n ${RG}' to remove everything)."
BODY
    } > "${out}/destroy.sh" || return 1
    chmod 0755 "${out}/destroy.sh" 2>/dev/null || true

    # --- checklist.md ---
    {
        printf '# azure-image deploy checklist (%s)\n\n' "${CD_DOMAIN:-unset-domain}"
        printf -- '- [ ] Image is the FIXED-size VHD from scripts/cloud-package.sh\n'
        printf '      (`--format vhd-fixed` — virtual size rounded UP to whole MiB, subformat\n'
        printf '      fixed + force_size: Azure hard requirements; dynamic VHDX will not work).\n'
        printf -- '- [ ] GEN2 ONLY — BY DESIGN: the x86 stage4 image is UEFI/GPT, so the image is\n'
        printf '      created `--hyper-v-generation V2`. Gen1 (BIOS) is impossible with this\n'
        printf '      artifact — do not try to work around it.\n'
        printf -- '- [ ] KERNEL/Hyper-V — HONEST CAVEAT: the guest needs the Hyper-V paravirt\n'
        printf '      drivers: verify CONFIG_HYPERV_STORAGE (hv_storvsc) and CONFIG_HYPERV_NET\n'
        printf '      (hv_netvsc) =y/=m in the x86 kernel config BEFORE first boot — without\n'
        printf '      them the VM has no disk/network on Azure.\n'
        printf -- '- [ ] CREDENTIALS: apply.sh/destroy.sh require an EXISTING `az login` session\n'
        printf '      and never handle secrets. The optional --creds-file is a NON-SECRET env\n'
        printf '      fragment (subscription/name overrides) — never put a client secret in it.\n'
        printf -- '- [ ] Entra ID: entra/claims-mapping.md BEFORE planning any IdP cutover —\n'
        printf '      3 architectural blockers are documented there honestly.\n'
        printf -- '- [ ] KEYS data disk attached before first boot (keys-disk.md).\n'
        printf -- '- [ ] Go-live posture unchanged: deploying does NOT open the firewall.\n'
        printf -- '- [ ] Portal: %s\n' "$(cdp_deeplink azure-image)"
    } > "${out}/checklist.md"
    return 0
}

# ── EMIT: openshift-cnv (#3) — KubeVirt/CNV DataVolume + VM over the qcow2 ─────
# Writes into $1:
#   datavolume.yaml   CDI DataVolume importing the qcow2 (http source or upload)
#   vm.yaml           the KubeVirt VirtualMachine consuming the DataVolume
#   oc-apply.sh       oc apply of both (KUBECONFIG = the creds file, path only)
#   scc-notes.md      restricted-v2 / Routes-vs-Ingress / no-Calico deltas
#   rhel-notes.md     plain-RHEL libvirt alternative (virt-install one-liner)
#   destroy.sh        oc delete of both
cdp_emit_openshift-cnv() {
    local out="$1"
    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local slug; slug="$(_cdp_name_slug)"
    local ns="${CD_OPENSHIFT_NS:-snapdragon-cnv}"
    local name="snapdragon-${slug}"
    local qcow; qcow="$(basename "${CD_IMAGE:-snapdragon-x86.qcow2}")"

    cat > "${out}/datavolume.yaml" <<EOF
# DataVolume — CDI imports the packaged qcow2 into a PVC (emitted ${now}).
# Source options (pick ONE):
#   http:  point url at any https server hosting ${qcow} (shown below), OR
#   upload: replace 'source' with '{upload: {}}' and push the file with
#           'virtctl image-upload dv ${name} --image-path ${CD_IMAGE:-<qcow2>}'.
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  source:
    http:
      url: "https://REPLACE-WITH-YOUR-ARTIFACT-HOST/${qcow}"
  storage:
    resources:
      requests:
        storage: 32Gi
EOF

    cat > "${out}/vm.yaml" <<EOF
# VirtualMachine — boots the imported DataVolume under OpenShift Virtualization
# (emitted ${now}). UEFI firmware matches the x86 stage4 artifact.
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  running: false   # start explicitly: virtctl start ${name} -n ${ns}
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${name}
    spec:
      domain:
        firmware:
          bootloader:
            efi:
              secureBoot: false
        cpu:
          cores: 4
        memory:
          guest: 8Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ${name}
EOF

    # --- oc-apply.sh : the apply-phase executable (KUBECONFIG by path only) ---
    {
        printf '#!/usr/bin/env bash\n'
        printf '# oc-apply.sh — emitted %s by snapdragon-cloud-deploy (provider openshift-cnv).\n' "${now}"
        printf '# Applies datavolume.yaml + vm.yaml. The kubeconfig is referenced by PATH only\n'
        printf '# (KUBECONFIG env) — never parsed, never on argv.\n'
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        printf 'CREDS=%q\n' "${CD_CREDS_FILE:-}"
        printf 'NS=%q\n'    "${ns}"
        _cdp_gate
        cat <<'BODY'
die() { echo "apply[openshift-cnv]: $*" >&2; exit 1; }
[ -n "${CREDS}" ] || die "no kubeconfig baked — re-plan with --creds-file <kubeconfig>"
[ -r "${CREDS}" ] || die "kubeconfig not readable: ${CREDS}"
export KUBECONFIG="${CREDS}"
confirm "oc apply the ${NS} DataVolume + VirtualMachine to the CURRENT kubeconfig cluster?"
oc get ns "${NS}" >/dev/null 2>&1 || oc create namespace "${NS}" || die "namespace create failed"
oc apply -f "${HERE}/datavolume.yaml" || die "datavolume apply failed"
oc apply -f "${HERE}/vm.yaml"         || die "vm apply failed"
mkdir -p "${HERE}/state"
printf '%s\n' "${NS}" > "${HERE}/state/namespace"
echo "apply[openshift-cnv]: DONE — watch the import: oc get dv -n ${NS} ; start: virtctl start -n ${NS} <vm>"
BODY
    } > "${out}/oc-apply.sh" || return 1
    chmod 0755 "${out}/oc-apply.sh" 2>/dev/null || true

    # --- scc-notes.md : the vanilla-k8s -> OpenShift delta, honestly ---
    {
        printf '# OpenShift deltas — what changes vs the vanilla kubeadm/kind story\n\n'
        printf 'This provider boots the NODE IMAGE as a VM under CNV. Running the PLATFORM\n'
        printf 'WORKLOADS directly on OpenShift instead is a larger port; the known deltas\n'
        printf '(from the cloud recon of specs/cluster):\n\n'
        printf '* SCC `restricted-v2` is the default: the hardened runAsNonRoot/drop-ALL BFF\n'
        printf '  Deployments port as-is, but attestation-server (runAsUser 0 -> needs anyuid),\n'
        printf '  headwind (fixed uid 1000 vs arbitrary-UID assignment), the nvidia device\n'
        printf '  plugin (privileged -> use the GPU Operator), and every hostNetwork/hostPath\n'
        printf '  consumer (ingress DSes, lan-dns, local-path, /dev/dri users) need SCC grants\n'
        printf '  or rework. The Kyverno securitycontext AUDIT report is a ready-made drift list.\n'
        printf '* CNI: do NOT install Calico (apps/01-calico.yaml) — OpenShift ships\n'
        printf '  OVN-Kubernetes; layering tigera-operator over it is destructive. Drop the app.\n'
        printf '* Ingress: apps/10/11 (ingress-nginx) are replaced by OpenShift Routes / the\n'
        printf '  built-in IngressController; the snapdragon-gateway chart Ingress objects need\n'
        printf '  Route equivalents (or rely on auto-generation minus the nginx annotations).\n'
        printf '* Storage: rancher.io/local-path + /mnt/data assumptions -> ODF/LVMS classes.\n'
        printf '* Bootstrap: bootstrap.sh (kubeadm + curl-installed ArgoCD + amd64 patch loop)\n'
        printf '  conflicts with the OpenShift GitOps operator model; keys-provision/firstboot\n'
        printf '  are Gentoo-image-specific. Nothing Ignition-shaped exists in-tree today.\n'
        printf '* Scheduling: everything selects snapdragon.systems/* capability labels — a\n'
        printf '  MachineSet/labeling story is required on any managed cluster.\n\n'
        printf 'CNV itself: the DataVolume/VM here assume the CNV (or upstream KubeVirt+CDI)\n'
        printf 'operator is installed and the namespace can schedule VMs.\n'
    } > "${out}/scc-notes.md"

    # --- rhel-notes.md : plain-RHEL libvirt alternative ---
    {
        printf '# Plain RHEL host (no OpenShift): run the qcow2 under libvirt\n\n'
        printf 'RHEL-family hosts (rhel/centos/rocky/alma — same families scripts/studio-launch.sh\n'
        printf 'detects) can boot the SAME packaged qcow2 with virt-install, no cluster at all:\n\n'
        printf '    virt-install --name %s --memory 8192 --vcpus 4 \\\n' "${name}"
        printf '        --disk path=%s,format=qcow2,bus=virtio \\\n' "${CD_IMAGE:-/var/lib/libvirt/images/${qcow}}"
        printf '        --import --boot uefi --osinfo linux2022 --network default --noautoconsole\n\n'
        printf 'Attach the KEYS media as a second disk (label KEYS — same provisioning contract\n'
        printf 'as the aws/azure notes) or virtiofs-share a pre-mounted bundle with\n'
        printf 'KEYS_PREMOUNTED=1. Console: virsh console %s\n' "${name}"
    } > "${out}/rhel-notes.md"

    # --- destroy.sh ---
    {
        printf '#!/usr/bin/env bash\n'
        printf '# destroy.sh — emitted %s by snapdragon-cloud-deploy (provider openshift-cnv).\n' "${now}"
        printf 'set -uo pipefail\n'
        printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        printf 'CREDS=%q\n' "${CD_CREDS_FILE:-}"
        printf 'NS=%q\n'    "${ns}"
        _cdp_gate
        cat <<'BODY'
die() { echo "destroy[openshift-cnv]: $*" >&2; exit 1; }
[ -n "${CREDS}" ] || die "no kubeconfig baked — re-plan with --creds-file <kubeconfig>"
[ -r "${CREDS}" ] || die "kubeconfig not readable: ${CREDS}"
export KUBECONFIG="${CREDS}"
confirm "oc delete the ${NS} VirtualMachine + DataVolume (the VM disk PVC goes with it)?"
oc delete -f "${HERE}/vm.yaml" --ignore-not-found || die "vm delete failed"
oc delete -f "${HERE}/datavolume.yaml" --ignore-not-found || die "datavolume delete failed"
rm -f "${HERE}/state/namespace"
echo "destroy[openshift-cnv]: DONE (namespace kept; 'oc delete ns ${NS}' to remove it)."
BODY
    } > "${out}/destroy.sh" || return 1
    chmod 0755 "${out}/destroy.sh" 2>/dev/null || true
    return 0
}

# ── EMIT: generic-qcow2 (#4) — libvirt XML + PaaS notes, NO cloud CLI ──────────
# The catch-all: any host/PaaS that takes a qcow2. Emits NO apply.sh at all —
# there is nothing remote for the driver to mutate; the operator runs the
# virt-install one-liner (or uploads per paas-upload.md) themselves.
cdp_emit_generic-qcow2() {
    local out="$1"
    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local slug; slug="$(_cdp_name_slug)"
    local name="snapdragon-${slug}"
    local img="${CD_IMAGE:-/var/lib/libvirt/images/snapdragon-x86.qcow2}"

    cat > "${out}/domain.xml" <<EOF
<!-- libvirt domain for the packaged Snapdragon qcow2 (emitted ${now}).
     UEFI firmware to match the x86 stage4 artifact; virtio disk + net.
     Define + start:  virsh define domain.xml && virsh start ${name} -->
<domain type="kvm">
  <name>${name}</name>
  <memory unit="GiB">8</memory>
  <vcpu>4</vcpu>
  <os firmware="efi">
    <type arch="x86_64" machine="q35">hvm</type>
  </os>
  <devices>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="${img}"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <interface type="network">
      <source network="default"/>
      <model type="virtio"/>
    </interface>
    <console type="pty"/>
  </devices>
</domain>
EOF

    {
        printf '# virt-install one-liner (alternative to domain.xml)\n\n'
        printf '    virt-install --name %s --memory 8192 --vcpus 4 \\\n' "${name}"
        printf '        --disk path=%s,format=qcow2,bus=virtio \\\n' "${img}"
        printf '        --import --boot uefi --osinfo linux2022 --network default --noautoconsole\n\n'
        printf 'KEYS media: attach a second disk/USB labelled KEYS carrying the\n'
        printf 'gen-provision-keys.sh bundle (the provision.sh contract), or pre-mount it and\n'
        printf 'set KEYS_PREMOUNTED=1. First boot provisions from it exactly like hardware.\n\n'
        printf 'NOTE: this provider mutates nothing remote — there is no apply.sh, and\n'
        printf '`snapdragon-cloud-deploy apply` will point you back here by design.\n'
    } > "${out}/virt-install.md"

    {
        printf '# Uploading the qcow2 to a qcow2-taking provider\n\n'
        printf 'Most non-hyperscaler providers take a raw/qcow2 image directly — the SAME\n'
        printf 'packaged artifact works. Typical flows (consult your provider'"'"'s docs):\n\n'
        printf '* Hetzner: boot a rescue system, dd/qemu-img the qcow2 onto the target disk.\n'
        printf '* DigitalOcean: "Custom Images" -> upload the qcow2 (or a URL to it).\n'
        printf '* Proxmox: qm importdisk <vmid> %s <storage>\n' "$(basename "${img}")"
        printf '* OpenStack: openstack image create --disk-format qcow2 --file %s %s\n\n' "$(basename "${img}")" "${name}"
        printf 'INVARIANTS that carry over from the checklists: UEFI boot (the artifact is\n'
        printf 'UEFI/GPT), virtio drivers are in-kernel, and the KEYS media contract is the\n'
        printf 'same everywhere. Deploying never opens the firewall — go-live is separate.\n'
    } > "${out}/paas-upload.md"

    # --- destroy.sh : local libvirt teardown (the only mutation this provider has) ---
    {
        printf '#!/usr/bin/env bash\n'
        printf '# destroy.sh — emitted %s by snapdragon-cloud-deploy (provider generic-qcow2).\n' "${now}"
        printf '# LOCAL libvirt teardown only (there is nothing remote). Leaves the qcow2 file.\n'
        printf 'set -uo pipefail\n'
        printf 'NAME=%q\n' "${name}"
        _cdp_gate
        cat <<'BODY'
die() { echo "destroy[generic-qcow2]: $*" >&2; exit 1; }
command -v virsh >/dev/null 2>&1 || die "virsh not found — this teardown is for the local-libvirt flow only"
confirm "virsh destroy + undefine domain '${NAME}' (the qcow2 file is NOT deleted)?"
virsh destroy "${NAME}" 2>/dev/null || true   # not running is fine
virsh undefine --nvram "${NAME}" || die "undefine failed"
echo "destroy[generic-qcow2]: DONE — domain removed; disk file left in place."
BODY
    } > "${out}/destroy.sh" || return 1
    chmod 0755 "${out}/destroy.sh" 2>/dev/null || true
    return 0
}

# ── Dispatch: driver calls this ONLY ───────────────────────────────────────────
# Renders provider $1's artifacts into dir $2. Returns non-zero on an unknown id.
cdp_emit() {
    local id="$1" out="$2"
    cdp_known "${id}" || return 2
    "cdp_emit_${id}" "${out}"
}
