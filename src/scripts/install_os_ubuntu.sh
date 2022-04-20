#!/bin/bash

set -e

MOUNT_PATH="/mnt"

if [ -f "/sys/firmware/efi/config_table" ]; then
  echo "EFI Detected!"
  echo "Unsupprted!"
  exit 1
fi

printf "\n==> Disk configuration\n\n"

if [ ! -z "$(ls /dev/* | grep '/md')" ]; then
  for md_device in $(ls /dev/md* | egrep '/dev/md([0-9]+)'); do
    drives=$(mdadm -vQD ${md_device} | grep -o '/dev/sd.*')

    mdadm --stop ${md_device}

    mdadm --zero-superblock ${drives}
  done
fi

DEVICES=()

device_list=$(ls /dev/sd* | egrep '/sd([a-z]{1})$')

if [ ! -z "${DISK_DEV}" ]; then
  device_list=${DISK_DEV}  
fi

for device in ${device_list}; do
  wipefs --all --force --quiet ${device}

  parted -s ${device} mklabel gpt
  parted -s ${device} mkpart primary 1 2
  parted -s ${device} mkpart primary 2 100%
  parted -s ${device} set 1 bios_grub on

  wipefs --all --force ${device}1
  wipefs --all --force ${device}2

  partprobe ${device}

  DEVICES+=(${device})
done

echo "Disk Devices: ${#DEVICES[@]} | ${DEVICES[*]}"

DEVICE_PATH=""

if [ "x${#DEVICES[@]}" == "x1" ]; then
  echo "No RAID configured."

  DEVICE_PATH="/dev/sda2"

elif [ "x${#DEVICES[@]}" == "x2" ]; then
  echo "Configuring RAID 1"

  raid_devices=""

  for dev in ${DEVICES[*]}; do
    if [ -b "${dev}2" ]; then
      raid_devices="${raid_devices} ${dev}2"
    fi
  done

  echo yes |  mdadm --create --quiet --auto=yes /dev/md0 --level=1 --raid-devices=2 ${raid_devices} 2>/dev/null

  DEVICE_PATH="/dev/md0"

elif [ "x${#DEVICES[@]}" == "x4"]; then
  echo "Configuring RAID 10"

  raid_devices=""

  for dev in ${DEVICES[*]}; do
    if [ -b "${dev}2" ]; then
      raid_devices="${raid_devices} ${dev}2"
    fi
  done

  echo yes |  mdadm --create --quiet --auto=yes /dev/md0 --level=10 --raid-devices=4 ${raid_devices} 2>/dev/null

  DEVICE_PATH="/dev/md0"
fi


printf "\n==> Formating rootfs device\n\n"

mkfs.ext4 -F ${DEVICE_PATH}

DEVICE_UUID=$(blkid -s UUID -o value ${DEVICE_PATH})

DEVICE_UUID_PATH="/dev/disk/by-uuid/${DEVICE_UUID}"

if [ -z "${DEVICE_UUID}" ]; then
  echo "No root device found"
  exit 1
fi

sleep 2

printf "\n==> Download OS image\n\n"

if [ ! -f "ubuntu-2004-base-amd64.tar.gz" ]; then
  wget -O ubuntu-2004-base-amd64.tar.gz http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.1-base-amd64.tar.gz
fi


printf "\n==> Extract rootfs\n\n"

mount -t ext4 ${DEVICE_UUID_PATH} ${MOUNT_PATH}

tar -xzf ubuntu-2004-base-amd64.tar.gz -C ${MOUNT_PATH}


printf "\n==> Deploing OS\n\n"

mount -t proc /proc ${MOUNT_PATH}/proc
mount --rbind --make-rslave /dev ${MOUNT_PATH}/dev
mount --rbind --make-rslave /proc ${MOUNT_PATH}/proc
mount --rbind --make-rslave /sys ${MOUNT_PATH}/sys

echo 'nameserver 1.1.1.1' > ${MOUNT_PATH}/etc/resolv.conf
echo 'nameserver 8.8.8.8' >> ${MOUNT_PATH}/etc/resolv.conf

pkg_install="linux-image-generic lldpd smartmontools"

systemd-detect-virt -q && {
  pkg_install="linux-image-virtual qemu-guest-agent haveged cloud-guest-utils"
}

cat <<EOF>${MOUNT_PATH}/sysinstall.sh
#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

apt update -qy
apt upgrade -qy

if [ -f "/usr/local/sbin/unminimize" ]; then
  echo y | /usr/local/sbin/unminimize
  rm /usr/local/sbin/unminimize
fi

apt install -qy --no-install-recommends ${pkg_install} grub-common grub-efi-amd64 grub-pc-bin systemd initramfs-tools \
	dbus-user-session systemd-sysv init init-system-helpers lsb-release isc-dhcp-client mdadm cron \
	ifupdown ethtool iputils-ping net-tools openssh-server iproute2 vim util-linux locales less wget curl dnsutils ntp \
	rsyslog bash-completion

locale-gen en_US.UTF-8

echo -e "${DEVICE_UUID_PATH}\t/\text4\tdefaults\t0\t1" > /etc/fstab

systemd-machine-id-setup --commit

sed -ie 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="text net.ifnames=0 consoleblank=0 systemd.show_status=true panic=20"/g' /etc/default/grub
sed -ie 's/#GRUB_TERMINAL/GRUB_TERMINAL/g' /etc/default/grub
sed -ir 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/g' /etc/default/grub
sed -ir 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/g' /etc/default/grub
sed -ie 's/#GRUB_GFXMODE=.*/GRUB_GFXMODE=1280x800/g' /etc/default/grub

systemctl enable multi-user.target --force
systemctl set-default multi-user.target

update-initramfs -u

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

EOF

chroot ${MOUNT_PATH} /bin/bash /sysinstall.sh >> ${MOUNT_PATH}/install.log 2>&1

for dev in ${DEVICES[*]}; do
  chroot ${MOUNT_PATH} /usr/sbin/grub-install ${dev} >> ${MOUNT_PATH}/install.log 2>&1
done

rm ${MOUNT_PATH}/sysinstall.sh

