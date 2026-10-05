#!/bin/bash
# Build mesa-switch (Mesa 26 for Horizon: EGL and OpenGL through Gallium nvc0
# or Zink, and loaderless NVK Vulkan, over the port's own Horizon backend) from the
# checkout in the current directory, and install it into portlibs. OpenGL and
# Vulkan come from one Meson build, so a program links one copy of Mesa for both.
set -euo pipefail
portlibs=/opt/devkitpro/portlibs/switch

# What mesa-switch's build-switch.sh sets up in its container: the cross
# wrappers for bindgen and rustc, the Nouveau header NAK's bindgen reads, the
# Clang header path mesa_clc uses, and placeholder libdl, librt and libutil
# for Rust std (rust_switch_stubs.c has the symbols). The Switch OpenGL winsys
# carries the libdrm_nouveau headers it implements, so none are installed.
mkdir -p /usr/local/libexec
cp bindgen-switch-wrapper.sh /usr/local/libexec/bindgen
cp rustc-switch-wrapper.sh /usr/local/libexec/rustc
cp bindgen-atomic-shim.h /usr/local/libexec/bindgen-atomic-shim.h
sed -i 's/\r$//' /usr/local/libexec/bindgen /usr/local/libexec/rustc
chmod +x /usr/local/libexec/bindgen /usr/local/libexec/rustc
cp -p src/nouveau/headers/nv_device_info.h $portlibs/include/
[ -d /usr/lib/llvm-15/lib/clang/15/include ] ||
    ln -sf /usr/lib/llvm-15/lib/clang/15.0.6/include /usr/lib/llvm-15/lib/clang/15/include
echo 'void __mesa_switch_stub_lib(void) {}' > /tmp/stub_posix.c
aarch64-none-elf-gcc -c /tmp/stub_posix.c -o /tmp/stub_posix.o
for l in dl rt util; do
    aarch64-none-elf-ar rcs $portlibs/lib/lib$l.a /tmp/stub_posix.o
done

# The host tools the cross build runs.
tools=/tmp/mesa-native
meson setup $tools \
    -Dvulkan-drivers= -Dgallium-drivers= -Dshader-cache=true -Dplatforms= \
    -Dglx=disabled -Degl=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
    -Dtools=[] -Dllvm=enabled -Dmesa-clc=enabled -Dprecomp-compiler=enabled -Dinstall-mesa-clc=true
ninja -C $tools src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2
export PATH="$tools/src/compiler/clc:$tools/src/compiler/spirv:$PATH"
# Rust for the Switch is AArch64 ELF whatever machine builds the image: the
# cross file's rustc wrapper takes its target from here, and without one it
# compiles for the build machine, which on amd64 put x86-64 objects in
# libvulkan.a. The wrapper stays out of PATH, so Mesa's proc-macro crates
# (native: true) are built by the real rustc for the machine they run on.
export MESA_SWITCH_RUST_TARGET=aarch64-unknown-linux-gnu

# build-unified.sh's options: EGL/OpenGL with both Gallium drivers, nvc0 and
# Zink (OpenGL on NVK), and NVK. A program picks the GL driver at run time
# with MESA_SWITCH_GL_DRIVER=nvc0|zink before its first eglGetDisplay.
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
    -Dgallium-drivers=nouveau,zink \
    -Dgallium-rusticl=false \
    -Dplatforms=switch \
    -Degl-native-platform=switch \
    -Dglx=disabled \
    -Degl=enabled \
    -Dopengl=true \
    -Dgles1=enabled \
    -Dgles2=enabled \
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
meson install -C /tmp/mesa-build --no-rebuild
# nvk_archive_merge.py merges libvulkan.a with Debian's ar, which cannot read
# the Rust std members and leaves their symbols out of the index, so ld then
# misses core and alloc. devkitA64's ranlib indexes every member.
# libvulkan.a is merged at install time, outside Meson's install log, so every
# archive in portlibs is indexed again; that is harmless for the others.
find $portlibs/lib -name '*.a' -exec aarch64-none-elf-ranlib {} \;
aarch64-none-elf-nm --print-armap $portlibs/lib/libvulkan.a > /tmp/vulkan-armap
awk '/^Archive index:/ { index_ = 1; next } /^$/ { if (index_) exit }
     index_ && /4core9panicking9panic_fmt / { found = 1 } END { exit !found }' /tmp/vulkan-armap ||
    { echo 'libvulkan.a has no index for Rust core' >&2; exit 1; }
rm /tmp/vulkan-armap
# And every object in it, the Rust ones included, is AArch64.
mkdir /tmp/vulkan-members && (cd /tmp/vulkan-members && aarch64-none-elf-ar x $portlibs/lib/libvulkan.a)
wrong="$(cd /tmp/vulkan-members && for o in *.o; do
    readelf -h "$o" | grep -q 'Machine:.*AArch64' || echo "$o"; done | head -5)"
rm -rf /tmp/vulkan-members
[ -z "$wrong" ] || { echo "libvulkan.a has objects that are not AArch64: $wrong" >&2; exit 1; }
# A program builds against portlibs alone, Vulkan headers included.
cp -r include/vulkan include/vk_video $portlibs/include/
mkdir -p $portlibs/share/licenses/mesa-switch
cp docs/license.rst $portlibs/share/licenses/mesa-switch/
rm -rf /tmp/mesa-native /tmp/mesa-build /tmp/stub_posix.*
