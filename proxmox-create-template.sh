#!/usr/bin/env bash
# =============================================================
# proxmox-create-template.sh — Crée un template Debian 12 cloud-init
# À exécuter UNE SEULE FOIS sur le nœud Proxmox (en root SSH)
#
# Usage :
#   ssh root@192.168.0.X 'bash -s' < proxmox-create-template.sh
#   ou avec paramètres :
#   VMID=9010 STORAGE=local-lvm bash proxmox-create-template.sh
# =============================================================
set -euo pipefail

VMID="${VMID:-9000}"
STORAGE="${STORAGE:-local-lvm}"          # adapter : local-lvm, local, ceph…
SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-local}"  # stockage avec snippets activés
TEMPLATE_NAME="debian12-muxpc"
DEBIAN_IMAGE="debian-12-generic-amd64.qcow2"
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/$DEBIAN_IMAGE"
TMP_IMAGE="/var/lib/vz/template/iso/$DEBIAN_IMAGE"

echo "━━━ Proxmox template Debian 12 cloud-init ━━━"
echo "  VMID     : $VMID"
echo "  Stockage : $STORAGE"
echo "  Snippets : $SNIPPETS_STORAGE"
echo ""

# Vérifier que l'ID n'est pas déjà utilisé
if qm status "$VMID" &>/dev/null; then
  echo "ERREUR : VM $VMID existe déjà. Choisir un autre VMID ou : qm destroy $VMID"
  exit 1
fi

# ── 1. Télécharger l'image cloud Debian 12 ───────────────────
echo "━━━ [1/6] Image Debian 12 cloud ━━━"
if [ ! -f "$TMP_IMAGE" ]; then
  wget -q --show-progress -O "$TMP_IMAGE" "$DEBIAN_URL"
else
  echo "==> Image déjà présente, skip."
fi

# ── 2. Créer la VM ───────────────────────────────────────────
echo "━━━ [2/6] Création VM $VMID ━━━"
qm create "$VMID" \
  --name "$TEMPLATE_NAME" \
  --memory 4096 \
  --cores 4 \
  --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --ostype l26 \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

# ── 3. Importer le disque ────────────────────────────────────
echo "━━━ [3/6] Import disque ━━━"
qm importdisk "$VMID" "$TMP_IMAGE" "$STORAGE" --format qcow2

qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1" \
  --boot order=scsi0 \
  --ide2 "${STORAGE}:cloudinit" \
  --ipconfig0 ip=dhcp

# Redimensionner le disque à 40 Go (image cloud de base = 2 Go)
qm resize "$VMID" scsi0 40G

# ── 4. Activer snippets sur le stockage local ────────────────
echo "━━━ [4/6] Activation snippets ━━━"
SNIPPETS_DIR=$(pvesm status -storage "$SNIPPETS_STORAGE" 2>/dev/null | \
  awk 'NR>1{print $1}' | head -1)
SNIPPETS_PATH="/var/lib/vz/snippets"
pvesm set "$SNIPPETS_STORAGE" --content "iso,vztmpl,backup,snippets" 2>/dev/null || true
mkdir -p "$SNIPPETS_PATH"

# ── 5. Copier le user-data cloud-init ────────────────────────
echo "━━━ [5/6] user-data cloud-init ━━━"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_DATA_SRC="$SCRIPT_DIR/cloud-init/user-data.yaml"

if [ -f "$USER_DATA_SRC" ]; then
  cp "$USER_DATA_SRC" "$SNIPPETS_PATH/muxpc-user-data.yaml"
  echo "==> user-data copié → $SNIPPETS_PATH/muxpc-user-data.yaml"
else
  echo "AVERTISSEMENT : $USER_DATA_SRC introuvable."
  echo "  Copier manuellement cloud-init/user-data.yaml dans $SNIPPETS_PATH/"
fi

# ── 6. Convertir en template ─────────────────────────────────
echo "━━━ [6/6] Conversion en template ━━━"
qm template "$VMID"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Template $TEMPLATE_NAME ($VMID) créé !              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Prochaine étape : proxmox-deploy-vm.sh"
echo "  VMID_TEMPLATE=$VMID VMID_NEW=200 VM_NAME=muxpc-dev bash proxmox-deploy-vm.sh"
