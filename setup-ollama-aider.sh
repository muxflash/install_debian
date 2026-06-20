#!/usr/bin/env bash
set -e

echo "==> Installation Ollama"
curl -fsSL https://ollama.com/install.sh | sh

echo "==> Téléchargement du modèle qwen3.6:35b (~23 GB)"
ollama pull qwen3.6:35b

echo "==> Installation de uv (gestionnaire de paquets Python)"
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

echo "==> Installation de aider (Python 3.12 via uv)"
uv tool install aider-chat --python 3.12

echo "==> Configuration de aider (~/.aider.conf.yml)"
cat > ~/.aider.conf.yml << 'EOF'
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

echo "==> Ajout de ~/.local/bin au PATH dans .zshrc"
if ! grep -q '.local/bin' ~/.zshrc; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
fi

echo ""
echo "==> Installation terminée !"
echo "    Utilisation : cd mon-projet && aider"
