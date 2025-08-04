#!/usr/bin/env bash

set -euo pipefail

echo "🔐 Instalación del agente Network Connector de senhasegura"
echo "-----------------------------------------------------------"

# === FUNCIÓN: validar si comando existe ===
check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "❌ Requisito faltante: '$1' no está instalado."
    return 1
  fi
}

# === VALIDACIONES PREVIAS ===
echo "🔎 Validando entorno..."

# 1. Ejecutar como root
if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Este script debe ejecutarse como root o con sudo."
  exit 1
fi

# 2. Verificar conexión a internet
if ! ping -q -c 1 -W 2 8.8.8.8 &>/dev/null; then
  echo "❌ No hay conexión a Internet. Verifica la red."
  exit 1
fi

# 3. Verificar si Docker ya está instalado
if command -v docker &>/dev/null; then
  echo "⚠️ Docker ya está instalado. Se omitirá la reinstalación."
  DOCKER_INSTALLED=true
else
  DOCKER_INSTALLED=false
fi

# === RECOLECCIÓN DE DATOS ===
read -rp "➡️  Ingresa el FINGERPRINT del agente: " SENHASEGURA_FINGERPRINT
if [[ -z "$SENHASEGURA_FINGERPRINT" ]]; then
  echo "❌ El fingerprint no puede estar vacío."
  exit 1
fi

read -rp "➡️  Puerto para el agente (30000-30999): " SENHASEGURA_AGENT_PORT
if ! [[ "$SENHASEGURA_AGENT_PORT" =~ ^30[0-9]{3}$ ]]; then
  echo "❌ Puerto inválido. Debe estar entre 30000 y 30999."
  exit 1
fi

# Validar si el puerto está en uso
if ss -tuln | grep -q ":$SENHASEGURA_AGENT_PORT "; then
  echo "❌ El puerto $SENHASEGURA_AGENT_PORT ya está en uso."
  exit 1
fi

read -rp "➡️  IPs o rangos permitidos (separados por comas): " SENHASEGURA_ADDRESSES
if [[ -z "$SENHASEGURA_ADDRESSES" ]]; then
  echo "❌ Las direcciones IP no pueden estar vacías."
  exit 1
fi

read -rp "➡️  Versión del agente a usar (ej. 2.20.0): " SENHASEGURA_AGENT_VERSION
SENHASEGURA_IMAGE="registry.senhasegura.io/network-connector/agent-v2:$SENHASEGURA_AGENT_VERSION"

# === INSTALACIÓN DE DOCKER ===
if [[ "$DOCKER_INSTALLED" = false ]]; then
  echo "📦 Instalando Docker y Docker Compose..."
  apt update -y
  apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

docker --version
docker compose version

# === CREAR DIRECTORIO Y ARCHIVO ===
AGENT_DIR="/opt/senhasegura-network-connector"
mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

cat > docker-compose.yaml <<EOF
version: '3.5'
services:
  network-connector-agent:
    container_name: network-connector-agent
    image: $SENHASEGURA_IMAGE
    restart: unless-stopped
    network_mode: host
    environment:
      - AGENT_FINGERPRINT=$SENHASEGURA_FINGERPRINT
      - AGENT_PORT=$SENHASEGURA_AGENT_PORT
      - AGENT_ADDRESS=$SENHASEGURA_ADDRESSES
EOF

# === DESPLIEGUE ===
echo "🚀 Lanzando contenedor del agente..."
docker compose up -d

echo ""
echo "✅ Instalación completada. Logs con:"
echo "   docker compose logs -f"
