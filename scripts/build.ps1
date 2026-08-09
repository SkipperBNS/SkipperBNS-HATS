param(
[string]$Version = "main"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "       SkipperBNS HATS Pack Builder"
Write-Host "========================================"

$Root = Split-Path -Parent $PSScriptRoot
$Pack = Join-Path $Root "pack"
$Work = Join-Path $Root "work"
$ComponentsFile = Join-Path $Root "components.json"

Write-Host ""
Write-Host "Preparing build directories..."

if (Test-Path $Work) {
Remove-Item $Work -Recurse -Force
}

if (Test-Path $Pack) {
Remove-Item $Pack -Recurse -Force
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Pack -Force | Out-Null

if (-not (Test-Path $ComponentsFile)) {
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

$GitHubHeaders = @{
"User-Agent" = "SkipperBNS-HATS-Builder"
"Accept"     = "application/vnd.github+json"
}

function Get-LatestRelease {
param(
[Parameter(Mandatory = $true)]
[string]$Repo
)

```
$Url = "https://api.github.com/repos/$Repo/releases/latest"

$MaxAttempts = 3

for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
    try {
        return Invoke-RestMethod `
            -Uri $Url `
            -Headers $GitHubHeaders `
            -Method Get `
            -TimeoutSec 30 `
            -ErrorAction Stop
    }
    catch {
        if ($Attempt -eq $MaxAttempts) {
            throw "Unable to retrieve latest release for '$Repo'. $($_.Exception.Message)"
        }

        Write-Warning "GitHub API request failed. Retry $Attempt/$MaxAttempts..."
        Start-Sleep -Seconds (5 * $Attempt)
    }
}
```

}

function Find-Asset {
param(
[Parameter(Mandatory = $true)]
$Release,

```
    [Parameter(Mandatory = $true)]
    [string]$Regex
)

foreach ($Asset in $Release.assets) {
    if ($Asset.name -match $Regex) {
        return $Asset
    }
}

return $null
```

}

function Download-Asset {
param(
[Parameter(Mandatory = $true)]
$Asset,

```
    [Parameter(Mandatory = $true)]
    [string]$Destination
)

$MaxAttempts = 3

for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
    try {
        Write-Host "Downloading: $($Asset.name)"
        Write-Host "Attempt: $Attempt/$MaxAttempts"

        Invoke-WebRequest `
            -Uri $Asset.browser_download_url `
            -OutFile $Destination `
            -Headers @{
                "User-Agent" = "SkipperBNS-HATS-Builder"
            } `
            -TimeoutSec 120 `
            -ErrorAction Stop

        if (-not (Test-Path $Destination)) {
            throw "Downloaded file does not exist."
        }

        $File = Get-Item $Destination

        if ($File.Length -le 0) {
            throw "Downloaded file is empty."
        }

        Write-Host "Download OK: $($File.Length) bytes"

        if ($Asset.digest -and $Asset.digest -match "^sha256:(.+)$") {
            $ExpectedHash = $Matches[1].ToUpperInvariant()

            Write-Host "Verifying SHA256..."

            $ActualHash = (
                Get-FileHash `
                    -Path $Destination `
                    -Algorithm SHA256
            ).Hash.ToUpperInvariant()

            if ($ActualHash -ne $ExpectedHash) {
                throw "SHA256 verification failed for $($Asset.name)."
            }

            Write-Host "SHA256 verification OK"
        }

        return
    }
    catch {
        if ($Attempt -eq $MaxAttempts) {
            throw "Failed to download '$($Asset.name)'. $($_.Exception.Message)"
        }

        Write-Warning "Download failed: $($_.Exception.Message)"
        Start-Sleep -Seconds (5 * $Attempt)
    }
}
```

}

$ComponentNumber = 0
$TotalComponents = $Config.components.Count

foreach ($Component in $Config.components) {

```
$ComponentNumber++

Write-Host ""
Write-Host "========================================"
Write-Host "[$ComponentNumber/$TotalComponents] $($Component.name)"
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
Write-Host "Pattern:    $($Component.asset_regex)"

$Release = Get-LatestRelease $Component.repo

Write-Host "Release:    $($Release.tag_name)"

if ($Release.draft) {
    throw "Latest release for '$($Component.repo)' is a draft."
}

if ($Release.prerelease) {
    Write-Warning "Latest release is marked as a prerelease."
}

if ($null -eq $Release.assets -or $Release.assets.Count -eq 0) {
    throw "Release '$($Release.tag_name)' has no downloadable assets."
}

$Asset = Find-Asset `
    -Release $Release `
    -Regex $Component.asset_regex

if ($null -eq $Asset) {
    Write-Host ""
    Write-Host "ERROR: No matching asset found." -ForegroundColor Red

    Write-Host ""
    Write-Host "Required pattern:"
    Write-Host "  $($Component.asset_regex)"

    Write-Host ""
    Write-Host "Available assets:"

    foreach ($Available in $Release.assets) {
        Write-Host "  $($Available.name)"
    }

    throw "Could not find an asset matching '$($Component.asset_regex)' in $($Component.repo) release $($Release.tag_name)."
}

Write-Host "Asset:      $($Asset.name)"

$DownloadPath = Join-Path $Work $Asset.name

Download-Asset `
    -Asset $Asset `
    -Destination $DownloadPath

if ($Component.mode -eq "zip") {

    if ([System.IO.Path]::GetExtension($DownloadPath).ToLowerInvariant() -ne ".zip") {
        throw "Component '$($Component.name)' is configured as ZIP but downloaded '$($Asset.name)'."
    }

    Write-Host "Extracting ZIP..."

    Expand-Archive `
        -Path $DownloadPath `
        -DestinationPath $Pack `
        -Force

    Write-Host "Extraction OK"

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

    if ([string]::IsNullOrWhiteSpace($DestinationFolder)) {
        throw "Invalid destination for '$($Component.name)'."
    }

    New-Item `
        -ItemType Directory `
        -Path $DestinationFolder `
        -Force | Out-Null

    Copy-Item `
        -LiteralPath $DownloadPath `
        -Destination $Destination `
        -Force

    if (-not (Test-Path $Destination)) {
        throw "Failed to install '$($Component.name)' to '$($Component.destination)'."
    }

    $InstalledFile = Get-Item $Destination

    if ($InstalledFile.Length -le 0) {
        throw "Installed file '$($Component.destination)' is empty."
    }

    Write-Host "Installed: $($Component.destination)"
    Write-Host "Size:      $($InstalledFile.Length) bytes"

    continue
}

throw "Unknown component mode: '$($Component.mode)'"
```

}

Write-Host ""
Write-Host "========================================"
Write-Host "Verifying pack contents"
Write-Host "========================================"

$PackFiles = @(
Get-ChildItem `        $Pack`
-File `
-Recurse
)

if ($PackFiles.Count -eq 0) {
throw "Pack directory is empty."
}

Write-Host "Files in pack: $($PackFiles.Count)"

$Output = Join-Path `    $Root`
"SkipperBNS-HATS-$Version.zip"

if (Test-Path $Output) {
Remove-Item $Output -Force
}

Write-Host ""
Write-Host "Creating final HATS ZIP..."

Compress-Archive `    -Path "$Pack\*"`
-DestinationPath $Output `
-Force

if (-not (Test-Path $Output)) {
throw "Final ZIP was not created: $Output"
}

$OutputFile = Get-Item $Output

if ($OutputFile.Length -le 0) {
throw "Final ZIP is empty."
}

Write-Host ""
Write-Host "========================================"
Write-Host "BUILD SUCCESSFUL"
Write-Host "========================================"
Write-Host "Version: $Version"
Write-Host "Output:  $($OutputFile.FullName)"
Write-Host "Size:    $($OutputFile.Length) bytes"
Write-Host "========================================"
