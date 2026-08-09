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

Write-Host ""
Write-Host "Root: $Root"
Write-Host "Pack: $Pack"
Write-Host "Work: $Work"

# ========================================

# PREPARE DIRECTORIES

# ========================================

Write-Host ""
Write-Host "Preparing build directories..."

if (Test-Path -LiteralPath $Work) {
Remove-Item -LiteralPath $Work -Recurse -Force
}

if (Test-Path -LiteralPath $Pack) {
Remove-Item -LiteralPath $Pack -Recurse -Force
}

New-Item `    -ItemType Directory`
-Path $Work `
-Force | Out-Null

New-Item `    -ItemType Directory`
-Path $Pack `
-Force | Out-Null

if (-not (Test-Path -LiteralPath $Pack -PathType Container)) {
throw "Could not create pack directory: $Pack"
}

if (-not (Test-Path -LiteralPath $Work -PathType Container)) {
throw "Could not create work directory: $Work"
}

Write-Host "Pack directory ready."
Write-Host "Work directory ready."

# ========================================

# LOAD COMPONENT CONFIG

# ========================================

if (-not (Test-Path -LiteralPath $ComponentsFile -PathType Leaf)) {
throw "components.json was not found: $ComponentsFile"
}

try {
$ConfigText = Get-Content `        -LiteralPath $ComponentsFile`
-Raw `
-ErrorAction Stop

```
$Config = $ConfigText |
    ConvertFrom-Json `
    -ErrorAction Stop
```

}
catch {
throw "Could not parse components.json. $($_.Exception.Message)"
}

if ($null -eq $Config.components) {
throw "components.json does not contain a components array."
}

Write-Host "Components configured: $($Config.components.Count)"

# ========================================

# GITHUB API SETTINGS

# ========================================

$Headers = @{
"User-Agent" = "SkipperBNS-HATS-Builder"
"Accept" = "application/vnd.github+json"
}

# ========================================

# GET LATEST RELEASE

# ========================================

function Get-LatestRelease {
param(
[string]$Repo
)

```
$Url = "https://api.github.com/repos/$Repo/releases/latest"

Write-Host "Requesting release information..."
Write-Host "URL: $Url"

try {
    return Invoke-RestMethod `
        -Uri $Url `
        -Headers $Headers `
        -Method Get `
        -ErrorAction Stop
}
catch {
    throw "Could not retrieve latest release for '$Repo'. $($_.Exception.Message)"
}
```

}

# ========================================

# FIND RELEASE ASSET

# ========================================

function Find-Asset {
param(
$Release,
[string]$Regex
)

```
foreach ($Asset in $Release.assets) {
    if ($Asset.name -match $Regex) {
        return $Asset
    }
}

return $null
```

}

# ========================================

# DOWNLOAD ASSET

# ========================================

function Download-Asset {
param(
$Asset,
[string]$Destination
)

```
Write-Host "Downloading:"
Write-Host "  $($Asset.name)"
Write-Host "From:"
Write-Host "  $($Asset.browser_download_url)"

try {
    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -OutFile $Destination `
        -Headers @{
            "User-Agent" = "SkipperBNS-HATS-Builder"
        } `
        -ErrorAction Stop
}
catch {
    throw "Failed to download '$($Asset.name)'. $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
    throw "Downloaded file does not exist: $Destination"
}

$DownloadedFile = Get-Item -LiteralPath $Destination

if ($DownloadedFile.Length -le 0) {
    throw "Downloaded file is empty: $Destination"
}

Write-Host "Downloaded: $($DownloadedFile.Length) bytes"
```

}

# ========================================

# PROCESS COMPONENTS

# ========================================

$Index = 0
$Total = $Config.components.Count

foreach ($Component in $Config.components) {

```
$Index++

Write-Host ""
Write-Host "========================================"
Write-Host "Component $Index of $Total"
Write-Host "$($Component.name)"
Write-Host "========================================"

if ([string]::IsNullOrWhiteSpace($Component.repo)) {
    throw "Component '$($Component.name)' has no repo."
}

if ([string]::IsNullOrWhiteSpace($Component.asset_regex)) {
    throw "Component '$($Component.name)' has no asset_regex."
}

if ([string]::IsNullOrWhiteSpace($Component.mode)) {
    throw "Component '$($Component.name)' has no mode."
}

Write-Host "Repository: $($Component.repo)"
Write-Host "Mode:       $($Component.mode)"
Write-Host "Pattern:    $($Component.asset_regex)"

$Release = Get-LatestRelease `
    -Repo $Component.repo

Write-Host "Release:    $($Release.tag_name)"

if ($null -eq $Release.assets) {
    throw "Release '$($Release.tag_name)' has no assets."
}

$Asset = Find-Asset `
    -Release $Release `
    -Regex $Component.asset_regex

if ($null -eq $Asset) {

    Write-Host ""
    Write-Host "ERROR: No matching asset found." -ForegroundColor Red

    Write-Host ""
    Write-Host "Required pattern:"
    Write-Host "  $($Component.asset_regex)"

    Write-Host ""
    Write-Host "Available assets:"

    foreach ($Available in $Release.assets) {
        Write-Host "  $($Available.name)"
    }

    throw "Could not find an asset matching '$($Component.asset_regex)' in $($Component.repo)."
}

Write-Host "Asset:      $($Asset.name)"

$DownloadPath = Join-Path `
    $Work `
    $Asset.name

Download-Asset `
    -Asset $Asset `
    -Destination $DownloadPath

# ========================================
# ZIP COMPONENT
# ========================================

if ($Component.mode -eq "zip") {

    Write-Host ""
    Write-Host "Extracting ZIP..."

    Expand-Archive `
        -LiteralPath $DownloadPath `
        -DestinationPath $Pack `
        -Force

    Write-Host "Extraction complete."

    # Make sure extraction didn't remove the root directory.
    if (-not (Test-Path -LiteralPath $Pack -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $Pack `
            -Force | Out-Null
    }

    continue
}

# ========================================
# FILE / NRO / OVL COMPONENT
# ========================================

if (
    $Component.mode -eq "nro" -or
    $Component.mode -eq "ovl" -or
    $Component.mode -eq "file"
) {

    if ([string]::IsNullOrWhiteSpace($Component.destination)) {
        throw "Component '$($Component.name)' has no destination."
    }

    $Destination = Join-Path `
        $Pack `
        $Component.destination

    $DestinationFolder = Split-Path `
        $Destination `
        -Parent

    if ([string]::IsNullOrWhiteSpace($DestinationFolder)) {
        throw "Invalid destination: $($Component.destination)"
    }

    New-Item `
        -ItemType Directory `
        -Path $DestinationFolder `
        -Force | Out-Null

    Copy-Item `
        -LiteralPath $DownloadPath `
        -Destination $Destination `
        -Force

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Failed to install '$($Component.name)' to '$Destination'."
    }

    $InstalledFile = Get-Item -LiteralPath $Destination

    if ($InstalledFile.Length -le 0) {
        throw "Installed file is empty: $Destination"
    }

    Write-Host "Installed: $($Component.destination)"
    Write-Host "Size:      $($InstalledFile.Length) bytes"

    continue
}

throw "Unknown component mode: $($Component.mode)"
```

}

# ========================================

# VERIFY PACK DIRECTORY

# ========================================

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying pack"
Write-Host "========================================"

# Re-create the root if necessary.

if (-not (Test-Path -LiteralPath $Pack -PathType Container)) {

```
Write-Warning "Pack directory was missing. Recreating it..."

New-Item `
    -ItemType Directory `
    -Path $Pack `
    -Force | Out-Null
```

}

if (-not (Test-Path -LiteralPath $Pack -PathType Container)) {
throw "Pack directory does not exist: $Pack"
}

$PackFiles = @(
Get-ChildItem `        -LiteralPath $Pack`
-File `        -Recurse`
-ErrorAction Stop
)

if ($PackFiles.Count -eq 0) {
throw "Pack directory is empty. No files were installed."
}

Write-Host "Pack directory: $Pack"
Write-Host "Files in pack: $($PackFiles.Count)"

foreach ($File in $PackFiles) {
Write-Host "  $($File.FullName.Substring($Pack.Length + 1))"
}

# ========================================

# CREATE FINAL ZIP

# ========================================

$Output = Join-Path `    $Root`
"SkipperBNS-HATS-$Version.zip"

if (Test-Path -LiteralPath $Output) {
Remove-Item `        -LiteralPath $Output`
-Force
}

Write-Host ""
Write-Host "Creating final HATS ZIP..."

Compress-Archive `    -Path "$Pack\*"`
-DestinationPath $Output `
-Force

if (-not (Test-Path -LiteralPath $Output -PathType Leaf)) {
throw "Final ZIP was not created: $Output"
}

$OutputFile = Get-Item -LiteralPath $Output

if ($OutputFile.Length -le 0) {
throw "Final ZIP is empty."
}

# ========================================

# SUCCESS

# ========================================

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"
Write-Host "Version: $Version"
Write-Host "Output:  $($OutputFile.FullName)"
Write-Host "Size:    $($OutputFile.Length) bytes"
Write-Host "========================================"
