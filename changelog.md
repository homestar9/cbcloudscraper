# Changelog

All notable changes to this project are written down here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-11

### Added

- First release. Make HTTP requests through Cloudflare protection from a ColdBox
  application by injecting `CloudScraper@cbcloudscraper` and calling `get()` or `post()`.
- Two engines bundled in one executable: `curl_cffi` (presents a real browser's TLS
  fingerprint, tried first) and `cloudscraper` (solves Cloudflare's legacy JavaScript
  challenge). Choose one or let the module pick automatically.
- The Windows executable is downloaded from GitHub Releases on first use and cached, so
  installing needs no Python and no build step. The `binaryPath` and `autoDownloadBinary`
  settings cover servers with no outbound internet access.
- Optional on-disk cookie cache to reuse Cloudflare clearance cookies between calls.
- A cfhttp-style result struct, with per-request options for engine, timeout, headers,
  proxy, redirects, TLS verification, and browser profile.
