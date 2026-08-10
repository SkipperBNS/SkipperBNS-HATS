param(
    [string]$Version = "main"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " SkipperBNS HATS Pack Builder"
Write-Host "=========================================="

$Root = Split-Path -Parent $PSScriptRoot
$Pack = Join-Path $Root "pack"
$Work = Join-Path $Root "work"
$ComponentsFile = Join-Path $Root "components.json"

Write-Host "Root: $Root"
Write-Host "Components: $ComponentsFile"
Write-Host ""

if (-not (Test-Path $ComponentsFile)) {
    throw "components.json was not found: $ComponentsFile"
}

Write-Host "Preparing build directories..."

if (Test-Path $Work) {
    Remove-Item $Work -Recurse -Force
}

if (Test-Path $Pack) {
    Remove-Item $Pack -Recurse -Force
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Pack -Force | Out-Null

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

function Get-GitHubHeaders {

    $Headers = @{
        "User-Agent" = "SkipperBNS-HATS-Builder"
        "Accept" = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $Headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
        Write-Host "GitHub API authentication: GITHUB_TOKEN"
    }
    else {
        Write-Host "GitHub API authentication: anonymous"
    }

    return $Headers
}

function Get-LatestRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    $Url = "https://api.github.com/repos/$Repo/releases/latest"

    Write-Host "Retrieving latest release..."
    Write-Host "URL: $Url"

    try {
        return Invoke-RestMethod `
            -Uri $Url `
            -Method Get `
            -Headers (Get-GitHubHeaders) `
            -ErrorAction Stop
    }
    catch {

        $Message = $_.Exception.Message

        if ($Message -match "403") {
            throw "Could not retrieve latest release for '$Repo'. GitHub API returned 403. Check GITHUB_TOKEN permissions or API rate limits. $Message"
        }

        if ($Message -match "404") {
            throw "GitHub repository or latest release not found: $Repo"
        }

        throw "Could not retrieve latest release for '$Repo'. $Message"
    }
}

function Find-Asset {
    param(
        [Parameter(Mandatory = $true)]
        $Release,

        [Parameter(Mandatory = $true)]
        [string]$Regex
    )

    foreach ($Asset in $Release.assets) {
        if ($Asset.name -match $Regex) {
            return $Asset
        }
    }

    return $null
}

$Index = 0
$Total = $Config.components.Count

foreach ($Component in $Config.components) {

    $Index++

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Component $Index of $Total"
    Write-Host "Name: $($Component.name)"
    Write-Host "Repository: $($Component.repo)"
    Write-Host "Mode: $($Component.mode)"
    Write-Host "=========================================="

    if ([string]::IsNullOrWhiteSpace($Component.repo)) {
        throw "Component '$($Component.name)' has no repository."
    }

    if ([string]::IsNullOrWhiteSpace($Component.asset_regex)) {
        throw "Component '$($Component.name)' has no asset_regex."
    }

    $Release = Get-LatestRelease $Component.repo

    if ($null -eq $Release) {
        throw "No release information returned for '$($Component.repo)'."
    }

    Write-Host "Release: $($Release.tag_name)"
    Write-Host "Release name: $($Release.name)"

    $Asset = Find-Asset `
        -Release $Release `
        -Regex $Component.asset_regex

    if ($null -eq $Asset) {

        Write-Host ""
        Write-Host "ERROR: No matching asset found." -ForegroundColor Red
        Write-Host "Required pattern: $($Component.asset_regex)"

        Write-Host ""
        Write-Host "Available assets:"

        foreach ($Available in $Release.assets) {
            Write-Host "  $($Available.name)"
        }

        throw "Could not find an asset matching '$($Component.asset_regex)' for $($Component.repo)"
    }

    Write-Host "Asset: $($Asset.name)"
    Write-Host "Download URL: $($Asset.browser_download_url)"

    $DownloadPath = Join-Path $Work $Asset.name

    if (Test-Path $DownloadPath) {
        Remove-Item $DownloadPath -Force
    }

    Write-Host ""
    Write-Host "Downloading..."

    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -OutFile $DownloadPath `
        -Headers (Get-GitHubHeaders) `
        -ErrorAction Stop

    if (-not (Test-Path $DownloadPath)) {
        throw "Download failed: $($Asset.name)"
    }

    $DownloadedFile = Get-Item $DownloadPath

    if ($DownloadedFile.Length -le 0) {
        throw "Downloaded file is empty: $($Asset.name)"
    }

    Write-Host "Downloaded: $($DownloadedFile.Length) bytes"

    if ($Component.mode -eq "zip") {

        Write-Host "Extracting ZIP..."

        Expand-Archive `
            -Path $DownloadPath `
            -DestinationPath $Pack `
            -Force

        Write-Host "ZIP extracted successfully."

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

        if (-not (Test-Path $DestinationFolder)) {
            New-Item `
                -ItemType Directory `
                -Path $DestinationFolder `
                -Force | Out-Null
        }

        Copy-Item `
            -LiteralPath $DownloadPath `
            -Destination $Destination `
            -Force

        Write-Host "Installed: $($Component.destination)"

        continue
    }

    throw "Unknown component mode: $($Component.mode)"
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Verifying pack"
Write-Host "=========================================="

if (-not (Test-Path $Pack)) {
    throw "Pack directory was not created: $Pack"
}

$PackFiles = @(Get-ChildItem $Pack -Recurse -File)

if ($PackFiles.Count -eq 0) {
    throw "Pack directory is empty."
}

Write-Host "Pack files: $($PackFiles.Count)"

$Output = Join-Path `
    $Root `
    "SkipperBNS-HATS-$Version.zip"

if (Test-Path $Output) {
    Remove-Item $Output -Force
}

Write-Host ""
Write-Host "Creating final HATS ZIP..."
Write-Host "Output: $Output"

Compress-Archive `
    -Path "$Pack\*" `
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
Write-Host "=========================================="
Write-Host "BUILD SUCCESSFUL"
Write-Host "=========================================="
Write-Host "Output: $Output"
Write-Host "Size: $($OutputFile.Length) bytes"
Write-Host "=========================================="