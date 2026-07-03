#!/usr/bin/env bash
# =============================================================
# proxmox-deploy-vm.sh — Clone le template et déploie une VM muxpc
# À exécuter sur le nœud Proxmox (root SSH), via pipe depuis muxcontainer :
#
#   SSH_PUB_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
#   INSTALL_SH="$(cat muxpc/install.sh)" \
#   VMID_NEW=200 VM_NAME=muxpc-test MUXPC_DE=gnome \
#   bash proxmox-deploy-vm.sh
# =============================================================
set -euo pipefail

VMID_TEMPLATE="${VMID_TEMPLATE:-9000}"
VMID_NEW="${VMID_NEW:-201}"
VM_NAME="${VM_NAME:-muxGnome}"
VM_HOSTNAME="${VM_HOSTNAME:-${VM_NAME}}"
VM_USER="${VM_USER:-muxflash}"
VM_PASS="${VM_PASS:-axlmux}"
STORAGE="${STORAGE:-NVME-STORAGE}"
SNIPPETS_STORAGE="${SNIPPETS_STORAGE:-local}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-2}"
DISK_SIZE="${DISK_SIZE:-}"

# Config muxpc
MUXPC_DE="${MUXPC_DE:-gnome}"
MUXPC_QWEN="${MUXPC_QWEN:-n}"
MUXPC_OI="${MUXPC_OI:-n}"

# Clé SSH : priorité à la variable d'env SSH_PUB_KEY (injectée depuis muxcontainer)
SSH_KEY="${SSH_PUB_KEY:-}"
if [ -z "$SSH_KEY" ]; then
  [ -f /root/.ssh/id_ed25519.pub ] && SSH_KEY=$(cat /root/.ssh/id_ed25519.pub)
  [ -f /root/.ssh/id_rsa.pub ]     && [ -z "$SSH_KEY" ] && SSH_KEY=$(cat /root/.ssh/id_rsa.pub)
fi

# install.sh embarqué : priorité à la variable INSTALL_SH (passée depuis muxcontainer)
INSTALL_SH_CONTENT="${INSTALL_SH:-}"

echo "━━━ Déploiement VM muxpc ($VM_HOSTNAME) ━━━"
echo "  Template  : $VMID_TEMPLATE → VM $VMID_NEW"
echo "  Ressources: $CORES CPU / ${MEMORY}Mo RAM"
echo "  User      : $VM_USER  /  pass : ${VM_PASS//?/*}"
echo "  Config    : DE=$MUXPC_DE qwen=$MUXPC_QWEN OI=$MUXPC_OI"
[ -n "$SSH_KEY" ] && echo "  SSH key   : ${SSH_KEY:0:40}..."
echo ""

if qm status "$VMID_NEW" &>/dev/null; then
  echo "ERREUR : VM $VMID_NEW existe déjà. Utiliser un autre VMID ou : qm destroy $VMID_NEW --purge"
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

# ── 3. Générer le user-data cloud-init ───────────────────────
echo "━━━ [3/4] Cloud-init user-data ━━━"
SNIPPETS_PATH="/var/lib/vz/snippets"
mkdir -p "$SNIPPETS_PATH"
USER_DATA_FILE="$SNIPPETS_PATH/muxpc-${VMID_NEW}-user-data.yaml"

# install.sh écrit en base64 pour éviter les problèmes d'échappement YAML
if [ -n "$INSTALL_SH_CONTENT" ]; then
  INSTALL_SH_B64=$(printf '%s' "$INSTALL_SH_CONTENT" | base64 -w 0)
  INSTALL_SH_BLOCK="  - path: /tmp/install.sh
    encoding: b64
    content: ${INSTALL_SH_B64}
    permissions: '0755'"
  RUN_INSTALL="bash /tmp/install.sh 2>&1 | tee /tmp/muxpc-install.log"
else
  INSTALL_SH_BLOCK=""
  RUN_INSTALL="echo 'ERREUR: install.sh non fourni via INSTALL_SH' | tee /tmp/muxpc-install.log; exit 1"
fi

cat > "$USER_DATA_FILE" << USERDATA
#cloud-config
hostname: ${VM_HOSTNAME}
timezone: Europe/Paris

users:
  - name: ${VM_USER}
    gecos: ${VM_USER}
    groups: sudo,audio,video,plugdev
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_KEY}

chpasswd:
  expire: false
  list: |
    ${VM_USER}:${VM_PASS}

package_update: true
package_upgrade: true
packages:
  - git
  - curl
  - qemu-guest-agent
  - locales

write_files:
${INSTALL_SH_BLOCK}

runcmd:
  - echo 'DEBIAN_FRONTEND=noninteractive' >> /etc/environment
  - printf 'Defaults env_keep += "DEBIAN_FRONTEND"\nDefaults !requiretty\n' > /etc/sudoers.d/muxpc_cloud_init
  - chmod 0440 /etc/sudoers.d/muxpc_cloud_init
  - sed -i 's/^# fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
  - locale-gen fr_FR.UTF-8
  - update-locale LANG=fr_FR.UTF-8
  - systemctl enable --now qemu-guest-agent || true
  - |
    sudo -u ${VM_USER} env \
      DEBIAN_FRONTEND=noninteractive \
      MUXPC_DE="${MUXPC_DE}" MUXPC_QWEN="${MUXPC_QWEN}" MUXPC_OI="${MUXPC_OI}" \
      ${TAILSCALE_AUTHKEY:+TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY}"} \
      HOME=/home/${VM_USER} \
      bash /tmp/install.sh 2>&1 | tee /tmp/muxpc-install.log

final_message: |
  muxpc-install terminé. Log : /tmp/muxpc-install.log
USERDATA

echo "==> user-data généré : $USER_DATA_FILE"

# Attacher le user-data cloud-init à la VM
qm set "$VMID_NEW" \
  --cicustom "user=${SNIPPETS_STORAGE}:snippets/muxpc-${VMID_NEW}-user-data.yaml"

# Régénérer l'ISO cloud-init
qm cloudinit dump "$VMID_NEW" user >/dev/null 2>&1 || true

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
