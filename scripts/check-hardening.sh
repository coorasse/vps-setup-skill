#!/usr/bin/env bash
# check-hardening.sh — verify the protections applied by provision.sh + harden-ssh.sh.
# READ-ONLY: it changes nothing, only inspects. Exit 0 = all required checks pass,
# 1 = at least one required check FAILED. WARNs do not affect the exit code.
#
# Run on the server as root (or a passwordless-sudo user). Two ways:
#
#   # piped from your laptop (deploy user has NOPASSWD sudo):
#   ssh DEPLOY_USER@SERVER_IP 'sudo bash -s' -- DEPLOY_USER < check-hardening.sh
#
#   # or copied onto the box:
#   sudo ./check-hardening.sh DEPLOY_USER
#
# Argument:
#   DEPLOY_USER  the non-root user provision.sh created (default: deploy)

set -uo pipefail   # deliberately NOT -e: every check must run even if one fails

DEPLOY_USER="${1:-deploy}"
PASS=0; FAIL=0; WARN=0

if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi

c_ok="\033[32m"; c_bad="\033[31m"; c_warn="\033[33m"; c_b="\033[1m"; c_z="\033[0m"
ok()   { printf "  ${c_ok}PASS${c_z} %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  ${c_bad}FAIL${c_z} %s\n" "$1"; FAIL=$((FAIL+1)); }
warn() { printf "  ${c_warn}WARN${c_z} %s\n" "$1"; WARN=$((WARN+1)); }
hdr()  { printf "\n${c_b}%s${c_z}\n" "$1"; }

# --- SSH hardening (authoritative: effective sshd config) ---------------------
hdr "SSH hardening"
sshd_cfg="$($SUDO sshd -T 2>/dev/null)"
if [ -z "$sshd_cfg" ]; then
  bad "Could not read effective sshd config (need root / sshd present)"
else
  echo "$sshd_cfg" | grep -qi '^passwordauthentication no'      && ok "PasswordAuthentication disabled"        || bad "PasswordAuthentication is NOT disabled"
  echo "$sshd_cfg" | grep -qi '^permitrootlogin no'            && ok "Root login disabled"                   || bad "PermitRootLogin is not 'no'"
  echo "$sshd_cfg" | grep -qi '^kbdinteractiveauthentication no' && ok "KbdInteractiveAuthentication disabled" || warn "KbdInteractiveAuthentication not disabled"
fi

# --- Firewall (UFW) ----------------------------------------------------------
hdr "Firewall (UFW)"
ufw_status="$($SUDO ufw status verbose 2>/dev/null)"
echo "$ufw_status" | grep -q 'Status: active'              && ok "UFW active"               || bad "UFW is not active"
echo "$ufw_status" | grep -qi 'deny (incoming)'            && ok "Default incoming = deny"  || bad "Default incoming policy is not deny"
for p in 22 80 443; do
  echo "$ufw_status" | grep -qE "(^|[^0-9])${p}/tcp" && ok "Port ${p}/tcp allowed" || warn "Port ${p}/tcp not found in UFW rules"
done

# --- fail2ban ----------------------------------------------------------------
hdr "fail2ban"
$SUDO systemctl is-active  --quiet fail2ban && ok "fail2ban running"          || bad "fail2ban not running"
$SUDO systemctl is-enabled --quiet fail2ban && ok "fail2ban enabled at boot"  || warn "fail2ban not enabled at boot"
$SUDO fail2ban-client status sshd >/dev/null 2>&1 && ok "sshd jail active"    || bad "sshd jail not active"

# --- Automatic security updates ----------------------------------------------
hdr "Automatic security updates"
dpkg -s unattended-upgrades >/dev/null 2>&1 && ok "unattended-upgrades installed" || bad "unattended-upgrades not installed"
auf=/etc/apt/apt.conf.d/20auto-upgrades
if [ -f "$auf" ] && grep -q 'Unattended-Upgrade "1"' "$auf" && grep -q 'Update-Package-Lists "1"' "$auf"; then
  ok "APT periodic auto-upgrade config present"
else
  bad "20auto-upgrades config missing or incomplete"
fi

# --- Automatic reboot window (optional) --------------------------------------
hdr "Automatic reboot window (optional)"
arf=/etc/apt/apt.conf.d/51auto-reboot
if [ -f "$arf" ] && grep -qi 'Automatic-Reboot "true"' "$arf"; then
  t=$(grep -i 'Automatic-Reboot-Time' "$arf" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1)
  tz=$(timedatectl show -p Timezone --value 2>/dev/null)
  ok "Auto-reboot enabled at ${t:-?} ${tz:+($tz)}"
else
  warn "Auto-reboot not configured (optional)"
fi
if [ -f /var/run/reboot-required ]; then
  warn "A reboot is currently pending (/var/run/reboot-required)"
fi

# --- Swap --------------------------------------------------------------------
hdr "Swap"
if $SUDO swapon --show 2>/dev/null | grep -q .; then
  ok "Swap active ($($SUDO swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'))"
else
  warn "No swap active"
fi
sw=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
[ "$sw" -le 20 ] && ok "vm.swappiness = $sw" || warn "vm.swappiness = $sw (expected <= 20)"

# --- Deploy user -------------------------------------------------------------
hdr "Deploy user (${DEPLOY_USER})"
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  ok "User exists"
  id -nG "$DEPLOY_USER" 2>/dev/null | grep -qw docker && ok "In docker group" || warn "Not in docker group"
  [ -f "/etc/sudoers.d/${DEPLOY_USER}" ] && ok "Dedicated sudoers file present" || warn "No /etc/sudoers.d/${DEPLOY_USER}"
  $SUDO test -s "/home/${DEPLOY_USER}/.ssh/authorized_keys" && ok "authorized_keys present" || bad "No authorized_keys for ${DEPLOY_USER}"
else
  bad "User ${DEPLOY_USER} does not exist"
fi

# --- Docker ------------------------------------------------------------------
hdr "Docker"
$SUDO systemctl is-active --quiet docker && ok "Docker running" || bad "Docker not running"

# --- Public listeners (informational) ----------------------------------------
hdr "Publicly-bound TCP ports (informational)"
pub=$($SUDO ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]|::):' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un)
if [ -z "$pub" ]; then
  warn "Could not enumerate listening sockets"
else
  for port in $pub; do
    case "$port" in
      22|80|443) ok "Public port ${port} (expected)";;
      *) warn "Public port ${port} bound to all interfaces — review whether it should be exposed";;
    esac
  done
fi

# --- Summary -----------------------------------------------------------------
hdr "Summary"
printf "PASS=%d  WARN=%d  FAIL=%d\n" "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf "${c_ok}All required checks passed.${c_z}\n"
  exit 0
else
  printf "${c_bad}%d required check(s) FAILED.${c_z}\n" "$FAIL"
  exit 1
fi
