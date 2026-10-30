#requires -Version 5.1
<#
.SYNOPSIS
  Run the ENTIRE HugMesh stack locally on Docker Desktop for Windows:
  clone every repo, build every service containerized, and run it.

.DESCRIPTION
  The Windows counterpart of `make stack-up`. It needs ONLY Docker Desktop
  (compose v2 ships with it) — no make, no bash on the host. Cloning is done
  inside a tiny throwaway Linux container (the "bootstrap" path) so a Windows
  user needs no git either; pass a GitHub token with -GhToken (or set
  $env:GH_TOKEN) for private-repo / VPN access.

  Steps:
    1. clone/update all repos into .stack-src (in a git:alpine container, or on
       the host if -UseHostGit and git is installed);
    2. docker compose build  (every first-party service from its repo);
    3. docker compose up -d   (core platform; add -Social for tuwunel/Mastodon).

.PARAMETER Env
  test (default) | prod. test = local placeholder issuer/creds (Casdoor at
  http://localhost:8000). prod = real domain/creds (see -CasdoorIssuer + docs).

.PARAMETER GhToken
  GitHub (or GitLab) token for cloning private repos. Falls back to $env:GH_TOKEN
  / $env:GITHUB_TOKEN. On the VPN with public mirrors you may not need it.

.PARAMETER GitBase
  Clone base URL. Default https://github.com/hugmesh. Point at the
  internal mirror on the VPN, e.g. https://gitlab.hugmesh.net/hugmesh.

.PARAMETER Social
  Also bring up the heavy tuwunel/Mastodon social tier (the `social` profile).

.PARAMETER Tor
  Also publish the fe-gateway as a Tor v3 .onion (the `tor` profile) — INBOUND
  reachability over Tor with no public IP/DNS/ports. Read the address from
  tests\stack\tor-onion\hostname once tor publishes it (~30s).

.PARAMETER Down
  Tear the stack down (docker compose down -v) instead of bringing it up.

.PARAMETER UseHostGit
  Clone with the host's git instead of the bootstrap container.

.EXAMPLE
  pwsh -File scripts\stack-up.ps1 -GhToken ghp_xxx
.EXAMPLE
  pwsh -File scripts\stack-up.ps1 -Env prod -CasdoorIssuer https://id.hugmesh.net
.EXAMPLE
  pwsh -File scripts\stack-up.ps1 -Down
#>
[CmdletBinding()]
param(
  [ValidateSet('test','prod')] [string]$Env = 'test',
  [string]$GhToken = $env:GH_TOKEN,
  [string]$GitBase = 'https://github.com/hugmesh',
  [string]$GitRef = 'main',
  [string]$CasdoorIssuer = '',
  [int]$PublicHostPort = 8088,
  [switch]$Social,
  [switch]$Tor,
  [switch]$Down,
  [switch]$UseHostGit
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to this script so it runs from anywhere.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..')
$StackDir  = Join-Path $RepoRoot 'tests\stack'
$StackSrc  = Join-Path $RepoRoot '.stack-src'
$Compose   = Join-Path $StackDir 'compose.local.yaml'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'docker not found. Install Docker Desktop for Windows first.'
}

# ENV -> Casdoor issuer (test = local placeholder; prod = real, must be provided).
if (-not $CasdoorIssuer) {
  if ($Env -eq 'prod') {
    throw 'ENV=prod requires -CasdoorIssuer (e.g. https://id.hugmesh.net).'
  }
  $CasdoorIssuer = 'http://localhost:8000'
}
$env:CASDOOR_ISSUER_URI = $CasdoorIssuer
$env:PUBLIC_HOST_PORT   = "$PublicHostPort"
# Pass STACK_SRC to compose as a RELATIVE posix path so the build contexts resolve
# the same on Windows + Linux engines (compose interprets build.context relative
# to the compose file's dir: tests/stack/ -> repo-root .stack-src is ../../).
$env:STACK_SRC = '../../.stack-src'

# route-access-db OWNER password: compose.local.yaml reads ${ROUTE_ACCESS_DB_PASSWORD:-}
# and no longer spells it. Twin of tests/stack/gen-route-access-env.sh (which every
# `make stack-up` runs first); same contract, read that script's header:
#  - the value lives in tests\stack\.env, compose's OWN auto-loaded env file, so a
#    hand-run `docker compose -f tests\stack\compose.local.yaml ...` gets it too;
#  - this script owns ONE key there: every other line an operator keeps is kept;
#  - created once, NEVER rotated (postgres honours POSTGRES_PASSWORD only when it
#    initialises an empty volume); -Down strips the key after `down -v`;
#  - key missing: migrate tests\stack\.route-access-db.env (an earlier revision's
#    file); else, if the route-access-pg volume EXISTS, adopt the password the
#    project's route-access-db container was created with, or failing that the owner
#    role's name (the compose default before 2026-10-29), with a warning; docker
#    that cannot answer writes nothing and stops; no volume mints a random value.
$DotEnv        = Join-Path $StackDir '.env'
$LegacyEnv     = Join-Path $StackDir '.route-access-db.env'
$RaKey         = 'ROUTE_ACCESS_DB_PASSWORD'
$RaBegin       = '# >>> route-access-db owner password (tests/stack/gen-route-access-env.sh) >>>'
$RaEnd         = '# <<< route-access-db owner password <<<'
$RaLineRe      = '^\s*(export\s+)?' + $RaKey + '\s*=\s*(.*?)\s*$'
$Utf8NoBom     = New-Object System.Text.UTF8Encoding $false

function Read-RaKey([string]$Path) {
  if (-not (Test-Path $Path)) { return '' }
  $v = ''
  foreach ($l in [System.IO.File]::ReadAllLines($Path)) { if ($l -match $RaLineRe) { $v = $Matches[2] } }
  if ($v.Length -ge 2 -and $v[0] -eq $v[-1] -and ('"', "'") -contains [string]$v[0]) { $v = $v.Substring(1, $v.Length - 2) }
  return $v
}
# A SYMLINKED tests\stack\.env (one file shared by several checkouts) stays a link:
# resolve it (through a chain of links) and replace the TARGET atomically in its own
# directory. WriteAllLines on the link would write through it but not atomically, and
# a delete would break every other checkout's link. LinkTarget is PowerShell 7's
# property; Windows PowerShell 5.1 exposes the same thing as .Target.
function Resolve-EnvTarget([string]$Path) {
  for ($i = 0; $i -lt 40; $i++) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return $Path }
    $t = if ($item.PSObject.Properties['LinkTarget']) { $item.LinkTarget } else { @($item.Target)[0] }
    if (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $item.FullName) $t }
    $Path = [System.IO.Path]::GetFullPath($t)
  }
  throw "tests\stack\.env: too many levels of symbolic links"
}
function Write-EnvAtomic([string]$Target, [string[]]$Lines) {
  $dir = Split-Path -Parent $Target
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    throw "tests\stack\.env resolves to $Target, whose directory does not exist. Nothing was written."
  }
  $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Target) + '.tmp.' + [guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllLines($tmp, $Lines, $Utf8NoBom)
    if (Test-Path -LiteralPath $Target) {
      [System.IO.File]::Replace($tmp, $Target, [NullString]::Value)
    } else {
      [System.IO.File]::Move($tmp, $Target)
    }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
  }
}
$DotEnvIsLink = [bool]((Get-Item -LiteralPath $DotEnv -Force -ErrorAction SilentlyContinue).LinkType -eq 'SymbolicLink')
$DotEnv       = Resolve-EnvTarget $DotEnv

function Get-LinesWithoutRaKey([string]$Path) {
  $keep = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path $Path)) { return ,$keep }
  $skip = $false
  foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
    if ($l -eq $RaBegin) { $skip = $true; continue }
    if ($skip) { if ($l -eq $RaEnd) { $skip = $false }; continue }
    if ($l -match $RaLineRe) { continue }
    $keep.Add($l)
  }
  return ,$keep
}

if ($Down) {
  Write-Host '==> Tearing down the local stack (docker compose down -v)'
  docker compose -f $Compose --profile social --profile tor down -v
  if ($LASTEXITCODE -eq 0 -and (Test-Path $DotEnv)) {
    $rest = Get-LinesWithoutRaKey $DotEnv
    if (@($rest | Where-Object { $_.Trim() }).Count -gt 0) {
      Write-EnvAtomic $DotEnv ([string[]]$rest)
    } elseif ($DotEnvIsLink) {
      Write-EnvAtomic $DotEnv ([string[]]@())   # shared through a link: empty it, never delete
    } else {
      Remove-Item -Force $DotEnv
    }
  }
  return
}

$routeAccessPw = Read-RaKey $DotEnv
if (-not $routeAccessPw) {
  $project = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { 'hugmesh-local' }
  $how = ''
  $legacy = Read-RaKey $LegacyEnv
  if ($legacy) {
    $routeAccessPw = $legacy
    $how = "migrated from .route-access-db.env $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
  } else {
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $probe = (docker volume inspect "${project}_route-access-pg" 2>&1 | Out-String)
      $volumeExists = ($LASTEXITCODE -eq 0)
    } finally { $ErrorActionPreference = $savedEap }
    # "docker could not say" (daemon down, wrong context) is NOT "no volume": a fresh
    # value written then would lock an existing volume's gateways out.
    if (-not $volumeExists -and $probe -notmatch '(?i)no such volume') {
      throw "docker could not say whether volume ${project}_route-access-pg exists, so $RaKey was NOT written to tests\stack\.env. Start Docker Desktop and retry."
    }
    if ($volumeExists) {
      $fromCtr = ''
      $savedEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $cid = @(docker ps -a -q --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.service=route-access-db' 2>$null) | Select-Object -First 1
        if ($cid) {
          $envLine = @(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $cid 2>$null) |
            Where-Object { $_ -like 'POSTGRES_PASSWORD=*' } | Select-Object -Last 1
          if ($envLine) { $fromCtr = $envLine.Substring('POSTGRES_PASSWORD='.Length) }
        }
      } finally { $ErrorActionPreference = $savedEap }
      if ($fromCtr) {
        $routeAccessPw = $fromCtr
        $how = "adopted from the existing $project route-access-db container (volume ${project}_route-access-pg predates this file)"
        Write-Warning "$RaKey was missing from tests\stack\.env but volume ${project}_route-access-pg exists; adopted the password its route-access-db container was created with."
      } else {
        $routeAccessPw = 'gateway'   # route-access-db's POSTGRES_USER: the compose default before 2026-10-29
        $how = "adopted: volume ${project}_route-access-pg predates this file and has no container (assumed the pre-2026-10-29 compose default)"
        Write-Warning ("$RaKey was missing from tests\stack\.env but volume ${project}_route-access-pg exists and no " +
          "route-access-db container is left; assuming the compose default before 2026-10-29 (the owner role's name). " +
          "If ANOTHER checkout created this volume, copy $RaKey from that checkout's tests\stack\.env instead.")
      }
      Write-Warning 'Rotate it with -Down (DROPS the stack''s data), or ALTER ROLE in the container and edit tests\stack\.env.'
    } else {
      $bytes = New-Object byte[] 24
      [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
      $routeAccessPw = -join ($bytes | ForEach-Object { $_.ToString('x2') })
      $how = "generated $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    }
  }
  if ($routeAccessPw -notmatch '^[A-Za-z0-9._~-]+$') {
    throw "The $how value for $RaKey is not URL-unreserved; the r2dbc URL would decode it differently. Nothing was written."
  }
  # Keep every other line of an operator-made .env; UTF-8 WITHOUT a BOM (a BOM
  # would glue itself onto the first key compose reads).
  $lines = Get-LinesWithoutRaKey $DotEnv
  $lines.Add($RaBegin)
  $lines.Add('# GENERATED, gitignored, never commit. Must match what the route-access-pg volume')
  $lines.Add('# was initialised with: do not edit or delete it while that volume exists')
  $lines.Add('# (-Down / make stack-down removes both). Other lines in this file are yours and are kept.')
  $lines.Add("# $how")
  $lines.Add("$RaKey=$routeAccessPw")
  $lines.Add($RaEnd)
  Write-EnvAtomic $DotEnv ([string[]]$lines)
  if ($how -like 'migrated*') { Remove-Item -Force -ErrorAction SilentlyContinue $LegacyEnv }
}
if ($routeAccessPw -notmatch '^[A-Za-z0-9._~-]+$') {
  throw "$RaKey in tests\stack\.env holds a character that is not URL-unreserved; the r2dbc URL would decode it differently. Fix the file."
}
# Passed explicitly as well: an inherited (even empty) variable would beat .env.
$env:ROUTE_ACCESS_DB_PASSWORD = $routeAccessPw

# ── 1. Clone / update all repos ────────────────────────────────────────────
Write-Host "==> Cloning all repos into $StackSrc (base=$GitBase ref=$GitRef)"
New-Item -ItemType Directory -Force -Path $StackSrc | Out-Null

if ($UseHostGit) {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw '-UseHostGit set but git is not installed.'
  }
  $env:STACK_SRC = $StackSrc
  $env:GIT_BASE  = $GitBase
  $env:GIT_REF   = $GitRef
  if ($GhToken) { $env:GH_TOKEN = $GhToken }
  # Use git-bash if available; otherwise the script is POSIX sh-compatible enough
  # to run under the bundled bash. Fall back to the bootstrap container if no bash.
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($bash) {
    & bash (Join-Path $ScriptDir 'clone-all-repos.sh')
    if ($LASTEXITCODE -ne 0) { throw 'clone-all-repos.sh failed.' }
  } else {
    Write-Warning 'No bash on PATH; falling back to the bootstrap container.'
    $UseHostGit = $false
  }
}

if (-not $UseHostGit) {
  # Bootstrap container: run the clone script inside alpine/git. Mount the script +
  # the .stack-src target; pass the token via env (never baked into an image).
  $tokenEnv = @()
  if ($GhToken) { $tokenEnv = @('-e', "GH_TOKEN=$GhToken") }
  docker run --rm `
    -v "${ScriptDir}:/scripts:ro" `
    -v "${StackSrc}:/stack-src" `
    -e "STACK_SRC=/stack-src" `
    -e "GIT_BASE=$GitBase" `
    -e "GIT_REF=$GitRef" `
    -e "USE_GH=0" `
    @tokenEnv `
    alpine/git:latest sh /scripts/clone-all-repos.sh
  if ($LASTEXITCODE -ne 0) { throw 'Repo clone (bootstrap container) failed — check token / VPN access.' }
}

# ── 1b. Social tier needs a Mastodon env_file before compose renders it ─────
$profileArgs = @()
if ($Tor) { $profileArgs += @('--profile', 'tor') }
if ($Social) {
  $profileArgs += @('--profile', 'social')
  $mastodonEnv = Join-Path $StackDir '.mastodon.env'
  if (-not (Test-Path $mastodonEnv)) {
    Write-Host '==> Generating dev tests\stack\.mastodon.env (SOCIAL tier)'
    function New-HexSecret { -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) }) }
    @(
      'LOCAL_DOMAIN=localhost'
      "SECRET_KEY_BASE=$(New-HexSecret)$(New-HexSecret)"
      "OTP_SECRET=$(New-HexSecret)$(New-HexSecret)"
      'DB_HOST=mastodon-db'; 'DB_USER=mastodon'; 'DB_NAME=mastodon'; 'DB_PASS=mastodon'
      'REDIS_HOST=mastodon-redis'
    ) | Set-Content -Path $mastodonEnv -Encoding ascii
  }
}

# ── 2. Build every first-party service ─────────────────────────────────────
Write-Host '==> Building all services (docker compose build)'
docker compose -f $Compose @profileArgs build
if ($LASTEXITCODE -ne 0) { throw 'docker compose build failed.' }

# ── 3. Up ──────────────────────────────────────────────────────────────────
Write-Host "==> Starting the stack (ENV=$Env, host port $PublicHostPort, social=$($Social.IsPresent), tor=$($Tor.IsPresent))"
docker compose -f $Compose @profileArgs up -d
if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed.' }

# ── 3b. Reconcile the route-access table (same step `make stack-up` runs) ──
# The postgres image runs /docker-entrypoint-initdb.d ONLY on the volume's first
# init, so an existing stack never receives a route row added since. Re-apply the
# canonical seed in one transaction (additive: an admin's row edits survive, a
# deleted seed row comes back) and print counts only. Needs no psql on the host.
# The seed is COPIED in from the checkout, never read from the container's
# single-file bind mount: that mount pins the inode it had at container start, and
# `git pull` replaces 20-schema.sql with a new file, so a container that kept
# running across the pull would re-apply the OLD seed and report success. It is
# copied, not piped: Windows PowerShell 5.1 re-encodes a pipeline to a native
# command with $OutputEncoding (ASCII), and the seed is not ASCII.
# NO double quote inside any `sh -c` argument below: Windows PowerShell 5.1 (and
# pwsh 7.0-7.2, "Legacy" native argument passing) does not escape an embedded `"`
# when it builds docker's command line, so `-c "SELECT 1"` reached sh as
# `-c SELECT` plus a stray `1` and the readiness loop could never succeed. The sh
# side quotes with '' (a literal ' inside a PowerShell single-quoted string), which
# every PowerShell version passes through unchanged. An unquoted $POSTGRES_PASSWORD
# in a `VAR=value cmd` prefix is an assignment word, so sh never field-splits it.
# tests/stack/test-route-access-reconcile.sh pins this.
Write-Host '==> Reconciling gateway_route_access from the canonical seed'
# The readiness probe is EXPECTED to fail while the database starts, and it
# redirects the native command's output (*> $null). In Windows PowerShell 5.1 and
# pwsh 7.0/7.1 a redirected stderr line becomes an error record, so under this
# script's $ErrorActionPreference = 'Stop' the FIRST not-ready probe ended the
# whole script instead of retrying (reproduced with pwsh 7.1.5). The loop runs
# with 'Continue' and restores the caller's preference in `finally`; the loud
# failure is the throw below, after the full wait.
$ready = $false
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  for ($i = 0; $i -lt 60; $i++) {
    docker compose -f $Compose exec -T route-access-db sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -X -q -h 127.0.0.1 -U gateway -d gateway -v ON_ERROR_STOP=1 -c ''SELECT 1''' *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 2
  }
} finally {
  $ErrorActionPreference = $savedEap
}
if (-not $ready) { throw 'route-access-db did not become reachable within 120s.' }
$before = docker compose -f $Compose exec -T route-access-db sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -X -q -tA -h 127.0.0.1 -U gateway -d gateway -v ON_ERROR_STOP=1 -c ''SELECT count(*) FROM gateway_route_access'''
$SeedSql = Join-Path $RepoRoot 'specs\cluster\manifests\route-access\initdb\20-schema.sql'
docker compose -f $Compose cp $SeedSql route-access-db:/tmp/route-access-seed.sql
if ($LASTEXITCODE -ne 0) { throw 'route-access reconcile: copying the seed into route-access-db failed.' }
docker compose -f $Compose exec -T route-access-db sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -X -q -h 127.0.0.1 -U gateway -d gateway -v ON_ERROR_STOP=1 -1 -f /tmp/route-access-seed.sql'
$applyExit = $LASTEXITCODE
docker compose -f $Compose exec -T route-access-db sh -c 'rm -f /tmp/route-access-seed.sql' | Out-Null
if ($applyExit -ne 0) { throw 'route-access reconcile FAILED (transaction rolled back, table unchanged).' }
$after = docker compose -f $Compose exec -T route-access-db sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -X -q -tA -h 127.0.0.1 -U gateway -d gateway -v ON_ERROR_STOP=1 -c ''SELECT count(*) FROM gateway_route_access'''
Write-Host "    route-access reconcile: $before -> $after rows"

Write-Host ''
Write-Host "Stack up. Front door: http://localhost:$PublicHostPort"
Write-Host "Casdoor (identity):  http://localhost:8000"
if ($Tor) {
  Write-Host "Tor onion: read tests\stack\tor-onion\hostname once tor publishes it (~30s) — open it in Tor Browser"
}
Write-Host "Logs:  docker compose -f `"$Compose`" logs -f"
Write-Host "Down:  pwsh -File scripts\stack-up.ps1 -Down"
