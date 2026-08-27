#!/bin/sh
# Tests for cache-lib.sh, cache-restore.sh and cache-backup.sh on a fake
# cache tree. Run directly (`sh test/cache-sync-test.sh`) or let the Docker
# build run it. Needs rsync and GNU find (-printf), as the image does.
#
# POSIX sh only, to match BusyBox ash in the runtime image.

set -eu

here="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_LIB="${CACHE_LIB:-$here/cache-lib.sh}"
CACHE_RESTORE_SCRIPT="${CACHE_RESTORE_SCRIPT:-$here/cache-restore.sh}"
CACHE_BACKUP_SCRIPT="${CACHE_BACKUP_SCRIPT:-$here/cache-backup.sh}"
export CACHE_LIB

WORK="$(mktemp -d /tmp/cache-sync-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CACHE_ARCHIVE_DIR="$WORK/archive"
export CACHE_LOCAL_DIR="$WORK/local"
export CACHE_STATE_DIR="$WORK/state"
export CACHE_LOCK_DIR="$WORK/archive/.lock"
export CACHE_RESTORE_BATCH=2
export CACHE_BACKUP_BATCH=2
export CACHE_BACKUP_LOCK_WAIT=0
export CACHE_RESTORE_JOBS=3
export CACHE_RUN_AS=
ARCHIVE="$CACHE_ARCHIVE_DIR/owlery"
LOCAL="$CACHE_LOCAL_DIR/owlery"

failures=0
checks=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else fail "$1 (missing $2)"; fi; }
assert_no_file() { if [ ! -e "$2" ]; then ok "$1"; else fail "$1 (unexpected $2)"; fi; }

# entry <root> <hash> <content> <age-seconds>
entry() {
    d="$1/${2%"${2#?}"}/$(printf '%s' "$2" | cut -c2-3)"
    mkdir -p "$d"
    printf 'KEY: %s\nHTTP/1.1 200 OK\n\n%s\n' "$2" "$3" > "$d/$2"
    touch -d "@$(( $(date +%s) - $4 ))" "$d/$2"
}
h() { printf '%032d' "$1"; }

# shellcheck source=../cache-lib.sh disable=SC1090
. "$CACHE_LIB"

echo "cache_entry_filter"
assert_eq "accepts levels path" "$(printf '%s\n' "a/bc/$(h 1)" | cache_entry_filter)" "a/bc/$(h 1)"
assert_eq "accepts flat entry" "$(printf '%s\n' "$(h 2)" | cache_entry_filter)" "$(h 2)"
assert_eq "rejects nginx temp file" "$(printf '%s\n' "a/bc/$(h 3).0000000012" | cache_entry_filter)" ""
assert_eq "rejects rsync partial" "$(printf '%s\n' "a/bc/.$(h 3).Xk3Zq" | cache_entry_filter)" ""
assert_eq "rejects markers" "$(printf '.restored\n.last-backup\n' | cache_entry_filter)" ""

echo "cache_jitter_minutes"
j1="$(cache_jitter_minutes 120)"; j2="$(cache_jitter_minutes 120)"
assert_eq "deterministic for this host" "$j1" "$j2"
[ "$j1" -ge 0 ] && [ "$j1" -lt 120 ] && ok "within [0,120)" || fail "jitter $j1 out of range"
assert_eq "zero span gives zero" "$(cache_jitter_minutes 0)" "0"
assert_eq "garbage span gives zero" "$(cache_jitter_minutes abc)" "0"

echo "cache_signal_status_refresh"
# A first version of this used `kill -USR1` at a pid health-monitor.sh
# recorded, woken by `trap ... USR1` in its main loop. That does not work: in
# ash/dash a pending trap is not run until the current `sleep` call returns
# on its own, so the signal just sat queued for the rest of the poll
# interval -- no better than not sending it (confirmed against production:
# CI stayed red with the identical stale snapshot after that fix "landed").
# Replaced with a flag file health-monitor.sh polls on a 1s tick, which has
# no such gotcha and works regardless of which user creates it.
rm -rf "$CACHE_STATE_DIR"
assert_eq "always succeeds, even before CACHE_STATE_DIR exists" "$(cache_signal_status_refresh; echo $?)" "0"
assert_file "creates CACHE_STATE_DIR and the dirty file" "$CACHE_STATE_DIR/.status-dirty"
rm -f "$CACHE_STATE_DIR/.status-dirty"

echo "cache_backup_cron_spec"
spec="$(CACHE_BACKUP_SCHEDULE=daily CACHE_BACKUP_TIME=03:00 CACHE_BACKUP_JITTER_MINUTES=0 cache_backup_cron_spec)"
assert_eq "daily 03:00 no jitter" "$spec" "0 3 * * *"
spec="$(CACHE_BACKUP_SCHEDULE=weekly CACHE_BACKUP_WEEKDAY=6 CACHE_BACKUP_TIME=23:30 CACHE_BACKUP_JITTER_MINUTES=0 cache_backup_cron_spec)"
assert_eq "weekly Saturday 23:30" "$spec" "30 23 * * 6"
spec="$(CACHE_BACKUP_SCHEDULE=daily CACHE_BACKUP_TIME=08:05 CACHE_BACKUP_JITTER_MINUTES=0 cache_backup_cron_spec)"
assert_eq "leading zeros are not octal" "$spec" "5 8 * * *"
spec="$(CACHE_BACKUP_SCHEDULE=off cache_backup_cron_spec)"
assert_eq "off yields empty" "$spec" ""
spec="$(CACHE_BACKUP_CRON='15 4 * * 2' CACHE_BACKUP_SCHEDULE=daily cache_backup_cron_spec)"
assert_eq "verbatim cron override" "$spec" "15 4 * * 2"
spec="$(CACHE_BACKUP_SCHEDULE=daily CACHE_BACKUP_TIME=03:00 CACHE_BACKUP_JITTER_MINUTES=120 cache_backup_cron_spec)"
m="${spec%% *}"; rest="${spec#* }"; hh="${rest%% *}"
total=$(( hh * 60 + m ))
[ "$total" -ge 180 ] && [ "$total" -lt 300 ] && ok "jittered slot lands in 03:00-04:59 ($spec)" || fail "jittered slot $spec outside window"
# Force the wrap: jitter fixed by hostname, so pick a base time near midnight.
spec="$(CACHE_BACKUP_SCHEDULE=weekly CACHE_BACKUP_WEEKDAY=6 CACHE_BACKUP_TIME=23:59 CACHE_BACKUP_JITTER_MINUTES=120 cache_backup_cron_spec)"
case "$spec" in
    *" * * 6") [ "$j1" -eq 0 ] && ok "no wrap when jitter is 0" || fail "expected wrap to Sunday, got '$spec'" ;;
    *" * * 0") ok "wrap past midnight moves weekday to Sunday ($spec)" ;;
    *) fail "unexpected spec '$spec'" ;;
esac

echo "cache-restore.sh"
entry "$ARCHIVE" "$(h 1)" "old-archive" 3600
entry "$ARCHIVE" "$(h 2)" "archive" 60
entry "$ARCHIVE" "$(h 3)" "archive" 10
entry "$ARCHIVE" "$(h 4)" "archive" 5
mkdir -p "$ARCHIVE/a/bc"; printf 'partial' > "$ARCHIVE/a/bc/$(h 9).0000000042"
# Local already holds a fresher copy of entry 1 (nginx fetched it after the archive did).
entry "$LOCAL" "$(h 1)" "fresh-local" 0
sh "$CACHE_RESTORE_SCRIPT" > "$WORK/restore.log" 2>&1 || fail "restore exited non-zero: $(cat "$WORK/restore.log")"
assert_file "restores entry 2" "$LOCAL/0/00/$(h 2)"
assert_file "restores entry 4" "$LOCAL/0/00/$(h 4)"
assert_eq "--update keeps the newer local entry 1" "$(tail -n 1 "$LOCAL/0/00/$(h 1)")" "fresh-local"
assert_no_file "temp file is not restored" "$LOCAL/a/bc/$(h 9).0000000042"
assert_file "marker written" "$CACHE_LOCAL_DIR/.restored"
[ -d "$CACHE_LOCAL_DIR/.rsync-tmp" ] && ok "rsync temp dir is outside the cache tree" || fail "rsync temp dir missing"
assert_eq "no rsync partials left in the tree" "$(find "$LOCAL" -name '.*' -type f | wc -l | tr -d ' ')" "0"
assert_eq "state is done" "$(sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' "$CACHE_STATE_DIR/cache-restore.json")" "done"
assert_eq "state counts 4 entries" "$(sed -n 's/.*"files": \([0-9]*\).*/\1/p' "$CACHE_STATE_DIR/cache-restore.json")" "4"
grep -q "4 entries" "$WORK/restore.log" && ok "log reports entries" || fail "log: $(cat "$WORK/restore.log")"

entry "$ARCHIVE" "$(h 5)" "later" 1
sh "$CACHE_RESTORE_SCRIPT" > "$WORK/restore2.log" 2>&1
assert_no_file "auto mode skips when marker exists" "$LOCAL/0/00/$(h 5)"
assert_eq "skipped state" "$(sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' "$CACHE_STATE_DIR/cache-restore.json")" "skipped"
sh "$CACHE_RESTORE_SCRIPT" --force > "$WORK/restore3.log" 2>&1
assert_file "--force restores again" "$LOCAL/0/00/$(h 5)"

rm -rf "$LOCAL" "$CACHE_LOCAL_DIR/.restored"
CACHE_RESTORE_MAX_BYTES=$(( $(stat -c %s "$ARCHIVE/0/00/$(h 5)") + $(stat -c %s "$ARCHIVE/0/00/$(h 4)") + 1 )) sh "$CACHE_RESTORE_SCRIPT" > "$WORK/restore4.log" 2>&1
assert_file "bounded restore takes newest (5)" "$LOCAL/0/00/$(h 5)"
assert_file "bounded restore takes next newest (4)" "$LOCAL/0/00/$(h 4)"
assert_no_file "bounded restore stops before older entries (2)" "$LOCAL/0/00/$(h 2)"

grep -q "newest" "$CACHE_STATE_DIR/cache-restore.ready" && fail "ready file should not claim a partial restore when unbounded" || ok "unbounded restore is ready only at the end"

rm -rf "$LOCAL" "$CACHE_LOCAL_DIR/.restored"
CACHE_RESTORE_JOBS=1 CACHE_RESTORE_BLOCKING_MAX_BYTES=1 sh "$CACHE_RESTORE_SCRIPT" > "$WORK/restore5.log" 2>&1
grep -q "restore: ready -- newest" "$WORK/restore5.log" && ok "hybrid: ready after the first batch" || fail "hybrid ready: $(cat "$WORK/restore5.log")"
assert_file "hybrid: ready file written" "$CACHE_STATE_DIR/cache-restore.ready"
assert_file "hybrid: restore still completes (oldest entry 1)" "$LOCAL/0/00/$(h 1)"
assert_eq "size suffix parsing" "$(cache_parse_size 2g) $(cache_parse_size 500m) $(cache_parse_size 7) $(cache_parse_size junk)" "2147483648 524288000 7 0"

CACHE_RESTORE=off sh "$CACHE_RESTORE_SCRIPT" > /dev/null 2>&1
assert_eq "CACHE_RESTORE=off skips" "$(sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' "$CACHE_STATE_DIR/cache-restore.json")" "skipped"

echo "cache-backup.sh"
rm -rf "$CACHE_ARCHIVE_DIR" "$CACHE_LOCAL_DIR"
entry "$LOCAL" "$(h 1)" "local-new" 0
entry "$LOCAL" "$(h 2)" "local-old" 3600
entry "$ARCHIVE" "$(h 2)" "archive-newer" 60
mkdir -p "$LOCAL/0/00"; printf 'partial' > "$LOCAL/0/00/$(h 7).0000000001"
sh "$CACHE_BACKUP_SCRIPT" > "$WORK/backup.log" 2>&1 || fail "backup exited non-zero: $(cat "$WORK/backup.log")"
assert_file "new local entry reaches archive" "$ARCHIVE/0/00/$(h 1)"
assert_eq "--update keeps newer archive copy of 2" "$(tail -n 1 "$ARCHIVE/0/00/$(h 2)")" "archive-newer"
assert_no_file "temp file is not backed up" "$ARCHIVE/0/00/$(h 7).0000000001"
assert_file "backup marker written" "$CACHE_LOCAL_DIR/.last-backup"
[ -d "$CACHE_ARCHIVE_DIR/.rsync-tmp" ] && ok "backup partials kept outside the archive tree" || fail "archive rsync temp dir missing"
assert_no_file "lock released" "$CACHE_LOCK_DIR"
assert_eq "state is done" "$(sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' "$CACHE_STATE_DIR/cache-backup.json")" "done"

# The marker is back-dated 2 s (see cache-backup.sh), so the run straight
# after re-lists entries written just before the previous one (harmless:
# --update skips them). Once the marker has moved past them, nothing is listed.
sleep 3
sh "$CACHE_BACKUP_SCRIPT" > "$WORK/backup2a.log" 2>&1
sh "$CACHE_BACKUP_SCRIPT" > "$WORK/backup2.log" 2>&1
grep -q "nothing new" "$WORK/backup2.log" && ok "steady state finds nothing new" || fail "steady state: $(cat "$WORK/backup2.log")"
entry "$LOCAL" "$(h 3)" "after-marker" 0
sh "$CACHE_BACKUP_SCRIPT" > "$WORK/backup3.log" 2>&1
assert_file "incremental run copies only the new entry" "$ARCHIVE/0/00/$(h 3)"
grep -q "1 entries" "$WORK/backup3.log" && ok "incremental run lists 1 entry" || fail "incremental: $(cat "$WORK/backup3.log")"

# Lock held by a live peer: give up after CACHE_BACKUP_LOCK_WAIT=0 minutes.
mkdir -p "$CACHE_LOCK_DIR"
entry "$LOCAL" "$(h 4)" "blocked" 0
sh "$CACHE_BACKUP_SCRIPT" > "$WORK/backup4.log" 2>&1
assert_no_file "held lock skips the run" "$ARCHIVE/0/00/$(h 4)"
assert_eq "skipped state" "$(sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' "$CACHE_STATE_DIR/cache-backup.json")" "skipped"
# Stale lock is taken over.
touch -d "@$(( $(date +%s) - 7 * 3600 ))" "$CACHE_LOCK_DIR"
sh "$CACHE_BACKUP_SCRIPT" > "$WORK/backup5.log" 2>&1
assert_file "stale lock is taken over" "$ARCHIVE/0/00/$(h 4)"
assert_no_file "lock released after takeover" "$CACHE_LOCK_DIR"

# --full ignores the marker.
sh "$CACHE_BACKUP_SCRIPT" --full > "$WORK/backup6.log" 2>&1
grep -q "4 entries" "$WORK/backup6.log" && ok "--full considers every entry" || fail "--full: $(cat "$WORK/backup6.log")"

rm -rf "$CACHE_ARCHIVE_DIR"
sh "$CACHE_BACKUP_SCRIPT" > "$WORK/backup7.log" 2>&1
grep -q "not mounted" "$WORK/backup7.log" && ok "missing archive is a clean skip" || fail "missing archive: $(cat "$WORK/backup7.log")"

printf '\n%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
