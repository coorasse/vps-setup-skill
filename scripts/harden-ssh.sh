#!/usr/bin/env bash
# Lock down SSH on an Ubuntu VPS: disable password auth and root login.
# Run as root, and ONLY after you have confirmed the non-root deploy user can
# SSH in with its key — otherwise you can lock yourself out.
#
# Usage (piped from your laptop):
#   ssh root@SERVER_IP 'bash -s' < harden-ssh.sh
set -euo pipefail

cat > /etc/ssh/sshd_config.d/91-require-ssh-keys.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

cat > /etc/ssh/sshd_config.d/92-disable-root-login.conf <<'EOF'
PermitRootLogin no
EOF

# Validate config before restarting so a typo can't break sshd.
sshd -t
systemctl restart ssh 2>/dev/null || systemctl restart sshd

echo ">>> SSH hardened: password authentication and root login are now disabled."
