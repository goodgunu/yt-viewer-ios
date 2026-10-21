import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    #if PERSONAL_BUILD
    @State private var serverURL = ServerSettings.baseURLString
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Viewer")
                            .font(.headline)
                            .foregroundStyle(ViewerColor.ink)
                        Text("動画サイトをアプリ内ブラウザで開いて再生します。コンテンツフィルタで広告枠の読み込みを抑えます。")
                            .font(.subheadline)
                            .foregroundStyle(ViewerColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("開いたページの通信先は、そのサイト自身です。フィルタはアプリに同梱したルールとスクリプトで、表示の前に適用します。")
                }

                #if PERSONAL_BUILD
                Section {
                    TextField(ServerSettings.defaultBaseURL, text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    Button("既定値に戻す") {
                        serverURL = ServerSettings.defaultBaseURL
                    }
                } header: {
                    Text("ダウンロードサーバー")
                } footer: {
                    Text("外部サーバーのベース URL です。末尾のスラッシュは不要です。サーバー本体はこのアプリに含まれません。届かないときは「ダウンロードサーバー未接続（準備中）」と表示し、アプリは終了しません。")
                }
                #else
                Section {
                    Text("このビルドはページ表示と広告ブロックのみです。")
                        .font(.subheadline)
                        .foregroundStyle(ViewerColor.muted)
                }
                #endif

                Section {
                    LabeledContent("バージョン", value: appVersion)
                    LabeledContent("構成", value: buildKind)
                }
            }
            .tint(ViewerColor.accent)
            .scrollContentBackground(.hidden)
            .background(ViewerColor.background)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .toolbarBackground(ViewerColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onDisappear(perform: persist)
        }
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var buildKind: String {
        #if PERSONAL_BUILD
        "Personal"
        #else
        "配信版"
        #endif
    }

    private func persist() {
        #if PERSONAL_BUILD
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ServerSettings.baseURLString = trimmed.isEmpty ? ServerSettings.defaultBaseURL : trimmed
        #endif
    }
}
