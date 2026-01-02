#!/bin/bash

# =======================================================
# Copy dot files
# =======================================================

mkdir -p ~/.config
cp -R config/* ~/.config/

mkdir -p ~/.local/share/applications
cp -R hidden-apps/* ~/.local/share/applications/
# =======================================================
# Install chaotic aur & yay
# =======================================================

# Only add Chaotic-AUR if the architecture is x86_64 so ARM users can build the packages
if [[ "$(uname -m)" == "x86_64" ]]; then
  # Try installing Chaotic-AUR keyring and mirrorlist
  if ! pacman-key --list-keys 3056513887B78AEB >/dev/null 2>&1 &&
    sudo pacman-key --recv-key 3056513887B78AEB &&
    sudo pacman-key --lsign-key 3056513887B78AEB &&
    sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' &&
    sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'; then

    # Add Chaotic-AUR repo to pacman config
    if ! grep -q "chaotic-aur" /etc/pacman.conf; then
      echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' | sudo tee -a /etc/pacman.conf >/dev/null
    fi

    # Install yay directly from Chaotic-AUR
    sudo pacman -Sy --needed --noconfirm yay
  else
    echo "Failed to install Chaotic-AUR, so won't include it in pacman config!"
  fi
fi

# Manually install yay from AUR if not already available
if ! command -v yay &>/dev/null; then
  # Install build tools
  sudo pacman -Sy --needed --noconfirm base-devel
  rm -rf yay-bin
  git clone https://aur.archlinux.org/yay-bin.git
  cd yay-bin
  makepkg -si --noconfirm
  cd -
  rm -rf yay-bin
fi

# Add fun and color to the pacman installer
if ! grep -q "ILoveCandy" /etc/pacman.conf; then
  sudo sed -i '/^\[options\]/a Color\nILoveCandy' /etc/pacman.conf
fi

# ==============================================================================
# Hyprland NVIDIA Setup Script for Arch Linux
# ==============================================================================
# This script automates the installation and configuration of NVIDIA drivers
# for use with Hyprland on Arch Linux, following the official Hyprland wiki.
#
# Author: https://github.com/Kn0ax
#
# ==============================================================================

# --- GPU Detection ---
if [ -n "$(lspci | grep -i 'nvidia')" ]; then
  show_logo
  show_subtext "Install NVIDIA drivers..."

  # --- Driver Selection ---
  # Turing (16xx, 20xx), Ampere (30xx), Ada (40xx), and newer recommend the open-source kernel modules
  if echo "$(lspci | grep -i 'nvidia')" | grep -q -E "RTX [2-9][0-9]|GTX 16"; then
    NVIDIA_DRIVER_PACKAGE="nvidia-open-dkms"
  else
    NVIDIA_DRIVER_PACKAGE="nvidia-dkms"
  fi

  # Check which kernel is installed and set appropriate headers package
  KERNEL_HEADERS="linux-headers" # Default
  if pacman -Q linux-zen &>/dev/null; then
    KERNEL_HEADERS="linux-zen-headers"
  elif pacman -Q linux-lts &>/dev/null; then
    KERNEL_HEADERS="linux-lts-headers"
  elif pacman -Q linux-hardened &>/dev/null; then
    KERNEL_HEADERS="linux-hardened-headers"
  fi

  # Enable multilib repository for 32-bit libraries
  if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
  fi

  # force package database refresh
  sudo pacman -Syy

  # Install packages
  PACKAGES_TO_INSTALL=(
    "${KERNEL_HEADERS}"
    "${NVIDIA_DRIVER_PACKAGE}"
    "nvidia-utils"
    "lib32-nvidia-utils"
    "egl-wayland"
    "libva-nvidia-driver" # For VA-API hardware acceleration
    "qt5-wayland"
    "qt6-wayland"
  )

  yay -S --needed --noconfirm "${PACKAGES_TO_INSTALL[@]}"

  # Configure modprobe for early KMS
  echo "options nvidia_drm modeset=1" | sudo tee /etc/modprobe.d/nvidia.conf >/dev/null

  # Configure mkinitcpio for early loading
  MKINITCPIO_CONF="/etc/mkinitcpio.conf"

  # Define modules
  NVIDIA_MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"

  # Create backup
  sudo cp "$MKINITCPIO_CONF" "${MKINITCPIO_CONF}.backup"

  # Remove any old nvidia modules to prevent duplicates
  sudo sed -i -E 's/ nvidia_drm//g; s/ nvidia_uvm//g; s/ nvidia_modeset//g; s/ nvidia//g;' "$MKINITCPIO_CONF"
  # Add the new modules at the start of the MODULES array
  sudo sed -i -E "s/^(MODULES=\\()/\\1${NVIDIA_MODULES} /" "$MKINITCPIO_CONF"
  # Clean up potential double spaces
  sudo sed -i -E 's/  +/ /g' "$MKINITCPIO_CONF"

  sudo mkinitcpio -P
fi

# =======================================================
# Install greeter (future plans: configure autologin)
# =======================================================

sudo pacman --noconfirm -S greetd greetd-tuigreet niri

sudo mkdir -p /etc/greetd
cat <<EOF | sudo tee /etc/greetd/config.toml > /dev/null
[terminal]
vt = 1

[initial_session]
command = "niri-session"
user = "$(whoami)"

[default_session]
command = "tuigreet --user-menu --cmd 'niri-session'"
user = "$(whoami)"
EOF

sudo systemctl enable greetd.service
sudo systemctl set-default graphical.target

# =======================================================
# Install content of packages.txt, docker, firewall 
# =======================================================

yay -Syu --needed --noconfirm - < <(grep -v '^#' packages.txt | grep -v '^$')

# Limit log size to avoid running out of disk
sudo mkdir -p /etc/docker
echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"5"}}' | sudo tee /etc/docker/daemon.json

# Give this user privileged Docker access
sudo usermod -aG docker $USER

# Prevent Docker from preventing boot for network-online.target
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/no-block-boot.conf <<'EOF'
[Unit]
DefaultDependencies=no
EOF

# Enable ufw and docker services

sudo systemctl daemon-reload

sudo systemctl enable docker.service
sudo systemctl enable ufw.service

# Allow nothing in, everything out
sudo ufw default deny incoming
sudo ufw default allow outgoing
# Allow ports for LocalSend
sudo ufw allow 53317/udp
sudo ufw allow 53317/tcp
# Allow SSH in
sudo ufw allow 22/tcp
# Allow Docker containers to use DNS on host
sudo ufw allow in on docker0 to any port 53
# Turn on the firewall
sudo ufw enable
sudo ufw reload

# =======================================================
# Enable flatpak and bazaar
# =======================================================

sudo pacman -Syu --noconfirm --needed flatpak xdg-desktop-portal xdg-desktop-portal-gtk

sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

flatpak install -y --noninteractive flathub io.github.kolunmi.Bazaar

# =======================================================
# Enable misc. services & stuff
# =======================================================

gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal foot
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal keybindings '<Ctrl><Alt>t'
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal new-tab true
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal flatpak system

rustup install stable

chmod +x ~/.config/bin/battery-monitor

mkdir -p ~/Desktop
mkdir -p ~/Documents
mkdir -p ~/Downloads
mkdir -p ~/Music
mkdir -p ~/Pictures
mkdir -p ~/Public
mkdir -p ~/Templates
mkdir -p ~/Videos

ln -sr ~/.config/Wallpapers ~/Pictures/Wallpapers

sudo systemctl daemon-reload

systemctl --user enable foot-server.service
systemctl --user enable battery-monitor.service
systemctl --user enable battery-monitor.timer
sudo systemctl enable swayosd-libinput-backend.service

sudo usermod -aG video $USER
sudo usermod -aG uucp $USER

sudo chsh -s /usr/bin/fish $USER

trash ~/neelix/

reboot
