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
