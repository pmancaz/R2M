import Foundation

enum R2MPaths {
    static let dataDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["R2M_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("R2M", isDirectory: true)
    }()
    static let modelsDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["R2M_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return dataDirectory.appendingPathComponent("Models", isDirectory: true)
    }()
}
