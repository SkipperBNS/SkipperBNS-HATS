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

# ------------------------------------------------------------
# CLEAN BUILD
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
# LOAD COMPONENTS
# ------------------------------------------------------------

if (-not (Test-Path $ComponentsFile -PathType Leaf)) {
    throw "components.json was not found: $ComponentsFile"
}

try {
    $Config = Get-Content $ComponentsFile -Raw | ConvertFrom-Json
}
catch {
    throw "Could not parse components.json. $($_.Exception.Message)"
}

if ($null -eq $Config.components) {
    throw "components.json does not contain a components array."
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
        [Parameter(Mandatory)]
        [string]$Repo
    )

    $Url = "https://api.github.com/repos/$Repo/releases/latest"

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
        [Parameter(Mandatory)]
        [object]$Release,

        [Parameter(Mandatory)]
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
        [Parameter(Mandatory)]
        [object]$Asset,

        [Parameter(Mandatory)]
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

    $File = Get-Item $Destination

    if ($File.Length -le 0) {
        throw "Downloaded file is empty: $Destination"
    }

    Write-Host "Downloaded: $($File.Length) bytes"
}

# ------------------------------------------------------------
# EXTRACT ZIP
# ------------------------------------------------------------

function Install-Zip {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [string]$Destination
    )

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
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $Folder = Split-Path $Destination -Parent

    if (-not [string]::IsNullOrWhiteSpace($Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }

    Copy-Item `
        -LiteralPath $Source `
        -Destination $Destination `
        -Force `
        -ErrorAction Stop

    Write-Host "Installed: $Destination"
}

# ------------------------------------------------------------
# MERGE DIRECTORIES
# ------------------------------------------------------------

function Merge-DirectoryContents {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (-not (Test-Path $Source -PathType Container)) {
        throw "Source directory does not exist: $Source"
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    foreach ($Item in @(Get-ChildItem -LiteralPath $Source -Force)) {

        $Target = Join-Path $Destination $Item.Name

        if ($Item.PSIsContainer) {

            if (-not (Test-Path $Target)) {
                New-Item -ItemType Directory -Path $Target -Force | Out-Null
            }

            Merge-DirectoryContents `
                -Source $Item.FullName `
                -Destination $Target
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
        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $ExtractPath = Join-Path $Work "HATS-Base"

    if (Test-Path $ExtractPath) {
        Remove-Item $ExtractPath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null

    Install-Zip `
        -ZipPath $ZipPath `
        -Destination $ExtractPath

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
        Write-Host $SdOut.FullName

        Merge-DirectoryContents `
            -Source $SdOut.FullName `
            -Destination $Destination

        return
    }

    $RootEntries = @(Get-ChildItem -LiteralPath $ExtractPath -Force)

    $LooksLikeSdRoot = $false

    foreach ($Entry in $RootEntries) {

        if (
            $Entry.Name -ieq "atmosphere" -or
            $Entry.Name -ieq "bootloader" -or
            $Entry.Name -ieq "switch" -or
            $Entry.Name -ieq "boot.dat" -or
            $Entry.Name -ieq "payload.bin" -or
            $Entry.Name -ieq "exosphere.ini"
        ) {
            $LooksLikeSdRoot = $true
            break
        }
    }

    if ($LooksLikeSdRoot) {

        Merge-DirectoryContents `
            -Source $ExtractPath `
            -Destination $Destination

        return
    }

    throw "Could not locate HATS SD contents or SdOut."
}

# ------------------------------------------------------------
# NORMALIZE BOOTLOADER
# ------------------------------------------------------------

function Normalize-Bootloader {

    $Bootloader = Join-Path $Pack "bootloader"

    if (-not (Test-Path $Bootloader -PathType Container)) {
        return
    }

    while ($true) {

        $Nested = Join-Path $Bootloader "bootloader"

        if (-not (Test-Path $Nested -PathType Container)) {
            break
        }

        foreach ($Item in @(Get-ChildItem -LiteralPath $Nested -Force)) {

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
                        -Force
                }
            }
            else {

                Copy-Item `
                    -LiteralPath $Item.FullName `
                    -Destination $Target `
                    -Force

                Remove-Item `
                    -LiteralPath $Item.FullName `
                    -Force
            }
        }

        Remove-Item `
            -LiteralPath $Nested `
            -Recurse `
            -Force
    }
}

# ------------------------------------------------------------
# REMOVE SDOUT
# ------------------------------------------------------------

function Remove-SdOutDirectories {

    $Directories = @(
        Get-ChildItem `
            -Path $Pack `
            -Directory `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "SdOut"
        }
    )

    foreach ($Directory in $Directories) {

        Remove-Item `
            -LiteralPath $Directory.FullName `
            -Recurse `
            -Force
    }
}

# ------------------------------------------------------------
# CLEAN DUPLICATE HOMEBREW NRO
# ------------------------------------------------------------

function Clean-DuplicateHomebrewApps {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Cleaning duplicate Homebrew NRO files"
    Write-Host "========================================"

    $SwitchPath = Join-Path $Pack "switch"

    if (-not (Test-Path $SwitchPath -PathType Container)) {
        Write-Host "No switch folder found."
        return
    }

    # These four applications have one canonical NRO.
    $Canonical = @{
        "90DNS" = "90DNSTester.nro"
        "Goldleaf" = "Goldleaf.nro"
        "JKSV" = "JKSV.nro"
        "NXThemesInstaller" = "NXThemesInstaller.nro"
    }

    $Patterns = @{
        "90DNS" = "*90DNS*.nro"
        "Goldleaf" = "*Goldleaf*.nro"
        "JKSV" = "*JKSV*.nro"
        "NXThemesInstaller" = "*NXThemes*.nro"
    }

    foreach ($Name in $Patterns.Keys) {

        $CanonicalName = $Canonical[$Name]
        $CanonicalPath = Join-Path $SwitchPath $CanonicalName

        Write-Host ""
        Write-Host "Checking $Name..."

        $Files = @(
            Get-ChildItem `
                -Path $SwitchPath `
                -Recurse `
                -File `
                -Filter "*.nro" `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like $Patterns[$Name]
            }
        )

        if (Test-Path $CanonicalPath -PathType Leaf) {

            foreach ($File in $Files) {

                if ($File.FullName -ieq $CanonicalPath) {
                    Write-Host "KEEP: $CanonicalName"
                }
                else {

                    Write-Host "REMOVE DUPLICATE: $($File.FullName)"

                    Remove-Item `
                        -LiteralPath $File.FullName `
                        -Force
                }
            }
        }
        elseif ($Files.Count -gt 0) {

            $Candidate = $Files |
                Where-Object {
                    $_.Directory.FullName -ieq $SwitchPath
                } |
                Select-Object -First 1

            if ($null -eq $Candidate) {
                $Candidate = $Files | Select-Object -First 1
            }

            Write-Host "Creating canonical file: $CanonicalName"

            if ($Candidate.Name -ne $CanonicalName) {

                Rename-Item `
                    -LiteralPath $Candidate.FullName `
                    -NewName $CanonicalName `
                    -Force
            }

            $CanonicalPath = Join-Path $SwitchPath $CanonicalName

            foreach ($File in @(
                Get-ChildItem `
                    -Path $SwitchPath `
                    -Recurse `
                    -File `
                    -Filter "*.nro" `
                    -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -like $Patterns[$Name]
                }
            )) {

                if ($File.FullName -ine $CanonicalPath) {

                    Write-Host "REMOVE DUPLICATE: $($File.FullName)"

                    Remove-Item `
                        -LiteralPath $File.FullName `
                        -Force
                }
            }
        }
    }

    # --------------------------------------------------------
    # EdiZon / Ultrahand / nx-ovlloader
    # --------------------------------------------------------
    # Only remove NRO files.
    # Do NOT touch .ovl files or Atmosphere/system files.
    # --------------------------------------------------------

    $ExtraNroPatterns = @(
        "*EdiZon*.nro",
        "*Ultrahand*.nro",
        "*nx-ovlloader*.nro"
    )

    foreach ($Pattern in $ExtraNroPatterns) {

        $Files = @(
            Get-ChildItem `
                -Path $SwitchPath `
                -Recurse `
                -File `
                -Filter "*.nro" `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like $Pattern
            }
        )

        foreach ($File in $Files) {

            Write-Host "REMOVE EXTRA NRO: $($File.FullName)"

            Remove-Item `
                -LiteralPath $File.FullName `
                -Force
        }
    }

    # --------------------------------------------------------
    # REMOVE EMPTY DIRECTORIES
    # --------------------------------------------------------

    $EmptyDirectories = @(
        Get-ChildItem `
            -Path $SwitchPath `
            -Directory `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Where-Object {
            @(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0
        }
    )

    foreach ($Directory in $EmptyDirectories) {

        Remove-Item `
            -LiteralPath $Directory.FullName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Duplicate NRO cleanup completed."
}

# ------------------------------------------------------------
# CUSTOM BOOTLOADER RESOURCES
# ------------------------------------------------------------

function Install-CustomBootloaderResources {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Installing custom Hekate resources"
    Write-Host "========================================"

    $Source = Join-Path $Root "assets\bootloader\res"
    $Destination = Join-Path $Pack "bootloader\res"

    if (-not (Test-Path $Source -PathType Container)) {
        throw "Custom bootloader resource folder not found: $Source"
    }

    New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    $Images = @(
        "background.bmp",
        "emummc.bmp",
        "ofw.bmp"
    )

    foreach ($Image in $Images) {

        $SourceFile = Join-Path $Source $Image
        $DestinationFile = Join-Path $Destination $Image

        if (-not (Test-Path $SourceFile -PathType Leaf)) {
            throw "Required custom bootloader image not found: $SourceFile"
        }

        $File = Get-Item $SourceFile

        if ($File.Length -le 0) {
            throw "Custom bootloader image is empty: $SourceFile"
        }

        Copy-Item `
            -LiteralPath $SourceFile `
            -Destination $DestinationFile `
            -Force

        Write-Host "OK: bootloader\res\$Image"
    }
}

# ------------------------------------------------------------
# CUSTOM HEKATE CONFIG
# ------------------------------------------------------------

function Install-CustomHekateConfig {

    $Source = Join-Path $Root "assets\bootloader\hekate_ipl.ini"
    $Destination = Join-Path $Pack "bootloader\hekate_ipl.ini"

    if (-not (Test-Path $Source -PathType Leaf)) {
        throw "Custom hekate_ipl.ini not found: $Source"
    }

    $Folder = Split-Path $Destination -Parent

    New-Item `
        -ItemType Directory `
        -Path $Folder `
        -Force | Out-Null

    Copy-Item `
        -LiteralPath $Source `
        -Destination $Destination `
        -Force

    Write-Host "OK: bootloader\hekate_ipl.ini"
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

    # --------------------------------------------------------
    # LOCAL ROOT
    # --------------------------------------------------------

    if ($Component.mode -eq "local_root") {

        $Source = Join-Path $Root $Component.source
        $Destination = Join-Path $Pack $Component.destination

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

        $Release = Get-LatestRelease $Component.repo

        $Asset = Find-Asset `
            -Release $Release `
            -Regex $Component.asset_regex

        if ($null -eq $Asset) {

            Write-Host "Available assets:"

            foreach ($Available in @($Release.assets)) {
                Write-Host "  $($Available.name)"
            }

            throw "Could not find HATS asset matching '$($Component.asset_regex)'"
        }

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

    $Release = Get-LatestRelease $Component.repo

    $Asset = Find-Asset `
        -Release $Release `
        -Regex $Component.asset_regex

    if ($null -eq $Asset) {

        Write-Host "Available assets:"

        foreach ($Available in @($Release.assets)) {
            Write-Host "  $($Available.name)"
        }

        throw "Could not find asset matching '$($Component.asset_regex)'"
    }

    $SafeName = $Asset.name -replace '[\\/:*?"<>|]', '_'
    $DownloadPath = Join-Path $Work "$Index-$SafeName"

    Download-Asset `
        -Asset $Asset `
        -Destination $DownloadPath

    switch ($Component.mode) {

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
        }

        "nro" {

            $Destination = Join-Path `
                $Pack `
                $Component.destination

            Install-File `
                -Source $DownloadPath `
                -Destination $Destination
        }

        "ovl" {

            $Destination = Join-Path `
                $Pack `
                $Component.destination

            Install-File `
                -Source $DownloadPath `
                -Destination $Destination
        }

        "file" {

            $Destination = Join-Path `
                $Pack `
                $Component.destination

            Install-File `
                -Source $DownloadPath `
                -Destination $Destination
        }

        default {
            throw "Unknown component mode '$($Component.mode)'"
        }
    }
}

# ------------------------------------------------------------
# FINAL NORMALIZATION
# ------------------------------------------------------------

Normalize-Bootloader
Remove-SdOutDirectories

$NestedBootloader = Join-Path $Pack "bootloader\bootloader"

if (Test-Path $NestedBootloader -PathType Container) {
    throw "Nested bootloader directory still exists: $NestedBootloader"
}

# ------------------------------------------------------------
# CLEAN DUPLICATE NRO FILES
# ------------------------------------------------------------

Clean-DuplicateHomebrewApps

# ------------------------------------------------------------
# CUSTOM HEKATE FILES
# ------------------------------------------------------------

Install-CustomBootloaderResources
Install-CustomHekateConfig

# ------------------------------------------------------------
# VERIFY LOCAL APPS
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying required applications"
Write-Host "========================================"

$RequiredApps = @(
    "switch\ftpd.nro",
    "switch\checkpoint.nro"
)

foreach ($App in $RequiredApps) {

    $Path = Join-Path $Pack $App

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Required file missing: $App"
    }

    Write-Host "OK: $App"
}

# ------------------------------------------------------------
# VERIFY HEKATE IMAGES
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying Hekate resources"
Write-Host "========================================"

$Images = @(
    "background.bmp",
    "emummc.bmp",
    "ofw.bmp"
)

foreach ($Image in $Images) {

    $Path = Join-Path $Pack "bootloader\res\$Image"

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Required bootloader image missing: $Image"
    }

    $File = Get-Item $Path

    if ($File.Length -le 0) {
        throw "Bootloader image is empty: $Image"
    }

    Write-Host "OK: bootloader\res\$Image"
}

# ------------------------------------------------------------
# VERIFY HEKATE CONFIG
# ------------------------------------------------------------

$HekateConfig = Join-Path $Pack "bootloader\hekate_ipl.ini"

if (-not (Test-Path $HekateConfig -PathType Leaf)) {
    throw "bootloader\hekate_ipl.ini is missing."
}

Write-Host "OK: bootloader\hekate_ipl.ini"

# ------------------------------------------------------------
# SHOW FINAL SWITCH NROS
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host "Final Switch NRO files"
Write-Host "========================================"

$SwitchPath = Join-Path $Pack "switch"

if (Test-Path $SwitchPath -PathType Container) {

    Get-ChildItem `
        -Path $SwitchPath `
        -Recurse `
        -File `
        -Filter "*.nro" |
        ForEach-Object {

            $Relative = $_.FullName.Substring($Pack.Length).TrimStart('\','/')

            Write-Host $Relative
        }
}

# ------------------------------------------------------------
# CREATE ZIP
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

if (-not (Test-Path $Output -PathType Leaf)) {
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
Write-Host "SkipperBNS HATS build completed successfully."
