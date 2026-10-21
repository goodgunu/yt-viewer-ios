import Foundation
import os.log
import WebKit

/// Compiles the bundled content-blocker list and installs it on a web view.
/// A compile failure leaves browsing intact; the page still loads.
final class ContentRuleManager {
    static let shared = ContentRuleManager()

    private let identifier = "YTViewerBlocklist"
    private let log = Logger(subsystem: "app.ytviewer.ios", category: "ContentRule")

    private init() {}

    func apply(to webView: WKWebView, completion: @escaping () -> Void) {
        guard let url = Bundle.main.url(forResource: "blocklist", withExtension: "json") else {
            log.error("blocklist.json is missing from the app bundle")
            DispatchQueue.main.async(execute: completion)
            return
        }

        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            log.error("blocklist.json could not be read: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async(execute: completion)
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: source
        ) { [weak webView] list, error in
            if let error {
                self.log.error("WKContentRuleList failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                if let list, let webView {
                    let controller = webView.configuration.userContentController
                    controller.removeAllContentRuleLists()
                    controller.add(list)
                }
                completion()
            }
        }
    }
}
