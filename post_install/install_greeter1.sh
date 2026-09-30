#!/usr/bin/env bash

set -e

USERNAME="$(whoami)"

echo "======================================"
echo "       Arch Linux Login Setup"
echo "======================================"
echo
echo "1) Install greetd + tuigreet"
echo "2) Install greetd + tuigreet + autologin"
echo "3) Autologin to TTY"
echo "4) Exit"
echo

read -rp "Select an option [1-4]: " choice

case "$choice" in

    1)
        echo
        echo "Installing greetd + tuigreet..."

        sudo pacman --needed --noconfirm -S greetd greetd-tuigreet

        sudo mkdir -p /etc/greetd

        sudo tee /etc/greetd/config.toml > /dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --user-menu --cmd 'niri-session'"
user = "greeter"
EOF

        sudo systemctl enable greetd.service
        sudo systemctl set-default graphical.target

        echo
        echo "greetd + tuigreet installed."
        echo "Reboot to start greetd."
        ;;

    2)
        echo
        echo "Installing greetd + tuigreet with autologin..."

        sudo pacman --needed --noconfirm -S greetd greetd-tuigreet

        sudo mkdir -p /etc/greetd

        sudo tee /etc/greetd/config.toml > /dev/null <<EOF
[terminal]
vt = 1

[initial_session]
command = "niri-session"
user = "$USERNAME"

[default_session]
command = "tuigreet --user-menu --cmd 'niri-session'"
user = "$USERNAME"
EOF

        sudo systemctl enable greetd.service
        sudo systemctl set-default graphical.target

        echo
        echo "greetd + tuigreet + autologin configured."
        echo "User: $USERNAME"
        echo "Reboot to apply the changes."
        ;;

    3)
        echo
        echo "Configuring TTY1 autologin for $USERNAME..."

        sudo mkdir -p /etc/systemd/system/getty@tty1.service.d

        sudo tee /etc/systemd/system/getty@tty1.service.d/skip-prompt.conf > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --skip-login --nonewline --noissue --autologin $USERNAME --noreset --noclear - \${TERM}
EOF

        sudo systemctl daemon-reload

        echo
        echo "TTY1 autologin configured."
        echo "User: $USERNAME"
        echo "Reboot to apply the changes."
        ;;

    4)
        echo "Exiting."
        exit 0
        ;;

    *)
        echo "Invalid option."
        exit 1
        ;;

esac
