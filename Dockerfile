ARG PHP_VERSION=7.4
ARG USER=www-data

### BASE ###
FROM php:${PHP_VERSION}-fpm-alpine as base
ARG USER
ENV USER=${USER} \
    APP_ENV=prod \
    APP_DEBUG=false \
    FPM_PM_MAX_CHILDREN=20 \
    FPM_PM_START_SERVERS=2 \
    FPM_PM_MIN_SPARE_SERVERS=1 \
    FPM_PM_MAX_SPARE_SERVERS=3 \
    FPM_PM_PROCESS_IDLE_TIMEOUT=3 \
    FPM_PM_MAX_REQUESTS=3 \
    NGINX_WORKER_PROCESSES=auto \
    NGINX_WORKER_CONNECTIONS=4096 \
    NGINX_KEEPALIVE_TIMEOUT=65

# Install dependencies
RUN apk add --update --no-cache \
        nginx \
        supervisor

# Prepare PHP
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
    intl \
    opcache \
    && mkdir -p /var/run/php/

# Prepare Nginx
RUN chown -R $USER:$USER /var/www/html/ \
    && rm -rf /usr/share/doc/* /var/www/html/* \
    && rm -f /etc/nginx/sites-enabled/* \
    && mkdir -p /etc/nginx/server-blocks/ \
    && mkdir -p /etc/nginx/site-default/ \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
	&& ln -sf /dev/stderr /var/log/nginx/error.log

# Copy config files
COPY supervisor/supervisor.conf /etc/supervisor/conf.d/supervisor.conf
COPY php/php.ini $PHP_INI_DIR/conf.d/custom-php.ini
COPY php/php-fpm.conf /usr/local/etc/php-fpm.d/zz-docker.conf
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/tune-worker-processes.sh /usr/local/bin/tune-worker-processes.sh
RUN chmod +x /usr/local/bin/tune-worker-processes.sh \
    && mkdir -p /usr/local/bin/docker-entrypoint.d/

WORKDIR /var/www

EXPOSE 80

COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh
HEALTHCHECK --interval=10s --timeout=3s CMD ["healthcheck.sh"]

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]

CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisor.conf", "--nodaemon"]

### DEBUG ###
FROM base as debug
ENV APP_ENV=dev \
    APP_DEBUG=true \
    XDEBUG_MODE=debug
RUN install-php-extensions \
      xdebug
COPY php/php_debug.ini $PHP_INI_DIR/conf.d/custom-php_debug.ini
