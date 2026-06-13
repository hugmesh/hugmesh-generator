<#
  Snapdragon mesh-node - WINDOWS installer (FD-09). Creates Start-Menu (and optional
  Desktop) shortcuts with the app icon for Join / Status / Leave, writes a launch
  config, and OPTIONALLY adds a login autostart + a task-bar (NotifyIcon) tray. All
  per-user, no admin required. Pairs with the Linux install.sh. See README.md.

  Usage:
    .\install.ps1 -Keys .\mykeys [-Role user|mod|admin|superadmin] [-Name HOST]
                  [-Image IMG] [-Desktop] [-Autostart] [-Tray]
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [string]$Keys,
  [string]$Role,
  [string]$Name,
  [string]$Image,
  [switch]$Desktop,
  [switch]$Autostart,
  [switch]$Tray,
  [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
$SelfDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppName   = "Snapdragon Mesh"
$CfgDir    = Join-Path $env:APPDATA "snapdragon-mesh"
$StartMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Snapdragon Mesh"
$Startup   = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$DesktopDir= [Environment]::GetFolderPath("Desktop")
$IconSrc   = Join-Path $SelfDir "icons\snapdragon-mesh-node.ico"
$IconDst   = Join-Path $CfgDir "snapdragon-mesh-node.ico"
$Cmd       = Join-Path $SelfDir "mesh-node.cmd"
$TraySrc   = Join-Path $SelfDir "tray\snapdragon-mesh-tray.ps1"

function New-Shortcut($Path, $Target, $Arguments, $Icon, $Hidden) {
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($Path)
  $sc.TargetPath = $Target
  if ($Arguments) { $sc.Arguments = $Arguments }
  $sc.WorkingDirectory = $SelfDir
  if ($Icon -and (Test-Path $Icon)) { $sc.IconLocation = "$Icon,0" }
  if ($Hidden) { $sc.WindowStyle = 7 }   # minimized
  $sc.Save()
}

if ($Uninstall) {
  Remove-Item -Recurse -Force $StartMenu -ErrorAction SilentlyContinue
  Remove-Item -Force (Join-Path $Startup "Snapdragon Mesh.lnk") -ErrorAction SilentlyContinue
  Remove-Item -Force (Join-Path $Startup "Snapdragon Mesh Tray.lnk") -ErrorAction SilentlyContinue
  Remove-Item -Force (Join-Path $DesktopDir "Snapdragon Mesh.lnk") -ErrorAction SilentlyContinue
  Write-Host "uninstalled Snapdragon Mesh shortcuts. Config kept at $CfgDir (remove it to fully clean)."
  exit 0
}

if (-not $Keys) { Write-Error "-Keys <dir> is required (the local KEYS folder)."; exit 2 }
if (-not (Test-Path $Keys)) { Write-Error "keys dir not found: $Keys"; exit 2 }
$KeysAbs = (Resolve-Path $Keys).Path

New-Item -ItemType Directory -Force -Path $CfgDir, $StartMenu | Out-Null
if (Test-Path $IconSrc) { Copy-Item -Force $IconSrc $IconDst }
$IconUse = if (Test-Path $IconDst) { $IconDst } else { "" }

# launch config (single source of truth for the shortcuts + tray)
@"
# written by snapdragon mesh-node install.ps1
KEYS=$KeysAbs
ROLE=$Role
NAME=$Name
IMAGE=$Image
"@ | Set-Content -Encoding ASCII (Join-Path $CfgDir "launch.env")

# Build the per-action argument strings for mesh-node.cmd.
$upArgs = "-Keys `"$KeysAbs`""
if ($Role)  { $upArgs += " -Role $Role" }
if ($Name)  { $upArgs += " -Name $Name" }
if ($Image) { $upArgs += " -Image $Image" }

New-Shortcut (Join-Path $StartMenu "Snapdragon Mesh - Join.lnk")   $Cmd $upArgs   $IconUse $false
New-Shortcut (Join-Path $StartMenu "Snapdragon Mesh - Status.lnk") $Cmd "-Logs"   $IconUse $false
New-Shortcut (Join-Path $StartMenu "Snapdragon Mesh - Leave.lnk")  $Cmd "-Stop"   $IconUse $false

if ($Desktop) {
  New-Shortcut (Join-Path $DesktopDir "Snapdragon Mesh.lnk") $Cmd $upArgs $IconUse $false
}

if ($Autostart) {
  New-Shortcut (Join-Path $Startup "Snapdragon Mesh.lnk") $Cmd $upArgs $IconUse $true
  Write-Host "autostart: node will join the mesh at login."
}

if ($Tray) {
  if (Test-Path $TraySrc) {
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = Join-Path $PSHOME "powershell.exe" }
    $trayArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TraySrc`""
    New-Shortcut (Join-Path $Startup "Snapdragon Mesh Tray.lnk") $pwshExe $trayArgs $IconUse $true
    New-Shortcut (Join-Path $StartMenu "Snapdragon Mesh - Tray.lnk") $pwshExe $trayArgs $IconUse $false
    Write-Host "tray: installed (starts at login; launch now from Start Menu > Snapdragon Mesh - Tray)."
  } else {
    Write-Warning "tray script not found at $TraySrc — skipping tray."
  }
}

Write-Host "installed Snapdragon Mesh:"
Write-Host "  Start Menu : '$AppName' (Join / Status / Leave)"
Write-Host "  config     : $CfgDir\launch.env  (KEYS=$KeysAbs ROLE=$Role)"
Write-Host "Join now from the Start Menu, or:  .\mesh-node.ps1 $upArgs"
