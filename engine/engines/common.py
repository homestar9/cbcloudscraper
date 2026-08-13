"""Shared helpers used by every engine.

These functions normalize what the underlying HTTP libraries return into the plain
data shapes the worker writes to the response file: a charset string, a list of
header dictionaries, and a list of cookie dictionaries.

This module also holds the download logic. When the request carries a "downloadto"
path, receive_body() writes the response body to that path in chunks instead of
returning it in memory, which is what makes a large download cheap.
"""
import os
import re

# How many bytes are read at a time while writing a download to disk.
CHUNK_BYTES = 65536

# How many bytes are read before deciding whether the body may be written. This is
# the "peek": it is enough to find a Cloudflare challenge marker and enough to detect
# the character set from a <meta charset> tag.
PEEK_BYTES = 65536

# How much of the body is kept in memory when a download is refused, so the caller
# can see the error page.
ERROR_PREVIEW_BYTES = 65536

# Text found near the top of a Cloudflare interstitial page. main.py uses this list to
# decide whether to try the next engine, and receive_body() uses it to decide whether a
# body may be written to the caller's file.
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
    """Return a real boolean for a value that came out of the request JSON.

    A CFML engine can serialize a boolean as the string "false", and Python's
    bool("false") is True. Read strings by name instead, and fall back to ``default``
    when the key was missing (value is None) or the text is not recognized.
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


# ----------------------------------------------------------------------------------
# Downloading the body to a file
# ----------------------------------------------------------------------------------


def head_has_challenge_marker(head_bytes):
    """Return True when the start of a body contains a Cloudflare challenge marker."""
    try:
        head = (head_bytes or b"")[:4096].decode("utf-8", "ignore").lower()
    except Exception:  # noqa: BLE001 - a body that cannot be read is not a challenge
        return False
    return any(marker in head for marker in CHALLENGE_MARKERS)


def receive_body(response, request, chunks=None):
    """Return the response body, writing it to a file when the request asked for that.

    Returns a dict with four keys:

        body          the bytes to send back to CFML (empty after a file was written)
        head          the first PEEK_BYTES of the body, for character set detection
        downloadedTo  the target path when a file was written, "" when not
        bytesWritten  how many bytes went into that file, 0 when none did

    Without a "downloadto" path in the request this returns the whole body in memory,
    which is what every request did before the download option existed.

    ``chunks`` is an iterator of byte chunks. Each engine builds its own, because the
    two HTTP libraries do not chunk the same way: curl_cffi ignores a chunk size, and
    requests defaults to one byte per chunk.
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
        # CFML already created this directory. Doing it here too keeps the worker
        # usable on its own, which is how build\smoke-test.ps1 runs it.
        os.makedirs(parent, exist_ok=True)

    written = _write_stream(part_path, head, chunks)
    try:
        _check_length(response, written)
        # The part file sits beside the target, so this rename stays on one volume
        # and is atomic. A half-written file never appears at the target path.
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
    """Return True when this response is allowed to land on the caller's file.

    A Cloudflare challenge page is never written, whatever downloadOnlyOn2xx says. Two
    reasons: main.py needs the body in memory so it can try the next engine, and a
    block page must never overwrite a good file the caller downloaded earlier.
    """
    server = ""
    try:
        server = (response.headers.get("Server") or "").lower()
    except Exception:  # noqa: BLE001 - a missing header container is not Cloudflare
        server = ""

    if "cloudflare" in server:
        if status in CHALLENGE_STATUSES or head_has_challenge_marker(head):
            return False

    if as_bool(request.get("downloadonlyon2xx"), True):
        return 200 <= status < 300

    return True


def _write_stream(part_path, head, chunks):
    """Write the peek and the rest of the body to the part file. Return the byte count.

    Deletes the part file and re-raises on any error, so a failed engine leaves nothing
    behind before the next engine tries.
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
    """Raise when Content-Length and the number of bytes written disagree.

    A truncated download must fail loudly instead of writing a short file over a good
    one. The check is skipped when the body arrived compressed, because both HTTP
    libraries decompress it while Content-Length reports the compressed size.
    """
    try:
        headers = response.headers
        encoding = (headers.get("Content-Encoding") or "").strip().lower()
        raw_length = headers.get("Content-Length")
    except Exception:  # noqa: BLE001 - without headers there is nothing to compare
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
    """Delete a file and ignore any error, so cleanup never hides the real problem."""
    try:
        os.remove(path)
    except OSError:
        pass
