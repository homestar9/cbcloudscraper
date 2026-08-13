# Changelog

This file lists the important changes in each cbcloudscraper release.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added a `downloadTo` request option that writes a response body straight to a file. The helper
  program writes the body to the path you give it a piece at a time, so the whole body is never
  held in memory at once. Without this option, a body is
  copied several times before your code sees it: the helper holds all of it in memory,
  base64-encodes it into a file on disk, and CFML reads that file back, decodes the bytes, and
  builds a text copy on top. For a 12 MB file that costs about 60 MB of short-lived heap. With
  `downloadTo`, none of those copies happen. This needs the 1.1.0 helper program; an older helper
  still works, but the module has to write the file itself and the savings do not apply.
- Added a `downloadOnlyOn2xx` request option, default `true`. The target file is replaced only when
  the site returns a 2xx status, so an error page cannot overwrite a file that downloaded
  successfully on an earlier run. Set it to `false` for `cfhttp` behavior. A Cloudflare block page
  is never written to the target file, whatever this option says.
- Added `downloadedTo` and `bytesWritten` to the result struct. Both are present on every result,
  including failures, so the shape stays the same.
- Added a `decodeText` request option, default `true`. Set it to `false` to skip building the text
  copy of the body in `fileContent`. This is for callers that read an image, a PDF, or any other
  binary response through `fileContentAsBinary`, where the text copy can double the heap cost for
  nothing.
- Added a `defaultDownloadTimeout` module setting, default 300 seconds. It replaces `defaultTimeout`
  when a request sets `downloadTo` and does not set its own `timeout`.
- Added a `downloadOnlyOn2xx` module setting so an application can change the default for every
  request instead of passing the option on every call.
- Added `test` and `test:python` scripts to `box.json`.
- Added unit tests for the helper program in `engine/tests/`, using Python's built-in `unittest`.
  They cover the download logic and need no network connection and no built binary. Run them with
  `box run-script test:python`.

### Changed

- Dropped support for Lucee 5, which has reached end of life. The lowest supported Lucee version
  is now Lucee 6, which is also the default engine for local development.
- Dropped the plain BoxLang engine from the test matrix. BoxLang is still tested in CFML mode,
  which is how the module is meant to run there.
- The release now runs its tests on Adobe ColdFusion 2023 instead of Lucee 5. The full engine
  matrix still runs on Lucee 6, Adobe 2023, Adobe 2025, and BoxLang CFML.
- The helper program now writes `downloadedTo` and `bytesWritten` on every response, which is how
  the module tells a current helper from an older one.
- `build\smoke-test.ps1` runs a second phase that downloads to a file and checks the result.
- Moved the shared `makeDirectory()` helper into a new `FileUtil` model. `CookieJar` and
  `CloudScraper` use it. `ModuleConfig.cfc` and `BinaryDownloader.cfc` keep their own copies,
  because `onLoad()` runs before models exist and the CommandBox task builds `BinaryDownloader`
  without WireBox.

### Fixed

- The helper program now reads the `verifySSL` and `followRedirects` request values by name instead
  of passing them straight to Python. A CFML engine that serialized a boolean as the text `"false"`
  would have turned it into `true`, because Python treats any non-empty text as true. No supported
  engine does this today, so nothing was broken in practice.

## [1.0.1] - 2026-08-12

### Fixed

- Fixed a compile error that stopped the module from loading on Adobe ColdFusion.
  `directoryCreate()` was called with Lucee-only arguments, and Adobe ColdFusion rejects the
  extra arguments when it compiles the file. Because ColdBox could not register the module, the
  whole host application failed to start. Directories are now created with
  `java.io.File.mkdirs()`, which behaves the same on every engine.
- Fixed the first binary download on Lucee. A private method named `writeLog()` collided with
  the built-in CFML function, so downloading the helper failed before it started. The method is
  now named `logMessage()`.
- Fixed checksum verification during a fresh download. The `verifyChecksum` argument shadowed
  the private method with the same name, so the verification call failed. The method is now
  named `assertChecksum()`.
- Fixed the CommandBox binary task's `install` and `update` actions on Lucee. A local variable
  named `url` resolved to the URL scope instead of the variable. The variable is now named
  `releaseBaseURL`.
- Fixed a second Adobe ColdFusion 2023 failure: `sweepTempFiles()` used a dynamic expression as
  an argument default value, which Adobe ColdFusion 2023 cannot compile. The whole `CloudScraper`
  model failed to load. The default is now resolved inside the method body.
- Fixed request options on Adobe ColdFusion. Adobe's `?:` operator treats a boolean `false` value
  like a missing value. A default of `false` (such as `throwOnError`) became an empty string, and
  every request that failed then threw a boolean conversion error instead of returning `ok=false`.
  Setting `autoDownloadBinary=false` or `verifyChecksum=false` was also silently ignored on Adobe
  for the same reason. All affected fallbacks now use explicit key checks.
- Fixed a helper process leak. A helper could keep running when the CFML engine interrupted the
  request thread. This can happen when the server times out a request or an administrator cancels
  it. `ProcessRunner` now checks the helper process from a `finally` block and stops it when
  needed. This prevents a helper from running after the request releases its process slot.
- Closed the helper process's unused standard input stream as soon as the process starts. The
  operating system previously kept the stream handle open until the JVM removed the process
  object from memory. A busy server could leave many of these handles open.

### Changed

- The binary download now reports a warning through its progress callback when the published
  `.sha256` checksum file cannot be fetched or read. The download still continues, but the
  skipped verification is no longer silent.
- A failed request now returns `fileContentAsBinary` as an empty byte array instead of an empty
  string, so the value has the same type in every result.
- Renamed the binary download progress-callback argument from `log` to `onProgress`. The old
  name matched the built-in `log()` function. This affects code that calls
  `BinaryDownloader.ensure()` directly with named arguments.
- Temporary-file cleanup can now run more than once. Cleanup previously ran only when the
  `CloudScraper` model loaded during application startup. A server that stayed online could not
  remove files left by later interrupted requests. After each request, the module now checks
  whether `tempSweepMinutes` have passed since the last cleanup. Set `tempSweepMinutes` to `0` to
  clean temporary files only at startup.

### Removed

- Removed the unused `engineOrder` setting. The module never read it, and the helper decides the
  `auto` engine order internally. The setting was never listed in the README.

### Documentation

- Documented that `statusCode` in the result struct is a number, while `cfhttp` returns a string
  such as `"200 OK"`.
- Added a README section about deploying to a server: provisioning the helper during a deploy,
  setting an explicit `workingDirectory` in production, and the shared temporary-directory
  default.
- Listed the valid `impersonate` values and linked the full `curl_cffi` list.
- Documented that `timeout` covers the whole request, and that the module stops the helper
  process 5 seconds after the limit.
- Documented that a hand-copied helper binary has no version stamp and is never replaced
  automatically.
- Documented that adding the module to a running application needs a full server restart, not a
  framework reinit.
- Added a README section about running requests at the same time. The section explains process
  limits, helper-process memory use, cookie-cache locks, and when to update the helper.
- Added a README section about crawling sites that use JavaScript. The section explains what
  `fileContent` contains and why links created by browser-side JavaScript are not included.

## [1.0.0] - 2026-08-11

### Added

- Added `CloudScraper@cbcloudscraper` for sending GET and POST requests from a ColdBox
  application.
- Added the `curl_cffi` engine. It sends requests with the TLS fingerprint of a real browser.
- Added the `cloudscraper` fallback engine for Cloudflare JavaScript challenges. It uses the
  maintained `cloudscraper25` Python package internally, while the public engine name stays
  `cloudscraper`, so settings, request options, and `engineUsed` checks are unaffected.
- Added `auto` mode. It tries `curl_cffi` first and then tries `cloudscraper` when needed.
- Added automatic download and storage of the Windows helper program. Application servers do
  not need Python or a local build step.
- Added settings for servers that need a custom helper path or cannot download files from
  GitHub.
- Added an optional cookie cache. It lets later requests reuse Cloudflare clearance cookies and
  other response cookies.
- Added a result struct that is similar to a `cfhttp` result.
- Added request options for the engine, timeout, headers, proxy, redirects, TLS checks, and
  browser fingerprint.
