# libkrun-build

A self-contained, reproducible build of [libkrun](https://github.com/libkrun/libkrun)
and [libkrunfw](https://github.com/containers/libkrunfw) for **x86_64 Linux**,
targeting the libkrun **2.0** API (the builder-style `krun_vmm_builder_*`
interface) with the `ffi` feature always enabled so the C API symbols are
exported for FFI/JNI/Panama consumers.

This repo exists to produce the native libraries that
[**frag-falcon**](https://github.com/vaccovecrana/frag-falcon) vendors and loads at
runtime, with local patches applied to the upstream sources. It is **not** intended
for crun/podman, which use the libkrun 1.x API.

## What it does

`build-libkrun.sh` fetches the latest `main` snapshots of libkrun and libkrunfw as
source archives (tarballs, not git clones), applies the patches under `patches/`,
then builds and stages everything into `./out`. Nothing is installed system-wide
unless `--install` is given.

```
src/        fetched libkrun + libkrunfw source trees (gitignored, regenerated)
patches/    *.patch applied to the fetched libkrun tree before compiling
out/        staged build artifacts (gitignored)
.tmp/       download / build scratch space (gitignored)
```

Output:

- `out/lib64/` — libkrun + libkrun-init shared objects, headers, and `.pc` files
- `out/lib/x86_64-linux-gnu/` — libkrunfw

## Usage

```bash
./build-libkrun.sh [options]
```

| Option          | Description                                                       |
| --------------- | ----------------------------------------------------------------- |
| `--isa v1\|v2`  | Rust target-cpu baseline. `v1` (default) = `x86-64`; `v2` = `x86-64-v2`. |
| `--jobs N`      | Parallel build jobs (default: `nproc`).                           |
| `--skip-fw`     | Do not build libkrunfw (libkrun only).                            |
| `--no-apt`      | Skip `apt-get` package installation.                              |
| `--no-verify`   | Skip the post-build baseline/artifact verification.               |
| `--install`     | Also `sudo make install` into `/usr/local`.                       |
| `--clean`       | Remove `src/`, `out/` and `.tmp/` before starting.                |
| `--no-fetch`    | Reuse existing `src/` trees (skip re-download of archives).       |
| `--no-patch`    | Do not apply `patches/*.patch` to the libkrun tree.               |
| `-h`, `--help`  | Show help.                                                        |

Using the staged tree at runtime:

```bash
export LD_LIBRARY_PATH="$PWD/out/lib64:$PWD/out/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export PKG_CONFIG_PATH="$PWD/out/lib64/pkgconfig:$PKG_CONFIG_PATH"
```

## Patches

Patches live in `patches/` and are applied with `patch -p1` to the fetched
`src/libkrun` tree **before compiling**. They must be `-p1` diffs rooted at the
libkrun source-tree root (the Rust sources).

The build is idempotent: a patch that is already present is skipped, so
`--no-fetch` re-runs are safe. Any rejected hunk **aborts the build** — a silently
unpatched tree is never produced. Use `--no-patch` to build pristine upstream.

Current patches:

- `libkrun-dhcp-retry.patch` — makes the guest init's DHCP client retransmit
  `DISCOVER` every 250 ms for an 8 s window and ignore duplicate `OFFER`s during the
  `REQUEST`/`ACK` step. A raw TAP/bridge can take a moment to start forwarding after
  the VM boots, so upstream's single-shot request is easily lost; this covers that
  warm-up window. See frag-falcon's `CAVEATS.md` §1.

## Target platform

Debian 13 (trixie), x86_64, baseline x86-64 (Sandy Bridge-EN / Ivy Bridge-EN and
newer). The Rust build is pinned to `-C target-cpu=x86-64` and the bundled guest
kernel uses `CONFIG_GENERIC_CPU=y`, so the artifacts carry no AVX/AVX2/FMA
requirement.
