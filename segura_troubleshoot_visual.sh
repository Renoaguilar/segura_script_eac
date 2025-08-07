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

set -uo pipefail

VERSION="1.2.0"
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
  NC=""; BOLD=""; DIM=""
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
  COLORS=0
fi

# Box-drawing (fallback ASCII si no hay tty)
if [[ -t 1 ]]; then
  TL="┌"; TR="┐"; BL="└"; BR="┘"; H="─"; V="│"; SEP="├"; SEPR="┤"; TEE="┬"; BTM="┴"
else
  TL="+"; TR="+"; BL="+"; BR="+"; H="-"; V="|"; SEP="+"; SEPR="+"; TEE="+"; BTM="+"
fi

ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*"; }
info() { echo -e "${CYAN}➤${NC} $*"; }
h1()   { local t="$*"; local L=$(( ${#t} + 2 )); printf "%s\n" "${TL}$(printf "%${L}s" | tr ' ' "${H}")${TR}"; printf "%s %s %s\n" "${V}" "${BOLD}${t}${NC}" "${V}"; printf "%s\n" "${BL}$(printf "%${L}s" | tr ' ' "${H}")${BR}"; }
h2()   { echo -e "${BOLD}› $*${NC}"; }
kv()   { printf "%-30s : %s\n" "$1" "$2"; }

has_cmd(){ command -v "$1" >/dev/null 2>&1; }
secs_to_human(){ awk -v S="$1" 'BEGIN{d=int(S/86400);S%=86400;h=int(S/3600);S%=3600;m=int(S/60);s=S%60;
  out=""; if(d) out=out d "d "; if(h) out=out h "h "; if(m) out=out m "m "; out=out s "s"; print out}'; }

# -------------------------- JSON liviano -------------------------------------
JSON='{"version":"","timestamp":"","hostname":"","summary":{},"findings":[]}'
json_add(){
  local sev="$1" title="$2" detail="${3:-}"
  JSON=$(python3 - "$sev" "$title" "$detail" <<'PY' "$JSON" 2>/dev/null || echo "$JSON")
import json, sys
data=json.loads(sys.stdin.read())
sev=sys.argv[1]; title=sys.argv[2]; detail=sys.argv[3]
data["findings"].append({"severity":sev,"title":title,"detail":detail})
print(json.dumps(data))
PY
}
json_finalize(){
  local okc warnc errc
  okc=$(python3 - <<'PY' "$JSON" 2>/dev/null || echo 0)
import json,sys
d=json.loads(sys.argv[1])
print(sum(1 for f in d["findings"] if f["severity"]=="ok"))
PY
  warnc=$(python3 - <<'PY' "$JSON" 2>/dev/null || echo 0)
import json,sys
d=json.loads(sys.argv[1])
print(sum(1 for f in d["findings"] if f["severity"]=="warn"))
PY
  errc=$(python3 - <<'PY' "$JSON" 2>/dev/null || echo 0)
import json,sys
d=json.loads(sys.argv[1])
print(sum(1 for f in d["findings"] if f["severity"]=="error"))
PY
  JSON=$(python3 - <<PY "$JSON" "$VERSION" "$DATE_UTC" "$HOSTNAME" "$okc" "$warnc" "$errc" 2>/dev/null || echo "$JSON")
import json,sys
d=json.loads(sys.argv[1])
d["version"]=sys.argv[2]; d["timestamp"]=sys.argv[3]; d["hostname"]=sys.argv[4]
d["summary"]={"ok":int(sys.argv[5]),"warnings":int(sys.argv[6]),"errors":int(sys.argv[7])}
print(json.dumps(d))
PY
}

# -------------------------- Reporte ------------------------------------------
mkdir -p "$REPORT_DIR" || { echo "No se pudo crear $REPORT_DIR"; exit 1; }
: > "${REPORT_DIR}/${REPORT_FILE}"
append(){ printf "%s\n" "$*" >> "${REPORT_DIR}/${REPORT_FILE}"; }
append_section(){
  local title="$1"; shift
  append ""; append "===== ${title} ====="
  [[ $# -gt 0 ]] && printf "%s\n" "$@" >> "${REPORT_DIR}/${REPORT_FILE}"
}

# -------------------------- Args ---------------------------------------------
usage(){
  cat <<'EOF'
Uso: segura_troubleshoot_visual.sh [opciones]
  --quick                 Modo rápido (menos pesado)
  --system|--network|--containers|--orbit|--logs  Filtra secciones
  --json                  Produce resumen JSON
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

set_section(){
  local name="$1" status="$2" detail="$3"
  SECTION_STATUS["$name"]="$status"
  SECTION_DETAIL["$name"]="$detail"
}

print_section_header(){
  local name="$1"
  h1 "$name"
}

print_section_footer(){
  local name="$1"; local st="${SECTION_STATUS[$name]:-OK}"; local dt="${SECTION_DETAIL[$name]:-}"
  local badge
  case "$st" in
    OK)    badge="${GREEN}[ OK ]${NC}";;
    WARN)  badge="${YELLOW}[ WARN ]${NC}";;
    ERROR) badge="${RED}[ ERROR ]${NC}";;
    *)     badge="[ $st ]";;
  esac
  echo -e "${V}${H}${H} ${BOLD}Estado sección:${NC} $badge   ${DIM}${dt}${NC}"
}

# ========================== 1) Sistema =======================================
check_system(){
  local name="1) Sistema Operativo y Recursos"
  print_section_header "$name"
  append_section "SYSTEM"

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

  echo
  h2 "Carga y memoria"
  kv "Load 1m" "$load1"
  kv "CPUs" "$cpus"
  kv "Memoria usada" "${mem_used}MB (${mem_pct}%)"
  append "load1=$load1 cpus=$cpus mem_used=${mem_used}MB mem_pct=${mem_pct}%"

  local st="OK"; local dt=()
  if awk -v l="$load1" -v c="$cpus" 'BEGIN{exit !(l>c*1.5)}'; then
    warn "Carga alta: $load1 > 1.5x CPUs ($cpus)"
    json_add "warn" "Carga alta" "load1=$load1 cpus=$cpus"
    st="WARN"; dt+=("Carga alta")
  else
    ok "Carga adecuada"
    json_add "ok" "Carga adecuada" "load1=$load1 cpus=$cpus"
  fi
  if (( mem_pct >= 90 )); then
    warn "Memoria alta: ${mem_pct}%"
    json_add "warn" "Memoria alta" "mem_pct=${mem_pct}%"
    st="WARN"; dt+=("Memoria ${mem_pct}%")
  else
    ok "Memoria dentro de rango (${mem_pct}%)"
  fi

  echo
  h2 "Almacenamiento (ordenado por % uso, críticos primero)"
  # df normalizado por POSIX -hP
  # Campos: Filesystem Size Used Avail Use% Mounted_on
  mapfile -t DF_LINES < <(df -hP | awk 'NR>1{print $1,$2,$3,$4,$5,$6}')
  # ordenar por % desc
  printf "%s\n" "${DF_LINES[@]}" | awk '{print $0}' | sort -k5 -hr | while read -r fs size used avail usep mount; do
    pct=${usep%%%}
    if (( pct >= 95 )); then
      printf "  %s %s %s %s %s %s\n" "$(printf "${RED}CRIT${NC}")" "$mount" "$usep" "$size" "$used" "$avail"
    elif (( pct >= 85 )); then
      printf "  %s %s %s %s %s %s\n" "$(printf "${YELLOW}WARN${NC}")" "$mount" "$usep" "$size" "$used" "$avail"
    else
      printf "  %s %s %s %s %s %s\n" "$(printf "${GREEN}OK  ${NC}")" "$mount" "$usep" "$size" "$used" "$avail"
    fi
  done | awk 'BEGIN{printf "  %
