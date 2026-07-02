#!/usr/bin/env bash
# =============================================================
# install.sh — Post-install KDE + Debian (poste muxflash)
# Usage : bash install.sh
# Idempotent : peut être relancé sans dupliquer quoi que ce soit
# =============================================================
set -euo pipefail

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
TAILSCALE_AUTHKEY="hskey-auth-KvGB3jXeQhXT-wtQzRFALXCN-p5suT1fDnskW7X7QPV3eYq03bmN5fFdf_thnrXGpKvIr7x4xOcxE"
TAILSCALE_SERVER="https://vpn.billot.net:8090"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        Post-install muxflash — KDE + Debian              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# -------------------------------------------------------------
# 0. Dépôts non-free + drivers NVIDIA + GRUB
# -------------------------------------------------------------
echo "━━━ [0/15] Dépôts non-free + NVIDIA + GRUB ━━━"

# Activation des dépôts contrib non-free non-free-firmware
SOURCES=/etc/apt/sources.list
if ! grep -q "non-free-firmware" "$SOURCES"; then
  echo "==> Activation de contrib non-free non-free-firmware dans $SOURCES..."
  sudo sed -i 's/^\(deb .*debian\.org\/debian[^#]*main\)\(.*\)$/\1 contrib non-free non-free-firmware/' "$SOURCES"
  sudo apt update
fi

# Paramètre GRUB : nvidia-drm.modeset=1 (requis pour KDE Wayland + NVIDIA)
GRUB_FILE=/etc/default/grub
if ! grep -q "nvidia-drm.modeset=1" "$GRUB_FILE"; then
  echo "==> Ajout de nvidia-drm.modeset=1 dans GRUB_CMDLINE_LINUX_DEFAULT..."
  sudo sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' "$GRUB_FILE"
  sudo update-grub
else
  echo "==> nvidia-drm.modeset=1 déjà présent dans GRUB, skip."
fi

# Installation des drivers NVIDIA non-free
if ! dpkg -l nvidia-driver &>/dev/null; then
  echo "==> Installation des drivers NVIDIA (nvidia-driver + firmware)..."
  sudo apt install -y nvidia-driver firmware-nvidia-graphics
else
  echo "==> Drivers NVIDIA déjà installés ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo '?')), skip."
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
sudo apt install -y \
  git curl unzip wget zip rsync screen \
  vim vlc \
  plocate \
  zsh \
  yakuake btop fastfetch kdeconnect filelight lm-sensors \
  plasma-systemmonitor \
  papirus-icon-theme \
  zsh-autosuggestions zsh-syntax-highlighting fzf \
  flatpak \
  python3-pip python3-venv \
  tmux

# fastfetch fallback (vieille version Debian)
if ! command -v fastfetch &>/dev/null; then
  echo "==> fastfetch absent des dépôts, installation via le .deb officiel..."
  ARCH=$(dpkg --print-architecture)
  FASTFETCH_URL=$(curl -s https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
    | grep "browser_download_url.*${ARCH}.*\.deb" | head -n1 | cut -d '"' -f4) || true
  if [ -n "${FASTFETCH_URL:-}" ]; then
    curl -fLo /tmp/fastfetch.deb "$FASTFETCH_URL"
    sudo apt install -y /tmp/fastfetch.deb
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
alias ia='interpreter --model ollama/qwen3.6:35b -y'

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
  curl -sS https://starship.rs/install.sh | sh -s -- -y
fi
grep -qxF 'eval "$(starship init zsh)"' "$ZSHRC" || \
  echo 'eval "$(starship init zsh)"' >> "$ZSHRC"

# -------------------------------------------------------------
# 5. Thème Dracula Konsole/Yakuake
# -------------------------------------------------------------
echo "━━━ [6/15] Thème Dracula Konsole ━━━"
mkdir -p "$HOME/.local/share/konsole"
TMP_DRACULA=$(mktemp -d)
git clone --depth 1 https://github.com/dracula/konsole.git "$TMP_DRACULA" -q
cp "$TMP_DRACULA"/*.colorscheme "$HOME/.local/share/konsole/"
rm -rf "$TMP_DRACULA"

# Autostart Yakuake
mkdir -p "$HOME/.config/autostart"
YAKUAKE_DESKTOP=$(find /usr/share/applications -iname "*yakuake*.desktop" 2>/dev/null | head -n1)
[ -n "${YAKUAKE_DESKTOP:-}" ] && cp "$YAKUAKE_DESKTOP" "$HOME/.config/autostart/"

# Capteurs température
sudo sensors-detect --auto >/dev/null 2>&1 || true

# -------------------------------------------------------------
# 6. zoxide
# -------------------------------------------------------------
echo "━━━ [7/15] zoxide ━━━"
if ! command -v zoxide &>/dev/null; then
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
fi

# -------------------------------------------------------------
# 7. Flatpak + ZapZap (WhatsApp) + Claude Code + Tailscale
# -------------------------------------------------------------
echo "━━━ [8/15] Apps (ZapZap, Claude Code, Tailscale) ━━━"

flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y --user flathub com.rtosta.zapzap

if ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

if ! command -v tailscale &>/dev/null; then
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
    | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  sudo apt update && sudo apt install -y tailscale
fi

# Bug connu Debian Trixie
[ ! -f /etc/default/tailscaled ] && echo 'PORT="41641"' | sudo tee /etc/default/tailscaled >/dev/null

sudo systemctl enable --now tailscaled

if tailscale status 2>&1 | grep -q "Logged out" || ! tailscale status &>/dev/null; then
  sudo tailscale up \
    --login-server="$TAILSCALE_SERVER" \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="$(hostname)"
fi

# -------------------------------------------------------------
# 8b. Ollama + qwen3.6:35b + aider
# -------------------------------------------------------------
echo "━━━ [8b/15] Ollama + qwen3.6:35b + aider ━━━"

if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

# Dernière version connue — mettre à jour si nouveau modèle disponible
QWEN_MODEL="qwen3.6:35b"
if ! ollama list 2>/dev/null | grep -q "$QWEN_MODEL"; then
  echo ""
  read -rp "==> Télécharger $QWEN_MODEL (~23 GB) ? [y/N] " _qw
  if [[ "$_qw" =~ ^[Yy]$ ]]; then
    ollama pull "$QWEN_MODEL"
  else
    echo "==> Skipped (relancer plus tard : ollama pull $QWEN_MODEL)"
  fi
else
  echo "==> $QWEN_MODEL déjà présent."
fi

if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
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
  curl -fsSL https://github.com/block/goose/releases/latest/download/download_cli.sh | bash
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
echo ""
read -rp "==> Installer open-interpreter ? [y/N] " _oi
if [[ "$_oi" =~ ^[Yy]$ ]]; then
  echo "━━━ [8c] open-interpreter ━━━"
  uv tool install open-interpreter --python 3.12
  echo "==> ok — alias disponible : ia  (interpreter --model ollama/$QWEN_MODEL -y)"
else
  echo "==> Skipped (relancer plus tard : uv tool install open-interpreter)"
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
    "$GITHUB_RAW/wallpaper/$WALLPAPER_IMAGE"
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
  read -r -p "Appuie sur Entrée une fois la clé ajoutée... "
fi

grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null || \
  ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

mkdir -p "$CLAUDE_DIR"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --quiet
else
  git clone "$REPO_SSH" "$REPO_DIR"
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

systemctl --user daemon-reload
systemctl --user enable --now claude-tmux.service

mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/claude-tmux-attach.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Claude tmux (attach)
Exec=konsole --title "ClaudeTmux" -e bash -c 'while ! tmux has-session -t claude 2>/dev/null; do sleep 0.5; done; exec tmux attach -t claude'
X-KDE-autostart-after=panel
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
# 14. KDE : icônes, panneaux, raccourcis, slideshow
# -------------------------------------------------------------
echo "━━━ [15/15] KDE layout + raccourcis + wallpaper slideshow ━━━"

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

# -------------------------------------------------------------
# 15. KMail — compte laurent@billot.net (Stalwart)
# -------------------------------------------------------------
echo "━━━ [16/16] KMail config (laurent@billot.net) ━━━"
KMAIL_SRC="$REPO_DIR/muxpc/kmail"

cp "$KMAIL_SRC/akonadi_imap_resource_0rc" "$HOME/.config/akonadi_imap_resource_0rc"
cp "$KMAIL_SRC/mailtransports"            "$HOME/.config/mailtransports"

# kmail2rc : copie seulement si absent (pour ne pas écraser une config existante)
if [ ! -f "$HOME/.config/kmail2rc" ]; then
  cp "$KMAIL_SRC/kmail2rc" "$HOME/.config/kmail2rc"
fi

# Enregistre la ressource IMAP dans Akonadi si pas déjà présente
AGENTSRC="$HOME/.config/akonadi/agentsrc"
if [ -f "$AGENTSRC" ] && ! grep -q "akonadi_imap_resource_0" "$AGENTSRC"; then
  sed -i 's/akonadi_imap_resource\\InstanceCounter=0/akonadi_imap_resource\\InstanceCounter=1/' "$AGENTSRC"
  sed -i '/akonadi_indexing_agent\\AgentType/i akonadi_imap_resource_0\\AgentType=akonadi_imap_resource' "$AGENTSRC"
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
echo "📺 Au prochain démarrage KDE : Konsole 'ClaudeTmux' s'ouvre auto"
echo "   et s'attache à la session tmux claude."
echo ""
echo "🔧 Étapes manuelles restantes (GUI uniquement) :"
echo "   1. Système → Apparence → Thème global → installer 'Dracula'"
echo "   2. Konsole/Yakuake : Paramètres → Profil → Apparence → 'Dracula'"
echo "   3. KWin Scripts → installer 'Polonium' (tiling 3 colonnes)"
echo "   4. Fenêtre ClaudeTmux : clic droit barre de titre → Bureau 2 + Plein écran"
echo ""
echo "💡 Ouvre un NOUVEAU terminal pour zsh + Starship + fastfetch."
