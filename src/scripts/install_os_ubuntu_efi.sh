#!/bin/bash

set -e

MOUNT_PATH="/mnt"
VERSION=${VERSION:-26.04}

if [ ! -f "/sys/firmware/efi/config_table" ]; then
  echo "EFI Not Detected!"
  echo "Use install_os_ubuntu.sh for BIOS systems"
  exit 1
fi

echo "EFI Detected!"

part_suffix() {
  case "$1" in
    *nvme*) echo "p" ;;
    *) echo "" ;;
  esac
}

printf "\n==> Disk configuration\n\n"

if [ ! -z "$(ls /dev/* | grep '/md')" ]; then
  for md_device in $(ls /dev/md* | grep -E '/dev/md([0-9]+)'); do
    drives=$(mdadm -vQD ${md_device} | grep -oE '/dev/(sd|nvme).*')

    mdadm --stop ${md_device}

    mdadm --zero-superblock ${drives}
  done
fi

DEVICES=()

device_list=$(ls /dev/sd* /dev/nvme* 2>/dev/null | grep -E '/(sd[a-z]{1}|nvme[0-9]+n[0-9]+)$')

if [ ! -z "${DISK_DEV}" ]; then
  device_list=${DISK_DEV}
fi

for device in ${device_list}; do
  suffix=$(part_suffix ${device})

  wipefs --all --force --quiet ${device}

  parted -s ${device} mklabel gpt
  parted -s ${device} --align=optimal mkpart primary fat32 0 128MiB
  parted -s ${device} --align=optimal mkpart primary 128MiB 100%
  parted -s ${device} set 1 esp on

  wipefs --all --force ${device}${suffix}1
  wipefs --all --force ${device}${suffix}2

  partprobe ${device}

  DEVICES+=(${device})
done

echo "Disk Devices: ${#DEVICES[@]} | ${DEVICES[*]}"

DEVICE_PATH=""

if [ "x${#DEVICES[@]}" == "x1" ]; then
  echo "No RAID configured."

  suffix=$(part_suffix ${DEVICES[0]})
  DEVICE_PATH="${DEVICES[0]}${suffix}2"

elif [ "x${#DEVICES[@]}" == "x2" ]; then
  echo "Configuring RAID 1"

  raid_devices=""

  for dev in ${DEVICES[*]}; do
    suffix=$(part_suffix ${dev})
    if [ -b "${dev}${suffix}2" ]; then
      raid_devices="${raid_devices} ${dev}${suffix}2"
    fi
  done

  echo yes |  mdadm --create --quiet --auto=yes /dev/md0 --level=1 --raid-devices=2 ${raid_devices} 2>/dev/null

  DEVICE_PATH="/dev/md0"

elif [ "x${#DEVICES[@]}" == "x4"]; then
  echo "Configuring RAID 10"

  raid_devices=""

  for dev in ${DEVICES[*]}; do
    suffix=$(part_suffix ${dev})
    if [ -b "${dev}${suffix}2" ]; then
      raid_devices="${raid_devices} ${dev}${suffix}2"
    fi
  done

  echo yes |  mdadm --create --quiet --auto=yes /dev/md0 --level=10 --raid-devices=4 ${raid_devices} 2>/dev/null

  DEVICE_PATH="/dev/md0"
fi

printf "\n==> Formating rootfs device\n\n"

mkfs.ext4 -L "rootfs" -F ${DEVICE_PATH}

if [ -z "$(blkid -s LABEL -o value ${DEVICE_PATH})" ]; then
  echo "No root device found"
  exit 1
fi

sleep 2

printf "\n==> Formating EFI system partition\n\n"

esp_suffix=$(part_suffix ${DEVICES[0]})
ESP_DEVICE="${DEVICES[0]}${esp_suffix}1"

mkfs.vfat -n "UEFI" ${ESP_DEVICE}

if [ -z "$(blkid -s LABEL -o value ${ESP_DEVICE})" ]; then
  echo "No EFI system partition found"
  exit 1
fi

sleep 2

printf "\n==> Download OS image\n\n"

FILE_ARCHIVE=""
PKG_EXTRA=""
case ${VERSION} in
  "24.04")
    if [ ! -f "ubuntu-2404-base-amd64.tar.gz" ]; then
      wget -O ubuntu-2404-base-amd64.tar.gz https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz
    fi
    FILE_ARCHIVE="ubuntu-2404-base-amd64.tar.gz"
    PKG_EXTRA="zstd"
    ;;

  "26.04")
    if [ ! -f "ubuntu-2604-base-amd64.tar.gz" ]; then
      wget -O ubuntu-2604-base-amd64.tar.gz https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04-base-amd64.tar.gz
    fi
    FILE_ARCHIVE="ubuntu-2604-base-amd64.tar.gz"
    PKG_EXTRA="zstd"
    ;;

  *)
    echo "Unknown ubuntu version: ${VERSION}"
    exit 1
    ;;
esac

printf "\n==> Extract rootfs\n\n"

mount -t ext4 LABEL=rootfs ${MOUNT_PATH}

tar -xzf ${FILE_ARCHIVE} -C ${MOUNT_PATH}

mkdir -p ${MOUNT_PATH}/boot/efi
mount -t vfat LABEL=UEFI ${MOUNT_PATH}/boot/efi

printf "\n==> Deploing OS\n\n"

mount -t proc /proc ${MOUNT_PATH}/proc
mount --rbind --make-rslave /dev ${MOUNT_PATH}/dev
mount --rbind --make-rslave /proc ${MOUNT_PATH}/proc
mount --rbind --make-rslave /sys ${MOUNT_PATH}/sys

echo 'nameserver 1.1.1.1' > ${MOUNT_PATH}/etc/resolv.conf
echo 'nameserver 8.8.8.8' >> ${MOUNT_PATH}/etc/resolv.conf

pkg_install="linux-image-generic lldpd smartmontools ifenslave vlan thermald usbmuxd upower"

systemd-detect-virt -q && {
  pkg_install="linux-image-virtual qemu-guest-agent haveged"
}

for dev in ${DEVICES[*]}; do
  case ${dev} in
    /dev/nvme*)
      pkg_install="${pkg_install} nvme-cli"
      break
      ;;
  esac
done

cat <<EOF>${MOUNT_PATH}/sysinstall.sh
#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

apt update -qy
apt upgrade -qy

if [ -f "/usr/local/sbin/unminimize" ]; then
  echo y | /usr/local/sbin/unminimize
  rm /usr/local/sbin/unminimize
fi

apt install -qy --no-install-recommends ${pkg_install} ${PKG_EXTRA} grub-common grub-efi-amd64 grub-efi-amd64-signed secureboot-db os-prober efibootmgr systemd initramfs-tools \
	dbus-user-session systemd-sysv init init-system-helpers lsb-release isc-dhcp-client mdadm cron ca-certificates dosfstools \
	ifupdown ethtool iputils-ping net-tools openssh-server iproute2 vim util-linux locales less wget curl dnsutils chrony \
	rsyslog bash-completion

locale-gen en_US.UTF-8

cat <<EOD>/etc/fstab
LABEL=rootfs	/	ext4	defaults,discard,errors=remount-ro	0 1
LABEL=UEFI	/boot/efi	vfat	umask=0077	0 1
EOD

systemd-machine-id-setup --commit

sed -ie 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="text net.ifnames=0 consoleblank=0 systemd.show_status=true panic=20"/g' /etc/default/grub
sed -ie 's/#GRUB_TERMINAL/GRUB_TERMINAL/g' /etc/default/grub
sed -ir 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/g' /etc/default/grub
sed -ir 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/g' /etc/default/grub
sed -ie 's/#GRUB_GFXMODE=.*/GRUB_GFXMODE=1280x800/g' /etc/default/grub

systemctl enable multi-user.target --force
systemctl set-default multi-user.target

update-initramfs -u

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=grub

update-grub

echo -e "root123\nroot123" | passwd root

cat <<EOD>/etc/network/interfaces.d/default
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOD

cat <<EOD>/etc/hosts
127.0.0.1 localhost
#127.0.1.1 server-name

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOD

mkdir -p /root/.ssh/
chmod 700 /root/.ssh/

wget -q -O /root/.ssh/authorized_keys https://github.com/vitalvas.keys
chmod 600 /root/.ssh/authorized_keys

systemctl enable ssh.service

cat <<EOD>/etc/systemd/system/firstboot.service
[Unit]
Description=First time boot script
After=network.target
ConditionFileNotEmpty=/boot/firstboot.sh

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/bin/bash /boot/firstboot.sh
ExecStartPost=/usr/bin/systemctl disable firstboot.service

[Install]
WantedBy=multi-user.target
EOD

systemctl enable firstboot.service

EOF

chroot ${MOUNT_PATH} /bin/bash /sysinstall.sh >> ${MOUNT_PATH}/install.log 2>&1

rm ${MOUNT_PATH}/sysinstall.sh
rm ${MOUNT_PATH}/install.log
