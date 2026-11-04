"""Exercise certificate and hostname verification over real local HTTPS.

These tests never modify Keychain trust or contact a public network. Run them
with the bundled Python after building so the packaged truststore is exercised.
"""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import asset_manager


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b"verified local download"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextmanager
def https_server(certfile, keyfile):
    instance = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(certfile), str(keyfile))
    instance.socket = context.wrap_socket(instance.socket, server_side=True)
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield instance
    finally:
        instance.shutdown()
        instance.server_close()
        thread.join()


@unittest.skipUnless(sys.platform == "darwin", "macOS native certificate verification")
class NativeDownloadTLS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        openssl = shutil.which("openssl")
        if openssl is None:
            raise unittest.SkipTest("openssl is required to generate temporary HTTPS certificates")
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.ca = cls.directory / "ca.pem"
        cls.cert = cls.directory / "server.pem"
        cls.key = cls.directory / "server.key"
        (cls.directory / "ca.cnf").write_text("""\
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=R2M temporary test CA
[extensions]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
""")
        (cls.directory / "server.cnf").write_text("""\
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
""")
        (cls.directory / "server.ext").write_text("""\
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
""")

        def run(*arguments):
            subprocess.run([openssl, *arguments], cwd=cls.directory,
                           capture_output=True, check=True, timeout=30)

        run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-days", "2", "-config", "ca.cnf", "-keyout", "ca.key", "-out", "ca.pem")
        run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-config", "server.cnf", "-keyout", "server.key", "-out", "server.csr")
        run("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
            "-set_serial", "1", "-days", "2", "-sha256", "-extfile", "server.ext", "-out", "server.pem")
        run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-days", "2", "-config", "server.cnf", "-keyout", "selfsigned.key", "-out", "selfsigned.pem")

    def opener(self, context):
        # The temporary localhost server must not be sent through an ambient proxy.
        return urllib.request.build_opener(urllib.request.ProxyHandler({}),
            asset_manager.SecureRedirect(), urllib.request.HTTPSHandler(context=context))

    def test_native_context_keeps_certificate_and_hostname_checks(self):
        import truststore
        context = asset_manager.verified_tls_context()
        self.assertIsInstance(context, truststore.SSLContext)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_untrusted_private_ca_is_rejected(self):
        context = asset_manager.verified_tls_context()
        with https_server(self.cert, self.key) as server:
            with self.assertRaises(urllib.error.URLError) as failure:
                self.opener(context).open(f"https://localhost:{server.server_port}/model", timeout=5)
        self.assertIsInstance(failure.exception.reason, ssl.SSLCertVerificationError)

    def test_selfsigned_server_is_rejected(self):
        context = asset_manager.verified_tls_context()
        with https_server(self.directory / "selfsigned.pem", self.directory / "selfsigned.key") as server:
            with self.assertRaises(urllib.error.URLError) as failure:
                self.opener(context).open(f"https://localhost:{server.server_port}/model", timeout=5)
        self.assertIsInstance(failure.exception.reason, ssl.SSLCertVerificationError)

    def test_rejected_certificate_stops_install_without_retry_or_readiness(self):
        body = b"verified local download"
        with tempfile.TemporaryDirectory() as temporary, https_server(self.cert, self.key) as server:
            root = Path(temporary) / "models"
            item = dict(path="README.md", size=len(body), sha256=hashlib.sha256(body).hexdigest(),
                        url=f"https://localhost:{server.server_port}/model")
            model = dict(id="speech", name="Speech", revision="test", bytes=len(body), files=[item])
            manifest = dict(version=1, models=[model])
            with patch.dict(os.environ, {"R2M_MODEL_DIR": str(root)}):
                installer = asset_manager.Installer(manifest, lambda value: None)
                # Keep the real downloader's TLS and redirects, but avoid ambient proxies.
                installer.opener = self.opener(asset_manager.verified_tls_context())
                partial = installer.partial_path(model, item)
                partial.parent.mkdir(parents=True)
                partial.write_bytes(body[:5])
                with patch.object(installer.opener, "open", wraps=installer.opener.open) as opened, \
                        patch.object(asset_manager.time, "sleep") as slept:
                    with self.assertRaisesRegex(RuntimeError, "Could not verify the secure connection"):
                        installer.install(["speech"])
                self.assertEqual(opened.call_count, 1)
                slept.assert_not_called()
                self.assertEqual(partial.read_bytes(), body[:5])
                self.assertFalse((root / "speech/README.md").exists())
                self.assertFalse((root / "speech/.installed.json").exists())

    def test_explicitly_trusted_ca_works_without_openssl_defaults(self):
        # An empty OpenSSL CA location must not prevent native context creation.
        # The private fixture is trusted only for this context, never in Keychain.
        missing = str(self.directory / "no-default-certificates")
        with patch.dict(os.environ, {"SSL_CERT_FILE": missing, "SSL_CERT_DIR": missing}):
            context = asset_manager.verified_tls_context()
            context.load_verify_locations(cafile=str(self.ca))
            with https_server(self.cert, self.key) as server:
                with self.opener(context).open(f"https://localhost:{server.server_port}/model", timeout=5) as response:
                    self.assertEqual(response.read(), b"verified local download")

    def test_trusted_ca_does_not_allow_wrong_hostname(self):
        context = asset_manager.verified_tls_context()
        context.load_verify_locations(cafile=str(self.ca))
        with https_server(self.cert, self.key) as server:
            with self.assertRaises(urllib.error.URLError) as failure:
                self.opener(context).open(f"https://127.0.0.1:{server.server_port}/model", timeout=5)
        self.assertIsInstance(failure.exception.reason, ssl.SSLCertVerificationError)


if __name__ == "__main__":
    unittest.main()
