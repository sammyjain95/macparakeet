import Foundation
import OSLog

/// Executes Command Mode transforms with the TRD's invariants:
/// - Tier 1 deterministic transforms run instantly (no LLM).
/// - Tier 2 LLM transforms use a local-only context, constrained prompt,
///   JSON output, low temperature, and validate-and-retry (once).
/// - Command/selection are treated as data; output is validated before use.
/// - No cloud fallback; fail closed with `localModelUnavailable`.
public actor CommandModeTransformExecutor {
    private let llmClient: any LLMClientProtocol
    private let logger: Logger

    public init(
        llmClient: any LLMClientProtocol,
        logger: Logger = Logger(subsystem: "com.macparakeet.core", category: "CommandModeTransform")
    ) {
        self.llmClient = llmClient
        self.logger = logger
    }

    public func execute(
        command: String,
        selectedText: String,
        appContext: CommandModeAppContext,
        localContext: LLMExecutionContext
    ) async throws -> CommandModeTransformResult {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw CommandModeTransformError.emptyCommand
        }
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandModeTransformError.emptySelection
        }

        // Fail-closed: local-only context must target in-process local.
        guard localContext.providerConfig.id == .inProcessLocal else {
            logger.error("command_mode_blocked_nonlocal provider=\(localContext.providerConfig.id.rawValue, privacy: .public)")
            throw CommandModeTransformError.localModelUnavailable
        }

        // Safety: secure fields and terminals.
        if appContext.fieldKind == .secureField {
            throw CommandModeTransformError.secureFieldBlocked
        }
        if appContext.fieldKind == .terminal || appContext.category == .terminal {
            // Terminal rewrites are refused per TRD.
            throw CommandModeTransformError.terminalRewriteRefused
        }

        // Selection length guard.
        let tokenEstimate = CommandModePromptBuilder.estimateTokens(selectedText)
        if tokenEstimate > CommandModePromptBuilder.maxSelectionTokens {
            throw CommandModeTransformError.selectionTooLong(
                tokenEstimate: tokenEstimate,
                limit: CommandModePromptBuilder.maxSelectionTokens
            )
        }

        let intent = CommandModeIntentClassifier.classify(command: trimmedCommand)
        if intent == .unsupported {
            throw CommandModeTransformError.unsupportedIntent(
                "Text transforms only in Command Mode"
            )
        }

        // Tier 1: deterministic (instant, no LLM).
        if let deterministic = DeterministicTextTransform.match(command: trimmedCommand) {
            let output = DeterministicTextTransformer.apply(deterministic, to: selectedText)
            return CommandModeTransformResult(
                output: output,
                intent: intent,
                tier: .deterministic,
                deterministicTransform: deterministic,
                confidence: 1.0
            )
        }

        // Tier 2: local LLM.
        return try await executeLLM(
            command: trimmedCommand,
            selectedText: selectedText,
            appContext: appContext,
            localContext: localContext,
            intent: intent
        )
    }

    private func executeLLM(
        command: String,
        selectedText: String,
        appContext: CommandModeAppContext,
        localContext: LLMExecutionContext,
        intent: CommandModeIntent
    ) async throws -> CommandModeTransformResult {
        let systemPrompt = CommandModePromptBuilder.systemPrompt(for: appContext)
        let userMessage = CommandModePromptBuilder.userMessage(command: command, selectedText: selectedText)
        let messages = [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: userMessage),
        ]

        // Low temperature, bounded output, no local chunking (complete context required).
        let outputLimit = min(4096, max(512, CommandModePromptBuilder.estimateTokens(selectedText) * 2 + 256))
        let options = ChatCompletionOptions(
            temperature: 0.1,
            maxTokens: outputLimit,
            allowsLocalChunking: false
        )

        // Attempt 1
        if let result = try await attemptLLM(
            messages: messages,
            localContext: localContext,
            options: options,
            command: command,
            inputText: selectedText,
            intent: intent
        ) {
            return result
        }

        logger.notice("command_mode_llm_retry reason=validation_failed")

        // Attempt 2 (retry once)
        if let result = try await attemptLLM(
            messages: messages,
            localContext: localContext,
            options: options,
            command: command,
            inputText: selectedText,
            intent: intent
        ) {
            return result
        }

        throw CommandModeTransformError.invalidLLMOutput
    }

    private func attemptLLM(
        messages: [ChatMessage],
        localContext: LLMExecutionContext,
        options: ChatCompletionOptions,
        command: String,
        inputText: String,
        intent: CommandModeIntent
    ) async throws -> CommandModeTransformResult? {
        let response: ChatCompletionResponse
        do {
            response = try await llmClient.chatCompletion(
                messages: messages,
                context: localContext,
                options: options
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Map local runtime unavailability to the TRD's fail-closed message.
            // Never leak transcript/selection content into surfaced errors.
            if let llmError = error as? LLMError {
                switch llmError {
                case .notConfigured:
                    throw CommandModeTransformError.localModelUnavailable
                default:
                    throw CommandModeTransformError.llmFailed("Local model unavailable")
                }
            }
            throw CommandModeTransformError.localModelUnavailable
        }

        guard let parsed = CommandModeOutputValidator.parse(response.content) else {
            return nil
        }
        guard CommandModeOutputValidator.validate(
            output: parsed,
            command: command,
            inputText: inputText,
            intent: intent
        ) else {
            return nil
        }

        return CommandModeTransformResult(
            output: parsed.output.trimmingCharacters(in: .whitespacesAndNewlines),
            intent: intent,
            tier: .llm,
            deterministicTransform: nil,
            confidence: parsed.confidence
        )
    }
}
