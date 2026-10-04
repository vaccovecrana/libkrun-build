#!/usr/bin/env bash
#
# build-libkrun.sh
#
# Fetch the latest `main` snapshots of libkrun and libkrunfw as source
# archives (tarballs, NOT git clones) and build them, staging the results
# into ./out. Nothing is installed system-wide unless --install is given.
#
# Local patches under ./patches/*.patch are applied to the fetched libkrun
# tree (before compiling) via `patch -p1`. They must be `-p1` diffs rooted at
# the libkrun source tree root. A patch that is already present is skipped,
# so re-runs with --no-fetch are idempotent; any rejected hunk aborts the
# build (die), never a silent unpatched build.
#
# NOTE: this script intentionally targets the libkrun 2.0 API (the
# builder-style krun_vmm_builder_* interface). The `ffi` feature is ALWAYS
# enabled so the C API symbols are exported for FFI/JNI/Panama consumers
# (e.g. a custom Java micro-VM management application). It is not intended
# for crun/podman, which use the 1.x API.
#
# Target platform: Debian 13 (trixie), x86_64, baseline x86-64
# (Sandy Bridge-EN / Ivy Bridge-EN and newer). The Rust build is pinned to
# `-C target-cpu=x86-64` and the bundled guest kernel already uses
# CONFIG_GENERIC_CPU=y, so the artifacts carry no AVX/AVX2/FMA requirement.
#
# Usage:
#   ./build-libkrun.sh [options]
#
# Options:
#   --isa v1|v2     Rust target-cpu baseline. v1 (default) = x86-64.
#                   v2 = x86-64-v2 (still Sandy Bridge-safe, slightly faster).
#   --jobs N        Parallel build jobs (default: nproc).
#   --skip-fw       Do not build libkrunfw (libkrun only).
#   --no-apt        Skip apt-get package installation.
#   --no-verify     Skip the post-build baseline/artifact verification.
#   --install       Also `sudo make install` into /usr/local.
#   --clean         Remove src/, out/ and .tmp/ before starting.
#   --no-fetch      Reuse existing src/ trees (skip re-download of archives).
#   --no-patch      Do not apply patches/*.patch to the libkrun tree.
#   -h, --help      Show this help.
#
# Output:
#   out/lib64/                    libkrun + libkrun-init + headers + .pc
#   out/lib/x86_64-linux-gnu/     libkrunfw
#
# Runtime use of the staged tree:
#   export LD_LIBRARY_PATH="$PWD/out/lib64:$PWD/out/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
#   export PKG_CONFIG_PATH="$PWD/out/lib64/pkgconfig:$PKG_CONFIG_PATH"
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out"
TMP="$ROOT/.tmp"
PATCHES="$ROOT/patches"

LIBKRUN_REPO="libkrun/libkrun"
LIBKRUNFW_REPO="containers/libkrunfw"
REF="main"

ISA="v1"
JOBS="$(nproc)"
DO_APT=1
DO_FW=1
DO_VERIFY=1
DO_INSTALL=0
DO_CLEAN=0
DO_FETCH=1
DO_PATCH=1

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[1;34m'; C_WARN=$'\033[1;33m'
    C_ERR=$'\033[1;31m'; C_OK=$'\033[1;32m'
else
    C_RESET=; C_INFO=; C_WARN=; C_ERR=; C_OK=
fi
log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
die()  { printf '%s[error]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    awk 'NR>=3 && /^#/ { sub(/^# ?/, ""); print; next } NR>=3 { exit }' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --isa)      ISA="${2:-}"; shift 2 ;;
        --jobs)     JOBS="${2:-}"; shift 2 ;;
        --skip-fw)  DO_FW=0; shift ;;
        --no-apt)   DO_APT=0; shift ;;
        --no-verify) DO_VERIFY=0; shift ;;
        --install)  DO_INSTALL=1; shift ;;
        --clean)    DO_CLEAN=1; shift ;;
        --no-fetch) DO_FETCH=0; shift ;;
        --no-patch) DO_PATCH=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown option: $1 (try --help)" ;;
    esac
done

case "$ISA" in
    v1) ISA_CPU="x86-64" ;;
    v2) ISA_CPU="x86-64-v2" ;;
    *)  die "--isa must be v1 or v2 (got: $ISA)" ;;
esac

case "$JOBS" in
    ''|*[!0-9]*) die "--jobs must be a positive integer (got: $JOBS)" ;;
esac

# Make feature variables for libkrun. blk/net for block/net devices; ffi is
# always on so the 2.0 C API symbols are exported for FFI/JNI/Panama consumers.
MAKE_FEATURES=(BLK=1 NET=1 FFI=1)

# ---------------------------------------------------------------- preflight
preflight() {
    log "Preflight checks"

    [ "$(uname -s)" = "Linux" ] || die "this script only supports Linux"

    ARCH="$(uname -m)"
    if [ "$ARCH" != "x86_64" ]; then
        die "this build targets x86_64 (host is $ARCH)"
    fi

    if [ -f /etc/debian_version ]; then
        ok "Debian $(cat /etc/debian_version)"
    else
        warn "not a Debian system; package list may be wrong"
    fi

    if ! grep -qm1 -E '(^flags|^Features).*(vmx|svm)' /proc/cpuinfo; then
        warn "no vmx/svm flag found: KVM may be unavailable on this host"
    fi
    if [ ! -e /dev/kvm ]; then
        warn "/dev/kvm is missing: libkrun will not run until KVM is available"
    else
        ok "/dev/kvm present"
    fi

    AV_FREE="$(df -Pk "$ROOT" | awk 'NR==2 {print int($4/1024)}')"
    if [ "$AV_FREE" -lt 5120 ]; then
        warn "only ${AV_FREE} MiB free under $ROOT (kernel build needs several GiB)"
    fi

    ok "host: $ARCH, $JOBS jobs, ${AV_FREE} MiB free, ISA baseline: $ISA_CPU"
}

# ---------------------------------------------------------------- packages
# Run a command through sudo. If SUDOPW is set in the environment, feed it to
# `sudo -S` so package installation is non-interactive (the value is never
# printed or logged).
sudo_run() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif [ -n "${SUDOPW:-}" ]; then
        printf '%s\n' "$SUDOPW" | sudo -S -p '' "$@"
    else
        sudo "$@"
    fi
}

install_deps() {
    log "Installing build dependencies (apt)"
    export DEBIAN_FRONTEND=noninteractive
    sudo_run apt-get update
    sudo_run apt-get install -y \
        build-essential bc flex bison libelf-dev python3-pyelftools \
        patchelf libclang-dev libc6-dev pkg-config curl xz-utils cpio musl-tools
}

# ---------------------------------------------------------------- rust
ensure_rust() {
    export PATH="$HOME/.cargo/bin:$PATH"
    if ! command -v rustup >/dev/null 2>&1; then
        log "Installing rustup (stable, minimal profile)"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain stable --profile minimal
    else
        log "Updating rustup stable toolchain"
        rustup update stable >/dev/null 2>&1 || warn "rustup update failed; using existing toolchain"
    fi
    rustup default stable >/dev/null 2>&1 || true
    rustup component add rustfmt >/dev/null 2>&1 || warn "could not install the rustfmt component (needed by ffier codegen)"
    rustup target add "$(uname -m)-unknown-linux-musl" >/dev/null 2>&1 \
        || warn "could not add the musl target (needed by krun-init-blob)"
    ok "rustc $(rustc --version | awk '{print $2}'), cargo $(cargo --version | awk '{print $2}')"
}

# ---------------------------------------------------------------- fetch
# Download a GitHub source archive for a branch and extract it under $SRC.
fetch_snapshot() {
    local repo="$1" dest="$2" name url tarball top=""
    name="${repo##*/}"
    url="https://codeload.github.com/${repo}/tar.gz/refs/heads/${REF}"

    log "Fetching ${repo}@${REF} snapshot (no git history)"
    mkdir -p "$SRC" "$TMP"
    tarball="$TMP/${name}-${REF}.tar.gz"

    rm -rf "$dest"
    curl -fL --retry 3 --retry-delay 2 -o "$tarball" "$url"
    tar -xzf "$tarball" -C "$SRC"

    top="$SRC/${name}-${REF}"
    [ -d "$top" ] || top="$(find "$SRC" -maxdepth 1 -mindepth 1 -type d -name "${name}-*" | head -1)"
    [ -n "$top" ] && [ -d "$top" ] || die "could not locate extracted directory for ${repo}"
    mv "$top" "$dest"
    ok "$(basename "$dest") -> $dest"
}

fetch_all() {
    fetch_snapshot "$LIBKRUN_REPO" "$SRC/libkrun"
    if [ "$DO_FW" -eq 1 ]; then
        fetch_snapshot "$LIBKRUNFW_REPO" "$SRC/libkrunfw"
    fi
}

# ---------------------------------------------------------------- patches
# Apply local patches/*.patch (in lexical order) to the fetched libkrun tree.
# The patch is first tested in reverse: a clean reverse-apply means it is
# already present (e.g. --no-fetch reusing a patched tree), so it is skipped.
# Any other outcome is applied with --forward; a rejected hunk is fatal.
apply_patches() {
    [ "$DO_PATCH" -eq 1 ] || { log "Skipping patches (--no-patch)"; return; }

    local dir="$SRC/libkrun"
    [ -d "$dir" ] || die "patch target missing: $dir"

    shopt -s nullglob
    local patches=("$PATCHES"/*.patch)
    shopt -u nullglob
    if [ "${#patches[@]}" -eq 0 ]; then
        log "No patches to apply ($PATCHES/*.patch)"
        return
    fi

    local p
    for p in "${patches[@]}"; do
        if patch -p1 --dry-run -R -d "$dir" < "$p" >/dev/null 2>&1; then
            ok "already applied, skipping: $(basename "$p")"
            continue
        fi
        log "Applying patch: $(basename "$p")"
        if ! patch -p1 --forward --reject-file=- -d "$dir" < "$p"; then
            die "patch failed (rejected hunks): $(basename "$p")"
        fi
        ok "applied: $(basename "$p")"
    done
}

# ---------------------------------------------------------------- libclang
# bindgen (via clang-sys) needs a discoverable libclang.so. Debian's `clang`
# package only ships versioned runtime libs (e.g. libclang-19.so.19), which
# clang-sys does not match. Debian's `libclang-dev` provides the unversioned
# libclang.so; when it is absent we synthesize a libclang.so symlink in a
# build-local directory and point LIBCLANG_PATH at it.
ensure_libclang() {
    if ldconfig -p 2>/dev/null | grep -qE 'libclang\.so'; then
        ok "system libclang discoverable"
    else
        local lib
        lib="$(find /usr/lib -maxdepth 4 \
                \( -name 'libclang-[0-9]*.so*' -o -name 'libclang.so.[0-9]*' \) 2>/dev/null \
              | grep -vE 'clang_rt|libclang-cpp' | sort -V | tail -1 || true)"

        if [ -z "$lib" ]; then
            warn "no libclang shared library found; install 'libclang-dev' or set LIBCLANG_PATH"
        else
            mkdir -p "$TMP/libclang"
            ln -sf "$lib" "$TMP/libclang/libclang.so"
            export LIBCLANG_PATH="$TMP/libclang"
            ok "using libclang: $lib"
        fi
    fi

    if ! command -v llvm-config >/dev/null 2>&1; then
        local lc
        lc="$(ls -1 /usr/bin/llvm-config-[0-9]* 2>/dev/null | sort -V | tail -1 || true)"
        [ -n "$lc" ] && export LLVM_CONFIG_PATH="$lc"
    fi
}

# ---------------------------------------------------------------- builds
build_libkrunfw() {
    log "Building libkrunfw (bundled Linux kernel; this takes a while)"
    make -C "$SRC/libkrunfw" -j"$JOBS"
    log "Installing libkrunfw into $OUT"
    make -C "$SRC/libkrunfw" install PREFIX="$OUT"
    ok "libkrunfw built"
}

build_libkrun() {
    log "Building libkrun with ${MAKE_FEATURES[*]} (target-cpu=$ISA_CPU)"
    ensure_libclang
    export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C target-cpu=$ISA_CPU"
    make -C "$SRC/libkrun" "${MAKE_FEATURES[@]}" PREFIX="$OUT" -j"$JOBS"
    log "Installing libkrun into $OUT"
    make -C "$SRC/libkrun" "${MAKE_FEATURES[@]}" PREFIX="$OUT" install
    ok "libkrun built"
}

system_install() {
    log "Installing into /usr/local (sudo)"
    sudo_run make -C "$SRC/libkrun" "${MAKE_FEATURES[@]}" install
    if [ "$DO_FW" -eq 1 ]; then
        sudo_run make -C "$SRC/libkrunfw" install
    fi
    ok "system install complete"
}

# ---------------------------------------------------------------- verify
verify() {
    log "Verifying artifacts are x86-64 baseline safe"
    local f props rc=0

    for f in "$OUT"/lib64/libkrun.so.* "$OUT"/lib64/libkrun_init.so.* \
             "$OUT"/lib/x86_64-linux-gnu/libkrunfw.so.*; do
        [ -e "$f" ] || continue
        props="$(readelf -n "$f" 2>/dev/null | grep -i 'ISA needed' || true)"
        printf '  %-28s %s\n' "$(basename "$f")" "${props:-no ISA property note}"
        case "$props" in
            *x86-64-v3*|*x86-64-v4*) warn "  ^ requires newer than target baseline!"; rc=1 ;;
        esac
    done

    local nsyms
    nsyms="$(nm -D "$OUT/lib64/libkrun.so.2.0.0" 2>/dev/null | grep -c ' T krun_' || true)"
    if [ "${nsyms:-0}" -gt 0 ]; then
        ok "libkrun exports $nsyms krun_* symbols (2.0 C API present)"
    else
        warn "libkrun exports no krun_* symbols; FFI=1 build expected"; rc=1
    fi

    local kcfg
    kcfg="$(find "$SRC/libkrunfw" -maxdepth 2 -name '.config' -path 'linux-*' 2>/dev/null | head -1 || true)"
    if [ -n "$kcfg" ]; then
        if grep -qE '^CONFIG_GENERIC_CPU=y' "$kcfg"; then
            ok "guest kernel config uses CONFIG_GENERIC_CPU=y"
        else
            warn "guest kernel config is not GENERIC_CPU; check $kcfg"; rc=1
        fi
    elif [ "$DO_FW" -eq 1 ]; then
        warn "guest kernel .config not found for verification"
    fi

    [ "$rc" -eq 0 ] && ok "baseline verification passed" || warn "baseline verification reported issues above"
}

summary() {
    echo
    log "Build complete"
    echo "  Artifacts:   $OUT"
    find "$OUT" -maxdepth 3 -type f \( -name '*.so*' -o -name '*.pc' -o -name '*.h' \) \
        | sort | sed 's/^/    /' || true
    echo
    echo "  Use at runtime:"
    echo "    export LD_LIBRARY_PATH=\"$OUT/lib64:$OUT/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH\""
    echo "    export PKG_CONFIG_PATH=\"$OUT/lib64/pkgconfig:\$PKG_CONFIG_PATH\""
    echo
    echo "  Note: this builds the libkrun 2.0 API (builder-style"
    echo "  krun_vmm_builder_*). FFI is always enabled, so the exported C API"
    echo "  is ready for FFI/JNI/Panama consumers such as a Java micro-VM"
    echo "  manager. Host-directory volumes use the built-in virtio-fs support."
}

# ---------------------------------------------------------------- main
main() {
    log "libkrun build"
    preflight

    if [ "$DO_CLEAN" -eq 1 ]; then
        log "Cleaning src/, out/, .tmp/"
        rm -rf "$SRC" "$OUT" "$TMP"
    fi

    if [ "$DO_APT" -eq 1 ]; then install_deps; fi
    ensure_rust
    if [ "$DO_FETCH" -eq 1 ]; then
        fetch_all
    else
        [ -d "$SRC/libkrun" ] || die "--no-fetch: $SRC/libkrun does not exist"
        [ "$DO_FW" -eq 0 ] || [ -d "$SRC/libkrunfw" ] || die "--no-fetch: $SRC/libkrunfw does not exist"
        log "Reusing existing sources (--no-fetch)"
    fi
    apply_patches
    if [ "$DO_FW" -eq 1 ]; then build_libkrunfw; fi
    build_libkrun
    if [ "$DO_VERIFY" -eq 1 ]; then verify; fi
    if [ "$DO_INSTALL" -eq 1 ]; then system_install; fi
    summary
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
