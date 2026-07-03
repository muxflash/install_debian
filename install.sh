#!/usr/bin/env bash
# =============================================================
# install.sh — Post-install KDE ou GNOME + Debian (poste muxflash)
# Usage : bash install.sh
# Idempotent : peut être relancé sans dupliquer quoi que ce soit
# =============================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# sudo strips env vars by default — prefix each sudo apt call explicitly too (see below)

GITHUB_RAW="https://raw.githubusercontent.com/muxflash/rancher/muxpc/muxpc"
WALLPAPER_IMAGE="wallpaperswide.com-assassins-creed-unity-arno-wallpaper-5120x1440.jpg"
WALLPAPER_DIR="$HOME/Images/Wallpaper"
CLAUDE_DIR="$HOME/claude"
REPO_DIR="$CLAUDE_DIR/github/rancher"
REPO_SSH="git@github.com:muxflash/rancher.git"
VENV="$HOME/.venv-tools"
ZSHRC="$HOME/.zshrc"

# Headscale auth key — RÉGÉNÉRER si expiré :
# https://vpn.billot.net:8090 → New auth key (expiry 24h suffit)
# Passer via env : TAILSCALE_AUTHKEY=hskey-auth-xxx bash install.sh
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-hskey-auth-yZlhjwxvQmB1-d8SDKReUiK9niHhoaqCs2QR18nOjwAB-mSS0P_vcXSd07vKk0gdOUF4rQ_xmo9sZ}"
TAILSCALE_SERVER="https://vpn.billot.net:8090"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        Post-install muxflash — Debian                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Toutes les questions upfront (avant qu'OMZ ferme /dev/tty) ──────────────
# Mode non-interactif via env : MUXPC_DE=kde|gnome  MUXPC_QWEN=y|n  MUXPC_OI=y|n

QWEN_MODEL="qwen3.6:35b"

if [ -n "${MUXPC_DE:-}" ]; then
  case "${MUXPC_DE}" in
    gnome) DE="gnome" ;;
    *)     DE="kde"   ;;
  esac
  _install_qwen="${MUXPC_QWEN:-n}"
  _install_oi="${MUXPC_OI:-n}"
  echo "==> Mode non-interactif : DE=$DE qwen=$_install_qwen open-interpreter=$_install_oi"
else
  echo "Environnement de bureau :"
  echo "  1) KDE Plasma  (défaut)"
  echo "  2) GNOME"
  read -rp "==> Choix [1/2] : " _de_choice
  case "${_de_choice:-1}" in
    2) DE="gnome" ;;
    *) DE="kde"   ;;
  esac
  echo "==> Bureau sélectionné : $DE"
  echo ""
  _install_qwen="n"
  if ! ollama list 2>/dev/null | grep -q "$QWEN_MODEL"; then
    read -rp "==> Télécharger $QWEN_MODEL (~23 GB) ? [y/N] " _install_qwen
  fi
  _install_oi="n"
  read -rp "==> Installer open-interpreter ? [y/N] " _install_oi
fi

echo ""

# -------------------------------------------------------------
# 0. Dépôts non-free + drivers NVIDIA + GRUB
# -------------------------------------------------------------
echo "━━━ [0/15] Dépôts non-free + NVIDIA + GRUB ━━━"

# Activation des dépôts contrib non-free non-free-firmware
# Debian 12 cloud image : format DEB822 dans /etc/apt/sources.list.d/debian.sources
_SOURCES_DEB822="/etc/apt/sources.list.d/debian.sources"
_SOURCES_CLASSIC="/etc/apt/sources.list"
if [ -f "$_SOURCES_DEB822" ] && ! grep -q "non-free" "$_SOURCES_DEB822"; then
  echo "==> Activation non-free (DEB822) dans $_SOURCES_DEB822..."
  sudo sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' "$_SOURCES_DEB822"
  sudo apt update -q
elif [ -f "$_SOURCES_CLASSIC" ] && ! grep -q "non-free-firmware" "$_SOURCES_CLASSIC"; then
  echo "==> Activation non-free (classique) dans $_SOURCES_CLASSIC..."
  sudo sed -i 's/^\(deb .*debian\.org\/debian[^#]*main\)\(.*\)$/\1 contrib non-free non-free-firmware/' "$_SOURCES_CLASSIC"
  sudo apt update -q
else
  echo "==> Dépôts non-free déjà configurés, skip."
fi

# GRUB + NVIDIA : seulement si GPU NVIDIA physique détecté
if lspci 2>/dev/null | grep -iq nvidia; then
  GRUB_FILE=/etc/default/grub
  if ! grep -q "nvidia-drm.modeset=1" "$GRUB_FILE"; then
    echo "==> Ajout de nvidia-drm.modeset=1 dans GRUB_CMDLINE_LINUX_DEFAULT..."
    sudo sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' "$GRUB_FILE"
    sudo update-grub
  fi
  if ! dpkg -l nvidia-driver &>/dev/null; then
    echo "==> Installation des drivers NVIDIA (nvidia-driver + firmware)..."
    sudo DEBIAN_FRONTEND=noninteractive apt install -y nvidia-driver firmware-nvidia-graphics
  else
    echo "==> Drivers NVIDIA déjà installés ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo '?')), skip."
  fi
else
  echo "==> Pas de GPU NVIDIA détecté, skip drivers + GRUB param."
fi

# -------------------------------------------------------------
# 1. Mise à jour système
# -------------------------------------------------------------
echo "━━━ [1/15] Mise à jour système ━━━"
sudo apt update && sudo apt upgrade -y

# -------------------------------------------------------------
# 1. Paquets de base
# -------------------------------------------------------------
echo "━━━ [2/15] Paquets de base ━━━"
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  git curl unzip wget zip rsync screen vim vlc plocate \
  zsh zsh-autosuggestions zsh-syntax-highlighting fzf \
  flatpak python3-pip python3-venv tmux \
  lm-sensors btop papirus-icon-theme

case "$DE" in
  kde)
    sudo DEBIAN_FRONTEND=noninteractive apt install -y \
      yakuake kdeconnect filelight plasma-systemmonitor ;;
  gnome)
    sudo DEBIAN_FRONTEND=noninteractive apt install -y \
      gnome-tweaks gnome-shell-extension-manager tilix \
      dconf-editor chrome-gnome-shell || \
      { sudo dpkg --configure -a 2>/dev/null || true; } ;;
esac

# fastfetch fallback (vieille version Debian)
if ! command -v fastfetch &>/dev/null; then
  echo "==> fastfetch absent des dépôts, installation via le .deb officiel..."
  ARCH=$(dpkg --print-architecture)
  FASTFETCH_URL=$(curl -s https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
    | grep "browser_download_url.*${ARCH}.*\.deb" | head -n1 | cut -d '"' -f4) || true
  if [ -n "${FASTFETCH_URL:-}" ]; then
    curl -fLo /tmp/fastfetch.deb "$FASTFETCH_URL"
    sudo DEBIAN_FRONTEND=noninteractive apt install -y /tmp/fastfetch.deb
    rm -f /tmp/fastfetch.deb
  fi
fi

# -------------------------------------------------------------
# 2. zsh + Oh My Zsh + plugins
# -------------------------------------------------------------
echo "━━━ [3/15] zsh + Oh My Zsh ━━━"

if [ "$(basename "${SHELL:-bash}")" != "zsh" ]; then
  sudo chsh -s "$(which zsh)" "$USER"
fi

if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
    "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

touch "$ZSHRC"

# Désactive le thème OMZ (Starship prend le relais)
if grep -q '^ZSH_THEME=' "$ZSHRC"; then
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME=""/' "$ZSHRC"
fi

# Décommente la ligne PATH ($HOME/.local/bin) si elle est commentée
sed -i 's/^# export PATH=\$HOME\/bin:\$HOME\/.local\/bin/export PATH=$HOME\/bin:$HOME\/.local\/bin/' "$ZSHRC"

# Plugins Oh My Zsh
DESIRED_PLUGINS=(git sudo kubectl docker docker-compose history-substring-search colored-man-pages command-not-found)
for p in "${DESIRED_PLUGINS[@]}"; do
  if ! grep -E "^plugins=\(.*\b${p}\b.*\)" "$ZSHRC" &>/dev/null; then
    if grep -E "^plugins=\(" "$ZSHRC" &>/dev/null; then
      sed -i -E "s/^plugins=\((.*)\)/plugins=(\1 ${p})/" "$ZSHRC"
    else
      echo "plugins=(${p})" >> "$ZSHRC"
    fi
  fi
done

# Bloc de customisation zsh
MARKER="# ===== Custom zsh additions ====="
if ! grep -qF "$MARKER" "$ZSHRC"; then
  cat >> "$ZSHRC" << 'EOF'

# ===== Custom zsh additions =====
HISTSIZE=50000
SAVEHIST=50000
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

command -v fzf    &>/dev/null && eval "$(fzf    --zsh)"
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"

alias k=kubectl
alias kgp='kubectl get pods'
alias kgn='kubectl get nodes'
alias kgs='kubectl get svc'
alias ll='ls -lah'
alias gs='git status'
alias gp='git pull'
alias gc='git commit -m'
alias cc=claude
ia() {
  local model
  model=$(ollama list 2>/dev/null | awk '/^qwen/{print $1}' | sort -V | tail -1)
  model="${model:-qwen3.6:35b}"
  echo "==> open-interpreter avec $model"
  interpreter --model "ollama/$model" -y "$@"
}

command -v fastfetch &>/dev/null && fastfetch

[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
# ===== Fin custom zsh additions =====
EOF
fi

# -------------------------------------------------------------
# 3. Police JetBrainsMono Nerd Font
# -------------------------------------------------------------
echo "━━━ [4/15] JetBrainsMono Nerd Font ━━━"
FONT_DIR="$HOME/.local/share/fonts"
mkdir -p "$FONT_DIR"
if ! fc-list | grep -qi "JetBrainsMono Nerd Font"; then
  curl -fLo /tmp/JetBrainsMono.zip \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
  unzip -o /tmp/JetBrainsMono.zip -d "$FONT_DIR" >/dev/null
  rm -f /tmp/JetBrainsMono.zip
  fc-cache -f "$FONT_DIR"
fi

# -------------------------------------------------------------
# 4. Starship prompt
# -------------------------------------------------------------
echo "━━━ [5/15] Starship ━━━"
if ! command -v starship &>/dev/null; then
  # --bin-dir évite le sudo interne de l'installeur (inutilisable sans TTY)
  mkdir -p "$HOME/.local/bin"
  curl -sS https://starship.rs/install.sh | sh -s -- -y --bin-dir "$HOME/.local/bin" || \
    { echo "  ==> Starship : installation échouée, skip."; true; }
fi
grep -qxF 'eval "$(starship init zsh)"' "$ZSHRC" || \
  echo 'eval "$(starship init zsh)"' >> "$ZSHRC"

# -------------------------------------------------------------
# 5. Thème terminal (Dracula)
# -------------------------------------------------------------
echo "━━━ [6/15] Thème Dracula ━━━"

# Capteurs température (commun)
sudo sensors-detect --auto >/dev/null 2>&1 || true

case "$DE" in
  kde)
    mkdir -p "$HOME/.local/share/konsole"
    TMP_DRACULA=$(mktemp -d)
    if git clone --depth 1 https://github.com/dracula/konsole.git "$TMP_DRACULA" -q 2>/dev/null; then
      cp "$TMP_DRACULA"/*.colorscheme "$HOME/.local/share/konsole/" 2>/dev/null || true
    else
      echo "  ==> Dracula Konsole : clone impossible, skip."
    fi
    rm -rf "$TMP_DRACULA"
    # Autostart Yakuake
    mkdir -p "$HOME/.config/autostart"
    YAKUAKE_DESKTOP=$(find /usr/share/applications -iname "*yakuake*.desktop" 2>/dev/null | head -n1)
    [ -n "${YAKUAKE_DESKTOP:-}" ] && cp "$YAKUAKE_DESKTOP" "$HOME/.config/autostart/"
    ;;
  gnome)
    # Dracula GTK theme
    if [ ! -d "$HOME/.themes/Dracula" ]; then
      mkdir -p "$HOME/.themes"
      TMP_DRACULA=$(mktemp -d)
      if git clone --depth 1 https://github.com/dracula/gtk.git "$TMP_DRACULA" -q 2>/dev/null; then
        cp -r "$TMP_DRACULA" "$HOME/.themes/Dracula"
      else
        echo "  ==> Dracula GTK : clone impossible, skip."
      fi
      rm -rf "$TMP_DRACULA"
    fi
    # Dracula couleurs Tilix
    mkdir -p "$HOME/.config/tilix/schemes"
    curl -fsSL https://raw.githubusercontent.com/dracula/tilix/master/Dracula.json \
      -o "$HOME/.config/tilix/schemes/Dracula.json" 2>/dev/null || true
    ;;
esac

# -------------------------------------------------------------
# 6. zoxide
# -------------------------------------------------------------
echo "━━━ [7/15] zoxide ━━━"
if ! command -v zoxide &>/dev/null; then
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash || \
    { echo "  ==> zoxide : installation échouée, skip."; true; }
fi

# -------------------------------------------------------------
# 7. Flatpak + ZapZap (WhatsApp) + Claude Code + Tailscale
# -------------------------------------------------------------
echo "━━━ [8/15] Apps (ZapZap, Claude Code, Tailscale) ━━━"

flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y --user flathub com.rtosta.zapzap

if ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash || \
    { echo "  ==> Claude Code : installation échouée, skip."; true; }
fi

if ! command -v tailscale &>/dev/null; then
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
    | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y tailscale
fi

# Bug connu Debian Trixie
[ ! -f /etc/default/tailscaled ] && echo 'PORT="41641"' | sudo tee /etc/default/tailscaled >/dev/null

sudo systemctl enable --now tailscaled

if tailscale status 2>&1 | grep -q "Logged out" || ! tailscale status &>/dev/null; then
  sudo tailscale up \
    --login-server="$TAILSCALE_SERVER" \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="$(hostname)" || \
    echo "  ==> Tailscale : authkey expirée — relancer : sudo tailscale up --login-server=$TAILSCALE_SERVER --authkey=<nouvelle-clé>"
fi

# -------------------------------------------------------------
# 8b. Ollama + qwen3.6:35b + aider
# -------------------------------------------------------------
echo "━━━ [8b/15] Ollama + qwen3.6:35b + aider ━━━"

if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh || \
    { echo "  ==> Ollama : installation échouée, skip."; true; }
fi

# QWEN_MODEL défini + réponse collectée au début du script
if ! ollama list 2>/dev/null | grep -q "$QWEN_MODEL"; then
  if [[ "$_install_qwen" =~ ^[Yy]$ ]]; then
    ollama pull "$QWEN_MODEL"
  else
    echo "==> Skipped (relancer plus tard : ollama pull $QWEN_MODEL)"
  fi
else
  echo "==> $QWEN_MODEL déjà présent."
fi

if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh || \
    { echo "  ==> uv : installation échouée, skip."; true; }
  export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v aider &>/dev/null; then
  uv tool install aider-chat --python 3.12
fi

AIDER_CONF="$HOME/.aider.conf.yml"
if [ ! -f "$AIDER_CONF" ]; then
  cat > "$AIDER_CONF" << 'EOF'
## Aider global configuration
model: ollama/qwen3.6:35b
openai-api-base: http://localhost:11434/v1
openai-api-key: ollama

show-model-warnings: false

git: true
gitignore: true

pretty: true
stream: true
EOF
fi

if ! command -v goose &>/dev/null; then
  curl -fsSL https://github.com/block/goose/releases/latest/download/download_cli.sh | bash || \
    { echo "  ==> Goose : installation échouée, skip."; true; }
fi

GOOSE_CONF="$HOME/.config/goose/config.yaml"
if [ ! -f "$GOOSE_CONF" ]; then
  mkdir -p "$HOME/.config/goose"
  cat > "$GOOSE_CONF" << 'EOF'
GOOSE_PROVIDER: ollama
GOOSE_MODEL: qwen3.6:35b
OLLAMA_CONTEXT_LENGTH: "32768"
EOF
fi

# -------------------------------------------------------------
# 8c. open-interpreter (optionnel)
# -------------------------------------------------------------
# Réponse open-interpreter collectée au début du script
if [[ "$_install_oi" =~ ^[Yy]$ ]]; then
  echo "━━━ [8c] open-interpreter ━━━"
  uv tool install open-interpreter --python 3.12
  echo "==> ok — alias disponible : ia  (interpreter --model ollama/$QWEN_MODEL -y)"
else
  echo "==> open-interpreter skipped (relancer plus tard : uv tool install open-interpreter)"
fi

# -------------------------------------------------------------
# 8d. Playwright (screenshots headless)
# -------------------------------------------------------------
echo "━━━ [9/15] Playwright + Chromium ━━━"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install playwright
  "$VENV/bin/playwright" install chromium
fi

# -------------------------------------------------------------
# 9. Claude Code settings (~/.claude/settings.json)
# -------------------------------------------------------------
echo "━━━ [10/15] Claude Code settings ━━━"
mkdir -p "$HOME/.claude"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

if [ -f "$CLAUDE_SETTINGS" ]; then
  python3 - "$CLAUDE_SETTINGS" <<'EOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault("env", {})["DISPLAY"] = ":0"
cfg.setdefault("permissions", {})["defaultMode"] = "dontAsk"
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("settings.json mis à jour")
EOF
else
  cat > "$CLAUDE_SETTINGS" << 'EOF'
{
  "theme": "auto",
  "env": { "DISPLAY": ":0" },
  "permissions": { "defaultMode": "dontAsk" }
}
EOF
fi

# -------------------------------------------------------------
# 10. Dossier wallpaper + image
# -------------------------------------------------------------
echo "━━━ [11/15] Wallpaper ━━━"
mkdir -p "$WALLPAPER_DIR"
if [ ! -f "$WALLPAPER_DIR/$WALLPAPER_IMAGE" ]; then
  curl -fLo "$WALLPAPER_DIR/$WALLPAPER_IMAGE" \
    "$GITHUB_RAW/wallpaper/$WALLPAPER_IMAGE" 2>/dev/null || \
    echo "  ==> Wallpaper non trouvé — placer $WALLPAPER_IMAGE dans $WALLPAPER_DIR/ manuellement."
fi

# -------------------------------------------------------------
# 11. Git SSH + clone rancher
# -------------------------------------------------------------
echo "━━━ [12/15] Git + clone rancher ━━━"
mkdir -p "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
  ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f "$HOME/.ssh/id_ed25519" -N ""
  echo ""
  echo "🔑 Ajoute cette clé publique sur GitHub avant de continuer :"
  echo "   https://github.com/settings/keys"
  echo ""
  cat "$HOME/.ssh/id_ed25519.pub"
  echo ""
  if [ -z "${MUXPC_DE:-}" ]; then
    read -r -p "Appuie sur Entrée une fois la clé ajoutée... "
  else
    echo "  ==> Mode non-interactif : ajoutez la clé GitHub ci-dessus manuellement, puis :"
    echo "      git clone git@github.com:muxflash/rancher.git $REPO_DIR"
  fi
fi

grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null || \
  ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

mkdir -p "$CLAUDE_DIR"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --quiet
elif [ -z "${MUXPC_DE:-}" ]; then
  git clone "$REPO_SSH" "$REPO_DIR"
else
  git clone "$REPO_SSH" "$REPO_DIR" 2>/dev/null || \
    echo "  ==> Clone rancher ignoré (clé SSH pas encore dans GitHub — à faire manuellement)"
fi

# -------------------------------------------------------------
# 12. Service systemd : Claude Code dans tmux au démarrage
# -------------------------------------------------------------
echo "━━━ [13/15] Service tmux Claude ━━━"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/claude-tmux.service"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_FILE" << 'EOF'
[Unit]
Description=Session tmux Claude Code au démarrage
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/tmux new-session -d -s claude -c %h claude
ExecStop=/usr/bin/tmux kill-session -t claude

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now claude-tmux.service 2>/dev/null || true

mkdir -p "$HOME/.config/autostart"
case "$DE" in
  kde)
    _term_exec='konsole --title "ClaudeTmux" -e bash -c '"'"'while ! tmux has-session -t claude 2>/dev/null; do sleep 0.5; done; exec tmux attach -t claude'"'"''
    ;;
  gnome)
    _term_exec='tilix --title "ClaudeTmux" -e bash -c '"'"'while ! tmux has-session -t claude 2>/dev/null; do sleep 0.5; done; exec tmux attach -t claude'"'"''
    ;;
esac
cat > "$HOME/.config/autostart/claude-tmux-attach.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Claude tmux (attach)
Exec=${_term_exec}
NoDisplay=true
EOF

# -------------------------------------------------------------
# 13. Fix veille NVIDIA + Wayland (NVreg_PreserveVideoMemoryAllocations)
# -------------------------------------------------------------
echo "━━━ [14/15] Fix veille NVIDIA Wayland ━━━"
# Sans cette option le driver NVIDIA 550 ne préserve pas la VRAM pendant la
# veille → au réveil kscreenlocker plante (nv_drm_revoke_modeset_permission),
# l'écran clignote et nécessite un Ctrl+Alt+F2 pour récupérer la session.
NVIDIA_OPTS=/etc/modprobe.d/nvidia-options.conf
if [ -f "$NVIDIA_OPTS" ]; then
  if grep -q "^#options nvidia-current NVreg_PreserveVideoMemoryAllocations=1" "$NVIDIA_OPTS"; then
    sudo sed -i 's/^#options nvidia-current NVreg_PreserveVideoMemoryAllocations=1/options nvidia-current NVreg_PreserveVideoMemoryAllocations=1/' "$NVIDIA_OPTS"
    echo "==> Option activée dans $NVIDIA_OPTS"
    sudo update-initramfs -u
  elif grep -q "^options nvidia-current NVreg_PreserveVideoMemoryAllocations=1" "$NVIDIA_OPTS"; then
    echo "==> NVreg_PreserveVideoMemoryAllocations déjà activé, skip."
  else
    echo "options nvidia-current NVreg_PreserveVideoMemoryAllocations=1" | sudo tee -a "$NVIDIA_OPTS" >/dev/null
    sudo update-initramfs -u
  fi
  sudo systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null || true
else
  echo "==> Pas de GPU NVIDIA détecté, skip."
fi

# -------------------------------------------------------------
# 14. Configuration du bureau
# -------------------------------------------------------------
echo "━━━ [15/15] Configuration bureau ($DE) ━━━"

case "$DE" in
# ── KDE Plasma ─────────────────────────────────────────────
  kde)
    # Icônes Papirus-Dark
    PLASMA_CHANGEICONS=$(find /usr/lib /usr/libexec -iname "plasma-changeicons" 2>/dev/null | head -n1)
    if [ -n "${PLASMA_CHANGEICONS:-}" ]; then
      "$PLASMA_CHANGEICONS" Papirus-Dark
    else
      kwriteconfig6 --file kdeglobals --group Icons --key Theme Papirus-Dark
      dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.iconChanged int32:0 2>/dev/null || true
    fi

    # 4 bureaux virtuels + transition Slide
    kwriteconfig6 --file kwinrc --group Desktops --key Number 4
    kwriteconfig6 --file kwinrc --group Plugins --key slideEnabled true
    dbus-send --session --dest=org.kde.KWin --type=method_call /KWin org.kde.KWin.reconfigure 2>/dev/null || true

    # Raccourcis : KRunner + navigation bureaux
    kwriteconfig6 --file kglobalshortcutsrc --group "org.kde.krunner.desktop" \
      --key _launch "Alt+Space,Alt+Space,Run Command"
    kwriteconfig6 --file kglobalshortcutsrc --group kwin \
      --key "Switch One Desktop to the Right" "Ctrl+Alt+Right,Ctrl+Alt+Right,Switch One Desktop to the Right"
    kwriteconfig6 --file kglobalshortcutsrc --group kwin \
      --key "Switch One Desktop to the Left" "Ctrl+Alt+Left,Ctrl+Alt+Left,Switch One Desktop to the Left"
    if command -v kquitapp6 &>/dev/null && command -v kglobalaccel6 &>/dev/null; then
      kquitapp6 kglobalaccel6 2>/dev/null || true
      (kglobalaccel6 &>/dev/null &)
      sleep 1
    fi

    # Panneaux Plasma (barre haut + dock bas + widgets monitoring)
    LAYOUT_JS=$(mktemp --suffix=.js)
    cat > "$LAYOUT_JS" << 'PLASMAEOF'
var existing = panels();
for (var i = 0; i < existing.length; i++) { existing[i].remove(); }

var topPanel = new Panel;
topPanel.location = 'top';
topPanel.height = 36;
topPanel.addWidget('org.kde.plasma.kickoff');
topPanel.addWidget('org.kde.plasma.panelspacer');
topPanel.addWidget('org.kde.plasma.digitalclock');
topPanel.addWidget('org.kde.plasma.panelspacer');
topPanel.addWidget('org.kde.plasma.pager');
topPanel.addWidget('org.kde.plasma.systemtray');

var dock = new Panel;
dock.location = 'bottom';
dock.height = 56;
dock.alignment = 'center';
dock.hiding = 'none';
dock.lengthMode = 'fit';
dock.addWidget('org.kde.plasma.icontasks');

var desktop = desktops()[0];
desktop.addWidget('org.kde.plasma.systemmonitor.cpu');
desktop.addWidget('org.kde.plasma.systemmonitor.memory');
desktop.addWidget('org.kde.plasma.systemmonitor.net');
PLASMAEOF

    dbus-send --session --print-reply --dest=org.kde.plasmashell --type=method_call \
      /PlasmaShell org.freedesktop.DBus.Properties.Set \
      string:org.kde.PlasmaShell string:editMode variant:boolean:true 2>/dev/null || true
    dbus-send --session --print-reply --dest=org.kde.plasmashell --type=method_call \
      /PlasmaShell org.kde.PlasmaShell.evaluateScript "string:$(cat "$LAYOUT_JS")" 2>/dev/null || true
    dbus-send --session --print-reply --dest=org.kde.plasmashell --type=method_call \
      /PlasmaShell org.freedesktop.DBus.Properties.Set \
      string:org.kde.PlasmaShell string:editMode variant:boolean:false 2>/dev/null || true
    rm -f "$LAYOUT_JS"

    # Slideshow fond d'écran
    SLIDE_JS=$(mktemp --suffix=.js)
    cat > "$SLIDE_JS" << SLIDEEOF
var allDesktops = desktops();
for (var i = 0; i < allDesktops.length; i++) {
    var d = allDesktops[i];
    d.wallpaperPlugin = 'org.kde.slideshow';
    d.currentConfigGroup = Array('Wallpaper', 'org.kde.slideshow', 'General');
    d.writeConfig('SlidePaths', ['$WALLPAPER_DIR']);
    d.writeConfig('SlideInterval', 300);
    d.writeConfig('FillMode', 1);
}
SLIDEEOF
    qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$(cat "$SLIDE_JS")" 2>/dev/null || \
    dbus-send --session --print-reply --dest=org.kde.plasmashell --type=method_call \
      /PlasmaShell org.kde.PlasmaShell.evaluateScript "string:$(cat "$SLIDE_JS")" 2>/dev/null || true
    rm -f "$SLIDE_JS"
    ;;

# ── GNOME ───────────────────────────────────────────────────
  gnome)
    GNOME_VER=$(gnome-shell --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)

    # Installe une extension GNOME depuis extensions.gnome.org
    install_gnome_ext() {
      local uuid="$1" ext_id="$2"
      if ! gnome-extensions list 2>/dev/null | grep -qF "$uuid"; then
        echo "  ==> Extension $uuid..."
        local info url
        info=$(curl -s "https://extensions.gnome.org/extension-info/?pk=${ext_id}&shell_version=${GNOME_VER}" 2>/dev/null || true)
        url=$(echo "$info" | python3 -c \
          "import json,sys; d=json.load(sys.stdin); print('https://extensions.gnome.org'+d['download_url'])" 2>/dev/null || true)
        if [ -n "${url:-}" ]; then
          curl -fLo /tmp/_gnome_ext.zip "$url" 2>/dev/null
          gnome-extensions install /tmp/_gnome_ext.zip --force 2>/dev/null || true
          gnome-extensions enable "$uuid" 2>/dev/null || true
          rm -f /tmp/_gnome_ext.zip
        else
          echo "  ==> $uuid : pas de version pour GNOME $GNOME_VER, skip."
        fi
      else
        echo "  ==> $uuid déjà installée."
      fi
    }

    # Extensions ergonomiques & visuelles
    install_gnome_ext "dash-to-dock@micxgx.gmail.com"             307   # dock auto-masqué
    install_gnome_ext "blur-my-shell@aunetx"                      3193  # flou overview/panel
    install_gnome_ext "user-theme@gnome-shell-extensions.gcampax.github.com" 19 # thèmes shell
    install_gnome_ext "caffeine@patapon.info"                     517   # anti-veille manuelle
    install_gnome_ext "clipboard-indicator@tudmotu.com"           779   # historique presse-papier
    install_gnome_ext "just-perfection-desktop@just-perfection"   3843  # masquer éléments superflus

    # Thème et icônes
    gsettings set org.gnome.desktop.interface color-scheme      'prefer-dark' || true
    gsettings set org.gnome.desktop.interface gtk-theme         'Dracula' || true
    gsettings set org.gnome.desktop.interface icon-theme        'Papirus-Dark' || true
    gsettings set org.gnome.desktop.interface cursor-theme      'Adwaita' || true
    gsettings set org.gnome.desktop.interface font-name         'Cantarell 11' || true
    gsettings set org.gnome.desktop.interface monospace-font-name 'JetBrainsMono Nerd Font 11' || true
    gsettings set org.gnome.shell.extensions.user-theme name    'Dracula' 2>/dev/null || true

    # Fond d'écran
    gsettings set org.gnome.desktop.background picture-uri      "file://$WALLPAPER_DIR/$WALLPAPER_IMAGE" || true
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALLPAPER_DIR/$WALLPAPER_IMAGE" || true
    gsettings set org.gnome.desktop.background picture-options  'zoom' || true
    gsettings set org.gnome.desktop.screensaver picture-uri     "file://$WALLPAPER_DIR/$WALLPAPER_IMAGE" || true

    # Ergonomie fenêtres
    gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close' || true
    gsettings set org.gnome.desktop.wm.preferences num-workspaces 4 || true
    gsettings set org.gnome.mutter dynamic-workspaces false || true
    gsettings set org.gnome.desktop.interface enable-hot-corners false || true

    # Horloge + calendrier
    gsettings set org.gnome.desktop.interface clock-show-weekday true || true
    gsettings set org.gnome.desktop.interface clock-show-seconds false || true
    gsettings set org.gnome.desktop.calendar show-weekdate true || true

    # Night Light (21h–7h, 3500 K)
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled           true || true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false || true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-from     21.0 || true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-to        7.0 || true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature       3500 || true

    # Raccourcis navigation bureaux (comme KDE)
    gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-left   "['<Control><Alt>Left']" || true
    gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-right  "['<Control><Alt>Right']" || true
    gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-left     "['<Control><Shift><Alt>Left']" || true
    gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-right    "['<Control><Shift><Alt>Right']" || true
    # Fermer fenêtre + plein écran
    gsettings set org.gnome.desktop.wm.keybindings close              "['<Super>q']" || true
    gsettings set org.gnome.desktop.wm.keybindings toggle-fullscreen  "['<Super>f']" || true

    # Dash-to-dock : dock bas auto-masqué, style plat
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-position  'BOTTOM'  2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock autohide        true      2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock intellihide     true      2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed      false     2>/dev/null || true
    gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 42     2>/dev/null || true

    # Just Perfection : masquer activités + simplifier barre
    gsettings set org.gnome.shell.extensions.just-perfection activities-button false 2>/dev/null || true
    gsettings set org.gnome.shell.extensions.just-perfection window-demands-attention-focus true 2>/dev/null || true
    ;;
esac

# -------------------------------------------------------------
# 15. Thunderbird — compte laurent@billot.net (mail.billot.net / Stalwart)
# -------------------------------------------------------------
echo "━━━ [16/17] Thunderbird (laurent@billot.net) ━━━"

sudo DEBIAN_FRONTEND=noninteractive apt install -y thunderbird

# Profil Thunderbird : pré-configure IMAP + SMTP via autoconfig
TB_PROFILE_DIR=$(find "$HOME/.thunderbird" -maxdepth 1 -name "*.default-release" 2>/dev/null | head -n1)
if [ -z "${TB_PROFILE_DIR:-}" ]; then
  # Premier lancement silencieux pour créer le profil
  timeout 5 thunderbird --headless 2>/dev/null || true
  TB_PROFILE_DIR=$(find "$HOME/.thunderbird" -maxdepth 1 -name "*.default-release" 2>/dev/null | head -n1)
fi

if [ -n "${TB_PROFILE_DIR:-}" ]; then
  # Prefs : compte IMAP + SMTP mail.billot.net / SSL
  PREFS="$TB_PROFILE_DIR/prefs.js"
  TB_ACCOUNT_SET=false
  [ -f "$PREFS" ] && grep -q "mail.billot.net" "$PREFS" && TB_ACCOUNT_SET=true

  if ! $TB_ACCOUNT_SET; then
    cat >> "$PREFS" << 'TBPREFS'
// Compte IMAP laurent@billot.net
user_pref("mail.account.account1.identities", "id1");
user_pref("mail.account.account1.server", "server1");
user_pref("mail.accountmanager.accounts", "account1");
user_pref("mail.accountmanager.defaultaccount", "account1");
user_pref("mail.identity.id1.fullName", "Laurent Billot");
user_pref("mail.identity.id1.useremail", "laurent@billot.net");
user_pref("mail.identity.id1.valid", true);
user_pref("mail.server.server1.hostname", "mail.billot.net");
user_pref("mail.server.server1.login_at_startup", true);
user_pref("mail.server.server1.name", "laurent@billot.net");
user_pref("mail.server.server1.port", 993);
user_pref("mail.server.server1.socketType", 3);
user_pref("mail.server.server1.type", "imap");
user_pref("mail.server.server1.userName", "laurent@billot.net");
user_pref("mail.smtpserver.smtp1.authMethod", 3);
user_pref("mail.smtpserver.smtp1.hostname", "mail.billot.net");
user_pref("mail.smtpserver.smtp1.port", 465);
user_pref("mail.smtpserver.smtp1.socketType", 3);
user_pref("mail.smtpserver.smtp1.username", "laurent@billot.net");
user_pref("mail.smtpservers", "smtp1");
user_pref("mail.identity.id1.smtpServer", "smtp1");
TBPREFS
    echo "  ==> Compte IMAP/SMTP mail.billot.net configuré dans Thunderbird."
  else
    echo "  ==> Compte Thunderbird déjà configuré, skip."
  fi
fi

# -------------------------------------------------------------
# 16. Lutris + Steam (gaming)
# -------------------------------------------------------------
echo "━━━ [17/17] Lutris + Steam ━━━"

# Activer l'architecture i386 (requis pour Steam)
sudo dpkg --add-architecture i386
sudo apt update -q

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  steam-installer \
  lutris \
  gamemode \
  libgamemode0:i386 2>/dev/null || \
sudo DEBIAN_FRONTEND=noninteractive apt install -y steam-installer lutris gamemode

# Mangohud (overlay FPS/VRAM/CPU/GPU en jeu)
if ! command -v mangohud &>/dev/null; then
  if apt-cache show mangohud &>/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt install -y mangohud
  fi
fi

# Proton-GE (meilleure compat Windows via Lutris/Steam)
PROTON_GE_DIR="$HOME/.steam/root/compatibilitytools.d"
if [ ! -d "$PROTON_GE_DIR" ]; then
  mkdir -p "$PROTON_GE_DIR"
fi
if [ -z "$(ls -A "$PROTON_GE_DIR" 2>/dev/null)" ]; then
  echo "  ==> Téléchargement Proton-GE dernière version..."
  PROTON_URL=$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
    | python3 -c "import json,sys; r=json.load(sys.stdin); print(next(a['browser_download_url'] for a in r['assets'] if a['name'].endswith('.tar.gz')))" 2>/dev/null || true)
  if [ -n "${PROTON_URL:-}" ]; then
    curl -fLo /tmp/proton-ge.tar.gz "$PROTON_URL" 2>/dev/null
    tar -xzf /tmp/proton-ge.tar.gz -C "$PROTON_GE_DIR"
    rm -f /tmp/proton-ge.tar.gz
    echo "  ==> Proton-GE installé dans $PROTON_GE_DIR"
  else
    echo "  ==> Proton-GE : téléchargement impossible, skip."
  fi
fi

# =============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Installation terminée !  (redémarrage requis)       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "🔑 Première utilisation Claude Code : 'claude' dans le terminal"
echo "   (authentification navigateur la première fois)"
echo ""

case "$DE" in
  kde)
    echo "📺 Au prochain démarrage KDE : Konsole 'ClaudeTmux' s'ouvre auto"
    echo "   et s'attache à la session tmux claude."
    echo ""
    echo "🔧 Étapes manuelles restantes (GUI uniquement) :"
    echo "   1. Système → Apparence → Thème global → installer 'Dracula'"
    echo "   2. Konsole/Yakuake : Paramètres → Profil → Apparence → 'Dracula'"
    echo "   3. KWin Scripts → installer 'Polonium' (tiling 3 colonnes)"
    echo "   4. Fenêtre ClaudeTmux : clic droit barre de titre → Bureau 2 + Plein écran"
    ;;
  gnome)
    echo "📺 Au prochain démarrage GNOME : Tilix 'ClaudeTmux' s'ouvre auto"
    echo "   et s'attache à la session tmux claude."
    echo ""
    echo "🔧 Étapes manuelles restantes (GUI uniquement) :"
    echo "   1. Gnome Tweaks → Appearance → Shell theme → 'Dracula'"
    echo "   2. Tilix : Préférences → Profil → Couleurs → schéma 'Dracula'"
    echo "   3. Extensions → activer dash-to-dock, blur-my-shell, user-themes, caffeine"
    echo "   4. Fenêtre ClaudeTmux : déplacer sur le bureau 2 + plein écran"
    ;;
esac

echo ""
echo "📧 Thunderbird : saisir le mot de passe IMAP au premier lancement"
echo "   Serveur : mail.billot.net  IMAP:993/SSL  SMTP:465/SSL"
echo ""
echo "🎮 Gaming : Steam + Lutris installés. Proton-GE dans ~/.steam/root/compatibilitytools.d"
echo "   Activer Proton-GE dans Steam : Paramètres → Compatibilité → outil de compatibilité"
echo ""
echo "💡 Ouvre un NOUVEAU terminal pour zsh + Starship + fastfetch."
