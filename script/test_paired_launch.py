"""Exercise the launcher's fresh-edition wait without launching an app or measuring the Mac."""

from pathlib import Path
import subprocess
import unittest


class FreshEditionWaitTests(unittest.TestCase):
    def test_confirmed_swap_and_timeout(self):
        source = Path(__file__).with_name("paired_launch.sh").read_text()
        wait = source[source.index("wait_for_fresh_edition()") : source.index("\none() {")]
        wait = wait.replace("/usr/bin/log show", "mock_log show")
        script = """
set -eu
mock_log() { printf '%s\\n' "$MOCK_LINE"; }
""" + wait + """
MOCK_LINE='today_fresh_edition_ready outcome=confirmed '
wait_for_fresh_edition now $$ any
if wait_for_fresh_edition now $$ swapped; then exit 1; fi
MOCK_LINE='today_fresh_edition_ready outcome=swapped '
wait_for_fresh_edition now $$ swapped
MOCK_LINE=''
NEWS_PAIRED_SWAP_WAIT=1
if wait_for_fresh_edition now $$ any; then exit 1; fi
"""
        subprocess.run(["bash", "-c", script], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
