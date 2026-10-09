#!/bin/bash
# Installs the native (arm64) tools needed to build the Wine runtime and the app. No sudo, no Intel Homebrew:
# x86_64 libraries are cross-compiled from source by build-deps.sh.
set -euo pipefail

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || { echo "Rosetta 2 is required: softwareupdate --install-rosetta" >&2; exit 1; }

# mingw-w64 is gcc-based on purpose: llvm-mingw builds of Wine stall Steam's login.
brew install mingw-w64 bison flex pkgconf ccache cmake
# Generates Corkscrew.xcodeproj from project.yml (the SwiftUI app, M2 on).
brew install xcodegen

echo "Build tools ready."
