#!/usr/bin/env bash
#
# VibeAmp — build script
#
# Compila la app con xcodebuild y deja el bundle listo en dist/VibeAmp.app
#
#   ./scripts/build.sh                # Release -> dist/VibeAmp.app
#   ./scripts/build.sh --debug        # Debug
#   ./scripts/build.sh --clean --zip  # limpia, compila y empaqueta dist/VibeAmp-<version>.zip
#   ./scripts/build.sh --open         # abre la app al terminar
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$PROJECT_ROOT/VibeAmp.xcodeproj"
SCHEME="VibeAmp"
APP_NAME="VibeAmp.app"

CONFIGURATION="Release"
DIST_DIR="$PROJECT_ROOT/dist"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
DO_CLEAN=0
DO_ZIP=0
DO_OPEN=0

usage() {
  cat <<'USAGE'
Uso: scripts/build.sh [opciones]

  --debug              Compila en configuración Debug (por defecto: Release)
  --release            Compila en configuración Release
  --clean              Borra DerivedData y dist/ antes de compilar
  --zip                Crea también dist/VibeAmp-<version>.zip
  --open               Abre dist/VibeAmp.app al terminar
  --dist <dir>         Directorio de salida (por defecto: ./dist)
  -h, --help           Muestra esta ayuda
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)    CONFIGURATION="Debug"; shift ;;
    --release)  CONFIGURATION="Release"; shift ;;
    --clean)    DO_CLEAN=1; shift ;;
    --zip)      DO_ZIP=1; shift ;;
    --open)     DO_OPEN=1; shift ;;
    --dist)     DIST_DIR="${2:?--dist necesita un directorio}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Opción desconocida: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --dist relativo -> absoluto
[[ "$DIST_DIR" = /* ]] || DIST_DIR="$PROJECT_ROOT/$DIST_DIR"

command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: xcodebuild no encontrado. Instala Xcode y ejecuta: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
}
[[ -d "$PROJECT" ]] || { echo "error: no existe $PROJECT" >&2; exit 1; }

echo "==> VibeAmp · $CONFIGURATION"
echo "    proyecto: $PROJECT"
echo "    salida:   $DIST_DIR"

if [[ $DO_CLEAN -eq 1 ]]; then
  echo "==> Limpiando"
  rm -rf "$DERIVED_DATA" "$DIST_DIR"
fi

# Formateador de log opcional (xcbeautify / xcpretty) si está instalado
FORMATTER=""
if command -v xcbeautify >/dev/null 2>&1; then
  FORMATTER="xcbeautify"
elif command -v xcpretty >/dev/null 2>&1; then
  FORMATTER="xcpretty"
fi

echo "==> Compilando"
build() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build
}

if [[ -n "$FORMATTER" ]]; then
  set -o pipefail
  build | "$FORMATTER"
else
  build
fi

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
[[ -d "$BUILT_APP" ]] || { echo "error: no se generó $BUILT_APP" >&2; exit 1; }

echo "==> Copiando a dist/"
mkdir -p "$DIST_DIR"
rm -rf "${DIST_DIR:?}/$APP_NAME"
ditto "$BUILT_APP" "$DIST_DIR/$APP_NAME"

# Firma ad-hoc: el proyecto usa CODE_SIGN_IDENTITY = "-" (distribución directa, sin notarizar).
# ditto preserva la firma, pero revalidamos por si acaso.
if ! codesign --verify --deep --strict "$DIST_DIR/$APP_NAME" 2>/dev/null; then
  echo "==> Re-firmando ad-hoc"
  codesign --force --deep --sign - "$DIST_DIR/$APP_NAME"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$DIST_DIR/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo "0.0")"
BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$DIST_DIR/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo "0")"

if [[ $DO_ZIP -eq 1 ]]; then
  ZIP_PATH="$DIST_DIR/VibeAmp-$VERSION.zip"
  echo "==> Empaquetando $(basename "$ZIP_PATH")"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/$APP_NAME" "$ZIP_PATH"
fi

echo
echo "✅ Listo — VibeAmp $VERSION ($BUILD_NO) · $CONFIGURATION"
echo "   $DIST_DIR/$APP_NAME  ($(du -sh "$DIST_DIR/$APP_NAME" | cut -f1))"
[[ $DO_ZIP -eq 1 ]] && echo "   $DIST_DIR/VibeAmp-$VERSION.zip  ($(du -sh "$DIST_DIR/VibeAmp-$VERSION.zip" | cut -f1))"
echo
echo "   Abrir:  open \"$DIST_DIR/$APP_NAME\""

[[ $DO_OPEN -eq 1 ]] && open "$DIST_DIR/$APP_NAME"
exit 0
