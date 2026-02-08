#!/usr/bin/env bash
set -euo pipefail

env="${1:-}"
if [[ -z "$env" ]]; then
  echo "usage: $0 <platformio-env>"
  exit 2
fi

build_dir=".pio/build/${env}"
mkdir -p "$build_dir"

echo "Staging boot artifacts for env: $env"
echo "PWD: $(pwd)"
echo "HOME: $HOME"
echo "PLATFORMIO_CORE_DIR: ${PLATFORMIO_CORE_DIR:-}"

# Where PlatformIO frameworks live (your wrapper mounts cache to /home/pio/.platformio)
PIO_HOME="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"

# 1) boot_app0.bin
if [[ -f "${build_dir}/boot_app0.bin" ]]; then
  echo "boot_app0.bin already present"
else
  src=""
  for cand in \
    ".pio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin" \
    .pio/packages/framework-arduinoespressif32@*/tools/partitions/boot_app0.bin \
    "${PIO_HOME}/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin" \
    "${PIO_HOME}"/packages/framework-arduinoespressif32@*/tools/partitions/boot_app0.bin
  do
    # glob-safe: expand, pick first file that exists
    for f in $cand; do
      if [[ -f "$f" ]]; then src="$f"; break 2; fi
    done
  done

  if [[ -z "$src" ]]; then
    echo "ERROR: boot_app0.bin not found in framework packages"
    exit 2
  fi

  echo "boot_app0: $src -> ${build_dir}/boot_app0.bin"
  cp -f "$src" "${build_dir}/boot_app0.bin"
fi

# 2) bootloader.bin (tinyUF2 recovery)
if [[ -f "${build_dir}/bootloader.bin" ]]; then
  echo "bootloader.bin present"
else
  # Try to infer variant from build deps
  variant="$(
    ( command -v rg >/dev/null 2>&1 && rg -g '*.d' -m1 --no-filename -o 'variants/[^/]+/' "$build_dir" 2>/dev/null || true; \
      command -v rg >/dev/null 2>&1 || grep -R -h -m1 -o 'variants/[^/]\+/' "$build_dir" 2>/dev/null || true ) \
    | head -n1 | sed -E 's#.*variants/([^/]+)/#\1#'
  )"

  # Hardcode your known special-case fallback if inference fails
  if [[ -z "$variant" && "$env" == "adafruit_matrix_portal_s3" ]]; then
    variant="adafruit_matrixportal_esp32s3"
  fi

  echo "variant: ${variant:-<unknown>}"

  cand=""
  if [[ -n "$variant" ]]; then
    for pkg in \
      "${PIO_HOME}/packages/framework-arduinoespressif32" \
      "${PIO_HOME}"/packages/framework-arduinoespressif32@*
    do
      [[ -d "$pkg" ]] || continue
      if [[ -f "$pkg/variants/$variant/bootloader-tinyuf2.bin" ]]; then
        cand="$pkg/variants/$variant/bootloader-tinyuf2.bin"
        break
      fi
    done
  fi

  # last-resort: first bootloader-tinyuf2 anywhere
  if [[ -z "$cand" ]]; then
    cand="$(find "${PIO_HOME}/packages" -maxdepth 6 -type f -name 'bootloader-tinyuf2.bin' 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$cand" || ! -f "$cand" ]]; then
    echo "ERROR: bootloader.bin missing and no bootloader-tinyuf2.bin found"
    exit 2
  fi

  echo "bootloader (tinyUF2): $cand -> ${build_dir}/bootloader.bin"
  cp -f "$cand" "${build_dir}/bootloader.bin"
fi
