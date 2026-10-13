#!/bin/bash
# Build NVK, mesa-switch's loaderless Vulkan, from the checkout in the current
# directory and stage it under $DESTDIR (default /tmp/nvk-stage) for portlibs.
# Only Vulkan: no EGL, OpenGL or Gallium, so it sits beside devkitPro's Mesa
# 20.1 OpenGL and libdrm_nouveau in switch-dev-legacy without replacing a
# file of theirs. NVK runs on mesa-switch's own Horizon backend and needs no
# libdrm_nouveau.
set -euo pipefail
portlibs=/opt/devkitpro/portlibs/switch
stage="${DESTDIR:-/tmp/nvk-stage}"
staged=$stage$portlibs

# What mesa-switch's build-switch.sh sets up in its container: the cross
# wrappers for bindgen and rustc, the Nouveau header NAK's bindgen reads, the
# Clang header path mesa_clc uses, and placeholder libdl, librt and libutil
# for Rust std (rust_switch_stubs.c has the symbols).
mkdir -p /usr/local/libexec "$staged/include" "$staged/lib"
cp bindgen-switch-wrapper.sh /usr/local/libexec/bindgen
cp rustc-switch-wrapper.sh /usr/local/libexec/rustc
cp bindgen-atomic-shim.h /usr/local/libexec/bindgen-atomic-shim.h
sed -i 's/\r$//' /usr/local/libexec/bindgen /usr/local/libexec/rustc
chmod +x /usr/local/libexec/bindgen /usr/local/libexec/rustc
cp -p src/nouveau/headers/nv_device_info.h $portlibs/include/
cp -p src/nouveau/headers/nv_device_info.h "$staged/include/"
[ -d /usr/lib/llvm-15/lib/clang/15/include ] ||
    ln -sf /usr/lib/llvm-15/lib/clang/15.0.6/include /usr/lib/llvm-15/lib/clang/15/include
echo 'void __mesa_switch_stub_lib(void) {}' > /tmp/stub_posix.c
aarch64-none-elf-gcc -c /tmp/stub_posix.c -o /tmp/stub_posix.o
for l in dl rt util; do
    aarch64-none-elf-ar rcs $portlibs/lib/lib$l.a /tmp/stub_posix.o
    cp $portlibs/lib/lib$l.a "$staged/lib/"
done
# vulkan.pc and VulkanConfig.cmake require libelf, which devkitPro does not
# package and NVK's Switch build does not call: a placeholder lets
# pkg-config and find_package(Vulkan) resolve.
aarch64-none-elf-ar rcs "$staged/lib/libelf.a" /tmp/stub_posix.o
mkdir -p "$staged/lib/pkgconfig"
cat > "$staged/lib/pkgconfig/libelf.pc" <<EOF
prefix=$portlibs
libdir=\${prefix}/lib

Name: libelf
Description: Placeholder: mesa-switch NVK requires libelf but does not use it on Horizon
Version: 0.0
Libs: -L\${libdir} -lelf
EOF

# The host tools the cross build runs.
tools=/tmp/mesa-native
meson setup $tools \
    -Dvulkan-drivers= -Dgallium-drivers= -Dshader-cache=true -Dplatforms= \
    -Dglx=disabled -Degl=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
    -Dtools=[] -Dllvm=enabled -Dmesa-clc=enabled -Dprecomp-compiler=enabled -Dinstall-mesa-clc=true
ninja -C $tools src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2
export PATH="$tools/src/compiler/clc:$tools/src/compiler/spirv:$PATH"
# Rust for the Switch is AArch64 ELF whatever machine builds the image (see
# switch-dev's mesa/build.sh).
export MESA_SWITCH_RUST_TARGET=aarch64-unknown-linux-gnu

meson setup /tmp/mesa-build \
    --cross-file switch_cross_file.txt \
    --default-library=static \
    --prefix=$portlibs \
    --libdir=lib \
    --buildtype=release \
    -Doptimization=2 \
    -Db_lto=false \
    -Db_ndebug=true \
    -Dvulkan-drivers=nouveau \
    -Dgallium-drivers= \
    -Dgallium-rusticl=false \
    -Dplatforms=switch \
    -Dglx=disabled \
    -Degl=disabled \
    -Dopengl=false \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dvideo-codecs= \
    -Dshader-cache=enabled \
    -Dxmlconfig=enabled \
    -Dexpat=enabled \
    -Dtools=[] \
    -Dllvm=disabled \
    -Dshared-glapi=disabled \
    -Dshared-llvm=disabled \
    -Dmesa-clc=system \
    -Dprecomp-compiler=system \
    -Dcpp_rtti=false \
    -Dbuild-tests=false
ninja -C /tmp/mesa-build
meson install -C /tmp/mesa-build --no-rebuild --destdir "$stage"
# The legacy Mesa's drirc defaults stay; NVK has its own 00-nvk-defaults.conf.
rm -f "$staged/share/drirc.d/00-mesa-defaults.conf"
# The legacy OpenGL (Mesa 20.1) and NVK (Mesa 26) are two Mesas with the same
# internals -- blob_*, nir_*, util_* and more -- so one program linking both
# gets duplicate symbols, or worse, one Mesa calling the other's version.
# Rename every global NVK defines that the legacy OpenGL libraries also define,
# in libvulkan.a only (the archive a Vulkan program links): its own objects
# then reference the renamed copies, and the vk* API is untouched.
defs() { aarch64-none-elf-nm -g --defined-only "$@" 2>/dev/null | awk 'NF == 3 { print $3 }' | sort -u; }
legacy_gl=()
for l in libEGL.a libGLESv2.a libGLESv1_CM.a libglapi.a libdrm_nouveau.a; do
    [ -f $portlibs/lib/$l ] && legacy_gl+=($portlibs/lib/$l)
done
defs "${legacy_gl[@]}" > /tmp/legacy-gl-syms
defs "$staged/lib/libvulkan.a" > /tmp/nvk-syms
comm -12 /tmp/legacy-gl-syms /tmp/nvk-syms | awk '{ print $1, "mesa_nvk_" $1 }' > /tmp/nvk-renames
if grep -E '^(vk|_?vk_icd)' /tmp/nvk-renames; then
    echo 'a Vulkan entry point clashes with the legacy OpenGL' >&2; exit 1
fi
echo "Renaming $(wc -l < /tmp/nvk-renames) NVK symbols the legacy OpenGL also defines"
aarch64-none-elf-objcopy --redefine-syms=/tmp/nvk-renames "$staged/lib/libvulkan.a"
defs "$staged/lib/libvulkan.a" | comm -12 /tmp/legacy-gl-syms - > /tmp/nvk-still
[ ! -s /tmp/nvk-still ] || { echo "still shared: $(head -5 /tmp/nvk-still)" >&2; exit 1; }
install -Dm644 /tmp/nvk-renames "$staged/share/mesa-switch/nvk-renamed-symbols.txt"
rm -f /tmp/legacy-gl-syms /tmp/nvk-syms /tmp/nvk-renames /tmp/nvk-still

# Index every member with devkitA64's ranlib, the Rust std ones included
# (Debian's ar leaves them out; see switch-dev's mesa/build.sh).
find "$staged/lib" -name '*.a' -exec aarch64-none-elf-ranlib {} \;
aarch64-none-elf-nm --print-armap "$staged/lib/libvulkan.a" > /tmp/vulkan-armap
awk '/^Archive index:/ { index_ = 1; next } /^$/ { if (index_) exit }
     index_ && /4core9panicking9panic_fmt / { found = 1 } END { exit !found }' /tmp/vulkan-armap ||
    { echo 'libvulkan.a has no index for Rust core' >&2; exit 1; }
rm /tmp/vulkan-armap
mkdir /tmp/vulkan-members && (cd /tmp/vulkan-members && aarch64-none-elf-ar x "$staged/lib/libvulkan.a")
wrong="$(cd /tmp/vulkan-members && for o in *.o; do
    readelf -h "$o" | grep -q 'Machine:.*AArch64' || echo "$o"; done | head -5)"
rm -rf /tmp/vulkan-members
[ -z "$wrong" ] || { echo "libvulkan.a has objects that are not AArch64: $wrong" >&2; exit 1; }
# A program builds against portlibs alone, Vulkan headers included.
cp -r include/vulkan include/vk_video "$staged/include/"
mkdir -p "$staged/share/licenses/mesa-switch"
cp docs/license.rst "$staged/share/licenses/mesa-switch/"
rm -rf /tmp/mesa-native /tmp/mesa-build /tmp/stub_posix.*
