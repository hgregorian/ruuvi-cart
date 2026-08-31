SHELL := /bin/bash

IMAGE        := ruuvi-fw-build:1

ROOT         := $(CURDIR)
FIRMWARE     := $(ROOT)/firmware

SDK_VERSION  := 15.3.0_59ac345
SDK_DIRNAME  := nRF5_SDK_$(SDK_VERSION)
SDK          := $(ROOT)/$(SDK_DIRNAME)
SDK_URL      ?= https://developer.nordicsemi.com/nRF5_SDK/nRF5_SDK_v15.x.x/nRF5_SDK_15.3.0_59ac345.zip
SDK_TOOLCHAIN_FILE := $(SDK)/components/toolchain/gcc/Makefile.posix

TARGET       := /src/src/targets/ruuvitag_b/armgcc
BUILD_DIR    := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc/_build
PACKAGE_DIR  := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc

OFFICIAL_BIN := $(ROOT)/official-v3.31.1/official.bin
PACKAGE_NAME ?= ruuvifw_cart

HOST_ARCH := $(shell uname -m)

# At an exact tag this becomes, for example, v3.31.1.
# After custom commits it falls back to the Git short SHA.
FW_VERSION := $(shell cd "$(FIRMWARE)" 2>/dev/null && \
	(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null))


.PHONY: help check-host sdk image tools clean build verify package stock all


help:
	@echo "Targets:"
	@echo "  make sdk        Download/configure Nordic nRF5 SDK $(SDK_VERSION)"
	@echo "  make image      Build the Docker toolchain image"
	@echo "  make tools      Display toolchain versions"
	@echo "  make clean      Remove firmware build output"
	@echo "  make build      Build RuuviTag firmware"
	@echo "  make verify     Compare build with official v3.31.1"
	@echo "  make package    Build DFU packages"
	@echo "  make stock      Clean, build and verify stock firmware"
	@echo "  make all        Clean, build and package firmware"
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


# Download the exact Nordic SDK required by Ruuvi firmware v3.31.1 and
# configure its GCC toolchain path for the compiler installed in our image.
# The target is idempotent: an existing SDK is kept and the toolchain file is
# normalized on every run.
sdk: check-host
	@if [ ! -d "$(SDK)" ]; then \
		command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required."; exit 1; }; \
		command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip is required."; exit 1; }; \
		echo "Downloading Nordic nRF5 SDK $(SDK_VERSION)..."; \
		tmp=$$(mktemp /tmp/nRF5SDK153059ac345.XXXXXX.zip); \
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
		-v "$(SDK):/src/nRF5_SDK_15.3.0_59ac345" \
		-w $(TARGET) \
		$(IMAGE) \
		make \
			DEBUG=-DNDEBUG \
			'FW_VERSION=-DAPP_FW_VERSION=\"$(FW_VERSION)\"'


verify:
	@test -f "$(BUILD_DIR)/nrf52832_xxaa.bin" || { \
		echo "ERROR: Build output not found. Run 'make build' first."; \
		exit 1; \
	}
	@test -f "$(OFFICIAL_BIN)" || { \
		echo "ERROR: Official reference binary not found:"; \
		echo "  $(OFFICIAL_BIN)"; \
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
		-v "$(SDK):/src/nRF5_SDK_15.3.0_59ac345" \
		-w $(TARGET) \
		$(IMAGE) \
		./package.sh -n $(PACKAGE_NAME) -v $(FW_VERSION)
	@echo
	@echo "Packages:"
	@ls -lh "$(PACKAGE_DIR)"/*$(PACKAGE_NAME)*.zip


stock: clean build verify


all: clean build package
