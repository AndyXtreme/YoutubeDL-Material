# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 — Utils: fetch ffmpeg + TwitchDownloaderCLI via the helper scripts
###############################################################################
# Ubuntu 22.04: the helper scripts are hard-wired for it (package names like
# libicu70, self-install of curl/jq/unzip). This stage only produces static
# binaries, so the distro is not critical here.
FROM ubuntu:22.04 AS utils
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETPLATFORM
WORKDIR /utils
# Use script due to local build compatibility (arch-aware downloads)
COPY docker-utils/*.sh ./
RUN chmod +x *.sh
RUN sh ./ffmpeg-fetch.sh
RUN sh ./fetch-twitchdownloader.sh

# Deno as a JavaScript runtime for yt-dlp. Modern yt-dlp needs a JS runtime for
# YouTube extraction; without one it prints a warning to stderr — and that very
# warning makes YTM's playlist/subscription lookup fail.
# yt-dlp uses Deno automatically by default (no extra arguments needed).
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates unzip && \
    arch="$(dpkg --print-architecture)" && \
    case "$arch" in \
        amd64) deno_arch="x86_64-unknown-linux-gnu" ;; \
        arm64) deno_arch="aarch64-unknown-linux-gnu" ;; \
        *) echo "Unsupported architecture for Deno: $arch" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/denoland/deno/releases/latest/download/deno-${deno_arch}.zip" -o /tmp/deno.zip && \
    unzip /tmp/deno.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/deno && \
    rm /tmp/deno.zip && \
    /usr/local/bin/deno --version


###############################################################################
# Stage 2 — Frontend: build the Angular app
# Node 20 LTS instead of node:16 (EOL). The build always runs on the build host.
###############################################################################
ARG BUILDPLATFORM
FROM --platform=${BUILDPLATFORM} node:26-bookworm AS frontend
WORKDIR /build
COPY ["package.json", "package-lock.json", "angular.json", "tsconfig.json", "./"]
COPY ["src/", "./src/"]
# @angular/cli comes from devDependencies — no global install needed.
# npm install instead of npm ci: the bundled package-lock.json is outdated
# (out of sync). --legacy-peer-deps because of old Angular peer conflicts (ajv 7/8).
RUN npm install --legacy-peer-deps && \
    npm run build && \
    ls -al /build/backend/public


###############################################################################
# Stage 3 — Install backend dependencies (production)
###############################################################################
FROM node:26-bookworm-slim AS backend
ENV NO_UPDATE_NOTIFIER=true
WORKDIR /app
COPY ["backend/package.json", "backend/package-lock.json", "./"]
# npm install instead of npm ci, because the backend lockfile may be outdated too.
RUN npm install --omit=dev --legacy-peer-deps
COPY ["backend/", "./"]

# Patch: subscription videos are downloaded individually via their video URL, so
# yt-dlp has no playlist context and %(playlist_index)s becomes "NA". YTM does
# know the index from the playlist metadata, so we inject it into the output
# template before the download. Aborts the build if the anchor code no longer
# matches (e.g. after a YTM update).
RUN node - <<'EOF'
const fs = require('fs');
const file = 'subscriptions.js';
let src = fs.readFileSync(file, 'utf8');
const anchor = "await downloader_api.createDownload(file_to_download['webpage_url'], sub.type || 'video', base_download_options, user_uid, sub.id, sub.name, [file_to_download]);";
const replacement = [
  "const download_options = Object.assign({}, base_download_options);",
  "        if (download_options.customOutput && file_to_download['playlist_index'] != null) {",
  "            download_options.customOutput = download_options.customOutput.replace(/%\\(playlist_index\\)(\\d*)[sd]/g, (m, w) => String(file_to_download['playlist_index']).padStart(parseInt(w || '0', 10), '0'));",
  "        }",
  "        await downloader_api.createDownload(file_to_download['webpage_url'], sub.type || 'video', download_options, user_uid, sub.id, sub.name, [file_to_download]);"
].join('\n');
if (!src.includes(anchor)) { console.error('playlist_index patch: anchor not found, aborting'); process.exit(1); }
src = src.replace(anchor, replacement);
fs.writeFileSync(file, src);
console.log('playlist_index patch applied to subscriptions.js successfully');
EOF


###############################################################################
# Stage 4 — Final image
###############################################################################
FROM node:26-bookworm-slim AS final

ARG DEBIAN_FRONTEND=noninteractive
ENV USER=youtube \
    UID=1000 \
    GID=1000 \
    NO_UPDATE_NOTIFIER=true \
    PM2_HOME=/app/pm2 \
    ALLOW_CONFIG_MUTATIONS=true \
    npm_config_cache=/app/.npm

# The official node image already ships a "node" user with uid/gid 1000.
# We rename it to "youtube" so that uid 1000 stays occupied as before.
RUN usermod -l "$USER" -d "/home/$USER" -m node && \
    groupmod -n "$USER" node

# Runtime packages: gosu (privilege drop), python3 + pycryptodomex (yt-dlp),
# atomicparsley (metadata/cover art), tzdata, ffmpeg dependencies.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gosu \
        tzdata \
        ca-certificates \
        atomicparsley \
        python3-minimal \
        python-is-python3 \
        python3-pip && \
    pip install --no-cache-dir --break-system-packages pycryptodomex && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Process manager
RUN npm install -g pm2 && npm cache clean --force

WORKDIR /app

# Binaries from the utils stage
COPY --chown=$UID:$GID --from=utils ["/usr/local/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
COPY --chown=$UID:$GID --from=utils ["/usr/local/bin/ffprobe", "/usr/local/bin/ffprobe"]
COPY --chown=$UID:$GID --from=utils ["/usr/local/bin/TwitchDownloaderCLI", "/usr/local/bin/TwitchDownloaderCLI"]
COPY --chown=$UID:$GID --from=utils ["/usr/local/bin/deno", "/usr/local/bin/deno"]

# Backend (incl. node_modules) and the built frontend
COPY --chown=$UID:$GID --from=backend ["/app/", "/app/"]
COPY --chown=$UID:$GID --from=frontend ["/build/backend/public/", "/app/public/"]

RUN chmod +x /app/fix-scripts/*.sh

EXPOSE 17442
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["npm", "start"]
