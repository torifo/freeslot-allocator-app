# Flutter Web / Chrome トラブルシューティング

このドキュメントは、`flutter run -d chrome` 実行時に発生した Chrome 接続エラーの記録と、原因の切り分け手順をまとめたものです。

## 対象の症状

今回確認できた主なエラーは次の3種類です。

### 1. Chrome 接続拒否

```text
SocketException: Connection refused
Failed to connect to Chrome instance.
```

Flutter ツールが、起動した Chrome のデバッグ用ポートへ接続できていません。

### 2. WebSocket 接続失敗

```text
WebSocketException: ... was not upgraded to websocket, HTTP status code: 500
Failed to establish connection with the application instance in Chrome.
```

Chrome までは到達しているが、DevTools / WebSocket の確立で失敗しています。

### 3. Web 開発サーバーのポート競合

```text
SocketException: Failed to create server socket
Address already in use
```

指定した `--web-port` を別プロセスが使用中です。

## 今回の切り分け結果

- `flutter run -d macos` は起動できた
- `flutter run -d chrome` は複数回失敗した
- `flutter run -d web-server --web-hostname=127.0.0.1 --web-port=8080` は起動できた

このため、アプリ本体や Flutter プロジェクトの破損よりも、**Flutter ツールと Chrome のデバッグ接続経路**に問題がある可能性が高いです。

## 原因候補

優先度の高い順に並べると次です。

1. Chrome のリモートデバッグ接続が macOS 側または Chrome 側で拒否されている
2. 既存の Chrome / Dart プロセスが残り、ポートやデバッグ状態が競合している
3. `localhost` の通信経路で WebSocket が失敗している
4. 拡張機能、VPN、プロキシ、セキュリティソフトが loopback 通信を妨げている
5. 固定した `--web-port` を別プロセスが使用している

## まず確認すること

### 1. 基本検証

```bash
dart format lib test
flutter analyze
flutter test
```

ここが通るなら、コード修正より先に実行環境を疑います。

### 2. macOS 版で動くか確認

```bash
flutter run -d macos
```

macOS 版が動く場合、ロジックや依存関係よりも web 実行系の問題である可能性が高いです。

## 推奨の切り分け手順

### Step 1. Chrome と Dart の残留プロセスを止める

```bash
pkill -f "Google Chrome"
pkill -f dart
```

必要なら使用中ポートも確認します。

```bash
lsof -i :8080
```

### Step 2. プロジェクトを掃除する

```bash
flutter clean
flutter pub get
```

これは依存や build cache の整理です。今回のログでは単独では解決しませんでしたが、切り分けの初手としては必要です。

### Step 3. まずは web-server で確認する

```bash
flutter run -d web-server --web-hostname=127.0.0.1 --web-port=8080
```

起動後に、Chrome で `http://127.0.0.1:8080` を手動で開きます。

これで画面が出る場合:

- Flutter の web ビルド自体は動く
- 問題は「Flutter が Chrome を直接デバッグ接続する処理」に寄っている

### Step 4. Chrome 実行時にホストとポートを明示する

```bash
flutter run -d chrome --web-hostname=127.0.0.1 --web-port=45678
```

`8080` は競合しやすいため、未使用の大きなポートを使う方が安全です。

### Step 5. 一時プロファイルで Chrome を起動する

```bash
flutter run -d chrome \
  --web-browser-flag="--user-data-dir=/tmp/flutter_chrome_dev" \
  --web-browser-flag="--disable-extensions"
```

既存の Chrome プロファイルや拡張機能の影響を切り離します。

## macOS 側の確認項目

### ローカルネットワーク権限

`システム設定 > プライバシーとセキュリティ > ローカルネットワーク`

ここで `Google Chrome`、`Terminal`、IDE などがある場合は ON を確認します。

### 権限リセット

```bash
tccutil reset All com.google.Chrome
tccutil reset All com.apple.Terminal
```

初回許可ポップアップを取り逃した可能性がある場合の再確認用です。

### ファイアウォール

`システム設定 > ネットワーク > ファイアウォール`

今回のケースでは OFF にしても解決しなかったため、**主因とは断定しにくい**です。ただし、補助要因の可能性は残ります。

## 既に分かっていること

### `flutter clean` だけでは解決しない

ログ上、`flutter clean` と `flutter pub get` 実行後も `Connection refused` が継続しました。

### `--web-hostname=127.0.0.1` だけでも解決しない

`localhost` 名解決だけが原因なら改善するはずですが、失敗が継続しました。

### `web-server` は起動できる

これは重要です。少なくとも:

- Flutter の web build
- 開発用サーバー起動
- Dart VM Service

までは正常です。

## 暫定回避策

Chrome デバッグ接続が不安定な間は、次のどちらかで進めます。

### 1. macOS アプリとして進める

```bash
flutter run -d macos
```

日常開発はこれで進め、web 固有確認は後でまとめて行います。

### 2. web-server で画面確認だけ行う

```bash
flutter run -d web-server --web-hostname=127.0.0.1 --web-port=8080
```

Chrome を手で開いて確認します。Flutter が Chrome を直接制御しないため、今回の不具合を回避しやすいです。

## 次に試す候補

優先順は次です。

1. `pkill` で Chrome / Dart を止める
2. `flutter run -d web-server` で画面確認
3. `--user-data-dir` と `--disable-extensions` 付きで Chrome 実行
4. ローカルネットワーク権限を確認
5. `flutter run -d chrome --verbose` で接続先ポートと Chrome 起動コマンドを確認

## 補足

今回のログからは、**コード不具合ではなく実行環境の Chrome デバッグ接続問題**として扱うのが妥当です。今後も同系統のエラーが出たら、まず `docs/feature_checklist.md` の機能確認ではなく、このドキュメントの接続切り分けを優先してください。
