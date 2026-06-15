FROM nginx:1.26-alpine

LABEL maintainer="VirtualFlyBrain"
LABEL description="NGINX caching proxy for Owlery"

ENV UPSTREAM_SERVER=owl.virtualflybrain.org:80
ENV CACHE_MAX_SIZE=20g
ENV CACHE_STALE_TIME=6M
ENV DNS_RESOLVER=8.8.8.8
ENV WORKER_PROCESSES=auto
ENV WORKER_CONNECTIONS=4096
ENV WORKER_RLIMIT_NOFILE=65535

ARG NGINX_CONF=nginx.conf.template
COPY $NGINX_CONF /etc/nginx/nginx.conf.template
COPY health-monitor.sh /usr/local/bin/health-monitor.sh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY purge-cached-404s.sh /usr/local/bin/purge-cached-404s.sh

RUN mkdir -p /var/cache/nginx/owlery /logs/hacks && \
    touch /logs/blocked.txt /logs/whitelist.txt /etc/nginx/blocked-ips.map /etc/nginx/whitelisted-ips.map /etc/nginx/whitelisted-cidrs.map && \
    chown -R nginx:nginx /var/cache/nginx /logs && \
    chmod +x /usr/local/bin/health-monitor.sh /usr/local/bin/docker-entrypoint.sh /usr/local/bin/purge-cached-404s.sh && \
    apk add --no-cache gettext

EXPOSE 80 8080

VOLUME ["/var/cache/nginx", "/logs"]

CMD ["/usr/local/bin/docker-entrypoint.sh"]
