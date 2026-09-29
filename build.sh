#!/usr/bin/env bash
#
# build.sh - Build sslscan for Linux, macOS or Windows.
#
# Wraps the Makefile targets ('make' for a dynamic build, 'make static' for a
# statically-linked OpenSSL build) and adds hermetic static builds, including
# cross-compilation (e.g. build an amd64 binary on an arm64 host, or a Windows
# .exe on Linux).
#
# Examples:
#   ./build.sh                                        # native static build (recommended)
#   ./build.sh --dynamic                              # native dynamic build (needs system OpenSSL dev files)
#   ./build.sh --fully-static                         # native fully static binary (Linux only)
#   ./build.sh --os linux --arch amd64 --fully-static # fully static amd64 binary, built on any Linux host
#   ./build.sh --os linux --arch arm64                # arm64 binary with static OpenSSL, built on any Linux host
#   ./build.sh --os mac                               # native macOS build (run on a Mac)
#   ./build.sh --os windows --arch amd64              # Windows x86-64 .exe (MinGW cross-compile)
#   ./build.sh --rebuild                              # force rebuild of bundled zlib/OpenSSL
#   ./build.sh --clean                                # remove the build/ working directory
#   ./build.sh --distclean                            # 'make realclean': remove ./openssl and sslscan
#
# macOS troubleshooting: if the final link fails with "tapi error: malformed
# file" / "unknown architecture" in an SDK .tbd file, your Xcode linker is
# older than the installed CommandLineTools SDK (mixed toolchain). build.sh
# now handles the common case automatically (pins SDKROOT to the SDK shipped
# with the active toolchain and aborts early with instructions if the
# toolchain cannot link). If it still fails, fix the toolchain with either:
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
#   windows (.exe via MinGW-w64, 64-bit only):
#                    x86_64-w64-mingw32-gcc, perl, make, git, curl.
#                    Debian/Ubuntu: apt install gcc-mingw-w64-x86-64
#                    (or re-run with --install-deps as root).
#                    macOS via Homebrew (brew install mingw-w64) is untested.
#
# Compatible with bash 3.2 (macOS system bash) and newer.

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
TARGET_OS="auto"        # auto | linux | mac | windows
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
    echo "  --os <linux|mac|windows|auto> Target OS (default: auto = host OS)"
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

# On macOS, a linker older than the macOS SDK fails with "tapi error:
# malformed file ... unknown architecture" in SDK .tbd files. Pin SDKROOT to
# the SDK shipped with the active toolchain (always parseable by it), unless
# the user already set SDKROOT. No-op on other platforms.
pin_macos_sdkroot() {
    [ "$(host_os)" = "mac" ] || return 0
    if [ -n "${SDKROOT:-}" ]; then
        info "macOS SDK (from environment): $SDKROOT"
        return 0
    fi
    devdir="${DEVELOPER_DIR:-}"
    if [ -z "$devdir" ] && command -v xcode-select >/dev/null 2>&1; then
        devdir="$(xcode-select -p 2>/dev/null || true)"
    fi
    if [ -n "$devdir" ]; then
        if [ -d "$devdir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
            SDKROOT="$devdir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
            export SDKROOT
        elif [ -d "$devdir/SDKs/MacOSX.sdk" ]; then
            SDKROOT="$devdir/SDKs/MacOSX.sdk"
            export SDKROOT
        fi
    fi
    if [ -n "${SDKROOT:-}" ]; then
        info "macOS SDK: $SDKROOT"
    fi
}

# Compile and link a trivial program to prove the active toolchain can link
# before spending minutes building OpenSSL. Returns non-zero on failure.
mac_link_smoke_test() {
    tmpd=""
    tmpd="$(mktemp -d 2>/dev/null || mktemp -d -t sslscanbuild)" || return 1
    cat > "$tmpd/t.c" <<'EOF'
#include <zlib.h>
int main(void) { return zlibVersion() == 0; }
EOF
    if cc -o "$tmpd/t" "$tmpd/t.c" -lz >/dev/null 2>&1; then
        rm -rf "$tmpd"
        return 0
    fi
    rm -rf "$tmpd"
    return 1
}

mac_toolchain_error() {
    {
        echo "build.sh: ERROR: C toolchain cannot link even a trivial program."
        echo "Active developer dir: $(xcode-select -p 2>/dev/null || echo unknown)"
        echo "cc: $(cc --version 2>/dev/null | head -n 1)"
        echo "SDKROOT: ${SDKROOT:-<unset>}"
        echo ""
        echo "This usually means the linker predates the macOS SDK (tapi errors about"
        echo "unknown architectures in .tbd files). Fix with one of:"
        echo "  sudo xcode-select --switch /Library/Developer/CommandLineTools"
        echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer  (Xcode 26+)"
        echo "then: ./build.sh --distclean && ./build.sh"
    } >&2
    exit 1
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
    linux|mac|windows) ;;
    *) die "--os must be linux, mac, windows or auto" ;;
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

if [ "$LINK_MODE" = "fully-static" ] && [ "$TARGET_OS" != "linux" ] && [ "$TARGET_OS" != "windows" ]; then
    die "--fully-static is Linux only (macOS does not support fully static binaries)"
fi

if [ "$TARGET_OS" = "windows" ]; then
    [ "$TARGET_ARCH" = "amd64" ] || die "--os windows only supports --arch amd64"
    if [ "$LINK_MODE" = "dynamic" ]; then
        die "--dynamic is not supported for Windows (static OpenSSL build only)"
    fi
    # Note: --fully-static is accepted as an alias for --static on Windows;
    # the MinGW link already passes -static (see Makefile.mingw).
fi

NATIVE="no"
if [ "$TARGET_OS" = "$HOST_OS" ] && [ "$TARGET_ARCH" = "$HOST_ARCH" ]; then
    NATIVE="yes"
fi

if [ -z "$OUTPUT" ]; then
    if [ "$LINK_MODE" = "dynamic" ]; then
        # Same name the Makefile produces.
        OUTPUT="$SCRIPT_DIR/sslscan"
    elif [ "$TARGET_OS" = "windows" ]; then
        OUTPUT="$SCRIPT_DIR/sslscan-$TARGET_OS-$TARGET_ARCH.exe"
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
    if [ "$HOST_OS" = "mac" ]; then
        # Use the SDK shipped with the active toolchain (old linkers choke on
        # newer SDK .tbd files), then prove the toolchain can link before
        # spending minutes building OpenSSL.
        pin_macos_sdkroot
        mac_link_smoke_test || mac_toolchain_error
    fi
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
# Path 3: Windows .exe via MinGW-w64 cross-compile (64-bit).
# Mirrors Makefile.mingw: zlib + OpenSSL for mingw64 are built from source
# into build/, then sslscan.c is linked statically. Needs MinGW-w64
# (x86_64-w64-mingw32-gcc) on any host OS.
# --------------------------------------------------------------------------
if [ "$TARGET_OS" = "windows" ]; then
    TRIPLE="x86_64-w64-mingw32"
    CC_BIN="$TRIPLE-gcc"
    STRIP_BIN="$TRIPLE-strip"

    for tool in perl make git curl; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
    done
    if ! command -v "$CC_BIN" >/dev/null 2>&1; then
        if [ "$INSTALL_DEPS" = "yes" ] && command -v apt-get >/dev/null 2>&1; then
            info "installing MinGW-w64 toolchain"
            apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y gcc-mingw-w64-x86-64 ca-certificates file
        else
            die "missing $CC_BIN. On Debian/Ubuntu: apt install gcc-mingw-w64-x86-64 (or re-run with --install-deps); on macOS: brew install mingw-w64"
        fi
    fi

    ZLIB_SRC="$BUILD_DIR/zlib-$ZLIB_VERSION-mingw64"
    SSL_DIR="$BUILD_DIR/openssl-mingw64"

    # --- zlib (static, for mingw64; built in place like Makefile.mingw) ---
    if [ ! -f "$ZLIB_SRC/libz.a" ] || [ "$REBUILD" = "yes" ]; then
        info "building zlib $ZLIB_VERSION for mingw64"
        # NB: remove the plain source dir too: the Linux build compiles
        # in-tree, and stale native .o files would otherwise survive the
        # tar extraction below (tarballs contain sources only) and poison
        # the MinGW build.
        rm -rf "$ZLIB_SRC" "$BUILD_DIR/zlib-$ZLIB_VERSION"
        mkdir -p "$BUILD_DIR"
        if [ ! -f "$BUILD_DIR/zlib-$ZLIB_VERSION.tar.gz" ]; then
            curl -fsSL -o "$BUILD_DIR/zlib-$ZLIB_VERSION.tar.gz" \
                "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
        fi
        tar xzf "$BUILD_DIR/zlib-$ZLIB_VERSION.tar.gz" -C "$BUILD_DIR"
        mv "$BUILD_DIR/zlib-$ZLIB_VERSION" "$ZLIB_SRC"
        (
            cd "$ZLIB_SRC"
            make -f win32/Makefile.gcc PREFIX="$TRIPLE-"
        )
    else
        info "reusing $ZLIB_SRC (use --rebuild to force)"
    fi

    # --- OpenSSL (static libs, for mingw64) ---
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
        info "building OpenSSL $OPENSSL_TAG for mingw64 (takes a few minutes)"
        rm -rf "$SSL_DIR"
        git clone --depth 1 -b "$OPENSSL_TAG" https://github.com/openssl/openssl "$SSL_DIR"
        (
            cd "$SSL_DIR"
            perl ./Configure --cross-compile-prefix="$TRIPLE-" \
                --with-zlib-include="$ZLIB_SRC" --with-zlib-lib="$ZLIB_SRC" \
                -fstack-protector-all -D_FORTIFY_SOURCE=2 \
                mingw64 no-shared enable-weak-ssl-ciphers enable-ssl2 zlib
            make depend CC="$CC_BIN"
            make -j"$NPROC" build_libs CC="$CC_BIN"
        )
    else
        info "reusing $SSL_DIR (use --rebuild to force)"
    fi
    if [ ! -f "$SSL_DIR/libssl.a" ]; then
        die "OpenSSL build did not produce libssl.a in $SSL_DIR"
    fi

    # --- sslscan (flags mirror Makefile.mingw) ---
    info "compiling sslscan for windows-amd64"
    # shellcheck disable=SC2086
    $CC_BIN -o "$OUTPUT" \
        -Wformat -Wformat-security -Wno-deprecated-declarations \
        -I$SSL_DIR/include -D__USE_GNU -DOPENSSL_NO_SSL2 \
        -fstack-protector-all -D_FORTIFY_SOURCE=2 -std=gnu11 -DVERSION=\"$VERSION\" \
        -Wl,-O1 -Wl,--discard-all -Wl,--no-undefined -Wl,--dynamicbase -Wl,--nxcompat -static \
        "$SCRIPT_DIR/sslscan.c" \
        $SSL_DIR/libssl.a $SSL_DIR/libcrypto.a $ZLIB_SRC/libz.a \
        -lws2_32 -lgdi32 -lcrypt32
    command -v "$STRIP_BIN" >/dev/null 2>&1 && "$STRIP_BIN" "$OUTPUT" || true
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
