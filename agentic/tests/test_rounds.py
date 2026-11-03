#!/usr/bin/env python3
"""Worker rounds in the overview (lib/overview.sh): the task-<id>.service units a coordinating session starts outside a
campaign, read from a fake systemctl."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest

from test_campaign import Repo


class RoundTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentic-rounds-")
        self.repo = Repo()
        root = Path(self.temp.name)
        self.running = root / "runs" / "API-001"
        self.waiting = root / "runs" / "API-002-fix1"
        for run in (self.running, self.waiting):
            run.mkdir(parents=True)
        (self.running / "started").write_text("2026-11-02T10:00:00-03:00\n")
        (self.running / "accounts.log").write_text(
            "2026-11-02T10:00:00-03:00 attempt 1 account /home/u/.claude\n"
            "2026-11-02T10:20:00-03:00 attempt 2 account /home/u/.claude-work\n")
        (self.waiting / "waiting").write_text("until=2026-11-02T15:30:00-03:00\n")
        units = {
            "task-API-001.service": f"/bin/launch {self.repo.root} {self.running} claude-opus-5-5 high 90 /p.md",
            "task-API-002-fix1.service": f"/bin/launch /nowhere {self.waiting} claude-sonnet-5-5 medium 45",
            "other.service": "/bin/other",
        }
        fake = root / "systemctl"
        lines = "\n".join(f"{name} loaded active running [systemd-run] {argv}" for name, argv in units.items()
                          if name.startswith("task-"))
        cases = "\n".join(
            f'  "{name}") printf "%s\\n" "{{ path=/bin/launch ; argv[]={argv} ; ignore_errors=no ; pid=1 }}" ;;'
            for name, argv in units.items())
        fake.write_text(f"""#!/usr/bin/env bash
case "$2" in
  list-units) printf '%s\\n' "{lines}" ;;
  show)
    if [[ $4 == ActiveEnterTimestamp ]]; then echo "Mon 2026-11-02 11:00:00 -03"; exit 0; fi
    case "${{@: -1}}" in
{cases}
    esac ;;
esac
""")
        fake.chmod(0o755)
        self.repo.env.update(AGENTIC_SYSTEMCTL=str(fake), AGENTIC_DISPLAY_TZ="America/Sao_Paulo")

    def tearDown(self):
        self.repo.close()
        self.temp.cleanup()

    def test_the_overview_lists_running_and_waiting_rounds(self):
        rounds = json.loads(self.repo.command("overview", "--json").stdout)["rounds"]
        self.assertEqual([item["id"] for item in rounds], ["API-001", "API-002-fix1"])
        running, waiting = rounds
        self.assertEqual((running["phase"], running["model"], running["effort"], running["deadline_minutes"]),
                         ("running", "claude-opus-5-5", "high", 90))
        self.assertEqual((running["attempts"], running["account"], running["started_local_time"]),
                         (2, "claude-work", "10:00 (02/11)"))
        self.assertEqual(running["repo"], self.repo.root.name)
        self.assertEqual((waiting["phase"], waiting["waiting_until_local_time"]), ("waiting-for-quota", "15:30 (02/11)"))
        self.assertEqual((waiting["repo"], waiting["attempts"], waiting["started_local_time"]), (None, 0, "11:00 (02/11)"))
        text = self.repo.command("overview").stdout
        self.assertIn("Round API-002-fix1: waiting-for-quota until 15:30 (02/11)", text)

    def test_without_systemctl_the_overview_has_no_rounds(self):
        self.repo.env["AGENTIC_SYSTEMCTL"] = "/nonexistent/systemctl"
        overview = json.loads(self.repo.command("overview", "--json").stdout)
        self.assertEqual(overview["rounds"], [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
