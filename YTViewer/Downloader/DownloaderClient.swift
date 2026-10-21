#if PERSONAL_BUILD
import Combine
import Foundation

enum DownloaderClientError: Error {
    case invalidBaseURL
    case unreachable
    case invalidResponse
    case http(status: Int, message: String)
    case cancelled
}

struct DownloaderClient {
    var baseURLString: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func startDownload(pageURL: String, quality: String = "best", format: String = "mp4") async throws -> String {
        let endpoint = try endpoint("/api/download")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            DownloadRequest(url: pageURL, quality: quality, format: format)
        )

        let (data, response) = try await send(request)
        try Self.validate(data: data, response: response)
        do {
            let created = try JSONDecoder().decode(DownloadTaskCreated.self, from: data)
            guard !created.taskId.isEmpty else {
                throw DownloaderClientError.invalidResponse
            }
            return created.taskId
        } catch let error as DownloaderClientError {
            throw error
        } catch {
            throw DownloaderClientError.invalidResponse
        }
    }

    func poll(taskID: String) -> AsyncThrowingStream<TaskStatus, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let status = try await self.fetchStatus(taskID: taskID)
                        if Task.isCancelled { break }
                        continuation.yield(status)
                        let key = status.status.lowercased()
                        if key == "done" || key == "error" {
                            break
                        }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.mapError(error))
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func saveToFiles(remoteString: String) async throws -> URL {
        let remote = try resolve(remoteString)
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await Self.session.download(from: remote)
        } catch {
            throw Self.mapError(error)
        }
        try Self.validateStatus(response)

        do {
            let folder = try downloadsDirectory()
            let filename = sanitize(Self.filename(response: response, remote: remote))
            var destination = folder.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let stem = destination.deletingPathExtension().lastPathComponent
                let ext = destination.pathExtension
                let stamped = ext.isEmpty ? "\(stem)-\(stamp)" : "\(stem)-\(stamp).\(ext)"
                destination = folder.appendingPathComponent(stamped)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch let error as DownloaderClientError {
            throw error
        } catch {
            throw DownloaderClientError.http(status: 0, message: "ファイルを保存できませんでした")
        }
    }

    private func fetchStatus(taskID: String) async throws -> TaskStatus {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = taskID.addingPercentEncoding(withAllowedCharacters: allowed) ?? taskID
        var request = URLRequest(url: try endpoint("/api/tasks/\(encoded)"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        try Self.validate(data: data, response: response)
        do {
            return try JSONDecoder().decode(TaskStatus.self, from: data)
        } catch let error as DownloaderClientError {
            throw error
        } catch {
            throw DownloaderClientError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch {
            throw Self.mapError(error)
        }
    }

    private func normalizedBase() throws -> URL {
        var raw = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") {
            raw.removeLast()
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            throw DownloaderClientError.invalidBaseURL
        }
        return url
    }

    private func endpoint(_ path: String) throws -> URL {
        let base = try normalizedBase()
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base.absoluteString + suffix) else {
            throw DownloaderClientError.invalidBaseURL
        }
        return url
    }

    private func resolve(_ fileURL: String) throws -> URL {
        let trimmed = fileURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DownloaderClientError.invalidResponse
        }
        if let absolute = URL(string: trimmed),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           absolute.host != nil {
            return absolute
        }
        let base = try normalizedBase()
        let rootString = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        guard let root = URL(string: rootString),
              let resolved = URL(string: trimmed, relativeTo: root)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloaderClientError.invalidResponse
        }
        return resolved
    }

    private func downloadsDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw DownloaderClientError.http(status: 0, message: "ファイルを保存できませんでした")
        }
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw DownloaderClientError.http(status: 0, message: "ファイルを保存できませんでした")
        }
        return folder
    }

    private func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "video.mp4"
        }
        return String(trimmed.prefix(120))
    }

    private static func filename(response: URLResponse, remote: URL) -> String {
        if let http = response as? HTTPURLResponse,
           let header = http.value(forHTTPHeaderField: "Content-Disposition"),
           let parsed = filenameFromContentDisposition(header) {
            return parsed
        }
        let last = remote.lastPathComponent
        if !last.isEmpty, last != "/", last.contains(".") {
            return last.removingPercentEncoding ?? last
        }
        return "video.mp4"
    }

    private static func filenameFromContentDisposition(_ header: String) -> String? {
        if let range = header.range(of: "filename*=", options: .caseInsensitive) {
            var value = header[range.upperBound...]
            if let semi = value.firstIndex(of: ";") {
                value = value[..<semi]
            }
            var token = value.trimmingCharacters(in: .whitespaces)
            if let mark = token.range(of: "''") {
                token = token[mark.upperBound...]
            }
            let decoded = token.removingPercentEncoding ?? String(token)
            let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let range = header.range(of: "filename=", options: .caseInsensitive) {
            var value = header[range.upperBound...]
            if let semi = value.firstIndex(of: ";") {
                value = value[..<semi]
            }
            var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
                token.removeFirst()
                token.removeLast()
            }
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DownloaderClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["message"] as? String {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    throw DownloaderClientError.http(status: http.statusCode, message: String(trimmed.prefix(180)))
                }
            }
            throw DownloaderClientError.unreachable
        }
    }

    private static func validateStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DownloaderClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloaderClientError.unreachable
        }
    }

    static func mapError(_ error: Error) -> DownloaderClientError {
        if error is CancellationError {
            return .cancelled
        }
        if let client = error as? DownloaderClientError {
            return client
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return .cancelled
            }
            return .unreachable
        }
        if error is DecodingError {
            return .invalidResponse
        }
        return .invalidResponse
    }
}

@MainActor
final class DownloadSessionModel: ObservableObject {
    @Published var isActive = false
    @Published var status = ""
    @Published var percent = 0.0
    @Published var speed = ""
    @Published var eta = ""
    @Published var message = ""
    @Published var toast: String?
    @Published var shareURL: URL?

    private var task: Task<Void, Never>?
    private var generation = 0
    private var toastToken = 0

    static let unreachableToast = "ダウンロードサーバー未接続（準備中）"

    var fraction: Double {
        min(max(percent / 100, 0), 1)
    }

    var percentText: String {
        let clamped = min(max(percent, 0), 100)
        return "\(Int(clamped.rounded()))%"
    }

    var statusLabel: String {
        switch status.lowercased() {
        case "downloading":
            return "ダウンロード中"
        case "merging":
            return "結合中"
        case "done":
            return "完了"
        case "error":
            return "エラー"
        case "":
            return "接続しています"
        default:
            return status
        }
    }

    func start(pageURL: String) {
        task?.cancel()
        generation += 1
        let generation = generation
        shareURL = nil
        toast = nil
        status = ""
        percent = 0
        speed = ""
        eta = ""
        message = "接続しています"
        isActive = true
        task = Task { [weak self] in
            await self?.run(pageURL: pageURL, generation: generation)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isActive = false
    }

    private func run(pageURL: String, generation: Int) async {
        guard isCurrent(generation) else { return }
        let client = DownloaderClient(baseURLString: ServerSettings.baseURLString)
        do {
            let taskID = try await client.startDownload(pageURL: pageURL)
            guard isCurrent(generation) else { return }
            for try await status in client.poll(taskID: taskID) {
                guard isCurrent(generation) else { return }
                apply(status)
                let key = status.status.lowercased()
                if key == "done" {
                    try await save(status, client: client, generation: generation)
                    return
                }
                if key == "error" {
                    guard isCurrent(generation) else { return }
                    message = status.message.isEmpty ? "ダウンロードに失敗しました" : status.message
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch let error as DownloaderClientError {
            guard isCurrent(generation) else { return }
            handle(error)
        } catch {
            guard isCurrent(generation) else { return }
            handle(.unreachable)
        }
    }

    private func save(_ status: TaskStatus, client: DownloaderClient, generation: Int) async throws {
        let file = status.fileURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else {
            message = "ファイルのURLが応答に含まれていません"
            return
        }
        message = "ファイルを保存しています"
        let local = try await client.saveToFiles(remoteString: file)
        guard isCurrent(generation) else { return }
        self.status = "done"
        percent = max(percent, 100)
        message = "ファイル App に保存しました"
        shareURL = local
    }

    private func apply(_ status: TaskStatus) {
        self.status = status.status
        percent = status.percent
        speed = status.speed
        eta = status.eta
        if !status.message.isEmpty {
            message = status.message
        }
    }

    private func handle(_ error: DownloaderClientError) {
        switch error {
        case .cancelled:
            isActive = false
        case .invalidBaseURL:
            isActive = false
            showToast("サーバーURLが正しくありません")
        case .unreachable, .invalidResponse:
            isActive = false
            showToast(Self.unreachableToast)
        case let .http(_, message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            self.status = "error"
            self.message = trimmed.isEmpty ? "サーバーからエラーが返りました" : trimmed
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastToken += 1
        let token = toastToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.toastToken == token else { return }
            self.toast = nil
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && !Task.isCancelled
    }
}
#endif
