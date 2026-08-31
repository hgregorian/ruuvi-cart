SHELL := /bin/bash

IMAGE                 := ruuvi-fw-build:1

ROOT                  := $(CURDIR)
FIRMWARE              := $(ROOT)/firmware

SDK_VERSION           := 15.3.0_59ac345
SDK_DIRNAME           := nRF5_SDK_$(SDK_VERSION)
SDK                   := $(ROOT)/$(SDK_DIRNAME)
SDK_URL               ?= https://developer.nordicsemi.com/nRF5_SDK/nRF5_SDK_v15.x.x/$(SDK_DIRNAME).zip
SDK_TOOLCHAIN_FILE    := $(SDK)/components/toolchain/gcc/Makefile.posix

TARGET                := /src/src/targets/ruuvitag_b/armgcc
BUILD_DIR             := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc/_build
PACKAGE_DIR           := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc

PACKAGE_NAME          ?= ruuvifw_cart

OFFICIAL_VERSION      := v3.31.1
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

.PHONY: help check-host update sdk official image tools clean build verify package stock all


help:
	@echo "Targets:"
	@echo "  make update     Pull repository and synchronize all submodules"
	@echo "  make sdk        Download/configure Nordic nRF5 SDK $(SDK_VERSION)"
	@echo "  make official   Download/verify official Ruuvi $(OFFICIAL_VERSION) reference"
	@echo "  make image      Build the Docker toolchain image"
	@echo "  make tools      Display toolchain versions"
	@echo "  make clean      Remove firmware build output"
	@echo "  make build      Build the currently checked-out firmware"
	@echo "  make verify     Compare current build with official $(OFFICIAL_VERSION)"
	@echo "  make package    Build DFU packages for current firmware"
	@echo "  make stock      Build pristine $(OFFICIAL_VERSION) in a temporary worktree and verify it"
	@echo "  make all        Clean, build and package current firmware"
	@echo
	@echo "Build host architecture: $(HOST_ARCH)"
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
	git submodule update --init --recursive
	@echo
	@$(MAKE) --no-print-directory sdk
	@echo
	@echo "Update complete."


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
	@echo "Building firmware version $(FW_VERSION)"
	docker run --rm \
		-v "$(FIRMWARE):/src" \
		-v "$(SDK):/src/$(SDK_DIRNAME)" \
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
	docker run --rm \
		-v "$(FIRMWARE):/src" \
		-v "$(SDK):/src/$(SDK_DIRNAME)" \
		-w $(TARGET) \
		$(IMAGE) \
		./package.sh -n $(PACKAGE_NAME) -v $(FW_VERSION)
	@echo
	@echo "Packages:"
	@ls -lh "$(PACKAGE_DIR)"/*$(PACKAGE_NAME)*.zip


# Build a pristine copy of the official tag without changing the firmware
# submodule's current branch/commit. The temporary worktree is always removed.
stock: check-host sdk official
	@set -euo pipefail; \
	if ! git -C "$(FIRMWARE)" rev-parse -q --verify "refs/tags/$(OFFICIAL_VERSION)^{commit}" >/dev/null; then \
		echo "Fetching firmware tag $(OFFICIAL_VERSION)..."; \
		git -C "$(FIRMWARE)" fetch origin "refs/tags/$(OFFICIAL_VERSION):refs/tags/$(OFFICIAL_VERSION)"; \
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
