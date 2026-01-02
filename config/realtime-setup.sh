#!/bin/bash

# Install the required packages
sudo pacman -Syu realtime-privileges cpupower

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
