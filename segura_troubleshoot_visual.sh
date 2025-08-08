#!/usr/bin/env bash
###############################################################################
# 🔍 Senhasegura Troubleshooting v2.1
# Diagnóstico visual completo con panel resumen
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

badge(){
  case "$1" in
    OK)    echo -e "${GREEN}OK${NC}" ;;
    WARN)  echo -e "${YELLOW}WARN${NC}" ;;
    ERROR) echo -e "${RED}ERROR${NC}" ;;
    *)     echo "$1" ;;
  esac
}

# ========= Variables =========
REPORT_DIR="/tmp/segura_diag"
REPORT_FILE="$REPORT_DIR/segura_diag_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p "$REPORT_DIR"
: > "$REPORT_FILE"

START_TS=$(date +%s)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

# Array para resumen final
declare -a SECTIONS

append(){ echo "$*" >> "$REPORT_FILE"; }
add_section_status(){ # nombre estado detalle
  SECTIONS+=("$1|$2|$3")
}

# ========= Funciones de chequeo =========

check_system(){
  local name="1 - Sistema Operativo y Recursos"
  h1 "$name"
  uname -a | tee -a "$REPORT_FILE"
  cat /etc/os-release | tee -a "$REPORT_FILE"

  cpus=$(nproc)
  mem_used=$(free -m | awk '/Mem:/ {print $3}')
  mem_total=$(free -m | awk '/Mem:/ {print $2}')
  mem_pct=$((mem_total>0 ? (100*mem_used/mem_total) : 0))
  load1=$(awk '{print $1}' /proc/loadavg)
  echo "CPUs: $cpus | Memoria usada: ${mem_used}MB (${mem_pct}%) | Load: $load1" | tee -a "$REPORT_FILE"

  df -hP | sort -k5 -hr | tee -a "$REPORT_FILE"

  local status="OK" detail=""
  ((mem_pct>=90)) && { status="WARN"; detail+="Memoria alta "; }
  awk -v l="$load1" -v c="$cpus" 'BEGIN{exit !(l>c*1.5)}' && { status="WARN"; detail+="Carga alta "; }
  add_section_status "$name" "$status" "$detail"
}

check_network(){
  local name="2 - Red y Conectividad"
  h1 "$name"
  ip -brief addr | tee -a "$REPORT_FILE"
  ip route | tee -a "$REPORT_FILE"

  local status="OK" detail=""
  for host in docs.senhasegura.io downloads.senhasegura.io community.senhasegura.io; do
    if ! getent ahosts "$host" >/dev/null; then status="WARN"; detail+="DNS $host "; fi
    if ! timeout 3 bash -c ">/dev/tcp/$host/443" 2>/dev/null; then status="WARN"; detail+="TCP $host "; fi
  done

  ss -tulpen | tee -a "$REPORT_FILE"
  add_section_status "$name" "$status" "$detail"
}

check_docker(){
  local name="3 - Contenedores Docker"
  h1 "$name"
  local status="OK" detail=""
  if ! command -v docker >/dev/null; then err "Docker no instalado"; add_section_status "$name" "ERROR" "Docker ausente"; return; fi
  systemctl is-active docker >/dev/null || { status="WARN"; detail+="Docker inactivo "; }
  docker ps | tee -a "$REPORT_FILE"
  for c in $(docker ps --format '{{.Names}}'); do
    state=$(docker inspect --format '{{.State.Status}}' "$c")
    if [[ "$state" != "running" ]]; then status="WARN"; detail+="$c $state "; fi
    docker logs --tail 50 "$c" 2>&1 | grep -Eqi 'ERROR|FATAL|exception' && { status="WARN"; detail+="Logs $c "; }
  done
  add_section_status "$name" "$status" "$detail"
}

check_orbit_services(){
  local name="4 - Servicios Orbit"
  h1 "$name"
  local status="OK" detail=""
  orbit version | tee -a "$REPORT_FILE"
  orbit app version | tee -a "$REPORT_FILE"
  orbit upgrade --check | tee -a "$REPORT_FILE"
  orbit services list | tee -a "$REPORT_FILE"
  orbit service status | tee -a "$REPORT_FILE"
  orbit app status | tee -a "$REPORT_FILE" | grep -qi "error\|down" && { status="WARN"; detail+="app status "; }
  add_section_status "$name" "$status" "$detail"
}

check_proxies(){
  local name="5 - Proxies"
  h1 "$name"
  local status="OK" detail=""
  for p in fajita jumpserver rdpgate nss; do
    orbit proxy "$p" status | tee -a "$REPORT_FILE" | grep -qi "error\|stopped" && { status="WARN"; detail+="$p "; }
  done
  add_section_status "$name" "$status" "$detail"
}

check_domum(){
  local name="6 - Domum Gateway"
  h1 "$name"
  local status="OK" detail=""
  orbit domum-gateway status | tee -a "$REPORT_FILE" | grep -qi "error\|down" && { status="WARN"; detail+="gateway "; }
  docker logs --tail 50 domum-gateway-client 2>/dev/null | grep -qi "error" && { status="WARN"; detail+="logs "; }
  add_section_status "$name" "$status" "$detail"
}

check_nats(){
  local name="7 - NATS / Async"
  h1 "$name"
  local status="OK" detail=""
  orbit nats stream ls | tee -a "$REPORT_FILE"
  orbit nats stream subjects | tee -a "$REPORT_FILE"
  tail -n 50 /var/log/senhasegura/async/async.log 2>/dev/null | grep -qi "error" && { status="WARN"; detail+="async "; }
  add_section_status "$name" "$status" "$detail"
}

check_backup(){
  local name="8 - Backup"
  h1 "$name"
  local status="OK" detail=""
  orbit backup time --show | tee -a "$REPORT_FILE"
  ls -lh /var/senhasegura/backup/ 2>/dev/null | head -n 5 | tee -a "$REPORT_FILE"
  add_section_status "$name" "$status" "$detail"
}

check_cert(){
  local name="9 - Certificados Web"
  h1 "$name"
  orbit webssl | tee -a "$REPORT_FILE"
  add_section_status "$name" "OK" ""
}

check_security(){
  local name="10 - Seguridad"
  h1 "$name"
  getenforce 2>/dev/null | tee -a "$REPORT_FILE"
  orbit firewall status | tee -a "$REPORT_FILE"
  orbit wazuh whitelist list 2>/dev/null | tee -a "$REPORT_FILE"
  add_section_status "$name" "OK" ""
}

check_healthcheck(){
  local name="11 - Healthcheck"
  h1 "$name"
  orbit healthcheck run | tee -a "$REPORT_FILE"
  ls -lh /var/senhasegura/healthcheck/ 2>/dev/null | tee -a "$REPORT_FILE"
  add_section_status "$name" "OK" ""
}

check_disk(){
  local name="12 - Disco Orbit"
  h1 "$name"
  orbit disk --show | tee -a "$REPORT_FILE"
  du -h --max-depth=1 / 2>/dev/null | sort -hr | head -n 10 | tee -a "$REPORT_FILE"
  add_section_status "$name" "OK" ""
}

check_logs(){
  local name="13 - Logs Senhasegura"
  h1 "$name"
  find /var/log/senhasegura -type f -printf '%s %p\n' 2>/dev/null | sort -nr | head -n 10 | \
    awk '{printf "%8.1f MB %s\n",$1/1024/1024,$2}' | tee -a "$REPORT_FILE"
  for f in $(find /var/log/senhasegura -type f -size +1M 2>/dev/null | head -n 3); do
    echo "--- $f ---" | tee -a "$REPORT_FILE"
    tail -n 50 "$f" | tee -a "$REPORT_FILE"
  done
  add_section_status "$name" "OK" ""
}

# ========= Ejecución =========
h1 "🔍 Senhasegura Troubleshooting v2.1"
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

# ========= Panel resumen =========
END_TS=$(date +%s)
DUR=$((END_TS - START_TS))

echo -e "\n${BOLD}📊 Panel de Salud:${NC}"
printf "┌%-30s┬%-8s┬%-40s┐\n" "" "" ""
printf "│ %-28s │ %-6s │ %-38s │\n" "Sección" "Estado" "Detalle"
printf "├%-30s┼%-8s┼%-40s┤\n" "" "" ""
for row in "${SECTIONS[@]}"; do
  sec="${row%%|*}"
  rest="${row#*|}"
  st="${rest%%|*}"
  dt="${rest#*|}"
  printf "│ %-28s │ %-6s │ %-38s │\n" "$sec" "$(badge "$st")" "$dt"
done
printf "└%-30s┴%-8s┴%-40s┘\n" "" "" ""

echo -e "\nReporte detallado: $REPORT_FILE"
echo "Duración total: ${DUR}s"
