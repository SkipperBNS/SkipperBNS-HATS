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
Write-Host "Preparing build directories..."

if (Test-Path $Work) {
Remove-Item $Work -Recurse -Force
}

if (Test-Path $Pack) {
Remove-Item $Pack -Recurse -Force
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Pack -Force | Out-Null

if (-not (Test-Path $ComponentsFile)) {
throw "components.json was not found: $ComponentsFile"
}

try {
$ConfigText = Get-Content -Path $ComponentsFile -Raw -ErrorAction Stop
$Config = $ConfigText | ConvertFrom-Json -ErrorAction Stop
}
catch {
throw "Could not parse components.json. $($_.Exception.Message)"
}

if ($null -eq $Config.components) {
throw "components.json does not contain a components array."
}

Write-Host "Components configured: $($Config.components.Count)"

$Headers = @{
"User-Agent" = "SkipperBNS-HATS-Builder"
"Accept" = "application/vnd.github+json"
}

function Get-LatestRelease {
param(
[string]$Repo
)

```
$Url = "https://api.github.com/repos/$Repo/releases/latest"

Write-Host "Requesting: $Url"

return Invoke-RestMethod `
    -Uri $Url `
    -Headers $Headers `
    -Method Get `
    -ErrorAction Stop
```

}

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

function Download-Asset {
param(
$Asset,
[string]$Destination
)

```
Write-Host "Downloading..."
Write-Host "URL: $($Asset.browser_download_url)"

Invoke-WebRequest `
    -Uri $Asset.browser_download_url `
    -OutFile $Destination `
    -Headers @{
        "User-Agent" = "SkipperBNS-HATS-Builder"
    } `
    -ErrorAction Stop

if (-not (Test-Path $Destination)) {
    throw "Download failed: file was not created."
}

$DownloadedFile = Get-Item $Destination

if ($DownloadedFile.Length -le 0) {
    throw "Download failed: downloaded file is empty."
}

Write-Host "Downloaded: $($DownloadedFile.Length) bytes"
```

}

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
Write-Host "Mode: $($Component.mode)"
Write-Host "Pattern: $($Component.asset_regex)"

$Release = Get-LatestRelease -Repo $Component.repo

Write-Host "Release: $($Release.tag_name)"

$Asset = Find-Asset -Release $Release -Regex $Component.asset_regex

if ($null -eq $Asset) {

    Write-Host ""
    Write-Host "ERROR: No matching asset found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Required pattern:"
    Write-Host $Component.asset_regex
    Write-Host ""
    Write-Host "Available assets:"

    foreach ($Available in $Release.assets) {
        Write-Host "  $($Available.name)"
    }

    throw "Could not find an asset matching '$($Component.asset_regex)' in $($Component.repo)."
}

Write-Host "Asset: $($Asset.name)"

$DownloadPath = Join-Path $Work $Asset.name

Download-Asset `
    -Asset $Asset `
    -Destination $DownloadPath

if ($Component.mode -eq "zip") {

    Write-Host "Extracting ZIP..."

    Expand-Archive `
        -Path $DownloadPath `
        -DestinationPath $Pack `
        -Force

    Write-Host "Extraction complete."

    continue
}

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

    New-Item `
        -ItemType Directory `
        -Path $DestinationFolder `
        -Force | Out-Null

    Copy-Item `
        -LiteralPath $DownloadPath `
        -Destination $Destination `
        -Force

    if (-not (Test-Path $Destination)) {
        throw "Failed to install $($Component.name)."
    }

    $InstalledFile = Get-Item $Destination

    if ($InstalledFile.Length -le 0) {
        throw "Installed file is empty: $Destination"
    }

    Write-Host "Installed: $($Component.destination)"
    Write-Host "Size: $($InstalledFile.Length) bytes"

    continue
}

throw "Unknown component mode: $($Component.mode)"
```

}

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying pack"
Write-Host "========================================"

$PackFiles = @(
Get-ChildItem `        -Path $Pack`
-File `
-Recurse
)

if ($PackFiles.Count -eq 0) {
throw "Pack directory is empty."
}

Write-Host "Pack files: $($PackFiles.Count)"

$Output = Join-Path `    $Root`
"SkipperBNS-HATS-$Version.zip"

if (Test-Path $Output) {
Remove-Item $Output -Force
}

Write-Host ""
Write-Host "Creating final HATS ZIP..."

Compress-Archive `    -Path "$Pack\*"`
-DestinationPath $Output `
-Force

if (-not (Test-Path $Output)) {
throw "Final ZIP was not created."
}

$OutputFile = Get-Item $Output

if ($OutputFile.Length -le 0) {
throw "Final ZIP is empty."
}

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"
Write-Host "Version: $Version"
Write-Host "Output:  $($OutputFile.FullName)"
Write-Host "Size:    $($OutputFile.Length) bytes"
Write-Host "========================================"
