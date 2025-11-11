FROM nginx:1.26-alpine

LABEL maintainer="VirtualFlyBrain"
LABEL description="NGINX caching proxy for Owlery"

ARG NGINX_CONF=nginx.conf.template
COPY $NGINX_CONF /etc/nginx/nginx.conf.template

RUN mkdir -p /var/cache/nginx && chown -R nginx:nginx /var/cache/nginx

EXPOSE 80

CMD ["/bin/sh", "-c", "UPSTREAM_SERVER=${UPSTREAM_SERVER:-owl.virtualflybrain.org:80} envsubst '${UPSTREAM_SERVER}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]