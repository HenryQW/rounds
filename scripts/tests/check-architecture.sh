#!/bin/sh
# Check that the architecture gate accepts a platform import and rejects boundary violations.
set -eu
check="$(cd "$(dirname "$0")/.." && pwd)/check-architecture.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
mkdir -p 'Sources/Core Fixture' Sources/rounds-hook
printf 'print("fixture")\n' > Sources/rounds-hook/main.swift

cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "BoundaryFixture", targets: [
    .target(name: "RoundsCore", path: "Sources/Core Fixture", exclude: ["Excluded.swift"]),
    .executableTarget(name: "rounds-hook", dependencies: ["RoundsCore"]),
])
SWIFT
printf 'import Foundation\n' > 'Sources/Core Fixture/Valid.swift'
printf 'import AppKit\n' > 'Sources/Core Fixture/Excluded.swift'
"$check"

cat > 'Sources/Core Fixture/Invalid.swift' <<'SWIFT'
#if os(macOS) && SWIFT_PACKAGE && DEBUG
import struct AppKit.NSSize
#elseif os(macOS) && SWIFT_PACKAGE
import SwiftUI
#endif
SWIFT
if "$check" > result 2>&1; then
    echo 'Boundary check accepted a user interface import in RoundsCore.' >&2
    exit 1
fi
if ! grep -Fx AppKit result >/dev/null || ! grep -Fx SwiftUI result >/dev/null; then
    cat result >&2
    exit 1
fi

cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "BoundaryFixture", targets: [
    .target(name: "PlatformAdapter"),
    .target(name: "RoundsCore", dependencies: ["PlatformAdapter"]),
    .executableTarget(name: "rounds-hook", dependencies: ["RoundsCore"]),
])
SWIFT
if "$check" > result 2>&1; then
    echo 'Boundary check accepted a target dependency in RoundsCore.' >&2
    exit 1
fi
if ! grep -F 'RoundsCore must have no target or product dependencies.' result >/dev/null; then
    cat result >&2
    exit 1
fi
printf 'Architecture check fixtures passed.\n'
