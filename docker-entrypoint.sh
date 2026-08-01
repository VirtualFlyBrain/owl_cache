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

# List compilation is shared with health-monitor.sh, which recompiles the same
# two files on every change. See ip-maps.sh for why it is not inlined here.
IP_MAPS_LIB="${IP_MAPS_LIB:-/usr/local/bin/ip-maps.sh}"
# shellcheck source=ip-maps.sh
. "$IP_MAPS_LIB"

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
