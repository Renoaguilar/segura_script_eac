#!/bin/bash
unset HISTFILE
history -d $((HISTCMD-1)) 2>/dev/null
history -w 2>/dev/null

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
# Función: Check_Orbit

# Pass Senhasegura
PASSWORD="Segura2025"

read -s -p "🔐 Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi

# -----------------------------------------------
# VALIDACIÓN VISUAL DE ESTADO SENHASEGURA ORBIT
# -----------------------------------------------

LOGFILE="/var/tmp/segura_orbit_resumen_$(date +%Y%m%d_%H%M%S).log"
echo -e "\n🕒 Inicio de validación: $(date)" | tee -a "$LOGFILE"

# Función para imprimir sección con bordes visuales
print_section() {
    echo -e "\n\033[1;36m╔════════════════════════════════════════╗"
    printf "║ %-38s ║\n" "$1"
    echo -e "╚════════════════════════════════════════╝\033[0m"
    echo -e "\n## $1\n" >> "$LOGFILE"
}

# Función para resaltado OK / WARN / FAIL
print_status() {
    status="$1"
    case "$status" in
        OK) echo -e "   ➤ \033[1;32m[$status]\033[0m" ;;
        WARN) echo -e "   ➤ \033[1;33m[$status]\033[0m" ;;
        FAIL) echo -e "   ➤ \033[1;31m[$status]\033[0m" ;;
        *) echo -e "   ➤ [$status]" ;;
    esac
}

# 1. Versión instalada
print_section "Versión de Senhasegura"
sudo orbit version 2>&1 | tee -a "$LOGFILE"

# 2. Estado del sistema
print_section "Estado general de la aplicación"
sudo orbit app status 2>&1 | tee -a "$LOGFILE"

# 3. ¿Está en mantenimiento?
print_section "¿Modo de mantenimiento activo?"
MAINT=$(sudo orbit app status | grep "Maintenance" | awk '{print $2}')
if [[ "$MAINT" == "Yes" ]]; then
    print_status "WARN"
else
    print_status "OK"
fi
echo "Maintenance: $MAINT" >> "$LOGFILE"

# 4. Hostname
print_section "Hostname configurado"
sudo orbit hostname --show 2>&1 | tee -a "$LOGFILE"

# 5. Red: IP, máscara, gateway
print_section "Red e IP asignada"
sudo orbit network --show 2>&1 | tee -a "$LOGFILE"

# 6. Resolución DNS
print_section "DNS y salida a Internet (google.com)"
if getent hosts google.com > /dev/null; then
    print_status "OK"
else
    print_status "FAIL"
fi
getent hosts google.com 2>&1 | tee -a "$LOGFILE"

# 7. Estado del Disco (ordenado visualmente)
print_section "Estado del Disco (uso de particiones)"

# Extraer, ordenar y visualizar uso de disco
df -h --output=source,size,used,avail,pcent,target | tail -n +2 | sort -k5 -nr | while read -r line; do
    device=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    pcent=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')

    filled=$((pcent / 2))
    empty=$((50 - filled))
    bar="$(printf '%0.s█' $(seq 1 $filled))$(printf '%0.s░' $(seq 1 $empty))"

    if [ "$pcent" -ge 95 ]; then color="\033[1;31m" && estado="FAIL"
    elif [ "$pcent" -ge 80 ]; then color="\033[1;33m" && estado="WARN"
    else color="\033[1;32m" && estado="OK"
    fi

    printf "📁 %-20s %5s usadas / %5s totales en %s\n" "$device" "$used" "$size" "$mount" | tee -a "$LOGFILE"
    printf "   ➤ Uso: ${color}[%s] %s%%\033[0m (%s)\n\n" "$bar" "$pcent" "$estado" | tee -a "$LOGFILE"
done

# Información adicional de particiones vía Orbit
echo -e "\n🔍 Detalles de particiones (Orbit):\n" | tee -a "$LOGFILE"
sudo orbit disk --show 2>&1 | tee -a "$LOGFILE"

# 8. Estado de Proxies
for proxy in fajita jumpserver rdpgate nss; do
    print_section "Estado del proxy: $proxy"
    sudo orbit proxy "$proxy" status 2>&1 | tee -a "$LOGFILE"
done

# 9. Firewall: IPs bloqueadas
print_section "Hosts bloqueados por fallos SSH"
sudo orbit firewall status 2>&1 | tee -a "$LOGFILE"

# 10. Backup: hora configurada
print_section "Horario de backup configurado"
sudo orbit backup time --show 2>&1 | tee -a "$LOGFILE"

# Final
echo -e "\n\033[1;34m✔ Validación completada. Revisa el reporte completo en:\033[0m $LOGFILE"
history -d $((HISTCMD-1))
