#!/bin/sh
set -eu

BLOCKLIST_SOURCE="/logs/blocked.txt"
BLOCKLIST_MAP="/etc/nginx/blocked-ips.map"
WHITELIST_SOURCE="/logs/whitelist.txt"
WHITELIST_MAP="/etc/nginx/whitelisted-ips.map"
# CIDR ranges from the same whitelist source are routed to a separate map
# consumed by an nginx `geo` block, which performs proper subnet matching.
# Plain `map` keys are literal strings and can't match a range.
WHITELIST_CIDR_MAP="/etc/nginx/whitelisted-cidrs.map"

prepare_log_paths() {
    # Ensure required runtime directories exist, including fresh bind mounts/volumes.
    mkdir -p \
        /logs \
        /logs/hacks \
        /var/cache/nginx \
        /var/cache/nginx/owlery \
        /var/log/nginx \
        /etc/nginx

    touch "$BLOCKLIST_SOURCE"
    touch "$WHITELIST_SOURCE"
    touch "$BLOCKLIST_MAP"
    touch "$WHITELIST_MAP"
    touch "$WHITELIST_CIDR_MAP"
}

# Loopback and private IPs must never end up in the blocked map -- they only
# get there via spoofed X-Forwarded-For and would lock out the local health
# monitor and any other internal caller.
is_safe_to_block() {
    case "$1" in
        127.*|::1) return 1 ;;
        10.*|192.168.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        fc*|fd*) return 1 ;;
        fe8*|fe9*|fea*|feb*) return 1 ;;
    esac
    return 0
}

generate_ip_map() {
    source_file="$1"
    target_map="$2"
    label="$3"
    tmp_map="$(mktemp /tmp/${label}-ips.XXXXXX)"
    : > "$tmp_map"

    {
        while IFS= read -r raw_line || [ -n "$raw_line" ]; do
            line="$(printf '%s' "$raw_line" | tr -d '\r' | tr 'A-F' 'a-f' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -z "$line" ] && continue

            if printf '%s' "$line" | grep -Eq '^[0-9a-f:.]+$'; then
                if [ "$label" = "blocked" ] && ! is_safe_to_block "$line"; then
                    printf 'Refusing to compile loopback/private IP into blocked map: %s\n' "$line" >&2
                    continue
                fi
                printf '%s\n' "$line"
            else
                printf 'Ignoring invalid %s IP entry in %s: %s\n' "$label" "$source_file" "$raw_line" >&2
            fi
        done < "$source_file"
    } | sort -u | while IFS= read -r line; do
        printf '%s 1;\n' "$line" >> "$tmp_map"
    done

    mv "$tmp_map" "$target_map"
}

# Compile whitelist.txt into TWO outputs:
#   - plain IPs go to $ip_map (consumed by the existing nginx `map` block)
#   - CIDR ranges go to $cidr_map (consumed by an nginx `geo` block)
# Routing happens by line shape; everything else is flagged invalid.
# Rancher pod-network ranges (10.42.0.0/16 by default for Canal/Flannel) are
# the canonical use case -- without CIDR support the warmup tool running from
# a pod can't be whitelisted for X-Force-Refresh.
generate_whitelist_maps() {
    source_file="$1"
    ip_map="$2"
    cidr_map="$3"
    tmp_ip="$(mktemp /tmp/whitelisted-ips.XXXXXX)"
    tmp_cidr="$(mktemp /tmp/whitelisted-cidrs.XXXXXX)"
    : > "$tmp_ip"
    : > "$tmp_cidr"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line="$(printf '%s' "$raw_line" | tr -d '\r' | tr 'A-F' 'a-f' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue

        if printf '%s' "$line" | grep -Eq '^[0-9a-f:.]+/[0-9]+$'; then
            # CIDR -- emitted in nginx `geo` syntax.
            printf '%s 1;\n' "$line" >> "$tmp_cidr"
        elif printf '%s' "$line" | grep -Eq '^[0-9a-f:.]+$'; then
            # Plain IP -- emitted in nginx `map` syntax.
            printf '%s 1;\n' "$line" >> "$tmp_ip"
        else
            printf 'Ignoring invalid whitelist entry in %s: %s\n' "$source_file" "$raw_line" >&2
        fi
    done < "$source_file"

    # Dedupe each output independently; atomic publish via mv.
    sort -u -o "$tmp_ip"   "$tmp_ip"
    sort -u -o "$tmp_cidr" "$tmp_cidr"
    mv "$tmp_ip"   "$ip_map"
    mv "$tmp_cidr" "$cidr_map"
}

export UPSTREAM_SERVER="${UPSTREAM_SERVER:-owl.virtualflybrain.org:80}"
export CACHE_MAX_SIZE="${CACHE_MAX_SIZE:-20g}"
export CACHE_STALE_TIME="${CACHE_STALE_TIME:-6M}"
export DNS_RESOLVER="${DNS_RESOLVER:-8.8.8.8}"
# Single-container concurrency knobs. By default we run nginx with 3/4 of the
# visible cores (rounded down, floored at 1), leaving headroom for the health
# monitor and the OS rather than nginx's native `auto`, which spawns one worker
# per core. Set WORKER_PROCESSES to a positive integer to override; an empty
# value or the literal `auto` falls back to the 3/4 calculation.
# Caveat: nproc honours a cpuset but ignores a CFS quota (--cpus / NanoCpus), so
# under a quota-only limit on a shared host, pin WORKER_PROCESSES explicitly.
resolve_worker_processes() {
    case "${WORKER_PROCESSES:-auto}" in
        ''|auto)
            cores="$(nproc 2>/dev/null || echo 1)"
            workers=$(( cores * 3 / 4 ))
            [ "$workers" -lt 1 ] && workers=1
            printf '%s' "$workers"
            ;;
        *)
            printf '%s' "$WORKER_PROCESSES"
            ;;
    esac
}
export WORKER_PROCESSES="$(resolve_worker_processes)"
export WORKER_CONNECTIONS="${WORKER_CONNECTIONS:-4096}"
export WORKER_RLIMIT_NOFILE="${WORKER_RLIMIT_NOFILE:-65535}"

case "$(printf '%s' "${FORCE_CACHE_REFRESH_ON_REQUEST:-false}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
        export FORCE_CACHE_REFRESH_ON_REQUEST=1
        ;;
    *)
        export FORCE_CACHE_REFRESH_ON_REQUEST=0
        ;;
esac

prepare_log_paths
generate_ip_map "$BLOCKLIST_SOURCE" "$BLOCKLIST_MAP" "blocked"
generate_whitelist_maps "$WHITELIST_SOURCE" "$WHITELIST_MAP" "$WHITELIST_CIDR_MAP"

envsubst '${UPSTREAM_SERVER} ${CACHE_MAX_SIZE} ${CACHE_STALE_TIME} ${DNS_RESOLVER} ${FORCE_CACHE_REFRESH_ON_REQUEST} ${WORKER_PROCESSES} ${WORKER_CONNECTIONS} ${WORKER_RLIMIT_NOFILE}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

/usr/local/bin/health-monitor.sh &
exec nginx -g 'daemon off;'
