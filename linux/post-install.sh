#!/bin/bash
# @name: Post-install setup
# @description: Base tools, optional QoL tools and bashrc injection
# @os: Ubuntu
#
# Run directly:
# bash <(curl -fsSL https://raw.githubusercontent.com/CrazyWolf13/code-snippets-scripts/main/linux/post-install.sh)

# Fallbacks for running outside Nexterm, where the @NEXTERM: lines are not rewritten
@NEXTERM:STEP() { echo "==> $1"; }
@NEXTERM:INFO() { echo "$1"; }
@NEXTERM:SUCCESS() { echo "$1"; }
@NEXTERM:INPUT() { read -rp "$2: " "$1"; }
@NEXTERM:SELECT() { local var=$1 prompt=$2; shift 2; echo "$prompt"; select o in "$@"; do printf -v "$var" %s "$o"; break; done; }
@NEXTERM:SUMMARY() { echo "== $1"; shift; while [ $# -gt 1 ]; do echo "$1: $2"; shift 2; done; }

has_gui() {
    [ -n "${DISPLAY}${WAYLAND_DISPLAY}${MIR_SOCKET}" ]
}

@NEXTERM:SELECT QOL "Install quality of life tools (bat, eza, fzf, cmatrix, duf, grc, oh-my-posh)?" "Yes" "No"
@NEXTERM:SELECT BASHRC "Inject custom settings into .bashrc?" "Yes" "No"
if [ "$BASHRC" = "Yes" ]; then
    @NEXTERM:INPUT TOKEN "GitHub personal access token"
fi

if has_gui; then
    @NEXTERM:STEP "Installing GUI packages"
    sudo apt install -y flameshot
fi

@NEXTERM:STEP "Installing base packages"
sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
sudo apt update
sudo apt upgrade -y
sudo apt install -y nala btop screen fastfetch git fdisk xclip

if [ "$QOL" = "Yes" ]; then
    @NEXTERM:STEP "Installing quality of life tools"
    sudo apt install -y bat eza fzf cmatrix duf grc
    curl -fsSL https://ohmyposh.dev/install.sh | bash
fi

if [ "$BASHRC" = "Yes" ]; then
    @NEXTERM:STEP "Injecting custom settings into .bashrc"
    {
        echo "ACCESS_TOKEN=$TOKEN"
        echo "bash <(curl -H \"Authorization: token $TOKEN\" -sSL https://raw.githubusercontent.com/CrazyWolf13/chezmoi/refs/heads/main/dot_bashrc)"
    } >> ~/.bashrc
fi

IP=$(hostname -I | awk '{print $1}')
HOST=$(hostname)
@NEXTERM:SUCCESS "Post-install finished"
@NEXTERM:SUMMARY "Machine" "Hostname" "$HOST" "IP" "$IP" "QoL tools" "$QOL" ".bashrc injected" "$BASHRC"
