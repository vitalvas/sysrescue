#!/bin/bash

set -x -e -o pipefail

export DEBIAN_FRONTEND=noninteractive

ROOT_PASSWD="root123"

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

export DEBIAN_FRONTEND=noninteractive

apt install -y --no-install-recommends \
    apt-transport-https \
    avahi-daemon \
    casper \
    chrony \
    cloud-utils \
    curl \
    discover \
    git \
    grub-common \
    grub-gfxpayload-lists \
    grub-pc \
    grub-pc-bin \
    grub2-common \
    ifupdown \
    iperf3 \
    ipmitool \
    ipmiutil \
    iproute2 \
    iputils-ping \
    isc-dhcp-client \
    less \
    linux-generic \
    lldpd \
    locales \
    lvm2 \
    mdadm \
    nano \
    net-tools \
    netplan.io \
    nmap \
    nvme-cli \
    openssh-server \
    openvpn \
    os-prober \
    screen \
    smartmontools \
    sudo \
    tcpdump \
    tmux \
    ubuntu-standard \
    vim \
    vlan \
    wget \
    wireguard \
    wireguard-tools \
    wireless-tools \
    wpasupplicant \
    xfsdump \
    xfsprogs


apt purge -qy ubuntu-pro-client ubuntu-pro-client-l10n linux-headers-generic libllvm16t64
dpkg -l | awk '$2~"linux-headers" {print $2}' | xargs apt purge -qy

apt-get autoremove -y
dpkg-reconfigure locales

echo -e "${ROOT_PASSWD}\n${ROOT_PASSWD}" | passwd root

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

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOL> /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOL

cat <<EOL> /etc/modules-load.d/live.conf
ipmi_devintf
bonding
EOL

mkdir -p /etc/avahi/services/
cat <<EOL> /etc/avahi/services/ssh.service
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_ssh._tcp</type>
    <port>22</port>
  </service>
</service-group>
EOL

cat <<EOL> /etc/systemd/system/firstboot.service
[Unit]
Description=First boot script

[Service]
Type=oneshot
ExecStart=/opt/sysrescue/bin/firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

mkdir -p /opt/sysrescue/bin
cat <<EOL> /opt/sysrescue/bin/firstboot.sh
#!/bin/bash

set -x -e

ssh-keygen -A

EOL

systemctl enable ssh.service
systemctl enable lldpd.service
systemctl enable chrony.service
systemctl enable avahi-daemon.service
systemctl enable firstboot.service

apt-get clean
rm -rf /tmp/* ~/.bash_history
rm -rf /etc/ssh/ssh_host_*
umount /proc
umount /sys
umount /dev/pts
export HISTSIZE=0
EOF

for row in $(grep "${BUILDHOME}/chroot" /proc/mounts | cut -f2 -d ' ' | sort -r); do
  umount -l ${row}
done

rm -Rf ${BUILDHOME}/image

mkdir -p ${BUILDHOME}/image/{casper,isolinux,install}
cp ${BUILDHOME}/chroot/boot/vmlinuz-**-**-generic ${BUILDHOME}/image/casper/vmlinuz
cp ${BUILDHOME}/chroot/boot/initrd.img-**-**-generic ${BUILDHOME}/image/casper/initrd

touch ${BUILDHOME}/image/ubuntu

DEFAULT_KERNEL_PARAM="nopersistent noprompt consoleblank=0 systemd.show_status=true panic=20 hostname=sysrescue build=${BUILDNAME}"

cat <<EOF > ${BUILDHOME}/image/isolinux/grub.cfg
search --set=root --file /ubuntu

insmod efi_gop
insmod efi_uga
insmod all_video
insmod videotest
insmod videoinfo

set default="0"
set timeout=30

menuentry "${BUILDNAME} - default options" {
   set gfxpayload=keep
   linux /casper/vmlinuz boot=casper ${DEFAULT_KERNEL_PARAM} ---
   initrd /casper/initrd
}

menuentry "${BUILDNAME} - copy system to RAM (copytoram)" {
   set gfxpayload=keep
   linux /casper/vmlinuz boot=casper ${DEFAULT_KERNEL_PARAM} toram ---
   initrd /casper/initrd
}

menuentry "${BUILDNAME} - basic display drivers (nomodeset)" {
   set gfxpayload=keep
   linux /casper/vmlinuz boot=casper ${DEFAULT_KERNEL_PARAM} nomodeset ---
   initrd /casper/initrd
}

menuentry 'Start EFI Shell' {
    insmod fat
    insmod chain
    terminal_output console
    chainloader /EFI/shell.efi
}

menuentry 'EFI Firmware setup' {
    fwsetup
}

menuentry 'Reboot' {
    reboot
}

menuentry 'Power off' {
    halt
}
EOF

chroot ${BUILDHOME}/chroot dpkg-query -W --showformat='${Package} ${Version}\n' | tee ${BUILDHOME}/image/casper/filesystem.manifest

if [ -f "${BUILDHOME}/image/casper/filesystem.squashfs" ]; then
    rm ${BUILDHOME}/image/casper/filesystem.squashfs
fi

mksquashfs ${BUILDHOME}/chroot ${BUILDHOME}/image/casper/filesystem.squashfs -comp zstd -b 256k -always-use-fragments -no-recovery -noappend

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

if [ -f "${BUILDHOME}/${BUILDNAME}.iso" ]; then
    rm ${BUILDHOME}/${BUILDNAME}.iso
fi

xorriso \
    -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "Ubuntu ${BUILDNAME}" \
    -output "${BUILDHOME}/${BUILDNAME}.iso" \
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
