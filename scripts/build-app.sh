#!/bin/bash
# Builds Corkscrew.app: generates the Xcode project from project.yml (XcodeGen), then builds it.
# Usage: build-app.sh [Debug|Release]   → build/DerivedData/Build/Products/<config>/Corkscrew.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-Debug}
command -v xcodegen >/dev/null || { echo "xcodegen is missing: run scripts/bootstrap.sh" >&2; exit 1; }
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 \
  || { echo "Xcode isn't set up yet: run sudo xcodebuild -runFirstLaunch" >&2; exit 1; }
xcodegen --quiet
xcodebuild -project Corkscrew.xcodeproj -scheme Corkscrew -configuration "$CONFIG" \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData build -quiet
APP="build/DerivedData/Build/Products/$CONFIG/Corkscrew.app"
# Register it with Launch Services so Finder offers it for .exe/.msi and corkscrew:// links work.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
