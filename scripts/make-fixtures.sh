#!/bin/bash
# Builds the Windows test and benchmark programs in fixtures/ into fixtures/bin with mingw-w64.
set -euo pipefail
cd "$(dirname "$0")/../fixtures"
mkdir -p bin
CC=x86_64-w64-mingw32-gcc
$CC -O2 -Wall -o bin/dx11_clear.exe dx11_clear.c -ld3d11 -ldxgi
$CC -O2 -Wall -o bin/dx12_clear.exe dx12_clear.c -ld3d12 -ldxgi
$CC -O2 -Wall -o bin/dx11_draws.exe dx11_draws.c -ld3d11 -ldxgi
$CC -O2 -Wall -o bin/win32_calls.exe win32_calls.c -lwinmm
ls -la bin
