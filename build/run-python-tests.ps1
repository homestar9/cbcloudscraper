<#
.SYNOPSIS
    Run the worker's Python unit tests.

.DESCRIPTION
    Uses Python's built-in unittest runner and the virtual environment created by
    build-binary.ps1. The tests do not need a network connection or a built executable.
    Run them before starting a PyInstaller build.

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
    # -t . adds the engine directory to the import path. Tests can then import engines.common.
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
