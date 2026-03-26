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
# Relative path under repo root.
WLEDMM_DIR   ?= WLED-MM
CLONE_DEPTH  ?= 1
GIT_REF      ?=
GH_PAT       ?=
OUT_DIR      ?= build

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

# Export needed values for downstream shells
export IOT_SSID WPA_KEY GITHUB_WORKSPACE FLASH_MODE FLASH_SIZE GIT_REF OUT_DIR WLEDMM_DIR PIO_NO_ANSI PIO_DISABLE_PROGRESSBAR

# Wrapper that runs PlatformIO inside your builder container with host-mounted ~/.platformio
WITH_BUILDER ?= cd "$(REPO_ROOT)" && WLEDMM_DIR="$(WLEDMM_DIR)" "$(REPO_ROOT)/scripts/with_builder.sh"
PIO      ?= $(WITH_BUILDER) env $(PIO_ENV) pio
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


# Compute PIO_ENVS from platform_override.ini
ifeq ($(strip $(PIO_ENVS)),)
  PIO_ENVS := $(strip $(shell $(call _parse_default_envs)))
endif


clone: ## Shallow clone WLED-MM at a particular Git ref (tag/branch/SHA). Usage: make clone GIT_REF=v14.7.1 [GH_PAT=token]
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

	# Prepare authenticated URL if PAT provided
	remote_url="$(WLEDMM_URL)"
	if [[ -n "$(GH_PAT)" && "$$remote_url" =~ ^https:// ]]; then
		remote_url="$${remote_url#https://}"
		remote_url="https://$(GH_PAT):x-oauth-basic@$${remote_url}"
	fi

	git remote add origin "$$remote_url"

	# Reuse the same logic for tags/branches/SHA
	cd ..
	$(MAKE) checkout GIT_REF="$(GIT_REF)" GH_PAT="$(GH_PAT)"


checkout: ## Checkout a tag/branch/commit of existing WLEDMM. Usage: make checkout GIT_REF=v14.7.1 [GH_PAT=token]
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

	# Use GitHub PAT for HTTPS URLs if provided
	git_url="$(WLEDMM_URL)"
	if [[ -n "$(GH_PAT)" && "$$git_url" =~ ^https:// ]]; then
		git_url="$${git_url#https://}"
		git_url="https://$(GH_PAT):x-oauth-basic@$${git_url}"
	fi

	# Ensure repo exists
	if [[ ! -d "$(WLEDMM_DIR)/.git" ]]; then
		echo "WLED-MM not found; cloning shallow..."
		$(MAKE) clone GIT_REF="$(GIT_REF)" GH_PAT="$(GH_PAT)"
		exit 0
	fi

	cd "$(WLEDMM_DIR)"

	# Update remote URL if PAT provided (for authentication to GitHub API)
	if [[ -n "$$git_url" ]]; then
		git remote set-url origin "$$git_url"
	fi

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


build-prep:
	@install -m 0644 "$(PLATFORM_OVERRIDE_INI)" "$(REPO_ROOT)/$(WLEDMM_DIR)/platformio_override.ini"
	$(WITH_BUILDER) npm ci --prefer-offline --no-audit --no-fund
	selected_envs="$${ENV_LIST:-$(PIO_ENVS)}"
	env_args=(); for e in $$selected_envs; do [[ -n "$$e" ]] && env_args+=(-e "$$e"); done
	if [[ -n "$$selected_envs" ]]; then
		echo "Preparing PlatformIO envs: $$selected_envs"
	else
		echo "Preparing PlatformIO default_envs from WLED-MM/platformio.ini"
	fi
	$(PIO) pkg install "$${env_args[@]}"


build: ## Compile the project source files (envs from platform_override.ini [platformio].default_envs)
	@$(call require_envs)
	for env in $(PIO_ENVS); do
		echo "Building env: $$env"
		$(PIO) run -e "$$env"
		$(MAKE) move-bins PIO_ENVS="$$env"
		$(WITH_BUILDER) bash -lc "../scripts/pio_stage_boot_artifacts.sh \"$$env\""
		$(WITH_BUILDER) bash -lc "../scripts/make_factory.sh \"$$env\""
	done


package: ## Package OTA + factory bins for existing build outputs
	@$(call require_envs)
	$(MAKE) move-bins
	$(MAKE) make-factory


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


# Produces WLEDMM_x.y.z_CamelcasedTarget.bin by merging bootloader+partitions+boot_app0+firmware into one image.
make-factory: ## Create factory (merged, flash-at-0x0) bins for each env in PIO_ENVS
	@$(call require_envs)
	$(WITH_BUILDER) bash -lc "../scripts/make_factory.sh $(PIO_ENVS)"


clean: ## Sync source with HEAD and remove generated files/directories
	@rm -rf "$(OUT_DIR)"
	rm -rf .platformio
	rm -rf .npm
	if [[ -d "$(WLEDMM_DIR)" ]]; then
		cd "$(WLEDMM_DIR)"
		git reset --hard HEAD
		git clean -fdx
		rm -rf .pio
	fi


ship-local:
	@tag=$$(curl -fsSL "https://api.github.com/repos/MoonModules/WLED-MM/releases?per_page=50" | jq -r ' \
		map(select(.draft == false and .prerelease == false)) | max_by(.published_at) | .tag_name')
	$(MAKE) clean
	$(MAKE) checkout GIT_REF="$$tag"
	$(MAKE) build-prep
	$(MAKE) build
	cp -r "$(OUT_DIR)"/* "/mnt/d/Apps/ESP32 Flash Tool/bin/"
