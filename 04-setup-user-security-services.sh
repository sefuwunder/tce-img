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

cat << 'EOF' > /etc/systemd/system/clamav-downloads-scan.service
[Unit]
Description=Low-priority ClamAV Scan of User Downloads
After=network.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/clamscan -r --no-summary --infected /home/* /Downloads
EOF

cat << 'EOF' > /etc/systemd/system/clamav-downloads-scan.timer
[Unit]
Description=Run ClamAV Downloads Scan Daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

# -------------------------------------------------------------------
# 2. Rkhunter: Weekly Rootkit Check
# -------------------------------------------------------------------
echo "[+] Configuring weekly Rkhunter audit..."

cat << 'EOF' > /etc/systemd/system/rkhunter-audit.service
[Unit]
Description=Weekly Rootkit Hunter System Check
After=network.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/rkhunter --check --cronjob --report-warnings-only
EOF

cat << 'EOF' > /etc/systemd/system/rkhunter-audit.timer
[Unit]
Description=Run Rkhunter Weekly

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=2h

[Install]
WantedBy=timers.target
EOF

# -------------------------------------------------------------------
# 3. Lynis: Monthly Hardening Audit
# -------------------------------------------------------------------
echo "[+] Configuring monthly Lynis hardening audit..."

cat << 'EOF' > /etc/systemd/system/lynis-audit.service
[Unit]
Description=Monthly Lynis Security Audit
After=network.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/lynis audit system --quiet --cronjob
EOF

cat << 'EOF' > /etc/systemd/system/lynis-audit.timer
[Unit]
Description=Run Lynis System Audit Monthly

[Timer]
OnCalendar=monthly
Persistent=true
RandomizedDelaySec=4h

[Install]
WantedBy=timers.target
EOF

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
