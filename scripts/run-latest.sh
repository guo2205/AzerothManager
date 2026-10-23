#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project AzerothManager.xcodeproj -scheme AzerothManager -configuration Release \
  -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- build > /tmp/azeroth-latest-build.log 2>&1
built="$PWD/DerivedData/Build/Products/Release/AzerothManager.app"
[[ -x "$built/Contents/MacOS/AzerothManager" ]]
# Stop only this app's executable before replacing its project-owned distribution.
pkill -x AzerothManager || true
mkdir -p outputs
rm -rf -- outputs/AzerothManager.app
cp -R "$built" outputs/AzerothManager.app
for archive in outputs/AzerothManager-v*.app.zip(N); do rm -- "$archive"; done
# The original project-level distribution was superseded by outputs/.
if [[ -f ../AzerothManager-macOS.app.zip ]]; then rm -- ../AzerothManager-macOS.app.zip; fi
# Preserve one canonical distribution bundle; Xcode can rebuild its product next run.
rm -rf -- "$built"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent outputs/AzerothManager.app outputs/AzerothManager-v0.8.app.zip
open "$PWD/outputs/AzerothManager.app"
