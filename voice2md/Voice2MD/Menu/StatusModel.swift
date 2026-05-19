import Foundation
import Observation

@Observable
@MainActor
final class StatusModel {
    enum State: Sendable, Equatable {
        case idle
        case processing(filename: String)
        case error(message: String)
    }

    var state: State = .idle
    var lastOutputs: [URL] = []
    var errorCountSinceLaunch: Int = 0
    var processedSinceLaunch: Int = 0

    func startProcessing(_ filename: String) {
        state = .processing(filename: filename)
    }

    func finishedProcessing(output: URL?) {
        if let output {
            var updated = lastOutputs.filter { $0 != output }
            updated.insert(output, at: 0)
            lastOutputs = Array(updated.prefix(10))
            processedSinceLaunch += 1
        }
        if case .error = state {
            // keep error sticky until next success or manual clear
        } else {
            state = .idle
        }
    }

    func recordError(_ msg: String) {
        state = .error(message: msg)
        errorCountSinceLaunch += 1
    }

    func clearErrorIfAny() {
        if case .error = state { state = .idle }
    }

    func iconName(paused: Bool) -> String {
        if paused { return "waveform.path.badge.minus" }
        switch state {
        case .idle: return "waveform"
        case .processing: return "waveform.circle"
        case .error: return "waveform.badge.exclamationmark"
        }
    }

    func statusLine(paused: Bool) -> String {
        if paused { return "Paused" }
        switch state {
        case .idle:
            return processedSinceLaunch == 0
                ? "Idle"
                : "Idle — \(processedSinceLaunch) processed this session"
        case .processing(let filename):
            return "Processing \(filename)…"
        case .error(let message):
            return "Last error: \(message)"
        }
    }
}
