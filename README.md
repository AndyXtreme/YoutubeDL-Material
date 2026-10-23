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
| Subscription checks | invisible at the default log level, and a failed check can block the subscription for good | **logged**, and the blocking flag is always cleared |
| A playlist containing a deleted or private video | one unavailable entry makes yt-dlp exit non-zero, the entire check counts as failed, and **nothing** from that playlist is ever downloaded | the videos that did come back are **used**, the dead entry is skipped and named in the log |
| Cookies | every concurrent download is handed the same `cookies.txt` and writes it back on exit, so a slow process overwrites fresh cookies with its stale ones and the session dies | each run works on **its own copy**, and a single keeper refreshes the master jar — on a copy too, promoted only if it still carries a login |
| Whether the cookies still work | nothing says so, anywhere | **shown in Settings → Advanced**, with a *Check now* button |
| Numbering after a video leaves a playlist | files keep the position they were downloaded with, so the numbering drifts out of step for good | a **button** on the subscription page, and optionally **after every check**, re-derives the numbers from the playlist as it is now |
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

Subscriptions are **not** checked in real time, but on a fixed interval (Settings → Main → *Check interval*, in seconds). New videos appear only at the next check; alternatively, refresh the subscription manually in the UI.

### 4. Videos removed from a playlist

Two separate things happen when a video disappears from a playlist, and this edition handles them differently.

**A video that is deleted or set to private but still sits in the playlist** makes yt-dlp
exit with code 1 — `-i` keeps it going but does not change the exit code. Upstream treats
that as a failed check and discards the output for *every* video in the playlist, so a
single dead entry stops the whole playlist from downloading, with nothing in the log at
the default level. This edition uses the entries that did come back:

```
WARN: yt-dlp reported an error but returned 257 usable entry/entries - continuing with those.
INFO: Subscription: RenumberTest checked, 257 new video(s) queued.
```

**A video taken out of the playlist** shifts the position of every video behind it, while
the files already on disk keep the number they were downloaded with. Nothing breaks, but
the numbering no longer matches the playlist.

Two ways to put it right. Open a subscription from the subscriptions list — not the list
itself — and the **renumber button** sits at the top right, immediately left of the pencil.
It only appears for playlist subscriptions, since a channel has no positions to follow, and
it is greyed out while a check for that subscription is running. It shows what it would
rename before it does anything:

```
Renumber 260 file(s)?

259 of the files are still in the playlist, 1 no longer is - those lose their number.

002 - Titel 001 [szM-KGgGUpI]   →   001 - Titel 001 [szM-KGgGUpI]
000 - Rausgeflogen [xxGONExx]   →   Rausgeflogen [xxGONExx]
…
```

And **Settings → Main → Renumber files after each check**, off by default, which
does the same automatically after every check of a playlist subscription. Files whose
video is still in the playlist get its current position, files whose video is gone lose
the number altogether, and the database follows the rename along with the `.info.json`
and the thumbnail.

Three situations make it refuse, and nothing is changed when it does:

- **The playlist was read incompletely.** yt-dlp reports the length the playlist claims
  for itself, so this is an exact check, not a guess: 259 claimed and 200 returned means
  YouTube cut the listing short, and acting on that order would strip the numbering off
  the 59 that did not come back — and put it back on the next run, names flapping across
  the whole library. This is what makes the automatic mode safe to leave on.
- **Two files would end up with the same name.** Add `[%(id)s]` to the output template so
  identical titles cannot collide.
- **More files are missing from the playlist than are still in it**, the fallback for a
  channel subscription, which does not advertise a length.

The automatic pass also waits while downloads for that subscription are still pending, so
nothing is renamed out from under a running download — it renumbers at the next check
instead.

The same thing is available over the API, which is how to pass `force` to override the
first and third refusal:

```bash
curl -s -X POST "http://<HOST-IP>:17442/api/renumberSubscription?apiKey=<YOUR-API-KEY>" \
  -H "Content-Type: application/json" -d '{"sub_id":"<SUB-ID>"}'
```

That call is a dry run and answers with the list of renames; add `"dry_run": false` to
carry them out, and `"force": true` to renumber on a partial listing anyway. `sub_id` is
the id in the URL of the subscription's page.

### 5. Cookies stay valid on their own

YouTube has no username/password login to offer here: yt-dlp refuses it outright
(*"Login with password is not supported for YouTube"*), because Google's sign-in is a
JavaScript flow with bot detection and device verification. A cookie jar is the only
durable form of authentication — so the job is to keep the jar from dying.

yt-dlp writes the rotated cookies back into the file it was given when it exits. Upstream
hands the *same* `appdata/cookies.txt` to every concurrent download, so with five parallel
downloads five processes load one jar and write it back in whatever order they finish: a
process that started twenty minutes earlier overwrites the fresh cookies with its stale
ones, and the session is gone. yt-dlp's own FAQ warns against sharing one cookie file
between instances for exactly this reason.

In this edition every run works on its own copy under `appdata/cookie-copies/`, which it
may write to as it likes and which is then swept up, and one keeper run refreshes the
master jar every 30 minutes — the only writer there is.

That refresh also runs on a copy, and the copy replaces the master only if it still
carries a login. This matters more than it sounds: yt-dlp writes back whatever the session
ended up as, so a request YouTube answered anonymously comes back as a jar with no login
in it at all — measured, a rejected jar returned with eight tracking cookies and not one
login cookie. Refreshing the master directly would mean one bad answer silently strips the
login out of the file you uploaded.

**Settings → Advanced** shows where the jar stands, instead of leaving that to the log:

```
✓  Cookies accepted by YouTube.
   14 cookies, 5 of them login cookies · valid until 28/04/2027 · last checked 21:14:08 · refreshed every 30 min
```

```
✗  The uploaded file carries no YouTube login - it was most likely exported while signed out.
   22 cookies, 0 of them login cookies
```

```
✗  YouTube rejected the cookies: [youtube:tab] WL: YouTube said: The playlist does not exist.
   3 cookies, 2 of them login cookies · a login cookie expired on 21/09/2026 · last checked 21:12:50
```

**Check now** next to *Set Cookies* asks YouTube straight away, and a fresh upload is
checked as soon as the dialog closes — no waiting for the next 30-minute round. The check
is one request against the account's watch-later list, which is the cheapest thing that
still needs a working login.

Export the jar from a **private/incognito window** that you close *without* logging out —
a jar from a window you later log out of is invalidated at the source, and no amount of
refreshing brings it back. Note that a jar exported while signed out is a common and
otherwise invisible mistake: the file looks perfectly well-formed and contains no login at
all, which is exactly what the line above reports.

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
