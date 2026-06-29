#!/bin/bash

set -ouex pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/39/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
dnf5 install -y tmux
dnf5 install -y spacenavd

# Build and install rpiboot (Raspberry Pi USB boot tool)
dnf5 install -y libusb1-devel make gcc git
git clone --depth=1 https://github.com/raspberrypi/usbboot /tmp/usbboot
make -C /tmp/usbboot
install -m 0755 /tmp/usbboot/rpiboot /usr/bin/rpiboot
rm -rf /tmp/usbboot
dnf5 remove -y libusb1-devel make gcc git

### uupd-indicator (GNOME-Shell-Extension, systemweit)
# Pulsierender Tray-Indicator, solange uupd.service Updates anwendet.
# Quelle: https://github.com/tobehn/uupd-indicator (neuester main, keine Tags)
UUPD_UUID="uupd-indicator@projectbluefin.io"
UUPD_DIR="/usr/share/gnome-shell/extensions/${UUPD_UUID}"
mkdir -p "${UUPD_DIR}"
curl -fsSL https://github.com/tobehn/uupd-indicator/archive/refs/heads/main.tar.gz \
    | tar -xz -C /tmp
cp -r "/tmp/uupd-indicator-main/${UUPD_UUID}/." "${UUPD_DIR}/"
rm -rf /tmp/uupd-indicator-main
chmod 644 "${UUPD_DIR}"/*
# Image laeuft auf GNOME Shell 50 (F44), Extension deklariert nur "49"
# -> aktuelle Shell-Major-Version ergaenzen, sonst laedt sie nicht.
UUPD_SHELL_MAJOR="$(rpm -q --qf '%{version}' gnome-shell | cut -d. -f1)"
if ! grep -q "\"${UUPD_SHELL_MAJOR}\"" "${UUPD_DIR}/metadata.json"; then
    sed -i "s/\(\"shell-version\": *\[\)/\1\"${UUPD_SHELL_MAJOR}\", /" \
        "${UUPD_DIR}/metadata.json"
fi
# Systemweit fuer alle User aktivieren (dconf-Default).
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/20-uupd-indicator <<EOF
[org/gnome/shell]
enabled-extensions=['${UUPD_UUID}']
EOF
dconf update

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket

### vfio-pci ins Initramfs damit es vor nouveau lädt
# Erforderlich für statisches GPU-Passthrough der GTX 1650 (Architektur A)
# Siehe: machines/mooncenter.md + memory/learnings/2026-04-22-gpu-cannot-be-shared-with-active-compositor
# Wirkt erst wenn rpm-ostree initramfs --enable einmalig auf dem Host gesetzt wurde
# (ist auf MONDZENTRUM seit 2026-04-22 aktiv)
mkdir -p /usr/lib/dracut/dracut.conf.d
cat > /usr/lib/dracut/dracut.conf.d/99-vfio.conf <<'EOF'
add_drivers+=" vfio vfio_iommu_type1 vfio-pci "
EOF

### Headless / Always-On (MONDZENTRUM via RDP im Tailnet)
# Ziel: PC läuft ohne Tastatur/Maus/Monitor durch, erreichbar via gnome-remote-desktop
# (System-"Remote-Anmeldung" / --system + --handover) im Tailnet.
# Hinweis: Display-Ausgang braucht ein EDID -> HDMI/DP-Dummy-Plug steckt physisch.
# Ohne EDID bleibt der amdgpu-Compositor ohne CRTC und GDM rendert schwarz.

# GDM-Greeter darf nicht in Suspend gehen, sonst schläft die Box VOR dem ersten
# RDP-Login am Anmeldebildschirm ein und ist im Tailnet weg.
# (Der User-Session-Wert liegt in /var/home und ist bereits gesetzt.)
mkdir -p /etc/dconf/db/gdm.d
cat > /etc/dconf/db/gdm.d/10-no-suspend <<'EOF'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-type='nothing'
EOF
dconf update

### Nächtlicher Reboot um 23:59:59
# Aktiviert das per Autoupdate gestagte bootc-Image (Reboot = apply).
cat > /usr/lib/systemd/system/nightly-reboot.service <<'EOF'
[Unit]
Description=Nightly system reboot (apply staged bootc/Bluefin updates)

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF

cat > /usr/lib/systemd/system/nightly-reboot.timer <<'EOF'
[Unit]
Description=Trigger nightly reboot at 23:59:59

[Timer]
OnCalendar=*-*-* 23:59:59
AccuracySec=1s
# Persistent=false: verpasste Reboots NICHT nachholen (sonst Reboot-Schleife beim Boot)
Persistent=false

[Install]
WantedBy=timers.target
EOF

systemctl enable nightly-reboot.timer
