# Unhandled for Swift

Errors, crashes, product analytics, revenue, experiments and app start telemetry for iOS, iPadOS, macOS, tvOS, visionOS and watchOS apps. It sends the same data as `@unhandled/react-native`, so a native app and an Expo app show up the same way in Unhandled.

No third-party dependencies. No device identifiers.

## Install

Add the package in Xcode (File > Add Package Dependencies) or in `Package.swift`:

```swift
.package(url: "https://github.com/treboryx/unhandled-swift", from: "0.1.0")
```

and add the `Unhandled` product to your app target. The mirror repository is not published yet, see [Release](#release).

Requirements: Xcode 16 or later (Swift 6 toolchain), iOS 13, macOS 10.15, tvOS 13, watchOS 6, visionOS 1.

## Start

Start the SDK once, as early as you can, so crashes during launch are caught.

SwiftUI:

```swift
import SwiftUI
import Unhandled

@main
struct ShopApp: App {
    init() {
        Unhandled.start(Options(
            dsn: "https://uh_live_…@ingest.unhandled.net/<service-id>",
            environment: .production
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

UIKit:

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Unhandled.start(Options(dsn: "https://uh_live_…@ingest.unhandled.net/<service-id>", environment: .production))
    return true
}
```

`start` returns the client, and `Unhandled.shared` returns it anywhere else. Before `start`, or when the DSN is empty or invalid, `Unhandled.shared` is an inactive client: every call is accepted and nothing is sent. A second `start` keeps the first client.

### Options

| Option | Default | |
|---|---|---|
| `dsn` | required | An empty string gives an inactive client, which is handy in debug builds. |
| `environment` | required | `.production`, `.staging` or `.development`. |
| `release` | `bundleId@version+build` | Groups errors by release. |
| `sampleRate` | `1` | Share of errors sent, 0 to 1. |
| `tracesSampleRate` | `1` | Share of app start, resume and screen spans sent. |
| `ignoreErrors` | `[]` | `"text"` drops errors whose message contains it; `.matching { $0.type == "…" }` drops by predicate. |
| `queueLimits` | 4 MB, 200 envelopes | Offline queue caps. |
| `enabled` | `true` | `false` gives an inactive client. |
| `storageDirectory` | `Caches/unhandled/<service-id>/` | Where the offline queue lives. |
| `captureCrashes` | `true` | Uncaught Objective-C exceptions and fatal signals. |

## Errors

```swift
do {
    try checkout.submit()
} catch {
    Unhandled.shared.captureError(error, context: CaptureContext(
        tags: ["flow": "checkout"],
        extra: ["cartSize": cart.count]
    ))
}

Unhandled.shared.captureException(exception)          // an NSException you caught
Unhandled.shared.captureMessage("Payment slow", level: .warning)
Unhandled.shared.setUser(CaptureUser(id: "42", email: "ana@example.com"))
```

`NSError` values report their domain and code as the type, and their underlying error (`NSUnderlyingErrorKey`) as the cause. Swift errors report their type name and `errorDescription` (for a `LocalizedError`) or description. The stack is captured where you call `captureError`. The same error object is reported once.

## Analytics

Analytics are anonymous until you call `identify`. Events sent before it count toward totals but belong to no one: there is no device id, install id or cookie to tie them together.

```swift
Unhandled.shared.track("checkout_started", properties: ["items": 3, "total": 59.9, "gift": false])

Unhandled.shared.identify(user.id, properties: ["plan": "pro"])   // on sign-in
Unhandled.shared.setUserProperties(["plan": "team"])              // after identify
Unhandled.shared.reset()                                          // on sign-out
```

`identify` also sets the error user. Property bags take up to 20 entries; keys are 1 to 64 bytes, strings up to 256 bytes, numbers must be finite. Event properties cannot use `user_id`, `email`, `distinct_id`, `anonymous_id`, `session_id` or the `user.`, `trace.`, `span.` and `unhandled.` prefixes. A call that breaks a rule is dropped.

## Revenue

Amounts are integers in the currency's minor unit: 1999 is $19.99. A negative amount is a refund.

```swift
Unhandled.shared.trackRevenue(Revenue(
    amount: 1999,
    currency: "USD",
    id: transaction.id,                       // resending the same id counts the charge once
    product: "pro",
    subscription: .init(id: "sub_123", interval: .month)
))
```

## Experiments

```swift
let variant = Unhandled.shared.getVariant("paywall", variants: ["control", "annual-first"])
let weighted = Unhandled.shared.getVariant("pricing-page", variants: [Variant("control", weight: 3), "green"])

Unhandled.shared.trackExposure("onboarding", variant: myOwnAssignment)
```

An identified user gets the same variant on every call, in every Unhandled SDK, with no network request. The first `getVariant` per experiment and variant in a run records an exposure. Before `identify`, `getVariant` returns the first variant and records nothing, so a user can move to their own variant when they sign in. `trackExposure` records a variant you assigned yourself and does nothing before `identify`.

## Screens and app start

```swift
Unhandled.shared.trackScreen("Checkout")   // from onAppear or viewDidAppear
Unhandled.shared.appReady()                // if you don't track screens
```

A screen change sends a span named after the screen, from the call to the next frame, and tags later errors with `app.screen.name`. The first screen (or `appReady()`) ends the `app start` span, measured from process start. Returning from the background sends an `app resume` span.

## Flush and shutdown

```swift
await Unhandled.shared.flush()      // before a planned exit
await Unhandled.shared.shutdown()   // removes crash handlers, flushes, stops
```

## Privacy

The SDK sends the OS name and version and a device class (phone, tablet, tv, desktop, vision). It never reads or sends the IDFA, the IDFV (`identifierForVendor`), the device model, an install id, the locale or the IP address, and it does not link AdSupport or AppTrackingTransparency. Requests carry no cookies. Users are known only through `identify` and `setUser`, with the values you pass.

## Offline queue

Every error is written to disk before the capture call returns, which costs the calling thread one small file write. Analytics and spans do no file I/O on the calling thread: they are buffered in memory for up to a second (or 50 records, or 30 KB) and then written on the SDK's own queue. Going to the background, `flush`, `shutdown` and an uncaught exception write the buffer synchronously. Files are sent oldest first, one at a time. A 408, 429, 5xx or network error keeps the file and retries with exponential backoff, from 1 to 2 seconds up to 5 minutes; coming back to the foreground retries at once. Any other rejection drops the file. When the queue passes its caps it drops the oldest analytics first and keeps errors as long as it can. Whatever is still on disk is sent on the next launch.

## Crashes

With `captureCrashes` on (the default, Apple platforms only):

- An uncaught `NSException` is written to disk as a fatal error before the previous handler runs.
- `SIGABRT`, `SIGBUS`, `SIGFPE`, `SIGILL`, `SIGSEGV` and `SIGTRAP` are caught by a signal handler that writes the signal, the faulting address, the raw stack addresses and the binary images loaded at that moment (name, UUID, load address, including libraries opened with `dlopen` after `start`) to a file opened at start. The report is sent on the next launch.
- After writing, the handler hands the signal on with its original context. A handler installed before Unhandled gets the original `(signal, info, context)`. With no previous handler, a hardware fault returns and re-runs the faulting instruction under the default action, so the system crash report still shows the real fault; `SIGABRT` and signals sent with `kill` are re-raised.
- An uncaught `NSException` ends in `SIGABRT`; that signal is not reported a second time.

Limits:

- A Swift runtime trap (force unwrap of nil, array index out of range, `fatalError`) arrives as `SIGTRAP` or `SIGILL` with addresses only; the trap message is lost.
- Watchdog terminations, out-of-memory kills and other `SIGKILL`s cannot be caught by any in-process handler and are not reported.
- The signal handler does only async-signal-safe work and never allocates: everything it touches is allocated in `start`, and `scripts/check-signal-handler.sh` checks the release build for that. One known gap remains: `backtrace()` is not on the POSIX safe list, so it is called once at start to load its code; Apple's implementation walks frame pointers without allocating, but that is not a documented guarantee.
- The alternate signal stack is installed only on the thread that calls `start`. A stack overflow on any other thread leaves the handler no stack to run on, so it goes unreported. tvOS and watchOS have no alternate stacks, so no stack overflow is reported there.
- The image list holds up to 1024 images. Frames in images past that limit show as unknown images.
- A crash reporter installed after Unhandled decides whether to chain to it; one installed before is chained.
- A crash report is sent with the next launch's release, which differs from the crashed one after an update.

## Symbolication

Native frames carry `instruction_addr`, `image_addr` (load address) and `image_uuid`, plus the symbol name when the binary has one. Unhandled does not symbolicate native frames on the server yet, so keep each release's dSYM: the `dSYMs` folder of the Xcode archive, or the output of `xcodebuild -exportArchive`. To symbolicate a frame locally:

```sh
atos -arch arm64 -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -l <image_addr> <instruction_addr>
```

Match the dSYM to the frame with `dwarfdump --uuid MyApp.app.dSYM` and the frame's `image_uuid`. dSYM upload arrives with server-side symbolication ([#336](https://github.com/treboryx/unhandled/issues/336)).

## Size

Measured on 2026-10-30 with Xcode 27 (Swift 6.4), release builds, arm64: linking the SDK into a macOS command-line tool adds 224 KiB of `__TEXT` and 289 KiB to the stripped (`strip -x`) executable. The iOS arm64 release object is 224 KiB of `__TEXT` and 62 KiB of `__DATA` before dead stripping.

## Development

```sh
swift build
swift test
scripts/check-apple.sh
docker run --rm -v "$PWD":/src -w /src swift:6.2-noble swift test --scratch-path /tmp/build
```

CI runs only on Linux. It builds and tests the core, but it does not compile the Apple-only code (`SystemHost`, `CrashCapture`). `scripts/check-apple.sh` is the required local check before every release: it builds for macOS and, with `xcodebuild`, for the iOS, tvOS, watchOS and visionOS simulators, with warnings as errors, then runs `scripts/check-signal-handler.sh`. That script disassembles the release build and fails if the signal handler, or any SDK function it calls, can reach `swift_once`, an allocator, or a retain or release.

## Release

Publishing needs the owner's approval. The steps, from the monorepo root:

1. `git subtree split --prefix packages/swift -b swift-release`
2. `git push git@github.com:treboryx/unhandled-swift.git swift-release:main`
3. In `treboryx/unhandled-swift`, tag `0.1.0` on `main` and push the tag.

Bump `SDK.version` in `Sources/Unhandled/Client.swift` before each release; it is the only place the version lives.
