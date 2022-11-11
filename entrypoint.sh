#!/bin/sh

set -e

if [ "$1" = "supervisord" ]; then
  # Setup Nginx config
  nginx_config_file=/etc/nginx/nginx.conf
  perl -p -i -e "s/<user>/${USER}/g" "$nginx_config_file"
  perl -p -i -e "s/<nginx_worker_connections>/${NGINX_WORKER_CONNECTIONS}/g" "$nginx_config_file"
  perl -p -i -e "s/<nginx_keepalive_timeout>/${NGINX_KEEPALIVE_TIMEOUT}/g" "$nginx_config_file"

  if [ "$NGINX_WORKER_PROCESSES" = "auto" ]; then
    tune-worker-processes.sh
  else
    perl -p -i -e "s/<nginx_worker_processes>/${NGINX_WORKER_PROCESSES}/g" "$nginx_config_file"
  fi

  # Setup PHP config
  perl -p -i -e "s/<user>/${USER}/g" "$PHP_INI_DIR/conf.d/custom-php.ini"

  # Setup PHP-FPM config
  phpfpm_config_file=/usr/local/etc/php-fpm.d/zz-docker.conf
  perl -p -i -e "s/<user>/${USER}/g" "$phpfpm_config_file"
  perl -p -i -e "s/<fpm_pm_max_children>/${FPM_PM_MAX_CHILDREN}/g" "$phpfpm_config_file"
  perl -p -i -e "s/<fpm_pm_start_servers>/${FPM_PM_START_SERVERS}/g" "$phpfpm_config_file"
  perl -p -i -e "s/<fpm_pm_min_spare_servers>/${FPM_PM_MIN_SPARE_SERVERS}/g" "$phpfpm_config_file"
  perl -p -i -e "s/<fpm_pm_max_spare_servers>/${FPM_PM_MAX_SPARE_SERVERS}/g" "$phpfpm_config_file"
  perl -p -i -e "s/<fpm_pm_max_requests>/${FPM_PM_MAX_REQUESTS}/g" "$phpfpm_config_file"
  perl -p -i -e "s/<fpm_pm_process_idle_timeout>/${FPM_PM_PROCESS_IDLE_TIMEOUT}/g" "$phpfpm_config_file"

  # Execute preseed scripts
  mkdir -p /usr/local/bin/preseed/
  for script in $(find /usr/local/bin/preseed/ -type f | sort 2>/dev/null); do
    echo "=> Executing preseed ${script}"
    ${script}
    if [ $? -ne 0 ]; then
      exit 1
    fi
  done
fi

exec "$@"
