"""Pinned, resumable model downloads using the Mac's native certificate trust."""
from pathlib import Path
import errno
import fcntl
import hashlib
import http.client
import json
import os
import re
import shutil
import ssl
import sys
import sysconfig
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model_paths import installed_marker, is_installed, load_manifest, model_root, status

CHUNK = 1024 * 1024
RESERVE = 64 * 1024 * 1024
ATTEMPTS = 4


def publish(path, payload):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, path)


def file_matches(path, item):
    try:
        if path.stat().st_size != item["size"]:
            return False
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(4 * CHUNK), b""):
                digest.update(chunk)
        return digest.hexdigest() == item["sha256"]
    except (OSError, ValueError):
        return False


class SecureRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urlsplit(newurl)
        local_test = bool(os.environ.get("R2M_MODELS_MANIFEST")) and parts.hostname in {"localhost", "127.0.0.1", "::1"}
        if parts.scheme != "https" and not (local_test and parts.scheme == "http"):
            raise ValueError("A model download was redirected to an insecure address.")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def verified_tls_context():
    if sys.platform == "darwin":
        # OpenSSL's default PEM files and certifi do not include certificates
        # managed by IT in the macOS Keychain. Let Security.framework evaluate
        # the server chain and hostname, including the Mac's trust settings.
        # Do not add certifi anchors here: macOS must also honour system distrust.
        try:
            import truststore
        except ImportError as exc:
            raise RuntimeError("R2M's secure download component is missing. Replace the app with a fresh copy of R2M; your models and documents will be kept.") from exc
        return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context = ssl.create_default_context()
    # Retain portable source/test support outside macOS.
    purelib = sysconfig.get_path("purelib")
    if purelib:
        bundled_roots = Path(purelib) / "certifi/cacert.pem"
        if bundled_roots.is_file():
            context.load_verify_locations(cafile=str(bundled_roots))
    return context


def certificate_error(exc):
    reason = exc.reason if isinstance(exc, urllib.error.URLError) else exc
    return reason if isinstance(reason, ssl.SSLCertVerificationError) else None


class Installer:
    def __init__(self, manifest, report):
        self.manifest = manifest
        self.root = model_root()
        self.report = report
        self.opener = urllib.request.build_opener(SecureRedirect(), urllib.request.HTTPSHandler(context=verified_tls_context()))
        self.completed = 0
        self.total = 0
        self.last_fraction = 0.0

    def update(self, message, current=0, complete=False):
        downloaded = min(self.total, self.completed + current)
        fraction = 1.0 if complete else min(0.995, downloaded / max(1, self.total))
        self.last_fraction = max(self.last_fraction, fraction)
        self.report({"message": message, "fraction": self.last_fraction,
                     "downloaded": downloaded, "total": self.total})

    def partial_path(self, model, item):
        # The digest in the filename prevents a partial from another revision being resumed.
        target = self.root / ".downloads" / model["id"] / item["path"]
        return target.with_name(target.name + "." + item["sha256"][:16] + ".part")

    def check_space(self, needed):
        if shutil.disk_usage(self.root).free < max(0, needed) + RESERVE:
            raise OSError("There is not enough free disk space for the selected models. Free some space and try again.")

    def download_file(self, model, item):
        final = self.root / model["id"] / item["path"]
        partial = self.partial_path(model, item)
        label = f"{model['name']} · {item['path']}"
        self.update("Checking " + label + "…")
        if file_matches(final, item):
            self.completed += item["size"]
            self.update("Verified " + label)
            return
        partial.parent.mkdir(parents=True, exist_ok=True)
        final.parent.mkdir(parents=True, exist_ok=True)
        for attempt in range(ATTEMPTS):
            try:
                offset = partial.stat().st_size if partial.exists() else 0
                if offset > item["size"] or (offset == item["size"] and not file_matches(partial, item)):
                    partial.unlink(missing_ok=True)
                    offset = 0
                if offset < item["size"]:
                    self.check_space(item["size"] - offset)
                    headers = {"User-Agent": "R2M/1.0", "Accept-Encoding": "identity"}
                    if offset:
                        headers["Range"] = f"bytes={offset}-"
                    request = urllib.request.Request(item["url"], headers=headers)
                    self.update("Downloading " + label + "…", offset)
                    with self.opener.open(request, timeout=30) as response:
                        code = response.status
                        if code == 206:
                            match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
                            if not match or int(match[1]) != offset or int(match[3]) != item["size"]:
                                raise ValueError("The server returned an invalid resumed download.")
                            if int(match[2]) < offset or int(match[2]) >= item["size"]:
                                raise ValueError("The server returned an invalid download range.")
                        elif code == 200:
                            # Some servers ignore Range. Restart rather than append the full file.
                            offset = 0
                        else:
                            raise OSError(f"The download server returned HTTP {code}.")
                        with partial.open("ab" if offset else "wb") as output:
                            current = offset
                            while True:
                                chunk = response.read(min(CHUNK, item["size"] - current + 1))
                                if not chunk:
                                    break
                                if current + len(chunk) > item["size"]:
                                    raise ValueError("A downloaded model file has the wrong size.")
                                output.write(chunk)
                                current += len(chunk)
                                self.update("Downloading " + label + "…", current)
                            output.flush()
                            os.fsync(output.fileno())
                    if partial.stat().st_size != item["size"]:
                        raise OSError("The model download ended early. Retrying the remaining bytes…")
                if item["size"] == 0:
                    partial.touch(exist_ok=True)
                self.update("Verifying " + label + "…", item["size"])
                if not file_matches(partial, item):
                    partial.unlink(missing_ok=True)
                    raise ValueError("The downloaded model checksum did not match. The file will be downloaded again.")
                os.replace(partial, final)
                self.completed += item["size"]
                self.update("Verified " + label)
                return
            except (OSError, ValueError, http.client.HTTPException) as exc:
                if certificate_error(exc) is not None:
                    # Retrying a rejected certificate cannot repair the trust chain.
                    # Preserve partial files and keep the failure actionable.
                    raise RuntimeError(
                        f"Could not verify the secure connection for {label}. "
                        "Check this Mac's date and time. If you use a workplace network or VPN, "
                        "ask IT to check its trusted certificates, or try another network. "
                        f"Details: {certificate_error(exc)}"
                    ) from exc
                if isinstance(exc, urllib.error.HTTPError) and exc.code == 416:
                    partial.unlink(missing_ok=True)
                if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
                    raise OSError("The disk became full during the model download. Free some space and try again.") from exc
                if attempt + 1 == ATTEMPTS:
                    raise RuntimeError(f"Could not download {label}. {exc}") from exc
                self.update("Retrying " + label + "…", partial.stat().st_size if partial.exists() else 0)
                time.sleep(min(2, 0.5 * (attempt + 1)))

    def install(self, selected):
        requested = list(dict.fromkeys(selected))
        available = {m["id"]: m for m in self.manifest["models"]}
        if not requested or any(key not in available for key in requested):
            raise ValueError("Select at least one available model to download.")
        self.root.mkdir(parents=True, exist_ok=True)
        # macOS releases this advisory lock automatically on cancellation or a crash.
        with (self.root / ".install.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise RuntimeError("Another R2M model download is already running.") from exc
            models = [available[key] for key in requested]
            self.total = sum(m["bytes"] for m in models)
            needed = 0
            for model in models:
                if is_installed(model, self.root, self.manifest["version"]):
                    continue
                for item in model["files"]:
                    final = self.root / model["id"] / item["path"]
                    partial = self.partial_path(model, item)
                    if final.is_file() and final.stat().st_size == item["size"]:
                        continue
                    needed += max(0, item["size"] - (partial.stat().st_size if partial.is_file() else 0))
            if needed:
                self.check_space(needed)
            for model in models:
                if is_installed(model, self.root, self.manifest["version"]):
                    self.completed += model["bytes"]
                    self.update(model["name"] + " is ready")
                    continue
                directory = self.root / model["id"]
                directory.mkdir(parents=True, exist_ok=True)
                (directory / ".installed.json").unlink(missing_ok=True)
                for item in model["files"]:
                    self.download_file(model, item)
                # A model becomes ready in one atomic write, only after every file was verified.
                publish(directory / ".installed.json", installed_marker(model, self.manifest["version"]))
                if not is_installed(model, self.root, self.manifest["version"]):
                    raise RuntimeError("The model files could not be verified after installation.")
            self.update("Selected models are ready", complete=True)
            return requested


def main():
    if sys.argv[1:] == ["--status"]:
        try:
            print(json.dumps(status(), ensure_ascii=False))
        except Exception as exc:
            print(json.dumps({"error": str(exc)}, ensure_ascii=False))
            return 1
        return 0
    if len(sys.argv) != 2:
        raise SystemExit("Usage: asset_manager.py JOBDIR | --status")
    folder = Path(sys.argv[1])
    try:
        (folder / "result.json").unlink(missing_ok=True)
        request = json.loads((folder / "request.json").read_text(encoding="utf-8"))
        if request.get("kind") != "install" or not isinstance(request.get("models"), list):
            raise ValueError("The model download request is invalid.")
        manifest = load_manifest()
        installer = Installer(manifest, lambda value: publish(folder / "progress.json", value))
        installed = installer.install(request["models"])
        result = {"installed": installed}
    except Exception as exc:
        result = {"error": str(exc) or "The model download stopped unexpectedly."}
    publish(folder / "result.json", result)
    return 0 if "installed" in result else 1


if __name__ == "__main__":
    raise SystemExit(main())
