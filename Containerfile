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

USER root

# 0. Boot stack for bootc: kernel, bootloader, initramfs tools, fs tools.
#    The kernel is copied into the versioned modules dir (where bootc expects it)
#    because /boot is removed during the ostree conversion at the end.
RUN apt-get update && apt-get install -y --no-install-recommends \
        linux-image-generic \
        systemd-boot \
        dracut \
        btrfs-progs xfsprogs dosfstools e2fsprogs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && cp /boot/vmlinuz-* "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/vmlinuz"

# bootc userspace from the builder stage
COPY --from=bootc-builder /output /

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
    && printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' \
        > /usr/lib/ostree/prepare-root.conf

# 7. Initialize rkhunter baseline (best-effort: /var is provisioned at install)
RUN rkhunter --propupd || true

# 8. Label Image Metadata
LABEL containers.bootc=1
LABEL org.opencontainers.image.title="The Coding Exec Ubuntu Workstation" \
      org.opencontainers.image.description="Bootc image tuned for executive productivity, Wi-Fi, AppImages, secure auditing, Firefox, and containerized coding."
