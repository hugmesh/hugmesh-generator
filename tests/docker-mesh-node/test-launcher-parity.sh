#!/usr/bin/env bash
# test-launcher-parity.sh — the Windows mesh-node launcher (clients/docker-mesh-node/
# mesh-node.ps1) must give docker the same arguments as the Linux one (mesh-node.sh),
# except the TUN pair the Linux launcher adds when the host has /dev/net/tun.
#
# Runs tests/docker-mesh-node/launcher-parity.Tests.ps1 (Pester 5.6.1). Both launchers
# run for real against a docker stub that records argv; no daemon, no network, no root.
#
# Where PowerShell comes from, in this order:
#   1. `pwsh` on PATH (the .gitlab-ci.yml job runs in the PowerShell image, which has it).
#      Pester 5.6.1 must be importable; PESTER_MODULE_PATH may name a folder holding
#      Pester/5.6.1 to prepend to PSModulePath.
#   2. otherwise docker: the pinned PowerShell image below runs the suite with
#      --network none. Pester comes from PESTER_MODULE_PATH, else from a one-time
#      Save-Module into ${TMPDIR:-/tmp}/hugmesh-pester-5.6.1 (that step needs network).
#   Neither available: SKIPPED, exit 2 (never a silent pass).
#
#   bash tests/docker-mesh-node/test-launcher-parity.sh
#
# What this cannot prove: how Windows turns the argument list into a command line for
# docker.exe, and the cmd.exe `%*` pass-through in mesh-node.cmd (which starts Windows
# PowerShell 5.1, not pwsh 7). That needs a Windows machine with Docker Desktop:
#   mesh-node.cmd -Keys "C:\my keys" -Role user -Name box1
#   docker inspect hugmesh-mesh-node --format "{{json .HostConfig.Binds}} {{json .Config.Env}}"
# must show the bind "C:\my keys:/keys:ro" as ONE entry, SNAP_ROLE=user and SNAP_HOSTNAME=box1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PESTER_VERSION="5.6.1"
# Tag plus the digest measured on 2026-10-21 (pwsh 7.4.6, image built 2024-11-12).
PWSH_IMAGE="${MESH_NODE_PARITY_PWSH_IMAGE:-mcr.microsoft.com/powershell:7.4-ubuntu-22.04@sha256:62300a213a9293916333df2b014cd3a8f22fb0b0b65f2bb446aaf436bcf8c868}"

PESTER_RUN="\$ErrorActionPreference='Stop'; Import-Module Pester -RequiredVersion ${PESTER_VERSION}; \$c=New-PesterConfiguration; \$c.Run.Path='TESTS'; \$c.Output.Verbosity='Detailed'; \$c.Run.Exit=\$true; Invoke-Pester -Configuration \$c"

if command -v pwsh >/dev/null 2>&1; then
  if [ -n "${PESTER_MODULE_PATH:-}" ]; then
    export PSModulePath="${PESTER_MODULE_PATH}${PSModulePath:+:${PSModulePath}}"
  fi
  echo "launcher parity: host pwsh $(pwsh -NoProfile -c '$PSVersionTable.PSVersion.ToString()')"
  exec pwsh -NoProfile -NonInteractive -c "${PESTER_RUN/TESTS/${HERE}/launcher-parity.Tests.ps1}"
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIPPED: launcher parity needs pwsh or a working docker; neither is available here." >&2
  exit 2
fi

MOD="${PESTER_MODULE_PATH:-${TMPDIR:-/tmp}/hugmesh-pester-${PESTER_VERSION}}"
if [ ! -f "${MOD}/Pester/${PESTER_VERSION}/Pester.psd1" ]; then
  echo "launcher parity: fetching Pester ${PESTER_VERSION} into ${MOD} (one time)"
  mkdir -p "${MOD}"
  docker run --rm --network host -v "${MOD}:/psmod" "${PWSH_IMAGE}" pwsh -NoProfile -NonInteractive -c \
    "Save-Module -Name Pester -RequiredVersion ${PESTER_VERSION} -Repository PSGallery -Path /psmod -Force"
fi

echo "launcher parity: ${PWSH_IMAGE} in docker"
exec docker run --rm --name "${MESH_NODE_PARITY_CONTAINER:-launcher-parity-$$}" --network none \
  -v "${REPO}/clients/docker-mesh-node:/repo/clients/docker-mesh-node:ro" \
  -v "${REPO}/tests/docker-mesh-node:/repo/tests/docker-mesh-node:ro" \
  -v "${MOD}:/psmod:ro" -e PSModulePath=/psmod \
  "${PWSH_IMAGE}" pwsh -NoProfile -NonInteractive -c "${PESTER_RUN/TESTS//repo/tests/docker-mesh-node/launcher-parity.Tests.ps1}"
