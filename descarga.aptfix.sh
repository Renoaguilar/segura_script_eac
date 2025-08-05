#!/bin/bash

# Ruta destino
DESTINO="/tmp/aptfix"
URL="https://downloads.senhasegura.io/d/other/aptfix"

echo -e "\e[33m[INFO] Forzando descarga ignorando certificados SSL...\e[0m"

# Descarga directa con verificación mínima
wget --no-check-certificate --quiet --output-document="$DESTINO" "$URL"

# Validar si se descargó correctamente
if [[ -f "$DESTINO" && -s "$DESTINO" ]]; then
    chmod +x "$DESTINO"
    echo -e "\e[32m[OK] Archivo descargado y preparado: $DESTINO\e[0m"
    echo -e "\e[36mPara ejecutar: sudo $DESTINO\e[0m"
else
    echo -e "\e[31m[ERROR] No se pudo descargar el archivo desde:\e[0m"
    echo -e "\e[31m$URL\e[0m"
    echo -e "\e[31mRevise conectividad, certificados, o intente desde otra red.\e[0m"
    exit 1
fi
