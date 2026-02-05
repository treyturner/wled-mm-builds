#!/usr/bin/env bash
set -euo pipefail

PUID="${PUID:-$(id -u)}"
PGID="${PGID:-$(id -g)}"
CACHE_KEY="${PIO_BUILDER_CACHE_KEY:-$(basename "$PWD")}"

PIO_CACHE_DIR="$HOME/.platformio"
BUILDER_CACHE_DIR="$HOME/.platformio-builder/${CACHE_KEY}"
NODE_CACHE_DIR="$BUILDER_CACHE_DIR/node_modules"

mkdir -p "$PIO_CACHE_DIR" "$NODE_CACHE_DIR"

# Where the repo lives in the job container
WS="${FORGEJO_WORKSPACE:-$PWD}"
WLED_DIR="$WS/WLED-MM"

echo "job pwd: $(pwd)"
echo "FORGEJO_WORKSPACE: ${FORGEJO_WORKSPACE:-}"
echo "WS: $WS"
echo "WLED_DIR: $WLED_DIR"
ls -al "$WLED_DIR/platformio.ini" || true

MOUNTS=()
WORKDIR=""

if docker inspect "$HOSTNAME" >/dev/null 2>&1; then
  # CI/job-container case: share the workspace volume(s)
  MOUNTS+=(--volumes-from "$HOSTNAME")
  WORKDIR="$WLED_DIR"
else
  # local case: bind-mount the project into /work
  MOUNTS+=(
    -v "$WLED_DIR:/work"
    -v "$WS/platformio_override.ini:/work/platformio_override.ini:ro"
  )
  WORKDIR="/work"
fi

docker run --rm \
  $([ -t 0 ] && echo -t) $([[ "$-" =~ i ]] && echo -i) \
  --pull always \
  -e PUID="$PUID" \
  -e PGID="$PGID" \
  -e UMASK="${UMASK:-002}" \
  -e IOT_SSID \
  -e WPA_KEY \
  -v "$PIO_CACHE_DIR:/home/pio/.platformio" \
  -v "$NODE_CACHE_DIR:$WORKDIR/node_modules" \
  "${MOUNTS[@]}" \
  -w "$WORKDIR" \
  forgejo.treyturner.info/treyturner/platformio-builder \
  "$@"