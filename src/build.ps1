<#
.SYNOPSIS
    Builds a Minecraft modpack server image from a pack definition.

.DESCRIPTION
    Reads packs/<name>.env for the provider, ids, image name and heap size, then
    builds src/Dockerfile with those values. Adding a new pack means adding one
    .env file - no Dockerfile changes.

.EXAMPLE
    .\src\build.ps1 -Pack atm10
    Builds dirnei/minecraft_atm_10:7.3 from the pinned version in packs/atm10.env.

.EXAMPLE
    .\src\build.ps1 -Pack atm10 -Latest
    Resolves the newest release from modpacks.ch, builds it, and writes the
    resolved ids back into packs/atm10.env.

.EXAMPLE
    .\src\build.ps1 -Pack atm10 -Push
    Builds and pushes to the registry.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Pack,

    # Override the version id from the pack file for a one-off build.
    [string] $PackVersion,

    [string] $Image,
    [string] $Tag,

    # Normally derived from the pack's Minecraft version; override if needed.
    [string] $JavaVersion,

    # Resolve the newest 'release' version from the API before building.
    [switch] $Latest,

    # Also tag :latest. Implied by -Latest; use this to force it for a pinned build.
    [switch] $TagLatest,

    [switch] $Push,
    [switch] $NoCache
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$packFile = Join-Path $repoRoot "packs\$Pack.env"

if (-not (Test-Path $packFile)) {
    $available = (Get-ChildItem (Join-Path $repoRoot 'packs') -Filter '*.env' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName }) -join ', '
    throw "No pack definition at '$packFile'. Available packs: $available"
}

# Parse KEY=VALUE, ignoring comments and blanks.
$cfg = @{}
foreach ($line in Get-Content $packFile) {
    if ($line -match '^\s*(#|$)') { continue }
    $kv = $line -split '=', 2
    if ($kv.Count -eq 2) { $cfg[$kv[0].Trim()] = $kv[1].Trim() }
}

foreach ($required in @('PACK_PROVIDER', 'PACK_ID')) {
    if (-not $cfg.ContainsKey($required)) { throw "$packFile is missing $required" }
}

$provider = $cfg['PACK_PROVIDER']
$packId = $cfg['PACK_ID']
$version = $cfg['PACK_VERSION']
$versionName = $null

if ($Latest) {
    $uri = "https://api.modpacks.ch/public/$provider/$packId"
    Write-Host "Resolving latest release from $uri"
    $meta = Invoke-RestMethod -Uri $uri -TimeoutSec 60

    $newest = $meta.versions |
        Where-Object { $_.type -eq 'release' } |
        Sort-Object id -Descending |
        Select-Object -First 1

    if (-not $newest) { throw "No 'release' version found for $($meta.name)" }

    $version = "$($newest.id)"
    $versionName = $newest.name
    Write-Host "  $($meta.name) -> $versionName (file id $version)"
}

if ($PackVersion) { $version = $PackVersion }
if (-not $version) { throw "No PACK_VERSION in $packFile - pass -PackVersion or -Latest." }

# The manifest carries a "java" target, but it is unreliable - ATM10, a
# Minecraft 1.21.1 pack, advertises java 8.0.312+7 - so derive the JDK from the
# Minecraft version instead. install-pack.sh applies the same table and fails
# the build with a clear message if the image ends up with the wrong one.
# Unrecognised versions fall through to the newest JDK rather than the oldest:
# an unknown version is far more likely to be newer than 1.21 than older than
# 1.7, and guessing Java 8 for it would fail the build for no reason.
function Get-RequiredJava([string] $mcVersion) {
    if (-not $mcVersion) { return '21' }
    switch -Regex ($mcVersion) {
        '^1\.([789]|1[0-6])(\.|$)' { return '8'  }
        '^1\.(17|18|19)(\.|$)'     { return '17' }
        '^1\.20\.[56]$'            { return '21' }
        '^1\.20(\.|$)'             { return '17' }
        default                    { return '21' }
    }
}

$mcVersion = $null
try {
    $verMeta = Invoke-RestMethod "https://api.modpacks.ch/public/$provider/$packId/$version" -TimeoutSec 60
    $mcVersion = ($verMeta.targets | Where-Object { $_.type -eq 'game' } | Select-Object -First 1).version
}
catch {
    Write-Warning "Could not read the version manifest to determine the Minecraft version: $($_.Exception.Message)"
}

if ($JavaVersion) { $java = $JavaVersion }
elseif ($cfg.ContainsKey('JAVA_VERSION')) { $java = $cfg['JAVA_VERSION'] }
else { $java = Get-RequiredJava $mcVersion }

if (-not $Image) {
    if ($cfg.ContainsKey('IMAGE')) { $Image = $cfg['IMAGE'] } else { $Image = $Pack }
}
if (-not $Tag) {
    if ($versionName) { $Tag = $versionName }
    elseif ($cfg.ContainsKey('TAG')) { $Tag = $cfg['TAG'] }
    else { $Tag = $version }
}

$fullImageName = "$Image`:$Tag"

Write-Host ''
Write-Host "Pack     : $Pack ($provider/$packId, version $version)"
Write-Host "Image    : $fullImageName"
Write-Host "Minecraft: $(if ($mcVersion) { $mcVersion } else { 'unknown' })  ->  Java $java"
Write-Host "Heap     : $($cfg['MEMORY'])  (runtime default; override with MEMORY at docker run)"
Write-Host ''

# --platform is explicit for reproducibility. Nothing in the install is
# architecture-specific any more, so arm64 should work, but it is untested.
$buildArgs = @(
    'build'
    '--platform', 'linux/amd64'
    '--pull'
    '--rm'
    '--progress', 'plain'
    '--build-arg', "PACK_PROVIDER=$provider"
    '--build-arg', "PACK_ID=$packId"
    '--build-arg', "PACK_VERSION=$version"
    '--build-arg', "JAVA_VERSION=$java"
    '-t', $fullImageName
)

# Also tag :latest when we know this really is the newest release, so the
# floating tag never moves backwards after a deliberate build of an old version.
$latestTag = $null
if ($TagLatest -or $Latest) { $latestTag = "$Image`:latest" }
if ($latestTag) { $buildArgs += @('-t', $latestTag) }

if ($cfg.ContainsKey('EXCLUDE_MODS')) {
    $buildArgs += @('--build-arg', "EXCLUDE_MODS=$($cfg['EXCLUDE_MODS'])")
}
if ($NoCache) { $buildArgs += '--no-cache' }
$buildArgs += $PSScriptRoot

# docker writes build progress to stderr. Under Windows PowerShell 5.1 that
# surfaces as NativeCommandError and, with ErrorActionPreference=Stop, aborts
# the build on its very first line of output. Drop to Continue around the
# native calls and rely on $LASTEXITCODE for the actual success check.
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker @buildArgs
    $buildExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousEap
}
if ($buildExit -ne 0) { throw "docker build failed with exit code $buildExit" }

# Persist a successful -Latest resolution so the pack file stays the source of truth.
if ($Latest) {
    $updated = Get-Content $packFile | ForEach-Object {
        if ($_ -match '^\s*PACK_VERSION\s*=') { "PACK_VERSION=$version" }
        elseif ($_ -match '^\s*TAG\s*=') { "TAG=$Tag" }
        else { $_ }
    }
    Set-Content -Path $packFile -Value $updated -Encoding utf8
    Write-Host "Updated $packFile -> PACK_VERSION=$version, TAG=$Tag"
}

if ($Push) {
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($ref in @($fullImageName, $latestTag | Where-Object { $_ })) {
            & docker push $ref
            if ($LASTEXITCODE -ne 0) { $pushExit = $LASTEXITCODE; break }
            $pushExit = 0
        }
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
    if ($pushExit -ne 0) { throw "docker push failed with exit code $pushExit" }
}

Write-Host ''
Write-Host "Built $fullImageName"
if ($latestTag) { Write-Host "      $latestTag" }
