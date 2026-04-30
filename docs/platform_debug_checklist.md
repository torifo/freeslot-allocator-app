# Platform Debug Checklist

このドキュメントは `macOS / Web / Android` での起動方法と、各プラットフォームで優先して確認するデバッグ観点をまとめたものです。

共通の進め方は [debug_flow.md](/Users/akito-shoji/dev/app/frelocator/docs/debug_flow.md) を参照し、機能単位の確認項目は [feature_checklist.md](/Users/akito-shoji/dev/app/frelocator/docs/feature_checklist.md) を使います。

## 事前確認

最初に次を実行します。

```bash
flutter analyze
flutter test
```

必要に応じてリリースビルドも確認します。

```bash
flutter build macos
flutter build web
flutter build apk --release
```

## macOS

### 起動方法

```bash
flutter run -d macos
```

リリースビルド確認だけなら:

```bash
flutter build macos
open build/macos/Build/Products/Release/frelocator.app
```

### 優先して見る項目

- ホーム画面の表示崩れがない
- ダイアログの高さ不足やスクロール不能がない
- TaskMaster の追加 / 編集 / 削除が通る
- DailyPlan の slot / assignment の追加・編集・削除が通る
- ドラッグ並び替えがマウス操作で破綻しない
- 週次レポートの週切替が崩れない
- 日本語日付表示が崩れない

### macOS で見つけやすい不具合

- ダイアログが小さくてフォーム下部が見切れる
- 横幅が広いレイアウトでカードが間延びする
- クリック可能に見えるのに無動作の UI が残る

## Web

### 起動方法

開発確認:

```bash
flutter run -d chrome
```

Chrome 接続が不安定な場合:

```bash
flutter run -d web-server --web-hostname=127.0.0.1 --web-port=8080
```

公開用ビルド:

```bash
flutter build web
```

### 優先して見る項目

- 初回表示で真っ白画面にならない
- リロードしても起動できる
- 主要画面で縦スクロールが効く
- 狭い幅でもボタンやフォームが操作できる
- Drag & Drop がブラウザ上で破綻しない
- `privacy.html` / `support.html` が開ける
- 日付表示と日本語ロケールが崩れない

### Web で見つけやすい不具合

- Chrome 起動まわりの接続失敗
- 狭い幅での overflow
- ブラウザごとのドラッグ挙動差
- リロード時の SPA fallback 未設定

### 補足

Chrome 接続トラブルの切り分けは [troubleshooting_flutter_web_chrome.md](/Users/akito-shoji/dev/app/frelocator/docs/troubleshooting_flutter_web_chrome.md) を参照します。

## Android

### 起動方法

#### 実機

USB デバッグを有効化した端末を接続して:

```bash
flutter devices
flutter run -d <device_id>
```

#### エミュレータ

利用可能端末確認:

```bash
flutter emulators
```

エミュレータ起動:

```bash
flutter emulators --launch <emulator_id>
```

起動後:

```bash
flutter devices
flutter run -d <device_id>
```

#### リリースビルド

```bash
flutter build apk --release
flutter build appbundle
```

### 優先して見る項目

- 起動時クラッシュがない
- 小さい画面でも主要ボタンが押せる
- キーボード表示時にフォームが隠れない
- DailyPlan ダイアログが縦に見切れない
- Drag & Drop がタッチ操作で誤爆しにくい
- SnackBar やエラーメッセージが読める
- 再起動後もデータが残る
- 複製機能がタッチ操作でも使える

### Android で見つけやすい不具合

- 縦幅不足による overflow
- タッチドラッグが PC よりシビア
- キーボード表示時のレイアウト崩れ
- 端末回転や復帰後の状態ずれ

### 補足

署名や `aab` 生成の情報は [android_release_signing.md](/Users/akito-shoji/dev/app/frelocator/docs/android_release_signing.md) を参照します。

## 推奨確認順

1. `macOS` で全導線を高速に確認する
2. `Web` でレスポンシブとブラウザ特有挙動を確認する
3. `Android 実機` でタッチ操作と小画面を確認する
4. `Android エミュレータ` で再現性の高い検証をする

## 不具合メモの残し方

不具合を見つけたら最低限これを残します。

- プラットフォーム
- 画面
- 手順
- 期待結果
- 実際の結果
- 再現率

例:

- プラットフォーム: Android 実機
- 画面: DailyPlan
- 手順: assignment を別 slot にドラッグ
- 期待: 先頭に移動
- 実際: drop 位置表示が出ず移動しない
- 再現率: 5/5
