# Containerfile - The Coding Exec Ubuntu Workstation
#
# Base: plain Ubuntu. We do the bootc conversion ourselves because pre-converted
# bootc base images ship with an empty /var (ostree state dir), which removes
# /var/lib/dpkg and makes any further apt use impossible.

# ---- Stage 1: compile bootc from source (binary + dracut module + units) ----
FROM docker.io/library/ubuntu:questing AS bootc-builder

ENV CARGO_HOME=/tmp/rust RUSTUP_HOME=/tmp/rust
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl make build-essential go-md2man \
        libzstd-dev libselinux-dev libclang-dev pkgconf libostree-dev ostree ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --profile minimal -y
WORKDIR /home/build
RUN git clone https://github.com/bootc-dev/bootc.git . \
    && sh -c ". ${RUSTUP_HOME}/env && make bin install-all DESTDIR=/output"

# ---- Stage 2: the workstation image ----
FROM docker.io/library/ubuntu:questing

ENV DEBIAN_FRONTEND=noninteractive

USER root

# 0. Boot stack for bootc: kernel, bootloader, initramfs tools, fs tools.
#    The kernel is copied into the versioned modules dir (where bootc expects it)
#    because /boot is removed during the ostree conversion at the end.
#    ostree/fdisk/skopeo: bootc and bootc-image-builder's tooling execute inside
#    the image's own userland (osbuild's image-pipeline stages run sfdisk/mkfs
#    there; bootc's installer spawns skopeo and its selinux stage labels
#    /usr/bin/ostree), so these must be in the image, not just the builder.
RUN apt-get update && apt-get install -y --no-install-recommends \
        linux-image-generic \
        systemd-boot \
        dracut \
        btrfs-progs xfsprogs dosfstools e2fsprogs \
        ostree fdisk skopeo \
        grub-efi-amd64-bin grub-efi-amd64-signed shim-signed grub-common grub-pc-bin \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && cp /boot/vmlinuz-* "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/vmlinuz"

# bootc userspace from the builder stage
COPY --from=bootc-builder /output /

# bootc install config: default root filesystem type. bootc-image-builder
# and `bootc install to-disk` refuse to guess it (BIB aborts with
# "missing required info: DefaultRootFs" without it). btrfs, chosen 2026-10-20.
RUN mkdir -p /usr/lib/bootc/install \
    && printf '[install.filesystem.root]\ntype = "btrfs"\n' > /usr/lib/bootc/install/10-tce.toml

# osbuild compatibility shim: bootc-image-builder's generated manifest hardcodes
# an org.osbuild.selinux stage that relabels the tree using
# etc/selinux/targeted/contexts/files/file_contexts plus three explicit path
# labels (/usr/bin/mount, /usr/bin/ostree, /usr/bin/umount). This image uses
# AppArmor, not SELinux, so the contexts file is intentionally empty: setfiles
# labels nothing and the stage is a no-op.
RUN mkdir -p /etc/selinux/targeted/contexts/files \
    && touch /etc/selinux/targeted/contexts/files/file_contexts \
    && touch /etc/selinux/targeted/contexts/files/file_contexts.local

# 1. Base Workstation, Hardware, AppImages, GOA, Security, & Dev Tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal \
    flatpak \
    podman \
    build-essential \
    curl \
    git \
    tmux \
    zsh \
    wireguard \
    openvpn \
    network-manager-openvpn \
    ca-certificates \
    libnss3-tools \
    power-profiles-daemon \
    upower \
    acpi \
    linux-firmware \
    iw \
    wpasupplicant \
    libfuse2t64 \
    fuse3 \
    desktop-file-utils \
    shared-mime-info \
    libglib2.0-bin \
    gnome-online-accounts \
    lynis \
    clamav \
    rkhunter \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Firefox via Mozilla's apt repo (NOT flatpak: flatpak installs land in
#    /var, which bootc provisions fresh at install time — they'd be lost)
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc \
    && chmod 644 /etc/apt/keyrings/packages.mozilla.org.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list \
    && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla \
    && apt-get update && apt-get install -y --no-install-recommends firefox \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 3. Install Distrobox to /usr (/usr/local becomes a symlink to empty
#    /var/usrlocal after the conversion below)
RUN curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix /usr

# 4. Enable Essential System Services
RUN systemctl enable \
    gdm.service \
    NetworkManager.service \
    podman.socket \
    power-profiles-daemon.service \
    upower.service

# 5. dracut initramfs with the bootc module (Ubuntu systemd path fix)
RUN mkdir -p /usr/lib/dracut/dracut.conf.d/ \
    && printf 'systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n' \
        > /usr/lib/dracut/dracut.conf.d/30-bootc-fix-bootc-module.conf \
    && printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc "\n' \
        > /usr/lib/dracut/dracut.conf.d/30-bootc-container-build.conf \
    && dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/initramfs.img"

# 6. Convert to ostree/bootc layout. LAST: it wipes /var, so the rkhunter
#    baseline below is best-effort (re-run propupd on first boot).
#    composefs stays OFF: questing's libostree ships without composefs support
#    compiled in, so enabled=yes could never execute here (bootc install and
#    boot both fail). Classic ostree checkouts instead; revisit if Ubuntu's
#    ostree gains composefs support.
RUN rm -rf /boot /home /root /usr/local /srv /opt /mnt /var \
    && mkdir -p /sysroot /boot /usr/lib/ostree /var \
    && ln -sT sysroot/ostree /ostree \
    && ln -sT var/roothome /root \
    && ln -sT var/srv /srv \
    && ln -sT var/opt /opt \
    && ln -sT var/mnt /mnt \
    && ln -sT var/home /home \
    && ln -sT ../var/usrlocal /usr/local \
    && printf 'd /var/opt 0755 root root -\nd /var/home 0755 root root -\nd /var/srv 0755 root root -\nd /var/mnt 0755 root root -\nd /var/usrlocal 0755 root root -\n' \
        >> /usr/lib/tmpfiles.d/bootc-base-dirs.conf \
    && printf 'd /var/roothome 0700 root root -\nd /run/media 0755 root root -\n' \
        >> /usr/lib/tmpfiles.d/bootc-base-dirs.conf \
    && printf '[composefs]\nenabled = no\n[sysroot]\nreadonly = true\n' \
        > /usr/lib/ostree/prepare-root.conf

# 7. Initialize rkhunter baseline (best-effort: /var is provisioned at install)
RUN rkhunter --propupd || true

# 8. Label Image Metadata
LABEL containers.bootc=1
LABEL org.opencontainers.image.title="The Coding Exec Ubuntu Workstation" \
      org.opencontainers.image.description="Bootc image tuned for executive productivity, Wi-Fi, AppImages, secure auditing, Firefox, and containerized coding."

# 9. ISO prerequisites for bootc-image-builder (bootc-installer contract).
#    Must run after the ostree conversion (step 6), which wipes /boot.
#    The builder reads kernel + initramfs from /usr/lib/modules/<ver>/,
#    detects the UEFI vendor from /usr/lib/efi/shim/*/EFI/<vendor>,
#    and takes the ISO label + GRUB entries from iso.yaml.
RUN mkdir -p /boot/efi/EFI/ubuntu /usr/lib/efi/shim/x64/EFI /usr/lib/image-builder/bootc \
    && cp /usr/lib/shim/shimx64.efi /boot/efi/EFI/ubuntu/shimx64.efi \
    && cp /usr/lib/shim/mmx64.efi /boot/efi/EFI/ubuntu/mmx64.efi \
    && cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /boot/efi/EFI/ubuntu/grubx64.efi \
    && cp /usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed /boot/efi/EFI/ubuntu/gcdx64.efi \
    && cp -r /boot/efi/EFI/. /usr/lib/efi/shim/x64/EFI/ \
    && printf 'label: "TCE_WORKSTATION"\ngrub2:\n  entries:\n    - name: "Install The Coding Exec Workstation"\n      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=TCE_WORKSTATION ro console=tty0"\n      initrd: "/images/pxeboot/initrd.img"\n' \
        > /usr/lib/image-builder/bootc/iso.yaml
