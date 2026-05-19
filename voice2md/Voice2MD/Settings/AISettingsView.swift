import SwiftUI

struct AISettingsView: View {
    @Environment(AppConfig.self) private var config
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        @Bindable var config = config
        Form {
            Section {
                Toggle("Use AI to extract structure", isOn: $config.useAIExtraction)
                Text("When off, the markdown contains only the transcript with minimal frontmatter — no API call, no key required. Turn on to add Claude/Azure/Ollama-generated title, summary, key ideas, action items, and entities.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                Section("Provider") {
                    Picker("Provider", selection: $config.aiProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch config.aiProvider {
                case .anthropic:
                    anthropicSection
                case .azureOpenAI:
                    azureSection
                case .ollama:
                    ollamaSection
                }

                Section {
                    HStack {
                        Button(testButtonLabel) { runTest() }
                            .disabled(!isCurrentProviderConfigured || testStatus == .testing)
                        statusView
                        Spacer()
                    }
                }
            }
            .disabled(!config.useAIExtraction)
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: config.aiProvider) { _, _ in testStatus = .idle }
        .onChange(of: config.useAIExtraction) { _, _ in testStatus = .idle }
    }

    @ViewBuilder
    private var anthropicSection: some View {
        @Bindable var config = config
        Section("Anthropic") {
            SecureField("API Key", text: $config.anthropicApiKey, prompt: Text("sk-ant-…"))
                .textFieldStyle(.roundedBorder)
            Picker("Model", selection: $config.claudeModel) {
                Text("Claude Haiku 4.5").tag("claude-haiku-4-5")
                Text("Claude Sonnet 4.6").tag("claude-sonnet-4-6")
            }
        }
    }

    @ViewBuilder
    private var azureSection: some View {
        @Bindable var config = config
        Section("Azure OpenAI") {
            SecureField("API Key", text: $config.azureApiKey, prompt: Text("Azure OpenAI key"))
                .textFieldStyle(.roundedBorder)
            TextField(
                "Endpoint",
                text: $config.azureEndpoint,
                prompt: Text("https://my-resource.openai.azure.com")
            )
            .textFieldStyle(.roundedBorder)
            TextField("Deployment", text: $config.azureDeployment, prompt: Text("e.g. gpt-4o"))
                .textFieldStyle(.roundedBorder)
            TextField(
                "API Version",
                text: $config.azureApiVersion,
                prompt: Text(AppConfig.defaultAzureApiVersion)
            )
            .textFieldStyle(.roundedBorder)
            Text("The deployment name is the one you set in Azure AI Studio, not the underlying model name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var ollamaSection: some View {
        @Bindable var config = config
        Section("Ollama (local)") {
            TextField(
                "Endpoint",
                text: $config.ollamaEndpoint,
                prompt: Text(AppConfig.defaultOllamaEndpoint)
            )
            .textFieldStyle(.roundedBorder)
            TextField(
                "Model",
                text: $config.ollamaModel,
                prompt: Text("e.g. llama3.1:8b, qwen2.5:14b")
            )
            .textFieldStyle(.roundedBorder)
            Text("Run `ollama serve` and `ollama pull <model>` first. Use a model with at least 7B parameters — smaller models often produce malformed JSON.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch testStatus {
        case .idle, .testing:
            EmptyView()
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
                .lineLimit(2)
        }
    }

    private var testButtonLabel: String {
        testStatus == .testing ? "Testing…" : "Test Connection"
    }

    private var isCurrentProviderConfigured: Bool {
        switch config.aiProvider {
        case .anthropic:
            return !config.anthropicApiKey.isEmpty
        case .azureOpenAI:
            return !config.azureApiKey.isEmpty
                && !config.azureEndpoint.isEmpty
                && !config.azureDeployment.isEmpty
        case .ollama:
            return !config.ollamaEndpoint.isEmpty && !config.ollamaModel.isEmpty
        }
    }

    private func runTest() {
        let extractor = makeExtractor()
        testStatus = .testing
        Task { @MainActor in
            do {
                try await extractor.testConnection()
                testStatus = .success
            } catch {
                testStatus = .failure(error.localizedDescription)
            }
        }
    }

    private func makeExtractor() -> any AIExtractor {
        switch config.aiProvider {
        case .anthropic:
            return ClaudeClient(apiKey: config.anthropicApiKey, model: config.claudeModel)
        case .azureOpenAI:
            return AzureOpenAIClient(
                apiKey: config.azureApiKey,
                endpoint: config.azureEndpoint,
                deployment: config.azureDeployment,
                apiVersion: config.azureApiVersion
            )
        case .ollama:
            return OllamaClient(
                endpoint: config.ollamaEndpoint,
                model: config.ollamaModel
            )
        }
    }
}
