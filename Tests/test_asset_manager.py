"""Exercise real worker IPC against a local HTTP server; no model downloads required."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "Backend/asset_manager.py"
DATA = bytes(range(256)) * 12288  # 3 MiB, deterministic and inexpensive.


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.ranges.append(self.headers.get("Range"))
        start = int(self.headers["Range"].split("=")[1].split("-")[0]) if self.headers.get("Range") else 0
        body = DATA
        if self.server.mode == "bad-hash":
            body = b"x" * len(DATA)
        if self.server.mode == "ignore-range":
            start = 0
        code = 206 if start else 200
        self.send_response(code)
        if code == 206:
            self.send_header("Content-Range", f"bytes {start}-{len(body)-1}/{len(body)}")
        self.send_header("Content-Length", str(len(body) - start))
        self.end_headers()
        try:
            if self.server.mode == "short-first" and len(self.server.ranges) == 1:
                self.wfile.write(body[:180000])
                self.wfile.flush()
                self.close_connection = True
                return
            for offset in range(start, len(body), 65536):
                self.wfile.write(body[offset:offset+65536])
                self.wfile.flush()
                if self.server.slow:
                    time.sleep(0.015)
        except (BrokenPipeError, ConnectionResetError):
            pass


@contextmanager
def server(mode="normal", slow=False):
    instance = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    instance.ranges = []
    instance.mode = mode
    instance.slow = slow
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield instance
    finally:
        instance.shutdown()
        instance.server_close()
        thread.join()


class Downloads(unittest.TestCase):
    def setup_job(self, directory, server, revision="test-pin"):
        directory = Path(directory)
        digest = hashlib.sha256(DATA).hexdigest()
        item = dict(path="weights.bin", size=len(DATA), sha256=digest,
                    url=f"http://127.0.0.1:{server.server_port}/weights.bin")
        model = dict(id="speech", name="Speech", revision=revision, bytes=len(DATA), files=[item])
        manifest = directory / "manifest.json"
        manifest.write_text(json.dumps(dict(version=1, models=[model])))
        job = directory / "job"
        job.mkdir(exist_ok=True)
        (job / "request.json").write_text(json.dumps(dict(kind="install", models=["speech"])))
        env = dict(os.environ, R2M_MODEL_DIR=str(directory / "models"), R2M_MODELS_MANIFEST=str(manifest))
        return job, env, model

    def run_worker(self, job, env):
        return subprocess.run([sys.executable, "-I", "-B", str(WORKER), str(job)], env=env,
                              capture_output=True, timeout=30)

    def installed(self, env):
        answer = subprocess.check_output([sys.executable, "-I", "-B", str(WORKER), "--status"], env=env)
        return json.loads(answer)["speech"]["installed"]

    def partial(self, env, model):
        return Path(env["R2M_MODEL_DIR"]) / ".downloads/speech" / ("weights.bin." + model["files"][0]["sha256"][:16] + ".part")

    def test_cancel_resume_and_revision_marker(self):
        with tempfile.TemporaryDirectory() as temp, server(slow=True) as http:
            job, env, model = self.setup_job(temp, http)
            process = subprocess.Popen([sys.executable, "-I", "-B", str(WORKER), str(job)], env=env)
            try:
                partial = self.partial(env, model)
                deadline = time.monotonic() + 10
                while (not partial.exists() or partial.stat().st_size < 1024*1024) and time.monotonic() < deadline:
                    time.sleep(0.01)
                process.terminate()
                process.wait(timeout=5)
                self.assertGreater(partial.stat().st_size, 0)
                self.assertLess(partial.stat().st_size, len(DATA))
                self.assertFalse(self.installed(env))
                self.assertFalse((job / "result.json").exists())
                http.slow = False
                result = self.run_worker(job, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(any(value for value in http.ranges[1:]))
                self.assertTrue(self.installed(env))
                final = Path(env["R2M_MODEL_DIR"]) / "speech/weights.bin"
                self.assertEqual(hashlib.sha256(final.read_bytes()).hexdigest(), model["files"][0]["sha256"])
                self.assertEqual(json.loads((job / "result.json").read_text()), {"installed": ["speech"]})
                self.assertEqual(json.loads((job / "progress.json").read_text())["fraction"], 1)
                # A changed manifest pin invalidates readiness, even when bytes remain reusable.
                job, env, _ = self.setup_job(temp, http, revision="new-pin")
                self.assertFalse(self.installed(env))
                calls = len(http.ranges)
                self.assertEqual(self.run_worker(job, env).returncode, 0)
                self.assertEqual(len(http.ranges), calls)
                self.assertTrue(self.installed(env))
                final.write_bytes(b"truncated")
                self.assertFalse(self.installed(env))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_server_ignores_range_restarts_safely(self):
        with tempfile.TemporaryDirectory() as temp, server(mode="ignore-range") as http:
            job, env, model = self.setup_job(temp, http)
            partial = self.partial(env, model)
            partial.parent.mkdir(parents=True)
            partial.write_bytes(DATA[:500000])
            self.assertEqual(self.run_worker(job, env).returncode, 0)
            self.assertIn("bytes=500000-", http.ranges)
            self.assertTrue(self.installed(env))

    def test_short_connection_resumes(self):
        with tempfile.TemporaryDirectory() as temp, server(mode="short-first") as http:
            job, env, _ = self.setup_job(temp, http)
            self.assertEqual(self.run_worker(job, env).returncode, 0)
            self.assertIn("bytes=180000-", http.ranges)
            self.assertTrue(self.installed(env))

    def test_hash_failure_never_reports_ready(self):
        with tempfile.TemporaryDirectory() as temp, server(mode="bad-hash") as http:
            job, env, _ = self.setup_job(temp, http)
            self.assertNotEqual(self.run_worker(job, env).returncode, 0)
            result = json.loads((job / "result.json").read_text())
            self.assertIn("checksum", result["error"])
            self.assertFalse(self.installed(env))
            self.assertFalse((Path(env["R2M_MODEL_DIR"]) / "speech/.installed.json").exists())
            self.assertFalse((Path(env["R2M_MODEL_DIR"]) / "speech/weights.bin").exists())

    def test_insufficient_space_stops_before_network(self):
        sys.path.insert(0, str(ROOT / "Backend"))
        import asset_manager
        with tempfile.TemporaryDirectory() as temp, server() as http:
            _, env, _ = self.setup_job(temp, http)
            with patch.dict(os.environ, env), patch.object(asset_manager.shutil, "disk_usage", return_value=SimpleNamespace(free=0)):
                with self.assertRaisesRegex(OSError, "disk space"):
                    asset_manager.Installer(asset_manager.load_manifest(), lambda _: None).install(["speech"])
            self.assertEqual(http.ranges, [])


if __name__ == "__main__":
    unittest.main()
