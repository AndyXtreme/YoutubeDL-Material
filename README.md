# YoutubeDL-Material – Modernized Edition (Node 20 / Mongo 7)

This is a modernized variant of [YoutubeDL-Material](https://github.com/Tzahi12345/YoutubeDL-Material) (by Isaac Grynsztein / Tzahi12345) – a Material Design frontend for [yt-dlp](https://github.com/yt-dlp/yt-dlp) with an Angular frontend and a Node.js backend.

The original project was built on **Node 16** (end-of-life) and **MongoDB 4**. Among other things, this broke the **subscription feature**, because yt-dlp now requires a JavaScript runtime. This edition brings the setup up to a current state and fixes several practical issues.

---

## What's different in this edition

| Area | Original | This edition |
|---|---|---|
| Node.js | 16.14.2 (EOL, via NVM) | **20 LTS** (official `node` image) |
| Base image (final) | Ubuntu 22.04 + NVM | **`node:20-bookworm-slim`** (slim) |
| MongoDB (Compose) | `mongo:4` (EOL) | **`mongo:7`** with healthcheck |
| JS runtime for yt-dlp | missing | **Deno** bundled into the image |
| Subscription file names | `%(playlist_index)s` → `NA` | **backend patch** injects the real index |
| Twitch VOD chat | `TwitchDownloaderCLI` aborts (no ICU in the image) | **`libicu72`** installed |
| Download queue after a restart | every unfinished download is set to *paused* | interrupted downloads **continue on their own** |
| Memory | finished download processes are never released, the queue is re-read in full every second → out of memory after a few days | **both fixed**, plus a pm2 restart guard |
| yt-dlp binary | re-downloaded on every single start | **only when a new version actually exists** |
| Deleting a subscription | the request never answers, a `TypeError` per second in the log | **answered cleanly**, log stays quiet |
| Architectures | amd64 | **amd64 + arm64** |
| Long playlists | capped at 100 videos | documented: cookies + `yt-dlp` as downloader |

All changes are documented in the [Dockerfile](Dockerfile) and applied **automatically at build time** – the source code itself is not permanently modified. Every patch names the exact upstream code it replaces and aborts the build if that code has changed (e.g. after a YTM update).

> Upgrading from an older image? Downloads that the old version left in the *paused* state stay paused – press **Resume all** once on the Downloads page.

---

## Features (original)

- Download video and audio (YouTube and many other sites via yt-dlp)
- Material Design web UI, dark mode
- **Subscriptions** for channels and playlists with automatic checks on an interval
- Multi-user mode with roles/permissions
- MongoDB backend for large datasets
- Public API, iOS shortcut, thumbnail embedding (AtomicParsley), Twitch VOD chat (TwitchDownloaderCLI)

---

## Getting started

Requirements: Docker with Compose (e.g. TrueNAS SCALE "Electric Eel" 24.10+ or any system with Docker).

### Option A — Use the prebuilt image (recommended)

The image is published on Docker Hub as **multi-arch (amd64 + arm64)**: [`andyxtreme/youtubedl-material`](https://hub.docker.com/r/andyxtreme/youtubedl-material).

You only need the [docker-compose.yml](docker-compose.yml) — no source code required. Put it in a folder and run:

```bash
docker compose up -d
```

Compose pulls `andyxtreme/youtubedl-material:latest` and also starts MongoDB 7.

### Option B — Build from source (for developers)

Clone this repository, then build the image yourself, tagging it with the name the compose file expects:

```bash
docker build -t andyxtreme/youtubedl-material:latest .
docker compose up -d
```

For both architectures at once (needs a registry to push to, since a manifest list can't live in the local image store):

```bash
docker build --platform linux/amd64,linux/arm64 -t <user>/youtubedl-material:latest --push .
```

The helper stage that fetches ffmpeg and TwitchDownloaderCLI runs unemulated on the build host and downloads binaries for the target architecture, so the arm64 build doesn't depend on QEMU behaving.

Since the image then already exists locally, Compose uses your build instead of pulling. During the build every patch reports itself:

```
patch applied: playlist_index in subscription downloads (subscriptions.js)
patch applied: restart: resume interrupted downloads (downloader.js)
...
```

---

The web UI is then available at:

```
http://<HOST-IP>:17442
```

> The container listens internally on port **17442**, and `docker-compose.yml` maps it 1:1 to the same host port (`17442:17442`). To use a different external port, change the host side of the mapping.

### Volumes / paths

By default, [docker-compose.yml](docker-compose.yml) uses **relative paths**: media and `appdata` land in subfolders next to the compose file (`./appdata`, `./audio`, `./video`, `./subscriptions`, `./users`), while the database lives in a Docker-managed **named volume** (`mongo-data`). This works without any extra configuration.

On a NAS or similar, just replace the relative paths with absolute host paths:

```yaml
volumes:
  - /mnt/pool/Ytdl_material/appdata:/app/appdata
  - /mnt/pool/Ytdl_material/audio:/app/audio
  - /mnt/pool/Ytdl_material/video:/app/video
  - /mnt/pool/Ytdl_material/subscriptions:/app/subscriptions
  - /mnt/pool/Ytdl_material/users:/app/users
```

(The data folders and the DB volume are excluded via `.gitignore`, so they won't end up in the repo.)

**Important:** `appdata` and the database must match each other. For a fresh setup leave both empty, otherwise the first start may run into migration errors.

---

## ⚠️ Important notes for playlists & subscriptions

YouTube and yt-dlp have a few quirks you should know about. None of them is **a bug of this edition**, but each can be solved cleanly with a setting.

### 1. Long playlists

Two settings decide whether a long playlist is enumerated completely:

- **Cookies.** Enable **Settings → Advanced → use cookies** and place `cookies.txt` in
  `appdata/`. Without it the run is anonymous and YouTube throttles enumeration much
  earlier. If the file is missing, YTM logs a warning and continues *without* cookies —
  check with `grep -i cookies appdata/logs/combined.log`.
- **Downloader.** **Settings → Advanced → Select a downloader** must be `yt-dlp`.
  The unrelated checkbox *“Use default downloading agent”* only picks the external
  fragment downloader (aria2c, curl, …) and has no effect on playlist enumeration.

Counting a playlist yourself:

```bash
docker exec -it youtubedl-material sh -lc './appdata/bin/yt-dlp --cookies appdata/cookies.txt --flat-playlist --print "%(playlist_index)s" "<PLAYLIST_URL>" | wc -l'
```

### 2. File naming with playlist position

So that files are named uniquely and in playlist order even with many identical titles, set this under **Settings → Downloader → File Output Template** (config key `default_file_output`):

```
%(playlist_index)03d - %(title)s [%(id)s]
```

Example result:

```
005 - Ariana Grande, Tyga - MIDNIGHT DRIFT [r5Ki7xyogzg].mp4
```

- `%(playlist_index)03d` – position in the playlist, zero-padded to three digits (clean sorting)
- `%(title)s` – title
- `[%(id)s]` – unique YouTube video ID (prevents collisions for identical titles)
- yt-dlp appends the file extension automatically – do **not** add it yourself.

**Why the backend patch is needed:** YTM downloads subscription videos **individually** via their video URL. In that context yt-dlp has no playlist position, which is why `%(playlist_index)s` would normally become `NA`. This edition injects the index **before the download** from the already-fetched playlist metadata (see the patch in the [Dockerfile](Dockerfile)).

Note: YTM automatically creates a folder per playlist for subscriptions (`subscriptions/<name>/`). You don't need `%(playlist_title)s/` in the template for that.

### 3. Subscription interval

Subscriptions are **not** checked in real time, but on a fixed interval (Settings → Subscriptions → *Check interval*, in seconds). New videos appear only at the next check; alternatively, refresh the subscription manually in the UI.

---

## Support

If this edition helps you, I'd appreciate a small donation – thank you! ☕

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20me-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/andyxtreme)

## Credits & License

- Original project: **YoutubeDL-Material** by Isaac Grynsztein (Tzahi12345) and contributors – <https://github.com/Tzahi12345/YoutubeDL-Material>
- License: **MIT** – see [LICENSE.md](LICENSE.md)
- This edition contains only infrastructure changes (Dockerfile, docker-compose, build-time patches) to modernize the runtime.

## Legal Disclaimer

This project is in no way affiliated with Google LLC, Alphabet Inc. or YouTube, nor endorsed by them.
