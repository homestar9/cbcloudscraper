"""Unit tests for engines/common.py.

These cover the download logic and the request-value helpers. They use Python's
built-in unittest so the project needs no extra dependency, and they use a small fake
response object so no HTTP library is involved.

Run from the engine directory:

    .venv\\Scripts\\python.exe -m unittest discover -s tests -t .
"""
import os
import shutil
import tempfile
import unittest

from engines import common


class FakeResponse:
    """Stands in for a curl_cffi or requests response object.

    Only the three things common.py reads are provided: the status code, the headers,
    and the whole body for the no-download path.
    """

    def __init__(self, status_code=200, headers=None, content=b""):
        self.status_code = status_code
        self.headers = dict(headers or {})
        self.content = content


def chunks_of(data, size=8):
    """Yield ``data`` in small pieces, the way a streamed response arrives."""
    for start in range(0, len(data), size):
        yield data[start : start + size]


class AsBoolTests(unittest.TestCase):
    def test_real_booleans_pass_through(self):
        self.assertTrue(common.as_bool(True, False))
        self.assertFalse(common.as_bool(False, True))

    def test_string_false_is_false(self):
        # bool("false") is True in Python, which is the whole reason this helper exists.
        self.assertFalse(common.as_bool("false", True))
        self.assertFalse(common.as_bool("FALSE", True))
        self.assertFalse(common.as_bool("no", True))
        self.assertFalse(common.as_bool(" off ", True))

    def test_string_true_is_true(self):
        self.assertTrue(common.as_bool("true", False))
        self.assertTrue(common.as_bool("YES", False))
        self.assertTrue(common.as_bool("1", False))

    def test_numbers_follow_zero_and_nonzero(self):
        self.assertTrue(common.as_bool(1, False))
        self.assertFalse(common.as_bool(0, True))

    def test_missing_or_unrecognized_uses_the_default(self):
        self.assertTrue(common.as_bool(None, True))
        self.assertFalse(common.as_bool(None, False))
        self.assertTrue(common.as_bool("", True))
        self.assertTrue(common.as_bool("maybe", True))
        self.assertFalse(common.as_bool([], False))


class ChallengeMarkerTests(unittest.TestCase):
    def test_finds_a_marker(self):
        self.assertTrue(common.head_has_challenge_marker(b"<title>Just a moment...</title>"))

    def test_ignores_case(self):
        self.assertTrue(common.head_has_challenge_marker(b"CF_CHL_OPT = {}"))

    def test_plain_page_has_no_marker(self):
        self.assertFalse(common.head_has_challenge_marker(b"<h1>Example Domain</h1>"))

    def test_empty_body_has_no_marker(self):
        self.assertFalse(common.head_has_challenge_marker(b""))
        self.assertFalse(common.head_has_challenge_marker(None))

    def test_only_the_first_4096_bytes_are_scanned(self):
        body = (b"x" * 5000) + b"just a moment"
        self.assertFalse(common.head_has_challenge_marker(body))


class CheckLengthTests(unittest.TestCase):
    def test_matching_length_passes(self):
        response = FakeResponse(headers={"Content-Length": "10"})
        common._check_length(response, 10)  # no exception

    def test_short_write_raises(self):
        response = FakeResponse(headers={"Content-Length": "1000"})
        with self.assertRaises(IOError):
            common._check_length(response, 400)

    def test_missing_header_skips_the_check(self):
        common._check_length(FakeResponse(), 400)  # no exception

    def test_unreadable_header_skips_the_check(self):
        response = FakeResponse(headers={"Content-Length": "not a number"})
        common._check_length(response, 400)  # no exception

    def test_compressed_body_skips_the_check(self):
        # The HTTP library decompressed the body, so the header size cannot match.
        response = FakeResponse(
            headers={"Content-Length": "1000", "Content-Encoding": "gzip"}
        )
        common._check_length(response, 4000)  # no exception

    def test_identity_encoding_still_checks(self):
        response = FakeResponse(
            headers={"Content-Length": "1000", "Content-Encoding": "identity"}
        )
        with self.assertRaises(IOError):
            common._check_length(response, 400)


class ReceiveBodyTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="cbcs-test-")
        self.target = os.path.join(self.dir, "download.csv")
        self.part = self.target + ".cbcs-test.part"

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def request(self, **overrides):
        base = {
            "downloadto": self.target,
            "downloadpartpath": self.part,
            "downloadonlyon2xx": True,
        }
        base.update(overrides)
        return base

    def test_no_download_path_returns_the_body_in_memory(self):
        response = FakeResponse(content=b"hello")
        outcome = common.receive_body(response, {"downloadto": ""})

        self.assertEqual(outcome["body"], b"hello")
        self.assertEqual(outcome["downloadedTo"], "")
        self.assertEqual(outcome["bytesWritten"], 0)

    def test_success_writes_the_file_and_empties_the_body(self):
        payload = b"name,number\r\n" * 500
        response = FakeResponse(headers={"Content-Length": str(len(payload))})

        outcome = common.receive_body(response, self.request(), chunks_of(payload))

        self.assertEqual(outcome["downloadedTo"], self.target)
        self.assertEqual(outcome["bytesWritten"], len(payload))
        self.assertEqual(outcome["body"], b"")
        with open(self.target, "rb") as handle:
            self.assertEqual(handle.read(), payload)
        self.assertFalse(os.path.exists(self.part))

    def test_success_keeps_the_peek_for_charset_detection(self):
        payload = b'<meta charset="iso-8859-1">' + (b"." * 100)
        response = FakeResponse()

        outcome = common.receive_body(response, self.request(), chunks_of(payload))

        self.assertTrue(outcome["head"].startswith(b'<meta charset="iso-8859-1">'))

    def test_missing_part_path_falls_back_to_target_plus_part(self):
        payload = b"body"
        response = FakeResponse()
        request = self.request()
        del request["downloadpartpath"]

        outcome = common.receive_body(response, request, chunks_of(payload))

        self.assertEqual(outcome["bytesWritten"], len(payload))
        self.assertTrue(os.path.exists(self.target))
        self.assertFalse(os.path.exists(self.target + ".part"))

    def test_cloudflare_block_is_never_written(self):
        page = b"<title>Just a moment...</title>"
        response = FakeResponse(status_code=403, headers={"Server": "cloudflare"})

        outcome = common.receive_body(response, self.request(), chunks_of(page))

        self.assertEqual(outcome["downloadedTo"], "")
        self.assertEqual(outcome["bytesWritten"], 0)
        self.assertEqual(outcome["body"], page)
        self.assertFalse(os.path.exists(self.target))

    def test_cloudflare_marker_on_a_200_is_never_written(self):
        page = b"<html>enable javascript and cookies to continue</html>"
        response = FakeResponse(status_code=200, headers={"Server": "cloudflare"})

        outcome = common.receive_body(response, self.request(), chunks_of(page))

        self.assertEqual(outcome["downloadedTo"], "")
        self.assertFalse(os.path.exists(self.target))

    def test_cloudflare_block_is_not_written_even_when_only_2xx_is_off(self):
        page = b"<title>Just a moment...</title>"
        response = FakeResponse(status_code=403, headers={"Server": "cloudflare"})
        request = self.request(downloadonlyon2xx=False)

        outcome = common.receive_body(response, request, chunks_of(page))

        self.assertEqual(outcome["downloadedTo"], "")
        self.assertFalse(os.path.exists(self.target))

    def test_a_403_from_another_server_is_still_a_normal_response(self):
        # Not Cloudflare, so downloadOnlyOn2xx alone decides. With it off, write it.
        page = b"access denied"
        response = FakeResponse(status_code=403, headers={"Server": "nginx"})
        request = self.request(downloadonlyon2xx=False)

        outcome = common.receive_body(response, request, chunks_of(page))

        self.assertEqual(outcome["downloadedTo"], self.target)
        with open(self.target, "rb") as handle:
            self.assertEqual(handle.read(), page)

    def test_non_2xx_is_skipped_by_default(self):
        page = b"<h1>Not Found</h1>"
        response = FakeResponse(status_code=404)

        outcome = common.receive_body(response, self.request(), chunks_of(page))

        self.assertEqual(outcome["downloadedTo"], "")
        self.assertEqual(outcome["bytesWritten"], 0)
        self.assertEqual(outcome["body"], page)
        self.assertFalse(os.path.exists(self.target))

    def test_only_2xx_reads_the_string_false(self):
        # A CFML engine can send the flag as text; bool("false") would be True.
        page = b"<h1>Not Found</h1>"
        response = FakeResponse(status_code=404)
        request = self.request(downloadonlyon2xx="false")

        outcome = common.receive_body(response, request, chunks_of(page))

        self.assertEqual(outcome["downloadedTo"], self.target)

    def test_preview_is_capped(self):
        page = b"z" * (common.ERROR_PREVIEW_BYTES + 5000)
        response = FakeResponse(status_code=404)

        outcome = common.receive_body(response, self.request(), chunks_of(page, 4096))

        self.assertEqual(len(outcome["body"]), common.ERROR_PREVIEW_BYTES)

    def test_truncated_download_raises_and_leaves_nothing_behind(self):
        payload = b"only the first part"
        response = FakeResponse(headers={"Content-Length": "999999"})

        with self.assertRaises(IOError):
            common.receive_body(response, self.request(), chunks_of(payload))

        self.assertFalse(os.path.exists(self.target))
        self.assertFalse(os.path.exists(self.part))

    def test_a_failing_chunk_iterator_leaves_no_part_file(self):
        def exploding_chunks():
            yield b"the start of the file"
            raise ValueError("connection dropped")

        response = FakeResponse()

        with self.assertRaises(ValueError):
            common.receive_body(response, self.request(), exploding_chunks())

        self.assertFalse(os.path.exists(self.target))
        self.assertFalse(os.path.exists(self.part))

    def test_an_existing_file_is_left_alone_when_the_download_is_refused(self):
        with open(self.target, "wb") as handle:
            handle.write(b"yesterday's good data")
        response = FakeResponse(status_code=503, headers={"Server": "cloudflare"})

        common.receive_body(response, self.request(), chunks_of(b"<html>blocked</html>"))

        with open(self.target, "rb") as handle:
            self.assertEqual(handle.read(), b"yesterday's good data")

    def test_a_missing_parent_directory_is_created(self):
        self.target = os.path.join(self.dir, "new", "deeper", "download.csv")
        self.part = self.target + ".part"
        response = FakeResponse()

        outcome = common.receive_body(response, self.request(), chunks_of(b"data"))

        self.assertEqual(outcome["downloadedTo"], self.target)
        self.assertTrue(os.path.exists(self.target))


if __name__ == "__main__":
    unittest.main()
