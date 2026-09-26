# cassette-ratings

Stores Cassette's 0.0–10.0 song, album and artist ratings on your own server, next to
Navidrome, so they survive reinstalls and sync between devices.

- Python standard library only, one file (`app.py`), SQLite storage.
- No accounts of its own: each request carries the user's Subsonic token credentials, which
  are checked against Navidrome's `ping` endpoint (cached for 5 minutes).
- Ratings are per Navidrome user.

## How Cassette finds it

The app calls `<server URL you log in with>/ratings/v1/...`. For
`https://music.example.com` that is `https://music.example.com/ratings/v1/...`. Route that path
to this service in the reverse proxy in front of Navidrome; everything else keeps going to
Navidrome. Custom headers configured in the app (e.g. Cloudflare Access) are sent on these
requests too.

If the service is not reachable, the app keeps ratings on the device and retries later.

## Run

```sh
docker compose up -d --build cassette-ratings   # see docker-compose.example.yml
```

| Variable | Default | Meaning |
|---|---|---|
| `NAVIDROME_URL` | `http://navidrome:4533` | How this service reaches Navidrome directly |
| `DB_PATH` | `/data/ratings.db` | SQLite file — back it up |
| `PORT` | `8000` | Listen port |
| `AUTH_CACHE_SECONDS` | `300` | How long a verified credential is trusted |

Without Docker: `NAVIDROME_URL=http://127.0.0.1:4533 DB_PATH=./ratings.db python3 app.py`.

## Reverse proxy

The service accepts paths with or without the `/ratings` prefix, so either style works.

**Caddy**

```caddy
music.example.com {
    handle /ratings/* {
        reverse_proxy cassette-ratings:8000
    }
    handle {
        reverse_proxy navidrome:4533
    }
}
```

**nginx** (inside the existing `server { ... }` for Navidrome)

```nginx
location /ratings/ {
    proxy_pass http://cassette-ratings:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

**Cloudflare Tunnel**: add an ingress rule for `path: ^/ratings/` pointing at
`http://cassette-ratings:8000`, above the Navidrome rule.

## Check it

```sh
curl https://music.example.com/ratings/v1/health          # {"status": "ok"}

# Authenticated (replace USER / PASSWORD):
SALT=$(openssl rand -hex 8)
TOKEN=$(printf '%s%s' 'PASSWORD' "$SALT" | md5sum | cut -d' ' -f1)
curl -H "X-Cassette-User: USER" -H "X-Cassette-Token: $TOKEN" -H "X-Cassette-Salt: $SALT" \
     https://music.example.com/ratings/v1/ratings          # {"ratings": [...], "cursor": N}
```

## API

| Method | Path | Body / query | Response |
|---|---|---|---|
| GET | `/v1/health` | — | `{"status":"ok"}` (no auth) |
| GET | `/v1/ratings` | `?since=<cursor>` | `{"ratings":[{type,id,value,updatedAt,deleted}], "cursor": N}` |
| PUT | `/v1/ratings/<type>/<id>` | `{"value": 8.4, "updatedAt": <ms>}` | `{"applied": bool, "rating": {...}}` |
| DELETE | `/v1/ratings/<type>/<id>` | `?updatedAt=<ms>` | `{"applied": bool, "rating": {...}}` |

`type` is `song`, `album` or `artist`. Auth headers: `X-Cassette-User`, `X-Cassette-Token`
(`md5(password + salt)`), `X-Cassette-Salt`. Newest `updatedAt` wins; deletes are kept as
tombstones so other devices see them.

## Tests

```sh
python3 -m unittest -v test_app
```
