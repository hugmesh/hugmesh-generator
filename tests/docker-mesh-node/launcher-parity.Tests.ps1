# Launcher parity: clients/docker-mesh-node/mesh-node.ps1 (Windows) must hand docker
# the same arguments as clients/docker-mesh-node/mesh-node.sh (Linux). The ONE allowed
# difference: on a host that has /dev/net/tun the Linux launcher adds exactly
# --cap-add=NET_ADMIN --device=/dev/net/tun (Docker Desktop on Windows has no host TUN,
# so the container falls back to userspace networking there).
#
# Both REAL launchers run against tests/docker-mesh-node/bin/docker, a stub that records
# every argument it receives, one per line. The tests compare those lists element by
# element, so an argument with a space in it must arrive as ONE element on both sides.
#
# The Linux launcher decides on TUN with `[ -c /dev/net/tun ]`. To prove BOTH branches on
# any machine (CI runners and the PowerShell container usually have no TUN), the tests also
# run two copies of mesh-node.sh in which only that one test is pointed elsewhere:
# /dev/null (a character device every Linux has) forces the TUN branch, a missing path
# forces the no-TUN branch. The copy step asserts it changed exactly one line, so if the
# launcher's TUN check is ever rewritten this suite fails instead of quietly testing nothing.
#
# Run it with: bash tests/docker-mesh-node/test-launcher-parity.sh

# One row per set of inputs: the Linux spelling, the Windows spelling, extra environment.
BeforeDiscovery {
  $script:Cases = @(
    @{ Label = 'keys folder with a space, role and name'
       ShArgs = @('--keys', '@KEYS_SPACE', '--role', 'user', '--name', 'box1')
       PsArgs = @('-Keys', '@KEYS_SPACE', '-Role', 'user', '-Name', 'box1'); Envs = @{} }
    @{ Label = 'keys only (no role, no name, so no -e at all)'
       ShArgs = @('--keys', '@KEYS_SPACE'); PsArgs = @('-Keys', '@KEYS_SPACE'); Envs = @{} }
    @{ Label = 'a name with a space'
       ShArgs = @('--keys', '@KEYS_SPACE', '--name', 'my pc'); PsArgs = @('-Keys', '@KEYS_SPACE', '-Name', 'my pc'); Envs = @{} }
    @{ Label = 'keys folder with an apostrophe and a dollar sign, superadmin role'
       ShArgs = @('--keys', '@KEYS_ODD', '--role', 'superadmin'); PsArgs = @('-Keys', '@KEYS_ODD', '-Role', 'superadmin'); Envs = @{} }
    @{ Label = 'image from the flag'
       ShArgs = @('--keys', '@KEYS_SPACE', '--image', 'registry.mesh.example/mesh-node:1')
       PsArgs = @('-Keys', '@KEYS_SPACE', '-Image', 'registry.mesh.example/mesh-node:1'); Envs = @{} }
    @{ Label = 'image from SNAP_MESH_IMAGE'
       ShArgs = @('--keys', '@KEYS_SPACE'); PsArgs = @('-Keys', '@KEYS_SPACE')
       Envs = @{ SNAP_MESH_IMAGE = 'registry.mesh.example/mesh-node:env' } }
    @{ Label = 'build first, then run'
       ShArgs = @('--keys', '@KEYS_SPACE', '--build'); PsArgs = @('-Keys', '@KEYS_SPACE', '-Build'); Envs = @{} }
  )
}

BeforeAll {
  $script:Src = if ($env:LAUNCHER_DIR) { $env:LAUNCHER_DIR } else {
    Join-Path $PSScriptRoot '../../clients/docker-mesh-node' | Resolve-Path | ForEach-Object Path }
  $script:Ps1 = Join-Path $Src 'mesh-node.ps1'
  $script:Sh  = Join-Path $Src 'mesh-node.sh'
  $script:Stub = Join-Path $PSScriptRoot 'bin'
  $script:PwshExe = (Get-Process -Id $PID).Path
  $script:TunTokens = @('--cap-add=NET_ADMIN', '--device=/dev/net/tun')

  $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("mesh-node-parity-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force $Work | Out-Null
  $script:Work = (Resolve-Path $Work).Path
  # Key folders with awkward names: a space, and an apostrophe plus a dollar sign.
  $script:KeysSpace = Join-Path $Work 'my keys'
  $script:KeysOdd   = Join-Path $Work "o'brien `$HOME keys"
  New-Item -ItemType Directory -Force $KeysSpace, $KeysOdd | Out-Null

  # The two forced-branch copies of the Linux launcher (see the header).
  $tunTest = '[ -c /dev/net/tun ]'
  $orig = Get-Content -Raw $Sh
  $script:TunCheckCount = ([regex]::Matches($orig, [regex]::Escape($tunTest))).Count
  $script:ShTun   = Join-Path $Work 'mesh-node-tun.sh'
  $script:ShNoTun = Join-Path $Work 'mesh-node-notun.sh'
  Set-Content -NoNewline -Path $ShTun   -Value $orig.Replace($tunTest, '[ -c /dev/null ]')
  Set-Content -NoNewline -Path $ShNoTun -Value $orig.Replace($tunTest, '[ -c /nonexistent/net/tun ]')

  $script:SavedPath = $env:PATH
  $env:PATH = $Stub + [IO.Path]::PathSeparator + $env:PATH

  # Runs one launcher and returns every docker call it made, in order.
  function Invoke-Launcher([string]$Script, [string[]]$Arguments, [hashtable]$Envs = @{}) {
    $log = Join-Path $Work ("stub-" + [guid]::NewGuid().ToString('N'))
    $selfDir = Split-Path -Parent (Resolve-Path $Script).Path
    $env:STUB_LOG = $log
    Remove-Item env:SNAP_MESH_IMAGE -ErrorAction SilentlyContinue
    foreach ($k in $Envs.Keys) { Set-Item "env:$k" $Envs[$k] }
    try {
      if ($Script.EndsWith('.ps1')) { $out = & $PwshExe -NoProfile -File $Script @Arguments 2>&1 | Out-String }
      else                          { $out = & sh $Script @Arguments 2>&1 | Out-String }
      $rc = $LASTEXITCODE
    } finally {
      foreach ($k in $Envs.Keys) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    $calls = @(Get-ChildItem "$log.*.argv" -ErrorAction SilentlyContinue |
      Sort-Object { [int]($_.Name.Substring((Split-Path -Leaf $log).Length + 1).Split('.')[0]) } |
      ForEach-Object {
        # `docker build` gets the launcher's own folder as its context. The forced-branch
        # copies live in a scratch folder, so that one element is named, not compared.
        , @(Get-Content $_.FullName | ForEach-Object { if ($_ -eq $selfDir) { '<launcher folder>' } else { $_ } }) })
    $run = @($calls | Where-Object { $_[0] -eq 'run' })
    [pscustomobject]@{
      Rc    = $rc
      Out   = $out
      Calls = $calls
      Subs  = @($calls | ForEach-Object { $_[0] }) -join ','
      Run   = $(if ($run.Count -eq 1) { $run[0] } else { $null })
    }
  }
  function Show($r) { "rc=$($r.Rc) calls=[$($r.Subs)] run=[$($r.Run -join ' | ')] out=$($r.Out.Trim())" }
  # The run argv with the TUN pair taken out, only if it appears once, adjacent, in order.
  function Remove-TunPair([string[]]$argv) {
    $i = [Array]::IndexOf($argv, $TunTokens[0])
    if ($i -lt 0 -or $i + 1 -ge $argv.Count -or $argv[$i + 1] -ne $TunTokens[1]) { return $null }
    @($argv[0..($i - 1)]) + @($argv[($i + 2)..($argv.Count - 1)])
  }

  # Case arguments name the key folders symbolically (they only exist once BeforeAll ran).
  function Resolve-Args([string[]]$a) {
    @($a | ForEach-Object { if ($_ -eq '@KEYS_SPACE') { $KeysSpace } elseif ($_ -eq '@KEYS_ODD') { $KeysOdd } else { $_ } })
  }
}

AfterAll {
  $env:PATH = $SavedPath
  Remove-Item env:STUB_LOG -ErrorAction SilentlyContinue
  if ($Work -and (Test-Path $Work)) { Remove-Item -Recurse -Force $Work }
}

Describe 'Harness (red here means nothing below counts)' {
  It 'both launchers find the recording stub as docker' {
    (Get-Command docker).Source | Should -Be (Join-Path $Stub 'docker')
    $r = Invoke-Launcher $Ps1 @('-Keys', $KeysSpace)
    $r.Run | Should -Not -BeNullOrEmpty -Because (Show $r)
    $r = Invoke-Launcher $Sh @('--keys', $KeysSpace)
    $r.Run | Should -Not -BeNullOrEmpty -Because (Show $r)
  }
  It 'mesh-node.sh has exactly one TUN check, so the forced copies each changed one line' {
    $TunCheckCount | Should -Be 1 -Because 'the forced-branch copies rewrite "[ -c /dev/net/tun ]"; if the launcher tests TUN another way, update this suite'
  }
  It 'the forced copies really take their branch' {
    (Invoke-Launcher $ShTun @('--keys', $KeysSpace)).Run | Should -Contain $TunTokens[1]
    (Invoke-Launcher $ShNoTun @('--keys', $KeysSpace)).Run | Should -Not -Contain $TunTokens[1]
  }
}

Describe 'docker run: Windows and Linux (no TUN) pass identical arguments' {
  It '<Label>' -ForEach $Cases {
    $s = Invoke-Launcher $ShNoTun (Resolve-Args $ShArgs) $Envs
    $p = Invoke-Launcher $Ps1 (Resolve-Args $PsArgs) $Envs
    $s.Rc | Should -Be 0 -Because (Show $s)
    $p.Rc | Should -Be 0 -Because (Show $p)
    $p.Subs | Should -BeExactly $s.Subs -Because "the same docker calls in the same order. linux: $(Show $s) windows: $(Show $p)"
    for ($i = 0; $i -lt $s.Calls.Count; $i++) {
      ($p.Calls[$i] -join "`n") | Should -BeExactly ($s.Calls[$i] -join "`n") -Because "docker call $i. linux: $(Show $s) windows: $(Show $p)"
    }
  }
}

Describe 'docker run: with TUN the Linux launcher adds exactly the TUN pair and nothing else' {
  It '<Label>' -ForEach $Cases {
    $s = Invoke-Launcher $ShTun (Resolve-Args $ShArgs) $Envs
    $p = Invoke-Launcher $Ps1 (Resolve-Args $PsArgs) $Envs
    $s.Run.Count | Should -Be ($p.Run.Count + 2) -Because "linux: $(Show $s) windows: $(Show $p)"
    $stripped = Remove-TunPair $s.Run
    $stripped | Should -Not -BeNullOrEmpty -Because "the pair must appear once, adjacent, in this order. linux: $(Show $s)"
    ($stripped -join "`n") | Should -BeExactly ($p.Run -join "`n") -Because "linux: $(Show $s) windows: $(Show $p)"
    $p.Run | Should -Not -Contain $TunTokens[0]
    $p.Run | Should -Not -Contain $TunTokens[1]
  }
}

Describe 'the unmodified Linux launcher matches the branch this machine selects' {
  It 'keys folder with a space, role and name' {
    $a = @('--keys', $KeysSpace, '--role', 'user', '--name', 'box1')
    $hasTun = (& sh -c '[ -c /dev/net/tun ] && echo yes || echo no') -eq 'yes'
    $real = Invoke-Launcher $Sh $a
    $forced = Invoke-Launcher $(if ($hasTun) { $ShTun } else { $ShNoTun }) $a
    $real.Run | Should -Not -BeNullOrEmpty -Because (Show $real)
    ($real.Run -join "`n") | Should -BeExactly ($forced.Run -join "`n") -Because "this machine has /dev/net/tun: $hasTun"
  }
}

Describe 'arguments with spaces stay one argument on both sides' {
  It 'the keys bind and the hostname each arrive as one element' {
    $s = Invoke-Launcher $ShNoTun @('--keys', $KeysSpace, '--name', 'my pc')
    $p = Invoke-Launcher $Ps1 @('-Keys', $KeysSpace, '-Name', 'my pc')
    foreach ($r in $s, $p) {
      $r.Run | Should -Contain "${KeysSpace}:/keys:ro" -Because (Show $r)
      $r.Run | Should -Contain 'SNAP_HOSTNAME=my pc' -Because (Show $r)
    }
  }
  It 'a folder name with an apostrophe and a dollar sign is passed through literally' {
    $s = Invoke-Launcher $ShNoTun @('--keys', $KeysOdd)
    $p = Invoke-Launcher $Ps1 @('-Keys', $KeysOdd)
    $s.Run | Should -Contain "${KeysOdd}:/keys:ro" -Because (Show $s)
    $p.Run | Should -Contain "${KeysOdd}:/keys:ro" -Because (Show $p)
  }
}

Describe 'stop and logs pass identical arguments' {
  It 'stop' {
    $s = Invoke-Launcher $Sh @('--stop')
    $p = Invoke-Launcher $Ps1 @('-Stop')
    $s.Subs | Should -Be 'rm'
    ($p.Calls | ForEach-Object { $_ -join ' ' }) -join ';' | Should -BeExactly (($s.Calls | ForEach-Object { $_ -join ' ' }) -join ';')
  }
  It 'logs' {
    $s = Invoke-Launcher $Sh @('--logs')
    $p = Invoke-Launcher $Ps1 @('-Logs')
    $s.Subs | Should -Be 'logs'
    ($p.Calls | ForEach-Object { $_ -join ' ' }) -join ';' | Should -BeExactly (($s.Calls | ForEach-Object { $_ -join ' ' }) -join ';')
  }
}
