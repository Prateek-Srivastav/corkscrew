#!/bin/bash
# Benchmark: what the translation layer costs, in the smoke test's bottle (run smoke.sh once first).
#  - win32_calls: Wine system calls, synchronisation and timers.
#  - dx11_draws: CPU cost per D3D11 draw call on each backend, with the settings the app launches
#    games with (LaunchPlanner). A window shows for each run.
# Usage: bench.sh [draws per frame (default 100000)] [seconds per run (default 5)]
# Compare runs on the same Mac, plugged in, with other apps quiet. DXMT and DXVK vary by a few
# percent between runs, D3DMetal by up to 20%: run it twice before drawing conclusions.
# Extra variables pass through to every run, e.g. MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 bench.sh.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

DRAWS=${1:-100000}
SECONDS_PER_RUN=${2:-5}
RUNTIME="$BUILD/runtime/winecx-$CROSSOVER_VERSION"
COMPONENTS="$BUILD/components"
WINED3D="$RUNTIME/lib/wine-backends/wined3d"
D3DMETAL="$COMPONENTS/d3dmetal-${D3DMETAL_VERSION:-3.0}"
FIXTURES="$REPO/fixtures/bin"
LOGS="$BUILD/logs/bench"
export WINEPREFIX="$BUILD/smoke/prefix"
WINE="$RUNTIME/bin/wine"

[[ -f $WINEPREFIX/system.reg ]] || { echo "Run scripts/smoke.sh first: it creates the bottle." >&2; exit 1; }
[[ -f $FIXTURES/dx11_draws.exe && -f $FIXTURES/win32_calls.exe ]] || { echo "Run scripts/make-fixtures.sh first." >&2; exit 1; }
mkdir -p "$LOGS"
# As LaunchPlanner sets them for games.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin WINEMSYNC=1 WINEDEBUG=-all ROSETTA_ADVERTISE_AVX=1
export MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=${MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS:-0}
export MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=${MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION:-1}

# run NAME BACKEND DLLPATH [VAR=VALUE...] -- PROGRAM [ARGS...]: output goes to $LOGS/NAME.log.
run() {
  local name=$1 backend=$2 dllpath=$3 vars=(); shift 3
  while [[ $1 != -- ]]; do vars+=("$1"); shift; done; shift
  env ${vars[@]+"${vars[@]}"} CX_ACTIVE_GRAPHICS_BACKEND="$backend" WINEDLLPATH="$dllpath" \
    WINEDLLOVERRIDES="winemenubuilder.exe=" perl -e 'alarm shift; exec @ARGV or die "$!"' 300 "$WINE" "$@" \
    >"$LOGS/$name.log" 2>&1
}

log "Win32 calls (log: $LOGS/win32-calls.log)"
run win32-calls wined3d "$WINED3D" -- "$FIXTURES/win32_calls.exe"
grep -vE '^(sink|qpc_frequency)=|^[[:space:]]|^\[mvk|^msync:' "$LOGS/win32-calls.log" | sed 's/^/  /'

log "D3D11, $DRAWS draws per frame, $SECONDS_PER_RUN s each (CPU-bound: more fps is less overhead)"
# draws NAME BACKEND DLLPATH [VAR=VALUE...]
draws() {
  run "$@" -- "$FIXTURES/dx11_draws.exe" "$DRAWS" "$SECONDS_PER_RUN"
  printf '  %-10s %s\n' "$1" "$(grep -E '^(frames=|FAIL)' "$LOGS/$1.log" || echo "FAIL, see $LOGS/$1.log")"
}
mkdir -p "$LOGS/cache"
draws dxmt dxmt "$COMPONENTS/dxmt-$DXMT_VERSION:$WINED3D" DXMT_SHADER_CACHE_PATH="$LOGS/cache"
if [[ -d $D3DMETAL ]]; then
  draws d3dmetal d3dmetal "$D3DMETAL/wine:$WINED3D" CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DMETAL/external/libd3dshared.dylib"
else
  echo "  SKIP  d3dmetal (run install-components.sh with your Game Porting Toolkit image)"
fi
draws dxvk dxvk "$COMPONENTS/dxvk-macos-$DXVK_VERSION:$WINED3D" DXVK_ASYNC=1 DXVK_STATE_CACHE_PATH="$LOGS/cache"

"$RUNTIME/bin/wineserver" -k 2>/dev/null
