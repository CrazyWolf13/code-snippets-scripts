#!/bin/bash
# @name: Post-install setup
# @description: Base tools, optional QoL tools and bashrc injection (interactive)
#
# Run directly:
# bash <(curl -fsSL https://raw.githubusercontent.com/CrazyWolf13/code-snippets-scripts/main/linux/post-install.sh)

ask() {
    local answer
    read -rp "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

has_gui() {
    [ -n "${DISPLAY}${WAYLAND_DISPLAY}${MIR_SOCKET}" ]
}

gui_install() {
    echo "Installing GUI-specific packages..."
    sudo apt install -y flameshot
}

server_install() {
    echo "Installing server-specific packages..."
}

general_install() {
    echo "Running general installation tasks..."
    sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
    sudo apt update
    sudo apt upgrade -y
    sudo apt install -y nala btop screen fastfetch git fdisk xclip
    clear
    echo "IP is: $(hostname -I | awk '{print $1}')"
    echo "Hostname is: $(hostname)"
    echo "Done!"
}

install_qol_tools() {
    if ask "Do you want to install quality of life tools (bat, eza, fzf, cmatrix, duf, grc, oh-my-posh)?"; then
        echo "Installing quality of life tools..."
        sudo apt install -y bat eza fzf cmatrix duf grc
        curl -fsSL https://ohmyposh.dev/install.sh | bash
        echo "Quality of life tools installed!"
    else
        echo "Skipping quality of life tools installation."
    fi
}

inject_bashrc() {
    if ask "Do you want to inject custom settings into your .bashrc file?"; then
        local token
        read -rsp "Enter your GitHub personal access token: " token
        echo
        echo "Injecting custom settings into .bashrc..."
        {
            echo "ACCESS_TOKEN=$token"
            echo "bash <(curl -H \"Authorization: token $token\" -sSL https://raw.githubusercontent.com/CrazyWolf13/chezmoi/refs/heads/main/dot_bashrc)"
        } >> ~/.bashrc
        echo "Custom settings have been injected into your .bashrc."
    else
        echo "Skipping .bashrc injection."
    fi
}

if has_gui; then
    echo "GUI environment detected. Running GUI-specific installation..."
    gui_install
else
    echo "No GUI environment detected. Running server-specific installation..."
    server_install
fi

general_install
install_qol_tools
inject_bashrc
