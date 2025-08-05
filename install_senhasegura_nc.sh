#!/bin/bash
# ----------------------------------------------------------------
# SENHASEGURA NETWORK CONNECTOR INSTALLER (VALIDACION SIMPLIFICADA)
# ----------------------------------------------------------------
INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AGENT_IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

OK="\033[1;32m[OK]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
INFO="\033[1;36m[INFO]\033[0m"

LOGFILE="/var/tmp/install_nc_$(date +%Y%m%d_%H%M%S).log"
declare -A STATUS

print_status() {
    STATUS["$2"]="$1"
    echo -e "   ➔ $1 $2" | tee -a "$LOGFILE"
}

mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR" || exit 1

# 1. Valida acceso a registro
nc -zvw2 registry.senhasegura.io 51445 &>/dev/null && print_status "$OK" "Puerto 51445 accesible" || print_status "$FAIL" "Puerto 51445 inaccesible"

# 2. Solicitar datos
while true; do
    read -rp "🔐 FINGERPRINT: " FINGERPRINT
    [[ "$FINGERPRINT" =~ ^[a-f0-9\-]{36}$ || "$FINGERPRINT" =~ ^[A-Za-z0-9+/=]{60,}$ ]] && break
    echo -e "$FAIL Formato inválido."
done

while true; do
    read -rp "📡 PUERTO AGENTE (30000-30999): " AGENT_PORT
    [[ "$AGENT_PORT" =~ ^30[0-9]{3}$ ]] && break
    echo -e "$FAIL Puerto inválido."
done

while true; do
    read -rp "🌐 IP(s) de PAM (coma separadas, sin puerto): " PAM_ADDRESS
    if [[ "$PAM_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(,([0-9]{1,3}\.){3}[0-9]{1,3})*$ ]]; then
        break
    else
        echo -e "$FAIL Formato incorrecto. Solo IPs, sin puertos."
    fi
    
    # Verificar si hay uso de IP:PUERTO por error
    if [[ "$PAM_ADDRESS" =~ ":" ]]; then
        echo -e "$WARN No debes incluir puertos en SENHASEGURA_ADDRESSES. Solo IPs."
    fi
    
    
    done

read -rp "🔄 ¿Es agente secundario? (true/false): " IS_SECONDARY

# 3. Generar YAML
cat > "$COMPOSE_FILE" <<EOF
version: "3"
services:
  senhasegura-network-connector-agent:
    image: "$AGENT_IMAGE"
    restart: unless-stopped
    networks:
      - senhasegura-network-connector
    environment:
      SENHASEGURA_FINGERPRINT: "$FINGERPRINT"
      SENHASEGURA_AGENT_PORT: "$AGENT_PORT"
      SENHASEGURA_ADDRESSES: "$PAM_ADDRESS"
      SENHASEGURA_AGENT_SECONDARY: "$IS_SECONDARY"
    ports:
      - "$AGENT_PORT:$AGENT_PORT"
networks:
  senhasegura-network-connector:
    driver: bridge
EOF

print_status "$OK" "YAML generado"

# 4. Deploy
which docker-compose &>/dev/null || {
    curl -sL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

# 5. Ejecutar
(cd "$INSTALL_DIR" && docker-compose down --remove-orphans && docker-compose up -d)

sleep 5
CONTAINER=$(docker ps --format '{{.Names}}' | grep network-connector-agent)

if [[ -n "$CONTAINER" ]]; then
    docker logs "$CONTAINER" | grep -q "Agent started"
    if [[ $? -eq 0 ]]; then
        echo -e "\n$OK Agente funcionando correctamente."
    else
        echo -e "\n$FAIL El contenedor está corriendo, pero el agente no inició correctamente."
    fi
else
    echo -e "\n$FAIL El contenedor no está corriendo."
fi

exit 0
