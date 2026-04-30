#!/bin/bash
# =============================================================================
# Setup Completo — AI Server (Oracle VPS 4 OCPU / 24GB RAM)
# Modelos: Qwen2.5-Coder:7B (Ollama) + Qwen3.6-35B-A3B Q4 (llama.cpp)
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
info()   { echo -e "${BLUE}[i]${NC} $1"; }
header() { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

# ─── Verifica root ───────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[✗] Execute como root: sudo bash setup.sh${NC}"
  exit 1
fi

INSTALL_DIR="/opt/ai-server"
DATA_DIR="/opt/ai-data"
MODELS_DIR="/opt/ai-models"

header "1/7 — Atualizando sistema e dependências"
# Aguarda lock do apt ser liberado
wait_apt() {
  while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    warn "apt bloqueado por outro processo, aguardando 5s..."
    sleep 5
  done
}

wait_apt
apt-get update -y && apt-get upgrade -y

wait_apt
apt-get install -y \
  curl wget git build-essential cmake \
  nginx certbot python3-certbot-nginx \
  nodejs npm \
  htop tmux ufw \
  python3 python3-pip python3-venv \
  libssl-dev libffi-dev ca-certificates gnupg lsb-release

# ── Docker CE (repositório oficial — evita conflito com containerd) ───────────
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  # Remove conflitos antes de instalar
  apt-get remove -y containerd containerd.io docker.io 2>/dev/null || true
  wait_apt
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  log "Docker CE instalado"
else
  warn "Docker já instalado — pulando"
fi

# Instala docker-compose standalone (compatibilidade com docker-compose.yml v2)
if ! command -v docker-compose &>/dev/null; then
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# Habilita Docker
systemctl enable docker && systemctl start docker
log "Sistema e dependências instalados"

# ─── Diretórios ──────────────────────────────────────────────────────────────
header "2/7 — Criando estrutura de diretórios"
mkdir -p $INSTALL_DIR $DATA_DIR $MODELS_DIR
mkdir -p $DATA_DIR/{open-webui,ollama,mcp-logs}
mkdir -p $INSTALL_DIR/{nginx,mcp,scripts}
log "Diretórios criados em $INSTALL_DIR"

# ─── Copia arquivos de configuração ──────────────────────────────────────────
cp -r "$(dirname "$0")"/* $INSTALL_DIR/
chmod +x $INSTALL_DIR/scripts/*.sh 2>/dev/null || true

# ─── Firewall ────────────────────────────────────────────────────────────────
header "3/7 — Configurando Firewall (UFW)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp    # HTTP (Nginx)
ufw allow 443/tcp   # HTTPS (Nginx)
# Portas internas — bloqueadas externamente, acessíveis via Nginx
ufw --force enable
log "Firewall configurado — apenas SSH, 80 e 443 expostos"
warn "ATENÇÃO: Libere também as portas no Security List da Oracle Cloud!"

# ─── Ollama ──────────────────────────────────────────────────────────────────
header "4/7 — Instalando Ollama"
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
  log "Ollama instalado"
else
  warn "Ollama já instalado — pulando"
fi

# Configura Ollama para escutar apenas localmente
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
EOF

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama
sleep 3

log "Baixando Qwen2.5-Coder:7B... (isso pode demorar)"
ollama pull qwen2.5-coder:7b
ollama pull nomic-embed-text  # Para embeddings/RAG
log "Modelos Ollama prontos"

# ─── llama.cpp ───────────────────────────────────────────────────────────────
header "5/7 — Compilando llama.cpp"
if [ ! -d "/opt/llama.cpp" ]; then
  git clone https://github.com/ggerganov/llama.cpp /opt/llama.cpp
fi

cd /opt/llama.cpp
git pull
cmake -B build -DGGML_CUDA=OFF -DGGML_NATIVE=ON -DLLAMA_BUILD_SERVER=ON
cmake --build build --config Release -j$(nproc)
log "llama.cpp compilado"

# ─── Download Qwen3.6-35B-A3B Q4 ─────────────────────────────────────────────
header "6/7 — Baixando Qwen3.6-35B-A3B Q4 (llama.cpp)"
python3 -m venv /opt/hf-venv --system-site-packages
/opt/hf-venv/bin/pip install --quiet --upgrade huggingface_hub

info "Iniciando download do Qwen3.6-35B-A3B Q4_K_M (~22GB)..."
warn "Este download pode levar 30-60 minutos dependendo da banda"

/opt/hf-venv/bin/python3 << 'PYEOF'
from huggingface_hub import hf_hub_download
import os

model_dir = "/opt/ai-models/qwen3.6-35b"
os.makedirs(model_dir, exist_ok=True)

print("Baixando Qwen3.6-35B-A3B Q4_K_M (~22GB)...")
path = hf_hub_download(
    repo_id="unsloth/Qwen3.6-35B-A3B-GGUF",
    filename="Qwen3.6-35B-A3B-Q4_K_M.gguf",
    local_dir=model_dir,
    resume_download=True
)
print(f"Modelo salvo em: {path}")
PYEOF

log "Qwen3.6-35B-A3B Q4 baixado"

# ─── Serviços systemd ─────────────────────────────────────────────────────────
header "7/7 — Criando serviços systemd"

# Serviço llama.cpp server para Qwen3.6
cat > /etc/systemd/system/llamacpp-qwen36.service << 'EOF'
[Unit]
Description=llama.cpp Server — Qwen3.6-35B-A3B
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --model /opt/ai-models/qwen3.6-35b/Qwen3.6-35B-A3B-Q4_K_M.gguf \
  --host 127.0.0.1 \
  --port 8081 \
  --ctx-size 16384 \
  --n-predict 4096 \
  --threads 4 \
  --batch-size 512 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --alias qwen3.6-35b-a3b \
  --log-disable
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable llamacpp-qwen36

log "Serviço llama.cpp criado (start manual após configurar Nginx)"

# ─── Docker Compose (Open WebUI) ─────────────────────────────────────────────
cd $INSTALL_DIR
docker-compose up -d
log "Open WebUI iniciado"

# ─── Nginx ───────────────────────────────────────────────────────────────────
cp $INSTALL_DIR/nginx/ai-server.conf /etc/nginx/sites-available/ai-server
ln -sf /etc/nginx/sites-available/ai-server /etc/nginx/sites-enabled/ai-server
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
log "Nginx configurado"

# ─── MCP Servers ─────────────────────────────────────────────────────────────
npm install -g \
  @modelcontextprotocol/server-filesystem \
  @modelcontextprotocol/server-git \
  @modelcontextprotocol/server-fetch \
  @modelcontextprotocol/server-memory

log "MCP Servers instalados globalmente"

# ─── Resumo ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           SETUP CONCLUÍDO COM SUCESSO            ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  Open WebUI     → http://SEU_IP (porta 80)      ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Ollama API     → http://127.0.0.1:11434        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Qwen3.6 API   → http://127.0.0.1:8081         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Logs WebUI     → docker-compose logs -f        ${CYAN}║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  Próximo passo: configurar domínio + SSL         ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  bash /opt/ai-server/scripts/ssl.sh seu.dominio  ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
warn "Inicie o Qwen3.6 manualmente: systemctl start llamacpp-qwen36"
warn "Monitore RAM antes: free -h (precisa de ~20GB livres)"
