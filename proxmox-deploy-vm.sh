#!/usr/bin/env bash
# =============================================================
# proxmox-deploy-vm.sh — Clone le template et déploie une VM muxpc
# À exécuter sur le nœud Proxmox (root SSH) ou via l'API Proxmox
#
# Usage :
#   bash proxmox-deploy-vm.sh
#   VMID_NEW=201 VM_NAME=muxpc-laurent bash proxmox-deploy-vm.sh
# =============================================================
set -euo pipefail

PROXMOX_HOST="192.168.0.4"
VMID_TEMPLATE="${VMID_TEMPLATE:-9000}"
VMID_NEW="${VMID_NEW:-200}"
VM_NAME="${VM_NAME:-muxpc}"
STORAGE="${STORAGE:-local-lvm}"
SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-local}"
MEMORY="${MEMORY:-8192}"    # Mo
CORES="${CORES:-4}"
DISK_SIZE="${DISK_SIZE:-}"  # vide = hérite du template (40G)

# Config muxpc : variables passées à install.sh
MUXPC_DE="${MUXPC_DE:-gnome}"
MUXPC_QWEN="${MUXPC_QWEN:-n}"
MUXPC_OI="${MUXPC_OI:-n}"

echo "━━━ Déploiement VM muxpc ($VM_NAME) ━━━"
echo "  Template  : $VMID_TEMPLATE → VM $VMID_NEW"
echo "  Ressources: $CORES CPU / ${MEMORY}Mo RAM"
echo "  Config    : DE=$MUXPC_DE qwen=$MUXPC_QWEN OI=$MUXPC_OI"
echo ""

if qm status "$VMID_NEW" &>/dev/null; then
  echo "ERREUR : VM $VMID_NEW existe déjà."
  exit 1
fi

# ── 1. Cloner le template ─────────────────────────────────────
echo "━━━ [1/4] Clone template ━━━"
qm clone "$VMID_TEMPLATE" "$VMID_NEW" \
  --name "$VM_NAME" \
  --full \
  --storage "$STORAGE"

# ── 2. Ajuster les ressources ─────────────────────────────────
echo "━━━ [2/4] Configuration VM ━━━"
qm set "$VMID_NEW" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --ipconfig0 ip=dhcp

[ -n "${DISK_SIZE:-}" ] && qm resize "$VMID_NEW" scsi0 "$DISK_SIZE"

# ── 3. Générer et injecter le user-data personnalisé ──────────
echo "━━━ [3/4] Cloud-init user-data ━━━"
SNIPPETS_PATH="/var/lib/vz/snippets"
USER_DATA_FILE="$SNIPPETS_PATH/muxpc-${VMID_NEW}-user-data.yaml"

# Lire la clé SSH publique si disponible
SSH_KEY=""
[ -f /root/.ssh/authorized_keys ] && SSH_KEY=$(head -1 /root/.ssh/authorized_keys)
[ -f /root/.ssh/id_ed25519.pub  ] && SSH_KEY=$(cat /root/.ssh/id_ed25519.pub)
[ -f /root/.ssh/id_rsa.pub      ] && [ -z "$SSH_KEY" ] && SSH_KEY=$(cat /root/.ssh/id_rsa.pub)

# Template user-data : on injecte les variables muxpc
mkdir -p "$SNIPPETS_PATH"
cat > "$USER_DATA_FILE" << USERDATA
#cloud-config
hostname: ${VM_NAME}
locale: fr_FR.UTF-8
timezone: Europe/Paris

users:
  - name: muxflash
    gecos: muxflash
    groups: sudo,audio,video,plugdev,netdev
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_KEY}

package_update: true
package_upgrade: true
packages:
  - git
  - curl
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
  - |
    # Lancer install.sh en mode non-interactif sous l'utilisateur muxflash
    sudo -u muxflash bash -c '
      export MUXPC_DE="${MUXPC_DE}"
      export MUXPC_QWEN="${MUXPC_QWEN}"
      export MUXPC_OI="${MUXPC_OI}"
      export HOME=/home/muxflash
      cd /tmp
      git clone https://github.com/muxflash/rancher.git rancher-setup
      bash /tmp/rancher-setup/muxpc/install.sh 2>&1 | tee /tmp/muxpc-install.log
    '

final_message: |
  ✅ VM ${VM_NAME} prête ! Log : /tmp/muxpc-install.log
  Connexion : ssh muxflash@$(hostname -I | awk '{print \$1}')
USERDATA

echo "==> user-data généré : $USER_DATA_FILE"

# Attacher le user-data cloud-init à la VM
qm set "$VMID_NEW" \
  --cicustom "user=${SNIPPETS_STORAGE}:snippets/muxpc-${VMID_NEW}-user-data.yaml"

# ── 4. Démarrer la VM ─────────────────────────────────────────
echo "━━━ [4/4] Démarrage VM ━━━"
qm start "$VMID_NEW"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  VM $VM_NAME ($VMID_NEW) démarrée !                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Suivre l'installation cloud-init :"
echo "   ssh muxflash@<ip-vm> 'tail -f /tmp/muxpc-install.log'"
echo "   ou depuis Proxmox : qm terminal $VMID_NEW"
echo ""
echo "💡 Pour détruire la VM plus tard :"
echo "   qm stop $VMID_NEW && qm destroy $VMID_NEW --purge"
