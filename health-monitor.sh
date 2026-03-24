#!/bin/sh

# Poll NGINX and the access log to keep /status current while also logging
# upstream reachability changes.

ACCESS_LOG=${ACCESS_LOG:-/var/log/nginx/access.log}
STATUS_FILE=${STATUS_FILE:-/var/run/nginx/status.json}
NGINX_STATUS_URL=${NGINX_STATUS_URL:-http://127.0.0.1:8080/__nginx_status}
STATUS_POLL_INTERVAL=${STATUS_POLL_INTERVAL:-5}
HEALTH_LOG_INTERVAL=${HEALTH_LOG_INTERVAL:-300}

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

active_connections=
reading_connections=
writing_connections=
waiting_connections=

nginx_healthy=false
upstream_healthy=false
last_upstream_state=
last_health_log_epoch=0

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
  }
}
EOF

    mv "$tmp_file" "$STATUS_FILE"
}

mkdir -p "$STATUS_DIR" "$ACCESS_LOG_DIR"
umask 022

recount_access_log
write_status_file

echo "Monitoring upstream server: $UPSTREAM_HOST:$UPSTREAM_PORT"

while true; do
    update_access_log_counts
    update_upstream_health
    update_connection_stats
    write_status_file
    sleep "$STATUS_POLL_INTERVAL"
done
