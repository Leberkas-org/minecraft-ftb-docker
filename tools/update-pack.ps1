<#
.SYNOPSIS
    Bumps a pack file to the newest release of its modpack.

.DESCRIPTION
    The "prepare release" half of the update workflow: it resolves the newest
    release from modpacks.ch and, if it differs from the pinned PACK_VERSION,
    rewrites PACK_VERSION and TAG in packs/<name>.env. It deliberately does not
    build - the pull request opened from the change is what builds and validates.

    Under GitHub Actions it also writes updated / version / version_name /
    previous / previous_name to $GITHUB_OUTPUT so the workflow can compose the
    pull request title and body.

.EXAMPLE
    .\tools\update-pack.ps1 -Pack atm10

.EXAMPLE
    .\tools\update-pack.ps1 -Pack atm10 -WhatIf
    Reports what would change without touching the file.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Pack
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\PackFile.ps1"

$packFile = Get-PackFilePath -Pack $Pack
$cfg = Get-PackConfig -PackFile $packFile -Require @('PACK_PROVIDER', 'PACK_ID')

$provider = $cfg['PACK_PROVIDER']
$packId = $cfg['PACK_ID']
$current = $cfg['PACK_VERSION']
$currentName = $cfg['TAG']

$newest = Get-NewestPackVersion -Provider $provider -PackId $packId

# Version names are prose ("All the Mods 10-7.3"); a Docker tag cannot hold spaces.
$newTag = ConvertTo-DockerTag $newest.VersionName

Write-Host "$($newest.PackName)  [$provider/$packId]"
Write-Host "  pinned : $current $(if ($currentName) { "($currentName)" })"
Write-Host "  newest : $($newest.VersionId) ($($newest.VersionName) -> tag $newTag)"

$updated = ($newest.VersionId -ne $current)

if (-not $updated) {
    Write-Host ''
    Write-Host 'Already up to date.' -ForegroundColor Green
}
else {
    if ($PSCmdlet.ShouldProcess($packFile, "bump to $($newest.VersionName)")) {
        Set-PackFileValue -PackFile $packFile -Values @{
            PACK_VERSION = $newest.VersionId
            TAG          = $newTag
        }
        Write-Host ''
        Write-Host "Updated $packFile -> PACK_VERSION=$($newest.VersionId), TAG=$newTag" -ForegroundColor Yellow
    }
}

if ($env:GITHUB_OUTPUT) {
    @(
        "updated=$($updated.ToString().ToLower())"
        "pack=$Pack"
        "pack_name=$($newest.PackName)"
        "version=$($newest.VersionId)"
        "version_name=$($newest.VersionName)"
        "tag=$newTag"
        "previous=$current"
        "previous_name=$currentName"
    ) | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
}
