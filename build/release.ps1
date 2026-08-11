<#
.SYNOPSIS
    Cut a cbcloudscraper release: build the binary, then run the build-template release kit,
    then attach the binary to the GitHub Release.

.DESCRIPTION
    The build-template kit (build/Release.cfc) handles the parts every project needs: run the
    tests, build the pure-source package, publish it to ForgeBox, tag the commit, and create a
    GitHub Release. This wrapper adds the two things specific to cbcloudscraper:

      1. Build the Windows executable (build/build-binary.ps1) and zip it with a SHA-256 file.
      2. After the kit creates the GitHub Release, upload that binary zip + checksum to it.

    Consumers download that binary from the Release on first use (see models/BinaryProvisioner.cfc).

    Run this AFTER you have bumped the version and committed:
        box run-script bump:patch      # or bump:minor / bump:major
        git commit -am "Release vX.Y.Z"
        powershell -ExecutionPolicy Bypass -File build\release.ps1

    Prerequisites: a clean git working tree on master, signed in to ForgeBox (box login), and
    the GitHub CLI (gh) authenticated.

.PARAMETER SkipBinaryBuild
    Reuse the existing bin\win64 binary instead of rebuilding it.
#>
param(
    [switch]$SkipBinaryBuild
)

$ErrorActionPreference = "Stop"

$BuildDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot    = Split-Path -Parent $BuildDir
$BinDir      = Join-Path $RepoRoot "bin\win64"
$ArtifactDir = Join-Path $RepoRoot ".artifacts\binary"
$Exe         = Join-Path $BinDir "cbcloudscraper.exe"

# ── 1. Build the Windows binary ───────────────────────────────────────────────
if (-not $SkipBinaryBuild) {
    Write-Host "Building the Windows binary..." -ForegroundColor Cyan
    & (Join-Path $BuildDir "build-binary.ps1")
    if ($LASTEXITCODE -ne 0) { throw "build-binary.ps1 failed." }
}
if (-not (Test-Path $Exe)) { throw "Binary not found at $Exe. Run without -SkipBinaryBuild." }

# ── 2. Zip the binary folder and write its SHA-256 ────────────────────────────
if (Test-Path $ArtifactDir) { Remove-Item -Recurse -Force $ArtifactDir }
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$Zip = Join-Path $ArtifactDir "cbcloudscraper-win64.zip"
Compress-Archive -Path (Join-Path $BinDir "*") -DestinationPath $Zip -Force
$Hash = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLower()
[System.IO.File]::WriteAllText("$Zip.sha256", "$Hash  cbcloudscraper-win64.zip`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Binary asset ready: $Zip" -ForegroundColor Green
Write-Host "SHA-256: $Hash"

# The version and tag the kit will release (read from box.json, the single source of truth).
$Version = (Get-Content (Join-Path $RepoRoot "box.json") -Raw | ConvertFrom-Json).version
$Tag     = "v$Version"

Push-Location $RepoRoot
try {
    # ── 3. Start the test server the kit uses to run the suite during release ──
    Write-Host "Starting the Lucee test server..." -ForegroundColor Cyan
    box server start serverConfigFile=server-lucee@5.json --noSaveSettings | Out-Null

    # ── 4. Run the build-template release (tests, source package, ForgeBox, tag, GitHub Release) ──
    Write-Host "Running the release kit for $Tag..." -ForegroundColor Cyan
    box run-script release
    if ($LASTEXITCODE -ne 0) { throw "The release kit (box run-script release) failed." }

    # ── 5. Attach the binary to the Release the kit just created ──────────────
    Write-Host "Attaching the binary to Release $Tag..." -ForegroundColor Cyan
    gh release upload $Tag $Zip "$Zip.sha256" --clobber
    if ($LASTEXITCODE -ne 0) { throw "Uploading the binary asset to Release $Tag failed." }

    Write-Host ""
    Write-Host "Release $Tag complete: published to ForgeBox and GitHub, with the Windows binary attached." -ForegroundColor Green
}
finally {
    Pop-Location
}
