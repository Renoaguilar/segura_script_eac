#!/bin/bash

#                 _
#                | |
#  ___  ___ _ __ | |__   __ _ ___  ___  __ _ _   _ _ __ __ _
# / __|/ _ \ '_ \| '_ \ / _` / __|/ _ \/ _` | | | | '__/ _` |
# \__ \  __/ | | | | | | (_| \__ \  __/ (_| | |_| | | | (_| |
# |___/\___|_| |_|_| |_|\__,_|___/\___|\__, |\__,_|_|  \__,_|
#                                       __/ |
#                                      |___/
#
# Script: segura_log_cleaner.sh
# Autor:  Esteban Ac
# Función: Check_Orbit (+ auto-reinicio, export ZIP, SCP)
# Uso:
#   ./segura_log_cleaner.sh [--auto] [--only-services] [--export-zip]
#                           [--scp user@IP] [--scp-path RUTA_REMOTA]
# Notas:
#   - Reinicia servicios individualmente: `orbit services restart <svc> --force`
#   - Log: /var/tmp/segura_orbit_resumen_YYYYmmdd_HHMMSS.log
#   - ZIP: /var/tmp/orbit_export_YYYYmmdd_HHMMSS.zip

set -euo pipefail

# ======== Config ========
PASSWORD="Segura2025"                 # Gate simple del script
LOGDIR="/var/tmp"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="${LOGDIR}/segura_orbit_resumen_${STAMP}.log"
PORTS_CHECK=("443" "8443" "51445")    # 8443(NC), 51445(Proxies), 443(GUI)
AUTO=0
ONLY_SERVICES=0
EXPORT_ZIP=0
SCP_TARGET=""                         # Ej: user@172.16.1.99
SCP_PATH="Downloads"                  # Windows OpenSSH: carpeta 'Downloads' en HOME
# ========================

# ---- Flags ----
while (( "$#" )); do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --only-services) ONLY_SERVICES=1; shift ;;
    --export-zip) EXPORT_ZIP=1; shift ;;
    --scp) SCP_TARGET="${2:-}"; shift 2 ;;
    --scp-path) SCP_PATH="${2:-Downloads}"; shift 2 ;;
    *) echo "Parámetro no reconocido: $1"; shift ;;
  esac
done

# ---- Helpers ----
have(){ command -v "$1" >/dev/null 2>&1; }

# Elevar antes del gate para no pedir contraseña 2 veces
if ! have orbit; then
  echo "❌ No se encontró 'orbit' en PATH. Abortando."
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" ${AUTO:+--auto} ${ONLY_SERVICES:+--only-services} \
    ${EXPORT_ZIP:+--export-zip} ${SCP_TARGET:+--scp "$SCP_TARGET"} ${SCP_PATH:+--scp-path "$SCP_PATH"}
fi

# Banner seguro (no rompe comillas)
cat <<'BANNER'
#                 _
#                | |
#  ___  ___ _ __ | |__   __ _ ___  ___  __ _ _   _ _ __ __ _
# / __|/ _ \ '_ \| '_ \ / _` / __|/ _ \/ _` | | | | '__/ _` |
# \__ \  __/ | | | | | | (_| \__ \  __/ (_| | |_| | | | (_| |
# |___/\___|_| |_|_| |_|\__,_|___/\___|\__, |\__,_|_|  \__,_|
#                                       __/ |
#                                      |___/

# Script: segura_log_cleaner.sh
# Autor:  Esteban Ac
# Función: Check_Orbit (+ auto-reinicio, export ZIP, SCP)
BANNER

# Gate por contraseña (simple)
read -s -p "🔐 Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
[[ "$user_pass" == "$PASSWORD" ]] || { echo "❌ Contraseña incorrecta. Abortando..."; exit 1; }

# Visual
print_section() {
  local title="$1"
  echo -e "\n\033[1;36m╔════════════════════════════════════════╗"
  printf "║ %-38s ║\n" "$title"
  echo -e "╚════════════════════════════════════════╝\033[0m"
  {
    echo
    echo "## $title"
  } >> "$LOGFILE"
}
print_status() {
  local status="$1"
  case "$status" in
    OK)   echo -e "   ➤ \033[1;32m[$status]\033[0m" ;;
    WARN) echo -e "   ➤ \033[1;33m[$status]\033[0m" ;;
    FAIL) echo -e "   ➤ \033[1;31m[$status]\033[0m" ;;
    *)    echo -e "   ➤ [$status]" ;;
  esac
}
bar_usage(){ local p=$1; local f=$((p/2)); ((f<0))&&f=0; ((f>50))&&f=50; local e=$((50-f)); printf "%0.s█" $(seq 1 $f); printf "%0.s░" $(seq 1 $e); }

mkdir -p "$LOGDIR"
echo -e "\n🕒 Inicio de validación: $(date)" | tee -a "$LOGFILE"

# -------- Servicios (listado + reinicio por servicio) ----------
get_services_list_cmd() {
  if orbit services list >/dev/null 2>&1; then
    echo "orbit services list"
  elif orbit service list >/dev/null 2>&1; then
    echo "orbit service list"
  else
    echo ""
  fi
}
list_services_table() {
  local cmd; cmd=$(get_services_list_cmd)
  [[ -n "$cmd" ]] || { echo "❌ No existe 'orbit services list' ni 'orbit service list'." | tee -a "$LOGFILE"; return 1; }
  eval "$cmd"
}
parse_down_services() {
  list_services_table | \
  awk -F'|' '
    /\|/ && $2 !~ /NAME|SERVICE|APPLICATION/ {
      svc=$2; st=$3;
      gsub(/^[ \t]+|[ \t]+$/, "", svc);
      gsub(/^[ \t]+|[ \t]+$/, "", st);
      if (svc != "" && st != "" && tolower(st) !~ /(running|active|ok|up)/) print svc
    }'
}
restart_service_name() {
  local s="$1"
  if orbit services restart "$s" --force >/dev/null 2>&1; then echo "OK"; else echo "FAIL"; fi
}
run_services_section() {
  print_section "Servicios de Senhasegura (auto-reinicio si están caídos)"
  echo "Listado con: $(get_services_list_cmd || echo 'N/D')" | tee -a "$LOGFILE"
  if ! list_services_table >/dev/null 2>&1; then return; fi
  list_services_table | tee -a "$LOGFILE"

  mapfile -t down_services < <(parse_down_services || true)
  if ((${#down_services[@]}==0)); then
    echo -e "\n   ➤ Todos los servicios parecen \033[1;32mOK\033[0m." | tee -a "$LOGFILE"
    return
  fi

  echo -e "\n   ⚠️  Servicios detectados como caídos/inactivos:" | tee -a "$LOGFILE"
  for s in "${down_services[@]}"; do echo "   - $s" | tee -a "$LOGFILE"; done

  if (( AUTO==1 )); then
    echo -e "\n   ➤ Modo --auto activo: reinicio sin confirmación..." | tee -a "$LOGFILE"
    for s in "${down_services[@]}"; do
      print_section "Reinicio del servicio: $s"
      [[ "$(restart_service_name "$s")" == "OK" ]] && print_status "OK" || print_status "FAIL"
    done
  else
    read -r -p $'\n¿Deseas reiniciarlos ahora? (y/N): ' confirm
    if [[ "${confirm,,}" == "y" ]]; then
      for s in "${down_services[@]}"; do
        print_section "Reinicio del servicio: $s"
        [[ "$(restart_service_name "$s")" == "OK" ]] && print_status "OK" || print_status "FAIL"
      done
    else
      echo "   ➤ Omitido por el usuario." | tee -a "$LOGFILE"
    fi
  fi

  echo -e "\n   ➤ Verificación post-reinicio:" | tee -a "$LOGFILE"
  list_services_table | tee -a "$LOGFILE"
}

# ---- Si pidió solo servicios, ejecutar y salir ----
if (( ONLY_SERVICES==1 )); then
  run_services_section
  echo -e "\n\033[1;34m✔ Finalizado (solo servicios). Log:\033[0m $LOGFILE"
  [[ -n "${HISTCMD:-}" ]] && history -d $((HISTCMD-1)) 2>/dev/null || true
  exit 0
fi

# ---------------------- Secciones completas ----------------------
print_section "Versión de Senhasegura"
orbit version 2>&1 | tee -a "$LOGFILE"

print_section "Estado general de la aplicación"
if orbit app status >/dev/null 2>&1; then orbit app status | tee -a "$LOGFILE"; else echo "Comando 'orbit app status' no disponible." | tee -a "$LOGFILE"; fi

print_section "¿Modo de mantenimiento activo?"
MAINT=$(orbit app status 2>/dev/null | awk -F':' '/Maintenance/{gsub(/ /,"",$2);print $2}')
[[ "$MAINT" == "Yes" ]] && print_status "WARN" || print_status "OK"
echo "Maintenance: ${MAINT:-Unknown}" >> "$LOGFILE"

print_section "Hostname configurado"
orbit hostname --show 2>&1 | tee -a "$LOGFILE"

print_section "Red e IP asignada"
orbit network --show 2>&1 | tee -a "$LOGFILE"

print_section "DNS y salida a Internet (google.com)"
if getent hosts google.com >/dev/null 2>&1; then print_status "OK"; else print_status "FAIL"; fi
(getent hosts google.com || true) 2>&1 | tee -a "$LOGFILE"

print_section "Estado de NTP y hora"
if orbit ntp --show >/dev/null 2>&1; then orbit ntp --show 2>&1 | tee -a "$LOGFILE"; else echo "Comando 'orbit ntp --show' no disponible." | tee -a "$LOGFILE"; fi
have timedatectl && timedatectl 2>&1 | tee -a "$LOGFILE"
date 2>&1 | tee -a "$LOGFILE"

print_section "Estado del Disco (uso de particiones)"
df -h --output=source,size,used,avail,pcent,target | tail -n +2 | sort -k5 -nr | \
while read -r device size used avail pcent mountpoint; do
  pnum=$(echo "$pcent" | tr -d '%'); bar=$(bar_usage "$pnum")
  if   (( pnum >= 95 )); then color="\033[1;31m"; estado="FAIL"
  elif (( pnum >= 80 )); then color="\033[1;33m"; estado="WARN"
  else                       color="\033[1;32m"; estado="OK"
  fi
  printf "📁 %-20s %6s usadas / %6s totales en %s\n" "$device" "$used" "$size" "$mountpoint" | tee -a "$LOGFILE"
  printf "   ➤ Uso: ${color}[%s] %s\033[0m (%s)\n\n" "$bar" "$pcent" "$estado" | tee -a "$LOGFILE"
done
echo -e "\n🔍 Detalles de particiones (Orbit):\n" | tee -a "$LOGFILE"
orbit disk --show >/dev/null 2>&1 && orbit disk --show 2>&1 | tee -a "$LOGFILE" || true

# Servicios (con auto-reinicio opcional)
run_services_section

# Proxies
for proxy in fajita jumpserver rdpgate nss; do
  if orbit proxy "$proxy" status >/dev/null 2>&1; then
    print_section "Estado del proxy: $proxy"
    orbit proxy "$proxy" status 2>&1 | tee -a "$LOGFILE"
  fi
done

# Domum Remote Access
print_section "Domum Remote Access"
if orbit domum-gateway status >/dev/null 2>&1; then
  orbit domum-gateway status 2>&1 | tee -a "$LOGFILE"
else
  echo "Comandos Domum no disponibles ('orbit domum-gateway ...')." | tee -a "$LOGFILE"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q domum-gateway-client; then
  echo -e "\nContenedor domum-gateway-client activo. Logs recientes:" | tee -a "$LOGFILE"
  docker logs --tail 100 domum-gateway-client 2>&1 | tee -a "$LOGFILE" || true
fi

# NATS / Async
print_section "NATS / Eventos Async"
if orbit nats stream ls >/dev/null 2>&1; then
  orbit nats stream ls 2>&1 | tee -a "$LOGFILE"
  echo -e "\nSubjects:" | tee -a "$LOGFILE"
  orbit nats stream subjects 2>&1 | tee -a "$LOGFILE"
else
  echo "Comandos NATS no disponibles." | tee -a "$LOGFILE"
fi
[[ -f /var/log/senhasegura/async/async.log ]] && { echo -e "\nÚltimas 100 líneas de async.log:" | tee -a "$LOGFILE"; tail -n 100 /var/log/senhasegura/async/async.log | tee -a "$LOGFILE"; }

# Cluster
print_section "Estado de Cluster"
orbit cluster status >/dev/null 2>&1 && orbit cluster status 2>&1 | tee -a "$LOGFILE" || echo "Cluster no disponible." | tee -a "$LOGFILE"

# Ejecuciones / Healthcheck
print_section "Ejecuciones y Healthcheck"
orbit execution list >/dev/null 2>&1 && orbit execution list 2>&1 | tee -a "$LOGFILE" || true
orbit healthcheck run --dry-run >/dev/null 2>&1 && echo -e "\nHealthcheck disponible: 'orbit healthcheck run'." | tee -a "$LOGFILE" || true

# Certificados web
print_section "Certificados Web (orbit webssl)"
orbit webssl >/dev/null 2>&1 && orbit webssl 2>&1 | tee -a "$LOGFILE" || echo "Comando 'orbit webssl' no disponible." | tee -a "$LOGFILE"

# Backup
print_section "Horario de backup configurado"
orbit backup time --show >/dev/null 2>&1 && orbit backup time --show 2>&1 | tee -a "$LOGFILE" || echo "Comando 'orbit backup time --show' no disponible." | tee -a "$LOGFILE"

# Firewall
print_section "Firewall y bloqueos"
orbit firewall status >/dev/null 2>&1 && orbit firewall status 2>&1 | tee -a "$LOGFILE" || echo "Comando 'orbit firewall status' no disponible." | tee -a "$LOGFILE"

# Puertos
print_section "Puertos locales en escucha"
for p in "${PORTS_CHECK[@]}"; do
  if ss -tulpen 2>/dev/null | grep -qE "[:.]$p(\s|$)"; then
    echo "   ➤ Port $p: LISTEN" | tee -a "$LOGFILE"
  else
    echo "   ➤ Port $p: NOT LISTEN" | tee -a "$LOGFILE"
  fi
done

# ----------------------- Export ZIP y SCP -----------------------
find_latest_healthcheck_zip() {
  # Busca ZIP reciente de orbit healthcheck
  ls -1t /var/tmp/orbit_healthcheck/*.zip 2>/dev/null | head -n1 || true
}

do_export_zip_and_scp() {
  local export_zip_path="/var/tmp/orbit_export_${STAMP}.zip"
  local tmpdir="/var/tmp/orbit_export_${STAMP}"
  mkdir -p "$tmpdir"

  print_section "Export (ZIP)"
  echo "➤ Ejecutando 'orbit healthcheck run'..." | tee -a "$LOGFILE"
  if orbit healthcheck run >/dev/null 2>&1; then
    echo "   ➤ Healthcheck: OK" | tee -a "$LOGFILE"
  else
    echo "   ➤ Healthcheck: WARN (continuando con log y artefactos disponibles)" | tee -a "$LOGFILE"
  fi

  local hc_zip; hc_zip="$(find_latest_healthcheck_zip)"
  if [[ -n "$hc_zip" && -f "$hc_zip" ]]; then
    cp -f "$hc_zip" "$tmpdir/"
    echo "   ➤ ZIP healthcheck: $hc_zip" | tee -a "$LOGFILE"
  else
    echo "   ➤ No se encontró ZIP de healthcheck en /var/tmp/orbit_healthcheck/" | tee -a "$LOGFILE"
  fi

  # Incluir log y algunos archivos útiles si existen
  cp -f "$LOGFILE" "$tmpdir/" || true
  [[ -f /var/log/senhasegura/async/async.log ]] && cp -f /var/log/senhasegura/async/async.log "$tmpdir/async.log" || true

  # Empaquetar
  if have zip; then
    (cd "$tmpdir" && zip -qr "$export_zip_path" .)
  else
    export_zip_path="${export_zip_path%.zip}.tar.gz"
    (cd "$tmpdir" && tar -czf "$export_zip_path" .)
  fi
  echo "   ➤ Export generado: $export_zip_path" | tee -a "$LOGFILE"

  # SCP (si se solicitó)
  if [[ -n "$SCP_TARGET" ]]; then
    echo "➤ Enviando a ${SCP_TARGET}:${SCP_PATH}/ ..." | tee -a "$LOGFILE"
    # Para Windows OpenSSH, 'Downloads' es bajo HOME del usuario remoto
    scp -o StrictHostKeyChecking=no "$export_zip_path" "$SCP_TARGET:${SCP_PATH}/" && print_status "OK" || print_status "FAIL"
  fi
}

if (( EXPORT_ZIP==1 )); then
  do_export_zip_and_scp
fi

# ----------------------- Final -----------------------
echo -e "\n\033[1;34m✔ Validación completada. Revisa el reporte:\033[0m $LOGFILE"
(( EXPORT_ZIP==1 )) && echo -e "\033[1;34m✔ Export preparado (ZIP/TAR):\033[0m /var/tmp/orbit_export_${STAMP}.*"

# Borrar línea de invocación del historial (si interactivo)
[[ -n "${HISTCMD:-}" ]] && history -d $((HISTCMD-1)) 2>/dev/null || true
