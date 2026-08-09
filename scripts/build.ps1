name: Build HATS Pack

on:
  workflow_dispatch:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  build:
    name: Build HATS Pack
    runs-on: windows-latest

    steps:

      # ========================================
      # CHECKOUT
      # ========================================

      - name: Checkout
        uses: actions/checkout@v4

      # ========================================
      # BUILD HATS PACK
      # ========================================

      - name: Build HATS pack
        shell: pwsh
        run: |
          $ErrorActionPreference = "Stop"

          Write-Host "=========================================="
          Write-Host " SkipperBNS HATS Pack Builder"
          Write-Host "=========================================="

          # Determine version
          $version = "${{ github.ref_name }}"

          if ($version.StartsWith("v")) {
            $version = $version.Substring(1)
          }

          if ([string]::IsNullOrWhiteSpace($version)) {
            $version = "main"
          }

          Write-Host "Version: $version"
          Write-Host ""

          # ========================================
          # VERIFY REQUIRED FILES
          # ========================================

          if (-not (Test-Path ".\scripts\build.ps1")) {
            throw "ERROR: scripts\build.ps1 was not found."
          }

          if (-not (Test-Path ".\components.json")) {
            throw "ERROR: components.json was not found."
          }

          # ========================================
          # CLEAN DIST
          # ========================================

          if (Test-Path ".\dist") {
            Write-Host "Removing previous dist directory..."
            Remove-Item ".\dist" -Recurse -Force
          }

          New-Item `
            -ItemType Directory `
            -Path ".\dist" `
            -Force | Out-Null

          # ========================================
          # RUN BUILD SCRIPT
          # ========================================

          Write-Host ""
          Write-Host "Running build.ps1..."
          Write-Host ""

          & ".\scripts\build.ps1" -Version $version

          # Do NOT use $LASTEXITCODE here.
          # build.ps1 uses PowerShell exceptions for failures.
          if (-not $?) {
            throw "build.ps1 failed."
          }

          Write-Host ""
          Write-Host "build.ps1 completed successfully."

          # ========================================
          # FIND GENERATED ZIP
          # ========================================

          $zipFiles = @(
            Get-ChildItem `
              -Path "." `
              -Filter "*.zip" `
              -File `
              -Recurse |
            Where-Object {
              $_.FullName -notlike "*\dist\*"
            }
          )

          if ($zipFiles.Count -eq 0) {
            throw "ERROR: build.ps1 completed but no ZIP was produced."
          }

          # Select newest ZIP
          $zip = $zipFiles |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

          Write-Host ""
          Write-Host "=========================================="
          Write-Host " BUILD ARTIFACT FOUND"
          Write-Host "=========================================="

          Write-Host "File: $($zip.FullName)"
          Write-Host "Size: $($zip.Length) bytes"

          if ($zip.Length -le 0) {
            throw "Generated ZIP is empty."
          }

          # ========================================
          # COPY ZIP TO DIST
          # ========================================

          $destination = Join-Path ".\dist" $zip.Name

          Copy-Item `
            -LiteralPath $zip.FullName `
            -Destination $destination `
            -Force

          if (-not (Test-Path $destination)) {
            throw "ERROR: Failed to copy ZIP to dist."
          }

          $distZip = Get-Item $destination

          if ($distZip.Length -le 0) {
            throw "ERROR: ZIP in dist is empty."
          }

          Write-Host ""
          Write-Host "Copied to:"
          Write-Host $destination

          # ========================================
          # DISPLAY OUTPUT
          # ========================================

          Write-Host ""
          Write-Host "=========================================="
          Write-Host " BUILD OUTPUT"
          Write-Host "=========================================="

          Get-ChildItem ".\dist" -File |
            Select-Object Name, Length |
            Format-Table -AutoSize

      # ========================================
      # GENERATE SHA256
      # ========================================

      - name: Generate checksums
        shell: pwsh
        run: |
          $ErrorActionPreference = "Stop"

          Write-Host "=========================================="
          Write-Host " Generating SHA256 checksums"
          Write-Host "=========================================="

          if (-not (Test-Path ".\dist")) {
            throw "ERROR: dist directory does not exist."
          }

          $zipFiles = @(
            Get-ChildItem ".\dist\*.zip" -File
          )

          if ($zipFiles.Count -eq 0) {
            throw "ERROR: No ZIP files found in dist."
          }

          $lines = foreach ($file in $zipFiles) {

            Write-Host "Hashing: $($file.Name)"

            $hash = (
              Get-FileHash `
                -Path $file.FullName `
                -Algorithm SHA256
            ).Hash

            "$hash  $($file.Name)"
          }

          $lines |
            Out-File `
              ".\dist\SHA256SUMS.txt" `
              -Encoding utf8

          Write-Host ""
          Write-Host "SHA256SUMS.txt:"
          Get-Content ".\dist\SHA256SUMS.txt"

      # ========================================
      # VERIFY BUILD
      # ========================================

      - name: Verify build output
        shell: pwsh
        run: |
          $ErrorActionPreference = "Stop"

          Write-Host "=========================================="
          Write-Host " Verifying build output"
          Write-Host "=========================================="

          if (-not (Test-Path ".\dist")) {
            throw "ERROR: dist directory does not exist."
          }

          $zipFiles = @(
            Get-ChildItem ".\dist\*.zip" -File
          )

          if ($zipFiles.Count -eq 0) {
            throw "ERROR: No ZIP file exists in dist."
          }

          foreach ($file in $zipFiles) {

            Write-Host ""
            Write-Host "ZIP:  $($file.Name)"
            Write-Host "Size: $($file.Length) bytes"

            if ($file.Length -le 0) {
              throw "ERROR: ZIP file is empty: $($file.Name)"
            }
          }

          if (-not (Test-Path ".\dist\SHA256SUMS.txt")) {
            throw "ERROR: SHA256SUMS.txt was not created."
          }

          $checksum = Get-Content ".\dist\SHA256SUMS.txt" -Raw

          if ([string]::IsNullOrWhiteSpace($checksum)) {
            throw "ERROR: SHA256SUMS.txt is empty."
          }

          Write-Host ""
          Write-Host "SHA256SUMS.txt verified."

          Write-Host ""
          Write-Host "=========================================="
          Write-Host " BUILD VERIFIED SUCCESSFULLY"
          Write-Host "=========================================="

      # ========================================
      # CREATE GITHUB RELEASE
      # ========================================

      - name: Create GitHub Release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          name: SkipperBNS HATS ${{ github.ref_name }}
          generate_release_notes: true
          files: |
            dist/*.zip
            dist/SHA256SUMS.txt
