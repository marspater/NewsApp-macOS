import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import summarize_signposts  # noqa: E402

EXPORT = """<?xml version="1.0"?>
<trace-query-result><node>
<schema name="os-signpost-interval"><col><mnemonic>duration</mnemonic></col><col><mnemonic>subsystem</mnemonic></col>
<col><mnemonic>category</mnemonic></col><col><mnemonic>name</mnemonic></col></schema>
<row><duration id="1" fmt="2 ms">2000000</duration><string id="2">com.marspater.news</string>
<string id="3">Feeds</string><string id="4">Refresh</string></row>
<row><duration id="5" fmt="4 ms">4000000</duration><string ref="2"/><string ref="3"/><string ref="4"/></row>
<row><duration ref="1"/><string id="6">com.apple.other</string><string ref="3"/><string ref="4"/></row>
</node></trace-query-result>"""


class SummarizeTests(unittest.TestCase):
    def test_refs_resolve_and_other_subsystems_drop(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "s.xml")
            with open(source, "w") as handle:
                handle.write(EXPORT)
            summarize_signposts.main(["x", source, os.path.join(directory, "out"), "--meta", "a=b"])
            with open(os.path.join(directory, "out.json")) as handle:
                result = json.load(handle)
        self.assertEqual(result["meta"], {"a": "b"})
        self.assertEqual(result["intervals"], [
            {"category": "Feeds", "name": "Refresh", "count": 2, "median_ms": 3.0, "p90_ms": 4.0}])


if __name__ == "__main__":
    unittest.main()
