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

Test the module against your real target site before you depend on it in production.

## Requirements

- ColdBox 8
- Lucee 5 or 6, Adobe ColdFusion 2023 or 2025, or BoxLang
- Windows (for now)

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
| `impersonate` | `"chrome"` | Chooses the browser fingerprint used by `curl_cffi`. |
| `timeout` | `30` | Sets the HTTP timeout in seconds. |
| `headers` | `{}` | Adds request headers. A request header replaces a default header with the same name. |
| `followRedirects` | `true` | Follows HTTP redirects. |
| `verifySSL` | `true` | Checks the target site's TLS certificate. |
| `proxy` | `""` | Sends the request through this proxy URL. An empty string means no proxy. |
| `useCookieCache` | `true` | Uses stored cookies for this request when the module cookie cache is enabled. |
| `throwOnError` | `false` | Throws on an operational failure instead of returning `ok=false`. |

The module settings provide these defaults. See [Configuration](#configuration) to change them
for every request.

## Result struct

Both request methods return the same struct.

| Key | Meaning |
| --- | --- |
| `ok` | `true` when an HTTP response was received. `false` when an operational failure stopped the request. |
| `statusCode` | The HTTP status code. The value is `0` when `ok` is false. |
| `statusText` | The HTTP status reason, such as `OK` or `Not Found`. |
| `fileContent` | The response body decoded as text. |
| `fileContentAsBinary` | The response body as raw bytes. Use this value for images, PDFs, and other binary files. |
| `charset` | The character set used to decode `fileContent`. |
| `headers` | A case-insensitive struct of response headers. The last value wins when a header appears more than once. |
| `rawHeaders` | An array of `{name, value}` structs. This array keeps repeated headers such as `Set-Cookie`. |
| `cookies` | An array of cookies returned by the request engine. |
| `finalUrl` | The final URL after redirects. |
| `engineUsed` | The engine that returned the response: `curl_cffi` or `cloudscraper`. |
| `executionTime` | The total request time measured by CFML, in milliseconds. |
| `errorDetail` | A description of the operational failure. This value is empty when `ok` is true. |

`throwOnError=true` changes only operational failures. HTTP responses such as `404` and `503`
still return a result struct.

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
| `defaultTimeout` | `30` | Sets the default HTTP timeout in seconds. |
| `defaultEngine` | `"auto"` | Sets the default request engine. Valid values are `auto`, `curl_cffi`, and `cloudscraper`. |
| `impersonate` | `"chrome"` | Sets the default browser fingerprint for `curl_cffi`. |
| `followRedirects` | `true` | Sets whether requests follow HTTP redirects. |
| `verifySSL` | `true` | Sets whether requests check TLS certificates. |
| `defaultHeaders` | `{}` | Adds these headers to every request. Per-request headers can replace them. |
| `defaultCharset` | `"utf-8"` | Decodes response text with this character set when the website does not provide one. |
| `proxy` | `""` | Sets a default proxy URL. An empty string means no proxy. |
| `workingDirectory` | System temp directory plus `/cbcloudscraper` | Stores temporary request, response, log, and default cookie files. |
| `keepFailureLogs` | `false` | Keeps process log files instead of deleting them after each request. |
| `tempSweepMinutes` | `30` | Deletes leftover temporary files older than this many minutes when the model starts or a sweep runs. |
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
box server start serverConfigFile=server-lucee@5.json
box testbox run
```

See [RELEASE.md](RELEASE.md) for binary build and release instructions.

## License

The project uses the Apache License 2.0. See [LICENSE](LICENSE).

The bundled `curl_cffi` and `cloudscraper25` libraries use the MIT License.
