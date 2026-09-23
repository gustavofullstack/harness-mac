#!/usr/bin/env python3
"""Exercise the real DSH.app crash/reconnect path without using the foreground screen.

Requires an installed `dsh` on PATH and a built `.build/debug/DSH` in this checkout.
It uses a temporary DSH profile, kills only the server child started by this app,
and checks that the app recovers and stops its replacement child on exit.
"""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / ".build/debug/DSH"


def server_child(parent_pid: int, excluding: int | None = None) -> int | None:
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,command="], text=True)
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid, ppid, command = int(fields[0]), int(fields[1]), fields[2]
        if ppid == parent_pid and pid != excluding and "dsh --profile web --no-open" in command:
            return pid
    return None


def wait_child(parent_pid: int, excluding: int | None = None, timeout: float = 15) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pid := server_child(parent_pid, excluding):
            return pid
        time.sleep(0.1)
    raise RuntimeError("app did not start or restart its DSH server")


def wait_listening(pid: int, timeout: float = 90) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-t"],
                                capture_output=True, text=True, check=False)
        if result.stdout.strip():
            return
        time.sleep(0.5)
    raise RuntimeError("DSH server did not start listening")


def still_running(pid: int) -> bool:
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], text=True,
                            capture_output=True, check=False)
    return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.lstrip().startswith("Z")


def main() -> None:
    if not APP.is_file():
        raise SystemExit("build DSH first: swift build --product DSH")
    with tempfile.TemporaryDirectory(prefix="dsh-reconnect-") as profile:
        snapshot = Path(profile) / "recovered.png"
        env = os.environ.copy()
        env.update(DSH_HOME=profile, HARNESS_SNAPSHOT=str(snapshot), HARNESS_SNAPSHOT_DELAY="12")
        app = subprocess.Popen([str(APP)], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
        owned = []
        try:
            first = wait_child(app.pid)
            owned.append(first)
            # Wait for its authenticated page to load so this exercises reconnection, not startup.
            # A fresh profile installs its plugins first, which takes far longer than a warm boot.
            wait_listening(first)
            time.sleep(5)
            os.kill(first, signal.SIGTERM)
            second = wait_child(app.pid, excluding=first, timeout=30)
            owned.append(second)
            output, _ = app.communicate(timeout=120)
            if app.returncode != 0 or not snapshot.is_file() or snapshot.stat().st_size < 1000:
                raise RuntimeError("app did not complete an off-screen snapshot after reconnect")
            page = output.decode("utf-8", "replace")
            if "ui: connected" not in page:
                raise RuntimeError("recovered page did not show the connected DSH UI")
            if still_running(second):
                raise RuntimeError("replacement DSH server remained after app exit")
            print("reconnect smoke: authenticated page recovered; replacement server stopped on quit")
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=7)
                except subprocess.TimeoutExpired:
                    app.kill()
            for pid in owned:
                if still_running(pid):
                    os.kill(pid, signal.SIGTERM)


if __name__ == "__main__":
    main()
