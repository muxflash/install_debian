#!/usr/bin/env bash
# =============================================================
# deploy.sh — Lance un déploiement VM muxpc depuis muxcontainer
#
# Usage depuis muxcontainer :
#   bash muxpc/deploy.sh [VMID]
#
# Génère automatiquement une authkey Headscale fraîche,
# puis déploie la VM sur Proxmox (192.168.0.4).
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXMOX_HOST="${PROXMOX_HOST:-192.168.0.4}"
HEADSCALE_HOST="${HEADSCALE_HOST:-muxflash@37.59.56.147}"
HEADSCALE_USER_ID="${HEADSCALE_USER_ID:-1}"

VMID_NEW="${1:-${VMID_NEW:-200}}"
VM_NAME="${VM_NAME:-muxpc-test}"
MUXPC_DE="${MUXPC_DE:-gnome}"
MUXPC_QWEN="${MUXPC_QWEN:-n}"
MUXPC_OI="${MUXPC_OI:-n}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-2}"

SSH_PUB_KEY="$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || echo '')"

echo "━━━ deploy.sh — VM muxpc sur Proxmox $PROXMOX_HOST ━━━"
echo "  VMID      : $VMID_NEW  ($VM_NAME)"
echo "  Config    : DE=$MUXPC_DE  qwen=$MUXPC_QWEN  OI=$MUXPC_OI"
echo ""

# ── 1. Générer une authkey Headscale fraîche ──────────────────
echo "━━━ [1/3] Génération authkey Headscale ━━━"
TAILSCALE_AUTHKEY=$(ssh "$HEADSCALE_HOST" \
  "sudo headscale preauthkeys create --user $HEADSCALE_USER_ID --expiration 24h --reusable 2>/dev/null" \
  | grep -o 'hskey-auth-[A-Za-z0-9_-]*')

if [ -z "$TAILSCALE_AUTHKEY" ]; then
  echo "ERREUR : impossible de générer l'authkey Headscale (SSH $HEADSCALE_HOST)"
  echo "  Vérifier l'accès SSH et que headscale est actif sur ce serveur."
  exit 1
fi
echo "  ==> Authkey : ${TAILSCALE_AUTHKEY:0:30}... (24h)"

# ── 2. Copier les scripts sur Proxmox ────────────────────────
echo "━━━ [2/3] Copie des scripts sur Proxmox ━━━"
scp "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/proxmox-deploy-vm.sh" "root@$PROXMOX_HOST:/tmp/"
echo "  ==> install.sh + proxmox-deploy-vm.sh copiés"

# ── 3. Lancer le déploiement ──────────────────────────────────
echo "━━━ [3/3] Déploiement sur Proxmox ━━━"
ssh "root@$PROXMOX_HOST" \
  "export SSH_PUB_KEY='$SSH_PUB_KEY'; \
   export INSTALL_SH=\"\$(cat /tmp/install.sh)\"; \
   VMID_NEW=$VMID_NEW VM_NAME=$VM_NAME \
   STORAGE=NVME-STORAGE SNIPPETS_STORAGE=local \
   MUXPC_DE=$MUXPC_DE MUXPC_QWEN=$MUXPC_QWEN MUXPC_OI=$MUXPC_OI \
   TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY \
   MEMORY=$MEMORY CORES=$CORES \
   bash /tmp/proxmox-deploy-vm.sh"
