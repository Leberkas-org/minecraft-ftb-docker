<#
.SYNOPSIS
    Generates the GitHub Pages site from packs/*.env.

.DESCRIPTION
    The pack files are the source of truth for what is published, so the site is
    generated from them rather than hand-written - a hand-written list drifts,
    which is exactly how the README ended up advertising an image name that did
    not exist.

    Pack titles, Minecraft/modloader versions and artwork come from modpacks.ch.

.EXAMPLE
    .\src\build-site.ps1
    Writes site/index.html.

.EXAMPLE
    .\src\build-site.ps1 -OutputDir out -Open
#>
[CmdletBinding()]
param (
    [string] $OutputDir,
    [switch] $Open
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\PackFile.ps1"

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'site' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Enc([string] $s) {
    if ($null -eq $s) { return '' }
    $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------
$packs = @()
foreach ($name in Get-PackNames) {
    $cfg = Get-PackConfig -PackFile (Get-PackFilePath -Pack $name) -Require @('PACK_PROVIDER', 'PACK_ID')

    $provider = $cfg['PACK_PROVIDER']
    $packId = $cfg['PACK_ID']
    $version = $cfg['PACK_VERSION']
    $image = if ($cfg.ContainsKey('IMAGE')) { $cfg['IMAGE'] } else { "ghcr.io/leberkas-org/$name" }
    $tag = $cfg['TAG']

    Write-Host "  $name -> $image`:$tag"

    $title = $name; $mc = ''; $loader = ''; $art = ''; $link = ''
    try {
        $meta = Invoke-RestMethod "https://api.modpacks.ch/public/$provider/$packId" -TimeoutSec 60
        if ($meta.name) { $title = $meta.name }
        $square = $meta.art | Where-Object { $_.type -eq 'square' } | Select-Object -First 1
        if ($square.url) { $art = [uri]::EscapeUriString($square.url) }
    } catch { Write-Warning "  pack metadata unavailable for $name" }

    if ($version) {
        try {
            $vm = Invoke-RestMethod "https://api.modpacks.ch/public/$provider/$packId/$version" -TimeoutSec 60
            $mc = ($vm.targets | Where-Object { $_.type -eq 'game' } | Select-Object -First 1).version
            $ml = $vm.targets | Where-Object { $_.type -eq 'modloader' } | Select-Object -First 1
            if ($ml) { $loader = "$($ml.name) $($ml.version)" }
        } catch { Write-Warning "  version metadata unavailable for $name" }
    }

    $link = if ($provider -eq 'modpack') { "https://feed-the-beast.com/modpacks/$packId" } else { 'https://www.curseforge.com/minecraft/modpacks' }

    $packs += [pscustomobject]@{
        key = $name; title = $title; image = $image; tag = $tag; version = $version
        memory = if ($cfg['MEMORY']) { $cfg['MEMORY'] } else { '8G' }
        mc = $mc; loader = $loader; art = $art; link = $link
        provider = $provider
    }
}

if (-not $packs) { throw 'No packs found.' }

# ---------------------------------------------------------------------------
# Markup
# ---------------------------------------------------------------------------
$slots = ($packs | ForEach-Object {
@"
        <button class="slot" role="tab" aria-selected="false" data-key="$(Enc $_.key)" title="$(Enc $_.title)">
          <span class="slot__art">$(if ($_.art) { "<img src=`"$(Enc $_.art)`" alt=`"`" loading=`"lazy`" width=`"96`" height=`"96`">" } else { '<span class="slot__fallback">?</span>' })</span>
          <span class="slot__name">$(Enc $_.title)</span>
        </button>
"@
}) -join "`n"

$rows = ($packs | ForEach-Object {
@"
          <tr>
            <th scope="row">$(Enc $_.title)</th>
            <td><code>$(Enc $_.mc)</code></td>
            <td>$(Enc $_.loader)</td>
            <td><code>$(Enc $_.memory)</code></td>
            <td><code class="ref">$(Enc $_.image):$(Enc $_.tag)</code></td>
          </tr>
"@
}) -join "`n"

$json = ($packs | ForEach-Object {
    $o = [ordered]@{
        key = $_.key; title = $_.title; image = $_.image; tag = $_.tag
        version = $_.version; memory = $_.memory; mc = $_.mc; loader = $_.loader; link = $_.link
    }
    ($o | ConvertTo-Json -Compress)
}) -join ",`n"

$generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

# Read as UTF-8 explicitly: Get-Content -Raw on Windows PowerShell 5.1 decodes
# with the ANSI codepage unless the file carries a BOM, which turns every em
# dash in the template into mojibake.
$template = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot 'site-template.html'),
    [System.Text.UTF8Encoding]::new($false))
$html = $template.
    Replace('{{SLOTS}}', $slots).
    Replace('{{ROWS}}', $rows).
    Replace('{{PACKS_JSON}}', "[`n$json`n]").
    Replace('{{COUNT}}', "$($packs.Count)").
    Replace('{{GENERATED}}', $generated)

$out = Join-Path $OutputDir 'index.html'
[System.IO.File]::WriteAllText($out, $html, [System.Text.UTF8Encoding]::new($false))

foreach ($asset in 'logo.png', 'logo_flat.png') {
    Copy-Item (Join-Path $repoRoot $asset) (Join-Path $OutputDir $asset) -Force
}
# Stops Pages running the output through Jekyll, which would drop _-prefixed files.
[System.IO.File]::WriteAllText((Join-Path $OutputDir '.nojekyll'), '')

Write-Host ''
Write-Host "Wrote $out ($([math]::Round((Get-Item $out).Length / 1kb)) kB, $($packs.Count) packs)" -ForegroundColor Green
if ($Open) { Start-Process $out }
