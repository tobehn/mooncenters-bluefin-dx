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

### Headless / Always-On (MONDZENTRUM im Tailnet)
# Ziel: PC läuft ohne Tastatur/Maus/Monitor durch. Fernzugriff (Stand 2026-07-13):
#  - Primär + einziger GUI-Weg: RustDesk nativ als Root-Dienst (unattended, Portal-Grant
#    reboot-fest; Block unten + Vault-Pattern 2026-07-13-rustdesk-unattended-gnome-wayland-service-mode)
#  - Notfall (Terminal): Tailscale SSH (Headscale-Policy tehn@->tehn@ seit 2026-07-13)
# ⚠️ gnome-remote-desktop System-Remote-Login (3389) wird bewusst MASKIERT (Block unten):
#    Es hält permanent eine parallele gdm-greeter-Session bereit, in die RustDesks
#    Connection-Manager nicht-deterministisch geraten kann (dort kein Portal-Grant ->
#    Dialog bei jedem Connect). Ohne 3389 existiert nur die tobias-Auto-Login-Session
#    -> RustDesk bedient deterministisch die Session mit dem persistenten Grant.
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

# Bulletproof: Sleep-Targets systemweit maskieren. Der dconf-Greeter-Fix oben
# deckt nur den GDM-Anmeldebildschirm ab; ein logind IdleAction-/Lid-/manueller
# Suspend käme trotzdem durch. Für eine Headless-Always-On-Box wollen wir gar
# keinen Sleep -> Targets hart maskieren (Symlink auf /dev/null).
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

### RustDesk-Determinismus: System-Remote-Login (3389) hart deaktivieren
# gnome-remote-desktop System-Mode (Port 3389, Remote-Login/Handover) hält permanent
# eine parallele gdm-greeter-Session bereit. RustDesks --service spawnt --server/--cm
# fuer JEDE grafische Session; landet der Connection-Manager (ipc_cm) in der
# gdm-greeter-Session (kein persistenter Portal-Grant, fluechtiges HOME), fragt RustDesk
# bei JEDEM Connect neu nach der Bildschirmfreigabe -> unattended-Zugriff kaputt.
# Das Symptom war nicht-deterministisch: mal traf der Connect die tobias-Session (Grant
# da -> kein Dialog), mal die gdm-greeter-Session (kein Grant -> Dialog). Genau das hat
# die Diagnose 2026-07-13 lange verschleiert.
# Fix: System-GRD maskieren -> nur die tobias-Auto-Login-Session existiert -> RustDesk
# bedient deterministisch die Session mit dem Grant. mask statt disable, weil das
# Atomic-Preset ein disable beim Boot re-aktiviert (Learning 2026-07-12).
# Verifiziert MONDZENTRUM 2026-07-13: loginctl zeigt nach Reboot nur tobias-Sessions,
# iPhone + mondflieger via RustDesk ohne Dialog drin.
# Trade-off: kein RDP-Desktop-Zugang (Remmina) mehr ueber 3389; RustDesk ist der GUI-Weg,
# Tailscale SSH der Terminal-Notfall.
systemctl mask gnome-remote-desktop.service

### RustDesk nativ (unattended Fernzugriff)
# Warum im Image statt Flatpak/AppImage: Nur mit laufendem RustDesk-*Dienst* nimmt der
# Client den ScreenCast-Portal-Pfad mit persist_mode=2 + restore_token -> die
# Bildschirmfreigabe überlebt Reboots ohne Bestätigungs-Dialog. Das Flatpak kann das
# prinzipbedingt nicht (RemoteDesktop-Portal-Pfad ohne persist, Upstream-TODO in
# libs/scrap/src/wayland/pipewire.rs). Das RPM liefert Binary + Unit + Desktop-Eintrag
# als EIN Artefakt; Updates/Rollback laufen über bootc mit (Version-Bump = Commit hier).
# Identität/permanentes Passwort (RustDesk.toml unter /root bzw. $HOME) und der
# Portal-Grant bleiben bewusst machine-local - keine Secrets im Image.
# Version gepinnt + Checksum-verifiziert: GitHub-Release-RPMs sind nicht repo-signiert,
# ein kompromittiertes Upstream-Release soll NICHT automatisch einfliessen.
# Details: Vault-Pattern 2026-07-13-rustdesk-unattended-gnome-wayland-service-mode
RUSTDESK_VERSION=1.4.9
RUSTDESK_SHA256=eb1b053ac5b2f774f2271f7fbbfd2ea475899f7a55135c5e172bc54b9388f108
curl -fsSL -o /tmp/rustdesk.rpm \
    "https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-0.x86_64.rpm"
echo "${RUSTDESK_SHA256}  /tmp/rustdesk.rpm" | sha256sum -c -
dnf5 install -y /tmp/rustdesk.rpm
rm -f /tmp/rustdesk.rpm
# Das RustDesk-RPM legt die Unit NUR als Vorlage nach /usr/share/rustdesk/files/ ab
# (keine aktive systemd-Unit an einem Suchpfad) -> explizit nach /usr/lib kopieren,
# sonst "Unit rustdesk.service does not exist" auf frischer Installation (z.B. UHV21).
# Verifiziert MONDZENTRUM 2026-07-13: die aktive Unit kam nur aus dem manuellen /etc-Override.
install -Dm644 /usr/share/rustdesk/files/rustdesk.service /usr/lib/systemd/system/rustdesk.service
# Preset ins Image: haelt den enable-Zustand ueber die Atomic-Preset-Neuberechnung beim
# Boot (sonst wird der enable-Symlink evtl. einkassiert, s. Learning 2026-07-12).
mkdir -p /usr/lib/systemd/system-preset
printf 'enable rustdesk.service\n' > /usr/lib/systemd/system-preset/20-rustdesk.preset
systemctl enable rustdesk.service

### Nächtlicher Reboot (konfigurierbares Intervall)
# Aktiviert das per Autoupdate gestagte bootc-Image (Reboot = apply).
# Der Timer feuert JEDE Nacht; ob wirklich rebootet wird, entscheidet das
# Check-Script anhand von INTERVAL_DAYS (Default 1 = täglich). "Alle N Tage"
# geht so robust, weil ein reines OnCalendar kein "every N days" kann und ein
# Zeitstempel verpasste Nächte/Reboots korrekt überbrückt.
# Steuerung zur Laufzeit über den Befehl:  reboot-schedule
cat > /usr/lib/systemd/system/nightly-reboot.service <<'EOF'
[Unit]
Description=Scheduled system reboot (apply staged bootc/Bluefin updates)

[Service]
Type=oneshot
ExecStart=/usr/libexec/reboot-schedule-check
EOF

cat > /usr/lib/systemd/system/nightly-reboot.timer <<'EOF'
[Unit]
Description=Trigger scheduled reboot check every night

[Timer]
OnCalendar=*-*-* 23:59:59
AccuracySec=1s
# Persistent=false: verpasste Trigger NICHT nachholen (sonst Reboot-Schleife beim Boot)
Persistent=false

[Install]
WantedBy=timers.target
EOF

# Entscheidungs-Script: rebootet nur, wenn seit dem letzten geplanten Reboot
# mindestens INTERVAL_DAYS Tage vergangen sind. Zeitstempel liegt in /var
# (persistent), Intervall in /etc/reboot-schedule.conf (fehlt = täglich).
cat > /usr/libexec/reboot-schedule-check <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF=/etc/reboot-schedule.conf
STAMP=/var/lib/reboot-schedule/last-reboot

INTERVAL_DAYS=1
[ -r "$CONF" ] && . "$CONF"
case "${INTERVAL_DAYS:-}" in ''|*[!0-9]*) INTERVAL_DAYS=1 ;; esac
[ "$INTERVAL_DAYS" -lt 1 ] && INTERVAL_DAYS=1

today=$(( $(date +%s) / 86400 ))   # Tage seit Epoch
mkdir -p "$(dirname "$STAMP")"
last=$(cat "$STAMP" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac

if [ "$last" -eq 0 ] || [ $(( today - last )) -ge "$INTERVAL_DAYS" ]; then
    echo "$today" > "$STAMP"
    logger -t reboot-schedule "Intervall erreicht (${INTERVAL_DAYS}d) -> Reboot"
    exec systemctl reboot
fi
logger -t reboot-schedule "Noch nicht fällig ($(( today - last ))/${INTERVAL_DAYS}d) -> übersprungen"
EOF
chmod +x /usr/libexec/reboot-schedule-check

# Bequemer An-/Aus-/Intervall-Schalter für den Admin.
cat > /usr/bin/reboot-schedule <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF=/etc/reboot-schedule.conf
TIMER=nightly-reboot.timer
DROPIN_DIR=/etc/systemd/system/${TIMER}.d
DROPIN=${DROPIN_DIR}/schedule.conf

usage() {
cat <<USG
reboot-schedule – geplanter Auto-Reboot (wendet gestagte bootc-Updates an)

  reboot-schedule status        Zustand, Intervall, Uhrzeit, nächster Reboot
  reboot-schedule on            Zeitplan aktivieren
  reboot-schedule off           Zeitplan deaktivieren
  reboot-schedule daily         Jede Nacht rebooten
  reboot-schedule every <N>     Alle N Tage rebooten (z.B. 5, 7, 30)
  reboot-schedule at <HH:MM>    Uhrzeit ändern (Default 23:59)
USG
}

require_root() { [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"; }

read_interval() {
    local INTERVAL_DAYS=1
    [ -r "$CONF" ] && . "$CONF"
    printf '%s' "${INTERVAL_DAYS:-1}"
}
read_time() {
    local t
    t=$(systemctl cat "$TIMER" 2>/dev/null | awk -F= '/^OnCalendar=./{v=$2} END{print v}')
    printf '%s' "${t:-*-*-* 23:59:59}"
}

case "${1:-status}" in
  status)
    echo "Zeitplan:  $(systemctl is-enabled "$TIMER" 2>/dev/null || true) / $(systemctl is-active "$TIMER" 2>/dev/null || true)"
    echo "Intervall: alle $(read_interval) Tag(e)"
    echo "Uhrzeit:   $(read_time)"
    systemctl list-timers "$TIMER" --no-pager 2>/dev/null | sed -n '1,2p' || true
    ;;
  on)
    require_root "$@"
    systemctl enable --now "$TIMER"
    echo "Auto-Reboot aktiviert (alle $(read_interval) Tag(e))."
    ;;
  off)
    require_root "$@"
    systemctl disable --now "$TIMER"
    echo "Auto-Reboot deaktiviert."
    ;;
  daily)
    require_root "$@"
    printf 'INTERVAL_DAYS=1\n' > "$CONF"
    echo "Intervall: jede Nacht."
    ;;
  every)
    require_root "$@"
    n=${2:-}
    case "$n" in ''|*[!0-9]*) echo "Fehler: 'every <N>' braucht eine Zahl >=1." >&2; exit 1 ;; esac
    [ "$n" -lt 1 ] && { echo "Fehler: N muss >=1 sein." >&2; exit 1; }
    printf 'INTERVAL_DAYS=%s\n' "$n" > "$CONF"
    echo "Intervall: alle $n Tag(e)."
    ;;
  at)
    require_root "$@"
    hhmm=${2:-}
    case "$hhmm" in
      [0-2][0-9]:[0-5][0-9]) : ;;
      *) echo "Fehler: 'at <HH:MM>', z.B. at 03:00" >&2; exit 1 ;;
    esac
    mkdir -p "$DROPIN_DIR"
    # leeres OnCalendar= setzt den Basiswert zurück, danach unser Wert
    printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00\n' "$hhmm" > "$DROPIN"
    systemctl daemon-reload
    echo "Uhrzeit gesetzt: $hhmm."
    systemctl list-timers "$TIMER" --no-pager 2>/dev/null | sed -n '2p' || true
    ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
EOF
chmod +x /usr/bin/reboot-schedule

# Bash-Completion: Unterbefehle + sinnvolle Argument-Vorschläge (Tab).
cat > /usr/share/bash-completion/completions/reboot-schedule <<'EOF'
_reboot_schedule() {
    local cur prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "status on off daily every at help" -- "$cur") )
        return
    fi
    case "$prev" in
        every) COMPREPLY=( $(compgen -W "5 7 14 30" -- "$cur") ) ;;
        at)    COMPREPLY=( $(compgen -W "23:59 03:00 04:00 05:00" -- "$cur") ) ;;
    esac
}
complete -F _reboot_schedule reboot-schedule
EOF

# Preset ins Image: haelt den enable-Zustand ueber die Atomic-Preset-Neuberechnung
# beim Boot. Ohne Preset-Regel kassiert der Boot den enable-Symlink wieder ein --
# Beweis (Gegenprobe MONDZENTRUM 2026-07-13): rustdesk MIT 20-rustdesk.preset blieb
# nach Reboot enabled, dieser Timer OHNE Preset wurde disabled. Auf MONDZENTRUM
# maskiert ein historischer /etc-Override den Fehler; jede frische Installation
# haette einen toten Auto-Update-Reboot (Updates werden gestagt, nie angewendet).
# Learning: 2026-07-13-bootc-image-enable-needs-preset-etc-merge-beats-image
printf 'enable nightly-reboot.timer\n' > /usr/lib/systemd/system-preset/21-nightly-reboot.preset
systemctl enable nightly-reboot.timer

### Selbstheilung bei Hard-Freeze: Hardware-Watchdog + Auto-Reboot bei Panic
# Problem: Die Box friert gelegentlich komplett ein (kompletter Kernel-/GPU-Hang,
# nichts mehr im Log, kein sauberes Shutdown). Dann ist sie via RDP nicht mehr
# erreichbar (MS-RDP "Fehler 204" = Host nicht erreichbar) und der nächtliche
# Reboot kann NICHT helfen, weil ein eingefrorener Kernel keine Timer mehr feuert.
# -> Ausweg ist der in der Hardware vorhandene Watchdog (sp5100-tco, /dev/watchdog).
#
# systemd pingt den Watchdog aus PID 1. Sobald der Kernel hart hängt, bleibt der
# Ping aus und die Hardware setzt die Box nach dem Timeout zwangsweise zurück.
# Aus "5 Tage tot + hinfahren + Strom ziehen" wird "~1-2 Min weg, kommt allein wieder".
mkdir -p /usr/lib/systemd/system.conf.d
cat > /usr/lib/systemd/system.conf.d/10-watchdog.conf <<'EOF'
[Manager]
# Hardware-Watchdog armen; PID1 pingt alle 30s, Reset wenn 60s kein Ping (Freeze).
RuntimeWatchdogSec=60s
# Falls ein Reboot/Shutdown selbst hängt: nach 10min per Watchdog erzwingen.
RebootWatchdogSec=10min
EOF

# Bei Kernel-Panic/Oops nicht endlos hängen bleiben, sondern automatisch neu starten.
mkdir -p /usr/lib/sysctl.d
cat > /usr/lib/sysctl.d/99-headless-panic-reboot.conf <<'EOF'
# Headless-Always-On: nach Panic 10s warten, dann rebooten (statt tot hängen).
kernel.panic = 10
# Ein Oops soll zur Panic eskalieren -> greift die Reboot-Regel oben.
kernel.panic_on_oops = 1
EOF

### Freeze-Ursache eingrenzen (AM4 Ryzen 5700G Idle-Hard-Freeze)
# Beobachtung: Box friert IM IDLE ein, stiller Totalstillstand, NICHTS im Log
# (kein Panic/GPU/IOMMU/MCE). Passt auf den bekannten AM4-Ryzen-Idle-Freeze
# (Hänger beim Eintritt in tiefe Package-C-States). Zwei Massnahmen:
#
# B) Workaround: tiefe C-States verhindern. Friert die Box damit nicht mehr,
#    ist die C-State-These bestaetigt (eigentlicher Fix waere BIOS "Power Supply
#    Idle Control = Typical Current Idle"). nmi_watchdog=panic laesst einen
#    Hardlockup panicen, damit er ueberhaupt erfassbar wird.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/10-idle-freeze.toml <<'EOF'
kargs = ["processor.max_cstate=1", "idle=nomwait", "nmi_watchdog=panic"]
EOF

# C) Beweissicherung OHNE zweite Maschine: Soft-Lockups sollen panicen. Ein Panic
#    (soft/hard-lockup, oops) wird von efi_pstore automatisch in die EFI-Variablen
#    geschrieben und ist nach dem (Watchdog-)Reboot unter /sys/fs/pstore/ lesbar.
#    -> naechster Freeze: "ls /sys/fs/pstore/; cat /sys/fs/pstore/dmesg-*".
#    Bleibt /sys/fs/pstore leer, gab es keinen Panic -> reiner HW-/Power-Halt
#    (C-State/BIOS), kein Software-Bug.
mkdir -p /usr/lib/sysctl.d
cat > /usr/lib/sysctl.d/98-freeze-diagnostics.conf <<'EOF'
# Soft-Lockup (CPU >20s ohne Scheduling) -> Panic, damit efi_pstore ihn sichert.
kernel.softlockup_panic = 1
EOF
