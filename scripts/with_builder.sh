#!/usr/bin/env bash
set -euo pipefail

PUID="${PUID:-$(id -u)}"
PGID="${PGID:-$(id -g)}"

# Build repo root (contains scripts/ and platformio_override.ini)
REPO_ROOT="$PWD"

# WLEDMM_DIR is assumed to be a relative path under the repo root.
WLEDMM_DIR="${WLEDMM_DIR:-WLED-MM}"
WLED_DIR="$REPO_ROOT/$WLEDMM_DIR"

if [[ ! -f "$WLED_DIR/platformio.ini" ]]; then
  echo "ERROR: platformio.ini not found in: $WLED_DIR"
  echo "Run scripts/with_builder.sh from the build repo root containing $WLEDMM_DIR/."
  exit 2
fi

PIO_CACHE_DIR="${PIO_CACHE_DIR:-platformio-cache}"
NODE_CACHE_DIR="${NODE_CACHE_DIR:-node-cache}"

# mkdir -p "$PIO_CACHE_DIR" "$NODE_CACHE_DIR/npm"


docker run --rm \
  $([ -t 0 ] && echo -t) $([[ "$-" =~ i ]] && echo -i) \
  --pull always \
  -e PUID="$PUID" \
  -e PGID="$PGID" \
  -e UMASK="${UMASK:-002}" \
  -e FLASH_MODE \
  -e FLASH_SIZE \
  -e GIT_REF \
  -e IOT_SSID \
  -e OUT_DIR \
  -e WLEDMM_DIR \
  -e WPA_KEY \
  -e PLATFORMIO_CORE_DIR=/home/pio/.platformio \
  -e PLATFORMIO_BUILD_CACHE_DIR=/tmp/pio-buildcache \
  -e PLATFORMIO_NO_ANSI \
  -e PLATFORMIO_DISABLE_PROGRESSBAR \
  -v "$PIO_CACHE_DIR:/home/pio/.platformio" \
  -e NPM_CONFIG_CACHE=/node-cache/npm \
  -v "$NODE_CACHE_DIR:/node-cache" \
  -v "$REPO_ROOT:/work" \
  -w "/work/$WLEDMM_DIR" \
  ghcr.io/treyturner/platformio-builder \
  "$@"
