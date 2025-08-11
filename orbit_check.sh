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
# Función: Check_Orbit (+ auto-reinicio de servicios caídos)
# Uso:
#   ./segura_log_cleaner.sh [--auto] [--only-services]
#     --auto           Reinicia sin pedir confirmación los servicios caídos.
#     --only-services  Solo lista/verifica/reinicia servicios (rápido para cron).
# Notas:
#   - Nunca usa "all" al reiniciar: siempre reinicio por servicio.
#   - Genera log: /var/tmp/segura_orbit_resumen_YYYYmmdd_HHMMSS.log

set -euo pipefail

# ======== Config ========
PASSWORD="Segura2025"                 # Gate simple
LOGDIR="/var/tmp"
LOGFILE="${LOGDIR}/segura_orbit_resumen_$(date +%Y%m%d_%H%M%S).log"
PORTS_CHECK=("443" "8443" "51445")    # 8443(NC), 51445(proxies), 443(GUI)
EXTRA_SECTIONS=1                      # 1=mostrar secciones extra
AUTO=0                                # 1=auto-restart sin prompt
ONLY_SERVICES=0                       # 1=solo seccion servicios
# ========================

# ---- Flags ----
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=1 ;;
    --only-services) ONLY_SERVICES=1 ;;
    *) echo "Parámetro no reconocido: $arg" ;;
  esac
done

# ---- Banner centrado ----
term_cols=$(tput cols 2>/dev/null || echo 80)
pad() {
  local text="$1"; local len=${#text}
  if (( term_cols > len )); then
    printf "%*s%s\n" $(( (term_cols-len)/2 )) "" "$text"
  else
    echo "$text"
  fi
}

pad "#                 _"
pad "#                | |"
pad "#  ___  ___ _ __ | |__   __ _ ___  ___  __ _ _   _ _ __ __ _"
pad "# / __|/ _ \ '_ \| '_ \ / _` / __|/ _ \/ _` | | | | '__/ _` |"
pad "# \__ \  __/ | | | | | | (_| \__ \  __/ (_| | |_| | | | (_| |"
pad "# |___/\___|_| |_|_| |_|\__,_|___/\___|\__, |\__,_|_|  \__,_|"
pad "#                                       __/ |"
pad "#                                      |___/"
echo

# ---- Gate por contraseña ----
read -s -p "🔐 Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi

# ---- Helpers visuales ----
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
bar_usage() { # barra 50 cols
  local pcent="$1"
  local filled=$((pcent / 2)); (( filled<0 )) && filled=0; (( filled>50 )) && filled=50
  local empty=$((50 - filled))
  printf "%0.s█" $(seq 1 $filled); printf "%0.s░" $(seq 1 $empty)
}
have() { command -v "$1" >/dev/null 2>&1; }

# ---- Prep ----
mkdir -p "$LOGDIR"
echo -e "\n🕒 Inicio de validación: $(date)" | tee -a "$LOGFILE"

# ---- Prerrequisitos y elevación ----
if ! have orbit; then
  echo "❌ No se encontró 'orbit' en PATH. Abortando." | tee -a "$LOGFILE"
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "ℹ️ Se requieren privilegios elevados. Reintentando con sudo..."
  exec sudo -E bash "$0" "$@"
fi

# ---- Funciones para servicios ----
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
  local cmd
  cmd=$(get_services_list_cmd)
  if [[ -z "$cmd" ]]; then
    echo "❌ No existe 'orbit services list' ni 'orbit service list' en esta versión." | tee -a "$LOGFILE"
    return 1
  fi
  eval "$cmd"
}
parse_down_services() {
  # Devuelve por stdout los servicios NO activos a partir de la tabla
  list_services_table | \
  awk -F'|' '
    /\|/ && $2 !~ /NAME|SERVICE|APPLICATION/ {
      svc=$2; st=$3;
      gsub(/^[ \t]+|[ \t]+$/, "", svc);
      gsub(/^[ \t]+|[ \t]+$/, "", st);
      # Considerar como "bien" running/active/ok/up
      if (svc != "" && st != "" && tolower(st) !~ /(running|active|ok|up)/) {
        print svc
      }
    }'
}
restart_service_name() {
  local sname="$1"
  # Reinicio individual con --force
  if orbit services restart "$sname" --force >/dev/null 2>&1; then
    echo "OK"
  else
    echo "FAIL"
  fi
}

# ---- Sección: Servicios (rápida; usada también por --only-services) ----
run_services_section() {
  print_section "Servicios de Senhasegura (auto-reinicio si están caídos)"
  echo "Listado con: $(get_services_list_cmd || echo 'N/D')" | tee -a "$LOGFILE"

  if ! list_services_table >/dev/null 2>&1; then
    echo "❌ No se pudo obtener la lista de servicios." | tee -a "$LOGFILE"
    return
  fi

  list_services_table | tee -a "$LOGFILE"

  mapfile -t down_services < <(parse_down_services || true)

  if ((${#down_services[@]}==0)); then
    echo -e "\n   ➤ Todos los servicios parecen \033[1;32mOK\033[0m." | tee -a "$LOGFILE"
    return
  fi

  echo -e "\n   ⚠️  Servicios detectados como caídos/inactivos:" | tee -a "$LOGFILE"
  for s in "${down_services[@]}"; do
    echo "   - $s" | tee -a "$LOGFILE"
  done

  if (( AUTO==1 )); then
    echo -e "\n   ➤ Modo --auto activo: reinicio sin confirmación..." | tee -a "$LOGFILE"
    for s in "${down_services[@]}"; do
      print_section "Reinicio del servicio: $s"
      res=$(restart_service_name "$s")
      if [[ "$res" == "OK" ]]; then print_status "OK"; else print_status "FAIL"; fi
    done
  else
    read -r -p $'\n¿Deseas reiniciarlos ahora? (y/N): ' confirm
    if [[ "${confirm,,}" == "y" ]]; then
      for s in "${down_services[@]}"; do
        print_section "Reinicio del servicio: $s"
        res=$(restart_service_name "$s")
        if [[ "$res" == "OK" ]]; then print_status "OK"; else print_status "FAIL"; fi
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
  # Borrar invocación del historial (si interactivo)
  if [[ -n "${HISTCMD:-}" ]]; then history -d $((HISTCMD-1)) 2>/dev/null || true; fi
  exit 0
fi

# ---- Secciones completas ----

# 1) Versión
print_section "Versión de Senhasegura"
orbit version 2>&1 | tee -a "$LOGFILE"

# 2) Estado general de la app
print_section "Estado general de la aplicación"
if orbit app status >/dev/null 2>&1; then
  orbit app status | tee -a "$LOGFILE"
else
  echo "Comando 'orbit app status' no disponible en esta versión." | tee -a "$LOGFILE"
fi

# 3) Mantenimiento
print_section "¿Modo de mantenimiento activo?"
MAINT=$(orbit app status 2>/dev/null | awk -F':' '/Maintenance/{gsub(/ /,"",$2);print $2}')
if [[ "$MAINT" == "Yes" ]]; then print_status "WARN"; else print_status "OK"; fi
echo "Maintenance: ${MAINT:-Unknown}" >> "$LOGFILE"

# 4) Hostname
print_section "Hostname configurado"
orbit hostname --show 2>&1 | tee -a "$LOGFILE"

# 5) Red
print_section "Red e IP asignada"
orbit network --show 2>&1 | tee -a "$LOGFILE"

# 6) DNS / conectividad básica
print_section "DNS y salida a Internet (google.com)"
if getent hosts google.com >/dev/null 2>&1; then print_status "OK"; else print_status "FAIL"; fi
(getent hosts google.com || true) 2>&1 | tee -a "$LOGFILE"

# 7) NTP / hora
print_section "Estado de NTP y hora"
if orbit ntp --show >/dev/null 2>&1; then
  orbit ntp --show 2>&1 | tee -a "$LOGFILE"
else
  echo "Comando 'orbit ntp --show' no disponible." | tee -a "$LOGFILE"
fi
if have timedatectl; then timedatectl 2>&1 | tee -a "$LOGFILE"; fi
date 2>&1 | tee -a "$LOGFILE"

# 8) Disco con barra
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
if orbit disk --show >/dev/null 2>&1; then orbit disk --show 2>&1 | tee -a "$LOGFILE"; fi

# 9) Servicios (con auto-reinicio opcional)
run_services_section

# 10) Proxies
for proxy in fajita jumpserver rdpgate nss; do
  if orbit proxy "$proxy" status >/dev/null 2>&1; then
    print_section "Estado del proxy: $proxy"
    orbit proxy "$proxy" status 2>&1 | tee -a "$LOGFILE"
  fi
done

# 11) Domum Remote Access
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

# 12) NATS y eventos async
print_section "NATS / Eventos Async"
if orbit nats stream ls >/dev/null 2>&1; then
  orbit nats stream ls 2>&1 | tee -a "$LOGFILE"
  echo -e "\nSubjects:" | tee -a "$LOGFILE"
  orbit nats stream subjects 2>&1 | tee -a "$LOGFILE"
else
  echo "Comandos NATS no disponibles." | tee -a "$LOGFILE"
fi
if [[ -f /var/log/senhasegura/async/async.log ]]; then
  echo -e "\nÚltimas 100 líneas de async.log:" | tee -a "$LOGFILE"
  tail -n 100 /var/log/senhasegura/async/async.log | tee -a "$LOGFILE"
fi

# 13) Cluster
print_section "Estado de Cluster"
if orbit cluster status >/dev/null 2>&1; then
  orbit cluster status 2>&1 | tee -a "$LOGFILE"
else
  echo "Cluster no disponible o comando ausente." | tee -a "$LOGFILE"
fi

# 14) Ejecuciones/Healthcheck
print_section "Ejecuciones y Healthcheck"
if orbit execution list >/dev/null 2>&1; then
  orbit execution list 2>&1 | tee -a "$LOGFILE"
fi
if orbit healthcheck run --dry-run >/dev/null 2>&1; then
  echo -e "\nHealthcheck disponible (ejecute manualmente para ZIP completo): 'orbit healthcheck run'." | tee -a "$LOGFILE"
fi

# 15) Certificados Web
print_section "Certificados Web (orbit webssl)"
if orbit webssl >/dev/null 2>&1; then
  orbit webssl 2>&1 | tee -a "$LOGFILE"
else
  echo "Comando 'orbit webssl' no disponible." | tee -a "$LOGFILE"
fi

# 16) Backup programado
print_section "Horario de backup configurado"
if orbit backup time --show >/dev/null 2>&1; then
  orbit backup time --show 2>&1 | tee -a "$LOGFILE"
else
  echo "Comando 'orbit backup time --show' no disponible." | tee -a "$LOGFILE"
fi

# 17) Firewall / bloqueos
print_section "Firewall y bloqueos"
if orbit firewall status >/dev/null 2>&1; then
  orbit firewall status 2>&1 | tee -a "$LOGFILE"
else
  echo "Comando 'orbit firewall status' no disponible." | tee -a "$LOGFILE"
fi

# 18) Puertos locales de interés
print_section "Puertos locales en escucha"
for p in "${PORTS_CHECK[@]}"; do
  if ss -tulpen 2>/dev/null | grep -qE "[:.]$p(\s|$)"; then
    echo "   ➤ Port $p: LISTEN" | tee -a "$LOGFILE"
  else
    echo "   ➤ Port $p: NOT LISTEN" | tee -a "$LOGFILE"
  fi
done

# ---- Final ----
echo -e "\n\033[1;34m✔ Validación completada. Revisa el reporte completo en:\033[0m $LOGFILE"

# Borrar la línea de invocación del historial (shell interactivo)
if [[ -n "${HISTCMD:-}" ]]; then
  history -d $((HISTCMD-1)) 2>/dev/null || true
fi
