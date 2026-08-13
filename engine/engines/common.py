"""Shared helpers used by every engine.

These functions normalize what the underlying HTTP libraries return into the plain
data shapes the worker writes to the response file: a charset string, a list of
header dictionaries, and a list of cookie dictionaries.

This module also handles file downloads. When a request has a "downloadto" path,
receive_body() writes the response body to that file instead of returning it in memory.
"""
import os
import re

# Number of bytes in each download chunk.
CHUNK_BYTES = 65536

# Read this many bytes before deciding whether to save the response. This preview is
# also used to find Cloudflare challenge markers and HTML character sets.
PEEK_BYTES = 65536

# Return at most this many bytes when a response cannot be saved. This lets the caller
# inspect an error page without keeping the full page in memory.
ERROR_PREVIEW_BYTES = 65536

# Text that may appear near the start of a Cloudflare challenge page. main.py uses these
# markers to decide whether to try another engine. receive_body() uses them to avoid
# saving a challenge page.
CHALLENGE_MARKERS = (
    "just a moment",
    "cf-challenge",
    "challenge-platform",
    "cf_chl_opt",
    "attention required",
    "enable javascript and cookies to continue",
)

# Statuses Cloudflare uses when it blocks a request.
CHALLENGE_STATUSES = (403, 429, 503)


def as_bool(value, default):
    """Convert a request JSON value to a boolean.

    A CFML engine may send a boolean as text. Python treats every non-empty string as
    true, including "false". Return ``default`` for a missing or unknown value.
    """
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        text = value.strip().lower()
        if text in ("true", "yes", "y", "1", "on"):
            return True
        if text in ("false", "no", "n", "0", "off"):
            return False
        return default
    return default


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


# File download helpers


def head_has_challenge_marker(head_bytes):
    """Return True when the start of a body contains a Cloudflare challenge marker."""
    try:
        head = (head_bytes or b"")[:4096].decode("utf-8", "ignore").lower()
    except Exception:  # noqa: BLE001 - unreadable bytes do not prove this is a challenge
        return False
    return any(marker in head for marker in CHALLENGE_MARKERS)


def receive_body(response, request, chunks=None):
    """Read the response body and save it when the request has a download path.

    The returned dict has four keys:

        body          Bytes returned to CFML. Empty after the file is saved.
        head          First PEEK_BYTES. Used to detect the character set.
        downloadedTo  Saved file path. Empty when no file was saved.
        bytesWritten  Number of saved bytes. Zero when no file was saved.

    Without "downloadto", the whole body is returned in memory.

    ``chunks`` provides pieces of the response body. Each engine creates this iterator
    because its HTTP library has different rules for chunk sizes.
    """
    target = (request.get("downloadto") or "").strip()
    if not target:
        return {
            "body": response.content or b"",
            "head": b"",
            "downloadedTo": "",
            "bytesWritten": 0,
        }

    head = _read_head(chunks)
    status = getattr(response, "status_code", 0) or 0

    if not _may_write(response, request, status, head):
        return {
            "body": head[:ERROR_PREVIEW_BYTES],
            "head": head,
            "downloadedTo": "",
            "bytesWritten": 0,
        }

    part_path = (request.get("downloadpartpath") or "").strip() or (target + ".part")

    parent = os.path.dirname(target)
    if parent:
        # CFML creates this directory before it starts the worker. Create it here too
        # so the worker can run by itself.
        os.makedirs(parent, exist_ok=True)

    written = _write_stream(part_path, head, chunks)
    try:
        _check_length(response, written)
        # The part file is next to the target. os.replace() can rename it atomically,
        # so the target never contains a partial download.
        os.replace(part_path, target)
    except BaseException:
        _remove_quietly(part_path)
        raise

    return {"body": b"", "head": head, "downloadedTo": target, "bytesWritten": written}


def _read_head(chunks):
    """Read the first PEEK_BYTES of the body, or all of it when it is smaller."""
    head = b""
    if chunks is None:
        return head
    for chunk in chunks:
        if not chunk:
            continue
        head += chunk
        if len(head) >= PEEK_BYTES:
            break
    return head


def _may_write(response, request, status, head):
    """Return whether this response can replace the target file.

    Never save a Cloudflare challenge page. Keeping the page in memory lets main.py try
    another engine. It also protects an existing target file. The downloadonlyon2xx
    option controls other HTTP error responses.
    """
    server = ""
    try:
        server = (response.headers.get("Server") or "").lower()
    except Exception:  # noqa: BLE001 - missing headers do not prove this is Cloudflare
        server = ""

    if "cloudflare" in server:
        if status in CHALLENGE_STATUSES or head_has_challenge_marker(head):
            return False

    if as_bool(request.get("downloadonlyon2xx"), True):
        return 200 <= status < 300

    return True


def _write_stream(part_path, head, chunks):
    """Write the saved first bytes and remaining chunks to the part file.

    Return the number of bytes written. Delete the part file if the write fails.
    """
    written = 0
    try:
        with open(part_path, "wb") as handle:
            if head:
                handle.write(head)
                written += len(head)
            if chunks is not None:
                for chunk in chunks:
                    if not chunk:
                        continue
                    handle.write(chunk)
                    written += len(chunk)
    except BaseException:
        _remove_quietly(part_path)
        raise
    return written


def _check_length(response, written):
    """Raise when an uncompressed Content-Length does not match the saved file.

    A mismatch means that the download may be incomplete. Skip this check for compressed
    responses because the HTTP libraries decompress the body before it is saved.
    Content-Length still reports the compressed size.
    """
    try:
        headers = response.headers
        encoding = (headers.get("Content-Encoding") or "").strip().lower()
        raw_length = headers.get("Content-Length")
    except Exception:  # noqa: BLE001 - no readable headers means no length to compare
        return

    if encoding and encoding != "identity":
        return

    if raw_length in (None, ""):
        return

    try:
        expected = int(str(raw_length).strip())
    except (TypeError, ValueError):
        return

    if expected != written:
        raise IOError(
            "download is incomplete: Content-Length said %d bytes but %d bytes arrived"
            % (expected, written)
        )


def _remove_quietly(path):
    """Delete a file without replacing the original error with a cleanup error."""
    try:
        os.remove(path)
    except OSError:
        pass
