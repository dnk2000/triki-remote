#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/ModuleCache
xcrun swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$PWD/build/ModuleCache" \
  TrikiMediaButton/TrikiBluetoothManager.swift TrikiMediaButton/MediaKeyController.swift TrikiMediaButton/MeetingController.swift Tests/TrikiRemoteTests.swift \
  -o build/TrikiRemoteTests
build/TrikiRemoteTests "$@"
