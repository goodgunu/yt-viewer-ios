import Foundation
import os.log
import WebKit

enum UserScriptManager {
    private static let log = Logger(subsystem: "app.ytviewer.ios", category: "UserScript")

    /// Document-end script for the main frame and every subframe.
    static func makeUserScript() -> WKUserScript? {
        guard let url = Bundle.main.url(forResource: "youtube_adblock", withExtension: "js") else {
            log.error("youtube_adblock.js is missing from the app bundle")
            return nil
        }
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return WKUserScript(
                source: source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        } catch {
            log.error("youtube_adblock.js could not be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
