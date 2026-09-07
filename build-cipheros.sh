#!/usr/bin/env bash
# =============================================================================
#  CipherOS — Automated ISO Build Script v4.0
#  Base: Debian 12 (Bookworm) | Build Host: Ubuntu 26.04
#  Includes: Calamares, SDDM, KDE, Plymouth, Powerlevel10k, Kvantum, Konsole
#  Author: Rico Wolmarans
#  Usage: sudo -i && bash build-cipheros.sh
# =============================================================================

set -euo pipefail
trap 'echo ""; echo "❌ BUILD FAILED at line $LINENO. Check $LOG_FILE for details."; exit 1' ERR

# ── CONFIG ────────────────────────────────────────────────────────────────────
WORKDIR="/home/rico/CipherOS"
ASSETS_DIR="/home/rico/CipherOS-assets"
LOG_FILE="$WORKDIR/build.log"
ISO_NAME="cipheros-1.0-amd64.iso"

# ── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; PINK='\033[0;35m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}✅ $*${RESET}" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠️  $*${RESET}" | tee -a "$LOG_FILE"; }
header()  { echo -e "\n${PINK}══════════════════════════════════════════${RESET}";
            echo -e "${RED}  $*${RESET}";
            echo -e "${PINK}══════════════════════════════════════════${RESET}\n" | tee -a "$LOG_FILE"; }

# ── PREFLIGHT ─────────────────────────────────────────────────────────────────
header "🔐 CipherOS Build System v4.0 — Debian 12 Bookworm"

[[ $EUID -ne 0 ]] && { echo -e "${RED}❌ Run as root: sudo -i && bash build-cipheros.sh${RESET}"; exit 1; }

mkdir -p "$WORKDIR"
cd "$WORKDIR"
echo "Build started: $(date)" > "$LOG_FILE"

FREE_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
[[ $FREE_GB -lt 60 ]] && { echo -e "${RED}❌ Need 60GB+ free, have ${FREE_GB}GB${RESET}"; exit 1; }
success "Disk: ${FREE_GB}GB free"

RAM_GB=$(free -g | awk 'NR==2 {print $2}')
[[ $RAM_GB -lt 6 ]] && warn "Low RAM: ${RAM_GB}GB — build may be slow"
success "RAM: ${RAM_GB}GB"

curl -s --max-time 5 https://deb.debian.org > /dev/null || { echo -e "${RED}❌ No internet${RESET}"; exit 1; }
success "Internet OK"

# ── PHASE 1: BUILD DEPENDENCIES ──────────────────────────────────────────────
header "📦 PHASE 1 — Build Dependencies"

apt-get update -qq 2>>"$LOG_FILE"
apt-get install -y \
    live-build debootstrap squashfs-tools xorriso \
    isolinux syslinux-common grub-pc-bin grub-efi-amd64-bin \
    mtools dosfstools git curl wget gnupg2 rsync pigz \
    qemu-utils ovmf imagemagick \
    2>>"$LOG_FILE"

success "Dependencies installed (live-build $(lb --version))"

# ── PHASE 2: PROJECT STRUCTURE ────────────────────────────────────────────────
header "📁 PHASE 2 — Project Structure"

[[ -d "$WORKDIR/chroot" || -d "$WORKDIR/binary" ]] && {
    warn "Previous build found — cleaning..."
    lb clean --all 2>>"$LOG_FILE" || true
}

mkdir -p config/{package-lists,hooks/live,hooks/normal}
mkdir -p config/includes.chroot/{etc/cipheros,etc/calamares/branding/cipheros,etc/calamares/modules}
mkdir -p config/includes.chroot/{usr/local/bin,usr/share/sddm/themes/cipheros}
mkdir -p config/includes.chroot/{usr/share/plasma/look-and-feel/CipherOS/contents/defaults}
mkdir -p config/includes.chroot/{usr/share/plasma/look-and-feel/CipherOS/contents/layouts}
mkdir -p config/includes.chroot/{usr/share/plasma/look-and-feel/CipherOS/contents/splash}
mkdir -p config/includes.chroot/{usr/share/wallpapers/CipherOS/contents/images}
mkdir -p config/includes.chroot/{usr/share/color-schemes,usr/share/konsole}
mkdir -p config/includes.chroot/usr/share/plymouth/themes/cipheros
mkdir -p config/includes.chroot/usr/share/Kvantum/CipherOS
mkdir -p config/includes.chroot/etc/skel/.config/{fastfetch,gtk-3.0,gtk-4.0,Kvantum}
mkdir -p config/includes.chroot/etc/skel/.local/share/konsole

success "Project structure ready"

# ── PHASE 3: LIVE-BUILD CONFIG ───────────────────────────────────────────────
header "⚙️  PHASE 3 — live-build Configuration (Debian 12 Bookworm)"

mkdir -p auto
cat > auto/config << 'AUTOEOF'
#!/bin/sh
set -e
lb config noauto \
    --mode debian \
    --distribution bookworm \
    --architectures amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap http://deb.debian.org/debian/ \
    --mirror-chroot http://deb.debian.org/debian/ \
    --mirror-binary http://deb.debian.org/debian/ \
    --mirror-binary-security http://security.debian.org/debian-security/ \
    --security true \
    --backports true \
    --bootloader grub-efi \
    --binary-images iso-hybrid \
    --iso-volume "CipherOS 1.0" \
    --iso-publisher "CipherOS Project" \
    --iso-application "CipherOS 1.0 Phantom" \
    --memtest none \
    --win32-loader false \
    --debian-installer none \
    --bootappend-live "boot=live components quiet splash" \
    "${@}"
AUTOEOF
chmod +x auto/config
lb config 2>>"$LOG_FILE"
success "live-build configured for Debian 12 Bookworm"

# ── PHASE 4: USER ASSETS ─────────────────────────────────────────────────────
header "🖼️  PHASE 4 — Syncing & Loading Wallpapers & Logo"

ASSETS_REPO="https://github.com/ricowolmarans/CipherOS-Assets.git"

if [[ -d "$ASSETS_DIR/.git" ]]; then
    log "Assets repo exists — pulling latest..."
    git -C "$ASSETS_DIR" pull --quiet 2>>"$LOG_FILE" || warn "git pull failed — using local copy"
    success "Assets synced"
elif [[ -d "$ASSETS_DIR" ]]; then
    warn "$ASSETS_DIR exists but isn't a git repo — using as-is"
else
    log "Cloning assets repo..."
    git clone --quiet "$ASSETS_REPO" "$ASSETS_DIR" 2>>"$LOG_FILE" && \
        success "Assets repo cloned" || \
        warn "Clone failed — will generate placeholders instead"
fi

WALLPAPER_DEST="config/includes.chroot/usr/share/wallpapers/CipherOS/contents/images"
LOGO_DEST="config/includes.chroot/etc/calamares/branding/cipheros"
mkdir -p "$WALLPAPER_DEST"
mkdir -p "$LOGO_DEST"

# Wallpapers
if [[ -d "$ASSETS_DIR/wallpapers" ]] && \
   [[ $(ls "$ASSETS_DIR/wallpapers"/*.{jpg,jpeg,png,webp} 2>/dev/null | wc -l) -gt 0 ]]; then

    FIRST_WALLPAPER=""
    for f in "$ASSETS_DIR/wallpapers"/*.{jpg,jpeg,png,webp}; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        cp "$f" "$WALLPAPER_DEST/$fname"
        [[ -z "$FIRST_WALLPAPER" ]] && FIRST_WALLPAPER="$fname"

        # Register each as its own KDE wallpaper package
        name="${fname%.*}"
        PKG="config/includes.chroot/usr/share/wallpapers/CipherOS-${name}"
        mkdir -p "$PKG/contents/images"
        cp "$f" "$PKG/contents/images/$fname"
        cat > "$PKG/metadata.json" << METAEOF
{
    "KPlugin": {
        "Authors": [{"Name": "CipherOS"}],
        "Id": "CipherOS-${name}",
        "License": "CC-BY-SA-4.0",
        "Name": "CipherOS — ${name}",
        "Version": "1.0"
    }
}
METAEOF
        success "  Wallpaper registered: $fname"
    done
    echo "$FIRST_WALLPAPER" > /tmp/cipheros_default_wallpaper

else
    warn "No wallpapers found in $ASSETS_DIR/wallpapers — generating placeholder"
    convert -size 3840x2160 gradient:'#0A0A0F-#12121A' \
        -fill '#FF2D55' -font DejaVu-Sans-Bold -pointsize 120 \
        -gravity center -annotate 0 'CIPHER OS' \
        "$WALLPAPER_DEST/cipheros-default.png" 2>>"$LOG_FILE" || \
        convert -size 3840x2160 xc:'#0A0A0F' \
        "$WALLPAPER_DEST/cipheros-default.png" 2>>"$LOG_FILE" || true
    echo "cipheros-default.png" > /tmp/cipheros_default_wallpaper
fi

# Main wallpaper package metadata
cat > "config/includes.chroot/usr/share/wallpapers/CipherOS/metadata.json" << 'EOF'
{
    "KPlugin": {
        "Authors": [{"Name": "CipherOS"}],
        "Id": "CipherOS",
        "License": "CC-BY-SA-4.0",
        "Name": "CipherOS",
        "Version": "1.0"
    }
}
EOF

# Logo
if [[ -f "$ASSETS_DIR/logo/cipheros-logo.png" ]]; then
    cp "$ASSETS_DIR/logo/cipheros-logo.png" "$LOGO_DEST/cipheros-logo.png"
    success "Logo loaded"
else
    warn "No logo found — generating placeholder"
    convert -size 256x256 xc:'#0A0A0F' \
        -fill '#FF2D55' -font DejaVu-Sans-Bold -pointsize 32 \
        -gravity center -annotate 0 "CIPHER\nOS" \
        "$LOGO_DEST/cipheros-logo.png" 2>>"$LOG_FILE" || \
        convert -size 256x256 xc:'#0A0A0F' \
        "$LOGO_DEST/cipheros-logo.png" 2>>"$LOG_FILE" || true
fi

# Welcome image
if [[ -f "$ASSETS_DIR/logo/cipheros-welcome.png" ]]; then
    cp "$ASSETS_DIR/logo/cipheros-welcome.png" "$LOGO_DEST/cipheros-welcome.png"
    success "Welcome image loaded"
else
    convert -size 800x450 gradient:'#0A0A0F-#12121A' \
        -fill '#FF2D55' -font DejaVu-Sans-Bold -pointsize 48 \
        -gravity center -annotate 0 "CIPHER OS\n1.0 (Phantom)" \
        "$LOGO_DEST/cipheros-welcome.png" 2>>"$LOG_FILE" || \
        convert -size 800x450 xc:'#0A0A0F' \
        "$LOGO_DEST/cipheros-welcome.png" 2>>"$LOG_FILE" || true
    warn "Using generated welcome image"
fi

# ── PHASE 5: PACKAGE LISTS ───────────────────────────────────────────────────
header "📋 PHASE 5 — Package Lists"

# Base — Debian package names (no ubuntu-specific packages)
cat > config/package-lists/base.list.chroot << 'EOF'
kde-standard
plasma-desktop
plasma-nm
plasma-pa
plasma-widgets-addons
plasma-workspace
kwin-x11
dolphin
konsole
kate
ark
gwenview
okular
spectacle
kcalc
sddm
sddm-theme-breeze
calamares
fonts-noto
fonts-noto-color-emoji
fonts-firacode
zsh
zsh-autosuggestions
zsh-syntax-highlighting
curl
wget
git
htop
btop
fastfetch
neovim
tmux
rsync
tree
jq
unzip
p7zip-full
network-manager
network-manager-gnome
openssh-client
openssh-server
ufw
firejail
firejail-profiles
apparmor
apparmor-profiles
apparmor-utils
dnscrypt-proxy
preload
irqbalance
thermald
systemd-zram-generator
firmware-linux
firmware-linux-nonfree
firmware-misc-nonfree
amd64-microcode
intel-microcode
EOF

# Security
cat > config/package-lists/security.list.chroot << 'EOF'
nmap
masscan
theharvester
gobuster
nikto
dirb
dnsrecon
whatweb
sqlmap
hydra
medusa
aircrack-ng
kismet
wireshark
tcpdump
hashcat
john
burpsuite
tor
torbrowser-launcher
onionshare
proxychains4
binwalk
foremost
exiftool
steghide
radare2
gdb
ltrace
strace
netcat-traditional
socat
net-tools
dnsutils
whois
sslscan
EOF

# Gaming — Debian has steam via non-free
cat > config/package-lists/gaming.list.chroot << 'EOF'
steam
lutris
wine
wine32
wine64
winetricks
gamemode
libgamemode0
libgamemodeauto0
mangohud
vulkan-tools
libvulkan1
mesa-vulkan-drivers
EOF

# Creative
cat > config/package-lists/creative.list.chroot << 'EOF'
blender
freecad
gimp
krita
inkscape
kdenlive
ardour
audacity
EOF

success "Package lists written"

# ── PHASE 6: SDDM LOGIN SCREEN ───────────────────────────────────────────────
header "🔒 PHASE 6 — SDDM Cyberpunk Login Screen"

SDDM_DIR="config/includes.chroot/usr/share/sddm/themes/cipheros"

cat > "$SDDM_DIR/metadata.desktop" << 'EOF'
[SddmGreeterTheme]
Name=CipherOS
Description=CipherOS Cyberpunk Login Theme
Author=CipherOS Team
License=CC-BY-SA-4.0
Type=sddm-theme
Version=1.0
Website=https://cipheros.gt.tc
EOF

cat > "$SDDM_DIR/Main.qml" << 'QMLEOF'
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import SddmComponents 2.0

Rectangle {
    id: root
    width: Screen.width
    height: Screen.height
    color: "#0A0A0F"

    Canvas {
        anchors.fill: parent
        opacity: 0.08
        onPaint: {
            var ctx = getContext("2d")
            ctx.strokeStyle = "#39FF14"
            ctx.lineWidth = 0.5
            for (var x = 0; x < width; x += 60) {
                ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, height); ctx.stroke()
            }
            for (var y = 0; y < height; y += 60) {
                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke()
            }
        }
    }

    Rectangle {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -120
        width: 500; height: 500; radius: 250
        color: "#FF2D55"; opacity: 0.04
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 0

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "⬡ CIPHER OS ⬡"
            color: "#FF2D55"
            font.pixelSize: 48; font.bold: true; font.family: "monospace"
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 8
            text: "\"Built for the ones who know.\""
            color: "#39FF14"; font.pixelSize: 16; font.family: "monospace"; opacity: 0.8
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 32; Layout.bottomMargin: 32
            width: 400; height: 1; color: "#FF2D55"; opacity: 0.5
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            width: 400; height: 260
            color: "#12121A"; border.color: "#FF2D5560"; border.width: 1; radius: 4

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 16; width: 340

                Text { color: "#FF79C6"; text: "OPERATOR"; font.pixelSize: 11
                       font.family: "monospace"; font.bold: true; letterSpacing: 3 }

                TextField {
                    id: userField
                    Layout.fillWidth: true
                    text: userModel.lastUser
                    placeholderText: "username"
                    height: 44; font.family: "monospace"; font.pixelSize: 14
                    color: "#39FF14"; placeholderTextColor: "#39FF1460"
                    background: Rectangle {
                        color: "#0A0A0F"
                        border.color: userField.activeFocus ? "#FF2D55" : "#39FF1440"
                        border.width: 1; radius: 2
                    }
                    leftPadding: 12
                    KeyNavigation.tab: passField
                }

                Text { color: "#FF79C6"; text: "PASSPHRASE"; font.pixelSize: 11
                       font.family: "monospace"; font.bold: true; letterSpacing: 3 }

                TextField {
                    id: passField
                    Layout.fillWidth: true
                    placeholderText: "••••••••"
                    echoMode: TextInput.Password
                    height: 44; font.family: "monospace"; font.pixelSize: 14
                    color: "#39FF14"; placeholderTextColor: "#39FF1460"
                    background: Rectangle {
                        color: "#0A0A0F"
                        border.color: passField.activeFocus ? "#FF2D55" : "#39FF1440"
                        border.width: 1; radius: 2
                    }
                    leftPadding: 12
                    Keys.onReturnPressed: doLogin()
                }
            }
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 16
            width: 400; height: 48
            color: loginBtn.pressed ? "#FF2D5580" : "#FF2D5520"
            border.color: "#FF2D55"; border.width: 1; radius: 2
            Text { anchors.centerIn: parent; text: "[ AUTHENTICATE ]"
                   color: "#FF2D55"; font.pixelSize: 14; font.bold: true
                   font.family: "monospace"; letterSpacing: 4 }
            MouseArea { id: loginBtn; anchors.fill: parent; onClicked: doLogin() }
        }

        Text {
            id: errorMsg
            Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 12
            color: "#FF2D55"; font.pixelSize: 12; font.family: "monospace"; visible: false
        }

        Text {
            Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 32
            text: Qt.formatDateTime(new Date(), "ddd dd MMM yyyy  |  hh:mm:ss")
            color: "#39FF1480"; font.pixelSize: 13; font.family: "monospace"
            Timer { interval: 1000; running: true; repeat: true
                    onTriggered: parent.text = Qt.formatDateTime(new Date(), "ddd dd MMM yyyy  |  hh:mm:ss") }
        }
    }

    RowLayout {
        anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.margins: 32; spacing: 16

        ComboBox {
            id: sessionCombo; model: sessionModel; textRole: "name"
            implicitWidth: 160; implicitHeight: 36; font.family: "monospace"; font.pixelSize: 12
            contentItem: Text { leftPadding: 8; text: sessionCombo.displayText
                                color: "#39FF14"; font: sessionCombo.font; verticalAlignment: Text.AlignVCenter }
            background: Rectangle { color: "#12121A"; border.color: "#39FF1440"; border.width: 1; radius: 2 }
        }

        Rectangle {
            width: 80; height: 36; color: "#12121A"
            border.color: "#FF2D5540"; border.width: 1; radius: 2
            Text { anchors.centerIn: parent; text: "⏻ OFF"; color: "#FF2D55"
                   font.family: "monospace"; font.pixelSize: 12 }
            MouseArea { anchors.fill: parent; onClicked: sddm.powerOff() }
        }

        Rectangle {
            width: 90; height: 36; color: "#12121A"
            border.color: "#FF2D5540"; border.width: 1; radius: 2
            Text { anchors.centerIn: parent; text: "↺ RESTART"; color: "#FF79C6"
                   font.family: "monospace"; font.pixelSize: 11 }
            MouseArea { anchors.fill: parent; onClicked: sddm.reboot() }
        }
    }

    function doLogin() {
        if (userField.text === "") {
            errorMsg.text = "[ ERROR: OPERATOR ID REQUIRED ]"; errorMsg.visible = true; return
        }
        errorMsg.visible = false
        sddm.login(userField.text, passField.text, sessionCombo.currentIndex)
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            errorMsg.text = "[ ACCESS DENIED — INVALID CREDENTIALS ]"
            errorMsg.visible = true; passField.text = ""; passField.forceActiveFocus()
        }
    }

    Component.onCompleted: { if (userField.text === "") userField.forceActiveFocus(); else passField.forceActiveFocus() }
}
QMLEOF

cat > config/includes.chroot/etc/sddm.conf << 'EOF'
[Theme]
Current=cipheros
CursorTheme=breeze_cursors

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
Numlock=on
EOF

success "SDDM cyberpunk theme written"

# ── PHASE 7: KDE PLASMA ───────────────────────────────────────────────────────
header "🖥️  PHASE 7 — KDE Plasma Look-and-Feel"

LOOKANDFEEL="config/includes.chroot/usr/share/plasma/look-and-feel/CipherOS"

cat > "$LOOKANDFEEL/metadata.json" << 'EOF'
{
    "KPlugin": {
        "Authors": [{"Email": "info@cipheros.gt.tc", "Name": "CipherOS"}],
        "Description": "CipherOS cyberpunk plasma theme",
        "Id": "CipherOS",
        "License": "GPL-2.0",
        "Name": "CipherOS",
        "Version": "1.0",
        "Website": "https://cipheros.gt.tc"
    },
    "X-Plasma-API": "5.0"
}
EOF

cat > "$LOOKANDFEEL/contents/defaults" << 'EOF'
[kdeglobals][General]
ColorScheme=CipherOS

[kdeglobals][Icons]
Theme=breeze-dark

[kdeglobals][KDE]
LookAndFeelPackage=CipherOS
widgetStyle=kvantum-dark

[Wallpaper]
Image=CipherOS
Plugin=org.kde.image

[kcminputrc][Mouse]
cursorTheme=breeze_cursors
EOF

cat > "$LOOKANDFEEL/contents/layouts/org.kde.plasma.desktop-layout.js" << 'EOF'
var plasma = getApiVersion(1);
var layout = {
    desktops: [{
        applets: [],
        wallpaperPlugin: "org.kde.image",
        wallpaperPluginConfig: {
            Image: "file:///usr/share/wallpapers/CipherOS/contents/images/",
            FillMode: 2
        }
    }],
    panels: [{
        location: "bottom",
        height: 48,
        hiding: "none",
        applets: [
            { plugin: "org.kde.plasma.kickoff" },
            { plugin: "org.kde.plasma.taskmanager" },
            { plugin: "org.kde.plasma.systemtray" },
            { plugin: "org.kde.plasma.digitalclock" }
        ]
    }]
};
EOF

cat > "$LOOKANDFEEL/contents/splash/Splash.qml" << 'SPLASHEOF'
import QtQuick 2.15
Rectangle {
    id: root; color: "#0A0A0F"
    property int stage: 0
    onStageChanged: if (stage == 1) anim.start()

    SequentialAnimation {
        id: anim
        NumberAnimation { target: logo; property: "opacity"; from: 0; to: 1; duration: 800 }
        NumberAnimation { target: tag;  property: "opacity"; from: 0; to: 1; duration: 600 }
    }

    Text {
        id: logo; anchors.centerIn: parent; anchors.verticalCenterOffset: -30
        text: "CIPHER OS"; color: "#FF2D55"
        font.pixelSize: 72; font.bold: true; font.family: "monospace"; opacity: 0
    }
    Text {
        id: tag; anchors.top: logo.bottom; anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 16; text: "\"Built for the ones who know.\""
        color: "#39FF14"; font.pixelSize: 18; font.family: "monospace"; opacity: 0
    }
    Rectangle {
        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 80; width: 400; height: 2; color: "#12121A"
        Rectangle {
            width: parent.width * (root.stage / 6); height: parent.height; color: "#FF2D55"
            Behavior on width { NumberAnimation { duration: 250 } }
        }
    }
}
SPLASHEOF

# KDE color scheme
cat > config/includes.chroot/usr/share/color-schemes/CipherOS.colors << 'EOF'
[Colors:Button]
BackgroundNormal=18,18,26
ForegroundNormal=230,230,240
DecorationFocus=255,45,85
DecorationHover=57,255,20

[Colors:Selection]
BackgroundNormal=255,45,85
ForegroundNormal=255,255,255

[Colors:Tooltip]
BackgroundNormal=18,18,26
ForegroundNormal=220,220,235

[Colors:View]
BackgroundNormal=10,10,15
ForegroundNormal=220,220,235
DecorationFocus=255,45,85
DecorationHover=57,255,20
ForegroundLink=57,255,20
ForegroundActive=255,121,198

[Colors:Window]
BackgroundNormal=10,10,15
ForegroundNormal=220,220,235
DecorationFocus=255,45,85
DecorationHover=57,255,20
ForegroundLink=57,255,20
ForegroundActive=255,121,198

[General]
ColorScheme=CipherOS
Name=CipherOS

[KDE]
contrast=4
EOF

# Skel KDE config
cat > config/includes.chroot/etc/skel/.config/kdeglobals << 'EOF'
[General]
ColorScheme=CipherOS

[Icons]
Theme=breeze-dark

[KDE]
LookAndFeelPackage=CipherOS
SingleClick=false
widgetStyle=kvantum-dark
EOF

cat > config/includes.chroot/etc/skel/.config/plasmarc << 'EOF'
[Theme]
name=default
EOF

cat > config/includes.chroot/etc/skel/.config/gtk-3.0/settings.ini << 'EOF'
[Settings]
gtk-theme-name=Breeze-Dark
gtk-icon-theme-name=breeze-dark
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=breeze_cursors
gtk-application-prefer-dark-theme=1
EOF

cat > config/includes.chroot/etc/skel/.config/gtk-4.0/settings.ini << 'EOF'
[Settings]
gtk-theme-name=Breeze-Dark
gtk-icon-theme-name=breeze-dark
gtk-cursor-theme-name=breeze_cursors
gtk-application-prefer-dark-theme=1
EOF

success "KDE Plasma theming written"

# ── PHASE 8: CALAMARES ────────────────────────────────────────────────────────
header "🧩 PHASE 8 — Calamares Installer"

CAL_DIR="config/includes.chroot/etc/calamares"

cat > "$CAL_DIR/settings.conf" << 'EOF'
---
modules-search: [ local, /usr/lib/calamares/modules ]

sequence:
  - show:
    - welcome
    - locale
    - keyboard
    - disk
    - users
    - summary
  - exec:
    - partition
    - mount
    - unpackfs
    - machineid
    - fstab
    - locale
    - keyboard
    - localecfg
    - users
    - networkcfg
    - hwclock
    - grubcfg
    - bootloader
    - packages
    - plymouthcfg
    - initramfscfg
    - initramfs
    - removeuser
    - umount
  - show:
    - finished

branding: cipheros
prompt-install: true
dont-chroot: false
disable-cancel: false
disable-cancel-during-exec: false
EOF

cat > "$CAL_DIR/branding/cipheros/branding.desc" << 'EOF'
---
componentName: cipheros
welcomeStyleCalamares: false
welcomeExpandingLogo: true

strings:
    productName:         CipherOS
    shortProductName:    CipherOS
    version:             1.0
    shortVersion:        1.0
    versionedName:       CipherOS 1.0
    shortVersionedName:  CipherOS 1.0
    bootloaderEntryName: CipherOS
    productUrl:          https://cipheros.gt.tc
    supportUrl:          https://github.com/ricowolmarans/CipherOS/issues
    releaseNotesUrl:     https://cipheros.gt.tc/release-notes

images:
    productLogo:         "cipheros-logo.png"
    productIcon:         "cipheros-logo.png"
    productWelcome:      "cipheros-welcome.png"

slideshow:               "show.qml"
slideshowAPI:            2

style:
    sidebarBackground:   "#12121A"
    sidebarText:         "#DCDCEB"
    sidebarTextSelect:   "#FF2D55"
    sidebarTextHighlight:"#FF2D55"
EOF

cat > "$CAL_DIR/branding/cipheros/show.qml" << 'SHOWEOF'
import QtQuick 2.15
import QtQuick.Controls 2.15
import Calamares.Slideshow 1.0

Presentation {
    id: presentation
    timer.interval: 5000

    Slide {
        Rectangle {
            anchors.fill: parent; color: "#0A0A0F"
            Column { anchors.centerIn: parent; spacing: 24
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "CIPHER OS"; color: "#FF2D55"
                       font.pixelSize: 64; font.bold: true; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "Installing your weapon of choice..."
                       color: "#39FF14"; font.pixelSize: 20; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "\"Built for the ones who know.\""
                       color: "#FF79C6"; font.pixelSize: 15; font.family: "monospace"; opacity: 0.8 }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent; color: "#0A0A0F"
            Column { anchors.centerIn: parent; spacing: 20
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "🔐 SECURITY TOOLKIT"; color: "#FF2D55"
                       font.pixelSize: 36; font.bold: true; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "nmap  •  metasploit  •  wireshark  •  hashcat"
                       color: "#39FF14"; font.pixelSize: 18; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "aircrack-ng  •  sqlmap  •  hydra  •  burpsuite"
                       color: "#39FF14"; font.pixelSize: 18; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "A complete ethical hacking toolkit — ready on first boot."
                       color: "#DCDCEB"; font.pixelSize: 14; font.family: "monospace"; opacity: 0.7 }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent; color: "#0A0A0F"
            Column { anchors.centerIn: parent; spacing: 20
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "🎮 GAMING READY"; color: "#FF2D55"
                       font.pixelSize: 36; font.bold: true; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "Steam  •  Lutris  •  Heroic  •  Wine + Proton"
                       color: "#39FF14"; font.pixelSize: 18; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "XanMod kernel  •  GameMode  •  MangoHUD  •  Vulkan"
                       color: "#39FF14"; font.pixelSize: 18; font.family: "monospace" }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent; color: "#0A0A0F"
            Column { anchors.centerIn: parent; spacing: 20
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "🛡️  PRIVACY FIRST"; color: "#FF2D55"
                       font.pixelSize: 36; font.bold: true; font.family: "monospace" }
                Repeater {
                    model: ["✓  No telemetry — ever","✓  DNS over HTTPS via dnscrypt-proxy",
                            "✓  MAC address randomization","✓  UFW firewall — deny incoming",
                            "✓  Firejail + AppArmor app isolation"]
                    Text { anchors.horizontalCenter: parent.horizontalCenter
                           text: modelData; color: "#39FF14"
                           font.pixelSize: 16; font.family: "monospace" }
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent; color: "#0A0A0F"
            Column { anchors.centerIn: parent; spacing: 24
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "⚡ ALMOST THERE"; color: "#FF2D55"
                       font.pixelSize: 36; font.bold: true; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "Finalizing your CipherOS installation..."
                       color: "#39FF14"; font.pixelSize: 18; font.family: "monospace" }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                       text: "cipheros.gt.tc"; color: "#FF79C6"
                       font.pixelSize: 14; font.family: "monospace"; opacity: 0.7 }
            }
        }
    }
}
SHOWEOF

cat > "$CAL_DIR/modules/welcome.conf" << 'EOF'
---
showSupportUrl:     true
showKnownIssuesUrl: false
showReleaseNotesUrl: false
requirements:
    check:    [ storage, ram, power, internet ]
    required: [ storage, ram ]
geoip:
    style: "none"
EOF

cat > "$CAL_DIR/modules/partition.conf" << 'EOF'
---
efiSystemPartition:     "/boot/efi"
efiSystemPartitionSize: 300M
userSwapChoices:        [ none, small, suspend, file ]
defaultFileSystemType:  "ext4"
availableFileSystemTypes: ["ext4","btrfs","xfs"]
initialPartitioningChoice: erase
initialSwapChoice: file
EOF

cat > "$CAL_DIR/modules/users.conf" << 'EOF'
---
defaultGroups:
    - name: users
      state: must-be-group
    - name: sudo
      state: must-be-group
    - name: video
      state: must-be-group
    - name: audio
      state: must-be-group
    - name: wireshark
      state: must-be-group
    - name: netdev
      state: must-be-group
sudoersGroup:    sudo
setRootPassword: true
doAutoLogin:     false
passwordRequirements:
    minLength: 8
userShell: /usr/bin/zsh
EOF

success "Calamares installer configured"

# ── PHASE 9: PLYMOUTH ────────────────────────────────────────────────────────
header "🌊 PHASE 9 — Plymouth Animated Boot Splash"

PLYMOUTH_DIR="config/includes.chroot/usr/share/plymouth/themes/cipheros"

cat > "$PLYMOUTH_DIR/cipheros.plymouth" << 'EOF'
[Plymouth Theme]
Name=CipherOS
Description=CipherOS animated cyberpunk boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/cipheros
ScriptFile=/usr/share/plymouth/themes/cipheros/cipheros.script
EOF

cat > "$PLYMOUTH_DIR/cipheros.script" << 'PLYMOUTHEOF'
Window.SetBackgroundTopColor(0.04, 0.04, 0.06);
Window.SetBackgroundBottomColor(0.02, 0.02, 0.04);

screen_width  = Window.GetWidth();
screen_height = Window.GetHeight();

COLS = 40;
col_x = []; col_y = []; col_speed = []; col_sprites = []; col_alpha = [];
col_chars = ["0","1","█","▓","░","X","Z","A","9","7","╬","╔","╗","╚","╝","║","═"];

fun init_matrix() {
    for (i = 0; i < COLS; i++) {
        col_x[i]     = Math.Int(Math.Random() * screen_width);
        col_y[i]     = Math.Int(Math.Random() * screen_height);
        col_speed[i] = 4 + Math.Int(Math.Random() * 8);
        col_alpha[i] = 0.05 + Math.Random() * 0.25;
        img  = Image(16, 20);
        op   = img.GetRootOperator();
        op.SetForegroundColor(0.22, 1.0, 0.08, col_alpha[i]);
        op.SetFont("Monospace 10");
        op.DrawText(0, 0, col_chars[Math.Int(Math.Random() * Math.ArraySize(col_chars))]);
        col_sprites[i] = Sprite();
        col_sprites[i].SetImage(img);
        col_sprites[i].SetX(col_x[i]);
        col_sprites[i].SetY(col_y[i]);
        col_sprites[i].SetZ(1);
    }
}

fun update_matrix() {
    for (i = 0; i < COLS; i++) {
        col_y[i] += col_speed[i];
        if (col_y[i] > screen_height) {
            col_y[i] = -20;
            col_x[i] = Math.Int(Math.Random() * screen_width);
        }
        col_sprites[i].SetX(col_x[i]);
        col_sprites[i].SetY(col_y[i]);
    }
}

fun draw_logo() {
    img = Image(500, 60);
    op  = img.GetRootOperator();
    op.SetForegroundColor(1.0, 0.18, 0.33, 1.0);
    op.SetFont("Monospace Bold 28");
    op.DrawText(0, 0, "C I P H E R  O S");
    op.SetForegroundColor(0.22, 1.0, 0.08, 0.9);
    op.SetFont("Monospace 12");
    op.DrawText(60, 38, "\"Built for the ones who know.\"");
    s = Sprite(); s.SetImage(img);
    s.SetX(screen_width / 2 - 250);
    s.SetY(screen_height / 2 - 80);
    s.SetZ(10);
}

BAR_W = 400; BAR_H = 3;
BAR_X = screen_width / 2 - BAR_W / 2;
BAR_Y = screen_height / 2 + 60;

bar_bg_img = Image(BAR_W, BAR_H);
bar_bg_op  = bar_bg_img.GetRootOperator();
bar_bg_op.SetForegroundColor(0.07, 0.07, 0.10, 1.0);
bar_bg_op.FillRectangle(0, 0, BAR_W, BAR_H);
bar_bg = Sprite(); bar_bg.SetImage(bar_bg_img);
bar_bg.SetX(BAR_X); bar_bg.SetY(BAR_Y); bar_bg.SetZ(9);

bar_fill = Sprite(); bar_fill.SetZ(10); bar_fill.SetX(BAR_X); bar_fill.SetY(BAR_Y);
glow     = Sprite(); glow.SetZ(11);     glow.SetY(BAR_Y - 3);

fun update_progress(duration, progress) {
    fw = Math.Int(BAR_W * progress);
    if (fw < 1) fw = 1;
    fi = Image(fw, BAR_H); fo = fi.GetRootOperator();
    fo.SetForegroundColor(1.0, 0.18, 0.33, 1.0);
    fo.FillRectangle(0, 0, fw, BAR_H);
    bar_fill.SetImage(fi);
    gi = Image(8, 8); go = gi.GetRootOperator();
    go.SetForegroundColor(1.0, 0.47, 0.78, 0.9);
    go.FillRectangle(0, 0, 8, 8);
    glow.SetImage(gi); glow.SetX(BAR_X + fw - 4);
}

tick = 0;
draw_logo();
init_matrix();

fun refresh_callback() { tick++; if (Math.Int(tick % 2) == 0) update_matrix(); }
Plymouth.SetRefreshFunction(refresh_callback);
Plymouth.SetBootProgressFunction(update_progress);
PLYMOUTHEOF

success "Plymouth animated boot splash written"

# ── PHASE 10: POWERLEVEL10K ───────────────────────────────────────────────────
header "⚡ PHASE 10 — Powerlevel10k Terminal Prompt"

cat > config/includes.chroot/etc/skel/.p10k.zsh << 'P10KEOF'
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'
  autoload -Uz is-at-least && is-at-least 5.1 || return

  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs newline prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status command_execution_time background_jobs ram time newline)

  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_BACKGROUND=
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_{LEFT,RIGHT}_WHITESPACE=
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SUBSEGMENT_SEPARATOR=' '
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SEGMENT_SEPARATOR=

  typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=196
  typeset -g POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION='⬡'

  typeset -g POWERLEVEL9K_DIR_FOREGROUND=51
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80

  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=46
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'

  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_ERROR=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=196
  typeset -g POWERLEVEL9K_STATUS_ERROR_VISUAL_IDENTIFIER_EXPANSION='✘'

  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=101

  typeset -g POWERLEVEL9K_RAM_FOREGROUND=66

  typeset -g POWERLEVEL9K_TIME_FOREGROUND=46
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M:%S}'

  typeset -g POWERLEVEL9K_VCS_BRANCH_ICON='\uF126 '
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true
  typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=76

  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
} always {
  'builtin' 'unset' 'p10k_config_opts'
}
P10KEOF

success "Powerlevel10k config written"

# ── PHASE 11: KVANTUM ────────────────────────────────────────────────────────
header "🪟 PHASE 11 — Kvantum Window Theming"

KVANTUM_DIR="config/includes.chroot/usr/share/Kvantum/CipherOS"

cat > "$KVANTUM_DIR/CipherOS.kvconfig" << 'EOF'
[%General]
author=CipherOS Team
comment=CipherOS cyberpunk dark theme
composite=true
translucent_windows=true
blurring=true
popup_blurring=true
reduce_window_opacity=18
reduce_menu_opacity=10
menu_shadow_depth=7
animate_states=true
scroll_width=8
scroll_arrows=false
transient_scrollbar=true

[GeneralColors]
window.color=#0A0A0F
base.color=#12121A
alt.base.color=#0E0E18
button.color=#1A1A28
highlight.color=#FF2D55
inactive.highlight.color=#8B1A30
text.color=#DCDCEB
window.text.color=#DCDCEB
button.text.color=#DCDCEB
disabled.text.color=#555565
tooltip.base.color=#12121A
tooltip.text.color=#DCDCEB
link.color=#39FF14
link.visited.color=#FF79C6
progress.indicator.color=#FF2D55

[Hacks]
blur_konsole=true
transparent_ktitle_label=true
transparent_dolphin_view=true
transparent_titlebar=true
disabled_icon_opacity=60
EOF

cat > "$KVANTUM_DIR/CipherOS.svg" << 'SVGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
  <defs>
    <linearGradient id="btn" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#1E1E2E"/>
      <stop offset="100%" style="stop-color:#12121A"/>
    </linearGradient>
    <linearGradient id="hl" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#FF2D55"/>
      <stop offset="100%" style="stop-color:#CC1A3A"/>
    </linearGradient>
    <filter id="glow">
      <feGaussianBlur stdDeviation="2" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <g id="button-normal-rest">
    <rect x="1" y="1" width="198" height="198" rx="3" fill="url(#btn)" stroke="#FF2D5540" stroke-width="1"/>
  </g>
  <g id="button-normal-focused">
    <rect x="1" y="1" width="198" height="198" rx="3" fill="url(#btn)" stroke="#FF2D55" stroke-width="1.5" filter="url(#glow)"/>
  </g>
  <g id="button-normal-pressed">
    <rect x="1" y="1" width="198" height="198" rx="3" fill="#0A0A0F" stroke="#FF2D55" stroke-width="1.5"/>
  </g>
  <g id="lineedit-normal-rest">
    <rect x="1" y="1" width="198" height="198" rx="2" fill="#0A0A0F" stroke="#39FF1440" stroke-width="1"/>
  </g>
  <g id="lineedit-normal-focused">
    <rect x="1" y="1" width="198" height="198" rx="2" fill="#0A0A0F" stroke="#FF2D55" stroke-width="1.5" filter="url(#glow)"/>
  </g>
  <g id="checkbox-normal-checked">
    <rect x="3" y="3" width="194" height="194" rx="2" fill="#FF2D5520" stroke="#FF2D55" stroke-width="1.5"/>
    <path d="M 40,100 L 80,150 L 160,60" stroke="#FF2D55" stroke-width="16" fill="none" stroke-linecap="round"/>
  </g>
  <g id="progressbar-horizontal-indicator">
    <rect x="1" y="1" width="198" height="198" rx="2" fill="url(#hl)" filter="url(#glow)"/>
  </g>
  <g id="scrollbar-slider-normal-rest">
    <rect x="3" y="3" width="194" height="194" rx="4" fill="#FF2D5530"/>
  </g>
  <g id="scrollbar-slider-normal-focused">
    <rect x="3" y="3" width="194" height="194" rx="4" fill="#FF2D5560"/>
  </g>
  <g id="menuitem-focused">
    <rect x="1" y="1" width="198" height="198" rx="2" fill="#FF2D5530" stroke="#FF2D5550" stroke-width="1"/>
  </g>
</svg>
SVGEOF

cat > config/includes.chroot/etc/skel/.config/Kvantum/kvantum.kvconfig << 'EOF'
[General]
theme=CipherOS
EOF

success "Kvantum theme written"

# ── PHASE 12: KONSOLE ────────────────────────────────────────────────────────
header "💻 PHASE 12 — Konsole Terminal Profile"

KONSOLE_DIR="config/includes.chroot/usr/share/konsole"

cat > "$KONSOLE_DIR/CipherOS.colorscheme" << 'EOF'
[Background]
Color=10,10,15

[BackgroundIntense]
Color=18,18,26

[Color0]
Color=10,10,15
[Color0Intense]
Color=30,30,45

[Color1]
Color=255,45,85
[Color1Intense]
Color=255,80,110

[Color2]
Color=57,255,20
[Color2Intense]
Color=100,255,60

[Color3]
Color=255,200,0
[Color3Intense]
Color=255,220,50

[Color4]
Color=0,180,255
[Color4Intense]
Color=50,210,255

[Color5]
Color=255,121,198
[Color5Intense]
Color=255,160,220

[Color6]
Color=0,230,230
[Color6Intense]
Color=50,255,255

[Color7]
Color=220,220,235
[Color7Intense]
Color=255,255,255

[Foreground]
Color=220,220,235
[ForegroundIntense]
Color=255,255,255

[General]
Blur=true
BlurRadius=20
ColorRandomization=false
Description=CipherOS
Opacity=0.88
EOF

cat > "$KONSOLE_DIR/CipherOS.profile" << 'EOF'
[Appearance]
ColorScheme=CipherOS
Font=FiraCode Nerd Font,12,-1,5,50,0,0,0,0,0
LineSpacing=2

[Cursor Options]
CursorShape=1
UseCustomCursorColor=true
CustomCursorColor=255,45,85

[General]
Name=CipherOS
Parent=FALLBACK/
TerminalColumns=120
TerminalRows=35

[Scrolling]
HistoryMode=2
HistorySize=10000
ScrollBarPosition=2

[Terminal Features]
BlinkingCursorEnabled=true
FlowControlEnabled=false
EOF

cp "$KONSOLE_DIR/CipherOS.profile" \
    config/includes.chroot/etc/skel/.local/share/konsole/CipherOS.profile

cat > config/includes.chroot/etc/skel/.config/konsolerc << 'EOF'
[Desktop Entry]
DefaultProfile=CipherOS.profile

[KonsoleWindow]
ShowMenuBarByDefault=false

[TabBar]
TabBarPosition=Top
TabBarVisibility=ShowTabBarWhenNeeded
EOF

success "Konsole profile written"

# ── PHASE 13: MAIN CHROOT HOOK ────────────────────────────────────────────────
header "🪝 PHASE 13 — Chroot Hook"

cat > config/hooks/live/0100-cipheros-setup.hook.chroot << 'HOOKEOF'
#!/bin/bash
set -euo pipefail
echo "🔐 CipherOS Debian Hook — Starting..."

# ── Add non-free and contrib (already in sources via live-build config)
apt-get update -qq

# ── 32-bit for Wine/Steam ─────────────────────────────────────────────────────
dpkg --add-architecture i386
apt-get update -qq

# ── XanMod Kernel (Debian repo — no PPA needed) ───────────────────────────────
echo "🧠 Installing XanMod kernel..."
wget -qO /usr/share/keyrings/xanmod-archive-keyring.gpg \
    https://dl.xanmod.org/archive.key 2>/dev/null || \
    curl -fsSL https://dl.xanmod.org/archive.key | \
    gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' \
    > /etc/apt/sources.list.d/xanmod-release.list
apt-get update -qq
apt-get install -y linux-xanmod-x64v3 2>/dev/null || \
    apt-get install -y linux-xanmod-x64v2 2>/dev/null || \
    echo "⚠️ XanMod unavailable — default kernel kept"

# ── Brave Browser (Debian repo) ───────────────────────────────────────────────
echo "🦁 Installing Brave..."
curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] \
    https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list
apt-get update -qq && apt-get install -y brave-browser

# Set Brave as the system default browser
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/brave-browser 200
update-alternatives --set x-www-browser /usr/bin/brave-browser 2>/dev/null || true
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/brave-browser 200
update-alternatives --set gnome-www-browser /usr/bin/brave-browser 2>/dev/null || true

mkdir -p /etc/skel/.config
cat > /etc/skel/.config/mimeapps.list << 'EOF'
[Default Applications]
text/html=brave-browser.desktop
x-scheme-handler/http=brave-browser.desktop
x-scheme-handler/https=brave-browser.desktop
x-scheme-handler/about=brave-browser.desktop
x-scheme-handler/unknown=brave-browser.desktop
EOF

# ── Metasploit ────────────────────────────────────────────────────────────────
echo "💀 Installing Metasploit..."
curl -fsSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfinstall | bash

# ── Heroic Games Launcher ─────────────────────────────────────────────────────
echo "🎮 Installing Heroic..."
HEROIC_VER=$(curl -s https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest \
    | grep tag_name | cut -d'"' -f4 | tr -d 'v')
wget -q "https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/download/v${HEROIC_VER}/heroic_${HEROIC_VER}_amd64.deb" \
    -O /tmp/heroic.deb
dpkg -i /tmp/heroic.deb || apt-get install -f -y
rm -f /tmp/heroic.deb

# ── Flatpak ───────────────────────────────────────────────────────────────────
apt-get install -y flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

# ── Kvantum ───────────────────────────────────────────────────────────────────
apt-get install -y qt5-style-kvantum qt5-style-kvantum-themes \
    qt6-style-kvantum 2>/dev/null || true

# ── Oh-My-Zsh + Powerlevel10k ─────────────────────────────────────────────────
echo "⚡ Installing Oh-My-Zsh + Powerlevel10k..."
git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /usr/share/oh-my-zsh 2>/dev/null || true
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git /usr/share/powerlevel10k 2>/dev/null || true
mkdir -p /usr/share/oh-my-zsh/custom/themes
ln -sfn /usr/share/powerlevel10k \
    /usr/share/oh-my-zsh/custom/themes/powerlevel10k 2>/dev/null || true
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
    /usr/share/oh-my-zsh/custom/plugins/zsh-autosuggestions 2>/dev/null || true
git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
    /usr/share/oh-my-zsh/custom/plugins/zsh-syntax-highlighting 2>/dev/null || true

# ── Plymouth ──────────────────────────────────────────────────────────────────
echo "🌊 Configuring Plymouth..."
apt-get install -y plymouth plymouth-themes 2>/dev/null || true
if [[ -f /usr/share/plymouth/themes/cipheros/cipheros.plymouth ]]; then
    update-alternatives --install \
        /usr/share/plymouth/themes/default.plymouth default.plymouth \
        /usr/share/plymouth/themes/cipheros/cipheros.plymouth 100
    update-alternatives --set default.plymouth \
        /usr/share/plymouth/themes/cipheros/cipheros.plymouth 2>/dev/null || true
fi
update-initramfs -u 2>/dev/null || true

# ── Proxychains ───────────────────────────────────────────────────────────────
cat > /etc/proxychains4.conf << 'EOF'
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 127.0.0.1 9050
EOF

# ── Firewall ──────────────────────────────────────────────────────────────────
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
systemctl enable ufw

# ── AppArmor ─────────────────────────────────────────────────────────────────
systemctl enable apparmor
firecfg --fix 2>/dev/null || true

# ── Sysctl tweaks ─────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/99-cipheros.conf << 'EOF'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
kernel.sched_autogroup_enabled = 1
kernel.nmi_watchdog = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
EOF
systemctl enable preload irqbalance thermald 2>/dev/null || true

# ── MAC randomization ─────────────────────────────────────────────────────────
mkdir -p /etc/NetworkManager/conf.d/
cat > /etc/NetworkManager/conf.d/99-mac-randomize.conf << 'EOF'
[device]
wifi.scan-rand-mac-address=yes
[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF

# ── dnscrypt-proxy ────────────────────────────────────────────────────────────
cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOF'
server_names = ['cloudflare', 'quad9-doh-ip4-port443-filter-ecs-pri']
listen_addresses = ['127.0.0.1:5300']
ipv4_servers = true
doh_servers = true
require_nolog = true
cache = true
cache_size = 4096
EOF
systemctl enable dnscrypt-proxy

# ── OS Branding ───────────────────────────────────────────────────────────────
cat > /etc/os-release << 'EOF'
NAME="CipherOS"
VERSION="1.0 (Phantom)"
ID=cipheros
ID_LIKE=debian
PRETTY_NAME="CipherOS 1.0 (Phantom)"
VERSION_ID="1.0"
HOME_URL="https://cipheros.gt.tc"
SUPPORT_URL="https://github.com/ricowolmarans/CipherOS/issues"
VERSION_CODENAME=phantom
EOF

cat > /etc/debian_version << 'EOF'
CipherOS/1.0 (Debian 12 Bookworm)
EOF

# ── ASCII logo + fastfetch ────────────────────────────────────────────────────
mkdir -p /etc/cipheros /etc/skel/.config/fastfetch
cat > /etc/cipheros/ascii-logo.txt << 'EOF'
  ██████╗██╗██████╗ ██╗  ██╗███████╗██████╗  ██████╗ ███████╗
 ██╔════╝██║██╔══██╗██║  ██║██╔════╝██╔══██╗██╔═══██╗██╔════╝
 ██║     ██║██████╔╝███████║█████╗  ██████╔╝██║   ██║███████╗
 ██║     ██║██╔═══╝ ██╔══██║██╔══╝  ██╔══██╗██║   ██║╚════██║
 ╚██████╗██║██║     ██║  ██║███████╗██║  ██║╚██████╔╝███████║
  ╚═════╝╚═╝╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
              "Built for the ones who know."
EOF

cat > /etc/skel/.config/fastfetch/config.jsonc << 'EOF'
{
    "logo": {
        "source": "/etc/cipheros/ascii-logo.txt",
        "color": { "1": "red", "2": "green" }
    },
    "modules": [
        "title","separator","os","kernel","uptime",
        "packages","shell","display","de","cpu","gpu","memory","disk"
    ]
}
EOF

# ── Zsh + Oh-My-Zsh + p10k ────────────────────────────────────────────────────
cat > /etc/skel/.zshrc << 'EOF'
export TERM="xterm-256color"
export ZSH="/usr/share/oh-my-zsh"
export ZSH_CUSTOM="$ZSH/custom"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(git zsh-autosuggestions zsh-syntax-highlighting sudo colored-man-pages extract)

if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

source $ZSH/oh-my-zsh.sh 2>/dev/null || true
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

alias ll='ls -alFh --color=auto'
alias update='sudo apt update && sudo apt upgrade -y'
alias install='sudo apt install'
alias myip='curl -s ifconfig.me'
alias ports='ss -tulpn'
alias scan='sudo nmap -sV -sC'
alias anon='sudo systemctl start tor && proxychains4'

fastfetch 2>/dev/null
EOF

sed -i 's|SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd

# ── GRUB branding ─────────────────────────────────────────────────────────────
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="CipherOS"/' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=off nowatchdog"/' \
    /etc/default/grub
update-grub 2>/dev/null || true

# ── DaVinci Resolve helper ────────────────────────────────────────────────────
cat > /usr/local/bin/install-davinci << 'EOF'
#!/bin/bash
echo "Download DaVinci Resolve from: https://www.blackmagicdesign.com/products/davinciresolve"
echo "Then run: bash ~/Downloads/DaVinci_Resolve_*.run"
EOF
chmod +x /usr/local/bin/install-davinci

# ── First-boot service ────────────────────────────────────────────────────────
cat > /usr/local/bin/cipheros-firstboot << 'EOF'
#!/bin/bash
MARKER="/var/lib/cipheros/.firstboot_done"
[ -f "$MARKER" ] && exit 0
mkdir -p /var/lib/cipheros
PRIMARY_USER=$(getent passwd 1000 | cut -d: -f1)
if [ -n "$PRIMARY_USER" ]; then
    chsh -s /usr/bin/zsh "$PRIMARY_USER"
    cp /etc/skel/.zshrc /home/"$PRIMARY_USER"/.zshrc 2>/dev/null || true
    cp /etc/skel/.p10k.zsh /home/"$PRIMARY_USER"/.p10k.zsh 2>/dev/null || true
    cp -r /etc/skel/.config /home/"$PRIMARY_USER"/ 2>/dev/null || true
    cp -r /etc/skel/.local /home/"$PRIMARY_USER"/ 2>/dev/null || true
    chown -R "$PRIMARY_USER":"$PRIMARY_USER" /home/"$PRIMARY_USER"/
    usermod -aG wireshark,netdev,sudo "$PRIMARY_USER" 2>/dev/null || true
    # Ensure Brave is default browser for this user's session
    sudo -u "$PRIMARY_USER" xdg-settings set default-web-browser brave-browser.desktop 2>/dev/null || true
fi
touch "$MARKER"
EOF
chmod +x /usr/local/bin/cipheros-firstboot

cat > /etc/systemd/system/cipheros-firstboot.service << 'EOF'
[Unit]
Description=CipherOS First Boot Setup
After=multi-user.target
ConditionPathExists=!/var/lib/cipheros/.firstboot_done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cipheros-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable cipheros-firstboot
echo "✅ CipherOS Debian hook complete."
HOOKEOF
chmod +x config/hooks/live/0100-cipheros-setup.hook.chroot

# Cleanup hook
cat > config/hooks/normal/0200-cleanup.hook.chroot << 'EOF'
#!/bin/bash
set -e
apt-get clean && apt-get autoremove -y
rm -rf /tmp/* /var/tmp/*
rm -f /etc/ssh/ssh_host_*
history -c
cat /dev/null > /root/.bash_history 2>/dev/null || true
journalctl --vacuum-size=1M 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
echo "✅ Cleanup done."
EOF
chmod +x config/hooks/normal/0200-cleanup.hook.chroot

success "All hooks written"

# ── PHASE 14: GIT ─────────────────────────────────────────────────────────────
header "🗂️  PHASE 14 — Git"

if [[ ! -d "$WORKDIR/.git" ]]; then
    git init 2>>"$LOG_FILE"
    cat > .gitignore << 'EOF'
chroot/
binary/
*.iso
*.log
cache/
.build/
EOF
    git add auto/ config/ .gitignore 2>>"$LOG_FILE"
    git commit -m "feat: CipherOS v4.0 — Debian 12 Bookworm base" 2>>"$LOG_FILE"
    success "Git repo initialised"
else
    warn "Git repo exists — skipping"
fi

# ── PHASE 15: BUILD ───────────────────────────────────────────────────────────
header "🚀 PHASE 15 — Building ISO (30–90 min)"

log "Monitor in another terminal: tail -f $LOG_FILE"
START_TIME=$(date +%s)
lb build 2>&1 | tee -a "$LOG_FILE"
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

# ── POST-BUILD ────────────────────────────────────────────────────────────────
header "✅ Post-Build"

BUILT_ISO=$(find "$WORKDIR" -maxdepth 1 -name "*.iso" | head -1)
[[ -z "$BUILT_ISO" ]] && { echo -e "${RED}❌ No ISO found. Check $LOG_FILE${RESET}"; exit 1; }
[[ "$BUILT_ISO" != "$WORKDIR/$ISO_NAME" ]] && mv "$BUILT_ISO" "$WORKDIR/$ISO_NAME"

ISO_SIZE=$(du -sh "$WORKDIR/$ISO_NAME" | cut -f1)
sha256sum "$ISO_NAME" > SHA256SUMS
sha512sum "$ISO_NAME" > SHA512SUMS

echo ""
echo -e "${PINK}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${PINK}║${RED}      🔐 CipherOS v4.0 Build Complete!                ${PINK}║${RESET}"
echo -e "${PINK}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${PINK}║${RESET}  Base    : ${CYAN}Debian 12 (Bookworm)${RESET}"
echo -e "${PINK}║${RESET}  ISO     : ${GREEN}$WORKDIR/$ISO_NAME${RESET}"
echo -e "${PINK}║${RESET}  Size    : ${CYAN}$ISO_SIZE${RESET}"
echo -e "${PINK}║${RESET}  Time    : ${CYAN}${ELAPSED} minutes${RESET}"
echo -e "${PINK}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Debian 12 base — no snaps, no telemetry"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Calamares installer + 5 branded slides"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} SDDM cyberpunk login screen"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} KDE Plasma + CipherOS color scheme"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Your wallpapers registered in System Settings"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Plymouth matrix rain boot splash"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Oh-My-Zsh + Powerlevel10k neon prompt"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Kvantum blur + neon glow borders"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Konsole FiraCode + neon cursor + blur"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Full security + gaming + creative stack"
echo -e "${PINK}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${PINK}║${RESET}  ${YELLOW}Test:${RESET} ${CYAN}qemu-system-x86_64 -enable-kvm -m 4096 \\${RESET}"
echo -e "${PINK}║${RESET}  ${CYAN}  -cdrom $WORKDIR/$ISO_NAME -vnc :0 -daemonize${RESET}"
echo -e "${PINK}║${RESET}  ${YELLOW}VNC:${RESET}  ${CYAN}your-ip:5900${RESET}"
echo -e "${PINK}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
