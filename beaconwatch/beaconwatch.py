#!/usr/bin/env python3
"""Receive Beacon 73 APRS packets and publish one map point per callsign."""

from __future__ import annotations

import json
import logging
import math
import os
import re
import signal
import socket
import sqlite3
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


LOG = logging.getLogger("beaconwatch")
TOCALL = "APB730"
MOVEMENT_THRESHOLD_KM = 250.0
CALLSIGN_RE = re.compile(r"^[A-Z0-9]{3,9}(?:-[A-Z0-9]{1,2})?$")
HEADER_RE = re.compile(
    r"^(?P<source>[A-Za-z0-9]{3,9}(?:-[A-Za-z0-9]{1,2})?)>"
    r"(?P<destination>[A-Za-z0-9]{1,9})(?:,[^:]*)?:(?P<information>.*)$"
)
POSITION_RE = re.compile(
    r"(?P<lat_degrees>\d{2})(?P<lat_minutes>\d{2}\.\d{2})(?P<lat_hemisphere>[NS])"
    r".(?P<lon_degrees>\d{3})(?P<lon_minutes>\d{2}\.\d{2})(?P<lon_hemisphere>[EW])"
)


@dataclass(frozen=True)
class Position:
    callsign: str
    latitude: float
    longitude: float


def parse_beacon_position(line: str) -> Position | None:
    """Parse the uncompressed APRS position format emitted by Beacon 73."""
    header = HEADER_RE.match(line.strip())
    if not header or header.group("destination").upper() != TOCALL:
        return None

    callsign = header.group("source").upper()
    if len(callsign) > 9 or not CALLSIGN_RE.fullmatch(callsign):
        return None

    information = header.group("information")
    if not information or information[0] not in "!=/@":
        return None

    # ! and = are followed immediately by the position. / and @ include a
    # seven-character timestamp first. Beacon 73 currently emits ! packets.
    offset = 1 if information[0] in "!=" else 8
    position = POSITION_RE.match(information, offset)
    if not position:
        return None

    latitude = int(position.group("lat_degrees")) + float(position.group("lat_minutes")) / 60.0
    longitude = int(position.group("lon_degrees")) + float(position.group("lon_minutes")) / 60.0
    if position.group("lat_hemisphere") == "S":
        latitude = -latitude
    if position.group("lon_hemisphere") == "W":
        longitude = -longitude
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    return Position(callsign, latitude, longitude)


def distance_km(first: Position, second: Position) -> float:
    """Return great-circle distance using the haversine formula."""
    radius_km = 6371.0088
    lat1, lat2 = math.radians(first.latitude), math.radians(second.latitude)
    delta_lat = lat2 - lat1
    delta_lon = math.radians(second.longitude - first.longitude)
    value = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    )
    return 2 * radius_km * math.asin(min(1.0, math.sqrt(value)))


class LocationStore:
    def __init__(self, database_path: Path):
        self.database_path = database_path
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS locations (
                    callsign TEXT PRIMARY KEY,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL
                )
                """
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self.database_path, timeout=10)

    def record(self, position: Position) -> str:
        """Insert once, or replace only after movement exceeds the threshold."""
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT latitude, longitude FROM locations WHERE callsign = ?",
                (position.callsign,),
            ).fetchone()
            if row is None:
                connection.execute(
                    "INSERT INTO locations (callsign, latitude, longitude) VALUES (?, ?, ?)",
                    (position.callsign, position.latitude, position.longitude),
                )
                return "inserted"

            current = Position(position.callsign, row[0], row[1])
            if distance_km(current, position) <= MOVEMENT_THRESHOLD_KM:
                return "unchanged"

            connection.execute(
                "UPDATE locations SET latitude = ?, longitude = ? WHERE callsign = ?",
                (position.latitude, position.longitude, position.callsign),
            )
            return "moved"

    def all(self) -> list[dict[str, object]]:
        with self._lock, self._connect() as connection:
            rows = connection.execute(
                "SELECT callsign, latitude, longitude FROM locations ORDER BY callsign"
            ).fetchall()
        return [
            {"callsign": row[0], "latitude": row[1], "longitude": row[2]}
            for row in rows
        ]


class APRSReceiver(threading.Thread):
    def __init__(self, store: LocationStore, stop_event: threading.Event):
        super().__init__(name="aprs-is", daemon=True)
        self.store = store
        self.stop_event = stop_event
        self.host = os.environ.get("BEACONWATCH_APRS_HOST", "rotate.aprs2.net")
        self.port = int(os.environ.get("BEACONWATCH_APRS_PORT", "14580"))
        self.login = os.environ.get("BEACONWATCH_APRS_LOGIN", "K6BAT-15").upper()
        self.connected = threading.Event()

    def run(self) -> None:
        delay = 2
        while not self.stop_event.is_set():
            try:
                self._receive()
                delay = 2
            except (OSError, TimeoutError) as error:
                LOG.warning("APRS-IS connection ended: %s; retrying in %s seconds", error, delay)
                self.stop_event.wait(delay)
                delay = min(delay * 2, 60)
            finally:
                self.connected.clear()

    def _receive(self) -> None:
        LOG.info("Connecting to APRS-IS %s:%s with filter u/%s", self.host, self.port, TOCALL)
        with socket.create_connection((self.host, self.port), timeout=30) as connection:
            connection.settimeout(90)
            login_line = (
                f"user {self.login} pass -1 vers BeaconWatch 1.0 "
                f"filter u/{TOCALL}\r\n"
            )
            connection.sendall(login_line.encode("ascii"))
            with connection.makefile("rb") as stream:
                for raw_line in stream:
                    if self.stop_event.is_set():
                        return
                    line = raw_line.decode("utf-8", errors="replace").strip()
                    if line.lower().startswith("# logresp"):
                        self.connected.set()
                        LOG.info("APRS-IS receive-only login accepted")
                    if not line or line.startswith("#"):
                        continue
                    position = parse_beacon_position(line)
                    if position is None:
                        continue
                    result = self.store.record(position)
                    if result != "unchanged":
                        # The public map intentionally exposes callsigns, but operational
                        # logs must not become a second store of callsign activity.
                        LOG.info("Location %s", result)
            raise ConnectionError("APRS-IS closed the stream")


class BeaconWatchHandler(BaseHTTPRequestHandler):
    server_version = "BeaconWatch/1.0"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._handle_request(send_body=True)

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._handle_request(send_body=False)

    def _handle_request(self, send_body: bool) -> None:
        path = urlsplit(self.path).path
        if path in ("/beaconwatch/api/locations", "/api/locations"):
            locations = self.server.store.all()  # type: ignore[attr-defined]
            self._send_json(
                {
                    "aprsConnected": self.server.receiver.connected.is_set(),  # type: ignore[attr-defined]
                    "count": len(locations),
                    "locations": locations,
                },
                send_body,
            )
            return
        if path in ("/beaconwatch/health", "/health"):
            self._send_json(
                {
                    "status": "ok",
                    "aprsConnected": self.server.receiver.connected.is_set(),  # type: ignore[attr-defined]
                },
                send_body,
            )
            return
        self._send_static(path, send_body)

    def _send_json(self, payload: object, send_body: bool) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def _send_static(self, path: str, send_body: bool) -> None:
        relative = path.removeprefix("/beaconwatch").lstrip("/") or "index.html"
        if relative not in {"index.html", "styles.css", "app.js", "countries-50m.json"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        file_path = self.server.web_root / relative  # type: ignore[attr-defined]
        try:
            body = file_path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_type = {
            ".html": "text/html; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".js": "text/javascript; charset=utf-8",
            ".json": "application/json; charset=utf-8",
        }[file_path.suffix]
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=300")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self' https://unpkg.com; "
            "style-src 'self' https://unpkg.com; img-src 'self' data: https://server.arcgisonline.com; "
            "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def log_message(self, format_string: str, *args: object) -> None:
        LOG.info("HTTP %s", format_string % args)


class BeaconWatchServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        store: LocationStore,
        web_root: Path,
        receiver: APRSReceiver,
    ):
        super().__init__(address, BeaconWatchHandler)
        self.store = store
        self.web_root = web_root
        self.receiver = receiver


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("BEACONWATCH_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    root = Path(__file__).resolve().parent
    database_path = Path(os.environ.get("BEACONWATCH_DATABASE", root / "data" / "locations.db"))
    listen_host = os.environ.get("BEACONWATCH_LISTEN_HOST", "127.0.0.1")
    listen_port = int(os.environ.get("BEACONWATCH_LISTEN_PORT", "20242"))
    store = LocationStore(database_path)
    stop_event = threading.Event()
    receiver = APRSReceiver(store, stop_event)
    server = BeaconWatchServer((listen_host, listen_port), store, root / "web", receiver)

    def stop(_signum: int, _frame: object) -> None:
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    receiver.start()
    LOG.info("BeaconWatch listening on http://%s:%s/beaconwatch/", listen_host, listen_port)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        stop_event.set()
        server.server_close()


if __name__ == "__main__":
    main()
