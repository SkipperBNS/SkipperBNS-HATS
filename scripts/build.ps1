param(
    [string]$Version = "main"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "       SkipperBNS HATS Pack Builder"
Write-Host "========================================"
Write-Host ""

# ------------------------------------------------------------
# PATHS
# ------------------------------------------------------------

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

Write-Host "Cleaning previous build..."

if (Test-Path $Work) {
    Remove-Item $Work -Recurse -Force
}

if (Test-Path $Pack) {
    Remove-Item $Pack -Recurse -Force
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Pack -Force | Out-Null

Write-Host "Build directories ready."
Write-Host ""

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
        [object]$Release,

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
        [object]$Asset,

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
# MERGE DIRECTORY CONTENTS
# ------------------------------------------------------------

function Merge-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path $Source -PathType Container)) {
        throw "Source directory does not exist: $Source"
    }

    New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    $Items = @(Get-ChildItem -LiteralPath $Source -Force)

    foreach ($Item in $Items) {

        $Target = Join-Path $Destination $Item.Name

        if ($Item.PSIsContainer) {

            if (Test-Path $Target -PathType Container) {

                Merge-DirectoryContents `
                    -Source $Item.FullName `
                    -Destination $Target
            }
            else {

                New-Item `
                    -ItemType Directory `
                    -Path $Target `
                    -Force | Out-Null

                Merge-DirectoryContents `
                    -Source $Item.FullName `
                    -Destination $Target
            }
        }
        else {

            Copy-Item `
                -LiteralPath $Item.FullName `
                -Destination $Target `
                -Force `
                -ErrorAction Stop
        }
    }
}

# ------------------------------------------------------------
# INSTALL HATS BASE
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

    # --------------------------------------------------------
    # LOOK FOR SdOut
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # CHECK IF ARCHIVE ROOT IS ALREADY SD ROOT
    # --------------------------------------------------------

    $RootEntries = @(
        Get-ChildItem `
            -LiteralPath $ExtractPath `
            -Force
    )

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
# NORMALIZE NESTED BOOTLOADER
# ------------------------------------------------------------

function Normalize-Bootloader {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Normalizing bootloader structure"
    Write-Host "========================================"

    $Bootloader = Join-Path $Pack "bootloader"

    if (-not (Test-Path $Bootloader -PathType Container)) {

        Write-Host "No bootloader directory found."
        return
    }

    while ($true) {

        $NestedBootloader = Join-Path $Bootloader "bootloader"

        if (-not (Test-Path $NestedBootloader -PathType Container)) {
            break
        }

        Write-Host "Found nested bootloader:"
        Write-Host "  $NestedBootloader"

        $Items = @(Get-ChildItem -LiteralPath $NestedBootloader -Force)

        foreach ($Item in $Items) {

            $Target = Join-Path $Bootloader $Item.Name

            if ($Item.PSIsContainer) {

                if (Test-Path $Target -PathType Container) {

                    Merge-DirectoryContents `
                        -Source $Item.FullName `
                        -Destination $Target

                    Remove-Item `
                        -LiteralPath $Item.FullName `
                        -Recurse `
                        -Force
                }
                else {

                    Move-Item `
                        -LiteralPath $Item.FullName `
                        -Destination $Target `
                        -Force `
                        -ErrorAction Stop
                }
            }
            else {

                Copy-Item `
                    -LiteralPath $Item.FullName `
                    -Destination $Target `
                    -Force `
                    -ErrorAction Stop

                Remove-Item `
                    -LiteralPath $Item.FullName `
                    -Force
            }
        }

        if (Test-Path $NestedBootloader) {

            Remove-Item `
                -LiteralPath $NestedBootloader `
                -Recurse `
                -Force
        }
    }

    Write-Host "Bootloader structure is clean."
}

# ------------------------------------------------------------
# REMOVE SdOut DIRECTORIES
# ------------------------------------------------------------

function Remove-SdOutDirectories {

    Write-Host ""
    Write-Host "Checking for unwanted SdOut directories..."

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

    foreach ($Directory in $SdOutDirectories) {

        Write-Host "Removing:"
        Write-Host "  $($Directory.FullName)"

        Remove-Item `
            -LiteralPath $Directory.FullName `
            -Recurse `
            -Force
    }

    if ($SdOutDirectories.Count -eq 0) {
        Write-Host "No unwanted SdOut directories found."
    }
}

# ------------------------------------------------------------
# REMOVE DUPLICATE APPLICATION NRO FILES
# ------------------------------------------------------------

function Remove-DuplicateApplications {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Removing duplicate application NRO files"
    Write-Host "========================================"

    $SwitchPath = Join-Path $Pack "switch"

    if (-not (Test-Path $SwitchPath -PathType Container)) {
        Write-Host "No switch directory found."
        return
    }

    # These applications are supplied by HATS Base.
    # If an application folder exists, remove the duplicate
    # root-level NRO file.

    $Applications = @(
        @{
            Name = "90DNS Testing Utility"
            Nro = "90DNSTester.nro"
            Folder = "Switch_90DNS_tester"
        },
        @{
            Name = "Goldleaf"
            Nro = "Goldleaf.nro"
            Folder = "Goldleaf"
        },
        @{
            Name = "JKSV"
            Nro = "JKSV.nro"
            Folder = "JKSV"
        },
        @{
            Name = "NXThemes Installer"
            Nro = "NXThemesInstaller.nro"
            Folder = "NXThemesInstaller"
        }
    )

    foreach ($Application in $Applications) {

        $NroPath = Join-Path $SwitchPath $Application.Nro
        $FolderPath = Join-Path $SwitchPath $Application.Folder

        if (
            (Test-Path $NroPath -PathType Leaf) -and
            (Test-Path $FolderPath -PathType Container)
        ) {

            Write-Host "Removing duplicate:"
            Write-Host "  $($Application.Nro)"

            Remove-Item `
                -LiteralPath $NroPath `
                -Force `
                -ErrorAction Stop
        }
        else {

            if (Test-Path $NroPath -PathType Leaf) {
                Write-Host "Keeping $($Application.Nro) because no matching application folder was found."
            }
        }
    }

    Write-Host "Application duplicate cleanup complete."
}

# ------------------------------------------------------------
# REMOVE DUPLICATE OVERLAYS
# ------------------------------------------------------------

function Remove-DuplicateOverlays {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Removing duplicate overlays"
    Write-Host "========================================"

    $OverlayPath = Join-Path $Pack "switch\.overlays"

    if (-not (Test-Path $OverlayPath -PathType Container)) {
        Write-Host "No .overlays directory found."
        return
    }

    # --------------------------------------------------------
    # EDIZON
    # --------------------------------------------------------

    $EdiZon = Join-Path $OverlayPath "EdiZon.ovl"
    $OldEdiZon = Join-Path $OverlayPath "ovlEdiZon.ovl"

    if (
        (Test-Path $EdiZon -PathType Leaf) -and
        (Test-Path $OldEdiZon -PathType Leaf)
    ) {

        Write-Host "Removing duplicate EdiZon overlay:"
        Write-Host "  ovlEdiZon.ovl"

        Remove-Item `
            -LiteralPath $OldEdiZon `
            -Force `
            -ErrorAction Stop
    }
    elseif (
        (-not (Test-Path $EdiZon -PathType Leaf)) -and
        (Test-Path $OldEdiZon -PathType Leaf)
    ) {

        Write-Host "EdiZon.ovl not found."
        Write-Host "Renaming ovlEdiZon.ovl to EdiZon.ovl"

        Rename-Item `
            -LiteralPath $OldEdiZon `
            -NewName "EdiZon.ovl" `
            -Force `
            -ErrorAction Stop
    }

    Write-Host "Overlay duplicate cleanup complete."
}

# ------------------------------------------------------------
# VERIFY BOOTLOADER
# ------------------------------------------------------------

function Verify-Bootloader {

    $NestedBootloader = Join-Path $Pack "bootloader\bootloader"

    if (Test-Path $NestedBootloader -PathType Container) {
        throw "Nested bootloader directory still exists: $NestedBootloader"
    }

    Write-Host "OK: No nested bootloader directory found."
}

# ------------------------------------------------------------
# VERIFY CUSTOM HEKATE RESOURCES
# ------------------------------------------------------------

function Verify-CustomHekateResources {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Verifying custom Hekate resources"
    Write-Host "========================================"

    $ResPath = Join-Path $Pack "bootloader\res"

    $RequiredImages = @(
        "background.bmp",
        "sysmmc.bmp",
        "emummc.bmp",
        "ofw.bmp",
        "stock.bmp"
    )

    foreach ($ImageName in $RequiredImages) {

        $ImagePath = Join-Path $ResPath $ImageName

        if (-not (Test-Path $ImagePath -PathType Leaf)) {
            throw "Required Hekate image missing: bootloader\res\$ImageName"
        }

        $ImageFile = Get-Item $ImagePath

        if ($ImageFile.Length -le 0) {
            throw "Hekate image is empty: $ImageName"
        }

        Write-Host "OK: bootloader\res\$ImageName"
        Write-Host "Size: $($ImageFile.Length) bytes"
    }

    $HekateConfig = Join-Path $Pack "bootloader\hekate_ipl.ini"

    if (-not (Test-Path $HekateConfig -PathType Leaf)) {
        throw "Custom hekate_ipl.ini is missing."
    }

    $ConfigFile = Get-Item $HekateConfig

    if ($ConfigFile.Length -le 0) {
        throw "Custom hekate_ipl.ini is empty."
    }

    Write-Host "OK: bootloader\hekate_ipl.ini"
    Write-Host "Size: $($ConfigFile.Length) bytes"
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
    # LOCAL ROOT
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

        if (-not (Test-Path $Source -PathType Leaf)) {
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
    # GITHUB COMPONENT
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
                -replace '^switch[\\/]\\.overlays[\\/]', 'switch\.overlays\'

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
# FINAL CLEANUP
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "FINAL PACK CLEANUP"
Write-Host "========================================"

Normalize-Bootloader

Remove-SdOutDirectories

Remove-DuplicateApplications

Remove-DuplicateOverlays

Verify-Bootloader

# ------------------------------------------------------------
# VERIFY CUSTOM HEKATE RESOURCES
# ------------------------------------------------------------

Verify-CustomHekateResources

# ------------------------------------------------------------
# VERIFY REQUIRED LOCAL FILES
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

    if (-not (Test-Path $RequiredPath -PathType Leaf)) {
        throw "Required file missing from final pack: $RelativePath"
    }

    $RequiredFile = Get-Item $RequiredPath

    if ($RequiredFile.Length -le 0) {
        throw "Required file is empty: $RelativePath"
    }

    Write-Host "OK: $RelativePath"
}

# ------------------------------------------------------------
# VERIFY DUPLICATE APPLICATIONS ARE GONE
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying application cleanup"
Write-Host "========================================"

$SwitchPath = Join-Path $Pack "switch"

$DuplicateRootNros = @(
    "90DNSTester.nro",
    "Goldleaf.nro",
    "JKSV.nro",
    "NXThemesInstaller.nro"
)

foreach ($NroName in $DuplicateRootNros) {

    $NroPath = Join-Path $SwitchPath $NroName

    if (Test-Path $NroPath -PathType Leaf) {
        throw "Duplicate root NRO still exists: switch\$NroName"
    }

    Write-Host "OK: no duplicate switch\$NroName"
}

# ------------------------------------------------------------
# VERIFY EDIZON DUPLICATE IS GONE
# ------------------------------------------------------------

$OverlayPath = Join-Path $Pack "switch\.overlays"

$DuplicateEdiZon = Join-Path $OverlayPath "ovlEdiZon.ovl"
$CorrectEdiZon = Join-Path $OverlayPath "EdiZon.ovl"

if (Test-Path $DuplicateEdiZon -PathType Leaf) {
    throw "Duplicate EdiZon overlay still exists: switch\.overlays\ovlEdiZon.ovl"
}

if (-not (Test-Path $CorrectEdiZon -PathType Leaf)) {
    throw "EdiZon.ovl is missing from switch\.overlays"
}

Write-Host "OK: only EdiZon.ovl is installed."

# ------------------------------------------------------------
# VERIFY PACK
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying final pack"
Write-Host "========================================"

if (-not (Test-Path $Pack -PathType Container)) {
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

# ------------------------------------------------------------
# SHOW FINAL SWITCH STRUCTURE
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Final switch structure"
Write-Host "========================================"

$FinalSwitch = Join-Path $Pack "switch"

if (Test-Path $FinalSwitch -PathType Container) {

    Get-ChildItem `
        -Path $FinalSwitch `
        -Force |
        Select-Object Name, Mode, Length |
        Format-Table -AutoSize
}

# ------------------------------------------------------------
# SHOW FINAL OVERLAY STRUCTURE
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Final overlay structure"
Write-Host "========================================"

$FinalOverlays = Join-Path $Pack "switch\.overlays"

if (Test-Path $FinalOverlays -PathType Container) {

    Get-ChildItem `
        -Path $FinalOverlays `
        -File `
        -Force |
        Select-Object Name, Length |
        Format-Table -AutoSize
}

# ------------------------------------------------------------
# SHOW FINAL BOOTLOADER STRUCTURE
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Final bootloader structure"
Write-Host "========================================"

$FinalBootloader = Join-Path $Pack "bootloader"

if (Test-Path $FinalBootloader -PathType Container) {

    Get-ChildItem `
        -Path $FinalBootloader `
        -Recurse `
        -Force |
        Select-Object FullName |
        Format-Table -AutoSize
}
else {
    Write-Host "WARNING: bootloader directory does not exist."
}

# ------------------------------------------------------------
# CREATE FINAL ZIP
# ------------------------------------------------------------

$Output = Join-Path `
    $Root `
    "SkipperBNS-HATS-$Version.zip"

if (Test-Path $Output) {
    Remove-Item $Output -Force
}

Write-Host ""
Write-Host "========================================"
Write-Host "Creating final HATS ZIP"
Write-Host "========================================"

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
# SUCCESS
# ------------------------------------------------------------

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
Write-Host "========================================"
Write-Host "SkipperBNS HATS BUILD COMPLETE"
Write-Host "========================================"
