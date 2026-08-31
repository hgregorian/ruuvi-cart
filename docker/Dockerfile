FROM hardwario/gcc-arm-embedded:7-2018-q2-update

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ARG NORDIC_CLI_VERSION=10.24.2
ARG NORDIC_CLI_URL=https://nsscprodmedia.blob.core.windows.net/prod/software-and-other-downloads/desktop-software/nrf-command-line-tools/sw/versions-10-x-x/10-24-2/nrf-command-line-tools-10.24.2_linux-amd64.tar.gz

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      wget \
      curl \
      git \
      make \
      zip \
      unzip \
      python3 \
      python3-pip \
      libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Nordic Command Line Tools: provides mergehex.
RUN mkdir -p /opt/nordic && \
    wget -O /tmp/nrf-cli.tar.gz "${NORDIC_CLI_URL}" && \
    tar -xzf /tmp/nrf-cli.tar.gz -C /opt/nordic && \
    rm /tmp/nrf-cli.tar.gz && \
    find /opt/nordic -type f -name mergehex -exec ln -s {} /usr/local/bin/mergehex \;

# Legacy Python nrfutil.
#
# Version 5.2.0 works with Python 3.6 and has the `pkg` and `settings`
# command families required by Ruuvi's package.sh.
RUN python3 -m pip install --no-cache-dir --upgrade \
      "pip<22" \
      setuptools \
      wheel && \
    python3 -m pip install --no-cache-dir \
      "nrfutil==6.0.1"

WORKDIR /src

RUN echo "=== toolchain ===" && \
    arm-none-eabi-gcc --version | head -1 && \
    echo "=== nrfutil ===" && \
    nrfutil version && \
    echo "=== mergehex ===" && \
    mergehex --version
