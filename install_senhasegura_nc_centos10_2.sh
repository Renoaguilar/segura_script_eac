#!/usr/bin/env bash
# ==========================================================
# Network Connector - Installer + Doctor (CentOS Stream/RHEL 10)
# Guía oficial: Docker+Compose, env con "comillas", sin ports por defecto.
# Opcional: PUBLICAR_PUERTO=yes para añadir ports y abrir firewalld.
# ==========================================================
set -euo pipefail

OK=$'\033[1;32m[OK]\033[0m'; WARN=$'\033[1;33m[WARN]\033[0m'; FAIL=$'\033[1;31m[FAIL]\033[0m'; INFO=$'\033[1;36m[INFO]\033[0m'
say(){ echo -e " ➔ $1 $2"; }
need(){ command -v "$1" >/dev/null 2>&1; }
as_root(){ [[ $EUID -eq 0 ]] || { echo -e "$FAIL Debes ejecutar como root"; exit 1; }; }

# --------- Parámetros ---------
as_root
INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SERVICE_NAME="senhasegura-network-connector-agent"
IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

read -rp " FINGERPRINT (exacto, sin espacios): " SNC_FINGERPRINT
read -rp " IP(s) de PAM (coma separadas, sin espacios): " PAM_IPS
read -rp " Puerto del agente [30000-30999]: " AGENT_PORT
read -rp " ¿Es agente secundario? [true/false]: " IS_SECONDARY
read -rp " ¿Publicar puerto en el host? [yes/no, default no]: " PUBLISH_PORT

SNC_FINGERPRINT="${SNC_FINGERPRINT//[[:space:]]/}"
PAM_IPS="${PAM_IPS// /}"
IS_SECONDARY="${IS_SECONDARY,,}"
PUBLISH_PORT="${PUBLISH_PORT,,}"

[[ "$AGENT_PORT" =~ ^30[0-9]{3}$ ]] || { echo -e "$FAIL Puerto inválido (30000–30999)"; exit 1; }
[[ "$IS_SECONDARY" == "true" || "$IS_SECONDARY" == "false" ]] || { echo -e "$FAIL Valor inválido para secundario"; exit 1; }

# --------- Paquetes base ---------
say "$INFO" "Actualizando e instalando utilidades"
dnf -y makecache >/dev/null
dnf -y install curl jq iproute procps-ng nmap-ncat firewalld dnf-plugins-core >/dev/null || true
systemctl enable --now firewalld >/dev/null 2>&1 || true
ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"

# --------- Docker o Podman (fallback) ---------
RUNTIME="docker"; HAVE_COMPOSE="plugin"
if ! need docker; then
  say "$INFO" "Instalando Docker CE (repo oficial)"
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] || curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo || true
  if ! dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
    say "$WARN" "Sin paquetes docker-ce; usando Podman + compat."
    dnf -y install podman podman-docker >/dev/null
    [[ -x /usr/bin/docker ]] || ln -sf /usr/bin/podman /usr/bin/docker
    systemctl enable --now podman.socket >/dev/null 2>&1 || true
    RUNTIME="podman"; HAVE_COMPOSE="v1"
    if dnf -y install podman-compose >/dev/null 2>&1; then :; else
      curl -fsSL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
  else
    systemctl enable --now docker >/dev/null
  fi
fi

# Detecta compose
if docker compose version >/dev/null 2>&1; then HAVE_COMPOSE="plugin"
elif command -v docker-compose >/dev/null 2>&1; then HAVE_COMPOSE="v1"
fi
say "$OK" "Runtime: ${RUNTIME} | Compose: ${HAVE_COMPOSE}"

mkdir -p "$INSTALL_DIR"

# --------- Generar docker-compose.yml (VALORES ENTRE COMILLAS) ---------
{
  echo "services:"
  echo "  ${SERVICE_NAME}:"
  echo "    image: ${IMAGE}"
  echo "    container_name: ${SERVICE_NAME}"
  echo "    restart: unless-stopped"
  echo "    networks:"
  echo "      - senhasegura-network-connector"
  if [[ "$PUBLISH_PORT" == "yes" || "$PUBLISH_PORT" == "y" ]]; then
    echo "    ports:"
    echo "      - \"${AGENT_PORT}:${AGENT_PORT}\""
  fi
  echo "    environment:"
  echo "      SENHASEGURA_FINGERPRINT: \"${SNC_FINGERPRINT}\""
  echo "      SENHASEGURA_AGENT_PORT: \"${AGENT_PORT}\""
  echo "      SENHASEGURA_ADDRESSES: \"${PAM_IPS}\""
  echo "      SENHASEGURA_AGENT_SECONDARY: \"${IS_SECONDARY}\""
  echo "networks:"
  echo "  senhasegura-network-connector:"
  echo "    driver: bridge"
} >"$COMPOSE_FILE"
say "$OK" "docker-compose.yml generado en ${COMPOSE_FILE}"

# Abre firewalld sólo si se publicó el puerto
if [[ "$PUBLISH_PORT" == "yes" || "$PUBLISH_PORT" == "y" ]]; then
  firewall-cmd --permanent --zone="$ZONE" --add-port="${AGENT_PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
  say "$OK" "firewalld permite ${AGENT_PORT}/tcp en zona ${ZONE}"
fi

# --------- Levantar ----------
cd "$INSTALL_DIR"
if [[ "$HAVE_COMPOSE" == "plugin" ]]; then
  docker compose down --remove-orphans >/dev/null 2>&1 || true
  docker compose up -d
else
  docker-compose down --remove-orphans >/dev/null 2>&1 || true
  docker-compose up -d
fi

# --------- Autotest ----------
say "$INFO" "Ejecutando pruebas…"
CID="$(docker ps -q -f "name=^${SERVICE_NAME}$" -f "label=com.docker.compose.service=${SERVICE_NAME}" | head -n1 || true)"
[[ -z "$CID" ]] && CID="$(docker ps -q --filter "name=${SERVICE_NAME}" | head -n1 || true)"
[[ -z "$CID" ]] && { say "$FAIL" "Contenedor no encontrado"; docker ps; exit 1; }

STATE="$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null || echo unknown)"
[[ "$STATE" == "running" ]] && say "$OK" "Contenedor en ejecución" || { say "$FAIL" "Estado: $STATE"; exit 1; }

ENV_DUMP="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CID" 2>/dev/null || true)"
for v in SENHASEGURA_FINGERPRINT SENHASEGURA_AGENT_PORT SENHASEGURA_ADDRESSES SENHASEGURA_AGENT_SECONDARY; do
  grep -q "^${v}=" <<<"$ENV_DUMP" && say "$OK" "ENV ${v} presente" || { say "$FAIL" "ENV ${v} ausente"; exit 1; }
done

# Puerto en host (sólo si se publicó)
if [[ "$PUBLISH_PORT" == "yes" || "$PUBLISH_PORT" == "y" ]]; then
  ss -ltnp | grep -q ":${AGENT_PORT}\b" && say "$OK" "Puerto ${AGENT_PORT}/tcp en escucha en el host." || say "$FAIL" "Puerto ${AGENT_PORT}/tcp no está en escucha."
fi

# Reach 51445 hacia cada PAM (requisito de la guía)
ALL_OK=1; IFS=',' read -ra PAMS <<< "$PAM_IPS"
for ip in "${PAMS[@]}"; do
  ip="${ip//[[:space:]]/}"
  if nc -zw3 "$ip" 51445; then say "$OK" "Salida a ${ip}:51445 OK"
  else say "$WARN" "Sin salida a ${ip}:51445 (WebSocket)."; ALL_OK=0; fi
done

echo
echo "===== ESTATUS DEL AGENTE ====="
echo " Contenedor:  ${STATE}"
echo " Fingerprint: $(echo "$SNC_FINGERPRINT" | sed -E 's/^(.{6}).*(.{6})$/\1…\2/')"
echo " PAM IP(s):   ${PAM_IPS}"
echo " Puerto:      ${AGENT_PORT} $( [[ "$PUBLISH_PORT" =~ ^y|yes$ ]] && echo '(publicado)' || echo '(no publicado)' )"
echo " Reach 51445: $([[ $ALL_OK -eq 1 ]] && echo OK || echo WARN)"
echo "=============================="
