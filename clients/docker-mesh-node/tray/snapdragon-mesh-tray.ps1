<#
  Snapdragon mesh-node - WINDOWS task-bar tray (FD-09). A NotifyIcon in the system
  tray showing the mesh-node container state, with Join / Logs / Leave / Refresh /
  Exit. Actions shell out to mesh-node.cmd (next to this script's parent dir) using
  the keys/role from %APPDATA%\snapdragon-mesh\launch.env. Run hidden at login via
  the Startup shortcut install.ps1 creates. Pairs with the Linux tray
  (snapdragon-mesh-tray.py). Requires Docker Desktop running.
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Container = "snapdragon-mesh-node"
$TrayDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $TrayDir
$Cmd       = Join-Path $RootDir "mesh-node.cmd"
$IconPath  = Join-Path $RootDir "icons\snapdragon-mesh-node.ico"
$CfgDir    = Join-Path $env:APPDATA "snapdragon-mesh"
$Cfg       = Join-Path $CfgDir "launch.env"

function Get-Cfg($key) {
  if (Test-Path $Cfg) {
    $line = Select-String -Path $Cfg -Pattern "^$key=(.*)$" | Select-Object -First 1
    if ($line) { return $line.Matches[0].Groups[1].Value }
  }
  return ""
}

function Invoke-Mesh($action) {
  switch ($action) {
    "up" {
      $a = "-Keys `"$(Get-Cfg 'KEYS')`""
      if (Get-Cfg 'ROLE')  { $a += " -Role $(Get-Cfg 'ROLE')" }
      if (Get-Cfg 'NAME')  { $a += " -Name $(Get-Cfg 'NAME')" }
      if (Get-Cfg 'IMAGE') { $a += " -Image $(Get-Cfg 'IMAGE')" }
      Start-Process -FilePath $Cmd -ArgumentList $a
    }
    "logs" { Start-Process -FilePath "cmd.exe" -ArgumentList "/k `"$Cmd`" -Logs" }
    "stop" { Start-Process -FilePath $Cmd -ArgumentList "-Stop" -WindowStyle Hidden }
  }
}

function Get-MeshState {
  try {
    $running = (& docker inspect -f "{{.State.Running}}" $Container 2>$null)
    if ($running -ne "true") { return "stopped" }
    $js = (& docker exec $Container tailscale status --json 2>$null) -join "`n"
    if ($js -match '"BackendState"\s*:\s*"Running"') { return "joined" }
    if ($js -match '"BackendState"\s*:\s*"NeedsLogin"') { return "registered (awaiting approval)" }
    return "running"
  } catch { return "unknown" }
}

# ── tray icon ──────────────────────────────────────────────────────
$icon = if (Test-Path $IconPath) {
  New-Object System.Drawing.Icon($IconPath)
} else {
  [System.Drawing.SystemIcons]::Application
}
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $icon
$ni.Text = "Snapdragon Mesh"
$ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add("Status: ...")
$statusItem.Enabled = $false
$menu.Items.Add("-") | Out-Null
($menu.Items.Add("Join the mesh")).add_Click({ Invoke-Mesh "up" })
($menu.Items.Add("Show logs")).add_Click({ Invoke-Mesh "logs" })
($menu.Items.Add("Leave the mesh")).add_Click({ Invoke-Mesh "stop" })
$menu.Items.Add("-") | Out-Null
($menu.Items.Add("Exit tray")).add_Click({
  $ni.Visible = $false
  $timer.Stop()
  [System.Windows.Forms.Application]::Exit()
})
$ni.ContextMenuStrip = $menu

# refresh the status label periodically + when the menu opens
$refresh = { $statusItem.Text = "Status: $(Get-MeshState)" }
$menu.add_Opening($refresh)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$timer.add_Tick($refresh)
$timer.Start()
& $refresh

[System.Windows.Forms.Application]::Run()
$ni.Dispose()
