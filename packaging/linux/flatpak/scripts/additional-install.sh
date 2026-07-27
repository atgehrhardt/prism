#!/bin/sh

# User Service
mkdir -p ~/.config/systemd/user
cp "/app/share/prism/systemd/user/app-dev.lizardbyte.app.Prism.service" "$HOME/.config/systemd/user/app-dev.lizardbyte.app.Prism.service"
echo "Prism User Service has been installed."
echo "Use [systemctl --user enable app-dev.lizardbyte.app.Prism] once to autostart Prism on login."

# Load uhid (DS5 emulation)
UHID=$(cat /app/share/prism/modules-load.d/60-prism.conf)
echo "Enabling DS5 emulation."
flatpak-spawn --host pkexec sh -c "echo '$UHID' > /etc/modules-load.d/60-prism.conf"
flatpak-spawn --host pkexec modprobe uhid

# Udev rule
UDEV=$(cat /app/share/prism/udev/rules.d/60-prism.rules)
echo "Configuring mouse permission."
flatpak-spawn --host pkexec sh -c "echo '$UDEV' > /etc/udev/rules.d/60-prism.rules"
echo "Restart computer for mouse permission to take effect."
