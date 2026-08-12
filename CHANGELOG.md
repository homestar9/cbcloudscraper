# Changelog

This file lists the important changes in each cbcloudscraper release.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
