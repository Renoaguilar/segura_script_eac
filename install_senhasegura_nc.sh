#!/bin/bash

# -----------------------------------------------
# INSTALACIÓN AUTOMÁTICA DE NETWORK CONNECTOR
# Usa la última versión disponible del agente
# -----------------------------------------------

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AGENT_IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

# Colores
OK="\033[1;32m[OK]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
INFO="\033[1;36m[INFO]\033[0m"

echo -e "$INFO Verificando requisitos..."

# 1. Instalar Docker si no existe
if ! command -v docker &> /dev/null; then
    echo -e "$INFO Instalando Docker..."
    apt update -y && apt install -y docker.io || { echo -e "$FAIL Error instalando Docker"; exit 1; }
    systemctl enable docker --now
else
    echo -e "$OK Docker ya está instalado"
fi

# 2. Instalar Docker Compose si no existe
if ! command -v docker-compose &> /dev/null; then
    echo -e "$INFO Instalando Docker Compose..."
    curl -sL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    echo -e "$OK Docker Compose ya está instalado"
fi

# 3. Crear carpeta de despliegue
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# 4. Solicitar parámetros
read -rp "🔐 FINGERPRINT (desde PAM): " FINGERPRINT
read -rp "📡 Puerto de escucha del agente (ej. 5555): " AGENT_PORT
read -rp "🌐 Dirección IP o hostname del PAM (ej. 172.16.1.10): " PAM_ADDRESS
read -rp "¿Es este un agente secundario? (true/false): " IS_SECONDARY

# 5. Crear archivo docker-compose.yml
cat > "$COMPOSE_FILE" <<EOF
version: "3"
services:
  senhasegura-network-connector-agent:
    image: "${AGENT_IMAGE}"
    restart: unless-stopped
    networks:
      - senhasegura-network-connector
    environment:
      SENHASEGURA_FINGERPRINT: "${FINGERPRINT}"
      SENHASEGURA_AGENT_PORT: "${AGENT_PORT}"
      SENHASEGURA_ADDRESSES: "${PAM_ADDRESS}"
      SENHASEGURA_AGENT_SECONDARY: "${IS_SECONDARY}"
networks:
  senhasegura-network-connector:
    driver: bridge
EOF

echo -e "$OK docker-compose.yml generado en $COMPOSE_FILE"

# 6. Iniciar servicio
echo -e "$INFO Iniciando el Network Connector..."
docker-compose up -d

if [[ $? -eq 0 ]]; then
    echo -e "$OK Network Connector iniciado correctamente"
else
    echo -e "$FAIL Hubo un problema al iniciar el agente"
    exit 1
fi

# 7. Mostrar logs recientes
echo -e "$INFO Logs del agente:"
docker-compose logs --tail=20
