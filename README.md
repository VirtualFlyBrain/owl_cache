# NGINX Caching Proxy for Owlery

[![Docker Image](https://img.shields.io/badge/docker-virtualflybrain%2Fowlery--cache-blue)](https://hub.docker.com/r/virtualflybrain/owlery-cache)

A high-performance caching proxy server that sits in front of OWL reasoning services to dramatically speed up query responses. Built on NGINX Alpine with 90-day cache TTL and stale-while-revalidate pattern.

## Usage Examples

### Basic Usage
```bash
# Start the proxy
docker run -d --name owl-cache -p 80:80 virtualflybrain/owlery-cache:latest

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
    image: virtualflybrain/owlery-cache:latest
    ports:
      - "80:80"
    environment:
      - UPSTREAM_SERVER=owl:8080  # For production with owl service
```

### Health Check
```bash
curl http://localhost/health
# Returns: OK
```

## Configuration

### Environment Variables

- `UPSTREAM_SERVER`: Backend server URL (default: `owl.virtualflybrain.org:80`)

### Cache Headers

The proxy adds helpful headers to responses:

- `X-Cache-Status`: `HIT`, `MISS`, `EXPIRED`, or `STALE`
- `X-Cache-Key`: The cache key used for the request

## Performance

- **Cache TTL**: 90 days for successful responses
- **First request**: ~200ms (backend query)
- **Cached requests**: <10ms (from cache)
- **Cache size**: Up to 20GB on disk
- **Memory usage**: ~100MB for cache metadata

## Docker Hub

📦 **Image**: [`virtualflybrain/owlery-cache`](https://hub.docker.com/r/virtualflybrain/owlery-cache)

Available tags:

- `latest` - Latest stable release
- `1.0.0` - Version 1.0.0

## Overview

This repository contains a custom Docker image based on NGINX Alpine that provides caching proxy functionality for an OWL reasoning server (Owlery). The image is published to Docker Hub and can be deployed across multiple environments.

## Architecture

### Docker Image

- **Base image**: nginx:1.26-alpine
- **Docker Hub**: virtualflybrain/owlery-cache:latest
- **Self-contained**: Requires only volume mount and network configuration at runtime

### Runtime Services

- **owlery-cache**: Custom NGINX image exposing port 80
- **Backend service**: Named "owl" running at `http://owl:8080` (configurable via UPSTREAM_SERVER env var)
- **Network**: Shared Docker network named "owlery_network"

### Networking

- NGINX listens on port 80 for all incoming HTTP requests
- Host-agnostic (accepts requests regardless of Host header)
- All requests proxied to backend at configurable upstream (default: owl.virtualflybrain.org:80) preserving original path and query parameters
- No TLS/HTTPS handling (handled externally upstream)

## Caching Behavior

### Cache Duration

- **Primary TTL**: 90 days (7,776,000 seconds) for HTTP 200 responses
- **404 responses**: 10 minutes
- **Other codes**: 1 hour

### Stale-While-Revalidate Pattern

Implemented using:

- `proxy_cache_use_stale updating`: Serve stale content when cache is being updated
- `proxy_cache_background_update on`: Fetch fresh content asynchronously in background
- `proxy_cache_lock on`: Prevent cache stampede by allowing only one backend request per cache key

### Cache Storage

- **Container path**: /var/cache/nginx/owlery
- **Docker volume**: /cache (persistent across restarts)
- **Levels**: 1:2 (two-level directory hierarchy)
- **Keys zone**: 100MB in-memory zone named "owlery_cache"
- **Max size**: 20GB on disk
- **Inactive timeout**: 90 days
- **use_temp_path**: off (write directly to cache)

### Cache Key Strategy

Cache key: `$request_method$request_uri`

- GET and POST requests cached separately
- Full URI including query parameters creates unique entries
- Host header ignored (host-agnostic)
- Backend cache control headers ignored to ensure caching

## Build and Deployment

### Build Process

```bash
# Build image locally
docker build -t virtualflybrain/owlery-cache:latest .

# Tag with version
docker tag virtualflybrain/owlery-cache:latest virtualflybrain/owlery-cache:1.0.0

# Push to Docker Hub
docker push virtualflybrain/owlery-cache:latest
docker push virtualflybrain/owlery-cache:1.0.0
```

### Deployment Process

```bash
# Pull image
docker pull virtualflybrain/owlery-cache:latest

# Create cache directory
mkdir -p /cache
chown -R 101:101 /cache

# Deploy with compose
docker-compose up -d

# Verify
curl -I http://localhost/health
```

## Testing

### Health Check

```bash
curl -I http://localhost/health
# Should return 200 OK
```

### Cache Testing

Example query to test caching:

```bash
curl "http://localhost/kbs/vfb/instances?object=%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FFBbt_00005106%3E+and+%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FRO_0002131%3E+some+%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FFBbt_00003680%3E&direct=false&includeDeprecated=false"
```

Check the response headers for cache status:

```bash
# First request (cache miss)
curl -I "http://localhost/kbs/vfb/instances?object=%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FFBbt_00005106%3E+and+%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FRO_0002131%3E+some+%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FFBbt_00003680%3E&direct=false&includeDeprecated=false"
# Should show X-Cache-Status: MISS

# Second request (cache hit)
curl -I "http://localhost/kbs/vfb/instances?object=%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FFBbt_00005106%3E+and+%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FRO_0002131%3E+some+%3Chttp%3A%2F%2Fpurl.obolibrary.org%2Fobo%2FFBbt_00003680%3E&direct=false&includeDeprecated=false"
# Should show X-Cache-Status: HIT
```

### Persistence Test

```bash
# Stop container
docker-compose down

# Start again
docker-compose up -d

# Check if cache persists
curl -I http://localhost/some-endpoint
# Should show X-Cache-Status: HIT if cache persisted
```

## Configuration Files

- `Dockerfile`: Image build instructions
- `nginx.conf`: Complete NGINX configuration
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

## Environment Variables

- `UPSTREAM_SERVER`: Backend server URL (default: `owl.virtualflybrain.org:80`)

## Expected Behavior

- **First Request**: Cache MISS → Query backend (~200ms) → Cache result → Return with X-Cache-Status: MISS
- **Subsequent Requests**: Cache HIT → Return cached result (<10ms) with X-Cache-Status: HIT
- **Expired Cache**: Return stale content immediately with X-Cache-Status: UPDATING + background refresh
- **Backend Down**: Serve stale content with X-Cache-Status: STALE until backend recovers
