# Web Release Checklist

公開先ドメインは `https://app.frelocator.riumu.net/` を前提にする。

## Build

```bash
flutter build web
```

ルート配信以外で公開する場合だけ `--base-href` を付ける。

```bash
flutter build web --base-href /subpath/
```

## Deploy

- `build/web/` の中身をそのまま静的ホスティングへ配置する
- `index.html` への SPA fallback を有効にする
- HTTPS を有効にする
- `app.frelocator.riumu.net` をホスティング先へ向ける

## Current metadata

- App name: `FRELOCATOR`
- Canonical URL: `https://app.frelocator.riumu.net/`
- Theme color: `#CA6E44`
- Description: `Plan daily schedules, organize tasks, and review each week in one place.`

## ハブ上の Web 版との関係（Plan 3a）

`app.frelocator.riumu.net` の公開 Web 版は **無変更**。ハブ配信版は
`window.__FRELOCATOR_HUB__` が注入されている場合にだけ hub モードに入り、
公開ビルドにはこの global が無いので従来どおりブラウザローカル
（`PrefsStateStore`）で動く。公開デプロイの手順は今までどおりで、
`tools/hub/web-dist/` は git 管理外なのでデプロイ対象にも入らない。

ハブ用のビルドは `cd tools/hub && npm run build:web`（内部で
`flutter build web --release` を回して `web-dist/` へ複製する）。開き方と
制約は `tools/hub/README.md` の「ハブ上の Web 版（Plan 3a）」にまとめてある。
ビルドし直したらハブを再起動すること（ETag は起動時に一度だけ取る）。

## Remaining non-web blockers

- Android release signing passwords must be kept safe with the local keystore
- macOS distribution method still needs to be chosen
  App Store or notarized direct distribution
