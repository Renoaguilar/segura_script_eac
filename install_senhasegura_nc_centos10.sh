#!/usr/bin/env bash
# ======================================================================
# Senhasegura Network Connector - Installer + Doctor (CentOS Stream 10)
# - Instala Docker CE + compose; si no hay paquetes, usa Podman (compat)
# - Genera docker-compose.yml SIN comillas y SIN 'ports:'
# - Levanta el agente y corre autotest (ENV, reach 51445, firewalld)
# ======================================================================
set -euo pipefail

OK=$'\033[1;32m[OK]\033[0m'; WARN=$'\033[1;33m[WARN]\033[0m'; FAIL=$'\033[1;31m[FAIL]\033[0m'; INFO=$'\033[1;36m[INFO]\033[0m'
say(){ echo -e " ➔ $1 $2"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo -e "$FAIL Debes ejecutar como root"; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }

need_root

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SERVICE_NAME="senhasegura-network-connector-agent"
IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# -------------------- Parámetros --------------------
read -rp " FINGERPRINT (exacto, sin espacios): " SNC_FINGERPRINT
read -rp " IP(s) de PAM (coma separadas, sin puerto): " PAM_IPS
read -rp " Puerto del agente [30000-30999]: " AGENT_PORT
read -rp " ¿Es agente secundario? [true/false]: " IS_SECONDARY

SNC_FINGERPRINT="${SNC_FINGERPRINT//[[:space:]]/}"
PAM_IPS="${PAM_IPS// /}"
IS_SECONDARY="${IS_SECONDARY,,}"

if ! [[ "$AGENT_PORT" =~ ^30[0-9]{3}$ ]]; then echo -e "$FAIL Puerto inválido (30000–30999)"; exit 1; fi
if [[ "$IS_SECONDARY" != "true" && "$IS_SECONDARY" != "false" ]]; then echo -e "$FAIL Valor inválido para secundario"; exit 1; fi

# -------------------- Paquetes base --------------------
say "$INFO" "Actualizando metadatos y herramientas base"
dnf -y makecache >/dev/null
dnf -y install curl jq iproute procps-ng nmap-ncat firewalld dnf-plugins-core >/dev/null || true
systemctl enable --now firewalld >/dev/null 2>&1 || true

# -------------------- Docker/Podman --------------------
RUNTIME="none"; HAVE_COMPOSE="no"

say "$INFO" "Intentando instalar Docker CE (repo oficial)"
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
  curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo || true
fi

if dnf list --available docker-ce >/dev/null 2>&1; then
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker >/dev/null
  RUNTIME="docker"
  if docker compose version >/dev/null 2>&1; then HAVE_COMPOSE="plugin"; fi
else
  say "$WARN" "Paquetes docker-ce no disponibles para este release. Usando Podman + compat."
  dnf -y install podman podman-docker >/dev/null
  [[ -x /usr/bin/docker ]] || ln -sf /usr/bin/podman /usr/bin/docker
  systemctl enable --now podman.socket >/dev/null 2>&1 || true
  RUNTIME="podman"
  if dnf list --available podman-compose >/dev/null 2>&1; then
    dnf -y install podman-compose >/dev/null && HAVE_COMPOSE="v1"
  else
    curl -fsSL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    HAVE_COMPOSE="v1"
  fi
fi

# Detección final de compose si quedó pendiente
if [[ "$HAVE_COMPOSE" == "no" ]]; then
  if docker compose version >/dev/null 2>&1; then HAVE_COMPOSE="plugin"
  elif command -v docker-compose >/dev/null 2>&1; then HAVE_COMPOSE="v1"
  else
    echo -e "$FAIL No hay docker compose disponible"; exit 1
  fi
fi
say "$OK" "Runtime: ${RUNTIME} | Compose: ${HAVE_COMPOSE}"

# -------------------- docker-compose.yml --------------------
cat > "$COMPOSE_FILE" <<YAML
services:
  ${SERVICE_NAME}:
    image: ${IMAGE}
    restart: unless-stopped
    networks:
      - senhasegura-network-connector
    environment:
      SENHASEGURA_FINGERPRINT: ${SNC_FINGERPRINT}
      SENHASEGURA_AGENT_PORT: ${AGENT_PORT}
      SENHASEGURA_ADDRESSES: ${PAM_IPS}
      SENHASEGURA_AGENT_SECONDARY: ${IS_SECONDARY}
networks:
  senhasegura-network-connector:
    driver: bridge
YAML

say "$OK" "docker-compose.yml generado en ${COMPOSE_FILE}"

# -------------------- Levantar agente --------------------
say "$INFO" "Levantando el agente…"
if [[ "$HAVE_COMPOSE" == "plugin" ]]; then
  docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  docker compose -f "$COMPOSE_FILE" up -d
elif [[ "$HAVE_COMPOSE" == "v1" ]]; then
  docker-compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  docker-compose -f "$COMPOSE_FILE" up -d
else
  # Último recurso: podman-compose
  podman-compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  podman-compose -f "$COMPOSE_FILE" up -d
fi

# -------------------- Autotest --------------------
say "$INFO" "Ejecutando pruebas…"
CID="$(docker ps -q -f "label=com.docker.compose.service=${SERVICE_NAME}" | head -n1 || true)"
[[ -z "$CID" ]] && CID="$(docker ps -q --filter "name=${SERVICE_NAME}" | head -n1 || true)"
if [[ -z "$CID" ]]; then
  say "$FAIL" "Contenedor '${SERVICE_NAME}' no encontrado tras levantar."
  docker ps; exit 1
fi

STATE="$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null || echo unknown)"
[[ "$STATE" == "running" ]] && say "$OK" "Contenedor en ejecución" || { say "$FAIL" "Estado: $STATE"; exit 1; }

ENV_DUMP="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CID" 2>/dev/null || true)"
MISS=0
for v in SENHASEGURA_FINGERPRINT SENHASEGURA_AGENT_PORT SENHASEGURA_ADDRESSES SENHASEGURA_AGENT_SECONDARY; do
  grep -q "^${v}=" <<<"$ENV_DUMP" && say "$OK" "ENV ${v} presente" || { say "$FAIL" "ENV ${v} ausente"; MISS=1; }
done
[[ $MISS -eq 0 ]] || exit 1

# Reachability 51445 hacia cada PAM
IFS=',' read -ra PAMS <<< "$PAM_IPS"
ALL_OK=1
for ip in "${PAMS[@]}"; do
  ip="${ip//[[:space:]]/}"
  if nc -zw3 "$ip" 51445; then
    say "$OK" "Salida a ${ip}:51445 OK"
  else
    say "$WARN" "Sin salida a ${ip}:51445 (posible firewall/proxy perimetral)"
    ALL_OK=0
  fi
done

# Firewalld (solo informativo)
if systemctl is-active --quiet firewalld; then
  Z="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
  P="$(firewall-cmd --zone="$Z" --list-ports 2>/dev/null || true)"
  grep -qw "51445/tcp" <<<"$P" && say "$OK" "51445/tcp permitido en firewalld ($Z)" || say "$WARN" "51445/tcp no permitido en firewalld ($Z)"
fi

echo
echo "===== ESTATUS DEL AGENTE ====="
echo " Runtime:     ${RUNTIME}"
echo " Compose:     ${HAVE_COMPOSE}"
echo " Contenedor:  ${STATE}"
echo " Fingerprint: $(echo "$SNC_FINGERPRINT" | sed -E 's/^(.{6}).*(.{6})$/\1…\2/')"
echo " PAM IP(s):   ${PAM_IPS}"
echo " Puerto:      ${AGENT_PORT} (no publicado en host)"
echo " Reach 51445: $([[ $ALL_OK -eq 1 ]] && echo OK || echo WARN)"
echo "=============================="
