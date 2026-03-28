#!/bin/bash

sudo pacman -Sy --needed --noconfirm ufw

# Enable ufw and docker services

sudo systemctl daemon-reload

sudo systemctl enable ufw.service

# Allow nothing in, everything out
sudo ufw default deny incoming
sudo ufw default allow outgoing
# Allow ports for LocalSend
sudo ufw allow 53317/udp
sudo ufw allow 53317/tcp
# Allow SSH in
sudo ufw allow 22/tcp
# Turn on the firewall
sudo ufw enable
sudo ufw reload

