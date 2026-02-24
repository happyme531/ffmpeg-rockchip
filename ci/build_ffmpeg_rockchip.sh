#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <shared|static> [jobs]"
  exit 1
fi

VARIANT="$1"
JOBS="${2:-4}"

if [[ "$VARIANT" != "shared" && "$VARIANT" != "static" ]]; then
  echo "Invalid variant: $VARIANT"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.ci-build/${VARIANT}"
SRC_DIR="${WORK_DIR}/src"
BUILD_DIR="${WORK_DIR}/build"
PREFIX_DIR="${WORK_DIR}/prefix"
DIST_DIR="${ROOT_DIR}/dist"
FFMPEG_SRC="${ROOT_DIR}"

LIBDRM_TAG="libdrm-2.4.123"
MBEDTLS_TAG="v2.28.9"
MPP_BRANCH="jellyfin-mpp"
RGA_BRANCH="jellyfin-rga"

mkdir -p "${SRC_DIR}" "${BUILD_DIR}" "${PREFIX_DIR}" "${DIST_DIR}"

export PATH="$HOME/.local/bin:$PATH"
export PKG_CONFIG_PATH="${PREFIX_DIR}/lib/pkgconfig"
export LD_LIBRARY_PATH="${PREFIX_DIR}/lib:${LD_LIBRARY_PATH:-}"

fetch_sources() {
  if [[ ! -d "${SRC_DIR}/libdrm/.git" ]]; then
    git clone --depth=1 --branch "${LIBDRM_TAG}" https://gitlab.freedesktop.org/mesa/drm.git "${SRC_DIR}/libdrm"
  fi
  if [[ ! -d "${SRC_DIR}/mbedtls" ]]; then
    curl -L --fail "https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/${MBEDTLS_TAG}.tar.gz" -o "${SRC_DIR}/mbedtls.tar.gz"
    tar -xf "${SRC_DIR}/mbedtls.tar.gz" -C "${SRC_DIR}"
    mv "${SRC_DIR}/mbedtls-${MBEDTLS_TAG#v}" "${SRC_DIR}/mbedtls"
  fi
  if [[ ! -d "${SRC_DIR}/rkmpp/.git" ]]; then
    git clone --depth=1 --branch "${MPP_BRANCH}" https://gitee.com/nyanmisaka/mpp.git "${SRC_DIR}/rkmpp"
  fi
  if [[ ! -d "${SRC_DIR}/rkrga/.git" ]]; then
    git clone --depth=1 --branch "${RGA_BRANCH}" https://gitee.com/nyanmisaka/rga.git "${SRC_DIR}/rkrga"
  fi
}

build_libdrm() {
  local default_library="$1"
  rm -rf "${BUILD_DIR}/libdrm"
  meson setup "${SRC_DIR}/libdrm" "${BUILD_DIR}/libdrm" \
    --prefix="${PREFIX_DIR}" \
    --libdir=lib \
    --buildtype=release \
    --default-library="${default_library}" \
    -Dintel=disabled \
    -Dradeon=disabled \
    -Damdgpu=disabled \
    -Dnouveau=disabled \
    -Dvmwgfx=disabled \
    -Dfreedreno=disabled \
    -Dvc4=disabled \
    -Detnaviv=disabled \
    -Dman-pages=disabled \
    -Dtests=false
  ninja -C "${BUILD_DIR}/libdrm" -j"${JOBS}"
  ninja -C "${BUILD_DIR}/libdrm" install
}

build_mbedtls() {
  local static_on="$1"
  local shared_on="$2"
  cmake -S "${SRC_DIR}/mbedtls" -B "${BUILD_DIR}/mbedtls" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX_DIR}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DUSE_STATIC_MBEDTLS_LIBRARY="${static_on}" \
    -DUSE_SHARED_MBEDTLS_LIBRARY="${shared_on}" \
    -DENABLE_TESTING=OFF \
    -DENABLE_PROGRAMS=OFF
  cmake --build "${BUILD_DIR}/mbedtls" -j"${JOBS}"
  cmake --install "${BUILD_DIR}/mbedtls"
}

build_mpp() {
  local shared_libs="$1"
  cmake -S "${SRC_DIR}/rkmpp" -B "${BUILD_DIR}/rkmpp" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX_DIR}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_DO_STRIP=OFF \
    -DCMAKE_C_FLAGS="-g1" \
    -DCMAKE_CXX_FLAGS="-g1" \
    -DBUILD_SHARED_LIBS="${shared_libs}" \
    -DBUILD_TEST=OFF
  cmake --build "${BUILD_DIR}/rkmpp" -j"${JOBS}"
  cmake --install "${BUILD_DIR}/rkmpp"
}

build_rga() {
  local default_library="$1"
  if [[ "${default_library}" == "static" ]]; then
    # Upstream rga meson.build hardcodes shared_library(), which ignores
    # --default-library=static. Switch to library() so Meson honors
    # the selected default library type for the static variant.
    if grep -q 'shared_library(' "${SRC_DIR}/rkrga/meson.build"; then
      sed -i '0,/shared_library(/s//library(/' "${SRC_DIR}/rkrga/meson.build"
    fi
  fi
  rm -rf "${BUILD_DIR}/rkrga"
  meson setup "${SRC_DIR}/rkrga" "${BUILD_DIR}/rkrga" \
    --prefix="${PREFIX_DIR}" \
    --libdir=lib \
    --buildtype=release \
    -Db_strip=false \
    --default-library="${default_library}" \
    -Dc_args=-g1 \
    -Dcpp_args="-fpermissive -g1" \
    -Dlibdrm=false \
    -Dlibrga_demo=false
  ninja -C "${BUILD_DIR}/rkrga" -j"${JOBS}"
  ninja -C "${BUILD_DIR}/rkrga" install
}

build_ffmpeg() {
  local ffmpeg_shared_flag="$1"
  local ffmpeg_static_flag="$2"
  local pkg_config_flags="$3"
  local extra_ldflags
  extra_ldflags="-L${PREFIX_DIR}/lib -Wl,-rpath,\$ORIGIN/../lib -Wl,-rpath,\$ORIGIN -Wl,--enable-new-dtags"

  cd "${FFMPEG_SRC}"
  make distclean >/dev/null 2>&1 || true

  ./configure \
    --prefix="${PREFIX_DIR}" \
    --enable-version3 \
    --disable-stripping \
    --enable-libdrm \
    --enable-rkmpp \
    --enable-rkrga \
    --disable-libxcb \
    --disable-iconv \
    --disable-zlib \
    --disable-bzlib \
    --disable-lzma \
    --disable-alsa \
    --disable-muxer=spdif \
    --disable-demuxer=spdif \
    --enable-mbedtls \
    --enable-pic \
    --extra-cflags="-fPIC -g1 -I${PREFIX_DIR}/include" \
    --extra-ldflags="${extra_ldflags}" \
    --pkg-config-flags="${pkg_config_flags}" \
    "${ffmpeg_shared_flag}" \
    "${ffmpeg_static_flag}"

  make -j"${JOBS}"
  make install
}

package_output() {
  local arch
  arch="$(uname -m)"
  local out_name
  out_name="ffmpeg-rockchip-${VARIANT}-${arch}"
  local out_dir="${DIST_DIR}/${out_name}"

  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"
  cp -a "${PREFIX_DIR}"/* "${out_dir}/"

  if command -v patchelf >/dev/null 2>&1; then
    find "${out_dir}/bin" -maxdepth 1 -type f -executable \
      -exec patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN' {} +
    find "${out_dir}/lib" -maxdepth 1 -type f -name '*.so*' \
      -exec patchelf --set-rpath '$ORIGIN:$ORIGIN/../lib' {} +
  fi

  cat > "${out_dir}/BUILD_INFO.txt" <<INFO
variant=${VARIANT}
arch=${arch}
configure_flags=--enable-version3 --disable-stripping --enable-libdrm --enable-rkmpp --enable-rkrga --disable-libxcb --disable-iconv --disable-zlib --disable-bzlib --disable-lzma --disable-alsa --disable-muxer=spdif --disable-demuxer=spdif --enable-mbedtls --enable-pic --extra-cflags=-fPIC
debug_level=-g1
INFO

  tar -C "${DIST_DIR}" -czf "${DIST_DIR}/${out_name}.tar.gz" "${out_name}"
  echo "Created package: ${DIST_DIR}/${out_name}.tar.gz"
}

fetch_sources

if [[ "$VARIANT" == "shared" ]]; then
  build_libdrm shared
  build_mbedtls OFF ON
  build_mpp ON
  build_rga shared
  build_ffmpeg --enable-shared --disable-static ""
else
  build_libdrm static
  build_mbedtls ON OFF
  build_mpp OFF
  build_rga static
  build_ffmpeg --disable-shared --enable-static "--static"
fi

package_output
