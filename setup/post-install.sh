#!/bin/bash
# @name: Setup: Post-install
# @description: Base and server tools, hardware tools on bare metal, optional QoL tools and bashrc injection
# @os: Ubuntu
#
# Run directly:
# bash <(curl -fsSL https://raw.githubusercontent.com/CrazyWolf13/code-snippets-scripts/main/setup/post-install.sh)

# Nexterm adds set -e itself, this makes a direct run behave the same
set -e

# Fallbacks for running outside Nexterm, where the @NEXTERM: lines are not rewritten
@NEXTERM:STEP() { echo "==> $1"; }
@NEXTERM:INFO() { echo "$1"; }
@NEXTERM:WARN() { echo "WARNING: $1"; }
@NEXTERM:SUCCESS() { echo "$1"; }
@NEXTERM:INPUT() { read -rp "$2: " "$1"; }
@NEXTERM:SELECT() { local var=$1 prompt=$2; shift 2; echo "$prompt"; select o in "$@"; do printf -v "$var" %s "$o"; break; done; }
@NEXTERM:SUMMARY() { echo "== $1"; shift; while [ $# -gt 1 ]; do echo "$1: $2"; shift 2; done; }

# LXCs often run as root without sudo installed (Nexterm turns "sudo" into "sudo -S")
if [ "$(id -u)" -eq 0 ] && ! command -v sudo >/dev/null; then
    sudo() { [ "$1" = "-S" ] && shift; "$@"; }
fi

# No prompts from apt, dpkg config files or needrestart
APT="env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

. /etc/os-release

# Prints only the packages the configured repos actually offer
available() {
    for p in "$@"; do
        apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^(]' && echo "$p"
    done
    return 0
}

has_gui() {
    # A display manager (GDM, SDDM, LightDM) also counts, so it works over SSH and Nexterm too
    [ -n "${DISPLAY}${WAYLAND_DISPLAY}${MIR_SOCKET}" ] || [ -e /etc/systemd/system/display-manager.service ]
}

@NEXTERM:SELECT QOL "Install quality of life tools (bat, eza, fzf, cmatrix, duf, grc, oh-my-posh)?" "Yes" "No"
@NEXTERM:SELECT BASHRC "Inject custom settings into .bashrc?" "Yes" "No"
if [ "$BASHRC" = "Yes" ]; then
    @NEXTERM:INPUT TOKEN "GitHub personal access token"
fi

@NEXTERM:STEP "Updating the system"
sudo $APT update
sudo $APT upgrade

@NEXTERM:STEP "Installing base and server tools"
sudo $APT install nala btop screen git fdisk curl wget jq unzip rsync tree ncdu lsof dnsutils mtr-tiny

# fastfetch is in the Ubuntu repos from 24.10 on, older releases skip it
if [ -n "$(available fastfetch)" ]; then
    sudo $APT install fastfetch
else
    @NEXTERM:WARN "fastfetch not available on $PRETTY_NAME, skipped"
fi

# Sensors, disks and NICs are only visible on bare metal, not in VMs or LXCs
if ! systemd-detect-virt -q 2>/dev/null; then
    HW="Yes"
    @NEXTERM:STEP "Installing hardware tools"
    sudo $APT install lm-sensors smartmontools nvme-cli ethtool
else
    HW="No ($(systemd-detect-virt 2>/dev/null))"
fi

if has_gui; then
    @NEXTERM:STEP "Installing GUI packages"
    sudo $APT install flameshot xclip
fi

if [ "$QOL" = "Yes" ]; then
    @NEXTERM:STEP "Installing quality of life tools"
    # eza is missing on 22.04, so only install what the release offers
    sudo $APT install $(available bat eza fzf cmatrix duf grc)
    # pipefail, otherwise a failed download pipes nothing into bash and counts as success
    if ! (set -o pipefail; curl -fsSL https://ohmyposh.dev/install.sh | bash); then
        @NEXTERM:WARN "oh-my-posh install failed"
    fi
fi

if [ "$BASHRC" = "Yes" ]; then
    @NEXTERM:STEP "Injecting custom settings into .bashrc"
    if grep -q 'CrazyWolf13/chezmoi' ~/.bashrc 2>/dev/null; then
        @NEXTERM:INFO ".bashrc already has the custom settings, skipped"
        BASHRC="already present"
    else
        {
            echo "ACCESS_TOKEN=$TOKEN"
            echo "bash <(curl -H \"Authorization: token $TOKEN\" -sSL https://raw.githubusercontent.com/CrazyWolf13/chezmoi/refs/heads/main/dot_bashrc)"
        } >> ~/.bashrc
    fi
fi

IP=$(hostname -I | awk '{print $1}')
HOST=$(hostname)
@NEXTERM:SUCCESS "Post-install finished"
@NEXTERM:SUMMARY "Machine" "Hostname" "$HOST" "IP" "$IP" "OS" "$PRETTY_NAME" "Hardware tools" "$HW" "QoL tools" "$QOL" ".bashrc injected" "$BASHRC"
