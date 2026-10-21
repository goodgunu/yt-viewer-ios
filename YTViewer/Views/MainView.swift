import SwiftUI
import UIKit

struct MainView: View {
    @State private var urlText = ""
    @State private var load: BrowserLoad?
    @State private var loadGeneration = 0
    @State private var pageProgress = 0.0
    @State private var pageMessage: String?
    @State private var showSettings = false
    @FocusState private var urlFieldFocused: Bool

    #if PERSONAL_BUILD
    @StateObject private var downloadModel = DownloadSessionModel()
    #endif

    var body: some View {
        #if PERSONAL_BUILD
        base
            .sheet(
                isPresented: Binding(
                    get: { downloadModel.shareURL != nil },
                    set: { presented in
                        if !presented {
                            downloadModel.shareURL = nil
                        }
                    }
                )
            ) {
                if let url = downloadModel.shareURL {
                    ActivityShareSheet(url: url)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = downloadModel.toast {
                    ToastBanner(text: toast)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
            }
            .animation(.easeOut(duration: 0.2), value: downloadModel.toast)
        #else
        base
        #endif
    }

    private var base: some View {
        layout
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .preferredColorScheme(.dark)
    }

    private var layout: some View {
        VStack(spacing: 0) {
            topBar
            if pageProgress > 0.02 && pageProgress < 0.98 {
                ProgressView(value: pageProgress)
                    .tint(ViewerColor.accent)
                    .scaleEffect(x: 1, y: 0.55, anchor: .center)
            }
            #if PERSONAL_BUILD
            if downloadModel.isActive {
                downloadProgress
            }
            #endif
            if let pageMessage {
                pageBanner(pageMessage)
            }
            ZStack {
                BrowserView(
                    load: load,
                    onLocationChange: { url in
                        guard !urlFieldFocused else { return }
                        let absolute = url.absoluteString
                        if absolute != urlText {
                            urlText = absolute
                        }
                    },
                    onPageMessage: { message in
                        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        pageMessage = trimmed.isEmpty ? nil : trimmed
                    },
                    onProgress: { value in
                        pageProgress = value
                    }
                )
                .opacity(load == nil ? 0 : 1)
                .allowsHitTesting(load != nil)
                .ignoresSafeArea(edges: .bottom)

                if load == nil {
                    emptyState
                }
            }
        }
        .background(ViewerColor.background.ignoresSafeArea())
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("VIEWER")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(ViewerColor.accent)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ViewerColor.ink)
                        .frame(width: 36, height: 36)
                        .background(ViewerColor.raised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("設定")
            }

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $urlText,
                    prompt: Text("https://").foregroundStyle(ViewerColor.muted)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(ViewerColor.ink)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($urlFieldFocused)
                .onSubmit(openEnteredURL)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(ViewerColor.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ViewerColor.ink.opacity(0.08), lineWidth: 1)
                )
                .layoutPriority(1)

                Button(action: openEnteredURL) {
                    Text("開く")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(ViewerColor.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                #if PERSONAL_BUILD
                Button(action: startDownload) {
                    Text("ダウンロード")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(ViewerColor.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(ViewerColor.accent.opacity(0.75), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(ViewerColor.accent)
            Text("動画ページの URL を入力して開く")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ViewerColor.ink)
                .multilineTextAlignment(.center)
            Text("再生はこの画面の中で続きます。")
                .font(.system(size: 13))
                .foregroundStyle(ViewerColor.muted)
        }
        .padding(.horizontal, 32)
    }

    private func pageBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                pageMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("閉じる")
        }
        .font(.system(size: 13))
        .foregroundStyle(ViewerColor.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ViewerColor.danger.opacity(0.22))
    }

    private func openEnteredURL() {
        urlFieldFocused = false
        guard let url = Self.normalizedWebURL(from: urlText) else {
            let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            pageMessage = trimmed.isEmpty ? nil : "URLを確認してください"
            return
        }
        pageMessage = nil
        urlText = url.absoluteString
        pageProgress = 0
        loadGeneration += 1
        load = BrowserLoad(url: url, generation: loadGeneration)
    }

    static func normalizedWebURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let encoded = withScheme.replacingOccurrences(of: " ", with: "%20")
        guard let url = URL(string: encoded),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    #if PERSONAL_BUILD
    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(downloadModel.statusLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ViewerColor.ink)
                Spacer(minLength: 8)
                Text(downloadModel.percentText)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(ViewerColor.muted)
                Button("キャンセル") {
                    downloadModel.cancel()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ViewerColor.danger)
                .buttonStyle(.plain)
            }
            ProgressView(value: downloadModel.fraction)
                .tint(ViewerColor.accent)
            HStack {
                if !downloadModel.speed.isEmpty {
                    Text(downloadModel.speed)
                }
                Spacer()
                if !downloadModel.eta.isEmpty {
                    Text(downloadModel.eta)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(ViewerColor.muted)
            if !downloadModel.message.isEmpty {
                Text(downloadModel.message)
                    .font(.system(size: 12))
                    .foregroundStyle(ViewerColor.ink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ViewerColor.raised)
        .accessibilityElement(children: .combine)
    }

    private func startDownload() {
        urlFieldFocused = false
        guard let url = Self.normalizedWebURL(from: urlText) else {
            pageMessage = "URLを確認してください"
            return
        }
        pageMessage = nil
        urlText = url.absoluteString
        downloadModel.start(pageURL: url.absoluteString)
    }
    #endif
}

#if PERSONAL_BUILD
private struct ToastBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ViewerColor.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(ViewerColor.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ViewerColor.accent.opacity(0.45), lineWidth: 1)
            )
            .accessibilityLabel(text)
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        configurePopover(controller)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        configurePopover(controller)
    }

    private func configurePopover(_ controller: UIActivityViewController) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.permittedArrowDirections = []
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        let window = scene.keyWindow ?? scene.windows.first
        guard let window else { return }
        popover.sourceView = window
        popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
    }
}
#endif
