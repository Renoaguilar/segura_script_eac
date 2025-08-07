#!/usr/bin/env bash
# =============================================================================
# Segura® (Senhasegura) - Troubleshooting Visual (read-only) - Compat MAX
# - Sin prompt de contraseña
# - Sin Python / sin arrays asociativos / sin process substitution
# - Panel visual por sección + almacenamiento ordenado por % uso
# =============================================================================
set -u
VERSION="1.3.0"
START_TS=$(date +%s)
DATE_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
REPORT_DIR="${REPORT_DIR:-/tmp/segura_diag}"
REPORT_FILE="segura_diag_$(date +%Y%m%d_%H%M%S).txt"

MODE_QUICK=0
WANT_JSON=0
OUT_PATH=""
FILTERS=""

# -------------------------- Colores / UI -------------------------------------
if [ -t 1 ]; then
  NC="$(printf '\033[0m')" ; BOLD="$(printf '\033[1m')" ; DIM="$(printf '\033[2m')"
  RED="$(printf '\033[31m')" ; GREEN="$(printf '\033[32m')" ; YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')" ; MAGENTA="$(printf '\033[35m')" ; CYAN="$(printf '\033[36m')"
  TL="┌"; TR="┐"; BL="└"; BR="┘"; H="─"; V="│"; SEP="├"; SEPR="┤"; TEE="┬"; BTM="┴"
else
  NC=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
  TL="+"; TR="+"; BL="+"; BR="+"; H="-"; V="|"; SEP="+"; SEPR="+"; TEE="+"; BTM="+"
fi

ok()   { printf "%b✔%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b⚠%b %s\n" "$YELLOW" "$NC" "$*"; }
err()  { printf "%b✖%b %s\n" "$RED" "$NC" "$*"; }
info() { printf "%b➤%b %s\n" "$CYAN" "$NC" "$*"; }
h1()   { t="$*"; L=$(( ${#t} + 2 )); printf "%s\n" "${TL}$(printf "%${L}s" | tr ' ' "${H}")${TR}"; printf "%s %b%s%b %s\n" "${V}" "${BOLD}" "${t}" "${NC}" "${V}"; printf "%s\n" "${BL}$(printf "%${L}s" | tr ' ' "${H}")${BR}"; }
h2()   { printf "%b› %s%b\n" "$BOLD" "$*" "$NC"; }
kv()   { printf "%-30s : %s\n" "$1" "$2"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
secs_to_human(){ S="$1"; d=$((S/86400)); S=$((S%86400)); h=$((S/3600)); S=$((S%3600)); m=$((S/60)); s=$((S%60)); out=""; [ "$d" -gt 0 ] && out="${out}${d}d "; [ "$h" -gt 0 ] && out="${out}${h}h "; [ "$m" -gt 0 ] && out="${out}${m}m "; printf "%s%ss\n" "$out" "$s"; }

mkdir -p "$REPORT_DIR" || { err "No se pudo crear $REPORT_DIR"; exit 1; }
: > "${REPORT_DIR}/${REPORT_FILE}"

append(){ printf "%s\n" "$*" >> "${REPORT_DIR}/${REPORT_FILE}"; }
append_section(){ title="$1"; shift; append ""; append "===== ${title} ====="; [ $# -gt 0 ] && printf "%s\n" "$*" >> "${REPORT_DIR}/${REPORT_FILE}"; }

usage(){
cat <<'EOF'
Uso: segura_troubleshoot_visual.sh [opciones]
  --quick                 Modo rápido
  --system|--network|--containers|--orbit|--logs  Filtra secciones (puedes combinar)
  --json                  Imprime JSON básico (sin jq/py; simple)
  --out <ruta>            Ruta de salida JSON
  --no-color              Desactiva color
  -h|--help               Ayuda
  -V|--version            Versión
EOF
}

# -------------------------- Parseo de args -----------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) MODE_QUICK=1;;
    --system|--network|--containers|--orbit|--logs) [ -z "$FILTERS" ] && FILTERS="$1" || FILTERS="$FILTERS $1";;
    --json) WANT_JSON=1;;
    --out) OUT_PATH="$2"; shift;;
    --no-color) NC=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN="";;
    -h|--help) usage; exit 0;;
    -V|--version) echo "$VERSION"; exit 0;;
    *) err "Opción no reconocida: $1"; usage; exit 1;;
  esac
  shift
done

# Helper de filtro
wants(){
  tag="$1"
  [ -z "$FILTERS" ] && return 0
  for f in $FILTERS; do
    case "$f" in
      --$tag) return 0;;
    esac
  done
  return 1
}

# -------------------------- Estado por sección (simple) ----------------------
SECTION1_STATUS="N/A"; SECTION1_DETAIL=""
SECTION2_STATUS="N/A"; SECTION2_DETAIL=""
SECTION3_STATUS="N/A"; SECTION3_DETAIL=""
SECTION4_STATUS="N/A"; SECTION4_DETAIL=""
SECTION5_STATUS="N/A"; SECTION5_DETAIL=""

badge(){
  case "$1" in
    OK)    printf "%b[ OK ]%b" "$GREEN" "$NC";;
    WARN)  printf "%b[ WARN ]%b" "$YELLOW" "$NC";;
    ERROR) printf "%b[ ERROR ]%b" "$RED" "$NC";;
    *)     printf "[ %s ]" "$1";;
  esac
}

# ========================== 1) Sistema =======================================
check_system(){
  name="1 - Sistema Operativo y Recursos"   # sin paréntesis para máxima compatibilidad
  h1 "$name"; append_section "SYSTEM"

  h2 "Información básica"
  {
    echo "## uname -a"; uname -a
    echo; echo "## /etc/os-release"; [ -r /etc/os-release ] && cat /etc/os-release || echo "N/A"
    echo; echo "## CPU y Memoria"; echo "- CPUs: $(nproc 2>/dev/null || echo 1)"
    echo "- Mem total (MB): $(free -m | awk '/Mem:/ {print $2}')"
  } | tee -a "${REPORT_DIR}/${REPORT_FILE}"

  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
  cpus="$(nproc 2>/dev/null || echo 1)"
  mem_used="$(free -m | awk '/Mem:/ {print $3}')"
  mem_total="$(free -m | awk '/Mem:/ {print $2}')"
  if [ "$mem_total" -gt 0 ] 2>/dev/null; then mem_pct=$(( 100 * mem_used / mem_total )); else mem_pct=0; fi

  echo; h2 "Carga y memoria"
  kv "Load 1m" "$load1"; kv "CPUs" "$cpus"; kv "Memoria usada" "${mem_used}MB (${mem_pct}%)"
  append "load1=$load1 cpus=$cpus mem_used=${mem_used}MB mem_pct=${mem_pct}%"

  st="OK"; dt=""
  # Carga alta si load1 > 1.5x CPUs
  awk -v l="$load1" -v c="$cpus" 'BEGIN{exit !(l>c*1.5)}'
  if [ $? -eq 0 ]; then warn "Carga alta: $load1 > 1.5x CPUs ($cpus)"; st="WARN"; dt="Carga alta"; else ok "Carga adecuada"; fi
  if [ "$mem_pct" -ge 90 ]; then warn "Memoria alta: ${mem_pct}%"; st="WARN"; dt="${dt:+$dt; }Memoria ${mem_pct}%"; else ok "Memoria dentro de rango (${mem_pct}%)"; fi

  echo; h2 "Almacenamiento (ordenado por % uso, críticos primero)"
  # Usamos df -hP, ordenamos por columna % y pintamos estado
  df -hP | awk 'NR>1 {print $0}' | sort -k5 -hr | \
  awk -v G="$GREEN" -v Y="$YELLOW" -v R="$RED" -v N="$NC" '
    BEGIN{
      printf "  %-6s %-18s %-6s %-7s %-7s %-7s\n","STATE","MOUNT","USE%","SIZE","USED","AVAIL";
      print  "  -----------------------------------------------------------"
    }
    {
      fs=$1; size=$2; used=$3; avail=$4; usep=$5; mount=$6;
      gsub("%","",usep);
      state="OK"; color=G;
      if (usep>=95){state="CRIT"; color=R}
      else if (usep>=85){state="WARN"; color=Y}
      printf "  %s%-6s%s %-18s %3d%%%6s %7s %7s %7s\n", color,state,N, mount, usep,"", size, used, avail
    }'

  # Marcamos hallazgos por % uso
  while read -r fs size used avail usep mount; do
    [ -z "$fs" ] && continue
    p="${usep%%%}"
    case "$p" in
      ''|*[!0-9]*) continue;;
    esac
    if [ "$p" -ge 95 ] 2>/dev/null; then st="ERROR"; dt="${dt:+$dt; }Disco $mount ${usep}"
    elif [ "$p" -ge 85 ] 2>/dev/null && [ "$st" = "OK" ]; then st="WARN"
    fi
  done <<EOF
$(df -hP | awk 'NR>1{print $1" "$2" "$3" "$4" "$5" "$6}')
EOF

  echo; h2 "Inodos"
  df -iP | awk 'NR==1{print;next}{printf "%-35s %10s %10s %10s %6s %s\n",$1,$2,$3,$4,$5,$6}' | tee -a "${REPORT_DIR}/${REPORT_FILE}"
  while read -r fs inodes iused ifree ipct mount; do
    [ -z "$fs" ] && continue
    ip="${ipct%%%}"
    case "$ip" in ''|*[!0-9]*) continue;; esac
    if [ "$ip" -ge 90 ] 2>/dev/null; then warn "Inodos altos en $mount ($ipct)"; [ "$st" = "OK" ] && st="WARN"; dt="${dt:+$dt; }Inodos $mount $ipct"; fi
  done <<EOF
$(df -iP | awk 'NR>1{print $1" "$2" "$3" "$4" "$5" "$6}')
EOF

  echo; h2 "SELinux/AppArmor y hora"
  if has_cmd getenforce; then se="$(getenforce)"; kv "SELinux" "$se"; append "SELinux=$se"
  elif [ -d /sys/kernel/security/apparmor ]; then kv "AppArmor" "presente"; append "AppArmor=present"
  else kv "MAC" "no detectado"; append "MAC=none"; fi
  timedatectl 2>/dev/null | sed 's/^/  /' | tee -a "${REPORT_DIR}/${REPORT_FILE}" >/dev/null

  SECTION1_STATUS="$st"; SECTION1_DETAIL="$dt"
  printf "%s %bEstado sección:%b " "${V}${H}${H}" "$BOLD" "$NC"; badge "$st"; [ -n "$dt" ] && printf "  %b%s%b" "$DIM" "$dt" "$NC"; printf "\n"
}

# ========================== 2) Red / DNS / Puertos ===========================
check_network(){
  name="2 - Red, DNS y Puertos"
  h1 "$name"; append_section "NETWORK"

  h2 "Interfaces y rutas"
  (ip -brief addr 2>/dev/null || ip addr) | sed 's/^/  /'
  echo
  (ip route 2>/dev/null || route -n) | sed 's/^/  /'

  echo; h2 "DNS y conectividad a endpoints oficiales"
  st="OK"; dt=""
  for h in docs.senhasegura.io downloads.senhasegura.io community.senhasegura.io; do
    if getent ahosts "$h" >/dev/null 2>&1; then ok "Resuelve $h"
    else warn "No resuelve $h"; st="WARN"; dt="${dt:+$dt; }DNS $h"; fi
  done

  echo; h2 "Conexión TCP:443"
  for h in docs.senhasegura.io downloads.senhasegura.io community.senhasegura.io; do
    timeout 4 bash -c ">/dev/tcp/$h/443" 2>/dev/null && ok "TCP 443 OK → $h" || { warn "TCP 443 FAIL → $h"; [ "$st" = "OK" ] && st="WARN"; dt="${dt:+$dt; }443 $h"; }
  done

  echo; h2 "Puertos locales relevantes"
  listening=0
  for p in 22 80 443 51445 3306 6379; do
    if ss -lntp 2>/dev/null | awk -v P=":$p" '$4 ~ P {found=1} END{exit !found}'; then
      printf "  %s %s\n" "$(printf "%sLISTEN%s" "$GREEN" "$NC")" "$p"; listening=$((listening+1))
    else
      printf "  %s %s\n" "$(printf "%sCLOSED%s" "$YELLOW" "$NC")" "$p"
    fi
  done

  echo; h2 "Firewall (vista rápida)"
  if has_cmd firewall-cmd; then
    firewall-cmd --state >/dev/null 2>&1 && kv "firewalld" "activo" || kv "firewalld" "inactivo"
    echo "  Puertos:"; firewall-cmd --list-ports 2>/dev/null | sed 's/^/   - /'
  elif has_cmd nft; then
    echo "  nft ruleset (primeras 100 líneas):"; nft list ruleset 2>/dev/null | head -100 | sed 's/^/   /'
  elif has_cmd iptables; then
    echo "  iptables (primeras 100 líneas):"; iptables -S 2>/dev/null | head -100 | sed 's/^/   /'
  else
    warn "No se detectó firewalld/nftables/iptables"
  fi

  [ "$listening" -eq 0 ] && { st="WARN"; dt="${dt:+$dt; }Sin puertos base escuchando"; }

  SECTION2_STATUS="$st"; SECTION2_DETAIL="$dt"
  printf "%s %bEstado sección:%b " "${V}${H}${H}" "$BOLD" "$NC"; badge "$st"; [ -n "$dt" ] && printf "  %b%s%b" "$DIM" "$dt" "$NC"; printf "\n"
}

# ========================== 3) Contenedores ==================================
check_containers(){
  name="3 - Contenedores y Runtime"
  h1 "$name"; append_section "CONTAINERS"

  st="OK"; dt=""
  if ! has_cmd docker; then
    err "Docker no está instalado"; SECTION3_STATUS="ERROR"; SECTION3_DETAIL="Docker ausente"
    printf "%s %bEstado sección:%b " "${V}${H}${H}" "$BOLD" "$NC"; badge "ERROR"; printf "  %bDocker ausente%b\n" "$DIM" "$NC"
    return
  fi

  if systemctl is-active docker >/dev/null 2>&1; then ok "Docker activo"; else warn "Docker inactivo"; st="WARN"; dt="Docker inactivo"; fi

  echo; h2 "Contenedores en ejecución"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null

  seg_count=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -Eic 'senhasegura|segura|pam|arbitrator|mysql|mariadb|redis|nginx' || true)
  if [ "$seg_count" -eq 0 ] 2>/dev/null; then
    warn "No se detectaron contenedores típicos de Segura®"; [ "$st" = "OK" ] && st="WARN"; dt="${dt:+$dt; }No containers Segura®"
  else
    echo; h2 "Salud de contenedores Segura®"
    docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | \
    while read -r cname cstatus_rest; do
      echo "$cname" | grep -Eiq 'senhasegura|segura|pam|arbitrator|mysql|mariadb|redis|nginx' || continue
      status="$(docker inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo unknown)"
      if [ "$status" != "running" ]; then warn "Container $cname en estado $status"; [ "$st" = "OK" ] && st="WARN"; dt="${dt:+$dt; }$cname $status"
      else ok "Container $cname running"; fi
    done
  fi

  if [ "$MODE_QUICK" -eq 0 ] && [ "$seg_count" -gt 0 ] 2>/dev/null; then
    echo; h2 "Logs (tail 120) con detección de errores"
    docker ps --format '{{.Names}}' 2>/dev/null | \
    while read -r cname; do
      echo "$cname" | grep -Eiq 'senhasegura|segura|pam|arbitrator|mysql|mariadb|redis|nginx' || continue
      echo; echo "--- $cname ---"
      docker logs --tail 120 "$cname" 2>&1 | sed 's/^/  /'
      docker logs --tail 120 "$cname" 2>&1 | grep -Eqi 'ERROR|FATAL|panic|exception' && { warn "Posibles errores en $cname"; [ "$st" = "OK" ] && st="WARN"; dt="${dt:+$dt; }Logs $cname"; }
    done
  fi

  SECTION3_STATUS="$st"; SECTION3_DETAIL="$dt"
  printf "%s %bEstado sección:%b " "${V}${H}${H}" "$BOLD" "$NC"; badge "$st"; [ -n "$dt" ] && printf "  %b%s%b" "$DIM" "$dt" "$NC"; printf "\n"
}

# ========================== 4) Orbit CLI =====================================
check_orbit(){
  name="4 - Orbit CLI y Apps"
  h1 "$name"; append_section "ORBIT"

  st="OK"; dt=""
  if ! has_cmd orbit; then
    err "Orbit CLI no encontrado"; SECTION4_STATUS="ERROR"; SECTION4_DETAIL="Orbit ausente"
    printf "%s %bEstado sección:%b " "${V}${H}${H}" "$BOLD" "$NC"; badge "ERROR"; printf "  %bOrbit no instalado%b\n" "$DIM" "$NC"
    return
  fi

  echo; h2 "Versiones"
  echo "  orbit version:"; orbit version 2>&1 | sed 's/^/    /' || true
  echo "  orbit app version:"; orbit app version 2>&1 | sed 's/^/    /' || true

  echo; h2 "Estado de aplicaciones"
  if orbit app status >/dev/null 2>&1; then
    orbit app status 2>&1 | sed 's/^/  /'
    bad="$(orbit app status 2>&1 | grep -Eiv 'healthy|running|up|ok' | grep -Ei 'down|unhealthy|error|failed' || true)"
    if [ -n "$bad" ]; then warn "Apps con estado no saludable"; st="WARN"; dt="apps no healthy"; else ok "Apps healthy"; fi
  else
    warn "orbit app status no disponible"; [ "$st" = "OK" ] && st="WARN"; dt="app status N/A"
  fi

  for proxy in ssh rdp web; do
    if orbit proxy "$proxy" status >/dev/null 2>&1; then echo; h2 "Proxy $(printf %s "$proxy" | tr a-z A-Z)"; orbit proxy "$proxy" status 2>&1 | sed 's/^/  /'; fi
  done

  if [ "$MODE_QUICK" -eq 0 ]; then
    echo; h2 "Logs de orbit (tail 200)"
    if orbit logs --tail=200 >/dev/null 2>&1; then
      orbit logs --tail=200 2>&1 | sed 's/^/  /'
      orbit logs --tail=200 2>&1 | grep -Eqi 'ERROR|FATAL|exception' && { warn "Errores recientes en orbit logs"; [ "$st" = "OK" ] && st="WARN"; dt="${dt:+$dt; }orbit logs"; }
    else
      warn "orbit logs --tail no soportado"
    fi
  fi

  SECTION4_STATUS="$st"; SECTION4_DETAIL="$dt"
  printf "%s %bEstado sección:%b " "${V}${H}${H}" "$BOLD" "$NC"; badge "$st"; [ -n "$dt" ] && printf "  %b%s%b" "$DIM" "$dt" "$NC"; printf "\n"
}

# ========================== 5) Logs de aplicación ============================
check_logs(){
  name="5 - Logs de Aplicación (ligero)"
  h1 "$name"; append_section "APP LOGS"

  st="OK"; dt=""
  base="/var/log/senhasegura"
  if [ -d "$base" ]; then
    h2 "Top directorios por tamaño"
    du -h --max-depth=1 "$base" 2>/dev/null | sort -hr | head -10 | sed 's/^/  /'
    echo; h2 "Archivos de log más pesados"
    find "$base" -type f -printf '%s %p\n' 2>/dev/null | sort -nr | head -10 | awk '{printf "  %8.1f MB  %s\n",$1/1024/1024,$2}'
    if [ "$MODE_QUICK" -eq 0 ]; then
      echo; h2 "Errores recientes (tail 120 de logs grandes)"
      # iteración simple; sin arrays
      for f in $(find "$base" -type f -name "*.log" -size +1M 2>/dev/null | head -10); do
        echo; echo "--- $f ---"
        tail -n 120 "$f" 2>/dev/null | sed 's/^/  /'
        tail -n 120 "$f" 2>/dev/null | grep -Eqi 'ERROR|FATAL|exception|traceback' && { warn "Errores en $f"; [ "$st" = "OK" ] && st="WARN"; dt="${dt:+$dt; }errores en logs"; }
      done
    fi
  else
    warn "Directorio $base no existe"; [ "$st" = "OK" ] && st="WARN"; dt="logs N/A"
  fi

  SECTION5_STATUS="$st"; SECTION5_DETAIL="$dt"
  printf "%s %bEstado sección:%b " "${V}${H}${H}" "$BOLD" "$NC"; badge "$st"; [ -n "$dt" ] && printf "  %b%s%b" "$DIM" "$dt" "$NC"; printf "\n"
}

# ========================== Ejecución ========================================
h1 "Segura® Troubleshooting VISUAL v$VERSION"
kv "Host" "$HOSTNAME"
kv "Fecha (UTC)" "$DATE_UTC"
kv "Modo rápido" "$MODE_QUICK"
kv "Filtros" "${FILTERS:-ninguno}"

append_section "HEADER" "host=$HOSTNAME" "timestamp=$DATE_UTC" "version=$VERSION" "quick=$MODE_QUICK" "filters=${FILTERS:-none}"

ran=0
wants system && { check_system; ran=1; }
wants network && { check_network; ran=1; }
wants containers && { check_containers; ran=1; }
wants orbit && { check_orbit; ran=1; }
wants logs && { check_logs; ran=1; }
[ "$ran" -eq 0 ] && { check_system; check_network; check_containers; check_orbit; check_logs; }

# ========================== Panel final ======================================
END_TS=$(date +%s)
DUR=$((END_TS-START_TS))

echo
h1 "Panel de Salud - Resumen por Sección"
printf "%s\n" "${TL}$(printf "%-20s" | tr ' ' "${H}")${TEE}$(printf "%-12s" | tr ' ' "${H}")${TEE}$(printf "%-50s" | tr ' ' "${H}")${TR}"
printf "%s %-20s %s %-12s %s %-50s %s\n" "${V}" "Sección" "${V}" "Estado" "${V}" "Detalle" "${V}"
printf "%s\n" "${SEP}$(printf "%-20s" | tr ' ' "${H}")${TEE}$(printf "%-12s" | tr ' ' "${H}")${TEE}$(printf "%-50s" | tr ' ' "${H}")${SEPR}"
for row in \
  "1 - Sistema Operativo y Recursos|$SECTION1_STATUS|$SECTION1_DETAIL" \
  "2 - Red, DNS y Puertos|$SECTION2_STATUS|$SECTION2_DETAIL" \
  "3 - Contenedores y Runtime|$SECTION3_STATUS|$SECTION3_DETAIL" \
  "4 - Orbit CLI y Apps|$SECTION4_STATUS|$SECTION4_DETAIL" \
  "5 - Logs de Aplicación (ligero)|$SECTION5_STATUS|$SECTION5_DETAIL"
do
  sec="${row%%|*}"; rest="${row#*|}"; st="${rest%%|*}"; dt="${rest#*|}"
  case "$st" in
    OK) badge_txt="${GREEN}OK${NC}";;
    WARN) badge_txt="${YELLOW}WARN${NC}";;
    ERROR) badge_txt="${RED}ERROR${NC}";;
    *) badge_txt="$st";;
  esac
  printf "%s %-20s %s %-12s %s %-50.50s %s\n" "${V}" "$sec" "${V}" "$badge_txt" "${V}" "$dt" "${V}"
done
printf "%s\n" "${BL}$(printf "%-20s" | tr ' ' "${H}")${BTM}$(printf "%-12s" | tr ' ' "${H}")${BTM}$(printf "%-50s" | tr ' ' "${H}")${BR}"

echo
h1 "Salida y Duración"
kv "Reporte TXT" "${REPORT_DIR}/${REPORT_FILE}"
kv "Duración" "$(secs_to_human "$DUR")"

append_section "FOOTER" "duration_sec=$DUR"

# -------------------------- JSON básico (opcional) ---------------------------
if [ "$WANT_JSON" -eq 1 ]; then
  # JSON simple sin jq/py (solo resumen por sección)
  json='{"version":"'"$VERSION"'","timestamp":"'"$DATE_UTC"'","hostname":"'"$HOSTNAME"'","sections":{'
  json=$json'"system":{"status":"'"$SECTION1_STATUS"'","detail":"'"$SECTION1_DETAIL"'"},'
  json=$json'"network":{"status":"'"$SECTION2_STATUS"'","detail":"'"$SECTION2_DETAIL"'"},'
  json=$json'"containers":{"status":"'"$SECTION3_STATUS"'","detail":"'"$SECTION3_DETAIL"'"},'
  json=$json'"orbit":{"status":"'"$SECTION4_STATUS"'","detail":"'"$SECTION4_DETAIL"'"},'
  json=$json'"logs":{"status":"'"$SECTION5_STATUS"'","detail":"'"$SECTION5_DETAIL"'"}'
  json=$json'}}'
  if [ -n "$OUT_PATH" ]; then
    printf "%s\n" "$json" > "$OUT_PATH" && ok "JSON escrito en $OUT_PATH"
  else
    printf "%s\n" "$json" > "${REPORT_DIR}/segura_diag_$(date +%Y%m%d_%H%M%S).json"
    kv "Resumen JSON" "${REPORT_DIR}/segura_diag_*.json"
  fi
fi

exit 0
