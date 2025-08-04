#!/bin/bash
# -------------------------------------------------------
# INSTALACIÓN Y VALIDACIÓN NETWORK CONNECTOR AGENT (VISUAL)
# Basado en "How to install Network Connector" doc.
# -------------------------------------------------------

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AGENT_IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

OK="\033[1;32m[OK]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
INFO="\033[1;36m[INFO]\033[0m"

LOGFILE="/var/tmp/install_nc_$(date +%Y%m%d_%H%M%S).log"
echo -e "\n${INFO} Iniciando instalación Network Connector Agent" | tee -a "$LOGFILE"

print_status() {
  echo -e "   ➤ $1 $2" | tee -a "$LOGFILE"
}

# 1. Requisitos básicos
echo -e "\n${INFO} Verificando requisitos..." | tee -a "$LOGFILE"
# Puerto WebSocket 51445
nc -zvw2 registry.senhasegura.io 51445 &>/dev/null && print_status "$OK" "Puerto 51445 WebSocket accesible" || print_status "$FAIL" "Puerto 51445 WebSocket NO accesible"
# Acceso a registro
nc -zvw2 registry.senhasegura.io 443 &>/dev/null && print_status "$OK" "Acceso registry.senhasegura.io:443" || print_status "$FAIL" "No acceso a registry.senhasegura.io:443"
nc -zvw2 us-docker.pkg.dev 443 &>/dev/null && print_status "$OK" "Acceso us-docker.pkg.dev:443" || print_status "$WARN" "No acceso a us-docker.pkg.dev:443 (opcional)"

# 2. Configurar server NC si no se ha hecho
echo -e "\n${INFO} Verificando configuración de servidor Network Connector (solo en Senhasegura PAM)" | tee -a "$LOGFILE"
if sudo command -v orbit &>/dev/null; then
  sudo orbit network-connector status &>/dev/null
  if [[ $? -ne 0 ]]; then
    echo -e "${INFO} Ejecutando 'orbit network-connector setup'..." | tee -a "$LOGFILE"
    sudo orbit network-connector setup | tee -a "$LOGFILE"
  else
    print_status "$OK" "Servidor NC ya configurado"
  fi
else
  print_status "$WARN" "Comando orbit no disponible, se asume host agent"
fi

# 3. Instalar Docker y docker-compose (opcional indica)
echo -e "\n${INFO} Verificando Docker y Docker Compose..." | tee -a "$LOGFILE"
if ! command -v docker &>/dev/null; then
  apt update -y && apt install -y docker.io || { print_status "$FAIL" "Error instalando Docker"; exit 1; }
  systemctl enable docker --now
  print_status "$OK" "Docker instalado"
else print_status "$OK" "Docker ya instalado"; fi

if ! command -v docker-compose &>/dev/null; then
  curl -sL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  print_status "$OK" "Docker Compose instalado"
else print_status "$OK" "Docker Compose ya instalado"; fi

# 4. Crear carpeta y solicitar variables
mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR" || exit 1
read -rp "🔐 FINGERPRINT: " FINGERPRINT
read -rp "📡 PUERTO AGENT (30000‑30999): " AGENT_PORT
read -rp "🌐 DIRECCIONES PAM (coma separado): " PAM_ADDRESS
read -rp "¿SECONDARY? true/false: " IS_SECONDARY

# 5. Generar docker-compose.yml conforme al ejemplo oficial
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
networks:
  senhasegura-network-connector:
    driver: bridge
EOF
print_status "$OK" "docker-compose.yml creado"

# 6. Levantar servicio
echo -e "\n${INFO} Iniciando agente..." | tee -a "$LOGFILE"
docker-compose up -d | tee -a "$LOGFILE"
if [[ $? -eq 0 ]]; then print_status "$OK" "Agent iniciado correctamente"; else print_status "$FAIL" "Fallo iniciando agente"; exit 1; fi

# 7. Mostrar logs del agente
echo -e "\n${INFO} Logs recientes del agente:" | tee -a "$LOGFILE"
docker-compose logs --tail=20 | tee -a "$LOGFILE"

echo -e "\n${OK} Instalación finalizada. Revisa logs en $LOGFILE"
