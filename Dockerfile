ARG PHP_VERSION=7.4

### BASE ###
FROM php:${PHP_VERSION}-fpm as base

ENV USER=www-data \
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
RUN apt-get update \
    && apt-get -y --no-install-recommends --no-install-suggests install \
        libfcgi0ldbl \
        nginx \
        supervisor \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install PHP extensions
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
    intl \
    opcache \
    && mkdir -p /var/run/php/

# Prepare Nginx
RUN chown -R $USER:$USER /var/www/html/ \
    && rm -rf /usr/share/doc/* /var/www/html/* \
    && rm -f /etc/nginx/sites-enabled/*

# Copy config files
COPY supervisor/supervisor.conf /etc/supervisor/conf.d/supervisor.conf
COPY php/php.ini $PHP_INI_DIR/conf.d/custom-php.ini
COPY php/php-fpm.conf /usr/local/etc/php-fpm.d/zz-docker.conf
COPY nginx/nginx.conf /etc/nginx/nginx.conf

WORKDIR /var/www

EXPOSE 80

COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["healthcheck.sh"]

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]

CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisor.conf", "--nodaemon"]

### DEV ###
FROM base as dev
ENV APP_ENV=dev \
    APP_DEBUG=true \
    XDEBUG_MODE=debug
RUN install-php-extensions \
    xdebug
COPY php/php_dev.ini $PHP_INI_DIR/conf.d/custom-php_dev.ini
