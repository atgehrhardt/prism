#!/bin/sh

# User Service
systemctl --user stop app-dev.lizardbyte.app.Prism
rm "$HOME/.config/systemd/user/app-dev.lizardbyte.app.Prism.service"
systemctl --user daemon-reload
echo "Prism User Service has been removed."

# Remove rules
flatpak-spawn --host pkexec sh -c "rm /etc/modules-load.d/60-prism.conf"
flatpak-spawn --host pkexec sh -c "rm /etc/udev/rules.d/60-prism.rules"
echo "Input rules removed. Restart computer to take effect."
