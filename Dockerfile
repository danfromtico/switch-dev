# syntax=docker/dockerfile:1
# danfromtico/switch-dev: devkitA64 with everything Autorun and other Horizon
# ports build against, each from a pinned revision:
#   libnx         switchbrew/libnx, newer than devkitPro's release
#   mesa-switch   Mesa 26 for Horizon: EGL/OpenGL through nvc0 or Zink, NVK Vulkan
#   lsfg-vk       LSFG-VK's backend with the Horizon port in lsfg/
#   libusbhsfs    with the UASP transport in libusbhsfs/
# and the tools to build them and more: Meson, CMake, Ninja, glslang,
# SPIRV-Tools, LLVM/Clang 15, Rust nightly with bindgen, and hactool.

ARG DEVKITA64=devkitpro/devkita64@sha256:1fc388c3a0d34bd2045a6dadcb1020e069d5f876a187fd705de14b4440c00282
FROM ${DEVKITA64}

ARG LIBNX_REVISION=146c3d1446d35546943c7b6cfcd479bc1f5e9b67
ARG MESA_SWITCH_REPOSITORY=https://github.com/danfromtico/mesa-switch.git
ARG MESA_SWITCH_REVISION=0ff52079ca9e9e837ed27eb95a8d239f439a1864
ARG LSFG_VK_REVISION=8b0da2661c6f3473a7fccc8ba643880050e71642
ARG LIBUSBHSFS_REVISION=625269b7725a6e2a3f2724e8d45b602c1b20ead5
ARG SPIRV_TOOLS_TAG=vulkan-sdk-1.3.290.0
ARG RUST_TOOLCHAIN=nightly-2026-09-08
ARG MESON_VERSION=1.12.0
ARG MAKO_VERSION=1.4.1
ARG HACTOOL_REVISION=3121a5bf08cd81d3a99719feb2cab3b60767afd5

ENV DEVKITPRO=/opt/devkitpro \
    DEVKITA64=/opt/devkitpro/devkitA64 \
    PATH=/opt/devkitpro/devkitA64/bin:/opt/devkitpro/tools/bin:/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Tools -------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-pip python3-setuptools python3-wheel \
        ninja-build pkg-config flex bison curl ca-certificates git cmake make \
        clang libclang-dev llvm-15-dev libllvmspirvlib-15-dev libclc-15-dev libclang-15-dev \
        glslang-tools \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --break-system-packages meson==${MESON_VERSION} mako==${MAKO_VERSION}
# Mesa wants SPIRV-Tools 2024.1 or later, newer than Debian's.
RUN git clone --depth 1 --branch ${SPIRV_TOOLS_TAG} https://github.com/KhronosGroup/SPIRV-Tools.git /tmp/spirv-tools \
    && git clone --depth 1 --branch ${SPIRV_TOOLS_TAG} https://github.com/KhronosGroup/SPIRV-Headers.git /tmp/spirv-tools/external/spirv-headers \
    && cmake -S /tmp/spirv-tools -B /tmp/spirv-tools/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local -DSPIRV_SKIP_TESTS=ON \
    && ninja -C /tmp/spirv-tools/build install \
    && rm -rf /tmp/spirv-tools
# NAK, NVK's shader compiler, is Rust: nightly with rust-src, and the AArch64
# ELF target's std, which Switch code is compiled for on an amd64 machine too.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
        --default-toolchain ${RUST_TOOLCHAIN} --component rust-src \
        --target aarch64-unknown-linux-gnu \
    && cargo install --locked bindgen-cli@0.73.2 cbindgen@0.29.4 \
    && rm -rf /root/.cargo/registry /root/.cargo/git
RUN git clone https://github.com/SciresM/hactool.git /tmp/hactool \
    && git -C /tmp/hactool checkout -q ${HACTOOL_REVISION} \
    && cp /tmp/hactool/config.mk.template /tmp/hactool/config.mk \
    && make -C /tmp/hactool -j"$(nproc)" \
    && install -m 755 /tmp/hactool/hactool /usr/local/bin/hactool \
    && rm -rf /tmp/hactool

# --- libnx ---------------------------------------------------------------------
# devkitPro's released libnx stays in /opt/devkitpro-release, beside the same
# toolchain, for projects that pin it: Atmosphere builds only against that
# release's API. Build them with DEVKITPRO=/opt/devkitpro-release.
RUN mkdir /opt/devkitpro-release \
    && for entry in /opt/devkitpro/*; do \
           [ "$(basename "$entry")" = libnx ] || ln -s "$entry" /opt/devkitpro-release/; \
       done \
    && cp -a /opt/devkitpro/libnx /opt/devkitpro-release/libnx
RUN git init -q /tmp/libnx \
    && git -C /tmp/libnx fetch -q --depth 1 https://github.com/switchbrew/libnx.git ${LIBNX_REVISION} \
    && git -C /tmp/libnx checkout -q FETCH_HEAD \
    && make -C /tmp/libnx -j"$(nproc)" install \
    && rm -rf /tmp/libnx

# --- mesa-switch ---------------------------------------------------------------
# It replaces devkitPro's Mesa 20.1 and the libdrm_nouveau that went with it:
# its Horizon backend is written against libnx, and the libdrm_nouveau API its
# OpenGL winsys implements comes with its own copy of the headers.
COPY mesa/build.sh /usr/local/share/switch-dev/mesa-build.sh
RUN dkp-pacman -Rdd --noconfirm switch-mesa switch-libdrm_nouveau \
    && git init -q /tmp/mesa-switch \
    && git -C /tmp/mesa-switch fetch -q --depth 1 ${MESA_SWITCH_REPOSITORY} ${MESA_SWITCH_REVISION} \
    && git -C /tmp/mesa-switch checkout -q FETCH_HEAD \
    && cd /tmp/mesa-switch && bash /usr/local/share/switch-dev/mesa-build.sh \
    && rm -rf /tmp/mesa-switch /root/.cargo/registry

# --- lsfg-vk and libusbhsfs ----------------------------------------------------
# Both are built as Autorun builds its own code: devkitA64 with x18 left alone,
# which Wine keeps its thread data in.
COPY cmake/switch.cmake /opt/devkitpro/cmake/switch-dev.cmake
COPY lsfg /usr/local/share/switch-dev/lsfg
RUN git init -q /tmp/lsfg-vk \
    && git -C /tmp/lsfg-vk fetch -q --depth 1 https://git.lsfg-vk.dev/lsfg-vk-archive.git ${LSFG_VK_REVISION} \
    && git -C /tmp/lsfg-vk -c core.autocrlf=false checkout -q FETCH_HEAD \
    && git -C /tmp/lsfg-vk apply /usr/local/share/switch-dev/lsfg/horizon.patch \
    && cmake -S /usr/local/share/switch-dev/lsfg -B /tmp/lsfg-build -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=/opt/devkitpro/cmake/switch-dev.cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/devkitpro/portlibs/switch -DLSFG_SOURCE=/tmp/lsfg-vk \
    && ninja -C /tmp/lsfg-build install \
    && rm -rf /tmp/lsfg-vk /tmp/lsfg-build
COPY libusbhsfs /usr/local/share/switch-dev/libusbhsfs
RUN git init -q /tmp/libusbhsfs \
    && git -C /tmp/libusbhsfs fetch -q --depth 1 https://github.com/ITotalJustice/libusbhsfs.git ${LIBUSBHSFS_REVISION} \
    && git -C /tmp/libusbhsfs checkout -q FETCH_HEAD \
    && for patch in /usr/local/share/switch-dev/libusbhsfs/*.patch; do \
           tr -d '\r' < "$patch" | git -C /tmp/libusbhsfs apply - || exit 1; \
       done \
    && cmake -S /usr/local/share/switch-dev/libusbhsfs -B /tmp/libusbhsfs-build -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE=/opt/devkitpro/cmake/switch-dev.cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/devkitpro/portlibs/switch -DUSBHSFS_SOURCE=/tmp/libusbhsfs \
    && ninja -C /tmp/libusbhsfs-build install \
    && rm -rf /tmp/libusbhsfs /tmp/libusbhsfs-build

# Sanitizer runtimes for host tests built with clang -fsanitize.
RUN apt-get update && apt-get install -y --no-install-recommends libclang-rt-14-dev \
    && rm -rf /var/lib/apt/lists/*

# What this image holds, for a build to record.
RUN printf '{\n  "devkita64": "%s",\n  "libnx": "%s",\n  "mesa_switch": "%s",\n  "lsfg_vk": "%s",\n  "libusbhsfs": "%s",\n  "rust": "%s"\n}\n' \
        "$(dkp-pacman -Q devkitA64 | cut -d' ' -f2)" ${LIBNX_REVISION} ${MESA_SWITCH_REVISION} \
        ${LSFG_VK_REVISION} ${LIBUSBHSFS_REVISION} ${RUST_TOOLCHAIN} \
        > /opt/devkitpro/portlibs/switch/share/switch-dev.json

LABEL org.opencontainers.image.source=https://github.com/danfromtico/switch-dev \
      org.opencontainers.image.description="devkitA64 with libnx, mesa-switch, lsfg-vk and libusbhsfs for Horizon" \
      dev.autorun.libnx=${LIBNX_REVISION} \
      dev.autorun.mesa-switch=${MESA_SWITCH_REVISION} \
      dev.autorun.lsfg-vk=${LSFG_VK_REVISION} \
      dev.autorun.libusbhsfs=${LIBUSBHSFS_REVISION} \
      dev.autorun.rust=${RUST_TOOLCHAIN}
WORKDIR /work
