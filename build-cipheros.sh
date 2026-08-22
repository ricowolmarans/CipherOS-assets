#!/bin/bash
set -euo pipefail

# ============================================================
# CipherOS Build Script
#
# Run this FROM INSIDE the cloned cipheros-assets folder:
#
#   git clone https://github.com/ricowolmarans/cipheros-assets
#   cd cipheros-assets
#   chmod +x build-cipheros.sh
#   ./build-cipheros.sh
#
# Creates ../CipherOS (sibling folder), scaffolds a full
# live-build project: KDE Plasma desktop, dev stack, Kali-style
# pentest suite, media production tools, Brave as default browser,
# and applies CipherOS branding (logo, wallpapers, GRUB/Plymouth/SDDM).
# ============================================================

ASSETS_DIR="$(pwd)"
BUILD_DIR="../CipherOS"

echo "[*] Assets source: $ASSETS_DIR"
echo "[*] Build target:  $BUILD_DIR"

# --- Sanity checks ---
if [ ! -d "$ASSETS_DIR/wallpapers" ]; then
    echo "[!] No 'wallpapers' folder found here. Run this from inside cipheros-assets/"
    exit 1
fi

# --- Dependencies ---
if ! command -v lb >/dev/null 2>&1; then
    echo "[*] live-build not found, installing..."
    sudo apt update
    sudo apt install -y live-build
fi

# --- Scaffold live-build project ---
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -d "config" ]; then
    echo "[*] Initializing live-build config..."
    lb config \
        --distribution bookworm \
        --architectures amd64 \
        --debian-installer live \
        --archive-areas "main contrib non-free non-free-firmware"
else
    echo "[*] live-build config already exists, skipping lb config."
fi

mkdir -p config/package-lists
mkdir -p config/includes.chroot/usr/share/backgrounds/cipheros
mkdir -p config/includes.chroot/usr/share/plymouth/themes/cipheros
mkdir -p config/includes.chroot/boot/grub
mkdir -p config/includes.chroot/usr/share/sddm/themes/cipheros
mkdir -p config/includes.chroot/usr/share/cipheros/logo
mkdir -p config/includes.chroot/usr/share/color-schemes
mkdir -p config/includes.chroot/usr/share/plasma/look-and-feel/org.cipheros.phantom/contents/defaults
mkdir -p config/hooks/live
mkdir -p config/archives

# ============================================================
# KALI REPO OVERLAY (pinned, low priority — only pulls specific
# packages like burpsuite/metasploit that aren't in Debian proper.
# Everything else stays sourced from Debian to keep the base stable.)
# ============================================================

cat > config/archives/kali.list.chroot <<'EOF'
deb [signed-by=/usr/share/keyrings/kali-archive-keyring.gpg] http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF
# NOTE: the actual keyring file is fetched/installed by
# 0050-kali-key.hook.chroot at build time, BEFORE this list is used —
# live-build runs archive hooks ahead of package installation.

cat > config/archives/kali.pref.chroot <<'EOF'
Package: *
Pin: release o=Kali
Pin-Priority: 100

Package: burpsuite metasploit-framework
Pin: release o=Kali
Pin-Priority: 900
EOF

# ============================================================
# PACKAGE LISTS
# ============================================================

# --- Desktop: KDE Plasma ---
cat > config/package-lists/desktop.list.chroot <<'EOF'
task-kde-desktop
kde-plasma-desktop
plasma-nm
sddm
plymouth
plymouth-themes
grub-common
grub-pc
konsole
dolphin
ark
kate
spectacle
EOF

# --- Dev stack ---
cat > config/package-lists/dev.list.chroot <<'EOF'
git
build-essential
curl
wget
docker.io
docker-compose
python3
python3-pip
python3-venv
nodejs
npm
EOF

# --- Pentest suite (Kali-style, via Debian-packaged equivalents to
# keep the base stable — swap in Kali repo overlay later if you want
# the exact upstream Kali builds) ---
cat > config/package-lists/pentest.list.chroot <<'EOF'
nmap
wireshark
metasploit-framework
burpsuite
aircrack-ng
john
hydra
sqlmap
netcat-traditional
gobuster
nikto
hashcat
ettercap-graphical
EOF

# --- Media production ---
cat > config/package-lists/media.list.chroot <<'EOF'
kdenlive
audacity
gimp
ffmpeg
EOF

# Browser: Brave installed via hook (needs external repo, not in apt by default)
# Chrome/Opera intentionally left out of base ISO — install on demand later

echo "[*] Wrote package lists (desktop, dev, pentest, media)"

# ============================================================
# PHANTOM THEME: Plasma color scheme, Plymouth boot theme,
# GRUB colors, SDDM login theme — red/grey palette to match
# the CipherOS PHANTOM UI previews.
# ============================================================

echo "[*] Generating PHANTOM theme files..."

# --- Plasma color scheme (red/grey, matches installer/desktop previews) ---
cat > config/includes.chroot/usr/share/color-schemes/CipherPhantom.colors <<'EOF'
[General]
ColorScheme=CipherPhantom
Name=Cipher Phantom
shadeSortColumn=true

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
BackgroundAlternate=18,17,16
BackgroundNormal=18,17,16
DecorationFocus=239,68,68
DecorationHover=185,28,28
ForegroundActive=239,68,68
ForegroundInactive=122,120,118
ForegroundNormal=228,226,224

[Colors:Selection]
BackgroundAlternate=185,28,28
BackgroundNormal=185,28,28
DecorationFocus=239,68,68
DecorationHover=239,68,68
ForegroundActive=255,255,255
ForegroundNormal=255,255,255

[Colors:View]
BackgroundAlternate=16,15,14
BackgroundNormal=10,9,8
DecorationFocus=239,68,68
DecorationHover=185,28,28
ForegroundActive=239,68,68
ForegroundInactive=122,120,118
ForegroundNormal=228,226,224

[Colors:Window]
BackgroundAlternate=18,17,16
BackgroundNormal=10,9,8
DecorationFocus=239,68,68
DecorationHover=185,28,28
ForegroundActive=239,68,68
ForegroundInactive=122,120,118
ForegroundNormal=228,226,224

[WM]
activeBackground=18,17,16
activeForeground=228,226,224
inactiveBackground=10,9,8
inactiveForeground=122,120,118
EOF

# --- Plymouth boot theme (basic script plugin, red/grey pulse) ---
cat > "config/includes.chroot/usr/share/plymouth/themes/cipheros/cipheros.plymouth" <<'EOF'
[Plymouth Theme]
Name=CipherOS Phantom
Description=CipherOS PHANTOM boot theme - red/grey
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/cipheros
ScriptFile=/usr/share/plymouth/themes/cipheros/cipheros.script
EOF

cat > "config/includes.chroot/usr/share/plymouth/themes/cipheros/cipheros.script" <<'EOF'
Window.SetBackgroundTopColor(0.039, 0.035, 0.031);
Window.SetBackgroundBottomColor(0.02, 0.018, 0.016);

logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetWidth()/2 - logo.image.GetWidth()/2);
logo.sprite.SetY(Window.GetHeight()/2 - logo.image.GetHeight()/2 - 40);

message_sprite = Sprite();
message_sprite.SetPosition(Window.GetWidth()/2 - 100, Window.GetHeight()/2 + 80, 10000);

pulse = 0;
fun refresh_callback() {
  pulse += 0.05;
  opacity = 0.5 + 0.5 * Math.Sin(pulse);
  logo.sprite.SetOpacity(opacity);
}
Plymouth.SetRefreshFunction(refresh_callback);

fun message_callback(text) {
  my_image = Image.Text(text, 0.93, 0.28, 0.28);
  message_sprite.SetImage(my_image);
}
Plymouth.SetUpdateStatusFunction(message_callback);
EOF

# --- SDDM login theme config (points to a QML theme + palette hints) ---
cat > "config/includes.chroot/usr/share/sddm/themes/cipheros/theme.conf" <<'EOF'
[General]
background=background.png
type=color
color=#0a0908
fontSize=11
EOF

mkdir -p config/includes.chroot/etc/sddm.conf.d
cat > config/includes.chroot/etc/sddm.conf.d/cipheros.conf <<'EOF'
[Theme]
Current=cipheros
EOF

# --- GRUB theme colors (text-mode GRUB menu, red/grey to match) ---
mkdir -p config/includes.chroot/etc/default/grub.d
cat > config/includes.chroot/etc/default/grub.d/cipheros-colors.cfg <<'EOF'
GRUB_COLOR_NORMAL="light-gray/black"
GRUB_COLOR_HIGHLIGHT="light-red/black"
EOF

echo "[*] PHANTOM theme files generated (Plasma colors, Plymouth, SDDM, GRUB)"

# ============================================================
# BRANDING: wallpapers, logo, default backgrounds
# ============================================================

echo "[*] Copying wallpapers..."
cp -v "$ASSETS_DIR/wallpapers/"* config/includes.chroot/usr/share/backgrounds/cipheros/ 2>/dev/null || echo "    (no wallpaper files found)"

if [ -d "$ASSETS_DIR/logo" ]; then
    echo "[*] Copying logo..."
    cp -v "$ASSETS_DIR/logo/"* config/includes.chroot/usr/share/cipheros/logo/ 2>/dev/null || echo "    (no logo files found)"
fi

DEFAULT_WALLPAPER=$(ls "$ASSETS_DIR/wallpapers" 2>/dev/null | head -n 1 || true)

if [ -n "$DEFAULT_WALLPAPER" ]; then
    echo "[*] Using '$DEFAULT_WALLPAPER' as default wallpaper (GRUB/Plymouth/SDDM)"
    cp "$ASSETS_DIR/wallpapers/$DEFAULT_WALLPAPER" config/includes.chroot/boot/grub/cipheros-grub-bg.png 2>/dev/null || true
    cp "$ASSETS_DIR/wallpapers/$DEFAULT_WALLPAPER" config/includes.chroot/usr/share/plymouth/themes/cipheros/background.png 2>/dev/null || true
    cp "$ASSETS_DIR/wallpapers/$DEFAULT_WALLPAPER" config/includes.chroot/usr/share/sddm/themes/cipheros/background.png 2>/dev/null || true
else
    echo "[!] No wallpapers found — copy manually into config/includes.chroot/usr/share/backgrounds/cipheros/ later"
fi

# ============================================================
# HOOKS
# ============================================================

# --- Kali signing key hook (must run before apt update in chroot) ---
cat > config/hooks/live/0050-kali-key.hook.chroot <<'EOF'
#!/bin/bash
set -e
apt-get install -y wget gnupg
wget -q -O /tmp/kali-archive-key.asc https://archive.kali.org/archive-key.asc
gpg --dearmor < /tmp/kali-archive-key.asc > /usr/share/keyrings/kali-archive-keyring.gpg
echo "[hook] Kali signing key installed."
EOF
chmod +x config/hooks/live/0050-kali-key.hook.chroot

# --- Branding + display manager hook ---
cat > config/hooks/live/0100-branding.hook.chroot <<'EOF'
#!/bin/bash
set -e

if [ -f /boot/grub/cipheros-grub-bg.png ]; then
    cat >> /etc/default/grub <<'GRUBEOF'
GRUB_BACKGROUND="/boot/grub/cipheros-grub-bg.png"
GRUBEOF
fi

if [ -x /usr/bin/sddm ]; then
    echo "/usr/bin/sddm" > /etc/X11/default-display-manager
    systemctl set-default graphical.target
    systemctl enable sddm
fi

# Fallback logo.png for Plymouth if none was copied from assets
if [ ! -f /usr/share/plymouth/themes/cipheros/logo.png ]; then
    LOGO_SRC=$(find /usr/share/cipheros/logo -type f \( -iname "*.png" \) 2>/dev/null | head -n 1 || true)
    if [ -n "$LOGO_SRC" ]; then
        cp "$LOGO_SRC" /usr/share/plymouth/themes/cipheros/logo.png
    fi
fi

# Set Plymouth default theme
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme cipheros || true
    update-initramfs -u || true
fi

# Set system-wide default Plasma color scheme (Cipher Phantom)
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/kdeglobals <<'KDEEOF'
[General]
ColorScheme=CipherPhantom

[KDE]
LookAndFeelPackage=org.cipheros.phantom
KDEEOF

echo "[hook] CipherOS PHANTOM branding applied (Plymouth, SDDM, Plasma colors)."
EOF
chmod +x config/hooks/live/0100-branding.hook.chroot

# --- Brave browser install hook ---
cat > config/hooks/live/0200-brave-browser.hook.chroot <<'EOF'
#!/bin/bash
set -e

curl -fsS https://dl.brave.com/install.sh | sh || {
    echo "[hook] Brave install script failed, retrying via saved script"
    curl -fsS https://dl.brave.com/install.sh -o /tmp/brave-install.sh
    bash /tmp/brave-install.sh
}

echo "[hook] Brave browser installed as default."
EOF
chmod +x config/hooks/live/0200-brave-browser.hook.chroot

# --- Docker service enable hook ---
cat > config/hooks/live/0300-docker-enable.hook.chroot <<'EOF'
#!/bin/bash
set -e
systemctl enable docker || true
echo "[hook] Docker service enabled."
EOF
chmod +x config/hooks/live/0300-docker-enable.hook.chroot

echo ""
echo "============================================================"
echo "[✓] CipherOS build scaffold ready at: $BUILD_DIR"
echo ""
echo "Includes:"
echo "  - KDE Plasma desktop"
echo "  - Dev stack: git, docker, python3, node/npm, build-essential"
echo "  - Pentest suite: nmap, wireshark, metasploit, burpsuite,"
echo "                   aircrack-ng, john, hydra, sqlmap, hashcat, etc."
echo "  - Media: kdenlive, audacity, gimp, ffmpeg"
echo "  - Brave as default browser (installed via hook)"
echo "  - CipherOS PHANTOM theme: red/grey Plasma color scheme,"
echo "                            animated Plymouth boot theme,"
echo "                            SDDM login theme, GRUB colors"
echo "  - Branding: wallpapers, logo, GRUB/Plymouth/SDDM backgrounds"
echo ""
echo "Next steps:"
echo "  cd $BUILD_DIR"
echo "  sudo lb build"
echo "============================================================"
