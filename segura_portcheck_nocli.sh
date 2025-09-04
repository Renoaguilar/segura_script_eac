#!/usr/bin/env bash
# ------------------------------------------------------------
# Segura® / Network Connector - Validador de Puertos (sin netcat)
# Usa /dev/tcp y /dev/udp (bash built-ins) + timeout
# Versión: 1.0 (2025-09-04)
# ------------------------------------------------------------
set -euo pipefail

# ====== CONFIGURACIÓN: EDITA TUS HOSTS/IP ======
# Segmenta por tipo según tu tabla. Puedes dejar listas vacías si no aplican.

# Conectividad NC -> SEGURA (puerto de Network Connector)
SEGURA_HOSTS=("segura.ejemplo.local" "10.10.10.10")
SEGURA_PORTS_TCP=(51445)   # Network Connector

# Gestión / Infra
DNS_SERVERS=("10.10.1.53" "10.10.2.53")       # UDP/TCP 53
NTP_SERVERS=("10.10.1.123")                    # UDP 123
RADIUS_SERVERS=("10.10.1.1812")                # UDP 1812
TACACS_SERVERS=("10.10.1.49")                  # TCP/UDP 49
SYSLOG_SERVERS=("10.20.1.50")                  # UDP 514 / TCP 514 / TLS 6514
SMTP_SERVERS=("mail.ejemplo.local")            # TCP 587 (submission)
LDAP_SERVERS=("ad01.ejemplo.local")            # TCP 389
LDAPS_SERVERS=("ad01.ejemplo.local")           # TCP 636

# Usuarios finales -> SEGURA (normalmente validas desde el lado cliente; aquí probamos desde NC hacia SEGURA)
USERS_TO_SEGURA_TCP=("443:Interfaz web HTTPS" "22:Proxy SSH" "3389:Proxy RDP" "1433:DB Proxy MSSQL" "2484:DB Proxy Oracle TCPS" "5432:DB Proxy PostgreSQL")
# Para UDP Oracle 2484 usualmente es TCPS (TCP). Se deja TCP 2484 arriba.

# NC/Segura -> Dispositivos gestionados (targets)
TARGETS_SSH=("srv-linux01" "192.168.1.20")     # TCP 22
TARGETS_TELNET=("router01")                    # TCP 23
TARGETS_HTTP=("app01")                         # TCP 80
TARGETS_HTTPS=("app01")                        # TCP 443
TARGETS_SMB=("winfile01")                      # TCP 445
TARGETS_RDP=("winjump01")                      # TCP 3389
TARGETS_RPC=("winjump01")                      # TCP 135 (Mapper)
TARGETS_DB_MSSQL=("sql01")                     # TCP 1433
TARGETS_DB_ORACLE=("ora01")                    # TCP 1521
TARGETS_DB_ORACLE_TCPS=("ora01")               # TCP 2484
TARGETS_DB_POSTGRES=("pg01")                   # TCP 5432
TARGETS_DB_MYSQL=("mysql01")                   # TCP 3306

# Backup (comunes)
BACKUP_TFTP=("bk01")                           # UDP 69
BACKUP_SFTP=("bk01")                           # TCP 22
BACKUP_NFS=("bk01")                            # TCP 2049 (NFSv4) + 111 (rpcbind)
BACKUP_SMB=("bk01")                            # TCP 445

# ====== PARÁMETROS ======
TCP_TIMEOUT=3
UDP_TIMEOUT=3

# ====== SALIDAS ======
START_TS=$(date +"%Y%m%d_%H%M%S")
OUTDIR="./salidas"
mkdir -p "$OUTDIR"
CSV_FILE="${OUTDIR}/segura_portcheck_${START_TS}.csv"
JSON_FILE="${OUTDIR}/segura_portcheck_${START_TS}.json"
LOG_FILE="${OUTDIR}/segura_portcheck_${START_TS}.log"

# ====== FORMATO SALIDA ======
echo "tipo,origen,host,puerto,proto,descripcion,resultado,detalle" > "$CSV_FILE"
echo "[" > "$JSON_FILE"; FIRST_JSON=1

# ====== HELPERS ======
log(){ printf '[%(%F %T)T] %s\n' -1 "$*" >> "$LOG_FILE"; }

append_csv_json(){
  local tipo="$1" origen="$2" host="$3" puerto="$4" proto="$5" desc="$6" res="$7" det="$8"
  printf "%s,%s,%s,%s,%s,%s,%s,%s\n" "$tipo" "$origen" "$host" "$puerto" "$proto" "$desc" "$res" "$det" >> "$CSV_FILE"
  local line
  line=$(printf '{"tipo":"%s","origen":"%s","host":"%s","puerto":%s,"proto":"%s","descripcion":"%s","resultado":"%s","detalle":"%s"}' \
    "$tipo" "$origen" "$host" "$puerto" "$proto" "$desc" "$res" "$det")
  if [ $FIRST_JSON -eq 1 ]; then echo "  $line" >> "$JSON_FILE"; FIRST_JSON=0; else echo " ,$line" >> "$JSON_FILE"; fi
}

# ====== PROBADORES ======
check_tcp(){
  local host="$1" port="$2" desc="$3" origin="$4"
  if timeout "${TCP_TIMEOUT}s" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    echo "[OK]  TCP $host:$port - $desc"
    log  "[OK] TCP $host:$port - $desc"
    append_csv_json "TCP" "$origin" "$host" "$port" "tcp" "$desc" "OK" "conectado"
    exec 3>&- 3<&- || true
  else
    echo "[FAIL] TCP $host:$port - $desc"
    log  "[FAIL] TCP $host:$port - $desc"
    append_csv_json "TCP" "$origin" "$host" "$port" "tcp" "$desc" "FAIL" "sin_conexion"
  fi
}

check_udp(){
  local host="$1" port="$2" desc="$3" origin="$4"
  # Best-effort: éxito = envío sin error inmediato/ICMP
  if timeout "${UDP_TIMEOUT}s" bash -c "echo ping >/dev/udp/$host/$port" 2>/dev/null; then
    echo "[UDP*] $host:$port - $desc (best-effort)"
    log  "[UDP*] $host:$port - $desc"
    append_csv_json "UDP" "$origin" "$host" "$port" "udp" "$desc" "OK" "datagrama_enviado"
  else
    echo "[FAIL] UDP $host:$port - $desc"
    log  "[FAIL] UDP $host:$port - $desc"
    append_csv_json "UDP" "$origin" "$host" "$port" "udp" "$desc" "FAIL" "error_envio_icmp"
  fi
}

bulk_tcp(){ local desc="$1" port="$2" origin="$3"; shift 3; for h in "$@"; do check_tcp "$h" "$port" "$desc" "$origin"; done; }
bulk_udp(){ local desc="$1" port="$2" origin="$3"; shift 3; for h in "$@"; do check_udp "$h" "$port" "$desc" "$origin"; done; }

# ====== EJECUCIÓN ======
echo ">>> Iniciando validación (sin netcat): $START_TS"
log  "Inicio pruebas"

# NC -> SEGURA
for host in "${SEGURA_HOSTS[@]}"; do
  for p in "${SEGURA_PORTS_TCP[@]}"; do
    check_tcp "$host" "$p" "Network Connector" "NC"
  done
done

# Gestión
[ "${#DNS_SERVERS[@]}"    -gt 0 ] && bulk_udp "DNS" 53 "NC" "${DNS_SERVERS[@]}"
[ "${#DNS_SERVERS[@]}"    -gt 0 ] && bulk_tcp "DNS (TCP opcional)" 53 "NC" "${DNS_SERVERS[@]}"
[ "${#NTP_SERVERS[@]}"    -gt 0 ] && bulk_udp "NTP" 123 "NC" "${NTP_SERVERS[@]}"
[ "${#RADIUS_SERVERS[@]}" -gt 0 ] && bulk_udp "RADIUS" 1812 "NC" "${RADIUS_SERVERS[@]}"
[ "${#TACACS_SERVERS[@]}" -gt 0 ] && bulk_tcp "TACACS" 49 "NC" "${TACACS_SERVERS[@]}"
[ "${#TACACS_SERVERS[@]}" -gt 0 ] && bulk_udp "TACACS" 49 "NC" "${TACACS_SERVERS[@]}"
[ "${#SYSLOG_SERVERS[@]}" -gt 0 ] && bulk_udp "SYSLOG" 514 "NC" "${SYSLOG_SERVERS[@]}"
[ "${#SYSLOG_SERVERS[@]}" -gt 0 ] && bulk_tcp "SYSLOG (TCP)" 514 "NC" "${SYSLOG_SERVERS[@]}"
[ "${#SYSLOG_SERVERS[@]}" -gt 0 ] && bulk_tcp "SYSLOG (TLS)" 6514 "NC" "${SYSLOG_SERVERS[@]}"
[ "${#SMTP_SERVERS[@]}"   -gt 0 ] && bulk_tcp "SMTP submission" 587 "NC" "${SMTP_SERVERS[@]}"
[ "${#LDAP_SERVERS[@]}"   -gt 0 ] && bulk_tcp "LDAP" 389 "NC" "${LDAP_SERVERS[@]}"
[ "${#LDAPS_SERVERS[@]}"  -gt 0 ] && bulk_tcp "LDAPS" 636 "NC" "${LDAPS_SERVERS[@]}"

# Usuarios finales -> SEGURA (probar desde NC hacia SEGURA por disponibilidad)
if [ "${#SEGURA_HOSTS[@]}" -gt 0 ] && [ "${#USERS_TO_SEGURA_TCP[@]}" -gt 0 ]; then
  for host in "${SEGURA_HOSTS[@]}"; do
    for item in "${USERS_TO_SEGURA_TCP[@]}"; do
      port="${item%%:*}"; desc="${item#*:}"
      check_tcp "$host" "$port" "$desc" "NC"
    done
  done
fi

# Targets gestionados
[ "${#TARGETS_SSH[@]}"       -gt 0 ] && bulk_tcp "SSH" 22 "NC" "${TARGETS_SSH[@]}"
[ "${#TARGETS_TELNET[@]}"    -gt 0 ] && bulk_tcp "TELNET" 23 "NC" "${TARGETS_TELNET[@]}"
[ "${#TARGETS_HTTP[@]}"      -gt 0 ] && bulk_tcp "HTTP" 80 "NC" "${TARGETS_HTTP[@]}"
[ "${#TARGETS_HTTPS[@]}"     -gt 0 ] && bulk_tcp "HTTPS" 443 "NC" "${TARGETS_HTTPS[@]}"
[ "${#TARGETS_SMB[@]}"       -gt 0 ] && bulk_tcp "SMB" 445 "NC" "${TARGETS_SMB[@]}"
[ "${#TARGETS_RDP[@]}"       -gt 0 ] && bulk_tcp "RDP" 3389 "NC" "${TARGETS_RDP[@]}"
[ "${#TARGETS_RPC[@]}"       -gt 0 ] && bulk_tcp "RPC Endpoint Mapper" 135 "NC" "${TARGETS_RPC[@]}"
[ "${#TARGETS_DB_MSSQL[@]}"  -gt 0 ] && bulk_tcp "MS-SQL" 1433 "NC" "${TARGETS_DB_MSSQL[@]}"
[ "${#TARGETS_DB_ORACLE[@]}" -gt 0 ] && bulk_tcp "Oracle Listener" 1521 "NC" "${TARGETS_DB_ORACLE[@]}"
[ "${#TARGETS_DB_ORACLE_TCPS[@]}" -gt 0 ] && bulk_tcp "Oracle TCPS" 2484 "NC" "${TARGETS_DB_ORACLE_TCPS[@]}"
[ "${#TARGETS_DB_POSTGRES[@]}" -gt 0 ] && bulk_tcp "PostgreSQL" 5432 "NC" "${TARGETS_DB_POSTGRES[@]}"
[ "${#TARGETS_DB_MYSQL[@]}"  -gt 0 ] && bulk_tcp "MySQL" 3306 "NC" "${TARGETS_DB_MYSQL[@]}"

# Backup
[ "${#BACKUP_TFTP[@]}"  -gt 0 ] && bulk_udp "Backup TFTP" 69 "NC" "${BACKUP_TFTP[@]}"
[ "${#BACKUP_SFTP[@]}"  -gt 0 ] && bulk_tcp "Backup SFTP" 22 "NC" "${BACKUP_SFTP[@]}"
[ "${#BACKUP_NFS[@]}"   -gt 0 ] && bulk_tcp "NFSv4" 2049 "NC" "${BACKUP_NFS[@]}"
[ "${#BACKUP_NFS[@]}"   -gt 0 ] && bulk_tcp "RPCBind" 111 "NC" "${BACKUP_NFS[@]}"
[ "${#BACKUP_SMB[@]}"   -gt 0 ] && bulk_tcp "Backup SMB" 445 "NC" "${BACKUP_SMB[@]}"

# ====== RESUMEN ======
echo "]" >> "$JSON_FILE"

TOTAL=0; OKS=0; FAILS=0
while IFS=, read -r tipo origen host puerto proto descripcion resultado detalle; do
  [ "$tipo" = "tipo" ] && continue
  TOTAL=$((TOTAL+1))
  if [ "$resultado" = "OK" ]; then OKS=$((OKS+1)); else FAILS=$((FAILS+1)); fi
done < "$CSV_FILE"

echo
echo "================= RESUMEN ================="
echo "  Pruebas totales: $TOTAL"
echo "  OK:   $OKS"
echo "  FAIL: $FAILS"
echo "==========================================="
echo
echo "Archivos generados:"
echo "  - CSV:  $CSV_FILE"
echo "  - JSON: $JSON_FILE"
echo "  - LOG:  $LOG_FILE"

# Salida útil para automatización
[ "$FAILS" -eq 0 ] && exit 0 || exit 1
