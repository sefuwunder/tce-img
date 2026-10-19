# Containerfile - The Coding Exec Ubuntu Workstation
FROM ghcr.io/bootcrew/ubuntu-bootc:latest

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
    wireless-tools \
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

# 2. Initialize Rkhunter File Properties Baseline (Locked to Build State)
RUN rkhunter --propupd || true

# 3. Install Distrobox for CLI / Dev Environments
RUN curl -shttps://raw.githubusercontent.com/89luca89/distrobox/main/install | sh

# 4. Enable Essential System Services
RUN systemctl enable \
    gdm.service \
    NetworkManager.service \
    podman.socket \
    power-profiles-daemon.service \
    upower.service

# 5. Configure Flathub Repository and Pre-install Firefox System-Wide
RUN flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo && \
    flatpak install -y flathub org.mozilla.firefox

# 6. Label Image Metadata
LABEL org.opencontainers.image.title="The Coding Exec Ubuntu Workstation" \
      org.opencontainers.image.description="Bootc image tuned for executive productivity, Wi-Fi, AppImages, secure auditing, Firefox, and containerized coding."
