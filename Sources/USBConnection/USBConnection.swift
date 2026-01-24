// Package: USBConnection
// File: USBConnection.swift
// Path: Sources/USBConnection/USBConnection.swift
// Date: 2025-11-23
// Author: Ahmed Emerah
// Email: ahmed.emerah@icloud.com
// Github: https://github.com/Emerah



import Foundation
import IOKit
import IOKit.usb



public typealias USBConnectionManager = USBConnection.USBConnectionManager
public typealias USBConnectionError = USBConnection.USBConnectionError
public typealias USBConnectionStream = AsyncThrowingStream<USBConnectionManager.Notification, Error>

fileprivate typealias USBLogger = USBConnection.USBLogger


/// Primary namespace for USB connection management types.
/// - Discussion: All USBKit connection types live under this namespace to avoid polluting the global scope.
public enum USBConnection {
    // USBConnection.USBConnectionManager
    // USBConnection.USBConnectionManager.ConnectionEvent [private]
    // USBConnection.USBConnectionManager.IteratorRegistry [private]
    // USBConnection.USBConnectionManager.DeviceReference
    // USBConnection.USBConnectionManagerNotification
    // USBConnection.USBConnectionManager.DeviceMatchingCriteria
    // USBConnection.USBConnectionError
}


// MARK: - DECLARE USB CONNECTION MANAGER
extension USBConnection {

    /// Actor that manages USB device connection monitoring.
    /// - Discussion: Create an instance to observe USB plug and unplug events and receive notifications asynchronously.
    public final actor USBConnectionManager {        
        /// Dispatch queue used to deliver IOKit notifications.
        /// - Returns: Queue that hosts notification callbacks.
        /// - Discussion: Internal queue ensures callbacks arrive on a predictable thread context.
        private let notificationQueue = DispatchQueue(label: "com.usbkit.connection.notifications", qos: .default)
        
        /// IOKit notification port associated with the monitoring session.
        /// - Returns: Notification port created for the current session, if any.
        /// - Discussion: Holds the port returned by `IONotificationPortCreate` while monitoring is active.
        private var notificationPort: IONotificationPortRef? = nil
        
        /// Continuation that feeds the public `USBConnectionStream`.
        /// - Returns: Continuation used to emit connection notifications to the consumer stream.
        /// - Discussion: Stored while monitoring so callbacks can yield connection notifications.
        private var continuation: USBConnectionStream.Continuation?
        
        /// Opaque context passed to IOKit callbacks.
        /// - Returns: Pointer retaining the actor instance for C callbacks.
        /// - Discussion: Retains a reference to `self` for use in C-style callbacks.
        private var connectionContext: UnsafeMutableRawPointer?
        
        /// Registry of active iterators for match/termination notifications.
        /// - Returns: Container for IOKit iterators while monitoring.
        /// - Discussion: Maintains ownership of IOKit iterators so they can be released during cleanup.
        private var iteratorRegistry: IteratorRegistry?
        
        /// Optional vendor/product filter applied to the matching dictionary.
        /// - Returns: Criteria restricting which devices trigger notifications, if provided.
        /// - Discussion: When provided, only USB devices matching this criteria trigger notifications.
        private var deviceMatchingCriteria: DeviceMatchingCriteria?
        
        /// Indicates whether monitoring is currently active.
        /// - Returns: `true` when monitoring has been started and not yet ended.
        /// - Discussion: Used internally to prevent duplicate monitoring sessions and gate cleanup.
        private var isMonitoring = false

        /// Creates a connection manager with no filtering criteria.
        /// - Discussion: Use this initializer to observe all USB device events.
        public init() {}
        
    }
}


// MARK: - PUBLIC API INTERFACE
extension USBConnection.USBConnectionManager {

    /// Starts monitoring USB devices and returns a stream of connection notifications.
    /// - Parameter matchingCriteria: Optional filtering criteria for matching devices. Pass `nil` to observe all USB devices.
    /// - Returns: An async throwing stream that yields `Notification` events.
    /// - Throws: `USBConnectionError` when monitoring cannot be started.
    /// - Discussion: Call this from an async context to begin observing USB plug and unplug events. Keep the returned stream alive for the lifetime of your observation. Invoke `endMonitoringActivity()` when you no longer need notifications.
    public func monitorDevices(matchingCriteria: DeviceMatchingCriteria? = nil) throws -> USBConnectionStream {
        self.deviceMatchingCriteria = matchingCriteria
        var tempContinuation: USBConnectionStream.Continuation?
        let stream = USBConnectionStream(bufferingPolicy: .bufferingOldest(64)) { tempContinuation = $0 }

        guard let continuation = tempContinuation else {
            let error = USBConnectionError.invalidContinuation
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }

        try startMonitoringDevices(continuation: continuation)
        return stream
    }

    /// Ends the active monitoring session and cleans up resources.
    /// - Discussion: Call this when you no longer need USB notifications to release IOKit resources and finish the stream.
    public func endMonitoringActivity() {
        guard isMonitoring else { return }
        continuation?.finish()
        continuation = nil
        cleanupIOKitResources()
        USBLogger.info("\(#function) succeeded")
    }
}


// MARK: - MONITORING ENGINE
extension USBConnection.USBConnectionManager {
    /// Configures IOKit notifications and begins draining USB events.
    /// - Parameter continuation: Continuation used to emit connection notifications.
    /// - Throws: `USBConnectionError` when monitoring setup fails.
    /// - Discussion: This internal helper wires up the notification port, registers iterators, and hooks termination handling before emitting events into the stream.
    private func startMonitoringDevices(continuation: USBConnectionStream.Continuation) throws {
        
        guard !isMonitoring else {
            let error = USBConnectionError.monitoringAlreadyStarted
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }

        do {
            let port = try createNotificationPort()
            setDispatchQueue(notificationQueue, for: port)
            self.notificationPort = port
                
            self.continuation = continuation
            isMonitoring = true

            let context = Unmanaged.passRetained(self).toOpaque()
            self.connectionContext = context

            let iteratorRegistry = try registerNotificationIterators(context)
            self.iteratorRegistry = iteratorRegistry    

            drain(iterator: iteratorRegistry.matchingIterator, event: .connected)  
            drain(iterator: iteratorRegistry.terminatingIterator, event: .disconnected)

            continuation.onTermination = { @Sendable [weak self] termination in
                guard let self else { return }
                Task { await self.handleStreamTermination(reason: termination) }
            }
            USBLogger.info("\(#function) succeeded")
        } catch let error as USBConnectionError {
            self.continuation = nil
            cleanupIOKitResources()
            throw error
        }
    }

    /// Registers IOKit iterators for device match and termination notifications.
    /// - Parameter context: Opaque pointer retained for callbacks.
    /// - Returns: A registry containing match and termination iterators.
    /// - Throws: `USBConnectionError` when a matching dictionary or iterator cannot be created.
    /// - Discussion: Called during monitoring setup to prepare iterators for both connection and disconnection events.
    private func registerNotificationIterators(_ context: UnsafeMutableRawPointer) throws -> IteratorRegistry {
        guard let port = notificationPort else {
            let error = USBConnectionError.notificationPortUnavailable 
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }
        
        guard 
            let matchingDictionary = buildMatchingDictionary(className: kIOUSBHostDeviceClassName, criteria: deviceMatchingCriteria),
            let terminationDictionary = buildMatchingDictionary(className: kIOUSBHostDeviceClassName, criteria: deviceMatchingCriteria)
        else {
            let error = USBConnectionError.matchingDictionaryUnavailable 
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error 
        }
        
        let matchingIterator: io_iterator_t
        
        do {
            matchingIterator = try addMatchingNotification(
                port: port, 
                notification: kIOFirstMatchNotification, 
                matchingDictionary: matchingDictionary, 
                callback: Self.deviceMatchedCallback, 
                context: context
            )
        } catch let error as USBConnectionError {
            throw error
        }
        
        let terminationIterator: io_iterator_t
        
        do {
            terminationIterator = try addMatchingNotification(
                port: port, 
                notification: kIOTerminatedNotification, 
                matchingDictionary: terminationDictionary, 
                callback: Self.deviceTerminatedCallback, 
                context: context
            )
        } catch let error as USBConnectionError {
            releaseIOObject(matchingIterator)
            throw error
        }

        USBLogger.info("\(#function) succeeded")
        return IteratorRegistry(matchingIterator: matchingIterator, terminationIterator: terminationIterator)
    }
}

// MARK: - IOKit HELPERS
extension USBConnection.USBConnectionManager {
    /// Registers a matching notification with IOKit and returns its iterator.
    /// - Parameters:
    ///   - port: Notification port hosting the callback.
    ///   - notification: Notification name, such as `kIOFirstMatchNotification`.
    ///   - matchingDictionary: Matching dictionary describing desired services.
    ///   - callback: Callback invoked when a match occurs.
    ///   - context: Context pointer passed to the callback.
    /// - Returns: An iterator that must be drained to receive pending events.
    /// - Throws: `USBConnectionError.invalidNotificationName` or `.addingNotificationFailed`.
    /// - Discussion: This wraps `IOServiceAddMatchingNotification` and centralizes error handling.
    private func addMatchingNotification(
        port: IONotificationPortRef,
        notification: UnsafePointer<CChar>?,
        matchingDictionary: CFMutableDictionary,
        callback: @escaping IOServiceMatchingCallback,
        context: UnsafeMutableRawPointer?
    ) throws -> io_iterator_t {
        guard let notification else { 
            let error = USBConnectionError.invalidNotificationName
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error
        }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        let status = IOServiceAddMatchingNotification(port, notification, matchingDictionary, callback, context, &iterator)
        
        guard status == KERN_SUCCESS else { 
            let error = USBConnectionError.addingNotificationFailed(status)
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error 
        }
        USBLogger.info("\(#function) succeeded")
        return iterator
    }

    /// Builds an IOKit matching dictionary optionally filtered by IDs and string properties.
    /// - Parameters:
    ///   - className: IOKit class name to match against.
    ///   - criteria: Optional vendor/product and string-based filter.
    /// - Returns: A mutable matching dictionary or `nil` if creation fails.
    /// - Discussion: Provide criteria to focus monitoring on a specific device family; pass `nil` to match all USB devices.
    private func buildMatchingDictionary(className: UnsafePointer<CChar>, criteria: DeviceMatchingCriteria? = nil) -> CFMutableDictionary? {
        guard let dictionary = IOServiceMatching(className) else { 
            return nil 
        }

        if let criteria {
            let vendorID = criteria.vendorID
            let productID = criteria.productID
            let mDict = dictionary as NSMutableDictionary
            mDict[kUSBVendorID] = vendorID
            mDict[kUSBProductID] = productID
            if let productName = criteria.productName { mDict[kUSBProductString] = productName as CFString }
            if let manufacturerName = criteria.manufacturerName { mDict[kUSBVendorString] = manufacturerName as CFString }
            if let serialNumber = criteria.serialNumber { mDict[kUSBSerialNumberString] = serialNumber as CFString }
            return mDict as CFMutableDictionary
        }

        return dictionary
    }

    /// Creates an IOKit notification port for USB events.
    /// - Returns: A configured notification port.
    /// - Throws: `USBConnectionError.notificationPortUnavailable` when creation fails.
    /// - Discussion: This is called once per monitoring session and must be paired with `destroyNotificationPort(_:)` during cleanup.
    private func createNotificationPort() throws -> IONotificationPortRef {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { 
            let error = USBConnectionError.notificationPortUnavailable
            USBLogger.error("\(#function) failed: \(error.errorDescriptor)")
            throw error 
        }
        USBLogger.info("\(#function) succeeded")
        return port
    }

    /// Associates a dispatch queue with the notification port.
    /// - Parameters:
    ///   - queue: Queue on which callbacks should be delivered.
    ///   - port: The notification port to configure.
    /// - Discussion: Passing `nil` detaches any existing queue during teardown.
    private func setDispatchQueue(_ queue: DispatchQueue?, for port: IONotificationPortRef) {
        IONotificationPortSetDispatchQueue(port, queue)
    }

    /// Destroys an IOKit notification port.
    /// - Parameter port: Port to destroy.
    /// - Discussion: Invoke this during cleanup to release kernel resources associated with monitoring.
    private func destroyNotificationPort(_ port: IONotificationPortRef) {
        IONotificationPortDestroy(port)
    }

    /// Releases an IOKit object reference.
    /// - Parameter object: The IOKit object to release.
    /// - Discussion: Used to balance retains on iterators and services once they are no longer needed.
    private func releaseIOObject(_ object: io_object_t) {
        IOObjectRelease(object)
    }
}

// MARK: - IOKit C-STYLE CALLBACKS
extension USBConnection.USBConnectionManager {

    /// Handles device match events from IOKit and routes them to the actor.
    /// - Parameters:
    ///   - refcon: Opaque reference to the `USBConnectionManager`.
    ///   - iterator: Iterator containing matched services.
    /// - Discussion: Dispatches into the actor context to safely process connection events.
    private static let deviceMatchedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let manager = Unmanaged<USBConnectionManager>.fromOpaque(refcon).takeUnretainedValue()
        Task { await manager.handleConnectionEvent(iterator: iterator, event: .connected) }
    }

    /// Handles device termination events from IOKit and routes them to the actor.
    /// - Parameters:
    ///   - refcon: Opaque reference to the `USBConnectionManager`.
    ///   - iterator: Iterator containing terminated services.
    /// - Discussion: Dispatches into the actor context to safely process disconnection events.
    private static let deviceTerminatedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let manager = Unmanaged<USBConnectionManager>.fromOpaque(refcon).takeUnretainedValue()
        Task { await manager.handleConnectionEvent(iterator: iterator, event: .disconnected) }
    }
}


// MARK: - HANDLE CONNECTION
extension USBConnection.USBConnectionManager {

    /// Handles external stream termination and tears down monitoring resources.
    /// - Parameter reason: Reason provided by the continuation termination handler.
    /// - Discussion: Invoked when the consumer cancels or finishes the stream to ensure IOKit resources are released.
    private func handleStreamTermination(reason: USBConnectionStream.Continuation.Termination) {
        guard isMonitoring else { return }
        self.continuation = nil
        cleanupIOKitResources()
    }

    /// Routes a connection iterator to the draining logic for the given event type.
    /// - Parameters:
    ///   - iterator: Iterator containing pending USB services.
    ///   - event: Connection event describing whether services are connected or disconnected.
    /// - Discussion: Keeps the callback layer minimal by deferring work to `drain`.
    private func handleConnectionEvent(iterator: io_iterator_t, event: ConnectionEvent) {
        drain(iterator: iterator, event: event)
    }

    /// Drains an IOKit iterator and yields notifications to the continuation.
    /// - Parameters:
    ///   - iterator: Iterator populated by IOKit for the given event.
    ///   - event: Connection or disconnection marker used to build notifications.
    /// - Discussion: Iterates through all available services, wraps them in `DeviceReference`, and emits them through the stream while ensuring IOKit objects are released.
    private func drain(iterator: io_iterator_t, event: ConnectionEvent) {
        guard iterator != IO_OBJECT_NULL else { return }
        
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            guard let continuation else { 
                releaseIOObject(service) 
                continue
            }

            switch event {
                case .connected:
                    let reference = DeviceReference(service)
                    USBLogger.info("\(#function) device connected: service \(service)")
                    continuation.yield(.deviceConnected(reference)) 
                case .disconnected:
                    let reference = DeviceReference(service)
                    USBLogger.info("\(#function) device disconnected: service \(service)")
                    continuation.yield(.deviceDisconnected(reference)) 
            }
            
            releaseIOObject(service)
        }

    }
}

// MARK: - CLEANUP IOKit RESOURCES
extension USBConnection.USBConnectionManager {

    /// Releases all IOKit resources associated with the monitoring session.
    /// - Discussion: Called after monitoring ends or errors occur to avoid leaking iterators, ports, or retained actor references.
    private func cleanupIOKitResources() {
        if let registry = iteratorRegistry {
            releaseIOObject(registry.matchingIterator)
            releaseIOObject(registry.terminatingIterator)
            self.iteratorRegistry = nil
        } 

        if let port = notificationPort {
            setDispatchQueue(nil, for: port)
            destroyNotificationPort(port)
            self.notificationPort = nil
        }

        if let context = connectionContext {
            Unmanaged<USBConnectionManager>.fromOpaque(context).release()
            self.connectionContext = nil
        }

        isMonitoring = false
        USBLogger.info("\(#function) successful")
    }
}


// MARK: - CONNECTION EVENT
extension USBConnection.USBConnectionManager {
    /// Signals connection events internally.
    /// - Discussion: Distinguishes between connection and disconnection events when draining iterators.
    private enum ConnectionEvent {
        case connected
        case disconnected
    }
}

// MARK: - ITERATORS REGISTRY
extension USBConnection.USBConnectionManager {
    /// Stores connection iterators during a monitoring session.
    /// - Discussion: Keeps track of both match and termination iterators for cleanup.
    private struct IteratorRegistry {
        
        /// Iterator for device match notifications.
        /// - Returns: Iterator to be drained for connection events.
        /// - Discussion: Drained to surface device connection events.
        internal let matchingIterator: io_iterator_t
        
        /// Iterator for device termination notifications.
        /// - Returns: Iterator to be drained for disconnection events.
        /// - Discussion: Drained to surface device disconnection events.
        internal let terminatingIterator: io_iterator_t

        /// Creates a registry with provided iterators.
        /// - Parameters:
        ///   - matchingIterator: Iterator for matched services.
        ///   - terminationIterator: Iterator for terminated services.
        /// - Discussion: Encapsulates iterator pairing to simplify cleanup.
        internal init(matchingIterator: io_iterator_t, terminationIterator: io_iterator_t) {
            self.matchingIterator = matchingIterator
            self.terminatingIterator = terminationIterator
        }
    }
}

// MARK: - DEVICE MATCHING CRITERIA
extension USBConnection.USBConnectionManager {
    /// Criteria used to filter USB devices by vendor/product identifiers and optional strings.
    /// - Discussion: Supply this to `monitorDevices(matchingCriteria:)` to observe only matching devices.
    public struct DeviceMatchingCriteria: Sendable {
        
        /// Vendor identifier to match.
        /// - Returns: Vendor ID provided at initialization.
        /// - Discussion: Combined with `productID` to narrow matching results.
        public let vendorID: UInt16
        
        /// Product identifier to match.
        /// - Returns: Product ID provided at initialization.
        /// - Discussion: Combined with `vendorID` to narrow matching results.
        public let productID: UInt16
        
        /// Optional product name to match.
        /// - Returns: Product name provided at initialization, if any.
        /// - Discussion: When provided, this string is added to the matching dictionary.
        public let productName: String?
        
        /// Optional manufacturer name to match.
        /// - Returns: Manufacturer name provided at initialization, if any.
        /// - Discussion: When provided, this string is added to the matching dictionary.
        public let manufacturerName: String?
        
        /// Optional serial number to match.
        /// - Returns: Serial number provided at initialization, if any.
        /// - Discussion: When provided, this string is added to the matching dictionary.
        public let serialNumber: String?
        
        /// Creates a new matching criteria instance.
        /// - Parameters:
        ///   - vendorID: Vendor identifier to monitor.
        ///   - productID: Product identifier to monitor.
        /// - Discussion: Pass this to `USBConnectionManager` to receive notifications only for matching devices.
        public init(vendorID: UInt16, productID: UInt16, productName: String? = nil, manufacturerName: String? = nil, serialNumber: String? = nil) {
            self.vendorID = vendorID
            self.productID = productID
            self.productName = productName
            self.manufacturerName = manufacturerName
            self.serialNumber = serialNumber
        }
    }
}


//extension USBConnection {
extension USBConnection.USBConnectionManager {

    /// Wraps a USB IOKit service with managed lifetime semantics.
    /// - Discussion: Use this type to access the retained `io_service_t` and query the registry as needed.
    public final class DeviceReference: Sendable, Equatable {

        /// Underlying IOKit service handle.
        private let _service: io_service_t
        private let _registryID: UInt64?
        
        /// Underlying IOKit service reference, retained for the lifetime of the wrapper.
        /// - Returns: The retained `io_service_t` reference.
        /// - Important: Do not call `IOObjectRelease` on this handle; it is released in `deinit`.
        /// - Discussion: Provides direct access for callers needing low-level IOKit operations.
        public var service: io_service_t { _service }
        
        /// Registry entry ID for the service, if available.
        /// - Returns: The IORegistry entry ID for this device.
        public var registryID: UInt64? { _registryID }
        
        /// Creates a service wrapper and retains the service handle.
        /// - Parameters:
        ///   - service: IOKit service representing the USB device.
        /// - Discussion: Stores the registry entry ID for convenience when available.
        internal init(_ service: io_service_t) {
            IOObjectRetain(service)
            USBLogger.info("\(#function) DeviceReference retained service: \(service)")
            self._service = service
            _registryID = Self.registryIDForService(service)
        }
        
        /// Fetches the registry entry ID for the given service.
        /// - Parameter service: IOKit service representing the USB device.
        /// - Returns: Registry entry ID when available; otherwise `nil`.
        private static func registryIDForService(_ service: io_service_t) -> UInt64? {
            var entryID: UInt64 = 0
            let status = IORegistryEntryGetRegistryEntryID(service, &entryID)
            return status == KERN_SUCCESS ? entryID : nil
        }
        
        deinit {
            USBLogger.info("\(#function) DeviceReference released service: \(service)")
            IOObjectRelease(service)
        }
        
        public static func == (lhs: USBConnectionManager.DeviceReference, rhs: USBConnectionManager.DeviceReference) -> Bool {
            lhs.service == rhs.service
        }
    }
}


// MARK: - CONNECTION NOTIFICATAION
//extension USBConnection {
extension USBConnection.USBConnectionManager {
    /// Notification describing a USB connection state change.
    /// - Discussion: Delivered through `USBConnectionStream` to inform callers about device arrivals and departures.
    public enum Notification: Sendable {
        /// Indicates a device has been connected.
        /// - Parameter reference: Service wrapper for the connected device.
        /// - Discussion: Use this to interrogate the connected device or retain the service for later use.
        case deviceConnected(_ reference: DeviceReference)
        
        /// Indicates a device has been disconnected.
        /// - Parameter reference: Service wrapper for the disconnected device.
        /// - Discussion: Use this to perform cleanup or update UI when a device is removed.
        case deviceDisconnected(_ reference: DeviceReference)
    }
}


// MARK: - CONNECTION ERROR
extension USBConnection {
    /// Errors that can occur while configuring or running USB monitoring.
    /// - Discussion: Thrown by monitoring APIs to describe setup or runtime failures.
    public enum USBConnectionError: Error, LocalizedError {
        /// Monitoring was requested while already active.
        case monitoringAlreadyStarted
        /// The stream continuation could not be obtained.
        case invalidContinuation
        /// The provided notification name was invalid.
        case invalidNotificationName
        /// A notification port could not be created.
        case notificationPortUnavailable
        /// A matching dictionary could not be created.
        case matchingDictionaryUnavailable
        /// Adding a matching notification failed with a kernel status code.
        case addingNotificationFailed(_ status: kern_return_t)
        
        /// Human-readable error description.
        /// - Returns: A localized description for the specific error.
        /// - Discussion: Useful for surfacing errors directly to users or logs.
        public var errorDescription: String? {
            switch self {
                case .monitoringAlreadyStarted:
                    return "Monitoring is already active."
                case .invalidContinuation:
                    return "Unable to start monitoring because the stream continuation is invalid."
                case .invalidNotificationName:
                    return "The provided notification name is invalid."
                case .notificationPortUnavailable:
                    return "Unable to create a notification port for USB events."
                case .matchingDictionaryUnavailable:
                    return "Unable to create a matching dictionary for USB device notifications."
                case .addingNotificationFailed(let status):
                    return "Failed to add a USB notification with kernel status \(status)."
            }
        }
        
        /// Non-localized error descriptor fallback.
        /// - Returns: A description of the error suitable for logging.
        /// - Discussion: Provides a consistent string even when `errorDescription` is unavailable.
        public var errorDescriptor: String {
            errorDescription ?? "Unknown USB connection error."
        }
    }
}




extension USBConnection {

    internal struct USBLogger {

        internal enum LogLevel: String {
            case debug = "DEBUG"
            case info = "INFO"
            case warning = "WARNING"
            case error = "ERROR"
        }

        // Core logging function
        #if USBCONNECTION_LOGGING
        private static func log(_ level: LogLevel, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
            print("\(timestamp()): [\(level.rawValue)] - \(file):\(line):- \(message)")
        }
        #else
        @inline(__always) private static func log(_ level: LogLevel, _ message: String, file: StaticString = #fileID, line: UInt = #line) { }
        #endif

        // MARK: - Convenience methods
        internal static func info(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.info, message, file: file, line: line)
        }

        internal static func warning(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.warning, message, file: file, line: line)
        }

        internal static func error(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.error, message, file: file, line: line)
        }

        internal static func debug(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
            log(.debug, message, file: file, line: line)
        }

        // MARK: - Helper
        private static func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: Date())
        }
    }
}
