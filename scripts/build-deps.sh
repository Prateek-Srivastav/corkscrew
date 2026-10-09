#!/bin/bash
# Cross-compiles Wine's x86_64 libraries (GMP, Nettle, GnuTLS, FreeType, SDL2) into build/deps-x86_64
# with the native clang. GMP comes from the CrossOver tarball; the rest are pinned upstream releases. Configure scripts run their x86_64 test programs under Rosetta.
# Re-runnable: finished packages are skipped. Logs go to build/logs/<package>.log.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PREFIX="$BUILD/deps-x86_64"
WORK="$BUILD/work-deps"
LOGS="$BUILD/logs"
mkdir -p "$PREFIX" "$WORK" "$LOGS"

# Only our own x86_64 libraries are visible: never Homebrew's arm64 ones.
export CC="clang -arch x86_64" CXX="clang++ -arch x86_64"
export CPPFLAGS="-I$PREFIX/include" CFLAGS="-O2" CXXFLAGS="-O2"
export LDFLAGS="-L$PREFIX/lib -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=""
unset CPATH LIBRARY_PATH C_INCLUDE_PATH
HOST=(--build=x86_64-apple-darwin --host=x86_64-apple-darwin --prefix="$PREFIX" --enable-shared --disable-static)

# autotools PACKAGE SOURCE_DIR [configure args...]
autotools() {
  local name=$1 src=$2; shift 2
  [[ -f $PREFIX/.done-$name ]] && { echo "$name: already built"; return; }
  log "Building $name"
  rm -rf "$WORK/$name" && mkdir -p "$WORK/$name"
  (
    cd "$WORK/$name"
    "$src/configure" "${HOST[@]}" "$@"
    make -j"$JOBS"
    make install
  ) >"$LOGS/$name.log" 2>&1 || { echo "$name failed; see $LOGS/$name.log" >&2; tail -30 "$LOGS/$name.log" >&2; exit 1; }
  touch "$PREFIX/.done-$name"
}

# unpack TARBALL: extract an upstream tarball into $SRC and print its directory.
unpack() {
  local dir; dir="$SRC/$(basename "$1" | sed -E 's/\.tar\.(gz|xz)$//')"
  [[ -d $dir ]] || tar -xf "$1" -C "$SRC"
  echo "$dir"
}

mkdir -p "$SRC"
CX=$(crossover_sources)

autotools gmp "$CX/gnutls/gmp" --disable-cxx
autotools nettle "$(unpack "$(fetch "$NETTLE_URL" "$NETTLE_SHA256")")" \
  --disable-openssl --disable-documentation
autotools gnutls "$(unpack "$(fetch "$GNUTLS_URL" "$GNUTLS_SHA256")")" \
  --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
  --without-zlib --without-zstd --without-brotli --without-tpm --without-tpm2 \
  --disable-tools --disable-cxx --disable-doc --disable-tests --disable-nls --disable-guile --disable-libdane
autotools freetype "$(unpack "$(fetch "$FREETYPE_URL" "$FREETYPE_SHA256")")" \
  --without-png --without-harfbuzz --without-brotli --without-bzip2

if [[ ! -f $PREFIX/.done-sdl2 ]]; then
  log "Building sdl2"
  sdl=$(unpack "$(fetch "$SDL2_URL" "$SDL2_SHA256")")
  rm -rf "$WORK/sdl2"
  (
    cmake -S "$sdl" -B "$WORK/sdl2" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
    cmake --build "$WORK/sdl2" -j"$JOBS"
    cmake --install "$WORK/sdl2"
  ) >"$LOGS/sdl2.log" 2>&1 || { echo "sdl2 failed; see $LOGS/sdl2.log" >&2; tail -30 "$LOGS/sdl2.log" >&2; exit 1; }
  touch "$PREFIX/.done-sdl2"
fi

log "x86_64 libraries ready in $PREFIX"
for lib in "$PREFIX"/lib/lib{gmp,nettle,hogweed,gnutls,freetype,SDL2}*.dylib; do
  [[ -L $lib ]] || printf '  %-28s %s\n' "$(basename "$lib")" "$(lipo -archs "$lib")"
done
