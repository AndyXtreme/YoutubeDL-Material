// Renumber a subscription folder after videos were removed from the playlist.
//
// A file output template with %(playlist_index)s bakes the playlist position
// into the file name. Remove one video from the playlist upstream and every
// position behind it shifts by one, while the files on disk keep the numbers
// they were downloaded with. This re-derives the numbers from the playlist as
// it is now: a file whose video is still in the playlist gets its current
// position, a file whose video is gone loses its number altogether.
//
// Not part of upstream YTM - this file is added by the Dockerfile of this
// edition, so it has no upstream anchor that could drift.

const fs = require('fs-extra');
const path = require('path');

const config_api = require('./config');
const db_api = require('./db');
const youtubedl_api = require('./youtube-dl');
const utils = require('./utils');
const logger = require('./logger');

// subscriptions.js requires this file, so pull it in only when it is needed -
// a top-level require here would close the circle.
const subscriptions = () => require('./subscriptions');

// "007 - Title [id].mp4", "7. Title.mp4", "07_Title.mp4": separator and padding
// are whatever the output template produced, so read them off the files that
// are already there instead of assuming one form.
const PREFIX = /^(\d{1,5})(\s*[-_.)\]]\s*|\s+)/;

function splitPrefix(stem) {
    const match = stem.match(PREFIX);
    if (!match) return {width: 0, separator: null, rest: stem};
    return {width: match[1].length, separator: match[2], rest: stem.slice(match[0].length)};
}

// The video id out of whatever is at hand. Needed because the two sides do not
// speak the same language: a playlist entry carries the real video id, while a
// file record's 'id' is its own file name without the extension
// (files.js: removeFileExtension(basename(file_path))). The reliable link is
// the watch URL, which both sides have - that is what subscriptions.js matches
// on as well.
function videoIdOf(value) {
    if (!value) return null;
    const text = String(value);
    if (!text.includes('/')) return text;                 // already a bare id
    const query = text.match(/[?&]v=([^&#]+)/);           // .../watch?v=ID
    if (query) return query[1];
    const last = text.match(/\/([^/?#]+)(?:[?#]|$)/);     // .../ID
    return last ? last[1] : null;
}

function mostCommon(counts, fallback) {
    const entries = Object.entries(counts);
    if (entries.length === 0) return fallback;
    return entries.sort((a, b) => b[1] - a[1])[0][0];
}

// The playlist as it is right now: video id -> current position, plus the
// length the playlist claims for itself. The two together are what makes it
// safe to rename unattended: if fewer entries came back than the playlist says
// it has, the enumeration was cut short and its order must not be acted on.
async function getCurrentPlaylistOrder(sub) {
    const args = ['--flat-playlist', '--dump-json'];
    const use_cookies = config_api.getConfigItem('ytdl_use_cookies');
    if (use_cookies) {
        if (await fs.pathExists(path.join(__dirname, 'appdata', 'cookies.txt'))) {
            args.push('--cookies', path.join('appdata', 'cookies.txt'));
        } else {
            logger.warn('Renumber: cookies are enabled but appdata/cookies.txt is missing - the playlist may be enumerated incompletely.');
        }
    }

    const {callback} = await youtubedl_api.runYoutubeDL(sub.url, args) || {};
    if (!callback) throw new Error('the downloader could not be started - check appdata/bin');

    const {parsed_output, err} = await callback;
    if (!parsed_output) throw new Error(`the playlist could not be read: ${(err && (err.stderr || err.message)) || err}`);

    const order = new Map();
    const by_url = new Map();
    let advertised = null;
    parsed_output.forEach((entry, i) => {
        if (!entry) return;
        const position = entry['playlist_index'] != null ? entry['playlist_index'] : i + 1;
        // A channel does not advertise a count, only a playlist does.
        if (advertised == null && entry['playlist_count'] != null) advertised = entry['playlist_count'];
        for (const candidate of [entry['id'], entry['url'], entry['webpage_url']]) {
            const id = videoIdOf(candidate);
            if (id) order.set(id, position);
        }
        for (const url of [entry['url'], entry['webpage_url']]) {
            if (url) by_url.set(String(url), position);
        }
    });
    return {order, by_url, advertised};
}

// A file's position in the playlist, by URL first and by video id after.
function positionOf(file, order, by_url) {
    const direct = by_url.get(String(file['url']));
    if (direct != null) return direct;
    for (const candidate of [file['url'], file['id']]) {
        const id = videoIdOf(candidate);
        if (id && order.has(id)) return order.get(id);
    }
    return null;
}

// Every file that belongs to one download: the media file plus the sidecars
// yt-dlp wrote next to it (.info.json, thumbnail, subtitles, description).
async function siblingFiles(file_path) {
    const dir = path.dirname(file_path);
    const stem = path.parse(file_path).name;
    const entries = await fs.readdir(dir);
    return entries.filter(entry => entry === stem || entry.startsWith(stem + '.'));
}

// Every refusal goes into the log as well. The caller shows it, but a message
// on screen is gone the moment it is dismissed, and "it just said something and
// disappeared" is not something anyone can act on.
function refuse(name, result) {
    logger.info(`Renumber: ${name} - nothing was renamed. ${result.error}`);
    return Object.assign({success: false}, result);
}

// only_numbered: touch nothing that does not already carry a number. The
// automatic pass runs it that way, because the stock file output template is
// %(title)s - without it, switching the automatic pass on would not maintain a
// numbering, it would impose one on everybody whose files never had one. The
// button does not set it: there the numbering is asked for and shown first.
exports.renumberSubscription = async (sub_id, {dry_run = true, force = false, only_numbered = false} = {}) => {
    const sub = await subscriptions().getSubscription(sub_id);
    if (!sub) return refuse(sub_id, {error: `No subscription with id ${sub_id}.`});

    const all_records = await db_api.getRecords('files', {sub_id: sub.id});
    if (!all_records || all_records.length === 0) return refuse(sub.name, {error: `Subscription ${sub.name} has no files in the database.`});

    // One file on disk can carry several database records - measured on a real
    // library, eight records over five paths. Planning per record would hand
    // the same file to the rename twice, which the collision check would then
    // report as two files wanting the same name, blaming the output template
    // for something it did not do. Plan per path, and update every record that
    // points at it.
    const by_path = new Map();
    for (const record of all_records) {
        const existing = by_path.get(record['path']);
        if (existing) existing.uids.push(record['uid']);
        else by_path.set(record['path'], {record, uids: [record['uid']]});
    }
    const files = [...by_path.values()].map(entry => entry.record);

    const {order, by_url, advertised} = await getCurrentPlaylistOrder(sub);
    if (order.size === 0) return refuse(sub.name, {error: `The playlist of ${sub.name} returned no entries - nothing was touched.`});

    // The playlist says how long it is; if the enumeration came back shorter,
    // YouTube cut it off and its order is not the real order. Renaming on that
    // basis would strip the numbering off everything that did not make it into
    // the answer, and put it back on the next run - names flapping back and
    // forth across the whole library.
    if (!force && advertised != null && order.size < advertised) {
        return refuse(sub.name, {
            error: `The playlist claims ${advertised} entries but only ${order.size} came back, so it was read `
                 + `incompletely - probably throttling, or cookies that no longer work. Nothing was changed. `
                 + `Use "force": true to renumber on a partial list anyway.`,
            incomplete: true, playlist_entries: order.size, playlist_claims: advertised,
        });
    }

    // Padding and separator: follow what the existing files use.
    const widths = {}, separators = {};
    for (const file of files) {
        const {width, separator} = splitPrefix(path.parse(file['path']).name);
        if (!width) continue;
        widths[width] = (widths[width] || 0) + 1;
        separators[separator] = (separators[separator] || 0) + 1;
    }
    const highest = Math.max(...order.values());
    const width = Math.max(parseInt(mostCommon(widths, '3'), 10), String(highest).length);
    const separator = mostCommon(separators, ' - ');

    // Build the plan before touching anything.
    const plan = [];
    let kept = 0, gone = 0;
    for (const file of files) {
        const parsed = path.parse(file['path']);
        const {width: has_number, rest} = splitPrefix(parsed.name);
        const position = positionOf(file, order, by_url);
        if (position != null) kept++; else gone++;
        if (only_numbered && !has_number) continue;
        const new_stem = position != null
            ? String(position).padStart(width, '0') + separator + rest
            : rest;
        if (new_stem === parsed.name) continue;
        plan.push({
            uids: by_path.get(file['path']).uids,
            dir: parsed.dir,
            old_stem: parsed.name,
            new_stem: new_stem,
            old_path: file['path'],
            new_path: path.join(parsed.dir, new_stem + parsed.ext),
            in_playlist: position != null,
            position: position != null ? position : null,
        });
    }

    // A truncated enumeration - throttled by YouTube, or cookies gone stale -
    // looks exactly like "everything was removed from the playlist", and would
    // strip the numbering off the whole library. Refuse that unless it is asked
    // for explicitly.
    if (gone > kept && !force) {
        return refuse(sub.name, {
            error: `${gone} of ${files.length} files are not in the playlist any more, more than are still in it. `
                 + `That usually means the playlist was only read partially (throttling, or cookies that no longer work) `
                 + `rather than emptied. Nothing was changed. Re-run with "force": true if the playlist really did shrink that much.`,
            kept, gone, playlist_entries: order.size,
        });
    }

    // Two files ending up on the same name: stop and say which, instead of
    // overwriting one of them. Happens when the template has no [%(id)s] and
    // two videos share a title. A target that is already held by a file this
    // run does not move counts just the same.
    const moving = new Set(plan.map(item => item.old_path));
    const targets = new Map();
    const collisions = [];
    for (const item of plan) {
        const existing = targets.get(item.new_path);
        if (existing) {
            collisions.push({target: item.new_path, from: [existing, item.old_path]});
            continue;
        }
        targets.set(item.new_path, item.old_path);
        if (!moving.has(item.new_path) && await fs.pathExists(item.new_path)) {
            collisions.push({target: item.new_path, from: [item.old_path], note: 'a file that is not part of this run already has that name'});
        }
    }
    if (collisions.length > 0) {
        return refuse(sub.name, {
            error: `${collisions.length} name collision(s) - nothing was changed. Add [%(id)s] to the file output template `
                 + `so identical titles cannot collide.`,
            collisions,
        });
    }

    const summary = {
        success: true,
        subscription: sub.name,
        dry_run,
        files_total: files.length,
        database_records: all_records.length,
        still_in_playlist: kept,
        removed_from_playlist: gone,
        playlist_entries: order.size,
        playlist_claims: advertised,
        renames: plan.length,
        changes: plan.map(item => ({
            from: path.basename(item.old_path),
            to: path.basename(item.new_path),
            position: item.position,
            in_playlist: item.in_playlist,
        })),
    };

    if (dry_run || plan.length === 0) {
        logger.info(`Renumber: ${sub.name} - ${plan.length} file(s) would be renamed (dry run).`);
        return summary;
    }

    // Phase 1: everything out of the way, so a target name that is still held
    // by another file of this subscription cannot block the rename. If this
    // half-finishes, put every file back before returning - a folder full of
    // *.ytm-renumber is worse than a folder with stale numbers.
    const staged = [];
    try {
        for (const item of plan) {
            for (const sibling of await siblingFiles(item.old_path)) {
                const from = path.join(item.dir, sibling);
                const to = from + '.ytm-renumber';
                await fs.move(from, to, {overwrite: false});
                staged.push({to_stage: to, from: from, suffix: sibling.slice(item.old_stem.length), item});
            }
        }
    } catch (e) {
        logger.error(`Renumber: staging failed (${e}) - rolling back.`);
        for (const entry of staged.reverse()) {
            try {
                await fs.move(entry.to_stage, entry.from, {overwrite: false});
            } catch (rollback_error) {
                logger.error(`Renumber: could not put ${entry.to_stage} back: ${rollback_error}`);
            }
        }
        return refuse(sub.name, {error: `Renaming could not be started (${e}) - every file was put back.`});
    }

    // Phase 2: into the new names. A file that cannot be moved goes back to the
    // name it came from, and its database record is left alone.
    const failures = [];
    const failed_uids = new Set();
    for (const entry of staged) {
        const target = path.join(entry.item.dir, entry.item.new_stem + entry.suffix);
        try {
            await fs.move(entry.to_stage, target, {overwrite: false});
        } catch (e) {
            logger.error(`Renumber: could not rename ${entry.from} to ${target}: ${e}`);
            failures.push({file: path.basename(entry.from), error: String(e)});
            failed_uids.add(entry.item.uids[0]);
            try {
                await fs.move(entry.to_stage, entry.from, {overwrite: false});
            } catch (rollback_error) {
                logger.error(`Renumber: could not put ${entry.to_stage} back either: ${rollback_error}`);
            }
        }
    }

    // The database stores the path, so it has to follow the rename.
    for (const item of plan) {
        if (failed_uids.has(item.uids[0])) continue;
        const update = {path: item.new_path};
        const thumbnail = utils.getDownloadedThumbnail(item.new_path);
        if (thumbnail) update['thumbnailPath'] = thumbnail;
        for (const uid of item.uids) await db_api.updateRecord('files', {uid: uid}, update);
    }

    logger.info(`Renumber: ${sub.name} - ${plan.length} file(s) renamed, ${kept} still in the playlist, ${gone} no longer in it.`);
    summary.failures = failures;
    return summary;
};

// Called after every subscription check. Off unless switched on, and it stays
// out of the way whenever the situation is not clearly safe: the completeness
// check above does the deciding, and downloads that are still pending get to
// finish first so nothing is renamed out from under them.
exports.renumberAfterCheck = async (sub) => {
    if (!config_api.getConfigItem('ytdl_subscriptions_renumber_on_check')) return;
    if (!sub || !sub.id || !sub.isPlaylist) return;

    const pending = await db_api.getRecords('download_queue', {sub_id: sub.id, finished: false});
    if (pending && pending.length > 0) {
        logger.verbose(`Renumber: ${sub.name} left alone for now, ${pending.length} download(s) still pending.`);
        return;
    }

    try {
        const result = await exports.renumberSubscription(sub.id, {dry_run: false, only_numbered: true});
        if (result['success']) {
            if (result['renames'] > 0) logger.info(`Renumber: ${sub.name} - ${result['renames']} file(s) renumbered after the check.`);
        } else if (result['incomplete']) {
            logger.info(`Renumber: ${sub.name} skipped - ${result['error']}`);
        } else if (result['collisions']) {
            logger.warn(`Renumber: ${sub.name} skipped - ${result['error']}`);
        } else {
            logger.verbose(`Renumber: ${sub.name} skipped - ${result['error']}`);
        }
    } catch (e) {
        logger.error(`Renumber: ${sub.name} failed after the check: ${e}`);
    }
};
