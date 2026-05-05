# Sync Extension Plan

`AppDataService` を起点として、端末引き継ぎ・クロスプラットフォーム同期を段階的に追加するための設計メモです。

## 統合ポイント

`lib/services/app_data_service.dart` の2メソッドが唯一の入口です。

| メソッド | 役割 |
|---|---|
| `exportAll()` | 全データを `Map<String, dynamic>` に束ねる |
| `importAll(data)` | 受け取った Map を両 Repository に書き込む |

## 将来の同期フロー

### 初回セットアップ（新規端末）

1. サーバー側で UUID を発行（= ルームID）
2. ユーザーがパスフレーズを設定（クライアント側の暗号化キーになる）
3. サーバーはパスフレーズを一切保存しない

### アップロード（バックアップ）

```
exportAll() → Map
  → AES-256-GCM 暗号化（パスフレーズで鍵導出）
  → POST /rooms/{uuid}  にそのまま投げる
```

### ダウンロード（引き継ぎ・復元）

```
ルームID + パスフレーズを入力
  → GET /rooms/{uuid}
  → AES-256-GCM 復号
  → importAll(decryptedMap)
```

## VPS API（最小構成）

```
POST /rooms/:uuid   — 暗号化 blob を作成または上書き
GET  /rooms/:uuid   — 暗号化 blob を取得
```

認証なし。UUID が識別子、暗号化がセキュリティを担保する。
UUID を知らない第三者はアクセスできない（推測困難なため）。

## 競合ポリシー

**Last-write-wins**。同期は手動なのでユーザーが順序をコントロールする。
自動マージは行わない。

## 実装時に追加するパッケージ

```yaml
dependencies:
  encrypt: ^5.x      # AES-256-GCM
  http: ^1.x         # HTTP クライアント
  uuid: ^4.x         # UUID 生成
```

## 実装ステップ（将来）

1. VPS に `/rooms` エンドポイントを追加（Node.js / Go など）
2. Flutter 側に `SyncService` を追加（`AppDataService` をラップ）
3. 設定画面に「バックアップ」「復元」ボタンを追加
4. 初回のみルームID生成ウィザードを表示

## 注意事項

- パスフレーズを忘れると復号不可（サーバーに平文なし）
- 同期中は UI をブロックせず、SnackBar でフィードバック
- `version` フィールドでスキーマ差異を検知し、必要なら migration を挟む
