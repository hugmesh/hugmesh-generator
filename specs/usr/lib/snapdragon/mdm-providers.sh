# shellcheck shell=bash
# mdm-providers.sh — the MDM PROVIDER REGISTRY for the phone wizard.
#
# This is a SOURCEABLE data + emit library, not an executable. The phone driver
# (scripts/phone-wizard.sh) sources it, and every thin front-end (the Makefile
# phone-* face, the ncurses phone_screen; Studio LATER) reaches the providers
# only THROUGH the driver — so this file is the single place that describes
# "what device-management backends exist and how each one enrolls a handset". It
# deliberately mirrors go-live-providers.sh (the go-live wizard's edge-provider
# registry): the same MDM_PROVIDER_IDS list + parallel associative arrays +
# ONE emit function `mdmp_emit_<id>` per provider + a `mdmp_emit` dispatcher the
# driver calls, never hard-coding a provider id.
#
# WHY a registry and not a two-way `if`: Headwind stays the sovereign DEFAULT,
# but Azure Intune is a co-equal, opt-in second provider — and the design leaves
# room for a third. The driver validates `--mdm-provider` against the registry
# (mdmp_known), branches its ACTIONS on the provider's MECHANISM (not its id),
# and renders the per-provider enrollment RUNBOOK via mdmp_emit. Add a provider
# by adding a row + an emit here; the driver does not change.
#
# ── The two provider mechanisms ────────────────────────────────────────────────
# MDM_PROVIDER_MECH taxonomy:
#   dpc-adb        — a self-hosted Device Policy Controller (DPC) installed and
#                    promoted to Android device-owner over adb
#                    (`dpm set-device-owner <pkg>/.AdminReceiver`). This is the
#                    SOVEREIGN path: the control plane is our own cluster service,
#                    no third-party SaaS backend, no Google Play-Integrity/FCM
#                    dependency for management traffic. Headwind MDM is this.
#   os-enrollment  — an OS-LEVEL enrollment the operator performs on the handset
#                    itself (Entra device registration + the Company Portal app,
#                    or an Android Enterprise provisioning package) — NOT an adb
#                    `dpm` call. The wizard CANNOT drive the in-OS/Company-Portal
#                    flow over adb, so this provider is RUNBOOK-only: the wizard
#                    prints the enrollment steps and records the resulting
#                    device id the lock leg will target. Azure Intune is this.
#
# The two mechanisms are why the wizard cannot hard-code Headwind's adb flow: an
# os-enrollment provider has NO adb device-owner step at all. The driver reads
# the mechanism from this registry and dispatches accordingly.
#
# ── Sovereignty posture ────────────────────────────────────────────────────────
# MDM_PROVIDER_SOVEREIGNTY: `sovereign` (self-hosted, no external control plane)
# vs `cloud` (a third-party SaaS control plane — Microsoft Graph/Intune). The
# DEFAULT provider is ALWAYS the sovereign one (headwind); selecting a `cloud`
# provider is an explicit per-deployment opt-in that forfeits sovereignty for
# that fleet (Microsoft SaaS dependency). See docs/MDM.md "MDM providers".
#
# CONTEXT the emit functions read (globals the driver sets before calling emit;
# same process, so no export needed — the driver SOURCES this file):
#   MDMP_DEVICE_ID          the stable device id the record is keyed on
#   MDMP_HEADWIND_URL       (headwind) the Headwind server base URL
#   MDMP_HEADWIND_PACKAGE   (headwind) the DPC package (default com.hmdm.launcher)
#   MDMP_INTUNE_DEVICE_ID   (azure-intune) the Graph managedDevice id the remote-
#                           lock leg targets (operator supplies it, or the
#                           runbook explains how to read it from the portal)
#   MDMP_GRAPH_BASE_URL     (azure-intune) Graph base (default v1.0 endpoint)
#   MDMP_AUTH_BASE_URL      (azure-intune) Entra token endpoint host
#
# SECRET CUSTODY: this registry NEVER takes a tenant/client/client-secret on a
# function argument or a global — the Azure client-credentials secret lives only
# in the cluster (the azure-intune ExternalSecret → the admin-bff env), never in
# the wizard, never on argv, never in a runbook. The wizard's job is enrollment +
# recording the device id; the lock leg (admin-bff AzureIntuneLockClient) is the
# only thing that ever holds the Graph secret.

# ── Registry rows ──────────────────────────────────────────────────────────────
# Order here is the PRIORITISED list — the SOVEREIGN default is first. Front-ends
# list in this order; the first id is the default (mdmp_default).
MDM_PROVIDER_IDS=(headwind azure-intune)

declare -gA MDM_PROVIDER_LABEL=(
    [headwind]="Headwind MDM (self-hosted DPC)"
    [azure-intune]="Microsoft Intune (Entra / Graph)"
)
declare -gA MDM_PROVIDER_MECH=(
    [headwind]="dpc-adb"
    [azure-intune]="os-enrollment"
)
# full = implemented end-to-end (enroll runbook + a lock leg on the admin-bff
# side). Both providers are full.
declare -gA MDM_PROVIDER_STATUS=(
    [headwind]="full"
    [azure-intune]="full"
)
declare -gA MDM_PROVIDER_SOVEREIGNTY=(
    [headwind]="sovereign"
    [azure-intune]="cloud"
)
# One-line human summary of what each provider IS / how it locks.
declare -gA MDM_PROVIDER_EMITS=(
    [headwind]="self-hosted DPC promoted to Android device-owner over adb; remote lock via the mesh-owned DPC (sovereign, no SaaS)"
    [azure-intune]="OS-level Entra/Company-Portal enrollment; remote lock via Microsoft Graph managedDevices/{id}/remoteLock (cloud SaaS)"
)

# ── Registry accessors (front-ends + driver use ONLY these) ──────────────────────
mdmp_known()       { [ -n "${MDM_PROVIDER_LABEL[$1]:-}" ]; }
mdmp_label()       { printf '%s' "${MDM_PROVIDER_LABEL[$1]:-$1}"; }
mdmp_mechanism()   { printf '%s' "${MDM_PROVIDER_MECH[$1]:-dpc-adb}"; }
mdmp_status()      { printf '%s' "${MDM_PROVIDER_STATUS[$1]:-stub}"; }
mdmp_sovereignty() { printf '%s' "${MDM_PROVIDER_SOVEREIGNTY[$1]:-cloud}"; }
mdmp_emits()       { printf '%s' "${MDM_PROVIDER_EMITS[$1]:-}"; }
mdmp_is_full()     { [ "$(mdmp_status "$1")" = "full" ]; }
mdmp_is_sovereign(){ [ "$(mdmp_sovereignty "$1")" = "sovereign" ]; }
# The DEFAULT provider — always the first (sovereign) row.
mdmp_default()     { printf '%s' "${MDM_PROVIDER_IDS[0]}"; }

# ── EMIT: headwind — self-hosted DPC device-owner (sovereign default) ────────────
# The adb device-owner ACTIONS themselves stay in the driver (cmd_mdm_enroll's
# dpc-adb branch); this emit renders the operator-facing runbook/summary that
# accompanies them so the front-end has one consistent per-provider narration.
mdmp_emit_headwind() {
    local out="$1"
    local pkg="${MDMP_HEADWIND_PACKAGE:-com.hmdm.launcher}"
    {
        printf 'MDM ENROLL — Headwind MDM (self-hosted DPC, SOVEREIGN default)\n'
        printf '=============================================================\n\n'
        printf 'Mechanism: dpc-adb — the wizard installs the Headwind DPC APK and\n'
        printf 'promotes it to Android device-owner over adb:\n'
        printf '  dpm set-device-owner %s/.AdminReceiver\n\n' "${pkg}"
        printf 'This is the sovereign path: the control plane is your own cluster\n'
        printf 'Headwind service (%s) — NO third-party SaaS, no\n' "${MDMP_HEADWIND_URL:-<--headwind-url>}"
        printf 'Google Play-Integrity / FCM dependency for management traffic.\n\n'
        printf 'Remote lock: the mesh-owned DPC enforces the platform lock on-device\n'
        printf '(paired with the provider-independent headscale mesh-deny leg).\n\n'
        printf 'PREREQUISITE: device-owner mode is a ONE-SHOT AOSP gate — the device\n'
        printf 'must have exactly one user and zero added accounts. mdm-enroll MUST run\n'
        printf 'before profile (which forecloses the window). See docs/MDM.md.\n'
    } > "${out}/runbook.txt"
    return 0
}

# ── EMIT: azure-intune — Microsoft Intune / Graph (cloud SaaS, opt-in) ────────────
# os-enrollment: there is NO adb `dpm` step. Intune enrollment happens IN THE OS
# (Entra device registration + the Company Portal app, or an Android Enterprise
# provisioning package). The wizard prints this runbook and records the resulting
# Graph managedDevice id; the admin-bff AzureIntuneLockClient (holding the Graph
# client-credentials secret, never this wizard) does the remoteLock.
mdmp_emit_azure-intune() {
    local out="$1"
    local graph="${MDMP_GRAPH_BASE_URL:-https://graph.microsoft.com/v1.0}"
    local auth="${MDMP_AUTH_BASE_URL:-https://login.microsoftonline.com}"
    local intune_id="${MDMP_INTUNE_DEVICE_ID:-}"
    {
        printf 'MDM ENROLL — Microsoft Intune (Entra / Graph, CLOUD SaaS — opt-in)\n'
        printf '=================================================================\n\n'
        printf 'SOVEREIGNTY NOTE: selecting azure-intune routes device management\n'
        printf 'through Microsoft Graph/Intune — a third-party SaaS control plane.\n'
        printf 'This FORFEITS the sovereign posture for this fleet. Headwind is the\n'
        printf 'default for a reason; use Intune only where an existing Intune/Entra\n'
        printf 'estate is a hard requirement.\n\n'
        printf 'Mechanism: os-enrollment — Intune enrollment is performed IN THE OS,\n'
        printf 'NOT over adb (`dpm set-device-owner` is a Headwind-only, sovereign\n'
        printf 'mechanism and is NOT used here). Perform these ON THE HANDSET:\n\n'
        printf '  1. Register the device with Entra ID (Microsoft Entra device\n'
        printf '     registration) under the target tenant.\n'
        printf '  2. Install the Intune Company Portal app and sign in with the\n'
        printf '     enrolling Entra account; complete the Company-Portal enrollment\n'
        printf '     flow (or apply your Android Enterprise provisioning package).\n'
        printf '  3. Wait for the device to appear as a managedDevice in the Intune\n'
        printf '     admin center (Devices -> All devices).\n\n'
        printf 'RECORD THE GRAPH DEVICE ID (the remote-lock leg targets it):\n'
        if [ -n "${intune_id}" ]; then
            printf '  intune_device_id = %s   (supplied via --intune-device-id)\n\n' "${intune_id}"
        else
            printf '  Pass --intune-device-id <managedDevice-id>. Obtain it from the\n'
            printf '  Intune admin center (the device blade URL / properties), or via\n'
            printf '  Graph:  GET %s/deviceManagement/managedDevices\n' "${graph}"
            printf '          ?$filter=... (the `id` GUID is the managedDevice id).\n\n'
        fi
        printf 'REMOTE LOCK (control plane, server-side — NOT this wizard):\n'
        printf '  client-credentials token:  POST %s/{tenant}/oauth2/v2.0/token\n' "${auth}"
        printf '     scope=%s/.default\n' "${graph%/v1.0}"
        printf '  lock:  POST %s/deviceManagement/managedDevices/{id}/remoteLock\n\n' "${graph}"
        printf 'UNLOCK ASYMMETRY: Intune has no native force-unlock. The platform\n'
        printf '"unlock" clears the CONTROL-PLANE lock record (and can re-enable the\n'
        printf 'device) — it does NOT push a credential to the handset. A remoteLock\n'
        printf 'is user-unlockable device-side with the existing passcode. See\n'
        printf 'docs/MDM.md "MDM providers".\n\n'
        printf 'SECRET CUSTODY: the tenant / client-id / client-secret NEVER touch\n'
        printf 'this wizard or its argv. They live only in Vault -> the azure-intune\n'
        printf 'ExternalSecret -> the admin-bff env (app.phone-lock.azure-intune.*).\n'
    } > "${out}/runbook.txt"
    return 0
}

# ── Dispatch: driver calls this ONLY ─────────────────────────────────────────────
# Renders provider $1's enrollment runbook into dir $2. Returns 2 on unknown id.
mdmp_emit() {
    local id="$1" out="$2"
    mdmp_known "${id}" || return 2
    "mdmp_emit_${id}" "${out}"
}
