# Cassette — Music client for Subsonic/OpenSubsonic servers
# Copyright (C) 2026 Mathieu Dubart
# Licensed under the Mozilla Public License 2.0.
# See LICENSE file in the project root for full license information.

"""cassette-ratings: stores Cassette's 0.0-10.0 ratings next to a Navidrome server.

Standard library only. Runs behind the same reverse proxy as Navidrome, mounted at
`<navidrome base URL>/ratings/`. Every request (except health) carries the user's Subsonic
token credentials in headers; they are checked against Navidrome's own `ping` endpoint, so
there is no separate account.

API (paths are relative to the mount point; a leading `/ratings` is accepted and stripped):

    GET    /v1/health                          -> {"status": "ok"}              (no auth)
    GET    /v1/ratings?since=<cursor>          -> {"ratings": [...], "cursor": <int>}
    PUT    /v1/ratings/<type>/<id>             body {"value": 8.4, "updatedAt": <ms>}
    DELETE /v1/ratings/<type>/<id>?updatedAt=<ms>

Auth headers: X-Cassette-User, X-Cassette-Token (md5(password + salt)), X-Cassette-Salt.

Conflicts are last-write-wins on the client's `updatedAt`. Deletes are kept as tombstones so
other devices learn about them. `cursor` is a server-assigned sequence, not a client clock, so
devices with skewed clocks still see every change.
"""

import hashlib
import json
import logging
import os
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ITEM_TYPES = {"song", "album", "artist"}
MAX_ID_LENGTH = 512
MAX_BODY_BYTES = 4096

log = logging.getLogger("cassette-ratings")


class Config:
    def __init__(self, env=os.environ):
        self.navidrome_url = env.get("NAVIDROME_URL", "http://navidrome:4533").rstrip("/")
        self.db_path = env.get("DB_PATH", "/data/ratings.db")
        self.host = env.get("HOST", "0.0.0.0")
        self.port = int(env.get("PORT", "8000"))
        self.auth_cache_seconds = int(env.get("AUTH_CACHE_SECONDS", "300"))
        self.auth_timeout_seconds = float(env.get("AUTH_TIMEOUT_SECONDS", "10"))


# MARK: - Storage

class Store:
    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS ratings (
                username    TEXT    NOT NULL,
                item_type   TEXT    NOT NULL,
                item_id     TEXT    NOT NULL,
                value       REAL,
                updated_at  INTEGER NOT NULL,
                deleted     INTEGER NOT NULL DEFAULT 0,
                seq         INTEGER NOT NULL,
                PRIMARY KEY (username, item_type, item_id)
            )
            """
        )
        self._conn.execute("CREATE INDEX IF NOT EXISTS ratings_user_seq ON ratings (username, seq)")
        self._conn.commit()

    def _next_seq(self):
        row = self._conn.execute("SELECT COALESCE(MAX(seq), 0) FROM ratings").fetchone()
        return row[0] + 1

    def upsert(self, username, item_type, item_id, value, updated_at, deleted):
        """Applies a change unless a newer one is already stored. Returns (applied, row)."""
        with self._lock:
            current = self._conn.execute(
                "SELECT value, updated_at, deleted FROM ratings WHERE username=? AND item_type=? AND item_id=?",
                (username, item_type, item_id),
            ).fetchone()
            if current is not None and current[1] > updated_at:
                return False, _row(item_type, item_id, current[0], current[1], current[2])
            seq = self._next_seq()
            self._conn.execute(
                """
                INSERT INTO ratings (username, item_type, item_id, value, updated_at, deleted, seq)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (username, item_type, item_id) DO UPDATE SET
                    value=excluded.value, updated_at=excluded.updated_at,
                    deleted=excluded.deleted, seq=excluded.seq
                """,
                (username, item_type, item_id, None if deleted else value, updated_at, 1 if deleted else 0, seq),
            )
            self._conn.commit()
            return True, _row(item_type, item_id, None if deleted else value, updated_at, deleted)

    def changes_since(self, username, since):
        with self._lock:
            rows = self._conn.execute(
                "SELECT item_type, item_id, value, updated_at, deleted, seq FROM ratings "
                "WHERE username=? AND seq>? ORDER BY seq",
                (username, since),
            ).fetchall()
        cursor = rows[-1][5] if rows else since
        return [_row(r[0], r[1], r[2], r[3], r[4]) for r in rows], cursor


def _row(item_type, item_id, value, updated_at, deleted):
    return {
        "type": item_type,
        "id": item_id,
        "value": None if deleted else value,
        "updatedAt": updated_at,
        "deleted": bool(deleted),
    }


# MARK: - Auth

class NavidromeAuthenticator:
    """Checks Subsonic token credentials against Navidrome's ping, with a short cache."""

    def __init__(self, config):
        self.config = config
        self._cache = {}
        self._lock = threading.Lock()

    def verify(self, user, token, salt):
        if not (user and token and salt):
            return False
        key = hashlib.sha256(f"{user}\0{token}\0{salt}".encode()).hexdigest()
        now = time.monotonic()
        with self._lock:
            expiry = self._cache.get(key)
            if expiry is not None and expiry > now:
                return True
        ok = self._ping(user, token, salt)
        if ok:
            with self._lock:
                self._cache[key] = now + self.config.auth_cache_seconds
                if len(self._cache) > 1000:
                    self._cache = {k: v for k, v in self._cache.items() if v > now}
        return ok

    def _ping(self, user, token, salt):
        query = urllib.parse.urlencode(
            {"u": user, "t": token, "s": salt, "v": "1.16.1", "c": "cassette-ratings", "f": "json"}
        )
        url = f"{self.config.navidrome_url}/rest/ping.view?{query}"
        try:
            with urllib.request.urlopen(url, timeout=self.config.auth_timeout_seconds) as response:
                payload = json.loads(response.read().decode("utf-8"))
            return payload.get("subsonic-response", {}).get("status") == "ok"
        except (urllib.error.URLError, TimeoutError, ValueError, OSError) as error:
            log.warning("Navidrome ping failed: %s", error)
            return False


# MARK: - HTTP

class RatingsHandler(BaseHTTPRequestHandler):
    server_version = "cassette-ratings/1"
    store = None
    auth = None

    def log_message(self, fmt, *args):  # route through logging, without query strings
        log.info("%s %s %s", self.command, self.path.split("?", 1)[0], args[1] if len(args) > 1 else "")

    # Routing

    def _route(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        if path == "/ratings" or path.startswith("/ratings/"):
            path = path[len("/ratings"):] or "/"
        segments = [urllib.parse.unquote(s) for s in path.strip("/").split("/") if s]
        return segments, urllib.parse.parse_qs(parsed.query)

    def do_GET(self):
        segments, query = self._route()
        if segments == ["v1", "health"]:
            return self._send(200, {"status": "ok"})
        if segments == ["v1", "ratings"]:
            user = self._authenticate()
            if user is None:
                return
            try:
                since = int(query.get("since", ["0"])[0])
            except ValueError:
                return self._send(400, {"error": "since must be an integer"})
            ratings, cursor = self.store.changes_since(user, max(since, 0))
            return self._send(200, {"ratings": ratings, "cursor": cursor})
        return self._send(404, {"error": "not found"})

    def do_PUT(self):
        target = self._item_target()
        if target is None:
            return
        user = self._authenticate()
        if user is None:
            return
        body = self._read_json()
        if body is None:
            return
        value = body.get("value")
        updated_at = body.get("updatedAt")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not (0 <= value <= 10):
            return self._send(400, {"error": "value must be a number from 0 to 10"})
        if isinstance(updated_at, bool) or not isinstance(updated_at, int):
            return self._send(400, {"error": "updatedAt must be an integer (ms since epoch)"})
        applied, row = self.store.upsert(user, *target, round(float(value), 1), updated_at, deleted=False)
        return self._send(200, {"applied": applied, "rating": row})

    def do_DELETE(self):
        target = self._item_target()
        if target is None:
            return
        user = self._authenticate()
        if user is None:
            return
        _, query = self._route()
        try:
            updated_at = int(query.get("updatedAt", [""])[0])
        except ValueError:
            return self._send(400, {"error": "updatedAt query parameter is required"})
        applied, row = self.store.upsert(user, *target, None, updated_at, deleted=True)
        return self._send(200, {"applied": applied, "rating": row})

    # Helpers

    def _item_target(self):
        segments, _ = self._route()
        if len(segments) != 4 or segments[:2] != ["v1", "ratings"]:
            self._send(404, {"error": "not found"})
            return None
        item_type, item_id = segments[2], segments[3]
        if item_type not in ITEM_TYPES:
            self._send(400, {"error": "type must be song, album or artist"})
            return None
        if not item_id or len(item_id) > MAX_ID_LENGTH:
            self._send(400, {"error": "invalid id"})
            return None
        return item_type, item_id

    def _authenticate(self):
        user = self.headers.get("X-Cassette-User", "").strip()
        token = self.headers.get("X-Cassette-Token", "").strip()
        salt = self.headers.get("X-Cassette-Salt", "").strip()
        if not self.auth.verify(user, token, salt):
            self._send(401, {"error": "unauthorized"})
            return None
        # Navidrome usernames are case-insensitive; keep one row set per account.
        return user.lower()

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY_BYTES:
            self._send(413 if length > MAX_BODY_BYTES else 400, {"error": "invalid body size"})
            return None
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "body must be JSON"})
            return None
        if not isinstance(body, dict):
            self._send(400, {"error": "body must be a JSON object"})
            return None
        return body

    def _send(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def make_server(config):
    handler = type("BoundRatingsHandler", (RatingsHandler,), {
        "store": Store(config.db_path),
        "auth": NavidromeAuthenticator(config),
    })
    return ThreadingHTTPServer((config.host, config.port), handler)


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    config = Config()
    server = make_server(config)
    log.info("cassette-ratings listening on %s:%d (Navidrome at %s, db %s)",
             config.host, config.port, config.navidrome_url, config.db_path)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
