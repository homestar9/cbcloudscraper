<#
.SYNOPSIS
    Report whether the cbcloudscraper binary needs rebuilding.

.DESCRIPTION
    Compares engine\requirements.lock.txt -- the exact library versions inside the binary you
    last built -- against the current versions on PyPI, and reports whether the worker source
    changed since the last release tag.

    This script only reads. It installs nothing, changes no virtual environment, and builds
    nothing.

    Why a check is needed at all: curl_cffi is range-pinned as ">=0.7,<1.0" in
    engine\requirements.txt, so a rebuild silently picks up new versions even though no file in
    this repository changed. Nothing in git can tell you that. cloudscraper25 is exact-pinned in
    requirements.txt, so it can only move if you edit that file yourself. Unlike the original
    cloudscraper (which was frozen upstream), cloudscraper25 is actively maintained and does ship
    new releases, so this check will surface them; bumping the pin is a decision to make, not a
    routine refresh.

    Only the libraries that end up inside the shipped binary are checked. Build-time packages
    such as pyinstaller and pefile are skipped, because a newer one changes nothing a consumer
    of this module would ever see.

    Versions are compared against PyPI's latest STABLE release, which is what pip installs under
    a range pin. Pre-releases are ignored unless you pass -Prerelease, so the report never
    suggests an update that a rebuild would not actually install.

.PARAMETER Prerelease
    Also show the newest pre-release of each library. Useful when a target site suddenly started
    failing and a beta may already carry the fix.

.PARAMETER Detailed
    List every package in the lock file, including the build-time ones.

.OUTPUTS
    Exit code 0 when the shipped binary is current, 1 when a rebuild is recommended.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\check-updates.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\check-updates.ps1 -Prerelease
#>
param(
    [switch]$Prerelease,
    [switch]$Detailed
)

$ErrorActionPreference = "Stop"

$BuildDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $BuildDir
$LockFile = Join-Path $RepoRoot "engine\requirements.lock.txt"

# The libraries that actually ship inside the executable. Everything else in the lock file is
# either a build tool or a transitive dependency that moves with these.
$Runtime = @(
    @{ Name = "curl_cffi";      Note = "browser TLS fingerprints - the engine that beats Cloudflare" },
    @{ Name = "cloudscraper25"; Note = "JS challenge fallback (maintained cloudscraper fork) - exact-pinned" },
    @{ Name = "js2py";          Note = "JavaScript interpreter used by cloudscraper25" },
    @{ Name = "certifi";        Note = "CA bundle for HTTPS verification" },
    @{ Name = "requests";       Note = "used by cloudscraper25" },
    @{ Name = "urllib3";        Note = "used by requests" }
)

# ── Read the lock file ────────────────────────────────────────────────────────
if (-not (Test-Path $LockFile)) {
    throw "No lock file at $LockFile. Build the binary once with build\build-binary.ps1 to create it."
}

$Locked = @{}
foreach ($line in Get-Content $LockFile) {
    if ($line -match "^\s*([A-Za-z0-9_.\-]+)\s*==\s*(.+?)\s*$") {
        # pip normalizes names inconsistently between "-" and "_", so key on a single form.
        $Locked[$matches[1].ToLower().Replace("-", "_")] = $matches[2]
    }
}
if ($Locked.Count -eq 0) {
    throw "Could not read any pinned versions from $LockFile."
}

# ── Ask PyPI what the current version is ──────────────────────────────────────
function Get-PyPIVersions {
    param([string]$Package)

    $url = "https://pypi.org/pypi/$Package/json"
    try {
        $data = Invoke-RestMethod -Uri $url -TimeoutSec 30 -UseBasicParsing
    } catch {
        # A failed lookup must never read as "nothing to update".
        return @{ Stable = $null; Prerelease = $null; Error = $_.Exception.Message }
    }

    # info.version is the latest stable, which is exactly what pip resolves to under a range
    # pin. Do not substitute the newest entry in the releases list; that includes betas.
    $stable = $data.info.version

    $newestPre = $null
    if ($Prerelease) {
        $newestPreDate = [datetime]::MinValue
        foreach ($entry in $data.releases.PSObject.Properties) {
            if ($entry.Name -notmatch "(a|b|rc)\d+$") { continue }
            if (-not $entry.Value -or $entry.Value.Count -eq 0) { continue }
            $uploaded = [datetime]$entry.Value[0].upload_time
            if ($uploaded -gt $newestPreDate) {
                $newestPreDate = $uploaded
                $newestPre     = $entry.Name
            }
        }
    }

    return @{ Stable = $stable; Prerelease = $newestPre; Error = $null }
}

Write-Host ""
Write-Host "cbcloudscraper binary update check" -ForegroundColor Cyan
Write-Host "  lock file: $LockFile"
Write-Host ""

$Reasons  = @()
$Warnings = @()
$Rows     = @()

foreach ($lib in $Runtime) {
    $key       = $lib.Name.ToLower().Replace("-", "_")
    $installed = $Locked[$key]
    $latest    = Get-PyPIVersions -Package $lib.Name

    if ($null -eq $installed) {
        $status = "not in lock file"
        $Warnings += "$($lib.Name) is not in the lock file. Rebuild once to record it."
    } elseif ($null -ne $latest.Error) {
        $status = "could not reach PyPI"
        $Warnings += "Could not check $($lib.Name): $($latest.Error)"
    } elseif ($installed -eq $latest.Stable) {
        $status = "current"
    } else {
        $status = "UPDATE AVAILABLE"
        $Reasons += "$($lib.Name) $installed -> $($latest.Stable)"
    }

    $Rows += [pscustomobject]@{
        Library     = $lib.Name
        InBinary    = if ($installed) { $installed } else { "-" }
        LatestPyPI  = if ($latest.Stable) { $latest.Stable } else { "?" }
        Status      = $status
        Prerelease  = if ($latest.Prerelease) { $latest.Prerelease } else { "" }
    }
}

$columns = @("Library", "InBinary", "LatestPyPI", "Status")
if ($Prerelease) { $columns += "Prerelease" }
$Rows | Format-Table -AutoSize -Property $columns | Out-String | Write-Host

foreach ($row in $Rows) {
    if ($row.Status -eq "UPDATE AVAILABLE") {
        $note = ($Runtime | Where-Object { $_.Name -eq $row.Library }).Note
        Write-Host "  $($row.Library): $note" -ForegroundColor Yellow
    }
}

if ($Detailed) {
    Write-Host ""
    Write-Host "Everything in the lock file (build-time packages included):" -ForegroundColor Cyan
    foreach ($name in ($Locked.Keys | Sort-Object)) {
        Write-Host ("  {0,-28} {1}" -f $name, $Locked[$name])
    }
}

# ── Did the worker source change since the last release? ──────────────────────
# git writes ordinary notices to stderr, which Windows PowerShell turns into a terminating
# error while ErrorActionPreference is "Stop". Relax it for this block only.
Push-Location $RepoRoot
$previousPreference    = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    # "git tag --list" is quiet and succeeds on a repository with no tags, unlike
    # "git describe", which fails with "No names found".
    $tags = git tag --list
    if ($tags) {
        $lastTag = git describe --tags --abbrev=0
        if ($LASTEXITCODE -eq 0 -and $lastTag) {
            $changed = git diff --name-only "$lastTag..HEAD" -- engine build/cbcloudscraper.spec
            if ($changed) {
                $Reasons += "worker source changed since $lastTag"
                Write-Host "Changed since ${lastTag}:" -ForegroundColor Yellow
                foreach ($file in $changed) { Write-Host "  $file" }
                Write-Host ""
            }
        }
    } else {
        Write-Host "No release tag yet, so there is no released binary to compare the source against." -ForegroundColor DarkGray
        Write-Host ""
    }
} finally {
    $ErrorActionPreference = $previousPreference
    Pop-Location
}

# ── Verdict ───────────────────────────────────────────────────────────────────
Write-Host ""
foreach ($warning in $Warnings) { Write-Host "  warning: $warning" -ForegroundColor Yellow }

if ($Reasons.Count -gt 0) {
    Write-Host "Rebuild recommended:" -ForegroundColor Yellow
    foreach ($reason in $Reasons) { Write-Host "  - $reason" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  1. powershell -ExecutionPolicy Bypass -File build\build-binary.ps1"
    Write-Host "  2. powershell -ExecutionPolicy Bypass -File build\smoke-test.ps1"
    Write-Host "  3. Commit engine\requirements.lock.txt, then ship it as a new version."
    Write-Host "     A rebuilt binary only reaches people through a new release tag."
    Write-Host ""
    exit 1
}

Write-Host "The shipped binary is current. No rebuild needed." -ForegroundColor Green
Write-Host ""
exit 0
