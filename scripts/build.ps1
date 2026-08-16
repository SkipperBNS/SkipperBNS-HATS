param(
    [string]$Version = "main"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "       SkipperBNS HATS Pack Builder"
Write-Host "========================================"
Write-Host ""

# ============================================================
# PATHS
# ============================================================

$Root = Split-Path -Parent $PSScriptRoot
$Pack = Join-Path $Root "pack"
$Work = Join-Path $Root "work"
$ComponentsFile = Join-Path $Root "components.json"
$DuplicateReport = Join-Path $Root "DUPLICATES.txt"

Write-Host "Root: $Root"
Write-Host "Pack: $Pack"
Write-Host "Work: $Work"
Write-Host ""

# ============================================================
# CLEAN BUILD DIRECTORIES
# ============================================================

Write-Host "========================================"
Write-Host "Cleaning previous build"
Write-Host "========================================"

if (Test-Path $Work) {
    Remove-Item $Work -Recurse -Force
}

if (Test-Path $Pack) {
    Remove-Item $Pack -Recurse -Force
}

if (Test-Path $DuplicateReport) {
    Remove-Item $DuplicateReport -Force
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Pack -Force | Out-Null

Write-Host "Build directories ready."
Write-Host ""

# ============================================================
# DUPLICATE TRACKING
# ============================================================

$FileOwners = @{}
$DuplicateFiles = @()

$CurrentComponent = "Unknown"

function Normalize-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Normalized = $Path.Replace("\", "/").TrimStart("/")

    return $Normalized
}

function Get-RelativePackPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    $PackFull = [System.IO.Path]::GetFullPath($Pack)
    $FileFull = [System.IO.Path]::GetFullPath($FullPath)

    if ($FileFull.StartsWith($PackFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $Relative = $FileFull.Substring($PackFull.Length)
        return (Normalize-RelativePath $Relative)
    }

    return (Normalize-RelativePath $FullPath)
}

function Register-FileOwner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Owner
    )

    $RelativePath = Get-RelativePackPath $FilePath

    if ($FileOwners.ContainsKey($RelativePath)) {

        $PreviousOwner = $FileOwners[$RelativePath]

        $DuplicateFiles += [PSCustomObject]@{
            Path          = $RelativePath
            FirstComponent = $PreviousOwner
            SecondComponent = $Owner
        }

        Write-Host ""
        Write-Host "DUPLICATE FILE DETECTED" -ForegroundColor Yellow
        Write-Host "  Path:      $RelativePath" -ForegroundColor Yellow
        Write-Host "  First:     $PreviousOwner" -ForegroundColor Yellow
        Write-Host "  Current:   $Owner" -ForegroundColor Yellow
        Write-Host ""
    }
    else {
        $FileOwners[$RelativePath] = $Owner
    }
}

function Register-ExistingPackFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Owner
    )

    if (-not (Test-Path $SourceDirectory -PathType Container)) {
        return
    }

    $Files = @(
        Get-ChildItem `
            -LiteralPath $SourceDirectory `
            -File `
            -Recurse `
            -Force
    )

    foreach ($File in $Files) {

        $Relative = $File.FullName.Substring(
            $SourceDirectory.Length
        ).TrimStart("\", "/")

        $Target = Join-Path $Pack $Relative

        Register-FileOwner `
            -FilePath $Target `
            -Owner $Owner
    }
}

# ============================================================
# CHECK COMPONENTS
# ============================================================

if (-not (Test-Path $ComponentsFile -PathType Leaf)) {
    throw "components.json was not found: $ComponentsFile"
}

try {

    $ConfigText = Get-Content `
        $ComponentsFile `
        -Raw `
        -ErrorAction Stop

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

# ============================================================
# GITHUB API
# ============================================================

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

# ============================================================
# GET LATEST RELEASE
# ============================================================

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

                throw `
                    "Could not retrieve latest release for '$Repo'. $($_.Exception.Message)"
            }

            Start-Sleep -Seconds (5 * $Attempt)
        }
    }
}

# ============================================================
# FIND ASSET
# ============================================================

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

# ============================================================
# DOWNLOAD ASSET
# ============================================================

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

    if (-not (Test-Path $Destination -PathType Leaf)) {
        throw "Download failed: $Destination"
    }

    $DownloadedFile = Get-Item $Destination

    if ($DownloadedFile.Length -le 0) {
        throw "Downloaded file is empty: $Destination"
    }

    Write-Host "Downloaded: $($DownloadedFile.Length) bytes"
}

# ============================================================
# EXTRACT ZIP
# ============================================================

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

# ============================================================
# COPY FILE
# ============================================================

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

    # --------------------------------------------------------
    # DUPLICATE DETECTION
    # --------------------------------------------------------

    if (Test-Path $Destination -PathType Leaf) {

        Register-FileOwner `
            -FilePath $Destination `
            -Owner $CurrentComponent
    }

    Copy-Item `
        -LiteralPath $Source `
        -Destination $Destination `
        -Force `
        -ErrorAction Stop

    Write-Host "Installed:"
    Write-Host "  $Destination"
}

# ============================================================
# MERGE DIRECTORY CONTENTS
# ============================================================

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

    $Items = @(
        Get-ChildItem `
            -LiteralPath $Source `
            -Force
    )

    foreach ($Item in $Items) {

        $Target = Join-Path `
            $Destination `
            $Item.Name

        if ($Item.PSIsContainer) {

            if (-not (Test-Path $Target -PathType Container)) {

                New-Item `
                    -ItemType Directory `
                    -Path $Target `
                    -Force | Out-Null
            }

            Merge-DirectoryContents `
                -Source $Item.FullName `
                -Destination $Target
        }
        else {

            if (Test-Path $Target -PathType Leaf) {

                Register-FileOwner `
                    -FilePath $Target `
                    -Owner $CurrentComponent
            }
            else {

                $RelativePath = Get-RelativePackPath $Target

                if (-not $FileOwners.ContainsKey($RelativePath)) {
                    $FileOwners[$RelativePath] = $CurrentComponent
                }
            }

            Copy-Item `
                -LiteralPath $Item.FullName `
                -Destination $Target `
                -Force `
                -ErrorAction Stop
        }
    }
}

# ============================================================
# INSTALL HATS BASE
# ============================================================

function Install-HatsBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $ExtractPath = Join-Path `
        $Work `
        "HATS-Base-Extract"

    if (Test-Path $ExtractPath) {

        Remove-Item `
            $ExtractPath `
            -Recurse `
            -Force
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
    # CHECK IF ROOT IS ALREADY SD ROOT
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

    throw `
        "Could not locate the HATS SD contents or SdOut directory."
}

# ============================================================
# NORMALIZE BOOTLOADER
# ============================================================

function Normalize-Bootloader {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Normalizing bootloader structure"
    Write-Host "========================================"

    $Bootloader = Join-Path `
        $Pack `
        "bootloader"

    if (-not (Test-Path $Bootloader -PathType Container)) {

        Write-Host "No bootloader directory found."
        return
    }

    while ($true) {

        $NestedBootloader = Join-Path `
            $Bootloader `
            "bootloader"

        if (-not (Test-Path $NestedBootloader -PathType Container)) {
            break
        }

        Write-Host "Found nested bootloader:"
        Write-Host "  $NestedBootloader"

        $Items = @(
            Get-ChildItem `
                -LiteralPath $NestedBootloader `
                -Force
        )

        foreach ($Item in $Items) {

            $Target = Join-Path `
                $Bootloader `
                $Item.Name

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

                if (Test-Path $Target -PathType Leaf) {

                    Register-FileOwner `
                        -FilePath $Target `
                        -Owner $CurrentComponent
                }

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

# ============================================================
# REMOVE SDOUT DIRECTORIES
# ============================================================

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

# ============================================================
# INSTALL CUSTOM HEKATE RESOURCES
# ============================================================

function Install-CustomHekateResources {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Installing custom Hekate resources"
    Write-Host "========================================"

    $Source = Join-Path `
        $Root `
        "assets\bootloader\res"

    $Destination = Join-Path `
        $Pack `
        "bootloader\res"

    if (-not (Test-Path $Source -PathType Container)) {
        throw "Custom Hekate resource directory not found: $Source"
    }

    New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    # --------------------------------------------------------
    # CUSTOM ICONS
    # --------------------------------------------------------

    $RequiredIcons = @(
        "emummc.bmp",
        "ofw.bmp"
    )

    foreach ($IconName in $RequiredIcons) {

        $IconSource = Join-Path `
            $Source `
            $IconName

        $IconDestination = Join-Path `
            $Destination `
            $IconName

        if (-not (Test-Path $IconSource -PathType Leaf)) {
            throw "Required custom Hekate icon not found: $IconSource"
        }

        $IconFile = Get-Item $IconSource

        if ($IconFile.Length -le 0) {
            throw "Custom Hekate icon is empty: $IconSource"
        }

        if (Test-Path $IconDestination -PathType Leaf) {

            Register-FileOwner `
                -FilePath $IconDestination `
                -Owner "Custom Hekate Resources"
        }
        else {

            $Relative = Get-RelativePackPath $IconDestination
            $FileOwners[$Relative] = "Custom Hekate Resources"
        }

        Copy-Item `
            -LiteralPath $IconSource `
            -Destination $IconDestination `
            -Force `
            -ErrorAction Stop

        Write-Host "Installed: bootloader\res\$IconName"
    }

    # --------------------------------------------------------
    # BACKGROUND
    # --------------------------------------------------------

    $BackgroundSource = Join-Path `
        $Source `
        "background.bmp"

    $BackgroundDestination = Join-Path `
        $Destination `
        "background.bmp"

    if (Test-Path $BackgroundSource -PathType Leaf) {

        $BackgroundFile = Get-Item $BackgroundSource

        if ($BackgroundFile.Length -le 0) {
            throw "Custom Hekate background is empty."
        }

        if (Test-Path $BackgroundDestination -PathType Leaf) {

            Register-FileOwner `
                -FilePath $BackgroundDestination `
                -Owner "Custom Hekate Resources"
        }
        else {

            $Relative = Get-RelativePackPath $BackgroundDestination
            $FileOwners[$Relative] = "Custom Hekate Resources"
        }

        Copy-Item `
            -LiteralPath $BackgroundSource `
            -Destination $BackgroundDestination `
            -Force `
            -ErrorAction Stop

        Write-Host "Installed: bootloader\res\background.bmp"
    }
    else {

        Write-Host "No custom background found in assets."
        Write-Host "Keeping the HATS/Hekate background."
    }
}

# ============================================================
# INSTALL CLEAN HEKATE CONFIG
# ============================================================

function Install-CleanHekateConfig {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Installing clean Hekate configuration"
    Write-Host "========================================"

    $Bootloader = Join-Path `
        $Pack `
        "bootloader"

    $ConfigPath = Join-Path `
        $Bootloader `
        "hekate_ipl.ini"

    New-Item `
        -ItemType Directory `
        -Path $Bootloader `
        -Force | Out-Null

    # --------------------------------------------------------
    # REMOVE EXTRA INI DIRECTORY
    # --------------------------------------------------------

    $IniDirectory = Join-Path `
        $Bootloader `
        "ini"

    if (Test-Path $IniDirectory -PathType Container) {

        Write-Host "Removing extra Hekate configuration files:"
        Write-Host "  $IniDirectory"

        Remove-Item `
            -LiteralPath $IniDirectory `
            -Recurse `
            -Force
    }

    # --------------------------------------------------------
    # CLEAN HEKATE CONFIG
    # --------------------------------------------------------

    $HekateConfig = @'
[config]
autoboot=0
autoboot_list=0
bootwait=3
noticker=0
backlight=100
autohosoff=1
autonogc=1
updater2p=1
bootprotect=0

[100% STOCK OFW]
fss0=atmosphere/package3
stock=1
emummc_force_disable=1
icon=bootloader/res/ofw.bmp

[CFW (EMUMMC)]
fss0=atmosphere/package3
emummcforce=1
icon=bootloader/res/emummc.bmp
'@

    if (Test-Path $ConfigPath -PathType Leaf) {

        Register-FileOwner `
            -FilePath $ConfigPath `
            -Owner "Custom Hekate Configuration"
    }
    else {

        $Relative = Get-RelativePackPath $ConfigPath
        $FileOwners[$Relative] = "Custom Hekate Configuration"
    }

    Set-Content `
        -LiteralPath $ConfigPath `
        -Value $HekateConfig `
        -Encoding ASCII `
        -Force

    Write-Host ""
    Write-Host "Installed clean Hekate configuration:"
    Write-Host "  100% STOCK OFW"
    Write-Host "  CFW (EMUMMC)"
}

# ============================================================
# REMOVE DUPLICATE APPLICATION NROS
# ============================================================

function Remove-DuplicateApplicationNros {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Cleaning duplicate application NRO files"
    Write-Host "========================================"

    $SwitchPath = Join-Path `
        $Pack `
        "switch"

    if (-not (Test-Path $SwitchPath -PathType Container)) {

        Write-Host "switch directory not found."
        return
    }

    # These are known duplicate root-level files
    # that commonly appear alongside their application
    # folders in HATS-based packs.

    $DuplicateRootNros = @(
        "90DNSTester.nro",
        "Goldleaf.nro",
        "JKSV.nro",
        "NXThemesInstaller.nro"
    )

    foreach ($NroName in $DuplicateRootNros) {

        $NroPath = Join-Path `
            $SwitchPath `
            $NroName

        if (Test-Path $NroPath -PathType Leaf) {

            Write-Host "Removing duplicate:"
            Write-Host "  switch\$NroName"

            Remove-Item `
                -LiteralPath $NroPath `
                -Force
        }
        else {

            Write-Host "Not present:"
            Write-Host "  switch\$NroName"
        }
    }

    Write-Host ""
    Write-Host "Duplicate application NRO cleanup complete."
}

# ============================================================
# REMOVE DUPLICATE OVERLAYS
# ============================================================

function Remove-DuplicateOverlays {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Cleaning duplicate overlays"
    Write-Host "========================================"

    $OverlayPath = Join-Path `
        $Pack `
        "switch\.overlays"

    if (-not (Test-Path $OverlayPath -PathType Container)) {

        Write-Host "switch\.overlays directory not found."
        return
    }

    $DuplicateOverlays = @(
        "ovlEdiZon.ovl"
    )

    foreach ($OverlayName in $DuplicateOverlays) {

        $OverlayFile = Join-Path `
            $OverlayPath `
            $OverlayName

        if (Test-Path $OverlayFile -PathType Leaf) {

            Write-Host "Removing duplicate overlay:"
            Write-Host "  switch\.overlays\$OverlayName"

            Remove-Item `
                -LiteralPath $OverlayFile `
                -Force
        }
    }

    Write-Host "Duplicate overlay cleanup complete."
}

# ============================================================
# REMOVE EMPTY DIRECTORIES
# ============================================================

function Remove-EmptyDirectories {

    Write-Host ""
    Write-Host "Removing empty directories..."

    $Changed = $true

    while ($Changed) {

        $Changed = $false

        $Directories = @(
            Get-ChildItem `
                -Path $Pack `
                -Directory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending
        )

        foreach ($Directory in $Directories) {

            $Items = @(
                Get-ChildItem `
                    -LiteralPath $Directory.FullName `
                    -Force `
                    -ErrorAction SilentlyContinue
            )

            if ($Items.Count -eq 0) {

                Remove-Item `
                    -LiteralPath $Directory.FullName `
                    -Force

                $Changed = $true
            }
        }
    }

    Write-Host "Empty directory cleanup complete."
}

# ============================================================
# VERIFY BOOTLOADER
# ============================================================

function Verify-Bootloader {

    $NestedBootloader = Join-Path `
        $Pack `
        "bootloader\bootloader"

    if (Test-Path $NestedBootloader -PathType Container) {

        throw `
            "Nested bootloader directory still exists: $NestedBootloader"
    }

    Write-Host "OK: No nested bootloader directory found."
}

# ============================================================
# WRITE DUPLICATE REPORT
# ============================================================

function Write-DuplicateReport {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "DUPLICATE FILE REPORT"
    Write-Host "========================================"

    if ($DuplicateFiles.Count -eq 0) {

        Write-Host "No duplicate files detected."
        Write-Host ""

        @"
SkipperBNS HATS Pack
Duplicate File Report
=====================

No duplicate files were detected during the build.
"@ | Set-Content `
            -LiteralPath $DuplicateReport `
            -Encoding UTF8

        return
    }

    Write-Host ""
    Write-Host "Duplicate files detected: $($DuplicateFiles.Count)"
    Write-Host ""

    $ReportLines = New-Object System.Collections.Generic.List[string]

    $ReportLines.Add("SkipperBNS HATS Pack")
    $ReportLines.Add("Duplicate File Report")
    $ReportLines.Add("=====================")
    $ReportLines.Add("")
    $ReportLines.Add("Total duplicate files: $($DuplicateFiles.Count)")
    $ReportLines.Add("")

    $Number = 0

    foreach ($Duplicate in $DuplicateFiles) {

        $Number++

        Write-Host "[$Number] $($Duplicate.Path)" `
            -ForegroundColor Yellow

        Write-Host "    First : $($Duplicate.FirstComponent)"
        Write-Host "    Second: $($Duplicate.SecondComponent)"
        Write-Host ""

        $ReportLines.Add("[$Number] $($Duplicate.Path)")
        $ReportLines.Add("    First : $($Duplicate.FirstComponent)")
        $ReportLines.Add("    Second: $($Duplicate.SecondComponent)")
        $ReportLines.Add("")
    }

    $ReportLines | Set-Content `
        -LiteralPath $DuplicateReport `
        -Encoding UTF8

    Write-Host "Duplicate report saved:"
    Write-Host "  $DuplicateReport"
}

# ============================================================
# MAIN BUILD
# ============================================================

$Index = 0
$Total = $Config.components.Count

foreach ($Component in $Config.components) {

    $Index++

    $CurrentComponent = [string]$Component.name

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Component $Index of $Total"
    Write-Host "$CurrentComponent"
    Write-Host "========================================"

    if ([string]::IsNullOrWhiteSpace($Component.mode)) {
        throw "Component '$CurrentComponent' has no mode."
    }

    Write-Host "Mode: $($Component.mode)"

    # ========================================================
    # LOCAL ROOT
    # ========================================================

    if ($Component.mode -eq "local_root") {

        if ([string]::IsNullOrWhiteSpace($Component.source)) {
            throw "Component '$CurrentComponent' has no source."
        }

        if ([string]::IsNullOrWhiteSpace($Component.destination)) {
            throw "Component '$CurrentComponent' has no destination."
        }

        $Source = Join-Path `
            $Root `
            $Component.source

        $Destination = Join-Path `
            $Pack `
            $Component.destination

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

    # ========================================================
    # HATS BASE
    # ========================================================

    if ($Component.mode -eq "hats_base") {

        if ([string]::IsNullOrWhiteSpace($Component.repo)) {
            throw "Component '$CurrentComponent' has no repository."
        }

        if ([string]::IsNullOrWhiteSpace($Component.asset_regex)) {
            throw "Component '$CurrentComponent' has no asset_regex."
        }

        Write-Host "Repository: $($Component.repo)"

        $Release = Get-LatestRelease `
            $Component.repo

        if ($null -eq $Release) {
            throw "No release information returned for $($Component.repo)"
        }

        Write-Host "Release: $($Release.tag_name)"

        $Asset = Find-Asset `
            -Release $Release `
            -Regex $Component.asset_regex

        if ($null -eq $Asset) {

            Write-Host ""
            Write-Host "ERROR: No matching HATS asset found." `
                -ForegroundColor Red

            Write-Host "Required pattern: $($Component.asset_regex)"
            Write-Host ""
            Write-Host "Available assets:"

            foreach ($Available in @($Release.assets)) {
                Write-Host "  $($Available.name)"
            }

            throw `
                "Could not find an asset matching '$($Component.asset_regex)' for $($Component.repo)"
        }

        Write-Host "Asset: $($Asset.name)"

        $DownloadPath = Join-Path `
            $Work `
            $Asset.name

        Download-Asset `
            -Asset $Asset `
            -Destination $DownloadPath

        Install-HatsBase `
            -ZipPath $DownloadPath `
            -Destination $Pack

        continue
    }

    # ========================================================
    # GITHUB COMPONENT
    # ========================================================

    if ([string]::IsNullOrWhiteSpace($Component.repo)) {
        throw "Component '$CurrentComponent' has no repository."
    }

    if ([string]::IsNullOrWhiteSpace($Component.asset_regex)) {
        throw "Component '$CurrentComponent' has no asset_regex."
    }

    Write-Host "Repository: $($Component.repo)"

    $Release = Get-LatestRelease `
        $Component.repo

    if ($null -eq $Release) {
        throw "No release information returned for $($Component.repo)"
    }

    Write-Host "Release: $($Release.tag_name)"

    $Asset = Find-Asset `
        -Release $Release `
        -Regex $Component.asset_regex

    if ($null -eq $Asset) {

        Write-Host ""
        Write-Host "ERROR: No matching asset found." `
            -ForegroundColor Red

        Write-Host "Required pattern: $($Component.asset_regex)"
        Write-Host ""
        Write-Host "Available assets:"

        foreach ($Available in @($Release.assets)) {
            Write-Host "  $($Available.name)"
        }

        throw `
            "Could not find an asset matching '$($Component.asset_regex)' for $($Component.repo)"
    }

    Write-Host "Asset: $($Asset.name)"

    $SafeAssetName = $Asset.name `
        -replace '[\\/:*?"<>|]', '_'

    $DownloadPath = Join-Path `
        $Work `
        "$Index-$SafeAssetName"

    Download-Asset `
        -Asset $Asset `
        -Destination $DownloadPath

    switch ($Component.mode) {

        # ====================================================
        # ZIP
        # ====================================================

        "zip" {

            $ExtractPath = Join-Path `
                $Work `
                "component-$Index"

            if (Test-Path $ExtractPath) {

                Remove-Item `
                    $ExtractPath `
                    -Recurse `
                    -Force
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

        # ====================================================
        # NRO
        # ====================================================

        "nro" {

            if ([string]::IsNullOrWhiteSpace($Component.destination)) {
                throw "Component '$CurrentComponent' has no destination."
            }

            $Destination = Join-Path `
                $Pack `
                $Component.destination

            Install-File `
                -Source $DownloadPath `
                -Destination $Destination

            continue
        }

        # ====================================================
        # OVL
        # ====================================================

        "ovl" {

            if ([string]::IsNullOrWhiteSpace($Component.destination)) {
                throw "Component '$CurrentComponent' has no destination."
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

        # ====================================================
        # FILE
        # ====================================================

        "file" {

            if ([string]::IsNullOrWhiteSpace($Component.destination)) {
                throw "Component '$CurrentComponent' has no destination."
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

            throw `
                "Unknown component mode '$($Component.mode)' for $CurrentComponent"
        }
    }
}

# ============================================================
# FINAL NORMALIZATION
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "FINAL PACK CLEANUP"
Write-Host "========================================"

$CurrentComponent = "Final Cleanup"

Normalize-Bootloader
Remove-SdOutDirectories
Verify-Bootloader

# ============================================================
# CUSTOM HEKATE RESOURCES
# ============================================================

Install-CustomHekateResources
Install-CleanHekateConfig

# ============================================================
# DUPLICATE CLEANUP
# ============================================================

Remove-DuplicateApplicationNros
Remove-DuplicateOverlays
Remove-EmptyDirectories

# ============================================================
# WRITE DUPLICATE REPORT
# ============================================================

Write-DuplicateReport

# ============================================================
# VERIFY CUSTOM HEKATE FILES
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying custom Hekate resources"
Write-Host "========================================"

$BootloaderResPath = Join-Path `
    $Pack `
    "bootloader\res"

$RequiredBootloaderImages = @(
    "emummc.bmp",
    "ofw.bmp"
)

foreach ($ImageName in $RequiredBootloaderImages) {

    $ImagePath = Join-Path `
        $BootloaderResPath `
        $ImageName

    if (-not (Test-Path $ImagePath -PathType Leaf)) {
        throw `
            "Required Hekate image missing: bootloader\res\$ImageName"
    }

    $ImageFile = Get-Item $ImagePath

    if ($ImageFile.Length -le 0) {
        throw "Hekate image is empty: $ImageName"
    }

    Write-Host "OK: bootloader\res\$ImageName"
    Write-Host "Size: $($ImageFile.Length) bytes"
}

# ============================================================
# VERIFY BACKGROUND
# ============================================================

$BackgroundPath = Join-Path `
    $Pack `
    "bootloader\res\background.bmp"

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying Hekate background"
Write-Host "========================================"

if (Test-Path $BackgroundPath -PathType Leaf) {

    $BackgroundFile = Get-Item $BackgroundPath

    if ($BackgroundFile.Length -le 0) {
        throw "Hekate background is empty."
    }

    Write-Host "OK: bootloader\res\background.bmp"
    Write-Host "Size: $($BackgroundFile.Length) bytes"
}
else {

    Write-Host "WARNING: background.bmp was not found."
    Write-Host "The default Hekate background will be used."
}

# ============================================================
# VERIFY HEKATE CONFIGURATION
# ============================================================

$HekateConfigPath = Join-Path `
    $Pack `
    "bootloader\hekate_ipl.ini"

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying Hekate configuration"
Write-Host "========================================"

if (-not (Test-Path $HekateConfigPath -PathType Leaf)) {
    throw "bootloader\hekate_ipl.ini is missing."
}

$HekateConfigFile = Get-Item $HekateConfigPath

if ($HekateConfigFile.Length -le 0) {
    throw "bootloader\hekate_ipl.ini is empty."
}

Write-Host "OK: bootloader\hekate_ipl.ini"

$HekateConfigText = Get-Content `
    -LiteralPath $HekateConfigPath `
    -Raw

if ($HekateConfigText -notmatch 'icon=bootloader/res/ofw\.bmp') {
    throw "OFW icon is not referenced by hekate_ipl.ini."
}

if ($HekateConfigText -notmatch 'icon=bootloader/res/emummc\.bmp') {
    throw "emuMMC icon is not referenced by hekate_ipl.ini."
}

if ($HekateConfigText -notmatch '\[100% STOCK OFW\]') {
    throw "100% STOCK OFW entry is missing from hekate_ipl.ini."
}

if ($HekateConfigText -notmatch '\[CFW \(EMUMMC\)\]') {
    throw "CFW (EMUMMC) entry is missing from hekate_ipl.ini."
}

Write-Host "OK: 100% STOCK OFW entry"
Write-Host "OK: CFW (EMUMMC) entry"
Write-Host "OK: OFW custom icon referenced"
Write-Host "OK: emuMMC custom icon referenced"

# ============================================================
# VERIFY NO EXTRA MAIN CONFIG ENTRIES
# ============================================================

$MainEntries = @(
    [regex]::Matches(
        $HekateConfigText,
        '(?m)^\[([^\]]+)\]\s*$'
    ) |
    ForEach-Object {
        $_.Groups[1].Value
    } |
    Where-Object {
        $_ -ne "config"
    }
)

Write-Host ""
Write-Host "Hekate main entries found: $($MainEntries.Count)"

foreach ($Entry in $MainEntries) {
    Write-Host "  $Entry"
}

if ($MainEntries.Count -ne 2) {
    throw `
        "Hekate configuration contains $($MainEntries.Count) main entries. Expected exactly 2."
}

# ============================================================
# VERIFY REQUIRED LOCAL APPLICATIONS
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying required local applications"
Write-Host "========================================"

$RequiredLocalFiles = @(
    "switch\ftpd.nro",
    "switch\checkpoint.nro"
)

foreach ($RelativePath in $RequiredLocalFiles) {

    $RequiredPath = Join-Path `
        $Pack `
        $RelativePath

    if (-not (Test-Path $RequiredPath -PathType Leaf)) {
        throw `
            "Required file missing from final pack: $RelativePath"
    }

    $RequiredFile = Get-Item $RequiredPath

    if ($RequiredFile.Length -le 0) {
        throw `
            "Required file is empty: $RelativePath"
    }

    Write-Host "OK: $RelativePath"
}

# ============================================================
# VERIFY DUPLICATE ROOT NROS ARE GONE
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying duplicate NRO cleanup"
Write-Host "========================================"

$DuplicateCheckFiles = @(
    "switch\90DNSTester.nro",
    "switch\Goldleaf.nro",
    "switch\JKSV.nro",
    "switch\NXThemesInstaller.nro"
)

foreach ($RelativePath in $DuplicateCheckFiles) {

    $DuplicatePath = Join-Path `
        $Pack `
        $RelativePath

    if (Test-Path $DuplicatePath -PathType Leaf) {

        throw `
            "Duplicate application NRO still exists: $RelativePath"
    }

    Write-Host "OK: removed $RelativePath"
}

# ============================================================
# VERIFY EDIZON DUPLICATE
# ============================================================

$DuplicateEdiZon = Join-Path `
    $Pack `
    "switch\.overlays\ovlEdiZon.ovl"

$KeptEdiZon = Join-Path `
    $Pack `
    "switch\.overlays\EdiZon.ovl"

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying EdiZon overlay cleanup"
Write-Host "========================================"

if (Test-Path $DuplicateEdiZon -PathType Leaf) {
    throw "Duplicate EdiZon overlay still exists."
}

Write-Host "OK: duplicate ovlEdiZon.ovl removed."

if (Test-Path $KeptEdiZon -PathType Leaf) {
    Write-Host "OK: EdiZon.ovl kept."
}
else {
    Write-Host "WARNING: EdiZon.ovl was not found."
}

# ============================================================
# IMPORTANT HATS FILES
# ============================================================

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

    $CheckPath = Join-Path `
        $Pack `
        $RelativePath

    if (Test-Path $CheckPath -PathType Leaf) {
        Write-Host "OK: $RelativePath"
    }
    else {
        Write-Host "WARNING: $RelativePath not found"
    }
}

# ============================================================
# SHOW FINAL HEKATE STRUCTURE
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "Final Hekate structure"
Write-Host "========================================"

$FinalBootloader = Join-Path `
    $Pack `
    "bootloader"

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

# ============================================================
# FINAL PACK COUNT
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "Final pack verification"
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

# ============================================================
# DUPLICATE SUMMARY
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "DUPLICATE SUMMARY"
Write-Host "========================================"

if ($DuplicateFiles.Count -eq 0) {

    Write-Host "SUCCESS: No duplicate files detected." `
        -ForegroundColor Green
}
else {

    Write-Host "WARNING: $($DuplicateFiles.Count) duplicate file(s) detected." `
        -ForegroundColor Yellow

    Write-Host ""
    Write-Host "The later component was allowed to overwrite the earlier file."
    Write-Host "See DUPLICATES.txt for the complete list."
}

# ============================================================
# CREATE FINAL ZIP
# ============================================================

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

if (-not (Test-Path $Output -PathType Leaf)) {
    throw "Final ZIP was not created."
}

$OutputFile = Get-Item $Output

if ($OutputFile.Length -le 0) {
    throw "Final ZIP is empty."
}

# ============================================================
# SUCCESS
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"

Write-Host "Output: $($OutputFile.FullName)"
Write-Host "Size:   $($OutputFile.Length) bytes"
Write-Host ""

Write-Host "Hekate menu:"
Write-Host "  1. 100% STOCK OFW"
Write-Host "  2. CFW (EMUMMC)"
Write-Host ""

Write-Host "Custom icons:"
Write-Host "  emummc.bmp"
Write-Host "  ofw.bmp"
Write-Host ""

Write-Host "Duplicate NRO cleanup:"
Write-Host "  90DNS Tester"
Write-Host "  Goldleaf"
Write-Host "  JKSV"
Write-Host "  NXThemesInstaller"
Write-Host ""

Write-Host "Duplicate overlay cleanup:"
Write-Host "  ovlEdiZon.ovl removed"
Write-Host "  EdiZon.ovl kept"
Write-Host ""

Write-Host "Duplicate report:"
Write-Host "  $DuplicateReport"
Write-Host ""

Write-Host "Build completed successfully."
