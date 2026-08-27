#!/bin/sh
# Stash the local nginx cache into the shared archive.
#
# Only entries written since the previous backup are considered. The list is
# built from the LOCAL disk (`find -newer <marker>`), which is cheap; the
# archive on NFS is never walked, only written to. rsync --update then copies
# each entry unless the archive already holds a newer copy, so several
# instances backing up into the same archive produce a union in which the
# newest version of every entry wins. Nothing is ever deleted from the
# archive; use purge-cached-404s.sh --archive to remove poisoned entries.
#
# Scheduled by docker-entrypoint.sh through crond (see CACHE_BACKUP_SCHEDULE)
# and runnable by hand:
#   docker exec owlery-cache cache-backup.sh          # incremental
#   docker exec owlery-cache cache-backup.sh --full   # ignore the marker
#
# Environment:
#   CACHE_ARCHIVE_DIR          /cache
#   CACHE_LOCAL_DIR            /var/cache/nginx
#   CACHE_BACKUP_BWLIMIT       rsync --bwlimit in KiB/s; 0 = unlimited
#   CACHE_BACKUP_BATCH         files per rsync invocation (default 5000)
#   CACHE_BACKUP_LOCK_WAIT     minutes to wait for another instance's backup
#                              to finish before giving up (default 120)
#   CACHE_LOCK_STALE_MINUTES   lock older than this is taken over (default 360)

set -eu

# Run as the nginx user, never root: the archive is NFS and typically
# root-squashed, and every file we create must be owned by the user nginx
# runs as. CACHE_RUN_AS="" keeps the current user (tests).
CACHE_RUN_AS="${CACHE_RUN_AS-nginx}"
if [ -n "$CACHE_RUN_AS" ] && [ "$(id -u)" = "0" ] && command -v su-exec >/dev/null 2>&1; then
    exec su-exec "$CACHE_RUN_AS" "$0" "$@"
fi

CACHE_LIB="${CACHE_LIB:-/usr/local/bin/cache-lib.sh}"
# shellcheck source=cache-lib.sh
. "$CACHE_LIB"

CACHE_BACKUP_BWLIMIT="${CACHE_BACKUP_BWLIMIT:-0}"
CACHE_BACKUP_BATCH="${CACHE_BACKUP_BATCH:-5000}"
CACHE_BACKUP_LOCK_WAIT="${CACHE_BACKUP_LOCK_WAIT:-120}"

STATE_FILE="$CACHE_STATE_DIR/cache-backup.json"
MARKER="$CACHE_LOCAL_DIR/.last-backup"
SRC="$CACHE_LOCAL_DIR/$CACHE_SUBDIR"
DST="$CACHE_ARCHIVE_DIR/$CACHE_SUBDIR"

full=0
[ "${1:-}" = "--full" ] && full=1

started="$(date +%s)"
files_done=0
bytes_done=0
finish() {
    cache_write_state "$STATE_FILE" "$1" "$files_done" "$bytes_done" "$started" "$(date +%s)" "$2"
    cache_log "backup: $1 -- $2"
    cache_signal_status_refresh
}

if [ ! -d "$CACHE_ARCHIVE_DIR" ]; then
    finish skipped "archive $CACHE_ARCHIVE_DIR not mounted"; exit 0
fi
if [ ! -d "$SRC" ]; then
    finish skipped "local cache $SRC does not exist yet"; exit 0
fi
if [ "$(cd "$SRC" && pwd -P)" = "$(mkdir -p "$DST" && cd "$DST" && pwd -P)" ]; then
    finish skipped "archive and local cache are the same directory; nothing to back up"; exit 0
fi

work="$(mktemp -d /tmp/cache-backup.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# Stamp the new marker before listing, so entries written while the backup
# runs are picked up next time rather than falling between two runs.
new_marker="$work/marker"
# Back-dated a couple of seconds: find -newer is a strict comparison, and a
# file written in the same second as the marker would otherwise be skipped.
touch -t "$(date -d "@$(( started - 2 ))" +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$new_marker"

if [ "$full" -eq 1 ] || [ ! -f "$MARKER" ]; then
    find "$SRC" -type f -printf '%s %P\n'
else
    find "$SRC" -type f -newer "$MARKER" -printf '%s %P\n'
fi 2>/dev/null | awk '
    { path=$2; for (i=3; i<=NF; i++) path=path " " $i }
    path ~ /^([0-9a-f]\/[0-9a-f][0-9a-f]\/)?[0-9a-f]{32}$/ { print $1, path }
' > "$work/entries.lst"

total_files="$(wc -l < "$work/entries.lst" | tr -d ' ')"
total_bytes="$(awk '{ s += $1 } END { print s + 0 }' "$work/entries.lst")"

if [ "$total_files" -eq 0 ]; then
    cp -p "$new_marker" "$MARKER"
    finish "done" "nothing new since last backup"; exit 0
fi

cache_log "backup: $total_files entries ($total_bytes bytes) changed since last backup; waiting for archive lock"
cache_write_state "$STATE_FILE" waiting 0 0 "$started" "" "waiting for lock ($total_files files pending)"
cache_signal_status_refresh

if ! cache_lock_acquire "$CACHE_BACKUP_LOCK_WAIT"; then
    finish skipped "another instance held the archive lock for more than ${CACHE_BACKUP_LOCK_WAIT} min; will retry next run"
    exit 0
fi
trap 'cache_lock_release; rm -rf "$work"' EXIT

cache_write_state "$STATE_FILE" running 0 0 "$started" "" "0/$total_files files"
cache_signal_status_refresh
mkdir -p "$DST"
# Batch files in listing order (awk rather than split: BusyBox builds differ
# in whether split is present, and this keeps the newest-first order).
awk -v n="$CACHE_BACKUP_BATCH" -v dir="$work" '{
    f = sprintf("%s/batch.%08d", dir, int((NR - 1) / n)); print > f
    if (NR % n == 0) close(f)
}' "$work/entries.lst"
errors=0
for batch in "$work"/batch.*; do
    [ -f "$batch" ] || continue
    cut -d' ' -f2- "$batch" > "$batch.paths"
    n="$(wc -l < "$batch" | tr -d ' ')"
    if ! cache_rsync_batch "$SRC" "$DST" "$batch.paths" "$CACHE_BACKUP_BWLIMIT" "$CACHE_ARCHIVE_DIR/.rsync-tmp"; then
        # Exit 24 (vanished source file) is normal: the cache manager evicts
        # entries under max_size while we run. Anything else is counted.
        errors=$(( errors + 1 ))
        cache_log "backup: rsync reported errors on batch $(basename "$batch"); continuing"
    fi
    files_done=$(( files_done + n ))
    bytes_done=$(( bytes_done + $(awk '{ s += $1 } END { print s + 0 }' "$batch") ))
    rm -f "$batch" "$batch.paths"
    cache_write_state "$STATE_FILE" running "$files_done" "$bytes_done" "$started" "" "$files_done/$total_files files"
    cache_signal_status_refresh
done

cp -p "$new_marker" "$MARKER"
if [ "$errors" -gt 0 ]; then
    finish "done" "$files_done entries synchronised to $DST ($errors batches reported rsync errors)"
else
    finish "done" "$files_done entries synchronised to $DST"
fi
