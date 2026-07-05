#!/usr/bin/env bash
# =============================================================
# deploy.sh — Lance un déploiement VM muxpc depuis muxcontainer
#
# Usage depuis muxcontainer :
#   bash muxpc/deploy.sh [VMID] [HOSTNAME] [USER] [PASSWORD]
#
# Exemples :
#   bash muxpc/deploy.sh 201
#   bash muxpc/deploy.sh 201 muxGnome
#   bash muxpc/deploy.sh 201 muxGnome muxflash <mot-de-passe>
#
# Variables d'env (priorité sur les args) :
#   VM_HOSTNAME, VM_USER, VM_PASS, MUXPC_DE, MEMORY, CORES
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXMOX_HOST="${PROXMOX_HOST:-192.168.0.4}"
HEADSCALE_HOST="${HEADSCALE_HOST:-muxflash@37.59.56.147}"
HEADSCALE_USER_ID="${HEADSCALE_USER_ID:-1}"

VMID_NEW="${1:-${VMID_NEW:-201}}"
VM_HOSTNAME="${2:-${VM_HOSTNAME:-muxGnome}}"
VM_USER="${3:-${VM_USER:-muxflash}}"
VM_PASS="${4:-${VM_PASS:-}}"
# Pas de mot de passe fixe committé : on en génère un aléatoire si aucun n'est fourni.
if [ -z "$VM_PASS" ]; then
  VM_PASS="$(openssl rand -base64 12)"
  echo "  ==> VM_PASS non fourni, mot de passe généré : $VM_PASS  (à noter avant de continuer)"
fi
VM_NAME="$VM_HOSTNAME"
MUXPC_DE="${MUXPC_DE:-gnome}"
MUXPC_QWEN="${MUXPC_QWEN:-n}"
MUXPC_OI="${MUXPC_OI:-n}"
MEMORY="${MEMORY:-4096}"
CORES="${CORES:-2}"

SSH_PUB_KEY="$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || echo '')"

echo "━━━ deploy.sh — VM muxpc sur Proxmox $PROXMOX_HOST ━━━"
echo "  VMID      : $VMID_NEW  ($VM_HOSTNAME)"
echo "  User      : $VM_USER  /  pass : ${VM_PASS//?/*}"
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
   VMID_NEW=$VMID_NEW VM_NAME='$VM_HOSTNAME' VM_HOSTNAME='$VM_HOSTNAME' \
   VM_USER='$VM_USER' VM_PASS='$VM_PASS' \
   STORAGE=NVME-STORAGE SNIPPETS_STORAGE=local \
   MUXPC_DE=$MUXPC_DE MUXPC_QWEN=$MUXPC_QWEN MUXPC_OI=$MUXPC_OI \
   TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY \
   MEMORY=$MEMORY CORES=$CORES \
   bash /tmp/proxmox-deploy-vm.sh"
