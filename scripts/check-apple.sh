#!/usr/bin/env bash
# Compiles the Apple-only code (SystemHost, CrashCapture) for every platform, which Linux CI cannot do.
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd)"
derived="${UNHANDLED_APPLE_CHECK_BUILD:-/tmp/unhandled-swift-apple-check}"
swift="${SWIFT:-/usr/bin/swift}"

echo "== macOS: swift build"
"$swift" build --package-path "$package" --scratch-path "$derived/macos" -Xswiftc -warnings-as-errors

for destination in "iOS Simulator" "tvOS Simulator" "watchOS Simulator" "visionOS Simulator"; do
    echo "== $destination: xcodebuild"
    (cd "$package" && xcodebuild build \
        -quiet \
        -scheme Unhandled \
        -destination "generic/platform=$destination" \
        -derivedDataPath "$derived/xcode" \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES)
done

echo "== signal handler"
"$package/scripts/check-signal-handler.sh"

echo "check-apple: all Apple platforms build"
