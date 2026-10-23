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
    if (refresh_running) return;
    if (!config_api.getConfigItem('ytdl_use_cookies')) return;
    if (!await fs.pathExists(MASTER)) return;

    refresh_running = true;
    const youtubedl_api = require('./youtube-dl');
    try {
        const args = ['--cookies', MASTER_RELATIVE, '--flat-playlist', '--playlist-items', '1',
                      '--simulate', '--ignore-config', '--print', '%(id)s'];
        const {callback} = await youtubedl_api.runYoutubeDL(':ytwatchlater', args) || {};
        if (!callback) {
            logger.warn('Cookies: refresh skipped, the downloader could not be started.');
            return;
        }
        const {err} = await callback;
        const stderr = String((err && (err.stderr || err.message)) || err || '');
        // Don't try to match YouTube's wording: a jar that no longer
        // authenticates gets "The playlist does not exist" for the watch later
        // list, somebody else's build gets something different again. Any ERROR
        // on a request that only needs a working session is worth reporting -
        // at warn, because a hiccup is not worth shouting about.
        const rejected = stderr.split('\n').find(line => line.startsWith('ERROR:'));
        if (rejected) {
            logger.warn('Cookies: the refresh request was rejected, which usually means the stored cookies no longer work - '
                      + `upload a fresh cookies.txt. The downloader said: ${rejected}`);
        } else {
            logger.verbose('Cookies: master jar refreshed.');
        }
    } catch (e) {
        logger.warn(`Cookies: refresh failed (${e}).`);
    } finally {
        refresh_running = false;
    }
}

exports.start = () => {
    if (refresh_timer) return;
    // Not straight away: at startup the downloader binary may still be on its
    // way in.
    setTimeout(() => refreshMaster(), 2 * 60 * 1000);
    refresh_timer = setInterval(() => refreshMaster(), REFRESH_MINUTES * 60 * 1000);
    logger.info(`Cookies: keeping appdata/cookies.txt alive, refreshed every ${REFRESH_MINUTES} minutes. Each download works on its own copy.`);
};
