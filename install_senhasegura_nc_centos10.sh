#!/usr/bin/env bash
# ==========================================================
# Senhasegura Network Connector - Installer + Doctor (CS10)
# ==========================================================
set -euo pipefail

OK=$'\033[1;32m[OK]\033[0m'
WARN=$'\033[1;33m[WARN]\033[0m'
FAIL=$'\033[1;31m[FAIL]\033[0m'
INFO=$'\033[1;36m[INFO]\033[0m'

say() { local s="$1"; shift; echo -e " ➔ $s $*"; }

# ---------- Requisitos ----------
if [[ $EUID -ne 0 ]]; then
  echo -e "$FAIL Debes ejecutar como root"; exit 1
fi

command -v dnf >/dev/null || { echo -e "$FAIL Falta dnf"; exit 1; }

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SERVICE_NAME="senhasegura-network-connector-agent"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ---------- Preguntas ----------
read -rp " FINGERPRINT (exacto, sin espacios): " SNC_FINGERPRINT
read -rp " IP(s) de PAM (coma separadas, sin puerto): " PAM_IPS
read -rp " Puerto del agente [30000-30999]: " AGENT_PORT
read -rp " ¿Es agente secundario? [true/false]: " IS_SECONDARY

# Sanitización básica
SNC_FINGERPRINT="${SNC_FINGERPRINT//[[:space:]]/}"
PAM_IPS="${PAM_IPS// /}"
IS_SECONDARY=$(echo "$IS_SECONDARY" | tr '[:upper:]' '[:lower:]')

if ! [[ "$AGENT_PORT" =~ ^3[0-0][0-9]{3}$ ]] || (( AGENT_PORT < 30000 || AGENT_PORT > 30999 )); then
  echo -e "$FAIL Puerto inválido: $AGENT_PORT (debe ser 30000–30999)"; exit 1
fi
if [[ "$IS_SECONDARY" != "true" && "$IS_SECONDARY" != "false" ]]; then
  echo -e "$FAIL Valor inválido para secundario: $IS_SECONDARY"; exit 1
fi

# ---------- Paquetes base ----------
say "$INFO" "Actualizando metadatos de paquetes"
dnf -y makecache >/dev/null

say "$INFO" "Instalando dependencias base"
dnf -y install curl jq iproute procps-ng nmap-ncat firewalld >/dev/null

# ---------- Docker / Compose ----------
if ! command -v docker >/dev/null; then
  say "$FAIL" "Docker no encontrado. Instálalo (Docker CE) y vuelve a ejecutar."
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  say "$FAIL" "Docker Compose plugin no disponible (docker compose)."
  exit 1
fi

# ---------- firewalld ----------
systemctl enable --now firewalld >/dev/null 2>&1 || true
DEFAULT_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || echo public)

# ---------- Generar docker-compose.yml ----------
cat > "$COMPOSE_FILE" <<YAML
services:
  ${SERVICE_NAME}:
    image: "registry.senhasegura.io/network-connector/agent-v2:latest"
    restart: unless-stopped
    networks:
      - senhasegura-network-connector
    # publicar el puerto del agente para facilitar pruebas desde el host
    environment:
      SENHASEGURA_FINGERPRINT: ${SNC_FINGERPRINT}
      SENHASEGURA_AGENT_PORT: ${AGENT_PORT}
      SENHASEGURA_ADDRESSES: ${PAM_IPS}
      SENHASEGURA_AGENT_SECONDARY: ${IS_SECONDARY}
networks:
  senhasegura-network-connector:
    driver: bridge
YAML

say "$INFO" "Levantando el agente…"
docker compose up -d

# ---------- Doctor / Tests ----------
say "$INFO" "Ejecutando pruebas del agente"

# 1) Resolver contenedor por etiqueta de Compose (robusto para nombres v2)
CID=$(docker ps -q -f "label=com.docker.compose.service=${SERVICE_NAME}" | head -n1)
if [[ -z "${CID}" ]]; then
  say "$FAIL" "Contenedor '${SERVICE_NAME}' no encontrado tras levantar Compose"
  docker compose ps
  exit 1
fi

STATE=$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null || echo "unknown")
if [[ "$STATE" != "running" ]]; then
  say "$FAIL" "Contenedor '${SERVICE_NAME}' no está corriendo (estado: $STATE)."
  docker ps --no-trunc
  exit 1
else
  say "$OK" "Contenedor '${SERVICE_NAME}' en ejecución"
fi

# 2) Variables dentro del contenedor
ENV_DUMP=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CID")
for v in SENHASEGURA_FINGERPRINT SENHASEGURA_AGENT_PORT SENHASEGURA_ADDRESSES SENHASEGURA_AGENT_SECONDARY; do
  if ! grep -q "^${v}=" <<<"$ENV_DUMP"; then
    say "$FAIL" "ENV ${v} ausente."
    MISSING_ENV=1
  fi
done
[[ ${MISSING_ENV:-0} -eq 0 ]] && say "$OK" "Variables de entorno presentes en el contenedor"

# 3) Puerto en escucha (host)
if ss -lntp | grep -q ":${AGENT_PORT}\b"; then
  say "$OK" "Puerto ${AGENT_PORT}/tcp en escucha en el host."
else
  say "$WARN" "Puerto ${AGENT_PORT}/tcp NO está en escucha en el host (revisar mapeo 'ports:')."
fi

# 4) Salida a registry (pull de imagen usa 443)
if nc -zw3 registry.senhasegura.io 443; then
  say "$OK" "Salida a registry.senhasegura.io:443 OK"
else
  say "$WARN" "Sin salida a registry.senhasegura.io:443 (proxy/firewall perimetral?)"
fi

# 5) Conectividad hacia PAM en 51445 (requisito SNC)
IFS=',' read -ra PAM_LIST <<< "$PAM_IPS"
ALL_OK=1
for ip in "${PAM_LIST[@]}"; do
  ip_trim="${ip//[[:space:]]/}"
  if nc -zw3 "$ip_trim" 51445; then
    say "$OK" "Salida a ${ip_trim}:51445 OK"
  else
    say "$WARN" "Sin salida a ${ip_trim}:51445 (posible firewall perimetral)."
    ALL_OK=0
  fi
done

# 6) firewalld (abrimos el puerto del agente para acceso local/red según topología)
if firewall-cmd --zone="$DEFAULT_ZONE" --list-ports | grep -q "\b${AGENT_PORT}/tcp\b"; then
  say "$INFO" "Regla firewalld ya presente para ${AGENT_PORT}/tcp"
else
  if firewall-cmd --permanent --zone="$DEFAULT_ZONE" --add-port="${AGENT_PORT}/tcp" >/dev/null; then
    firewall-cmd --reload >/dev/null
    say "$OK" "firewalld permite ${AGENT_PORT}/tcp en zona ${DEFAULT_ZONE}"
  else
    say "$WARN" "No se pudo agregar la regla firewalld para ${AGENT_PORT}/tcp"
  fi
fi

# 7) Resumen
echo
echo "===== ESTATUS DEL AGENTE ====="
echo " Contenedor:  ${STATE}"
echo " Fingerprint: $(echo "$SNC_FINGERPRINT" | sed -E 's/^(.{6}).*(.{6})$/\1…\2/')"
echo " PAM IP(s):   ${PAM_IPS}"
echo " Puerto:      ${AGENT_PORT}"
[[ $ALL_OK -eq 1 ]] && echo -e " Conectividad 51445: ${OK}" || echo -e " Conectividad 51445: ${WARN}"
echo "=============================="
