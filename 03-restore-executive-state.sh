#!/bin/bash
# 03-restore-executive-state.sh — restore workstation state after installing.
# Run as your normal user (not with sudo); only the NetworkManager step
# escalates internally.
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
  echo "[-] Error: run as your normal user, not with sudo." >&2
  echo "    (Only the NetworkManager restore step uses sudo internally.)" >&2
  exit 1
fi

# Default to the newest export; script 01 names them coding_exec_backup_YYYYMMDD.
BACKUP_BASE="/media/${USER}/BackupDrive"
if [ $# -ge 1 ]; then
  BACKUP_SOURCE="$1"
else
  BACKUP_SOURCE="$(ls -dt "${BACKUP_BASE}"/coding_exec_backup_* 2>/dev/null | head -n 1 || true)"
fi
if [ -z "${BACKUP_SOURCE}" ] || [ ! -d "${BACKUP_SOURCE}" ]; then
  echo "[-] Error: no backup found under ${BACKUP_BASE} (expected coding_exec_backup_YYYYMMDD)." >&2
  echo "    Pass the backup directory explicitly: $0 <path>" >&2
  exit 1
fi

echo "[+] Restoring Executive User State from: ${BACKUP_SOURCE}"

# 1. Restore Home Directory Data
echo "[+] Restoring Home directory files..."
if ! command -v rsync >/dev/null 2>&1; then
  echo "[-] Error: rsync is not installed." >&2
  exit 1
fi
rsync -aHAX --progress "${BACKUP_SOURCE}/home_backup/" "${HOME}/"

# 2. Restore SSH & Config Credentials
if [ -f "${BACKUP_SOURCE}/user-configs.tar.gz" ]; then
    echo "[+] Extracting SSH, GPG, and application settings..."
    tar -xzf "${BACKUP_SOURCE}/user-configs.tar.gz" -C "${HOME}/"
    [ -d "${HOME}/.ssh" ] && chmod 700 "${HOME}/.ssh"
    [ -d "${HOME}/.gnupg" ] && chmod 700 "${HOME}/.gnupg"
    chmod 600 "${HOME}/.ssh/"* 2>/dev/null || true
fi

# 3. Restore Network Connections
if [ -f "${BACKUP_SOURCE}/networkmanager-conns.tar.gz" ]; then
    echo "[+] Restoring NetworkManager VPN and Wi-Fi profiles..."
    sudo tar -xzf "${BACKUP_SOURCE}/networkmanager-conns.tar.gz" -C /etc/NetworkManager/system-connections/
    sudo chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true
    sudo systemctl restart NetworkManager
fi

# 4. Provision Executive Flatpaks (Slack, Zoom, VS Code, Browser)
#    One failure must not abort the rest of the restore.
echo "[+] Installing Executive Applications via Flatpak..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
for app in com.slack.Slack us.zoom.Zoom com.visualstudio.code com.brave.Browser md.obsidian.Obsidian; do
  flatpak install -y flathub "${app}" || echo "[!] Failed to install ${app}; continuing."
done

# 5. Initialize Coding Exec Distrobox Containers
echo "[+] Setting up isolated development environment in Distrobox..."
if command -v distrobox >/dev/null 2>&1; then
  distrobox create -n dev-ub2404 -i ubuntu:24.04 --yes || echo "[!] Distrobox container setup failed; continuing."
else
  echo "[!] distrobox not found; skipping container setup."
fi

echo "[+] Executive State Restoration Complete!"
