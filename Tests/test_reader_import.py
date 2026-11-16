"""Exercise website import locally, including native TLS and text fidelity."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import ssl
import sys
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
sys.path.insert(0, str(ROOT / "Tests"))
import reader


class WebsiteHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/restricted":
            self.send_response(403)
            self.end_headers()
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/utf8")
            self.end_headers()
            return
        content_type = "text/plain"
        body = "Café research 🧪 remains the author's own text.".encode()
        if self.path == "/latin1":
            content_type = "text/plain; charset=iso-8859-1"
            body = "Café research — résumé".replace("—", "-").encode("iso-8859-1")
        elif self.path == "/invalid-encoding":
            content_type = "text/plain; charset=utf-8"
            body = b"A broken word: \xff."
        elif self.path == "/unknown-encoding":
            content_type = "text/plain; charset=r2m-not-a-codec"
        elif self.path == "/empty":
            body = b""
        elif self.path == "/html":
            content_type = "text/html; charset=utf-8"
            paragraph = "This article explains how researchers preserve original words while preparing papers for local speech. " * 8
            body = ("<!doctype html><html><head><title>Local research fixture</title></head><body><main><article><h1>Local research fixture</h1><p>" + paragraph + "</p></article></main></body></html>").encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(40 * 1024**2 + 1 if self.path == "/oversize" else len(body)))
        self.end_headers()
        try:
            if self.path == "/oversize":
                for _ in range(641):
                    self.wfile.write(b"a" * 65536)
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


@contextmanager
def website(cert=None, key=None):
    instance = ThreadingHTTPServer(("127.0.0.1", 0), WebsiteHandler)
    if cert is not None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(cert), str(key))
        instance.socket = context.wrap_socket(instance.socket, server_side=True)
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield instance
    finally:
        instance.shutdown()
        instance.server_close()
        thread.join()


class WebsiteImport(unittest.TestCase):
    def setUp(self):
        # A local fixture must not be routed through a workplace proxy.
        self.environment = patch.dict(os.environ, {"NO_PROXY": "localhost,127.0.0.1"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def read(self, server, path="/utf8", host="127.0.0.1", secure=False):
        return reader.read_link(f"{'https' if secure else 'http'}://{host}:{server.server_port}{path}", lambda message: None)

    def test_utf8_plain_text_is_preserved_without_charset(self):
        with website() as server:
            result = self.read(server)
        self.assertEqual(result["text"], "Café research 🧪 remains the author's own text.")

    def test_declared_plain_text_charset_is_respected(self):
        with website() as server:
            result = self.read(server, "/latin1")
        self.assertEqual(result["text"], "Café research - résumé")

    def test_undecodable_text_is_reported_instead_of_replacing_author_letters(self):
        with website() as server:
            for path in ["/invalid-encoding", "/unknown-encoding"]:
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "text encoding could not be read"):
                    self.read(server, path)

    def test_restriction_and_empty_page_errors_are_actionable(self):
        with website() as server:
            with self.assertRaisesRegex(ValueError, "restricted access"):
                self.read(server, "/restricted")
            with self.assertRaisesRegex(ValueError, "No article text"):
                self.read(server, "/empty")

    def test_redirect_and_html_extraction(self):
        with website() as server:
            self.assertIn("Café research", self.read(server, "/redirect")["text"])
            article = self.read(server, "/html")
        self.assertEqual(article["title"], "Local research fixture")
        self.assertIn("researchers preserve original words", article["text"])

    def test_download_is_bounded(self):
        with website() as server:
            with self.assertRaisesRegex(ValueError, "exceeds 40 MB"):
                self.read(server, "/oversize")

    def test_invalid_ports_and_credentials_are_rejected_before_network(self):
        for url in ["https://example.org:bad/article", "https://[", "https://@example.org/article", "https://user:password@example.org/article"]:
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "Enter an http or https link"):
                reader.read_link(url, lambda message: None)


@unittest.skipUnless(sys.platform == "darwin", "macOS native certificate verification")
class WebsiteNativeTLS(unittest.TestCase):
    setUp = WebsiteImport.setUp
    read = WebsiteImport.read

    @classmethod
    def setUpClass(cls):
        import test_download_tls as fixtures
        cls.certificates = fixtures.NativeDownloadTLS
        cls.certificates.setUpClass()
        cls.addClassCleanup(cls.certificates.doClassCleanups)

    # TLS cases use read_link itself so requests' default certifi adapter cannot
    # silently replace the native context being tested.
    def test_native_tls_trusted_context_and_hostname(self):
        import asset_manager
        context = asset_manager.verified_tls_context()
        context.load_verify_locations(cafile=str(self.certificates.ca))
        with patch.object(asset_manager, "verified_tls_context", return_value=context), \
                website(self.certificates.cert, self.certificates.key) as server:
            result = self.read(server, host="localhost", secure=True)
            self.assertIn("Café research", result["text"])
            with self.assertRaisesRegex(ValueError, "verify the website's secure connection"):
                self.read(server, host="127.0.0.1", secure=True)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_native_tls_rejects_untrusted_certificate(self):
        with website(self.certificates.cert, self.certificates.key) as server:
            with self.assertRaisesRegex(ValueError, "verify the website's secure connection"):
                self.read(server, host="localhost", secure=True)


if __name__ == "__main__":
    unittest.main()
