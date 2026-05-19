import os.log

enum AppLog {
    private static let subsystem = "com.adrianprecub.Voice2MD"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let claude = Logger(subsystem: subsystem, category: "claude")
    static let whisper = Logger(subsystem: subsystem, category: "whisper")
    static let watcher = Logger(subsystem: subsystem, category: "watcher")
}
