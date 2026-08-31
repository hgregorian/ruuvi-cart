SHELL := /bin/bash

IMAGE        := ruuvi-fw-build:1

ROOT         := $(CURDIR)
FIRMWARE     := $(ROOT)/firmware
SDK          := $(ROOT)/nRF5_SDK_15.3.0_59ac345
TARGET       := /src/src/targets/ruuvitag_b/armgcc

BUILD_DIR    := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc/_build
PACKAGE_DIR  := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc

OFFICIAL_BIN := $(ROOT)/official-v3.31.1/official.bin
PACKAGE_NAME ?= ruuvifw_cart

HOST_ARCH := $(shell uname -m)

# At an exact tag this becomes, for example, v3.31.1.
# After custom commits it falls back to the Git short SHA.
FW_VERSION := $(shell cd "$(FIRMWARE)" && \
	(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD))


.PHONY: help check-host image tools clean build verify package stock all


help:
	@echo "Targets:"
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


# This project intentionally builds on a native amd64 Linux host (tycho).
# Avoid Docker Desktop/Rosetta and macOS bind-mount filesystem issues.
check-host:
	@if [ "$(HOST_ARCH)" != "x86_64" ]; then \
		echo "ERROR: Firmware builds are intended for a native x86_64 Linux host."; \
		echo "Current host architecture: $(HOST_ARCH)"; \
		exit 1; \
	fi


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


clean:
	docker run --rm \
		-v "$(FIRMWARE):/src" \
		-v "$(SDK):/src/nRF5_SDK_15.3.0_59ac345" \
		-w $(TARGET) \
		$(IMAGE) \
		make clean


build: check-host
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


package: check-host
	@test -f "$(BUILD_DIR)/nrf52832_xxaa.hex" || { \
		echo "ERROR: Build output not found. Run 'make build' first."; \
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
