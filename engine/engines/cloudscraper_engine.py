"""Secondary engine: cloudscraper.

cloudscraper solves Cloudflare's JavaScript challenge (the "Checking your browser
before you access" interstitial). It runs after curl_cffi in "auto" mode, as a
fallback for sites that answer with that specific challenge.

The imported package is cloudscraper25, the maintained fork of the original
cloudscraper. We alias it to `cloudscraper` so the rest of this module and the public
engine name stay unchanged. The public engine identifier remains "cloudscraper"
(see NAME below), which keeps the CFML config, docs, and result `engineUsed` value
stable regardless of the pip package name.
"""
import base64

import cloudscraper25 as cloudscraper

from .common import (
    CHUNK_BYTES,
    as_bool,
    cookiejar_to_list,
    detect_charset,
    headers_to_list,
    receive_body,
)

NAME = "cloudscraper"


def fetch(request, cookies):
    """Perform one HTTP request and return a normalized result dict."""
    scraper = cloudscraper.create_scraper(
        browser={"browser": "chrome", "platform": "windows", "mobile": False}
    )

    for cookie in cookies:
        try:
            scraper.cookies.set(
                cookie["name"],
                cookie["value"],
                domain=cookie.get("domain") or None,
                path=cookie.get("path") or "/",
            )
        except Exception:
            pass

    body_b64 = request.get("bodybase64") or ""
    data = base64.b64decode(body_b64) if body_b64 else None
    proxy = request.get("proxy") or ""
    proxies = {"http": proxy, "https": proxy} if proxy else None

    # This engine deliberately does not ask for a streamed response. cloudscraper reads
    # resp.text on every response to look for a challenge, which loads the whole body
    # into memory before this code ever sees it. Asking for a stream would save nothing
    # and would only put the challenge-solving path at risk. Writing the body to a file
    # still skips the base64 encoding, the JSON round trip, and both CFML decodes.
    download_wanted = bool((request.get("downloadto") or "").strip())

    response = scraper.request(
        (request.get("method") or "GET").upper(),
        request["url"],
        headers=request.get("headers") or {},
        data=data,
        timeout=request.get("timeoutseconds") or 30,
        verify=as_bool(request.get("verifyssl"), True),
        allow_redirects=as_bool(request.get("followredirects"), True),
        proxies=proxies,
    )

    # iter_content() on a response that was already read hands back slices of the bytes
    # it kept, so the shared download code works here without a special case. The chunk
    # size matters: requests defaults it to one byte.
    chunks = response.iter_content(chunk_size=CHUNK_BYTES) if download_wanted else None
    outcome = receive_body(response, request, chunks)

    # Detect the character set from the peek, because the body is empty after a
    # download was written to disk.
    charset = detect_charset(
        response.headers.get("Content-Type", ""),
        outcome["head"] or outcome["body"],
        request.get("defaultcharset", "utf-8"),
    )

    return {
        "ok": True,
        "statusCode": response.status_code,
        "statusText": getattr(response, "reason", "") or "",
        "finalUrl": str(response.url),
        "engineUsed": NAME,
        "headers": headers_to_list(response),
        "cookies": cookiejar_to_list(scraper.cookies),
        "bodyBytes": outcome["body"],
        "bodyCharset": charset,
        "downloadedTo": outcome["downloadedTo"],
        "bytesWritten": outcome["bytesWritten"],
        "error": None,
    }
