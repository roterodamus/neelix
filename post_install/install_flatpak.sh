#!/bin/bash

sudo pacman -Sy --needed --noconfirm flatpak

sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

flatpak install -y --noninteractive flathub io.github.kolunmi.Bazaar

