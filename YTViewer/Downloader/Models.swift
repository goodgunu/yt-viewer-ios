#if PERSONAL_BUILD
import Foundation

enum ServerSettings {
    static let storageKey = "downloadServerBaseURL"
    static let defaultBaseURL = "http://192.168.1.10:8000"

    static var baseURLString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: storageKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultBaseURL : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: storageKey)
        }
    }
}

struct DownloadRequest: Codable, Equatable {
    let url: String
    let quality: String
    let format: String
}

struct DownloadTaskCreated: Codable, Equatable {
    let taskId: String

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
    }
}

/// Wire format: status, percent (0...100), speed, eta, message, file_url.
struct TaskStatus: Codable, Equatable {
    let status: String
    let percent: Double
    let speed: String
    let eta: String
    let message: String
    let fileURL: String

    enum CodingKeys: String, CodingKey {
        case status
        case percent
        case speed
        case eta
        case message
        case fileURL = "file_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        if let value = try? container.decode(Double.self, forKey: .percent) {
            percent = value
        } else if let raw = try? container.decode(String.self, forKey: .percent), let value = Double(raw) {
            percent = value
        } else {
            percent = 0
        }
        speed = (try? container.decode(String.self, forKey: .speed)) ?? ""
        eta = (try? container.decode(String.self, forKey: .eta)) ?? ""
        message = (try? container.decode(String.self, forKey: .message)) ?? ""
        fileURL = (try? container.decode(String.self, forKey: .fileURL)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(percent, forKey: .percent)
        try container.encode(speed, forKey: .speed)
        try container.encode(eta, forKey: .eta)
        try container.encode(message, forKey: .message)
        try container.encode(fileURL, forKey: .fileURL)
    }
}
#endif
