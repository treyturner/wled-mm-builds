#!/usr/bin/env bash
set -euo pipefail

PUID="${PUID:-$(id -u)}"
PGID="${PGID:-$(id -g)}"
CACHE_KEY="${PIO_BUILDER_CACHE_KEY:-$(basename "$PWD")}"

PIO_CACHE_DIR="$HOME/.platformio"
BUILDER_CACHE_DIR="$HOME/.platformio-builder/${CACHE_KEY}"
NODE_CACHE_DIR="$BUILDER_CACHE_DIR/node_modules"

mkdir -p "$PIO_CACHE_DIR" "$NODE_CACHE_DIR"

docker run --rm -it \
  -e PUID="$PUID" \
  -e PGID="$PGID" \
  -e UMASK="${UMASK:-002}" \
  -e IOT_SSID \
  -e WPA_KEY \
  -v "$PWD/WLED-MM:/work" \
  -v "$PWD/platformio_override.ini:/work/platformio_override.ini" \
  -v "$PIO_CACHE_DIR:/home/pio/.platformio" \
  -v "$NODE_CACHE_DIR:/work/node_modules" \
  -w /work \
  forgejo.treyturner.info/treyturner/platformio-builder \
  "$@"
