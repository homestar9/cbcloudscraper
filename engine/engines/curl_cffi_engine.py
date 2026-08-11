"""Primary engine: curl_cffi.

curl_cffi makes HTTP requests through a real browser's TLS and HTTP/2 fingerprint
(the "impersonate" profile). This defeats Cloudflare blocks that reject clients based
on the TLS handshake, which plain Python HTTP libraries cannot pass.
"""
import base64

from curl_cffi import requests as cc_requests

from .common import cookiejar_to_list, detect_charset, headers_to_list

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

    response = session.request(
        (request.get("method") or "GET").upper(),
        request["url"],
        headers=request.get("headers") or {},
        data=data,
        impersonate=impersonate,
        timeout=request.get("timeoutseconds") or 30,
        verify=request.get("verifyssl", True),
        allow_redirects=request.get("followredirects", True),
        proxies=proxies,
    )

    body = response.content or b""
    content_type = response.headers.get("Content-Type", "") if response.headers else ""
    charset = detect_charset(content_type, body, request.get("defaultcharset", "utf-8"))

    return {
        "ok": True,
        "statusCode": response.status_code,
        "statusText": getattr(response, "reason", "") or "",
        "finalUrl": str(response.url),
        "engineUsed": NAME,
        "headers": headers_to_list(response),
        "cookies": cookiejar_to_list(session.cookies),
        "bodyBytes": body,
        "bodyCharset": charset,
        "error": None,
    }
