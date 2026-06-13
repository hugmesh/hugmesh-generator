<#
  Snapdragon mesh-node - WINDOWS onboarding (FD-09). Make THIS machine a background
  Snapdragon mesh node via Docker Desktop, using LOCAL FILE KEYS + a one-line Casdoor
  login. No OS flash. Mirrors mesh-node.sh (Linux). See README.md.

  Usage:
    .\mesh-node.ps1 -Keys .\mykeys [-Role user|mod|admin|superadmin] [-Name HOST]
                    [-Image IMG] [-Build] [-Stop] [-Logs]

  The keys dir mirrors the KEYS-USB layout (tailscale\authkey, login-server,
  casdoor.json, role) the appliance images consume.
#>
[CmdletBinding()]
param(
  [string]$Keys,
  [string]$Role,
  [string]$Name,
  [string]$Image = $(if ($env:SNAP_MESH_IMAGE) { $env:SNAP_MESH_IMAGE } else { "snapdragon/mesh-node:latest" }),
  [switch]$Build,
  [switch]$Stop,
  [switch]$Logs
)
$ErrorActionPreference = "Stop"
$Container = "snapdragon-mesh-node"
$SelfDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Error "docker not found - install Docker Desktop for Windows."; exit 1
}

if ($Stop) { docker rm -f $Container 2>$null | Out-Null; Write-Host "stopped + removed $Container"; exit 0 }
if ($Logs) { docker logs -f $Container; exit 0 }
if ($Build) { Write-Host "building $Image ..."; docker build -t $Image $SelfDir }

if (-not $Keys) { Write-Error "-Keys <dir> is required (the local KEYS folder)."; exit 2 }
if (-not (Test-Path $Keys)) { Write-Error "keys dir not found: $Keys"; exit 2 }
$KeysAbs = (Resolve-Path $Keys).Path

# Docker Desktop (Windows/WSL2) has no host /dev/net/tun, so the container uses
# userspace networking automatically (the entrypoint detects this).
docker rm -f $Container 2>$null | Out-Null
$runArgs = @(
  "run","-d","--name",$Container,"--restart","unless-stopped",
  "-v","${KeysAbs}:/keys:ro",
  "-v","snapdragon-meshnode-state:/var/lib/tailscale"
)
if ($Role) { $runArgs += @("-e","SNAP_ROLE=$Role") }
if ($Name) { $runArgs += @("-e","SNAP_HOSTNAME=$Name") }
$runArgs += $Image
docker @runArgs

Write-Host "mesh-node started (container: $Container). Follow the join + Casdoor login with:"
Write-Host "    docker logs -f $Container      (or:  .\mesh-node.ps1 -Logs)"
Write-Host "Leave the mesh with:  .\mesh-node.ps1 -Stop"
