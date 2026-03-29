#!/bin/bash

sudo pacman -Sy --needed --noconfirm ripgrep jq taplo-cli marksman rustup lldb rust-analyzer

systemctl --user enable foot-server.service

rustup install stable
