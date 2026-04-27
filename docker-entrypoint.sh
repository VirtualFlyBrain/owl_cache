#!/bin/sh
set -eu

BLOCKLIST_SOURCE="/logs/blocked.txt"
BLOCKLIST_MAP="/etc/nginx/blocked-ips.map"
WHITELIST_SOURCE="/logs/whitelist.txt"
WHITELIST_MAP="/etc/nginx/whitelisted-ips.map"

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
}

generate_ip_map() {
    source_file="$1"
    target_map="$2"
    label="$3"
    tmp_map="$(mktemp /tmp/${label}-ips.XXXXXX)"
    : > "$tmp_map"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line="$(printf '%s' "$raw_line" | tr -d '\r' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue

        if printf '%s' "$line" | grep -Eq '^[0-9A-Fa-f:.]+$'; then
            printf '%s 1;\n' "$line" >> "$tmp_map"
        else
            printf 'Ignoring invalid %s IP entry in %s: %s\n' "$label" "$source_file" "$raw_line" >&2
        fi
    done < "$source_file"

    mv "$tmp_map" "$target_map"
}

export UPSTREAM_SERVER="${UPSTREAM_SERVER:-owl.virtualflybrain.org:80}"
export CACHE_MAX_SIZE="${CACHE_MAX_SIZE:-20g}"
export CACHE_STALE_TIME="${CACHE_STALE_TIME:-6M}"
export DNS_RESOLVER="${DNS_RESOLVER:-8.8.8.8}"

case "$(printf '%s' "${FORCE_CACHE_REFRESH_ON_REQUEST:-false}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
        FORCE_CACHE_REFRESH_ON_REQUEST=1
        ;;
    *)
        FORCE_CACHE_REFRESH_ON_REQUEST=0
        ;;
esac

prepare_log_paths
generate_ip_map "$BLOCKLIST_SOURCE" "$BLOCKLIST_MAP" "blocked"
generate_ip_map "$WHITELIST_SOURCE" "$WHITELIST_MAP" "whitelisted"

envsubst '${UPSTREAM_SERVER} ${CACHE_MAX_SIZE} ${CACHE_STALE_TIME} ${DNS_RESOLVER} ${FORCE_CACHE_REFRESH_ON_REQUEST}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

/usr/local/bin/health-monitor.sh &
exec nginx -g 'daemon off;'
