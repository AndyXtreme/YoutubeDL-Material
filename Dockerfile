# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 — Utils: fetch ffmpeg + TwitchDownloaderCLI via the helper scripts
###############################################################################
# Ubuntu 22.04: the helper scripts are hard-wired for it (package names like
# libicu70, self-install of curl/jq/unzip). This stage only produces static
# binaries, so the distro is not critical here.
#
# The stage runs on the BUILD platform, never emulated: it only downloads
# prebuilt binaries for the target architecture, and under QEMU this stage is
# where multi-arch builds fall over (tar failing with "Invalid argument",
# repeated TLS resets against GitHub). TARGET_MACHINE tells the helper scripts
# which architecture to fetch for instead of them reading `uname -m`.
ARG BUILDPLATFORM
FROM --platform=${BUILDPLATFORM} ubuntu:22.04 AS utils
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
WORKDIR /utils
# Use script due to local build compatibility (arch-aware downloads)
COPY docker-utils/*.sh ./
RUN chmod +x *.sh
RUN case "$TARGETARCH" in \
        amd64) export TARGET_MACHINE=x86_64 ;; \
        arm64) export TARGET_MACHINE=aarch64 ;; \
        *) echo "Unsupported target architecture: $TARGETARCH" && exit 1 ;; \
    esac && \
    sh ./ffmpeg-fetch.sh
RUN case "$TARGETARCH" in \
        amd64) export TARGET_MACHINE=x86_64 ;; \
        arm64) export TARGET_MACHINE=aarch64 ;; \
        *) echo "Unsupported target architecture: $TARGETARCH" && exit 1 ;; \
    esac && \
    sh ./fetch-twitchdownloader.sh

# Deno as a JavaScript runtime for yt-dlp. Modern yt-dlp needs a JS runtime for
# YouTube extraction; without one it prints a warning to stderr — and that very
# warning makes YTM's playlist/subscription lookup fail.
# yt-dlp uses Deno automatically by default (no extra arguments needed).
# Pinned so a build stays reproducible and a Deno release can't break it silently.
ARG DENO_VERSION=v2.9.6
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates unzip && \
    case "$TARGETARCH" in \
        amd64) deno_arch="x86_64-unknown-linux-gnu" ;; \
        arm64) deno_arch="aarch64-unknown-linux-gnu" ;; \
        *) echo "Unsupported architecture for Deno: $TARGETARCH" && exit 1 ;; \
    esac && \
    curl -fsSL --connect-timeout 10 --max-time 180 --retry 5 --retry-delay 2 --retry-all-errors \
        "https://github.com/denoland/deno/releases/download/${DENO_VERSION}/deno-${deno_arch}.zip" -o /tmp/deno.zip && \
    unzip /tmp/deno.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/deno && \
    rm /tmp/deno.zip && \
    if [ "$TARGETARCH" = "$(dpkg --print-architecture)" ]; then /usr/local/bin/deno --version; fi


###############################################################################
# Stage 2 — Frontend: build the Angular app
# Node 20 LTS instead of node:16 (EOL). The build always runs on the build host.
###############################################################################
ARG BUILDPLATFORM
FROM --platform=${BUILDPLATFORM} node:20-bookworm AS frontend
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
FROM node:20-bookworm-slim AS backend
ENV NO_UPDATE_NOTIFIER=true
WORKDIR /app
COPY ["backend/package.json", "backend/package-lock.json", "./"]
# npm install instead of npm ci, because the backend lockfile may be outdated too.
RUN npm install --omit=dev --legacy-peer-deps
COPY ["backend/", "./"]

# Patches against the YTM backend. Each one names the exact upstream code it
# replaces; if an anchor is gone (e.g. after a YTM update) the build aborts
# instead of quietly producing an image with a patch missing. The source in the
# repository stays untouched.
RUN node - <<'EOF'
const fs = require('fs');

const patches = [
{
    // Subscription videos are downloaded individually via their video URL, so
    // yt-dlp has no playlist context and %(playlist_index)s becomes "NA". YTM
    // does know the index from the playlist metadata, so inject it into the
    // output template before the download starts.
    name: 'playlist_index in subscription downloads',
    file: 'subscriptions.js',
    find: "await downloader_api.createDownload(file_to_download['webpage_url'], sub.type || 'video', base_download_options, user_uid, sub.id, sub.name, [file_to_download]);",
    replace: [
        "const download_options = Object.assign({}, base_download_options);",
        "        if (download_options.customOutput && file_to_download['playlist_index'] != null) {",
        "            download_options.customOutput = download_options.customOutput.replace(/%\\(playlist_index\\)(\\d*)[sd]/g, (m, w) => String(file_to_download['playlist_index']).padStart(parseInt(w || '0', 10), '0'));",
        "        }",
        "        await downloader_api.createDownload(file_to_download['webpage_url'], sub.type || 'video', download_options, user_uid, sub.id, sub.name, [file_to_download]);"
    ].join('\n')
},
{
    // fixDownloadState() pauses every unfinished download on startup, so after a
    // crash or a plain restart the queue stays dead until someone presses resume
    // by hand. Only touch downloads that were actually interrupted...
    name: 'restart: leave user-paused downloads alone',
    file: 'downloader.js',
    find: "const running_downloads = downloads.filter(download => !download['finished'] && !download['error']);",
    replace: "const running_downloads = downloads.filter(download => !download['finished'] && !download['error'] && !download['paused']);"
},
{
    // ...and let those continue instead of pausing them.
    name: 'restart: resume interrupted downloads',
    file: 'downloader.js',
    find: "const update_obj = {finished_step: true, paused: true, running: false};",
    replace: "const update_obj = {finished_step: true, paused: false, running: false};"
},
{
    // checkDownloads() runs once per second and pulled the *entire* download
    // queue out of the database every time, finished downloads included. Nothing
    // ever prunes that collection, so the poll gets heavier every day.
    name: 'poll only unfinished downloads',
    file: 'downloader.js',
    find: "    if (!should_check_downloads) return;\n\n    const downloads = await db_api.getRecords('download_queue');",
    replace: "    if (!should_check_downloads) return;\n\n    const downloads = await db_api.getRecords('download_queue', {finished: false});"
},
{
    // The child process of a finished download was never removed from the map.
    // It is spawned with maxBuffer: Infinity, so every entry pins that
    // download's complete yt-dlp output in memory until the process dies.
    name: 'release finished download processes',
    file: 'downloader.js',
    find: "        const {parsed_output, err} = await callback;\n        clearInterval(download_checker);",
    replace: "        const {parsed_output, err} = await callback;\n        delete download_to_child_process[download['uid']];\n        clearInterval(download_checker);"
},
{
    // fs.existsSync() returns a boolean, so indexing it with the fork name is
    // always undefined: the version file was considered missing on every start
    // and yt-dlp was re-downloaded each time the container came up.
    name: 'read the yt-dlp version file correctly',
    file: 'youtube-dl.js',
    find: "    let current_app_details_exists = fs.existsSync(CONSTS.DETAILS_BIN_PATH);\n    if (!current_app_details_exists[selected_fork]) {",
    replace: "    const existing_details = fs.existsSync(CONSTS.DETAILS_BIN_PATH) ? fs.readJSONSync(CONSTS.DETAILS_BIN_PATH, {throws: false}) : null;\n    if (!existing_details || !existing_details[selected_fork]) {"
},
{
    // getLatestUpdateVersion() resolves to null when the GitHub API is
    // unreachable or rate limited. Overwriting a working binary in that case is
    // how you end up with a truncated yt-dlp.
    name: 'keep yt-dlp when the version check fails',
    file: 'youtube-dl.js',
    find: "if (!fs.existsSync(output_file_path) || current_fork !== selected_fork || !current_version || current_version !== latest_version) {",
    replace: "if (!fs.existsSync(output_file_path) || current_fork !== selected_fork || !current_version || (latest_version && current_version !== latest_version)) {"
},
{
    // Safety net: a clean pm2 restart below the V8 heap limit instead of a fatal
    // "JavaScript heap out of memory" abort in the middle of a download.
    name: 'pm2 memory guard',
    file: 'pm2.config.js',
    find: '      watch  : "placeholder",',
    replace: '      watch  : "placeholder",\n      max_memory_restart: "3G",'
},
{
    // getRecord() returns null for a subscription that no longer exists, and
    // JSON.parse(JSON.stringify(null)) is null too - so reading 'downloading'
    // off it threw. The UI keeps polling a subscription for a moment after it
    // was deleted, which produced a TypeError per second in the log.
    name: 'getSubscription: handle a deleted subscription',
    file: 'subscriptions.js',
    find: "exports.getSubscription = async (subID) => {\n    // stringify and parse because we may override the 'downloading' property\n    const sub = JSON.parse(JSON.stringify(await db_api.getRecord('subscriptions', {id: subID})));",
    replace: "exports.getSubscription = async (subID) => {\n    const sub_record = await db_api.getRecord('subscriptions', {id: subID});\n    // a missing subscription is not an error - every caller below handles null\n    if (!sub_record) return null;\n    // stringify and parse because we may override the 'downloading' property\n    const sub = JSON.parse(JSON.stringify(sub_record));"
},
{
    // A subscription can be deleted between listing the ones to check and the
    // check itself.
    name: 'checkSubscription: tolerate a missing subscription',
    file: 'subscriptions.js',
    find: "async function checkSubscription(sub_id) {\n    let sub = await exports.getSubscription(sub_id);\n",
    replace: "async function checkSubscription(sub_id) {\n    let sub = await exports.getSubscription(sub_id);\n    if (!sub) return;\n"
},
{
    name: 'cancelCheckSubscription: tolerate a missing subscription',
    file: 'subscriptions.js',
    find: "    const sub = await exports.getSubscription(sub_id);\n    if (!sub['downloading'] && !sub['child_process']) {",
    replace: "    const sub = await exports.getSubscription(sub_id);\n    if (!sub || (!sub['downloading'] && !sub['child_process'])) {"
},
{
    name: 'unsubscribe: tolerate a missing subscription',
    file: 'subscriptions.js',
    find: "exports.unsubscribe = async (sub_id, deleteMode, user_uid = null) => {\n    const sub = await exports.getSubscription(sub_id);\n",
    replace: "exports.unsubscribe = async (sub_id, deleteMode, user_uid = null) => {\n    const sub = await exports.getSubscription(sub_id);\n    if (!sub) return;\n"
},
{
    // Missing await: sub was a Promise, so sub.id was undefined and the endpoint
    // never downloaded anything.
    name: 'downloadVideosForSubscription: await the lookup',
    file: 'app.js',
    find: "    const sub = subscriptions_api.getSubscription(subID);\n    subscriptions_api.getVideosForSub(sub.id);",
    replace: "    const sub = await subscriptions_api.getSubscription(subID);\n    if (!sub) {\n        res.sendStatus(400);\n        return;\n    }\n    subscriptions_api.getVideosForSub(sub.id);"
}
];

for (const patch of patches) {
    // Normalise line endings first: a checkout on Windows has CRLF, while the
    // multi-line anchors above are written with LF.
    const src = fs.readFileSync(patch.file, 'utf8').split('\r\n').join('\n');
    if (!src.includes(patch.find)) {
        console.error(`patch '${patch.name}': anchor not found in ${patch.file}, aborting`);
        process.exit(1);
    }
    fs.writeFileSync(patch.file, src.replace(patch.find, patch.replace));
    console.log(`patch applied: ${patch.name} (${patch.file})`);
}
EOF


###############################################################################
# Stage 4 — Final image
###############################################################################
FROM node:20-bookworm-slim AS final

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
# libicu72: TwitchDownloaderCLI is a .NET binary and aborts on startup without
# an ICU package ("Couldn't find a valid ICU package installed on the system").
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gosu \
        tzdata \
        ca-certificates \
        atomicparsley \
        libicu72 \
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
