import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

SUBMIT = Path(__file__).resolve().parent.parent / "calendar-helper-submit"


def write_status(home: Path, status="started", pid=None):
    (home / "status.json").write_text(json.dumps({"status": status, "pid": pid or os.getpid()}))


def fake_helper(home: Path, ok: bool, seen: list):
    """Answer the first command the way the real helper does."""
    commands = home / "commands"
    deadline = time.time() + 10
    while time.time() < deadline:
        files = list(commands.glob("*.json")) if commands.exists() else []
        if files:
            cmd = json.loads(files[0].read_text())
            seen.append(cmd)
            files[0].unlink()
            result = {"id": cmd["id"], "ok": ok, "lines": [f"echo={cmd['command']} {' '.join(cmd['args'])}"]}
            (home / "results" / f"{cmd['id']}.result.json").write_text(json.dumps(result))
            return
        time.sleep(0.05)


class SubmitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def submit(self, *args, timeout="5"):
        env = dict(os.environ, CALENDAR_HELPER_HOME=str(self.home), CALENDAR_HELPER_TIMEOUT=timeout)
        return subprocess.run([str(SUBMIT), *args], env=env, capture_output=True, text=True)

    def submit_with_helper(self, ok, *args):
        write_status(self.home)
        seen = []
        helper = threading.Thread(target=fake_helper, args=(self.home, ok, seen))
        helper.start()
        proc = self.submit(*args)
        helper.join()
        return proc, seen

    def test_round_trip_sends_cwd_and_cleans_up(self):
        proc, seen = self.submit_with_helper(True, "list-calendars")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "echo=list-calendars")
        self.assertEqual(seen[0]["cwd"], os.getcwd())
        self.assertEqual(list((self.home / "results").iterdir()), [])

    def test_error_result_exits_nonzero(self):
        proc, _ = self.submit_with_helper(False, "dump-events", "iCloud", "Work")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("echo=dump-events iCloud Work", proc.stdout)

    def test_no_command_prints_usage(self):
        proc = self.submit()
        self.assertEqual(proc.returncode, 2)
        self.assertIn("list-calendars", proc.stderr)

    def test_never_started(self):
        proc = self.submit("list-calendars")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("has never run", proc.stderr)
        self.assertIn("Start it with: open", proc.stderr)

    def test_helper_stopped(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        write_status(self.home, pid=dead.pid)
        proc = self.submit("list-calendars")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("not running", proc.stderr)
        self.assertFalse(any((self.home / "commands").glob("*.json")) if (self.home / "commands").exists() else False)

    def test_access_denied(self):
        write_status(self.home, status="access-denied")
        proc = self.submit("list-calendars")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Privacy & Security > Calendars", proc.stderr)

    def test_running_but_silent(self):
        write_status(self.home)
        proc = self.submit("list-calendars", timeout="1")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("timed out", proc.stderr)
        self.assertIn("did not run", proc.stderr)
        self.assertEqual(list((self.home / "commands").glob("*.json")), [])

    def test_bad_timeout_setting(self):
        write_status(self.home)
        proc = self.submit("list-calendars", timeout="soon")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("CALENDAR_HELPER_TIMEOUT must be a number", proc.stderr)
        self.assertFalse((self.home / "commands").exists())

    def test_helper_dies_after_picking_up_command(self):
        sleeper = subprocess.Popen(["sleep", "30"])
        write_status(self.home, pid=sleeper.pid)

        def claim_then_die():
            commands = self.home / "commands"
            deadline = time.time() + 10
            while time.time() < deadline:
                files = list(commands.glob("*.json")) if commands.exists() else []
                if files:
                    files[0].unlink()
                    sleeper.kill()
                    sleeper.wait()
                    return
                time.sleep(0.05)

        helper = threading.Thread(target=claim_then_die)
        helper.start()
        proc = self.submit("delete-event", "ABC", "r.json", timeout="10")
        helper.join()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("not running", proc.stderr)
        self.assertIn("may have run", proc.stderr)

    def test_stale_status_replaced_by_new_launch(self):
        write_status(self.home, status="access-denied", pid=999999)
        seen = []

        def relaunch():
            time.sleep(1)
            write_status(self.home)
            fake_helper(self.home, True, seen)

        helper = threading.Thread(target=relaunch)
        helper.start()
        proc = self.submit("list-calendars")
        helper.join()
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_waiting_for_permission(self):
        write_status(self.home, status="waiting-for-permission")
        proc = self.submit("list-calendars", timeout="3")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("allow calendar access", proc.stderr)


if __name__ == "__main__":
    unittest.main()
