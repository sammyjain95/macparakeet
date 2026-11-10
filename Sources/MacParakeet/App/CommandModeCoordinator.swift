import AppKit
import Foundation
import MacParakeetCore
import OSLog

/// Orchestrates Command Mode (voice-driven transforms on selected text).
///
/// Invariants (TRD 2026-11-09):
/// - Explicit mode: triggered only by the dedicated Command hotkey/state.
/// - Capture selection/context first (before recording).
/// - Command transcript is kept in an internal buffer only and is never pasted.
/// - Local-only, fail-closed LLM for Tier 2 transforms (no cloud fallback).
/// - Selected text/result are not written to telemetry/crash logs.
@MainActor
final class CommandModeCoordinator {
    enum Phase: Equatable {
        case idle
        case capturing
        case listening
        case transcribing
        case thinking
        case applying
        case preview(CommandModePreviewState)
        case failed(String)
        case done
    }

    struct CommandModePreviewState: Equatable {
        let original: String
        let transformed: String
        let intent: CommandModeIntent
        let tier: CommandModeTransformTier
        let deterministicLabel: String?
    }

    private let audioProcessor: AudioProcessor
    private let sttTranscriber: any SpeechEngineRoutedTranscribing & STTTranscribing
    private let selectionCapture: SelectionCaptureService
    private let selectionReplacement: SelectionReplacementService
    private let focusedAppContextService: FocusedAppContextService
    private let routingLLMClient: RoutingLLMClient
    private let preferences: AppRuntimePreferencesProtocol
    private let overlayController: DictationOverlayController
    private let overlayViewModel: DictationOverlayViewModel
    private let isBusyForDictation: () -> Bool
    private let logger = Logger(subsystem: "com.macparakeet.app", category: "CommandMode")

    private var phase: Phase = .idle
    private var activeTask: Task<Void, Never>?
    private var capturedSelection: SelectionCaptureResult?
    private var capturedAppContext: AppPromptContext?
    private var commandAudioURL: URL?
    /// Original text for undo/restore of the last applied command (in-memory).
    private var lastAppliedOriginal: String?
    private var lastAppliedSelection: SelectionCaptureResult?
    private var undoTask: Task<Void, Never>?

    init(
        audioProcessor: AudioProcessor,
        sttTranscriber: any SpeechEngineRoutedTranscribing & STTTranscribing,
        selectionCapture: SelectionCaptureService = SelectionCaptureService(),
        selectionReplacement: SelectionReplacementService = SelectionReplacementService(),
        focusedAppContextService: FocusedAppContextService = FocusedAppContextService(),
        routingLLMClient: RoutingLLMClient,
        preferences: AppRuntimePreferencesProtocol = UserDefaultsAppRuntimePreferences(),
        isBusyForDictation: @escaping () -> Bool = { false }
    ) {
        self.audioProcessor = audioProcessor
        self.sttTranscriber = sttTranscriber
        self.selectionCapture = selectionCapture
        self.selectionReplacement = selectionReplacement
        self.focusedAppContextService = focusedAppContextService
        self.routingLLMClient = routingLLMClient
        self.preferences = preferences
        self.isBusyForDictation = isBusyForDictation
        let vm = DictationOverlayViewModel()
        self.overlayViewModel = vm
        self.overlayController = DictationOverlayController(viewModel: vm)
    }

    var isActive: Bool {
        switch phase {
        case .idle, .done, .failed:
            return false
        default:
            return true
        }
    }

    /// Hotkey entry point: start listening if idle, stop-and-process if listening.
    func toggle() {
        switch phase {
        case .idle, .failed, .done:
            start()
        case .listening:
            stopAndProcess()
        case .capturing, .transcribing, .thinking, .applying:
            // Busy; ignore extra toggles (could support cancel in future).
            break
        case .preview:
            // MVP: dismiss preview without applying.
            cancelPreview()
        }
    }

    func start() {
        guard AppFeatures.isCommandModeAvailable() else { return }
        guard !isBusyForDictation() else { return }
        switch phase {
        case .idle, .failed, .done:
            break
        default:
            return
        }

        activeTask?.cancel()
        undoTask?.cancel()
        cleanupTempAudio()
        lastAppliedOriginal = nil
        lastAppliedSelection = nil

        phase = .capturing
        activeTask = Task { @MainActor [weak self] in
            await self?.runCaptureAndListen()
        }
    }

    /// Stop recording and process the spoken command.
    func stopAndProcess() {
        guard phase == .listening else { return }
        activeTask?.cancel()
        phase = .transcribing
        activeTask = Task { @MainActor [weak self] in
            await self?.finishRecordingAndTransform()
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        Task { [weak self] in
            await self?.handleCancelCleanup()
        }
    }

    // MARK: - Flow

    private func runCaptureAndListen() async {
        // 1) Capture context and selection first (before recording).
        let appContext = focusedAppContextService.currentContext()
        capturedAppContext = appContext

        let category = appContext?.category ?? .other
        let bundleID = appContext?.bundleIdentifier ?? ""

        // Per-app exclusion / secure-field heuristics (best-effort; AX secure detection
        // is limited without focused element role, but we block common password managers).
        if preferences.commandModeExcludedBundleIDs.contains(bundleID) {
            fail("Command Mode is turned off for this app")
            return
        }

        // Refuse terminal rewrites up front for common terminal apps.
        if category == .terminal {
            fail(CommandModeTransformError.terminalRewriteRefused.localizedDescription)
            return
        }

        let selection = await selectionCapture.captureSelection()
        capturedSelection = selection

        let selectedText: String
        switch selection {
        case .ax(let text, _, _), .clipboard(let text, _, _):
            selectedText = text
        case .empty:
            await selectionCapture.restoreClipboardCaptureIfCurrent(selection)
            capturedSelection = nil
            fail("Nothing selected")
            return
        case .failed(let error):
            fail(error.errorDescription ?? error.localizedDescription)
            return
        }

        if Task.isCancelled { await handleCancelCleanup(); return }

        // 2) Show command UI and start listening.
        overlayViewModel.state = .recording
        overlayViewModel.recordingMode = .persistent
        overlayViewModel.processingLoadCaption = nil
        overlayViewModel.processingMessage = nil
        overlayViewModel.liveTranscript = ""
        overlayController.configureForCommandMode(selectedPreview: String(selectedText.prefix(120)))
        overlayController.show()
        overlayViewModel.startTimer()

        do {
            try await audioProcessor.startCapture()
            phase = .listening
            logger.info("command_mode_listening")
        } catch {
            await handleCancelCleanup()
            fail(userFacingCaptureError(error))
        }
    }

    private func finishRecordingAndTransform() async {
        // 3) Stop capture and transcribe (command transcript stays internal).
        let wavURL: URL
        do {
            wavURL = try await audioProcessor.stopCapture()
            commandAudioURL = wavURL
        } catch {
            await handleCancelCleanup()
            fail(userFacingCaptureError(error))
            return
        }

        if Task.isCancelled { await handleCancelCleanup(); return }

        await MainActor.run {
            overlayViewModel.stopTimer()
            overlayViewModel.state = .processing
            overlayViewModel.processingMessage = "Transcribing locally"
            overlayViewModel.busyProcessingMessage = nil
        }
        phase = .transcribing

        let commandText: String
        do {
            let selection = SpeechEngineSelection.current()
            let result = try await sttTranscriber.transcribe(
                audioPath: wavURL.path,
                job: .dictation,
                speechEngine: selection,
                onProgress: nil
            )
            commandText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            cleanupTempAudio(at: wavURL)
            commandAudioURL = nil
            await handleCancelCleanup()
            fail("Could not understand the command. Try again.")
            return
        }

        cleanupTempAudio(at: wavURL)
        commandAudioURL = nil

        if Task.isCancelled { await handleCancelCleanup(); return }

        guard !commandText.isEmpty else {
            await handleCancelCleanup()
            fail("No command heard. Try again.")
            return
        }

        // Never log or paste the command transcript. Keep it internal.
        await MainActor.run {
            overlayViewModel.processingMessage = "Thinking locally"
        }
        phase = .thinking

        await runTransform(commandText: commandText)
    }

    private func runTransform(commandText: String) async {
        guard let selection = capturedSelection,
              let selectedText = selection.capturedText else {
            await handleCancelCleanup()
            fail("Nothing selected")
            return
        }

        let appCategory = capturedAppContext?.category ?? .other
        let cmdContext = CommandModeAppContext(
            bundleIdentifier: capturedAppContext?.bundleIdentifier,
            category: appCategory,
            fieldKind: fieldKind(for: appCategory),
            languageHint: nil
        )

        // Tier 1 deterministic short-circuit (no model needed).
        if let deterministic = DeterministicTextTransform.match(command: commandText) {
            let intent = CommandModeIntentClassifier.classify(command: commandText)
            let output = DeterministicTextTransformer.apply(deterministic, to: selectedText)
            let result = CommandModeTransformResult(
                output: output,
                intent: intent,
                tier: .deterministic,
                deterministicTransform: deterministic,
                confidence: 1.0
            )
            await applyOrPreview(result: result, original: selectedText, selection: selection)
            return
        }

        // Tier 2 requires local-only model context (fail closed).
        guard let localContext = routingLLMClient.makeCommandModeLocalContext(),
              routingLLMClient.supportsInProcessLocalLLM else {
            await handleCancelCleanup()
            fail(CommandModeTransformError.localModelUnavailable.localizedDescription)
            return
        }

        do {
            let executor = CommandModeTransformExecutor(llmClient: routingLLMClient.inProcessLocalClient)
            let result = try await executor.execute(
                command: commandText,
                selectedText: selectedText,
                appContext: cmdContext,
                localContext: localContext
            )
            await applyOrPreview(result: result, original: selectedText, selection: selection)
        } catch is CancellationError {
            await handleCancelCleanup()
        } catch let error as CommandModeTransformError {
            if case .terminalRewriteRefused = error {
                // already guarded, but keep safe
            }
            await handleCancelCleanup()
            fail(error.errorDescription ?? "Command failed")
        } catch {
            await handleCancelCleanup()
            fail("Local model unavailable")
        }
    }

    private func applyOrPreview(
        result: CommandModeTransformResult,
        original: String,
        selection: SelectionCaptureResult
    ) async {
        if Task.isCancelled { await handleCancelCleanup(); return }

        let behavior = preferences.commandModePreviewBehavior
        let shouldPreview: Bool = {
            if result.intent == .panel { return true } // summaries/extractions: do not destroy original
            switch behavior {
            case .alwaysPreview:
                return true
            case .autoApplyDeterministicOnly:
                return result.tier == .llm || original.count > 200
            case .autoApplyAll:
                return original.count > 200 && result.tier == .llm
            }
        }()

        if shouldPreview {
            showPreview(result: result, original: original)
            return
        }

        await applyReplacement(output: result.output, original: original, selection: selection, tier: result.tier)
    }

    private func showPreview(result: CommandModeTransformResult, original: String) {
        phase = .preview(CommandModePreviewState(
            original: original,
            transformed: result.output,
            intent: result.intent,
            tier: result.tier,
            deterministicLabel: result.deterministicTransform?.displayName
        ))
        // MVP preview: show the result is ready. A full Before/After diff panel
        // with Accept/Retry/Cancel is follow-up; for now we do not auto-apply
        // LLM/long-selection results (respecting preview-first behavior).
        overlayViewModel.state = .processing
        overlayViewModel.processingMessage = result.intent == .panel
            ? "Result ready (not applied)"
            : "Preview ready (not applied)"
        overlayViewModel.busyProcessingMessage = nil
        logger.info("command_mode_preview intent=\(result.intent.rawValue, privacy: .public) tier=\(result.tier.rawValue, privacy: .public)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, case .preview = self.phase else { return }
            self.finishWithoutApplying()
        }
    }

    private func cancelPreview() {
        finishWithoutApplying()
    }

    private func finishWithoutApplying() {
        if let selection = capturedSelection {
            Task { await selectionCapture.restoreClipboardCaptureIfCurrent(selection) }
        }
        capturedSelection = nil
        phase = .done
        overlayViewModel.stopTimer()
        overlayViewModel.state = .success
        overlayViewModel.processingMessage = nil
        scheduleHide()
    }

    private func applyReplacement(
        output: String,
        original: String,
        selection: SelectionCaptureResult,
        tier: CommandModeTransformTier
    ) async {
        phase = .applying
        overlayViewModel.state = .processing
        overlayViewModel.processingMessage = "Applying"

        do {
            _ = try await selectionReplacement.replace(with: output, in: selection, mode: .replaceSelection)
            capturedSelection = nil
            lastAppliedOriginal = original
            lastAppliedSelection = selection
            overlayViewModel.stopTimer()
            overlayViewModel.processingMessage = nil
            logger.info("command_mode_applied tier=\(tier.rawValue, privacy: .public)")
            beginUndoWindow()
        } catch {
            await handleCancelCleanup()
            fail("Could not replace the selection")
        }
    }

    private func beginUndoWindow() {
        let seconds = 10.0
        overlayViewModel.cancelCountdownDuration = seconds
        overlayViewModel.cancelTimeRemaining = seconds
        overlayViewModel.onUndo = { [weak self] in
            Task { @MainActor in self?.performUndo() }
        }
        overlayViewModel.onCancel = { [weak self] in
            Task { @MainActor in self?.finalizeAfterApply() }
        }
        overlayViewModel.state = .cancelled(timeRemaining: seconds)
        phase = .done

        undoTask?.cancel()
        undoTask = Task { @MainActor [weak self] in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                // If user undid/finalized, phase/state will have changed.
                guard case .cancelled = self.overlayViewModel.state else { return }
                remaining = max(0, remaining - 0.25)
                self.overlayViewModel.cancelTimeRemaining = remaining
            }
            guard !Task.isCancelled, let self else { return }
            guard case .cancelled = self.overlayViewModel.state else { return }
            self.finalizeAfterApply()
        }
    }

    private func performUndo() {
        undoTask?.cancel()
        undoTask = nil
        guard let original = lastAppliedOriginal, let selection = lastAppliedSelection else {
            finalizeAfterApply()
            return
        }
        lastAppliedOriginal = nil
        lastAppliedSelection = nil
        overlayViewModel.processingMessage = "Restoring original"
        overlayViewModel.state = .processing
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.selectionReplacement.replace(with: original, in: selection, mode: .replaceSelection)
                self.overlayViewModel.state = .success
                self.overlayViewModel.processingMessage = nil
                self.scheduleHide()
            } catch {
                self.fail("Could not restore the original text")
            }
        }
    }

    private func finalizeAfterApply() {
        undoTask?.cancel()
        undoTask = nil
        lastAppliedOriginal = nil
        lastAppliedSelection = nil
        overlayViewModel.onUndo = nil
        overlayViewModel.onCancel = nil
        overlayViewModel.state = .success
        overlayViewModel.processingMessage = nil
        scheduleHide()
    }

    // MARK: - Helpers

    private func fieldKind(for category: TelemetryAppCategory) -> CommandModeFieldKind {
        if category == .terminal { return .terminal }
        return .plainText
    }

    private func fail(_ message: String) {
        if let selection = capturedSelection {
            Task { await selectionCapture.restoreClipboardCaptureIfCurrent(selection) }
        }
        capturedSelection = nil
        phase = .failed(message)
        overlayViewModel.stopTimer()
        overlayViewModel.state = .error(message)
        overlayViewModel.processingMessage = nil
        overlayViewModel.busyProcessingMessage = nil
        scheduleHide(delay: .seconds(2))
    }

    private func scheduleHide(delay: Duration = .milliseconds(900)) {
        let resetKind = { [weak self] in
            self?.overlayController.resetSessionKind()
            self?.overlayController.hide()
            self?.overlayViewModel.onUndo = nil
            self?.overlayViewModel.onCancel = nil
            switch self?.phase {
            case .done, .failed, .idle, .none:
                self?.phase = .idle
            default:
                break
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            resetKind()
        }
    }

    private func handleCancelCleanup() async {
        overlayViewModel.stopTimer()
        undoTask?.cancel()
        undoTask = nil
        if let url = commandAudioURL {
            cleanupTempAudio(at: url)
            commandAudioURL = nil
        } else {
            // Best-effort stop if we were recording.
            if phase == .listening || phase == .capturing {
                _ = try? await audioProcessor.stopCapture()
            }
        }
        if let selection = capturedSelection {
            await selectionCapture.restoreClipboardCaptureIfCurrent(selection)
            capturedSelection = nil
        }
        lastAppliedOriginal = nil
        lastAppliedSelection = nil
        overlayViewModel.onUndo = nil
        overlayViewModel.onCancel = nil
        phase = .idle
        overlayViewModel.state = .ready
        overlayViewModel.processingMessage = nil
        overlayController.resetSessionKind()
        overlayController.hide()
    }

    private func cleanupTempAudio(at url: URL? = nil) {
        let target = url ?? commandAudioURL
        guard let target else { return }
        try? FileManager.default.removeItem(at: target)
        if url == nil { commandAudioURL = nil }
    }

    private func userFacingCaptureError(_ error: Error) -> String {
        if let audioError = error as? AudioProcessorError {
            return audioError.errorDescription ?? audioError.localizedDescription
        }
        return error.localizedDescription
    }

    private func cleanupTempAudio() {
        if let url = commandAudioURL {
            try? FileManager.default.removeItem(at: url)
            commandAudioURL = nil
        }
    }
}
