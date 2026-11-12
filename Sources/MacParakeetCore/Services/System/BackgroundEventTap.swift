import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

/// The one thread that runs every MacParakeet `CGEvent` tap.
///
/// macOS holds each event until a filtering tap's callback returns. Callbacks
/// on the main run loop therefore made any UI stall delay typing in every other
/// app (#1142). Taps live here instead, so their callbacks never wait on the UI.
///
/// Rule: this thread never waits on the main thread. Work that must reach the
/// UI is posted asynchronously.
public final class EventTapThread: @unchecked Sendable {
    public static let shared = EventTapThread()

    public let runLoop: CFRunLoop

    private init() {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var threadRunLoop: CFRunLoop?
        let thread = Thread {
            threadRunLoop = CFRunLoopGetCurrent()
            // A run loop with no sources exits immediately; keep it alive.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true {
                CFRunLoopRunInMode(.defaultMode, 1e10, false)
            }
        }
        thread.name = "com.macparakeet.event-taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = threadRunLoop!
    }

    public var isCurrent: Bool {
        CFRunLoopGetCurrent() === runLoop
    }

    /// Runs `body` on the tap thread and waits for it. Runs inline when
    /// already on the tap thread.
    public func performAndWait<T>(_ body: () -> T) -> T {
        if isCurrent { return body() }
        return withoutActuallyEscaping(body) { escapable in
            // The run loop may release the performed block after `done.wait()`
            // returns. The block holds only this box, and the box drops `body`
            // before signalling, so nothing retains `body` once this scope
            // exits. Capturing `body` directly traps intermittently.
            let box = PerformBox(work: escapable)
            let done = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                box.run()
                done.signal()
            }
            CFRunLoopWakeUp(runLoop)
            done.wait()
            return box.result!
        }
    }
}

/// Carries a `performAndWait` body to the tap thread. The semaphore orders the
/// tap thread's writes before the caller's read.
private final class PerformBox<T>: @unchecked Sendable {
    private var work: (() -> T)?
    private(set) var result: T?

    init(work: @escaping () -> T) {
        self.work = work
    }

    func run() {
        result = work?()
        work = nil
    }
}

/// A keyboard/mouse `CGEvent` tap whose callback runs on `EventTapThread`.
///
/// The handler is called only on the tap thread. When macOS disables the tap
/// (timeout or secure input), the tap is re-enabled first and the handler then
/// receives the `.tapDisabledBy…` event so its owner can resync state; the
/// handler's return value is ignored for those.
public final class BackgroundEventTap: @unchecked Sendable {
    public typealias Handler = (_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?

    private static let logger = Logger(subsystem: "com.macparakeet.core", category: "BackgroundEventTap")

    private let handler: Handler
    // Tap-thread state.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retainedSelf: Unmanaged<BackgroundEventTap>?

    private init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Creates and enables the tap on the tap thread. Returns nil when macOS
    /// refuses the tap (usually a missing permission).
    ///
    /// `diagnosticContext` names the tap's owner for failure logs (e.g.
    /// "command mode (Control+Option)"). It never contains user text.
    public static func start(
        options: CGEventTapOptions,
        eventsOfInterest: CGEventMask,
        diagnosticContext: String? = nil,
        handler: @escaping Handler
    ) -> BackgroundEventTap? {
        let eventTap = BackgroundEventTap(handler: handler)
        let started = EventTapThread.shared.performAndWait {
            eventTap.install(
                options: options,
                eventsOfInterest: eventsOfInterest,
                diagnosticContext: diagnosticContext
            )
        }
        return started ? eventTap : nil
    }

    /// Whether macOS has granted this process Input Monitoring (TCC
    /// `kTCCServiceListenEvent`). Event taps fail to create without it,
    /// even when Accessibility is granted, so the two grants must be
    /// checked separately (A3). Read-only: never triggers a prompt.
    public static func isInputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Disables and invalidates the tap. Idempotent. After it returns, the
    /// handler will not be called again. Call it from the owner, not from
    /// inside this tap's own handler.
    public func stop() {
        EventTapThread.shared.performAndWait {
            EventTapTeardown.tearDown(tap: tap, source: source, runLoop: EventTapThread.shared.runLoop)
            tap = nil
            source = nil
            // Release last: this may deallocate self. `performAndWait` holds
            // the caller's reference, so it cannot happen mid-teardown.
            retainedSelf?.release()
            retainedSelf = nil
        }
    }

    public var runLoopSourceForTesting: CFRunLoopSource? {
        EventTapThread.shared.performAndWait { source }
    }

    private func install(
        options: CGEventTapOptions,
        eventsOfInterest: CGEventMask,
        diagnosticContext: String? = nil
    ) -> Bool {
        let retained = Unmanaged.passRetained(self)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let eventTap = Unmanaged<BackgroundEventTap>.fromOpaque(refcon).takeUnretainedValue()
            return eventTap.handle(type: type, event: event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            // A1: a refused tap used to fail silently at every layer.
            // Log the owner context and the trust state so Console.app
            // shows which permission is missing instead of nothing.
            Self.logger.error(
                "event_tap_create_failed context=\(diagnosticContext ?? "unknown", privacy: .public) accessibility_trusted=\(AXIsProcessTrusted(), privacy: .public)"
            )
            return false
        }
        tap = created
        retainedSelf = retained
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(EventTapThread.shared.runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            _ = handler(type, event)
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}

// MARK: - Tap Failure Diagnostics (A1/A4)

/// A record of the most recent event-tap creation failure. Contains only
/// the tap owner's label and the process trust state — never user text or
/// key contents. Read by the app for Settings diagnostics so a refused tap
/// is visible without opening Console.app.
public struct HotkeyTapFailure: Sendable, Equatable {
    /// Owner label, e.g. "command mode (Control+Option)".
    public let context: String
    public let accessibilityTrusted: Bool
    public let date: Date

    public init(context: String, accessibilityTrusted: Bool, date: Date = Date()) {
        self.context = context
        self.accessibilityTrusted = accessibilityTrusted
        self.date = date
    }
}

/// Thread-safe holder for the last tap-create failure. Written by the tap
/// owners on failure; read by the app (Settings diagnostics wiring is
/// follow-up — the store is the seam it reads).
public final class LastHotkeyTapFailure: @unchecked Sendable {
    public static let shared = LastHotkeyTapFailure()

    private let lock = NSLock()
    private var failure: HotkeyTapFailure?

    private init() {}

    public func record(_ failure: HotkeyTapFailure) {
        lock.lock()
        defer { lock.unlock() }
        self.failure = failure
    }

    public var current: HotkeyTapFailure? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}
