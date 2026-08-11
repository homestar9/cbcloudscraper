"""Shared helpers used by every engine.

These functions normalize what the underlying HTTP libraries return into the plain
data shapes the worker writes to the response file: a charset string, a list of
header dictionaries, and a list of cookie dictionaries.
"""
import re


def detect_charset(content_type, body_bytes, default="utf-8"):
    """Return the best guess for the response body's character set.

    Checks, in order: the Content-Type header, a byte-order mark, and a
    ``<meta charset>`` tag near the top of an HTML body. Falls back to ``default``.
    """
    if content_type:
        match = re.search(r"charset=([^\s;]+)", content_type, re.IGNORECASE)
        if match:
            return match.group(1).strip().strip("\"'").lower()

    if body_bytes[:3] == b"\xef\xbb\xbf":
        return "utf-8"
    if body_bytes[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16"

    head = body_bytes[:2048]
    match = re.search(rb"charset=[\"']?([a-zA-Z0-9_\-]+)", head, re.IGNORECASE)
    if match:
        try:
            return match.group(1).decode("ascii").lower()
        except Exception:
            pass

    return default


def headers_to_list(response):
    """Return response headers as a list of ``{"name","value"}`` dicts.

    Prefers the raw urllib3 header container when available so that duplicate
    headers (most importantly multiple ``Set-Cookie`` lines) are preserved instead
    of being collapsed into one comma-joined value.
    """
    items = None

    # requests / cloudscraper expose the raw urllib3 HTTPHeaderDict here.
    raw = getattr(response, "raw", None)
    raw_headers = getattr(raw, "headers", None)
    if raw_headers is not None:
        try:
            items = list(raw_headers.items())
        except Exception:
            items = None

    if items is None:
        headers = getattr(response, "headers", {})
        # curl_cffi's Headers object supports multi_items(); use it when present.
        multi = getattr(headers, "multi_items", None)
        if callable(multi):
            try:
                items = list(multi())
            except Exception:
                items = None
        if items is None:
            try:
                items = list(headers.items())
            except Exception:
                items = []

    return [{"name": str(name), "value": str(value)} for name, value in items]


def cookiejar_to_list(cookie_container):
    """Return persisted cookies from a session's cookie store as a list of dicts.

    Accepts either an ``http.cookiejar`` compatible jar or a wrapper that exposes
    one through a ``.jar`` attribute (curl_cffi). Reads each cookie's attributes
    defensively because the exact object type varies between libraries.
    """
    jar = getattr(cookie_container, "jar", cookie_container)
    out = []
    try:
        iterator = iter(jar)
    except TypeError:
        return out

    for cookie in iterator:
        try:
            out.append(
                {
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": cookie.domain or "",
                    "path": cookie.path or "/",
                    "expires": cookie.expires or 0,
                    "secure": bool(getattr(cookie, "secure", False)),
                }
            )
        except AttributeError:
            # Not a Cookie object (e.g. iterating yielded a name); skip it.
            continue

    return out
