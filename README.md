# Ruuvi Cart Firmware

Custom RuuviTag Pro firmware and reproducible build environment for motion-triggered, high-frequency accelerometer telemetry intended for Home Assistant trash-cart tracking.

The firmware source is maintained in the `firmware/` Git submodule, which points to a fork of Ruuvi's `ruuvi.firmware.c` repository. The outer repository contains the Docker build environment, helper `Makefile`, setup instructions, and project-specific documentation.

## Repository Layout

```text
ruuvi-cart/
├── Makefile
├── README.md
├── docker/
│   └── Dockerfile
├── firmware/                       # Git submodule: Ruuvi firmware fork
├── nRF5_SDK_15.3.0_59ac345/       # Local dependency; not committed
└── official-v3.31.1/               # Optional local reference artifacts
```

## Firmware Baseline

The project is based on Ruuvi firmware release:

```text
v3.31.1
```

The initial custom firmware branch is:

```text
cart-motion-burst
```

The build environment has been validated by reproducing Ruuvi's official `v3.31.1` default application binary byte-for-byte.

Verified SHA-256:

```text
0d965eff27639e7d2ff18c620194ce059b92887e77852900dc08fa29938060ac
```

## Clone

Clone recursively so the firmware submodule and all nested Ruuvi submodules are initialized:

```bash
git clone --recursive git@github.com:hgregorian/ruuvi-cart.git
cd ruuvi-cart
```

If the repository was cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

To verify the firmware submodules:

```bash
git -C firmware submodule status --recursive
```

No lines should begin with `-`, `+`, or `U`.

## Nordic nRF5 SDK

This project builds against:

```text
nRF5 SDK 15.3.0
```

Download it from Nordic Semiconductor:

https://www.nordicsemi.com/Products/Development-software/nRF5-SDK/Download

On the download page:

1. Locate **nRF5 SDK 15.3.0**.
2. Download the SDK ZIP archive.
3. Extract it into the root of this repository.
4. Ensure the extracted directory is named:

```text
nRF5_SDK_15.3.0_59ac345
```

The resulting project layout should contain:

```text
ruuvi-cart/
├── Makefile
├── docker/
├── firmware/
└── nRF5_SDK_15.3.0_59ac345/
```

The SDK is intentionally excluded from Git.

## Configure the Nordic SDK GCC Toolchain

Edit:

```text
nRF5_SDK_15.3.0_59ac345/components/toolchain/gcc/Makefile.posix
```

Set the GCC configuration to:

```make
GNU_INSTALL_ROOT ?= /opt/gcc-arm-none-eabi-7-2018-q2-update/bin/
GNU_VERSION ?= 7.3.1
GNU_PREFIX ?= arm-none-eabi
```

This points the Nordic SDK build system at the ARM compiler installed inside the Docker image.

You can verify the file with:

```bash
grep -E 'GNU_INSTALL_ROOT|GNU_VERSION|GNU_PREFIX' \
  nRF5_SDK_15.3.0_59ac345/components/toolchain/gcc/Makefile.posix
```

Expected output:

```text
GNU_INSTALL_ROOT ?= /opt/gcc-arm-none-eabi-7-2018-q2-update/bin/
GNU_VERSION ?= 7.3.1
GNU_PREFIX ?= arm-none-eabi
```

## Docker Build Environment

The build environment is containerized so the firmware can be compiled with the same historical toolchain used for the validated Ruuvi release.

The Docker image contains:

```text
ARM GCC       7.3.1 / 7-2018-q2-update
nrfutil       6.0.1
mergehex      10.24.2
```

Build the image:

```bash
make image
```

Verify the toolchain:

```bash
make tools
```

Expected major versions:

```text
x86_64
arm-none-eabi-gcc ... 7.3.1 ...
nrfutil version 6.0.1
mergehex version: 10.24.2
```

## Apple Silicon Macs

The build container is intentionally run as:

```text
linux/amd64
```

On Apple Silicon, Docker Desktop must support x86_64 emulation.

A quick validation is:

```bash
docker run --rm --platform linux/amd64 alpine uname -m
```

Expected output:

```text
x86_64
```

If this produces `exec format error`, enable Docker Desktop's x86_64/Rosetta emulation and restart Docker Desktop.

## Build Targets

Show the available wrapper targets:

```bash
make help
```

### Clean

```bash
make clean
```

### Build

Build the default RuuviTag firmware:

```bash
make build
```

The build output is written under:

```text
firmware/src/targets/ruuvitag_b/armgcc/_build/
```

Important files include:

```text
nrf52832_xxaa.bin
nrf52832_xxaa.hex
nrf52832_xxaa.out
```

### Verify the Stock Baseline

For the unmodified `v3.31.1` source tree:

```bash
make verify
```

This compares the locally built application binary against the official reference binary.

A successful validation ends with:

```text
MATCH: locally built firmware is byte-for-byte identical.
```

The convenience target:

```bash
make stock
```

performs:

```text
clean -> build -> verify
```

Once custom firmware changes are introduced, `make verify` is expected to fail because the custom binary should no longer match stock Ruuvi firmware.

## Package Firmware

Generate Nordic Secure DFU packages with:

```bash
make package
```

A custom package name can be supplied:

```bash
make package PACKAGE_NAME=ruuvifw_cart
```

The application-only DFU package is the normal OTA update artifact of interest:

```text
*_dfu_app.zip
```

The upstream Ruuvi packaging script also creates:

```text
*_sdk12.3_to_15.3_dfu.zip
```

That artifact is intended for migration from older SDK/SoftDevice generations and is generated with `--debug-mode` by the upstream script. The large `nrfutil` warning shown during creation of that migration package does **not** apply to the normal application-only `*_dfu_app.zip`.

## Firmware Version Injection

The Ruuvi source defaults to:

```c
#define APP_FW_VERSION "v0.0.1"
```

when the lower-level target Makefile is invoked without a firmware version.

The project wrapper therefore explicitly supplies the firmware version when building.

For the validated stock baseline:

```text
v3.31.1
```

This matters because a build without version injection differs from the official binary only in the embedded firmware version string.

## Git Structure

There are two Git repositories involved.

The outer project repository:

```text
hgregorian/ruuvi-cart
```

contains the build environment, project documentation, and a gitlink to the firmware revision.

The firmware submodule:

```text
hgregorian/ruuvi.firmware.c
```

is a fork of:

```text
https://github.com/ruuvi/ruuvi.firmware.c
```

Inside the firmware submodule, the recommended remotes are:

```text
origin    git@github.com:hgregorian/ruuvi.firmware.c.git
upstream  https://github.com/ruuvi/ruuvi.firmware.c.git
```

Verify with:

```bash
git -C firmware remote -v
```

## Firmware Development Workflow

Firmware changes should be committed inside the submodule first.

Example:

```bash
cd firmware

git status
git add <files>
git commit -m "Implement motion-triggered telemetry burst"
git push

cd ..
```

Then update the outer repository's submodule pointer:

```bash
git add firmware
git commit -m "Update firmware submodule"
git push
```

The outer repository therefore records the exact firmware commit used by the project.

## Updating From Ruuvi Upstream

Inside the firmware submodule:

```bash
cd firmware

git fetch upstream
git fetch origin
```

Review newer Ruuvi releases or changes before rebasing or merging them into the custom firmware branch.

The project intentionally starts from the known-good, validated `v3.31.1` baseline so custom changes can be isolated from upstream/toolchain differences.

## Current Project Goal

The custom firmware is intended to support a trash-cart tracking workflow with two operating modes.

Idle mode:

```text
Fresh telemetry approximately every 120 seconds
Low-power accelerometer motion detection
Minimal radio activity
```

Active mode:

```text
Fresh accelerometer XYZ samples
BLE advertisements approximately every 100 ms
Continues while motion is detected
```

After motion stops for a configurable inactivity period, the firmware should send a final fresh telemetry update and return to the low-power idle interval.

Initial design parameters:

```c
#define CART_IDLE_INTERVAL_MS      120000
#define CART_ACTIVE_INTERVAL_MS       100
#define CART_IDLE_TIMEOUT_MS          5000
#define CART_MOTION_THRESHOLD_G       0.080F
```

These values are starting points and may change after field testing.

## Home Assistant Use

The resulting Ruuvi advertisements are intended to remain compatible with Ruuvi RAWv2 / Data Format 5 so Home Assistant can continue consuming:

```text
Acceleration X
Acceleration Y
Acceleration Z
Battery
Environmental telemetry
BLE identity / RSSI
```

The higher-frequency burst during motion is intended to support:

- cart movement detection,
- orientation and tilt analysis,
- trash-dump detection,
- post-dump settling detection,
- closest Bluetooth proxy / area determination.

## Local Files Not Committed

The following are intentionally kept out of the outer Git repository:

```text
nRF5_SDK_15.3.0_59ac345/
nRF5SDK*.zip
official-v3.31.1/
.DS_Store
```

Build products generated inside the firmware submodule should also generally remain uncommitted.

## Reference Binary Validation

The original build environment was validated by comparing the locally built application against Ruuvi's official `v3.31.1` production application.

Both produced:

```text
SHA256
0d965eff27639e7d2ff18c620194ce059b92887e77852900dc08fa29938060ac
```

and:

```bash
cmp official.bin local-release.bin
```

produced no output.

The same byte-for-byte result was subsequently reproduced on Apple Silicon using Docker's `linux/amd64` emulation.

This provides a known-good baseline before applying custom firmware changes.
