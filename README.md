# cbCloudscraper

![cbCloudscraper](https://github.com/homestar9/cbcloudscraper/blob/master/cbcloudscraper-logo.avif?raw=true)

cbCloudscraper lets a ColdBox application make HTTP requests to websites protected by Cloudflare.
It returns a CFML struct that is similar to a `cfhttp` result.

The module is useful when a normal `cfhttp` request is blocked because it does not look like a
request from a web browser.

## Important Limitations

cbcloudscraper can pass some Cloudflare checks, but it cannot pass every challenge.

The module works best when Cloudflare checks the TLS or HTTP/2 fingerprint of the client. A
fingerprint is the set of network details that identifies how a browser connects to a server.
The module can also handle some JavaScript challenge pages.

The module does not run a full browser. It may fail when a site requires a modern interactive
challenge, such as a Turnstile widget or a managed challenge that expects a real person. In that
case, the result may contain status `403`, `429`, or `503`. The response body may also contain a
Cloudflare challenge page instead of the page you wanted.

A managed challenge can still succeed. One production application uses this module to download a
public file from `roc.az.gov`. That site uses a Cloudflare managed challenge. The request returns a
12 MB CSV file with HTTP status 200 through `curl_cffi`, without using the fallback engine. The
request takes about 3.0 seconds without a stored cookie. It takes about 1.6 seconds after the
application stores and reuses the `cf_clearance` cookie.

These results apply only to this site and test. Cloudflare can change its challenge at any time.
Test the module with your target site before using it in production.

## Requirements

- ColdBox 8
- Lucee 6+, Adobe ColdFusion 2023 or 2025, or BoxLang
- Windows (for now)

The current release needs no extra Adobe ColdFusion packages. Adobe ColdFusion provides `cfzip` in
an optional `zip` package. This module uses Java instead, so it works on a default Adobe ColdFusion
install. Version 1.1.0 and earlier require `cfpm install zip`. Install that package or update the
module if you use one of those versions.

The project currently publishes only a Windows version of the required binary. If you want to help me test with Linux or MacOS, please contact me.

## Installation

Install the ForgeBox package from your application directory:

```bash
box install cbcloudscraper
```

You can also install the module from its GitHub repository:

```bash
box install homestar9/cbcloudscraper
```

When you add the module to an application that is already running, restart the server fully.
A framework reinit (`?fwreinit=1`) is not enough to register a new module and can leave the
application unable to serve requests until the next restart.

The first request downloads the helper program from the matching GitHub Release. The module
checks the download and stores it in the module's `bin/` directory. Later requests use the stored
copy.

Your server needs outbound HTTPS access to GitHub for this first download. See
[Use the module without GitHub access](#use-the-module-without-github-access) if your server
cannot reach GitHub.

## Make a GET request

Inject `CloudScraper@cbcloudscraper`, then call `get()` with a URL:

```cfc
component {

    property name="scraper" inject="CloudScraper@cbcloudscraper";

    function loadPage(){
        var result = scraper.get( "https://example.com/" );

        if ( !result.ok ) {
            throw( message = "The request could not run: " & result.errorDetail );
        }

        if ( result.statusCode != 200 ) {
            throw( message = "The website returned HTTP " & result.statusCode );
        }

        return result.fileContent;
    }

}
```

Check both `ok` and `statusCode`. These values answer different questions:

- `ok` tells you whether the helper completed the HTTP request.
- `statusCode` tells you how the target website answered.

A website response such as `404` or `503` still has `ok=true` because the HTTP request completed.
A missing helper program, timeout, or unreadable response has `ok=false` and `statusCode=0`.
The second group is called an operational failure because the helper could not finish its work.

## How the request engines work

The helper program contains two request engines. An engine is the library that sends the HTTP
request.

- `curl_cffi` copies the TLS and HTTP/2 fingerprint of a real browser. The module tries this engine first.
- `cloudscraper` handles some Cloudflare JavaScript challenges. The module uses the maintained
  `cloudscraper25` Python package internally, but the public engine name stays `cloudscraper`.

The default engine is `auto`. In `auto` mode, the helper tries `curl_cffi` first. It then tries
`cloudscraper` when `curl_cffi` fails or returns a response that looks like a Cloudflare
challenge.

You can choose one engine for a request:

```cfc
var result = scraper.get(
    url     = "https://example.com/",
    options = { engine : "curl_cffi" }
);
```

Choosing one engine turns off the automatic fallback for that request.

## Crawling and JavaScript

`fileContent` contains the response body decoded as text. The module does not build or display
the page like a browser.

The `cloudscraper` engine can run JavaScript from some Cloudflare challenges. It uses `js2py`, a
JavaScript interpreter written in Python. The interpreter only solves the Cloudflare challenge.
It does not provide a page layout engine, a document object model (DOM), or browser APIs. This
means it cannot run the website's application code like a browser. The `curl_cffi` engine does
not run JavaScript.

The module returns the response text, but it does not extract links for you. The following table
shows which links your code can find in `fileContent`:

| What you want to find | Is it available in `fileContent`? |
| --- | --- |
| `<a href>` links written by the web server | Yes |
| `<script src>` and other tag attributes | Yes |
| URLs written inside inline `<script>` text | Yes. Your code can search the text with a regular expression. |
| Links that a React, Vue, or Angular application creates while the page runs | No |
| URLs that the page loads later through a background request | No |

If your target site builds its content in the browser, open the site once in your browser's
developer tools. Open the Network tab and find the request that returns the page data. The data
is often JSON. Then use this module to request that URL directly. A direct data request is faster
and is less likely to fail when the site's page layout changes.

If you need the page after its JavaScript runs, use a tool that runs a real browser, such as
Playwright, FlareSolverr, or nodriver.

## Request methods

### `get( url, options={} )`

Sends a GET request.

```cfc
var result = scraper.get( "https://example.com/" );
```

### `post( url, body="", options={} )`

Sends a POST request. The body can be a string, a binary value, or a struct of form fields.

A struct is encoded as `application/x-www-form-urlencoded`:

```cfc
var result = scraper.post(
    url  = "https://example.com/search",
    body = {
        lastName : "Smith",
        state    : "CA"
    }
);
```

Pass a string when the target expects JSON or another text format. Set the matching content type
in the request headers:

```cfc
var result = scraper.post(
    url     = "https://example.com/api/search",
    body    = serializeJSON( { lastName : "Smith" } ),
    options = {
        headers : { "Content-Type" : "application/json" }
    }
);
```

A binary body is sent without changing its bytes.

### `warmup()`

`warmup()` makes sure the helper program is installed. It does not send an HTTP request. Use it
during deployment or application startup when you do not want the first real request to wait for
the download.

```cfc
getInstance( "CloudScraper@cbcloudscraper" ).warmup();
```

The method returns the full path to the helper program. It throws an exception if the helper
cannot be found or downloaded.

## Request options

Pass request options in the last argument to `get()` or `post()`:

```cfc
var result = scraper.get(
    url     = "https://example.com/",
    options = {
        engine         : "auto",
        impersonate    : "chrome131",
        timeout        : 45,
        headers        : { "Accept-Language" : "en-US" },
        followRedirects: true,
        verifySSL      : true,
        proxy          : "http://user:pass@proxy.example.com:8080",
        useCookieCache : true,
        throwOnError   : false
    }
);
```

| Option | Default | What it does |
| --- | --- | --- |
| `engine` | `"auto"` | Chooses `auto`, `curl_cffi`, or `cloudscraper`. |
| `impersonate` | `"chrome"` | Chooses the browser fingerprint used by `curl_cffi`. See the list of values below. |
| `timeout` | `30` | The maximum time for the whole request in seconds, not just the connection. The module stops the helper process 5 seconds after this limit. |
| `headers` | `{}` | Adds request headers. A request header replaces a default header with the same name. |
| `followRedirects` | `true` | Follows HTTP redirects. |
| `verifySSL` | `true` | Checks the target site's TLS certificate. |
| `proxy` | `""` | Sends the request through this proxy URL. An empty string means no proxy. |
| `useCookieCache` | `true` | Uses stored cookies for this request when the module cookie cache is enabled. |
| `throwOnError` | `false` | Throws on an operational failure instead of returning `ok=false`. |
| `downloadTo` | `""` | Writes the response body to this file instead of returning it in memory. Must be a full path. See [Download a large file](#download-a-large-file). |
| `downloadOnlyOn2xx` | `true` | With `downloadTo`, writes the file only when the status is 2xx. Set `false` to write an error page too, the way `cfhttp` does. |
| `decodeText` | `true` | Set `false` to skip decoding the body into `fileContent`. Use this for images, PDFs, and other binary responses you read through `fileContentAsBinary`. |

The module settings provide these defaults. See [Configuration](#configuration) to change them
for every request.

### `impersonate` values

The module passes the `impersonate` value to `curl_cffi` without changes, so the valid values
come from the bundled `curl_cffi` build (currently 0.16.0). The setting only affects the
`curl_cffi` engine.

- A bare browser name uses the newest fingerprint in the bundle: `chrome`, `edge`, `safari`,
  `firefox`, or `tor`.
- A versioned name pins one fingerprint, for example `chrome131`, `chrome99_android`, `edge101`,
  `safari184`, or `firefox135`.

See the [curl_cffi impersonation list](https://github.com/lexiforest/curl_cffi?tab=readme-ov-file#supported-browsers)
for every supported value. An unknown value makes the `curl_cffi` engine fail for that request.

## Result struct

Both request methods return the same struct.

| Key | Meaning |
| --- | --- |
| `ok` | `true` when an HTTP response was received. `false` when an operational failure stopped the request. |
| `statusCode` | The HTTP status code as a **number**, such as `200`. This differs from `cfhttp`, which returns a string such as `"200 OK"`. The value is `0` when `ok` is false. |
| `statusText` | The HTTP status reason, such as `OK` or `Not Found`. |
| `fileContent` | The response body decoded as text. This is an empty string when the body went to a file, and when `decodeText` was `false`. |
| `fileContentAsBinary` | The response body as raw bytes. Use this value for images, PDFs, and other binary files. This value is always a byte array; it has zero length when `ok` is false and when the body went to a file. |
| `charset` | The character set used to decode `fileContent`. |
| `headers` | A case-insensitive struct of response headers. The last value wins when a header appears more than once. |
| `rawHeaders` | An array of `{name, value}` structs. This array keeps repeated headers such as `Set-Cookie`. |
| `cookies` | An array of cookies returned by the request engine. |
| `finalUrl` | The final URL after redirects. |
| `engineUsed` | The engine that returned the response: `curl_cffi` or `cloudscraper`. |
| `downloadedTo` | The path written by `downloadTo`. Empty when no file was written. The path always uses forward slashes. On Windows, replace the backslashes in an `expandPath()` result before comparing the paths. |
| `bytesWritten` | How many bytes went into that file. `0` when no file was written. |
| `downloadStreamed` | `true` only when the helper wrote the file directly without returning the full body to CFML. `false` when no file was written or an old helper returned the full body to CFML. See [Download a large file](#download-a-large-file). |
| `executionTime` | The total request time measured by CFML, in milliseconds. |
| `errorDetail` | A description of the operational failure. This value is empty when `ok` is true. |

`throwOnError=true` changes only operational failures. HTTP responses such as `404` and `503`
still return a result struct.

## Download a large file

Set the `downloadTo` option to a full file path. The helper writes the response body straight to
that path, a piece at a time, so the whole body is never held in memory at once.

```cfc
var result = scraper.get(
    url     = "https://example.com/licenses.csv",
    options = { downloadTo : "C:/data/licenses.csv" }
);

if ( result.ok && len( result.downloadedTo ) ) {
    writeOutput( "Saved #result.bytesWritten# bytes to #result.downloadedTo#" );
}
```

Without this option, a response body is copied several times before your code sees it: the helper
holds the whole body in memory, base64-encodes it into a file on disk, and CFML reads that file
back, decodes the bytes, and builds a text copy on top. For a 12 MB file that costs about 60 MB of
short-lived heap. With `downloadTo`, none of those copies happen.

**The path must be absolute.** A relative path means something different on each CFML engine and
operating system, so the module rejects it and throws `cbcloudscraper.InvalidOption`. Call
`expandPath()` yourself if you need to turn an application-relative path into a full one. Missing
parent directories are created for you.

**The timeout default is higher.** A request with `downloadTo` uses the `defaultDownloadTimeout`
setting (300 seconds) instead of `defaultTimeout` (30 seconds). An explicit `timeout` option still
wins over both. With `downloadTo`, the `timeout` value stops meaning "total time for the request."
It becomes the time allowed to connect, and the time the transfer may sit stalled before it gives
up. A large download is not stopped just for being large. The module still stops the helper
process 5 seconds after the timeout, so that number is the real ceiling on how long one request
can run.

**A long download holds a process slot the whole time.** The `maxConcurrentProcesses` setting
limits how many helper processes run at once. A 5 minute download occupies one of those slots for
5 minutes, so other requests can fail with `cbcloudscraper.Busy` once they wait longer than
`acquireTimeout`. Raise `maxConcurrentProcesses`, or run large downloads on a schedule when the
application is quiet.

**Nothing is written unless the response is good.** By default the target file is only replaced
when the site returns a 2xx status. A 404 or a 500 leaves the existing file untouched,
`downloadedTo` is empty, and the error page comes back in `fileContent` so you can see what the
site said. Up to 64 KB of it is kept. Set `downloadOnlyOn2xx : false` to write the file for any
status, the way `cfhttp` does.

**A Cloudflare block page is never written to your file.** This holds even with
`downloadOnlyOn2xx : false`. The helper checks the start of the body before it writes anything, and
a block page is returned in memory instead so the next engine can try. Without this rule, a
nightly job could replace yesterday's good file with an HTML error page.

**The in-progress file.** While the download runs, the helper writes to a file named
`<your path>.cbcs-<id>.part` in the same directory as your target, then renames it onto the target
when the download finishes whole. Two things follow from that. Your target file is never half
written. And the module needs write access to the target's directory, not just to the file. If a
download fails, the module deletes the in-progress file. If the whole CFML process is killed
mid-download, the file is left behind, and the next download to the same target removes it once it
is over an hour old.

**A truncated download fails.** If the site sends a `Content-Length` header and fewer bytes
arrive, the helper reports an error and your target file is not touched. The module then tries the
next engine.

**An out-of-date helper still works but uses more memory.** An old helper does not support
`downloadTo`. It returns the full response body to CFML, and the module writes the file. The module
also logs a warning. This fallback writes files only for 2xx responses, even when
`downloadOnlyOn2xx` is `false`. The old helper cannot identify a Cloudflare block page before it
returns the response body. Update the helper to stream the file and support the configured
`downloadOnlyOn2xx` value.

Check `result.downloadStreamed` to identify the fallback. The value is `true` only when the helper
wrote the file directly. Test this value if your application must avoid holding the full response
body in CFML memory:

```cfc
var result = scraper.get( url = feedURL, options = { downloadTo : target } );

if ( result.ok && !result.downloadStreamed ) {
    // The download succeeded, but CFML held the full response body in memory.
    log.warn( "The cbcloudscraper helper program is out of date." );
}
```

## Install or update the helper before a request

The automatic first-request download is enough for most applications. You can also run the
included CommandBox task from your application directory.

Check the installed version without downloading anything:

```bash
box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=status
```

Download the helper now, even if the correct version is already installed:

```bash
box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install
```

Download only when the installed version is missing or out of date:

```bash
box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=update
```

The `update` action asks for confirmation before it downloads a missing or outdated helper.

When you run `box update cbcloudscraper`, the module version may change. The next request checks
the stored helper's release tag. The module downloads the matching helper when the tags do not
match.

## Deploy to a server

Most applications do not commit the `modules/` directory, so every production deploy starts
without the helper program. Without a deploy step, the first request after a deploy pays the
GitHub download — a problem when that request is an unattended scheduled task. Two ways to
provision the helper ahead of the first request:

1. Run the install task as part of the deploy, after `box install`:

   ```bash
   box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install
   ```

2. Or call `warmup()` from your application's startup code. It downloads the helper when needed
   and throws `cbcloudscraper.BinaryUnavailable` when it cannot, so a bad deploy fails at startup
   instead of at the first request.

Two more production recommendations:

- Set an explicit `workingDirectory`. The default lives under `java.io.tmpdir`, which changes
  with how the server process starts, and two applications on the same server share the same
  default directory.
- If your server cannot reach GitHub, see
  [Use the module without GitHub access](#use-the-module-without-github-access).

## Use the module without GitHub access

Download `cbcloudscraper-win64.zip` from the matching GitHub Release on a computer that can
reach GitHub. Copy the extracted folder to the server. Then point the module at the extracted
`cbcloudscraper.exe` file:

```cfc
// config/ColdBox.cfc
moduleSettings = {
    cbcloudscraper : {
        binaryPath         : "C:\tools\cbcloudscraper\cbcloudscraper.exe",
        autoDownloadBinary : false
    }
};
```

`binaryPath` always takes priority. The module does not download or update the helper when this
setting contains a path.

You can also unzip the release archive into the module's `bin/` directory instead of setting
`binaryPath`. A hand-copied helper has no version stamp file, so the module treats it as current
and never replaces it automatically. When you update the module, replace the helper by hand as
well.

## Checksum verification

Each release includes the helper archive and a `.sha256` checksum file. A SHA-256 checksum is a value
calculated from the contents of a file. The module calculates the archive's checksum and compares it
with the published value. If the values differ, the module deletes the archive and throws
`cbcloudscraper.BinaryUnavailable`. The `verifyChecksum` setting enables this check by default.

The `strictChecksum` setting controls what happens when the `.sha256` file cannot be read:

- **`strictChecksum : false`, the default.** The module logs a warning and installs the helper
  without verifying it.
- **`strictChecksum : true`.** The module deletes the downloaded archive and throws
  `cbcloudscraper.BinaryUnavailable`.

Set `strictChecksum` to `true` if the module must never install an unverified helper. The install
will also stop when the checksum file is missing or cannot be downloaded.

```cfc
// config/ColdBox.cfc
moduleSettings = {
    cbcloudscraper : {
        verifyChecksum : true,
        strictChecksum : true
    }
};
```

The `Binary.cfc` task takes the same option as a flag:

```bash
box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install :strict=true
```

## Store cookies between requests

Each HTTP request starts a new helper process. Without a cookie cache, cookies from one request
are not available to the next request.

Enable the cookie cache in `config/ColdBox.cfc`:

```cfc
moduleSettings = {
    cbcloudscraper : {
        cookieCache : {
            enabled : true
        }
    }
};
```

The cache stores response cookies in one file per domain. Stored cookies can include
Cloudflare's `cf_clearance` cookie. Later requests to the same domain send those cookies again.

You can turn off stored cookies for one request with `useCookieCache=false`.

Inject `CookieJar@cbcloudscraper` to inspect or clear stored cookies:

```cfc
component {

    property name="cookieJar" inject="CookieJar@cbcloudscraper";

    function clearExampleCookies(){
        return cookieJar.clearCookies( "example.com" );
    }

}
```

The cookie manager provides these methods:

- `getCookies( domain )` returns the stored cookies for one domain.
- `clearCookies( domain )` deletes the cookie file for one domain.
- `clearAllCookies()` deletes every stored cookie file.

## Run requests at the same time

You can call the module from several threads at the same time. Each call has its own request
state. Each temporary file name also contains a unique identifier, so calls do not share
temporary files.

`maxConcurrentProcesses` sets how many helper processes may run at the same time. The default is
`8`. Each allowed process is called a process slot. Before a thread starts a helper process, it
waits for an open slot. If no slot opens within `acquireTimeout` seconds, the module raises a
`cbcloudscraper.Busy` error. With the default error settings, the request returns `ok=false`.

```cfc
// config/ColdBox.cfc
moduleSettings = {
    cbcloudscraper : {
        maxConcurrentProcesses : 16, // More parallel requests.
        acquireTimeout         : 60  // Wait longer for a slot instead of failing.
    }
};
```

Keep these three limits in mind.

**Available memory limits the number of helper processes.** Each active request starts a separate
helper process with its own copy of the Python runtime. Plan for about 60 MB of memory for each
process. Set `maxConcurrentProcesses` low enough for the amount of memory that your server can
give to these processes.

**The cookie cache runs requests to the same domain one at a time.** When `cookieCache.enabled`
is `true`, requests to the same domain share one cookie file. The module locks that domain until
each request finishes. Requests to different domains can still run at the same time. A thread
gets a process slot before it waits for the domain lock. Waiting threads can therefore fill every
process slot and prevent requests to other domains from starting. Leave the cookie cache disabled
when you crawl one site in parallel. You can also set `useCookieCache=false` on those requests.

**Do not update the helper program while requests are running.** An update removes and recreates
the entire platform folder under `bin/`. A request can fail if the update changes these files
while the helper program starts or runs. The lock for an automatic first-request download does
not protect a manual update from the CommandBox task. Run
`box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=update` during a
maintenance window. You can also call `warmup()` during application startup so the download
finishes before the application accepts requests.

## Configuration

Add overrides under `moduleSettings.cbcloudscraper` in your application's
`config/ColdBox.cfc`.

| Setting | Default | What it does |
| --- | --- | --- |
| `binaryPath` | `""` | Uses an existing helper program at this full path. A value here disables automatic binary selection and downloads. |
| `binaryDirectory` | `""` | Stores downloaded helpers under this directory. An empty string uses the module's `bin/` directory. |
| `autoDownloadBinary` | `true` | Downloads a missing or outdated helper from the release server. |
| `binaryBaseURL` | `""` | Overrides the GitHub Releases download base URL. An empty string derives the URL from `box.json`. |
| `binaryReleaseTag` | `""` | Overrides the release tag used for the helper. An empty string uses `v` followed by the module version. |
| `verifyChecksum` | `true` | Checks the downloaded ZIP file against its published SHA-256 checksum when the checksum is available. |
| `strictChecksum` | `false` | Stops the install when the SHA-256 file cannot be read. The default logs a warning and installs the helper without verifying it. See [Checksum verification](#checksum-verification). |
| `defaultTimeout` | `30` | Sets the default HTTP timeout in seconds. |
| `defaultDownloadTimeout` | `300` | Used instead of `defaultTimeout` when a request sets `downloadTo` and does not set its own `timeout`. |
| `downloadOnlyOn2xx` | `true` | Sets the module-wide default for the `downloadOnlyOn2xx` request option. |
| `defaultEngine` | `"auto"` | Sets the default request engine. Valid values are `auto`, `curl_cffi`, and `cloudscraper`. |
| `impersonate` | `"chrome"` | Sets the default browser fingerprint for `curl_cffi`. |
| `followRedirects` | `true` | Sets whether requests follow HTTP redirects. |
| `verifySSL` | `true` | Sets whether requests check TLS certificates. |
| `defaultHeaders` | `{}` | Adds these headers to every request. Per-request headers can replace them. |
| `defaultCharset` | `"utf-8"` | Decodes response text with this character set when the website does not provide one. |
| `proxy` | `""` | Sets a default proxy URL. An empty string means no proxy. |
| `workingDirectory` | System temp directory plus `/cbcloudscraper` | Stores temporary request, response, log, and default cookie files. |
| `keepFailureLogs` | `false` | Keeps process log files instead of deleting them after each request. |
| `tempSweepMinutes` | `30` | Deletes temporary files older than this many minutes. The module cleans these files at startup. After each request, it checks whether this many minutes have passed since the last cleanup. Use `0` to disable cleanup after requests. |
| `cookieCache` | `{ enabled:false, directory:"" }` | Enables stored cookies and optionally changes their directory. An empty directory uses `workingDirectory/cookies`. |
| `maxConcurrentProcesses` | `8` | Limits how many helper processes can run at the same time. Use `0` for no limit. |
| `acquireTimeout` | `20` | Sets how many seconds a request waits for an open process slot. |
| `throwOnError` | `false` | Sets the module-wide default for throwing on operational failures. |

## Test your target site

The only reliable test is a request to the site you plan to use.

```cfc
var result = getInstance( "CloudScraper@cbcloudscraper" )
    .get( "https://your-target.example.com/" );

writeDump( {
    ok         : result.ok,
    statusCode : result.statusCode,
    engineUsed : result.engineUsed,
    finalUrl   : result.finalUrl,
    bodyStart  : left( result.fileContent, 500 )
} );
```

A `200` response with the expected page content means the module works for that request. A
Cloudflare block or challenge page means the site may require a full browser-based tool.

## Contributing

The test suite uses a mock helper for most tests, so most tests do not need a network connection
or a built binary. The project also has one live test that runs only when the Windows helper has
been built.

```bash
box install
cd test-harness && box install && cd ..
box run-script start:lucee6
box run-script test
```

The helper program has its own unit tests, written with Python's built-in `unittest`. They cover
the download logic and need no network connection and no built binary, so they are the fastest way
to check a change in `engine/`. They do need the virtual environment that `build\build-binary.ps1`
creates.

```bash
box run-script test:python
```

See [RELEASE.md](RELEASE.md) for binary build and release instructions.

## License

The project uses the Apache License 2.0. See [LICENSE](LICENSE).

The bundled `curl_cffi` and `cloudscraper25` libraries use the MIT License.
