<#
.SYNOPSIS
    Creates a packs/<name>.env for a modpack from its id.

.DESCRIPTION
    Resolves the pack from modpacks.ch, picks its newest release, and writes a
    ready-to-build pack file. The provider is detected automatically - CurseForge
    project ids and FTB pack ids live in different ranges - so usually only the
    id is needed.

    Nothing else has to change: both workflows enumerate packs/*.env, so the new
    pack is picked up by the daily update check and by CI on its own.

.EXAMPLE
    .\tools\propose-pack.ps1 -Id 1298402
    Detects the provider, writes packs/all-the-mods-10-to-the-sky.env.

.EXAMPLE
    .\tools\propose-pack.ps1 -Id 1298402 -Name atm10sky
    Same, but names the file (and therefore the image) atm10sky.

.EXAMPLE
    .\tools\propose-pack.ps1 -Id 103 -Provider modpack -Memory 8G
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Id,

    # Skips auto-detection.
    [ValidateSet('curseforge', 'modpack')]
    [string] $Provider,

    # Pack file name, and therefore the image name. Defaults to a slug of the pack.
    [string] $Name,

    # Heap size. Estimated from the mod count when omitted.
    [string] $Memory,

    # Registry the generated IMAGE line points at.
    [string] $Registry = 'ghcr.io/leberkas-org',

    # Include the newest alpha/beta rather than only releases.
    [switch] $IncludeAll,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\PackFile.ps1"

function Resolve-Provider([string] $id, [string] $forced, [bool] $includeAll) {
    <#
        The two id spaces overlap: 103 is FTB Skies under `modpack`, but is also
        a real CurseForge project ("AlphaMap"). Taking the first namespace that
        answers would happily generate a pack file for the wrong thing, so probe
        both and only proceed when the answer is unambiguous.
    #>
    $candidates = if ($forced) { @($forced) } else { @('curseforge', 'modpack') }
    $found = @()

    foreach ($p in $candidates) {
        try {
            $meta = Invoke-RestMethod "https://api.modpacks.ch/public/$p/$id" -TimeoutSec 60
            if ($meta -and $meta.status -ne 'error' -and $meta.name) {
                $usable = @($meta.versions | Where-Object { $includeAll -or $_.type -eq 'release' })
                $found += [pscustomobject]@{ Provider = $p; Meta = $meta; Usable = $usable.Count }
            }
        }
        catch { }   # the wrong namespace answers 404
    }

    $withVersions = @($found | Where-Object { $_.Usable -gt 0 })

    if ($withVersions.Count -eq 1) { return $withVersions[0] }

    if ($withVersions.Count -gt 1) {
        $lines = $withVersions | ForEach-Object { "  -Provider $($_.Provider)  ->  $($_.Meta.name)" }
        throw "Id '$id' is ambiguous - it exists in both namespaces. Re-run with one of:`n$($lines -join "`n")"
    }

    if ($found.Count -gt 0) {
        $names = ($found | ForEach-Object { "$($_.Provider): $($_.Meta.name)" }) -join '; '
        throw "Found $names for id '$id', but with no usable version. Try -IncludeAll for alpha/beta builds."
    }

    throw "No modpack with id '$id' on modpacks.ch (tried: $($candidates -join ', '))."
}

function ConvertTo-Slug([string] $text) {
    $s = $text.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 48) { $s = $s.Substring(0, 48).Trim('-') }
    $s
}

function ConvertTo-PackName([string] $packName) {
    <#
        Pack names usually end in their own abbreviation - "All the Mods 10 -
        ATM10", "... To the Sky   ATM10SKY" - and that abbreviation is a far
        better image name than a slug of the whole title. Falls back to the slug
        when there is no such token, which is what "FTB Skies" wants anyway.
    #>
    $tokens = @($packName -split '[\s:\-]+' | Where-Object { $_ })
    if ($tokens.Count -gt 1) {
        $last = $tokens[-1]
        # Must mix letters and digits. Requiring a digit is what separates a real
        # abbreviation (ATM10, atm9sky) from a trailing genre word - "Prominence
        # II RPG" would otherwise be published as the image "rpg".
        if ($last.Length -ge 3 -and $last.Length -le 16 -and
            $last -match '^[A-Za-z0-9]+$' -and $last -match '[A-Za-z]' -and $last -match '[0-9]') {
            return $last.ToLowerInvariant()
        }
    }
    ConvertTo-Slug $packName
}

Write-Host "Resolving id $Id ..."
$resolved = Resolve-Provider $Id $Provider ([bool]$IncludeAll)
$provider = $resolved.Provider
$meta = $resolved.Meta

$newest = Get-NewestPackVersion -Provider $provider -PackId $Id -IncludeAll:$IncludeAll
$tag = ConvertTo-DockerTag $newest.VersionName

# The version manifest is where the Minecraft version, modloader and file list
# live; the pack-level document does not carry them.
$mc = ''; $loader = ''; $modCount = 0
try {
    $vm = Invoke-RestMethod "https://api.modpacks.ch/public/$provider/$Id/$($newest.VersionId)" -TimeoutSec 60
    $mc = ($vm.targets | Where-Object { $_.type -eq 'game' } | Select-Object -First 1).version
    $ml = $vm.targets | Where-Object { $_.type -eq 'modloader' } | Select-Object -First 1
    if ($ml) { $loader = "$($ml.name) $($ml.version)" }
    $modCount = @($vm.files | Where-Object { -not $_.clientonly }).Count
}
catch {
    Write-Warning "Could not read the version manifest: $($_.Exception.Message)"
}

if (-not $Memory) {
    # A starting point, not a measurement - modded servers vary wildly.
    $Memory = if ($modCount -ge 300) { '10G' } elseif ($modCount -ge 150) { '8G' } else { '6G' }
}

if (-not $Name) { $Name = ConvertTo-PackName $meta.name }

$packsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'packs'
$packFile = Join-Path $packsDir "$Name.env"

if ((Test-Path $packFile) -and -not $Force) {
    throw "packs/$Name.env already exists. Pass -Force to overwrite, or -Name to choose another."
}

$pageUrl = if ($provider -eq 'curseforge') {
    "https://www.curseforge.com/minecraft/modpacks (project id $Id)"
} else {
    "https://feed-the-beast.com/modpacks/$Id"
}

$lines = @(
    "# $($meta.name)"
    "# $pageUrl"
    "#"
    "# Minecraft $mc  $loader"
    "# $modCount server-side mods"
    "PACK_PROVIDER=$provider"
    "PACK_ID=$Id"
    "PACK_VERSION=$($newest.VersionId)"
    "IMAGE=$Registry/$Name"
    "TAG=$tag"
    "MEMORY=$Memory"
    "#"
    "# EXCLUDE_MODS takes space-separated globs, for mods the manifest wrongly"
    "# marks as server-side. Add them if the first build will not boot."
)

[System.IO.File]::WriteAllText($packFile, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host "$($meta.name)" -ForegroundColor Cyan
Write-Host "  provider   : $provider/$Id"
Write-Host "  version    : $($newest.VersionId)  ($($newest.VersionName) -> tag $tag)"
Write-Host "  minecraft  : $mc  $loader"
Write-Host "  mods       : $modCount server-side"
Write-Host "  heap       : $Memory$(if (-not $PSBoundParameters.ContainsKey('Memory')) { ' (estimated)' })"
Write-Host ''
Write-Host "Wrote packs/$Name.env" -ForegroundColor Green
Write-Host ''
Write-Host 'Next:' -ForegroundColor DarkGray
Write-Host "  .\tools\build.ps1 -Pack $Name        # build it locally first" -ForegroundColor DarkGray
Write-Host "  git checkout -b add-pack/$Name" -ForegroundColor DarkGray
Write-Host "  # open a PR, add the 'build' label to run the checks" -ForegroundColor DarkGray
