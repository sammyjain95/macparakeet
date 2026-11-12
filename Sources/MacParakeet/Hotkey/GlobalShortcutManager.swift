import Cocoa
import Foundation
import MacParakeetCore
import OSLog

/// Lightweight global shortcut listener for immediate actions like toggling
/// meeting recording. Unlike `HotkeyManager`, this does not model hold or
/// dictation gesture handling.
///
/// **Threading.** Matching runs entirely on `EventTapThread`, so a stalled
/// main thread cannot delay other apps' keystrokes (#1142). `onTrigger` is
/// called on the tap thread; set it before `start()` and hop to the main actor
/// for any UI work. `start()` and `stop()` are called from the main thread;
/// matching state is only touched while no tap is running or from the tap.
public final class GlobalShortcutManager {
    private static let logger = Logger(subsystem: "com.macparakeet.app", category: "GlobalShortcutManager")

    public var onTrigger: (() -> Void)?
    /// Fired (on the tap thread; the event is never consumed) when Escape
    /// is pressed. Set by the Command Mode owner so a live command session
    /// can be cancelled with Escape; nil by default, so the auxiliary
    /// managers (meeting/file/YouTube) are unaffected.
    public var onEscape: (() -> Void)?

    private let trigger: HotkeyTrigger
    /// Owner label for tap-failure diagnostics, e.g. "command mode".
    /// Nil for the auxiliary managers.
    private let diagnosticContext: String?
    private var backgroundTap: BackgroundEventTap?
    private var targetModifierWasPressed = false
    private var triggerKeyIsPressed = false
    private var modifierChordRequiredWasPressed = false
    private var modifierChordTriggeredDuringPress = false
    private var modifierChordBlockedUntilRelease = false

    public init(trigger: HotkeyTrigger, diagnosticContext: String? = nil) {
        self.trigger = trigger
        self.diagnosticContext = diagnosticContext
    }

    deinit {
        backgroundTap?.stop()
    }

    public func start() -> Bool {
        if backgroundTap != nil {
            stop()
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        // No tap is running yet, so this cannot race the tap thread.
        recoverFromDisabledTap()
        guard let tap = BackgroundEventTap.start(
            options: .defaultTap,
            eventsOfInterest: eventMask,
            diagnosticContext: diagnosticContext.map { "\($0) (\(trigger.displayName))" } ?? trigger.displayName,
            handler: { [weak self] type, event in
                guard let self else { return Unmanaged.passUnretained(event) }
                return self.handleEvent(type: type, event: event)
            }
        ) else {
            // A1: log the failure with the trust state instead of
            // returning false silently.
            Self.logger.error(
                "global_shortcut_tap_create_failed trigger=\(self.trigger.displayName, privacy: .public) accessibility_trusted=\(AXIsProcessTrusted(), privacy: .public)"
            )
            return false
        }
        backgroundTap = tap
        return true
    }

    public func stop() {
        // Returns only after the tap thread has stopped calling back.
        backgroundTap?.stop()
        backgroundTap = nil
        targetModifierWasPressed = false
        triggerKeyIsPressed = false
        modifierChordRequiredWasPressed = false
        modifierChordTriggeredDuringPress = false
        modifierChordBlockedUntilRelease = false
    }

    var runLoopSourceForTesting: CFRunLoopSource? {
        backgroundTap?.runLoopSourceForTesting
    }

    /// Runs on the tap thread.
    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // C2: offer Escape to the owner (Command Mode cancel) but never
        // consume it — it must still reach the frontmost app and the
        // dictation managers' own Escape handling.
        if type == .keyDown, onEscape != nil,
           UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == 53 {
            onEscape?()
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // `BackgroundEventTap` already re-enabled the tap.
            recoverFromDisabledTap()
            return Unmanaged.passUnretained(event)
        }

        if AppGeneratedEventMarker.isMarked(event) {
            return Unmanaged.passUnretained(event)
        }

        switch trigger.kind {
        case .disabled:
            return Unmanaged.passUnretained(event)
        case .modifier:
            return handleModifierEvent(type: type, event: event)
        case .keyCode:
            return handleKeyCodeEvent(type: type, event: event)
        case .chord:
            return handleChordEvent(type: type, event: event)
        case .modifierChord:
            return handleModifierChordEvent(type: type, event: event)
        }
    }

    private func handleModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        handleModifierFlagsChanged(
            flags: event.flags,
            changedKeyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        )
        return Unmanaged.passUnretained(event)
    }

    private func handleModifierFlagsChanged(flags: CGEventFlags, changedKeyCode: UInt16? = nil) {
        if let targetKeyCode = trigger.modifierKeyCode {
            handleSideSpecificModifierFlagsChanged(
                flags: flags,
                targetKeyCode: targetKeyCode,
                changedKeyCode: changedKeyCode
            )
            return
        }

        let isPressed = ModifierKeyMatcher.modifierIsPressed(trigger: trigger, flags: flags)
        if isPressed != targetModifierWasPressed {
            targetModifierWasPressed = isPressed
            if isPressed {
                onTrigger?()
            }
        }
    }

    private func handleSideSpecificModifierFlagsChanged(
        flags: CGEventFlags,
        targetKeyCode: UInt16,
        changedKeyCode: UInt16?
    ) {
        let isPressed = ModifierKeyMatcher.sideSpecificModifierIsPressed(
            flags: flags,
            keyCode: targetKeyCode,
            changedKeyCode: changedKeyCode,
            previouslyPressed: targetModifierWasPressed
        )
        let oppositeIsPressed = ModifierKeyMatcher.oppositeSideModifierIsPressed(
            flags: flags,
            keyCode: targetKeyCode,
            changedKeyCode: changedKeyCode
        )

        guard isPressed else {
            targetModifierWasPressed = false
            return
        }

        guard !targetModifierWasPressed else { return }
        targetModifierWasPressed = true
        if !oppositeIsPressed {
            onTrigger?()
        }
    }

    private func handleModifierChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        handleModifierChordFlagsChanged(flags: event.flags)
        return Unmanaged.passUnretained(event)
    }

    private func handleModifierChordFlagsChanged(flags: CGEventFlags) {
        let requiredPressed = ModifierKeyMatcher.modifierChordRequiredComponentsArePressed(
            trigger: trigger,
            flags: flags
        )
        let exactPressed = ModifierKeyMatcher.modifierChordMatches(trigger: trigger, flags: flags)

        if !requiredPressed {
            modifierChordRequiredWasPressed = false
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = false
            return
        }

        if !modifierChordRequiredWasPressed {
            modifierChordRequiredWasPressed = true
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = !exactPressed
        }

        guard exactPressed,
              !modifierChordBlockedUntilRelease,
              !modifierChordTriggeredDuringPress else {
            return
        }
        modifierChordTriggeredDuringPress = true
        onTrigger?()
    }

    private func handleKeyCodeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            guard !triggerKeyIsPressed else { return nil }
            triggerKeyIsPressed = true
            onTrigger?()
            return nil
        case .keyUp:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            triggerKeyIsPressed = false
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shouldSwallow = handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: event.flags.rawValue & HotkeyTrigger.relevantModifierBits
        )
        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    private func recoverFromDisabledTap(flags: CGEventFlags? = nil) {
        recoverFromDisabledTap(flags: flags, triggerKeyPressed: currentPhysicalTriggerKeyIsPressed())
    }

    private func recoverFromDisabledTap(flags: CGEventFlags? = nil, triggerKeyPressed: Bool) {
        triggerKeyIsPressed = triggerKeyPressed
        syncModifierPressedState(flags: flags)
        syncModifierChordPressedState(flags: flags)
    }

    private func currentPhysicalTriggerKeyIsPressed() -> Bool {
        guard trigger.kind == .keyCode || trigger.kind == .chord,
              let keyCode = trigger.keyCode else {
            return false
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }

    private func syncModifierPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifier else {
            targetModifierWasPressed = false
            return
        }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        if let targetKeyCode = trigger.modifierKeyCode {
            targetModifierWasPressed = ModifierKeyMatcher.sideSpecificModifierIsPressed(
                flags: currentFlags,
                keyCode: targetKeyCode
            )
        } else {
            targetModifierWasPressed = ModifierKeyMatcher.modifierIsPressed(trigger: trigger, flags: currentFlags)
        }
    }

    private func syncModifierChordPressedState(flags: CGEventFlags? = nil) {
        guard trigger.kind == .modifierChord else {
            modifierChordRequiredWasPressed = false
            modifierChordTriggeredDuringPress = false
            modifierChordBlockedUntilRelease = false
            return
        }

        let currentFlags = flags ?? CGEventSource.flagsState(.combinedSessionState)
        modifierChordRequiredWasPressed = ModifierKeyMatcher.modifierChordRequiredComponentsArePressed(
            trigger: trigger,
            flags: currentFlags
        )
        let exactPressed = ModifierKeyMatcher.modifierChordMatches(trigger: trigger, flags: currentFlags)
        modifierChordBlockedUntilRelease = modifierChordRequiredWasPressed
            && !exactPressed
        modifierChordTriggeredDuringPress = exactPressed
    }

    @discardableResult
    private func handleChordEvent(
        type: CGEventType,
        triggerCode: UInt16,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return false }
            guard trigger.chordEventMatches(flags: flags) else { return false }
            guard !triggerKeyIsPressed else { return true }
            triggerKeyIsPressed = true
            onTrigger?()
            return true
        case .keyUp:
            guard keyCode == triggerCode else { return false }
            guard triggerKeyIsPressed else { return false }
            triggerKeyIsPressed = false
            return true
        default:
            return false
        }
    }

    @discardableResult
    func handleChordEventForTesting(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        guard let triggerCode = trigger.keyCode else { return false }
        return handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: flags & HotkeyTrigger.relevantModifierBits
        )
    }

    func modifierFlagsChangedForTesting(flags: CGEventFlags, changedKeyCode: UInt16? = nil) {
        guard trigger.kind == .modifier else { return }
        handleModifierFlagsChanged(flags: flags, changedKeyCode: changedKeyCode)
    }

    func modifierChordFlagsChangedForTesting(flags: CGEventFlags) {
        guard trigger.kind == .modifierChord else { return }
        handleModifierChordFlagsChanged(flags: flags)
    }

    func recoverFromDisabledTapForTesting(
        flags: CGEventFlags? = nil,
        triggerKeyPressed: Bool = false
    ) {
        recoverFromDisabledTap(flags: flags, triggerKeyPressed: triggerKeyPressed)
    }

}
