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
