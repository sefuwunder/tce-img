# The Coding Exec’s Guide to Bootc-Based Ubuntu Workstations

This document describes the complete architecture, lifecycle, and operational
workflows for running an immutable, containerized **`bootc` Ubuntu Workstation**,
as built by this repo (`tce-img`).

Designed for **"The Coding Exec"**: executive-grade stability (fail-safe atomic
updates, instant rollback) alongside full developer freedom (containerized
toolchains, sandboxed apps, automated background security audits).

The image is built, linted, and published automatically by GitHub Actions:
`ghcr.io/sefuwunder/tce-img:latest` (plus `sha-<commit>` tags for pinning/rollback), with a bootable
installer ISO attached to each run as a workflow artifact.

## Architecture & Security Model

```
+-------------------------------------------------------------------------+
|                  THE CODING EXEC WORKSTATION LAYOUT                     |
+-------------------------------------------------------------------------+
| [User Apps]        Slack, Zoom, VS Code, Brave, Obsidian -> Flatpak     |
| [Browser]          Firefox -> Mozilla apt repo (NOT flatpak: installs    |
|                    land in /var, which bootc provisions fresh)          |
| [Dev Environments] Toolchains -> Distrobox containers (prefix /usr)     |
| [User State]       /home, /var, /etc -> Persistent, machine-local       |
| [Immutable Base]   Kernel, drivers, desktop -> Bootc OCI image (/usr)   |
+-------------------------------------------------------------------------+
```

1. **System immutability (`/usr` read-only):** system files cannot be modified
   live. Rebooting resets any uncommitted `/usr` changes to the sealed OCI image.
2. **Zero-downtime atomic updates:** `sudo bootc upgrade` stages the new image in
   the background. A bad update is undone with `sudo bootc rollback`.
3. **Compartmentalized workflows:** GUI tools in Flatpak sandboxes, CLI dev
   environments in Distrobox containers, credentials persist in `/home`.

## Phase 1: OS Image Declaration (`Containerfile`)

The OS is declared entirely in code. Notable design decisions:

- **Plain Ubuntu base** (`docker.io/library/ubuntu:questing`), not a pre-converted
  bootc base: finished bootc images ship with an empty `/var` (ostree state dir),
  which removes `/var/lib/dpkg` and makes further `apt` use impossible.
- **bootc compiled from source** in a builder stage (binary + dracut module + units).
- **Boot stack:** `linux-image-generic`, `systemd-boot`, dracut initramfs with the
  `bootc` module; the kernel and initramfs live in `/usr/lib/modules/<ver>/`
  because `/boot` is wiped during the ostree conversion.
- **Firefox from Mozilla's apt repo**, not Flatpak (Flatpak installs land in `/var`).
- **Distrobox with `--prefix /usr`** (`/usr/local` becomes a symlink to empty
  `/var/usrlocal` after conversion).
- **Ostree conversion last**, then a best-effort `rkhunter --propupd` (re-run it on
  first boot — `/var` is provisioned fresh at install).
- **ISO prerequisites** (`bootc-generic-iso` contract): GRUB/shim stack,
  `/boot/efi/EFI/ubuntu` + `/usr/lib/efi/shim` arrangement, and
  `/usr/lib/image-builder/bootc/iso.yaml`.

```dockerfile
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
RUN apt-get update && apt-get install -y --no-install-recommends \
        linux-image-generic \
        systemd-boot \
        dracut \
        btrfs-progs xfsprogs dosfstools e2fsprogs \
        grub-efi-amd64-bin grub-efi-amd64-signed shim-signed grub-common grub-pc-bin \
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
    && printf '[composefs]\nenabled = no\n[sysroot]\nreadonly = true\n' \
        > /usr/lib/ostree/prepare-root.conf

# 7. Initialize rkhunter baseline (best-effort: /var is provisioned at install)
RUN rkhunter --propupd || true

# 8. Label Image Metadata
LABEL containers.bootc=1
LABEL org.opencontainers.image.title="The Coding Exec Ubuntu Workstation" \
      org.opencontainers.image.description="Bootc image tuned for executive productivity, Wi-Fi, AppImages, secure auditing, Firefox, and containerized coding."

# 9. ISO prerequisites for bootc-image-builder (bootc-generic-iso contract).
#    Must run after the ostree conversion (step 6), which wipes /boot.
#    The builder reads kernel + initramfs from /usr/lib/modules/<ver>/,
#    detects the UEFI vendor from /usr/lib/efi/shim/*/EFI/<vendor>,
#    and takes the ISO label + GRUB entries from iso.yaml.
RUN mkdir -p /boot/efi/EFI/ubuntu /usr/lib/efi/shim/x64/EFI /usr/lib/image-builder/bootc \
    && cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/ubuntu/shimx64.efi \
    && cp /usr/lib/shim/mmx64.efi.signed /boot/efi/EFI/ubuntu/mmx64.efi \
    && cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /boot/efi/EFI/ubuntu/grubx64.efi \
    && cp -r /boot/efi/EFI/. /usr/lib/efi/shim/x64/EFI/ \
    && printf 'label: "TCE_WORKSTATION"\ngrub2:\n  entries:\n    - name: "Install The Coding Exec Workstation"\n      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=TCE_WORKSTATION ro console=tty0"\n      initrd: "/images/pxeboot/initrd.img"\n' \
        > /usr/lib/image-builder/bootc/iso.yaml
```

## Phase 2: State Export (Pre-Migration)

Run `01-export-executive-state.sh` on the current workstation **before**
converting. It resolves the real user even under `sudo`, refuses to run unless
the backup drive is actually mounted, and archives package lists, Flatpaks,
NetworkManager profiles, dotfiles/credentials, and `/home` (minus caches).

```bash
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
```

## Phase 3: Dry-Run Verification (VM Sandbox)

Before touching bare metal, build a VM disk image and boot it in QEMU/KVM.

1. **Build a QCOW2 image:**

   ```bash
   sudo podman run --rm -it --privileged \
     --security-opt label=type:unconfined_t \
     -v ./output:/output \
     quay.io/centos-bootc/bootc-image-builder:latest \
     --type qcow2 \
     ghcr.io/sefuwunder/tce-img:latest
   ```

2. **Boot and test in QEMU:**

   ```bash
   qemu-system-x86_64 \
     -enable-kvm \
     -cpu host \
     -m 4G \
     -smp 4 \
     -drive file=./output/qcow2/disk.qcow2,format=qcow2 \
     -netdev user,id=net0 \
     -device virtio-net-pci,netdev=net0
   ```

## Phase 4: In-Place System Transition

`02-provision-bootc.sh` converts the running machine to the bootc image
(must run as root). It pulls the image, best-effort prepares the backing
filesystem for composefs/fs-verity (the image itself currently ships with
composefs disabled — questing's libostree has no composefs support compiled
in), and runs `bootc install to-existing-root` — `/home` and user state
survive; reboot into the immutable environment afterwards.

```bash
#!/bin/bash
# 02-provision-bootc.sh — install the bootc workstation image onto this machine.
set -euo pipefail

IMAGE_REF="${1:-ghcr.io/sefuwunder/tce-img:latest}"

if [ "$EUID" -ne 0 ]; then
  echo "[-] Error: Please run as root (sudo)." >&2
  exit 1
fi

echo "[+] Pulling Bootc Workstation Image: ${IMAGE_REF}..."
podman pull "${IMAGE_REF}"

# Best-effort: composefs wants inline_data + extra_isize on the backing fs.
# Resolve the actual root device instead of assuming Ubuntu's LVM layout.
echo "[+] Enabling filesystem fs-verity / composefs requirements (best-effort)..."
ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [ -n "${ROOT_DEV}" ]; then
  tune2fs -O inline_data,extra_isize "${ROOT_DEV}" 2>/dev/null || true
fi

echo "[+] Installing bootc to the existing root (content of /boot is replaced)..."
podman run --privileged --rm \
    --pid=host --security-opt label=type:unconfined_t \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    -v /:/target \
    "${IMAGE_REF}" \
    bootc install to-existing-root

echo "=================================================================="
echo "[+] Bootc installation finished!"
echo "[+] Reboot system now to boot into the immutable bootc environment."
echo "=================================================================="
```

## Phase 5: Bare-Metal Deployment via Installer ISO

Every push to `main` (and manual workflow runs) builds a bootable installer ISO
with bootc-image-builder (`bootc-generic-iso`) from the just-published image.
(Skipped on the nightly schedule run.)

1. **Download** the `tce-workstation-installer-iso` artifact from the Actions run.

2. **Flash it to a USB stick** (`flash-tce-usb.sh`):

   ```bash
   #!/bin/bash
   # flash-tce-usb.sh
   set -euo pipefail

   if [ "$EUID" -ne 0 ]; then echo "[-] Run as root."; exit 1; fi

   ISO_IMAGE="./tce-workstation-installer.iso"
   lsblk -d -o NAME,SIZE,MODEL,TRAN,RM | grep -E "usb|1" || true
   read -p "Enter target USB device name (e.g. sdb): " TARGET_DEV
   TARGET_PATH="/dev/$TARGET_DEV"

   # Guardrail: never target the disk we booted from
   ROOT_DISK=$(findmnt / -o SOURCE -n | sed 's/[0-9]*$//' | awk -F'/' '{print $3}')
   if [ "$TARGET_DEV" = "$ROOT_DISK" ]; then echo "[-] Cannot target root disk!"; exit 1; fi

   read -p "Type 'ERASE' to confirm wiping $TARGET_PATH: " CONFIRM
   if [ "$CONFIRM" != "ERASE" ]; then exit 1; fi

   umount "${TARGET_PATH}"* 2>/dev/null || true
   dd if="$ISO_IMAGE" of="$TARGET_PATH" bs=4M status=progress conv=fsync
   sync
   echo "[+] Installer USB created!"
   ```

3. **Install:** boot the target machine from USB. The ISO boots a live
   environment; from a terminal there, write the image to the internal disk:

   ```bash
   sudo bootc install to-disk /dev/sdX   # replace sdX with the target disk
   ```

   Then reboot into the installed workstation and continue with Phase 6.

## Phase 6: Post-Install State & Application Restoration

Run `03-restore-executive-state.sh` **as your normal user** (not with sudo)
after first login. It defaults to the newest dated backup, restores `/home`,
credentials, and NetworkManager profiles, then installs the executive Flatpaks
(Slack, Zoom, VS Code, Brave, Obsidian) and creates the `dev-ub2404` Distrobox.

```bash
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
```

## Phase 7: Maintenance & Background Security Services

`04-setup-user-security-services.sh` (as root) installs low-priority systemd
timers: daily ClamAV scan of `~/Downloads`, weekly rkhunter check, monthly Lynis
audit.

```bash
#!/bin/bash
# 04-setup-user-security-services.sh
# Sets up low-overhead systemd timers for security auditing and scanning

set -euo pipefail

# --- GUARDRAIL: Root Privileges ---
if [ "$EUID" -ne 0 ]; then
  echo "[-] Error: This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "[+] Setting up automated security services for The Coding Exec Workstation..."

# -------------------------------------------------------------------
# 1. ClamAV: Daily Scan of ~/Downloads
# -------------------------------------------------------------------
echo "[+] Configuring daily ClamAV scan for Downloads directory..."

cat << 'UNIT_EOF' > /etc/systemd/system/clamav-downloads-scan.service
[Unit]
Description=Low-priority ClamAV Scan of User Downloads
After=network.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
# sh -c wrapper: systemd does not expand globs in ExecStart itself
ExecStart=/bin/sh -c 'exec /usr/bin/clamscan -r --no-summary --infected /home/*/Downloads'
UNIT_EOF

cat << 'UNIT_EOF' > /etc/systemd/system/clamav-downloads-scan.timer
[Unit]
Description=Run ClamAV Downloads Scan Daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
UNIT_EOF

# -------------------------------------------------------------------
# 2. Rkhunter: Weekly Rootkit Check
# -------------------------------------------------------------------
echo "[+] Configuring weekly Rkhunter audit..."

cat << 'UNIT_EOF' > /etc/systemd/system/rkhunter-audit.service
[Unit]
Description=Weekly Rootkit Hunter System Check
After=network.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/rkhunter --check --cronjob --report-warnings-only
UNIT_EOF

cat << 'UNIT_EOF' > /etc/systemd/system/rkhunter-audit.timer
[Unit]
Description=Run Rkhunter Weekly

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=2h

[Install]
WantedBy=timers.target
UNIT_EOF

# -------------------------------------------------------------------
# 3. Lynis: Monthly Hardening Audit
# -------------------------------------------------------------------
echo "[+] Configuring monthly Lynis hardening audit..."

cat << 'UNIT_EOF' > /etc/systemd/system/lynis-audit.service
[Unit]
Description=Monthly Lynis Security Audit
After=network.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/lynis audit system --quiet --cronjob
UNIT_EOF

cat << 'UNIT_EOF' > /etc/systemd/system/lynis-audit.timer
[Unit]
Description=Run Lynis System Audit Monthly

[Timer]
OnCalendar=monthly
Persistent=true
RandomizedDelaySec=4h

[Install]
WantedBy=timers.target
UNIT_EOF

# -------------------------------------------------------------------
# 4. Enable & Start Systemd Timers
# -------------------------------------------------------------------
echo "[+] Reloading systemd daemon and enabling security timers..."
systemctl daemon-reload

systemctl enable --now clamav-downloads-scan.timer
systemctl enable --now rkhunter-audit.timer
systemctl enable --now lynis-audit.timer

echo "=================================================================="
echo "[+] SUCCESS: Security background services initialized!"
echo "    - ClamAV (Downloads folder): Runs daily"
echo "    - Rkhunter (Rootkit scan):  Runs weekly"
echo "    - Lynis (System audit):     Runs monthly"
echo "=================================================================="
```

## Operational Cheat Sheet

| Action | Command | Description |
| ----- | ----- | ----- |
| **Check System State** | `bootc status` | Active image, registry target, staged updates. |
| **Pull Latest Image** | `sudo bootc switch ghcr.io/sefuwunder/tce-img:latest` | Re-target to the latest published image. |
| **Pin / Roll Back** | `sudo bootc switch ghcr.io/sefuwunder/tce-img:sha-<commit>` | Pin a specific build; rollback target. |
| **Stage OS Update** | `sudo bootc upgrade` | Fetch latest image in the background; reboot to apply. |
| **Rollback Update** | `sudo bootc rollback` | Revert to the previous deployment. |
| **Update Desktop Apps** | `flatpak update` | Update GUI apps without touching the host OS. |
| **Dev Session** | `distrobox enter dev-ub2404` | Enter the isolated development container. |

_Note: the script listings above are snapshots — the `.sh` files and `Containerfile`
in this repo are the source of truth._
