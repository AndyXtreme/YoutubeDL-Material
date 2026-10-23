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

# Patches against the YTM frontend, same contract as the backend ones further
# down: each names the exact code it replaces and the build aborts if that code
# has changed. These add the "renumber" button on a subscription page and the
# switch that turns the automatic pass on.
RUN node - <<'EOF'
const fs = require('fs');

const patches = [
{
    name: 'api: renumberSubscription',
    file: 'src/app/posts.services.ts',
    find: "    cancelCheckSubscription(sub_id: string) {\n        const body: CheckSubscriptionRequest = {sub_id: sub_id};\n        return this.http.post<SuccessObject>(this.path + 'cancelCheckSubscription', body, this.httpOptions);\n    }",
    replace: [
        "    cancelCheckSubscription(sub_id: string) {",
        "        const body: CheckSubscriptionRequest = {sub_id: sub_id};",
        "        return this.http.post<SuccessObject>(this.path + 'cancelCheckSubscription', body, this.httpOptions);",
        "    }",
        "",
        "    renumberSubscription(sub_id: string, dry_run = true, force = false) {",
        "        return this.http.post<any>(this.path + 'renumberSubscription', {sub_id: sub_id, dry_run: dry_run, force: force}, this.httpOptions);",
        "    }"
    ].join('\n')
},
{
    // The dialog renders the preview as plain text, so the line breaks in it
    // have to survive. Existing single-line dialogs are unaffected.
    name: 'dialog: keep line breaks in the text',
    file: 'src/app/dialogs/confirm-dialog/confirm-dialog.component.html',
    find: "      {{dialogText}}",
    replace: "      <span style=\"white-space: pre-line;\">{{dialogText}}</span>"
},
{
    name: 'subscription page: import the confirm dialog',
    file: 'src/app/subscription/subscription/subscription.component.ts',
    find: "import { EditSubscriptionDialogComponent } from 'app/dialogs/edit-subscription-dialog/edit-subscription-dialog.component';",
    replace: "import { EditSubscriptionDialogComponent } from 'app/dialogs/edit-subscription-dialog/edit-subscription-dialog.component';\nimport { ConfirmDialogComponent } from 'app/dialogs/confirm-dialog/confirm-dialog.component';"
},
{
    name: 'subscription page: renumber state',
    file: 'src/app/subscription/subscription/subscription.component.ts',
    find: "  check_clicked = false;\n  cancel_clicked = false;",
    replace: "  check_clicked = false;\n  cancel_clicked = false;\n  renumber_clicked = false;"
},
{
    // Preview first, rename only after that is confirmed.
    name: 'subscription page: renumber action',
    file: 'src/app/subscription/subscription/subscription.component.ts',
    find: "  cancelCheckSubscription(): void {",
    replace: [
        "  renumberSubscription(): void {",
        "    this.renumber_clicked = true;",
        "    this.postsService.renumberSubscription(this.subscription.id, true).subscribe(res => {",
        "      this.renumber_clicked = false;",
        "      if (!res['success']) {",
        "        this.postsService.openSnackBar(res['error'] || 'Renumbering failed!');",
        "        return;",
        "      }",
        "      if (!res['renames']) {",
        "        this.postsService.openSnackBar('The numbering already matches the playlist.');",
        "        return;",
        "      }",
        "      const shown = res['changes'].slice(0, 12).map(change => change['from'] + '   \\u2192   ' + change['to']).join('\\n');",
        "      const rest = res['changes'].length > 12 ? '\\n\\u2026 and ' + (res['changes'].length - 12) + ' more' : '';",
        "      this.dialog.open(ConfirmDialogComponent, {",
        "        data: {",
        "          dialogTitle: 'Renumber ' + res['renames'] + ' file(s)?',",
        "          dialogText: res['still_in_playlist'] + ' of the files are still in the playlist, ' + res['removed_from_playlist']",
        "            + ' no longer are - those lose their number.\\n\\n' + shown + rest,",
        "          submitText: 'Rename',",
        "        }",
        "      }).afterClosed().subscribe(confirmed => {",
        "        if (!confirmed) { return; }",
        "        this.postsService.renumberSubscription(this.subscription.id, false).subscribe(done => {",
        "          this.postsService.openSnackBar(done['success'] ? done['renames'] + ' file(s) renumbered.' : (done['error'] || 'Renumbering failed!'));",
        "          this.postsService.files_changed.next(true);",
        "        }, err => {",
        "          console.error(err);",
        "          this.postsService.openSnackBar('Renumbering failed!');",
        "        });",
        "      });",
        "    }, err => {",
        "      console.error(err);",
        "      this.renumber_clicked = false;",
        "      this.postsService.openSnackBar('Renumbering failed!');",
        "    });",
        "  }",
        "",
        "  cancelCheckSubscription(): void {"
    ].join('\n')
},
{
    name: 'subscription page: renumber button',
    file: 'src/app/subscription/subscription/subscription.component.html',
    find: "            <button class=\"edit-button\" (click)=\"editSubscription()\" [disabled]=\"downloading\" matTooltip=\"Edit\" i18n-matTooltip=\"Edit\" mat-icon-button><mat-icon class=\"save-icon\">edit</mat-icon></button>",
    replace: [
        "            <button class=\"edit-button\" (click)=\"editSubscription()\" [disabled]=\"downloading\" matTooltip=\"Edit\" i18n-matTooltip=\"Edit\" mat-icon-button><mat-icon class=\"save-icon\">edit</mat-icon></button>",
        "            <button *ngIf=\"subscription.isPlaylist\" class=\"renumber-button\" (click)=\"renumberSubscription()\" [disabled]=\"renumber_clicked || subscription.downloading\" matTooltip=\"Renumber files to match the playlist\" i18n-matTooltip=\"Renumber subscription\" mat-icon-button><mat-icon class=\"save-icon\">format_list_numbered</mat-icon></button>"
    ].join('\n')
},
{
    // .edit-button is pinned to the top right, so the new one needs its own
    // offset or the two sit on top of each other.
    name: 'subscription page: renumber button position',
    file: 'src/app/subscription/subscription/subscription.component.scss',
    find: ".edit-button {\n    right: 35px;\n    position: fixed;\n    z-index: 99999;\n}",
    replace: ".edit-button {\n    right: 35px;\n    position: fixed;\n    z-index: 99999;\n}\n\n.renumber-button {\n    right: 80px;\n    position: fixed;\n    z-index: 99999;\n}"
},
{
    name: 'api: cookie status',
    file: 'src/app/posts.services.ts',
    find: "    uploadCookiesFile(cookiesFile: File, cookiesFilePath: string) {",
    replace: [
        "    getCookieStatus() {",
        "        return this.http.post<any>(this.path + 'getCookieStatus', {}, this.httpOptions);",
        "    }",
        "",
        "    checkCookies() {",
        "        return this.http.post<any>(this.path + 'checkCookies', {}, this.httpOptions);",
        "    }",
        "",
        "    uploadCookiesFile(cookiesFile: File, cookiesFilePath: string) {"
    ].join('\n')
},
{
    name: 'settings: cookie status state',
    file: 'src/app/settings/settings.component.ts',
    find: "  db_info: DBInfoResponse = null;\n  db_transferring = false;",
    replace: "  db_info: DBInfoResponse = null;\n  db_transferring = false;\n  cookie_status = null;\n  cookie_checking = false;"
},
{
    name: 'settings: cookie status loader',
    file: 'src/app/settings/settings.component.ts',
    find: "  openCookiesUploaderDialog(): void {\n    this.dialog.open(CookiesUploaderDialogComponent, {\n      width: '65vw'\n    });\n  }",
    replace: [
        "  openCookiesUploaderDialog(): void {",
        "    this.dialog.open(CookiesUploaderDialogComponent, {",
        "      width: '65vw'",
        "    }).afterClosed().subscribe(() => this.checkCookiesNow());",
        "  }",
        "",
        "  getCookieStatus(): void {",
        "    this.postsService.getCookieStatus().subscribe(res => {",
        "      this.cookie_status = res;",
        "    }, err => console.error(err));",
        "  }",
        "",
        "  checkCookiesNow(): void {",
        "    this.cookie_checking = true;",
        "    this.postsService.checkCookies().subscribe(res => {",
        "      this.cookie_checking = false;",
        "      this.cookie_status = res;",
        "    }, err => {",
        "      console.error(err);",
        "      this.cookie_checking = false;",
        "    });",
        "  }",
        "",
        "  cookieStatusText(): string {",
        "    const status = this.cookie_status;",
        "    if (!status) { return ''; }",
        "    switch (status['state']) {",
        "      case 'missing':  return $localize`No cookies file uploaded yet.`;",
        "      case 'no_login': return $localize`The uploaded file carries no YouTube login - it was most likely exported while signed out.`;",
        "      case 'off':      return $localize`A usable file is stored, but \"Use Cookies\" is switched off.`;",
        "      case 'ok':       return $localize`Cookies accepted by YouTube.`;",
        "      case 'rejected': return $localize`YouTube rejected the cookies: ` + status['message'];",
        "      default:         return $localize`Not checked yet.`;",
        "    }",
        "  }",
        "",
        "  cookieStatusIcon(): string {",
        "    const state = this.cookie_status ? this.cookie_status['state'] : '';",
        "    if (state === 'ok') { return 'check_circle'; }",
        "    if (state === 'rejected' || state === 'no_login') { return 'error'; }",
        "    if (state === 'missing') { return 'info'; }",
        "    return 'help';",
        "  }",
        "",
        "  cookieStatusDetail(): string {",
        "    const status = this.cookie_status;",
        "    if (!status || !status['file_present']) { return ''; }",
        "    const parts = [status['cookie_count'] + ' cookies, ' + status['auth_cookies'] + ' of them login cookies'];",
        "    if (status['expires']) { parts.push((status['expires'] < Date.now() ? 'a login cookie expired on ' : 'valid until ') + new Date(status['expires']).toLocaleDateString()); }",
        "    if (status['last_checked']) { parts.push('last checked ' + new Date(status['last_checked']).toLocaleTimeString()); }",
        "    if (status['state'] === 'ok') { parts.push('refreshed every ' + status['refresh_minutes'] + ' min'); }",
        "    return parts.join(' \\u00b7 ');",
        "  }"
    ].join('\n')
},
{
    name: 'settings: load the cookie status on open',
    file: 'src/app/settings/settings.component.ts',
    find: "      this.getConfig();\n      this.getDBInfo();",
    replace: "      this.getConfig();\n      this.getDBInfo();\n      this.getCookieStatus();"
},
{
    name: 'settings: load the cookie status on open (deferred)',
    file: 'src/app/settings/settings.component.ts',
    find: "          this.getConfig();\n          this.getDBInfo();",
    replace: "          this.getConfig();\n          this.getDBInfo();\n          this.getCookieStatus();"
},
{
    // The line that was missing: upload a file, press a switch, and until now
    // nothing ever said whether any of it worked.
    name: 'settings: cookie status line',
    file: 'src/app/settings/settings.component.html',
    find: "                        <button class=\"checkbox-button\" mat-stroked-button (click)=\"openCookiesUploaderDialog()\"><ng-container i18n=\"Set cookies button\">Set Cookies</ng-container></button>",
    replace: [
        "                        <button class=\"checkbox-button\" mat-stroked-button (click)=\"openCookiesUploaderDialog()\"><ng-container i18n=\"Set cookies button\">Set Cookies</ng-container></button>",
        "                        <button class=\"checkbox-button\" mat-stroked-button [disabled]=\"cookie_checking || !cookie_status || !cookie_status['file_present']\" (click)=\"checkCookiesNow()\"><ng-container i18n=\"Check cookies button\">Check now</ng-container><mat-spinner *ngIf=\"cookie_checking\" style=\"display: inline-block; margin-left: 8px;\" [diameter]=\"16\"></mat-spinner></button>",
        "                        <div *ngIf=\"cookie_status\" style=\"margin-top: 10px; display: flex; align-items: flex-start;\">",
        "                            <mat-icon [ngStyle]=\"{'color': cookie_status['state'] === 'ok' ? '#4caf50' : (cookie_status['state'] === 'rejected' || cookie_status['state'] === 'no_login' ? '#f44336' : 'inherit')}\" style=\"margin-right: 8px;\">{{cookieStatusIcon()}}</mat-icon>",
        "                            <div>",
        "                                <div>{{cookieStatusText()}}</div>",
        "                                <div *ngIf=\"cookieStatusDetail()\" style=\"opacity: 0.7; font-size: 90%;\">{{cookieStatusDetail()}}</div>",
        "                            </div>",
        "                        </div>"
    ].join('\n')
},
{
    name: 'settings: renumber after each check',
    file: 'src/app/settings/settings.component.html',
    find: "                    <div class=\"col-12 mt-3 mb-3\">\n                        <mat-checkbox color=\"accent\" [(ngModel)]=\"new_config['Subscriptions']['redownload_fresh_uploads']\"",
    replace: "                    <div class=\"col-12 mt-3\">\n                        <mat-checkbox color=\"accent\" [disabled]=\"!new_config['Subscriptions']['allow_subscriptions']\" [(ngModel)]=\"new_config['Subscriptions']['renumber_on_check']\" matTooltip=\"After each check, rename the files of a playlist subscription so the numbering matches the playlist again. Videos that were taken out of the playlist lose their number. Skipped whenever the playlist could only be read partially, so a throttled check cannot scramble the numbering.\" i18n-matTooltip=\"Renumber after check tooltip\"><ng-container i18n=\"Renumber after check\">Renumber files after each check</ng-container></mat-checkbox>\n                    </div>\n                    <div class=\"col-12 mt-3 mb-3\">\n                        <mat-checkbox color=\"accent\" [(ngModel)]=\"new_config['Subscriptions']['redownload_fresh_uploads']\""
}
];

for (const patch of patches) {
    const src = fs.readFileSync(patch.file, 'utf8').split('\r\n').join('\n');
    if (!src.includes(patch.find)) {
        console.error(`patch '${patch.name}': anchor not found in ${patch.file}, aborting`);
        process.exit(1);
    }
    fs.writeFileSync(patch.file, src.replace(patch.find, patch.replace));
    console.log(`patch applied: ${patch.name} (${patch.file})`);
}
EOF

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
# Additions of this edition that are whole files rather than patches, so they
# have no upstream anchor that could drift.
COPY ["docker-extras/", "./"]

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
},
{
    // A subscription is flagged 'downloading' for the length of its check, and
    // every later check is skipped while that flag is set. runYoutubeDL()
    // returns undefined when the binary is missing - destructuring that throws,
    // the flag is never cleared, and the subscription is silently skipped for
    // good (until the next restart clears it).
    name: 'subscription check: never leave the downloading flag set',
    file: 'subscriptions.js',
    find: "    let {child_process, callback} = await youtubedl_api.runYoutubeDL(sub.url, downloadConfig);\n    updateSubscriptionProperty(sub, {child_process: child_process}, user_uid);",
    replace: "    let child_process = null, callback = null;\n    try {\n        ({child_process, callback} = await youtubedl_api.runYoutubeDL(sub.url, downloadConfig) || {});\n    } catch (e) {\n        logger.error(`Subscription: check for ${sub.name} could not be started: ${e}`);\n    }\n    if (!callback) {\n        logger.error(`Subscription: check for ${sub.name} was not started - is the yt-dlp binary in appdata/bin intact?`);\n        updateSubscriptionProperty(sub, {downloading: false, child_process: null}, user_uid);\n        return null;\n    }\n    updateSubscriptionProperty(sub, {child_process: child_process}, user_uid);"
},
{
    // At the default log level a subscription check was completely invisible:
    // start, result and \"nothing new\" were all on verbose. That leaves \"it just
    // doesn't download\" with nothing to go on.
    name: 'log: subscription check start',
    file: 'subscriptions.js',
    find: "    logger.verbose(`Subscription: getting list of videos to download for ${sub.name} with args: ${downloadConfig.join(',')}`);",
    replace: "    logger.info(`Subscription: checking ${sub.name} - for a long playlist this takes several minutes.`);\n    logger.verbose(`Subscription: getting list of videos to download for ${sub.name} with args: ${downloadConfig.join(',')}`);"
},
{
    name: 'log: subscription check result',
    file: 'subscriptions.js',
    find: "    logger.verbose('Subscription: finished check for ' + sub.name);\n    const files_to_download = await handleOutputJSON(parsed_output, sub, user_uid);",
    replace: "    logger.verbose('Subscription: finished check for ' + sub.name);\n    const files_to_download = await handleOutputJSON(parsed_output, sub, user_uid);\n    logger.info(`Subscription: ${sub.name} checked, ${files_to_download.length} new video(s) queued.`);\n    await renumber_api.renumberAfterCheck(sub);"
},
{
    name: 'log: nothing new for a subscription',
    file: 'subscriptions.js',
    find: "        logger.verbose('No additional videos to download for ' + sub.name);",
    replace: "        logger.info('No additional videos to download for ' + sub.name);"
},
{
    // The only clue that a subscription is stuck on its downloading flag.
    name: 'log: subscription skipped while checking',
    file: 'subscriptions.js',
    find: "        logger.verbose(`Subscription: skipped checking ${sub.name} as it's downloading videos.`);",
    replace: "        logger.info(`Subscription: skipped checking ${sub.name} as its previous check is still running.`);"
},
{
    // yt-dlp exits non-zero as soon as a single entry of a playlist fails - a
    // deleted, private or geo-blocked video. -i only keeps it going, it does
    // not change the exit code, and execa turns a non-zero exit into a
    // rejection. This catch threw away e.stdout, which holds the JSON of every
    // video that *did* work: one dead video in a playlist and the whole
    // subscription check reports "failed", so nothing from that playlist is
    // ever downloaded.
    name: 'salvage the output when yt-dlp exits with an error',
    file: 'youtube-dl.js',
    find: "        } catch (e) {\n            resolve({parsed_output: null, err: e})\n        }",
    replace: [
        "        } catch (e) {",
        "            const salvaged = e && typeof e.stdout === 'string' ? e.stdout.trim() : '';",
        "            const parsed_output = salvaged ? utils.parseOutputJSON(salvaged.split(/\\r?\\n/), null) : null;",
        "            if (parsed_output) logger.warn(`${youtubedl_fork} reported an error but returned ${parsed_output.length} usable entry/entries - continuing with those. Unavailable videos inside a playlist are the usual cause.`);",
        "            resolve({parsed_output, err: e})",
        "        }"
    ].join('\n')
},
{
    // A single unreadable line killed the whole batch: indexOf('{"') returns -1
    // for a line that is not JSON, and slice(-1) then reduces it to its last
    // character - which JSON.parse rejects, taking every good entry with it.
    name: 'skip non-JSON lines in the downloader output',
    file: 'utils.js',
    find: "        for (const output_item of output) {\n            // we have to do this because sometimes there will be leading characters before the actual json\n            const start_idx = output_item.indexOf('{\"');\n            const clean_output = output_item.slice(start_idx, output_item.length);\n            split_output.push(clean_output);\n        }",
    replace: [
        "        for (const output_item of output) {",
        "            // we have to do this because sometimes there will be leading characters before the actual json",
        "            const start_idx = output_item.indexOf('{\"');",
        "            if (start_idx === -1) continue;",
        "            split_output.push(output_item.slice(start_idx, output_item.length));",
        "        }"
    ].join('\n')
},
{
    // ...and parse what is left entry by entry, so one broken record no longer
    // discards the other 227.
    name: 'parse the downloader output entry by entry',
    file: 'utils.js',
    find: "    try {\n        return split_output.map(split_output_str => JSON.parse(split_output_str));\n    } catch(e) {\n        return null;\n    }",
    replace: [
        "    const parsed_output = [];",
        "    for (const split_output_str of split_output) {",
        "        try {",
        "            parsed_output.push(JSON.parse(split_output_str));",
        "        } catch (e) {",
        "            logger.warn('Skipping one unreadable entry in the downloader output.');",
        "        }",
        "    }",
        "    return parsed_output.length > 0 ? parsed_output : null;"
    ].join('\n')
},
{
    // Wire up the files this edition adds of its own.
    name: 'require the renumber and cookie helpers',
    file: 'app.js',
    find: "const subscriptions_api = require('./subscriptions');",
    replace: "const subscriptions_api = require('./subscriptions');\nconst renumber_api = require('./renumber');\nconst cookies_api = require('./cookies');"
},
{
    // Every yt-dlp run gets its own copy of the cookie jar instead of all of
    // them sharing appdata/cookies.txt - see cookies.js for why that one shared
    // file was killing the session. Both call sites in subscriptions.js are
    // byte for byte identical, hence 'all'.
    name: 'cookies: private jar per subscription run',
    file: 'subscriptions.js',
    all: true,
    find: "    if (useCookies) {\n        if (await fs.pathExists(path.join(__dirname, 'appdata', 'cookies.txt'))) {\n            downloadConfig.push('--cookies', path.join('appdata', 'cookies.txt'));\n        } else {\n            logger.warn('Cookies file could not be found. You can either upload one, or disable \\'use cookies\\' in the Advanced tab in the settings.');\n        }\n    }",
    replace: "    if (useCookies) {\n        downloadConfig.push(...await cookies_api.cookieArgs('sub'));\n    }"
},
{
    name: 'cookies: private jar per download',
    file: 'downloader.js',
    find: "        if (useCookies) {\n            if (await fs.pathExists(path.join(__dirname, 'appdata', 'cookies.txt'))) {\n                downloadConfig.push('--cookies', path.join('appdata', 'cookies.txt'));\n            } else {\n                logger.warn('Cookies file could not be found. You can either upload one, or disable \\'use cookies\\' in the Advanced tab in the settings.');\n            }\n        }",
    replace: "        if (useCookies) {\n            downloadConfig.push(...await cookies_api.cookieArgs('download'));\n        }"
},
{
    name: 'require the helpers in subscriptions.js',
    file: 'subscriptions.js',
    find: "const archive_api = require('./archive');",
    replace: "const archive_api = require('./archive');\nconst cookies_api = require('./cookies');\nconst renumber_api = require('./renumber');"
},
{
    // The switch for renumbering after a check. Default off: an update must not
    // start renaming somebody's library on its own.
    name: 'config: renumber_on_check',
    file: 'config.js',
    find: "        \"redownload_fresh_uploads\": false",
    replace: "        \"redownload_fresh_uploads\": false,\n        \"renumber_on_check\": false"
},
{
    name: 'config item: ytdl_subscriptions_renumber_on_check',
    file: 'consts.js',
    find: "    'ytdl_subscriptions_redownload_fresh_uploads': {\n        'key': 'ytdl_subscriptions_redownload_fresh_uploads',\n        'path': 'YoutubeDLMaterial.Subscriptions.redownload_fresh_uploads'\n    },",
    replace: "    'ytdl_subscriptions_redownload_fresh_uploads': {\n        'key': 'ytdl_subscriptions_redownload_fresh_uploads',\n        'path': 'YoutubeDLMaterial.Subscriptions.redownload_fresh_uploads'\n    },\n    'ytdl_subscriptions_renumber_on_check': {\n        'key': 'ytdl_subscriptions_renumber_on_check',\n        'path': 'YoutubeDLMaterial.Subscriptions.renumber_on_check'\n    },"
},
{
    name: 'cookies: require the helper in downloader.js',
    file: 'downloader.js',
    find: "const archive_api = require('./archive');",
    replace: "const archive_api = require('./archive');\nconst cookies_api = require('./cookies');"
},
{
    // So the settings page can say whether the stored jar still works, instead
    // of that only being visible in the log.
    name: 'endpoints: cookie status',
    file: 'app.js',
    find: "var upload_multer = multer({ dest: __dirname + '/appdata/' });",
    replace: [
        "app.post('/api/getCookieStatus', optionalJwt, async (req, res) => {",
        "    res.send(await cookies_api.status());",
        "});",
        "",
        "app.post('/api/checkCookies', optionalJwt, async (req, res) => {",
        "    res.send(await cookies_api.checkNow());",
        "});",
        "",
        "var upload_multer = multer({ dest: __dirname + '/appdata/' });"
    ].join('\n')
},
{
    // The one serialized writer that keeps the master jar fresh.
    name: 'cookies: start the keeper',
    file: 'app.js',
    find: "        subscriptions_api.watchSubscriptionsInterval();\n    }",
    replace: "        subscriptions_api.watchSubscriptionsInterval();\n    }\n\n    cookies_api.start();"
},
{
    // Renumber a subscription folder against the playlist as it is now. Default
    // is a dry run: it answers with the list of renames it would make.
    name: 'endpoint: renumberSubscription',
    file: 'app.js',
    find: "app.post('/api/updateSubscription', optionalJwt, async (req, res) => {",
    replace: [
        "app.post('/api/renumberSubscription', optionalJwt, async (req, res) => {",
        "    try {",
        "        res.send(await renumber_api.renumberSubscription(req.body.sub_id, {dry_run: req.body.dry_run !== false, force: req.body.force === true}));",
        "    } catch (e) {",
        "        logger.error(`Renumber: ${e}`);",
        "        res.send({success: false, error: String((e && e.message) || e)});",
        "    }",
        "});",
        "",
        "app.post('/api/updateSubscription', optionalJwt, async (req, res) => {"
    ].join('\n')
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
    // split/join rather than replaceAll: it takes the replacement literally, so
    // a '$' in the new code cannot turn into a substitution pattern.
    const count = patch.all ? src.split(patch.find).length - 1 : 1;
    fs.writeFileSync(patch.file, patch.all ? src.split(patch.find).join(patch.replace) : src.replace(patch.find, patch.replace));
    console.log(`patch applied: ${patch.name} (${patch.file}${patch.all ? `, ${count}x` : ''})`);
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
