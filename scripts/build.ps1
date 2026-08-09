param(
    [string]$Version = "",
    [string]$Manifest = "$PSScriptRoot\..\config\components.json"
)

$ErrorActionPreference = "Stop"

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    Write-Host "Downloading: $Url"

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Destination `
        -Headers @{
            "User-Agent" = "SkipperBNS-HATS-Builder"
        }
}

function Get-LatestRelease {
    param(
        [string]$Repo
    )

    $Url = "https://api.github.com/repos/$Repo/releases/latest"

    Write-Host "Checking latest release: $Repo"

    return Invoke-RestMethod `
        -Uri $Url `
        -Headers @{
            "Accept" = "application/vnd.github+json"
            "User-Agent" = "SkipperBNS-HATS-Builder"
        }
}

function Get-ReleaseAsset {
    param(
        $Release,
        [string]$Regex
    )

    $Asset = @(
        $Release.assets |
        Where-Object {
            $_.name -match $Regex
        }
    ) | Select-Object -First 1

    if ($null -eq $Asset) {
        Write-Host ""
        Write-Host "Available assets:" -ForegroundColor Yellow

        foreach ($Available in $Release.assets) {
            Write-Host " - $($Available.name)"
        }

        throw "Could not find an asset matching: $Regex"
    }

    return $Asset
}

function Merge-Folder {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $Destination |
        Out-Null

    Get-ChildItem `
        -LiteralPath $Source `
        -Force |
        ForEach-Object {

            $Target = Join-Path `
                $Destination `
                $_.Name

            if ($_.PSIsContainer) {

                Merge-Folder `
                    -Source $_.FullName `
                    -Destination $Target

            } else {

                Copy-Item `
                    -LiteralPath $_.FullName `
                    -Destination $Target `
                    -Force
            }
        }
}

Write-Host "=========================================="
Write-Host "       SkipperBNS HATS Pack Builder"
Write-Host "=========================================="

$Root = (Resolve-Path "$PSScriptRoot\..").Path

$Work = Join-Path $Root "work"
$Pack = Join-Path $Root "pack"
$Dist = Join-Path $Root "dist"

Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $Pack -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $Dist -Recurse -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force -Path $Work | Out-Null
New-Item -ItemType Directory -Force -Path $Pack | Out-Null
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

if (!(Test-Path $Manifest)) {
    throw "components.json was not found: $Manifest"
}

$Config = Get-Content `
    -LiteralPath $Manifest `
    -Raw |
    ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $Config.version
}

$Results = @()

foreach ($Component in $Config.components) {

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Component: $($Component.name)"
    Write-Host "Repository: $($Component.repo)"
    Write-Host "=========================================="

    $Release = Get-LatestRelease `
        -Repo $Component.repo

    Write-Host "Release: $($Release.tag_name)"

    $Asset = Get-ReleaseAsset `
        -Release $Release `
        -Regex $Component.asset_regex

    Write-Host "Asset: $($Asset.name)"

    $SafeName = [IO.Path]::GetFileName($Asset.name)

    $DownloadPath = Join-Path `
        $Work `
        $SafeName

    Download-File `
        -Url $Asset.browser_download_url `
        -Destination $DownloadPath

    #
    # Individual NRO/application file
    #
    if ($Component.mode -eq "nro") {

        if ([string]::IsNullOrWhiteSpace($Component.destination)) {
            throw "Component '$($Component.name)' uses mode 'nro' but has no destination."
        }

        $Destination = Join-Path `
            $Pack `
            $Component.destination

        $DestinationFolder = Split-Path `
            $Destination `
            -Parent

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $DestinationFolder |
            Out-Null

        Copy-Item `
            -LiteralPath $DownloadPath `
            -Destination $Destination `
            -Force

        Write-Host "Installed: $Destination"
    }

    #
    # ZIP archive
    #
    elseif ($Asset.name -match "\.zip$") {

        $Extracted = Join-Path `
            $Work `
            ([guid]::NewGuid().ToString())

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $Extracted |
            Out-Null

        Write-Host "Extracting: $($Asset.name)"

        Expand-Archive `
            -Path $DownloadPath `
            -DestinationPath $Extracted `
            -Force

        Merge-Folder `
            -Source $Extracted `
            -Destination $Pack

        Write-Host "Installed ZIP component."
    }

    else {

        throw "Unsupported asset type: $($Asset.name)"
    }

    $Results += [PSCustomObject]@{
        Name       = $Component.name
        Version    = $Release.tag_name
        Asset      = $Asset.name
        Repository = "https://github.com/$($Component.repo)"
    }
}

#
# Create build information
#

$BuildInfo = [ordered]@{
    name       = $Config.pack_name
    version    = $Version
    generated  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    components = $Results
}

$BuildInfo |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath "$Pack\HATS-BUILD.json" `
        -Encoding UTF8

#
# Create ZIP
#

$ZipName = "$($Config.pack_name)-v$Version.zip"

$ZipPath = Join-Path `
    $Dist `
    $ZipName

Write-Host ""
Write-Host "Creating pack:"
Write-Host $ZipPath

Compress-Archive `
    -Path "$Pack\*" `
    -DestinationPath $ZipPath `
    -CompressionLevel Optimal

Write-Host ""
Write-Host "=========================================="
Write-Host "          BUILD COMPLETE"
Write-Host "=========================================="
Write-Host ""
Write-Host "Pack:"
Write-Host $ZipPath
Write-Host ""
Write-Host "Components built: $($Results.Count)"
Write-Host ""
