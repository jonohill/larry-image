#!/usr/bin/env python3
"""Prometheus exporter for the media pipeline.

Serves GET /metrics and reads every source afresh on each request:

  qbt      downloads, from the qBittorrent WebUI API
  dirs     files waiting in sorted-media and plex-media
  av1ator  the current encode, from av1ator's --status-dir file
  rclone   the current upload, from rclone-move's STATUS_DIR file
  plex     recently added movies and episodes, from the Plex API

Every collector also reports media_metrics_up and
media_metrics_duration_seconds. A collector whose source is unreachable,
missing or stale reports only those two, so its item series go stale.

The parse_* functions take source data and return metric lines, so the
tests can feed them saved fixtures. Standard library only: it runs on the
stock python image.
"""

import json
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PORT = int(os.environ.get("PORT", "9101"))
QBT_URL = os.environ.get("QBT_URL", "http://qbittorrent:9092")
PLEX_URL = os.environ.get("PLEX_URL", "http://plex:32400")
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
STATUS_DIR = Path(os.environ.get("STATUS_DIR", "/status"))

# VictoriaMetrics gives up on a scrape after 10 s, and the plex collector
# makes several requests.
HTTP_TIMEOUT = 3

# av1ator writes at least every 30 s poll and every 5 s while encoding,
# rclone-move every 30 s loop and every 10 s while moving.
STATUS_STALE_SECONDS = 120
# av1ator doesn't write while copying a file through, which for a large 4K
# file takes minutes.
PASSTHROUGH_STALE_SECONDS = 3600

DOWNLOADING_STATES = frozenset({
    "downloading", "stalledDL", "metaDL", "forcedDL", "queuedDL",
    "checkingDL", "stoppedDL", "pausedDL", "forcedMetaDL",
})
QBT_ETA_INFINITE = 8640000

# Matches av1ator's own list, so "video" here means a file av1ator would encode.
VIDEO_EXTENSIONS = frozenset({
    ".mkv", ".mp4", ".m4v", ".mov", ".avi", ".webm",
    ".ts", ".m2ts", ".mts", ".wmv", ".flv",
    ".mpg", ".mpeg", ".vob", ".ogv", ".ogm", ".3gp", ".divx",
})
STAGES = {"sorted": "sorted-media", "plex": "plex-media"}

UPLOAD_STATES = ("idle", "waiting", "moving", "cleanup")

PLEX_RECENT_ITEMS = 20
PLEX_SECTION_TYPES = {"movie": 1, "show": 4}


class SourceError(Exception):
    """The source can't be read. The message goes to the journal."""


def escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def metric(name, labels=None, value=1):
    """One exposition line. Booleans become 0 or 1."""
    if isinstance(value, bool):
        value = int(value)
    label_set = ""
    if labels:
        label_set = "{" + ",".join(f'{k}="{escape(v)}"' for k, v in labels.items()) + "}"
    return f"{name}{label_set} {value}"


# ---------------------------------------------------------------- qbt


def parse_torrents(torrents):
    lines = []
    for t in torrents:
        if t["state"] not in DOWNLOADING_STATES:
            continue
        labels = {"hash": t["hash"], "name": t["name"]}
        # State is on its own series so the numeric series keep their
        # identity when it changes.
        lines.append(metric("media_torrent_info", {**labels, "state": t["state"]}))
        lines.append(metric("media_torrent_progress_ratio", labels, t["progress"]))
        lines.append(metric("media_torrent_size_bytes", labels, t["size"]))
        lines.append(metric("media_torrent_left_bytes", labels, t["amount_left"]))
        lines.append(metric("media_torrent_download_bytes_per_second", labels, t["dlspeed"]))
        if t["eta"] != QBT_ETA_INFINITE:
            lines.append(metric("media_torrent_eta_seconds", labels, t["eta"]))
        lines.append(metric("media_torrent_availability", labels, t["availability"]))
        lines.append(metric("media_torrent_seeds", labels, t["num_seeds"]))
        lines.append(metric("media_torrent_added_timestamp_seconds", labels, t["added_on"]))
    return lines


def parse_transfer(info):
    return [
        metric("media_qbt_download_bytes_per_second", None, info["dl_info_speed"]),
        metric("media_qbt_upload_bytes_per_second", None, info["up_info_speed"]),
    ]


def qbt_get(path):
    """GET a WebUI API path without logging in. qBittorrent's
    AuthSubnetWhitelist must include this container's fixed address."""
    try:
        with urllib.request.urlopen(f"{QBT_URL}{path}", timeout=HTTP_TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 403:
            raise SourceError("qBittorrent wants a login: is this container's address "
                              "in its WebUI AuthSubnetWhitelist?") from None
        raise


def collect_qbt():
    return (parse_torrents(qbt_get("/api/v2/torrents/info"))
            + parse_transfer(qbt_get("/api/v2/transfer/info")))


# ---------------------------------------------------------------- dirs


def scan_stage(root):
    """(path relative to root, size, ctime) for every file under root,
    skipping in-progress *.part.* files."""
    if not root.is_dir():
        raise SourceError(f"{root} is not a directory")
    files = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if ".part." in name:
                continue
            path = Path(dirpath) / name
            try:
                st = path.stat()
            except OSError:
                continue
            files.append((path.relative_to(root).as_posix(), st.st_size, st.st_ctime))
    return files


def parse_stage(stage, files):
    lines = []
    counts = {"video": 0, "other": 0}
    total = 0
    for path, size, ctime in files:
        total += size
        if Path(path).suffix.lower() not in VIDEO_EXTENSIONS:
            counts["other"] += 1
            continue
        counts["video"] += 1
        labels = {"stage": stage, "path": path}
        lines.append(metric("media_file_size_bytes", labels, size))
        # Hard-linking and renaming both update ctime, so it approximates
        # when the file arrived in this stage.
        lines.append(metric("media_file_changed_timestamp_seconds", labels, int(ctime)))
    for kind, count in counts.items():
        lines.append(metric("media_stage_files", {"stage": stage, "kind": kind}, count))
    lines.append(metric("media_stage_bytes", {"stage": stage}, total))
    return lines


def collect_dirs():
    lines = []
    for stage, name in STAGES.items():
        lines += parse_stage(stage, scan_stage(DATA_DIR / name))
    return lines


# ---------------------------------------------------------------- status files


def read_status(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        raise SourceError(f"{path} does not exist") from None


def check_fresh(status, now, limit):
    age = now - status["updated_at"]
    if age > limit:
        raise SourceError(f"status is {age:.0f} s old")


def parse_av1ator(status, now):
    current = status.get("current")
    passthrough = current is not None and current.get("action") == "passthrough"
    check_fresh(status, now, PASSTHROUGH_STALE_SECONDS if passthrough else STATUS_STALE_SECONDS)

    lines = [metric("media_encode_active", None, current is not None)]
    if current is not None:
        labels = {"file": current["src"], "action": current["action"]}
        for name, field in (
            ("media_encode_start_timestamp_seconds", "started_at"),
            ("media_encode_input_bytes", "input_bytes"),
            ("media_encode_output_bytes", "output_bytes"),
            ("media_encode_duration_seconds", "duration_seconds"),
            ("media_encode_position_seconds", "position_seconds"),
            ("media_encode_fps", "fps"),
            ("media_encode_speed_ratio", "speed"),
        ):
            if current.get(field) is not None:
                lines.append(metric(name, labels, current[field]))
        duration = current.get("duration_seconds")
        position = current.get("position_seconds")
        speed = current.get("speed")
        if duration and position is not None:
            lines.append(metric("media_encode_progress_ratio", labels, round(position / duration, 6)))
            if speed:
                lines.append(metric("media_encode_eta_seconds", labels, round((duration - position) / speed)))
    for s in status.get("skipped", []):
        lines.append(metric("media_encode_skipped_timestamp_seconds",
                            {"file": s["src"], "reason": s["reason"]}, s["at"]))
    return lines


def parse_rclone(status, now):
    check_fresh(status, now, STATUS_STALE_SECONDS)

    lines = [metric("media_upload_state", {"state": s}, status["state"] == s) for s in UPLOAD_STATES]
    stats = (status.get("move") or {}).get("stats") or {}
    lines.append(metric("media_upload_bytes_per_second", None, stats.get("speed", 0)))
    if stats:
        lines.append(metric("media_upload_done_bytes", None, stats["bytes"]))
        lines.append(metric("media_upload_total_bytes", None, stats["totalBytes"]))
        if stats.get("eta") is not None:
            lines.append(metric("media_upload_eta_seconds", None, stats["eta"]))
    # rclone leaves the key out of its last stats line rather than sending
    # an empty list.
    for t in stats.get("transferring", []):
        labels = {"file": t["name"]}
        lines.append(metric("media_upload_file_size_bytes", labels, t["size"]))
        lines.append(metric("media_upload_file_done_bytes", labels, t["bytes"]))
        lines.append(metric("media_upload_file_bytes_per_second", labels, t["speed"]))
        if t.get("eta") is not None:
            lines.append(metric("media_upload_file_eta_seconds", labels, t["eta"]))
    last = status.get("last_move")
    if last:
        ok = "true" if last["ok"] else "false"
        lines.append(metric("media_upload_last_timestamp_seconds", {"ok": ok}, last["finished_at"]))
        lines.append(metric("media_upload_last_bytes", None, last["bytes"]))
    return lines


def collect_av1ator():
    return parse_av1ator(read_status(STATUS_DIR / "av1ator" / "status.json"), time.time())


def collect_rclone():
    return parse_rclone(read_status(STATUS_DIR / "rclone-move" / "status.json"), time.time())


# ---------------------------------------------------------------- plex


def plex_get(path):
    token = os.environ.get("PLEX_TOKEN")
    if not token:
        raise SourceError("PLEX_TOKEN is not set")
    request = urllib.request.Request(
        f"{PLEX_URL}{path}", headers={"X-Plex-Token": token, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as r:
        return json.load(r)["MediaContainer"]


def parse_sections(container):
    """(key, title, Plex item type) for each movie and show section."""
    return [
        (d["key"], d["title"], PLEX_SECTION_TYPES[d["type"]])
        for d in container.get("Directory", [])
        if d["type"] in PLEX_SECTION_TYPES
    ]


def parse_recent(section, container):
    lines = []
    for item in container.get("Metadata", []):
        title = item["title"]
        if item["type"] == "episode":
            show = item.get("grandparentTitle", "")
            if item.get("parentIndex") is not None and item.get("index") is not None:
                title = f"S{item['parentIndex']:02}E{item['index']:02} - {title}"
        else:
            show = ""
            if item.get("year"):
                title = f"{title} ({item['year']})"
        labels = {"section": section, "show": show, "title": title, "rating_key": item["ratingKey"]}
        lines.append(metric("media_plex_added_timestamp_seconds", labels, item["addedAt"]))
    return lines


def collect_plex():
    lines = []
    for key, title, item_type in parse_sections(plex_get("/library/sections")):
        query = urllib.parse.urlencode({
            "type": item_type,
            "sort": "addedAt:desc",
            "X-Plex-Container-Start": 0,
            "X-Plex-Container-Size": PLEX_RECENT_ITEMS,
        })
        lines += parse_recent(title, plex_get(f"/library/sections/{key}/all?{query}"))
    return lines


# ---------------------------------------------------------------- server


COLLECTORS = {
    "qbt": collect_qbt,
    "dirs": collect_dirs,
    "av1ator": collect_av1ator,
    "rclone": collect_rclone,
    "plex": collect_plex,
}

last_errors = {}


def run_collector(name, collect):
    start = time.monotonic()
    lines = []
    error = None
    try:
        lines = collect()
    except SourceError as e:
        error = str(e)
    except Exception as e:
        error = f"{type(e).__name__}: {e}"
    # Logged on change only, so a source that stays down for days doesn't
    # write a line every scrape.
    if error != last_errors.get(name):
        print(f"{name}: {error or 'recovered'}", file=sys.stderr, flush=True)
        last_errors[name] = error
    labels = {"collector": name}
    return lines + [
        metric("media_metrics_up", labels, error is None),
        metric("media_metrics_duration_seconds", labels, round(time.monotonic() - start, 3)),
    ]


def render(collectors=COLLECTORS):
    lines = []
    for name, collect in collectors.items():
        lines += run_collector(name, collect)
    # The exposition format wants each metric's lines together. The sort is
    # stable, so lines keep their order within a metric.
    lines.sort(key=lambda line: line.split("{", 1)[0].split(" ", 1)[0])
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    # As PID 1 in the container, the process ignores SIGTERM unless it
    # handles it.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    HTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
