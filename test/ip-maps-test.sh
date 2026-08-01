#!/bin/sh
# Unit tests for ip-maps.sh.
#
# Run directly (`sh test/ip-maps-test.sh`) or let the Docker build run it --
# the Dockerfile executes this before the image is finalised, so a regression
# here fails `docker build` rather than surfacing as a silently-ignored
# whitelist entry hours later in production.
#
# POSIX sh only, to match BusyBox ash in the runtime image.

set -eu

# Defaults to the copy next to this checkout; the image build points it at the
# installed copy instead.
IP_MAPS_LIB="${IP_MAPS_LIB:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/ip-maps.sh}"
# shellcheck source=ip-maps.sh disable=SC1090
. "$IP_MAPS_LIB"

WORK="$(mktemp -d /tmp/ip-maps-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

failures=0
checks=0

ok() {
    checks=$((checks + 1))
    printf '  ok   %s\n' "$1"
}

fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf '  FAIL %s\n' "$1"
}

assert_status() {
    # assert_status <description> <expected 0|1> <command...>
    description="$1"
    expected="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then
        actual=0
    else
        actual=1
    fi
    if [ "$actual" = "$expected" ]; then
        ok "$description"
    else
        fail "$description (expected status $expected, got $actual)"
    fi
}

assert_file_is() {
    # assert_file_is <description> <file> <expected contents>
    if [ "$(cat "$2")" = "$3" ]; then
        ok "$1"
    else
        fail "$1"
        printf '       expected: %s\n' "$3"
        printf '       actual:   %s\n' "$(cat "$2")"
    fi
}

echo 'line classification'
assert_status 'plain IPv4 is an IP'        0 is_valid_ip   '129.215.105.177'
assert_status 'plain IPv6 is an IP'        0 is_valid_ip   '2001:db8::beef'
assert_status 'CIDR is not a plain IP'     1 is_valid_ip   '129.215.0.0/16'
assert_status 'IPv4 CIDR is a CIDR'        0 is_valid_cidr '10.42.0.0/16'
assert_status 'IPv6 CIDR is a CIDR'        0 is_valid_cidr '2001:db8::/32'
assert_status 'plain IP is not a CIDR'     1 is_valid_cidr '203.0.113.50'
assert_status 'hostname is neither'        1 is_valid_ip   'example.org'
assert_status 'missing prefix is not CIDR' 1 is_valid_cidr '10.42.0.0/'

echo
echo 'whitelist compilation splits IPs from ranges'
# The regression this file exists for: 129.215.0.0/16 must land in the geo map,
# not be discarded as an invalid IP.
printf '%s\n' \
    '203.0.113.50' \
    '# the VPN pool' \
    '129.215.0.0/16' \
    '10.42.0.0/16' \
    '2001:DB8::BEEF' \
    '2001:db8::/32' \
    '' \
    '   198.51.100.7   ' \
    'not-an-address' \
    '203.0.113.50' \
    > "$WORK/whitelist.txt"
printf '192.0.2.1\r\n' >> "$WORK/whitelist.txt"

generate_whitelist_maps "$WORK/whitelist.txt" "$WORK/ips.map" "$WORK/cidrs.map" 2>"$WORK/warnings"

assert_file_is 'plain IPs compiled, deduped, sorted, CRLF and case normalised' \
    "$WORK/ips.map" \
'192.0.2.1 1;
198.51.100.7 1;
2001:db8::beef 1;
203.0.113.50 1;'

assert_file_is 'CIDR ranges compiled into the geo map' \
    "$WORK/cidrs.map" \
'10.42.0.0/16 1;
129.215.0.0/16 1;
2001:db8::/32 1;'

if grep -q 'not-an-address' "$WORK/warnings"; then
    ok 'junk entry reported'
else
    fail 'junk entry reported'
fi
if grep -q '129.215.0.0/16' "$WORK/warnings"; then
    fail 'CIDR must not be reported as invalid'
else
    ok 'CIDR not reported as invalid'
fi

echo
echo 'blocklist compilation'
printf '%s\n' '203.0.113.10' '127.0.0.1' '10.0.0.5' '198.51.100.0/24' > "$WORK/blocked.txt"
generate_ip_map "$WORK/blocked.txt" "$WORK/blocked.map" blocked 2>"$WORK/blocked-warnings"
assert_file_is 'public IPs blocked, loopback and RFC1918 refused, range refused' \
    "$WORK/blocked.map" '203.0.113.10 1;'
if grep -q 'ranges are not supported' "$WORK/blocked-warnings"; then
    ok 'blocklist range rejected with a specific message'
else
    fail 'blocklist range rejected with a specific message'
fi

echo
echo 'IPv4 range membership'
assert_status 'inside a /16'            0 ipv4_in_cidr '129.215.105.177' '129.215.0.0/16'
assert_status 'outside a /16'           1 ipv4_in_cidr '129.216.105.177' '129.215.0.0/16'
assert_status 'inside a /24'            0 ipv4_in_cidr '10.42.0.99'      '10.42.0.0/24'
assert_status 'outside a /24'           1 ipv4_in_cidr '10.42.1.99'      '10.42.0.0/24'
assert_status 'first address of range'  0 ipv4_in_cidr '10.42.0.0'       '10.42.0.0/16'
assert_status 'last address of range'   0 ipv4_in_cidr '10.42.255.255'   '10.42.0.0/16'
assert_status 'one past the range'      1 ipv4_in_cidr '10.43.0.0'       '10.42.0.0/16'
assert_status 'one before the range'    1 ipv4_in_cidr '10.41.255.255'   '10.42.0.0/16'
assert_status '/32 matches exactly'     0 ipv4_in_cidr '203.0.113.50'    '203.0.113.50/32'
assert_status '/32 rejects neighbour'   1 ipv4_in_cidr '203.0.113.51'    '203.0.113.50/32'
assert_status '/0 matches anything'     0 ipv4_in_cidr '8.8.8.8'         '0.0.0.0/0'
assert_status 'top of the address space' 0 ipv4_in_cidr '255.255.255.255' '255.255.255.0/24'
assert_status 'octet over 255 rejected' 1 ipv4_in_cidr '10.42.0.256'     '10.42.0.0/16'
assert_status 'non-numeric rejected'    1 ipv4_in_cidr 'example.org'     '10.42.0.0/16'
assert_status 'IPv6 candidate rejected' 1 ipv4_in_cidr '2001:db8::1'     '10.42.0.0/16'

echo
echo 'auto-block exemption honours ranges'
printf '%s\n' '203.0.113.50' '129.215.0.0/16' > "$WORK/wl-v4.txt"
assert_status 'exact entry exempt'        0 is_ip_whitelisted "$WORK/wl-v4.txt" '203.0.113.50'
assert_status 'address inside range exempt' 0 is_ip_whitelisted "$WORK/wl-v4.txt" '129.215.105.177'
assert_status 'address outside range not exempt' 1 is_ip_whitelisted "$WORK/wl-v4.txt" '198.51.100.9'
assert_status 'trailing comment tolerated' 0 is_ip_whitelisted "$WORK/wl-v4.txt" '203.0.113.50 # office'
assert_status 'IPv6 not exempt via IPv4 range' 1 is_ip_whitelisted "$WORK/wl-v4.txt" '2001:db8::1'
assert_status 'missing file is not exempt' 1 is_ip_whitelisted "$WORK/nope.txt" '203.0.113.50'

printf '%s\n' '2001:db8::/32' > "$WORK/wl-v6.txt"
assert_status 'IPv6 range present means no IPv6 auto-block' 0 \
    is_ip_whitelisted "$WORK/wl-v6.txt" '2001:db8::1'
assert_status 'IPv6 range does not exempt IPv4' 1 \
    is_ip_whitelisted "$WORK/wl-v6.txt" '198.51.100.9'

: > "$WORK/wl-empty.txt"
assert_status 'empty whitelist exempts nothing' 1 is_ip_whitelisted "$WORK/wl-empty.txt" '203.0.113.50'

echo
echo 'callers are wired to the shared library'
# The original bug was not in the compiler but in who called it: the monitor
# had its own copy and recompiled the whitelist with the IP-only function, so
# every hot reload dropped the ranges the entrypoint had accepted at boot.
# These checks fail the build if the two ever diverge again.
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$IP_MAPS_LIB")" && pwd)"
for script in health-monitor.sh docker-entrypoint.sh; do
    path="$SCRIPT_DIR/$script"
    if [ ! -f "$path" ]; then
        fail "$script found next to ip-maps.sh"
        continue
    fi
    ok "$script found next to ip-maps.sh"

    if grep -q '^\. "\$IP_MAPS_LIB"' "$path"; then
        ok "$script sources the shared library"
    else
        fail "$script sources the shared library"
    fi

    if grep -qE '^(is_valid_ip|is_safe_to_block|generate_ip_map|generate_whitelist_maps)\(\)' "$path"; then
        fail "$script keeps no private copy of the compiler"
    else
        ok "$script keeps no private copy of the compiler"
    fi

    if grep -q 'generate_whitelist_maps "\$WHITELIST_SOURCE" "\$WHITELIST_MAP" "\$WHITELIST_CIDR_MAP"' "$path"; then
        ok "$script compiles the whitelist with CIDR routing"
    else
        fail "$script compiles the whitelist with CIDR routing"
    fi
done

echo
if [ "$failures" -eq 0 ]; then
    printf '%s checks passed\n' "$checks"
else
    printf '%s of %s checks FAILED\n' "$failures" "$checks"
    exit 1
fi
