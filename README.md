# USBConnection
Lightweight Swift package for observing USB plug and unplug events on macOS. It wraps IOKit notifications behind a Swift Concurrency API so you can handle connection changes with an `AsyncThrowingStream` and optional vendor/product filtering.

- macOS 13.0+
- Swift Package Manager
- Uses IOKit under the hood; no polling

## Installation

Add the package to your `Package.swift` dependencies:

```swift
// swift-tools-version: 6.0
dependencies: [
    .package(url: "https://github.com/Emerah/USBConnection.git", branch: "main")
]
```

Then add `"USBConnection"` to the target that needs it:

```swift
.target(
    name: "YourTarget",
    dependencies: ["USBConnection"]
)
```

In Xcode: File → Add Packages… → paste the repository URL → add to your app target.

## Quick start: observe all USB devices

```swift
import USBConnection

let manager = USBConnectionManager()

Task {
    do {
        let stream = try await manager.monitorDevices()

        for try await event in stream {
            switch event {
            case .deviceConnected(let service):
                print("Connected:", service.registryID ?? 0,
                      "service:", service.service)

            case .deviceDisconnected(let service):
                print("Disconnected:", service.registryID ?? 0)
            }
        }
    } catch {
        print("USB monitoring failed:", error.localizedDescription)
    }
}
```

Keep a strong reference to `manager` for as long as you want to receive events.

## Filter to a specific device

Use vendor/product IDs and optional product/manufacturer/serial strings to limit notifications:

```swift
import USBConnection

// Example: Apple Magic Keyboard (replace with your device IDs)
let criteria = USBConnectionManager.DeviceMatchingCriteria(
    vendorID: 0x05AC,
    productID: 0x024F,
    productName: "Magic Keyboard"
)
let manager = USBConnectionManager()

Task {
    let stream = try await manager.monitorDevices(matchingCriteria: criteria)
    for try await event in stream {
        if case .deviceConnected(let service) = event {
            print("Matched device:", service.registryID ?? 0)
        }
    }
}
```

## Stopping monitoring

Call `endMonitoringActivity()` when you no longer need updates. The stream will finish and IOKit resources are released.

```swift
let task = Task {
    let stream = try await manager.monitorDevices()
    for try await _ in stream { /* ... */ }
}

// Later, when done:
await manager.endMonitoringActivity()
task.cancel()
```

If the consumer finishes or cancels the stream, the actor also cleans up automatically.

## What the API provides

- `USBConnectionManager`: actor that owns IOKit callbacks and the stream lifecycle.
- `monitorDevices(matchingCriteria:)`: starts monitoring and returns `AsyncThrowingStream<USBConnectionManager.Notification, Error>`.
- `Notification`: `.deviceConnected(DeviceReference)` and `.deviceDisconnected(DeviceReference)`.
- `DeviceReference`: retained `io_service_t` handle with an optional `registryID`.
- `DeviceMatchingCriteria`: vendor/product filter with optional product/manufacturer/serial strings.
- Errors (`USBConnectionError`): invalid continuation, duplicate monitoring, missing IOKit objects, or kernel status failures.

## Tips and troubleshooting

- Events are delivered on an internal queue; the actor ensures thread safety.
- `DeviceReference` does not parse metadata; query the IOKit registry if you need names or IDs.
- Logging uses `USBLogger` and only prints in `DEBUG` builds.
- If you see `monitoringAlreadyStarted`, call `endMonitoringActivity()` before starting again.
- App sandboxing: if you sandbox your app, ensure it can access USB devices; entitlement requirements vary by app type.

## Minimal integration checklist

1. Import `USBConnection` and hold a `USBConnectionManager` strongly.
2. Call `monitorDevices()` from an async context and iterate the returned stream.
3. Handle `.deviceConnected` and `.deviceDisconnected` cases.
4. Optionally provide `DeviceMatchingCriteria` to filter events (vendor/product plus optional product/manufacturer/serial strings).
5. Call `endMonitoringActivity()` when finished (or on teardown).
