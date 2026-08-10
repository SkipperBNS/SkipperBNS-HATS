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

# ------------------------------------------------------------
# CHECK COMPONENTS
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
    Write-Host "GitHub API token: configured"
}
else {
    Write-Host "GitHub API token: NOT configured"
}

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
# DOWNLOAD
# ------------------------------------------------------------

function Download-Asset {
    param(
        [Parameter(Mandatory = $true)]
        $Asset,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Write-Host "Downloading: $($Asset.name)"

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
    Write-Host "  $ZipPath"

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

    Write-Host "Installed:"
    Write-Host "  $Destination"
}

# ------------------------------------------------------------
# COPY DIRECTORY CONTENTS WITHOUT SdOut WRAPPER
# ------------------------------------------------------------

function Merge-DirectoryContents {
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

    $Items = Get-ChildItem -LiteralPath $Source -Force

    foreach ($Item in $Items) {
        $Target = Join-Path $Destination $Item.Name

        Copy-Item `
            -LiteralPath $Item.FullName `
            -Destination $Target `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }
}

# ------------------------------------------------------------
# INSTALL HATS BASE
#
# HATS releases commonly contain:
#
# SdOut/
#   atmosphere/
#   bootloader/
#   switch/
#   boot.dat
#   ...
#
# We copy the CONTENTS of SdOut into Pack.
#
# This prevents:
#
# SdOut/atmosphere
# SdOut/switch
#
# from appearing in the final ZIP.
# ------------------------------------------------------------

function Install-HatsBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $ExtractPath = Join-Path $Work "HATS-Base-Extract"

    if (Test-Path $ExtractPath) {
        Remove-Item $ExtractPath -Recurse -Force
    }

    New-Item `
        -ItemType Directory `
        -Path $ExtractPath `
        -Force | Out-Null

    Install-Zip `
        -ZipPath $ZipPath `
        -Destination $ExtractPath

    Write-Host ""
    Write-Host "Inspecting HATS base..."

    $SdOut = Get-ChildItem `
        -LiteralPath $ExtractPath `
        -Directory `
        -Recurse `
        -ErrorAction Stop |
        Where-Object {
            $_.Name -ieq "SdOut"
        } |
        Select-Object -First 1

    if ($null -ne $SdOut) {

        Write-Host "Found SdOut:"
        Write-Host "  $($SdOut.FullName)"

        Write-Host "Merging SdOut contents into pack..."

        Merge-DirectoryContents `
            -Source $SdOut.FullName `
            -Destination $Destination

        return
    }

    # Some HATS releases may already have their SD contents
    # at the ZIP root. Detect that situation.

    $RootEntries = @(Get-ChildItem `
        -LiteralPath $ExtractPath `
        -Force)

    $LooksLikeSdRoot = $false

    foreach ($Entry in $RootEntries) {
        if (
            $Entry.Name -ieq "atmosphere" -or
            $Entry.Name -ieq "bootloader" -or
            $Entry.Name -ieq "switch" -or
            $Entry.Name -ieq "boot.dat" -or
            $Entry.Name -ieq "boot.ini" -or
            $Entry.Name -ieq "payload.bin" -or
            $Entry.Name -ieq "exosphere.ini" -or
            $Entry.Name -ieq "manifest.json"
        ) {
            $LooksLikeSdRoot = $true
            break
        }
    }

    if ($LooksLikeSdRoot) {
        Write-Host "HATS archive already contains SD root contents."
        Write-Host "Merging archive root into pack..."

        Merge-DirectoryContents `
            -Source $ExtractPath `
            -Destination $Destination

        return
    }

    throw "Could not locate the HATS SD contents or SdOut directory."
}

# ------------------------------------------------------------
# MAIN BUILD
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

    if ([string]::IsNullOrWhiteSpace($Component.mode)) {
        throw "Component '$($Component.name)' has no mode."
    }

    Write-Host "Mode: $($Component.mode)"

    # --------------------------------------------------------
    # LOCAL ROOT FILE
    # --------------------------------------------------------

    if ($Component.mode -eq "local_root") {

        if ([string]::IsNullOrWhiteSpace($Component.source)) {
            throw "Component '$($Component.name)' has no source."
        }

        if ([string]::IsNullOrWhiteSpace($Component.destination)) {
            throw "Component '$($Component.name)' has no destination."
        }

        $Source = Join-Path $Root $Component.source
        $Destination = Join-Path $Pack $Component.destination

        Write-Host "Local source:"
        Write-Host "  $Source"

        if (-not (Test-Path $Source)) {
            throw "Local file was not found: $Source"
        }

        Install-File `
            -Source $Source `
            -Destination $Destination

        continue
    }

    # --------------------------------------------------------
    # HATS BASE
    # --------------------------------------------------------

    if ($Component.mode -eq "hats_base") {

        if ([string]::IsNullOrWhiteSpace($Component.repo)) {
            throw "Component '$($Component.name)' has no repository."
        }

        if ([string]::IsNullOrWhiteSpace($Component.asset_regex)) {
            throw "Component '$($Component.name)' has no asset_regex."
        }

        Write-Host "Repository: $($Component.repo)"

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
            Write-Host "ERROR: No matching HATS asset found." -ForegroundColor Red
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

        Install-HatsBase `
            -ZipPath $DownloadPath `
            -Destination $Pack

        continue
    }

    # --------------------------------------------------------
    # GITHUB COMPONENTS
    # --------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($Component.repo)) {
        throw "Component '$($Component.name)' has no repository."
    }

    if ([string]::IsNullOrWhiteSpace($Component.asset_regex)) {
        throw "Component '$($Component.name)' has no asset_regex."
    }

    Write-Host "Repository: $($Component.repo)"

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

    $SafeAssetName = $Asset.name -replace '[\\/:*?"<>|]', '_'
    $DownloadPath = Join-Path $Work "$Index-$SafeAssetName"

    Download-Asset `
        -Asset $Asset `
        -Destination $DownloadPath

    switch ($Component.mode) {

        # ----------------------------------------------------
        # ZIP
        # ----------------------------------------------------

        "zip" {

            $ExtractPath = Join-Path $Work "component-$Index"

            if (Test-Path $ExtractPath) {
                Remove-Item $ExtractPath -Recurse -Force
            }

            New-Item `
                -ItemType Directory `
                -Path $ExtractPath `
                -Force | Out-Null

            Install-Zip `
                -ZipPath $DownloadPath `
                -Destination $ExtractPath

            # Merge ZIP contents into the final SD root.
            Merge-DirectoryContents `
                -Source $ExtractPath `
                -Destination $Pack

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
# VERIFY LOCAL FILES
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying required local applications"
Write-Host "========================================"

$RequiredLocalFiles = @(
    "switch\ftpd.nro",
    "switch\checkpoint.nro"
)

foreach ($RelativePath in $RequiredLocalFiles) {

    $RequiredPath = Join-Path $Pack $RelativePath

    if (-not (Test-Path $RequiredPath)) {
        throw "Required file missing from final pack: $RelativePath"
    }

    $RequiredFile = Get-Item $RequiredPath

    if ($RequiredFile.Length -le 0) {
        throw "Required file is empty: $RelativePath"
    }

    Write-Host "OK: $RelativePath"
}

# ------------------------------------------------------------
# VERIFY IMPORTANT HATS FILES
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying HATS base files"
Write-Host "========================================"

$ImportantFiles = @(
    "boot.dat",
    "boot.ini",
    "exosphere.ini",
    "manifest.json",
    "payload.bin"
)

foreach ($RelativePath in $ImportantFiles) {

    $CheckPath = Join-Path $Pack $RelativePath

    if (Test-Path $CheckPath) {
        Write-Host "OK: $RelativePath"
    }
    else {
        Write-Host "WARNING: $RelativePath not found"
    }
}

# ------------------------------------------------------------
# VERIFY NO SdOut DIRECTORY
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Checking for unwanted SdOut directory"
Write-Host "========================================"

$SdOutDirectories = @(
    Get-ChildItem `
        -Path $Pack `
        -Directory `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "SdOut"
        }
)

if ($SdOutDirectories.Count -gt 0) {
    foreach ($BadDirectory in $SdOutDirectories) {
        Write-Host "Removing unwanted SdOut:"
        Write-Host "  $($BadDirectory.FullName)"

        Remove-Item `
            $BadDirectory.FullName `
            -Recurse `
            -Force
    }
}

# ------------------------------------------------------------
# VERIFY PACK
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying pack"
Write-Host "========================================"

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

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"
Write-Host "Output: $($OutputFile.FullName)"
Write-Host "Size:   $($OutputFile.Length) bytes"
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
