# Changelog

This file lists the important changes in each cbcloudscraper release.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
