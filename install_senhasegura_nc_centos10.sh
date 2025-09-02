#!/bin/bash
set -euo pipefail

# ==========================
# SENHASEGURA NETWORK CONNECTOR INSTALLER (CentOS Stream 10 / RHEL 10)
# - Instala Docker CE si está disponible; si no, cae a Podman (podman-docker + podman-compose)
# - Abre el puerto 51445 con firewalld (o iptables si no está firewalld)
# - Genera docker-compose.yml y levanta el contenedor del agente
# ==========================

# --- Seguridad básica (opcional) ---
PASSWORD="Segura2025"
read -s -p " Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi

# --- Constantes / Paths ---
INSTALL_DIR="/opt/senhasegura/network-connector"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AGENT_IMAGE="registry.senhasegura.io/network-connector/agent-v2:latest"
LOGFILE="/var/tmp/install_nc_$(date +%Y%m%d_%H%M%S).log"

OK="\033[1;32m[OK]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
INFO="\033[1;36m[INFO]\033[0m"

print_status() {
  local status="$1"; shift
  echo -e " ➔ $status $*" | tee -a "$LOGFILE"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "$FAIL Debes ejecutar como root."
    exit 1
  fi
}

# --- Utilidades ---
pkg_install() {
  # dnf para CentOS/RHEL 10
  dnf -y install "$@" 2>&1 | tee -a "$LOGFILE"
}

enable_start() {
  systemctl enable --now "$1" 2>&1 | tee -a "$LOGFILE" || true
}

# --- Inicio ---
require_root
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

print_status "$INFO" "Actualizando metadatos de paquetes"
dnf -y makecache 2>&1 | tee -a "$LOGFILE"

# Herramientas base
print_status "$INFO" "Instalando dependencias base"
pkg_install curl tar jq iproute procps-ng \
  || print_status "$WARN" "Algunas dependencias ya estaban instaladas"

# netcat en RHEL/CentOS es nmap-ncat
if ! command -v nc >/dev/null 2>&1; then
  pkg_install nmap-ncat || true
fi

# --- Abrir puerto 51445 (registry.senhasegura.io) ---
print_status "$INFO" "Probando conectividad TCP 51445 hacia registry.senhasegura.io"
if nc -zvw2 registry.senhasegura.io 51445 >/dev/null 2>&1; then
  print_status "$OK" "Puerto 51445 accesible"
else
  print_status "$WARN" "Puerto 51445 inaccesible, intentando abrir con firewalld"
  if command -v firewall-cmd >/dev/null 2>&1; then
    enable_start firewalld
    firewall-cmd --permanent --add-port=51445/tcp 2>&1 | tee -a "$LOGFILE" || true
    firewall-cmd --reload 2>&1 | tee -a "$LOGFILE" || true
  else
    print_status "$WARN" "firewalld no está presente, usando iptables temporalmente"
    iptables -C INPUT -p tcp --dport 51445 -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport 51445 -j ACCEPT
    # persistencia iptables no cubierta (recomendado instalar firewalld)
  fi
  sleep 2
  if nc -zvw2 registry.senhasegura.io 51445 >/dev/null 2>&1; then
    print_status "$OK" "Puerto 51445 ahora accesible"
  else
    print_status "$FAIL" "No se pudo abrir el puerto 51445 (ver firewall/red). Continuando de todos modos..."
  fi
fi

# --- Solicitar datos ---
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
    echo -e "$FAIL Formato incorrecto. Solo IPs, sin puertos."
  fi
  if [[ "$PAM_ADDRESS" =~ ":" ]]; then
    echo -e "$WARN No incluyas puertos en SENHASEGURA_ADDRESSES. Solo IPs."
  fi
done

read -rp " ¿Es agente secundario? (true/false): " IS_SECONDARY
IS_SECONDARY="${IS_SECONDARY,,}"
[[ "$IS_SECONDARY" == "true" || "$IS_SECONDARY" == "false" ]] || IS_SECONDARY="false"

# --- Docker/Podman instalación inteligente ---
HAVE_DOCKER=0
HAVE_DOCKER_COMPOSE=0

print_status "$INFO" "Intentando instalar Docker CE (si está disponible para este release)"
# Repo oficial Docker (puede no tener todavía el release de el10; probamos el de el9 como fallback)
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
  dnf -y install dnf-plugins-core 2>&1 | tee -a "$LOGFILE" || true
  # Primero intentamos el repo el10; si falla, probamos el9.
  curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo || true
fi

# Intento 1: paquetes docker-ce (si existen para el release)
if dnf list --available docker-ce >/dev/null 2>&1; then
  pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  HAVE_DOCKER=1
  HAVE_DOCKER_COMPOSE=1
  enable_start docker
else
  print_status "$WARN" "Paquetes docker-ce no disponibles para este release. Probando con Moby/Podman…"
  # Intento 2: Podman + compatibilidad
  pkg_install podman podman-docker || true
  # Composición: preferimos plugin de docker si existe; de lo contrario, podman-compose
  if ! command -v docker >/dev/null 2>&1; then
    # 'podman-docker' crea /usr/bin/docker compat
    ln -sf /usr/bin/podman /usr/bin/docker
  fi

  # Podman socket (opcional, no requerido para 'docker' CLI)
  systemctl enable --now podman.socket 2>/dev/null || true

  # docker compose (plugin) no existe con podman; usamos docker-compose v1 o podman-compose
  if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    # preferimos podman-compose desde repos
    if dnf list --available podman-compose >/dev/null 2>&1; then
      pkg_install podman-compose
      HAVE_DOCKER_COMPOSE=1
    else
      # Último recurso: binario docker-compose v1 (funciona con podman-docker en muchos casos)
