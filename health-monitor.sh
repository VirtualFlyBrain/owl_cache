#!/bin/sh

# Health monitoring script for upstream server
# Logs warnings but doesn't exit container

UPSTREAM_HOST=$(echo $UPSTREAM_SERVER | cut -d: -f1)
UPSTREAM_PORT=$(echo $UPSTREAM_SERVER | cut -d: -f2)

echo "Monitoring upstream server: $UPSTREAM_HOST:$UPSTREAM_PORT"

while true; do
    if nc -z -w3 $UPSTREAM_HOST $UPSTREAM_PORT 2>/dev/null; then
        echo "$(date): Upstream server is healthy"
    else
        echo "$(date): WARNING - Upstream server $UPSTREAM_HOST:$UPSTREAM_PORT is unreachable"
    fi

    sleep 300  # Check every 5 minutes
done