# 🤖 AI Dev Server — Oracle VPS (4 OCPU / 24GB RAM)

Setup completo com dois modelos coexistindo:
- **Qwen2.5-Coder:7B** via Ollama — rápido, para o dia a dia
- **Qwen3.6-35B-A3B Q4** via llama.cpp — raciocínio profundo, para tasks complexas

---

## Arquitetura

```
Internet
    │
    ▼
 Nginx (80/443)
    ├──/             → Open WebUI (3000)   — Interface visual
    ├──/ollama/      → Ollama (11434)      — Qwen2.5-Coder 7B
    └──/qwen36/v1/   → llama.cpp (8081)   — Qwen3.6 35B-A3B
```

---

## Instalação

### 1. Clone e execute na VPS

```bash
git clone https://github.com/seu-usuario/ai-server /tmp/ai-server
cd /tmp/ai-server
sudo bash setup.sh
```

O script faz tudo automaticamente:
- Instala dependências, Docker, Nginx
- Instala e configura Ollama + baixa Qwen2.5-Coder 7B
- Compila llama.cpp
- Baixa Qwen3.6-35B-A3B Q4 (~22GB)
- Cria serviços systemd
- Sobe Open WebUI via Docker

> ⏱ Duração estimada: 45–90 min (maioria é download do modelo)

### 2. Libere as portas no Oracle Cloud

No painel da Oracle Cloud:
**Networking → Virtual Cloud Networks → Security Lists → Ingress Rules**

Adicione:
| Protocol | Port | Description |
|---|---|---|
| TCP | 80 | HTTP |
| TCP | 443 | HTTPS |

As portas 11434, 8081 e 3000 **não devem** ser abertas — ficam atrás do Nginx.

### 3. Configure SSL (opcional mas recomendado)

```bash
sudo bash /opt/ai-server/scripts/scripts.sh ssl seu.dominio.com seu@email.com
```

---

## Uso dos modelos

### Qwen2.5-Coder 7B — Rápido ⚡

Via Open WebUI: selecione `qwen2.5-coder:7b`

Via API (compatível Ollama):
```bash
curl http://SEU_IP/ollama/api/generate \
  -d '{"model":"qwen2.5-coder:7b","prompt":"Crie uma função Python para ordenar uma lista","stream":false}'
```

Via Python:
```python
import ollama
client = ollama.Client(host='http://SEU_IP/ollama')
response = client.generate(model='qwen2.5-coder:7b', prompt='...')
```

---

### Qwen3.6-35B-A3B — Raciocínio Profundo 🧠

> Inicie manualmente pois consome ~20GB de RAM:
```bash
sudo bash /opt/ai-server/scripts/scripts.sh start-qwen36
```

Via API (compatível OpenAI):
```bash
curl http://SEU_IP/qwen36/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-35b-a3b",
    "messages": [{"role": "user", "content": "/think Refatore este código para ser mais eficiente: ..."}]
  }'
```

Via Python (OpenAI SDK):
```python
from openai import OpenAI

client = OpenAI(
    base_url="http://SEU_IP/qwen36/v1",
    api_key="local-key"
)

response = client.chat.completions.create(
    model="qwen3.6-35b-a3b",
    messages=[
        {"role": "user", "content": "/think Analise este sistema e sugira melhorias de arquitetura..."}
    ]
)
```

#### Modos de raciocínio:
| Prefixo no prompt | Comportamento |
|---|---|
| `/think` | Ativa raciocínio profundo antes de responder (mais lento, melhor) |
| `/no_think` | Resposta direta sem raciocínio (padrão, mais rápido) |

---

## Claude Code + MCP

Configure o `~/.claude.json` na sua máquina local:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/seu/projeto"]
    },
    "git": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-git", "--repository", "/seu/projeto"]
    },
    "fetch": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-fetch"]
    }
  }
}
```

---

## Scripts de gerenciamento

```bash
# Estado geral + RAM
sudo bash /opt/ai-server/scripts/scripts.sh status

# Iniciar/parar Qwen3.6 (modelo pesado)
sudo bash /opt/ai-server/scripts/scripts.sh start-qwen36
sudo bash /opt/ai-server/scripts/scripts.sh stop-qwen36

# Testar os dois modelos
sudo bash /opt/ai-server/scripts/scripts.sh test

# Ver logs em tempo real
sudo bash /opt/ai-server/scripts/scripts.sh logs ollama
sudo bash /opt/ai-server/scripts/scripts.sh logs qwen36
sudo bash /opt/ai-server/scripts/scripts.sh logs webui

# Adicionar usuário para autenticação da API
sudo bash /opt/ai-server/scripts/scripts.sh add-user meu-usuario
```

---

## Estratégia de uso recomendada

```
Task simples / completions rápidas
  → Use Qwen2.5-Coder 7B (sempre ativo)
  → ~10–15 tokens/seg

Arquitetura, refatoração grande, debug complexo
  → start-qwen36 → use Qwen3.6 com /think
  → ~3–6 tokens/seg mas qualidade muito superior
  → stop-qwen36 depois para liberar RAM
```

---

## Consumo de RAM estimado

| Serviço | RAM |
|---|---|
| Sistema operacional | ~1–2 GB |
| Ollama + Qwen2.5-Coder 7B | ~6–8 GB |
| Open WebUI (Docker) | ~0.5 GB |
| Nginx | ~0.1 GB |
| **Total sem Qwen3.6** | **~8–11 GB** |
| Qwen3.6-35B-A3B Q4 | ~20–22 GB |
| **Total com Qwen3.6** | **~21–24 GB** ⚠️ |

> Com os dois rodando simultaneamente, a RAM fica no limite. Por isso o Qwen3.6 é gerenciado manualmente.

---

## Troubleshooting

**Qwen3.6 não inicia (OOM):**
```bash
free -h                          # Verifica RAM disponível
docker stats --no-stream         # Verifica uso do Docker
sudo bash scripts.sh stop-qwen36 # Para se já tiver rodando
```

**Ollama não responde:**
```bash
systemctl restart ollama
ollama list  # Lista modelos disponíveis
```

**Open WebUI inacessível:**
```bash
cd /opt/ai-server && docker-compose ps
docker-compose restart open-webui
```
