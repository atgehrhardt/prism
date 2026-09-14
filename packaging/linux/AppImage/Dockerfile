# Build against glibc 2.39; newer compositor libraries are built below this baseline.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc-14 g++-14 git ca-certificates curl wget pkg-config ninja-build \
    python3 python3-venv python3-jinja2 nodejs npm desktop-file-utils file patchelf \
    libcap-dev libcurl4-openssl-dev libdrm-dev libevdev-dev libgbm-dev libgl-dev \
    libegl-dev libgles-dev libminiupnpc-dev libnotify-dev libnuma-dev libopus-dev \
    libpipewire-0.3-dev libpulse-dev libssl-dev libsystemd-dev libudev-dev libva-dev \
    libwayland-dev libx11-dev libxcb-shm0-dev libxcb-xfixes0-dev libxcb1-dev \
    libxfixes-dev libxkbcommon-dev libxrandr-dev libxtst-dev libvulkan-dev \
    qt6-base-dev qt6-svg-dev glslc glslang-tools libffi-dev libexpat1-dev \
    libxml2-dev liblcms2-dev libpixman-1-dev libcairo2-dev libpango1.0-dev \
    libpng-dev libxcb-ewmh-dev libxcb-icccm4-dev libxcb-composite0-dev \
    libxcb-render0-dev libxcb-res0-dev xwayland wayland-utils wlr-randr \
    pulseaudio-utils xkb-data x11-xkb-utils bubblewrap patch shellcheck xvfb \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends bison && rm -rf /var/lib/apt/lists/*
COPY --from=node:22-bookworm-slim /usr/local/bin/node /usr/local/bin/node
RUN python3 -m venv /opt/build-tools && \
    /opt/build-tools/bin/pip install --no-cache-dir cmake==4.3.0 meson==1.9.2 Jinja2==3.1.6
ENV PATH="/opt/build-tools/bin:/opt/prism-deps/bin:${PATH}"
ENV PKG_CONFIG_PATH=/opt/prism-deps/lib/pkgconfig:/opt/prism-deps/share/pkgconfig
ENV CMAKE_PREFIX_PATH=/opt/prism-deps
ENV CC=gcc-14 CXX=g++-14
COPY packaging/linux/AppImage/build-dependencies.sh /opt/build-dependencies.sh
RUN bash /opt/build-dependencies.sh
RUN apt-get update && apt-get install -y --no-install-recommends squashfs-tools && rm -rf /var/lib/apt/lists/*
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Compiler/runtime development files only; no host driver is installed or bundled.
RUN curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb && \
    echo 'd2a6b11c096396d868758b86dab1823b25e14d70333f1dfa74da5ddaf6a06dba  /tmp/cuda-keyring.deb' | sha256sum --check --status && \
    dpkg -i /tmp/cuda-keyring.deb && apt-get update && \
    apt-get install -y --no-install-recommends cuda-nvcc-12-8 cuda-cudart-dev-12-8 && \
    rm -f /tmp/cuda-keyring.deb && rm -rf /var/lib/apt/lists/*
ENV PATH="/usr/local/cuda-12.8/bin:${PATH}"
RUN apt-get update && apt-get install -y --no-install-recommends libinput-dev && rm -rf /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends \
    libxkbfile-dev libxfont-dev libxcvt-dev libepoxy-dev libxshmfence-dev \
    xtrans-dev x11proto-dev mesa-common-dev && rm -rf /var/lib/apt/lists/*
COPY packaging/linux/AppImage/build-xwayland.sh /opt/build-xwayland.sh
RUN bash /opt/build-xwayland.sh
RUN apt-get update && apt-get install -y --no-install-recommends qt6-wayland ccache && rm -rf /var/lib/apt/lists/*
# The CI checkout is owned by the runner, while packaging runs as root in this image.
RUN git config --system --add safe.directory /src
COPY contrib/virtual-session/build-headless-compositor.sh contrib/virtual-session/check-headless-build-deps.sh /opt/prism-compositor-src/contrib/virtual-session/
COPY contrib/virtual-session/patches/ /opt/prism-compositor-src/contrib/virtual-session/patches/
COPY packaging/linux/AppImage/build-compositor.sh /opt/prism-compositor-src/packaging/linux/AppImage/build-compositor.sh
RUN bash /opt/prism-compositor-src/packaging/linux/AppImage/build-compositor.sh
# CMake reads this submodule's tag to select the pinned prebuilt FFmpeg release.
RUN git config --system --add safe.directory /src/third-party/build-deps
WORKDIR /src
