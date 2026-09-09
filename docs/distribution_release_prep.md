# Distribution Release Prep

2026-05-01 時点の配布準備メモです。  
対象は `Web / Android / macOS` です。

## Current Status

- Web
  - `flutter build web` 成功
  - 公開ドメイン前提: `app.frelocator.riumu.net`
  - `privacy.html` / `support.html` あり
- Android
  - `flutter build appbundle` 成功
  - 出力: `build/app/outputs/bundle/release/app-release.aab`
  - package ID: `net.riumu.frelocator`
  - release signing 設定済み
- macOS
  - `flutter build macos` 成功
  - 出力: `build/macos/Build/Products/Release/FRELOCATOR.app`
  - bundle ID: `net.riumu.frelocator`
  - アプリ名: `FRELOCATOR`

## Web

### Current Publish Target

一旦の実ホスティング先:

```text
ssh root@X-VPS
root@x162-43-88-107:/home/ubuntu/app/frelocator#
```

必要に応じて、今後 CDN / 別ホスティング / リバースプロキシ構成は再検討する。

### Web Release Steps

1. ローカルでビルド

```bash
flutter build web
```

2. 生成物を配置

配置元:

```text
build/web
```

配置先:

```text
/home/ubuntu/app/frelocator
```

3. Web サーバー設定で確認すること

- `index.html` を配信できること
- SPA fallback が必要なら 404 時に `index.html` を返すこと
- `privacy.html` と `support.html` が直接開けること
- HTTPS 設定
- `app.frelocator.riumu.net` の DNS が到達していること

### Web Release Checklist

- `https://app.frelocator.riumu.net/`
- `https://app.frelocator.riumu.net/privacy.html`
- `https://app.frelocator.riumu.net/support.html`
- manifest / favicon / title 確認
- モバイル幅での表示確認

## Android

### Current Status

- release keystore 作成済み
- `android/key.properties` により release signing 設定済み
- 提出用 `.aab` 生成確認済み

### Android Release Artifact

```text
build/app/outputs/bundle/release/app-release.aab
```

### Android Remaining Work

- Play Console の本人確認完了待ち
- アプリ説明文
- スクリーンショット
- カテゴリ / 年齢区分 / 連絡先
- プライバシーポリシー URL
- サポート URL
- 内部テストまたはクローズドテスト

### Android Submission Notes

- 提出は `apk` ではなく `aab`
- keystore とパスワードは紛失しないこと
- 今後の更新も同じ signing key を使う

## macOS

### Current Status

- release build 成功
- `.app` 生成確認済み
- App Store 外配布を想定するなら notarization を検討中

### macOS Release Artifact

```text
build/macos/Build/Products/Release/FRELOCATOR.app
```

### notarization Overview

App Store 外で配る場合の基本手順:

1. `Developer ID Application` 証明書で署名
2. `.app` を zip などでまとめる
3. `notarytool` で Apple に提出
4. 通過後に `stapler` を実行
5. 最終配布物を検証

### Useful Commands

証明書確認:

```bash
security find-identity -v -p codesigning
```

署名確認:

```bash
codesign --verify --deep --strict --verbose=2 build/macos/Build/Products/Release/FRELOCATOR.app
```

zip 化:

```bash
ditto -c -k --keepParent build/macos/Build/Products/Release/FRELOCATOR.app FRELOCATOR.zip
```

notarytool 提出:

```bash
xcrun notarytool submit FRELOCATOR.zip --apple-id "<APPLE_ID>" --team-id "<TEAM_ID>" --password "<APP_SPECIFIC_PASSWORD>" --wait
```

staple:

```bash
xcrun stapler staple build/macos/Build/Products/Release/FRELOCATOR.app
```

Gatekeeper 確認:

```bash
spctl -a -vv build/macos/Build/Products/Release/FRELOCATOR.app
```

### macOS Remaining Work

- Apple Developer 側の本番 Team / 証明書確認
- Developer ID 署名
- notarization 実行
- zip か dmg の最終配布形式決定

## Release Notes

### 1.0.0+6（競合の記録と解決 / Plan 3b）

Play Console 用の本文（`release/release-notes-6.txt`、ストア提出時に作成）:

```text
PC と同期したときに、同じ項目を PC とスマホの両方で編集していた場合は「競合」として
記録し、あとからどちらを採用するか選べるようになりました。同期そのものは今までどおり
完了します。「設定 › PC と同期 › 競合」から一覧を開けます。
```

- **データセーフティの回答は変更なし**（「データを収集しません」のまま）。競合レコードは
  端末とオーナーの PC の間だけを往復し、第三者サーバーには出ない。
- **権限の追加なし。** 新しい API も新しいネットワーク先も増えていない。
- **スキーマ版は 2 のまま。** 競合レコードはドキュメント直下の任意フィールド
  `conflicts[]` で、持たない v2 文書（Plan 2b ビルドの書き出し）とも往復できる。
  古いアプリは受け取った `conflicts` を落とすが、ハブは常に和集合を取るので PC 側の
  記録は消えない（この非対称は README と `tools/hub/README.md` に明記）。
- MCP ツールは 39 → 43（`list_conflicts` / `get_conflict` / `resolve_conflict` /
  `resolve_all_conflicts`）。

## Cross-Platform Notes

- アプリ名: `FRELOCATOR`
- Android package ID: `net.riumu.frelocator`
- macOS bundle ID: `net.riumu.frelocator`
- Web domain: `app.frelocator.riumu.net`

## Recommended Next Order

1. Web を VPS に一旦配置して公開確認
2. Android は本人確認完了後に `app-release.aab` を提出
3. macOS は notarization 方針を確定して署名と提出
