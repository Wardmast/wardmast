#!/usr/bin/env bash
# Build the Erlang/OTP that the published release bundles as its ERTS, with
# OpenSSL linked in *statically*.
#
# Why this exists (bd-c6h5dr / #1977): the release is built inside
# `redhat/ubi8` so it runs on glibc 2.28 (RHEL 8) and everything newer. Until
# v0.1.69 the job installed OTP from the rabbitmq `erlang` el8 RPM, whose
# `crypto` NIF is dynamically linked against the build image's OpenSSL 1.1
# (`libcrypto.so.1.1`). Hosts that only carry OpenSSL 3 — Fedora >= 36,
# Ubuntu >= 22.04, Debian >= 12, RHEL 9 — cannot load that NIF, so `kernel`
# died in `on_load` before any Wardmast code ran.
#
# Building OTP here with `--disable-dynamic-ssl-lib` against a static,
# upstream OpenSSL 3 (an LTS line) gives a `crypto` NIF with no host libcrypto
# dependency at all, which is the usual way portable Erlang releases are made.
# The glibc baseline is unchanged: everything is still compiled against ubi8's
# glibc 2.28. The same RPM also linked `beam.smp` against `libz.so.1` and
# `epmd` against `libsystemd.so.0`; this build uses OTP's bundled zlib and
# leaves systemd support off, so neither dependency ships any more.
#
# `scripts/check-release-shared-libs.sh` is what enforces the outcome on the
# packaged tarball; this script runs the same check against the OTP it
# installs, so a regression fails here, closest to its cause.
#
# macOS (bd-6uq02m): the same recipe runs on an Apple Silicon runner for the
# darwin-arm64 tarball. Differences: OpenSSL's `darwin64-arm64-cc` target, a
# pinned MACOSX_DEPLOYMENT_TARGET, `shasum` for `sha256sum`, and
# `scripts/check-release-macho-libs.sh` (otool) for the readelf-based guard.
# glibc does not apply there.
set -euo pipefail

# Keep OTP_VERSION in step with the OTP line used in CI (.github/workflows/ci.yml).
OTP_VERSION="29.1.1"
OTP_SHA256="054e0143e39c780e091107fc9b345792a9c1a55f6bac1eca1c1101510fc06bf6"

# 3.5 is an OpenSSL LTS line (supported to 2030-04). Bump within it for
# security fixes; the checksum is the upstream `.sha256` for the tarball.
OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"

usage() {
  cat <<'USAGE'
Usage: scripts/build-release-otp.sh [--prefix DIR] [--src-cache DIR]

  --prefix DIR     Where to install OTP (default: /opt/otp). OpenSSL is
                   installed alongside it under DIR/openssl, for linking only;
                   nothing in the resulting OTP loads it at runtime.
  --src-cache DIR  Directory to look in for (and save) the downloaded
                   otp_src_*.tar.gz / openssl-*.tar.gz. Checksums are verified
                   either way.
  --print-versions Print "OTP_VERSION=... OPENSSL_VERSION=..." and exit — used
                   as the CI cache key.

  --print-config   Print the platform-derived build settings
                   (OPENSSL_TARGET, DEPLOYMENT_TARGET, SHA256_TOOL), one
                   KEY=value per line, and exit. ARB_OTP_UNAME_S /
                   ARB_OTP_UNAME_M override `uname -s` / `uname -m` (tests).

Needs a C/C++ toolchain, make, perl (with IPC::Cmd), ncurses-devel and curl
(on macOS: the Xcode command line tools, perl and curl).
On success `DIR/bin/erl` is a working OTP whose crypto NIF needs no
libcrypto from the host.

macOS only: MACOSX_DEPLOYMENT_TARGET overrides the default minimum macOS
version OTP and OpenSSL are built for.
USAGE
}

PREFIX="/opt/otp"
SRC_CACHE=""
PRINT_CONFIG=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --print-versions)
      echo "OTP_VERSION=${OTP_VERSION} OPENSSL_VERSION=${OPENSSL_VERSION}"
      exit 0
      ;;
    --print-config)
      PRINT_CONFIG=1
      shift
      ;;
    --prefix)
      PREFIX="${2:?--prefix needs a directory}"
      shift 2
      ;;
    --src-cache)
      SRC_CACHE="${2:?--src-cache needs a directory}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Platform. ARB_OTP_UNAME_* exist so tests can exercise both branches anywhere.
UNAME_S="${ARB_OTP_UNAME_S:-$(uname -s)}"
UNAME_M="${ARB_OTP_UNAME_M:-$(uname -m)}"
# Lowest macOS the published darwin tarball runs on. Exported below so that
# clang (OpenSSL, OTP) and rustc (the mdex NIF) all agree on it.
DEFAULT_DEPLOYMENT_TARGET="13.0"
DEPLOYMENT_TARGET=""

case "${UNAME_S}/${UNAME_M}" in
  Linux/x86_64)
    OPENSSL_TARGET="linux-x86_64"
    SHA256_TOOL="sha256sum"
    ;;
  Darwin/arm64)
    OPENSSL_TARGET="darwin64-arm64-cc"
    SHA256_TOOL="shasum -a 256"
    DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$DEFAULT_DEPLOYMENT_TARGET}"
    ;;
  *)
    echo "error: unsupported platform: ${UNAME_S}/${UNAME_M} (supported: Linux/x86_64, Darwin/arm64)" >&2
    exit 1
    ;;
esac

if [ "$PRINT_CONFIG" -eq 1 ]; then
  echo "OPENSSL_TARGET=${OPENSSL_TARGET}"
  echo "DEPLOYMENT_TARGET=${DEPLOYMENT_TARGET}"
  echo "SHA256_TOOL=${SHA256_TOOL}"
  exit 0
fi

if [ -n "$DEPLOYMENT_TARGET" ]; then
  export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
SSL_PREFIX="$PREFIX/openssl"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/build-release-otp.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# fetch <url> <sha256> -> path of a verified tarball
fetch() {
  local url="$1" sha="$2" name
  name=$(basename "$url")
  local dest="${SRC_CACHE:-$WORK_DIR}/$name"

  if [ -n "$SRC_CACHE" ]; then mkdir -p "$SRC_CACHE"; fi
  if [ ! -f "$dest" ]; then
    echo "Downloading $url" >&2
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi

  # Both sha256sum and `shasum -a 256` verify "<hash>  <file>" lines via -c.
  # shellcheck disable=SC2086 # SHA256_TOOL is a command plus fixed arguments
  if ! echo "$sha  $dest" | $SHA256_TOOL -c - >&2; then
    echo "error: checksum mismatch for $name (expected $sha)" >&2
    exit 1
  fi
  printf '%s\n' "$dest"
}

ssl_tarball=$(fetch \
  "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
  "$OPENSSL_SHA256")
otp_tarball=$(fetch \
  "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz" \
  "$OTP_SHA256")

echo "==> OpenSSL ${OPENSSL_VERSION} (static) -> ${SSL_PREFIX}"
tar -xzf "$ssl_tarball" -C "$WORK_DIR"
(
  cd "$WORK_DIR/openssl-${OPENSSL_VERSION}"
  # no-shared: only libcrypto.a/libssl.a, so nothing can link it dynamically.
  # -fPIC:     the archive gets linked into the crypto NIF, a shared object.
  # no-module: build the legacy provider into libcrypto instead of as a
  #            loadable .so that would not exist on the target host.
  # --libdir=lib: OpenSSL 3 defaults to lib64 on x86_64, which OTP's
  #            configure does not look in.
  # --openssldir: deliberately NOT the distro's /etc/pki/tls or /usr/lib/ssl.
  #            This upstream libcrypto would otherwise read the host's
  #            (distro-patched) openssl.cnf at init; a missing default config
  #            file is ignored, so point it somewhere hosts don't populate.
  #            Erlang's ssl verifies peers via public_key:cacerts_get/0, not
  #            through this directory.
  ./Configure "$OPENSSL_TARGET" \
    --prefix="$SSL_PREFIX" \
    --libdir=lib \
    --openssldir=/usr/local/ssl \
    no-shared no-module no-tests no-docs \
    -fPIC
  make -j"$JOBS"
  make install_sw
)

echo "==> Erlang/OTP ${OTP_VERSION} -> ${PREFIX}"
tar -xzf "$otp_tarball" -C "$WORK_DIR"
(
  cd "$WORK_DIR/otp_src_${OTP_VERSION}"
  # --disable-dynamic-ssl-lib: link libcrypto.a into the crypto NIF.
  # --enable-builtin-zlib:     don't make beam.smp NEED the host's libz.so.1.
  ./configure \
    --prefix="$PREFIX" \
    --with-ssl="$SSL_PREFIX" \
    --disable-dynamic-ssl-lib \
    --enable-builtin-zlib \
    --without-javac \
    --without-wx \
    --without-odbc
  make -j"$JOBS"
  make install
)

echo "==> Verifying ${PREFIX}"
"$PREFIX/bin/erl" -noshell -eval '
  ok = crypto:start(),
  [{_, _, Lib}] = crypto:info_lib(),
  io:format("crypto OK, linked against ~s~n", [Lib]),
  halt().'

# The same linked-library allowlist check the release tarball goes through.
case "$UNAME_S" in
  Darwin) bash "$SCRIPT_DIR/check-release-macho-libs.sh" "$PREFIX/lib/erlang" ;;
  *) bash "$SCRIPT_DIR/check-release-shared-libs.sh" "$PREFIX/lib/erlang" ;;
esac
