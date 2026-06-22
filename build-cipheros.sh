#!/usr/bin/env bash
# =============================================================================
#  CipherOS — Automated ISO Build Script v3.0
#  Base: Ubuntu 24.04 LTS (Noble) | Build Host: Ubuntu 26.04
#  Includes: Calamares, SDDM, KDE theming, Plymouth, Powerlevel10k, Kvantum, Konsole
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

# CipherOS Color Palette
COLOR_PRIMARY="#FF2D55"    # Neon Red-Pink
COLOR_SECONDARY="#39FF14"  # Matrix Green
COLOR_ACCENT="#FF79C6"     # Pink accent
COLOR_BG="#0A0A0F"         # Near black background
COLOR_SURFACE="#12121A"    # Surface color

# ── COLORS (terminal) ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; PINK='\033[0;35m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[$(date '+%H:%M:%S')]${RESET} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}✅ $*${RESET}" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠️  $*${RESET}" | tee -a "$LOG_FILE"; }
header()  { echo -e "\n${PINK}══════════════════════════════════════════${RESET}";
            echo -e "${RED}  $*${RESET}";
            echo -e "${PINK}══════════════════════════════════════════${RESET}\n" | tee -a "$LOG_FILE"; }

# ── PREFLIGHT CHECKS ─────────────────────────────────────────────────────────
header "🔐 CipherOS Build System v2.0 Starting"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Run as root: sudo -i && bash build-cipheros.sh${RESET}"
    exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"
echo "Build started: $(date)" > "$LOG_FILE"

log "Checking system requirements..."

FREE_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [[ $FREE_GB -lt 60 ]]; then
    echo -e "${RED}❌ Insufficient disk space: ${FREE_GB}GB free, need 60GB+${RESET}"; exit 1
fi
success "Disk space OK: ${FREE_GB}GB free"

RAM_GB=$(free -g | awk 'NR==2 {print $2}')
[[ $RAM_GB -lt 6 ]] && warn "Low RAM: ${RAM_GB}GB. Recommended: 8GB+"
success "RAM: ${RAM_GB}GB"

if ! curl -s --max-time 5 https://archive.ubuntu.com > /dev/null; then
    echo -e "${RED}❌ No internet connectivity.${RESET}"; exit 1
fi
success "Internet OK"

# ── PHASE 1: BUILD DEPENDENCIES ──────────────────────────────────────────────
header "📦 PHASE 1 — Installing Build Dependencies"

apt-get update -qq 2>>"$LOG_FILE"
apt-get install -y \
    live-build debootstrap squashfs-tools xorriso \
    isolinux syslinux-common grub-pc-bin grub-efi-amd64-bin \
    mtools dosfstools git curl wget gnupg2 rsync pigz \
    qemu-utils ovmf imagemagick python3-pip \
    2>>"$LOG_FILE"

success "Build dependencies installed (live-build $(lb --version))"

# ── PHASE 2: PROJECT STRUCTURE ────────────────────────────────────────────────
header "📁 PHASE 2 — Project Structure"

if [[ -d "$WORKDIR/chroot" || -d "$WORKDIR/binary" ]]; then
    warn "Previous build found. Cleaning..."
    lb clean --all 2>>"$LOG_FILE" || true
fi

mkdir -p config/{package-lists,hooks/live,hooks/normal}
mkdir -p config/includes.chroot/{etc/cipheros,etc/calamares/branding/cipheros,etc/calamares/modules,usr/local/bin,usr/share/sddm/themes/cipheros,usr/share/plasma/look-and-feel/CipherOS,usr/share/wallpapers/CipherOS/contents/images,usr/share/color-schemes,usr/share/icons}
mkdir -p config/includes.chroot/etc/skel/.config/{plasma-org.kde.plasma.desktop-appletsrc,fastfetch,gtk-3.0,gtk-4.0}

success "Project structure ready"

# ── PHASE 3: LIVE-BUILD CONFIG ───────────────────────────────────────────────
header "⚙️  PHASE 3 — live-build Configuration"

mkdir -p auto
cat > auto/config << 'AUTOEOF'
#!/bin/sh
set -e
lb config noauto \
    --mode ubuntu \
    --distribution noble \
    --architectures amd64 \
    --archive-areas "main restricted universe multiverse" \
    --mirror-bootstrap http://archive.ubuntu.com/ubuntu/ \
    --mirror-chroot http://archive.ubuntu.com/ubuntu/ \
    --mirror-binary http://archive.ubuntu.com/ubuntu/ \
    --mirror-binary-security http://security.ubuntu.com/ubuntu/ \
    --security true --updates true --backports false \
    --bootloader grub-efi \
    --binary-images iso-hybrid \
    --iso-volume "CipherOS 1.0" \
    --iso-publisher "CipherOS Project" \
    --iso-application "CipherOS 1.0 Phantom" \
    --memtest none --win32-loader false \
    --debian-installer none \
    --bootappend-live "boot=live components quiet splash" \
    "${@}"
AUTOEOF
chmod +x auto/config
lb config 2>>"$LOG_FILE"
success "live-build configured"

# ── PHASE 4.5: LOAD USER ASSETS ──────────────────────────────────────────────
header "🖼️  PHASE 4.5 — Loading Your Wallpapers & Logo"

WALLPAPER_DEST="config/includes.chroot/usr/share/wallpapers/CipherOS/contents/images"
LOGO_DEST_CAL="config/includes.chroot/etc/calamares/branding/cipheros"

mkdir -p "$WALLPAPER_DEST"
mkdir -p "$LOGO_DEST_CAL"

# ── Wallpapers ────────────────────────────────────────────────────────────────
if [[ -d "$ASSETS_DIR/wallpapers" ]] && \
   [[ $(ls "$ASSETS_DIR/wallpapers"/*.{jpg,jpeg,png,webp} 2>/dev/null | wc -l) -gt 0 ]]; then

    log "Copying your wallpapers from $ASSETS_DIR/wallpapers..."
    FIRST_WALLPAPER=""

    for f in "$ASSETS_DIR/wallpapers"/*.{jpg,jpeg,png,webp}; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        cp "$f" "$WALLPAPER_DEST/$fname"
        [[ -z "$FIRST_WALLPAPER" ]] && FIRST_WALLPAPER="$fname"
        success "  Added wallpaper: $fname"
    done

    # Write KDE wallpaper metadata for each image
    # This makes them show up in System Settings > Wallpaper like a normal OS
    for f in "$WALLPAPER_DEST"/*.{jpg,jpeg,png,webp}; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        name="${fname%.*}"
        WALLPAPER_PKG_DIR="config/includes.chroot/usr/share/wallpapers/CipherOS-${name}"
        mkdir -p "$WALLPAPER_PKG_DIR/contents/images"
        cp "$f" "$WALLPAPER_PKG_DIR/contents/images/$fname"
        cat > "$WALLPAPER_PKG_DIR/metadata.json" << METAEOF
{
    "KPlugin": {
        "Authors": [{"Email": "info@cipheros.gt.tc", "Name": "CipherOS"}],
        "Id": "CipherOS-${name}",
        "License": "CC-BY-SA-4.0",
        "Name": "CipherOS — ${name}",
        "Version": "1.0"
    }
}
METAEOF
    done

    # Also write the main CipherOS wallpaper package metadata
    cat > "$WALLPAPER_DEST/../../../metadata.json" << METAEOF
{
    "KPlugin": {
        "Authors": [{"Email": "info@cipheros.gt.tc", "Name": "CipherOS"}],
        "Id": "CipherOS",
        "License": "CC-BY-SA-4.0",
        "Name": "CipherOS",
        "Version": "1.0"
    }
}
METAEOF

    # Store first wallpaper name for KDE default config
    echo "$FIRST_WALLPAPER" > /tmp/cipheros_default_wallpaper

    success "Wallpapers loaded ($(ls "$WALLPAPER_DEST" | wc -l) files)"
else
    warn "No wallpapers found in $ASSETS_DIR/wallpapers — generating placeholder..."
    convert -size 3840x2160 gradient:'#0A0A0F-#12121A' \
        -fill '#FF2D5530' -draw "circle 1920,1080 1920,200" \
        -fill '#FF2D55' -font DejaVu-Sans-Bold -pointsize 120 \
        -gravity center -annotate 0 'CIPHER OS' \
        "$WALLPAPER_DEST/cipheros-default.png" 2>>"$LOG_FILE" || \
        convert -size 3840x2160 xc:'#0A0A0F' \
        "$WALLPAPER_DEST/cipheros-default.png" 2>>"$LOG_FILE" || true
    echo "cipheros-default.png" > /tmp/cipheros_default_wallpaper
    warn "Using generated placeholder wallpaper"
fi

# ── Logo ──────────────────────────────────────────────────────────────────────
if [[ -f "$ASSETS_DIR/logo/cipheros-logo.png" ]]; then
    cp "$ASSETS_DIR/logo/cipheros-logo.png" "$LOGO_DEST_CAL/cipheros-logo.png"
    success "Logo loaded: cipheros-logo.png"
else
    warn "No logo found at $ASSETS_DIR/logo/cipheros-logo.png — generating placeholder..."
    convert -size 256x256 xc:'#0A0A0F' \
        -fill '#FF2D55' -font DejaVu-Sans-Bold -pointsize 32 \
        -gravity center -annotate 0 "CIPHER\nOS" \
        "$LOGO_DEST_CAL/cipheros-logo.png" 2>>"$LOG_FILE" || \
        convert -size 256x256 xc:'#0A0A0F' \
        "$LOGO_DEST_CAL/cipheros-logo.png" 2>>"$LOG_FILE" || true
fi

if [[ -f "$ASSETS_DIR/logo/cipheros-welcome.png" ]]; then
    cp "$ASSETS_DIR/logo/cipheros-welcome.png" "$LOGO_DEST_CAL/cipheros-welcome.png"
    success "Welcome image loaded: cipheros-welcome.png"
else
    warn "No welcome image found — generating placeholder..."
    convert -size 800x450 gradient:'#0A0A0F-#12121A' \
        -fill '#FF2D55' -font DejaVu-Sans-Bold -pointsize 48 \
        -gravity center -annotate 0 "CIPHER OS\n1.0 (Phantom)" \
        "$LOGO_DEST_CAL/cipheros-welcome.png" 2>>"$LOG_FILE" || \
        convert -size 800x450 xc:'#0A0A0F' \
        "$LOGO_DEST_CAL/cipheros-welcome.png" 2>>"$LOG_FILE" || true
fi
header "📋 PHASE 4 — Package Lists"

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
calamares-settings-ubuntu
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
zram-config
python3
python3-pip
EOF

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
hashcat-utils
burpsuite
tor
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

cat > config/package-lists/gaming.list.chroot << 'EOF'
steam-installer
lutris
wine
winetricks
gamemode
libgamemode0
libgamemodeauto0
mangohud
vulkan-tools
libvulkan1
mesa-vulkan-drivers
EOF

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
mkdir -p "$SDDM_DIR"

# SDDM theme metadata
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

# SDDM QML theme — full cyberpunk login screen
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

    // Animated grid background
    Canvas {
        id: gridCanvas
        anchors.fill: parent
        opacity: 0.08

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.strokeStyle = "#39FF14"
            ctx.lineWidth = 0.5

            // Vertical lines
            for (var x = 0; x < width; x += 60) {
                ctx.beginPath()
                ctx.moveTo(x, 0)
                ctx.lineTo(x, height)
                ctx.stroke()
            }
            // Horizontal lines
            for (var y = 0; y < height; y += 60) {
                ctx.beginPath()
                ctx.moveTo(0, y)
                ctx.lineTo(width, y)
                ctx.stroke()
            }
        }
    }

    // Ambient glow behind logo
    Rectangle {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -120
        width: 500; height: 500
        radius: 250
        color: "#FF2D55"
        opacity: 0.04
    }

    // Center login panel
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 0

        // ASCII-style logo text
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "⬛ CIPHER OS ⬛"
            color: "#FF2D55"
            font.pixelSize: 48
            font.bold: true
            font.family: "monospace"
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 8
            text: "\"Built for the ones who know.\""
            color: "#39FF14"
            font.pixelSize: 16
            font.family: "monospace"
            opacity: 0.8
        }

        // Divider
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 32
            Layout.bottomMargin: 32
            width: 400; height: 1
            color: "#FF2D55"
            opacity: 0.5
        }

        // Login form
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            width: 400
            height: 260
            color: "#12121A"
            border.color: "#FF2D5560"
            border.width: 1
            radius: 4

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 16
                width: 340

                // Username
                Text {
                    color: "#FF79C6"
                    text: "OPERATOR"
                    font.pixelSize: 11
                    font.family: "monospace"
                    font.bold: true
                    letterSpacing: 3
                }

                TextField {
                    id: userField
                    Layout.fillWidth: true
                    text: userModel.lastUser
                    placeholderText: "username"
                    height: 44
                    font.family: "monospace"
                    font.pixelSize: 14
                    color: "#39FF14"
                    placeholderTextColor: "#39FF1460"
                    background: Rectangle {
                        color: "#0A0A0F"
                        border.color: userField.activeFocus ? "#FF2D55" : "#39FF1440"
                        border.width: 1
                        radius: 2
                    }
                    leftPadding: 12
                    KeyNavigation.tab: passField
                }

                Text {
                    color: "#FF79C6"
                    text: "PASSPHRASE"
                    font.pixelSize: 11
                    font.family: "monospace"
                    font.bold: true
                    letterSpacing: 3
                }

                TextField {
                    id: passField
                    Layout.fillWidth: true
                    placeholderText: "••••••••"
                    echoMode: TextInput.Password
                    height: 44
                    font.family: "monospace"
                    font.pixelSize: 14
                    color: "#39FF14"
                    placeholderTextColor: "#39FF1460"
                    background: Rectangle {
                        color: "#0A0A0F"
                        border.color: passField.activeFocus ? "#FF2D55" : "#39FF1440"
                        border.width: 1
                        radius: 2
                    }
                    leftPadding: 12
                    Keys.onReturnPressed: doLogin()
                }
            }
        }

        // Login button
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 16
            width: 400; height: 48
            color: loginBtn.pressed ? "#FF2D5580" : "#FF2D5520"
            border.color: "#FF2D55"
            border.width: 1
            radius: 2

            Text {
                anchors.centerIn: parent
                text: "[ AUTHENTICATE ]"
                color: "#FF2D55"
                font.pixelSize: 14
                font.bold: true
                font.family: "monospace"
                letterSpacing: 4
            }

            MouseArea {
                id: loginBtn
                anchors.fill: parent
                onClicked: doLogin()
            }
        }

        // Error message
        Text {
            id: errorMsg
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 12
            color: "#FF2D55"
            font.pixelSize: 12
            font.family: "monospace"
            visible: false
        }

        // Clock
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 32
            text: Qt.formatDateTime(new Date(), "ddd dd MMM yyyy  |  hh:mm:ss")
            color: "#39FF1480"
            font.pixelSize: 13
            font.family: "monospace"

            Timer {
                interval: 1000; running: true; repeat: true
                onTriggered: parent.text = Qt.formatDateTime(new Date(), "ddd dd MMM yyyy  |  hh:mm:ss")
            }
        }
    }

    // Session + power buttons bottom right
    RowLayout {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 32
        spacing: 16

        ComboBox {
            id: sessionCombo
            model: sessionModel
            textRole: "name"
            implicitWidth: 160; implicitHeight: 36
            font.family: "monospace"
            font.pixelSize: 12
            contentItem: Text {
                leftPadding: 8
                text: sessionCombo.displayText
                color: "#39FF14"
                font: sessionCombo.font
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                color: "#12121A"
                border.color: "#39FF1440"
                border.width: 1
                radius: 2
            }
        }

        Rectangle {
            width: 80; height: 36
            color: "#12121A"
            border.color: "#FF2D5540"
            border.width: 1
            radius: 2
            Text { anchors.centerIn: parent; text: "⏻ OFF"; color: "#FF2D55"; font.family: "monospace"; font.pixelSize: 12 }
            MouseArea { anchors.fill: parent; onClicked: sddm.powerOff() }
        }

        Rectangle {
            width: 80; height: 36
            color: "#12121A"
            border.color: "#FF2D5540"
            border.width: 1
            radius: 2
            Text { anchors.centerIn: parent; text: "↺ RESTART"; color: "#FF79C6"; font.family: "monospace"; font.pixelSize: 11 }
            MouseArea { anchors.fill: parent; onClicked: sddm.reboot() }
        }
    }

    function doLogin() {
        if (userField.text === "") {
            errorMsg.text = "[ ERROR: OPERATOR ID REQUIRED ]"
            errorMsg.visible = true
            return
        }
        errorMsg.visible = false
        sddm.login(userField.text, passField.text, sessionCombo.currentIndex)
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            errorMsg.text = "[ ACCESS DENIED — INVALID CREDENTIALS ]"
            errorMsg.visible = true
            passField.text = ""
            passField.forceActiveFocus()
        }
    }

    Component.onCompleted: {
        if (userField.text === "") userField.forceActiveFocus()
        else passField.forceActiveFocus()
    }
}
QMLEOF

# SDDM global config
cat > config/includes.chroot/etc/sddm.conf << 'EOF'
[Theme]
Current=cipheros
CursorTheme=breeze_cursors

[Autologin]
Relogin=false

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
Numlock=on
EOF

success "SDDM cyberpunk theme created"

# ── PHASE 7: KDE PLASMA HOME SCREEN ──────────────────────────────────────────
header "🖥️  PHASE 7 — KDE Plasma Home Screen Configuration"

LOOKANDFEEL="config/includes.chroot/usr/share/plasma/look-and-feel/CipherOS"
mkdir -p "$LOOKANDFEEL/contents/"{defaults,layouts,lockscreen,logout,plasmoidsetupscripts,splash/images}

# Look-and-feel metadata
cat > "$LOOKANDFEEL/metadata.json" << 'EOF'
{
    "KPlugin": {
        "Authors": [{"Email": "info@cipheros.gt.tc", "Name": "CipherOS Team"}],
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

# Plasma defaults — sets wallpaper, color scheme, cursor, icons
cat > "$LOOKANDFEEL/contents/defaults" << 'EOF'
[kdeglobals][General]
ColorScheme=CipherOS

[kdeglobals][Icons]
Theme=breeze-dark

[kdeglobals][KDE]
LookAndFeelPackage=CipherOS
widgetStyle=Breeze

[plasmarc][Theme]
name=default

[Wallpaper]
Image=CipherOS
Plugin=org.kde.image

[kcminputrc][Mouse]
cursorTheme=breeze_cursors

[kwinrc][WindowSwitcher]
LayoutName=thumbnail_grid

[kwinrc][Effect-overview]
BorderActivate=7
EOF

# KDE Plasma panel + desktop layout (applied via kwriteconfig in hook)
cat > "$LOOKANDFEEL/contents/layouts/org.kde.plasma.desktop-layout.js" << 'EOF'
var plasma = getApiVersion(1);

var layout = {
    desktops: [{
        applets: [],
        wallpaperPlugin: "org.kde.image",
        wallpaperPluginConfig: {
            Image: "file:///usr/share/wallpapers/CipherOS/contents/images/3840x2160.png",
            FillMode: 2
        }
    }],
    panels: [{
        location: "bottom",
        height: 48,
        hiding: "none",
        maximumLength: -1,
        minimumLength: -1,
        offset: 0,
        applets: [
            { plugin: "org.kde.plasma.kickoff", config: { useCustomButtonImage: false } },
            { plugin: "org.kde.plasma.taskmanager", config: { groupingStrategy: 1, maxStripes: 1 } },
            { plugin: "org.kde.plasma.systemtray" },
            { plugin: "org.kde.plasma.digitalclock", config: { dateFormat: "custom", customDateFormat: "ddd d MMM", use24hFormat: 2 } }
        ]
    }]
};
EOF

# KDE splash screen (shown during login)
cat > "$LOOKANDFEEL/contents/splash/Splash.qml" << 'SPLASHEOF'
import QtQuick 2.15

Rectangle {
    id: root
    color: "#0A0A0F"

    property int stage: 0

    onStageChanged: {
        if (stage == 1) animLogo.start()
    }

    SequentialAnimation {
        id: animLogo
        NumberAnimation { target: logoText; property: "opacity"; from: 0; to: 1; duration: 800 }
        NumberAnimation { target: tagline; property: "opacity"; from: 0; to: 1; duration: 600 }
    }

    Text {
        id: logoText
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -30
        text: "CIPHER OS"
        color: "#FF2D55"
        font.pixelSize: 72
        font.bold: true
        font.family: "monospace"
        opacity: 0
    }

    Text {
        id: tagline
        anchors.top: logoText.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 16
        text: "\"Built for the ones who know.\""
        color: "#39FF14"
        font.pixelSize: 18
        font.family: "monospace"
        opacity: 0
    }

    // Progress bar
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 80
        width: 400; height: 2
        color: "#12121A"

        Rectangle {
            width: parent.width * (root.stage / 6)
            height: parent.height
            color: "#FF2D55"
            Behavior on width { NumberAnimation { duration: 250 } }
        }
    }
}
SPLASHEOF

success "KDE Plasma look-and-feel package created"

# KDE color scheme
cat > config/includes.chroot/usr/share/color-schemes/CipherOS.colors << 'EOF'
[ColorEffects:Disabled]
Color=56,56,56
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=112,111,110
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundAlternate=18,18,26
BackgroundNormal=18,18,26
DecorationFocus=255,45,85
DecorationHover=57,255,20
ForegroundActive=255,121,198
ForegroundInactive=150,150,160
ForegroundLink=57,255,20
ForegroundNegative=255,45,85
ForegroundNormal=230,230,240
ForegroundPositive=57,255,20

[Colors:Selection]
BackgroundAlternate=255,45,85
BackgroundNormal=255,45,85
ForegroundNormal=255,255,255
ForegroundActive=255,255,255

[Colors:Tooltip]
BackgroundNormal=18,18,26
ForegroundNormal=220,220,235
DecorationFocus=255,45,85

[Colors:View]
BackgroundAlternate=12,12,20
BackgroundNormal=10,10,15
DecorationFocus=255,45,85
DecorationHover=57,255,20
ForegroundActive=255,121,198
ForegroundInactive=130,130,140
ForegroundLink=57,255,20
ForegroundNegative=255,45,85
ForegroundNormal=220,220,235
ForegroundPositive=57,255,20

[Colors:Window]
BackgroundAlternate=18,18,26
BackgroundNormal=10,10,15
DecorationFocus=255,45,85
DecorationHover=57,255,20
ForegroundActive=255,121,198
ForegroundInactive=120,120,135
ForegroundLink=57,255,20
ForegroundNegative=255,45,85
ForegroundNormal=220,220,235
ForegroundPositive=57,255,20

[General]
ColorScheme=CipherOS
Name=CipherOS
shadeSortColumn=true

[KDE]
contrast=4
EOF

success "KDE color scheme written"

# ── PHASE 8: CALAMARES INSTALLER ─────────────────────────────────────────────
header "🧩 PHASE 8 — Calamares Installer Branding"

CAL_DIR="config/includes.chroot/etc/calamares"
mkdir -p "$CAL_DIR/branding/cipheros"
mkdir -p "$CAL_DIR/modules"

# Main Calamares config
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
    - luksbootkeyfile
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
oem-setup: false
disable-cancel: false
disable-cancel-during-exec: false
EOF

# Calamares branding config
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

# Calamares slideshow QML — shown during installation
cat > "$CAL_DIR/branding/cipheros/show.qml" << 'SHOWEOF'
import QtQuick 2.15
import QtQuick.Controls 2.15
import Calamares.Slideshow 1.0

Presentation {
    id: presentation
    timer.interval: 5000

    // ── Slide 1: Welcome ────────────────────────────────────────────────────
    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0A0F"

            Column {
                anchors.centerIn: parent
                spacing: 24

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "CIPHER OS"
                    color: "#FF2D55"
                    font.pixelSize: 64
                    font.bold: true
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Installing your weapon of choice..."
                    color: "#39FF14"
                    font.pixelSize: 20
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "\"Built for the ones who know.\""
                    color: "#FF79C6"
                    font.pixelSize: 15
                    font.family: "monospace"
                    opacity: 0.8
                }
            }
        }
    }

    // ── Slide 2: Security ───────────────────────────────────────────────────
    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0A0F"

            Column {
                anchors.centerIn: parent
                spacing: 20

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "🔐 SECURITY TOOLKIT"
                    color: "#FF2D55"
                    font.pixelSize: 36
                    font.bold: true
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "nmap  •  metasploit  •  wireshark  •  hashcat"
                    color: "#39FF14"
                    font.pixelSize: 18
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "aircrack-ng  •  sqlmap  •  hydra  •  burpsuite"
                    color: "#39FF14"
                    font.pixelSize: 18
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "A complete ethical hacking toolkit — ready on first boot."
                    color: "#DCDCEB"
                    font.pixelSize: 14
                    font.family: "monospace"
                    opacity: 0.7
                }
            }
        }
    }

    // ── Slide 3: Gaming ─────────────────────────────────────────────────────
    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0A0F"

            Column {
                anchors.centerIn: parent
                spacing: 20

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "🎮 GAMING READY"
                    color: "#FF2D55"
                    font.pixelSize: 36
                    font.bold: true
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Steam  •  Lutris  •  Heroic  •  Wine + Proton"
                    color: "#39FF14"
                    font.pixelSize: 18
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "XanMod kernel  •  GameMode  •  MangoHUD  •  Vulkan"
                    color: "#39FF14"
                    font.pixelSize: 18
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Maximum performance. Zero compromise."
                    color: "#DCDCEB"
                    font.pixelSize: 14
                    font.family: "monospace"
                    opacity: 0.7
                }
            }
        }
    }

    // ── Slide 4: Privacy ────────────────────────────────────────────────────
    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0A0F"

            Column {
                anchors.centerIn: parent
                spacing: 20

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "🛡️  PRIVACY FIRST"
                    color: "#FF2D55"
                    font.pixelSize: 36
                    font.bold: true
                    font.family: "monospace"
                }

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    Repeater {
                        model: [
                            "✓  Ubuntu telemetry removed",
                            "✓  DNS over HTTPS via dnscrypt-proxy",
                            "✓  MAC address randomization enabled",
                            "✓  UFW firewall — deny incoming by default",
                            "✓  App isolation via Firejail + AppArmor"
                        ]
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData
                            color: "#39FF14"
                            font.pixelSize: 16
                            font.family: "monospace"
                        }
                    }
                }
            }
        }
    }

    // ── Slide 5: Almost done ────────────────────────────────────────────────
    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0A0F"

            Column {
                anchors.centerIn: parent
                spacing: 24

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "⚡ ALMOST THERE"
                    color: "#FF2D55"
                    font.pixelSize: 36
                    font.bold: true
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Finalizing your CipherOS installation..."
                    color: "#39FF14"
                    font.pixelSize: 18
                    font.family: "monospace"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "cipheros.gt.tc"
                    color: "#FF79C6"
                    font.pixelSize: 14
                    font.family: "monospace"
                    opacity: 0.7
                }
            }
        }
    }
}
SHOWEOF

# Calamares welcome module
cat > "$CAL_DIR/modules/welcome.conf" << 'EOF'
---
showSupportUrl:        true
showKnownIssuesUrl:    false
showReleaseNotesUrl:   false
showDonateUrl:         false

requirements:
    check:
        - storage
        - ram
        - power
        - internet
    required:
        - storage
        - ram

geoip:
    style: "none"
EOF

# Calamares partition module
cat > "$CAL_DIR/modules/partition.conf" << 'EOF'
---
efiSystemPartition:     "/boot/efi"
efiSystemPartitionSize: 300M
efiSystemPartitionName: EFI

userSwapChoices:
    - none
    - small
    - suspend
    - file

drawNestedPartitions:   false
alwaysShowPartitionLabels: true
initialPartitioningChoice: erase
initialSwapChoice: file
defaultFileSystemType:  "ext4"
availableFileSystemTypes: ["ext4","btrfs","xfs"]
EOF

# Calamares users module
cat > "$CAL_DIR/modules/users.conf" << 'EOF'
---
defaultGroups:
    - name: users
      state: must-be-group
    - name: lp
      state: must-be-group
    - name: video
      state: must-be-group
    - name: network
      state: must-be-group
    - name: storage
      state: must-be-group
    - name: wheel
      state: must-be-group
    - name: wireshark
      state: must-be-group
    - name: netdev
      state: must-be-group

autologinGroup:  autologin
sudoersGroup:    sudo

setRootPassword: true
doAutoLogin:     false

passwordRequirements:
    minLength:   8
    maxLength:  -1

userShell: /usr/bin/zsh
EOF

# Placeholder logo images (ImageMagick generated)
convert -size 256x256 xc:"#0A0A0F" \
    -fill "#FF2D55" -font DejaVu-Sans-Bold -pointsize 32 \
    -gravity center -annotate 0 "CIPHER\nOS" \
    "$CAL_DIR/branding/cipheros/cipheros-logo.png" 2>>"$LOG_FILE" || \
    convert -size 256x256 xc:"#0A0A0F" "$CAL_DIR/branding/cipheros/cipheros-logo.png" 2>>"$LOG_FILE" || \
    warn "Logo generation failed — placeholder used"

convert -size 800x450 \
    gradient:"#0A0A0F-#12121A" \
    -fill "#FF2D55" -font DejaVu-Sans-Bold -pointsize 48 \
    -gravity center -annotate 0 "CIPHER OS\n1.0 (Phantom)" \
    "$CAL_DIR/branding/cipheros/cipheros-welcome.png" 2>>"$LOG_FILE" || \
    convert -size 800x450 xc:"#0A0A0F" "$CAL_DIR/branding/cipheros/cipheros-welcome.png" 2>>"$LOG_FILE" || \
    warn "Welcome image generation failed"

success "Calamares installer fully configured"

# ── PHASE 9: PLYMOUTH ANIMATED BOOT SPLASH ───────────────────────────────────
header "🌊 PHASE 9 — Plymouth Animated Boot Splash"

PLYMOUTH_DIR="config/includes.chroot/usr/share/plymouth/themes/cipheros"
mkdir -p "$PLYMOUTH_DIR"

# Plymouth theme descriptor
cat > "$PLYMOUTH_DIR/cipheros.plymouth" << 'EOF'
[Plymouth Theme]
Name=CipherOS
Description=CipherOS animated cyberpunk boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/cipheros
ScriptFile=/usr/share/plymouth/themes/cipheros/cipheros.script
EOF

# Plymouth script — matrix rain + CipherOS logo + animated progress bar
cat > "$PLYMOUTH_DIR/cipheros.script" << 'PLYMOUTHEOF'
# ── CipherOS Plymouth Script ─────────────────────────────────────────────────
# Cyberpunk boot animation: falling green chars + neon progress bar

# ── Background ───────────────────────────────────────────────────────────────
Window.SetBackgroundTopColor(0.04, 0.04, 0.06);
Window.SetBackgroundBottomColor(0.02, 0.02, 0.04);

screen_width  = Window.GetWidth();
screen_height = Window.GetHeight();

# ── Matrix rain columns ───────────────────────────────────────────────────────
COLS        = 40;
col_x       = [];
col_y       = [];
col_speed   = [];
col_chars   = ["0","1","█","▓","░","▄","▀","┼","╬","╔","╗","╚","╝","║","═","X","Z","A","9","7","3"];
col_sprites = [];
col_alpha   = [];

fun init_matrix() {
    for (i = 0; i < COLS; i++) {
        col_x[i]     = Math.Int(Math.Random() * screen_width);
        col_y[i]     = Math.Int(Math.Random() * screen_height);
        col_speed[i] = 4 + Math.Int(Math.Random() * 8);
        col_alpha[i] = 0.05 + Math.Random() * 0.25;

        img             = Image(16, 20);
        op              = img.GetRootOperator();
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
            col_y[i]     = -20;
            col_x[i]     = Math.Int(Math.Random() * screen_width);
            col_speed[i] = 4 + Math.Int(Math.Random() * 8);
        }
        col_sprites[i].SetX(col_x[i]);
        col_sprites[i].SetY(col_y[i]);
    }
}

# ── Logo text ─────────────────────────────────────────────────────────────────
fun draw_logo() {
    logo_img = Image(500, 60);
    op       = logo_img.GetRootOperator();

    op.SetForegroundColor(1.0, 0.18, 0.33, 1.0);   # #FF2D55
    op.SetFont("Monospace Bold 28");
    op.DrawText(0, 0, "C I P H E R  O S");

    op.SetForegroundColor(0.22, 1.0, 0.08, 0.9);   # #39FF14
    op.SetFont("Monospace 12");
    op.DrawText(60, 38, "\"Built for the ones who know.\"");

    logo_sprite = Sprite();
    logo_sprite.SetImage(logo_img);
    logo_sprite.SetX(screen_width  / 2 - 250);
    logo_sprite.SetY(screen_height / 2 - 80);
    logo_sprite.SetZ(10);
    return logo_sprite;
}

# ── Progress bar ──────────────────────────────────────────────────────────────
BAR_WIDTH  = 400;
BAR_HEIGHT = 3;
BAR_X      = screen_width  / 2 - BAR_WIDTH / 2;
BAR_Y      = screen_height / 2 + 60;

# Background track
bar_bg_img = Image(BAR_WIDTH, BAR_HEIGHT);
bar_bg_op  = bar_bg_img.GetRootOperator();
bar_bg_op.SetForegroundColor(0.07, 0.07, 0.10, 1.0);
bar_bg_op.FillRectangle(0, 0, BAR_WIDTH, BAR_HEIGHT);
bar_bg_sprite = Sprite();
bar_bg_sprite.SetImage(bar_bg_img);
bar_bg_sprite.SetX(BAR_X);
bar_bg_sprite.SetY(BAR_Y);
bar_bg_sprite.SetZ(9);

# Active fill
bar_fill_sprite = Sprite();
bar_fill_sprite.SetZ(10);
bar_fill_sprite.SetX(BAR_X);
bar_fill_sprite.SetY(BAR_Y);

# Glow dot at leading edge
glow_sprite = Sprite();
glow_sprite.SetZ(11);
glow_sprite.SetY(BAR_Y - 3);

current_progress = 0;

fun update_progress(duration, progress) {
    current_progress = progress;

    fill_w = Math.Int(BAR_WIDTH * progress);
    if (fill_w < 1) fill_w = 1;

    fill_img = Image(fill_w, BAR_HEIGHT);
    fill_op  = fill_img.GetRootOperator();
    fill_op.SetForegroundColor(1.0, 0.18, 0.33, 1.0);  # #FF2D55
    fill_op.FillRectangle(0, 0, fill_w, BAR_HEIGHT);
    bar_fill_sprite.SetImage(fill_img);

    # Glow dot
    glow_img = Image(8, 8);
    glow_op  = glow_img.GetRootOperator();
    glow_op.SetForegroundColor(1.0, 0.47, 0.78, 0.9);  # #FF79C6
    glow_op.FillRectangle(0, 0, 8, 8);
    glow_sprite.SetImage(glow_img);
    glow_sprite.SetX(BAR_X + fill_w - 4);
}

# ── Status text ───────────────────────────────────────────────────────────────
status_img    = Image(400, 20);
status_sprite = Sprite();
status_sprite.SetZ(10);
status_sprite.SetX(BAR_X);
status_sprite.SetY(BAR_Y + 12);

fun update_status(text) {
    status_img = Image(400, 20);
    op = status_img.GetRootOperator();
    op.SetForegroundColor(0.22, 1.0, 0.08, 0.6);
    op.SetFont("Monospace 9");
    op.DrawText(0, 0, text);
    status_sprite.SetImage(status_img);
}

# ── Tick / animation loop ─────────────────────────────────────────────────────
tick = 0;
logo_sprite = draw_logo();
init_matrix();

fun refresh_callback() {
    tick++;
    if (Math.Int(tick % 2) == 0) update_matrix();
}

fun boot_progress_callback(duration, progress) {
    update_progress(duration, progress);
}

fun status_callback(text) {
    update_status(text);
}

Plymouth.SetRefreshFunction(refresh_callback);
Plymouth.SetBootProgressFunction(boot_progress_callback);
Plymouth.SetUpdateStatusFunction(status_callback);

# ── Password prompt (for LUKS) ────────────────────────────────────────────────
fun password_callback(prompt) {
    update_status("[ " + prompt + " ]");
}
Plymouth.SetDisplayPasswordFunction(password_callback);
PLYMOUTHEOF

success "Plymouth animated boot splash written"

# ── PHASE 10: POWERLEVEL10K TERMINAL PROMPT ───────────────────────────────────
header "⚡ PHASE 10 — Powerlevel10k Terminal Prompt"

mkdir -p config/includes.chroot/usr/share/cipheros
mkdir -p config/includes.chroot/etc/skel

# p10k config — full CipherOS cyberpunk prompt
# Left side:  OS icon > dir > git
# Right side: time | exit code | background jobs | ram
cat > config/includes.chroot/etc/skel/.p10k.zsh << 'P10KEOF'
# CipherOS Powerlevel10k configuration
# Generated for CipherOS 1.0 (Phantom)

'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob

  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  autoload -Uz is-at-least && is-at-least 5.1 || return

  # ── Prompt elements ────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    os_icon           # CipherOS icon
    dir               # current directory
    vcs               # git status
    newline
    prompt_char       # ❯ prompt character
  )

  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status            # exit code
    command_execution_time
    background_jobs
    ram
    time
    newline
  )

  # ── Basic config ───────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_ICON_PADDING=moderate
  typeset -g POWERLEVEL9K_BACKGROUND=                        # transparent bg
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_{LEFT,RIGHT}_WHITESPACE=
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SUBSEGMENT_SEPARATOR=' '
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SEGMENT_SEPARATOR=
  typeset -g POWERLEVEL9K_VISUAL_IDENTIFIER_EXPANSION='${P9K_VISUAL_IDENTIFIER}'
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose

  # ── OS icon — neon red ─────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_OS_ICON_FOREGROUND=196           # bright red
  typeset -g POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION='⬡'   # cipher hex icon

  # ── Directory ─────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=51                # cyan
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_SHORTEN_DELIMITER=
  typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=103
  typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=51
  typeset -g POWERLEVEL9K_DIR_ANCHOR_BOLD=true
  local anchor_files=(
    .git .node-version .python-version .ruby-version
    .tool-versions .shrc .zshrc Makefile package.json
  )
  typeset -g POWERLEVEL9K_SHORTEN_FOLDER_MARKER="(${(j:|:)anchor_files})"
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS=40
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS_PCT=50
  typeset -g POWERLEVEL9K_DIR_HYPERLINK=false

  # ── VCS (git) — neon green ────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_VCS_BRANCH_ICON='\uF126 '
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_ICON='?'
  function my_git_formatter() {
    emulate -L zsh
    if [[ -n $P9K_CONTENT ]]; then
      typeset -g my_git_format=$P9K_CONTENT
      return
    fi
    local       meta='%f'
    local      clean='%46F'   # matrix green
    local   modified='%178F'  # yellow
    local  untracked='%39F'   # cyan
    local conflicted='%196F'  # red

    local res
    local where
    if [[ -n $VCS_STATUS_LOCAL_BRANCH ]]; then
      res+="${clean}\uF126 "
      where=${(V)VCS_STATUS_LOCAL_BRANCH}
    elif [[ -n $VCS_STATUS_TAG ]]; then
      res+="${meta}#"
      where=${(V)VCS_STATUS_TAG}
    else
      res+="${meta}@"
      where=${VCS_STATUS_COMMIT[1,8]}
    fi

    (( $#where > 32 )) && where[13,-13]="…"
    res+="${clean}${where//\%/%%}"

    if (( VCS_STATUS_COMMITS_BEHIND > 0 )); then
      res+=" ${clean}⇣${VCS_STATUS_COMMITS_BEHIND}"
    fi
    if (( VCS_STATUS_COMMITS_AHEAD  > 0 )); then
      res+=" ${clean}⇡${VCS_STATUS_COMMITS_AHEAD}"
    fi
    if (( VCS_STATUS_PUSH_COMMITS_BEHIND > 0 )); then
      res+=" ${clean}⇠${VCS_STATUS_PUSH_COMMITS_BEHIND}"
    fi
    if (( VCS_STATUS_PUSH_COMMITS_AHEAD  > 0 )); then
      res+=" ${clean}⇢${VCS_STATUS_PUSH_COMMITS_AHEAD}"
    fi
    if (( VCS_STATUS_NUM_CONFLICTED    > 0 )); then res+=" ${conflicted}~${VCS_STATUS_NUM_CONFLICTED}"; fi
    if (( VCS_STATUS_NUM_STAGED        > 0 )); then res+=" ${modified}+${VCS_STATUS_NUM_STAGED}";       fi
    if (( VCS_STATUS_NUM_UNSTAGED      > 0 )); then res+=" ${modified}!${VCS_STATUS_NUM_UNSTAGED}";     fi
    if (( VCS_STATUS_NUM_UNTRACKED     > 0 )); then res+=" ${untracked}?${VCS_STATUS_NUM_UNTRACKED}";   fi

    typeset -g my_git_format=$res
  }
  functions -M my_git_formatter 2>/dev/null
  typeset -g POWERLEVEL9K_VCS_MAX_INDEX_SIZE_DIRTY=-1
  typeset -g POWERLEVEL9K_VCS_DISABLED_WORKDIR_PATTERN='~'
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true
  typeset -g POWERLEVEL9K_VCS_CONTENT_EXPANSION='${$((my_git_formatter(1)))+${my_git_format}}'
  typeset -g POWERLEVEL9K_VCS_{STAGED,UNSTAGED,UNTRACKED,CONFLICTED,COMMITS_AHEAD,COMMITS_BEHIND}_MAX_NUM=-1
  typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=76
  typeset -g POWERLEVEL9K_VCS_LOADING_TEXT=

  # ── Prompt character ──────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=46   # green ❯
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196 # red ❯
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='❮'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIVIS_CONTENT_EXPANSION='V'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIOWR_CONTENT_EXPANSION='▶'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_LEFT_PROMPT_LAST_SEGMENT_END_SYMBOL=
  typeset -g POWERLEVEL9K_PROMPT_CHAR_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL=
  typeset -g POWERLEVEL9K_PROMPT_CHAR_LEFT_LEFT_WHITESPACE=
  typeset -g POWERLEVEL9K_PROMPT_CHAR_LEFT_RIGHT_WHITESPACE=' '
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OVERWRITE_STATE=true
  typeset -g POWERLEVEL9K_PROMPT_CHAR_VISUAL_IDENTIFIER_EXPANSION=
  typeset -g POWERLEVEL9K_PROMPT_CHAR_IWS_DISPLAY=false

  # ── Exit status ───────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_STATUS_EXTENDED_STATES=true
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=70
  typeset -g POWERLEVEL9K_STATUS_OK_VISUAL_IDENTIFIER_EXPANSION='✔'
  typeset -g POWERLEVEL9K_STATUS_ERROR=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=196
  typeset -g POWERLEVEL9K_STATUS_ERROR_VISUAL_IDENTIFIER_EXPANSION='✘'
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=196
  typeset -g POWERLEVEL9K_STATUS_VERBOSE_SIGNAME=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=196

  # ── Command execution time ────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PRECISION=0
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=101
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FORMAT='d h m s'

  # ── RAM ───────────────────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_RAM_FOREGROUND=66

  # ── Time — matrix green ───────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=46
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M:%S}'
  typeset -g POWERLEVEL9K_TIME_UPDATE_ON_COMMAND=false

  # ── Background jobs ───────────────────────────────────────────────────────
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VERBOSE=false
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_FOREGROUND=178

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
} always {
  'builtin' 'unset' 'p10k_config_opts'
}
P10KEOF

success "Powerlevel10k config written"

# ── PHASE 11: KVANTUM WINDOW THEMING ──────────────────────────────────────────
header "🪟 PHASE 11 — Kvantum Window Theming (blur + glow borders)"

KVANTUM_DIR="config/includes.chroot/usr/share/Kvantum/CipherOS"
mkdir -p "$KVANTUM_DIR"

# Kvantum theme config — dark, blurred, neon borders
cat > "$KVANTUM_DIR/CipherOS.kvconfig" << 'EOF'
[%General]
author=CipherOS Team
comment=CipherOS cyberpunk dark theme with blur and neon accents
x11drag=all
alt_mnemonic=true
left_tabs=false
attach_active_tab=false
mirror_doc_tabs=true
group_toolbar_buttons=false
toolbar_item_spacing=0
toolbar_interior_spacing=2
spread_progressbar=true
composite=true
translucent_windows=true
blurring=true
popup_blurring=true
reduce_window_opacity=18
reduce_menu_opacity=10
menu_shadow_depth=7
tooltip_shadow_depth=4
scroll_width=8
scroll_arrows=false
scroll_min_extent=80
transient_scrollbar=true
center_toolbar_handle=false
slim_toolbars=false
merge_menubar_with_toolbar=false
menubar_mouse_tracking=true
toolbutton_style=0
double_click=false
selectionHighlight=true
shade_dockwidget_titles=false
click_behavior=0
autoRaise_toolbar_buttons=0
drag_from_buttons=false
middle_click_scroll=false
button_width_correction=0
vertical_spin_indicators=false
inline_spin_indicators=true
spin_button_width=16
combo_menu=false
combo_as_lineedit=false
combo_focus_rect=false
hide_combo_checkboxes=false
animate_states=true
no_inactiveness=false
no_window_pattern=false
window_dragging=true
respect_DE=true
kick_out_workarounds=false
small_icon_size=16
large_icon_size=32
button_icon_size=16
toolbar_icon_size=22
layout_spacing=2
layout_margin=4
submenu_overlap=0
splitter_width=7
check_size=13
tooltip_delay=-1
backgnd_opacity=100
dialog_backgnd_opacity=100
tooltip_opacity=90
contrast=1.0
intensity=1.0
saturation=1.0
shadowless_popup=false

[GeneralColors]
window.color=#0A0A0F
base.color=#12121A
alt.base.color=#0E0E18
button.color=#1A1A28
light.color=#252535
dark.color=#050508
mid.color=#111118
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
transparent_ktitle_label=true
transparent_dolphin_view=true
transparent_pcmanfm_sidepane=false
blur_konsole=true
transparent_titlebar=true
no_selection_tint=false
normal_default_pushbutton=false
single_top_toolbar=false
tint_on_mouseover=0
disabled_icon_opacity=60
lxqtmainmenu_iconsize=0
EOF

# Kvantum SVG theme — controls all widget shapes
# This is a minimal SVG defining the core widget style
cat > "$KVANTUM_DIR/CipherOS.svg" << 'SVGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
  <defs>
    <linearGradient id="btnGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#1E1E2E;stop-opacity:1"/>
      <stop offset="100%" style="stop-color:#12121A;stop-opacity:1"/>
    </linearGradient>
    <linearGradient id="highlightGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#FF2D55;stop-opacity:1"/>
      <stop offset="100%" style="stop-color:#CC1A3A;stop-opacity:1"/>
    </linearGradient>
    <filter id="neonGlow">
      <feGaussianBlur stdDeviation="2" result="coloredBlur"/>
      <feMerge>
        <feMergeNode in="coloredBlur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
  </defs>

  <!-- Button normal -->
  <g id="button-normal-rest">
    <rect x="1" y="1" width="198" height="198" rx="3" ry="3"
          fill="url(#btnGrad)" stroke="#FF2D5540" stroke-width="1"/>
  </g>

  <!-- Button focused/hover — neon border glow -->
  <g id="button-normal-focused">
    <rect x="1" y="1" width="198" height="198" rx="3" ry="3"
          fill="url(#btnGrad)" stroke="#FF2D55" stroke-width="1.5"
          filter="url(#neonGlow)"/>
  </g>

  <!-- Button pressed -->
  <g id="button-normal-pressed">
    <rect x="1" y="1" width="198" height="198" rx="3" ry="3"
          fill="#0A0A0F" stroke="#FF2D55" stroke-width="1.5"/>
  </g>

  <!-- Input field -->
  <g id="lineedit-normal-rest">
    <rect x="1" y="1" width="198" height="198" rx="2" ry="2"
          fill="#0A0A0F" stroke="#39FF1440" stroke-width="1"/>
  </g>

  <g id="lineedit-normal-focused">
    <rect x="1" y="1" width="198" height="198" rx="2" ry="2"
          fill="#0A0A0F" stroke="#FF2D55" stroke-width="1.5"
          filter="url(#neonGlow)"/>
  </g>

  <!-- Checkbox -->
  <g id="checkbox-normal-rest">
    <rect x="3" y="3" width="194" height="194" rx="2" ry="2"
          fill="#12121A" stroke="#39FF1440" stroke-width="1"/>
  </g>

  <g id="checkbox-normal-checked">
    <rect x="3" y="3" width="194" height="194" rx="2" ry="2"
          fill="#FF2D5520" stroke="#FF2D55" stroke-width="1.5"/>
    <path d="M 40,100 L 80,150 L 160,60"
          stroke="#FF2D55" stroke-width="16" fill="none"
          stroke-linecap="round" stroke-linejoin="round"/>
  </g>

  <!-- Progress bar -->
  <g id="progressbar-horizontal-rest">
    <rect x="1" y="1" width="198" height="198" rx="2" ry="2"
          fill="#12121A" stroke="none"/>
  </g>

  <g id="progressbar-horizontal-indicator">
    <rect x="1" y="1" width="198" height="198" rx="2" ry="2"
          fill="url(#highlightGrad)" filter="url(#neonGlow)"/>
  </g>

  <!-- Scrollbar handle -->
  <g id="scrollbar-slider-normal-rest">
    <rect x="3" y="3" width="194" height="194" rx="4" ry="4"
          fill="#FF2D5530" stroke="none"/>
  </g>

  <g id="scrollbar-slider-normal-focused">
    <rect x="3" y="3" width="194" height="194" rx="4" ry="4"
          fill="#FF2D5560" stroke="none"/>
  </g>

  <!-- Menu item highlight -->
  <g id="menuitem-rest">
    <rect x="1" y="1" width="198" height="198" rx="2" ry="2"
          fill="#FF2D5515" stroke="none"/>
  </g>

  <g id="menuitem-focused">
    <rect x="1" y="1" width="198" height="198" rx="2" ry="2"
          fill="#FF2D5530" stroke="#FF2D5550" stroke-width="1"/>
  </g>
</svg>
SVGEOF

# Default Kvantum theme for all users
mkdir -p config/includes.chroot/etc/skel/.config/Kvantum
cat > config/includes.chroot/etc/skel/.config/Kvantum/kvantum.kvconfig << 'EOF'
[General]
theme=CipherOS
EOF

# Tell KDE to use Kvantum as the widget style
cat >> config/includes.chroot/etc/skel/.config/kdeglobals << 'EOF'

[KDE]
widgetStyle=kvantum-dark
EOF

success "Kvantum theme with blur and neon glow written"

# ── PHASE 12: KONSOLE TERMINAL PROFILE ────────────────────────────────────────
header "🖥️  PHASE 12 — Custom Konsole Terminal Profile"

KONSOLE_DIR="config/includes.chroot/usr/share/konsole"
mkdir -p "$KONSOLE_DIR"
mkdir -p "config/includes.chroot/etc/skel/.local/share/konsole"

# Konsole color scheme — full cyberpunk palette
cat > "$KONSOLE_DIR/CipherOS.colorscheme" << 'EOF'
[Background]
Color=10,10,15

[BackgroundFaint]
Color=10,10,15

[BackgroundIntense]
Color=18,18,26

[Color0]
Color=10,10,15

[Color0Faint]
Color=18,18,26

[Color0Intense]
Color=30,30,45

[Color1]
Color=255,45,85

[Color1Faint]
Color=180,30,60

[Color1Intense]
Color=255,80,110

[Color2]
Color=57,255,20

[Color2Faint]
Color=30,180,10

[Color2Intense]
Color=100,255,60

[Color3]
Color=255,200,0

[Color3Faint]
Color=180,140,0

[Color3Intense]
Color=255,220,50

[Color4]
Color=0,180,255

[Color4Faint]
Color=0,120,180

[Color4Intense]
Color=50,210,255

[Color5]
Color=255,121,198

[Color5Faint]
Color=180,80,140

[Color5Intense]
Color=255,160,220

[Color6]
Color=0,230,230

[Color6Faint]
Color=0,160,160

[Color6Intense]
Color=50,255,255

[Color7]
Color=220,220,235

[Color7Faint]
Color=150,150,165

[Color7Intense]
Color=255,255,255

[Foreground]
Color=220,220,235

[ForegroundFaint]
Color=150,150,165

[ForegroundIntense]
Color=255,255,255

[General]
Anchor=0.5,0.5
Blur=true
BlurRadius=20
ColorRandomization=false
Description=CipherOS
FillStyle=Tile
Opacity=0.88
Wallpaper=
WallpaperFlipType=NoFlip
WallpaperOpacity=1
EOF

# Konsole profile — sets font, colors, scrollback, blur
cat > "$KONSOLE_DIR/CipherOS.profile" << 'EOF'
[Appearance]
ColorScheme=CipherOS
Font=FiraCode Nerd Font,12,-1,5,50,0,0,0,0,0
UseFontLineChararacters=false
LineSpacing=2

[Cursor Options]
CursorShape=1
UseCustomCursorColor=true
CustomCursorColor=255,45,85
CustomCursorTextColor=10,10,15

[General]
Name=CipherOS
Parent=FALLBACK/
TerminalCenter=false
TerminalColumns=120
TerminalRows=35

[Interaction Options]
AutoCopySelectedText=true
MiddleClickPasteMode=1
TrimLeadingSpacesInSelectedText=true
TrimTrailingSpacesInSelectedText=true
UnderlineFilesEnabled=true

[Scrolling]
HistoryMode=2
HistorySize=10000
ScrollBarPosition=2

[Terminal Features]
BlinkingCursorEnabled=true
FlowControlEnabled=false
UrlHintsModifiers=67108864
EOF

# Make CipherOS profile the default for all new users
cat > "config/includes.chroot/etc/skel/.local/share/konsole/CipherOS.profile" << 'EOF'
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

# Konsole global default — points to CipherOS profile
mkdir -p "config/includes.chroot/etc/skel/.config"
cat > "config/includes.chroot/etc/skel/.config/konsolerc" << 'EOF'
[Desktop Entry]
DefaultProfile=CipherOS.profile

[FileLocation]
dialogLastFolder[$e]=$HOME

[KonsoleWindow]
RememberWindowSize=true
ShowMenuBarByDefault=false
UseSingleInstance=false

[TabBar]
TabBarPosition=Top
TabBarVisibility=ShowTabBarWhenNeeded
EOF

# Add FiraCode Nerd Font to package list (needed for p10k icons + Konsole)
echo "fonts-firacode" >> config/package-lists/base.list.chroot

success "Konsole profile with CipherOS theme, blur, and neon cursor written"

# ── PHASE 13: MAIN CHROOT HOOK ────────────────────────────────────────────────
header "🪝 PHASE 13 — Chroot Hooks"

cat > config/hooks/live/0100-cipheros-setup.hook.chroot << 'HOOKEOF'
#!/bin/bash
set -euo pipefail
echo "🔐 CipherOS Main Hook — Starting..."

# 32-bit support
dpkg --add-architecture i386
apt-get update -qq

# XanMod Kernel
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

# ── Plymouth ──────────────────────────────────────────────────────────────────
echo "🌊 Installing Plymouth..."
apt-get install -y plymouth plymouth-themes 2>/dev/null || true

# Install CipherOS Plymouth theme (files already placed by includes.chroot)
if [[ -f /usr/share/plymouth/themes/cipheros/cipheros.plymouth ]]; then
    update-alternatives --install \
        /usr/share/plymouth/themes/default.plymouth \
        default.plymouth \
        /usr/share/plymouth/themes/cipheros/cipheros.plymouth 100
    update-alternatives --set default.plymouth \
        /usr/share/plymouth/themes/cipheros/cipheros.plymouth
fi

# Rebuild initramfs so Plymouth kicks in at boot
sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="splash"/' /etc/default/grub 2>/dev/null || true
update-initramfs -u 2>/dev/null || true

# ── Powerlevel10k ─────────────────────────────────────────────────────────────
echo "⚡ Installing Powerlevel10k + Nerd Fonts..."

# Install Nerd Fonts (FiraCode)
apt-get install -y fonts-firacode 2>/dev/null || true

# Install powerlevel10k via git (most reliable method)
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    /usr/share/powerlevel10k 2>/dev/null || true

# Install Oh-My-Zsh system-wide
if [[ ! -d /usr/share/oh-my-zsh ]]; then
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git \
        /usr/share/oh-my-zsh 2>/dev/null || true
fi

# Link p10k as a custom theme inside OMZ
mkdir -p /usr/share/oh-my-zsh/custom/themes
ln -sfn /usr/share/powerlevel10k \
    /usr/share/oh-my-zsh/custom/themes/powerlevel10k 2>/dev/null || true

# Install zsh plugins system-wide
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
    /usr/share/oh-my-zsh/custom/plugins/zsh-autosuggestions 2>/dev/null || true
git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
    /usr/share/oh-my-zsh/custom/plugins/zsh-syntax-highlighting 2>/dev/null || true

# ── Kvantum ───────────────────────────────────────────────────────────────────
echo "🪟 Installing Kvantum..."
apt-get install -y qt5-style-kvantum qt5-style-kvantum-themes \
    qt6-style-kvantum 2>/dev/null || true

# ── Brave Browser ─────────────────────────────────────────────────────────────
curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] \
    https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list
apt-get update -qq && apt-get install -y brave-browser

# Metasploit
echo "💀 Installing Metasploit..."
curl -fsSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfinstall | bash

# Heroic Games Launcher
HEROIC_VER=$(curl -s https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest \
    | grep tag_name | cut -d'"' -f4 | tr -d 'v')
wget -q "https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/download/v${HEROIC_VER}/heroic_${HEROIC_VER}_amd64.deb" \
    -O /tmp/heroic.deb
dpkg -i /tmp/heroic.deb || apt-get install -f -y
rm -f /tmp/heroic.deb

# Flatpak
apt-get install -y flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

# Proxychains
cat > /etc/proxychains4.conf << 'EOF'
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 127.0.0.1 9050
EOF

# Firewall
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
systemctl enable ufw

# AppArmor
systemctl enable apparmor
firecfg --fix 2>/dev/null || true

# Sysctl tweaks
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

# MAC randomization
mkdir -p /etc/NetworkManager/conf.d/
cat > /etc/NetworkManager/conf.d/99-mac-randomize.conf << 'EOF'
[device]
wifi.scan-rand-mac-address=yes
[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF

# Remove Ubuntu telemetry
apt-get purge -y ubuntu-report apport apport-gtk whoopsie \
    popularity-contest ubuntu-advantage-tools 2>/dev/null || true

# dnscrypt-proxy
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

# OS Branding
cat > /etc/os-release << 'EOF'
NAME="CipherOS"
VERSION="1.0 (Phantom)"
ID=cipheros
ID_LIKE=ubuntu
PRETTY_NAME="CipherOS 1.0 (Phantom)"
VERSION_ID="1.0"
HOME_URL="https://cipheros.gt.tc"
SUPPORT_URL="https://github.com/ricowolmarans/CipherOS/issues"
VERSION_CODENAME=phantom
UBUNTU_CODENAME=noble
EOF

cat > /etc/lsb-release << 'EOF'
DISTRIB_ID=CipherOS
DISTRIB_RELEASE=1.0
DISTRIB_CODENAME=phantom
DISTRIB_DESCRIPTION="CipherOS 1.0 (Phantom)"
EOF

# Apply KDE Look-and-Feel for all new users via kwriteconfig
mkdir -p /etc/skel/.config

cat > /etc/skel/.config/kdeglobals << 'EOF'
[General]
ColorScheme=CipherOS
Name=CipherOS

[Icons]
Theme=breeze-dark

[KDE]
LookAndFeelPackage=CipherOS
SingleClick=false
widgetStyle=Breeze
EOF

cat > /etc/skel/.config/kwinrc << 'EOF'
[Desktops]
Number=1
Rows=1

[Effect-overview]
BorderActivate=7

[Windows]
BorderlessMaximizedWindows=false
EOF

cat > /etc/skel/.config/plasmarc << 'EOF'
[Theme]
name=default
EOF

cat > /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc << 'EOF'
[Containments][1]
activityId=
formfactor=0
immutability=1
lastScreen=0
location=0
plugin=org.kde.plasma.folder
wallpaperplugin=org.kde.image

[Containments][1][Wallpaper][org.kde.image][General]
Image=file:///usr/share/wallpapers/CipherOS/contents/images/3840x2160.png
FillMode=2

[Containments][2]
activityId=
formfactor=2
immutability=1
lastScreen=0
location=4
plugin=org.kde.panel

[Containments][2][Applets][3]
immutability=1
plugin=org.kde.plasma.kickoff

[Containments][2][Applets][4]
immutability=1
plugin=org.kde.plasma.taskmanager

[Containments][2][Applets][5]
immutability=1
plugin=org.kde.plasma.systemtray

[Containments][2][Applets][6]
immutability=1
plugin=org.kde.plasma.digitalclock

[Containments][2][General]
AppletOrder=3;4;5;6
EOF

# GTK theme to match (dark)
mkdir -p /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0
cat > /etc/skel/.config/gtk-3.0/settings.ini << 'EOF'
[Settings]
gtk-theme-name=Breeze-Dark
gtk-icon-theme-name=breeze-dark
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=breeze_cursors
gtk-application-prefer-dark-theme=1
EOF

cat > /etc/skel/.config/gtk-4.0/settings.ini << 'EOF'
[Settings]
gtk-theme-name=Breeze-Dark
gtk-icon-theme-name=breeze-dark
gtk-cursor-theme-name=breeze_cursors
gtk-application-prefer-dark-theme=1
EOF

# ASCII logo + fastfetch
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

# Zsh config — Oh-My-Zsh + Powerlevel10k
cat > /etc/skel/.zshrc << 'EOF'
# ── CipherOS Shell ────────────────────────────────────────────────────────────
export TERM="xterm-256color"
export ZSH="/usr/share/oh-my-zsh"
export ZSH_CUSTOM="$ZSH/custom"

ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    sudo
    colored-man-pages
    command-not-found
    extract
)

# Load p10k instant prompt (must be near top)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

source $ZSH/oh-my-zsh.sh 2>/dev/null || true

# Load p10k config
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# ── CipherOS Aliases ──────────────────────────────────────────────────────────
alias ll='ls -alFh --color=auto'
alias la='ls -A --color=auto'
alias update='sudo apt update && sudo apt upgrade -y'
alias install='sudo apt install'
alias remove='sudo apt remove'
alias myip='curl -s ifconfig.me'
alias localip='hostname -I | awk "{print \$1}"'
alias ports='ss -tulpn'
alias scan='sudo nmap -sV -sC'
alias anon='sudo systemctl start tor && proxychains4'
alias cipher-tools='echo "nmap sqlmap hydra hashcat metasploit aircrack-ng wireshark"'

# ── CipherOS Welcome ──────────────────────────────────────────────────────────
fastfetch 2>/dev/null
EOF
sed -i 's|SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd

# GRUB branding
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="CipherOS"/' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=off nowatchdog"/' /etc/default/grub
update-grub 2>/dev/null || true

# First-boot service
cat > /usr/local/bin/cipheros-firstboot << 'EOF'
#!/bin/bash
MARKER="/var/lib/cipheros/.firstboot_done"
[ -f "$MARKER" ] && exit 0
mkdir -p /var/lib/cipheros
PRIMARY_USER=$(getent passwd 1000 | cut -d: -f1)
if [ -n "$PRIMARY_USER" ]; then
    chsh -s /usr/bin/zsh "$PRIMARY_USER"
    cp /etc/skel/.zshrc /home/"$PRIMARY_USER"/.zshrc 2>/dev/null || true
    cp -r /etc/skel/.config /home/"$PRIMARY_USER"/ 2>/dev/null || true
    chown -R "$PRIMARY_USER":"$PRIMARY_USER" /home/"$PRIMARY_USER"/
    usermod -aG wireshark,netdev "$PRIMARY_USER" 2>/dev/null || true
fi
touch "$MARKER"
echo "✅ CipherOS first-boot complete."
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
echo "✅ CipherOS main hook complete."
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

# ── PHASE 10: GIT ────────────────────────────────────────────────────────────
header "🗂️  PHASE 10 — Git Repository"

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
    git commit -m "feat: CipherOS v2.0 — with Calamares, SDDM, KDE theming" 2>>"$LOG_FILE"
    success "Git repo initialised"
else
    warn "Git repo exists — skipping"
fi

# ── PHASE 11: BUILD ───────────────────────────────────────────────────────────
header "🚀 PHASE 11 — Building ISO (30–90 min)"

log "Logging to: $LOG_FILE"
log "Monitor in another terminal: tail -f $LOG_FILE"

START_TIME=$(date +%s)
lb build 2>&1 | tee -a "$LOG_FILE"
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

# ── PHASE 12: POST-BUILD ──────────────────────────────────────────────────────
header "✅ PHASE 12 — Post-Build"

BUILT_ISO=$(find "$WORKDIR" -maxdepth 1 -name "*.iso" | head -1)
if [[ -z "$BUILT_ISO" ]]; then
    echo -e "${RED}❌ No ISO found. Check $LOG_FILE${RESET}"; exit 1
fi
[[ "$BUILT_ISO" != "$WORKDIR/$ISO_NAME" ]] && mv "$BUILT_ISO" "$WORKDIR/$ISO_NAME"

ISO_SIZE=$(du -sh "$WORKDIR/$ISO_NAME" | cut -f1)
cd "$WORKDIR"
sha256sum "$ISO_NAME" > SHA256SUMS
sha512sum "$ISO_NAME" > SHA512SUMS
success "Checksums written"

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${PINK}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${PINK}║${RED}         🔐 CipherOS Build Complete! v3.0             ${PINK}║${RESET}"
echo -e "${PINK}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${PINK}║${RESET}  ISO     : ${GREEN}$WORKDIR/$ISO_NAME${RESET}"
echo -e "${PINK}║${RESET}  Size    : ${CYAN}$ISO_SIZE${RESET}"
echo -e "${PINK}║${RESET}  Time    : ${CYAN}${ELAPSED} minutes${RESET}"
echo -e "${PINK}║${RESET}  Log     : ${CYAN}$LOG_FILE${RESET}"
echo -e "${PINK}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${PINK}║${RESET}  ${YELLOW}Included in this build:${RESET}"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Calamares installer — branded + 5 install slides"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} SDDM cyberpunk login screen"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} KDE Plasma dark theme + CipherOS color scheme"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} CipherOS wallpaper 4K + 1080p"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Plymouth matrix rain animated boot splash"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Oh-My-Zsh + Powerlevel10k neon prompt"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Kvantum dark theme — blur + neon glow borders"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Konsole — FiraCode font, neon cursor, 88% opacity blur"
echo -e "${PINK}║${RESET}  ${GREEN}✓${RESET} Security toolkit, gaming stack, creative suite"
echo -e "${PINK}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${PINK}║${RESET}  ${YELLOW}Test with QEMU:${RESET}"
echo -e "${PINK}║${RESET}  ${CYAN}qemu-system-x86_64 -enable-kvm -m 4096 \\${RESET}"
echo -e "${PINK}║${RESET}  ${CYAN}  -cdrom $WORKDIR/$ISO_NAME -vnc :0 -daemonize${RESET}"
echo -e "${PINK}║${RESET}  ${YELLOW}Connect VNC viewer to: your-ip:5900${RESET}"
echo -e "${PINK}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
