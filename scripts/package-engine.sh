#!/bin/bash
# Packs the engine that downloaded copies of the app install on first launch: the runtime built by
# build-runtime.sh, plus DXMT, DXVK and D3DMetal from install-components.sh, with their licenses.
# D3DMetal comes from Apple's Game Porting Toolkit $GPTK_VERSION (pinned image), whose license allows
# non-commercial redistribution of its redist/ components with Apple's notices.
#
# Usage: package-engine.sh <release>        e.g. package-engine.sh 26.3.0-1
#   <release> is the Wine version and the pack's revision. Writes dist/runtime-<release>/:
#   corkscrew-engine-<release>.tar.xz  the pack
#   *-source.tar.*                     the source of everything in it (LGPL: published next to the binaries)
#   SHA256SUMS
# and points the app at the pack (Packages/GameCore/Sources/GameCore/Engines/EnginePackPin.swift).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

RELEASE=${1:?usage: package-engine.sh <release>, e.g. 26.3.0-1}
[[ $RELEASE == "$CROSSOVER_VERSION"-* ]] || { echo "The release must start with the Wine version: $CROSSOVER_VERSION-<n>" >&2; exit 1; }
RUNTIME="$BUILD/runtime/winecx-$CROSSOVER_VERSION"
COMPONENTS="$BUILD/components"
DXMT="$COMPONENTS/dxmt-$DXMT_VERSION"
DXVK="$COMPONENTS/dxvk-macos-$DXVK_VERSION"
D3DMETAL="$COMPONENTS/d3dmetal-$GPTK_VERSION"
CX="$SRC/crossover-$CROSSOVER_VERSION/sources"

[[ -f $RUNTIME/manifest.json ]] || { echo "No runtime at $RUNTIME: run scripts/build-runtime.sh" >&2; exit 1; }
[[ -d $DXMT && -d $DXVK ]] || { echo "DXMT or DXVK isn't staged: run scripts/install-components.sh" >&2; exit 1; }
[[ -d $D3DMETAL ]] || { echo "D3DMetal $GPTK_VERSION isn't staged: run scripts/install-components.sh with Game_Porting_Toolkit_$GPTK_VERSION.dmg" >&2; exit 1; }
# Only Apple's genuine image, with Apple's notices, which its license requires on every copy.
[[ $(cat "$D3DMETAL/gptk-image.sha256" 2>/dev/null) == "$GPTK_DMG_SHA256" ]] \
  || { echo "$D3DMETAL wasn't staged from the pinned Game Porting Toolkit image: delete it and rerun install-components.sh" >&2; exit 1; }
for notice in Apple-License.rtf Apple-Acknowledgements.rtf; do
  [[ -f $D3DMETAL/$notice ]] || { echo "$D3DMETAL lacks $notice: delete it and rerun install-components.sh" >&2; exit 1; }
done
# The runtime has to match today's patches (build-runtime.sh); a stale one would ship old behavior.
grep -qa CORKSCREW_NO_LOADER_LINK "$RUNTIME/lib/wine/x86_64-unix/ntdll.so" \
  || { echo "$RUNTIME predates the current Wine patches: rebuild it" >&2; exit 1; }
# DXMT needs its winemetal inside the runtime (install-components.sh puts it there; a runtime rebuild
# removes it). Without it new bottles get no placeholder for it, and DXMT games exit at once.
for f in x86_64-windows/winemetal.dll i386-windows/winemetal.dll x86_64-unix/winemetal.so; do
  cmp -s "$DXMT/$f" "$RUNTIME/lib/wine/$f" \
    || { echo "The runtime lacks DXMT's $f: run scripts/install-components.sh" >&2; exit 1; }
done
# CORKSCREW_TRY_PACKAGE=1 skips this, to try the script out; don't publish what it makes.
if ! git -C "$REPO" diff --quiet HEAD -- scripts tools && [[ -z ${CORKSCREW_TRY_PACKAGE:-} ]]; then
  echo "scripts/ or tools/ has uncommitted changes; commit them first, so the published build scripts match the runtime." >&2
  exit 1
fi

OUT="$REPO/dist/runtime-$RELEASE"
NAME="corkscrew-engine-$RELEASE"
STAGE="$OUT/stage/$NAME"
rm -rf "$OUT" && mkdir -p "$STAGE/runtime" "$STAGE/components" "$STAGE/LICENSES"

log "Collecting the runtime and components"
cp -ac "$RUNTIME" "$STAGE/runtime/"
cp -ac "$DXMT" "$DXVK" "$D3DMETAL" "$STAGE/components/"

log "Collecting licenses"
dxmt_src=$(fetch "$DXMT_SOURCE_URL" "$DXMT_SOURCE_SHA256")
dxvk_src=$(fetch "$DXVK_SOURCE_URL" "$DXVK_SOURCE_SHA256")
moltenvk=$(fetch "$MOLTENVK_URL" "$MOLTENVK_SHA256")
license() { mkdir -p "$STAGE/LICENSES/$1" && cp "${@:2}" "$STAGE/LICENSES/$1/"; }
license wine "$CX/wine/COPYING.LIB" "$CX/wine/LICENSE" "$CX/wine/AUTHORS"
license gnutls "$SRC/gnutls-3.8.13/COPYING.LESSERv2" "$SRC/gnutls-3.8.13/COPYING"
license nettle "$SRC/nettle-3.10/COPYING.LESSERv3" "$SRC/nettle-3.10/COPYINGv2"
license gmp "$CX/gnutls/gmp/COPYING.LESSERv3" "$CX/gnutls/gmp/COPYINGv2"
license freetype "$SRC/freetype-2.13.3/LICENSE.TXT" "$SRC/freetype-2.13.3/docs/FTL.TXT"
license sdl2 "$SRC/SDL2-2.32.10/LICENSE.txt"
mkdir -p "$STAGE/LICENSES/dxmt" "$STAGE/LICENSES/dxvk" "$STAGE/LICENSES/moltenvk"
top() { tar -tzf "$1" | head -1 | cut -d/ -f1; }
tar -xzf "$dxmt_src" -C "$STAGE/LICENSES/dxmt" --strip-components 1 "$(top "$dxmt_src")/LICENSE"
tar -xzf "$dxvk_src" -C "$STAGE/LICENSES/dxvk" --strip-components 1 "$(top "$dxvk_src")/LICENSE"
tar -xf "$moltenvk" -C "$STAGE/LICENSES/moltenvk" --strip-components 1 MoltenVK/LICENSE
mkdir -p "$STAGE/LICENSES/apple-game-porting-toolkit"
cp "$D3DMETAL/Apple-License.rtf" "$STAGE/LICENSES/apple-game-porting-toolkit/License.rtf"
cp "$D3DMETAL/Apple-Acknowledgements.rtf" "$STAGE/LICENSES/apple-game-porting-toolkit/Acknowledgements.rtf"

log "Collecting the source"
COMMIT=$(git -C "$REPO" rev-parse HEAD)
crossover=$(fetch "$CROSSOVER_URL" "$CROSSOVER_SHA256")
cp "$crossover" "$OUT/wine-crossover-$CROSSOVER_VERSION-source.tar.gz"
cp "$DOWNLOADS/$(basename "$NETTLE_URL")" "$OUT/nettle-source.tar.gz"
cp "$DOWNLOADS/$(basename "$GNUTLS_URL")" "$OUT/gnutls-source.tar.xz"
cp "$DOWNLOADS/$(basename "$FREETYPE_URL")" "$OUT/freetype-source.tar.xz"
cp "$DOWNLOADS/$(basename "$SDL2_URL")" "$OUT/sdl2-source.tar.gz"
cp "$dxmt_src" "$OUT/dxmt-$DXMT_VERSION-source.tar.gz"
cp "$dxvk_src" "$OUT/dxvk-macos-$DXVK_VERSION-source.tar.gz"
git -C "$REPO" archive --format=tar.gz --prefix="corkscrew-build-scripts/" -o "$OUT/corkscrew-build-scripts-source.tar.gz" HEAD scripts tools

cat >"$STAGE/SOURCES.md" <<EOF
# Corkscrew engine $RELEASE

The Wine runtime and graphics components that Corkscrew downloads on first launch. Each component
keeps its own license (LICENSES/).

Built with Corkscrew's scripts at commit $COMMIT:
https://github.com/Prateek-Srivastav/corkscrew/tree/$COMMIT/scripts

| Component | Version | License | Source |
|---|---|---|---|
| Wine (CodeWeavers' winecx), with Corkscrew's patches in scripts/build-runtime.sh | $CROSSOVER_VERSION | LGPL 2.1 or later | wine-crossover-$CROSSOVER_VERSION-source.tar.gz |
| GnuTLS | 3.8.13 | LGPL 2.1 or later | gnutls-source.tar.xz |
| Nettle | 3.10 | LGPL 3 or GPL 2 | nettle-source.tar.gz |
| GMP (in the Wine source tarball) | | LGPL 3 or GPL 2 | wine-crossover-$CROSSOVER_VERSION-source.tar.gz |
| FreeType | 2.13.3 | FreeType License or GPL 2 | freetype-source.tar.xz |
| SDL2 | 2.32.10 | zlib | sdl2-source.tar.gz |
| MoltenVK | $MOLTENVK_VERSION | Apache 2.0 | https://github.com/KhronosGroup/MoltenVK/tree/v$MOLTENVK_VERSION |
| DXMT | $DXMT_VERSION | MIT | dxmt-$DXMT_VERSION-source.tar.gz |
| DXVK-macOS | $DXVK_VERSION | zlib | dxvk-macos-$DXVK_VERSION-source.tar.gz |
| D3DMetal, from Apple's Game Porting Toolkit | $GPTK_VERSION | Apple's license (LICENSES/apple-game-porting-toolkit): non-commercial redistribution only | Not open source |

The source archives are published with this pack:
https://github.com/Prateek-Srivastav/corkscrew/releases/tag/runtime-$RELEASE

D3DMetal is Apple's, not open source, and isn't covered by Corkscrew's GPL: Apple's license allows
redistributing it only for non-commercial purposes, so anything that sells Corkscrew or this pack
must leave it out.
EOF

log "Compressing $NAME.tar.xz (this takes a few minutes)"
tar -C "$OUT/stage" -cf - "$NAME" | xz -T0 -6 >"$OUT/$NAME.tar.xz"
rm -rf "$OUT/stage"
(cd "$OUT" && shasum -a 256 -- *.tar.* >SHA256SUMS)

SHA=$(shasum -a 256 "$OUT/$NAME.tar.xz" | cut -d' ' -f1)
SIZE=$(stat -f %z "$OUT/$NAME.tar.xz")
REPO_SLUG=$(git -C "$REPO" remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
URL="https://github.com/$REPO_SLUG/releases/download/runtime-$RELEASE/$NAME.tar.xz"
cat >"$REPO/Packages/GameCore/Sources/GameCore/Engines/EnginePackPin.swift" <<EOF
// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "$RELEASE",
        url: URL(string: "$URL")!,
        sha256: "$SHA",
        size: $SIZE
    )
}
EOF

log "Done: $OUT"
ls -lh "$OUT"
cat <<EOF

Next:
1. Commit EnginePackPin.swift (the app now downloads this pack).
2. Publish the pack and its source as a pre-release:
   gh release create runtime-$RELEASE --prerelease --title "Engine $RELEASE" \\
     --notes "Wine runtime and graphics components for Corkscrew. See SOURCES.md inside the pack." \\
     $OUT/*.tar.* $OUT/SHA256SUMS
EOF
