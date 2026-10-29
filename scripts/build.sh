#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Crema.xcodeproj -scheme Crema -configuration Release -derivedDataPath .build -destination 'platform=macOS,arch=arm64' build
print "Built: $PWD/.build/Build/Products/Release/Crema.app"
