#!/usr/bin/env bash
# Génère debian-12-muxgnome-autoinstall.iso depuis debian-12 netinst
# Usage: bash build-iso.sh [DE=gnome|kde] [QWEN=y|n] [OI=y|n]
set -euo pipefail

DE="${1:-gnome}"
QWEN="${2:-n}"
OI="${3:-y}"
DEBIAN_VER="12.14.0"
ISO_URL="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VER}/amd64/iso-cd/debian-${DEBIAN_VER}-amd64-netinst.iso"
OUT_ISO="debian-12-muxgnome-autoinstall.iso"
WORKDIR="$(mktemp -d)"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "━━━ Téléchargement Debian ${DEBIAN_VER} netinst ━━━"
wget -q --show-progress "$ISO_URL" -O "$WORKDIR/debian-netinst.iso"

echo "━━━ Extraction ISO ━━━"
xorriso -osirrox on -indev "$WORKDIR/debian-netinst.iso" -extract / "$WORKDIR/iso" 2>/dev/null
chmod -R u+w "$WORKDIR/iso"

echo "━━━ Injection preseed + install.sh ━━━"
cp "$(dirname "$0")/preseed.cfg" "$WORKDIR/iso/preseed.cfg"
cp "$(dirname "$0")/install.sh"  "$WORKDIR/iso/install.sh"

# Remplacer les paramètres dans preseed selon args
sed -i "s/MUXPC_DE=gnome/MUXPC_DE=${DE}/" "$WORKDIR/iso/preseed.cfg"
sed -i "s/MUXPC_QWEN=n/MUXPC_QWEN=${QWEN}/" "$WORKDIR/iso/preseed.cfg"
sed -i "s/MUXPC_OI=y/MUXPC_OI=${OI}/" "$WORKDIR/iso/preseed.cfg"

# BIOS (isolinux)
cat > "$WORKDIR/iso/isolinux/txt.cfg" << 'EOF'
default autoinstall
label autoinstall
	menu label ^Autoinstall muxGnome
	menu default
	kernel /install.amd/vmlinuz
	append auto=true priority=critical vga=788 initrd=/install.amd/initrd.gz file=/cdrom/preseed.cfg --- quiet

label install
	menu label ^Install (manuel)
	kernel /install.amd/vmlinuz
	append vga=788 initrd=/install.amd/initrd.gz --- quiet
EOF

# menu.cfg — uniquement stdmenu + txt (pas de gtk/spkgtk qui prennent la priorité)
cat > "$WORKDIR/iso/isolinux/menu.cfg" << 'EOF'
menu hshift 4
menu width 70
menu title Debian GNU/Linux installer menu (BIOS mode)
include stdmenu.cfg
include txt.cfg
EOF
sed -i 's/^timeout .*/timeout 30/' "$WORKDIR/iso/isolinux/isolinux.cfg"

# UEFI (grub)
python3 - "$WORKDIR/iso/boot/grub/grub.cfg" << 'PYEOF'
import sys
path = sys.argv[1]
content = open(path).read()
entry = '''set default=0\nset timeout=5\n\nmenuentry --hotkey=a \'Autoinstall muxGnome\' {\n    set background_color=black\n    linux    /install.amd/vmlinuz auto=true priority=critical vga=788 file=/cdrom/preseed.cfg --- quiet\n    initrd   /install.amd/initrd.gz\n}\n'''
content = content.replace("insmod play\nplay 960 440 1 0 4 440 1", "insmod play\nplay 960 440 1 0 4 440 1\n" + entry)
open(path, 'w').write(content)
PYEOF

echo "━━━ Reconstruction ISO ━━━"
xorriso -as mkisofs \
  -V "Debian 12 muxGnome" \
  -isohybrid-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt,zero_apm:"$WORKDIR/debian-netinst.iso" \
  -partition_cyl_align on -partition_offset 0 -partition_hd_cyl 64 -partition_sec_hd 32 \
  --mbr-force-bootable -apm-block-size 2048 -iso_mbr_part_type 0x00 \
  -c '/isolinux/boot.cat' -b '/isolinux/isolinux.bin' -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e '/boot/grub/efi.img' -no-emul-boot -boot-load-size 18976 \
  -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \
  -o "$OUT_ISO" "$WORKDIR/iso" 2>&1 | tail -4

echo "━━━ ISO créé : $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1)) ━━━"
