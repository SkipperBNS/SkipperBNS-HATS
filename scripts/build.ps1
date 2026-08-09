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
        -UseBasicParsing
}

function Get-LatestRelease {
    param([string]$Repo)

    $Url = "https://api.github.com/repos/$Repo/releases/latest"

    Invoke-RestMethod `
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

Write-Host "====================================="
Write-Host " SkipperBNS HATS Builder"
Write-Host "====================================="

$Root = Resolve-Path "$PSScriptRoot\.."

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
    throw "components.json was not found."
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
    Write-Host "-------------------------------------"
    Write-Host "Component: $($Component.name)"
    Write-Host "-------------------------------------"

    $Archive = Join-Path `
        $Work `
        (([guid]::NewGuid()).ToString() + ".zip")

    $Extracted = Join-Path `
        $Work `
        ([guid]::NewGuid()).ToString()

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $Extracted |
        Out-Null

    $Release = Get-LatestRelease `
        -Repo $Component.repo

    Write-Host "Release: $($Release.tag_name)"

    $Asset = Get-ReleaseAsset `
        -Release $Release `
        -Regex $Component.asset_regex

    Write-Host "Asset: $($Asset.name)"

    Download-File `
        -Url $Asset.browser_download_url `
        -Destination $Archive

    Expand-Archive `
        -Path $Archive `
        -DestinationPath $Extracted `
        -Force

    Merge-Folder `
        -Source $Extracted `
        -Destination $Pack

    $Results += [PSCustomObject]@{
        Name = $Component.name
        Version = $Release.tag_name
        Asset = $Asset.name
        Repository = "https://github.com/$($Component.repo)"
    }
}

$BuildInfo = @{
    name = $Config.pack_name
    version = $Version
    generated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    components = $Results
}

$BuildInfo |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath "$Pack\HATS-BUILD.json" `
        -Encoding UTF8

$ZipPath = Join-Path `
    $Dist `
    "$($Config.pack_name)-v$Version.zip"

Compress-Archive `
    -Path "$Pack\*" `
    -DestinationPath $ZipPath `
    -CompressionLevel Optimal

Write-Host ""
Write-Host "====================================="
Write-Host " BUILD COMPLETE"
Write-Host "====================================="
Write-Host ""
Write-Host "Output:"
Write-Host $ZipPath
