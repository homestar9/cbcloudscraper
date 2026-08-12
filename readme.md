# cbcloudscraper

Make HTTP requests from a ColdBox application that pass Cloudflare's bot protection.

Some public websites sit behind Cloudflare, which blocks ordinary `cfhttp` requests and
headless-browser scraping. This module gives you a third method: a small helper program
that fetches a page using a real browser's network fingerprint, and returns the result to
your CFML code as a struct shaped like a `cfhttp` result.

## What it can and cannot do

This module uses two techniques, bundled in one executable, and tries them in order:

1. **curl_cffi** (tried first) presents a real browser's TLS and HTTP/2 fingerprint. This
   passes Cloudflare blocks that reject clients based on the network handshake, which is the
   layer plain Python and Java HTTP clients fail.
2. **cloudscraper** (fallback) solves Cloudflare's older "Checking your browser" JavaScript
   challenge.

**Honest limitation:** neither technique reliably passes a modern Cloudflare *interactive*
challenge — a Turnstile widget or a "managed challenge" that expects a real browser with a
person behind it. Those need a real browser engine, which is out of scope for this version.
Test against your specific target early (see [Verifying against your target](#verifying-against-your-target)).
If it returns an interactive challenge, you will need a heavier browser-based approach
(for example FlareSolverr, nodriver, or SeleniumBase); the module is structured so such an
engine can be added later.

## How it works

Each request runs the helper program once:

```
Your ColdBox code
  └─ getInstance("CloudScraper@cbcloudscraper").get( url )
       ├─ makes sure the platform binary is present (downloads it once on first use)
       ├─ writes a small request file (URL, method, headers, body)
       ├─ runs cbcloudscraper.exe once (via Java ProcessBuilder)
       ├─ reads the response file (status, headers, cookies, body)
       └─ returns a cfhttp-style struct
```

The program is built from the Python source in [`engine/`](engine/) with PyInstaller, but you
do **not** build or install it yourself. It is published as a per-platform asset on the
module's GitHub Releases, and the module downloads the build that matches your operating
system the first time a request runs, then caches it. Your server needs no Python.

## Requirements

- ColdBox 7+ on Lucee 5/6, Adobe ColdFusion 2023/2025, or BoxLang.
- Windows to run the binary (this version publishes a Windows build only).
- Outbound HTTPS access the first time a request runs, so the module can fetch the binary
  from GitHub Releases. A server that can reach the sites you scrape can reach GitHub. For a
  locked-down server, see [Offline and locked-down servers](#offline-and-locked-down-servers).

## Installation

Install from ForgeBox:

```bash
box install cbcloudscraper
```

Or install straight from GitHub:

```bash
box install homestar9/cbcloudscraper
```

Either way you get pure CFML — no Python, no build step. The first `get`/`post` call
downloads the Windows binary once (about 26 MB) from the matching GitHub Release and caches
it under the module's `bin/` folder; every later call uses the cached copy.

## Pre-installing and updating the binary

The binary downloads automatically on the first request, so you can skip this section and it
will just work. To fetch it ahead of time — for example during a deploy, so the first real
request is not delayed — use the bundled CommandBox task from your app root:

```bash
box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=status    # installed vs wanted version
box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install   # download it now
box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=update    # refresh only if out of date
```

A shorter alias can go in your app's `box.json`:

```json
"scripts": {
    "cbcloudscraper:install": "task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install"
}
```

Or pre-fetch from application code (for example in `onApplicationStart` or a scheduled task):

```cfc
getInstance( "CloudScraper@cbcloudscraper" ).warmup();
```

**Updating.** `box update cbcloudscraper` bumps the module. The cached binary records which
release it came from, so the next request automatically fetches the binary that matches the
new module version — nothing to clear by hand.

## Usage

Inject the model and call `get` or `post`:

```cfc
component {

    property name="scraper" inject="CloudScraper@cbcloudscraper";

    function getWebpage( required string licenseNumber ){
        var result = scraper.get( "https://example.com/" );

        if ( !result.ok ) {
            throw( message = "Lookup failed: " & result.errorDetail );
        }
        if ( result.statusCode != 200 ) {
            throw( message = "Unexpected status: " & result.statusCode );
        }

        return result.fileContent; // the page HTML
    }

}
```

POST a form (a struct is sent as `application/x-www-form-urlencoded`):

```cfc
var result = scraper.post(
    url  = "https://example.com/search",
    body = { "lastName" : "Smith" }
);
```

Pass options as the last argument:

```cfc
var result = scraper.get(
    url     = "https://example.com",
    options = {
        "engine"      : "curl_cffi",   // auto | curl_cffi | cloudscraper
        "impersonate" : "chrome131",   // browser profile for curl_cffi
        "timeout"     : 45,            // seconds
        "headers"     : { "Accept-Language" : "en-US" },
        "throwOnError": true           // throw on operational failures instead of returning ok=false
    }
);
```

### The result struct

Shaped to feel like a `cfhttp` result. A 4xx or 5xx response from the site is **not** an
error; it comes back with `ok=true` and the real `statusCode`.

| Key | Meaning |
| --- | --- |
| `ok` | `true` when the request completed at the network level. `false` only for an operational failure (binary unavailable, timeout, unreadable output). |
| `statusCode` | HTTP status code (`0` when `ok` is false). |
| `statusText` | HTTP status reason. |
| `fileContent` | The response body, decoded to text. |
| `fileContentAsBinary` | The response body as raw bytes (for images, PDFs, etc.). |
| `charset` | The character set used to decode the body. |
| `headers` | Case-insensitive struct of headers (last value wins). |
| `rawHeaders` | Array of `{name, value}` preserving duplicates, including every `Set-Cookie`. |
| `cookies` | Array of cookie structs, including Cloudflare's `cf_clearance` when present. |
| `finalUrl` | The URL after redirects. |
| `engineUsed` | `curl_cffi` or `cloudscraper`. |
| `executionTime` | Milliseconds spent, measured in CFML. |
| `errorDetail` | Human-readable message when `ok` is false. |

## Reusing Cloudflare clearance cookies

Cloudflare hands out a `cf_clearance` cookie after a client passes. Because each request is a
separate process, that cookie is normally lost between calls. Turn on the cookie cache to
store it on disk (one file per site) and reuse it on the next call to the same site:

```cfc
// config/ColdBox.cfc
moduleSettings = {
    cbcloudscraper : {
        cookieCache : { enabled : true }
    }
};
```

Manage stored cookies through the model: `clearCookies( domain )`, `clearAllCookies()`,
`getCookies( domain )` on `CookieJar@cbcloudscraper`.

## Offline and locked-down servers

The binary download needs outbound HTTPS to GitHub. On a server that cannot reach GitHub,
place the binary yourself and point the module at it:

1. Download `cbcloudscraper-win64.zip` from the module's GitHub Releases on a machine that
   can, and unzip it somewhere on the server.
2. In `config/ColdBox.cfc`, set the path and turn off the download:

```cfc
moduleSettings = {
    cbcloudscraper : {
        binaryPath         : "C:\tools\cbcloudscraper\cbcloudscraper.exe",
        autoDownloadBinary : false
    }
};
```

## Configuration

Override any of these in your app's `config/ColdBox.cfc` under
`moduleSettings.cbcloudscraper`:

| Setting | Default | Purpose |
| --- | --- | --- |
| `binaryPath` | `""` | Full path to an executable you provide. When set, the module uses it and never downloads. |
| `autoDownloadBinary` | `true` | Download the binary from GitHub Releases when it is missing. Set `false` to require a pre-placed binary. |
| `binaryDirectory` | `""` (the module's `bin/` folder) | Where the downloaded binary is cached. Override when the module folder is read-only. |
| `binaryBaseURL` | `""` (derived from `repository.url`) | Where per-platform binary assets are fetched from. |
| `binaryReleaseTag` | `""` (derives `v` + version) | Pin the release tag the binary is fetched from. |
| `verifyChecksum` | `true` | Verify the download's SHA-256 before using it. |
| `defaultTimeout` | `30` | Request timeout in seconds. |
| `defaultEngine` | `"auto"` | `auto`, `curl_cffi`, or `cloudscraper`. |
| `engineOrder` | `["curl_cffi","cloudscraper"]` | Order tried in `auto` mode. |
| `impersonate` | `"chrome"` | curl_cffi browser profile. |
| `followRedirects` | `true` | Follow HTTP redirects. |
| `verifySSL` | `true` | Verify TLS certificates. |
| `defaultHeaders` | `{}` | Headers added to every request. |
| `defaultCharset` | `"utf-8"` | Fallback when the site does not name a character set. |
| `proxy` | `""` | Proxy URL, for example `http://user:pass@host:8080`. |
| `workingDirectory` | `<system temp>/cbcloudscraper` | Where per-request temp files are written. |
| `keepFailureLogs` | `false` | Keep the diagnostic log when a request fails. |
| `tempSweepMinutes` | `30` | Remove leftover temp files older than this. |
| `cookieCache` | `{ enabled:false, directory:"" }` | On-disk cookie storage (see above). |
| `maxConcurrentProcesses` | `8` | Cap on executables running at once (`0` = no cap). |
| `acquireTimeout` | `20` | Seconds to wait for a free process slot. |
| `throwOnError` | `false` | Module-wide default for throwing on operational failures. |

## Verifying against your target

The decisive test is your actual target site. Build the binary locally (see below), then:

```powershell
powershell -ExecutionPolicy Bypass -File build\smoke-test.ps1 -Url https://your-target-site.gov/lookup
```

- Status `200` with real page content: this module works for that site.
- Status `403`/`503`, or a body containing a Cloudflare challenge: the site likely uses an
  interactive challenge, and you will need a browser-based engine as described above.

## For maintainers

Consumers never build anything. These steps are only for maintaining and releasing the
module.

### Rebuilding the binary

You only rebuild when updating the pinned Python libraries (for example bumping `curl_cffi`,
or swapping `cloudscraper` for the heavier `cloudscraper25` fork). Requires Python 3.11+ on
Windows.

```powershell
powershell -ExecutionPolicy Bypass -File build\build-binary.ps1
```

This creates a Python virtual environment, installs the pinned dependencies from
`engine/requirements.txt`, records the exact resolved versions in
`engine/requirements.lock.txt`, and produces `bin\win64\cbcloudscraper.exe`. The
request/response file format is the stable boundary between the CFML code and the binary, so
a library update needs no CFML changes.

### Releasing

Releases run locally with the vendored [`build-template`](build/) kit. Write your notes under
`[Unreleased]` in `changelog.md`, then:

```bash
box run-script bump:patch      # or bump:minor / bump:major
git commit -am "Release vX.Y.Z"
powershell -ExecutionPolicy Bypass -File build\release.ps1
```

`build\release.ps1` builds the Windows binary, then runs the kit's `release` (tests, the
pure-source package, ForgeBox publish, git tag, and the GitHub Release), then attaches
`cbcloudscraper-win64.zip` + its `.sha256` to that Release — which is what consumers download
on first use. Check readiness first with `box run-script release:check`.

### Testing

Most tests inject a mock runner, so they run on any engine and operating system with no
network and no binary. One live test uses the locally built binary and is skipped when it is
not present.

```bash
box install
cd test-harness && box install && cd ..
box server start serverConfigFile=server-lucee@5.json
box testbox run
```

## License

Apache 2.0 (see [LICENSE](LICENSE)). The bundled Python libraries `curl_cffi` and
`cloudscraper` are MIT licensed.
