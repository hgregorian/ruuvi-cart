SHELL := /bin/bash

IMAGE        := ruuvi-fw-build:1
PLATFORM     := linux/amd64
BUILD_VOLUME ?= ruuvi-fw-output

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
	@echo "  make clean      Remove host build output and Docker build volume"
	@echo "  make build      Build firmware using a Docker-managed build volume"
	@echo "  make verify     Compare build with official v3.31.1"
	@echo "  make package    Build DFU packages"
	@echo "  make stock      Clean, build and verify stock firmware"
	@echo
	@echo "Current firmware version: $(FW_VERSION)"
	@echo "Build volume: $(BUILD_VOLUME)"


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


# GCC produces hundreds of small .o/.d/.su files. On Docker Desktop for macOS,
# writing those directly to a bind mount can intermittently fail with EDEADLK
# ("Resource deadlock avoided"). Keep _build on Docker's native Linux storage
# and copy the completed build tree back to the host after a successful build.
clean:
	rm -rf "$(BUILD_DIR)"
	@docker volume rm "$(BUILD_VOLUME)" >/dev/null 2>&1 || true


build:
	@echo "Building firmware version $(FW_VERSION)"
	@docker volume inspect "$(BUILD_VOLUME)" >/dev/null 2>&1 || \
		docker volume create "$(BUILD_VOLUME)" >/dev/null
	docker run --rm \
		--platform $(PLATFORM) \
		-v "$(FIRMWARE):/src" \
		-v "$(SDK):/src/nRF5_SDK_15.3.0_59ac345" \
		-v "$(BUILD_VOLUME):$(TARGET)/_build" \
		-w $(TARGET) \
		$(IMAGE) \
		make \
			DEBUG=-DNDEBUG \
			'FW_VERSION=-DAPP_FW_VERSION=\"$(FW_VERSION)\"'
	@echo "Copying build output to $(BUILD_DIR)"
	rm -rf "$(BUILD_DIR)"
	mkdir -p "$(BUILD_DIR)"
	docker run --rm \
		--platform $(PLATFORM) \
		-v "$(BUILD_VOLUME):/build:ro" \
		-v "$(BUILD_DIR):/out" \
		$(IMAGE) \
		sh -c 'cp -a /build/. /out/'


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
	@docker volume inspect $(BUILD_VOLUME) >/dev/null 2>&1 || { \
		echo "ERROR: Docker build volume '$(BUILD_VOLUME)' not found. Run 'make build' first."; \
		exit 1; \
	}
	docker run --rm \
		--platform $(PLATFORM) \
		-v "$(FIRMWARE):/src" \
		-v "$(SDK):/src/nRF5_SDK_15.3.0_59ac345" \
		-v $(BUILD_VOLUME):$(TARGET)/_build \
		-w $(TARGET) \
		$(IMAGE) \
		./package.sh -n $(PACKAGE_NAME) -v $(FW_VERSION)
	@echo
	@echo "Packages:"
	@ls -lh "$(PACKAGE_DIR)"/*$(PACKAGE_NAME)*.zip


stock: clean build verify


all: clean build package
