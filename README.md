# switch-dev

A Docker image for building Horizon (Nintendo Switch) homebrew: devkitA64 with
everything [Autorun](https://github.com/autorunhq/autorun) builds against,
each from a pinned revision, and the tools to build more.

| In portlibs | Revision | |
|---|---|---|
| [libnx](https://github.com/switchbrew/libnx) | `146c3d14` | newer than devkitPro's 4.12.0 release |
| [mesa-switch](https://github.com/danfromtico/mesa-switch) | `0ff52079` | Mesa 26: EGL, OpenGL and GLES through nvc0 or Zink (OpenGL on NVK, picked with `MESA_SWITCH_GL_DRIVER`), and loaderless NVK Vulkan, over a Horizon backend written against libnx. Replaces devkitPro's Mesa 20.1 and libdrm_nouveau. |
| [lsfg-vk](https://git.lsfg-vk.dev/lsfg-vk-archive.git) | `8b0da266` | the last GPL archive revision, with the Horizon port in `lsfg/`: `liblsfg-vk.a` |
| [libusbhsfs](https://github.com/ITotalJustice/libusbhsfs) | `625269b7` | with the UASP transport in `libusbhsfs/`, FAT and exFAT only: `libusbhsfs.a` |

Tools: CMake, Ninja, Meson 1.12, glslang, SPIRV-Tools 1.3.290, LLVM/Clang 15,
Rust `nightly-2026-09-08` with rust-src, bindgen and cbindgen, and hactool
1.4.0.

`/opt/devkitpro-release` is the same toolchain with devkitPro's released
libnx (4.12.0), for projects pinned to it such as Atmosphère: build them with
`DEVKITPRO=/opt/devkitpro-release`.

`/opt/devkitpro/cmake/switch-dev.cmake` is the CMake toolchain lsfg-vk and
libusbhsfs are built with. It leaves x18 alone, as Wine on Horizon needs.
`/opt/devkitpro/portlibs/switch/share/switch-dev.json` lists the revisions,
and so do the image's labels.

## Use

```sh
docker run --rm -v "$PWD:/work" ghcr.io/danfromtico/switch-dev make
```

The image is built for `linux/amd64` and `linux/arm64`, each natively on its
own runner.

## Build

```sh
docker build --platform linux/arm64 -t ghcr.io/danfromtico/switch-dev .
```

To change a revision, edit its `ARG` in the `Dockerfile`.

Pushing a tag named for the day it is cut, such as `2026.09.28`, builds the
image on GitHub's amd64 and arm64 runners and publishes it as
`ghcr.io/danfromtico/switch-dev:2026.09.28` and `:latest`
(`.github/workflows/publish.yml`).

## Legacy OpenGL with Vulkan

`Dockerfile.legacy-vulkan` builds a second image on
[switch-dev-legacy](https://github.com/danfromtico/switch-dev-legacy):
its OpenGL (devkitPro's Mesa 20.1 through nvc0, and libdrm_nouveau) stays as
it is, and mesa-switch's NVK is built beside it, Vulkan only
(`mesa/build-vulkan.sh`). One program can link both and pick its renderer at
run time: the Mesa internals NVK shares with the legacy OpenGL are renamed
`mesa_nvk_*` in `libvulkan.a`, and the list is installed as
`share/mesa-switch/nvk-renamed-symbols.txt`.

```sh
docker build -f Dockerfile.legacy-vulkan -t switch-dev-legacy-vulkan .
```

Pushing a tag such as `legacy-vulkan-2026.10.12` publishes
`ghcr.io/danfromtico/switch-dev-legacy-vulkan:2026.10.12` and `:latest`
(`.github/workflows/publish-legacy-vulkan.yml`).

## Licenses

The Dockerfile and build scripts are MIT. What the image builds keeps its own
license, installed under `portlibs/switch/share/licenses`:
- mesa-switch is MIT.
- lsfg-vk and the port in `lsfg/` are GPL-3.0-or-later.
- libusbhsfs is ISC as built here (no NTFS or ext4).
