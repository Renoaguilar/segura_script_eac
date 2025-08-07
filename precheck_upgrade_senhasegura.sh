#!/bin/bash
# Validación previa a upgrade offline de Senhasegura

#!/bin/bash

PASSWORD="Segura2025"

read -s -p "🔐 Ingresa la contraseña para ejecutar este script: " user_pass
echo ""
if [[ "$user_pass" != "$PASSWORD" ]]; then
  echo "❌ Contraseña incorrecta. Abortando..."
  exit 1
fi



YELLOW="\e[33m"
GREEN="\e[32m"
RED="\e[31m"
NC="\e[0m"

echo -e "${YELLOW}[INFO] Validación Pre-Upgrade para Senhasegura${NC}"

# 1. Validar usuario root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] Este script debe ejecutarse como root.${NC}"
  exit 1
fi

# 2. Verificar versión actual
echo -e "\n${YELLOW}[INFO] Versión actual de Orbit:${NC}"
orbit version

echo -e "\n${YELLOW}[INFO] Versiones de componentes de la app:${NC}"
orbit app version || echo -e "${RED}[WARN] Orbit app version no disponible${NC}"

# 3. Recursos
echo -e "\n${YELLOW}[INFO] Recursos del sistema:${NC}"
echo -e "🧠 Memoria RAM:" && free -h
echo -e "💽 CPU cores: $(nproc)"
echo -e "🗂️ Espacio en disco:" && df -h / /var /srv /opt /tmp 2>/dev/null

# 4. Servicios críticos
echo -e "\n${YELLOW}[INFO] Servicios críticos:${NC}"
for svc in mysql nginx php-fpm cron elasticsearch-senhasegura wazuh-manager; do
  echo -e "\n➡️ ${svc}:"
  systemctl is-active $svc && systemctl status $svc | head -5
done

# 5. Estado de la aplicación
echo -e "\n${YELLOW}[INFO] Estado de la app PAM:${NC}"
orbit app status

# 6. Tareas automáticas habilitadas
echo -e "\n${YELLOW}[INFO] Procesos de ejecución activos (async):${NC}"
orbit execution list | grep -i enabled || echo -e "${GREEN}[OK] Sin procesos críticos en ejecución${NC}"

# 7. DNS comentado
echo -e "\n${YELLOW}[INFO] Validación de resolv.conf:${NC}"
if grep -E "^\s*#.*nameserver" /etc/resolv.conf >/dev/null; then
  echo -e "${RED}[WARN] DNS está comentado. Revisa /etc/resolv.conf${NC}"
else
  echo -e "${GREEN}[OK] DNS parece estar configurado correctamente${NC}"
fi

# 8. Uso en /var/senhasegura, /var/log, /srv
echo -e "\n${YELLOW}[INFO] Carpetas que más espacio consumen:${NC}"
for dir in /var/senhasegura /var/log /srv; do
  echo -e "\n📁 $dir:"
  du -h --max-depth=1 $dir 2>/dev/null | sort -hr | head -10
done

# 9. Validar disponibilidad de red (opcional)
echo -e "\n${YELLOW}[INFO] Verificando conectividad a repositorio (opcional)...${NC}"
ping -c1 downloads.senhasegura.io &>/dev/null && {
  echo -e "${GREEN}[OK] Hay conectividad a internet${NC}"
  apt update -qq && echo -e "${GREEN}[OK] apt update ejecutado sin errores${NC}" || echo -e "${RED}[WARN] Error en apt update${NC}"
} || echo -e "${YELLOW}[INFO] Entorno sin conexión, se asume instalación offline${NC}"

# 10. Validación final
echo -e "\n${GREEN}[FINALIZADO] Prevalidación completa. Revisa advertencias si las hay.${NC}"
