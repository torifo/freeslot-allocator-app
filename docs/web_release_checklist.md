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

## Remaining non-web blockers

- Android `applicationId` is still `com.example.frelocator`
- Android release signing is still debug signing
- macOS bundle identifier is still `com.example.frelocator`
