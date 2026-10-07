#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift test
xcodebuild -project QuantumAuxBridge.xcodeproj -scheme QuantumAuxBridge -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
