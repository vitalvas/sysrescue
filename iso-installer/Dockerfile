FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-utils \
    debootstrap \
    dosfstools \
    grub-efi-amd64-bin \
    isolinux \
    mtools \
    syslinux-common \
    wget \
    xorriso \
    && rm -rf /var/lib/apt/lists/*

COPY make.sh preseed.cfg /build/
RUN chmod +x /build/make.sh

ENTRYPOINT ["/build/make.sh"]
