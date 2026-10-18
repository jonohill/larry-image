"""Tests for root/usr/share/containers/systemd/media-metrics/media-metrics.py.

Run from the repo root with: python3 -m unittest discover -s tests

The parsers run against fixtures in fixtures/media-metrics, shaped like the
real APIs and status files but with made-up names, and must reproduce
expected/<collector>.prom exactly. The dashboard queries these metric names,
so a change to the expected files is a change to the dashboard's inputs.
Regenerate them with UPDATE_EXPECTED=1.
"""

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures" / "media-metrics"
EXPECTED = FIXTURES / "expected"
NOW = 1791800030.0

# The script lives under root/, which is copied into the image, so loading it
# must not leave a __pycache__ beside it.
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader(
    "media_metrics", str(REPO / "root/usr/share/containers/systemd/media-metrics/media-metrics.py"))
spec = importlib.util.spec_from_loader(loader.name, loader)
mm = importlib.util.module_from_spec(spec)
loader.exec_module(mm)


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


class ExpectedOutput(unittest.TestCase):
    def check(self, name, lines):
        text = "\n".join(lines) + "\n"
        path = EXPECTED / f"{name}.prom"
        if os.environ.get("UPDATE_EXPECTED"):
            path.write_text(text)
        self.assertEqual(text, path.read_text())

    def test_qbt(self):
        self.check("qbt", mm.parse_torrents(fixture("qbt-torrents.json"))
                   + mm.parse_transfer(fixture("qbt-transfer.json")))

    def test_dirs(self):
        files = [
            ("TV Shows/Example Show/Season 01/Example Show - S01E05 - Three Boys.mkv", 3398984313, 1791790000.7),
            ("TV Shows/Example Show/Season 01/Example Show - S01E05 - Three Boys.eng.srt", 44683, 1791790000.2),
            ("Movies/Old (1999)/Old (1999).AVI", 700000000, 1791780000.0),
        ]
        self.check("dirs", mm.parse_stage("sorted", files) + mm.parse_stage("plex", []))

    def test_av1ator(self):
        self.check("av1ator", mm.parse_av1ator(fixture("av1ator-encoding.json"), NOW))

    def test_rclone(self):
        self.check("rclone", mm.parse_rclone(fixture("rclone-moving.json"), NOW))

    def test_plex(self):
        sections = mm.parse_sections(fixture("plex-sections.json")["MediaContainer"])
        self.assertEqual(sections, [("1", "Films", 1), ("2", "TV shows", 4), ("6", "Downloads", 1)])
        recent = {"Films": "plex-recent-films.json", "TV shows": "plex-recent-tv.json",
                  "Downloads": "plex-recent-downloads.json"}
        lines = []
        for _, title, _ in sections:
            lines += mm.parse_recent(title, fixture(recent[title])["MediaContainer"])
        self.check("plex", lines)


class StatusFiles(unittest.TestCase):
    def test_stale_encode_is_down(self):
        with self.assertRaisesRegex(mm.SourceError, "121 s old"):
            mm.parse_av1ator(fixture("av1ator-encoding.json"), 1791800121.0)

    def test_passthrough_tolerates_a_long_copy(self):
        lines = mm.parse_av1ator(fixture("av1ator-passthrough.json"), 1791800000.0 + 1800)
        self.assertIn("media_encode_active 1", lines)
        self.assertFalse(any(line.startswith("media_encode_progress_ratio") for line in lines))
        with self.assertRaises(mm.SourceError):
            mm.parse_av1ator(fixture("av1ator-passthrough.json"), 1791800000.0 + 3601)

    def test_idle_av1ator(self):
        status = {"updated_at": NOW, "current": None, "skipped": []}
        self.assertEqual(mm.parse_av1ator(status, NOW), ["media_encode_active 0"])

    def test_last_stats_line_without_transferring(self):
        lines = mm.parse_rclone(fixture("rclone-finished.json"), NOW)
        self.assertIn("media_upload_done_bytes 2400000000", lines)
        self.assertFalse(any("file=" in line for line in lines))
        self.assertFalse(any(line.startswith("media_upload_eta_seconds") for line in lines))

    def test_missing_status_file(self):
        with self.assertRaisesRegex(mm.SourceError, "does not exist"):
            mm.read_status(Path("/nonexistent/status.json"))


class Dirs(unittest.TestCase):
    def test_scan_skips_partial_files(self):
        with tempfile.TemporaryDirectory() as root:
            season = Path(root) / "TV Shows" / "Show" / "Season 01"
            season.mkdir(parents=True)
            (season / "Show - S01E01.mkv").write_bytes(b"x" * 10)
            (season / "Show - S01E02.part.mkv").write_bytes(b"x" * 5)
            files = mm.scan_stage(Path(root))
        self.assertEqual([(p, s) for p, s, _ in files], [("TV Shows/Show/Season 01/Show - S01E01.mkv", 10)])

    def test_missing_stage_is_down(self):
        with self.assertRaises(mm.SourceError):
            mm.scan_stage(Path("/nonexistent"))


class FakeQbt(BaseHTTPRequestHandler):
    """Answers like qBittorrent: JSON for a whitelisted client, 403 otherwise."""

    whitelisted = True

    def do_GET(self):
        if not self.whitelisted:
            self.send_error(403)
            return
        reply = json.dumps({"ok": True}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, format, *args):
        pass


class Qbt(unittest.TestCase):
    def setUp(self):
        self.server = HTTPServer(("127.0.0.1", 0), FakeQbt)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = mock.patch.object(mm, "QBT_URL", f"http://127.0.0.1:{self.server.server_port}")
        self.url.start()

    def tearDown(self):
        self.url.stop()
        self.server.shutdown()
        self.server.server_close()

    def test_whitelisted(self):
        with mock.patch.object(FakeQbt, "whitelisted", True):
            self.assertEqual(mm.qbt_get("/api/v2/torrents/info"), {"ok": True})

    def test_not_whitelisted_names_the_cause(self):
        with mock.patch.object(FakeQbt, "whitelisted", False), \
                self.assertRaisesRegex(mm.SourceError, "AuthSubnetWhitelist"):
            mm.qbt_get("/api/v2/torrents/info")


class Render(unittest.TestCase):
    def test_groups_metrics_and_reports_failures(self):
        def ok():
            return ["media_b 1", 'media_a{x="1"} 1', "media_b 2"]

        def broken():
            raise mm.SourceError("gone")

        with mock.patch.object(mm, "last_errors", {}), \
                mock.patch("sys.stderr"):
            text = mm.render({"ok": ok, "broken": broken})
        names = [line.split("{")[0].split(" ")[0] for line in text.splitlines()]
        self.assertEqual(names, sorted(names))
        self.assertIn('media_metrics_up{collector="ok"} 1', text)
        self.assertIn('media_metrics_up{collector="broken"} 0', text)
        self.assertLess(text.index("media_b 1"), text.index("media_b 2"))


if __name__ == "__main__":
    unittest.main()
