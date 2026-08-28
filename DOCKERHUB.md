## Support

If this edition helps you, I'd appreciate a small donation – thank you! ☕

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20me-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/andyxtreme)


# YoutubeDL-Material – Modernized Edition

Material Design web UI for [yt-dlp](https://github.com/yt-dlp/yt-dlp) in a
container: download video and audio, subscribe to channels and playlists, manage
everything from the browser – **with a working subscription feature**, instead of
one that silently fails on today's YouTube.

This is a modernized variant of
[YoutubeDL-Material](https://github.com/Tzahi12345/YoutubeDL-Material) by Isaac
Grynsztein (Tzahi12345). Same application, current runtime: **Node 20**,
**MongoDB 7**, and a JavaScript runtime (**Deno**) inside the image – which is
exactly what modern yt-dlp needs for YouTube extraction, and what the original
image was missing.

Self-hosted, no cloud, no account anywhere. Multi-arch: **amd64 + arm64**.

---

## What's different from the original image

| Area | Original | This image |
|---|---|---|
| Node.js | 16.14.2 (EOL, via NVM) | **20 LTS** (official `node` image) |
| Base image | Ubuntu 22.04 + NVM | **`node:20-bookworm-slim`** |
| MongoDB | `mongo:4` (EOL) | **`mongo:7`** with healthcheck |
| JS runtime for yt-dlp | missing – subscriptions break | **Deno** bundled in |
| `%(playlist_index)s` in subscriptions | resolves to `NA` | **backend patch** injects the real index |
| Twitch VOD chat | `TwitchDownloaderCLI` aborts (no ICU in the image) | **`libicu72`** installed |
| Architectures | amd64 | **amd64 + arm64** |

The patch is applied at build time and aborts the build if the upstream code it
anchors to changes – the source itself stays unmodified.

---

## Quick start

The app needs a MongoDB. Compose brings both up:

```yaml
services:
  ytdl-mongo-db:
    container_name: youtubedl-mongo
    image: mongo:7
    logging:
      driver: none
    restart: unless-stopped
    volumes:
      - mongo-data:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

  ytdl_material:
    container_name: youtubedl-material
    image: andyxtreme/youtubedl-material:latest
    depends_on:
      ytdl-mongo-db:
        condition: service_healthy
    environment:
      TZ: Europe/Berlin
      ytdl_mongodb_connection_string: mongodb://ytdl-mongo-db:27017
      ytdl_use_local_db: 'false'
      # Optional, default is 1000:1000
      # UID: '1000'
      # GID: '1000'
    ports:
      - '17442:17442'
    restart: unless-stopped
    volumes:
      # Relative paths keep everything in folders next to this file.
      # On a NAS use absolute host paths instead, e.g.:
      #   - /mnt/pool/Ytdl_material/appdata:/app/appdata
      - ./appdata:/app/appdata
      - ./audio:/app/audio
      - ./video:/app/video
      - ./subscriptions:/app/subscriptions
      - ./users:/app/users

volumes:
  mongo-data:
```

Then: **http://&lt;HOST-IP&gt;:17442**

> **Start with a clean pair.** `appdata` and the database belong together. For a
> fresh setup leave **both** empty – an old `appdata` next to an empty database
> (or the other way round) runs into migration errors on first start.

---

## Interfaces

| | |
|---|---|
| Port | `17442` in the container, mapped 1:1 above. For a different external port, change only the host side of the mapping. |
| `/app/appdata` | Configuration (`default.json`), logs, the yt-dlp binary, and `cookies.txt` if you use cookies. Belongs with the database – see above. |
| `/app/audio`, `/app/video` | Manual downloads. |
| `/app/subscriptions` | One folder per subscription (`subscriptions/<name>/`), created automatically. |
| `/app/users` | Per-user files in multi-user mode. |
| Database | MongoDB 7 in its own container. Must not be lost – it holds files, playlists, users and subscriptions. |

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `TZ` | UTC | Time zone – otherwise log timestamps and scheduled checks are off |
| `UID` / `GID` | `1000` | Owner of the downloaded files; the entrypoint takes ownership of `/app` and then drops privileges via `gosu` |
| `ytdl_mongodb_connection_string` | `mongodb://127.0.0.1:27017` | Address of the database |
| `ytdl_use_local_db` | `false` | `true` uses the built-in file database instead of MongoDB (not recommended for large libraries) |
| `YTDL_UMASK` | – | umask for created files |

**Every** setting from the settings page can also be given as an environment
variable, named exactly like its config key (`ytdl_default_file_output`,
`ytdl_subscriptions_check_interval`, …). Note what that means: such variables are
written **into `appdata/default.json` on every start** – as long as the line
stands in the compose file, the compose file is the lever, not the web UI.
Everything else is configured in the UI and stays there.

---

## ⚠️ Notes on playlists & subscriptions

None of these is a bug of this image, but each one costs an evening if you don't
know about it.

### Long playlists

Two settings decide whether a long playlist is enumerated completely:

- **Cookies.** **Settings → Advanced → use cookies**, with `cookies.txt` in
  `appdata/`. Without it the run is anonymous and YouTube throttles enumeration
  much earlier. If the file is missing, the app logs a warning and continues
  *without* cookies – check with `grep -i cookies appdata/logs/combined.log`.
- **Downloader.** **Settings → Advanced → Select a downloader** must be `yt-dlp`.
  The checkbox *"Use default downloading agent"* is unrelated; it only picks the
  external fragment downloader.

Counting a playlist yourself:

```bash
docker exec -it youtubedl-material sh -lc './appdata/bin/yt-dlp --cookies appdata/cookies.txt --flat-playlist --print "%(playlist_index)s" "<PLAYLIST_URL>" | wc -l'
```

### File names in playlist order

Under **Settings → Downloader → File Output Template**:

```
%(playlist_index)03d - %(title)s [%(id)s]
```

produces `005 - Ariana Grande, Tyga - MIDNIGHT DRIFT [r5Ki7xyogzg].mp4`: position
zero-padded to three digits, title, and the video ID so identical titles can't
collide. Do not add the file extension – yt-dlp appends it.

This works **because of this image**: the app downloads subscription videos
individually by video URL, where yt-dlp has no playlist context and
`%(playlist_index)s` would become `NA`. The bundled patch injects the index from
the already-fetched playlist metadata before the download starts.

### Subscriptions run on an interval

Not in real time. New videos appear at the next check
(**Settings → Subscriptions → Check interval**, in seconds) – or right away if
you refresh the subscription by hand in the UI.

---

## What's in it

- **Downloads** of video and audio from YouTube and the many other sites yt-dlp
  supports, with format and quality selection, in a Material Design UI with dark
  mode.
- **Subscriptions** to channels and playlists, checked automatically, each in its
  own folder, with a usable playlist index in the file name.
- **Multi-user mode** with roles and permissions, plus file manager, playlists
  and a built-in player.
- **MongoDB backend** – built for libraries that outgrow a JSON file.
- **Extras:** public API, iOS shortcut, thumbnail and metadata embedding
  (AtomicParsley), Twitch VOD chat download (TwitchDownloaderCLI), ffmpeg
  bundled.

## What it isn't

Not a public service. This is a LAN-facing self-hosted app – put it behind a
reverse proxy with authentication before exposing it to the internet, and expect
to supply your own cookies for anything YouTube treats as account-bound. What you
download, and what you do with it, is your responsibility.

---

## Tags

| Tag | |
|---|---|
| `latest` | current state |
| `1.0` | fixed version |

Full documentation – build details, the patch itself, volumes and every one of
the playlist caveats – lives as `README.md` in the source repository:
<https://github.com/AndyXtreme/YoutubeDL-Material>

## Credits & License

Original project: **YoutubeDL-Material** by Isaac Grynsztein (Tzahi12345) and
contributors – <https://github.com/Tzahi12345/YoutubeDL-Material>, MIT licensed.
This edition adds infrastructure changes only (Dockerfile, compose, build-time
patches).

Not affiliated with, or endorsed by, Google LLC, Alphabet Inc. or YouTube.
