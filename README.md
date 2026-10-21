# Viewer（YTViewer）

iPhone 向けのアプリ内ブラウザです。動画サイトを WKWebView で開き、コンテンツブロッカーとユーザースクリプトの二段で広告枠を抑えます。再生はページの中で続きます。

**Storeビルドは広告ブロック機能のみ、Personalビルドは将来実装される外部ダウンロードサーバーに接続する機能を含む**

ダウンロードの本体（抽出や結合）はこのリポジトリにありません。Personal ビルドが持つのは HTTP クライアントと画面の配線だけで、サーバーは別リポジトリで後から実装します。

## 必要環境

- Xcode 15 以降
- iOS 16 以降（iPhone）
- SwiftUI

## 構成

```
MainView
  URL 欄 · 開く · ダウンロード（Personal のみ） · 歯車
  進捗（Personal のみ）
  ┌─────────────────────────────────────────────┐
  │ BrowserView（WKWebView）                     │
  │   allowsInlineMediaPlayback                  │
  │   ユーザー操作なしでメディア再生可能          │
  │   ├ ContentRuleManager                       │
  │   │    Resources/blocklist.json              │
  │   │    WKContentRuleList にコンパイル         │
  │   └ UserScriptManager                        │
  │        Resources/youtube_adblock.js          │
  │        documentEnd / メインフレームとサブフレーム │
  └─────────────────────────────────────────────┘
                 │  PERSONAL_BUILD のみ
                 ▼
        DownloaderClient ──HTTP──► 外部サーバー（別リポジトリ、未実装）
          POST /api/download
          GET  /api/tasks/{task_id}  を 0.5 秒間隔
          file_url を書類フォルダへ保存し、共有シートを出す
```

ルールのコンパイルに失敗しても、ブラウザ自体は開きます。フィルタだけが無効になります。

## ビルド構成

| | Store | Personal |
| --- | --- | --- |
| スキーム | Store | Personal |
| 画面上の名前 | Viewer | Viewer P |
| バンドル ID | `app.ytviewer.ios` | `app.ytviewer.ios.personal` |
| 広告ブロック | あり | あり |
| ダウンロード | なし | 外部サーバーへ接続 |
| コンパイル条件 | なし | `PERSONAL_BUILD` |
| ATS | ローカル HTTP のみ許可 | ローカル HTTP に加え、任意の HTTP も許可 |

二つのバンドル ID は別アプリとして並ぶので、配信版とサイドロード版を同時に入れられます。

Store では次の両方でダウンロードコードを外しています。

- `DownloaderClient.swift` と `Models.swift` の全体を `#if PERSONAL_BUILD` で囲む
- Store 構成の `EXCLUDED_SOURCE_FILE_NAMES` で、その 2 ファイルをコンパイル対象から外す

設定画面のサーバー URL、ダウンロードボタン、進捗、未接続時のトーストも同じ条件の中にあります。Store のバイナリに、隠したダウンロード機能は残りません。

Xcode で `YTViewer.xcodeproj` を開き、スキームを選びます。実機へ入れるときは Signing & Capabilities で Team を選びます。シミュレータ向け SDK では署名を要求しない設定にしてあります。

```bash
xcodebuild -project YTViewer.xcodeproj -scheme Store -configuration Store -destination 'generic/platform=iOS Simulator' build
xcodebuild -project YTViewer.xcodeproj -scheme Personal -configuration Personal -destination 'generic/platform=iOS Simulator' build
```

App Store へ出すアーカイブは、必ず **Store** スキームです。説明文とスクリーンショットの案は [docs/AppStore.md](docs/AppStore.md) にあります。

## サイドロード

無料の Apple ID で署名したアプリは、おおよそ 7 日で起動できなくなります。期限が来る前に、同じ手順でもう一度署名して入れ直します。有料の Apple Developer Program だと、この期限はおおよそ 1 年です。無料 Apple ID では、同時に有効にできる App ID の数が少ないので、他のサイドロードと衝突したら一度消してから入れ直します。

入れた直後に起動できないときは、iPhone の「設定 → 一般 → VPN とデバイス管理」で自分の開発者を信頼します。

### Xcode から直接入れる

1. Xcode の Settings → Accounts に Apple ID を追加する
2. スキーム **Personal**（広告ブロックだけ試すなら **Store**）を選ぶ
3. ターゲット YTViewer の Signing & Capabilities で Team を選ぶ
4. iPhone を接続して信頼し、Run する

### AltStore

1. Mac または Windows に AltServer を入れ、同じ Apple ID で iPhone に AltStore を入れる
2. Xcode で Personal を Archive し、Organizer から Development 向けの IPA を書き出す
3. AltStore でその IPA をインストールする
4. 同じネットワークで AltServer が動いていれば、AltStore が期限前に署名を更新できる。Mac を閉じたまま 7 日を超えると起動できなくなるので、そのときは IPA を入れ直す

### Sideloadly

1. Mac または Windows に Sideloadly を入れる
2. 上と同じ手順で書き出した IPA をドラッグする
3. Apple ID を入力してインストールする
4. 無料 Apple ID では、起動できなくなったら Sideloadly で同じ IPA を署名し直して入れ直す

## ブロックリストを更新する

同梱の `YTViewer/Resources/blocklist.json` は、主要な広告配信ドメインと動画ページ向けの要素非表示を入れたスターターです。EasyList そのものではありません。差し替える前にコピーを残します。

```bash
cp YTViewer/Resources/blocklist.json /tmp/blocklist.starter.json
curl -L -o /tmp/easylist.txt https://easylist.to/easylist/easylist.txt
python3 tools/convert_easylist.py /tmp/easylist.txt -o YTViewer/Resources/blocklist.json
python3 tools/convert_easylist.py --check YTViewer/Resources/blocklist.json
```

規則が多すぎる、または汎用の要素非表示が重いときは、ドメイン付きの非表示だけ残して上限を下げます。

```bash
python3 tools/convert_easylist.py /tmp/easylist.txt \
  --no-generic-cosmetic --limit 50000 \
  -o YTViewer/Resources/blocklist.json
```

`tools/convert_easylist.py` は EasyList のテキストを WebKit の Content Blocker JSON に変換します。コメント、`||domain^`、`@@` 例外、`$script` などのリソース種別、`third-party`、`domain=`、`##selector` を扱います。`$csp` や手続き的な化粧フィルタは捨て、件数を標準エラーに出します。変換ツール自身の確認は次です。

```bash
python3 tools/convert_easylist.py --self-test
```

WebKit は、リストの 1 件でも不正だとコンパイル全体を失敗させます。その場合でもアプリは落ちず、フィルタなしでページを開きます。失敗したときは Xcode のコンソールに `WKContentRuleList failed` が出ます。

## ダウンロード（Personal のみ）

サーバーの実装はこのリポジトリに含まれません。別リポジトリで後から作ります。アプリが話す契約は次のとおりです。`percent` は 0 から 100 です。

```http
POST {base}/api/download
Content-Type: application/json

{"url":"...","quality":"best","format":"mp4"}

→ {"task_id":"..."}
```

```http
GET {base}/api/tasks/{task_id}

→ {"status":"downloading|merging|done|error","percent":0.0,"speed":"...","eta":"...","message":"...","file_url":"..."}
```

ベース URL の既定値は `http://192.168.1.10:8000` です。歯車の設定で変えられます。末尾のスラッシュは送る前に外します。`file_url` が相対パスなら、このベース URL を基準に解決します。

ダウンロードを押すと POST し、0.5 秒間隔で状態を取り、進捗（状態、パーセント、速度、残り時間、メッセージ）を出します。`done` になったら `file_url` をアプリの書類フォルダ `Downloads` に保存します。ファイル App の「Viewer P」から開けます。続けて共有シートも出します。

サーバーに届かない、または契約と違う応答のときは、トーストで **ダウンロードサーバー未接続（準備中）** と表示します。アプリは終了しません。ベース URL の形が違うときだけ、「サーバーURLが正しくありません」と出します。

Personal はローカルネットワークへの接続説明を Info.plist に持ちます。iPhone が許可を求めたら許可しないと、LAN 上のサーバーには届きません。Store は任意の HTTP を開かず、HTTPS のページ閲覧用です。

## ディレクトリ

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
YTViewer/Info.plist
YTViewer/PrivacyInfo.xcprivacy
YTViewer/Assets.xcassets
tools/convert_easylist.py
docs/AppStore.md
README.md
```

`Info.plist` はプリプロセスします。`NSAllowsLocalNetworking` は両方の構成にあります。`NSAllowsArbitraryLoads`、ローカルネットワークの使用目的、ファイル App への公開は Personal だけです。
