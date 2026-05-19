import Foundation
import Observation

@Observable
final class AppConfig {
    @ObservationIgnored
    private let defaults: UserDefaults

    var useAIExtraction: Bool {
        didSet { defaults.set(useAIExtraction, forKey: Keys.useAIExtraction) }
    }
    var aiProvider: AIProvider {
        didSet { defaults.set(aiProvider.rawValue, forKey: Keys.aiProvider) }
    }
    var inputFolderBookmark: Data? {
        didSet { defaults.set(inputFolderBookmark, forKey: Keys.inputFolderBookmark) }
    }
    var outputFolderBookmark: Data? {
        didSet { defaults.set(outputFolderBookmark, forKey: Keys.outputFolderBookmark) }
    }
    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Keys.claudeModel) }
    }
    var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Keys.whisperModel) }
    }
    var extensionAllowlist: [String] {
        didSet { defaults.set(extensionAllowlist, forKey: Keys.extensionAllowlist) }
    }
    var paused: Bool {
        didSet { defaults.set(paused, forKey: Keys.paused) }
    }
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    var anthropicApiKey: String {
        didSet { Keychain.write(anthropicApiKey, account: Keychain.anthropicAccount) }
    }
    var azureApiKey: String {
        didSet { Keychain.write(azureApiKey, account: Keychain.azureAccount) }
    }
    var azureEndpoint: String {
        didSet { defaults.set(azureEndpoint, forKey: Keys.azureEndpoint) }
    }
    var azureDeployment: String {
        didSet { defaults.set(azureDeployment, forKey: Keys.azureDeployment) }
    }
    var azureApiVersion: String {
        didSet { defaults.set(azureApiVersion, forKey: Keys.azureApiVersion) }
    }
    var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Keys.ollamaEndpoint) }
    }
    var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        self.useAIExtraction = d.bool(forKey: Keys.useAIExtraction)
        let providerRaw = d.string(forKey: Keys.aiProvider) ?? AIProvider.anthropic.rawValue
        self.aiProvider = AIProvider(rawValue: providerRaw) ?? .anthropic
        self.inputFolderBookmark = d.data(forKey: Keys.inputFolderBookmark)
        self.outputFolderBookmark = d.data(forKey: Keys.outputFolderBookmark)
        self.claudeModel = d.string(forKey: Keys.claudeModel) ?? "claude-haiku-4-5"
        self.whisperModel = d.string(forKey: Keys.whisperModel) ?? "small.en"
        self.extensionAllowlist = d.stringArray(forKey: Keys.extensionAllowlist) ?? Self.defaultExtensions
        self.paused = d.bool(forKey: Keys.paused)
        self.launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        self.anthropicApiKey = Keychain.read(account: Keychain.anthropicAccount) ?? ""
        self.azureApiKey = Keychain.read(account: Keychain.azureAccount) ?? ""
        self.azureEndpoint = d.string(forKey: Keys.azureEndpoint) ?? ""
        self.azureDeployment = d.string(forKey: Keys.azureDeployment) ?? ""
        self.azureApiVersion = d.string(forKey: Keys.azureApiVersion) ?? Self.defaultAzureApiVersion
        self.ollamaEndpoint = d.string(forKey: Keys.ollamaEndpoint) ?? Self.defaultOllamaEndpoint
        self.ollamaModel = d.string(forKey: Keys.ollamaModel) ?? ""
    }

    static let defaultOllamaEndpoint = "http://localhost:11434"

    static let defaultExtensions = [
        "m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "m4b",
        "mp4", "mov", "mkv", "webm", "wma"
    ]
    static let defaultAzureApiVersion = "2024-08-01-preview"

    func resolveInputFolderURL() -> URL? { Self.resolveBookmark(inputFolderBookmark) }
    func resolveOutputFolderURL() -> URL? { Self.resolveBookmark(outputFolderBookmark) }

    private static func resolveBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private enum Keys {
        static let useAIExtraction = "useAIExtraction"
        static let aiProvider = "aiProvider"
        static let inputFolderBookmark = "inputFolderBookmark"
        static let outputFolderBookmark = "outputFolderBookmark"
        static let claudeModel = "claudeModel"
        static let whisperModel = "whisperModel"
        static let extensionAllowlist = "extensionAllowlist"
        static let paused = "paused"
        static let launchAtLogin = "launchAtLogin"
        static let azureEndpoint = "azureEndpoint"
        static let azureDeployment = "azureDeployment"
        static let azureApiVersion = "azureApiVersion"
        static let ollamaEndpoint = "ollamaEndpoint"
        static let ollamaModel = "ollamaModel"
    }
}
