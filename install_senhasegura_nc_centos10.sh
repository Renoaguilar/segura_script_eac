#!/bin/bash
set -euo pipefail

# ==========================
# SENHASEGURA NETWORK CONNECTOR INSTALLER (CentOS Stream 10 / RHEL 10)
# ==========================

PASSWORD="Segura2025"

OK="\033[1;32m[OK]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
INFO="\033[1;36m[INFO]\033[0m"

print_status() { local s="$1"; shift; echo -e " ➔ $s $*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "$FAIL Debes ejecutar como root."
    exit 1
  fi
}

pkg_install() { dnf -y install "$@" ; }
enable_start() { systemctl enable --now "$1" || true; }

INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AGENT_IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"

# --- Seguridad básica (opcional) ---
read -s -p " Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi

# --- Inicio ---
require_root
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

print_status "$INFO" "Actualizando metadatos de paquetes"
dnf -y makecache

print_status "$INFO" "Instalando dependencias base"
pkg_install curl tar jq iproute procps-ng || true
command -v nc >/dev/null 2>&1 || pkg_install nmap-ncat

# --- Abrir 51445/TCP local (salida a registry.senhasegura.io) ---
print_status "$INFO" "Probando conectividad TCP 51445 hacia registry.senhasegura.io"
if nc -zvw2 registry.senhasegura.io 51445 >/dev/null 2>&1; then
  print_status "$OK" "Puerto 51445 accesible"
else
  print_status "$WARN" "51445 inaccesible, abriendo en firewalld"
  if command -v firewall-cmd >/dev/null 2>&1; then
    enable_start firewalld
    firewall-cmd --permanent --add-port=51445/tcp || true
    firewall-cmd --reload || true
  else
    print_status "$WARN" "firewalld no presente; añadiendo iptables (no persistente)"
    iptables -C INPUT -p tcp --dport 51445 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 51445 -j ACCEPT
  fi
  sleep 2
  if nc -zvw2 registry.senhasegura.io 51445 >/dev/null 2>&1; then
    print_status "$OK" "51445 ahora accesible"
  else
    print_status "$FAIL" "Sigue inaccesible. Puede estar bloqueado en el perímetro; continuaremos."
  fi
fi

# --- Datos requeridos ---
while true; do
  read -rp " FINGERPRINT: " FINGERPRINT
  if [[ "$FINGERPRINT" =~ ^[a-f0-9\-]{36}$ || "$FINGERPRINT" =~ ^[A-Za-z0-9+/=]{60,}$ ]]; then
    break
  else
    echo -e "$FAIL Formato inválido (GUID o Base64 largo)."
  fi
done

while true; do
  read -rp " PUERTO AGENTE (30000-30999): " AGENT_PORT
  [[ "$AGENT_PORT" =~ ^30[0-9]{3}$ ]] && break || echo -e "$FAIL Puerto inválido."
done

while true; do
  read -rp " IP(s) de PAM (coma separadas, sin puerto): " PAM_ADDRESS
  if [[ "$PAM_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(,([0-9]{1,3}\.){3}[0-9]{1,3})*$ ]]; then
    break
  else
    echo -e "$FAIL Solo IPs, sin puertos."
  fi
  if [[ "$PAM_ADDRESS" =~ ":" ]]; then
    echo -e "$WARN No incluyas puertos en SENHASEGURA_ADDRESSES."
  fi
done

read -rp " ¿Es agente secundario? (true/false): " IS_SECONDARY
IS_SECONDARY="${IS_SECONDARY,,}"
[[ "$IS_SECONDARY" == "true" || "$IS_SECONDARY" == "false" ]] || IS_SECONDARY="false"

# --- Docker/Podman ---
print_status "$INFO" "Intentando Docker CE (si hay paquetes para el release)"
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
  dnf -y install dnf-plugins-core || true
  curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo || true
fi

HAVE_COMPOSE="no"

if dnf list --available docker-ce >/dev/null 2>&1; then
  pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
  enable_start docker
  if docker compose version >/dev/null 2>&1; then HAVE_COMPOSE="plugin"; fi
else
  print_status "$WARN" "Sin docker-ce para este release. Usando Podman + compat."
  pkg_install podman podman-docker || true
  command -v docker >/dev/null 2>&1 || ln -sf /usr/bin/podman /usr/bin/docker
  systemctl enable --now podman.socket 2>/dev/null || true
  if command -v docker-compose >/dev/null 2>&1; then
    HAVE_COMPOSE="v1"
  else
    if dnf list --available podman-compose >/dev/null 2>&1; then
      pkg_install podman-compose || true
      HAVE_COMPOSE="podman-compose"
    else
      curl -fsSL "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
      HAVE_COMPOSE="v1"
    fi
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo -e "$FAIL No hay CLI 'docker' disponible (ni podman-docker)."
  exit 1
fi

if [[ "$HAVE_COMPOSE" == "no" ]]; then
  if docker compose version >/dev/null 2>&1; then
    HAVE_COMPOSE="plugin"
  elif command -v docker-compose >/dev/null 2>&1; then
    HAVE_COMPOSE="v1"
  else
    echo -e "$FAIL No se encontró docker compose."
    exit 1
  fi
fi

# --- Generar docker-compose.yml ---
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"
services:
  agent:
    image: ${AGENT_IMAGE}
    container_name: network-connector-agent
    network_mode: host
    restart: unless-stopped
    environment:
      - FINGERPRINT=${FINGERPRINT}
      - SENHASEGURA_ADDRESSES=${PAM_ADDRESS}
      - AGENT_PORT=${AGENT_PORT}
      - IS_SECONDARY=${IS_SECONDARY}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/log:/var/log
EOF

echo -e "$OK docker-compose.yml generado en $COMPOSE_FILE"
echo "-----"
cat "$COMPOSE_FILE"
echo "-----"

# --- Levantar ---
case "$HAVE_COMPOSE" in
  plugin)
    docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
    docker compose -f "$COMPOSE_FILE" up -d
    ;;
  v1)
    docker-compose -f "$COMPOSE_FILE" down --remove-orphans || true
    docker-compose -f "$COMPOSE_FILE" up -d
    ;;
  podman-compose)
    docker-compose -f "$COMPOSE_FILE" down --remove-orphans || true
    docker-compose -f "$COMPOSE_FILE" up -d
    ;;
  *)
    echo -e "$FAIL Estado compose desconocido: $HAVE_COMPOSE"
    exit 1
    ;;
esac

sleep 5
if docker ps --format '{{.Names}}' | grep -q '^network-connector-agent$'; then
  if docker logs network-connector-agent 2>&1 | grep -qi "Agent started"; then
    echo -e "$OK Agente funcionando correctamente."
  else
    echo -e "$WARN Contenedor activo; revisa logs para confirmar inicialización."
  fi
else
  echo -e "$FAIL El contenedor no está corriendo."
  exit 1
fi

exit 0
