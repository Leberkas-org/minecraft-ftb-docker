<#
.SYNOPSIS
    Lists available versions of a modpack and shows which one is pinned.

.DESCRIPTION
    A pack file needs a PACK_ID (the pack) and a PACK_VERSION (a specific file /
    version id). PACK_ID you read off the pack's page:

      CurseForge -> "Project ID" in the right-hand sidebar
      FTB        -> the number in the pack URL, e.g. /modpacks/103-ftb-skies

    This script turns that id into the list of PACK_VERSION values to choose
    from. There is deliberately no search mode: modpacks.ch's search endpoint
    does not reliably return even well-known packs, so it would only mislead.

.EXAMPLE
    .\src\find-pack.ps1 atm10
    Lists recent versions of a configured pack, marking the pinned one.

.EXAMPLE
    .\src\find-pack.ps1 -Provider curseforge -Id 925200
    Lists versions for a pack that has no pack file yet.

.EXAMPLE
    .\src\find-pack.ps1 -Provider curseforge -Id 925200 -All -Count 20
    Includes alpha/beta versions.
#>
[CmdletBinding(DefaultParameterSetName = 'Pack')]
param (
    [Parameter(ParameterSetName = 'Pack', Position = 0)]
    [string] $Pack,

    [Parameter(ParameterSetName = 'Id', Mandatory = $true)]
    [ValidateSet('curseforge', 'modpack')]
    [string] $Provider,

    [Parameter(ParameterSetName = 'Id', Mandatory = $true)]
    [string] $Id,

    # Include alpha/beta versions, not just releases.
    [switch] $All,

    [int] $Count = 10
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\PackFile.ps1"
$api = 'https://api.modpacks.ch/public'

function Show-Versions($provider, $id, $pinned) {
    $meta = Invoke-RestMethod "$api/$provider/$id" -TimeoutSec 60
    if ($meta.status -eq 'error') { throw "No pack at $provider/$id : $($meta.message)" }

    $versions = $meta.versions
    if (-not $All) { $versions = $versions | Where-Object { $_.type -eq 'release' } }
    $versions = $versions | Sort-Object id -Descending | Select-Object -First $Count
    if (-not $versions) { throw "No versions found for $provider/$id" }

    # Minecraft/modloader targets live on the version, not the pack, so read them
    # from the newest one - it is what -Latest would build.
    $newest = $versions | Select-Object -First 1
    $mc = ''; $loader = ''
    try {
        $vm = Invoke-RestMethod "$api/$provider/$id/$($newest.id)" -TimeoutSec 60
        $mc = ($vm.targets | Where-Object { $_.type -eq 'game' } | Select-Object -First 1).version
        $ml = $vm.targets | Where-Object { $_.type -eq 'modloader' } | Select-Object -First 1
        if ($ml) { $loader = "$($ml.name) $($ml.version)" }
    } catch { }

    Write-Host ''
    Write-Host "$($meta.name)   [$provider/$id]" -ForegroundColor Cyan
    if ($mc) { Write-Host "newest targets Minecraft $mc  $loader" -ForegroundColor DarkGray }
    Write-Host ''

    $versions |
        Select-Object `
            @{ n = '  '; e = { if ("$($_.id)" -eq "$pinned") { ' *' } else { '' } } },
            @{ n = 'PACK_VERSION'; e = { $_.id } },
            @{ n = 'version'; e = { $_.name } },
            @{ n = 'type'; e = { $_.type } },
            @{ n = 'released'; e = {
                if ($_.updated) { [DateTimeOffset]::FromUnixTimeSeconds($_.updated).ToString('yyyy-MM-dd') } else { '' } } } |
        Format-Table -AutoSize

    if ($pinned) { Write-Host ' * currently pinned in the pack file' -ForegroundColor DarkGray }
}

if ($PSCmdlet.ParameterSetName -eq 'Id') {
    Show-Versions $Provider $Id $null
    Write-Host ''
    Write-Host "Put PACK_PROVIDER=$Provider / PACK_ID=$Id / PACK_VERSION=<id> into packs/<name>.env" -ForegroundColor DarkGray
    return
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$packsDir = Join-Path $repoRoot 'packs'

if (-not $Pack) {
    Write-Host 'Configured packs:'
    Get-PackNames -PacksDir $packsDir | ForEach-Object { "  $_" }
    Write-Host ''
    Write-Host 'Usage: .\src\find-pack.ps1 <pack>' -ForegroundColor DarkGray
    Write-Host '       .\src\find-pack.ps1 -Provider curseforge -Id <project id>' -ForegroundColor DarkGray
    return
}

$packFile = Get-PackFilePath -Pack $Pack -PacksDir $packsDir
$cfg = Get-PackConfig -PackFile $packFile -Require @('PACK_PROVIDER', 'PACK_ID')

Show-Versions $cfg['PACK_PROVIDER'] $cfg['PACK_ID'] $cfg['PACK_VERSION']
Write-Host ''
Write-Host "Build the newest with: .\src\build.ps1 -Pack $Pack -Latest" -ForegroundColor DarkGray
