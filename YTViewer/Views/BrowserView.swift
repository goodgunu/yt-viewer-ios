import SwiftUI
import UIKit
import WebKit

struct BrowserLoad: Equatable {
    var url: URL
    var generation: Int
}

struct BrowserView: UIViewRepresentable {
    var load: BrowserLoad?
    var onLocationChange: (URL) -> Void
    var onPageMessage: (String?) -> Void
    var onProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLocationChange: onLocationChange,
            onPageMessage: onPageMessage,
            onProgress: onProgress
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.preferences.isElementFullscreenEnabled = true

        let controller = configuration.userContentController
        controller.addUserScript(Self.inlinePlaybackScript)
        if let adScript = UserScriptManager.makeUserScript() {
            controller.addUserScript(adScript)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.mobileSafariUserAgent

        let background = UIColor(red: 0.071, green: 0.078, blue: 0.094, alpha: 1)
        webView.isOpaque = false
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.scrollView.keyboardDismissMode = .onDrag

        context.coordinator.attach(webView)
        context.coordinator.armRulesTimeout()

        let coordinator = context.coordinator
        ContentRuleManager.shared.apply(to: webView) { [weak coordinator] in
            coordinator?.noteRulesReady()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLocationChange = onLocationChange
        context.coordinator.onPageMessage = onPageMessage
        context.coordinator.onProgress = onProgress
        context.coordinator.requested = load
        context.coordinator.loadIfReady()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private static let mobileSafariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    private static let inlinePlaybackScript = WKUserScript(
        source: """
        (function () {
          if (window.__viewerInline) { return; }
          window.__viewerInline = true;
          var scheduled = false;
          function mark(video) {
            try {
              video.setAttribute("playsinline", "");
              video.setAttribute("webkit-playsinline", "");
              video.playsInline = true;
            } catch (e) {}
          }
          function scan() {
            var nodes = document.getElementsByTagName("video");
            for (var i = 0; i < nodes.length; i++) { mark(nodes[i]); }
          }
          function schedule() {
            if (scheduled) { return; }
            scheduled = true;
            requestAnimationFrame(function () {
              scheduled = false;
              scan();
            });
          }
          scan();
          try {
            new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onLocationChange: (URL) -> Void
        var onPageMessage: (String?) -> Void
        var onProgress: (Double) -> Void
        var requested: BrowserLoad?
        var rulesReady = false
        private var lastGeneration: Int?
        private weak var webView: WKWebView?
        private var observing = false

        init(
            onLocationChange: @escaping (URL) -> Void,
            onPageMessage: @escaping (String?) -> Void,
            onProgress: @escaping (Double) -> Void
        ) {
            self.onLocationChange = onLocationChange
            self.onPageMessage = onPageMessage
            self.onProgress = onProgress
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
            webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
            observing = true
        }

        func detach() {
            guard observing, let webView else { return }
            webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
            webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
            observing = false
        }

        deinit {
            detach()
        }

        func armRulesTimeout() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.rulesReady else { return }
                self.noteRulesReady()
            }
        }

        /// Rules usually compile immediately. If they arrive after a fallback load, reload once.
        func noteRulesReady() {
            let alreadyBrowsing = rulesReady
            rulesReady = true
            if alreadyBrowsing {
                if webView?.url != nil {
                    webView?.reload()
                }
                return
            }
            loadIfReady()
        }

        func loadIfReady() {
            guard rulesReady, let webView, let requested else { return }
            guard lastGeneration != requested.generation else { return }
            lastGeneration = requested.generation
            webView.load(URLRequest(url: requested.url))
        }

        override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard let webView else { return }
            if keyPath == #keyPath(WKWebView.url), let url = webView.url {
                onLocationChange(url)
            } else if keyPath == #keyPath(WKWebView.estimatedProgress) {
                onProgress(webView.estimatedProgress)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageMessage(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func report(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            onPageMessage(nsError.localizedDescription)
        }
    }
}
