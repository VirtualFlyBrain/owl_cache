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

# Cache archive handling. nginx serves from CACHE_LOCAL_DIR (node disk);
# CACHE_ARCHIVE_DIR is the shared NFS volume every instance restores from at
# start and backs up into on a schedule. See cache-restore.sh / cache-backup.sh
# and README "Cache archive".
export CACHE_ARCHIVE_DIR="${CACHE_ARCHIVE_DIR:-/cache}"
export CACHE_LOCAL_DIR="${CACHE_LOCAL_DIR:-/var/cache/nginx}"
# daily | weekly | off, plus CACHE_BACKUP_TIME (HH:MM, container local time)
# and CACHE_BACKUP_WEEKDAY (0-6, Sunday=0, weekly only). Replicas add a
# deterministic per-host offset of up to CACHE_BACKUP_JITTER_MINUTES so they do
# not all hit the NAS in the same minute. CACHE_BACKUP_CRON, if set, is used
# verbatim (5-field crontab spec) and receives no jitter.
export CACHE_BACKUP_SCHEDULE="${CACHE_BACKUP_SCHEDULE:-daily}"
export CACHE_BACKUP_TIME="${CACHE_BACKUP_TIME:-03:00}"
export CACHE_BACKUP_WEEKDAY="${CACHE_BACKUP_WEEKDAY:-0}"
export CACHE_BACKUP_JITTER_MINUTES="${CACHE_BACKUP_JITTER_MINUTES:-120}"

CACHE_LIB="${CACHE_LIB:-/usr/local/bin/cache-lib.sh}"
# shellcheck source=cache-lib.sh
. "$CACHE_LIB"

start_backup_scheduler() {
    spec="$(cache_backup_cron_spec)"
    if [ -z "$spec" ]; then
        echo "Scheduled cache backup disabled (CACHE_BACKUP_SCHEDULE=$CACHE_BACKUP_SCHEDULE); run cache-backup.sh by hand"
        return
    fi
    mkdir -p /etc/crontabs
    # Container stdout is fd 1 of PID 1, so the backup log lands in `docker logs`.
    # crond runs the job as root; cache-backup.sh drops to nginx itself.
    printf '%s /usr/local/bin/cache-backup.sh >> /proc/1/fd/1 2>&1\n' "$spec" > /etc/crontabs/root
    echo "Scheduled cache backup: crontab '$spec' (base ${CACHE_BACKUP_SCHEDULE} ${CACHE_BACKUP_TIME}, jitter up to ${CACHE_BACKUP_JITTER_MINUTES} min)"
    crond -b -l 8 -L /dev/stdout
}

prepare_log_paths
generate_ip_map "$BLOCKLIST_SOURCE" "$BLOCKLIST_MAP" "blocked"
generate_whitelist_maps "$WHITELIST_SOURCE" "$WHITELIST_MAP" "$WHITELIST_CIDR_MAP"

envsubst '${UPSTREAM_SERVER} ${CACHE_MAX_SIZE} ${CACHE_STALE_TIME} ${DNS_RESOLVER} ${FORCE_CACHE_REFRESH_ON_REQUEST} ${WORKER_PROCESSES} ${WORKER_CONNECTIONS} ${WORKER_RLIMIT_NOFILE}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# The sync scripts run as nginx (see CACHE_RUN_AS): they need to write their
# markers at the cache root and their state files next to status.json. Only
# the top-level directories are chowned -- a recursive chown over millions of
# cache entries would take longer than the restore.
mkdir -p /var/run/nginx "$CACHE_LOCAL_DIR/owlery"
chown nginx:nginx /var/run/nginx "$CACHE_LOCAL_DIR" "$CACHE_LOCAL_DIR/owlery" 2>/dev/null || true

/usr/local/bin/health-monitor.sh &

# CACHE_RESTORE_MODE=blocking (default): copy the archive into the local
# cache BEFORE nginx starts, so the instance only answers once it is fully
# warm. Nothing listens on port 80 meanwhile, so the orchestrator's health
# check must allow for the restore time (Rancher: raise the service's
# "initializing timeout", or rely on the load balancer's check instead).
# CACHE_RESTORE_MODE=background: start nginx immediately and warm the cache
# concurrently; nginx serves whatever has landed and treats the rest as
# ordinary misses. Use this when there is no redundant instance to cover.
export CACHE_RESTORE_MODE="${CACHE_RESTORE_MODE:-blocking}"
case "$(printf '%s' "$CACHE_RESTORE_MODE" | tr '[:upper:]' '[:lower:]')" in
    background|async)
        echo "Cache restore runs in the background (CACHE_RESTORE_MODE=$CACHE_RESTORE_MODE)"
        /usr/local/bin/cache-restore.sh &
        ;;
    *)
        echo "Cache restore runs before nginx starts (CACHE_RESTORE_MODE=$CACHE_RESTORE_MODE); port 80 stays closed until it finishes"
        /usr/local/bin/cache-restore.sh || echo "cache-restore.sh exited with status $?; starting nginx anyway"
        ;;
esac
start_backup_scheduler
exec nginx -g 'daemon off;'
