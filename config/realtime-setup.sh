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

echo
echo "IMPORTANT: Manual steps required:"
echo
echo "  1) Add the kernel parameter 'threadirqs' to your boot loader configuration (e.g., GRUB or systemd-boot)."
echo "     This typically involves editing your boot loader's kernel line and regenerating the config."
echo "     For more details, see:"
echo
echo "     https://wiki.archlinux.org/title/Kernel_parameters#Boot_loader_configuration"
echo
echo
echo "  2) Disable Hyper-Threading (SMT) in your system UEFI/BIOS firmware."
echo "     Reboot, enter the firmware settings, and disable SMT/Hyper-Threading for best realtime performance."
echo
echo "After making these changes, reboot the system for them to take effect."
echo
