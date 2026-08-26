# NGINX Caching Proxy for Owlery

[![Docker Image](https://img.shields.io/badge/docker-virtualflybrain%2Fowl_cache-blue)](https://hub.docker.com/r/virtualflybrain/owl_cache)

A high-performance caching proxy server that sits in front of OWL reasoning services to dramatically speed up query responses. Built on NGINX Alpine with a 6-month cache TTL, stale-while-revalidate pattern, and 5-year disk retention so a cached response is always available.

The proxy also includes security guardrails to refuse common scanner/probing requests before they reach Owlery, with optional IP block and whitelist files under `/logs`.

## Usage Examples

### Basic Usage

```bash
# Start the proxy (both ports 80 and 8080 are available)
docker run -d --name owl-cache -p 80:80 -p 8080:8080 virtualflybrain/owl_cache:latest

# Make a query on port 80 (will be slow first time)
curl "http://localhost/kbs/vfb/instances?object=<http://purl.obolibrary.org/obo/FBbt_00005106>"

# Same query on port 8080 (will be fast from cache)
curl "http://localhost:8080/kbs/vfb/instances?object=<http://purl.obolibrary.org/obo/FBbt_00005106>"
```

### With Docker Compose

```yaml
version: '3.8'
services:
  owl-cache:
    image: virtualflybrain/owl_cache:latest
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - /data/owl-cache:/var/cache/nginx   # local node disk: what NGINX serves from
      - /cache:/cache                      # shared NFS archive: restored from at start, backed up into daily
      - /logs:/logs
    environment:
      - UPSTREAM_SERVER=owl:8080  # For production with owl service
      - CACHE_MAX_SIZE=1t         # bound on the LOCAL cache; size it to the node disk
      - DNS_RESOLVER=169.254.169.250  # Rancher internal DNS (check /etc/resolv.conf)
```

See [Cache archive](#cache-archive) for why the cache is split across two volumes.

### Health Check

```bash
curl http://localhost/health
# Returns: OK
```

`/health` is a lightweight liveness check for NGINX itself. Use `/status` for upstream reachability, cache totals, and connection counters.

### Status Endpoint

```bash
curl http://localhost/status
```

Example response:

```json
{
  "updated_at": "2026-03-24T12:00:00Z",
  "health": {
    "nginx": true,
    "upstream": true
  },
  "upstream": {
    "host": "owl.virtualflybrain.org",
    "port": 80
  },
  "cache": {
    "source": "access_log",
    "total": 120,
    "hit": 113,
    "miss": 7
  },
  "connections": {
    "active": 3,
    "reading": 0,
    "writing": 1,
    "waiting": 2
  }
}
```

`/status` is refreshed by a background monitor that reads `/var/log/nginx/cache-access.log` for cache totals and samples NGINX `stub_status` for connection counters.

**Health Monitoring**: A background process logs warnings when the upstream server becomes unreachable, but the container continues running to serve cached content.

## Configuration

### Environment Variables

- `UPSTREAM_SERVER`: Backend server URL (default: `owl.virtualflybrain.org:80`)
- `CACHE_MAX_SIZE`: Maximum cache size on disk (default: `20g`, accepts NGINX size units like `1t` for 1TB)
- `CACHE_STALE_TIME`: How long a cached response is considered fresh (default: `6M`). After this time the entry is served stale while being refreshed in the background. Accepts NGINX time units: `s`, `m`, `h`, `d`, `w`, `M` (30 days), `y` (365 days).
- `DNS_RESOLVER`: DNS resolver servers (default: `8.8.8.8`, space-separated list). Check `cat /etc/resolv.conf` in your container to find the correct value for your environment.
- `STATUS_POLL_INTERVAL`: Seconds between `/status` refreshes (default: `5`)
- `HEALTH_LOG_INTERVAL`: Seconds between periodic upstream health log lines when state is unchanged (default: `300`)
- `AUTO_BLOCK_SCANNERS`: Automatically append probe-source IPs from `/logs/hacks/probes.log` to `/logs/blocked.txt` and live-reload NGINX maps (default: `true`)
- `FORCE_CACHE_REFRESH_ON_REQUEST`: When `true`, each incoming request bypasses the cache and fetches fresh content from upstream, updating the cache on demand instead of serving cached entries.
- `WORKER_PROCESSES`: Number of NGINX worker processes (default: `auto`). `auto` spawns one worker per host CPU core, but it reads the host's online core count and **ignores the container's cgroup CPU quota** — on a shared/Rancher host pin this to the CPU reservation (e.g. `2`) so you don't over-spawn workers that can't run in parallel. A single container with a coherent local cache is the only safe way to share one cache directory across workers; do not point multiple containers at the same `/var/cache/nginx` volume — share the archive at `/cache` instead (see [Cache archive](#cache-archive)).
- `WORKER_CONNECTIONS`: Max simultaneous connections per worker (default: `4096`). Effective client concurrency is roughly `WORKER_PROCESSES × WORKER_CONNECTIONS`, halved on cache MISS since each client connection also opens an upstream connection.
- `WORKER_RLIMIT_NOFILE`: Per-worker open-file-descriptor ceiling (default: `65535`). Each client connection plus every open cached file uses a descriptor, so the OS default of 1024 throttles a busy cache. Must stay within the container's hard `nofile` ulimit — NGINX logs a warning and caps to the runtime limit if this is higher.

### Security Filtering and Blocking

- **Probe filtering**: Requests matching common probing signatures (for example `*.php`, WordPress probe paths like `wp-login.php`, `xmlrpc.php`, `wlwmanifest.xml`, `wp-includes/*`, `.env`, `phpmyadmin`, path traversal payloads) are immediately refused with HTTP `403` and are **not** forwarded upstream.
- **Probe log output**: Refused probe requests are logged to `/logs/hacks/probes.log`, including both raw `X-Forwarded-For` and the extracted left-most client IP.
- **Automatic scanner blocking**: When `AUTO_BLOCK_SCANNERS=true`, newly detected `client_ip` values in `/logs/hacks/probes.log` are appended to `/logs/blocked.txt` (unless already present or whitelisted), and NGINX is reloaded so the block takes effect without container restart.
- **Manual IP blocklist**: Add one IPv4/IPv6 address per line in `/logs/blocked.txt` (comments allowed with `#`).
- **Manual IP whitelist**: Add one IPv4/IPv6 address, or one CIDR range, per line in `/logs/whitelist.txt` (comments allowed with `#`). Ranges are matched as subnets, so a VPN or pod network whose addresses are reassigned per session can be whitelisted once instead of being re-added every time it changes.

Example `/logs/blocked.txt`:

```txt
203.0.113.10
# office VPN egress
2001:db8::1234
```

Example `/logs/whitelist.txt`:

```txt
203.0.113.50
# trusted monitoring source
2001:db8::beef
# whole networks, matched as subnets
10.42.0.0/16
2001:db8::/32
```

The blocklist takes single addresses only. A range there would be far more damaging to get wrong than an over-broad whitelist, so a CIDR line in `/logs/blocked.txt` is refused and logged rather than compiled.

Blocked IP requests return HTTP `403` and are logged to `/logs/hacks/blocked.log`.

Whitelist entries take precedence over both the blocklist and probe filter.

Blocklist/whitelist entries are watched continuously by the runtime monitor. Updates to `/logs/blocked.txt` or `/logs/whitelist.txt` are converted into map files and applied via `nginx -s reload` within a few seconds. A rejected line is reported on the container log, so check there if an entry does not seem to take effect.

### Per-request cache refresh

A whitelisted caller may send `X-Force-Refresh: true` (`1`, `yes` and `on` also work) to bypass the cache for that one request. The upstream response is written into the same cache slot the request would otherwise have read, so the next ordinary caller gets the refreshed copy — this is `proxy_cache_bypass` without `proxy_no_cache`, and it is how the post-release VFBquery warmup tool refreshes entries without flushing the cache.

The header is honoured only for addresses in `/logs/whitelist.txt`; from anywhere else it falls back to `FORCE_CACHE_REFRESH_ON_REQUEST` and is otherwise ignored. Nothing in the response says the header was refused, so confirm it took by reading `X-Cache-Status`:

```bash
curl -sS -o /dev/null -D - -H 'X-Force-Refresh: true' 'https://v3-cached.virtualflybrain.org/some/path' | grep -i '^x-cache-status'
```

`BYPASS` means the request went upstream and rewrote the cache slot. `HIT` means the header was ignored and the caller is not whitelisted.

### Cache Headers

The proxy adds helpful headers to responses:

- `X-Cache-Status`: `HIT`, `MISS`, `EXPIRED`, `STALE`, `UPDATING`, or `REVALIDATED`
- `X-Cache-Key`: The cache key used for the request

### Cache archive

NGINX serves the cache from `/var/cache/nginx` on local node disk. Serving
directly from an NFS volume costs an `open()`/`stat()` round trip per hit and
a metadata walk over millions of entries for the cache manager, and NGINX
cannot share one cache directory between instances anyway (the index lives in
each instance's shared memory). The shared NFS volume mounted at `/cache`
is therefore an **archive**, not the live cache: every instance restores from
it at start and backs up into it on a schedule.

Both directions follow one rule. NGINX names each entry by the MD5 of its
cache key and replaces entries atomically, so the union of several instances'
caches is itself a valid cache. Files are only ever copied with
`rsync --update` (skip when the destination is newer) and nothing is ever
deleted, so the archive is the union of everything any instance has cached,
with the newest version of each entry winning. The comparison is by mtime,
so the nodes and the NAS must agree on time (NTP); `--modify-window=2`
absorbs filesystem timestamp granularity, not clock skew.

**Restore** (`cache-restore.sh`) walks the archive once, sorts entries
newest first, and copies them in batches. By default
(`CACHE_RESTORE_MODE=blocking`) it runs **before NGINX starts**, so a fresh
instance only answers requests once its cache is fully warm; port 80 stays
closed meanwhile, so give the orchestrator's health check enough time (on
Rancher, raise the service's *initializing timeout* or rely on the load
balancer's check) and keep a second instance serving. A restore of ~1 TB /
millions of files takes hours. With `CACHE_RESTORE_MODE=background` NGINX
starts immediately and the copy runs alongside it: NGINX serves a cache file
that appears on disk after it has started (verified against 1.26), and
requests whose entry has not landed yet are ordinary misses. Either way,
progress is under `archive.restore` in `/status` (in blocking mode `/status`
only becomes reachable when NGINX starts; watch the container log until
then). If the local volume persists across restarts, the `.restored` marker
makes later starts skip the restore (`CACHE_RESTORE=always` forces it; `off`
disables it). rsync writes its partial files to `.rsync-tmp` beside the
cache tree, never inside it, because NGINX's cache loader deletes any file
in the tree that does not look like a complete entry.

**Backup** (`cache-backup.sh`) lists entries written since the previous run
from the local disk (`find -newer`; the NFS side is never walked) and copies
them into the archive. `crond` inside the container runs it daily at
`CACHE_BACKUP_TIME` (or weekly on `CACHE_BACKUP_WEEKDAY`). When a service is
scaled to several containers they all share one environment, so each adds a
deterministic per-host offset of up to `CACHE_BACKUP_JITTER_MINUTES` to spread
the NAS load; a `mkdir`-based lock on the archive serialises any that still
overlap (a lock older than `CACHE_LOCK_STALE_MINUTES` is treated as
abandoned). Run it by hand at any time:

```bash
docker exec owlery-cache cache-backup.sh          # entries new since the last run
docker exec owlery-cache cache-backup.sh --full   # consider every local entry
docker exec owlery-cache cache-restore.sh --force # re-pull the archive now
curl -s http://localhost/status | jq .archive     # progress of both
```

Loss window: a container that dies loses whatever it cached since its last
backup (at most one day on the default schedule); everything older is in the
archive and comes back on the next restore.

Warm-up note: the `X-Force-Refresh` warm-up tool only refreshes the instance
that the load balancer routes it to. With several instances, warm one, run
`cache-backup.sh` on it, then let the others pick the entries up on their
next restore (or point the warm-up at each instance in turn).

Variables (all optional):

- `CACHE_ARCHIVE_DIR` (`/cache`), `CACHE_LOCAL_DIR` (`/var/cache/nginx`): the two roots; both hold an `owlery/` tree.
- `CACHE_RESTORE`: `auto` (default; skip if `.restored` exists), `always`, `off`.
- `CACHE_RESTORE_MODE`: `blocking` (default; restore, then start NGINX) or `background` (start NGINX, restore alongside).
- `CACHE_RESTORE_BWLIMIT`, `CACHE_BACKUP_BWLIMIT`: rsync `--bwlimit` in KiB/s (default unlimited).
- `CACHE_RESTORE_MAX_BYTES`: stop the restore after this many bytes of the newest entries (default: whole archive).
- `CACHE_RESTORE_BATCH`, `CACHE_BACKUP_BATCH`: entries per rsync invocation (default 5000).
- `CACHE_BACKUP_SCHEDULE`: `daily` (default), `weekly`, `off`.
- `CACHE_BACKUP_TIME` (`03:00`, container local time), `CACHE_BACKUP_WEEKDAY` (`0` = Sunday).
- `CACHE_BACKUP_JITTER_MINUTES` (`120`); `CACHE_BACKUP_CRON`: a verbatim 5-field crontab spec that overrides the above and gets no jitter.
- `CACHE_BACKUP_LOCK_WAIT` (`120` min), `CACHE_LOCK_STALE_MINUTES` (`360`).

### Selective 404 cache eviction

404 responses are not cached going forward, but a long-lived cache may still
contain 404 entries written before this change. Wiping the whole cache is
expensive, so the image ships with a small helper that finds and deletes
only files whose stored response status is 404:

```bash
# inside a running cache container
docker exec -it owlery-cache purge-cached-404s.sh           # dry run, lists candidates
docker exec -it owlery-cache purge-cached-404s.sh --apply   # delete matching files
```

The script identifies entries by matching the response status line
(`^HTTP/1.x 404 `) inside each cache file; entries with a 200 response that
happens to contain the text "HTTP/1.1 404" elsewhere in the body are not
affected. Files removed from disk are simply treated as `MISS` on the next
request — no nginx reload required. The cache directory is taken from
`$CACHE_DIR` (default `/var/cache/nginx/owlery`). Add `--archive` to walk the
shared archive as well; without it the next restore brings the purged entries
back.

## Performance

- **Cache TTL**: 6 months for successful responses (configurable via `CACHE_STALE_TIME`)
- **Disk retention**: 5 years (`inactive=5y`) — entries are never evicted while disk space allows
- **First request**: ~200ms (backend query)
- **Cached requests**: <10ms (from cache)
- **Cache size**: Up to 20GB on disk (configurable via `CACHE_MAX_SIZE`)
- **Memory usage**: ~100MB for cache metadata

## Technical Details

### Architecture

- **Base image**: nginx:1.26-alpine
- **Cache storage**: `/var/cache/nginx/owlery` with 1:2 directory levels
- **Cache zone**: 100MB in-memory metadata zone
- **Max cache size**: 20GB on disk (configurable via `CACHE_MAX_SIZE` environment variable)
- **Status monitoring**: Background process updates `/var/run/nginx/status.json` from the access log and NGINX `stub_status`
- **Health monitoring**: Background process checks upstream connectivity and logs warnings without taking the cache offline

### Caching Behavior

- **Cache TTL**: 6 months for HTTP 200/400, 10 minutes for 404 (TTL configurable via `CACHE_STALE_TIME`)
- **Always serve stale**: `proxy_cache_use_stale expired updating` — expired entries are served immediately while refreshed in the background (prevents MISSes after TTL)
- **Disk retention**: 5 years — cache files are kept on disk even after TTL expires
- **Retry on errors**: Automatically retries failed requests (502, 503, 504, timeouts) up to 2 times
- **Cache lock**: Prevents stampede with `proxy_cache_lock on`
- **Cache key**: `$request_method$request_uri`
- **Ignores backend headers**: `Cache-Control`, `Expires`, `Set-Cookie`

### Networking

- **Listen ports**: 80 and 8080 (both ports handle requests identically)
- **Status endpoints**: `/health` for liveness, `/status` for JSON metrics, and internal-only `/__nginx_status` for raw NGINX counters
- **DNS resolver**: Configurable via `DNS_RESOLVER` (default: Google Public DNS `8.8.8.8` with 30s TTL for fast upstream IP updates). Check `cat /etc/resolv.conf` in your container for the correct value.
- **Host-agnostic**: Ignores Host header for routing
- **Connection pooling**: 16 keep-alive connections to backend
- **Timeouts**: 90s connect/read/send, 3s for health checks

## Build and Deployment

### Deployment Process

```bash
# Pull image
docker pull virtualflybrain/owl_cache:latest

# Local cache on node disk, and the shared archive (NFS) it syncs with
mkdir -p /data/owl-cache /cache
chown -R 101:101 /data/owl-cache /cache

# Create persistent logs + blocklist file
mkdir -p /logs/hacks
touch /logs/blocked.txt
touch /logs/whitelist.txt

# Deploy with compose
docker-compose up -d

# Verify
curl -I http://localhost/health
```

## Configuration Files

- `Dockerfile`: Image build instructions
- `nginx.conf.template`: NGINX configuration template
- `docker-compose.yml`: Example deployment configuration
- `cache-lib.sh`, `cache-restore.sh`, `cache-backup.sh`: archive ↔ local cache sync (see [Cache archive](#cache-archive)); `test/cache-sync-test.sh` runs at image build
- `.github/workflows/docker.yml`: GitHub Actions CI/CD pipeline

## CI/CD

This repository includes GitHub Actions workflow (`.github/workflows/docker.yml`) that:

- Tests NGINX configuration syntax on every push
- Builds and tests the Docker image
- Pushes to Docker Hub on push to main branch or release

### Required Secrets

Set these in your GitHub repository secrets:

- `DOCKER_HUB_USER`: Your Docker Hub username
- `DOCKER_HUB_PASSWORD`: Your Docker Hub password or access token

## Expected Behavior

- **First Request**: Cache MISS → Query backend (~200ms) → Cache result → Return with X-Cache-Status: MISS
- **Subsequent Requests**: Cache HIT → Return cached result (<10ms) with X-Cache-Status: HIT
- **Expired Cache**: Return stale content immediately with X-Cache-Status: UPDATING + background refresh
- **Backend Errors**: Forward errors to client without caching, allowing retries to succeed
- **Status Reporting**: `/status` shows current hit/miss/total counts from the access log plus sampled connection counters
