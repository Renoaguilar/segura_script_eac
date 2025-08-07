#!/usr/bin/env bash
# =============================================================================
# Segura® (Senhasegura) - Troubleshooting Visual (read-only)
# Autor: Agente Técnico Experto en Segura®
# Licencia: MIT
# Descripción:
#   Diagnóstico integral y VISUAL para entornos Segura®/Senhasegura en Linux.
#   * No hace cambios (solo lectura).
#   * Estatus por sección (OK/WARN/ERROR) con detalles resumidos.
#   * Reporte TXT estructurado y resumen JSON opcional.
#   * En almacenamiento, ordena por % de uso (críticos primero).
#
# Uso:
#   bash segura_troubleshoot_visual.sh [--quick] [--json] [--out /ruta/salida.json]
#   bash segura_troubleshoot_visual.sh --network --containers
#
# Filtros:
#   --system --network --containers --orbit --logs
# =============================================================================
# Pass Senhasegura
PASSWORD="Segura2025"

read -s -p "🔐 Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi

set -uo pipefail

VERSION="1.2.1"
START_TS=$(date +%s)
DATE_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
REPORT_DIR="${REPORT_DIR:-/tmp/segura_diag}"
REPORT_FILE="segura_diag_$(date +%Y%m%d_%H%M%S).txt"
JSON_FILE="segura_diag_$(date +%Y%m%d_%H%M%S).json"
MODE_QUICK="0"
FILTERS=()
WANT_JSON="0"
OUT_PATH=""
COLORS=1

# -------------------------- Colores / UI -------------------------------------
if [[ -t 1 ]]; then
  NC=$'\e[0m'; BOLD=$'\e[1m'; DIM=$'\e[2m'
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'
else
  NC=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
  COLORS=0
fi

# Box-drawing
if [[ -t 1 ]]; then
  TL="┌"; TR="┐"; BL="└"; BR="┘"; H="─"; V="│"; SEP="├"; SEPR="┤"; TEE="┬"; BTM="┴"
else
  TL="+"; TR="+"; BL="+"; BR="+"; H="-"; V="|"; SEP="+"; SEPR="+""; TEE="+"; BTM="+"
fi

ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*"; }
info() { echo -e "${CYAN}➤${NC} $*"; }
h1()   { local t="$*"; local L=$(( ${#t} + 2 )); printf "%s\n" "${TL}$(printf "%${L}s" | tr ' ' "${H}")${TR}"; printf "%s %s %s\n" "${V}" "${BOLD}${t}${NC}" "${V}"; printf "%s\n" "${BL}$(printf "%${L}s" | tr ' ' "${H}")${BR}"; }
h2()   { echo -e "${BOLD}› $*${NC}"; }
kv()   { printf "%-30s : %s\n" "$1" "$2"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
secs_to_human(){ awk -v S="$1" 'BEGIN{d=int(S/86400);S%=86400;h=int(S/3600);S%=3600;m=int(S/60);s=S%60; out=""; if(d) out=out d "d "; if(h) out=out h "h "; if(m) out=out m "m "; out=out s "s"; print out}'; }

# -------------------------- JSON con jq --------------------------------------
JSON='{"version":"","timestamp":"","hostname":"","summary":{"ok":0,"warnings":0,"errors":0},"findings":[]}'
jq_add(){
  # $1 sev, $2 title, $3 detail
  JSON=$(printf '%s' "$JSON" | jq --arg s "$1" --arg t "$2" --arg d "$3" '.findings += [{"severity":$s,"title":$t,"detail":$d}]' 2>/dev/null) || true
}
jq_finalize(){
  local okc warnc errc
  okc=$(printf '%s' "$JSON" | jq '[.findings[]|select(.severity=="ok")] | length' 2>/dev/null || echo 0)
  warnc=$(printf '%s' "$JSON" | jq '[.findings[]|select(.severity=="warn")] | length' 2>/dev/null || echo 0)
  errc=$(printf '%s' "$JSON" | jq '[.findings[]|select(.severity=="error")] | length' 2>/dev/null || echo 0)
  JSON=$(printf '%s' "$JSON" | jq --arg v "$VERSION" --arg ts "$DATE_UTC" --arg hn "$HOSTNAME" --argjson ok "$okc" --argjson w "$warnc" --argjson e "$errc" \
        '.version=$v|.timestamp=$ts|.hostname=$hn|.summary={"ok":$ok,"warnings":$w,"errors":$e}' 2>/dev/null) || true
}
# Si no hay jq, desactivar JSON para evitar errores
if ! has_cmd jq; then WANT_JSON="0"; fi

# -------------------------- Reporte ------------------------------------------
mkdir -p "$REPORT_DIR" || { echo "No se pudo crear $REPORT_DIR"; exit 1; }
: > "${REPORT_DIR}/${REPORT_FILE}"
append(){ printf "%s\n" "$*" >> "${REPORT_DIR}/${REPORT_FILE}"; }
append_section(){ local title="$1"; shift; append ""; append "===== ${title} ====="; [[ $# -gt 0 ]] && printf "%s\n" "$@" >> "${REPORT_DIR}/${REPORT_FILE}"; }

# -------------------------- Args ---------------------------------------------
usage(){
  cat <<'EOF'
Uso: segura_troubleshoot_visual.sh [opciones]
  --quick                 Modo rápido (menos pesado)
  --system|--network|--containers|--orbit|--logs  Filtra secciones
  --json                  Produce resumen JSON (requiere jq)
  --out <ruta>            Ruta del JSON de salida
  --no-color              Desactiva color
  -h|--help               Ayuda
  -V|--version            Versión
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) MODE_QUICK="1";;
    --system|--network|--containers|--orbit|--logs) FILTERS+=("${1#--}");;
    --json) WANT_JSON="1";;
    --out) OUT_PATH="${2:-}"; shift;;
    --no-color) COLORS=0; NC=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN="";;
    -h|--help) usage; exit 0;;
    -V|--version) echo "$VERSION"; exit 0;;
    *) err "Opción no reconocida: $1"; usage; exit 1;;
  esac; shift
done
want(){ local t="$1"; [[ ${#FILTERS[@]} -eq 0 ]] && return 0; for f in "${FILTERS[@]}"; do [[ "$f" == "$t" ]] && return 0; done; return 1; }

# -------------------------- Estado por sección -------------------------------
declare -A SECTION_STATUS SECTION_DETAIL
set_section(){ SECTION_STATUS["$1"]="$2"; SECTION_DETAIL["$1"]="$3"; }
print_section_header(){ h1 "$1"; }
print_section_footer(){
  local name="$1"; local st="${SECTION_STATUS[$name]:-OK}"; local dt="${SECTION_DETAIL[$name]:-}"
  local badge; case "$st" in
    OK) badge="${GREEN}[ OK ]${NC}";;
    WARN) badge="${YELLOW}[ WARN ]${NC}";;
    ERROR) badge="${RED}[ ERROR ]${NC}";;
    *) badge="[ $st ]";;
  esac
  echo -e "${V}${H}${H} ${BOLD}Estado sección:${NC} $badge   ${DIM}${dt}${NC}"
}

# ========================== 1) Sistema =======================================
check_system(){
  local name="1) Sistema Operativo y Recursos"
  print_section_header "$name"; append_section "SYSTEM"

  h2 "Información básica"
  {
    echo "## uname -a"; uname -a
    echo; echo "## /etc/os-release"; [[ -r /etc/os-release ]] && cat /etc/os-release || echo "N/A"
    echo; echo "## CPU y Memoria"; echo "- CPUs: $(nproc)"
    echo "- Mem total (MB): $(free -m | awk '/Mem:/ {print $2}')"
  } | tee -a "${REPORT_DIR}/${REPORT_FILE}"

  local load1 cpus mem_used mem_total mem_pct
  load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
  cpus=$(nproc 2>/dev/null || echo 1)
  mem_used=$(free -m | awk '/Mem:/ {print $3}')
  mem_total=$(free -m | awk '/Mem:/ {print $2}')
  mem_pct=$(( mem_total>0 ? (100*mem_used/mem_total) : 0 ))

  echo; h2 "Carga y memoria"
  kv "Load 1m" "$load1"; kv "CPUs" "$cpus"; kv "Memoria usada" "${mem_used}MB (${mem_pct}%)"
  append "load1=$load1 cpus=$cpus mem_used=${mem_used}MB mem_pct=${mem_pct}%"

  local st="OK"; local dt=()
  if awk -v l="$load1" -v c="$cpus" 'BEGIN{exit !(l>c*1.5)}'; then
    warn "Carga alta: $load1 > 1.5x CPUs ($cpus)"; jq_add "warn" "Carga alta" "load1=$load1 cpus=$cpus"; st="WARN"; dt+=("Carga alta")
  else
    ok "Carga adecuada"; jq_add "ok" "Carga adecuada" "load1=$load1 cpus=$cpus"
  fi
  (( mem_pct >= 90 )) && { warn "Memoria alta: ${mem_pct}%"; jq_add "warn" "Memoria alta" "mem_pct=${mem_pct}%"; st="WARN"; dt+=("Memoria ${mem_pct}%"); } || ok "Memoria dentro de rango (${mem_pct}%)"

  echo; h2 "Almacenamiento (ordenado por % uso, críticos primero)"
  mapfile -t DF_LINES < <(df -hP | awk 'NR>1{print $1,$2,$3,$4,$5,$6}')
  printf "%s\n" "${DF_LINES[@]}" | sort -k5 -hr | \
  awk -v G="$GREEN" -v Y="$YELLOW" -v R="$RED" -v N="$NC" '
    BEGIN{printf "  %-6s %-18s %-6s %-7s %-7s %-7s\n","STATE","MOUNT","USE%","SIZE","USED","AVAIL";
          print  "  -----------------------------------------------------------"}
    {
      fs=$1; size=$2; used=$3; avail=$4; usep=$5; mount=$6;
      sub("%","",usep); state="OK"; color=G;
      if (usep>=95){state="CRIT"; color=R}
      else if (usep>=85){state="WARN"; color=Y}
      printf "  %s%s%-6s%s %-18s %3d%%%6s %7s %7s %7s\n", color,"",state,N, mount, usep, "", size, used, avail
    }'
  while read -r fs size used avail usep mount; do
    pct=${usep%%%}
    if (( pct >= 95 )); then jq_add "error" "Disco crítico" "mount=$mount usage=$usep"; st="ERROR"; dt+=("Disco $mount $usep")
    elif (( pct >= 85 )); then jq_add "warn"  "Disco alto"    "mount=$mount usage=$usep"; [[ "$st" == "OK" ]] && st="WARN"
    fi
  done < <(df -hP | awk 'NR>1{print $1,$2,$3,$4,$5,$6}')

  echo; h2 "Inodos"
  df -iP | awk 'NR==1{print;next}{printf "%-35s %10s %10s %10s %6s %s\n",$1,$2,$3,$4,$5,$6}' | tee -a "${REPORT_DIR}/${REPORT_FILE}"
  while read -r fs inodes iused ifree ipct mount; do
    ip=${ipct%%%}; if (( ip >= 90 )); then warn "Inodos altos en $mount ($ipct)"; jq_add "warn" "Inodos altos" "mount=$mount usage=$ipct"; [[ "$st" == "OK" ]] && st="WARN"; dt+=("Inodos $mount $ipct"); fi
  done < <(df -iP | awk 'NR>1{print $1,$2,$3,$4,$5,$6}')

  echo; h2 "SELinux/AppArmor y hora"
  if has_cmd getenforce; then se=$(getenforce); kv "SELinux" "$se"; append "SELinux=$se"
  elif [[ -d /sys/kernel/security/apparmor ]]; then kv "AppArmor" "presente"; append "AppArmor=present"
  else kv "MAC" "no detectado"; append "MAC=none"; fi
  timedatectl 2>/dev/null | sed 's/^/  /' | tee -a "${REPORT_DIR}/${REPORT_FILE}" >/dev/null

  set_section "$name" "$st" "$(IFS=';'; echo "${dt[*]}")"; print_section_footer "$name"
}

# ========================== 2) Red / DNS / Puertos ===========================
check_network(){
  local name="2) Red, DNS y Puertos"
  print_section_header "$name"; append_section "NETWORK"

  h2 "Interfaces y rutas"
  (ip -brief addr 2>/dev/null || ip addr) | sed 's/^/  /'; echo
  (ip route 2>/dev/null || route -n) | sed 's/^/  /'

  echo; h2 "DNS y conectividad a endpoints oficiales"
  local st="OK"; local dt=(); local hosts=("docs.senhasegura.io" "downloads.senhasegura.io" "community.senhasegura.io")
  for h in "${hosts[@]}"; do
    if getent ahosts "$h" >/dev/null 2>&1; then ok "Resuelve $h"; jq_add "ok" "DNS ok" "$h"
    else warn "No resuelve $h"; jq_add "warn" "DNS fallo" "$h"; st="WARN"; dt+=("DNS $h"); fi
  done

  echo; h2 "Conexión TCP:443"
  for h in "${hosts[@]}"; do
    if timeout 4 bash -c ">/dev/tcp/$h/443" 2>/dev/null; then ok "TCP 443 OK → $h"
    else warn "TCP 443 FAIL → $h"; jq_add "warn" "Conectividad 443" "$h"; [[ "$st" == "OK" ]] && st="WARN"; dt+=("443 $h"); fi
  done

  echo; h2 "Puertos locales relevantes"
  local ports=(22 80 443 51445 3306 6379) listening=0
  for p in "${ports[@]}"; do
    if ss -lntp 2>/dev/null | awk -v P=":$p" '$4 ~ P {found=1} END{exit !found}'; then printf "  %s %s\n" "$(printf "${GREEN}LISTEN${NC}")" "$p"; ((listening++))
    else printf "  %s %s\n" "$(printf "${YELLOW}CLOSED${NC}")" "$p"; fi
  done

  echo; h2 "Firewall (vista rápida)"
  if has_cmd firewall-cmd; then firewall-cmd --state >/dev/null 2>&1 && kv "firewalld" "activo" || kv "firewalld" "inactivo"; echo "  Puertos:"; firewall-cmd --list-ports 2>/dev/null | sed 's/^/   - /'
  elif has_cmd nft; then echo "  nft ruleset (primeras 100 líneas):"; nft list ruleset 2>/dev/null | head -100 | sed 's/^/   /'
  elif has_cmd iptables; then echo "  iptables (primeras 100 líneas):"; iptables -S 2>/dev/null | head -100 | sed 's/^/   /'
  else warn "No se detectó firewalld/nftables/iptables"; fi

  [[ $listening -eq 0 ]] && { st="WARN"; dt+=("Sin puertos base escuchando"); }
  set_section "$name" "$st" "$(IFS=';'; echo "${dt[*]}")"; print_section_footer "$name"
}

# ========================== 3) Contenedores ==================================
check_containers(){
  local name="3) Contenedores y Runtime"
  print_section_header "$name"; append_section "CONTAINERS"
  local st="OK"; local dt=()
  if ! has_cmd docker; then err "Docker no está instalado"; jq_add "error" "Docker ausente" "binario docker no encontrado"; set_section "$name" "ERROR" "Docker ausente"; print_section_footer "$name"; return 0; fi
  systemctl is-active docker >/dev/null 2>&1 && ok "Docker activo" || { warn "Docker inactivo"; jq_add "warn" "Docker inactivo" "systemctl != active"; st="WARN"; dt+=("Docker inactivo"); }

  echo; h2 "Contenedores en ejecución"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

  mapfile -t seg_conts < <(docker ps --format '{{.Names}}' | grep -Ei 'senhasegura|segura|pam|arbitrator|mysql|mariadb|redis|nginx' || true)
  local bad_ct=0
  if [[ ${#seg_conts[@]} -eq 0 ]]; then warn "No se detectaron contenedores típicos de Segura®"; jq_add "warn" "Contenedores no detectados" "nombres no coinciden"; st="WARN"; dt+=("No hay containers Segura®")
  else
    echo; h2 "Salud de contenedores Segura®"
    for c in "${seg_conts[@]}"; do
      status=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo "unknown")
      if [[ "$status" != "running" ]]; then warn "Container $c en estado $status"; jq_add "warn" "Container no running" "container=$c status=$status"; ((bad_ct++)); st="WARN"
      else ok "Container $c running"; fi
    done
  fi

  if [[ "$MODE_QUICK" == "0" && ${#seg_conts[@]} -gt 0 ]]; then
    echo; h2 "Logs (tail 120) con detección de errores"
    for c in "${seg_conts[@]}"; do
      echo -e "\n--- $c ---"; docker logs --tail 120 "$c" 2>&1 | sed 's/^/  /'
      if docker logs --tail 120 "$c" 2>&1 | grep -Eqi 'ERROR|FATAL|panic|exception'; then warn "Posibles errores en $c"; jq_add "warn" "Errores en logs" "container=$c"; st="WARN"; dt+=("Logs $c"); fi
    done
  fi
  set_section "$name" "$st" "$(IFS=';'; echo "${dt[*]}")"; print_section_footer "$name"
}

# ========================== 4) Orbit CLI =====================================
check_orbit(){
  local name="4) Orbit CLI y Apps"
  print_section_header "$name"; append_section "ORBIT"
  local st="OK"; local dt=()
  if ! has_cmd orbit; then err "Orbit CLI no encontrado"; jq_add "error" "Orbit ausente" "binario orbit no encontrado"; set_section "$name" "ERROR" "Orbit no instalado"; print_section_footer "$name"; return 0; fi

  echo; h2 "Versiones"
  echo "  orbit version:"; orbit version 2>&1 | sed 's/^/    /' || true
  echo "  orbit app version:"; orbit app version 2>&1 | sed 's/^/    /' || true

  echo; h2 "Estado de aplicaciones"
  if orbit app status >/dev/null 2>&1; then
    orbit app status 2>&1 | sed 's/^/  /'
    bad=$(orbit app status 2>&1 | grep -Eiv 'healthy|running|up|ok' | grep -Ei 'down|unhealthy|error|failed' || true)
    if [[ -n "$bad" ]]; then warn "Apps con estado no saludable"; jq_add "warn" "Apps no healthy" "$(printf '%s\n' "$bad" | head -10)"; st="WARN"; dt+=("apps no healthy")
    else ok "Apps healthy"; jq_add "ok" "Apps healthy" ""; fi
  else
    warn "orbit app status no disponible"; jq_add "warn" "app status N/A" ""; [[ "$st" == "OK" ]] && st="WARN"; dt+=("app status N/A")
  fi

  for proxy in ssh rdp web; do
    if orbit proxy "$proxy" status >/dev/null 2>&1; then echo; h2 "Proxy ${proxy^^}"; orbit proxy "$proxy" status 2>&1 | sed 's/^/  /'; fi
  done

  if [[ "$MODE_QUICK" == "0" ]]; then
    echo; h2 "Logs de orbit (tail 200)"
    if orbit logs --tail=200 >/dev/null 2>&1; then
      orbit logs --tail=200 2>&1 | sed 's/^/  /'
      if orbit logs --tail=200 2>&1 | grep -Eqi 'ERROR|FATAL|exception'; then warn "Errores recientes en orbit logs"; jq_add "warn" "Errores en orbit logs" ""; [[ "$st" == "OK" ]] && st="WARN"; dt+=("orbit logs"); fi
    else
      warn "orbit logs --tail no soportado"; jq_add "warn" "orbit logs N/A" ""
    fi
  fi

  set_section "$name" "$st" "$(IFS=';'; echo "${dt[*]}")"; print_section_footer "$name"
}

# ========================== 5) Logs de aplicación ============================
check_logs(){
  local name="5) Logs de Aplicación (ligero)"
  print_section_header "$name"; append_section "APP LOGS"
  local st="OK"; local dt=(); local base="/var/log/senhasegura"
  if [[ -d "$base" ]]; then
    h2 "Top directorios por tamaño"
    du -h --max-depth=1 "$base" 2>/dev/null | sort -hr | head -10 | sed 's/^/  /'
    echo; h2 "Archivos de log más pesados"
    find "$base" -type f -printf '%s %p\n' 2>/dev/null | sort -nr | head -10 | awk '{printf "  %8.1f MB  %s\n",$1/1024/1024,$2}'
    if [[ "$MODE_QUICK" == "0" ]]; then
      echo; h2 "Errores recientes (tail 120 de logs grandes)"
      mapfile -t biglogs < <(find "$base" -type f -name "*.log" -size +1M 2>/dev/null | head -10)
      for f in "${biglogs[@]}"; do
        echo -e "\n--- $f ---"; tail -n 120 "$f" 2>/dev/null | sed 's/^/  /'
        if tail -n 120 "$f" 2>/dev/null | grep -Eqi 'ERROR|FATAL|exception|traceback'; then warn "Errores en $f"; jq_add "warn" "Errores en log" "$f"; [[ "$st" == "OK" ]] && st="WARN"; dt+=("errores en logs"); fi
      done
    fi
  else
    warn "Directorio $base no existe"; jq_add "warn" "Logs no encontrados" "$base"; [[ "$st" == "OK" ]] && st="WARN"; dt+=("logs N/A")
  fi
  set_section "$name" "$st" "$(IFS=';'; echo "${dt[*]}")"; print_section_footer "$name"
}

# ========================== Ejecución ========================================
h1 "Segura® Troubleshooting VISUAL v$VERSION"
kv "Host" "$HOSTNAME"; kv "Fecha (UTC)" "$DATE_UTC"; kv "Modo rápido" "$MODE_QUICK"; kv "Filtros" "${FILTERS[*]:-ninguno}"
append_section "HEADER" "host=$HOSTNAME" "timestamp=$DATE_UTC" "version=$VERSION" "quick=$MODE_QUICK" "filters=${FILTERS[*]:-none}"

run_all(){ local ran=0
  want system && { check_system; ran=1; }
  want network && { check_network; ran=1; }
  want containers && { check_containers; ran=1; }
  want orbit && { check_orbit; ran=1; }
  want logs && { check_logs; ran=1; }
  [[ $ran -eq 0 ]] && { check_system; check_network; check_containers; check_orbit; check_logs; }
}
run_all

# ========================== Panel final ======================================
END_TS=$(date +%s); DUR=$((END_TS-START_TS))
echo; h1 "Panel de Salud - Resumen por Sección"
printf "%s\n" "${TL}$(printf "%-20s" | tr ' ' "${H}")${TEE}$(printf "%-12s" | tr ' ' "${H}")${TEE}$(printf "%-50s" | tr ' ' "${H}")${TR}"
printf "%s %-20s %s %-12s %s %-50s %s\n" "${V}" "Sección" "${V}" "Estado" "${V}" "Detalle" "${V}"
printf "%s\n" "${SEP}$(printf "%-20s" | tr ' ' "${H}")${TEE}$(printf "%-12s" | tr ' ' "${H}")${TEE}$(printf "%-50s" | tr ' ' "${H}")${SEPR}"
for key in "1) Sistema Operativo y Recursos" "2) Red, DNS y Puertos" "3) Contenedores y Runtime" "4) Orbit CLI y Apps" "5) Logs de Aplicación (ligero)"; do
  st="${SECTION_STATUS[$key]:-N/A}"; dt="${SECTION_DETAIL[$key]:-}"
  case "$st" in OK) badge="${GREEN}OK${NC}";; WARN) badge="${YELLOW}WARN${NC}";; ERROR) badge="${RED}ERROR${NC}";; *) badge="$st";; esac
  printf "%s %-20s %s %-12s %s %-50.50s %s\n" "${V}" "$key" "${V}" "$badge" "${V}" "$dt" "${V}"
done
printf "%s\n" "${BL}$(printf "%-20s" | tr ' ' "${H}")${BTM}$(printf "%-12s" | tr ' ' "${H}")${BTM}$(printf "%-50s" | tr ' ' "${H}")${BR}"

echo; h1 "Salida y Duración"
kv "Reporte TXT" "${REPORT_DIR}/${REPORT_FILE}"
kv "Duración" "$(secs_to_human "$DUR")"
append_section "FOOTER" "duration_sec=$DUR"

# Finalizar JSON (solo si hay jq y se pidió)
if [[ "$WANT_JSON" == "1" ]] && has_cmd jq; then
  jq_finalize
  if [[ -n "$OUT_PATH" ]]; then printf '%s\n' "$JSON" > "$OUT_PATH" && ok "JSON escrito en $OUT_PATH"
  else printf '%s\n' "$JSON" | tee "${REPORT_DIR}/${JSON_FILE}" >/dev/null; kv "Resumen JSON" "${REPORT_DIR}/${JSON_FILE}"; fi
fi

exit 0

