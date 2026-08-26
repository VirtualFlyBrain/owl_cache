#!/bin/sh
# Shared helpers for cache-restore.sh and cache-backup.sh.
#
# The archive (`/cache`, an NFS volume shared by every instance) and the local
# cache (`/var/cache/nginx`, node disk that nginx actually serves from) are
# synchronised in both directions with the same rule: a file only moves if it
# is newer than the copy at the destination (`rsync --update`). nginx names
# each entry by the MD5 of its cache key and replaces entries atomically, so
# the union of several instances' caches is itself a valid cache and "newest
# wins" is the only merge rule needed. Nothing here ever deletes.
#
# POSIX sh only: the runtime image is BusyBox ash.

CACHE_ARCHIVE_DIR="${CACHE_ARCHIVE_DIR:-/cache}"
CACHE_LOCAL_DIR="${CACHE_LOCAL_DIR:-/var/cache/nginx}"
# Subdirectory (under both roots) that holds the nginx cache tree.
CACHE_SUBDIR="${CACHE_SUBDIR:-owlery}"
CACHE_STATE_DIR="${CACHE_STATE_DIR:-/var/run/nginx}"
# rsync --modify-window: NFS and local filesystems can disagree by a second
# on mtime; without this a byte-identical file would be recopied every run.
CACHE_MODIFY_WINDOW="${CACHE_MODIFY_WINDOW:-2}"
# Lock directory on the archive so concurrent instances serialise their
# backups. flock(2) is unreliable on NFS; mkdir(2) is atomic there.
CACHE_LOCK_DIR="${CACHE_LOCK_DIR:-$CACHE_ARCHIVE_DIR/.owl-cache-backup.lock}"
CACHE_LOCK_STALE_MINUTES="${CACHE_LOCK_STALE_MINUTES:-360}"

cache_log() {
    printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

cache_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Is the argument a real nginx cache entry path (relative to the tree root)?
# Entries are <32 hex>, optionally under levels=1:2 directories. Anything
# else in the tree is an in-flight temp file or an rsync partial and must not
# be copied: a half-written body would be served as a truncated response.
cache_entry_filter() {
    grep -E '^([0-9a-f]/[0-9a-f]{2}/)?[0-9a-f]{32}$'
}

# Deterministic per-instance offset in [0, N) minutes derived from the
# hostname (the container id under Rancher/Docker), so several replicas of
# one service, which all receive the same environment, do not fire at the
# same minute. A restarted container keeps its slot.
cache_jitter_minutes() {
    span="${1:-0}"
    case "$span" in
        ''|*[!0-9]*) span=0 ;;
    esac
    [ "$span" -le 0 ] && { printf '0'; return; }
    sum="$(hostname 2>/dev/null | cksum | cut -d' ' -f1)"
    [ -z "$sum" ] && sum=0
    printf '%s' "$(( sum % span ))"
}

# Turn CACHE_BACKUP_SCHEDULE / CACHE_BACKUP_TIME / CACHE_BACKUP_WEEKDAY /
# CACHE_BACKUP_JITTER_MINUTES (or a verbatim CACHE_BACKUP_CRON) into one
# 5-field crontab spec on stdout, or nothing when backups are off.
cache_backup_cron_spec() {
    if [ -n "${CACHE_BACKUP_CRON:-}" ]; then
        printf '%s' "$CACHE_BACKUP_CRON"
        return
    fi
    case "$(printf '%s' "${CACHE_BACKUP_SCHEDULE:-daily}" | tr '[:upper:]' '[:lower:]')" in
        off|0|false|no|manual|none) return ;;
        weekly) dow="${CACHE_BACKUP_WEEKDAY:-0}" ;;
        *) dow='*' ;;
    esac
    case "$dow" in
        '*') ;;
        ''|*[!0-9]*) dow=0 ;;
        *) dow=$(( dow % 7 )) ;;
    esac
    time="${CACHE_BACKUP_TIME:-03:00}"
    hour="${time%%:*}"
    minute="${time#*:}"
    case "$hour$minute" in
        ''|*[!0-9]*) hour=3; minute=0 ;;
    esac
    # Strip leading zeros so "08" is not read as octal.
    hour=$(( $(printf '%s' "$hour" | sed 's/^0*//; s/^$/0/') ))
    minute=$(( $(printf '%s' "$minute" | sed 's/^0*//; s/^$/0/') ))
    total=$(( hour * 60 + minute + $(cache_jitter_minutes "${CACHE_BACKUP_JITTER_MINUTES:-0}") ))
    if [ "$total" -ge 1440 ]; then
        total=$(( total - 1440 ))
        # Jitter pushed the slot past midnight: shift the weekday along too.
        [ "$dow" != '*' ] && dow=$(( (dow + 1) % 7 ))
    fi
    printf '%s %s * * %s' "$(( total % 60 ))" "$(( total / 60 ))" "$dow"
}

# Write a small JSON state file atomically; health-monitor.sh embeds it in
# /status. Arguments: <file> <state> <files> <bytes> <started_epoch>
# <finished_epoch|""> <message>
cache_write_state() {
    file="$1"; state="$2"; files="$3"; bytes="$4"; started="$5"; finished="$6"; message="$7"
    mkdir -p "$(dirname "$file")"
    now="$(date +%s)"
    if [ -n "$finished" ]; then
        elapsed=$(( finished - started ))
        finished_json="\"$(date -u -d "@$finished" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")\""
    else
        elapsed=$(( now - started ))
        finished_json=null
    fi
    started_iso="$(date -u -d "@$started" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "$file.tmp" <<EOF
{
  "state": "$state",
  "host": "$(cache_json_escape "$(hostname 2>/dev/null || echo unknown)")",
  "files": $files,
  "bytes": $bytes,
  "started_at": "$started_iso",
  "finished_at": $finished_json,
  "elapsed_seconds": $elapsed,
  "message": "$(cache_json_escape "$message")"
}
EOF
    mv "$file.tmp" "$file"
}

# Acquire the archive lock. Returns 0 when held, 1 when it could not be
# obtained within <wait_minutes>. A lock older than CACHE_LOCK_STALE_MINUTES
# is treated as abandoned (a container killed mid-backup) and taken over.
cache_lock_acquire() {
    wait_minutes="${1:-0}"
    deadline=$(( $(date +%s) + wait_minutes * 60 ))
    while :; do
        if mkdir "$CACHE_LOCK_DIR" 2>/dev/null; then
            printf '%s %s\n' "$(hostname 2>/dev/null)" "$(date +%s)" > "$CACHE_LOCK_DIR/owner" 2>/dev/null || true
            return 0
        fi
        lock_epoch="$(stat -c %Y "$CACHE_LOCK_DIR" 2>/dev/null || echo 0)"
        age_minutes=$(( ( $(date +%s) - lock_epoch ) / 60 ))
        if [ "$age_minutes" -ge "$CACHE_LOCK_STALE_MINUTES" ]; then
            cache_log "backup lock at $CACHE_LOCK_DIR is ${age_minutes} min old (stale after ${CACHE_LOCK_STALE_MINUTES}); taking it over"
            rm -rf "$CACHE_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            return 1
        fi
        sleep 60
    done
}

cache_lock_release() {
    rm -rf "$CACHE_LOCK_DIR" 2>/dev/null || true
}

# Run rsync over a batch file of relative paths from <src> to <dst>.
# Whole-file copies (no delta computation: entries are immutable blobs),
# newest wins, never delete, atomic per file via rsync's temp+rename.
cache_rsync_batch() {
    src="$1"; dst="$2"; list="$3"; bwlimit="${4:-0}"
    # --files-from implies --relative, so `a/bc/<hash>` lands at the same
    # levels path under <dst> and the intermediate directories are created.
    set -- -a --whole-file --update --modify-window="$CACHE_MODIFY_WINDOW" \
        --files-from="$list" --quiet
    if [ "$bwlimit" != "0" ] && [ -n "$bwlimit" ]; then
        set -- "$@" --bwlimit="$bwlimit"
    fi
    rsync "$@" "$src/" "$dst/"
}
