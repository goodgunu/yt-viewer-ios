# 引き継ぎ

次にこのリポジトリを触る人（人間でも、別の AI でも）向けのメモです。実装の前に、下の「守ること」を読んでください。

## 目的

iPhone 向けのアプリ内ブラウザです。動画サイトを WKWebView で開き、広告枠を二段で抑えます。

1. 同梱の `blocklist.json` を `WKContentRuleList` にコンパイルする
2. `youtube_adblock.js` を document end、メインフレームとサブフレームの両方に入れる

Personal ビルドだけ、まだ無い外部ダウンロードサーバーへつなぐ HTTP クライアントと画面を持ちます。抽出や結合はアプリの仕事ではありません。

画面上の名前は Store が Viewer、Personal が Viewer P です。Xcode のターゲット名は YTViewer です。

## 仕様の要約

- Xcode 15 以降、SwiftUI、iOS 16 以降、iPhone のみ
- 上段に URL 欄、開く、Personal だけダウンロード、歯車で設定
- 本体は WKWebView。インライン再生（`allowsInlineMediaPlayback`、メディアのユーザー操作不要）
- 設定のベース URL 既定値は `http://192.168.1.10:8000`
- ダウンロードは POST → 0.5 秒間隔のポーリング → 進捗 UI → `file_url` を書類フォルダ `Downloads` に保存し、共有シートも出す
- サーバーに届かないときはトースト「ダウンロードサーバー未接続（準備中）」。落とさない
- `Info.plist` はローカル HTTP を許可する。`NSAllowsArbitraryLoads` は Personal だけ
- 構成は Store と Personal の二つ。Personal だけ `SWIFT_ACTIVE_COMPILATION_CONDITIONS = PERSONAL_BUILD`
- App Store 用の文面は [docs/AppStore.md](docs/AppStore.md)。特定サービスの名前を出さない
- ブロックリスト更新ツールは `tools/convert_easylist.py`

## 守ること

破ると、このリポジトリの前提が崩れます。

- **サーバー側のダウンロード実装をここに書かない。** yt-dlp、署名解読、ストリーム抽出、結合処理は禁止。サーバーは別リポジトリで後から作る。このアプリは HTTP クライアントと UI だけ。
- **API 契約を変えない。** フィールド名はスネークケースのまま。

  ```http
  POST {base}/api/download
  {"url":"...","quality":"best","format":"mp4"}
  → {"task_id":"..."}

  GET {base}/api/tasks/{task_id}
  → {"status":"downloading|merging|done|error","percent":0.0,"speed":"...","eta":"...","message":"...","file_url":"..."}
  ```

  `percent` は 0 から 100。`quality` は `best`、`format` は `mp4` を送る。`file_url` が相対ならベース URL 基準。
- **ディレクトリ構成を動かさない。** 仕様で決まっているパスは次のとおり。リネームや別ターゲットへの移動をしない。ビルドに必要な追加ファイル（`Info.plist`、アセット、プライバシーマニフェスト、この文書、CI）は置いてよい。

  ```
  YTViewer.xcodeproj
  YTViewer/YTViewerApp.swift
  YTViewer/Views/MainView.swift
  YTViewer/Views/BrowserView.swift
  YTViewer/AdBlock/ContentRuleManager.swift
  YTViewer/AdBlock/UserScriptManager.swift
  YTViewer/Resources/blocklist.json
  YTViewer/Resources/youtube_adblock.js
  YTViewer/Downloader/DownloaderClient.swift
  YTViewer/Downloader/Models.swift
  YTViewer/Settings/SettingsView.swift
  tools/convert_easylist.py
  README.md
  ```

- **Store と Personal を混ぜない。** Store ビルドは広告ブロックだけ。Personal だけが外部サーバー接続を含む。
  - `Downloader/` のファイルは先頭から末尾まで `#if PERSONAL_BUILD` で囲む
  - Store 構成の `EXCLUDED_SOURCE_FILE_NAMES` からも外す
  - ダウンロードボタン、進捗、設定のサーバー URL、未接続トーストも `#if PERSONAL_BUILD` の中だけ
  - Store のバイナリに、隠したダウンロード機能を残さない
- **Store の審査用画面にダウンロード UI を出さない。** スクリーンショットは Store スキームで撮る。
- **動画本体のホストをブロックリストで塞がない。** `googlevideo.com` やサムネイル用ホストをドメインごと止めると再生が壊れる。広告配信用ホストと、分かっている広告パスに留める。

## 今の状態

ソースは揃っている。**Mac 上でのビルドは、この文書を書いた時点ではまだ一度も通していない。** 書いた環境は Linux で、Xcode も Swift も無かった。確認できたのは次だけ。

- `project.pbxproj` の ID、ファイル参照、Store / Personal の設定が食い違っていない
- `Info.plist` の `#if PERSONAL_BUILD` を両方の構成として展開し、XML として読める
- Store 向けにプリプロセスした Swift から、ダウンロードの文字列と型名が消える
- `tools/convert_easylist.py --self-test` と、同梱 `blocklist.json` の `--check`
- `youtube_adblock.js` が JavaScript として構文エラーでない

最初の実コンパイルは GitHub Actions（`.github/workflows/ios-build.yml`）に任せてある。ジョブは二つ。

- `build` は macOS 上で Store と Personal をシミュレータ向けに署名なしでビルドし、Store の実行ファイルに `DownloaderClient` と `/api/download` が無いこと、Personal には `DownloaderClient` があることを見る。成果物はシミュレータ用の Personal `.app`。iPhone には入らない。
- `device` は同じ二つの構成を `generic/platform=iOS`（iphoneos）で署名なしにビルドする。プロジェクトは Automatic 署名でチームが空なので、`CODE_SIGNING_ALLOWED=NO` に加え `CODE_SIGN_STYLE=Manual` と空のチームを渡している。できた `.app` を `Payload/` に入れて `YTViewer-Store-unsigned.ipa` と `YTViewer-Personal-unsigned.ipa` として上げる。未署名のままでは実機に入らない。Windows では Sideloadly が Apple ID で署名し直す。無料 Apple ID はおおよそ 7 日で署名が切れる。Store の IPA にもダウンローダ記号が無いことを見ている。

緑になるまでは「コンパイルできる」と書かない。この IPA は App Store 用の Archive ではない。配信は Store スキームの正式な Archive だけ。

## ファイルごとの役割

| パス | 役割 |
| --- | --- |
| `YTViewer.xcodeproj/project.pbxproj` | 手書き。objectVersion 56。構成は Store と Personal だけ。Debug / Release は無い |
| `YTViewer.xcodeproj/xcshareddata/xcschemes/Store.xcscheme` | 全アクションが Store |
| `YTViewer.xcodeproj/xcshareddata/xcschemes/Personal.xcscheme` | 全アクションが Personal。日常の確認とサイドロード用 |
| `YTViewer/YTViewerApp.swift` | `@main`。色は `ViewerColor` |
| `YTViewer/Views/MainView.swift` | URL、開く、歯車、空の状態、ページのエラー。ダウンロード UI は `#if` の中 |
| `YTViewer/Views/BrowserView.swift` | `WKWebView`。インライン再生、モバイル Safari の UA、別ウィンドウのリンクは同じ画面で開く。ルールのコンパイルを待ってから読む。3 秒待っても終わらなければ先に開き、ルールが後から来たら一度だけ再読み込み |
| `YTViewer/AdBlock/ContentRuleManager.swift` | `blocklist.json` をコンパイルして web view に足す。失敗しても閲覧は続ける |
| `YTViewer/AdBlock/UserScriptManager.swift` | `youtube_adblock.js` を `.atDocumentEnd`、`forMainFrameOnly: false` で入れる |
| `YTViewer/Resources/blocklist.json` | スターター。EasyList 全文ではない。約 60 件。広告ドメインは third-party、YouTube の広告パスはファーストパーティとしてブロック。動画 CDN は入れていない |
| `YTViewer/Resources/youtube_adblock.js` | 独自のスキップ用スクリプト。uBlock Origin のコードはコピーしていない。広告表示中だけスキップボタンを押し、短い広告動画だけ終端へ送る |
| `YTViewer/Downloader/DownloaderClient.swift` | URLSession の async/await、0.5 秒ポーリング、書類への保存、`DownloadSessionModel`。ファイル全体が `#if PERSONAL_BUILD` |
| `YTViewer/Downloader/Models.swift` | リクエストと応答の Codable、`ServerSettings`（UserDefaults）。ファイル全体が `#if PERSONAL_BUILD` |
| `YTViewer/Settings/SettingsView.swift` | 両方に説明とバージョン。サーバー URL は Personal だけ |
| `YTViewer/Info.plist` | `INFOPLIST_PREPROCESS`。ローカルネットは両方。任意 HTTP、ローカルネットの使用目的、ファイル App 公開、表示名 Viewer P は Personal だけ |
| `YTViewer/PrivacyInfo.xcprivacy` | トラッキングなし。UserDefaults は CA92.1 |
| `YTViewer/Assets.xcassets` | アプリアイコン、アクセント、起動背景 |
| `tools/convert_easylist.py` | EasyList テキスト → Content Blocker JSON。未対応規則は捨てる。`--self-test` と `--check` |
| `docs/AppStore.md` | ストア用の文面と撮影メモ。Store スキームで撮る |
| `.github/workflows/ios-build.yml` | macos-latest。シミュレータの署名なしビルドと、iphoneos の未署名 IPA（`Payload/` に `.app` を入れて zip）。Store にダウンローダが混ざっていないか見る |
| `README.md` | 利用者向けの日本語説明 |

バンドル ID は Store が `app.ytviewer.ios`、Personal が `app.ytviewer.ios.personal`。並べてインストールできる。

## 分かっているリスクと TODO

- **未コンパイル。** Swift 6 や新しい Xcode が、WebKit の MainActor、`deinit` からの KVO 解除、OSLog の補間で警告をエラーにすることがある。`SWIFT_VERSION` は 5.0 で、厳密な並行性は付けていない。CI が赤なら、そこから直す。
- **`EXCLUDED_SOURCE_FILE_NAMES` の一致規則は Xcode の版で解釈が揺れる。** ファイル名とプロジェクト相対パスの両方を書いてある。本当の保証は `#if PERSONAL_BUILD` と、CI の `nm` / `strings`。どちらかを外さない。
- **Info.plist のプリプロセス。** Personal の `INFOPLIST_PREPROCESSOR_DEFINITIONS` が効かないと、LAN 以外の HTTP サーバーに繋がらない。実機で ATS エラーが出たら、ビルド済み plist を見る。
- **Content Blocker は 1 件でも不正だとリスト全体が失敗する。** スターターは単純な正規表現だけ。変換ツールが出す `(?:...)` や `\w` は WebKit が拒む可能性がある。拒んでもアプリは落ちないが、フィルタは無効になる。コンソールの `WKContentRuleList failed` を見る。
- **広告スクリプトのセレクタはページ側のクラス名に依存する。** クラスが変わるとスキップが止まる。`.ad-showing` の付いた短い動画だけ終端へ送る。本編まで飛ばすようなら、そのシークを止める。
- **共有シートは SwiftUI の sheet から `UIActivityViewController` を出している。** iPhone では動く想定。空のシートや iPad のポップオーバーで落ちたら、提示方法を直す。
- **Swift 側の自動テストは無い。** クライアントの JSON と、届かないときのトーストは、シミュレータでサーバーを止めた状態で見る。
- **プライバシーマニフェストの UserDefaults は両ビルド共通。** 実際に読むのは Personal のサーバー URL だけ。Store に不要なら、審査で指摘されたときだけ分ける。
- **`LastUpgradeCheck` は 1500。** 新しい Xcode がプロジェクトの更新を勧める。objectVersion を上げるときは、構成名 Store / Personal が Debug / Release に潰れないことを確認する。
- **実機の署名チームは空。** シミュレータは `CODE_SIGNING_ALLOWED=NO` で足りる。iphoneos の CI はそれに加え Manual と空チームを渡して未署名 IPA を作る。Xcode から実機へ Run するときと Archive には、開発者の Team が要る。
- **CI の IPA は未署名。** `Payload/YTViewer.app` を zip しただけなので、そのままでは iPhone に入らない。Sideloadly が Apple ID で署名し直す。無料 Apple ID は約 7 日。シミュレータ用 `.app` は iPhone に入らない。Store の IPA にダウンロード機能は無い。

## 次にやること

1. GitHub に push し、Actions の「iOS build」を緑にする。赤ならログの Swift エラーだけ直す。仕様は変えない。
2. 緑のあと、Mac のシミュレータで Store を起動する。URL を開いてインラインで再生できること、歯車の設定にサーバー URL が無いこと。
3. Personal を起動し、サーバーを止めたままダウンロードを押す。トーストが「ダウンロードサーバー未接続（準備中）」になり、アプリが落ちないこと。
4. Mac が無い Windows からは、Actions の `YTViewer-Personal-unsigned.ipa`（広告ブロックだけなら Store の IPA）を Sideloadly で入れる。Sideloadly が署名し直す。無料 Apple ID は約 7 日で署名が切れる。Mac から直接入れる手順も README にある。
5. ダウンロードサーバーは **別リポジトリ** で、上の API 契約どおりに作る。このリポジトリには足さない。
6. ブロックリストを EasyList 全文に差し替えるなら、README の変換手順と `--limit` を使う。差し替え前にスターターをコピーする。
7. App Store に出すのは Store の Archive だけ。文面は `docs/AppStore.md`。
