# Unhandled for Swift

The Swift SDK for [Unhandled](https://unhandled.net): errors, crashes, analytics events, identify, revenue and experiments from iOS, iPadOS, macOS, tvOS, watchOS and visionOS apps. No third-party dependencies, no device identifiers.

```swift
.package(url: "https://github.com/treboryx/unhandled-swift", from: "0.1.0")
```

Add the `Unhandled` product to your app target, then follow the [Swift SDK docs](https://unhandled.net/docs/sdks/swift).

## About this repository

This is a release mirror. The SDK is developed in the Unhandled monorepo (`treboryx/unhandled`, under `packages/swift`). Each release tag here is that directory at the release commit, split out with `git subtree split` so Swift Package Manager can resolve it from a repository root. The `main` branch holds only this README and the license; browse a tag for the source.

Requirements: Xcode 16 or later (Swift 6 toolchain), iOS 13, macOS 10.15, tvOS 13, watchOS 6, visionOS 1.

## License

MIT
