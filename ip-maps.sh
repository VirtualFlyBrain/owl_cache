#!/bin/sh
# shellcheck shell=sh
#
# Shared compilation of /logs/blocked.txt and /logs/whitelist.txt into the
# nginx map/geo files.
#
# This file exists because the logic had two copies. docker-entrypoint.sh
# compiles the lists once at container start; health-monitor.sh recompiles them
# every time one of the files changes. When the entrypoint learned to route
# CIDR ranges into a `geo` map, the monitor's private copy did not -- so a CIDR
# added to whitelist.txt worked until the next hot reload, then silently
# stopped, logging only "Ignoring invalid whitelisted IP entry". Both scripts
# now source this file, so they cannot drift again.
#
# POSIX sh only: this runs under BusyBox ash in nginx:*-alpine.

# A bare address, v4 or v6. Deliberately loose -- nginx does the real parsing
# and rejects a malformed key at reload; this only has to separate "address"
# from "range" from "junk".
is_valid_ip() {
    printf '%s' "$1" | grep -Eq '^[0-9a-f:.]+$'
}

# An address with a prefix length: 10.42.0.0/16, 2001:db8::/32.
is_valid_cidr() {
    printf '%s' "$1" | grep -Eq '^[0-9a-f:.]+/[0-9]+$'
}

# Strip CR, lowercase hex, drop `#` comments, trim surrounding space.
normalise_list_line() {
    printf '%s' "$1" | tr -d '\r' | tr 'A-F' 'a-f' | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Loopback and private IPs cannot legitimately reach nginx as $remote_addr from
# the outside; if one shows up in the probe log it is because a scanner spoofed
# X-Forwarded-For. Blocking such an address would lock out the local health
# monitor and anything else on the same bridge network, so refuse.
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

# Compile a list of bare addresses into nginx `map` syntax. Used for the
# blocklist, which has no range support by design -- an over-broad block is far
# more damaging than an over-broad whitelist.
generate_ip_map() {
    source_file="$1"
    target_map="$2"
    label="$3"
    tmp_map="$(mktemp "/tmp/${label}-ips.XXXXXX")"
    : > "$tmp_map"

    {
        while IFS= read -r raw_line || [ -n "$raw_line" ]; do
            line="$(normalise_list_line "$raw_line")"
            [ -z "$line" ] && continue

            if is_valid_ip "$line"; then
                if [ "$label" = "blocked" ] && ! is_safe_to_block "$line"; then
                    printf 'Refusing to compile loopback/private IP into blocked map: %s\n' "$line" >&2
                    continue
                fi
                printf '%s\n' "$line"
            elif is_valid_cidr "$line"; then
                printf 'Ignoring %s CIDR range in %s (ranges are not supported here): %s\n' \
                    "$label" "$source_file" "$raw_line" >&2
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
        line="$(normalise_list_line "$raw_line")"
        [ -z "$line" ] && continue

        if is_valid_cidr "$line"; then
            # CIDR -- emitted in nginx `geo` syntax.
            printf '%s 1;\n' "$line" >> "$tmp_cidr"
        elif is_valid_ip "$line"; then
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

# Is an IPv4 address inside an IPv4 CIDR? Compared by network index rather than
# a bitwise AND: BusyBox awk has no and(), but integer division by the block
# size gives the same answer and stays inside awk's double precision (a /0
# block is 2^32, well under 2^53).
#
# The block size is doubled in a loop rather than written as 2^(32-bits):
# BusyBox can be built without libm, and there the `^` operator dies with
# "Math support is not compiled in" -- which would have made every in-range
# address look out-of-range, silently, only on the runtime image.
ipv4_in_cidr() {
    awk -v ip="$1" -v cidr="$2" '
        function tonum(a,   p, n, i) {
            n = split(a, p, ".")
            if (n != 4) return -1
            for (i = 1; i <= 4; i++) {
                if (p[i] !~ /^[0-9]+$/ || p[i] + 0 > 255) return -1
            }
            return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4]
        }
        BEGIN {
            slash = index(cidr, "/")
            if (slash == 0) exit 1
            base = tonum(substr(cidr, 1, slash - 1))
            addr = tonum(ip)
            bits = substr(cidr, slash + 1)
            if (bits !~ /^[0-9]+$/) exit 1
            bits += 0
            if (base < 0 || addr < 0 || bits > 32) exit 1
            block = 1
            for (i = bits; i < 32; i++) block *= 2
            exit (int(base / block) == int(addr / block)) ? 0 : 1
        }'
}

# Is this address exempt from auto-blocking? Checks exact entries and IPv4
# ranges. Without the range check, an address inside a whitelisted CIDR could
# trip a probe pattern and get auto-blocked despite the operator having
# whitelisted its whole network -- the map files would then disagree about the
# same address.
#
# IPv6 ranges are not matched arithmetically here (no bitwise ops in BusyBox
# awk, and `::` compression makes textual prefix matching unsafe). Instead, if
# any IPv6 range is whitelisted at all, no IPv6 address is auto-blocked. That
# errs towards leaving a scanner unblocked rather than locking out a trusted
# host, which is the right way round: the probe filter still returns 403 either
# way, auto-blocking only saves the work of matching it.
is_ip_whitelisted() {
    source_file="$1"
    ip="$2"

    [ -f "$source_file" ] || return 1

    candidate="$(normalise_list_line "$ip")"
    [ -n "$candidate" ] || return 1

    case "$candidate" in
        *:*) candidate_is_v6=1 ;;
        *)   candidate_is_v6=0 ;;
    esac

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line="$(normalise_list_line "$raw_line")"
        [ -z "$line" ] && continue

        [ "$line" = "$candidate" ] && return 0

        is_valid_cidr "$line" || continue

        case "$line" in
            *:*)
                [ "$candidate_is_v6" -eq 1 ] && return 0
                ;;
            *)
                if [ "$candidate_is_v6" -eq 0 ] && ipv4_in_cidr "$candidate" "$line"; then
                    return 0
                fi
                ;;
        esac
    done < "$source_file"

    return 1
}
