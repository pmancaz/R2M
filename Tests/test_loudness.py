"""Exercise encoder cleanup using a real disposable child process."""
from pathlib import Path
import os
import signal
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import loudness


class EncoderLifecycle(unittest.TestCase):
    def test_progress_failure_reaps_encoder_and_restores_signal_handler(self):
        self.check_failed_report(OSError)

    def test_progress_value_error_is_not_swallowed_as_malformed_encoder_output(self):
        self.check_failed_report(ValueError)

    def check_failed_report(self, error_type):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            pidfile = directory / "pid"
            encoder = directory / "ffmpeg"
            program = (
                "import os, time\n"
                "from pathlib import Path\n"
                f"Path({str(pidfile)!r}).write_text(str(os.getpid()))\n"
                'print("out_time_us=1000", flush=True)\n'
                "time.sleep(30)\n"
            )
            # exec keeps the real child PID, including when Python's path has spaces.
            encoder.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) +
                               " -c " + shlex.quote(program) + ' "$@"\n')
            encoder.chmod(0o700)
            previous = signal.getsignal(signal.SIGTERM)

            def failed_report(fraction):
                raise error_type("The progress file could not be written")

            pid = None
            try:
                with patch.object(loudness, "FFMPEG", encoder):
                    with self.assertRaisesRegex(error_type, "progress file"):
                        loudness.run([], report=failed_report, duration=1)
                pid = int(pidfile.read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
                self.assertIsNone(loudness.ACTIVE)
                self.assertEqual(signal.getsignal(signal.SIGTERM), previous)
            finally:
                # Also clean up the child if this test is run against the old bug.
                if pidfile.exists():
                    pid = int(pidfile.read_text())
                    try:
                        os.kill(pid, signal.SIGKILL)
                        os.waitpid(pid, 0)
                    except (ProcessLookupError, ChildProcessError):
                        pass


if __name__ == "__main__":
    unittest.main()
