#!/bin/bash

curl -O https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xvf cachyos-repo.tar.xz
cd cachyos-repo
sudo ./cachyos-repo.sh
sudo pacman -Scc
sudo pacman -Sy
pacman -Qqn | sudo pacman -S -
sudo pacman -Syu
