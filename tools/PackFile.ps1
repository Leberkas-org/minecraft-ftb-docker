# Shared pack-file helpers, dot-sourced by build.ps1, find-pack.ps1 and
# update-pack.ps1 so the packs/<name>.env format is parsed in exactly one place.
#
#   . "$PSScriptRoot\PackFile.ps1"

function Get-PackFilePath {
    <#
    .SYNOPSIS
        Resolves packs/<name>.env, listing what is available if it does not exist.
    #>
    param (
        [Parameter(Mandatory = $true)] [string] $Pack,
        [string] $PacksDir
    )

    if (-not $PacksDir) {
        $PacksDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'packs'
    }

    $packFile = Join-Path $PacksDir "$Pack.env"
    if (-not (Test-Path $packFile)) {
        $available = (Get-ChildItem $PacksDir -Filter '*.env' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName }) -join ', '
        throw "No pack definition at '$packFile'. Available packs: $available"
    }
    $packFile
}

function Get-PackConfig {
    <#
    .SYNOPSIS
        Reads a pack file into a hashtable, ignoring comments and blank lines.
    #>
    param (
        [Parameter(Mandatory = $true)] [string] $PackFile,
        [string[]] $Require = @()
    )

    $cfg = @{}
    foreach ($line in Get-Content $PackFile) {
        if ($line -match '^\s*(#|$)') { continue }
        $kv = $line -split '=', 2
        if ($kv.Count -eq 2) { $cfg[$kv[0].Trim()] = $kv[1].Trim() }
    }

    foreach ($key in $Require) {
        if (-not $cfg.ContainsKey($key)) { throw "$PackFile is missing $key" }
    }
    $cfg
}

function Get-PackNames {
    <#
    .SYNOPSIS
        Every pack name that has a definition, for matrices and error messages.
    #>
    param ([string] $PacksDir)

    if (-not $PacksDir) {
        $PacksDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'packs'
    }
    Get-ChildItem $PacksDir -Filter '*.env' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName } | Sort-Object
}

function Get-NewestPackVersion {
    <#
    .SYNOPSIS
        Newest version of a pack from modpacks.ch. Releases only unless -IncludeAll.
    #>
    param (
        [Parameter(Mandatory = $true)] [string] $Provider,
        [Parameter(Mandatory = $true)] [string] $PackId,
        [switch] $IncludeAll
    )

    $meta = Invoke-RestMethod "https://api.modpacks.ch/public/$Provider/$PackId" -TimeoutSec 60
    if ($meta.status -eq 'error') { throw "No pack at $Provider/$PackId : $($meta.message)" }

    $versions = $meta.versions
    if (-not $IncludeAll) { $versions = $versions | Where-Object { $_.type -eq 'release' } }

    $newest = $versions | Sort-Object id -Descending | Select-Object -First 1
    if (-not $newest) { throw "No release version found for $($meta.name)" }

    [pscustomobject]@{
        PackName    = $meta.name
        VersionId   = "$($newest.id)"
        VersionName = $newest.name
        Type        = $newest.type
    }
}

function ConvertTo-DockerTag {
    <#
    .SYNOPSIS
        Turns a modpack version name into a valid Docker tag.

    .DESCRIPTION
        Version names are prose - "All the Mods 10-7.3", "Atm7 Sky 1.2.3" - and a
        Docker tag may not contain spaces, so they cannot be used raw. Prefer the
        trailing version number, which is what a human would have typed anyway
        ("All the Mods 10-7.3" -> "7.3"); fall back to slugifying the whole name.
    #>
    param ([Parameter(Mandatory = $true)] [string] $VersionName)

    $name = $VersionName.Trim()

    # Some packs put the archive name in the version, e.g.
    # "BMC4 [FORGE] 1.20.1 v60.zip". The extension is never part of a version.
    $name = $name -replace '\.(zip|jar|7z|tar\.gz)$', ''

    if ($name -match '(?:^|[-\s_])(v\d+(?:\.\d+)*[A-Za-z0-9]*)$') {
        # Trailing build number, e.g. "BMC4 [FORGE] 1.20.1 v60" -> v60. Checked
        # before the dotted-version rule: without it "… v57.5" yields "57.5"
        # while its sibling "… v57" slugifies whole, so tags for one pack end up
        # in two different shapes.
        $candidate = $Matches[1]
    }
    elseif ($name -match '(?:^|[-\s_])v?(\d+(?:\.\d+)+[A-Za-z0-9._-]*)$') {
        # Trailing dotted version, e.g. "All the Mods 10-7.3" -> 7.3
        $candidate = $Matches[1]
    }
    else {
        $candidate = $name
    }

    # Docker: [A-Za-z0-9_][A-Za-z0-9._-]{0,127}
    $tag = ($candidate -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-'
    $tag = $tag.Trim('-', '.')
    if ($tag -notmatch '^[A-Za-z0-9_]') { $tag = "v$tag" }
    if ($tag.Length -gt 128) { $tag = $tag.Substring(0, 128) }
    $tag
}

function Set-PackFileValue {
    <#
    .SYNOPSIS
        Rewrites KEY=VALUE in place, appending the key if it is not present.
    #>
    param (
        [Parameter(Mandatory = $true)] [string] $PackFile,
        [Parameter(Mandatory = $true)] [hashtable] $Values
    )

    $lines = @(Get-Content $PackFile)
    $seen = @{}

    $updated = foreach ($line in $lines) {
        $matched = $false
        foreach ($key in $Values.Keys) {
            if ($line -match "^\s*$([regex]::Escape($key))\s*=") {
                $seen[$key] = $true
                $matched = $true
                "$key=$($Values[$key])"
                break
            }
        }
        if (-not $matched) { $line }
    }

    foreach ($key in $Values.Keys) {
        if (-not $seen.ContainsKey($key)) { $updated += "$key=$($Values[$key])" }
    }

    # Written explicitly rather than via Set-Content: on Windows PowerShell 5.1
    # `-Encoding utf8` emits a BOM while PowerShell 7 does not, so the same edit
    # made locally and in CI would produce different bytes and churn the diff. A
    # BOM is also not whitespace, so it would corrupt the first key in any pack
    # file that does not open with a comment. LF matches .gitattributes.
    $text = ($updated -join "`n") + "`n"
    [System.IO.File]::WriteAllText($PackFile, $text, [System.Text.UTF8Encoding]::new($false))
}
