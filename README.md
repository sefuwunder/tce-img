# tce-img — The Coding Exec Ubuntu Workstation

[![Build and Publish Bootc Workstation Image](https://github.com/sefuwunder/tce-img/actions/workflows/docker-image.yml/badge.svg)](https://github.com/sefuwunder/tce-img/actions/workflows/docker-image.yml)

A bootc-based Ubuntu workstation image: an immutable, image-based desktop tuned for
executive productivity — GNOME desktop, hardware enablement, containerized coding,
Wi-Fi/VPN, and layered security auditing. Built from plain Ubuntu with the bootc
conversion done in the `Containerfile` itself (kernel + dracut initramfs with the
bootc module, ostree/composefs layout).

**Image:** `ghcr.io/sefuwunder/tce-img:latest` (also tagged `sha-<commit>` per build)

## What's inside

| Area | Contents |
|---|---|
| Desktop | `ubuntu-desktop-minimal`, GNOME Online Accounts, power profiles, firmware |
| Dev tooling | `build-essential`, `git`, `curl`, `tmux`, `zsh`, `podman`, Distrobox (`/usr/bin`) |
| Network | `wireguard`, `openvpn` + NetworkManager plugin, `iw`, `wpasupplicant` |
| Browser | Firefox from Mozilla's apt repo (pinned to Mozilla's build) |
| Security | `lynis`, `clamav`, `rkhunter` (baseline taken at build; re-run `rkhunter --propupd` on first boot — `/var` is provisioned fresh at install) |
| Boot | `linux-image-generic`, `systemd-boot`, dracut initramfs with bootc module, bootc userspace compiled from source |

## Migrate a workstation to it

The numbered scripts are a full migration path: export → install → restore → harden.

```bash
# 1. Back up the current machine to an external drive
#    (apt list, flatpaks, NetworkManager connections, dotfiles/ssh/gpg, /home)
sudo ./01-export-executive-state.sh

# 2. Install the image onto this machine (replaces the current root)
#    (defaults to ghcr.io/sefuwunder/tce-img:latest; pass another ref to override)
sudo ./02-provision-bootc.sh

# 3. Reboot into the bootc environment, then restore your state:
#    home dir, credentials, Wi-Fi/VPN profiles, executive flatpaks
#    (Slack, Zoom, VS Code, Brave, Obsidian), and a dev-ub2404 distrobox
./03-restore-executive-state.sh

# 4. Enable background security auditing
sudo ./04-setup-user-security-services.sh
```

Security timers installed by step 4:

| Timer | Cadence |
|---|---|
| ClamAV scan of Downloads | daily |
| rkhunter rootkit check | weekly |
| Lynis hardening audit | monthly |

## Day-to-day

```bash
bootc status                  # current booted image
sudo bootc upgrade            # pull + stage the latest image, reboot to apply
sudo bootc switch ghcr.io/sefuwunder/tce-img:sha-<commit>  # pin / roll back
```

## How the image is built

`.github/workflows/docker-image.yml` builds with Podman/Buildah and pushes to GHCR:

- on push to `main` touching `Containerfile` or `.github/workflows/**`
- nightly at 02:00 UTC
- manually via **Actions → Run workflow**

Each build is Trivy-scanned (`CRITICAL,HIGH`) and results upload to the Security tab.

### Repo layout

```
Containerfile                        # multi-stage: bootc compiled from source,
                                     # then Ubuntu + workstation + ostree conversion
01-export-executive-state.sh         # back up apt/flatpak/network/dotfiles//home
02-provision-bootc.sh                # bootc install to-existing-root
03-restore-executive-state.sh        # restore home/configs/network + exec flatpaks
04-setup-user-security-services.sh   # ClamAV/rkhunter/Lynis systemd timers
.github/workflows/docker-image.yml   # build, push, scan
```

### Design notes

- The image is based on `docker.io/library/ubuntu:questing` rather than a
  pre-converted bootc base: finished bootc images ship with an empty `/var`
  (ostree state dir), which removes `/var/lib/dpkg` and makes further `apt`
  use impossible.
- `/var` is machine-local state on bootc systems — nothing baked into `/var`
  at build time survives installation. That's why Firefox comes from an apt
  repo (into `/usr`) instead of flatpak, and Distrobox installs with
  `--prefix /usr`.
