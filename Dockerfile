FROM nginx:1.26-alpine

LABEL maintainer="VirtualFlyBrain"
LABEL description="NGINX caching proxy for Owlery"

ENV UPSTREAM_SERVER=owl.virtualflybrain.org:80
ENV CACHE_MAX_SIZE=20g
ENV CACHE_STALE_TIME=6M
ENV DNS_RESOLVER=8.8.8.8

ARG NGINX_CONF=nginx.conf.template
COPY $NGINX_CONF /etc/nginx/nginx.conf.template
COPY health-monitor.sh /usr/local/bin/health-monitor.sh

RUN mkdir -p /var/cache/nginx/owlery && chown -R nginx:nginx /var/cache/nginx && \
    chmod +x /usr/local/bin/health-monitor.sh && \
    apk add --no-cache gettext

EXPOSE 80 8080

CMD ["/bin/sh", "-c", "export UPSTREAM_SERVER=$UPSTREAM_SERVER && export CACHE_MAX_SIZE=$CACHE_MAX_SIZE && export CACHE_STALE_TIME=$CACHE_STALE_TIME && export DNS_RESOLVER=\"$DNS_RESOLVER\" && envsubst '${UPSTREAM_SERVER} ${CACHE_MAX_SIZE} ${CACHE_STALE_TIME} ${DNS_RESOLVER}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && /usr/local/bin/health-monitor.sh & nginx -g 'daemon off;'"]