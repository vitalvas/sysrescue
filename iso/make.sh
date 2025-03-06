#!/bin/bash

set -x -e -o pipefail

export DEBIAN_FRONTEND=noninteractive

BUILDROOT=/media
BUILDNAME="sysrescue-$(date +'%Y%m%d-%H%M')"
export BUILDHOME="${BUILDROOT}/${BUILDNAME}"

apt update
apt install -qy binutils debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools

if [ ! -d "${BUILDHOME}/chroot/bin" ]; then
    debootstrap --arch=amd64 --variant=minbase noble \
        ${BUILDHOME}/chroot \
        http://us.archive.ubuntu.com/ubuntu/
fi

chroot ${BUILDHOME}/chroot /bin/bash -x <<'EOF'
export LC_ALL=C
mount none -t proc /proc
mount none -t sysfs /sys
mount none -t devpts /dev/pts
export HOME=/root

echo "${BUILDNAME}" > /etc/hostname

cat <<EOL > /etc/apt/sources.list
deb http://us.archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
deb http://us.archive.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
deb http://us.archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
EOL

apt update -qy
apt upgrade -qy

apt install -qy systemd-sysv

dbus-uuidgen > /etc/machine-id
ln -fs /etc/machine-id /var/lib/dbus/machine-id

dpkg-divert --local --rename --add /sbin/initctl
ln -s /bin/true /sbin/initctl

apt install -y \
    sudo ubuntu-standard casper discover os-prober net-tools wireless-tools locales \
    grub-common grub-gfxpayload-lists grub-pc grub-pc-bin grub2-common iproute2 \
    openssh-server apt-transport-https wget curl vim nano lldpd mdadm cloud-utils \
    less smartmontools iperf3 iputils-ping nmap vlan git tcpdump chrony \
    netplan.io wpasupplicant wireguard wireguard-tools ifupdown isc-dhcp-client openvpn \
    hashcat ipmitool ipmiutil screen tmux

apt install -y --no-install-recommends linux-generic

apt purge -qy ubuntu-pro-client ubuntu-pro-client-l10n linux-headers-generic
dpkg -l | awk '$2~"linux-headers" {print $2}' | xargs apt purge -qy

apt-get autoremove -y
dpkg-reconfigure locales

cat <<EOL> /etc/netplan/10-init.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    all:
      match:
        name: en*
      dhcp4: yes
      dhcp6: yes
EOL

chmod 600 /etc/netplan/10-init.yaml

systemctl enable ssh.service

mkdir -p /root/.ssh
chmod 700 /root/.ssh/

wget https://github.com/vitalvas.keys -O /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

cat <<EOL> /etc/ssh/sshd_config.d/live.conf
PasswordAuthentication no
UseDNS no
EOL

truncate -s 0 /etc/machine-id
rm /sbin/initctl
dpkg-divert --rename --remove /sbin/initctl

apt-get clean
rm -rf /tmp/* ~/.bash_history
umount /proc
umount /sys
umount /dev/pts
export HISTSIZE=0
EOF


rm -Rf ${BUILDHOME}/image

mkdir -p ${BUILDHOME}/image/{casper,isolinux,install}
cp ${BUILDHOME}/chroot/boot/vmlinuz-**-**-generic ${BUILDHOME}/image/casper/vmlinuz
cp ${BUILDHOME}/chroot/boot/initrd.img-**-**-generic ${BUILDHOME}/image/casper/initrd

touch ${BUILDHOME}/image/ubuntu

cat <<EOF > ${BUILDHOME}/image/isolinux/grub.cfg
search --set=root --file /ubuntu

insmod all_video

set default="0"
set timeout=10

menuentry "Ubuntu ${BUILDNAME}" {
   linux /casper/vmlinuz boot=casper nopersistent toram hostname=${BUILDNAME} ---
   initrd /casper/initrd
}
EOF

chroot ${BUILDHOME}/chroot dpkg-query -W --showformat='${Package} ${Version}\n' | tee ${BUILDHOME}/image/casper/filesystem.manifest

if [ -f "${BUILDHOME}/image/casper/filesystem.squashfs" ]; then
    rm ${BUILDHOME}/image/casper/filesystem.squashfs
fi

mksquashfs ${BUILDHOME}/chroot ${BUILDHOME}/image/casper/filesystem.squashfs -comp zstd -b 256k -always-use-fragments -no-recovery

cd ${BUILDHOME}

printf $(du -sx --block-size=1 chroot | cut -f1) > ${BUILDHOME}/image/casper/filesystem.size

cat <<EOF > ${BUILDHOME}/image/README.diskdefines
#define DISKNAME  Ubuntu ${BUILDNAME}
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  amd64
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF

cd ${BUILDHOME}/image

grub-mkstandalone \
   --format=x86_64-efi \
   --output=isolinux/bootx64.efi \
   --locales="" \
   --fonts="" \
   "boot/grub/grub.cfg=isolinux/grub.cfg"

(
    cd ${BUILDHOME}/image/isolinux && \
    dd if=/dev/zero of=efiboot.img bs=1M count=10 && \
    mkfs.vfat efiboot.img && \
    LC_CTYPE=C mmd -i efiboot.img efi efi/boot && \
    LC_CTYPE=C mcopy -i efiboot.img ./bootx64.efi ::efi/boot/
)

grub-mkstandalone \
    --format=i386-pc \
    --output=isolinux/core.img \
    --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
    --modules="linux16 linux normal iso9660 biosdisk search" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=isolinux/grub.cfg"

cat /usr/lib/grub/i386-pc/cdboot.img ${BUILDHOME}/image/isolinux/core.img > ${BUILDHOME}/image/isolinux/bios.img

/bin/bash -c "(find . -type f -print0 | xargs -0 md5sum | grep -v -e 'md5sum.txt' -e 'bios.img' -e 'efiboot.img' > ${BUILDHOME}/image/md5sum.txt)"

if [ -f "${BUILDHOME}/ubuntu-${BUILDNAME}.iso" ]; then
    rm ${BUILDHOME}/ubuntu-${BUILDNAME}.iso
fi

xorriso \
    -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "Ubuntu ${BUILDNAME}" \
    -output "${BUILDHOME}/ubuntu-${BUILDNAME}.iso" \
    -eltorito-boot boot/grub/bios.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --eltorito-catalog boot/grub/boot.cat \
    --grub2-boot-info \
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot \
    -e EFI/efiboot.img \
    -no-emul-boot \
    -append_partition 2 0xef isolinux/efiboot.img \
    -m "isolinux/efiboot.img" \
    -m "isolinux/bios.img" \
    -graft-points \
    "/EFI/efiboot.img=isolinux/efiboot.img" \
    "/boot/grub/bios.img=isolinux/bios.img" \
    "."
