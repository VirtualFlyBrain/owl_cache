#!/bin/sh
# Warm the local nginx cache from the shared archive, newest entries first,
# while nginx is already serving.
#
# nginx serves a cache file that appears on disk after startup: a lookup that
# misses the shared-memory index still opens the file, validates its header,
# serves it and registers it (verified against nginx 1.26). So there is no
# need to block startup on a copy of the archive -- which at ~1 TB and
# millions of files would take hours. Instead docker-entrypoint.sh starts
# nginx immediately and runs this script in the background. Requests whose
# entry has not landed yet are ordinary misses served by Owlery; once the
# file lands, later requests are hits.
#
# Ordering: the archive is walked once to list every entry with its mtime,
# sorted newest first, and copied in batches. Newest entries are the ones
# most likely to be requested again, and a bounded restore
# (CACHE_RESTORE_MAX_BYTES) keeps the freshest part of the archive.
#
# Merge rule: rsync --update, so an entry that nginx has already fetched fresh
# on this instance is never overwritten by an older archive copy. Re-running
# the script is idempotent; a container restart mid-restore simply resumes.
#
# Environment:
#   CACHE_RESTORE            auto (default) | always | off
#                            auto skips when the local marker from a previous
#                            completed restore exists (persistent local disk).
#   CACHE_ARCHIVE_DIR        /cache
#   CACHE_LOCAL_DIR          /var/cache/nginx
#   CACHE_RESTORE_BWLIMIT    rsync --bwlimit in KiB/s; 0 = unlimited (default)
#   CACHE_RESTORE_BATCH      files per rsync invocation (default 5000)
#   CACHE_RESTORE_MAX_BYTES  stop after this many bytes (0 = whole archive)
#   CACHE_RESTORE_DELAY      seconds to wait before starting (default 0)
#
# Usage: cache-restore.sh            # honours CACHE_RESTORE
#        cache-restore.sh --force    # same as CACHE_RESTORE=always

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

CACHE_RESTORE="${CACHE_RESTORE:-auto}"
CACHE_RESTORE_BWLIMIT="${CACHE_RESTORE_BWLIMIT:-0}"
CACHE_RESTORE_BATCH="${CACHE_RESTORE_BATCH:-5000}"
CACHE_RESTORE_MAX_BYTES="${CACHE_RESTORE_MAX_BYTES:-0}"
CACHE_RESTORE_DELAY="${CACHE_RESTORE_DELAY:-0}"

STATE_FILE="$CACHE_STATE_DIR/cache-restore.json"
MARKER="$CACHE_LOCAL_DIR/.restored"
SRC="$CACHE_ARCHIVE_DIR/$CACHE_SUBDIR"
DST="$CACHE_LOCAL_DIR/$CACHE_SUBDIR"

[ "${1:-}" = "--force" ] && CACHE_RESTORE=always

started="$(date +%s)"
finish() {
    cache_write_state "$STATE_FILE" "$1" "${files_done:-0}" "${bytes_done:-0}" "$started" "$(date +%s)" "$2"
    cache_log "restore: $1 -- $2"
}

case "$(printf '%s' "$CACHE_RESTORE" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no)
        finish skipped "CACHE_RESTORE=off"; exit 0 ;;
    always|1|true|yes|force) ;;
    *)
        if [ -f "$MARKER" ]; then
            finish skipped "local cache already restored ($(cat "$MARKER" 2>/dev/null)); set CACHE_RESTORE=always to repeat"
            exit 0
        fi ;;
esac

if [ ! -d "$SRC" ]; then
    finish skipped "archive $SRC not present"; exit 0
fi
if [ "$(cd "$SRC" && pwd -P)" = "$(mkdir -p "$DST" && cd "$DST" && pwd -P)" ]; then
    finish skipped "archive and local cache are the same directory; nothing to restore"; exit 0
fi

if [ "$CACHE_RESTORE_DELAY" -gt 0 ] 2>/dev/null; then
    sleep "$CACHE_RESTORE_DELAY"
fi

work="$(mktemp -d /tmp/cache-restore.XXXXXX)"
trap 'rm -rf "$work"' EXIT

files_done=0
bytes_done=0
cache_write_state "$STATE_FILE" listing 0 0 "$started" "" "walking archive $SRC"
cache_log "restore: listing $SRC (this walks the whole archive once)"

# One walk of the archive: "<mtime> <size> <relative path>", newest first.
# find -printf needs GNU findutils (installed in the image); BusyBox find
# has no -printf and would need one stat(2) per file on top of the walk.
find "$SRC" -type f -printf '%T@ %s %P\n' 2>/dev/null \
    | awk '{ path=$3; for (i=4; i<=NF; i++) path=path " " $i; print $1, $2, path }' \
    | sort -k1,1nr > "$work/all.lst"

# Keep only real cache entries and apply the optional byte bound.
awk -v max="$CACHE_RESTORE_MAX_BYTES" '
    { path=$3; for (i=4; i<=NF; i++) path=path " " $i }
    path ~ /^([0-9a-f]\/[0-9a-f][0-9a-f]\/)?[0-9a-f]{32}$/ {
        if (max > 0 && total + $2 > max) exit
        total += $2; print $2, path
    }' "$work/all.lst" > "$work/entries.lst"

total_files="$(wc -l < "$work/entries.lst" | tr -d ' ')"
total_bytes="$(awk '{ s += $1 } END { print s + 0 }' "$work/entries.lst")"
cache_log "restore: $total_files entries ($total_bytes bytes) to consider, newest first, batches of $CACHE_RESTORE_BATCH"
cache_write_state "$STATE_FILE" running 0 0 "$started" "" "0/$total_files files"

if [ "$total_files" -eq 0 ]; then
    finish "done" "archive is empty"; printf '%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ") 0 files" > "$MARKER"; exit 0
fi

mkdir -p "$DST"
# Batch files in listing order (awk rather than split: BusyBox builds differ
# in whether split is present, and this keeps the newest-first order).
awk -v n="$CACHE_RESTORE_BATCH" -v dir="$work" '{
    f = sprintf("%s/batch.%08d", dir, int((NR - 1) / n)); print > f
    if (NR % n == 0) close(f)
}' "$work/entries.lst"

# rsync partials go here, outside the tree nginx's cache loader walks.
TMPDIR_RSYNC="$CACHE_LOCAL_DIR/.rsync-tmp"
retry=""
for batch in "$work"/batch.*; do
    [ -f "$batch" ] || continue
    cut -d' ' -f2- "$batch" > "$batch.paths"
    n="$(wc -l < "$batch" | tr -d ' ')"
    if ! cache_rsync_batch "$SRC" "$DST" "$batch.paths" "$CACHE_RESTORE_BWLIMIT" "$TMPDIR_RSYNC"; then
        # Entries evicted from the archive between listing and copy show up as
        # vanished files (rsync exit 24); anything else is worth surfacing but
        # must not abandon the remaining batches. Failed batches get one more
        # pass at the end (--update makes the repeat cheap).
        cache_log "restore: rsync reported errors on batch $(basename "$batch"); will retry once"
        retry="$retry $batch.paths"
    else
        rm -f "$batch.paths"
    fi
    files_done=$(( files_done + n ))
    # Bytes are accounted from the listing, not from rsync, so this is the
    # size of the entries considered so far (already-current files included).
    bytes_done=$(( bytes_done + $(awk '{ s += $1 } END { print s + 0 }' "$batch") ))
    rm -f "$batch"
    cache_write_state "$STATE_FILE" running "$files_done" "$bytes_done" "$started" "" "$files_done/$total_files files"
done

failed=0
for paths in $retry; do
    cache_write_state "$STATE_FILE" running "$files_done" "$bytes_done" "$started" "" "retrying $(basename "$paths" .paths)"
    if ! cache_rsync_batch "$SRC" "$DST" "$paths" "$CACHE_RESTORE_BWLIMIT" "$TMPDIR_RSYNC"; then
        failed=$(( failed + 1 ))
        cache_log "restore: batch $(basename "$paths" .paths) still reported errors on retry"
    fi
done

printf '%s %s files\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$files_done" > "$MARKER"
if [ "$failed" -gt 0 ]; then
    finish "done" "$files_done/$total_files entries synchronised from $SRC ($failed batches reported errors after retry; run cache-restore.sh --force to repeat)"
else
    finish "done" "$files_done/$total_files entries synchronised from $SRC"
fi
