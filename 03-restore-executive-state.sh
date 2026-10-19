#!/bin/bash
# 03-restore-executive-state.sh
set -euo pipefail

BACKUP_SOURCE="${1:-/media/${USER}/BackupDrive/coding_exec_backup}"

if [ ! -d "${BACKUP_SOURCE}" ]; then
  echo "[-] Error: Backup source directory '${BACKUP_SOURCE}' does not exist." >&2
  exit 1
fi

echo "[+] Restoring Executive User State from: ${BACKUP_SOURCE}"

# 1. Restore Home Directory Data
echo "[+] Restoring Home directory files..."
rsync -aHAX --progress "${BACKUP_SOURCE}/home_backup/" "${HOME}/"

# 2. Restore SSH & Config Credentials
if [ -f "${BACKUP_SOURCE}/user-configs.tar.gz" ]; then
    echo "[+] Extracting SSH, GPG, and application settings..."
    tar -xzf "${BACKUP_SOURCE}/user-configs.tar.gz" -C "${HOME}/"
    chmod 700 "${HOME}/.ssh" "${HOME}/.gnupg"
    chmod 600 "${HOME}/.ssh/"* 2>/dev/null || true
fi

# 3. Restore Network Connections
if [ -f "${BACKUP_SOURCE}/networkmanager-conns.tar.gz" ]; then
    echo "[+] Restoring NetworkManager VPN and Wi-Fi profiles..."
    sudo tar -xzf "${BACKUP_SOURCE}/networkmanager-conns.tar.gz" -C /etc/NetworkManager/system-connections/
    sudo systemctl restart NetworkManager
fi

# 4. Provision Executive Flatpaks (Slack, Zoom, VS Code, Browser)
echo "[+] Installing Executive Applications via Flatpak..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub \
    com.slack.Slack \
    us.zoom.Zoom \
    com.visualstudio.code \
    com.brave.Browser \
    md.obsidian.Obsidian

# 5. Initialize Coding Exec Distrobox Containers
echo "[+] Setting up isolated development environment in Distrobox..."
distrobox create -n dev-ub2404 -i ubuntu:24.04 --yes || true

echo "[+] Executive State Restoration Complete!"
