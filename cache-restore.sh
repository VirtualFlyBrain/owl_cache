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
#   CACHE_RESTORE_JOBS       concurrent rsync workers (default 8). Copy time is
#                            dominated by per-file NFS round trips, so workers
#                            overlap almost perfectly.
#   CACHE_RESTORE_BLOCKING_MAX_BYTES
#                            the READY file is written once this many bytes
#                            of the newest entries have landed (0 = only when
#                            everything has). docker-entrypoint.sh waits for
#                            that file before starting nginx in blocking and
#                            hybrid modes. Accepts k/m/g/t suffixes.
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
CACHE_RESTORE_MAX_BYTES="$(cache_parse_size "${CACHE_RESTORE_MAX_BYTES:-0}")"
CACHE_RESTORE_JOBS="${CACHE_RESTORE_JOBS:-8}"
CACHE_RESTORE_BLOCKING_MAX_BYTES="$(cache_parse_size "${CACHE_RESTORE_BLOCKING_MAX_BYTES:-0}")"
CACHE_RESTORE_DELAY="${CACHE_RESTORE_DELAY:-0}"
case "$CACHE_RESTORE_JOBS" in ''|*[!0-9]*|0) CACHE_RESTORE_JOBS=1 ;; esac

STATE_FILE="$CACHE_STATE_DIR/cache-restore.json"
# Written when the blocking portion has landed; the entrypoint waits for it.
READY_FILE="$CACHE_STATE_DIR/cache-restore.ready"
MARKER="$CACHE_LOCAL_DIR/.restored"
SRC="$CACHE_ARCHIVE_DIR/$CACHE_SUBDIR"
DST="$CACHE_LOCAL_DIR/$CACHE_SUBDIR"

[ "${1:-}" = "--force" ] && CACHE_RESTORE=always

started="$(date +%s)"
mkdir -p "$CACHE_STATE_DIR"
rm -f "$READY_FILE"
mark_ready() {
    [ -f "$READY_FILE" ] && return
    printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" > "$READY_FILE"
    cache_log "restore: ready -- $1"
}
finish() {
    cache_write_state "$STATE_FILE" "$1" "${files_done:-0}" "${bytes_done:-0}" "$started" "$(date +%s)" "$2"
    cache_log "restore: $1 -- $2"
    # Whatever happened, never leave the entrypoint waiting.
    mark_ready "$1: $2"
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
# The walk is NFS-latency bound, so the sixteen levels=1 top directories are
# walked concurrently (files at the root, if any, in a seventeenth).
mkdir -p "$work/list"
i=0
for top in "$SRC"/*/; do
    [ -d "$top" ] || continue
    rel="${top#"$SRC"/}"; rel="${rel%/}"
    ( cd "$SRC" && find "$rel" -type f -printf '%T@ %s %p\n' ) > "$work/list/$i" 2>/dev/null &
    i=$(( i + 1 ))
done
( cd "$SRC" && find . -maxdepth 1 -type f -printf '%T@ %s %P\n' ) > "$work/list/root" 2>/dev/null &
wait
cat "$work/list"/* \
    | awk '{ path=$3; for (i=4; i<=NF; i++) path=path " " $i; print $1, $2, path }' \
    | sort -k1,1nr > "$work/all.lst"
rm -rf "$work/list"

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

# Where in the newest-first list the blocking portion ends: the first batch
# index whose cumulative bytes exceed CACHE_RESTORE_BLOCKING_MAX_BYTES.
# 0 means "all of it" (ready only when the whole restore is complete).
ready_after_batch=-1
if [ "$CACHE_RESTORE_BLOCKING_MAX_BYTES" -gt 0 ]; then
    ready_after_batch="$(awk -v n="$CACHE_RESTORE_BATCH" -v max="$CACHE_RESTORE_BLOCKING_MAX_BYTES" '
        { total += $1; if (total >= max) { print int((NR - 1) / n); exit } }
        END { if (total < max) print int((NR - 1) / n) }' "$work/entries.lst")"
fi

# Worker w takes batches w, w+J, w+2J, ... so every worker starts near the
# top of the newest-first list. Each appends "<files> <bytes>" per finished
# batch to its progress file and lists failed batches for the retry pass.
worker() {
    w="$1"; k=0
    for batch in "$work"/batch.*; do
        case "$batch" in *.paths|*.failed) continue ;; esac
        [ -f "$batch" ] || continue
        if [ $(( k % CACHE_RESTORE_JOBS )) -eq "$w" ]; then
            cut -d' ' -f2- "$batch" > "$batch.paths"
            n="$(wc -l < "$batch" | tr -d ' ')"
            b="$(awk '{ s += $1 } END { print s + 0 }' "$batch")"
            if cache_rsync_batch "$SRC" "$DST" "$batch.paths" "$CACHE_RESTORE_BWLIMIT" "$TMPDIR_RSYNC"; then
                rm -f "$batch.paths"
            else
                # Vanished files (exit 24, archive evicted between listing and
                # copy) or anything else: retried once at the end.
                cache_log "restore: rsync reported errors on batch $(basename "$batch"); will retry once"
                printf '%s\n' "$batch.paths" >> "$work/failed.$w"
            fi
            printf '%s %s %s\n' "$n" "$b" "$k" >> "$work/progress.$w"
        fi
        k=$(( k + 1 ))
    done
    : > "$work/worker.$w.done"
}

w=0
while [ "$w" -lt "$CACHE_RESTORE_JOBS" ]; do
    worker "$w" &
    w=$(( w + 1 ))
done

# Monitor: fold progress files into /status until every worker is done.
update_progress() {
    set -- $(cat "$work"/progress.* 2>/dev/null | awk '{ f += $1; b += $2 } END { print f + 0, b + 0 }')
    files_done="$1"; bytes_done="$2"
    cache_write_state "$STATE_FILE" running "$files_done" "$bytes_done" "$started" "" "$files_done/$total_files files, $CACHE_RESTORE_JOBS workers"
    if [ "$ready_after_batch" -ge 0 ] && [ ! -f "$READY_FILE" ]; then
        # Ready once every batch up to ready_after_batch has been processed.
        done_upto="$(cat "$work"/progress.* 2>/dev/null | awk -v want="$ready_after_batch" '
            $3 <= want { c++ } END { print c + 0 }')"
        if [ "$done_upto" -ge $(( ready_after_batch + 1 )) ]; then
            mark_ready "newest $bytes_done bytes ($files_done files) landed; remaining $(( total_files - files_done )) continue in the background"
        fi
    fi
}
while [ "$(ls "$work"/worker.*.done 2>/dev/null | wc -l | tr -d ' ')" -lt "$CACHE_RESTORE_JOBS" ]; do
    sleep 5
    update_progress
done
wait
update_progress

failed=0
for paths in $(cat "$work"/failed.* 2>/dev/null); do
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
