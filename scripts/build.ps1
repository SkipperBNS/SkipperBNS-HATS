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
    # CHECK ARCHIVE ROOT
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
# VERIFY NO NESTED BOOTLOADER
# ------------------------------------------------------------

function Verify-Bootloader {

    $NestedBootloader = Join-Path $Pack "bootloader\bootloader"

    if (Test-Path $NestedBootloader -PathType Container) {
        throw "Nested bootloader directory still exists: $NestedBootloader"
    }

    Write-Host "OK: No nested bootloader directory found."
}

# ------------------------------------------------------------
# REMOVE DUPLICATE HOMEBREW NRO FILES
# ------------------------------------------------------------

function Clean-DuplicateHomebrewApps {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Cleaning duplicate Homebrew applications"
    Write-Host "========================================"

    $SwitchPath = Join-Path $Pack "switch"

    if (-not (Test-Path $SwitchPath -PathType Container)) {
        Write-Host "No switch directory found."
        return
    }

    # --------------------------------------------------------
    # DESIRED APPLICATIONS
    # --------------------------------------------------------

    $Apps = @(
        @{
            Name = "90DNS"
            Canonical = "90DNSTester.nro"
            Patterns = @(
                "*90DNS*.nro",
                "*90DNS*Tester*.nro"
            )
        },
        @{
            Name = "Goldleaf"
            Canonical = "Goldleaf.nro"
            Patterns = @(
                "*Goldleaf*.nro"
            )
        },
        @{
            Name = "JKSV"
            Canonical = "JKSV.nro"
            Patterns = @(
                "*JKSV*.nro"
            )
        },
        @{
            Name = "NXThemesInstaller"
            Canonical = "NXThemesInstaller.nro"
            Patterns = @(
                "*NXThemes*.nro",
                "*ThemeInjector*.nro",
                "*NXThemesInstaller*.nro"
            )
        }
    )

    foreach ($App in $Apps) {

        Write-Host ""
        Write-Host "Checking $($App.Name)..."

        $CanonicalPath = Join-Path `
            $SwitchPath `
            $App.Canonical

        $AllNros = @(
            Get-ChildItem `
                -Path $SwitchPath `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -ieq ".nro"
            }
        )

        $Matches = @()

        foreach ($File in $AllNros) {

            foreach ($Pattern in $App.Patterns) {

                if ($File.Name -like $Pattern) {
                    $Matches += $File
                    break
                }
            }
        }

        $Matches = @(
            $Matches |
            Sort-Object FullName -Unique
        )

        if (Test-Path $CanonicalPath -PathType Leaf) {

            Write-Host "KEEP: $($App.Canonical)"

            foreach ($File in $Matches) {

                if ($File.FullName -ne $CanonicalPath) {

                    Write-Host "REMOVE: $($File.FullName)"

                    Remove-Item `
                        -LiteralPath $File.FullName `
                        -Force `
                        -ErrorAction Stop
                }
            }

            continue
        }

        if ($Matches.Count -eq 0) {

            Write-Host "No $($App.Name) NRO found."

            continue
        }

        $Preferred = $Matches |
            Where-Object {
                $_.Directory.FullName -ieq $SwitchPath
            } |
            Select-Object -First 1

        if ($null -eq $Preferred) {
            $Preferred = $Matches | Select-Object -First 1
        }

        New-Item `
            -ItemType Directory `
            -Path $SwitchPath `
            -Force | Out-Null

        Copy-Item `
            -LiteralPath $Preferred.FullName `
            -Destination $CanonicalPath `
            -Force `
            -ErrorAction Stop

        Write-Host "KEEP:"
        Write-Host "  $CanonicalPath"

        foreach ($File in $Matches) {

            if ($File.FullName -ne $CanonicalPath) {

                Write-Host "REMOVE:"
                Write-Host "  $($File.FullName)"

                Remove-Item `
                    -LiteralPath $File.FullName `
                    -Force `
                    -ErrorAction Stop
            }
        }
    }

    # --------------------------------------------------------
    # REMOVE UNWANTED DUPLICATE NRO FILES
    # --------------------------------------------------------

    $ExtraPatterns = @(
        "*EdiZon*.nro",
        "*Ultrahand*.nro",
        "*nx-ovlloader*.nro",
        "*ovlSysmodules*.nro"
    )

    foreach ($Pattern in $ExtraPatterns) {

        $Files = @(
            Get-ChildItem `
                -Path $SwitchPath `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -ieq ".nro" -and
                $_.Name -like $Pattern
            }
        )

        foreach ($File in $Files) {

            Write-Host "REMOVE EXTRA NRO:"
            Write-Host "  $($File.FullName)"

            Remove-Item `
                -LiteralPath $File.FullName `
                -Force `
                -ErrorAction Stop
        }
    }

    Write-Host ""
    Write-Host "Duplicate NRO cleanup completed."
}

# ------------------------------------------------------------
# INSTALL CUSTOM HEKATE RESOURCES
# ------------------------------------------------------------

function Install-CustomHekateResources {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Installing custom Hekate resources"
    Write-Host "========================================"

    $Source = Join-Path $Root "assets\bootloader\res"
    $Destination = Join-Path $Pack "bootloader\res"

    if (-not (Test-Path $Source -PathType Container)) {

        Write-Host "Custom Hekate resource folder not found:"
        Write-Host "  $Source"

        return
    }

    New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    $Files = @(
        Get-ChildItem `
            -LiteralPath $Source `
            -File `
            -Force `
            -ErrorAction Stop
    )

    foreach ($File in $Files) {

        $Target = Join-Path `
            $Destination `
            $File.Name

        Copy-Item `
            -LiteralPath $File.FullName `
            -Destination $Target `
            -Force `
            -ErrorAction Stop

        Write-Host "Installed:"
        Write-Host "  bootloader\res\$($File.Name)"
    }

    Write-Host "Custom Hekate resources installed."
}

# ------------------------------------------------------------
# INSTALL CUSTOM HEKATE CONFIGURATION
# ------------------------------------------------------------

function Install-CustomHekateConfig {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Installing custom Hekate configuration"
    Write-Host "========================================"

    $ConfigSource = Join-Path `
        $Root `
        "assets\bootloader\hekate_ipl.ini"

    $ConfigDestination = Join-Path `
        $Pack `
        "bootloader\hekate_ipl.ini"

    if (-not (Test-Path $ConfigSource -PathType Leaf)) {

        Write-Host "Custom hekate_ipl.ini not found:"
        Write-Host "  $ConfigSource"

        return
    }

    $BootloaderDirectory = Split-Path `
        $ConfigDestination `
        -Parent

    New-Item `
        -ItemType Directory `
        -Path $BootloaderDirectory `
        -Force | Out-Null

    Copy-Item `
        -LiteralPath $ConfigSource `
        -Destination $ConfigDestination `
        -Force `
        -ErrorAction Stop

    Write-Host "Installed:"
    Write-Host "  bootloader\hekate_ipl.ini"
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

    $DownloadPath = Join-Path `
        $Work `
        "$Index-$SafeAssetName"

    Download-Asset `
        -Asset $Asset `
        -Destination $DownloadPath

    switch ($Component.mode) {

        # ----------------------------------------------------
        # ZIP
        # ----------------------------------------------------

        "zip" {

            $ExtractPath = Join-Path `
                $Work `
                "component-$Index"

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
# FINAL NORMALIZATION
# ------------------------------------------------------------

Normalize-Bootloader
Remove-SdOutDirectories
Verify-Bootloader

# ------------------------------------------------------------
# CLEAN DUPLICATE NRO FILES
# ------------------------------------------------------------

Clean-DuplicateHomebrewApps

# ------------------------------------------------------------
# INSTALL CUSTOM HEKATE RESOURCES
# ------------------------------------------------------------

Install-CustomHekateResources
Install-CustomHekateConfig

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

    $RequiredPath = Join-Path `
        $Pack `
        $RelativePath

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
# VERIFY HEKATE RESOURCES
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying Hekate resources"
Write-Host "========================================"

$BootloaderResPath = Join-Path `
    $Pack `
    "bootloader\res"

if (Test-Path $BootloaderResPath -PathType Container) {

    $BmpFiles = @(
        Get-ChildItem `
            -LiteralPath $BootloaderResPath `
            -Filter "*.bmp" `
            -File `
            -ErrorAction SilentlyContinue
    )

    foreach ($Bmp in $BmpFiles) {

        if ($Bmp.Length -le 0) {
            throw "Hekate BMP is empty: $($Bmp.Name)"
        }

        Write-Host "OK: bootloader\res\$($Bmp.Name)"
        Write-Host "Size: $($Bmp.Length) bytes"
    }

    if ($BmpFiles.Count -eq 0) {
        Write-Host "WARNING: No BMP files found in bootloader\res"
    }
}
else {
    Write-Host "WARNING: bootloader\res does not exist."
}

# ------------------------------------------------------------
# VERIFY HEKATE CONFIGURATION
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying Hekate configuration"
Write-Host "========================================"

$HekateConfigPath = Join-Path `
    $Pack `
    "bootloader\hekate_ipl.ini"

if (Test-Path $HekateConfigPath -PathType Leaf) {

    $HekateConfigFile = Get-Item $HekateConfigPath

    if ($HekateConfigFile.Length -le 0) {
        throw "hekate_ipl.ini is empty."
    }

    Write-Host "OK: bootloader\hekate_ipl.ini"
}
else {

    Write-Host "WARNING: Custom hekate_ipl.ini not found."
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

    $CheckPath = Join-Path `
        $Pack `
        $RelativePath

    if (Test-Path $CheckPath) {
        Write-Host "OK: $RelativePath"
    }
    else {
        Write-Host "WARNING: $RelativePath not found"
    }
}

# ------------------------------------------------------------
# SHOW FINAL NRO FILES
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "FINAL NRO FILES"
Write-Host "========================================"

$SwitchPath = Join-Path `
    $Pack `
    "switch"

if (Test-Path $SwitchPath -PathType Container) {

    $FinalNros = @(
        Get-ChildItem `
            -Path $SwitchPath `
            -Recurse `
            -File `
            -Filter "*.nro" `
            -ErrorAction SilentlyContinue
    )

    foreach ($Nro in $FinalNros) {

        $Relative = $Nro.FullName.Substring(
            $Pack.Length + 1
        )

        Write-Host "  $Relative"
    }

    Write-Host ""
    Write-Host "Total NRO files: $($FinalNros.Count)"
}

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
# SHOW FINAL BOOTLOADER STRUCTURE
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Final bootloader structure"
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

Write-Host "Build completed successfully."
