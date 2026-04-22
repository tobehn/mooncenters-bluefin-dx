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
