# Android Store Assets Checklist

Android の Play Console 提出用素材を、macOS から揃えるためのチェックリストです。

## Store URLs

- Privacy policy
  - `https://app.frelocator.riumu.net/privacy.html`
- Support
  - `https://app.frelocator.riumu.net/support.html`

## Required / Recommended Assets

### Required or near-required

- Phone screenshots
  - 4 枚以上を推奨
- Feature graphic
  - `1024 x 500`
- App icon
  - 既存の正式版を使用
- Privacy policy URL
- Support URL

### データセーフティ / 権限

- データセーフティの質問票: 「収集なし」を維持する。デバイス間の転送のみで、いずれの第三者サーバーにも送信しない。転送は暗号化（TLS）する。
- 権限の理由文
  - `INTERNET`: 同じ Wi-Fi 上の自分の PC（`tools/hub`）と LAN 同期するために使用する。外部サーバーとの通信には使わない。
  - `CAMERA`: PC とのペアリング用 QR コードと、PC から送られるデータ QR コードを読み取るためだけに使用する。画像は保存・送信しない。

### Optional

- Preview video
  - 任意
- Tablet screenshots
  - 大画面対応を見せるなら推奨

## Suggested Screenshot Set

### Phone

1. Home
   ダッシュボード全体が見える状態
2. TaskMaster
   `やるべきこと / やりたいこと` が見える状態
3. DailyPlan
   タイムラインが見える状態
4. DailyPlan
   自由時間枠と予定が入った状態
5. WeeklyReport
   週次集計が見える状態

### Tablet

1. TaskMaster
   セクション表示と並び替えが見える状態
2. DailyPlan
   タイムライン全体が広く見える状態

## Capture Principles

- 空画面は避ける
- ダミーデータは自然で見栄えの良いものにする
- 1 枚につき 1 メッセージに絞る
- 文字が読める状態にする
- デバッグ用表示や OS 通知は消す
- 端末フレーム付き画像にしない

## Feature Graphic

### Requirement

- Size: `1024 x 500`
- Format: `PNG` or `JPEG`

### Suggested Direction

- Title: `FRELOCATOR`
- Copy candidates:
  - `Plan free time with clarity`
  - `Turn free time into real plans`
  - `Organize tasks, time, and weekly reviews`
- Visual direction:
  - warm parchment / clay tone
  - UI を小さく詰め込みすぎない
  - ロゴとタイトルを主役にする

## macOS Workflow

### Build and launch

```bash
flutter run -d <android_device_id>
```

### Check connected devices

```bash
flutter devices
```

### Emulator screenshot

Android Emulator のツールバーから撮影してもよいし、`adb` でも可能です。

```bash
adb devices
adb exec-out screencap -p > phone-home.png
```

### Optional screen recording

動画が必要なら macOS の画面収録か、Android Emulator の recording 機能を使う。

## Suggested Preparation Order

1. Phone 用の見せる状態を作る
2. Phone screenshots を撮る
3. Tablet screenshots を撮る
4. Feature graphic を作る
5. Play Console にアップロードする

## Final Pre-Upload Check

- 画像サイズが要件内
- 文字が潰れていない
- Home / TaskMaster / DailyPlan / WeeklyReport が揃っている
- Privacy / Support URL が入力済み
- スクリーンショットの並びがストア上で意味の通る順番になっている

