import Foundation

/// Routes LLM requests to the appropriate client based on provider ID.
/// HTTP-based providers go to `LLMClient`; `.localCLI` goes to
/// `LocalCLILLMClient`; `.inProcessLocal` goes to `InProcessLLMClient`;
/// `.appleIntelligence` goes to `AppleIntelligenceLLMClient`.
public final class RoutingLLMClient: LLMClientProtocol, Sendable {
    private let httpClient: any LLMClientProtocol
    private let cliClient: any LLMClientProtocol
    private let inProcessClient: any LLMClientProtocol
    private let appleIntelligenceClient: any LLMClientProtocol

    public init(
        httpClient: any LLMClientProtocol = LLMClient(),
        cliClient: any LLMClientProtocol = LocalCLILLMClient(),
        inProcessClient: any LLMClientProtocol = InProcessLLMClient(),
        appleIntelligenceClient: any LLMClientProtocol = AppleIntelligenceLLMClient()
    ) {
        self.httpClient = httpClient
        self.cliClient = cliClient
        self.inProcessClient = inProcessClient
        self.appleIntelligenceClient = appleIntelligenceClient
    }

    public var supportsInProcessLocalLLM: Bool {
        inProcessClient.supportsInProcessLocalLLM
    }

    /// Exposes the in-process local client for Command Mode's fail-closed
    /// local-only path. Returns nil-like behavior via `supportsInProcessLocalLLM`
    /// check on the caller side.
    public var inProcessLocalClient: any LLMClientProtocol {
        inProcessClient
    }

    /// Creates an execution context for Command Mode that targets the local
    /// in-process MLX provider only. Returns nil if in-process local LLM is
    /// not supported by the current build/runtime.
    public func makeCommandModeLocalContext(
        modelName: String = LLMProviderID.inProcessLocal.defaultModelName
    ) -> LLMExecutionContext? {
        guard inProcessClient.supportsInProcessLocalLLM else { return nil }
        return LLMExecutionContext(providerConfig: .inProcessLocal(model: modelName))
    }

    public func structuredOutputCapability(
        context: LLMExecutionContext
    ) -> LLMStructuredOutputCapability {
        client(for: context).structuredOutputCapability(context: context)
    }

    public func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        try await client(for: context).chatCompletion(messages: messages, context: context, options: options)
    }

    public func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        client(for: context).chatCompletionStream(messages: messages, context: context, options: options)
    }

    public func chatCompletionDetailedStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        client(for: context).chatCompletionDetailedStream(
            messages: messages,
            context: context,
            options: options
        )
    }

    public func testConnection(context: LLMExecutionContext) async throws {
        try await client(for: context).testConnection(context: context)
    }

    public func listModels(context: LLMExecutionContext) async throws -> [String] {
        try await client(for: context).listModels(context: context)
    }

    public func withInProcessLocalModelRemoval(_ operation: @Sendable () async throws -> Void) async throws {
        try await inProcessClient.withInProcessLocalModelRemoval(operation)
    }

    private func client(for context: LLMExecutionContext) -> any LLMClientProtocol {
        switch context.providerConfig.id {
        case .localCLI:
            return cliClient
        case .inProcessLocal:
            return inProcessClient
        case .appleIntelligence:
            return appleIntelligenceClient
        case .anthropic, .openai, .openaiCompatible, .gemini, .openrouter, .moonshot, .deepseek, .qwen, .zai, .minimax,
            .ollama, .lmstudio:
            return httpClient
        }
    }
}
