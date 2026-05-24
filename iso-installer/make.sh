#!/bin/bash

# Builds a Debian 13 (trixie) installer ISO from scratch.
# All packages are included for air-gap installation.
# No pre-built ISO required - everything is fetched from the Debian archive.
#
# Runs inside a Docker container. Use build.sh to invoke.

set -e -o pipefail

export DEBIAN_FRONTEND=noninteractive

DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_SUITE="trixie"

BUILDROOT="/tmp/build"
BUILDNAME="debian-installer-$(date +'%Y%m%d-%H%M')"
BUILDHOME="${BUILDROOT}/${BUILDNAME}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="/output"

EXTRA_PACKAGES="openssh-server chrony curl sudo nano less"

echo "=== Building ${BUILDNAME} ==="
mkdir -p "${BUILDHOME}"

# Step 1: Create ISO directory structure
echo "=== Creating ISO structure ==="
ISO_WORK="${BUILDHOME}/iso-work"
mkdir -p "${ISO_WORK}"/{.disk,install.amd,isolinux,boot/grub,pool/main}
mkdir -p "${ISO_WORK}/dists/${DEBIAN_SUITE}/main/binary-amd64"
mkdir -p "${ISO_WORK}/dists/${DEBIAN_SUITE}/main/debian-installer/binary-amd64"

echo "Debian GNU/Linux ${DEBIAN_SUITE} - Custom amd64" > "${ISO_WORK}/.disk/info"
touch "${ISO_WORK}/.disk/base_installable"
touch "${ISO_WORK}/debian"

# Step 2: Download debian-installer boot files
echo "=== Downloading debian-installer boot files ==="
DI_BASE="${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/main/installer-amd64/current/images/cdrom"

wget -q -O "${ISO_WORK}/install.amd/vmlinuz" "${DI_BASE}/vmlinuz"
wget -q -O "${ISO_WORK}/install.amd/initrd.gz" "${DI_BASE}/initrd.gz"

echo "Downloaded d-i kernel and initrd"

# Step 3: Download d-i udeb packages
echo "=== Downloading d-i udeb packages ==="
DI_PACKAGES_URL="${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/main/debian-installer/binary-amd64/Packages.gz"
UDEBS_WORK="${BUILDHOME}/udebs"
mkdir -p "${UDEBS_WORK}"

wget -q -O "${UDEBS_WORK}/Packages.gz" "${DI_PACKAGES_URL}"
gunzip -kf "${UDEBS_WORK}/Packages.gz"

grep "^Filename: " "${UDEBS_WORK}/Packages" | awk '{print $2}' | while read -r filepath; do
    target_dir="${ISO_WORK}/$(dirname "${filepath}")"
    mkdir -p "${target_dir}"
    wget -q -O "${ISO_WORK}/${filepath}" "${DEBIAN_MIRROR}/${filepath}"
done

echo "Downloaded $(find "${ISO_WORK}/pool" -name '*.udeb' | wc -l) udeb packages"

# Copy d-i Packages index
cp "${UDEBS_WORK}/Packages" \
    "${ISO_WORK}/dists/${DEBIAN_SUITE}/main/debian-installer/binary-amd64/Packages"
gzip -kf "${ISO_WORK}/dists/${DEBIAN_SUITE}/main/debian-installer/binary-amd64/Packages"

# Step 4: Download .deb packages for target system
echo "=== Downloading .deb packages for offline installation ==="
RESOLVER="${BUILDHOME}/resolver"

debootstrap --arch=amd64 --variant=minbase "${DEBIAN_SUITE}" \
    "${RESOLVER}" \
    "${DEBIAN_MIRROR}/"

mount -t proc proc "${RESOLVER}/proc"

chroot "${RESOLVER}" bash -x <<CHROOT_EOF
export DEBIAN_FRONTEND=noninteractive

apt-get clean

cat <<EOF > /etc/apt/sources.list
deb ${DEBIAN_MIRROR}/ ${DEBIAN_SUITE} main contrib non-free non-free-firmware
EOF

apt-get update -qy

# Download extra packages and their dependencies
apt-get install -y -d --no-install-recommends ${EXTRA_PACKAGES}

# Download base system packages for air-gap completeness
dpkg-query -W -f='\${Package}\n' | xargs apt-get install -y -d --reinstall 2>/dev/null || true
CHROOT_EOF

umount "${RESOLVER}/proc" 2>/dev/null || true

mkdir -p "${ISO_WORK}/pool/main/custom"
find "${RESOLVER}/var/cache/apt/archives" -name "*.deb" \
    -exec cp {} "${ISO_WORK}/pool/main/custom/" \;

echo "Added $(find "${ISO_WORK}/pool/main/custom" -name '*.deb' | wc -l) deb packages"

# Step 5: Generate package indices
echo "=== Generating package indices ==="
cd "${ISO_WORK}"

# Index .deb packages (apt-ftparchive ignores .udeb files)
apt-ftparchive packages pool/main \
    > "dists/${DEBIAN_SUITE}/main/binary-amd64/Packages"
gzip -kf "dists/${DEBIAN_SUITE}/main/binary-amd64/Packages"

# Generate Release file
apt-ftparchive \
    -o APT::FTPArchive::Release::Codename="${DEBIAN_SUITE}" \
    -o APT::FTPArchive::Release::Label="Debian" \
    -o APT::FTPArchive::Release::Architectures="amd64" \
    -o APT::FTPArchive::Release::Components="main" \
    release "dists/${DEBIAN_SUITE}" > "dists/${DEBIAN_SUITE}/Release"

# Step 6: Add preseed
echo "=== Adding preseed configuration ==="
cp "${SCRIPT_DIR}/preseed.cfg" "${ISO_WORK}/preseed.cfg"

# Step 7: Set up boot infrastructure
echo "=== Setting up boot configuration ==="
PRESEED_PARAMS="auto=true priority=high preseed/file=/cdrom/preseed.cfg"

# BIOS boot (isolinux)
cp /usr/lib/ISOLINUX/isolinux.bin "${ISO_WORK}/isolinux/"
for module in ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32; do
    cp "/usr/lib/syslinux/modules/bios/${module}" "${ISO_WORK}/isolinux/"
done

cat <<EOF > "${ISO_WORK}/isolinux/isolinux.cfg"
path
include txt.cfg
default vesamenu.c32
prompt 0
timeout 50
EOF

cat <<EOF > "${ISO_WORK}/isolinux/txt.cfg"
label install
    menu label ^Debian 13 Install
    kernel /install.amd/vmlinuz
    append ${PRESEED_PARAMS} initrd=/install.amd/initrd.gz --- quiet
label expert
    menu label ^Debian 13 Install (Expert)
    kernel /install.amd/vmlinuz
    append priority=low initrd=/install.amd/initrd.gz ---
EOF

# UEFI boot (GRUB)
cat <<EOF > "${ISO_WORK}/boot/grub/grub.cfg"
set timeout=5
set default=0

insmod efi_gop
insmod efi_uga
insmod all_video

menuentry "Debian 13 Install" {
    linux /install.amd/vmlinuz ${PRESEED_PARAMS} --- quiet
    initrd /install.amd/initrd.gz
}

menuentry "Debian 13 Install (Expert)" {
    linux /install.amd/vmlinuz priority=low ---
    initrd /install.amd/initrd.gz
}

menuentry "Reboot" {
    reboot
}

menuentry "Power off" {
    halt
}
EOF

grub-mkstandalone \
    --format=x86_64-efi \
    --output="${BUILDHOME}/bootx64.efi" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=${ISO_WORK}/boot/grub/grub.cfg"

dd if=/dev/zero of="${ISO_WORK}/boot/grub/efi.img" bs=1M count=10
mkfs.vfat "${ISO_WORK}/boot/grub/efi.img"
LC_CTYPE=C mmd -i "${ISO_WORK}/boot/grub/efi.img" efi efi/boot
LC_CTYPE=C mcopy -i "${ISO_WORK}/boot/grub/efi.img" "${BUILDHOME}/bootx64.efi" ::efi/boot/

# Step 8: Generate checksums
echo "=== Generating checksums ==="
cd "${ISO_WORK}"
find . -type f ! -name 'md5sum.txt' ! -path './isolinux/*' -print0 | \
    xargs -0 md5sum > md5sum.txt

# Step 9: Build ISO
echo "=== Building ISO ==="
OUTPUT_ISO="${BUILDHOME}/${BUILDNAME}.iso"

xorriso -as mkisofs \
    -r -V "Debian 13 Custom" \
    -o "${OUTPUT_ISO}" \
    -J -joliet-long \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -partition_offset 16 \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "${ISO_WORK}"

cp "${OUTPUT_ISO}" "${OUTPUT_DIR}/"

echo ""
echo "=== Build complete ==="
echo "ISO: ${OUTPUT_DIR}/${BUILDNAME}.iso"
echo "Size: $(du -h "${OUTPUT_ISO}" | cut -f1)"
