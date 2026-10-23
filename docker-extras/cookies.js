// Keeping a YouTube cookie jar alive.
//
// There is no username/password login to build here: yt-dlp refuses it for
// YouTube outright ("Login with password is not supported for YouTube. Use
// --cookies-from-browser or --cookies"), because Google's sign-in is a
// JavaScript flow with bot detection and device verification. A cookie jar is
// the only durable form of authentication, so the job is to stop the jar from
// dying - and the main thing that killed it was YTM itself.
//
// yt-dlp writes the rotated cookies back into the file it was given when it
// exits. YTM handed the *same* appdata/cookies.txt to every concurrent
// download, so up to five processes loaded one jar and wrote it back in
// whatever order they happened to finish: a process that started twenty
// minutes earlier overwrote the fresh cookies with its stale ones, and the
// session was gone. yt-dlp's own FAQ warns against sharing one cookie file
// between instances for exactly this reason.
//
// So: every yt-dlp run gets its own private copy of the jar, which it may
// write to as it pleases and which is then thrown away, and one single keeper
// run touches the master file on a timer - serialized, so there is never more
// than one writer.
//
// Not part of upstream YTM - this file is added by the Dockerfile of this
// edition, so it has no upstream anchor that could drift.

const fs = require('fs-extra');
const path = require('path');

const config_api = require('./config');
const logger = require('./logger');

// yt-dlp is started with /app as its working directory, so the paths handed to
// it stay relative, exactly as upstream does it.
const MASTER_RELATIVE = path.join('appdata', 'cookies.txt');
const COPIES_RELATIVE = path.join('appdata', 'cookie-copies');
const MASTER = path.join(__dirname, MASTER_RELATIVE);
const COPIES = path.join(__dirname, COPIES_RELATIVE);

// How often the master jar is exercised, and how long a leftover copy may sit
// around before it is swept up (a copy outlives its process only if that
// process was killed).
const REFRESH_MINUTES = 30;
const COPY_MAX_AGE_HOURS = 24;

let refresh_running = false;
let refresh_timer = null;

// Result of the last request made with the master jar, so the settings page can
// show whether the cookies still work instead of leaving it to the log.
let last_check = null;   // {at, ok, message}

// The cookies that actually carry a YouTube login. A jar exported while signed
// out looks perfectly well-formed and contains none of these - worth saying so
// plainly, because the file itself gives no hint.
const AUTH_COOKIES = ['__Secure-1PSID', '__Secure-3PSID', 'SID', 'HSID', 'SSID', 'SAPISID', 'LOGIN_INFO'];

// A private jar for one yt-dlp run. Returns the arguments to append, or nothing
// at all when cookies are switched off or the file is missing - same contract
// as the upstream code this replaces.
exports.cookieArgs = async (tag = 'run') => {
    if (!config_api.getConfigItem('ytdl_use_cookies')) return [];

    if (!await fs.pathExists(MASTER)) {
        logger.warn('Cookies file could not be found. You can either upload one, or disable \'use cookies\' in the Advanced tab in the settings.');
        return [];
    }

    try {
        await fs.ensureDir(COPIES);
        await sweepOldCopies();
        const name = `${tag}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}.txt`;
        await fs.copy(MASTER, path.join(COPIES, name));
        return ['--cookies', path.join(COPIES_RELATIVE, name)];
    } catch (e) {
        // Rather than fail the download, fall back to the shared file: that is
        // upstream's behaviour, cookie rotation and all.
        logger.error(`Cookies: could not prepare a private copy (${e}) - falling back to the shared file.`);
        return ['--cookies', MASTER_RELATIVE];
    }
};

async function sweepOldCopies() {
    const cutoff = Date.now() - COPY_MAX_AGE_HOURS * 60 * 60 * 1000;
    for (const entry of await fs.readdir(COPIES)) {
        const file = path.join(COPIES, entry);
        try {
            if ((await fs.stat(file)).mtimeMs < cutoff) await fs.unlink(file);
        } catch (e) {
            // a copy another run just removed - nothing to do
        }
    }
}

// One request with the master jar, which lets yt-dlp refresh and write it back,
// and which says whether the session still authenticates. :ytwatchlater is
// account-bound and tiny, so it answers both questions cheaply.
async function refreshMaster() {
    if (refresh_running) return last_check;
    if (!config_api.getConfigItem('ytdl_use_cookies')) return null;
    if (!await fs.pathExists(MASTER)) return null;

    refresh_running = true;
    const youtubedl_api = require('./youtube-dl');
    // Never hand the master itself to yt-dlp. yt-dlp writes back whatever the
    // session ended up as, and a request that was answered anonymously ends up
    // as a jar with no login in it at all - measured: a rejected jar came back
    // with eight tracking cookies and not one of the login cookies. Refreshing
    // on the master directly would mean a single bad answer, or one transient
    // YouTube error, quietly strips the login out of the uploaded file. So
    // refresh on a copy and promote it only if it still carries a login.
    const probe_relative = path.join(COPIES_RELATIVE, 'keeper.txt');
    const probe = path.join(COPIES, 'keeper.txt');
    try {
        await fs.ensureDir(COPIES);
        await fs.copy(MASTER, probe, {overwrite: true});

        const args = ['--cookies', probe_relative, '--flat-playlist', '--playlist-items', '1',
                      '--simulate', '--ignore-config', '--print', '%(id)s'];
        const {callback} = await youtubedl_api.runYoutubeDL(':ytwatchlater', args) || {};
        if (!callback) {
            logger.warn('Cookies: refresh skipped, the downloader could not be started.');
            return last_check;
        }
        const {err} = await callback;
        const stderr = String((err && (err.stderr || err.message)) || err || '');
        // Don't try to match YouTube's wording: a jar that no longer
        // authenticates gets "The playlist does not exist" for the watch later
        // list, somebody else's build gets something different again. Any ERROR
        // on a request that only needs a working session is worth reporting -
        // at warn, because a hiccup is not worth shouting about.
        const rejected = stderr.split('\n').find(line => line.startsWith('ERROR:'));
        const refreshed = await readJar(probe);

        if (!rejected && refreshed.auth_cookies > 0) {
            await fs.copy(probe, MASTER, {overwrite: true});
            logger.verbose('Cookies: master jar refreshed.');
            last_check = {at: Date.now(), ok: true, message: ''};
        } else {
            const reason = rejected
                ? rejected.replace(/^ERROR:\s*/, '')
                : 'YouTube answered the request but renewed no login - the cookies are not being accepted.';
            logger.warn('Cookies: the refresh was rejected, which usually means the stored cookies no longer work - '
                      + `upload a fresh cookies.txt. Reason: ${reason}`);
            last_check = {at: Date.now(), ok: false, message: reason};
        }
    } catch (e) {
        logger.warn(`Cookies: refresh failed (${e}).`);
        last_check = {at: Date.now(), ok: false, message: `the check itself failed: ${e}`};
    } finally {
        await fs.remove(probe).catch(() => {});
        refresh_running = false;
    }
    return last_check;
}

// What a jar itself says, without asking YouTube.
async function readJar(file = MASTER) {
    const facts = {cookie_count: 0, auth_cookies: 0, expires: null};
    let text = '';
    try {
        text = await fs.readFile(file, 'utf8');
    } catch (e) {
        return facts;
    }
    for (const line of text.split('\n')) {
        // '#HttpOnly_' is a real entry some exporters write, any other '#' is a comment.
        const row = line.startsWith('#HttpOnly_') ? line.slice('#HttpOnly_'.length) : line;
        if (!row || row.startsWith('#')) continue;
        const fields = row.split('\t');
        if (fields.length < 7) continue;
        facts.cookie_count++;
        if (!AUTH_COOKIES.includes(fields[5])) continue;
        facts.auth_cookies++;
        // 0 means a session cookie, which has no useful date.
        const expires = parseInt(fields[4], 10) * 1000;
        if (expires > 0 && (facts.expires === null || expires < facts.expires)) facts.expires = expires;
    }
    return facts;
}

// One line for the settings page: is this jar going to work, and since when do
// we believe that.
exports.status = async () => {
    const enabled = !!config_api.getConfigItem('ytdl_use_cookies');
    const file_present = await fs.pathExists(MASTER);
    const status = {
        enabled, file_present, state: 'unknown', message: '',
        last_checked: last_check ? last_check.at : null,
        file_modified: null, cookie_count: 0, auth_cookies: 0, expires: null,
        refresh_minutes: REFRESH_MINUTES,
    };

    if (!file_present) {
        status.state = 'missing';
        return status;
    }

    try {
        status.file_modified = (await fs.stat(MASTER)).mtimeMs;
    } catch (e) {
        // not worth failing the whole status over
    }
    Object.assign(status, await readJar());

    if (status.auth_cookies === 0) {
        // No point asking YouTube: this jar cannot authenticate anything.
        status.state = 'no_login';
        return status;
    }
    if (!enabled) {
        status.state = 'off';
        return status;
    }
    if (last_check) {
        status.state = last_check.ok ? 'ok' : 'rejected';
        status.message = last_check.message;
    }
    return status;
};

// Check right now instead of waiting for the timer - what the button on the
// settings page calls, and what runs after a fresh upload.
exports.checkNow = async () => {
    if (config_api.getConfigItem('ytdl_use_cookies') && await fs.pathExists(MASTER)) await refreshMaster();
    return exports.status();
};

exports.start = () => {
    if (refresh_timer) return;
    // Not straight away: at startup the downloader binary may still be on its
    // way in.
    setTimeout(() => refreshMaster(), 2 * 60 * 1000);
    refresh_timer = setInterval(() => refreshMaster(), REFRESH_MINUTES * 60 * 1000);
    logger.info(`Cookies: keeping appdata/cookies.txt alive, refreshed every ${REFRESH_MINUTES} minutes. Each download works on its own copy.`);
};
