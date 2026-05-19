import Foundation
import UserNotifications

@MainActor
enum Notifier {
    private static var didRequestAuthorization = false

    static func notifyError(_ message: String) {
        post(title: "Voice2MD — failed", body: message, identifier: "vm2md.error")
    }

    static func notifyInfo(_ message: String) {
        post(title: "Voice2MD", body: message, identifier: "vm2md.info")
    }

    private static func post(title: String, body: String, identifier: String) {
        Task {
            await ensureAuthorized()
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(160))
            let request = UNNotificationRequest(
                identifier: "\(identifier).\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private static func ensureAuthorized() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }
}
