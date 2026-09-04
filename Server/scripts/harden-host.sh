#!/usr/bin/env bash
# Host hardening for the Budget server VM. Run ON the VM (needs sudo):
#
#   ssh -t mmice@<vm> 'bash -s' < Server/scripts/harden-host.sh
#
# Does two things:
#   1. Disables SSH password authentication and root login (key-only access).
#   2. Installs unattended-upgrades so security patches land automatically.
#
# Both are claims made in docs/security/access-control-policy.md, so run this
# before relying on that document.
#
# Deliberately NOT done here: MFA on the Proxmox hypervisor, which is a web-UI
# change on the Proxmox host itself, not this VM. See the policy for the steps.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

echo "==> Checking that key-based login will still work"
# The failure mode here is locking yourself out of your own server, so this is
# checked before anything is changed rather than discovered afterwards.
keyfile=""
for f in "$HOME/.ssh/authorized_keys" "$HOME/.ssh/authorized_keys2"; do
  [[ -s "$f" ]] && keyfile="$f" && break
done
if [[ -z "$keyfile" ]]; then
  echo "REFUSING: no authorized_keys found for $USER." >&2
  echo "Disabling password auth now would lock you out of this machine." >&2
  echo "Install your public key first:  ssh-copy-id $USER@\$(hostname -I | awk '{print \$1}')" >&2
  exit 1
fi
echo "    found $(grep -c . "$keyfile") key(s) in $keyfile"

echo "==> Disabling SSH password authentication and root login"
# A drop-in rather than editing sshd_config, so a package upgrade to the main
# file cannot silently revert this.
$SUDO tee /etc/ssh/sshd_config.d/10-budget-hardening.conf >/dev/null <<'CONF'
# Managed by Server/scripts/harden-host.sh — see docs/security/access-control-policy.md
# Key-only access. Password auth on an internet-adjacent host holding financial
# data is a standing invitation to credential stuffing.
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
CONF

echo "==> Validating sshd config before applying"
# If this fails we stop with the old config still live and the session open.
if ! $SUDO sshd -t; then
  echo "sshd config invalid — removing the drop-in and leaving SSH untouched." >&2
  $SUDO rm -f /etc/ssh/sshd_config.d/10-budget-hardening.conf
  exit 1
fi

$SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd
echo "    reloaded. Your current session stays open — test a NEW one before"
echo "    closing this one."

echo "==> Installing unattended-upgrades"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get -qq update
$SUDO apt-get -qq install -y unattended-upgrades apt-listchanges

# Enable automatic security updates without the interactive debconf prompt.
$SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
CONF

$SUDO systemctl enable --now unattended-upgrades

echo
echo "==> Verifying"
printf '    PasswordAuthentication: '; $SUDO sshd -T | grep -i '^passwordauthentication' | awk '{print $2}'
printf '    PermitRootLogin:        '; $SUDO sshd -T | grep -i '^permitrootlogin' | awk '{print $2}'
printf '    unattended-upgrades:    '; systemctl is-active unattended-upgrades || true
echo
echo "Done. Now, in a SEPARATE terminal, confirm you can still log in:"
echo "    ssh $USER@$(hostname -I | awk '{print $1}')"
echo "Do not close this session until that works."
