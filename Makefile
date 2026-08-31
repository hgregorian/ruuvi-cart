SHELL := /bin/bash

IMAGE        := ruuvi-fw-build:1
PLATFORM     := linux/amd64

ROOT         := $(CURDIR)
FIRMWARE     := $(ROOT)/firmware
SDK          := $(ROOT)/nRF5_SDK_15.3.0_59ac345
TARGET       := /src/src/targets/ruuvitag_b/armgcc

BUILD_DIR    := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc/_build
PACKAGE_DIR  := $(FIRMWARE)/src/targets/ruuvitag_b/armgcc

OFFICIAL_BIN := $(ROOT)/official-v3.31.1/official.bin
PACKAGE_NAME ?= ruuvifw_cart

# At an exact tag this becomes, for example, v3.31.1.
# After we start making custom commits it falls back to the Git short SHA.
FW_VERSION := $(shell cd "$(FIRMWARE)" && \
	(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD))


.PHONY: help image tools clean build verify package stock all


help:
	@echo "Targets:"
	@echo "  make image      Build the Docker toolchain image"
	@echo "  make tools      Display toolchain versions"
	@echo "  make clean      Remove firmware build output"
	@echo "  make build      Build default RuuviTag firmware"
	@echo "  make verify     Compare build with official v3.31.1"
	@echo "  make package    Build DFU packages"
	@echo "  make stock      Clean, build and verify stock firmware"
	@echo
	@echo "Current firmware version: $(FW_VERSION)"


image:
	docker buildx build \
		--platform $(PLATFORM) \
		--load \
		-t $(IMAGE) \
		-f docker/Dockerfile \
		docker


tools:
	docker run --rm \
		--platform $(PLATFORM) \
		$(IMAGE) \
		sh -c '\
			uname -m; \
			arm-none-eabi-gcc --version | head -1; \
			nrfutil version; \
			mergehex --version'


clean:
	docker run --rm \
		--platform $(PLATFORM) \
		-v "$(FIRMWARE):/src" \
		-v "$(SDK):/src/nRF5_SDK_15.3.0_59ac345" \
		-w $(TARGET) \
		$(IMAGE) \
		make clean


build:
	@echo "Building firmware version $(FW_VERSION)"
	docker run --rm \
		--platform $(PLATFORM) \
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


package:
	@test -f "$(BUILD_DIR)/nrf52832_xxaa.hex" || { \
		echo "ERROR: Build output not found. Run 'make build' first."; \
		exit 1; \
	}
	docker run --rm \
		--platform $(PLATFORM) \
		-v "$(FIRMWARE):/src" \
		-v "$(SDK):/src/nRF5_SDK_15.3.0_59ac345" \
		-w $(TARGET) \
		$(IMAGE) \
		./package.sh -n $(PACKAGE_NAME)
	@echo
	@echo "Packages:"
	@ls -lh "$(PACKAGE_DIR)"/*$(PACKAGE_NAME)*.zip


stock: clean build verify


all: clean build package
