# SPDX-License-Identifier: Apache-2.0

import os
from pathlib import Path
import selectors
import signal
import subprocess

from .errors import ImageError


class ImageProcessError(ImageError):
    pass


def run_logged(
    command: list[str],
    workspace: Path,
    environment: dict[str, str],
    log_path: Path,
) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    print("+ " + " ".join(command), flush=True)
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            command,
            cwd=workspace,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        previous = signal.getsignal(signal.SIGTERM)

        def terminate(number: int, _frame: object) -> None:
            _stop_group(process)
            raise ImageProcessError(
                "image build interrupted by " + signal.Signals(number).name
            )

        signal.signal(signal.SIGTERM, terminate)
        try:
            assert process.stdout is not None
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    for key, _ in selector.select(timeout=0.2):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        log.write(chunk)
                        log.flush()
                        os.write(1, chunk)
            status = process.wait()
        except BaseException:
            _stop_group(process)
            raise
        finally:
            signal.signal(signal.SIGTERM, previous)
            if process.stdout is not None:
                process.stdout.close()
        if status:
            raise ImageProcessError(
                f"command failed ({status}); see {log_path}"
            )


def _stop_group(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
