param(
    [string]$Version = "main"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "       SkipperBNS HATS Pack Builder"
Write-Host "========================================"
Write-Host ""

$Root = Split-Path -Parent $PSScriptRoot
$Pack = Join-Path $Root "pack"
$Work = Join-Path $Root "work"
$ComponentsFile = Join-Path $Root "components.json"

Write-Host "Root: $Root"
Write-Host "Pack: $Pack"
Write-Host "Work: $Work"
Write-Host ""

# ------------------------------------------------------------
# CLEAN BUILD DIRECTORIES
# ------------------------------------------------------------

if (Test-Path $Work) {
    Remove-Item $Work -Recurse -Force
}

if (Test-Path $Pack) {
    Remove-Item $Pack -Recurse -Force
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Pack -Force | Out-Null

Write-Host "Preparing build directories..."
Write-Host ""

# ------------------------------------------------------------
# LOAD COMPONENTS.JSON
# ------------------------------------------------------------

if (-not (Test-Path $ComponentsFile)) {
    throw "components.json was not found: $ComponentsFile"
}

try {
    $ConfigText = Get-Content $ComponentsFile -Raw -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($ConfigText)) {
        throw "components.json is empty."
    }

    $Config = $ConfigText | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Could not parse components.json. $($_.Exception.Message)"
}

if ($null -eq $Config.components) {
    throw "components.json does not contain a 'components' array."
}

Write-Host "Components configured: $($Config.components.Count)"
Write-Host ""

# ------------------------------------------------------------
# GITHUB API
# ------------------------------------------------------------

$GitHubToken = $env:GITHUB_TOKEN

$Headers = @{
    "User-Agent" = "SkipperBNS-HATS-Builder"
    "Accept"     = "application/vnd.github+json"
}

if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    $Headers["Authorization"] = "Bearer $GitHubToken"
}

Write-Host "GitHub authentication:"
Write-Host "Token configured: $(-not [string]::IsNullOrWhiteSpace($GitHubToken))"
Write-Host ""

# ------------------------------------------------------------
# GET LATEST RELEASE
# ------------------------------------------------------------

function Get-LatestRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    $Url = "https://api.github.com/repos/$Repo/releases/latest"

    Write-Host "Checking latest release for $Repo..."

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            return Invoke-RestMethod `
                -Uri $Url `
                -Headers $Headers `
                -Method Get `
                -ErrorAction Stop
        }
        catch {
            Write-Host "Release request failed (attempt $Attempt of 3)."

            if ($Attempt -eq 3) {
                throw "Could not retrieve latest release for '$Repo'. $($_.Exception.Message)"
            }

            Start-Sleep -Seconds (5 * $Attempt)
        }
    }
}

# ------------------------------------------------------------
# FIND ASSET
# ------------------------------------------------------------

function Find-Asset {
    param(
        [Parameter(Mandatory = $true)]
        $Release,

        [Parameter(Mandatory = $true)]
        [string]$Regex
    )

    foreach ($Asset in @($Release.assets)) {
        if ($Asset.name -match $Regex) {
            return $Asset
        }
    }

    return $null
}

# ------------------------------------------------------------
# DOWNLOAD ASSET
# ------------------------------------------------------------

function Download-Asset {
    param(
        [Parameter(Mandatory = $true)]
        $Asset,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Write-Host "Downloading: $($Asset.name)"
    Write-Host "URL: $($Asset.browser_download_url)"

    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -Headers $Headers `
        -OutFile $Destination `
        -UseBasicParsing `
        -ErrorAction Stop

    if (-not (Test-Path $Destination)) {
        throw "Download failed: $Destination"
    }

    $DownloadedFile = Get-Item $Destination

    if ($DownloadedFile.Length -le 0) {
        throw "Downloaded file is empty: $Destination"
    }

    Write-Host "Downloaded: $($DownloadedFile.Length) bytes"
    Write-Host ""
}

# ------------------------------------------------------------
# EXTRACT ZIP
# ------------------------------------------------------------

function Install-Zip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Write-Host "Extracting ZIP:"
    Write-Host $ZipPath

    Expand-Archive `
        -Path $ZipPath `
        -DestinationPath $Destination `
        -Force `
        -ErrorAction Stop
}

# ------------------------------------------------------------
# COPY FILE
# ------------------------------------------------------------

function Install-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $DestinationFolder = Split-Path $Destination -Parent

    if (-not [string]::IsNullOrWhiteSpace($DestinationFolder)) {
        New-Item `
            -ItemType Directory `
            -Path $DestinationFolder `
            -Force | Out-Null
    }

    Copy-Item `
        -LiteralPath $Source `
        -Destination $Destination `
        -Force `
        -ErrorAction Stop

    Write-Host "Installed: $Destination"
}

# ------------------------------------------------------------
# FIND EXTRACTED FILE
# ------------------------------------------------------------

function Find-ExtractedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $Matches = @(
        Get-ChildItem `
            -Path $Root `
            -Recurse `
            -File `
            -Filter $FileName `
            -ErrorAction SilentlyContinue
    )

    if ($Matches.Count -eq 0) {
        return $null
    }

    return $Matches[0].FullName
}

# ------------------------------------------------------------
# HATS BASE
# ------------------------------------------------------------

$HatsBase = @(
    $Config.components |
    Where-Object {
        $_.mode -eq "hats_base"
    }
)

if ($HatsBase.Count -ne 1) {
    throw "components.json must contain exactly one component with mode 'hats_base'."
}

$HatsComponent = $HatsBase[0]

Write-Host ""
Write-Host "========================================"
Write-Host "Installing HATS Base"
Write-Host "========================================"
Write-Host ""

if ([string]::IsNullOrWhiteSpace($HatsComponent.repo)) {
    throw "HATS base has no repository."
}

if ([string]::IsNullOrWhiteSpace($HatsComponent.asset_regex)) {
    throw "HATS base has no asset_regex."
}

$HatsRelease = Get-LatestRelease $HatsComponent.repo

if ($null -eq $HatsRelease) {
    throw "No HATS release information returned."
}

Write-Host "HATS release: $($HatsRelease.tag_name)"
Write-Host ""

$HatsAsset = Find-Asset `
    -Release $HatsRelease `
    -Regex $HatsComponent.asset_regex

if ($null -eq $HatsAsset) {

    Write-Host "Available HATS assets:"
    foreach ($Available in @($HatsRelease.assets)) {
        Write-Host "  $($Available.name)"
    }

    throw "Could not find the HATS base ZIP."
}

Write-Host "HATS base asset: $($HatsAsset.name)"
Write-Host ""

$HatsZip = Join-Path $Work $HatsAsset.name

Download-Asset `
    -Asset $HatsAsset `
    -Destination $HatsZip

$HatsExtract = Join-Path $Work "hats-base"

New-Item `
    -ItemType Directory `
    -Path $HatsExtract `
    -Force | Out-Null

Install-Zip `
    -ZipPath $HatsZip `
    -Destination $HatsExtract

Write-Host "Installing HATS base files..."

# The HATS release may contain files directly at its root
# or inside a single top-level directory.
$RootCandidates = @(
    $HatsExtract
)

$Directories = @(
    Get-ChildItem `
        -Path $HatsExtract `
        -Directory `
        -ErrorAction SilentlyContinue
)

if ($Directories.Count -eq 1) {
    $RootCandidates += $Directories[0].FullName
}

$HatsRoot = $null

foreach ($Candidate in $RootCandidates) {

    $HasBootFile = Test-Path (Join-Path $Candidate "boot.dat")
    $HasManifest = Test-Path (Join-Path $Candidate "manifest.json")

    if ($HasBootFile -or $HasManifest) {
        $HatsRoot = $Candidate
        break
    }
}

if ($null -eq $HatsRoot) {
    $HatsRoot = $HatsExtract
}

Write-Host "HATS base root:"
Write-Host $HatsRoot
Write-Host ""

# Copy all HATS base files into pack.
Copy-Item `
    -Path (Join-Path $HatsRoot "*") `
    -Destination $Pack `
    -Recurse `
    -Force `
    -ErrorAction Stop

Write-Host "HATS base installed."
Write-Host ""

# ------------------------------------------------------------
# COMPONENT INSTALLATION
# ------------------------------------------------------------

$Index = 0

$ComponentsToInstall = @(
    $Config.components |
    Where-Object {
        $_.mode -ne "hats_base"
    }
)

$Total = $ComponentsToInstall.Count

foreach ($Component in $ComponentsToInstall) {

    $Index++

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Component $Index of $Total"
    Write-Host "$($Component.name)"
    Write-Host "========================================"

    if ([string]::IsNullOrWhiteSpace($Component.repo)) {
        throw "Component '$($Component.name)' has no repository."
    }

    if ([string]::IsNullOrWhiteSpace($Component.asset_regex)) {
        throw "Component '$($Component.name)' has no asset_regex."
    }

    Write-Host "Repository: $($Component.repo)"
    Write-Host "Mode: $($Component.mode)"

    $Release = Get-LatestRelease $Component.repo

    if ($null -eq $Release) {
        throw "No release information returned for $($Component.repo)"
    }

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

        foreach ($Available in @($Release.assets)) {
            Write-Host "  $($Available.name)"
        }

        throw "Could not find an asset matching '$($Component.asset_regex)' for $($Component.repo)"
    }

    Write-Host "Asset: $($Asset.name)"

    $DownloadPath = Join-Path $Work $Asset.name

    Download-Asset `
        -Asset $Asset `
        -Destination $DownloadPath

    switch ($Component.mode) {

        "zip" {

            Install-Zip `
                -ZipPath $DownloadPath `
                -Destination $Pack

            continue
        }

        "nro" {

            if ([string]::IsNullOrWhiteSpace($Component.destination)) {
                throw "Component '$($Component.name)' has no destination."
            }

            $Destination = Join-Path `
                $Pack `
                $Component.destination

            Install-File `
                -Source $DownloadPath `
                -Destination $Destination

            continue
        }

        "ovl" {

            if ([string]::IsNullOrWhiteSpace($Component.destination)) {
                throw "Component '$($Component.name)' has no destination."
            }

            $OverlayDestination = $Component.destination `
                -replace '^switch[\\/]\.overlays[\\/]', 'switch\.overlays\'

            $Destination = Join-Path `
                $Pack `
                $OverlayDestination

            Install-File `
                -Source $DownloadPath `
                -Destination $Destination

            continue
        }

        "file" {

            if ([string]::IsNullOrWhiteSpace($Component.destination)) {
                throw "Component '$($Component.name)' has no destination."
            }

            $Destination = Join-Path `
                $Pack `
                $Component.destination

            Install-File `
                -Source $DownloadPath `
                -Destination $Destination

            continue
        }

        default {
            throw "Unknown component mode '$($Component.mode)' for $($Component.name)"
        }
    }
}

# ------------------------------------------------------------
# VERIFY REQUIRED HATS ROOT FILES
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying HATS root files"
Write-Host "========================================"
Write-Host ""

$RequiredRootFiles = @(
    "boot.dat",
    "boot.ini",
    "exosphere.ini",
    "manifest.json",
    "payload.bin"
)

$MissingRootFiles = @()

foreach ($FileName in $RequiredRootFiles) {

    $Path = Join-Path $Pack $FileName

    if (Test-Path $Path) {
        $File = Get-Item $Path

        if ($File.Length -gt 0) {
            Write-Host "[OK] $FileName - $($File.Length) bytes"
        }
        else {
            Write-Host "[ERROR] $FileName is empty" -ForegroundColor Red
            $MissingRootFiles += $FileName
        }
    }
    else {
        Write-Host "[MISSING] $FileName" -ForegroundColor Red
        $MissingRootFiles += $FileName
    }
}

if ($MissingRootFiles.Count -gt 0) {
    throw "HATS base is missing required root files: $($MissingRootFiles -join ', ')"
}

# ------------------------------------------------------------
# VERIFY IMPORTANT DIRECTORIES
# ------------------------------------------------------------

Write-Host ""
Write-Host "Verifying directories..."

$RequiredDirectories = @(
    "atmosphere",
    "bootloader",
    "switch"
)

foreach ($Directory in $RequiredDirectories) {

    $Path = Join-Path $Pack $Directory

    if (Test-Path $Path -PathType Container) {
        Write-Host "[OK] $Directory/"
    }
    else {
        Write-Host "[WARNING] $Directory/ not found" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# VERIFY PACK
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying pack"
Write-Host "========================================"
Write-Host ""

if (-not (Test-Path $Pack)) {
    throw "Pack directory does not exist."
}

$PackFiles = @(
    Get-ChildItem `
        -Path $Pack `
        -Recurse `
        -File
)

if ($PackFiles.Count -eq 0) {
    throw "Pack directory is empty."
}

Write-Host "Files in pack: $($PackFiles.Count)"
Write-Host ""

# ------------------------------------------------------------
# CREATE FINAL ZIP
# ------------------------------------------------------------

$Output = Join-Path `
    $Root `
    "SkipperBNS-HATS-$Version.zip"

if (Test-Path $Output) {
    Remove-Item $Output -Force
}

Write-Host "Creating final HATS ZIP..."

Compress-Archive `
    -Path (Join-Path $Pack "*") `
    -DestinationPath $Output `
    -Force `
    -ErrorAction Stop

if (-not (Test-Path $Output)) {
    throw "Final ZIP was not created."
}

$OutputFile = Get-Item $Output

if ($OutputFile.Length -le 0) {
    throw "Final ZIP is empty."
}

# ------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"
Write-Host "Output: $($OutputFile.FullName)"
Write-Host "Size:   $($OutputFile.Length) bytes"
Write-Host ""

Write-Host "Required HATS root files:"
foreach ($FileName in $RequiredRootFiles) {
    Write-Host "  [OK] $FileName"
}

Write-Host ""
Write-Host "Pack contents:"
Get-ChildItem `
    -Path $Pack `
    -Recurse `
    -File |
    Select-Object FullName, Length |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Build completed successfully."
