<#
.SYNOPSIS
    Build the cbcloudscraper worker into a standalone Windows executable.

.DESCRIPTION
    Creates (or reuses) a Python virtual environment under engine\.venv, installs the
    pinned dependencies, records the exact resolved versions in engine\requirements.lock.txt,
    and runs PyInstaller to produce a self-contained program at bin\win64\cbcloudscraper.exe.

    The result needs no Python installed on the server that runs the ColdBox module.

    Run this whenever you change engine\requirements.txt (for example to update
    cloudscraper or curl_cffi) or the worker source under engine\.

.PARAMETER Clean
    Delete and recreate the virtual environment and previous build output before building.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\build-binary.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\build-binary.ps1 -Clean
#>
param(
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# --- Resolve paths (script lives in <repo>\build) --------------------------------
$BuildDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $BuildDir
$EngineDir = Join-Path $RepoRoot "engine"
$VenvDir = Join-Path $EngineDir ".venv"
$BinDir = Join-Path $RepoRoot "bin\win64"
$SpecFile = Join-Path $BuildDir "cbcloudscraper.spec"
$WorkPath = Join-Path $BuildDir ".pyi-work"
$DistPath = Join-Path $BuildDir ".pyi-dist"
$Requirements = Join-Path $EngineDir "requirements.txt"
$LockFile = Join-Path $EngineDir "requirements.lock.txt"

Write-Host "cbcloudscraper build" -ForegroundColor Cyan
Write-Host "  repo:   $RepoRoot"
Write-Host "  engine: $EngineDir"
Write-Host "  output: $BinDir\cbcloudscraper.exe"

# --- Pick a Python interpreter (prefer 3.11) -------------------------------------
function Resolve-Python {
    # Prefer the 3.11 launcher for the widest wheel coverage and cloudscraper25 support.
    try {
        $v = & py -3.11 --version 2>$null
        if ($LASTEXITCODE -eq 0) { return @("py", "-3.11") }
    } catch {}
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        $ver = & python --version 2>&1
        Write-Host "  note: Python 3.11 launcher not found; using '$ver'. 3.11 is recommended." -ForegroundColor Yellow
        return @("python")
    }
    throw "No Python interpreter found. Install Python 3.11 (or 3.x) and ensure it is on PATH."
}

$PyLauncher = Resolve-Python

# --- Create / reset the virtual environment --------------------------------------
if ($Clean) {
    foreach ($d in @($VenvDir, $WorkPath, $DistPath, $BinDir)) {
        if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    }
}

$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path $VenvPython)) {
    Write-Host "Creating virtual environment..." -ForegroundColor Cyan
    & $PyLauncher[0] $PyLauncher[1..($PyLauncher.Length - 1)] -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "Failed to create virtual environment." }
}

Write-Host "Installing dependencies..." -ForegroundColor Cyan
& $VenvPython -m pip install --upgrade pip --quiet
if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed." }
& $VenvPython -m pip install -r $Requirements --quiet
if ($LASTEXITCODE -ne 0) { throw "Dependency install failed." }

# Record the exact resolved versions for reproducible rebuilds (ASCII, no BOM).
$frozen = & $VenvPython -m pip freeze
[System.IO.File]::WriteAllText($LockFile, ($frozen -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  wrote lock file: $LockFile"

# --- Build the executable --------------------------------------------------------
if (Test-Path $WorkPath) { Remove-Item -Recurse -Force $WorkPath }
if (Test-Path $DistPath) { Remove-Item -Recurse -Force $DistPath }

Write-Host "Running PyInstaller..." -ForegroundColor Cyan
& $VenvPython -m PyInstaller $SpecFile --noconfirm --workpath $WorkPath --distpath $DistPath --log-level WARN
if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed." }

# --- Place the onedir output at bin\win64\ ---------------------------------------
$Produced = Join-Path $DistPath "cbcloudscraper"
if (-not (Test-Path (Join-Path $Produced "cbcloudscraper.exe"))) {
    throw "Build did not produce cbcloudscraper.exe at $Produced"
}

if (Test-Path $BinDir) { Remove-Item -Recurse -Force $BinDir }
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Copy-Item -Path (Join-Path $Produced "*") -Destination $BinDir -Recurse -Force

# Clean up intermediate build folders.
Remove-Item -Recurse -Force $WorkPath -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $DistPath -ErrorAction SilentlyContinue

$ExePath = Join-Path $BinDir "cbcloudscraper.exe"
Write-Host ""
Write-Host "Build complete: $ExePath" -ForegroundColor Green
Write-Host "Quick self-test: run build\smoke-test.ps1 to verify the binary." -ForegroundColor Green
