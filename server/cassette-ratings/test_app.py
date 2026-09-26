# Cassette — Music client for Subsonic/OpenSubsonic servers
# Copyright (C) 2026 Mathieu Dubart
# Licensed under the Mozilla Public License 2.0.
# See LICENSE file in the project root for full license information.

"""End-to-end tests: a fake Navidrome for auth, the real service on an ephemeral port."""

import hashlib
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import app

PASSWORD = "secret"


class FakeNavidrome(BaseHTTPRequestHandler):
    pings = 0

    def log_message(self, *args):
        pass

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        FakeNavidrome.pings += 1
        salt = query.get("s", [""])[0]
        token = query.get("t", [""])[0]
        ok = token == hashlib.md5((PASSWORD + salt).encode()).hexdigest()
        body = {"subsonic-response": {"status": "ok" if ok else "failed"}}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class RatingsServiceTests(unittest.TestCase):
    def setUp(self):
        self.navidrome = serve(ThreadingHTTPServer(("127.0.0.1", 0), FakeNavidrome))
        self.tmp = tempfile.TemporaryDirectory()
        config = app.Config({
            "NAVIDROME_URL": f"http://127.0.0.1:{self.navidrome.server_address[1]}",
            "DB_PATH": f"{self.tmp.name}/ratings.db",
            "HOST": "127.0.0.1",
            "PORT": "0",
        })
        self.service = serve(app.make_server(config))
        self.base = f"http://127.0.0.1:{self.service.server_address[1]}/ratings/v1"
        FakeNavidrome.pings = 0

    def tearDown(self):
        self.service.shutdown()
        self.service.server_close()
        self.navidrome.shutdown()
        self.navidrome.server_close()
        self.tmp.cleanup()

    def request(self, method, path, body=None, password=PASSWORD, user="John", salt="abc123"):
        headers = {
            "X-Cassette-User": user,
            "X-Cassette-Token": hashlib.md5((password + salt).encode()).hexdigest(),
            "X-Cassette-Salt": salt,
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_health_needs_no_auth(self):
        with urllib.request.urlopen(self.base + "/health") as response:
            self.assertEqual(json.loads(response.read()), {"status": "ok"})

    def test_rejects_bad_credentials(self):
        status, _ = self.request("GET", "/ratings", password="wrong")
        self.assertEqual(status, 401)

    def test_put_then_pull(self):
        status, body = self.request("PUT", "/ratings/album/al-1", {"value": 8.44, "updatedAt": 1000})
        self.assertEqual(status, 200)
        self.assertTrue(body["applied"])
        status, body = self.request("GET", "/ratings")
        self.assertEqual(status, 200)
        self.assertEqual(body["ratings"], [
            {"type": "album", "id": "al-1", "value": 8.4, "updatedAt": 1000, "deleted": False},
        ])
        self.assertGreater(body["cursor"], 0)

    def test_pull_since_cursor_returns_only_newer_changes(self):
        self.request("PUT", "/ratings/song/s-1", {"value": 3, "updatedAt": 1})
        _, first = self.request("GET", "/ratings")
        self.request("PUT", "/ratings/song/s-2", {"value": 7, "updatedAt": 2})
        _, second = self.request("GET", f"/ratings?since={first['cursor']}")
        self.assertEqual([r["id"] for r in second["ratings"]], ["s-2"])
        _, third = self.request("GET", f"/ratings?since={second['cursor']}")
        self.assertEqual(third["ratings"], [])
        self.assertEqual(third["cursor"], second["cursor"])

    def test_older_write_loses(self):
        self.request("PUT", "/ratings/song/s-1", {"value": 9, "updatedAt": 2000})
        status, body = self.request("PUT", "/ratings/song/s-1", {"value": 2, "updatedAt": 1000})
        self.assertEqual(status, 200)
        self.assertFalse(body["applied"])
        self.assertEqual(body["rating"]["value"], 9)

    def test_delete_leaves_a_tombstone(self):
        self.request("PUT", "/ratings/artist/ar-1", {"value": 6, "updatedAt": 1})
        status, body = self.request("DELETE", "/ratings/artist/ar-1?updatedAt=2")
        self.assertEqual(status, 200)
        self.assertTrue(body["applied"])
        _, pulled = self.request("GET", "/ratings")
        self.assertEqual(pulled["ratings"], [
            {"type": "artist", "id": "ar-1", "value": None, "updatedAt": 2, "deleted": True},
        ])

    def test_ratings_are_per_user(self):
        self.request("PUT", "/ratings/song/s-1", {"value": 5, "updatedAt": 1}, user="john")
        _, other = self.request("GET", "/ratings", user="someone-else")
        self.assertEqual(other["ratings"], [])
        _, same = self.request("GET", "/ratings", user="JOHN")
        self.assertEqual(len(same["ratings"]), 1)

    def test_validation(self):
        self.assertEqual(self.request("PUT", "/ratings/playlist/p-1", {"value": 5, "updatedAt": 1})[0], 400)
        self.assertEqual(self.request("PUT", "/ratings/song/s-1", {"value": 11, "updatedAt": 1})[0], 400)
        self.assertEqual(self.request("PUT", "/ratings/song/s-1", {"value": "8", "updatedAt": 1})[0], 400)
        self.assertEqual(self.request("PUT", "/ratings/song/s-1", {"value": 8})[0], 400)
        self.assertEqual(self.request("DELETE", "/ratings/song/s-1")[0], 400)

    def test_ids_are_url_decoded(self):
        self.request("PUT", "/ratings/song/" + urllib.parse.quote("a/b c", safe=""), {"value": 4, "updatedAt": 1})
        _, pulled = self.request("GET", "/ratings")
        self.assertEqual(pulled["ratings"][0]["id"], "a/b c")

    def test_auth_is_cached(self):
        self.request("GET", "/ratings")
        self.request("GET", "/ratings")
        self.assertEqual(FakeNavidrome.pings, 1)

    def test_works_without_the_ratings_prefix(self):
        url = self.base.replace("/ratings/v1", "/v1") + "/health"
        with urllib.request.urlopen(url) as response:
            self.assertEqual(response.status, 200)


if __name__ == "__main__":
    unittest.main()
