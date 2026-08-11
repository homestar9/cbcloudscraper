<#
.SYNOPSIS
    Verify the built cbcloudscraper.exe by fetching one URL.

.DESCRIPTION
    Writes a request JSON file, runs bin\win64\cbcloudscraper.exe against it, reads the
    response, and prints the status code, engine used, and body length. Use this after
    build-binary.ps1 to confirm the packaged binary works on its own, before testing it
    through the ColdBox module.

.PARAMETER Url
    The URL to fetch. Defaults to https://example.com.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\smoke-test.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\smoke-test.ps1 -Url https://the-target-site.gov/lookup
#>
param(
    [string]$Url = "https://example.com"
)

$ErrorActionPreference = "Stop"

$BuildDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $BuildDir
$Exe = Join-Path $RepoRoot "bin\win64\cbcloudscraper.exe"

if (-not (Test-Path $Exe)) {
    throw "Binary not found at $Exe. Run build\build-binary.ps1 first."
}

$ReqFile = Join-Path $env:TEMP ("cbcs-smoke-" + [guid]::NewGuid().ToString() + ".req.json")
$ResFile = Join-Path $env:TEMP ("cbcs-smoke-" + [guid]::NewGuid().ToString() + ".res.json")

$request = @{
    url            = $Url
    method         = "GET"
    engine         = "auto"
    impersonate    = "chrome"
    timeoutSeconds = 30
    followRedirects = $true
    verifySSL      = $true
}

try {
    # Write UTF-8 without a byte-order mark, matching how the ColdBox module writes it.
    $json = $request | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($ReqFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Fetching $Url ..." -ForegroundColor Cyan
    & $Exe --request $ReqFile --response $ResFile
    $exit = $LASTEXITCODE
    Write-Host "exit code: $exit"

    if (-not (Test-Path $ResFile)) {
        throw "No response file was produced."
    }

    $res = Get-Content $ResFile -Raw | ConvertFrom-Json
    $bodyLen = 0
    if ($res.bodyBase64) {
        $bodyLen = [System.Convert]::FromBase64String($res.bodyBase64).Length
    }
    Write-Host ""
    Write-Host ("ok:          " + $res.ok)
    Write-Host ("statusCode:  " + $res.statusCode)
    Write-Host ("engineUsed:  " + $res.engineUsed)
    Write-Host ("charset:     " + $res.bodyCharset)
    Write-Host ("body bytes:  " + $bodyLen)
    Write-Host ("timing ms:   " + $res.timingMs)
    if ($res.ok -and $res.statusCode -ge 200 -and $res.statusCode -lt 400) {
        Write-Host "SMOKE TEST PASSED" -ForegroundColor Green
    } else {
        Write-Host "SMOKE TEST returned a non-success status; inspect the response above." -ForegroundColor Yellow
    }
}
finally {
    Remove-Item -Force $ReqFile -ErrorAction SilentlyContinue
    Remove-Item -Force $ResFile -ErrorAction SilentlyContinue
}
