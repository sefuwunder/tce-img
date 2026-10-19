#!/bin/bash
# 01-export-executive-state.sh
set -euo pipefail

BACKUP_TARGET="/media/${USER}/BackupDrive/coding_exec_backup_$(date +%Y%m%d)"

echo "[+] Starting Executive State Export to: ${BACKUP_TARGET}"
mkdir -p "${BACKUP_TARGET}"

# 1. Export Installed Application Manifests
echo "[+] Exporting package and Flatpak lists..."
dpkg --get-selections > "${BACKUP_TARGET}/apt-packages.list"
flatpak list --app --columns=application > "${BACKUP_TARGET}/flatpaks.list" 2>/dev/null || true

# 2. Export Network & VPN Configurations
echo "[+] Backing up NetworkManager connections..."
sudo tar -czf "${BACKUP_TARGET}/networkmanager-conns.tar.gz" -C /etc/NetworkManager/system-connections .

# 3. Backup Critical Dotfiles & Configs
echo "[+] Archiving SSH, GPG, and Git configurations..."
tar -czf "${BACKUP_TARGET}/user-configs.tar.gz" \
    -C "${HOME}" \
    .ssh \
    .gnupg \
    .gitconfig \
    .config/dconf \
    .var/app

# 4. Sync /home Directory Data
echo "[+] Syncing Home Directory Data (excluding caches and runtimes)..."
rsync -aHAX --progress \
    --exclude='.cache' \
    --exclude='.local/share/containers' \
    --exclude='.local/share/Trash' \
    "${HOME}/" "${BACKUP_TARGET}/home_backup/"

echo "[+] Export complete! Backup located at: ${BACKUP_TARGET}"
