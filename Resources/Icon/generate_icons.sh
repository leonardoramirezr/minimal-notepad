#!/usr/bin/env bash
set -euo pipefail

# generate_icons.sh
# Genera un AppIcon.icns para macOS a partir de un SVG maestro.
#
# Requisitos:
#   brew install librsvg   # provee `rsvg-convert`
#
# Uso:
#   ./generate_icons.sh logo.svg [nombre_salida]
#   ./generate_icons.sh logo.svg AppIcon
#
# Produce AppIcon.icns en el directorio actual (borra la carpeta
# .iconset temporal al terminar).

SVG="${1:?Uso: $0 archivo.svg [nombre_salida]}"
NAME="${2:-AppIcon}"
ICONSET="${NAME}.iconset"

if [ ! -f "$SVG" ]; then
  echo "Error: no se encontró el archivo '$SVG'" >&2
  exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "Error: falta rsvg-convert. Instálalo con: brew install librsvg" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# tamaño_px:nombre_archivo (convención estándar de .iconset)
SIZES=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

echo "Generando ${#SIZES[@]} tamaños desde $SVG..."
for entry in "${SIZES[@]}"; do
  px="${entry%%:*}"
  file="${entry##*:}"
  rsvg-convert -w "$px" -h "$px" "$SVG" -o "${ICONSET}/${file}"
  echo "  -> ${file} (${px}x${px})"
done

iconutil -c icns "$ICONSET" -o "${NAME}.icns"
rm -rf "$ICONSET"

echo "Listo: ${NAME}.icns"
