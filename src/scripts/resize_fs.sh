#!/bin/bash

DEV=${1:-/dev/sda}

for part in $(ls ${DEV}* | egrep -o '([0-9]+)'); do
  [[ -e ${DEV}${part} ]] && {
    growpart ${DEV} ${part} || true
    case $(lsblk -f ${DEV}${part} | egrep '(ext4|xfs)' | awk '{print $2}') in
      ext4) resize2fs ${DEV}${part};;
      xfs) xfs_growfs -d ${DEV}${part};;
    esac
  }
done
