#!/usr/bin/env bash
###############################################################################
# 🔍 Senhasegura Troubleshooting v2.0
# - Diagnóstico visual y estructurado para entornos Senhasegura
# - Requiere bash y permisos root
###############################################################################

# ========= 🔐 Password Protect =========
PASSWORD="Segura2025"
read -s -p "🔐 Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi

# ========= Colores =========
if [[ -t 1 ]]; then
  NC=$'\e[0m'; BOLD=$'\e[1m'
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
else
  NC=""; BOLD=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*"; }
h1()   { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ========= Variables =========
REPORT_DIR="/tmp/segura_diag"
REPORT_FILE="$REPORT_DIR/segura_diag_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p "$REPORT_DIR"
: > "$REPORT_FILE"

append(){ echo "$*" >> "$REPORT_FILE"; }

START_TS=$(date +%s)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

# ========= Funciones =========

check_system(){
  h1 "1 - Sistema Operativo y Recursos"
  uname -a | tee -a "$REPORT_FILE"
  cat /etc/os-release | tee -a "$REPORT_FILE"
  cpus=$(nproc)
  mem_used=$(free -m | awk '/Mem:/ {print $3}')
  mem_total=$(free -m | awk '/Mem:/ {print $2}')
  mem_pct=$((mem_total>0 ? (100*mem_used/mem_total) : 0))
  load1=$(awk '{print $1}' /proc/loadavg)
  echo "CPUs: $cpus | Memoria usada: ${mem_used}MB (${mem_pct}%) | Load: $load1" | tee -a "$REPORT_FILE"
  df -hP | sort -k5 -hr | tee -a "$REPORT_FILE"
}

check_network(){
  h1 "2 - Red y Conectividad"
  ip -brief addr | tee -a "$REPORT_FILE"
  ip route | tee -a "$REPORT_FILE"
  for host in docs.senhasegura.io downloads.senhasegura.io community.senhasegura.io; do
    if getent ahosts "$host" >/dev/null; then ok "Resuelve $host"; else warn "No resuelve $host"; fi
    if timeout 3 bash -c ">/dev/tcp/$host/443" 2>/dev/null; then ok "TCP 443 OK → $host"; else warn "TCP 443 FAIL → $host"; fi
  done
  ss -tulpen | tee -a "$REPORT_FILE"
}

check_docker(){
  h1 "3 - Contenedores Docker"
  if ! command -v docker >/dev/null; then err "Docker no instalado"; return; fi
  systemctl is-active docker >/dev/null && ok "Docker activo" || warn "Docker inactivo"
  docker ps | tee -a "$REPORT_FILE"
  for c in $(docker ps --format '{{.Names}}'); do
    status=$(docker inspect --format '{{.State.Status}}' "$c")
    if [[ "$status" != "running" ]]; then warn "Container $c en estado $status"; fi
    docker logs --tail 50 "$c" 2>&1 | grep -Eqi 'ERROR|FATAL|exception' && warn "Errores en logs de $c"
  done
}

check_orbit_services(){
  h1 "4 - Servicios Orbit"
  orbit version | tee -a "$REPORT_FILE"
  orbit app version | tee -a "$REPORT_FILE"
  orbit upgrade --check | tee -a "$REPORT_FILE"
  orbit services list | tee -a "$REPORT_FILE"
  orbit service status | tee -a "$REPORT_FILE"
  orbit app status | tee -a "$REPORT_FILE"
}

check_proxies(){
  h1 "5 - Proxies"
  for p in fajita jumpserver rdpgate nss; do
    orbit proxy "$p" status | tee -a "$REPORT_FILE"
  done
}

check_domum(){
  h1 "6 - Domum Gateway"
  orbit domum-gateway status | tee -a "$REPORT_FILE"
  docker logs --tail 50 domum-gateway-client 2>/dev/null | tee -a "$REPORT_FILE"
}

check_nats(){
  h1 "7 - NATS / Async"
  orbit nats stream ls | tee -a "$REPORT_FILE"
  orbit nats stream subjects | tee -a "$REPORT_FILE"
  tail -n 50 /var/log/senhasegura/async/async.log 2>/dev/null | tee -a "$REPORT_FILE"
}

check_backup(){
  h1 "8 - Backup"
  orbit backup time --show | tee -a "$REPORT_FILE"
  ls -lh /var/senhasegura/backup/ 2>/dev/null | head -n 5 | tee -a "$REPORT_FILE"
}

check_cert(){
  h1 "9 - Certificados Web"
  orbit webssl | tee -a "$REPORT_FILE"
}

check_security(){
  h1 "10 - Seguridad"
  getenforce 2>/dev/null | tee -a "$REPORT_FILE"
  orbit firewall status | tee -a "$REPORT_FILE"
  orbit wazuh whitelist list 2>/dev/null | tee -a "$REPORT_FILE"
}

check_healthcheck(){
  h1 "11 - Healthcheck"
  orbit healthcheck run | tee -a "$REPORT_FILE"
  ls -lh /var/senhasegura/healthcheck/ 2>/dev/null | tee -a "$REPORT_FILE"
}

check_disk(){
  h1 "12 - Disco Orbit"
  orbit disk --show | tee -a "$REPORT_FILE"
  du -h --max-depth=1 / 2>/dev/null | sort -hr | head -n 10 | tee -a "$REPORT_FILE"
}

check_logs(){
  h1 "13 - Logs Senhasegura"
  find /var/log/senhasegura -type f -printf '%s %p\n' 2>/dev/null | sort -nr | head -n 10 | awk '{printf "%8.1f MB %s\n",$1/1024/1024,$2}' | tee -a "$REPORT_FILE"
  for f in $(find /var/log/senhasegura -type f -size +1M 2>/dev/null | head -n 3); do
    echo "--- $f ---" | tee -a "$REPORT_FILE"
    tail -n 50 "$f" | tee -a "$REPORT_FILE"
  done
}

# ========= Ejecución =========
h1 "🔍 Senhasegura Troubleshooting v2.0"
echo "Host: $HOSTNAME" | tee -a "$REPORT_FILE"
echo "Fecha: $(date)" | tee -a "$REPORT_FILE"

check_system
check_network
check_docker
check_orbit_services
check_proxies
check_domum
check_nats
check_backup
check_cert
check_security
check_healthcheck
check_disk
check_logs

END_TS=$(date +%s)
DUR=$((END_TS - START_TS))

h1 "✅ Resumen"
echo "Reporte generado en: $REPORT_FILE"
echo "Duración total: ${DUR}s"
