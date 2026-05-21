#!/usr/bin/env bash
# Provision a fresh Ubuntu VPS for Kamal deployments.
# Run as root on the server. Idempotent — safe to re-run.
#
# Usage (piped from your laptop):
#   ssh root@SERVER_IP 'bash -s' -- DEPLOY_USER SWAP_SIZE < provision.sh
#
# Arguments:
#   DEPLOY_USER  non-root user Kamal will deploy as (default: deploy)
#   SWAP_SIZE    size of the swap file (default: 2G)
#
# This does NOT disable root login or password auth — run harden-ssh.sh for
# that, only AFTER you have confirmed the deploy user can log in with a key.
set -euo pipefail

DEPLOY_USER="${1:-deploy}"
SWAP_SIZE="${2:-2G}"

echo ">>> Provisioning VPS for deploy user '${DEPLOY_USER}' (swap ${SWAP_SIZE})"

# --- System update -----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# --- Base packages -----------------------------------------------------------
apt-get install -y docker.io curl ufw fail2ban unattended-upgrades
systemctl enable --now docker

# --- Automatic security updates ----------------------------------------------
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl restart unattended-upgrades || true

# --- fail2ban (SSH brute-force protection) -----------------------------------
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# --- Firewall (UFW) ----------------------------------------------------------
# NOTE: Docker manipulates iptables directly and can bypass UFW for *published*
# container ports. Kamal only publishes 80/443 (via kamal-proxy), which we open
# anyway, so this stays consistent. UFW still guards SSH and the host itself.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw logging on
ufw --force enable

# --- Swap --------------------------------------------------------------------
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l "${SWAP_SIZE}" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
grep -q '/swapfile' /etc/fstab || echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
sysctl -w vm.swappiness=20 >/dev/null
# Persist via /etc/sysctl.d (newer Ubuntu, e.g. 26.04, ships no /etc/sysctl.conf).
echo 'vm.swappiness=20' > /etc/sysctl.d/99-swappiness.conf

# --- Non-root deploy user ----------------------------------------------------
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${DEPLOY_USER}"
fi
usermod -aG docker "${DEPLOY_USER}"

install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
  cp /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
else
  echo "!!! /root/.ssh/authorized_keys not found — add the deploy user's key manually" >&2
fi

# Passwordless sudo (Kamal needs non-interactive sudo).
echo "${DEPLOY_USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
chmod 0440 "/etc/sudoers.d/${DEPLOY_USER}"
visudo -c -f "/etc/sudoers.d/${DEPLOY_USER}"

echo ""
echo ">>> Provisioning complete."
echo ">>> Verify the deploy user works:  ssh ${DEPLOY_USER}@<SERVER_IP> 'docker ps'"
echo ">>> SSH is NOT yet hardened. Only after that check passes, run harden-ssh.sh."
if [ -f /var/run/reboot-required ]; then
  echo ">>> A reboot is required to finish applying kernel/security updates."
fi
