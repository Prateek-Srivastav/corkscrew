#!/bin/bash
# Runs the GameCore tests. With only the Command Line Tools installed, SwiftPM doesn't search
# the folder holding the Swift Testing macro plugin, so point it there. A no-op with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d $plugins ]]; then
  args+=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
exec swift test --package-path Packages/GameCore ${args[@]+"${args[@]}"} "$@"
