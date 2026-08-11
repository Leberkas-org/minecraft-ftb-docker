<#
.SYNOPSIS
    Builds a Minecraft modpack server image from a pack definition.

.DESCRIPTION
    Reads packs/<name>.env for the provider, ids, image name and heap size, then
    builds src/Dockerfile with those values. Adding a new pack means adding one
    .env file - no Dockerfile changes.

    Every build is tagged three ways: :latest, :pack-version-<id> and the
    version name (when the pack file has a TAG).

.EXAMPLE
    .\tools\build.ps1 -Pack atm10
    Builds the pinned version from packs/atm10.env, tagged
    :latest, :pack-version-8558519 and :7.3.

.EXAMPLE
    .\tools\build.ps1 -Pack atm10 -Push
    Builds and pushes every tag to the registry named by IMAGE in the pack file.

.EXAMPLE
    .\tools\build.ps1 -Pack atm10 -Latest
    Resolves the newest release from modpacks.ch, builds it, and writes the
    resolved ids back into packs/atm10.env.

.EXAMPLE
    .\tools\build.ps1 -Pack atm10 -Push
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

    # Used only when the pack file has no IMAGE, so a new pack needs nothing but
    # its ids. Without this the fallback was the bare pack name, which resolves
    # to Docker Hub - a build would succeed and only fail at push.
    [string] $Registry = 'ghcr.io/leberkas-org',

    # Normally derived from the pack's Minecraft version; override if needed.
    [string] $JavaVersion,

    # Resolve the newest 'release' version from the API before building.
    [switch] $Latest,

    [switch] $Push,
    [switch] $NoCache
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\PackFile.ps1"

$packFile = Get-PackFilePath -Pack $Pack
$cfg = Get-PackConfig -PackFile $packFile -Require @('PACK_PROVIDER', 'PACK_ID')

$provider = $cfg['PACK_PROVIDER']
$packId = $cfg['PACK_ID']
$version = $cfg['PACK_VERSION']
$versionName = $null

if ($Latest) {
    Write-Host "Resolving latest release for $provider/$packId"
    $newest = Get-NewestPackVersion -Provider $provider -PackId $packId
    $version = $newest.VersionId
    # Version names are prose ("All the Mods 10-7.3") and cannot be used as a tag.
    $versionName = ConvertTo-DockerTag $newest.VersionName
    Write-Host "  $($newest.PackName) -> $($newest.VersionName) (file id $version, tag $versionName)"
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
    if ($cfg.ContainsKey('IMAGE')) { $Image = $cfg['IMAGE'] } else { $Image = "$Registry/$Pack" }
}
if (-not $Tag) {
    if ($versionName) { $Tag = $versionName }
    elseif ($cfg.ContainsKey('TAG')) { $Tag = $cfg['TAG'] }
}

# Every build carries three tags: the floating one, the provider's version id and
# the human version name (when the pack file or -Latest supplied one).
#
# The id is prefixed rather than published bare: both it and the version name are
# numeric, so a bare tag list reads "7.3, 8558519, latest" and gives no clue which
# number means what - or that 8558519 is a modpacks.ch version id at all.
$tags = @("$Image`:latest", "$Image`:pack-version-$version")
if ($Tag) { $tags += "$Image`:$Tag" }
$tags = $tags | Select-Object -Unique

$fullImageName = $tags[0]

Write-Host ''
Write-Host "Pack     : $Pack ($provider/$packId, version $version)"
Write-Host "Image    : $Image"
Write-Host "Tags     : $(($tags | ForEach-Object { ($_ -split ':')[-1] }) -join ', ')"
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
)
foreach ($t in $tags) { $buildArgs += @('-t', $t) }

if ($cfg.ContainsKey('EXCLUDE_MODS')) {
    $buildArgs += @('--build-arg', "EXCLUDE_MODS=$($cfg['EXCLUDE_MODS'])")
}
if ($NoCache) { $buildArgs += '--no-cache' }
$buildArgs += (Join-Path (Split-Path -Parent $PSScriptRoot) 'src')

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
    $values = @{ PACK_VERSION = $version }
    if ($Tag) { $values['TAG'] = $Tag }
    Set-PackFileValue -PackFile $packFile -Values $values
    Write-Host "Updated $packFile -> PACK_VERSION=$version, TAG=$Tag"
}

if ($Push) {
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($ref in $tags) {
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

# Let a CI job push exactly what was built without re-deriving the tag list.
if ($env:GITHUB_OUTPUT) {
    "image=$Image"                 | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
    "tags=$($tags -join ' ')"      | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
    "primary=$fullImageName"       | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host ''
Write-Host 'Built:'
foreach ($t in $tags) { Write-Host "  $t" }
