"""Primary engine: curl_cffi.

curl_cffi makes HTTP requests through a real browser's TLS and HTTP/2 fingerprint
(the "impersonate" profile). This defeats Cloudflare blocks that reject clients based
on the TLS handshake, which plain Python HTTP libraries cannot pass.
"""
import base64

from curl_cffi import requests as cc_requests

from .common import as_bool, cookiejar_to_list, detect_charset, headers_to_list, receive_body

NAME = "curl_cffi"


def fetch(request, cookies):
    """Perform one HTTP request and return a normalized result dict."""
    impersonate = request.get("impersonate") or "chrome"
    session = cc_requests.Session()

    for cookie in cookies:
        try:
            session.cookies.set(
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

    # Stream file downloads so the full body is not stored in memory.
    download_wanted = bool((request.get("downloadto") or "").strip())

    response = session.request(
        (request.get("method") or "GET").upper(),
        request["url"],
        headers=request.get("headers") or {},
        data=data,
        impersonate=impersonate,
        timeout=request.get("timeoutseconds") or 30,
        verify=as_bool(request.get("verifyssl"), True),
        allow_redirects=as_bool(request.get("followredirects"), True),
        proxies=proxies,
        stream=download_wanted,
    )

    try:
        # curl_cffi ignores chunk_size and logs a warning when it is passed.
        chunks = response.iter_content() if download_wanted else None
        outcome = receive_body(response, request, chunks)
    finally:
        if download_wanted:
            # In stream mode, close() stops curl_cffi's transfer thread and releases
            # its copied curl handle. Without close(), the worker may not exit.
            response.close()

    content_type = response.headers.get("Content-Type", "") if response.headers else ""
    # A file download has an empty body, so detect its character set from the saved first chunk.
    charset = detect_charset(
        content_type,
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
        "cookies": cookiejar_to_list(session.cookies),
        "bodyBytes": outcome["body"],
        "bodyCharset": charset,
        "downloadedTo": outcome["downloadedTo"],
        "bytesWritten": outcome["bytesWritten"],
        "error": None,
    }
