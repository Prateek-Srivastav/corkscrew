#!/bin/bash
# Smoke test: creates a throwaway bottle and runs the D3D test programs under every backend.
# A small window flashes for each run. Needs build-runtime.sh, install-components.sh, make-fixtures.sh.
# D3DMETAL_VERSION=4.0b2 tests another staged Game Porting Toolkit (default 3.0).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

RUNTIME="$BUILD/runtime/winecx-$CROSSOVER_VERSION"
COMPONENTS="$BUILD/components"
WINED3D="$RUNTIME/lib/wine-backends/wined3d"
D3DMETAL="$COMPONENTS/d3dmetal-${D3DMETAL_VERSION:-3.0}"
FIXTURES="$REPO/fixtures/bin"
LOGS="$BUILD/logs/smoke"
export WINEPREFIX="$BUILD/smoke/prefix"
WINE="$RUNTIME/bin/wine"

mkdir -p "$LOGS" "$WINEPREFIX" "/private/tmp/.wine-$(id -u)"
chmod 700 "/private/tmp/.wine-$(id -u)"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin WINEMSYNC=1 WINEDEBUG=-all ROSETTA_ADVERTISE_AVX=1
# DXVK writes <program>.dxvk-cache to the working folder unless told otherwise.
export DXVK_STATE_CACHE_PATH="$LOGS"

# run_timeout SECONDS CMD...: macOS has no timeout(1).
run_timeout() { perl -e 'alarm shift; exec @ARGV or die "$!"' "$@"; }

# Create the bottle, or update it so it gets placeholders for modules added to the runtime since.
[[ -f $WINEPREFIX/system.reg ]] && mode=--update || mode=--init
log "Preparing bottle $WINEPREFIX ($mode)"
WINEDLLPATH="$WINED3D" WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=" \
  run_timeout 300 "$WINE" wineboot "$mode" >"$LOGS/wineboot.log" 2>&1 || { tail -20 "$LOGS/wineboot.log"; exit 1; }
"$RUNTIME/bin/wineserver" -w

pass=0 fail=0
# check NAME BACKEND DLLPATH PROGRAM [VAR=VALUE...]
check() {
  local name=$1 backend=$2 dllpath=$3 program=$4; shift 4
  local log="$LOGS/$name.log"
  env "$@" CX_ACTIVE_GRAPHICS_BACKEND="$backend" WINEDLLPATH="$dllpath" \
    WINEDLLOVERRIDES="winemenubuilder.exe=" perl -e 'alarm shift; exec @ARGV or die "$!"' 90 \
    "$WINE" "$FIXTURES/$program" 120 >"$log" 2>&1
  local status=$?
  if [[ $status -eq 0 ]] && grep -q "^frames=120" "$log"; then
    pass=$((pass + 1)); printf '  PASS  %-18s %s\n' "$name" "$(grep -h -E '^(api|frames)=' "$log" | tr '\n' ' ')"
  else
    fail=$((fail + 1)); printf '  FAIL  %-18s exit %s, see %s\n' "$name" "$status" "$log"
    grep -E "^FAIL|err:" "$log" | head -3 | sed 's/^/        /'
  fi
}

log "Running D3D test programs"
check wined3d-dx11  wined3d "$WINED3D"                         dx11_clear.exe
check dxmt-dx11     dxmt    "$COMPONENTS/dxmt-$DXMT_VERSION:$WINED3D" dx11_clear.exe
check dxvk-dx11     dxvk    "$COMPONENTS/dxvk-macos-$DXVK_VERSION:$WINED3D" dx11_clear.exe
check vkd3d-dx12    wined3d "$WINED3D"                         dx12_clear.exe
if [[ -d $D3DMETAL ]]; then
  gptk=(CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DMETAL/external/libd3dshared.dylib")
  check d3dmetal-dx11 d3dmetal "$D3DMETAL/wine:$WINED3D" dx11_clear.exe "${gptk[@]}"
  check d3dmetal-dx12 d3dmetal "$D3DMETAL/wine:$WINED3D" dx12_clear.exe "${gptk[@]}"
else
  echo "  SKIP  d3dmetal (run install-components.sh with your Game Porting Toolkit image)"
fi

"$RUNTIME/bin/wineserver" -k 2>/dev/null
log "$pass passed, $fail failed (logs: $LOGS)"
[[ $fail -eq 0 ]]
