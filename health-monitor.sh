#!/bin/sh

# Poll NGINX and the access log to keep /status current while also logging
# upstream reachability changes.

ACCESS_LOG=${ACCESS_LOG:-/var/log/nginx/cache-access.log}
STATUS_FILE=${STATUS_FILE:-/var/run/nginx/status.json}
NGINX_STATUS_URL=${NGINX_STATUS_URL:-http://127.0.0.1:8080/__nginx_status}
STATUS_POLL_INTERVAL=${STATUS_POLL_INTERVAL:-5}
HEALTH_LOG_INTERVAL=${HEALTH_LOG_INTERVAL:-300}
PROBE_LOG=${PROBE_LOG:-/logs/hacks/probes.log}
BLOCKLIST_SOURCE=${BLOCKLIST_SOURCE:-/logs/blocked.txt}
BLOCKLIST_MAP=${BLOCKLIST_MAP:-/etc/nginx/blocked-ips.map}
WHITELIST_SOURCE=${WHITELIST_SOURCE:-/logs/whitelist.txt}
WHITELIST_MAP=${WHITELIST_MAP:-/etc/nginx/whitelisted-ips.map}
WHITELIST_CIDR_MAP=${WHITELIST_CIDR_MAP:-/etc/nginx/whitelisted-cidrs.map}
AUTO_BLOCK_SCANNERS=${AUTO_BLOCK_SCANNERS:-true}

# List compilation is shared with docker-entrypoint.sh, which compiles the same
# two files once at startup. See ip-maps.sh for why it is not inlined here.
IP_MAPS_LIB=${IP_MAPS_LIB:-/usr/local/bin/ip-maps.sh}
# shellcheck source=ip-maps.sh
. "$IP_MAPS_LIB"

UPSTREAM_HOST=$(printf '%s' "$UPSTREAM_SERVER" | cut -d: -f1)
UPSTREAM_PORT=$(printf '%s' "$UPSTREAM_SERVER" | cut -d: -f2)

# Default to port 80 if no port is specified.
if [ -z "$UPSTREAM_HOST" ]; then
    UPSTREAM_HOST=unknown
fi

if [ -z "$UPSTREAM_PORT" ] || [ "$UPSTREAM_HOST" = "$UPSTREAM_PORT" ]; then
    UPSTREAM_PORT=80
fi

STATUS_DIR=$(dirname "$STATUS_FILE")
ACCESS_LOG_DIR=$(dirname "$ACCESS_LOG")

total_requests=0
hit_requests=0
miss_requests=0
access_log_size=0
probe_log_size=0
last_blocklist_signature=0:0
last_whitelist_signature=0:0

active_connections=
reading_connections=
writing_connections=
waiting_connections=

nginx_healthy=false
upstream_healthy=false
last_upstream_state=
last_health_log_epoch=0

CACHE_RESTORE_STATE=${CACHE_RESTORE_STATE:-$STATUS_DIR/cache-restore.json}
CACHE_BACKUP_STATE=${CACHE_BACKUP_STATE:-$STATUS_DIR/cache-backup.json}
HEALTH_MONITOR_PID_FILE=${HEALTH_MONITOR_PID_FILE:-$STATUS_DIR/health-monitor.pid}

# Embed a state file written by cache-restore.sh / cache-backup.sh, or null
# when that job has not run in this container yet.
json_state_or_null() {
    if [ -s "$1" ]; then
        # Indent every line but the first, which follows the key on its own line.
        sed '1!s/^/    /' "$1"
    else
        printf 'null'
    fi
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_number_or_null() {
    if [ -n "$1" ]; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}

get_file_size() {
    if [ ! -f "$1" ]; then
        printf '0'
        return
    fi

    if size=$(stat -c %s "$1" 2>/dev/null); then
        printf '%s' "$size"
    else
        wc -c < "$1" 2>/dev/null | tr -d ' '
    fi
}

get_file_mtime() {
    if [ ! -f "$1" ]; then
        printf '0'
        return
    fi

    if mtime=$(stat -c %Y "$1" 2>/dev/null); then
        printf '%s' "$mtime"
    else
        printf '0'
    fi
}

get_file_signature() {
    file_path="$1"
    printf '%s:%s' "$(get_file_mtime "$file_path")" "$(get_file_size "$file_path")"
}

is_truthy() {
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Exact-match membership test, used to avoid appending a duplicate to
# blocked.txt. The whitelist side needs range awareness and uses
# is_ip_whitelisted from ip-maps.sh instead.
is_ip_listed() {
    source_file="$1"
    ip="$2"

    if [ ! -f "$source_file" ]; then
        return 1
    fi

    grep -Fqx "$ip" "$source_file" 2>/dev/null
}

prepare_security_paths() {
    mkdir -p \
        "$(dirname "$PROBE_LOG")" \
        "$(dirname "$BLOCKLIST_SOURCE")" \
        "$(dirname "$BLOCKLIST_MAP")" \
        "$(dirname "$WHITELIST_SOURCE")" \
        "$(dirname "$WHITELIST_MAP")" \
        "$(dirname "$WHITELIST_CIDR_MAP")"

    touch "$PROBE_LOG"
    touch "$BLOCKLIST_SOURCE"
    touch "$BLOCKLIST_MAP"
    touch "$WHITELIST_SOURCE"
    touch "$WHITELIST_MAP"
    touch "$WHITELIST_CIDR_MAP"
}

reload_nginx() {
    if nginx -s reload >/dev/null 2>&1; then
        echo "$(date): Applied updated block/whitelist IP maps and reloaded nginx"
    else
        echo "$(date): WARNING - Failed to reload nginx after IP map update" >&2
    fi
}

sync_ip_maps_if_needed() {
    blocklist_signature=$(get_file_signature "$BLOCKLIST_SOURCE")
    whitelist_signature=$(get_file_signature "$WHITELIST_SOURCE")

    if [ "$blocklist_signature" = "$last_blocklist_signature" ] && [ "$whitelist_signature" = "$last_whitelist_signature" ]; then
        return
    fi

    generate_ip_map "$BLOCKLIST_SOURCE" "$BLOCKLIST_MAP" "blocked"
    generate_whitelist_maps "$WHITELIST_SOURCE" "$WHITELIST_MAP" "$WHITELIST_CIDR_MAP"
    last_blocklist_signature="$blocklist_signature"
    last_whitelist_signature="$whitelist_signature"
    reload_nginx
}

update_auto_blocklist_from_probe_log() {
    if ! is_truthy "$AUTO_BLOCK_SCANNERS"; then
        return
    fi

    current_size=$(get_file_size "$PROBE_LOG")

    if [ "$current_size" -lt "$probe_log_size" ]; then
        # Log rotation/truncation: restart tailing from the beginning.
        probe_log_size=0
    fi

    if [ "$current_size" -eq "$probe_log_size" ]; then
        return
    fi

    start_byte=$((probe_log_size + 1))
    tmp_chunk="$(mktemp /tmp/probe-log.XXXXXX)"

    if ! tail -c +"$start_byte" "$PROBE_LOG" > "$tmp_chunk" 2>/dev/null; then
        rm -f "$tmp_chunk"
        probe_log_size="$current_size"
        return
    fi

    probe_log_size="$current_size"
    added_ip=0

    while IFS= read -r line || [ -n "$line" ]; do
        ip="$(printf '%s\n' "$line" | sed -n 's/.*client_ip="\([^"]*\)".*/\1/p')"
        [ -z "$ip" ] && continue
        is_valid_ip "$ip" || continue

        # Never auto-block loopback or RFC1918 addresses -- they only land in
        # the probe log via spoofed X-Forwarded-For.
        if ! is_safe_to_block "$ip"; then
            echo "$(date): Refusing to auto-block loopback/private IP from probe log: $ip" >&2
            continue
        fi

        # Whitelisted IPs remain exempt even if they trigger probe patterns.
        # Range-aware: an address inside a whitelisted CIDR is exempt too.
        if is_ip_whitelisted "$WHITELIST_SOURCE" "$ip"; then
            continue
        fi

        if ! is_ip_listed "$BLOCKLIST_SOURCE" "$ip"; then
            printf '%s\n' "$ip" >> "$BLOCKLIST_SOURCE"
            added_ip=1
            echo "$(date): Auto-blocked scanner IP: $ip"
        fi
    done < "$tmp_chunk"

    rm -f "$tmp_chunk"

    if [ "$added_ip" -eq 1 ]; then
        sync_ip_maps_if_needed
    fi
}

recount_access_log() {
    if [ ! -f "$ACCESS_LOG" ]; then
        total_requests=0
        hit_requests=0
        miss_requests=0
        access_log_size=0
        return
    fi

    counts=$(awk '
        BEGIN { total = 0; hit = 0; miss = 0 }
        {
            status = ""
            if (NF >= 3) {
                status = $(NF - 2)
            }
            if (status ~ /^(HIT|MISS|BYPASS|EXPIRED|STALE|UPDATING|REVALIDATED)$/) {
                total++
                if (status == "HIT") {
                    hit++
                } else if (status == "MISS") {
                    miss++
                }
            }
        }
        END { printf "%d %d %d", total, hit, miss }
    ' "$ACCESS_LOG" 2>/dev/null)

    set -- $counts
    total_requests=${1:-0}
    hit_requests=${2:-0}
    miss_requests=${3:-0}
    access_log_size=$(get_file_size "$ACCESS_LOG")
}

update_access_log_counts() {
    current_size=$(get_file_size "$ACCESS_LOG")

    if [ "$current_size" -lt "$access_log_size" ]; then
        recount_access_log
        return
    fi

    if [ "$current_size" -eq "$access_log_size" ]; then
        return
    fi

    if [ "$access_log_size" -eq 0 ]; then
        recount_access_log
        return
    fi

    start_byte=$((access_log_size + 1))
    counts=$(tail -c +"$start_byte" "$ACCESS_LOG" 2>/dev/null | awk '
        BEGIN { total = 0; hit = 0; miss = 0 }
        {
            status = ""
            if (NF >= 3) {
                status = $(NF - 2)
            }
            if (status ~ /^(HIT|MISS|BYPASS|EXPIRED|STALE|UPDATING|REVALIDATED)$/) {
                total++
                if (status == "HIT") {
                    hit++
                } else if (status == "MISS") {
                    miss++
                }
            }
        }
        END { printf "%d %d %d", total, hit, miss }
    ')

    set -- $counts
    total_requests=$((total_requests + ${1:-0}))
    hit_requests=$((hit_requests + ${2:-0}))
    miss_requests=$((miss_requests + ${3:-0}))
    access_log_size=$current_size
}

update_upstream_health() {
    current_epoch=$(date +%s)

    if nc -z -w3 "$UPSTREAM_HOST" "$UPSTREAM_PORT" 2>/dev/null; then
        upstream_healthy=true
        upstream_state=healthy
        upstream_message="Upstream server is healthy"
    else
        upstream_healthy=false
        upstream_state=unreachable
        upstream_message="WARNING - Upstream server $UPSTREAM_HOST:$UPSTREAM_PORT is unreachable"
    fi

    if [ "$upstream_state" != "$last_upstream_state" ] || [ $((current_epoch - last_health_log_epoch)) -ge "$HEALTH_LOG_INTERVAL" ]; then
        echo "$(date): $upstream_message"
        last_upstream_state=$upstream_state
        last_health_log_epoch=$current_epoch
    fi
}

update_connection_stats() {
    status_text=$(wget -q -O - "$NGINX_STATUS_URL" 2>/dev/null || true)

    if [ -n "$status_text" ]; then
        active_connections=$(printf '%s\n' "$status_text" | awk '/Active connections:/ { print $3 }')
        reading_connections=$(printf '%s\n' "$status_text" | awk '/Reading:/ { print $2 }')
        writing_connections=$(printf '%s\n' "$status_text" | awk '/Writing:/ { print $4 }')
        waiting_connections=$(printf '%s\n' "$status_text" | awk '/Waiting:/ { print $6 }')
        nginx_healthy=true
    else
        active_connections=
        reading_connections=
        writing_connections=
        waiting_connections=
        nginx_healthy=false
    fi
}

write_status_file() {
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    escaped_host=$(json_escape "$UPSTREAM_HOST")
    tmp_file="${STATUS_FILE}.tmp"

    cat > "$tmp_file" <<EOF
{
  "updated_at": "$timestamp",
  "health": {
    "nginx": $nginx_healthy,
    "upstream": $upstream_healthy
  },
  "upstream": {
    "host": "$escaped_host",
    "port": $UPSTREAM_PORT
  },
  "cache": {
    "source": "access_log",
    "total": $total_requests,
    "hit": $hit_requests,
    "miss": $miss_requests
  },
  "connections": {
    "active": $(json_number_or_null "$active_connections"),
    "reading": $(json_number_or_null "$reading_connections"),
    "writing": $(json_number_or_null "$writing_connections"),
    "waiting": $(json_number_or_null "$waiting_connections")
  },
  "archive": {
    "restore": $(json_state_or_null "$CACHE_RESTORE_STATE"),
    "backup": $(json_state_or_null "$CACHE_BACKUP_STATE")
  }
}
EOF

    mv "$tmp_file" "$STATUS_FILE"
}

mkdir -p "$STATUS_DIR" "$ACCESS_LOG_DIR"
prepare_security_paths
umask 022

# cache-restore.sh / cache-backup.sh signal this PID (cache_signal_status_refresh
# in cache-lib.sh) so a state change lands in /status immediately rather than
# waiting for the next STATUS_POLL_INTERVAL tick -- see cache-lib.sh for why.
echo $$ > "$HEALTH_MONITOR_PID_FILE"
trap 'write_status_file' USR1

probe_log_size=$(get_file_size "$PROBE_LOG")
last_blocklist_signature=$(get_file_signature "$BLOCKLIST_SOURCE")
last_whitelist_signature=$(get_file_signature "$WHITELIST_SOURCE")

recount_access_log
write_status_file

echo "Monitoring upstream server: $UPSTREAM_HOST:$UPSTREAM_PORT"
if is_truthy "$AUTO_BLOCK_SCANNERS"; then
    echo "Auto-blocking scanner IPs from probe log is enabled"
else
    echo "Auto-blocking scanner IPs from probe log is disabled"
fi

while true; do
    update_access_log_counts
    update_auto_blocklist_from_probe_log
    sync_ip_maps_if_needed
    update_upstream_health
    update_connection_stats
    write_status_file
    sleep "$STATUS_POLL_INTERVAL"
done
