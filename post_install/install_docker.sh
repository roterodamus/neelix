#!/bin/bash

sudo pacman -Sy --needed --noconfirm docker docker-buildx docker-compose

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

# Enable docker services
sudo systemctl daemon-reload
sudo systemctl enable docker.service

# Allow Docker containers to use DNS on host
sudo ufw allow in on docker0 to any port 53
sudo ufw reload

