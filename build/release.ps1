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

    There are two ways to run this, and which one you need depends on who created the git tag.

    1. Plain release from master, where the build kit creates the tag itself:

        box run-script bump:patch      # or bump:minor / bump:major
        git commit -am "Release vX.Y.Z"
        powershell -ExecutionPolicy Bypass -File build\release.ps1

    2. Gitflow release, where GitKraken's "Finish release" already created the tag. Push master,
       develop, and the tag first, then check out master and run:

        powershell -ExecutionPolicy Bypass -File build\release.ps1 -ExistingTag

    Without -ExistingTag the kit tries to create the tag and stops, because it already exists.

    Prerequisites: a clean git working tree on master, signed in to ForgeBox (box login), and
    the GitHub CLI (gh) authenticated.

.PARAMETER SkipBinaryBuild
    Reuse the existing bin\win64 binary instead of rebuilding it.

.PARAMETER SkipEngineTests
    Skip the multi-engine test sweep. Use this only for an urgent hotfix. The sweep is what
    catches code that works on one CFML engine and fails to compile on another.

.PARAMETER ExistingTag
    Publish a tag that already exists and points at the checked-out commit, instead of creating
    one. Use this whenever GitKraken or the git-flow extension made the tag.
#>
param(
    [switch]$SkipBinaryBuild,
    [switch]$SkipEngineTests,
    [switch]$ExistingTag
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

# The binary zip is built later (step 4), after the release kit runs. The kit rewrites the
# .artifacts directory, so a zip written here (under .artifacts\binary) would be deleted before
# the upload step. Building it after the kit keeps the file in place for the upload.

# The version and tag the kit will release (read from box.json, the single source of truth).
$Version = (Get-Content (Join-Path $RepoRoot "box.json") -Raw | ConvertFrom-Json).version
$Tag     = "v$Version"

Push-Location $RepoRoot
try {
    # ── 2. Run the suite on every supported CFML engine ───────────────────────
    # The engines are listed in build/build.json. They run one at a time, because they share one
    # port, and TestEngines.cfc stops every server when it finishes. That is why this has to run
    # before the kit's own server starts below.
    #
    # This step exists because CFML engines disagree at compile time. Version 1.1.0 shipped with a
    # cfzip call that made the module impossible to load on a default Adobe ColdFusion install, and
    # a single-engine release could not have caught it.
    if (-not $SkipEngineTests) {
        Write-Host "Running the test suite on every engine..." -ForegroundColor Cyan
        box run-script test:engines
        if ($LASTEXITCODE -ne 0) { throw "The multi-engine test sweep (box run-script test:engines) failed." }
    } else {
        Write-Host "Skipping the multi-engine test sweep (-SkipEngineTests)." -ForegroundColor Yellow
    }

    # ── 3. Start the test server the kit uses to run the suite during release ──
    # Adobe 2023 is the engine used in production, so the release runs its tests there.
    Write-Host "Starting the Adobe 2023 test server..." -ForegroundColor Cyan
    box server start serverConfigFile=server-adobe@2023.json --noSaveSettings | Out-Null

    # ── 4. Run the build-template release (tests, source package, ForgeBox, tag, GitHub Release) ──
    # release:existing-tag skips tag creation and the branch push, because the tag is already
    # made and pushed. Everything else about the two paths is the same.
    $ReleaseScript = if ($ExistingTag) { "release:existing-tag" } else { "release" }
    if ($ExistingTag) {
        Write-Host "Running the release kit for existing tag $Tag..." -ForegroundColor Cyan
    } else {
        Write-Host "Running the release kit for $Tag (the kit will create the tag)..." -ForegroundColor Cyan
    }
    box run-script $ReleaseScript
    if ($LASTEXITCODE -ne 0) { throw "The release kit (box run-script $ReleaseScript) failed." }

    # ── 5. Zip the binary folder and write its SHA-256 ────────────────────────
    # Built here, after the kit runs, because the kit rewrites the .artifacts directory and would
    # otherwise delete this zip before it is uploaded.
    if (Test-Path $ArtifactDir) { Remove-Item -Recurse -Force $ArtifactDir }
    New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
    $Zip = Join-Path $ArtifactDir "cbcloudscraper-win64.zip"
    # ZipFile::CreateFromDirectory is used instead of Compress-Archive because Compress-Archive on
    # Windows PowerShell writes entry names with backslashes, such as "_internal\cryptography\".
    # The zip format says entry names use forward slashes, and a reader that follows the format
    # cannot tell those folder entries from files. Releases up to 1.1.0 were built the broken way.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $BinDir,
        $Zip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false   # do not add the bin\win64 folder itself as a top-level entry
    )
    $Hash = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLower()
    [System.IO.File]::WriteAllText("$Zip.sha256", "$Hash  cbcloudscraper-win64.zip`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Binary asset ready: $Zip" -ForegroundColor Green
    Write-Host "SHA-256: $Hash"

    # ── 6. Attach the binary to the Release the kit just created ──────────────
    Write-Host "Attaching the binary to Release $Tag..." -ForegroundColor Cyan
    if (-not (Test-Path $Zip)) { throw "Binary asset $Zip is missing; cannot upload it to Release $Tag." }
    gh release upload $Tag $Zip "$Zip.sha256" --clobber
    if ($LASTEXITCODE -ne 0) { throw "Uploading the binary asset to Release $Tag failed." }

    Write-Host ""
    Write-Host "Release $Tag complete: published to ForgeBox and GitHub, with the Windows binary attached." -ForegroundColor Green
}
finally {
    Pop-Location
}
