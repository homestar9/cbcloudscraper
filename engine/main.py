#!/usr/bin/env python3
"""cbcloudscraper worker.

Reads one request from a JSON file, makes one HTTP request that tries to pass
Cloudflare protection, and writes the result to a JSON response file.

Usage:
    cbcloudscraper --request <path-to-request.json> --response <path-to-response.json>

The command line carries only these two file paths. The URL, headers, and body all
travel inside the request file, which avoids command-line length limits and quoting
problems. The response body is base64-encoded so it arrives byte-for-byte no matter
its character set, compression, or content.

A request can instead set "downloadto" to an absolute path. The body is then written
to that path in chunks and never base64-encoded, which is much cheaper for a large
file. The response reports the path in "downloadedTo" and the size in "bytesWritten",
and "bodyBase64" is empty.

Exit code:
    0  an HTTP response was received (any status, including 403 or 404).
    1  an operational failure (bad input, every engine errored, cannot write output).

Diagnostic text is printed only to stderr. The page body is never printed to stdout.
"""
import argparse
import base64
import json
import sys
import time

from cookiejar import load_cookies, save_cookies
from engines import cloudscraper_engine, curl_cffi_engine
from engines.common import CHALLENGE_STATUSES, head_has_challenge_marker

ENGINES = {
    curl_cffi_engine.NAME: curl_cffi_engine,
    cloudscraper_engine.NAME: cloudscraper_engine,
}

# Order used when the request asks for "auto": try the TLS-fingerprint engine first,
# then fall back to the JavaScript-challenge engine.
AUTO_ORDER = [curl_cffi_engine.NAME, cloudscraper_engine.NAME]


def log(message):
    """Write a diagnostic line to stderr (captured by the caller's log file)."""
    print("[cbcloudscraper] " + message, file=sys.stderr, flush=True)


def server_is_cloudflare(result):
    """Return True when the response's Server header names Cloudflare."""
    for header in result.get("headers", []):
        if header.get("name", "").lower() == "server":
            return "cloudflare" in header.get("value", "").lower()
    return False


def looks_like_challenge(result):
    """Return True when a response looks like a Cloudflare block worth retrying.

    A retry is only sensible when Cloudflare served the response. We treat the
    common blocking statuses as a challenge, and also scan the start of the body
    for known interstitial markers in case the block returns HTTP 200.
    """
    if result is None or not server_is_cloudflare(result):
        return False

    if result.get("statusCode", 0) in CHALLENGE_STATUSES:
        return True

    # bodyBytes is empty after a download was written to a file, and a download is only
    # written when the engine already ruled out a challenge, so there is nothing to scan.
    return head_has_challenge_marker(result.get("bodyBytes", b""))


def resolve_engine_order(request):
    """Return the ordered list of engine names to try for this request."""
    requested = (request.get("engine") or "auto").lower()
    if requested == "auto":
        return list(AUTO_ORDER)
    if requested in ENGINES:
        return [requested]
    # Unknown engine name: fall back to the full auto order rather than failing.
    log("unknown engine '%s'; using auto order" % requested)
    return list(AUTO_ORDER)


def run_request(request):
    """Try each selected engine in order and return the best result.

    Uses the first response that does not look like a Cloudflare challenge. If every
    engine returns a challenge (or errors), returns the last result obtained, or None
    when no engine produced any response at all.
    """
    cookie_path = request.get("cookiejarpath") or ""
    cookies = load_cookies(cookie_path)

    order = resolve_engine_order(request)
    last_result = None
    errors = []

    for name in order:
        engine = ENGINES[name]
        try:
            log("trying engine: " + name)
            result = engine.fetch(request, cookies)
        except Exception as exc:  # noqa: BLE001 - report any engine failure and try the next
            errors.append("%s: %s" % (name, exc))
            log("engine %s failed: %s" % (name, exc))
            continue

        last_result = result
        if not looks_like_challenge(result):
            _persist_cookies(cookie_path, result)
            return result, errors
        log("engine %s returned a Cloudflare challenge; trying next" % name)

    if last_result is not None:
        _persist_cookies(cookie_path, last_result)
    return last_result, errors


def _persist_cookies(cookie_path, result):
    if cookie_path and result and result.get("cookies"):
        save_cookies(cookie_path, result["cookies"])


def build_response(result, errors):
    """Convert an engine result into the JSON-serializable response structure."""
    body = result.get("bodyBytes", b"") or b""
    response = dict(result)
    response.pop("bodyBytes", None)
    response["bodyBase64"] = base64.b64encode(body).decode("ascii")
    if errors and not response.get("error"):
        # Keep a note of earlier engine failures even when a later engine succeeded.
        response["engineNotes"] = errors
    return response


def failure_response(message, errors):
    return {
        "ok": False,
        "statusCode": 0,
        "statusText": "",
        "finalUrl": "",
        "engineUsed": "",
        "timingMs": 0,
        "headers": [],
        "cookies": [],
        "bodyBase64": "",
        "bodyCharset": "utf-8",
        # Always present, so CFML can tell a current worker from an older one.
        "downloadedTo": "",
        "bytesWritten": 0,
        "error": {"type": "worker", "message": message, "engineNotes": errors},
    }


def write_response(path, payload):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)


def main(argv=None):
    parser = argparse.ArgumentParser(description="cbcloudscraper worker")
    parser.add_argument("--request", required=True, help="path to the request JSON file")
    parser.add_argument("--response", required=True, help="path to the response JSON file")
    args = parser.parse_args(argv)

    try:
        # utf-8-sig tolerates an optional byte-order mark that some callers add.
        with open(args.request, "r", encoding="utf-8-sig") as handle:
            request = json.load(handle)
    except Exception as exc:  # noqa: BLE001
        log("cannot read request file: %s" % exc)
        try:
            write_response(args.response, failure_response("cannot read request file: %s" % exc, []))
        except Exception:
            pass
        return 1

    # Normalize the top-level request keys to lowercase. Adobe ColdFusion uppercases
    # struct keys when it serializes JSON, while Lucee and BoxLang keep the original
    # case; lowercasing here makes the contract work the same way on every engine.
    # Only the top level is touched, so header names and the body value are unchanged.
    if isinstance(request, dict):
        request = {str(key).lower(): value for key, value in request.items()}

    started = time.time()
    try:
        result, errors = run_request(request)
    except Exception as exc:  # noqa: BLE001
        write_response(args.response, failure_response("unexpected worker error: %s" % exc, []))
        return 1

    elapsed_ms = int((time.time() - started) * 1000)

    if result is None:
        write_response(args.response, failure_response("all engines failed to return a response", errors))
        return 1

    payload = build_response(result, errors)
    payload["timingMs"] = elapsed_ms
    write_response(args.response, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
