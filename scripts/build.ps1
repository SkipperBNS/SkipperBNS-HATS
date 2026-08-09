param(
    [string]$Version = "main"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "       SkipperBNS HATS Pack Builder"
Write-Host "========================================"

$Root = Split-Path -Parent $PSScriptRoot
$Pack = Join-Path $Root "pack"
$Work = Join-Path $Root "work"
$ComponentsFile = Join-Path $Root "components.json"

if (Test-Path $Work) {
    Remove-Item $Work -Recurse -Force
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Pack -Force | Out-Null

$Config = Get-Content $ComponentsFile -Raw | ConvertFrom-Json

function Get-LatestRelease {
    param(
        [string]$Repo
    )

    $Url = "https://api.github.com/repos/$Repo/releases/latest"

    return Invoke-RestMethod `
        -Uri $Url `
        -Headers @{
            "User-Agent" = "SkipperBNS-HATS-Builder"
        }
}

function Find-Asset {
    param(
        $Release,
        [string]$Regex
    )

    foreach ($Asset in $Release.assets) {
        if ($Asset.name -match $Regex) {
            return $Asset
        }
    }

    return $null
}

foreach ($Component in $Config.components) {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Component: $($Component.name)"
    Write-Host "Repository: $($Component.repo)"
    Write-Host "========================================"

    $Release = Get-LatestRelease $Component.repo

    Write-Host "Release: $($Release.tag_name)"

    $Asset = Find-Asset `
        -Release $Release `
        -Regex $Component.asset_regex

    if ($null -eq $Asset) {
        Write-Host ""
        Write-Host "ERROR: No matching asset found." -ForegroundColor Red
        Write-Host "Required pattern: $($Component.asset_regex)"

        Write-Host ""
        Write-Host "Available assets:"

        foreach ($Available in $Release.assets) {
            Write-Host "  $($Available.name)"
        }

        throw "Could not find an asset matching: $($Component.asset_regex)"
    }

    Write-Host "Asset: $($Asset.name)"
    Write-Host "Mode: $($Component.mode)"

    $DownloadPath = Join-Path $Work $Asset.name

    Write-Host "Downloading..."

    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -OutFile $DownloadPath

    # ========================================
    # ZIP COMPONENT
    # ========================================

    if ($Component.mode -eq "zip") {

        Write-Host "Extracting ZIP..."

        Expand-Archive `
            -Path $DownloadPath `
            -DestinationPath $Pack `
            -Force

        continue
    }

    # ========================================
    # NRO / OVL COMPONENT
    # ========================================

    if ($Component.mode -eq "nro" -or
        $Component.mode -eq "ovl" -or
        $Component.mode -eq "file") {

        if ([string]::IsNullOrWhiteSpace($Component.destination)) {
            throw "Component '$($Component.name)' has no destination."
        }

        $Destination = Join-Path `
            $Pack `
            $Component.destination

        $DestinationFolder = Split-Path `
            $Destination `
            -Parent

        New-Item `
            -ItemType Directory `
            -Path $DestinationFolder `
            -Force | Out-Null

        Copy-Item `
            -LiteralPath $DownloadPath `
            -Destination $Destination `
            -Force

        Write-Host "Installed: $($Component.destination)"

        continue
    }

    throw "Unknown component mode: $($Component.mode)"
}

# ========================================
# CREATE FINAL ZIP
# ========================================

$Output = Join-Path `
    $Root `
    "SkipperBNS-HATS-$Version.zip"

if (Test-Path $Output) {
    Remove-Item $Output -Force
}

Write-Host ""
Write-Host "Creating final HATS ZIP..."

Compress-Archive `
    -Path "$Pack\*" `
    -DestinationPath $Output `
    -Force

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"
Write-Host "Output: $Output"
