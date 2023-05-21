#!/bin/bash

set -e

# Install deps: apt install -qy tar zstd

if [ -f "/etc/lsb-release" ]; then
  which tar >/dev/null || apt install -qy tar
  which zstd >/dev/null || apt install -qy zstd
fi

ARCHIVE_PATHS=(
  /etc
  /opt
  /srv
  /media
  /home
  /root
  /var/backups
  /var/www
  /var/spool
  /var/lib
  /usr/local/bin
  /usr/local/sbin
  /usr/local/openresty/nginx/conf
)

HOSTNAME=$(hostname -f)

if [ -e "/usr/bin/dpkg" ]; then
  /usr/bin/dpkg --get-selections > /var/backups/dpkg-get-selections.txt
  /usr/bin/dpkg --list > /var/backups/dpkg-list.txt
fi

for path in $(ls /usr/src/ | grep -v 'linux-headers'); do
  ARCHIVE_PATHS+=("/usr/src/${path}")
done

current_archive_paths=""

for path in ${ARCHIVE_PATHS[*]}; do
  if [ -d "${path}" ]; then
    current_archive_paths="${current_archive_paths} ${path}"
  fi
done

filename=${HOSTNAME}-$(date +"%Y-%m-%d").tar

if [ -f "/${filename}" ]; then
  rm /${filename}
fi

tar -cf /${filename} ${current_archive_paths}
zstd --rm -19 /${filename}

