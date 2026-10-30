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

if ($Down) {
  Write-Host '==> Tearing down the local stack (docker compose down -v)'
  docker compose -f $Compose --profile social --profile tor down -v
  return
}

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
