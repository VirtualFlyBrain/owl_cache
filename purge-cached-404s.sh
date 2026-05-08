#!/bin/sh
# Purge cached 404 responses from the nginx cache directory.
#
# nginx writes each cache entry as: <fixed-size binary header> KEY:
# ... <verbatim HTTP response>. The binary header does not contain the
# ASCII string "HTTP/1.x NNN ", so grepping for the response status line
# reliably identifies cached responses by status code.
#
# Walks the cache, finds entries whose stored status is 404, and deletes
# only those entries. Use this to evict 404 entries that were poisoned
# into the cache before the fix that stopped caching 404s, without
# nuking the whole cache. Files removed from disk are simply treated as
# MISS on the next request -- no nginx reload required.
#
# Usage:
#   purge-cached-404s.sh           # dry run; list candidate files
#   purge-cached-404s.sh --apply   # delete the matching files
#
# Honours $CACHE_DIR (default: /var/cache/nginx/owlery).

set -eu

CACHE_DIR="${CACHE_DIR:-/var/cache/nginx/owlery}"
# Anchor to the start of a line. In an nginx cache file the response
# status line is always preceded by the newline that terminates the
# preceding "KEY: ..." line, so this matches the real status line and
# not a substring that happens to appear inside a response body.
PATTERN='^HTTP/1\.[01] 404 '
APPLY=0

case "${1:-}" in
    --apply|-y)
        APPLY=1
        ;;
    --help|-h)
        sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,20p'
        exit 0
        ;;
    "")
        ;;
    *)
        printf 'purge-cached-404s: unknown argument: %s\n' "$1" >&2
        exit 2
        ;;
esac

if [ ! -d "$CACHE_DIR" ]; then
    printf 'purge-cached-404s: cache directory not found: %s\n' "$CACHE_DIR" >&2
    exit 1
fi

CANDIDATES="$(mktemp)"
trap 'rm -f "$CANDIDATES"' EXIT

# -r recursive, -l list filenames, -a treat binary as text,
# --max-count=1 stop reading each file after the first match.
grep -rla --max-count=1 "$PATTERN" "$CACHE_DIR" > "$CANDIDATES" 2>/dev/null || true

found=$(wc -l < "$CANDIDATES" | tr -d ' ')

if [ "$APPLY" = "1" ]; then
    if [ "$found" -gt 0 ]; then
        xargs -r rm -f -- < "$CANDIDATES"
    fi
    printf 'purge-cached-404s: deleted %d cached 404 entries from %s\n' \
        "$found" "$CACHE_DIR"
else
    cat "$CANDIDATES"
    printf '\npurge-cached-404s: %d candidate file(s) in %s. Re-run with --apply to delete.\n' \
        "$found" "$CACHE_DIR" >&2
fi
