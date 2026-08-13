<#
.SYNOPSIS
    Run the worker's Python unit tests.

.DESCRIPTION
    Runs engine\tests with Python's built-in unittest runner, using the virtual
    environment that build-binary.ps1 creates. These tests cover the download logic and
    the request-value helpers in engine\engines\common.py. They need no network
    connection and no built binary, so run them before starting a PyInstaller build.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\run-python-tests.ps1
#>

$ErrorActionPreference = "Stop"

$BuildDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $BuildDir
$EngineDir = Join-Path $RepoRoot "engine"
$Python = Join-Path $EngineDir ".venv\Scripts\python.exe"

if (-not (Test-Path $Python)) {
    throw "Python virtual environment not found at $Python. Run build\build-binary.ps1 first."
}

Push-Location $EngineDir
try {
    # -t . makes the engine directory the top level, so "from engines import common" works.
    & $Python -m unittest discover -s tests -t . -v
    $exit = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($exit -ne 0) {
    throw "Python unit tests failed (exit code $exit)."
}

Write-Host "PYTHON TESTS PASSED" -ForegroundColor Green
