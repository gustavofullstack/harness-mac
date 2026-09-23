#!/usr/bin/env python3
"""Exercise the real DSH.app crash/reconnect path without using the foreground screen.

Requires an installed `dsh` on PATH and a bundled `dist/DSH.app` in this checkout.
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
APP = ROOT / "dist/DSH.app/Contents/MacOS/DSH"


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


def wait_child(parent_pid: int, excluding: int | None = None, timeout: float = 45) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pid := server_child(parent_pid, excluding):
            return pid
        time.sleep(0.1)
    raise RuntimeError("app did not start or restart its DSH server")


def wait_ready(marker: Path, app: subprocess.Popen[bytes], timeout: float = 120) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if marker.is_file() and marker.read_text() == "connected\n":
            return
        if app.poll() is not None:
            raise RuntimeError("app exited before its authenticated page was ready")
        time.sleep(0.5)
    child = server_child(app.pid)
    listening = False
    if child:
        probe = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(child), "-iTCP", "-sTCP:LISTEN", "-t"],
                               capture_output=True, text=True, check=False)
        listening = bool(probe.stdout.strip())
    raise RuntimeError(f"authenticated DSH page did not become ready (child={child is not None}, "
                       f"listening={listening}, navigation={marker.is_file()})")


def still_running(pid: int) -> bool:
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], text=True,
                            capture_output=True, check=False)
    return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.lstrip().startswith("Z")


def main() -> None:
    if not APP.is_file():
        raise SystemExit("bundle DSH first: scripts/bundle.sh")
    with tempfile.TemporaryDirectory(prefix="dsh-reconnect-") as profile:
        snapshot = Path(profile) / "recovered.png"
        ready = Path(profile) / "ready.txt"
        env = os.environ.copy()
        env.update(DSH_HOME=profile, HARNESS_SNAPSHOT=str(snapshot), HARNESS_SNAPSHOT_DELAY="12",
                   HARNESS_READY_FILE=str(ready))
        app = subprocess.Popen([str(APP)], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
        owned = []
        try:
            # Wait for the authenticated WebKit page, not merely an open TCP socket.
            wait_ready(ready, app)
            for _ in range(3):
                first = wait_child(app.pid)
                try:
                    os.kill(first, signal.SIGTERM)
                    break
                except ProcessLookupError:
                    # DSH can exit during its own cold boot; require a new connected page.
                    ready.unlink(missing_ok=True)
                    wait_ready(ready, app)
            else:
                raise RuntimeError("DSH exited repeatedly before it could be terminated")
            owned.append(first)
            second = wait_child(app.pid, excluding=first, timeout=90)
            owned.append(second)
            output, _ = app.communicate(timeout=120)
            if app.returncode != 0 or not snapshot.is_file() or snapshot.stat().st_size < 1000:
                raise RuntimeError("app did not complete an off-screen snapshot after reconnect")
            page = output.decode("utf-8", "replace")
            if "ui: connected" not in page:
                # App stdout is deliberately limited to sanitized UI/snapshot state.
                raise RuntimeError(f"recovered page did not show the connected DSH UI: {page.strip()}")
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
