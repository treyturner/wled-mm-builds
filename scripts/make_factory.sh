#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <platformio-env> [env ...]"
  exit 2
fi

FLASH_MODE="${FLASH_MODE:-dio}"
FLASH_SIZE="${FLASH_SIZE:-4MB}"
OUT_DIR="${OUT_DIR:-build}"
GIT_REF="${GIT_REF:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# WLEDMM_DIR is assumed to be a relative path under the repo root.
WLEDMM_DIR="${WLEDMM_DIR:-WLED-MM}"
WLED_DIR="$REPO_ROOT/$WLEDMM_DIR"

if [[ ! -d "$WLED_DIR" ]]; then
  echo "ERROR: WLED-MM directory not found: $WLED_DIR"
  exit 2
fi
if [[ ! -f "$WLED_DIR/platformio.ini" ]]; then
  echo "ERROR: platformio.ini not found in: $WLED_DIR"
  exit 2
fi
if ! command -v pio >/dev/null 2>&1; then
  echo "ERROR: pio not found in PATH"
  exit 2
fi

PIO_HOME="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"

normal_git_ref="$GIT_REF"
if [[ "$normal_git_ref" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  normal_git_ref="${BASH_REMATCH[1]}"
fi

sanitize_name() {
  local s="$1"
  printf '%s' "$s" | sed -E 's/["'"'"'\\]//g; s/^MM[[:space:]]+//'
}

esptool_cmd=(pio pkg exec -p tool-esptoolpy -- esptool.py)

mkdir -p "$REPO_ROOT/$OUT_DIR"

cd "$WLED_DIR"
for env in "$@"; do
  build_dir="$WLED_DIR/.pio/build/$env"
  bootloader="$build_dir/bootloader.bin"
  partitions="$build_dir/partitions.bin"
  bootapp0="$build_dir/boot_app0.bin"
  firmware="$build_dir/firmware.bin"

  # Try to infer the board variant name from build artifacts.
  variant="$(
    ( command -v rg >/dev/null 2>&1 && rg -g '*.d' -m1 --no-filename -o 'variants/[^/]+/' "$build_dir" 2>/dev/null || true; \
      command -v rg >/dev/null 2>&1 || grep -R -h -m1 -o 'variants/[^/]\\+/' "$build_dir" 2>/dev/null || true ) \
    | head -n1 | sed -E 's#.*variants/([^/]+)/#\1#'
  )"
  if [[ -z "$variant" ]]; then
    case "$env" in \
      adafruit_matrix_portal_s3) variant="adafruit_matrixportal_esp32s3" ;; \
    esac
  fi

  echo "Framework packages:"
  ls -d "$PIO_HOME/packages/framework-arduinoespressif32"* 2>/dev/null || true
  echo "Variant dirs (sample):"
  for pkg in "$PIO_HOME/packages/framework-arduinoespressif32" "$PIO_HOME/packages/framework-arduinoespressif32@"*; do
  [[ -d "$pkg/variants" ]] || continue
  echo "== $pkg/variants =="
  ls -1 "$pkg/variants" | head -n 50
  done

  # Some Adafruit tinyUF2 envs don't emit bootloader.bin; recover from framework packages.
  if [[ ! -f "$bootloader" ]]; then
    found_boot=0
    for pkg in "$PIO_HOME/packages/framework-arduinoespressif32" \
        "$PIO_HOME/packages/framework-arduinoespressif32@"*; do
      [[ -d "$pkg" ]] || continue

      cand=""
      if [[ -n "$variant" && -f "$pkg/variants/$variant/bootloader-tinyuf2.bin" ]]; then
        cand="$pkg/variants/$variant/bootloader-tinyuf2.bin"
      elif [[ -d "$pkg/variants" ]]; then
        cand="$(find "$pkg/variants" -maxdepth 3 -type f -name 'bootloader-tinyuf2.bin' 2>/dev/null | head -n1 || true)"
      fi

      if [[ -n "$cand" && -f "$cand" ]]; then
        mkdir -p "$build_dir"
        echo "bootloader: $cand -> $bootloader (tinyUF2)"
        cp -f "$cand" "$bootloader"
        found_boot=1
        break
      fi
    done

    if [[ "$found_boot" -eq 0 ]]; then
      echo "bootloader-tinyuf2.bin not found for variant '$variant'"
    fi
  fi

  # If tinyUF2 is in the partition table, add tinyuf2.bin at the correct offset.
  uf2_off=""
  gen_esp32part=""
  for pkg in "$PIO_HOME/packages/framework-arduinoespressif32" \
    "$PIO_HOME/packages/framework-arduinoespressif32@"*; do
    if [[ -f "$pkg/tools/gen_esp32part.py" ]]; then
      gen_esp32part="$pkg/tools/gen_esp32part.py"
      break
    fi
  done
  if [[ -n "$gen_esp32part" && -f "$partitions" ]] && command -v python3 >/dev/null 2>&1; then
    uf2_off="$(python3 "$gen_esp32part" "$partitions" 2>/dev/null | awk -F, 'BEGIN{IGNORECASE=1} $1 ~ /^uf2$/ {gsub(/[[:space:]]+/, "", $4); print $4; exit}')"
  fi
  tinyuf2_image=""
  tinyuf2_src=""
  if [[ -n "$variant" ]]; then
    for pkg in "$PIO_HOME/packages/framework-arduinoespressif32" \
      "$PIO_HOME/packages/framework-arduinoespressif32@"*; do
      cand="$pkg/variants/$variant/tinyuf2.bin"
      if [[ -f "$cand" ]]; then
        tinyuf2_src="$cand"
        break
      fi
    done
  fi
  if [[ -n "$tinyuf2_src" ]]; then
    mkdir -p "$build_dir"
    tinyuf2_image="$build_dir/tinyuf2.bin"
    echo "tinyuf2: $tinyuf2_src -> $tinyuf2_image"
    cp -f "$tinyuf2_src" "$tinyuf2_image"
  elif [[ -f "$build_dir/tinyuf2.bin" ]]; then
    tinyuf2_image="$build_dir/tinyuf2.bin"
  fi
  uf2_args=()
  if [[ -n "$uf2_off" && -n "$tinyuf2_image" ]]; then
    echo "UF2: $tinyuf2_image -> $uf2_off"
    uf2_args+=("$uf2_off" "$tinyuf2_image")
  elif [[ -n "$uf2_off" || -n "$tinyuf2_image" ]]; then
    echo "WARN: UF2 partition/image mismatch; skipping UF2 merge"
  fi

  for f in "$bootloader" "$partitions" "$bootapp0" "$firmware"; do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: missing $f (did the build succeed for env $env?)"
      if [[ "$f" == "$bootloader" ]]; then
        echo "NOTE: tinyUF2 envs use bootloader-tinyuf2.bin; ensure it exists in your PlatformIO packages."
      fi
      exit 2
    fi
  done

  # Determine chip family from bootloader image to pick correct bootloader offset:
  # - ESP32 classic often uses 0x1000
  # - ESP32-S3/C3/C6/H2/C2 typically use 0x0
  chip="$( ("${esptool_cmd[@]}" image_info "$bootloader" 2>/dev/null) \
    | sed -n -E 's/^Detected (chip type|image type):[[:space:]]*//p; s/^Chip is[[:space:]]*//p' \
    | head -n1 | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' || true )"
  if [[ -z "$chip" ]]; then
    echo "ERROR: failed to detect chip type from: $bootloader"
    echo "Ensure bootloader.bin exists and esptool can parse it."
    exit 2
  fi
  chip_norm="$(printf '%s' "$chip" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  chip_disp="$chip"
  esptool_chip="esp32"
  case "$chip_norm" in \
    esp32) esptool_chip="esp32" ;; \
    esp32s2) esptool_chip="esp32s2" ;; \
    esp32s3) esptool_chip="esp32s3" ;; \
    esp32c2) esptool_chip="esp32c2" ;; \
    esp32c3) esptool_chip="esp32c3" ;; \
    esp32c6) esptool_chip="esp32c6" ;; \
    esp32h2) esptool_chip="esp32h2" ;; \
  esac
  boot_off="0x1000"
  if [[ "$chip_norm" =~ ^(esp32s3|esp32c2|esp32c3|esp32c6|esp32h2)$ ]]; then
    boot_off="0x0"
  fi
  flash_size_arg="$FLASH_SIZE"
  if [[ "$chip_norm" == "esp32s3" ]]; then
    flash_size_arg="keep"
  fi

  # Reuse the same target-name logic as move-bins
  target_name="$env"
  if compgen -G "build_output/release/*.bin" > /dev/null; then
    fw_size="$(stat -c%s "$firmware")"
    for rel in build_output/release/*.bin; do
      [[ -f "$rel" ]] || continue
      if [[ "$(stat -c%s "$rel")" == "$fw_size" ]]; then
        bin_name="$(basename "$rel")"
        tmp="${bin_name%.bin}"
        tmp="${tmp#*_*_}"
        tmp="${tmp%% WLED*}"
        tmp="$(printf '%s' "$tmp" | sed -E 's/[[:space:]]+$//')"
        if [[ -n "$tmp" ]]; then
          target_name="$tmp"
          break
        fi
      fi
    done
  fi

  target_name="$(sanitize_name "$target_name")"
  if [[ -z "$target_name" ]]; then
    target_name="$env"
  fi

  target_slug="${target_name// /_}"
  factory_tmp="$WLED_DIR/build_output/factory/WLEDMM_${normal_git_ref}_${target_slug}.bin"
  factory_dest="$REPO_ROOT/$OUT_DIR/WLEDMM_${normal_git_ref}_${target_slug}.bin"

  echo "Factory merge: $env (chip='$chip_disp', boot_off=$boot_off) -> $factory_dest"
  mkdir -p "$WLED_DIR/build_output/factory"
  "${esptool_cmd[@]}" --chip "$esptool_chip" merge_bin \
    -o "$factory_tmp" \
    --flash_mode "$FLASH_MODE" --flash_size "$flash_size_arg" \
    "$boot_off" "$bootloader" \
    0x8000 "$partitions" \
    0xE000 "$bootapp0" \
    0x10000 "$firmware" \
    "${uf2_args[@]}"
  cp -f "$factory_tmp" "$factory_dest"
done
