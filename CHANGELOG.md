# Changelog

This file lists the important changes in each cbcloudscraper release.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Fixed a helper process leak. A helper could keep running when the CFML engine interrupted the
  request thread. This can happen when the server times out a request or an administrator cancels
  it. `ProcessRunner` now checks the helper process from a `finally` block and stops it when
  needed. This prevents a helper from running after the request releases its process slot.
- Closed the helper process's unused standard input stream as soon as the process starts. The
  operating system previously kept the stream handle open until the JVM removed the process
  object from memory. A busy server could leave many of these handles open.

### Changed

- Temporary-file cleanup can now run more than once. Cleanup previously ran only when the
  `CloudScraper` model loaded during application startup. A server that stayed online could not
  remove files left by later interrupted requests. After each request, the module now checks
  whether `tempSweepMinutes` have passed since the last cleanup. Set `tempSweepMinutes` to `0` to
  clean temporary files only at startup.

### Documentation

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
