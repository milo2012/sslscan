#!/usr/bin/env bash
#
# build.sh - Build sslscan for Linux or macOS.
#
# Wraps the Makefile targets ('make' for a dynamic build, 'make static' for a
# statically-linked OpenSSL build) and adds hermetic static builds for Linux,
# including cross-compilation (e.g. build an amd64 binary on an arm64 host).
#
# Examples:
#   ./build.sh                                        # native static build (recommended)
#   ./build.sh --dynamic                              # native dynamic build (needs system OpenSSL dev files)
#   ./build.sh --fully-static                         # native fully static binary (Linux only)
#   ./build.sh --os linux --arch amd64 --fully-static # fully static amd64 binary, built on any Linux host
#   ./build.sh --os linux --arch arm64                # arm64 binary with static OpenSSL, built on any Linux host
#   ./build.sh --os mac                               # native macOS build (run on a Mac)
#   ./build.sh --rebuild                              # force rebuild of bundled zlib/OpenSSL
#   ./build.sh --clean                                # remove the build/ working directory
#   ./build.sh --distclean                            # 'make realclean': remove ./openssl and sslscan
#
# macOS troubleshooting: if the final link fails with "tapi error: malformed
# file" / "unknown architecture" in an SDK .tbd file, your Xcode linker is
# older than the installed CommandLineTools SDK (mixed toolchain). Fix with
# either:
#   sudo xcode-select --switch /Library/Developer/CommandLineTools
# or update Xcode to the latest release and:
#   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
# then run './build.sh --distclean' and rebuild with './build.sh'.
#
# Cross-compiling to macOS from Linux (or vice versa) is NOT supported by
# this script. macOS builds must run on a Mac.
#
# Requirements per path (the script checks and tells you what to install):
#   native dynamic:  C compiler, make, git, perl, OpenSSL headers
#                    (Debian/Ubuntu: apt install build-essential git perl libssl-dev)
#                    (macOS: Xcode CLT, and brew install openssl for the headers)
#   native static:   C compiler, make, git, perl (everything else is built from source)
#   hermetic (any --fully-static, or any Linux cross build):
#                    Linux host, C compiler (native or cross), perl, make, git,
#                    curl, ca-certificates. zlib + OpenSSL for the target are
#                    built from source into build/.
#                    Cross toolchains on Debian/Ubuntu, e.g. for amd64:
#                    apt install gcc-x86-64-linux-gnu libc6-dev-amd64-cross
#                    (or re-run with --install-deps as root).
#
# Compatible with bash 3.2 (macOS system bash) and newer.

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
TARGET_OS="auto"        # auto | linux | mac
TARGET_ARCH="native"    # native | amd64 | arm64
LINK_MODE="static"      # dynamic | static | fully-static
JOBS="auto"
OUTPUT=""               # default name is derived from target + mode
REBUILD="no"
INSTALL_DEPS="no"
CLEAN="no"
DISTCLEAN="no"
OPENSSL_TAG=""          # e.g. openssl-3.5.8; empty = newest openssl-3.5.x
OPENSSL_TAG_FALLBACK="openssl-3.5.8"
ZLIB_VERSION="1.3.1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
usage() {
    sed -n '2,/^# Compatible/p' "$0" | sed 's/^# \?//'
    echo ""
    echo "Options:"
    echo "  --os <linux|mac|auto>       Target OS (default: auto = host OS)"
    echo "  --arch <amd64|arm64|native> Target architecture (default: native)"
    echo "  --static                    Statically link OpenSSL (default). Recommended:"
    echo "                              enables weak-cipher checks missing from distro OpenSSL."
    echo "  --dynamic                   Link against system OpenSSL (native builds only, fast)."
    echo "  --fully-static              Fully static binary via -static (Linux only)."
    echo "  --jobs <n>                  Parallel build jobs (default: CPU count)."
    echo "  --output <file>             Output binary path (default: derived name in repo root)."
    echo "  --builddir <dir>            Working dir for zlib/OpenSSL sources (default: ./build)."
    echo "  --openssl-tag <tag>         OpenSSL git tag, e.g. openssl-3.5.8 (default: newest 3.5.x)."
    echo "  --zlib-version <ver>        zlib version tarball to use (default: 1.3.1)."
    echo "  --install-deps              apt-get install missing cross toolchain (Debian/Ubuntu, as root)."
    echo "  --rebuild                   Force rebuild of bundled zlib/OpenSSL even if present."
    echo "  --clean                     Remove the build working directory and exit."
    echo "  --distclean                 Run 'make realclean' (removes ./openssl and sslscan) and exit."
    echo "                              Use after switching Xcode/CLT toolchains on macOS."
    echo "  --help                      Show this help (also echoed from the script header above)."
}

die() {
    echo "build.sh: ERROR: $*" >&2
    exit 1
}

info() {
    echo "build.sh: $*"
}

cpu_count() {
    if [ "$JOBS" != "auto" ]; then
        echo "$JOBS"
        return
    fi
    if command -v nproc >/dev/null 2>&1; then
        nproc
    else
        sysctl -n hw.ncpu 2>/dev/null || echo 4
    fi
}

host_os() {
    case "$(uname)" in
        Linux) echo "linux" ;;
        Darwin) echo "mac" ;;
        *) uname ;;
    esac
}

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) uname -m ;;
    esac
}

git_version() {
    # Mirrors the Makefile: git tag, else Changelog, always with -static suffix.
    local ver=""
    if git -C "$SCRIPT_DIR" describe --tags --always --dirty=-wip >/dev/null 2>&1; then
        ver="$(git -C "$SCRIPT_DIR" describe --tags --always --dirty=-wip)"
    fi
    if [ -z "$ver" ]; then
        ver="$(grep -E -o -m 1 '[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT_DIR/Changelog" || true)"
    fi
    if [ -z "$ver" ]; then
        ver="unknown"
    fi
    echo "${ver}-static"
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --os) TARGET_OS="$2"; shift 2 ;;
        --arch) TARGET_ARCH="$2"; shift 2 ;;
        --static) LINK_MODE="static"; shift ;;
        --dynamic) LINK_MODE="dynamic"; shift ;;
        --fully-static) LINK_MODE="fully-static"; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --builddir) BUILD_DIR="$2"; shift 2 ;;
        --openssl-tag) OPENSSL_TAG="$2"; shift 2 ;;
        --zlib-version) ZLIB_VERSION="$2"; shift 2 ;;
        --install-deps) INSTALL_DEPS="yes"; shift ;;
        --rebuild) REBUILD="yes"; shift ;;
        --clean) CLEAN="yes"; shift ;;
        --distclean) DISTCLEAN="yes"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

if [ "$CLEAN" = "yes" ]; then
    info "removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    exit 0
fi

if [ "$DISTCLEAN" = "yes" ]; then
    info "running: make realclean (removes ./openssl, .openssl.is.fresh and sslscan)"
    make -C "$SCRIPT_DIR" realclean || true
    exit 0
fi

HOST_OS="$(host_os)"
HOST_ARCH="$(host_arch)"

case "$TARGET_OS" in
    auto) TARGET_OS="$HOST_OS" ;;
    linux|mac) ;;
    *) die "--os must be linux, mac or auto" ;;
esac
case "$TARGET_ARCH" in
    native) TARGET_ARCH="$HOST_ARCH" ;;
    amd64|arm64) ;;
    *) die "--arch must be amd64, arm64 or native" ;;
esac
case "$LINK_MODE" in
    dynamic|static|fully-static) ;;
    *) die "invalid link mode" ;;
esac

if [ "$LINK_MODE" = "fully-static" ] && [ "$TARGET_OS" != "linux" ]; then
    die "--fully-static is Linux only (macOS does not support fully static binaries)"
fi

NATIVE="no"
if [ "$TARGET_OS" = "$HOST_OS" ] && [ "$TARGET_ARCH" = "$HOST_ARCH" ]; then
    NATIVE="yes"
fi

if [ -z "$OUTPUT" ]; then
    if [ "$LINK_MODE" = "dynamic" ]; then
        # Same name the Makefile produces.
        OUTPUT="$SCRIPT_DIR/sslscan"
    elif [ "$LINK_MODE" = "fully-static" ]; then
        OUTPUT="$SCRIPT_DIR/sslscan-$TARGET_OS-$TARGET_ARCH-static"
    else
        # Partial static (static OpenSSL, dynamic libc).
        OUTPUT="$SCRIPT_DIR/sslscan-$TARGET_OS-$TARGET_ARCH"
    fi
fi

NPROC="$(cpu_count)"
VERSION="$(git_version)"

info "host: $HOST_OS/$HOST_ARCH | target: $TARGET_OS/$TARGET_ARCH | mode: $LINK_MODE | jobs: $NPROC"
info "version: $VERSION"
info "output: $OUTPUT"

# --------------------------------------------------------------------------
# Path 1: native build via the Makefile ('make' / 'make static').
# --------------------------------------------------------------------------
if [ "$NATIVE" = "yes" ] && [ "$LINK_MODE" != "fully-static" ]; then
    for tool in cc make git perl; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
    done
    if [ "$LINK_MODE" = "dynamic" ]; then
        if ! echo '#include <openssl/ssl.h>' | cc -E - >/dev/null 2>&1; then
            if [ "$HOST_OS" = "mac" ]; then
                die "OpenSSL headers not found; try: brew install openssl"
            else
                die "OpenSSL headers not found; try: apt install libssl-dev (Debian/Ubuntu) or equivalent"
            fi
        fi
        if ! printf '#include <openssl/opensslv.h>\n#if OPENSSL_VERSION_NUMBER < 0x30500000L\n#error TOO_OLD\n#endif\nOPENSSL_OK\n' \
                | cc -E - 2>/dev/null | grep -q OPENSSL_OK; then
            die "system OpenSSL headers are older than 3.5 (sslscan requires OpenSSL 3.5+); use './build.sh' (static build) instead of --dynamic"
        fi
        info "running: make"
        make -C "$SCRIPT_DIR" -j"$NPROC"
    else
        info "running: make static (builds bundled OpenSSL; takes a few minutes)"
        make -C "$SCRIPT_DIR" -j"$NPROC" static
    fi
    if [ "$SCRIPT_DIR/sslscan" != "$OUTPUT" ]; then
        cp -f "$SCRIPT_DIR/sslscan" "$OUTPUT"
    fi
    if command -v strip >/dev/null 2>&1; then
        if [ "$HOST_OS" = "mac" ]; then
            strip "$OUTPUT" || true
        else
            strip --strip-all "$OUTPUT" || true
        fi
    fi
    file "$OUTPUT" || true
    info "built $OUTPUT"
    exit 0
fi

# --------------------------------------------------------------------------
# Path 2: hermetic build (any --fully-static, or any Linux cross build).
# zlib + OpenSSL for the target are built from source into build/, then
# sslscan.c is linked directly. Needs a Linux host.
# --------------------------------------------------------------------------
if [ "$HOST_OS" != "linux" ] || [ "$TARGET_OS" != "linux" ]; then
    die "this build needs a Linux host targeting Linux (macOS builds must run on a Mac; cross-compiling to macOS is not supported)"
fi

TRIPLE=""
OPENSSL_TARGET_ARGS=""
if [ "$NATIVE" = "no" ]; then
    case "$TARGET_ARCH" in
        amd64)
            TRIPLE="x86_64-linux-gnu"
            OPENSSL_TARGET_ARGS="--cross-compile-prefix=$TRIPLE- linux-x86_64"
            DEB_PKGS="gcc-x86-64-linux-gnu libc6-dev-amd64-cross"
            ;;
        arm64)
            TRIPLE="aarch64-linux-gnu"
            OPENSSL_TARGET_ARGS="--cross-compile-prefix=$TRIPLE- linux-aarch64"
            DEB_PKGS="gcc-aarch64-linux-gnu libc6-dev-arm64-cross"
            ;;
    esac
fi

if [ -n "$TRIPLE" ]; then
    CC_BIN="$TRIPLE-gcc"
    STRIP_BIN="$TRIPLE-strip"
else
    CC_BIN="gcc"
    STRIP_BIN="strip"
fi

for tool in cc perl make git curl; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
if ! command -v "$CC_BIN" >/dev/null 2>&1; then
    if [ "$INSTALL_DEPS" = "yes" ] && command -v apt-get >/dev/null 2>&1; then
        info "installing cross toolchain: $DEB_PKGS"
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y $DEB_PKGS ca-certificates file
    else
        die "missing $CC_BIN. On Debian/Ubuntu, re-run with --install-deps (as root) or: apt install $DEB_PKGS"
    fi
fi

ZLIB_DIR="$BUILD_DIR/zlib-$TARGET_ARCH"
SSL_DIR="$BUILD_DIR/openssl-$TARGET_ARCH"

# --- zlib (static, for the target) ---
if [ ! -f "$ZLIB_DIR/lib/libz.a" ] || [ "$REBUILD" = "yes" ]; then
    info "building zlib $ZLIB_VERSION for $TARGET_ARCH"
    rm -rf "$ZLIB_DIR" "$BUILD_DIR/zlib-$ZLIB_VERSION"
    mkdir -p "$BUILD_DIR"
    curl -fsSL -o "$BUILD_DIR/zlib-$ZLIB_VERSION.tar.gz" \
        "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
    tar xzf "$BUILD_DIR/zlib-$ZLIB_VERSION.tar.gz" -C "$BUILD_DIR"
    (
        cd "$BUILD_DIR/zlib-$ZLIB_VERSION"
        if [ -n "$TRIPLE" ]; then
            CC="$CC_BIN" AR="$TRIPLE-ar" RANLIB="$TRIPLE-ranlib" \
                ./configure --prefix="$ZLIB_DIR" --static
        else
            CC="$CC_BIN" ./configure --prefix="$ZLIB_DIR" --static
        fi
        make -j"$NPROC"
        make install
    )
else
    info "reusing $ZLIB_DIR (use --rebuild to force)"
fi

# --- OpenSSL (static libs, for the target) ---
if [ -z "$OPENSSL_TAG" ]; then
    OPENSSL_TAG="$(git ls-remote https://github.com/openssl/openssl 2>/dev/null \
        | grep -Eo '(openssl-3\.5\.[0-9]+)' | sort -V | tail -n 1 || true)"
    if [ -z "$OPENSSL_TAG" ]; then
        info "could not determine newest OpenSSL tag; falling back to $OPENSSL_TAG_FALLBACK"
        OPENSSL_TAG="$OPENSSL_TAG_FALLBACK"
    fi
fi
info "OpenSSL tag: $OPENSSL_TAG"
if [ ! -f "$SSL_DIR/libcrypto.a" ] || [ "$REBUILD" = "yes" ]; then
    info "building OpenSSL $OPENSSL_TAG for $TARGET_ARCH (takes a few minutes)"
    rm -rf "$SSL_DIR"
    git clone --depth 1 -b "$OPENSSL_TAG" https://github.com/openssl/openssl "$SSL_DIR"
    (
        cd "$SSL_DIR"
        # shellcheck disable=SC2086
        perl ./Configure $OPENSSL_TARGET_ARGS \
            -fstack-protector-all -D_FORTIFY_SOURCE=2 -fPIC \
            no-shared enable-weak-ssl-ciphers zlib \
            --with-zlib-include="$ZLIB_DIR/include" \
            --with-zlib-lib="$ZLIB_DIR/lib"
        make depend
        make -j"$NPROC" build_libs
    )
else
    info "reusing $SSL_DIR (use --rebuild to force)"
fi

# --- sslscan ---
info "compiling sslscan for $TARGET_ARCH"
WARNINGS="-Wall -Wformat=2 -Wformat-security -Wno-deprecated-declarations"
CFLAGS="-D_FORTIFY_SOURCE=2 -fstack-protector-all -fPIE -std=gnu11 -DVERSION=\"$VERSION\""
CFLAGS="$CFLAGS -I$SSL_DIR/include -I$SSL_DIR -I$ZLIB_DIR/include"
LDFLAGS="-L$SSL_DIR -L$ZLIB_DIR/lib"
if [ "$LINK_MODE" = "fully-static" ]; then
    LDFLAGS="$LDFLAGS -static"
else
    LDFLAGS="$LDFLAGS -pie -z relro -z now"
fi
# shellcheck disable=SC2086
$CC_BIN -o "$OUTPUT" $WARNINGS $CFLAGS "$SCRIPT_DIR/sslscan.c" $LDFLAGS \
    -lssl -lcrypto -lz -lpthread -ldl
command -v "$STRIP_BIN" >/dev/null 2>&1 && "$STRIP_BIN" --strip-all "$OUTPUT" || true
file "$OUTPUT" || true
info "built $OUTPUT"
