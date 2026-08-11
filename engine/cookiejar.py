"""On-disk cookie storage shared between separate worker runs.

Each worker invocation is its own process, so there is no in-memory session to reuse.
A Cloudflare clearance cookie (cf_clearance) earned on one call is valuable on the
next call. These helpers read the cookie file before a request and write it after,
so that value persists between runs. The file is a JSON list of cookie dictionaries.
"""
import json
import os


def load_cookies(path):
    """Return the list of cookies stored at ``path``, or an empty list."""
    if not path or not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8-sig") as handle:
            data = json.load(handle)
        if isinstance(data, list):
            return data
    except Exception:
        pass
    return []


def save_cookies(path, cookies):
    """Write ``cookies`` (a list of dicts) to ``path`` as JSON. Errors are ignored."""
    if not path:
        return
    try:
        directory = os.path.dirname(path)
        if directory and not os.path.isdir(directory):
            os.makedirs(directory, exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(cookies, handle)
    except Exception:
        pass
