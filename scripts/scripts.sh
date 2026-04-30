#!/bin/bash
# =============================================================================
# Scripts utilitários para gerenciar os modelos de IA
# =============================================================================

# ── Cores ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# =============================================================================
# status — Mostra estado de todos os serviços
# =============================================================================
status() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Status dos Serviços de IA${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # RAM
    TOTAL=$(free -h | awk '/^Mem:/{print $2}')
    USED=$(free -h  | awk '/^Mem:/{print $3}')
    FREE=$(free -h  | awk '/^Mem:/{print $4}')
    echo -e "  💾 RAM: ${USED} usados / ${TOTAL} total (${FREE} livre)"

    # Ollama
    if systemctl is-active --quiet ollama; then
        echo -e "  ${GREEN}● Ollama${NC}       → ativo  (porta 11434)"
    else
        echo -e "  ${RED}● Ollama${NC}       → inativo"
    fi

    # Qwen3.6 llama.cpp
    if systemctl is-active --quiet llamacpp-qwen36; then
        echo -e "  ${GREEN}● Qwen3.6 35B${NC}  → ativo  (porta 8081)"
    else
        echo -e "  ${YELLOW}● Qwen3.6 35B${NC}  → inativo (use: systemctl start llamacpp-qwen36)"
    fi

    # Open WebUI
    if docker ps --format '{{.Names}}' | grep -q open-webui; then
        echo -e "  ${GREEN}● Open WebUI${NC}   → ativo  (porta 3000)"
    else
        echo -e "  ${RED}● Open WebUI${NC}   → inativo"
    fi

    # Nginx
    if systemctl is-active --quiet nginx; then
        echo -e "  ${GREEN}● Nginx${NC}        → ativo  (porta 80/443)"
    else
        echo -e "  ${RED}● Nginx${NC}        → inativo"
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# =============================================================================
# start-qwen36 — Inicia o modelo pesado verificando RAM disponível
# =============================================================================
start_qwen36() {
    info "Verificando memória disponível..."
    FREE_GB=$(free -g | awk '/^Mem:/{print $4}')

    if [ "$FREE_GB" -lt 18 ]; then
        warn "RAM livre: ${FREE_GB}GB — mínimo recomendado é 18GB"
        warn "Considere parar outros processos antes de iniciar o Qwen3.6"
        read -p "Continuar mesmo assim? [s/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Ss]$ ]] && exit 1
    fi

    log "RAM livre: ${FREE_GB}GB — iniciando Qwen3.6..."
    systemctl start llamacpp-qwen36
    sleep 5

    if systemctl is-active --quiet llamacpp-qwen36; then
        log "Qwen3.6-35B-A3B iniciado com sucesso!"
        info "Endpoint: http://127.0.0.1:8081/v1"
        info "Compatível com OpenAI SDK — use model='qwen3.6-35b-a3b'"
    else
        echo -e "${RED}[✗] Falha ao iniciar. Verifique os logs:${NC}"
        journalctl -u llamacpp-qwen36 -n 30 --no-pager
    fi
}

# =============================================================================
# stop-qwen36 — Para o modelo pesado e libera RAM
# =============================================================================
stop_qwen36() {
    systemctl stop llamacpp-qwen36
    log "Qwen3.6 parado — RAM liberada"
    status
}

# =============================================================================
# test-models — Testa os dois modelos com uma pergunta simples
# =============================================================================
test_models() {
    echo -e "\n${CYAN}Testando Qwen2.5-Coder 7B (Ollama)...${NC}"
    RESP=$(curl -s http://127.0.0.1:11434/api/generate \
        -d '{"model":"qwen2.5-coder:7b","prompt":"Olá! Responda apenas: funcionando","stream":false}' \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('response','ERRO'))" 2>/dev/null)
    echo -e "  Resposta: ${GREEN}${RESP}${NC}"

    if systemctl is-active --quiet llamacpp-qwen36; then
        echo -e "\n${CYAN}Testando Qwen3.6-35B-A3B (llama.cpp)...${NC}"
        RESP2=$(curl -s http://127.0.0.1:8081/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d '{"model":"qwen3.6-35b-a3b","messages":[{"role":"user","content":"Responda apenas: funcionando"}],"max_tokens":10}' \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)
        echo -e "  Resposta: ${GREEN}${RESP2}${NC}"
    else
        warn "Qwen3.6 não está rodando — use: bash scripts.sh start-qwen36"
    fi
}

# =============================================================================
# ssl — Configura SSL com Certbot
# =============================================================================
setup_ssl() {
    DOMAIN="$1"
    EMAIL="$2"

    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
        echo "Uso: bash scripts.sh ssl seu.dominio.com seu@email.com"
        exit 1
    fi

    # Substitui domínio no Nginx
    sed -i "s/seu.dominio.com/${DOMAIN}/g" /etc/nginx/sites-available/ai-server
    nginx -t && systemctl reload nginx

    # Certbot
    certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive
    log "SSL configurado para ${DOMAIN}"

    # Remove bloco de acesso por IP (já tem HTTPS)
    info "Remova o bloco 'default_server' do nginx/ai-server.conf se desejar"
}

# =============================================================================
# add-user — Adiciona usuário para autenticação básica da API
# =============================================================================
add_user() {
    USER="$1"
    if [ -z "$USER" ]; then
        echo "Uso: bash scripts.sh add-user nome-do-usuario"
        exit 1
    fi
    apt-get install -y apache2-utils -qq
    htpasswd -c /etc/nginx/.htpasswd "$USER"
    nginx -t && systemctl reload nginx
    log "Usuário '${USER}' adicionado para acesso à API"
}

# =============================================================================
# logs — Mostra logs de um serviço
# =============================================================================
show_logs() {
    case "$1" in
        ollama)   journalctl -u ollama -f ;;
        qwen36)   journalctl -u llamacpp-qwen36 -f ;;
        webui)    docker-compose -f /opt/ai-server/docker-compose.yml logs -f ;;
        nginx)    tail -f /var/log/nginx/error.log ;;
        *)        echo "Uso: bash scripts.sh logs [ollama|qwen36|webui|nginx]" ;;
    esac
}

# =============================================================================
# Dispatcher
# =============================================================================
case "$1" in
    status)       status ;;
    start-qwen36) start_qwen36 ;;
    stop-qwen36)  stop_qwen36 ;;
    test)         test_models ;;
    ssl)          setup_ssl "$2" "$3" ;;
    add-user)     add_user "$2" ;;
    logs)         show_logs "$2" ;;
    *)
        echo ""
        echo -e "${CYAN}Uso: bash scripts.sh <comando>${NC}"
        echo ""
        echo "  status          — Estado de todos os serviços + RAM"
        echo "  start-qwen36    — Inicia Qwen3.6 35B (verifica RAM antes)"
        echo "  stop-qwen36     — Para Qwen3.6 e libera RAM"
        echo "  test            — Testa os dois modelos"
        echo "  ssl <dom> <mail> — Configura HTTPS com Let's Encrypt"
        echo "  add-user <nome> — Adiciona usuário para API básica"
        echo "  logs <serviço>  — Mostra logs em tempo real"
        echo ""
        ;;
esac
