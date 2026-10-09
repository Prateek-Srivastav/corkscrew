#!/bin/bash
# Makes Steam's UI work under Wine: installs tools/steamwebhelper-wrapper in front of Steam's
# real steamwebhelper.exe (kept as steamwebhelper_real.exe). Safe to rerun; run it before each
# Steam launch, because Steam updates put the original back.
# Usage: steam-fix.sh <bottle prefix>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
PREFIX=${1:?usage: steam-fix.sh <bottle prefix>}
CEF="$PREFIX/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
WRAPPER="$BUILD/tools/steamwebhelper-wrapper.exe"

if [[ ! -f $WRAPPER || "$REPO/tools/steamwebhelper-wrapper/wrapper.c" -nt $WRAPPER ]]; then
  mkdir -p "$BUILD/tools"
  x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -o "$WRAPPER" "$REPO/tools/steamwebhelper-wrapper/wrapper.c"
fi
[[ -f $CEF/steamwebhelper.exe ]] || { echo "Steam's web helper not found; launch Steam once to let it update." >&2; exit 1; }

# Our wrapper names steamwebhelper_real.exe (UTF-16); Steam's own helper doesn't.
is_wrapper() { perl -0777 -ne 'exit(index($_, join("\0", split(//, "steamwebhelper_real.exe")) . "\0") < 0)' "$1"; }

if cmp -s "$WRAPPER" "$CEF/steamwebhelper.exe"; then
  echo "Wrapper already in place."
elif is_wrapper "$CEF/steamwebhelper.exe"; then
  # Another build of the wrapper (builds differ by timestamp): never move it over the real helper.
  cp "$WRAPPER" "$CEF/steamwebhelper.exe"
  echo "Wrapper updated."
else
  # Either first install or Steam restored its own helper during an update: keep the newest real one.
  mv -f "$CEF/steamwebhelper.exe" "$CEF/steamwebhelper_real.exe"
  cp "$WRAPPER" "$CEF/steamwebhelper.exe"
  echo "Wrapper installed in front of steamwebhelper_real.exe."
fi
