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
# LOAD COMPONENTS
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

Write-Host "GitHub token configured: $(-not [string]::IsNullOrWhiteSpace($GitHubToken))"
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

    Write-Host "Checking latest release..."

    for ($Attempt = 1; $Attempt -le 5; $Attempt++) {
        try {
            $Response = Invoke-RestMethod `
                -Uri $Url `
                -Headers $Headers `
                -Method Get `
                -ErrorAction Stop

            return $Response
        }
        catch {
            $Message = $_.Exception.Message

            Write-Host "Release request failed (attempt $Attempt of 5)."
            Write-Host $Message

            if ($Attempt -eq 5) {
                throw "Could not retrieve latest release for '$Repo'. $Message"
            }

            # GitHub API rate limiting.
            # Wait progressively longer.
            $Delay = 5 * $Attempt

            if ($Message -match "403") {
                $Delay = 15 * $Attempt
            }

            Write-Host "Waiting $Delay seconds before retry..."
            Start-Sleep -Seconds $Delay
        }
    }

    throw "Unexpected error retrieving release for '$Repo'."
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

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Invoke-WebRequest `
                -Uri $Asset.browser_download_url `
                -Headers $Headers `
                -OutFile $Destination `
                -UseBasicParsing `
                -ErrorAction Stop

            if (-not (Test-Path $Destination)) {
                throw "Downloaded file does not exist."
            }

            $DownloadedFile = Get-Item $Destination

            if ($DownloadedFile.Length -le 0) {
                throw "Downloaded file is empty."
            }

            Write-Host "Downloaded: $($DownloadedFile.Length) bytes"
            return
        }
        catch {
            Write-Host "Download failed (attempt $Attempt of 3)."

            if ($Attempt -eq 3) {
                throw "Could not download '$($Asset.name)'. $($_.Exception.Message)"
            }

            Start-Sleep -Seconds (5 * $Attempt)
        }
    }
}

# ------------------------------------------------------------
# COPY TREE
#
# Copies files recursively while preserving their relative
# paths. Existing files are overwritten.
#
# This prevents:
#
# SdOut\switch
#
# from becoming:
#
# pack\SdOut\switch
# ------------------------------------------------------------

function Merge-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "Source directory does not exist: $Source"
    }

    New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    $SourceRoot = (Resolve-Path $Source).Path.TrimEnd('\')

    $Files = Get-ChildItem `
        -Path $Source `
        -Recurse `
        -File `
        -Force

    foreach ($File in $Files) {

        $Relative = $File.FullName.Substring(
            $SourceRoot.Length
        ).TrimStart('\')

        $Target = Join-Path `
            $Destination `
            $Relative

        $TargetFolder = Split-Path `
            $Target `
            -Parent

        if (-not [string]::IsNullOrWhiteSpace($TargetFolder)) {
            New-Item `
                -ItemType Directory `
                -Path $TargetFolder `
                -Force | Out-Null
        }

        Copy-Item `
            -LiteralPath $File.FullName `
            -Destination $Target `
            -Force
    }
}

# ------------------------------------------------------------
# EXTRACT ZIP TO TEMP DIRECTORY
# ------------------------------------------------------------

function Extract-Zip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }

    New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    Write-Host "Extracting ZIP..."

    Expand-Archive `
        -Path $ZipPath `
        -DestinationPath $Destination `
        -Force `
        -ErrorAction Stop
}

# ------------------------------------------------------------
# MERGE ZIP
#
# Handles these layouts:
#
# 1. atmosphere/...
# 2. switch/...
# 3. SdOut/atmosphere/...
# 4. SdOut/switch/...
#
# SdOut is automatically removed from the final structure.
# ------------------------------------------------------------

function Merge-ZipIntoPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath
    )

    $ExtractPath = Join-Path `
        $Work `
        ("extract_" + [guid]::NewGuid().ToString())

    Extract-Zip `
        -ZipPath $ZipPath `
        -Destination $ExtractPath

    $RootEntries = @(Get-ChildItem `
        -Path $ExtractPath `
        -Force)

    if ($RootEntries.Count -eq 0) {
        throw "ZIP contains no files: $ZipPath"
    }

    # --------------------------------------------------------
    # CASE 1:
    # ZIP has a single SdOut directory.
    #
    # Extract:
    #   SdOut\atmosphere
    #   SdOut\switch
    #
    # Into:
    #   pack\atmosphere
    #   pack\switch
    # --------------------------------------------------------

    $SdOut = $RootEntries |
        Where-Object {
            $_.PSIsContainer -and
            $_.Name -ieq "SdOut"
        }

    if ($SdOut.Count -eq 1) {

        Write-Host "Detected SdOut directory."
        Write-Host "Merging SdOut contents into pack root."

        Merge-Directory `
            -Source $SdOut.FullName `
            -Destination $Pack

        return
    }

    # --------------------------------------------------------
    # CASE 2:
    # ZIP has another single wrapper directory.
    #
    # Only unwrap it if it contains typical SD-card content.
    # --------------------------------------------------------

    if ($RootEntries.Count -eq 1 -and $RootEntries[0].PSIsContainer) {

        $Wrapper = $RootEntries[0]

        $WrapperChildren = @(Get-ChildItem `
            -Path $Wrapper.FullName `
            -Force)

        $LooksLikeSdRoot = $false

        foreach ($Child in $WrapperChildren) {
            if (
                $Child.Name -ieq "atmosphere" -or
                $Child.Name -ieq "bootloader" -or
                $Child.Name -ieq "switch" -or
                $Child.Name -ieq "payload.bin" -or
                $Child.Name -ieq "boot.dat" -or
                $Child.Name -ieq "boot.ini" -or
                $Child.Name -ieq "exosphere.ini" -or
                $Child.Name -ieq "hekate_ipl.ini"
            ) {
                $LooksLikeSdRoot = $true
                break
            }
        }

        if ($LooksLikeSdRoot) {

            Write-Host "Detected wrapper directory: $($Wrapper.Name)"
            Write-Host "Merging wrapper contents into pack root."

            Merge-Directory `
                -Source $Wrapper.FullName `
                -Destination $Pack

            return
        }
    }

    # --------------------------------------------------------
    # CASE 3:
    # Normal ZIP.
    # --------------------------------------------------------

    Write-Host "Merging ZIP contents into pack root."

    Merge-Directory `
        -Source $ExtractPath `
        -Destination $Pack
}

# ------------------------------------------------------------
# INSTALL SINGLE FILE
# ------------------------------------------------------------

function Install-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $DestinationFolder = Split-Path `
        $Destination `
        -Parent

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
# PROCESS COMPONENTS
# ------------------------------------------------------------

$Index = 0
$Total = $Config.components.Count

foreach ($Component in $Config.components) {

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

    if ([string]::IsNullOrWhiteSpace($Component.mode)) {
        throw "Component '$($Component.name)' has no mode."
    }

    Write-Host "Repository: $($Component.repo)"
    Write-Host "Mode:       $($Component.mode)"

    $Release = Get-LatestRelease $Component.repo

    if ($null -eq $Release) {
        throw "No release information returned for $($Component.repo)"
    }

    Write-Host "Release:    $($Release.tag_name)"

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

    Write-Host "Asset:      $($Asset.name)"

    $SafeAssetName = $Asset.name -replace '[\\/:*?"<>|]', '_'

    $DownloadPath = Join-Path `
        $Work `
        $SafeAssetName

    Download-Asset `
        -Asset $Asset `
        -Destination $DownloadPath

    # --------------------------------------------------------
    # HATS BASE
    #
    # The HATS ZIP is the foundation of the final SD card.
    # Its SdOut folder is flattened automatically.
    # --------------------------------------------------------

    switch ($Component.mode.ToLowerInvariant()) {

        "hats_base" {

            if (-not $Asset.name.ToLowerInvariant().EndsWith(".zip")) {
                throw "HATS Base asset must be a ZIP: $($Asset.name)"
            }

            Merge-ZipIntoPack `
                -ZipPath $DownloadPath

            continue
        }

        # ----------------------------------------------------
        # NORMAL ZIP
        # ----------------------------------------------------

        "zip" {

            if (-not $Asset.name.ToLowerInvariant().EndsWith(".zip")) {
                throw "Component '$($Component.name)' is mode zip but asset is not a ZIP."
            }

            Merge-ZipIntoPack `
                -ZipPath $DownloadPath

            continue
        }

        # ----------------------------------------------------
        # NRO
        # ----------------------------------------------------

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

        # ----------------------------------------------------
        # OVL
        # ----------------------------------------------------

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

        # ----------------------------------------------------
        # FILE
        # ----------------------------------------------------

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
# REMOVE EMPTY DIRECTORIES
# ------------------------------------------------------------

Get-ChildItem `
    -Path $Pack `
    -Directory `
    -Recurse `
    -Force |
    Sort-Object FullName -Descending |
    ForEach-Object {

        $Children = @(Get-ChildItem `
            -LiteralPath $_.FullName `
            -Force)

        if ($Children.Count -eq 0) {
            Remove-Item `
                -LiteralPath $_.FullName `
                -Force
        }
    }

# ------------------------------------------------------------
# VERIFY REQUIRED HATS FILES
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying HATS base"
Write-Host "========================================"
Write-Host ""

$RequiredFiles = @(
    "boot.dat",
    "boot.ini",
    "exosphere.ini",
    "manifest.json",
    "payload.bin"
)

$MissingRequired = @()

foreach ($Required in $RequiredFiles) {

    $RequiredPath = Join-Path `
        $Pack `
        $Required

    if (Test-Path $RequiredPath) {
        Write-Host "[OK] $Required"
    }
    else {
        Write-Host "[MISSING] $Required" -ForegroundColor Yellow
        $MissingRequired += $Required
    }
}

if ($MissingRequired.Count -gt 0) {

    Write-Host ""
    Write-Host "WARNING: Some expected HATS root files are missing:" -ForegroundColor Yellow

    foreach ($Missing in $MissingRequired) {
        Write-Host "  $Missing"
    }

    Write-Host ""
    Write-Host "The build will continue because upstream HATS may change its root files."
}

# ------------------------------------------------------------
# VERIFY NO SDOUT DIRECTORY
# ------------------------------------------------------------

$SdOutDirectory = Join-Path `
    $Pack `
    "SdOut"

if (Test-Path $SdOutDirectory) {
    throw "Invalid final structure: SdOut directory still exists in pack."
}

# ------------------------------------------------------------
# VERIFY PACK
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying pack"
Write-Host "========================================"
Write-Host ""

$PackFiles = @(
    Get-ChildItem `
        -Path $Pack `
        -Recurse `
        -File `
        -Force
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
    Remove-Item `
        $Output `
        -Force
}

Write-Host "Creating final HATS ZIP..."

Compress-Archive `
    -Path (Join-Path $Pack "*") `
    -DestinationPath $Output `
    -Force

if (-not (Test-Path $Output)) {
    throw "Final ZIP was not created."
}

$OutputFile = Get-Item $Output

if ($OutputFile.Length -le 0) {
    throw "Final ZIP is empty."
}

# ------------------------------------------------------------
# FINAL STRUCTURE CHECK
# ------------------------------------------------------------

$ZipCheckPath = Join-Path `
    $Work `
    "final_zip_check"

if (Test-Path $ZipCheckPath) {
    Remove-Item `
        $ZipCheckPath `
        -Recurse `
        -Force
}

Expand-Archive `
    -Path $Output `
    -DestinationPath $ZipCheckPath `
    -Force

if (Test-Path (Join-Path $ZipCheckPath "SdOut")) {
    throw "Final ZIP incorrectly contains SdOut directory."
}

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"
Write-Host ""

Write-Host "Output:"
Write-Host $OutputFile.FullName

Write-Host ""
Write-Host "Size:"
Write-Host "$($OutputFile.Length) bytes"

Write-Host ""
Write-Host "Root files:"

Get-ChildItem `
    -Path $Pack `
    -File `
    -Force |
    Select-Object Name, Length |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Build completed successfully."
