#!/bin/bash
# Stages the graphics backends as WINEDLLPATH folders in build/components:
#   dxmt-<v>/  dxvk-macos-<v>/   {x86_64-windows,i386-windows,x86_64-unix}
#   d3dmetal-<v>/{external,wine} from Apple's Game Porting Toolkit download (package-engine.sh ships 3.0).
# Usage: install-components.sh [path/to/Game_Porting_Toolkit_<version>.dmg]
# Each toolkit version gets its own folder (3.0, 4.0b2…), so several can be staged side by side.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

COMPONENTS="$BUILD/components"
mkdir -p "$COMPONENTS"

# builtin_tarball NAME URL SHA256: unpack a "builtin" release whose top folder holds the arch folders.
builtin_tarball() {
  local dest="$COMPONENTS/$1" tarball tmp
  [[ -d $dest ]] && { echo "$1: already staged"; return; }
  tarball=$(fetch "$2" "$3")
  tmp=$(mktemp -d)
  tar -xzf "$tarball" -C "$tmp"
  local tops=("$tmp"/*/)
  [[ ${#tops[@]} -eq 1 && -d ${tops[0]} ]] \
    || { echo "$1: expected one top folder in $(basename "$tarball"), found ${#tops[@]}" >&2; rm -rf "$tmp"; exit 1; }
  mv "${tops[0]}" "$dest"
  rm -rf "$tmp"
  echo "$1: $(cd "$dest" && find . -name '*.dll' -o -name '*.so' | sort | tr '\n' ' ')"
}

builtin_tarball "dxmt-$DXMT_VERSION" "$DXMT_URL" "$DXMT_SHA256"
builtin_tarball "dxvk-macos-$DXVK_VERSION" "$DXVK_URL" "$DXVK_SHA256"

# DXMT's winemetal has a Mac half linked against the runtime's own ntdll.so and winemac.so, so it
# must live in the runtime's lib/wine (it replaces nothing there). It stays in the DXMT folder too,
# so this script can reinstall it after a runtime rebuild. Bottles pick it up on their next
# `wineboot -u`, which creates its placeholder in system32; without one Wine never looks for it.
RUNTIME="$BUILD/runtime/winecx-$CROSSOVER_VERSION"
DXMT="$COMPONENTS/dxmt-$DXMT_VERSION"
[[ -d $RUNTIME/lib/wine ]] || { echo "Build the runtime before installing DXMT." >&2; exit 1; }
for f in x86_64-windows/winemetal.dll i386-windows/winemetal.dll x86_64-unix/winemetal.so; do
  cmp -s "$DXMT/$f" "$RUNTIME/lib/wine/$f" || cp "$DXMT/$f" "$RUNTIME/lib/wine/$f"
done
echo "dxmt: winemetal installed in the runtime"

GPTK_DMG=${1:-$HOME/Downloads/Game_Porting_Toolkit_3.0.dmg}
# Game_Porting_Toolkit_4.0_beta_2.dmg -> 4.0b2
GPTK_VERSION=$(basename "$GPTK_DMG" .dmg | sed -E 's/^Game_Porting_Toolkit_//; s/_beta_/b/')
[[ $GPTK_VERSION =~ ^[0-9][0-9a-z.]*$ ]] || { echo "Can't read a toolkit version from $(basename "$GPTK_DMG")." >&2; exit 1; }
DEST="$COMPONENTS/d3dmetal-$GPTK_VERSION"
if [[ -d $DEST ]]; then
  echo "d3dmetal-$GPTK_VERSION: already staged"
elif [[ ! -f $GPTK_DMG ]]; then
  echo "d3dmetal: skipped, no Game Porting Toolkit image at $GPTK_DMG"
else
  # The toolkit image holds the evaluation environment as a second, nested image.
  # Staged next to its final place and renamed at the end, so an interrupted run doesn't leave a
  # partial folder that the next run would take for a finished one.
  outer=$(mktemp -d) inner=$(mktemp -d) staging="$DEST.partial"
  trap 'hdiutil detach -quiet "$inner" 2>/dev/null; hdiutil detach -quiet "$outer" 2>/dev/null; rmdir "$inner" "$outer" 2>/dev/null; rm -rf "$staging"' EXIT
  rm -rf "$staging"
  hdiutil attach -quiet -readonly -nobrowse -noverify -mountpoint "$outer" "$GPTK_DMG"
  hdiutil attach -quiet -readonly -nobrowse -noverify -mountpoint "$inner" "$outer"/Evaluation*environment*.dmg
  cp -R "$inner/redist/lib" "$staging"
  # Apple's license asks for its notices to travel with every copy.
  cp "$inner/License.rtf" "$staging/Apple-License.rtf"
  cp "$inner/Acknowledgements.rtf" "$staging/Apple-Acknowledgements.rtf"
  # Which image this came from; package-engine.sh only ships D3DMetal from the pinned one.
  shasum -a 256 "$GPTK_DMG" | cut -d' ' -f1 >"$staging/gptk-image.sha256"
  # The Windows side looks for nvngx; GPTK ships it as nvngx-on-metalfx.
  mv "$staging/wine/x86_64-windows/nvngx-on-metalfx.dll" "$staging/wine/x86_64-windows/nvngx.dll"
  mv "$staging/wine/x86_64-unix/nvngx-on-metalfx.so" "$staging/wine/x86_64-unix/nvngx.so"
  # The .so files find libd3dshared through @loader_path (their own folder).
  ln -s ../../external/libd3dshared.dylib "$staging/wine/x86_64-unix/libd3dshared.dylib"
  mv "$staging" "$DEST"
  echo "d3dmetal-$GPTK_VERSION: $(cd "$DEST/wine" && find . -name '*.dll' | sort | tr '\n' ' ')"
fi
