SHELL := /bin/bash

IMAGE                 := ruuvi-fw-build:1

ROOT                  := $(CURDIR)
FIRMWARE              := $(ROOT)/firmware

SDK_VERSION           := 15.3.0_59ac345
SDK_DIRNAME           := nRF5_SDK_$(SDK_VERSION)
SDK                   := $(ROOT)/$(SDK_DIRNAME)
SDK_URL               ?= https://developer.nordicsemi.com/nRF5_SDK/nRF5_SDK_v15.x.x/$(SDK_DIRNAME).zip
SDK_TOOLCHAIN_FILE    := $(SDK)/components/toolchain/gcc/Makefile.posix

FIRMWARE_REL          = $(patsubst $(ROOT)/%,%,$(FIRMWARE))
CONTAINER_FIRMWARE    = /repo/$(FIRMWARE_REL)
TARGET                = $(CONTAINER_FIRMWARE)/src/targets/ruuvitag_b/armgcc
BUILD_DIR             := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc/_build
PACKAGE_DIR           := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc

PACKAGE_NAME          ?= ruuvifw_cart

BUILDS_DIR            := $(ROOT)/builds

OFFICIAL_VERSION      := v3.31.1
OFFICIAL_REPO         := https://github.com/ruuvi/ruuvi.firmware.c.git
OFFICIAL_VERSION_NUM  := $(patsubst v%,%,$(OFFICIAL_VERSION))
OFFICIAL_DIR          := $(ROOT)/official-$(OFFICIAL_VERSION_NUM)
OFFICIAL_HEX_NAME     := ruuvitag_b_armgcc_ruuvifw_default_$(OFFICIAL_VERSION)_app.hex
OFFICIAL_HEX          := $(OFFICIAL_DIR)/$(OFFICIAL_HEX_NAME)
OFFICIAL_BIN          := $(OFFICIAL_DIR)/official.bin
OFFICIAL_URL          := https://github.com/ruuvi/ruuvi.firmware.c/releases/download/$(OFFICIAL_VERSION)/$(OFFICIAL_HEX_NAME)
OFFICIAL_SHA256       := 0d965eff27639e7d2ff18c620194ce059b92887e77852900dc08fa29938060ac

STOCK_WORKTREE        := $(ROOT)/.stock-firmware

HOST_ARCH             := $(shell uname -m)

# At an exact tag this becomes, for example, v3.31.1.
# After custom commits it falls back to the Git short SHA.
FW_VERSION := $(shell cd "$(FIRMWARE)" 2>/dev/null && \
	(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null))

# Human-readable source name used for surfaced build artifacts.
# Prefer a branch name, then an exact tag, then a short commit SHA.
FW_SOURCE_NAME := $(shell cd "$(FIRMWARE)" 2>/dev/null && \
	(git symbolic-ref --short -q HEAD 2>/dev/null || \
	 git describe --tags --exact-match 2>/dev/null || \
	 git rev-parse --short HEAD 2>/dev/null))

BUILD_OUTPUT_DIR := $(BUILDS_DIR)/$(FW_SOURCE_NAME)

.PHONY: help check-host update sdk official image tools \
	firmware-use firmware-reset firmware-status firmware-list \
	clean build verify package surface stock all


help:
	@echo "Targets:"
	@echo "  make update                 Pull repository and reset/synchronize submodules"
	@echo "  make sdk                    Download/configure Nordic nRF5 SDK $(SDK_VERSION)"
	@echo "  make official               Download/verify official Ruuvi $(OFFICIAL_VERSION) reference"
	@echo "  make image                  Build the Docker toolchain image"
	@echo "  make tools                  Display toolchain versions"
	@echo
	@echo "Firmware selection:"
	@echo "  make firmware-use REF=<ref> Select a firmware branch, tag, or commit"
	@echo "  make firmware-reset         Restore firmware to the outer repository's pinned commit"
	@echo "  make firmware-status        Show selected firmware and outer repository pin"
	@echo "  make firmware-list          List local and remote firmware branches"
	@echo
	@echo "Build:"
	@echo "  make clean                  Remove firmware build output"
	@echo "  make build                  Build the currently selected firmware"
	@echo "  make verify                 Compare current build with official $(OFFICIAL_VERSION)"
	@echo "  make package                Build DFU packages and surface artifacts under builds/"
	@echo "  make surface                Re-surface existing build/package artifacts"
	@echo "  make stock                  Build pristine $(OFFICIAL_VERSION) and verify it"
	@echo "  make all                    Clean, build and package current firmware"
	@echo
	@echo "Build host architecture: $(HOST_ARCH)"
	@echo "Current firmware source: $(FW_SOURCE_NAME)"
	@echo "Current firmware version: $(FW_VERSION)"
	@echo "SDK directory: $(SDK)"


# This project intentionally builds on a native amd64 Linux host (tycho).
# Avoid Docker Desktop/Rosetta and macOS bind-mount filesystem issues.
check-host:
	@if [ "$(HOST_ARCH)" != "x86_64" ]; then \
		echo "ERROR: Firmware builds are intended for a native x86_64 Linux host."; \
		echo "Current host architecture: $(HOST_ARCH)"; \
		exit 1; \
	fi


update: check-host
	@echo "Updating ruuvi-cart..."
	git pull --ff-only
	@echo
	@echo "Synchronizing submodule URLs..."
	git submodule sync --recursive
	@echo
	@echo "Updating submodules to revisions recorded by the repository..."
	git submodule update --init --recursive --checkout --force
	@echo
	@$(MAKE) --no-print-directory sdk
	@echo
	@echo "Update complete."


# Select an arbitrary firmware branch, tag, or commit in-place.
# The firmware checkout is intentionally treated as disposable build state:
# all local/untracked changes in it and its nested submodules are discarded.
firmware-use:
	@test -n "$(REF)" || { \
		echo "ERROR: REF is required."; \
		echo "Usage: make firmware-use REF=<branch|tag|commit>"; \
		exit 1; \
	}
	@test -d "$(FIRMWARE)/.git" -o -f "$(FIRMWARE)/.git" || { \
		echo "ERROR: Firmware submodule is not initialized: $(FIRMWARE)"; \
		echo "Run 'git submodule update --init --recursive firmware' first."; \
		exit 1; \
	}
	@echo "Cleaning current firmware checkout..."
	@git -C "$(FIRMWARE)" submodule foreach --recursive 'git reset --hard >/dev/null && git clean -fdx >/dev/null' || true
	@git -C "$(FIRMWARE)" reset --hard
	@git -C "$(FIRMWARE)" clean -fdx
	@echo
	@echo "Fetching firmware refs..."
	@git -C "$(FIRMWARE)" fetch --all --tags --prune
	@echo
	@echo "Selecting firmware ref: $(REF)"
	@set -euo pipefail; \
	if git -C "$(FIRMWARE)" show-ref --verify --quiet "refs/heads/$(REF)"; then \
		git -C "$(FIRMWARE)" switch --force "$(REF)"; \
	elif git -C "$(FIRMWARE)" show-ref --verify --quiet "refs/remotes/origin/$(REF)"; then \
		git -C "$(FIRMWARE)" switch --force --track -c "$(REF)" "origin/$(REF)"; \
	elif git -C "$(FIRMWARE)" show-ref --verify --quiet "refs/remotes/upstream/$(REF)"; then \
		git -C "$(FIRMWARE)" switch --force --track -c "$(REF)" "upstream/$(REF)"; \
	else \
		git -C "$(FIRMWARE)" checkout --force --detach "$(REF)"; \
	fi
	@echo
	@echo "Synchronizing nested firmware submodules..."
	@git -C "$(FIRMWARE)" submodule sync --recursive
	@git -C "$(FIRMWARE)" submodule update --init --recursive --checkout --force
	@git -C "$(FIRMWARE)" submodule foreach --recursive 'git reset --hard >/dev/null && git clean -fdx >/dev/null'
	@echo
	@$(MAKE) --no-print-directory firmware-status


# Restore firmware/ to the exact commit pinned by the outer ruuvi-cart repository.
firmware-reset:
	@echo "Cleaning firmware checkout..."
	@git -C "$(FIRMWARE)" submodule foreach --recursive 'git reset --hard >/dev/null && git clean -fdx >/dev/null' || true
	@git -C "$(FIRMWARE)" reset --hard
	@git -C "$(FIRMWARE)" clean -fdx
	@echo
	@echo "Restoring firmware to outer repository pin..."
	@git submodule sync --recursive
	@git submodule update --init --recursive --checkout --force firmware
	@git -C "$(FIRMWARE)" submodule foreach --recursive 'git reset --hard >/dev/null && git clean -fdx >/dev/null'
	@echo
	@$(MAKE) --no-print-directory firmware-status


firmware-status:
	@set -euo pipefail; \
	pinned=$$(git ls-tree HEAD firmware | awk '{print $$3}'); \
	current=$$(git -C "$(FIRMWARE)" rev-parse HEAD); \
	branch=$$(git -C "$(FIRMWARE)" symbolic-ref --short -q HEAD || true); \
	describe=$$(git -C "$(FIRMWARE)" describe --tags --exact-match 2>/dev/null || true); \
	echo "Firmware checkout:"; \
	echo "  path:    $(FIRMWARE)"; \
	if [ -n "$$branch" ]; then \
		echo "  branch:  $$branch"; \
	elif [ -n "$$describe" ]; then \
		echo "  ref:     $$describe (detached)"; \
	else \
		echo "  ref:     $${current:0:7} (detached)"; \
	fi; \
	echo "  commit:  $$current"; \
	echo "  version: $(FW_VERSION)"; \
	echo; \
	echo "Outer repository pin:"; \
	echo "  commit:  $$pinned"; \
	if [ "$$current" = "$$pinned" ]; then \
		echo "  status:  MATCH"; \
	else \
		echo "  status:  DIFFERENT (expected while testing another firmware ref)"; \
	fi


firmware-list:
	@echo "Local branches:"
	@git -C "$(FIRMWARE)" branch
	@echo
	@echo "Remote branches:"
	@git -C "$(FIRMWARE)" branch -r


# Download the exact Nordic SDK required by Ruuvi firmware v3.31.1 and
# configure its GCC toolchain path for the compiler installed in our image.
# An incomplete SDK directory is removed and downloaded again.
sdk: check-host
	@if [ ! -f "$(SDK_TOOLCHAIN_FILE)" ]; then \
		command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required."; exit 1; }; \
		command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip is required."; exit 1; }; \
		if [ -e "$(SDK)" ]; then \
			echo "Removing incomplete SDK: $(SDK)"; \
			rm -rf "$(SDK)"; \
		fi; \
		echo "Downloading Nordic nRF5 SDK $(SDK_VERSION)..."; \
		tmp=$$(mktemp /tmp/nRF5SDK.XXXXXX.zip); \
		trap 'rm -f "$$tmp"' EXIT; \
		curl -fL --retry 3 --retry-delay 2 "$(SDK_URL)" -o "$$tmp"; \
		unzip -q "$$tmp" -d "$(ROOT)"; \
	fi
	@test -f "$(SDK_TOOLCHAIN_FILE)" || { \
		echo "ERROR: SDK toolchain file not found after SDK setup:"; \
		echo "  $(SDK_TOOLCHAIN_FILE)"; \
		exit 1; \
	}
	@sed -i \
		-e 's|^GNU_INSTALL_ROOT.*|GNU_INSTALL_ROOT ?= /opt/gcc-arm-none-eabi-7-2018-q2-update/bin/|' \
		-e 's|^GNU_VERSION.*|GNU_VERSION ?= 7.3.1|' \
		-e 's|^GNU_PREFIX.*|GNU_PREFIX ?= arm-none-eabi|' \
		"$(SDK_TOOLCHAIN_FILE)"
	@echo "SDK ready: $(SDK)"


# Download Ruuvi's official v3.31.1 application HEX, convert it to a raw
# binary with the same toolchain image, and verify the known SHA-256.
official: check-host
	@command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required."; exit 1; }
	@command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required."; exit 1; }
	@if [ ! -f "$(OFFICIAL_BIN)" ] || \
	    ! echo "$(OFFICIAL_SHA256)  $(OFFICIAL_BIN)" | sha256sum -c --status; then \
		echo "Downloading official Ruuvi firmware $(OFFICIAL_VERSION)..."; \
		rm -rf "$(OFFICIAL_DIR)"; \
		mkdir -p "$(OFFICIAL_DIR)"; \
		curl -fL --retry 3 --retry-delay 2 "$(OFFICIAL_URL)" -o "$(OFFICIAL_HEX)"; \
		docker run --rm \
			-v "$(OFFICIAL_DIR):/official" \
			$(IMAGE) \
			arm-none-eabi-objcopy \
				-I ihex \
				-O binary \
				"/official/$(OFFICIAL_HEX_NAME)" \
				/official/official.bin; \
	fi
	@echo "$(OFFICIAL_SHA256)  $(OFFICIAL_BIN)" | sha256sum -c -
	@echo "Official reference ready: $(OFFICIAL_BIN)"


image: check-host
	docker build \
		-t $(IMAGE) \
		-f docker/Dockerfile \
		docker


tools: check-host
	docker run --rm \
		$(IMAGE) \
		sh -c '\
			uname -m; \
			arm-none-eabi-gcc --version | head -1; \
			nrfutil version; \
			mergehex --version'


# Build output lives on tycho's native Linux filesystem, so no Docker volume
# or artifact-copy container is required.
clean:
	rm -rf "$(BUILD_DIR)"


build: check-host sdk
	@test -n "$(FW_VERSION)" || { \
		echo "ERROR: Unable to determine firmware Git version."; \
		exit 1; \
	}
	@echo "Building firmware source $(FW_SOURCE_NAME), version $(FW_VERSION)"
	docker run --rm \
		-v "$(ROOT):/repo" \
		-v "$(SDK):$(CONTAINER_FIRMWARE)/$(SDK_DIRNAME)" \
		-w $(TARGET) \
		$(IMAGE) \
		make \
			DEBUG=-DNDEBUG \
			'FW_VERSION=-DAPP_FW_VERSION=\"$(FW_VERSION)\"'


verify: official
	@test -f "$(BUILD_DIR)/nrf52832_xxaa.bin" || { \
		echo "ERROR: Build output not found. Run 'make build' first."; \
		exit 1; \
	}
	@echo "SHA-256:"
	@sha256sum \
		"$(OFFICIAL_BIN)" \
		"$(BUILD_DIR)/nrf52832_xxaa.bin"
	@echo
	@echo "Binary comparison:"
	@cmp \
		"$(OFFICIAL_BIN)" \
		"$(BUILD_DIR)/nrf52832_xxaa.bin"
	@echo "MATCH: locally built firmware is byte-for-byte identical."


package: check-host sdk
	@test -f "$(BUILD_DIR)/nrf52832_xxaa.hex" || { \
		echo "ERROR: Build output not found. Run 'make build' first."; \
		exit 1; \
	}
	@test -n "$(FW_VERSION)" || { \
		echo "ERROR: Unable to determine firmware Git version."; \
		exit 1; \
	}
	@test -n "$(FW_SOURCE_NAME)" || { \
		echo "ERROR: Unable to determine firmware source name."; \
		exit 1; \
	}

	@echo "Preparing surfaced build directory..."
	@rm -rf "$(BUILD_OUTPUT_DIR)"
	@mkdir -p "$(BUILD_OUTPUT_DIR)"

	@cp "$(BUILD_DIR)/nrf52832_xxaa.bin" "$(BUILD_OUTPUT_DIR)/"
	@cp "$(BUILD_DIR)/nrf52832_xxaa.hex" "$(BUILD_OUTPUT_DIR)/"
	@if [ -f "$(BUILD_DIR)/nrf52832_xxaa.out" ]; then \
		cp "$(BUILD_DIR)/nrf52832_xxaa.out" "$(BUILD_OUTPUT_DIR)/"; \
	fi

	# package.sh emits two harmless warnings for custom, non-tagged builds:
	#   - git describe --exact-match fails because the commit is not a tag
	#   - it attempts to move a .map file that this build does not generate
	# Filter only those exact messages while preserving all other stderr and
	# the package.sh/docker exit status.
	docker run --rm \
		-v "$(ROOT):/repo" \
		-v "$(SDK):$(CONTAINER_FIRMWARE)/$(SDK_DIRNAME)" \
		-w $(TARGET) \
		$(IMAGE) \
		./package.sh -n $(PACKAGE_NAME) -v $(FW_VERSION) \
		2> >(grep -v -E \
			-e "^fatal: no tag exactly matches '" \
			-e "^mv: cannot stat '_build/nrf52832_xxaa\\.map': No such file or directory$$" \
			>&2)

	@set -euo pipefail; \
	shopt -s nullglob; \
	packages=("$(PACKAGE_DIR)"/*"$(PACKAGE_NAME)"*.zip); \
	if [ $${#packages[@]} -eq 0 ]; then \
		echo "ERROR: No DFU packages were generated."; \
		exit 1; \
	fi; \
	cp "$${packages[@]}" "$(BUILD_OUTPUT_DIR)/"

	@{ \
		echo "source=$(FW_SOURCE_NAME)"; \
		echo "commit=$$(git -C "$(FIRMWARE)" rev-parse HEAD)"; \
		echo "version=$(FW_VERSION)"; \
		echo "package_name=$(PACKAGE_NAME)"; \
		echo "sdk=$(SDK_VERSION)"; \
		echo "built_at=$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	} > "$(BUILD_OUTPUT_DIR)/BUILD_INFO"

	@echo
	@echo "Artifacts:"
	@ls -lh "$(BUILD_OUTPUT_DIR)"
	@echo
	@echo "Surfaced at: $(BUILD_OUTPUT_DIR)"


# Copy the useful outputs into builds/<firmware-source>/ so ready-to-flash
# artifacts are visible from the project root. The directory is replaced on
# every successful surface operation so it never contains stale files.
surface:
	@test -n "$(FW_SOURCE_NAME)" || { \
		echo "ERROR: Unable to determine firmware source name."; \
		exit 1; \
	}
	@test -f "$(BUILD_DIR)/nrf52832_xxaa.bin" || { \
		echo "ERROR: Build output not found. Run 'make build' first."; \
		exit 1; \
	}
	@rm -rf "$(BUILD_OUTPUT_DIR)"
	@mkdir -p "$(BUILD_OUTPUT_DIR)"
	@cp "$(BUILD_DIR)/nrf52832_xxaa.bin" "$(BUILD_OUTPUT_DIR)/"
	@cp "$(BUILD_DIR)/nrf52832_xxaa.hex" "$(BUILD_OUTPUT_DIR)/"
	@if [ -f "$(BUILD_DIR)/nrf52832_xxaa.out" ]; then \
		cp "$(BUILD_DIR)/nrf52832_xxaa.out" "$(BUILD_OUTPUT_DIR)/"; \
	fi
	@set -euo pipefail; \
	shopt -s nullglob; \
	packages=("$(PACKAGE_DIR)"/*"$(PACKAGE_NAME)"*.zip); \
	if [ $${#packages[@]} -eq 0 ]; then \
		echo "ERROR: No DFU packages found in $(PACKAGE_DIR). Run 'make package' first."; \
		exit 1; \
	fi; \
	cp "$${packages[@]}" "$(BUILD_OUTPUT_DIR)/"
	@{ \
		echo "source=$(FW_SOURCE_NAME)"; \
		echo "commit=$$(git -C "$(FIRMWARE)" rev-parse HEAD)"; \
		echo "version=$(FW_VERSION)"; \
		echo "package_name=$(PACKAGE_NAME)"; \
		echo "sdk=$(SDK_VERSION)"; \
		echo "built_at=$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	} > "$(BUILD_OUTPUT_DIR)/BUILD_INFO"
	@echo "Artifacts:"
	@ls -lh "$(BUILD_OUTPUT_DIR)"
	@echo
	@echo "Surfaced at: $(BUILD_OUTPUT_DIR)"


# Build a pristine copy of the official tag without changing the firmware
# submodule's current branch/commit. The temporary worktree is always removed.
stock: check-host sdk official
	@set -euo pipefail; \
	if ! git -C "$(FIRMWARE)" rev-parse -q --verify "refs/tags/$(OFFICIAL_VERSION)^{commit}" >/dev/null; then \
		echo "Fetching official Ruuvi tag $(OFFICIAL_VERSION)..."; \
		git -C "$(FIRMWARE)" fetch "$(OFFICIAL_REPO)" \
			"refs/tags/$(OFFICIAL_VERSION):refs/tags/$(OFFICIAL_VERSION)"; \
	fi; \
	if [ -e "$(STOCK_WORKTREE)" ]; then \
		git -C "$(FIRMWARE)" worktree remove --force "$(STOCK_WORKTREE)" >/dev/null 2>&1 || true; \
		rm -rf "$(STOCK_WORKTREE)"; \
	fi; \
	cleanup() { \
		git -C "$(FIRMWARE)" worktree remove --force "$(STOCK_WORKTREE)" >/dev/null 2>&1 || true; \
		rm -rf "$(STOCK_WORKTREE)"; \
	}; \
	trap cleanup EXIT; \
	echo "Creating temporary firmware worktree at $(OFFICIAL_VERSION)..."; \
	git -C "$(FIRMWARE)" worktree add --detach "$(STOCK_WORKTREE)" "$(OFFICIAL_VERSION)"; \
	git -C "$(STOCK_WORKTREE)" submodule update --init --recursive; \
	echo; \
	echo "Building pristine $(OFFICIAL_VERSION)..."; \
	$(MAKE) --no-print-directory \
		FIRMWARE="$(STOCK_WORKTREE)" \
		FW_VERSION="$(OFFICIAL_VERSION)" \
		clean; \
	$(MAKE) --no-print-directory \
		FIRMWARE="$(STOCK_WORKTREE)" \
		FW_VERSION="$(OFFICIAL_VERSION)" \
		build; \
	echo; \
	echo "SHA-256:"; \
	sha256sum \
		"$(OFFICIAL_BIN)" \
		"$(STOCK_WORKTREE)/src/targets/ruuvitag_b/armgcc/_build/nrf52832_xxaa.bin"; \
	echo; \
	echo "Binary comparison:"; \
	cmp \
		"$(OFFICIAL_BIN)" \
		"$(STOCK_WORKTREE)/src/targets/ruuvitag_b/armgcc/_build/nrf52832_xxaa.bin"; \
	echo "MATCH: pristine $(OFFICIAL_VERSION) build is byte-for-byte identical."


all: clean build package
