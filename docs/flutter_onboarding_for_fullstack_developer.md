# Flutter未経験のフルスタック開発者向け開発ガイド

このドキュメントは [flutter_development_flow.md](/Users/akito-shoji/dev/app/frelocator/docs/flutter_development_flow.md) を実行に移すための補助ガイドである。

対象は次のような開発者を想定する。

- Webやバックエンドの開発経験はある
- Flutterは未経験、または触ったことがほぼない
- このアプリのMVPを自走できるところまで早く持っていきたい

結論から言うと、Flutter未経験でもこのアプリは進められる。ただし、最初にFlutter固有の概念を全部学ぼうとすると止まるので、学ぶ範囲を絞るべきである。

最初に必要なのは次の5つだけで十分である。

- `Widget`
- `StatefulWidget` / `ConsumerWidget`
- `BuildContext`
- 画面遷移
- 非同期データの扱い

それ以外は、作りながら必要になったタイミングで足せばよい。

## 1. まず理解すること

Flutterは、Webフロントエンド経験者にとっては次の対応で理解すると速い。

| Web/Backendでの感覚 | Flutterでの対応 |
| --- | --- |
| React Component | `Widget` |
| props | コンストラクタ引数 |
| state | `State`, Riverpod provider |
| route | `go_router` |
| service/usecase | application layer |
| repository | data layer |
| ORM model/entity | domain/data model |

重要なのは、Flutterを「モバイル専用の特殊技術」として見るより、`UIをWidgetで組むフロントエンド` として捉えることである。

## 2. 最初に学ぶ範囲を制限する

最初の段階では、次のものは後回しでよい。

- アニメーション最適化
- プラットフォーム固有実装
- 高度な描画
- 状態管理ライブラリの比較検討
- Clean Architectureの過剰な抽象化

このアプリで最初に必要なのは、次の実務だけである。

1. 画面を出す
2. フォームを作る
3. ローカルDBに保存する
4. 一覧に出す
5. 集計する

## 3. このアプリで使う技術を先に固定する

未経験者が迷わないように、最初の技術選定は固定した方がよい。

- `Flutter`
- `flutter_riverpod`
- `go_router`
- `drift`
- `sqlite3_flutter_libs`
- `path_provider`
- `intl`
- `fl_chart`

理由は単純で、このアプリに必要なものがほぼ揃っているからである。

- Riverpod: 画面状態と非同期ロードを整理しやすい
- go_router: 画面遷移を単純に保てる
- drift: CRUDと集計をやりやすい
- fl_chart: 週次レポートの可視化に使える

## 4. 開発開始時の手順

まだFlutterプロジェクト自体がないので、最初はここから始める。

```bash
flutter create frelocator
cd frelocator
flutter pub add flutter_riverpod go_router drift sqlite3_flutter_libs path_provider intl fl_chart
flutter pub add dev:drift_dev dev:build_runner
```

その後、最低限次を確認する。

```bash
flutter doctor
flutter run
```

ここで詰まる場合は、アプリ実装ではなく環境構築が原因であることが多い。未経験者はコードより先に `flutter doctor` を正常化すること。

## 5. 最初のディレクトリ構成

最初から巨大な構成にしない方がよいが、責務の分離は最初に入れておくべきである。

```text
lib/
  app/
    app.dart
    router.dart
    theme.dart
  core/
    utils/
  features/
    daily_plan/
      presentation/
      application/
      domain/
      data/
    task_master/
      presentation/
      application/
      domain/
      data/
    weekly_report/
      presentation/
      application/
      domain/
      data/
  shared/
    widgets/
```

未経験者がやりがちな失敗は、`screens`, `models`, `services` に全部入れて肥大化させることである。このアプリは日付・時間・集計が複雑なので、最初から feature 単位で切った方が後で楽になる。

## 6. 最初に作る画面

実装順は既存ドキュメントと同じだが、未経験者向けにはさらに細かく区切る。

### Step 1: 画面遷移だけ作る

先にDBをつながず、空画面でよいので次を作る。

- ホーム
- 1日詳細
- 自由時間枠編集
- タスク一覧
- タスク編集
- 週間レポート

この段階のゴールは「全部の画面に遷移できること」である。

### Step 2: モックデータで見た目を組む

次に、固定データで以下を出せるようにする。

- 日付一覧
- 自由時間枠一覧
- タスク割り当て行
- 週次集計カード

ここでは保存処理を作らない。まずUI上の情報量と操作感を確定させる。

### Step 3: TaskMaster CRUDを通す

最初の本実装はタスクマスター管理にする。

理由は次のとおり。

- 画面が単純
- DB接続の最初の練習になる
- 後続機能が全部これに依存する

### Step 4: DailyPlan と FreeTimeSlot を通す

次に日別計画と自由時間枠を実装する。

この時点で必要なのは次だけでよい。

- 1日を作る
- 自由時間枠を追加する
- 一覧表示する
- 編集する
- 削除する

### Step 5: SlotTaskAssignment を実装する

ここからこのアプリの本体に入る。

やることは次の順に限定する。

1. 枠の中にタスクを1件入れる
2. 2件以上入れる
3. 重複チェックを入れる
4. 枠超過チェックを入れる
5. 日またぎケースを確認する

### Step 6: 週間レポートを実装する

最後に集計を作る。円グラフは最後でよく、先に数値一覧が出れば十分である。

## 7. 未経験者が先に作るべきでないもの

次のものはMVP着手時点では作らない方がよい。

- 認証
- クラウド同期
- 通知
- Googleカレンダー連携
- リアルタイム連携
- AI提案
- 高度なデザイン調整

理由は、どれもFlutterの学習コストではなく、要件と実装範囲を無駄に増やすからである。

## 8. まず書くべきコードの単位

Flutter未経験者は「画面から書く」か「DBから書く」かで迷いやすいが、このアプリでは次の単位で進めると詰まりにくい。

1. `domain`: どんなデータを扱うか
2. `data`: どう保存するか
3. `application`: 何をさせるか
4. `presentation`: どう見せるか

例えば `task_master` なら、最初の作業は次になる。

1. TaskMasterの定義を決める
2. driftのtableを作る
3. repositoryを作る
4. 一覧取得providerを作る
5. 一覧画面を作る
6. 新規作成フォームを作る

この順だと、どこで壊れているか切り分けやすい。

TaskMasterの定義では、カテゴリを固定enumで閉じない方がよい。今回の前提では、初期カテゴリは持てるが、ユーザーが追加・編集・削除でき、ローカル保存される必要がある。また、`やるべきこと` と `やりたいこと` のカテゴリ体系は共有ON/OFFを切り替えられるようにし、共有化時に内容が一致しない場合は統合方針を選べる前提で設計する。

## 9. Flutter未経験者が詰まりやすいポイント

### `setState` と状態管理が混ざる

画面ローカルな入力中状態だけ `setState` を使い、永続データや画面横断データは Riverpod に寄せる。

### `DateTime` の扱いが雑になる

このアプリでは `DateTime` の扱いが中核なので、表示用文字列と保存値を分ける。保存は `DateTime`、表示は `intl` で整形する。

### UIで防げるものを保存時にしか見ない

重複、枠超過、開始終了逆転は、入力時と保存時の両方で検証する。

### DBスキーマを後から変えすぎる

週次集計と複製機能を考えると、`TaskMaster`, `DailyPlan`, `FreeTimeSlot`, `SlotTaskAssignment` の4層は最初に固定した方がよい。

同様に、カテゴリ設定テーブルや共有設定の持ち方も早めに決めた方がよい。ここを後から変えると、TaskMaster入力UI、週次集計、設定画面の全部に波及する。

## 10. 最初の1週間でやること

### Day 1

- Flutter環境構築
- `flutter create`
- `flutter doctor` 正常化
- エミュレータまたは実機で起動

### Day 2

- ルーティング追加
- 空画面で6画面を作る
- テーマと共通レイアウトを置く

### Day 3

- TaskMaster の domain/data/presentation を作る
- CRUDの最初の1本を通す

### Day 4

- DailyPlan
- FreeTimeSlot
- 日別詳細画面

### Day 5

- SlotTaskAssignment
- 重複チェック
- 枠超過チェック

### Day 6

- 複製機能
- 日またぎケース検証

### Day 7

- 週次集計
- 手動テスト
- テスト追加

## 11. 学習と実装の比率

Flutter未経験者は、学習に寄りすぎると進まない。このアプリでは次の比率で十分である。

- 20%: 公式ドキュメント確認
- 80%: 小さく実装して動かす

調べるときも、「Flutterの全体像」ではなく「TextFieldで日時入力する方法」「Riverpodで一覧を読む方法」のように、作業単位で調べるべきである。

## 12. このリポジトリで次にやるべきこと

このドキュメントを前提にすると、実際の次アクションは次の順になる。

1. Flutterプロジェクトを作成する
2. `lib/` の基本構成を切る
3. `go_router` で画面遷移だけ通す
4. `task_master` から最初のCRUDを作る
5. その後に `daily_plan` と `free_time_slot` に進む

一番重要なのは、最初から完成形を作ろうとしないことである。このアプリは、`TaskMaster CRUD -> DailyPlan/Slot CRUD -> Assignment -> Report` の順に積み上げれば十分進められる。
