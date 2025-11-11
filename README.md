# NGINX Caching Proxy for Owlery

[![Docker Image](https://img.shields.io/badge/docker-virtualflybrain%2Fowl_cache-blue)](https://hub.docker.com/r/virtualflybrain/owl_cache)

A high-performance caching proxy server that sits in front of OWL reasoning services to dramatically speed up query responses. Built on NGINX Alpine with 90-day cache TTL and stale-while-revalidate pattern.

## Usage Examples

### Basic Usage

```bash
# Start the proxy
docker run -d --name owl-cache -p 80:80 virtualflybrain/owl_cache:latest

# Make a query (will be slow first time)
curl "http://localhost/kbs/vfb/instances?object=<http://purl.obolibrary.org/obo/FBbt_00005106>"

# Same query again (will be fast from cache)
curl "http://localhost/kbs/vfb/instances?object=<http://purl.obolibrary.org/obo/FBbt_00005106>"
```

### With Docker Compose

```yaml
version: '3.8'
services:
  owl-cache:
    image: virtualflybrain/owl_cache:latest
    ports:
      - "80:80"
    environment:
      - UPSTREAM_SERVER=owl:8080  # For production with owl service
      - CACHE_MAX_SIZE=1000g      # 1TB cache size for high-traffic deployments
```

### Health Check

```bash
curl http://localhost/health
# Returns: OK
```

## Configuration

### Environment Variables

- `UPSTREAM_SERVER`: Backend server URL (default: `owl.virtualflybrain.org:80`)
- `CACHE_MAX_SIZE`: Maximum cache size on disk (default: `20g`, accepts NGINX size units: `k`/`K` kilobytes, `m`/`M` megabytes, `g`/`G` gigabytes)

### Cache Headers

The proxy adds helpful headers to responses:

- `X-Cache-Status`: `HIT`, `MISS`, `EXPIRED`, or `STALE`
- `X-Cache-Key`: The cache key used for the request

## Performance

- **Cache TTL**: 90 days for successful responses
- **First request**: ~200ms (backend query)
- **Cached requests**: <10ms (from cache)
- **Cache size**: Up to 20GB on disk (configurable via `CACHE_MAX_SIZE`)
- **Memory usage**: ~100MB for cache metadata

## Technical Details

### Architecture

- **Base image**: nginx:1.26-alpine
- **Cache storage**: `/var/cache/nginx/owlery` with 1:2 directory levels
- **Cache zone**: 100MB in-memory metadata zone
- **Max cache size**: 20GB on disk (configurable via `CACHE_MAX_SIZE` environment variable, supports k/K, m/M, g/G units)

### Caching Behavior

- **Cache TTL**: 90 days for HTTP 200, 10 minutes for 404, 1 hour for others
- **Stale-while-revalidate**: `proxy_cache_use_stale updating` + `proxy_cache_background_update on`
- **Retry on errors**: Automatically retries failed requests (502, 503, 504, timeouts) up to 2 times
- **Cache lock**: Prevents stampede with `proxy_cache_lock on`
- **Cache key**: `$request_method$request_uri`
- **Ignores backend headers**: `Cache-Control`, `Expires`, `Set-Cookie`

### Networking

- **Listen port**: 80
- **Host-agnostic**: Ignores Host header for routing
- **Connection pooling**: 16 keep-alive connections to backend
- **Timeouts**: 90s connect/read/send

## Build and Deployment

### Deployment Process

```bash
# Pull image
docker pull virtualflybrain/owl_cache:latest

# Create cache directory
mkdir -p /cache
chown -R 101:101 /cache

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
- **Backend Down**: Serve stale content with X-Cache-Status: STALE until backend recovers
