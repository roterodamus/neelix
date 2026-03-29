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


# =======================================================
# Install greeter (future plans: configure autologin)
# =======================================================

sudo pacman --needed --noconfirm -S greetd greetd-tuigreet niri

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
# Install content of packages.txt
# =======================================================

yay -Syu --needed --noconfirm - < <(grep -v '^#' packages.txt | grep -v '^$')

# =======================================================
# Enable misc. services & stuff
# =======================================================

gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal foot
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal keybindings '<Ctrl><Alt>t'
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal new-tab true
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal flatpak system

chmod +x ~/.config/bin/battery-monitor
chmod +x ~/neelix/post_install/realtime-setup.sh
chmod +x ~/neelix/post_install/install_firewall.sh
chmod +x ~/neelix/post_install/install_docker.sh
chmod +x ~/neelix/post_install/install_devtools.sh
chmod +x ~/neelix/post_install/install_flatpak.sh

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

systemctl --user enable battery-monitor.service
systemctl --user enable battery-monitor.timer
sudo systemctl enable swayosd-libinput-backend.service

sudo usermod -aG video $USER
sudo usermod -aG uucp $USER

sudo chsh -s /usr/bin/fish $USER

# =======================================================
# Prompt user to run post install scripts
# =======================================================

prompt_run() {
  local prompt="$1"
  local cmd="$2"
  while true; do
    read -r -p "$prompt [y/n] " ans
    case "$ans" in
      [Yy]|[Yy][Ee][Ss])
        "$cmd"
        break
        ;;
      [Nn]|[Nn][Oo])
        echo "Skipped: $cmd"
        break
        ;;
      *)
        echo "Please answer y/yes or n/no."
        ;;
    esac
  done
}

clear
prompt_run "Install firewall?" ./post_install/install_firewall.sh
clear
prompt_run "Install Flatpak?" ./post_install/install_flatpak.sh
clear
prompt_run "Run realtime setup?" ./post_install/realtime-setup.sh
prompt_run "Install dev tools?" ./post_install/install_devtools.sh
clear
prompt_run "Install Docker?" ./post_install/install_docker.sh
clear
echo "Moved Neelix install folder to trash"
trash ~/neelix/
sleep 2
clear
echo "Rebooting in 3 seconds"
sleep 1
clear
echo "Rebooting in 2 seconds"
sleep 1
clear
echo "Rebooting in 1 seconds"
sleep 1
clear
echo "Rebooting"

reboot
