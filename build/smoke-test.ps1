<#
.SYNOPSIS
    Verify the built cbcloudscraper.exe by fetching one URL.

.DESCRIPTION
    Runs two checks against bin\win64\cbcloudscraper.exe.

    Phase 1 fetches the URL normally and prints the status code, engine used, and body
    length. Phase 2 fetches it again with downloadTo set, and checks that the body went
    to the file instead of into the response JSON.

    Use this after build-binary.ps1 to confirm the packaged binary works on its own,
    before testing it through the ColdBox module.

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
$DownloadFile = Join-Path $env:TEMP ("cbcs-smoke-" + [guid]::NewGuid().ToString() + ".download")

function Invoke-Worker($request) {
    # Write UTF-8 without a byte-order mark, matching how the ColdBox module writes it.
    $json = $request | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($ReqFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item -Force $ResFile -ErrorAction SilentlyContinue
    & $Exe --request $ReqFile --response $ResFile
    Write-Host ("exit code:   " + $LASTEXITCODE)
    if (-not (Test-Path $ResFile)) {
        throw "No response file was produced."
    }
    return (Get-Content $ResFile -Raw | ConvertFrom-Json)
}

try {
    # ---- Phase 1: a normal request, with the body in the response JSON ----
    Write-Host "Phase 1: fetching $Url ..." -ForegroundColor Cyan
    $res = Invoke-Worker @{
        url             = $Url
        method          = "GET"
        engine          = "auto"
        impersonate     = "chrome"
        timeoutSeconds  = 30
        followRedirects = $true
        verifySSL       = $true
    }

    $bodyLen = 0
    if ($res.bodyBase64) {
        $bodyLen = [System.Convert]::FromBase64String($res.bodyBase64).Length
    }
    Write-Host ("ok:          " + $res.ok)
    Write-Host ("statusCode:  " + $res.statusCode)
    Write-Host ("engineUsed:  " + $res.engineUsed)
    Write-Host ("charset:     " + $res.bodyCharset)
    Write-Host ("body bytes:  " + $bodyLen)
    Write-Host ("timing ms:   " + $res.timingMs)

    if (-not ($res.ok -and $res.statusCode -ge 200 -and $res.statusCode -lt 400)) {
        Write-Host "SMOKE TEST returned a non-success status; inspect the response above." -ForegroundColor Yellow
        return
    }
    if ($bodyLen -le 0) {
        throw "Phase 1 failed: a normal request returned no body."
    }

    # ---- Phase 2: the same request with downloadTo, so the body goes to a file ----
    # downloadPartPath is left out on purpose, so this also checks the worker's own
    # fallback to <target>.part.
    Write-Host ""
    Write-Host "Phase 2: downloading $Url to a file ..." -ForegroundColor Cyan
    $res = Invoke-Worker @{
        url               = $Url
        method            = "GET"
        engine            = "auto"
        impersonate       = "chrome"
        timeoutSeconds    = 300
        followRedirects   = $true
        verifySSL         = $true
        downloadTo        = $DownloadFile
        downloadOnlyOn2xx = $true
    }

    $b64Len = 0
    if ($res.bodyBase64) { $b64Len = $res.bodyBase64.Length }
    Write-Host ("ok:            " + $res.ok)
    Write-Host ("statusCode:    " + $res.statusCode)
    Write-Host ("engineUsed:    " + $res.engineUsed)
    Write-Host ("downloadedTo:  " + $res.downloadedTo)
    Write-Host ("bytesWritten:  " + $res.bytesWritten)
    Write-Host ("bodyBase64:    " + $b64Len + " characters")

    if (-not $res.ok) { throw "Phase 2 failed: ok was false." }
    if ($res.downloadedTo -ne $DownloadFile) {
        throw "Phase 2 failed: downloadedTo was '$($res.downloadedTo)', expected '$DownloadFile'."
    }
    if ($res.bytesWritten -le 0) { throw "Phase 2 failed: bytesWritten was $($res.bytesWritten)." }
    if ($b64Len -ne 0) { throw "Phase 2 failed: the body was base64-encoded as well as written to the file." }
    if (-not (Test-Path $DownloadFile)) { throw "Phase 2 failed: $DownloadFile was not created." }

    $actualSize = (Get-Item $DownloadFile).Length
    if ($actualSize -ne $res.bytesWritten) {
        throw "Phase 2 failed: the file is $actualSize bytes but bytesWritten said $($res.bytesWritten)."
    }
    if (Test-Path ($DownloadFile + ".part")) {
        throw "Phase 2 failed: the in-progress .part file was left behind."
    }
    Write-Host ("file size:     " + $actualSize + " bytes, matches bytesWritten")

    Write-Host ""
    Write-Host "SMOKE TEST PASSED" -ForegroundColor Green
}
finally {
    Remove-Item -Force $ReqFile -ErrorAction SilentlyContinue
    Remove-Item -Force $ResFile -ErrorAction SilentlyContinue
    Remove-Item -Force $DownloadFile -ErrorAction SilentlyContinue
    Remove-Item -Force ($DownloadFile + ".part") -ErrorAction SilentlyContinue
}
