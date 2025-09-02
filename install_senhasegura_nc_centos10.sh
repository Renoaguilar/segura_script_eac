#!/bin/bash
set -euo pipefail

# ==========================
# SENHASEGURA NETWORK CONNECTOR INSTALLER (CentOS Stream 10 / RHEL 10)
# Genera docker-compose.yml conforme a documentación oficial (SENHASEGURA_*),
# levanta el agente y ejecuta pruebas básicas al final.
# ==========================

PASSWORD="Segura2025"

OK="\033[1;32m[OK]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
INFO="\033[1;36m[INFO]\033[0m"

say(){ echo -e " ➔ $1 $2"; }
need_root(){ [[ $EUID -eq 0 ]] || { say "$FAIL" "Ejecuta como root."; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }
pkg(){ dnf -y install "$@" >/dev/null; }
enable_now(){ systemctl enable --now "$1" >/dev/null 2>&1 || true; }

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SERVICE_NAME="senhasegura-network-connector-agent"
IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

# --- Autenticación básica (opcional)
read -s -p " Ingresa la contraseña para ejecutar este script: " _pw; echo
[[ "$_pw" == "$PASSWORD" ]] || { echo "❌ Contraseña incorrecta"; exit 1; }

need_root
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

say "$INFO" "Preparando utilidades"
dnf -y makecache >/dev/null
pkg curl tar jq iproute procps-ng >/dev/null || true
has nc || pkg nmap-ncat >/dev/null || true
has firewall-cmd || true

# --- Datos requeridos (según docs)
while true; do
  read -rp " FINGERPRINT (SENHASEGURA_FINGERPRINT): " SENHASEGURA_FINGERPRINT
  [[ -n "$SENHASEGURA_FINGERPRINT" ]] && break || say "$WARN" "No puede quedar vacío."
done

while true; do
  read -rp " PUERTO del agente 30000-30999 (SENHASEGURA_AGENT_PORT): " SENHASEGURA_AGENT_PORT
  [[ "$SENHASEGURA_AGENT_PORT" =~ ^30[0-9]{3}$ ]] && break || say "$WARN" "Puerto inválido."
done

while true; do
  read -rp " IP(s) de la(s) instancia(s) Segura (SENHASEGURA_ADDRESSES, separadas por coma SIN espacios): " SENHASEGURA_ADDRESSES
  [[ "$SENHASEGURA_ADDRESSES" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(,[0-9]{1,3}(\.[0-9]{1,3}){3})*$ ]] && break || say "$WARN" "Formato inválido."
done

read -rp " ¿Es agente secundario? (true/false) [false]: " SENHASEGURA_AGENT_SECONDARY
SENHASEGURA_AGENT_SECONDARY="${SENHASEGURA_AGENT_SECONDARY,,}"
[[ "$SENHASEGURA_AGENT_SECONDARY" == "true" || "$SENHASEGURA_AGENT_SECONDARY" == "false" ]] || SENHASEGURA_AGENT_SECONDARY="false"

# --- Docker/Podman
say "$INFO" "Instalando runtime (Docker/Podman)"
if ! has docker; then
  dnf -y install dnf-plugins-core >/dev/null || true
  curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo || true
fi

HAVE_COMPOSE="no"
if dnf list --available docker-ce >/dev/null 2>&1; then
  pkg docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
  enable_now docker
  has docker && docker compose version >/dev/null 2>&1 && HAVE_COMPOSE="plugin"
else
  # Fallback a Podman con compatibilidad
  pkg podman podman-docker || true
  [[ -x /usr/bin/docker ]] || ln -sf /usr/bin/podman /usr/bin/docker
  systemctl enable --now podman.socket >/dev/null 2>&1 || true
  if dnf list --available podman-compose >/dev/null 2>&1; then
    pkg podman-compose || true
    HAVE_COMPOSE="v1"
  else
    # docker-compose v1 standalone (funciona con podman-docker)
    curl -fsSL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    HAVE_COMPOSE="v1"
  fi
fi

# Detección final de compose
if [[ "$HAVE_COMPOSE" == "no" ]]; then
  if docker compose version >/dev/null 2>&1; then HAVE_COMPOSE="plugin"
  elif command -v docker-compose >/dev/null 2>&1; then HAVE_COMPOSE="v1"
  else
    say "$FAIL" "No hay docker compose disponible."; exit 1
  fi
fi

# --- Firewall local: mostramos (no tocamos aún)
if command -v firewall-cmd >/dev/null 2>&1; then
  say "$INFO" "firewalld detectado. Recuerda permitir: 51445/tcp (egreso registry) y ${SENHASEGURA_AGENT_PORT}/tcp."
fi

# --- Generar docker-compose.yml conforme DOCS
#   Nota: DOCS muestran servicio, imagen, restart, networks y environment con claves SENHASEGURA_*.
#   Agregamos 'ports' para exponer el puerto del agente en el host (sin romper el formato de DOCS).
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
  ${SERVICE_NAME}:
    image: "${IMAGE}"
    restart: unless-stopped
    networks:
      - senhasegura-network-connector
    ports:
      - "${SENHASEGURA_AGENT_PORT}:${SENHASEGURA_AGENT_PORT}"
    environment:
      SENHASEGURA_FINGERPRINT: "${SENHASEGURA_FINGERPRINT}"
      SENHASEGURA_AGENT_PORT: "${SENHASEGURA_AGENT_PORT}"
      SENHASEGURA_ADDRESSES: "${SENHASEGURA_ADDRESSES}"
      SENHASEGURA_AGENT_SECONDARY: "${SENHASEGURA_AGENT_SECONDARY}"
networks:
  senhasegura-network-connector:
    driver: bridge
EOF

say "$OK" "docker-compose.yml generado en $COMPOSE_FILE"
echo "-----"; cat "$COMPOSE_FILE"; echo "-----"

# --- Levantar
say "$INFO" "Levantando el agente…"
if [[ "$HAVE_COMPOSE" == "plugin" ]]; then
  docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  docker compose -f "$COMPOSE_FILE" up -d
else
  docker-compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  docker-compose -f "$COMPOSE_FILE" up -d
fi

# --- Espera breve y tests
sleep 5

STATUS_FAIL=0
NAME="$SERVICE_NAME"

# 1) Contenedor corriendo
STATE="$(docker inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null || echo "unknown")"
if [[ "$STATE" == "running" ]]; then
  say "$OK" "Contenedor '$NAME' en ejecución."
else
  say "$FAIL" "Contenedor '$NAME' no está corriendo (estado: $STATE)."
  STATUS_FAIL=1
fi

# 2) Variables dentro del contenedor
ENV_OUT="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null || true)"
for v in SENHASEGURA_FINGERPRINT SENHASEGURA_AGENT_PORT SENHASEGURA_ADDRESSES SENHASEGURA_AGENT_SECONDARY; do
  if grep -q "^${v}=" <<<"$ENV_OUT"; then
    say "$OK" "ENV ${v} presente."
  else
    say "$FAIL" "ENV ${v} ausente."
    STATUS_FAIL=1
  fi
done

# 3) Puerto escuchando en host (por mapeo ports:)
if ss -ltn "( sport = :$SENHASEGURA_AGENT_PORT )" | awk 'NR>1{print}' | grep -q .; then
  say "$OK" "Puerto ${SENHASEGURA_AGENT_PORT}/tcp en escucha en el host."
else
  say "$FAIL" "Puerto ${SENHASEGURA_AGENT_PORT}/tcp NO aparece en escucha en el host."
  STATUS_FAIL=1
fi

# 4) Egreso a registry 51445 (no bloqueante)
if nc -zvw2 registry.senhasegura.io 51445 >/dev/null 2>&1; then
  say "$OK" "Salida a registry.senhasegura.io:51445 OK."
else
  say "$WARN" "Sin salida a registry.senhasegura.io:51445 (posible firewall perimetral)."
fi

# 5) Firewalld: solo informar (no cambia reglas)
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  PORTS="$(firewall-cmd --list-ports 2>/dev/null || true)"
  if grep -qw "51445/tcp" <<<"$PORTS"; then
    say "$OK" "51445/tcp permitido en firewalld."
  else
    say "$WARN" "51445/tcp NO aparece permitido en firewalld."
  fi
  if grep -qw "${SENHASEGURA_AGENT_PORT}/tcp" <<<"$PORTS"; then
    say "$OK" "${SENHASEGURA_AGENT_PORT}/tcp permitido en firewalld."
  else
    say "$WARN" "${SENHASEGURA_AGENT_PORT}/tcp NO aparece permitido en firewalld."
  fi
fi

# 6) Mensaje final + hint de logs
echo
if [[ "$STATUS_FAIL" -eq 0 ]]; then
  say "$OK" "Instalación y pruebas básicas completadas."
else
  say "$WARN" "Instalado con observaciones. Revisa logs:"
fi
echo "    docker logs -f ${NAME} | sed -n '1,120p'"

exit "$STATUS_FAIL"
