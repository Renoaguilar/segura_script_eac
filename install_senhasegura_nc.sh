#!/bin/bash

# Pass Senhasegura
PASSWORD="Segura2025"

read -s -p "🔐 Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi

#                 _
#                | |
#  ___  ___ _ __ | |__   __ _ ___  ___  __ _ _   _ _ __ __ _
# / __|/ _ \ '_ \| '_ \ / _` / __|/ _ \/ _` | | | | '__/ _` |
# \__ \  __/ | | | | | | (_| \__ \  __/ (_| | |_| | | | (_| |
# |___/\___|_| |_|_| |_|\__,_|___/\___|\__, |\__,_|_|  \__,_|
#                                       __/ |
#                                      |___/

# Script: segura_log_cleaner.sh
# Autor:  Esteban Ac
# Función: Limpieza de logs grandes y sesiones huérfanas con resumen visual por archivo

# ----------------------------------------------------------------
# SENHASEGURA NETWORK CONNECTOR INSTALLER v3 (Resiliente + Firewall + Docker Compose Fix)
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

# 1. Validar acceso a registry y abrir puerto si es necesario
nc -zvw2 registry.senhasegura.io 51445 &>/dev/null
if [[ $? -eq 0 ]]; then
    print_status "$OK" "Puerto 51445 accesible"
else
    print_status "$FAIL" "Puerto 51445 inaccesible. Intentando abrir..."
    if command -v ufw &>/dev/null; then
        ufw allow 51445/tcp && print_status "$OK" "Regla UFW abierta para puerto 51445"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --add-port=51445/tcp --permanent && firewall-cmd --reload && print_status "$OK" "Regla firewalld aplicada para 51445"
    else
        iptables -C INPUT -p tcp --dport 51445 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 51445 -j ACCEPT && print_status "$OK" "Puerto 51445 abierto con iptables"
    fi

    # Validar de nuevo
    sleep 2
    nc -zvw2 registry.senhasegura.io 51445 &>/dev/null && print_status "$OK" "Puerto 51445 ahora accesible" || print_status "$FAIL" "No se pudo abrir el puerto 51445"
fi

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

# 4. Validar e instalar Docker si falta
if ! command -v docker &>/dev/null; then
    echo -e "$WARN Docker no detectado. Instalando..."
    apt update -y && apt install -y docker.io && systemctl enable docker --now
fi

# 5. Validar docker-compose (v1) o plugin docker compose (v2)
if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    echo -e "$WARN docker-compose no encontrado. Instalando..."
    curl -sL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# 6. Ejecutar con la versión disponible
cd "$INSTALL_DIR"
if command -v docker-compose &>/dev/null; then
    docker-compose down --remove-orphans && docker-compose up -d
elif docker compose version &>/dev/null; then
    docker compose down --remove-orphans && docker compose up -d
else
    echo -e "$FAIL No se pudo ejecutar docker compose"
    exit 1
fi

# 7. Validar estado
sleep 5
CONTAINER=$(docker ps --format '{{.Names}}' | grep network-connector-agent)
if [[ -n "$CONTAINER" ]]; then
    docker logs "$CONTAINER" 2>&1 | grep -q "Agent started"
    if [[ $? -eq 0 ]]; then
        echo -e "\n$OK Agente funcionando correctamente."
    else
        echo -e "\n$FAIL Contenedor activo pero el agente no responde correctamente."
    fi
else
    echo -e "\n$FAIL El contenedor no está corriendo."
fi

exit 0
