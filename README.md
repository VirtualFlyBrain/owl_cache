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
      - /cache:/var/cache/nginx
      - /logs:/logs
    environment:
      - UPSTREAM_SERVER=owl:8080  # For production with owl service
      - CACHE_MAX_SIZE=1t         # 1TB cache size for high-traffic deployments
      - DNS_RESOLVER=169.254.169.250  # Rancher internal DNS (check /etc/resolv.conf)
```

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

### Security Filtering and Blocking

- **Probe filtering**: Requests matching common probing signatures (for example `*.php`, `wp-login.php`, `xmlrpc.php`, `wlwmanifest.xml`, `.env`, `phpmyadmin`, path traversal payloads) are immediately refused with HTTP `403` and are **not** forwarded upstream.
- **Probe log output**: Refused probe requests are logged to `/logs/hacks/probes.log`, including both raw `X-Forwarded-For` and the extracted left-most client IP.
- **Manual IP blocklist**: Add one IPv4/IPv6 address per line in `/logs/blocked.txt` (comments allowed with `#`).
- **Manual IP whitelist**: Add one IPv4/IPv6 address per line in `/logs/whitelist.txt` (comments allowed with `#`).

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
```

Blocked IP requests return HTTP `403` and are logged to `/logs/hacks/blocked.log`.

Whitelist entries take precedence over both the blocklist and probe filter.

Blocklist/whitelist entries are loaded when the container starts. If you update `/logs/blocked.txt` or `/logs/whitelist.txt`, restart the container to apply changes.

### Cache Headers

The proxy adds helpful headers to responses:

- `X-Cache-Status`: `HIT`, `MISS`, `EXPIRED`, `STALE`, `UPDATING`, or `REVALIDATED`
- `X-Cache-Key`: The cache key used for the request

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

# Create cache directory
mkdir -p /cache
chown -R 101:101 /cache

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
