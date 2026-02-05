.PHONY: \
	help \
	clone \
	checkout \
	build \
	package \
	move-bins \
	copy-bootapp0 \
	make-factory \
	clean \
	copy-builds-to-wsl

help: ## Display this help message
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z._-]+:.*?##/ {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

SHELL := $(shell command -v bash)
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
# Keep recursive make calls quiet ("Entering directory" noise).
MAKEFLAGS += --no-print-directory

WLEDMM_URL   ?= https://github.com/MoonModules/WLED-MM.git
WLEDMM_DIR   ?= WLED-MM
CLONE_DEPTH  ?= 1
GIT_REF      ?=
OUT_DIR      ?= build
export IOT_SSID WPA_KEY FORGEJO_WORKSPACE

### Env selection
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PLATFORM_OVERRIDE_INI ?= $(REPO_ROOT)/platformio_override.ini

# Optional manual override:
#   make build PIO_ENVS="env1 env2"
PIO_ENVS ?=

# Reduce noisy output (progress bars/ANSI) from PlatformIO in logs.
PIO_NO_ANSI ?= true
PIO_DISABLE_PROGRESSBAR ?= true
PIO_ENV ?= PLATFORMIO_NO_ANSI=$(PIO_NO_ANSI) PLATFORMIO_DISABLE_PROGRESSBAR=$(PIO_DISABLE_PROGRESSBAR)

# Wrapper that runs PlatformIO inside your builder container with host-mounted ~/.platformio
PIO      ?= $(REPO_ROOT)/with_builder.sh env $(PIO_ENV) pio
ESPTOOL  := $(PIO) pkg exec -p tool-esptoolpy -- esptool.py

FLASH_MODE   ?= dio
FLASH_SIZE   ?= 4MB

# Parse platform_override.ini [platformio] default_envs into a space-separated list.
# Handles:
#   default_envs = a, b, c
#   default_envs =
#     a
#     b
#     c
# Ignores comments and blank lines.
define _parse_default_envs
awk '\
  BEGIN{in_pio=0; grab=0} \
  /^[[:space:]]*\[platformio\][[:space:]]*$$/{in_pio=1; next} \
  /^[[:space:]]*\[/{in_pio=0; grab=0} \
  in_pio && $$0 ~ /^[[:space:]]*default_envs[[:space:]]*=/ { \
    grab=1; \
    line=$$0; \
    sub(/^[[:space:]]*default_envs[[:space:]]*=[[:space:]]*/, "", line); \
    sub(/[;#].*$$/, "", line); \
    gsub(/,/, " ", line); \
    gsub(/[[:space:]]+/, " ", line); \
    gsub(/^[[:space:]]+|[[:space:]]+$$/, "", line); \
    if (length(line)>0) printf "%s ", line; \
    next \
  } \
  grab { \
    if ($$0 ~ /^[[:space:]]*$$/) next; \
    if ($$0 ~ /^[[:space:]]*[;#]/) next; \
    if ($$0 ~ /^[[:space:]]*\[/) { grab=0; next } \
    line=$$0; \
    sub(/[;#].*$$/, "", line); \
    gsub(/,/, " ", line); \
    gsub(/[[:space:]]+/, " ", line); \
    gsub(/^[[:space:]]+|[[:space:]]+$$/, "", line); \
    if (length(line)>0) printf "%s ", line; \
  }' "$(PLATFORM_OVERRIDE_INI)"
endef

define require_override_ini
if [[ ! -f "$(PLATFORM_OVERRIDE_INI)" ]]; then \
  echo "ERROR: Missing $(PLATFORM_OVERRIDE_INI)"; \
  echo "Expected platformio_override.ini in the repo root (same dir as Makefile)."; \
  exit 2; \
fi
endef

define require_envs
$(call require_override_ini)
if [[ -z "$(PIO_ENVS)" ]]; then \
  echo "ERROR: No PlatformIO envs found to build."; \
  echo "Expected [platformio] default_envs in $(PLATFORM_OVERRIDE_INI), or pass PIO_ENVS='env1 env2'."; \
  exit 2; \
fi
endef

# If user didn't provide PIO_ENVS, compute it from platform_override.ini
ifeq ($(strip $(PIO_ENVS)),)
  PIO_ENVS := $(strip $(shell $(call _parse_default_envs)))
endif


clone: ## Shallow clone WLED-MM at a particular Git ref (tag/branch/SHA). Usage: make clone GIT_REF=v14.7.1
	@if [[ -z "$(GIT_REF)" ]]; then
		echo "ERROR: missing GIT_REF. Example: make clone GIT_REF=v14.7.1"
		exit 2
	fi

	if [[ -d "$(WLEDMM_DIR)/.git" ]]; then
		echo "WLED-MM already present at $(WLEDMM_DIR)"
		exit 0
	fi

	mkdir -p "$(WLEDMM_DIR)"
	cd "$(WLEDMM_DIR)"
	git init -q
	git remote add origin "$(WLEDMM_URL)"

	# Reuse the same logic for tags/branches/SHA
	cd ..
	$(MAKE) checkout GIT_REF="$(GIT_REF)"


checkout: ## Checkout a tag/branch/commit of existing WLEDMM. Usage: make checkout GIT_REF=v14.7.1
	@if [[ -z "$(GIT_REF)" ]]; then
		echo "ERROR: missing GIT_REF (tag, branch, or SHA). Example: make checkout GIT_REF=v14.7.1"
		exit 2
	fi

	# Non-interactive + fail-fast (prevents "hang" on auth/hostkey prompts)
	export GIT_TERMINAL_PROMPT=0
	export GIT_ASKPASS=/bin/false

	# If origin is SSH, this prevents "are you sure you want to continue connecting" hangs
	if [[ "$(WLEDMM_URL)" =~ ^git@|^ssh:// ]]; then
		export GIT_SSH_COMMAND='ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new'
	fi

	# Ensure repo exists
	if [[ ! -d "$(WLEDMM_DIR)/.git" ]]; then
		echo "WLED-MM not found; cloning shallow..."
		$(MAKE) clone GIT_REF="$(GIT_REF)"
		exit 0
	fi

	cd "$(WLEDMM_DIR)"
	ref="$(GIT_REF)"

	# Normalize tag candidates: allow vX.Y.Z or X.Y.Z
	tag="$$ref"
	if [[ "$$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then
		tag_no_v="$${ref#v}"
	else
		tag_no_v="v$$ref"
	fi

	echo "Resolving '$$ref' (preferring branch, then tag)..."

	# One network probe: only ask for the exact refs we care about
	# (much less likely to stall / rate-limit than multiple ls-remote calls)
	ls_out="$$(timeout 30 git ls-remote --exit-code origin \
		"refs/heads/$$ref" \
		"refs/tags/$$tag" \
		"refs/tags/$$tag_no_v" \
		2>/dev/null || true)"

	if echo "$$ls_out" | grep -qE "[[:space:]]refs/heads/$$ref$$"; then
		echo "-> branch: $$ref"
		timeout 120 git fetch -q --depth="$(CLONE_DEPTH)" origin \
			"refs/heads/$$ref:refs/remotes/origin/$$ref"
		git checkout -q -B "$$ref" "refs/remotes/origin/$$ref"

	elif echo "$$ls_out" | grep -qE "[[:space:]]refs/tags/$$tag$$"; then
		echo "-> tag: $$tag"
		# Force tag updates to avoid failures from conflicting local tags (e.g., nightly)
		timeout 120 git fetch -q --depth="$(CLONE_DEPTH)" --force --tags origin \
			"refs/tags/$$tag:refs/tags/$$tag"
		git checkout -q "refs/tags/$$tag"

	elif echo "$$ls_out" | grep -qE "[[:space:]]refs/tags/$$tag_no_v$$"; then
		echo "-> tag: $$tag_no_v"
		# Force tag updates to avoid failures from conflicting local tags (e.g., nightly)
		timeout 120 git fetch -q --depth="$(CLONE_DEPTH)" --force --tags origin \
			"refs/tags/$$tag_no_v:refs/tags/$$tag_no_v"
		git checkout -q "refs/tags/$$tag_no_v"

	else
		echo "-> commit-ish / unknown ref; attempting shallow fetch and detach"
		# Try fetching the ref directly (works for SHAs, or refs not listed above)
		# If this fails (e.g., server rejects shallow by SHA), fall back to deepening.
		if timeout 120 git fetch -q --depth="$(CLONE_DEPTH)" origin "$$ref"; then
			git checkout -q --detach FETCH_HEAD
		else
			echo "WARN: couldn't shallow-fetch '$$ref'; deepening and retrying..."
			timeout 300 git fetch -q --unshallow origin || timeout 300 git fetch -q origin
			git checkout -q --detach "$$ref"
		fi
	fi

	echo "Now at: $$(git rev-parse --short=12 HEAD)"


build: ## Compile the project source files (envs from platform_override.ini [platformio].default_envs)
	@$(call require_envs)
	$(MAKE) checkout GIT_REF="$(GIT_REF)"
	ln -sf "$(PLATFORM_OVERRIDE_INI)" "$(REPO_ROOT)/$(WLEDMM_DIR)/platformio_override.ini"

	for env in $(PIO_ENVS); do
		echo "Building env: $$env"
		$(PIO) run -e "$$env"
		$(MAKE) move-bins PIO_ENVS="$$env"
		$(MAKE) copy-bootapp0 PIO_ENVS="$$env"
		$(REPO_ROOT)/with_builder.sh sh -lc make make-factory PIO_ENVS="$$env"
	done


package: ## Package OTA + factory bins for existing build outputs
	@$(call require_envs)
	$(MAKE) move-bins
	$(REPO_ROOT)/with_builder.sh sh -lc make make-factory

# Produces WLEDMM_x.y.z_CamelcasedTarget_OTA.bin from .pio/build/<env>/firmware.bin
move-bins: ## Create OTA bins (renamed firmware.bin) for each env in PIO_ENVS
	@$(call require_envs)
	mkdir -p "$(OUT_DIR)"

	# Normalize git ref for filenames (strip leading v)
	normal_git_ref="$(GIT_REF)"
	if [[ "$$normal_git_ref" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$$ ]]; then
		normal_git_ref="$${BASH_REMATCH[1]}"
	fi
	sanitize_name() {
		local s="$$1"
		printf '%s' "$$s" | sed -E 's/["'"'"'\\]//g'
	}

	# Helper: CamelCase from messy target string
	cd "$(WLEDMM_DIR)"
	for env in $(PIO_ENVS); do
		build_dir="build_output/firmware"
		fw_src="$$build_dir/$$env.bin"

		if [[ ! -f "$$fw_src" ]]; then
			echo "ERROR: missing $$fw_src (did the build succeed for env $$env?)"
			exit 2
		fi

		# Prefer the release filename if present, else fall back to env name.
		release_glob="build_output/release/"*
		target_name="$$env"
		if compgen -G "$$release_glob" > /dev/null; then
			# Try to pick a release bin that matches this env by size match against firmware.bin
			fw_size="$$(stat -c%s "$$fw_src")"
			for rel in build_output/release/*.bin; do
				[[ -f "$$rel" ]] || continue
				if [[ "$$(stat -c%s "$$rel")" == "$$fw_size" ]]; then
					bin_name="$$(basename "$$rel")"
					tmp="$${bin_name%.bin}"
					# remove leading WLEDMM_<ver>_ if present
					tmp="$${tmp#*_*_}"
					# take everything before " WLED"
					tmp="$${tmp%% WLED*}"
					# trim
					tmp="$$(printf '%s' "$$tmp" | sed -E 's/[[:space:]]+$$//')"
					if [[ -n "$$tmp" ]]; then
						target_name="$$tmp"
						break
					fi
				fi
			done
		fi

		target_name="$$(sanitize_name "$$target_name")"
		if [[ -z "$$target_name" ]]; then
			target_name="$$env"
		fi

		ota_dest="../$(OUT_DIR)/WLEDMM_$${normal_git_ref}_$${target_name// /_}_OTA.bin"

		echo "OTA: $$fw_src -> $$ota_dest"
		cp -f "$$fw_src" "$$ota_dest"
	done

copy-bootapp0: ## Copy boot_app0.bin from the framework into .pio/build/<env>
	@$(call require_envs)
	$(REPO_ROOT)/with_builder.sh sh -lc "$$(cat <<'SH'
	set -euo pipefail
	for env in $(PIO_ENVS); do
	build_dir=".pio/build/$${env}"
	dest="$${build_dir}/boot_app0.bin"

	if [ -f "$${dest}" ]; then
		echo "boot_app0: $${env} already present"
		continue
	fi

	cd "$(WLEDMM_DIR)"
	src=""
	echo "HOME: $$HOME"
	for pattern in \
		".pio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin" \
		".pio/packages/framework-arduinoespressif32@*/tools/partitions/boot_app0.bin" \
		"$$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin" \
		"$$HOME/.platformio/packages/framework-arduinoespressif32@*/tools/partitions/boot_app0.bin"
	do
		for f in $${pattern}; do
		if [ -f "$${f}" ]; then
			src="$${f}"
			break 2
		fi
		done
	done

	if [ -z "$${src}" ] || [ ! -f "$${src}" ]; then
		echo "ERROR: boot_app0.bin not found in framework-arduinoespressif32."
		exit 2
	fi

	mkdir -p "$${build_dir}"
	echo "boot_app0: $${src} -> $${dest}"
	cp -f "$${src}" "$${dest}"
	done
	SH
	)"


# Produces WLEDMM_x.y.z_CamelcasedTarget.bin by merging bootloader+partitions+boot_app0+firmware into one image.
make-factory: ## Create factory (merged, flash-at-0x0) bins for each env in PIO_ENVS
	@$(call require_envs)
	mkdir -p "$(OUT_DIR)"

	normal_git_ref="$(GIT_REF)"
	if [[ "$$normal_git_ref" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$$ ]]; then
		normal_git_ref="$${BASH_REMATCH[1]}"
	fi

	camelcase() {
		local s="$$1"
		s="$$(printf '%s' "$$s" | sed -E 's/[^[:alnum:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$$//; s/[[:space:]]+/ /g')"
		printf '%s' "$$s" | awk '{for(i=1;i<=NF;i++){printf toupper(substr($$i,1,1)) tolower(substr($$i,2))}}'
	}
	sanitize_name() {
		local s="$$1"
		printf '%s' "$$s" | sed -E 's/["'"'"'\\]//g; s/^MM[[:space:]]+//'
	}

	cd "$(WLEDMM_DIR)"
	for env in $(PIO_ENVS); do
		build_dir=".pio/build/$$env"
		bootloader="$$build_dir/bootloader.bin"
		partitions="$$build_dir/partitions.bin"
		bootapp0="$$build_dir/boot_app0.bin"
		firmware="$$build_dir/firmware.bin"

		# Try to infer the board variant name from build artifacts.
		variant="$$( \
			( command -v rg >/dev/null 2>&1 && rg -g '*.d' -m1 --no-filename -o 'variants/[^/]+/' "$$build_dir" 2>/dev/null || true; \
			  command -v rg >/dev/null 2>&1 || grep -R -h -m1 -o 'variants/[^/]\\+/' "$$build_dir" 2>/dev/null || true ) \
			| head -n1 | sed -E 's#.*variants/([^/]+)/#\1#' )"
		if [[ -z "$$variant" ]]; then
			case "$$env" in \
				adafruit_matrix_portal_s3) variant="adafruit_matrixportal_esp32s3" ;; \
			esac
		fi

		echo "Framework packages:"
		ls -d "$$HOME/.platformio/packages/framework-arduinoespressif32"* 2>/dev/null || true
		echo "Variant dirs (sample):"
		for pkg in "$$HOME/.platformio/packages/framework-arduinoespressif32" "$$HOME/.platformio/packages/framework-arduinoespressif32@"*; do
		[[ -d "$$pkg/variants" ]] || continue
		echo "== $$pkg/variants =="
		ls -1 "$$pkg/variants" | head -n 50
		done

		# Some Adafruit tinyUF2 envs don't emit bootloader.bin; recover from framework packages.
		if [[ ! -f "$$bootloader" ]]; then
			found_boot=0
			for pkg in "$$HOME/.platformio/packages/framework-arduinoespressif32" \
					"$$HOME/.platformio/packages/framework-arduinoespressif32@"*; do
				[[ -d "$$pkg" ]] || continue

				cand=""
				if [[ -n "$$variant" && -f "$$pkg/variants/$$variant/bootloader-tinyuf2.bin" ]]; then
					cand="$$pkg/variants/$$variant/bootloader-tinyuf2.bin"
				elif [[ -d "$$pkg/variants" ]]; then
					cand="$$(find "$$pkg/variants" -maxdepth 3 -type f -name 'bootloader-tinyuf2.bin' 2>/dev/null | head -n1 || true)"
				fi

				if [[ -n "$$cand" && -f "$$cand" ]]; then
					mkdir -p "$$build_dir"
					echo "bootloader: $$cand -> $$bootloader (tinyUF2)"
					cp -f "$$cand" "$$bootloader"
					found_boot=1
					break
				fi
			done

			if [[ "$$found_boot" -eq 0 ]]; then
				echo "bootloader-tinyuf2.bin not found for variant '$$variant'"
			fi
		fi

		# If tinyUF2 is in the partition table, add tinyuf2.bin at the correct offset.
		uf2_off=""
		gen_esp32part=""
		for pkg in "$$HOME/.platformio/packages/framework-arduinoespressif32" \
			"$$HOME/.platformio/packages/framework-arduinoespressif32@"*; do
			if [[ -f "$$pkg/tools/gen_esp32part.py" ]]; then
				gen_esp32part="$$pkg/tools/gen_esp32part.py"
				break
			fi
		done
		if [[ -n "$$gen_esp32part" && -f "$$partitions" ]] && command -v python3 >/dev/null 2>&1; then
			uf2_off="$$(python3 "$$gen_esp32part" "$$partitions" 2>/dev/null | awk -F, 'BEGIN{IGNORECASE=1} $$1 ~ /^uf2$$/ {gsub(/[[:space:]]+/, "", $$4); print $$4; exit}')"
		fi
		tinyuf2_image=""
		tinyuf2_src=""
		if [[ -n "$$variant" ]]; then
			for pkg in "$$HOME/.platformio/packages/framework-arduinoespressif32" \
				"$$HOME/.platformio/packages/framework-arduinoespressif32@"*; do
				cand="$$pkg/variants/$$variant/tinyuf2.bin"
				if [[ -f "$$cand" ]]; then
					tinyuf2_src="$$cand"
					break
				fi
			done
		fi
		if [[ -n "$$tinyuf2_src" ]]; then
			mkdir -p "$$build_dir"
			tinyuf2_image="$$build_dir/tinyuf2.bin"
			echo "tinyuf2: $$tinyuf2_src -> $$tinyuf2_image"
			cp -f "$$tinyuf2_src" "$$tinyuf2_image"
		elif [[ -f "$$build_dir/tinyuf2.bin" ]]; then
			tinyuf2_image="$$build_dir/tinyuf2.bin"
		fi
		uf2_args=()
		if [[ -n "$$uf2_off" && -n "$$tinyuf2_image" ]]; then
			echo "UF2: $$tinyuf2_image -> $$uf2_off"
			uf2_args+=("$$uf2_off" "$$tinyuf2_image")
		elif [[ -n "$$uf2_off" || -n "$$tinyuf2_image" ]]; then
			echo "WARN: UF2 partition/image mismatch; skipping UF2 merge"
		fi

		for f in "$$bootloader" "$$partitions" "$$bootapp0" "$$firmware"; do
			if [[ ! -f "$$f" ]]; then
				echo "ERROR: missing $$f (did the build succeed for env $$env?)"
				if [[ "$$f" == "$$bootloader" ]]; then
					echo "NOTE: tinyUF2 envs use bootloader-tinyuf2.bin; ensure it exists in your PlatformIO packages."
				fi
				exit 2
			fi
		done

		# Determine chip family from bootloader image to pick correct bootloader offset:
		# - ESP32 classic often uses 0x1000
		# - ESP32-S3/C3/C6/H2/C2 typically use 0x0
		chip="$$( (cd "$(REPO_ROOT)" && $(ESPTOOL) image_info "$$bootloader" 2>/dev/null) | sed -n -E 's/^Detected (chip type|image type):[[:space:]]*//p; s/^Chip is[[:space:]]*//p' | head -n1 | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$$//g' || true )"
		chip_norm="$$(printf '%s' "$$chip" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
		chip_disp="$${chip:-unknown}"
		esptool_chip="esp32"
		case "$$chip_norm" in \
			esp32) esptool_chip="esp32" ;; \
			esp32s2) esptool_chip="esp32s2" ;; \
			esp32s3) esptool_chip="esp32s3" ;; \
			esp32c2) esptool_chip="esp32c2" ;; \
			esp32c3) esptool_chip="esp32c3" ;; \
			esp32c6) esptool_chip="esp32c6" ;; \
			esp32h2) esptool_chip="esp32h2" ;; \
		esac
		boot_off="0x1000"
		if [[ "$$chip_norm" =~ ^(esp32s3|esp32c2|esp32c3|esp32c6|esp32h2)$$ ]]; then
			boot_off="0x0"
		fi
		flash_size_arg="$(FLASH_SIZE)"
		if [[ "$$chip_norm" == "esp32s3" ]]; then
			flash_size_arg="keep"
		fi

		# Reuse the same target-name logic as move-bins
		target_name="$$env"
		if compgen -G "build_output/release/*.bin" > /dev/null; then
			fw_size="$$(stat -c%s "$$firmware")"
			for rel in build_output/release/*.bin; do
				[[ -f "$$rel" ]] || continue
				if [[ "$$(stat -c%s "$$rel")" == "$$fw_size" ]]; then
					bin_name="$$(basename "$$rel")"
					tmp="$${bin_name%.bin}"
					tmp="$${tmp#*_*_}"
					tmp="$${tmp%% WLED*}"
					tmp="$$(printf '%s' "$$tmp" | sed -E 's/[[:space:]]+$$//')"
					if [[ -n "$$tmp" ]]; then
						target_name="$$tmp"
						break
					fi
				fi
			done
		fi

		target_name="$$(sanitize_name "$$target_name")"
		if [[ -z "$$target_name" ]]; then
			target_name="$$env"
		fi

		target_slug="$${target_name// /_}"
		factory_tmp="build_output/factory/WLEDMM_$${normal_git_ref}_$${target_slug}.bin"
		factory_dest="$(REPO_ROOT)/$(OUT_DIR)/WLEDMM_$${normal_git_ref}_$${target_slug}.bin"

		echo "Factory merge: $$env (chip='$$chip_disp', boot_off=$$boot_off) -> $$factory_dest"
		mkdir -p "build_output/factory"
		(cd "$(REPO_ROOT)" && $(ESPTOOL) --chip "$$esptool_chip" merge_bin \
			-o "$$factory_tmp" \
			--flash_mode "$(FLASH_MODE)" --flash_size "$$flash_size_arg" \
			"$$boot_off" "$$bootloader" \
			0x8000 "$$partitions" \
			0xE000 "$$bootapp0" \
			0x10000 "$$firmware" \
			"$${uf2_args[@]}")
		cp -f "$$factory_tmp" "$$factory_dest"
	done

clean: ## Sync source with HEAD and remove generated files/directories
	@rm -rf "$(OUT_DIR)"
	if [[ -d "$(WLEDMM_DIR)" ]]; then
		cd "$(WLEDMM_DIR)"
		git reset --hard HEAD
		git clean -fdx
		rm -rf .pio
	fi

build-from-wsl: # Personal use ;D
	@tag=$$(curl -fsSL "https://api.github.com/repos/MoonModules/WLED-MM/releases?per_page=50" | jq -r ' \
		map(select(.draft == false and .prerelease == false)) | max_by(.published_at) | .tag_name')
	$(MAKE) build GIT_REF="$$tag" PIO_ENVS="$(PIO_ENVS)"
	cp -r "$(OUT_DIR)"/* "/mnt/d/Apps/ESP32 Flash Tool/bin/"
