# SPDX-License-Identifier: Apache-2.0

import os
from pathlib import Path
import signal
import tempfile
import threading
import time
import unittest

from resources.images.process import ImageProcessError, run_logged


class ImageProcessTests(unittest.TestCase):
    def test_cancel_stops_descendant_without_newline_and_keeps_output(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            pid_file = directory / "child.pid"

            def cancel_after_start():
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                os.kill(os.getpid(), signal.SIGTERM)

            sender = threading.Thread(target=cancel_after_start)
            sender.start()
            started = time.monotonic()
            with self.assertRaisesRegex(ImageProcessError, "SIGTERM"):
                run_logged([
                    "bash", "-c", 'sleep 30 & child=$!; printf ready; '
                    'printf "%s" "$child" > "$1/child.pid"; wait',
                    "image-command", str(directory),
                ], directory, os.environ.copy(), directory / "build.log")
            sender.join()
            self.assertLess(time.monotonic() - started, 5)
            child = int(pid_file.read_text())
            deadline = time.monotonic() + 5
            while (Path(f"/proc/{child}").exists()
                   and time.monotonic() < deadline):
                time.sleep(0.02)
            self.assertFalse(Path(f"/proc/{child}").exists())
            self.assertIn(b"ready", (directory / "build.log").read_bytes())

    def test_failed_command_keeps_its_output_log(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            log = directory / "build.log"
            with self.assertRaisesRegex(ImageProcessError, "command failed"):
                run_logged(
                    ["bash", "-c", "printf failure; exit 7"],
                    directory,
                    os.environ.copy(),
                    log,
                )
            self.assertIn(b"failure", log.read_bytes())


if __name__ == "__main__":
    unittest.main()
