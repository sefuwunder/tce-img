#!/bin/bash
# 02-provision-bootc.sh
set -euo pipefail

IMAGE_REF="${1:-quay.io/codingexec/ubuntu-workstation:latest}"

if [ "$EUID" -ne 0 ]; then
  echo "[-] Error: Please run as root (sudo)." >&2
  exit 1
fi

echo "[+] Pulling Bootc Workstation Image: ${IMAGE_REF}..."
podman pull "${IMAGE_REF}"

echo "[+] Enabling filesystem fs-verity / composefs requirements..."
tune2fs -O inline_data,extra_isize /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null || true

echo "[+] Executing bootc install to current root filesystem target..."
podman run --privileged --rm \
    -v /:/target \
    -v /dev:/dev \
    -v /var/lib/containers:/var/lib/containers \
    "${IMAGE_REF}" \
    bootc install to-existing-root --target-no-wipe /target

echo "=================================================================="
echo "[+] Bootc installation finished!"
echo "[+] Reboot system now to boot into the immutable bootc environment."
echo "=================================================================="
