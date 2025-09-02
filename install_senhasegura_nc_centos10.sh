#!/usr/bin/env bash
# ==========================================================
# Senhasegura Network Connector - Installer + Doctor (CS10)
# YAML sin comillas en environment, sin publicar puertos.
# ==========================================================
set -euo pipefail

OK=$'\033[1;32m[OK]\033[0m'
WARN=$'\033[1;33m[WARN]\033[0m'
FAIL=$'\033[1;31m[FAIL]\033[0m'
INFO=$'\033[1;36m[INFO]\033[0m'

say(){ echo -e " ➔ $1 $2"; }
need(){ command -v "$1" >/dev/null 2>&1 || { say "$FAIL" "Falta $1"; exit 1; }; }

[[ $EUID -eq 0 ]] || { echo -e "$FAIL Debes ejecutar como root"; exit 1; }
need dnf

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SERVICE_NAME="senhasegura-network-connector-agent"
IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ------- Parámetros -------
read -rp " FINGERPRINT (exacto, sin espacios): " SNC_FINGERPRINT
read -rp " IP(s) de PAM (coma separadas, sin espacio): " PAM_IPS
read -rp " Puerto del agente [30000-30999]: " AGENT_PORT
read -rp " ¿Es agente secundario? [true/false]: " IS_SECONDARY

# Sanitiza mínimos
SNC_FINGERPRINT="${SNC_FINGERPRINT//[[:space:]]/}"
PAM_IPS="${PAM_IPS// /}"
IS_SECONDARY="$(echo "$IS_SECONDARY" | tr '[:upper:]' '[:lower:]')"

if ! [[ "$AGENT_PORT" =~ ^30[0-9]{3}$ ]]; then
  echo -e "$FAIL Puerto inválido: $AGENT_PORT (30000–30999)"; exit 1
fi
if [[ "$IS_SECONDARY" != "true" && "$IS_SECONDARY" != "false" ]]; then
  echo -e "$FAIL Valor inválido para secundario: $IS_SECONDARY"; exit 1
fi

# ------- Paquetes base -------
say "$INFO" "Preparando utilidades"
dnf -y makecache >/dev/null
dnf -y install curl jq iproute procps-ng nmap-ncat firewalld >/dev/null

# ------- Docker / Compose -------
need docker
if ! docker compose version >/dev/null 2>&1; then
  echo -e "$FAIL Falta Docker Compose plugin (docker compose)"; exit 1
fi
systemctl enable --now firewalld >/dev/null 2>&1 || true

# ------- Generar docker-compose.yml (sin comillas) -------
cat > "$COMPOSE_FILE" <<YAML
services:
  ${SERVICE_NAME}:
    image: ${IMAGE}
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
docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_FILE" up -d

# ------- Doctor / Tests -------
say "$INFO" "Ejecutando pruebas"

# Contenedor (usamos etiqueta de compose)
CID="$(docker ps -q -f "label=com.docker.compose.service=${SERVICE_NAME}" | head -n1)"
if [[ -z "$CID" ]]; then
  say "$FAIL" "Contenedor '${SERVICE_NAME}' no encontrado"
  docker compose ps; exit 1
fi

STATE="$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null || echo unknown)"
[[ "$STATE" == "running" ]] && say "$OK" "Contenedor '${SERVICE_NAME}' en ejecución" || { say "$FAIL" "Estado: $STATE"; exit 1; }

# Variables dentro del contenedor
ENV_DUMP="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CID")"
MISSING=0
for v in SENHASEGURA_FINGERPRINT SENHASEGURA_AGENT_PORT SENHASEGURA_ADDRESSES SENHASEGURA_AGENT_SECONDARY; do
  if grep -q "^${v}=" <<<"$ENV_DUMP"; then
    say "$OK" "ENV ${v} presente"
  else
    say "$FAIL" "ENV ${v} ausente"; MISSING=1
  fi
done
[[ $MISSING -eq 0 ]] || exit 1

# Reachability 51445 hacia cada PAM
IFS=',' read -ra _PAMS <<< "$PAM_IPS"
ALL_OK=1
for ip in "${_PAMS[@]}"; do
  ip="${ip//[[:space:]]/}"
  if nc -zw3 "$ip" 51445; then
    say "$OK" "Salida a ${ip}:51445 OK"
  else
    say "$WARN" "Sin salida a ${ip}:51445 (firewall/proxy perimetral?)"
    ALL_OK=0
  fi
done

# Firewalld (solo informar; no tocamos reglas)
if systemctl is-active --quiet firewalld; then
  Z="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
  P="$(firewall-cmd --zone="$Z" --list-ports 2>/dev/null || true)"
  grep -qw "51445/tcp" <<<"$P" && say "$OK" "51445/tcp permitido en firewalld ($Z)" || say "$WARN" "51445/tcp no permitido en firewalld ($Z)"
  # Como no publicamos puerto en host, no exigimos ${AGENT_PORT}/tcp en firewalld.
fi

echo
echo "===== ESTATUS DEL AGENTE ====="
echo " Contenedor:  ${STATE}"
echo " Fingerprint: $(echo "$SNC_FINGERPRINT" | sed -E 's/^(.{6}).*(.{6})$/\1…\2/')"
echo " PAM IP(s):   ${PAM_IPS}"
echo " Puerto:      ${AGENT_PORT} (no publicado en host)"
echo " Reach 51445: $([[ $ALL_OK -eq 1 ]] && echo OK || echo WARN)"
echo "=============================="
