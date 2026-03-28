#!/bin/bash

# Install the required packages
sudo pacman -Syu --needed --noconfirm realtime-privileges cpupower

# Append limits to /etc/security/limits.conf
{
    echo "$USER   hard    memlock     unlimited"
    echo "$USER   soft    memlock     unlimited"
    echo "$USER   hard    rtprio      99"
    echo "$USER   soft    rtprio      99"
} | sudo tee -a /etc/security/limits.conf

# Add user to groups
sudo usermod -aG audio $USER
sudo usermod -aG realtime $USER

# Create or append to /etc/sysctl.d/99-swappiness.conf
echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf

# Apply the new sysctl settings
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf

# Set CPU frequency scaling to peformance
{
    echo "governor='performance'"
} | sudo tee -a /etc/default/cpupower

sudo systemctl enable cpupower.service

# Neelix specific things
yay -Sy --needed --noconfirm pw-lat millisecond-bin
yay -Rns --noconfirm network-manager-applet

systemctl --user disable battery-monitor.timer --now
systemctl --user disable foot-server.service --now
sudo systemctl disable swayosd-libinput-backend.service --now
sudo systemctl disable docker.service --now
sudo systemctl disable docker.socket --now

clear
echo
echo "IMPORTANT: Manual steps required:"
echo
echo "  1) Add the kernel parameter 'threadirqs' to your boot loader configuration (e.g., GRUB or systemd-boot)."
echo "     This typically involves editing your boot loader's kernel line and regenerating the config."
echo "     For more details, see:"
echo
echo "     https://wiki.archlinux.org/title/Kernel_parameters#Boot_loader_configuration"
echo
echo "     Optional:"
echo
echo "  2) A. Disable Hyper-Threading (SMT) in your system UEFI/BIOS firmware."
echo "     B. Or add the kernel parameter 'nosmt' to your boot loader's kernel line like above."
echo
echo "After making these changes, reboot the system for them to take effect."
echo "Use Millisecond to check if settings are applied"
echo
