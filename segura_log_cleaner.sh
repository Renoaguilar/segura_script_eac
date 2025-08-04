#!/bin/bash

#                 _
#                | |
#  ___  ___ _ __ | |__   __ _ ___  ___  __ _ _   _ _ __ __ _
# / __|/ _ \ '_ \| '_ \ / _` / __|/ _ \/ _` | | | | '__/ _` |
# \__ \  __/ | | | | | | (_| \__ \  __/ (_| | |_| | | | (_| |
# |___/\___|_| |_|_| |_|\__,_|___/\___|\__, |\__,_|_|  \__,_|
#                                       __/ |
#                                      |___/

# Script: segura_log_cleaner.sh
# Autor: ChatGPT (ajustado para Esteban Ac)
# Función: Limpieza de logs grandes y sesiones huérfanas con resumen visual por archivo

TOP_N=5
MIN_SIZE_MB=50
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

declare -A SIZE_BEFORE_MAP
declare -A SIZE_AFTER_MAP

echo -e "\n${CYAN}📦 ESPACIO INICIAL EN /var/log:${NC}"
SPACE_BEFORE=$(du -sh /var/log | cut -f1)
echo -e "${YELLOW}   ➤ Ocupado: $SPACE_BEFORE${NC}"

echo -e "\n${CYAN}🔍 DETECTANDO LOGS MÁS GRANDES (TOP $TOP_N > ${MIN_SIZE_MB}MB)${NC}"
mapfile -t TARGETS < <(find /var/log -type f -size +${MIN_SIZE_MB}M -exec du -m {} + 2>/dev/null | sort -nr | head -n $TOP_N | awk '{print $2}')

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ No se encontraron logs grandes. Nada que limpiar.${NC}"
else
    echo -e "\n${CYAN}✂️ LIMPIEZA DE LOGS GRANDES (mitad más reciente)${NC}"
    for f in "${TARGETS[@]}"; do
        if [[ -f "$f" ]]; then
            SIZE_BEFORE=$(du -m "$f" | cut -f1)
            TOTAL_LINES=$(wc -l < "$f")
            HALF_LINES=$((TOTAL_LINES / 2))
            if [[ $HALF_LINES -gt 0 ]]; then
                tail -n "$HALF_LINES" "$f" > "$f"
                SIZE_AFTER=$(du -m "$f" | cut -f1)
                SIZE_BEFORE_MAP["$f"]=$SIZE_BEFORE
                SIZE_AFTER_MAP["$f"]=$SIZE_AFTER
                echo -e "${GREEN}   • $f reducido de ${SIZE_BEFORE}MB a ${SIZE_AFTER}MB${NC}"
            else
                echo -e "${RED}   ⚠️  $f tiene muy pocas líneas, se omite.${NC}"
            fi
        fi
    done
fi

echo -e "\n${CYAN}🧽 LIMPIEZA DE SESIONES HUÉRFANAS EN /srv/cache/drive${NC}"
CACHED_DRIVES_PATH=/srv/cache/drive
STATUS_PATH=/var/tmp/
COUNT_REMOVED=0
for SESSION_ID in $(ls -1 "$CACHED_DRIVES_PATH" 2>/dev/null); do
    if ! grep -rIq "$SESSION_ID" "$STATUS_PATH" --include=*.status; then
        FOLDER_FOR_REMOVAL="$CACHED_DRIVES_PATH/$SESSION_ID"
        echo -e "   🗑️  Eliminando sesión inactiva: ${YELLOW}$SESSION_ID${NC}"
        rm -rf "$FOLDER_FOR_REMOVAL"
        COUNT_REMOVED=$((COUNT_REMOVED + 1))
    fi
done

echo -e "\n${CYAN}🔁 REINICIANDO RSYSLOG...${NC}"
systemctl restart rsyslog

SPACE_AFTER=$(du -sh /var/log | cut -f1)
echo -e "\n${CYAN}📊 RESUMEN DE LIMPIEZA POR ARCHIVO${NC}"
printf '%-45s | %10s | %10s | %10s\n' "Archivo" "Antes(MB)" "Después(MB)" "Liberado(MB)"
printf '%.0s-' {1..85}; echo
for f in "${!SIZE_BEFORE_MAP[@]}"; do
    BEFORE=${SIZE_BEFORE_MAP[$f]}
    AFTER=${SIZE_AFTER_MAP[$f]}
    FREED=$((BEFORE - AFTER))
    printf '%-45s | %10s | %10s | %10s\n' "$f" "$BEFORE" "$AFTER" "$FREED"
done

echo -e "\n${CYAN}📈 RESUMEN FINAL${NC}"
echo -e "${GREEN}   • Espacio total liberado: $SPACE_BEFORE → $SPACE_AFTER"
echo -e "   • Logs truncados       : ${#SIZE_BEFORE_MAP[@]}"
echo -e "   • Sesiones eliminadas  : $COUNT_REMOVED${NC}"

echo -e "\n✅ ${GREEN}Limpieza completada con éxito.${NC}"
