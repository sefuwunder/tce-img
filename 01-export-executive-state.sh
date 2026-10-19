#!/bin/bash
# 01-export-executive-state.sh — back up workstation state to an external drive.
set -euo pipefail

# Resolve the real (non-root) user even when run via sudo, so we always
# back up the human's home — never root's.
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
if [ -z "${REAL_HOME}" ] || [ ! -d "${REAL_HOME}" ]; then
  echo "[-] Error: cannot resolve a home directory for user '${REAL_USER}'." >&2
  exit 1
fi

# Refuse to "back up" onto the local disk if the drive isn't mounted.
BACKUP_DRIVE="/media/${REAL_USER}/BackupDrive"
if ! mountpoint -q "${BACKUP_DRIVE}"; then
  echo "[-] Error: backup drive is not mounted at ${BACKUP_DRIVE}." >&2
  echo "    Mount it first — refusing to write the backup to the local disk." >&2
  exit 1
fi

BACKUP_TARGET="${BACKUP_DRIVE}/coding_exec_backup_$(date +%Y%m%d)"

echo "[+] Starting Executive State Export to: ${BACKUP_TARGET}"
mkdir -p "${BACKUP_TARGET}"

# 1. Export Installed Application Manifests
echo "[+] Exporting package and Flatpak lists..."
dpkg --get-selections > "${BACKUP_TARGET}/apt-packages.list"
# List the *user's* flatpaks even when we're root via sudo.
if [ "$EUID" -eq 0 ] && [ "${REAL_USER}" != "root" ]; then
  sudo -u "${REAL_USER}" flatpak list --app --columns=application > "${BACKUP_TARGET}/flatpaks.list" 2>/dev/null || true
else
  flatpak list --app --columns=application > "${BACKUP_TARGET}/flatpaks.list" 2>/dev/null || true
fi

# 2. Export Network & VPN Configurations
echo "[+] Backing up NetworkManager connections..."
if [ -d /etc/NetworkManager/system-connections ]; then
  sudo tar -czf "${BACKUP_TARGET}/networkmanager-conns.tar.gz" -C /etc/NetworkManager/system-connections .
else
  echo "[!] No NetworkManager connections directory; skipping."
fi

# 3. Backup Critical Dotfiles & Configs (only what actually exists —
#    tar exits non-zero on a missing path, which would abort the backup)
echo "[+] Archiving SSH, GPG, and Git configurations..."
dotfiles=()
for f in .ssh .gnupg .gitconfig .config/dconf .var/app; do
  [ -e "${REAL_HOME}/${f}" ] && dotfiles+=("${f}")
done
if [ "${#dotfiles[@]}" -gt 0 ]; then
  tar -czf "${BACKUP_TARGET}/user-configs.tar.gz" -C "${REAL_HOME}" "${dotfiles[@]}"
else
  echo "[!] No dotfiles found; skipping."
fi

# 4. Sync /home Directory Data
echo "[+] Syncing Home Directory Data (excluding caches and runtimes)..."
if ! command -v rsync >/dev/null 2>&1; then
  echo "[-] Error: rsync is not installed." >&2
  exit 1
fi
rsync -aHAX --progress \
    --exclude='.cache' \
    --exclude='.local/share/containers' \
    --exclude='.local/share/Trash' \
    "${REAL_HOME}/" "${BACKUP_TARGET}/home_backup/"

echo "[+] Export complete! Backup located at: ${BACKUP_TARGET}"
