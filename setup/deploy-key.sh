# @name: Setup: Deploy Nexterm and emergency keys
# @description: Deploys an IP-Restricted Pubkey of Nexterm and Emergency Key
# @os: Debian, Ubuntu

#!/bin/sh
set -eu #
NEXTERM_IP="10.10.20.16" #
NEXTERM_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHQ9vmsolyPNE2tEo+Fry1tRya+I8j7u1iWnP0daEvbx nexterm-gateway" #
EMERGENCY_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILDGW7YxevLJYybxnjIECbA4euCVQvmeP/nIXHZhT1vj emergency-homelab" #
#
AK="$HOME/.ssh/authorized_keys" #
#
mkdir -p "$HOME/.ssh" #
chmod 700 "$HOME/.ssh" 2>/dev/null || true #
touch "$AK" #
chmod 600 "$AK" 2>/dev/null || true #
#
add_key() { #
  label="$1"; key="$2"; prefix="$3" #
  body=$(echo "$key" | awk '{print $2}') #
  if grep -qF "$body" "$AK"; then #
    echo "$(hostname): $label key already present" #
  else #
    if [ -s "$AK" ] && [ -n "$(tail -c1 "$AK")" ]; then echo >> "$AK"; fi #
    echo "${prefix}${key}" >> "$AK" #
    echo "$(hostname): $label key added" #
  fi #
} #
#
add_key "Nexterm"   "$NEXTERM_KEY"   "from=\"${NEXTERM_IP}\" " #
add_key "emergency" "$EMERGENCY_KEY" "" #
#
cat "$AK" #
