#!/bin/bash
# -------------------------------------------------------
# INSTALACIÓN AUTOMÁTICA DEL NETWORK CONNECTOR (NC)
# CON VALIDACIONES, LOGS Y ESTATUS FINAL
# Basado en: https://docs.senhasegura.io/docs/en/network-connector-how-to-install-network-connector
# -------------------------------------------------------

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AGENT_IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

# Estados
OK="\033[1;32m[OK]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
INFO="\033[1;36m[INFO]\033[0m"

LOGFILE="/var/tmp/install_nc_$(date +%Y%m%d_%H%M%S).log"
declare -A STATUS
echo -e "\n$INFO Instalación Network Connector — $(date)" | tee -a "$LOGFILE"

print_status() {
    STATUS["$2"]="$1"
    echo -e "   ➤ $1 $2" | tee -a "$LOGFILE"
}

# 1. Validar conectividad requerida
echo -e "\n$INFO Verificando conectividad externa..." | tee -a "$LOGFILE"
nc -zvw2 registry.senhasegura.io 51445 &>/dev/null && print_status "$OK" "Puerto 51445 WebSocket accesible" || print_status "$FAIL" "Puerto 51445 WebSocket inaccesible"

nc -zvw2 registry.senhasegura.io 443 &>/dev/null && print_status "$OK" "Acceso HTTPS a registry.senhasegura.io" || print_status "$FAIL" "Sin acceso a registry.senhasegura.io:443"

nc -zvw2 us-docker.pkg.dev 443 &>/dev/null && print_status "$OK" "Acceso opcional a us-docker.pkg.dev" || print_status "$WARN" "No acceso a us-docker.pkg.dev (no bloqueante)"

# 2. Orbit (solo si es servidor PAM)
if command -v orbit &>/dev/null; then
    echo -e "\n$INFO Verificando configuración de NC en servidor PAM..." | tee -a "$LOGFILE"
    sudo orbit network-connector status &>/dev/null
    if [[ $? -ne 0 ]]; then
        sudo orbit network-connector setup && print_status "$OK" "Servidor PAM configurado con orbit network-connector" || print_status "$FAIL" "Error en setup de orbit network-connector"
    else
        print_status "$OK" "Servidor PAM ya tiene Network Connector activo"
    fi
else
    print_status "$WARN" "Orbit no detectado. Asumimos host agente"
fi

# 3. Instalar Docker si no está
if ! command -v docker &>/dev/null; then
    apt update -y && apt install -y docker.io && systemctl enable docker --now && print_status "$OK" "Docker instalado" || print_status "$FAIL" "Error instalando Docker"
else
    print_status "$OK" "Docker ya está instalado"
fi

# 4. Instalar Docker Compose si no está
if ! command -v docker-compose &>/dev/null; then
    curl -sL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose && print_status "$OK" "Docker Compose instalado" || print_status "$FAIL" "Error instalando Docker Compose"
else
    print_status "$OK" "Docker Compose ya instalado"
fi

# 5. Solicitar datos y crear carpeta
mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR" || exit 1
read -rp "🔐 FINGERPRINT: " FINGERPRINT
read -rp "📡 PUERTO AGENTE (30000-30999): " AGENT_PORT
read -rp "🌐 DIRECCIONES PAM (coma separado): " PAM_ADDRESS
read -rp "¿Es secundario? (true/false): " IS_SECONDARY

# 6. Generar docker-compose.yml
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

print_status "$OK" "docker-compose.yml generado en $COMPOSE_FILE"

# 7. Levantar contenedor
docker-compose up -d && print_status "$OK" "Contenedor iniciado con Docker Compose" || print_status "$FAIL" "Error al iniciar el contenedor"

# 8. Verificar si el contenedor está corriendo
CONTAINER=$(docker ps --format '{{.Names}}' | grep network-connector-agent)
if [[ -n "$CONTAINER" ]]; then
    print_status "$OK" "Contenedor $CONTAINER activo"
else
    print_status "$FAIL" "El contenedor del agente no está corriendo"
fi

# 9. Logs breves
echo -e "\n$INFO Logs recientes del agente:"
docker-compose logs --tail=10 | tee -a "$LOGFILE"

# 10. RESUMEN FINAL
echo -e "\n\033[1;35m╔════════════════════════════════════════════╗"
echo -e "║         RESUMEN FINAL DE LA INSTALACIÓN   ║"
echo -e "╚════════════════════════════════════════════╝\033[0m"
for key in "${!STATUS[@]}"; do
    echo -e " - ${STATUS[$key]} $key"
done

echo -e "\n$OK Revisión completa. Logs completos: $LOGFILE"
