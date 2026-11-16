#!/usr/bin/env bash
# build_wpe.sh - build and install WPE WebKit (with libwpe) for flutter_inappwebview_linux.
#
# The scripted form of WPE_BACKEND.md "Build from Source": check the build
# dependencies, download the release tarballs (SHA-256 checked), build libwpe and
# WPE WebKit with WPEPlatform (headless), install them into a prefix, and verify
# the result with pkg-config (and optionally a `flutter build linux` of an app).
# wpebackend-fdo is not built: the plugin uses WPEPlatform.
#
# STARTED BY A PERSON, NEVER ON ITS OWN. A WebKit build takes hours and installs
# into /usr/local with sudo; nothing schedules or triggers this script (al_the_bear
# CLAUDE.md: builds are started by a person, from the repository).
#
# Linux only (Debian/Ubuntu package names). macOS and Windows use the plugin's other
# backends and need no WPE build.
#
# History: 2026-11-16 written to replace the 33,046 WPE WebKit source files that were
# tracked in tom_ai/xternal/wpe_webkit_build (al_the_bear workspace_layout,
# 00a_wslayout-3, BP-8 (c)).
#
# Usage: build_wpe.sh [options]      (build_wpe.sh --help)
# Exit:  0 done; 1 a step failed (a missing package, a checksum mismatch, a build
#        error); 2 bad usage or an unsupported platform.
set -euo pipefail

WPE_VERSION=2.50.4
LIBWPE_VERSION=1.16.3
RELEASES_URL=https://wpewebkit.org/releases
PREFIX=/usr/local
PREFIX_GIVEN=0
JOBS=""
VERIFY_APP=""
STEPS="check,download,build,install,verify"
BUILD_DIR=""

# SHA-256 of the release tarballs, from https://wpewebkit.org/releases/<file>.sums.
# A version without an entry is refused: add its sum here first.
tarball_sha256() {
  case "$1" in
    libwpe-1.16.3.tar.xz)    echo c880fa8d607b2aa6eadde7d6d6302b1396ebc38368fe2332fa20e193c7ee1420 ;;
    wpewebkit-2.50.4.tar.xz) echo d204e405b0975508748c0273c18090304a979e1170ffa2a0a528fad90191ef87 ;;
    *) echo "" ;;
  esac
}

# Required packages (WPE_BACKEND.md, Prerequisites). "a|b" accepts either name:
# the documented one and the name newer Ubuntu releases use. libwpe-1.0-dev is
# not required: this script builds libwpe itself.
REQUIRED_PACKAGES=(
  build-essential cmake ninja-build meson pkg-config
  ruby ruby-dev python3 python3-pip gperf unifdef
  libglib2.0-dev
  libsoup-3.0-dev libssl-dev libgnutls28-dev libsecret-1-dev libgcrypt20-dev "libtasn1-6-dev|libtasn1-dev"
  libepoxy-dev "libegl1-mesa-dev|libegl-dev" "libgles2-mesa-dev|libgles-dev" libxkbcommon-dev
  libjpeg-dev libpng-dev libwebp-dev libharfbuzz-dev libharfbuzz-icu0 "libfreetype6-dev|libfreetype-dev" "libfontconfig1-dev|libfontconfig-dev"
  libicu-dev libxml2-dev libhyphen-dev libenchant-2-dev
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good
  libsqlite3-dev
)

# Optional features that WPE WebKit enables by default (WPE_BACKEND.md, Optional
# Features): "FLAG:package package". When a package is missing, the feature is
# built OFF and the check says so; install the packages to keep it.
OPTIONAL_FEATURES=(
  "USE_JPEGXL:libjxl-dev"
  "USE_AVIF:libavif-dev"
  "USE_WOFF2:libwoff-dev"
  "USE_LCMS:liblcms2-dev"
  "USE_ATK:libatk1.0-dev libatk-bridge2.0-dev"
  "USE_GBM:libgbm-dev"
  "USE_LIBDRM:libdrm-dev"
  "USE_LIBBACKTRACE:libbacktrace-dev"     # not in Ubuntu 24.04's archive: OFF there
  "ENABLE_SPEECH_SYNTHESIS:flite1-dev"
  "ENABLE_XSLT:libxslt1-dev"
  "ENABLE_JOURNALD_LOG:libsystemd-dev"
  "ENABLE_BUBBLEWRAP_SANDBOX:bubblewrap xdg-dbus-proxy libseccomp-dev"
  "ENABLE_GAMEPAD:libmanette-0.2-dev"
  # On by default in WPE 2.50 (OptionsWPE.cmake), although WPE_BACKEND.md's table
  # once said OFF: the DRM and Wayland platforms beside the headless one this
  # plugin uses, and the system sysprof capture library (bundled copy when OFF).
  "ENABLE_WPE_PLATFORM_DRM:libinput-dev libudev-dev libgbm-dev"
  "ENABLE_WPE_PLATFORM_WAYLAND:libwayland-dev wayland-protocols"
  "USE_SYSTEM_SYSPROF_CAPTURE:libsysprof-capture-4-dev"
)

usage() {
  cat <<EOF
build_wpe.sh - build and install WPE WebKit and libwpe for flutter_inappwebview_linux.

Options:
  --wpe <version>         WPE WebKit version (default $WPE_VERSION)
  --libwpe <version>      libwpe version (default $LIBWPE_VERSION)
  --build-dir <dir>       where the tarballs are kept and built (default: the
                          workspace's tom_ai/xternal/wpe_webkit_build, found from
                          this script's place in the fork)
  --prefix <dir>          install into <dir>, without sudo and without ldconfig
                          (a test build); default $PREFIX with sudo + ldconfig
  --jobs <n>              ninja jobs (default: min(cores, RAM GB / 1.5))
  --verify-app <dir>      also run 'flutter build linux' in that app folder against
                          the prefix
  --steps <list>          run a part: any of check,download,build,install,verify
                          (default: all, in that order). 'build' installs libwpe
                          into the prefix, because WPE WebKit is configured against it.
  -h, --help              this text

Typical calls:
  build_wpe.sh                                  # build and install into /usr/local
  build_wpe.sh --prefix ~/wpe-test --verify-app <app>   # a test build, no sudo
EOF
}

die() { echo "build_wpe: $*" >&2; exit 1; }
say() { echo "== $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --wpe) WPE_VERSION="${2:?--wpe needs a version}"; shift 2 ;;
    --libwpe) LIBWPE_VERSION="${2:?--libwpe needs a version}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?--build-dir needs a folder}"; shift 2 ;;
    --prefix) PREFIX="${2:?--prefix needs a folder}"; PREFIX_GIVEN=1; shift 2 ;;
    --jobs) JOBS="${2:?--jobs needs a number}"; shift 2 ;;
    --verify-app) VERIFY_APP="${2:?--verify-app needs an app folder}"; shift 2 ;;
    --steps) STEPS="${2:?--steps needs a list}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "build_wpe: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != Linux ]; then
  echo "build_wpe: WPE WebKit is the plugin's Linux backend; on $(uname -s) the plugin uses its other backends and needs no WPE build." >&2
  exit 2
fi

for s in ${STEPS//,/ }; do
  case "$s" in check|download|build|install|verify) ;; *) echo "build_wpe: unknown step '$s'" >&2; exit 2 ;; esac
done
[[ "$JOBS" =~ ^[0-9]*$ ]] || { echo "build_wpe: --jobs must be a number" >&2; exit 2; }
wants() { [[ ",$STEPS," == *",$1,"* ]]; }

# The default build folder: <tom_ai>/xternal/wpe_webkit_build, beside the fork.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$BUILD_DIR" ]; then
  xternal="$(cd "$script_dir/../../.." && pwd)"
  [ "$(basename "$xternal")" = xternal ] \
    || die "no default build folder: this copy of the script is not in <tom_ai>/xternal/<fork>; pass --build-dir"
  BUILD_DIR="$xternal/wpe_webkit_build"
fi
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
if [ "$PREFIX_GIVEN" = 1 ]; then mkdir -p "$PREFIX"; PREFIX="$(cd "$PREFIX" && pwd)"; fi

libwpe_tar="libwpe-$LIBWPE_VERSION.tar.xz"
wpe_tar="wpewebkit-$WPE_VERSION.tar.xz"
arch_dir="$(uname -m)-linux-gnu"
pc_path="$PREFIX/lib/pkgconfig:$PREFIX/lib/$arch_dir/pkgconfig"
ld_path="$PREFIX/lib:$PREFIX/lib/$arch_dir"

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
# "a|b": installed when one of the names is.
installed_any() {
  local name
  for name in ${1//|/ }; do installed "$name" && return 0; done
  return 1
}

# Echo the -D<FLAG>=OFF options for the optional features whose packages are missing.
optional_off_flags() {
  local entry flag pkgs p
  for entry in "${OPTIONAL_FEATURES[@]}"; do
    flag="${entry%%:*}"; pkgs="${entry#*:}"
    for p in $pkgs; do
      if ! installed "$p"; then echo "-D$flag=OFF"; break; fi
    done
  done
}

as_root() { if [ "$PREFIX_GIVEN" = 1 ]; then "$@"; else sudo "$@"; fi; }

jobs_default() {
  local cores mem_kb by_ram
  cores="$(nproc)"
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  by_ram=$(( mem_kb * 10 / 1024 / 1024 / 15 ))   # GB / 1.5, about 1.5 GB per WebKit job
  [ "$by_ram" -lt 1 ] && by_ram=1
  if [ "$cores" -lt "$by_ram" ]; then echo "$cores"; else echo "$by_ram"; fi
}

step_check() {
  say "check: build dependencies"
  local missing=() p tool entry flag pkgs absent
  for tool in cmake ninja pkg-config curl sha256sum tar; do
    command -v "$tool" >/dev/null || missing+=("command:$tool")
  done
  for p in "${REQUIRED_PACKAGES[@]}"; do
    installed_any "$p" || missing+=("$p")
  done
  for entry in "${OPTIONAL_FEATURES[@]}"; do
    flag="${entry%%:*}"; pkgs="${entry#*:}"; absent=()
    for p in $pkgs; do installed "$p" || absent+=("$p"); done
    if [ ${#absent[@]} -gt 0 ]; then
      echo "   optional: $flag will be built OFF - missing ${absent[*]}"
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    local install=() m
    for m in "${missing[@]}"; do
      case "$m" in command:*) ;; *) install+=("${m%%|*}") ;; esac
    done
    echo "   MISSING (required): ${missing[*]}"
    if [ ${#install[@]} -gt 0 ]; then
      echo "   Install them (a person, with sudo; this script never installs packages):"
      echo "   sudo apt-get install ${install[*]}"
    fi
    return 1
  fi
  echo "   every required package is installed"
}

fetch() {   # fetch <file>: download into the build folder unless there, then check its sum
  local file="$1" want got
  want="$(tarball_sha256 "$file")"
  [ -n "$want" ] || die "no SHA-256 recorded for $file - add it to tarball_sha256 in this script (from $RELEASES_URL/$file.sums)"
  if [ ! -f "$BUILD_DIR/$file" ]; then
    say "download: $RELEASES_URL/$file"
    curl -fL --retry 3 --progress-bar -o "$BUILD_DIR/$file.part" "$RELEASES_URL/$file"
    mv "$BUILD_DIR/$file.part" "$BUILD_DIR/$file"
  else
    say "download: $file already in $BUILD_DIR"
  fi
  got="$(sha256sum "$BUILD_DIR/$file" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    die "SHA-256 mismatch for $file: got $got, want $want - not using it"
  fi
  echo "   sha256 $got OK"
}

# unpack <file> <dir>: extract the (checksummed) tarball unless this script
# unpacked it before (a marker file). A folder without the marker is unpacked
# over: in the Tom workspace it held a copy of the sources from git, where an
# ignore rule for `build/` had dropped files such as
# Source/ThirdParty/pdfjs/build/pdf.mjs, and the build failed on it.
unpack() {
  local file="$1" dir="$2" marker="$BUILD_DIR/$2/.unpacked-by-build_wpe"
  if [ -f "$marker" ]; then
    echo "   $dir already unpacked"
    return
  fi
  [ -d "$BUILD_DIR/$dir" ] && echo "   $dir exists but was not unpacked by this script: unpacking $file over it"
  tar -C "$BUILD_DIR" -xf "$BUILD_DIR/$file"
  touch "$marker"
}

step_build() {
  local jobs="${JOBS:-$(jobs_default)}" off
  [ -f "$BUILD_DIR/$libwpe_tar" ] && [ -f "$BUILD_DIR/$wpe_tar" ] || die "tarballs missing in $BUILD_DIR - run the download step"

  say "build: libwpe $LIBWPE_VERSION (installed into $PREFIX: WPE WebKit is configured against it)"
  unpack "$libwpe_tar" "libwpe-$LIBWPE_VERSION"
  cmake -S "$BUILD_DIR/libwpe-$LIBWPE_VERSION" -B "$BUILD_DIR/libwpe-$LIBWPE_VERSION/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX"
  ninja -C "$BUILD_DIR/libwpe-$LIBWPE_VERSION/build" -j"$jobs"
  as_root ninja -C "$BUILD_DIR/libwpe-$LIBWPE_VERSION/build" install

  say "build: WPE WebKit $WPE_VERSION with $jobs job(s)"
  unpack "$wpe_tar" "wpewebkit-$WPE_VERSION"
  off="$(optional_off_flags | tr '\n' ' ')"
  [ -n "$off" ] && echo "   optional features built OFF (missing packages): $off"
  # shellcheck disable=SC2086 # $off is a list of -D options
  PKG_CONFIG_PATH="$pc_path${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  cmake -S "$BUILD_DIR/wpewebkit-$WPE_VERSION" -B "$BUILD_DIR/wpewebkit-$WPE_VERSION/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DPORT=WPE \
    -DENABLE_DOCUMENTATION=OFF \
    -DENABLE_INTROSPECTION=OFF \
    -DENABLE_BUBBLEWRAP_SANDBOX=ON \
    -DENABLE_WEBDRIVER=OFF \
    -DENABLE_MINIBROWSER=OFF \
    -DUSE_AVIF=ON \
    -DUSE_WOFF2=ON \
    -DUSE_JPEGXL=ON \
    -DENABLE_WPE_PLATFORM=ON \
    -DENABLE_WPE_PLATFORM_HEADLESS=ON \
    $off
  ninja -C "$BUILD_DIR/wpewebkit-$WPE_VERSION/build" -j"$jobs"
}

step_install() {
  [ -d "$BUILD_DIR/wpewebkit-$WPE_VERSION/build" ] || die "no WPE WebKit build in $BUILD_DIR - run the build step"
  say "install: WPE WebKit $WPE_VERSION into $PREFIX"
  as_root ninja -C "$BUILD_DIR/wpewebkit-$WPE_VERSION/build" install
  if [ "$PREFIX_GIVEN" = 0 ]; then sudo ldconfig; fi
}

step_verify() {
  say "verify: pkg-config in $PREFIX"
  local mod want got fail=0
  for mod in wpe-webkit-2.0 wpe-platform-2.0 wpe-1.0; do
    if [ "$mod" = wpe-1.0 ]; then want="$LIBWPE_VERSION"; else want="$WPE_VERSION"; fi
    got="$(PKG_CONFIG_PATH="$pc_path" pkg-config --modversion "$mod" 2>/dev/null || true)"
    if [ "$got" = "$want" ]; then echo "   $mod $got OK"; else echo "   $mod is '$got', want $want"; fail=1; fi
  done
  [ "$fail" = 0 ] || return 1
  if [ -n "$VERIFY_APP" ]; then
    say "verify: flutter build linux in $VERIFY_APP"
    (cd "$VERIFY_APP" && PKG_CONFIG_PATH="$pc_path" LD_LIBRARY_PATH="$ld_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" flutter build linux)
  fi
}

echo "build_wpe: WPE WebKit $WPE_VERSION, libwpe $LIBWPE_VERSION, build folder $BUILD_DIR, prefix $PREFIX, steps $STEPS"
if wants check; then step_check; fi
if wants download; then fetch "$libwpe_tar"; fetch "$wpe_tar"; fi
if wants build; then step_build; fi
if wants install; then step_install; fi
if wants verify; then step_verify; fi
echo "build_wpe: done ($STEPS)"
