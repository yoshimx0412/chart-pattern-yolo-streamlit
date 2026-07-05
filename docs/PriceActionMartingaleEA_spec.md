# PriceActionMartingaleEA 詳細仕様書(MT4 / MQL4)

## 1. 概要

- **EA名**: PriceActionMartingaleEA
- **対象プラットフォーム**: MetaTrader 4(MQL4)
- **ファイル**: `MQL4/Experts/PriceActionMartingaleEA.mq4`(単一ファイル、外部ライブラリ・DLL不使用)
- **コンセプト**: プライスアクション型マーチンゲールEA。一般的なマーチンゲール(逆行pipsや時間経過で機械的にナンピン/倍賭けする方式)と異なり、**「明確な反転サイン」= ダブルボトム(DB)/ダブルトップ(DT)のパターン確定時のみ**エントリーおよびロット増し(マーチン)を行う。
- **シグナル定義**:
  - **買いシグナル**: ダブルボトム確定(2つの安値が許容差以内で並び、間の戻り高値=ネックラインを確定足の終値で上抜け)
  - **売りシグナル**: ダブルトップ確定(上記の対称形。ネックラインを終値で下抜け)
- **マーチン発動条件**: 直前トレードが負けで、かつ**次のDB/DTシグナルが確定した時のみ**、ロットを倍率(`LotMultiplier`)で増やして再エントリーする。**時間経過・逆行pips・含み損では絶対にマーチンしない。**
- **判定タイミング**: 全判定は確定足ベース(新バー確定時に1回のみ評価)。リペイントなし。
- **ポジション**: 同時保有は常に最大1ポジション。両建てなし。
- **背景**: 本リポジトリのYOLO+StreamlitアプリはDB/DTを画像検出するが、本EAは同じパターン概念を価格データ(スイングポイント)から直接アルゴリズム検出する。

---

## 2. 検出アルゴリズム(ダブルボトム/ダブルトップ)

すべて確定足(シフト `>= 1`)のみを使用する。評価は新バー確定時(`Time[0]` の変化検知時)に1回だけ実行する。

### 2.1 スイングポイント抽出(フラクタル方式)

- **スイングロー**: バー `i` が、その前後 `SwingBars` 本と比較して最小の安値を持つ。
  - 条件: `Low[i] < Low[i-k]` かつ `Low[i] < Low[i+k]`(`k = 1..SwingBars` のすべてで成立。同値 `==` は不成立とする)
  - 確定条件: 右側に `SwingBars` 本の確定足が必要なため、スイングローが「確定」するのはバー `i` から `SwingBars` 本後のバーが確定した時点。判定に使う最新スイングはシフト `i >= SwingBars + 1` の範囲から探索する。
- **スイングハイ**: 上記の対称形(`High[i]` が前後 `SwingBars` 本より厳密に高い)。
- **探索範囲**: 直近 `LookbackBars` 本以内。それより古いスイングはパターン構成に使用しない。

### 2.2 ダブルボトム検出(買いシグナル)

直近 `LookbackBars` 本の中から以下を満たす3点 `(L1, H_neck, L2)` を探索する(`L1` が古い方の安値、`L2` が新しい方の安値、`H_neck` は両者の間の最高スイングハイ)。

1. **2つのスイングロー**: `L1`(バー `b1`)と `L2`(バー `b2`)が存在し、`b1 > b2`(L1が古い)。
2. **ボトム間隔**: `MinBarsBetweenBottoms <= (b1 - b2) <= MaxBarsBetweenBottoms`
3. **2点の価格許容差**: `MathAbs(Low[b1] - Low[b2]) <= BottomTolerancePips * PipPoint`
   - `PipPoint` は3/5桁ブローカー補正済みの1pip値(§5.7参照)。
4. **ネックライン**: `b1` と `b2` の間の区間 `(b2 < j < b1)` における最高値バー `bn` を取り、`Neckline = High[bn]`。
5. **パターンの深さ(ノイズ除去)**: `Neckline - MathMax(Low[b1], Low[b2]) >= MinPatternDepthPips * PipPoint`
6. **中間戻りの独立性**: `bn` は `b1` とも `b2` とも異なるバーであること(3点が同一バーに縮退しない)。
7. **ブレイク前の非先行ブレイク**: `b2` より新しい確定足 `j = b2-1 .. 2` のすべてで `Close[j] <= Neckline + BreakBufferPips * PipPoint` が成立(初回ブレイクのみを捕捉し、同一パターンの再検出を防ぐ)。
8. **ネックラインブレイク(シグナル確定)**: 直近確定足(シフト1)で
   `Close[1] > Neckline + BreakBufferPips * PipPoint`
9. **第2ボトムの鮮度**: `b2 <= MaxBreakDelayBars + SwingBars + 1`(ブレイクが第2ボトムから離れすぎたパターンは無効)。

上記1〜9をすべて満たした場合、**当該ティックで買いシグナル成立**。パターンID(§7.1)を記録し、同一パターンでの再エントリーを禁止する。

### 2.3 ダブルトップ検出(売りシグナル)

ダブルボトムの完全な対称形。

1. 2つのスイングハイ `H1`(バー `b1`、古い)、`H2`(バー `b2`、新しい)。
2. `MinBarsBetweenBottoms <= (b1 - b2) <= MaxBarsBetweenBottoms`(パラメータはDBと共用)
3. `MathAbs(High[b1] - High[b2]) <= BottomTolerancePips * PipPoint`
4. ネックライン: 間の区間の最安値 `Neckline = Low[bn]`
5. 深さ: `MathMin(High[b1], High[b2]) - Neckline >= MinPatternDepthPips * PipPoint`
6. 3点の非縮退(DBと同じ)
7. 非先行ブレイク: `j = b2-1 .. 2` のすべてで `Close[j] >= Neckline - BreakBufferPips * PipPoint`
8. ブレイク確定: `Close[1] < Neckline - BreakBufferPips * PipPoint`
9. 鮮度: DBと同じ。

### 2.4 検出の一意性

- パターンIDは `(方向, Time[b1], Time[b2])` の組で定義し、直近に取引したパターンIDと一致する場合はシグナル無効(同一バー・同一パターンの多重発火防止)。
- 同一の新バーでDBとDTが同時成立した場合は**両方無効**(矛盾シグナルとして見送り)。

---

## 3. エントリー/エグジットルール

### 3.1 エントリー

- **前提条件(すべてAND)**:
  1. 自EAのオープンポジション(`MagicNumber` 一致)が0件
  2. 全フィルタ通過(§5: スプレッド、時間帯、日次損失、曜日末制御)
  3. 取引許可状態(`IsTradeAllowed()`、`TradingHalted == false`)
- **買い**: DBシグナル確定 → 次ティックで `OrderSend(Symbol(), OP_BUY, lot, Ask, SlippagePoints, sl, tp, comment, MagicNumber)`
- **売り**: DTシグナル確定 → `OP_SELL`(Bid成行)
- **ロット**: §4のマーチン状態から算出。
- **初回エントリーもシグナル必須**: EA起動直後やリセット直後であっても、DB/DT確定なしにはエントリーしない。

### 3.2 SL/TP(エグジット)

- **SL(買いの場合)**: `SL = MathMin(Low[b1], Low[b2]) - SlBufferPips * PipPoint`
  - ただし `UseFixedSlTp == true` の場合は `SL = 約定価格 - StopLossPips * PipPoint`
  - パターンベースSLの距離が `MaxSlPips` を超える場合はシグナル見送り(過大リスク回避)。
  - SL距離がブローカーの `MODE_STOPLEVEL` 未満なら `STOPLEVEL + 1 point` に拡張。
- **TP(買いの場合)**: `TP = 約定価格 + SL距離 × RewardRatio`
  - `UseFixedSlTp == true` の場合は `TP = 約定価格 + TakeProfitPips * PipPoint`
- 売りは対称形。
- **決済はSL/TPのみ**。裁量的な途中決済・トレーリングは行わない(v1仕様。ロジックの検証可能性を優先)。

### 3.3 勝敗判定

決済済み注文(`MODE_HISTORY`、`MagicNumber` 一致)の `OrderProfit() + OrderSwap() + OrderCommission()` の合計が
- `> 0` → 勝ち
- `<= 0` → 負け(建値決済も負け扱い=保守側)

---

## 4. マーチンゲールルール

### 4.1 状態変数

| 変数 | 意味 |
|---|---|
| `MartingaleLevel` | 現在のマーチン段数(0 = 初期ロット) |
| `LastClosedTicket` | 最後に集計した決済チケット(履歴の二重集計防止) |

### 4.2 ロット計算

```
lot = BaseLot * MathPow(LotMultiplier, MartingaleLevel)
lot = MathMin(lot, MaxLot)
lot をブローカーの LOTSTEP/MINLOT/MAXLOT に正規化(切り捨て方向)
```

### 4.3 遷移ルール(本EAの核心)

| イベント | 遷移 |
|---|---|
| トレードが**勝ち**で決済 | `MartingaleLevel = 0`(初期ロットにリセット) |
| トレードが**負け**で決済 | `MartingaleLevel += 1`(ただしエントリーはしない。**待機**) |
| 負け後、**次のDB/DTシグナルが確定** | そのロット(`BaseLot × LotMultiplier^Level`)で再エントリー |
| `MartingaleLevel > MaxMartingaleSteps` に達した | `ResetAfterMaxSteps == true` なら Level を0に戻して続行、`false` なら `TradingHalted = true`(手動再起動まで停止) |

- **禁止事項(実装上の明示的制約)**: 含み損拡大・逆行pips・経過時間・曜日などを理由としたロット増しエントリーは一切行わない。マーチンの唯一のトリガーは「負け決済後の新規DB/DTシグナル確定」である。
- 負け後の再エントリー方向はシグナルに従う(直前が買い負けでも、次にDTが出れば売りでマーチンする。方向は固定しない)。

---

## 5. リスク管理

すべてエントリー前チェックとして実装。1つでも不合格ならエントリー見送り(シグナルは消費せず破棄。パターンIDは記録し再発火は防ぐ)。

### 5.1 最大マーチン段数
- `MaxMartingaleSteps`(デフォルト4)。§4.3参照。

### 5.2 最大ロット
- `MaxLot` で頭打ち。ブローカー `MAXLOT` とも比較し小さい方を採用。

### 5.3 SL/TP必須
- 全注文にSL/TPを必ず設定。`OrderSend` でSL/TP同時指定。ECN口座向けに `EcnMode == true` の場合はSL/TPなしで発注後、即 `OrderModify` で設定(失敗時は3回リトライ、全失敗なら成行クローズして安全側に倒す)。

### 5.4 スプレッドフィルタ
- `(Ask - Bid) / PipPoint > MaxSpreadPips` ならエントリー禁止。

### 5.5 取引時間帯フィルタ
- `UseTimeFilter == true` のとき、サーバー時刻 `Hour()` が `TradeStartHour <= H < TradeEndHour` の範囲内のみエントリー可。
- `TradeStartHour > TradeEndHour` の場合は日跨ぎ(例: 22→6 = 22:00〜翌5:59)として解釈。
- `CloseAllOnFriday == true` のとき、金曜 `FridayCloseHour` 以降は新規停止+保有ポジションを成行クローズ(週末ギャップ対策)。

### 5.6 日次損失上限
- サーバー日付ベースで当日の確定損益(`MagicNumber` 一致の決済履歴合計)+現在の含み損益を集計。
- `当日合計損益 <= -MaxDailyLossMoney`(口座通貨額)に達したら `DailyHalted = true`:新規エントリーを当日いっぱい停止(保有ポジションはSL/TPに委ねる。`CloseOnDailyStop == true` なら即クローズ)。
- 日付が変わったら自動解除。

### 5.7 pip換算(3/5桁対応)
- `PipPoint = (Digits == 3 || Digits == 5) ? Point * 10 : Point`。pips系パラメータはすべてこの値で価格換算する。

### 5.8 その他
- `AccountFreeMarginCheck` で証拠金不足を事前検知し、不足時はエントリー見送り+アラート。
- `OrderSend` 失敗時は `GetLastError()` をログし、リクオート系エラー(135/136/138)のみ最大3回リトライ。

---

## 6. 入力パラメータ一覧

| パラメータ名 | 型 | デフォルト | 説明(日本語) |
|---|---|---|---|
| **--- パターン検出 ---** | | | |
| `SwingBars` | int | 3 | スイングハイ/ロー判定の前後比較本数(フラクタル幅) |
| `LookbackBars` | int | 100 | パターン探索の最大遡及バー数 |
| `MinBarsBetweenBottoms` | int | 5 | 2つのボトム(トップ)間の最小バー数 |
| `MaxBarsBetweenBottoms` | int | 40 | 2つのボトム(トップ)間の最大バー数 |
| `BottomTolerancePips` | double | 5.0 | 2点の安値(高値)の許容価格差(pips) |
| `MinPatternDepthPips` | double | 10.0 | ネックラインまでの最小深さ(pips、ノイズ除去) |
| `BreakBufferPips` | double | 1.0 | ネックラインブレイク確認バッファ(pips) |
| `MaxBreakDelayBars` | int | 20 | 第2ボトム(トップ)からブレイクまでの最大バー数 |
| **--- ロット/マーチンゲール ---** | | | |
| `BaseLot` | double | 0.01 | 初期ロット |
| `LotMultiplier` | double | 2.0 | 負け後のロット倍率 |
| `MaxMartingaleSteps` | int | 4 | 最大マーチン段数(0=マーチン無効) |
| `MaxLot` | double | 1.0 | 1注文の最大ロット(絶対上限) |
| `ResetAfterMaxSteps` | bool | false | true: 最大段数到達で初期ロットに戻す / false: 取引停止 |
| **--- SL/TP ---** | | | |
| `UseFixedSlTp` | bool | false | true: 固定pips SL/TP / false: パターンベースSL+RR比TP |
| `StopLossPips` | double | 30.0 | 固定SL(pips、UseFixedSlTp=true時) |
| `TakeProfitPips` | double | 45.0 | 固定TP(pips、UseFixedSlTp=true時) |
| `SlBufferPips` | double | 2.0 | パターン安値(高値)からのSLバッファ(pips) |
| `RewardRatio` | double | 1.5 | TP = SL距離×この倍率(パターンベース時) |
| `MaxSlPips` | double | 60.0 | パターンベースSLの許容最大距離(超過時は見送り) |
| **--- フィルタ/リスク管理 ---** | | | |
| `MaxSpreadPips` | double | 3.0 | 許容最大スプレッド(pips) |
| `UseTimeFilter` | bool | true | 取引時間帯フィルタを使用する |
| `TradeStartHour` | int | 8 | 取引開始時刻(サーバー時、0-23) |
| `TradeEndHour` | int | 22 | 取引終了時刻(サーバー時、この時刻を含まない) |
| `CloseAllOnFriday` | bool | true | 金曜クローズ処理を有効化 |
| `FridayCloseHour` | int | 21 | 金曜のこの時刻以降は新規停止+全決済(サーバー時) |
| `MaxDailyLossMoney` | double | 500.0 | 日次損失上限(口座通貨額。到達で当日停止) |
| `CloseOnDailyStop` | bool | false | 日次停止時に保有ポジションも即決済するか |
| **--- 発注/システム ---** | | | |
| `MagicNumber` | int | 20260705 | 自己注文識別用マジックナンバー |
| `SlippagePoints` | int | 30 | 許容スリッページ(point単位) |
| `EcnMode` | bool | false | ECN口座モード(発注後にOrderModifyでSL/TP設定) |
| `OrderCommentText` | string | "PA-Martin" | 注文コメント |
| `EnableAlerts` | bool | false | シグナル/停止イベント時にAlertを出す |

---

## 7. 状態管理とエッジケース

### 7.1 内部状態(グローバル変数)

- `LastBarTime`(datetime): 新バー検知用。`Time[0] != LastBarTime` の時のみ検出ロジックを実行。
- `MartingaleLevel`(int): 現在のマーチン段数。
- `TradingHalted` / `DailyHalted`(bool): 恒久停止/日次停止フラグ。
- `LastTradedPatternD1` / `LastTradedPatternD2`(datetime)+ `LastTradedPatternDir`(int): 直近に発火したパターンID(§2.4)。
- `LastClosedTicket`(int): 決済履歴の集計済み位置。

### 7.2 再起動復帰(状態の再構築)

`OnInit()` で以下を実行し、**チャート再起動・端末再起動・パラメータ変更後も状態を復元**する:

1. `OrdersHistoryTotal()` を新しい順に走査し、`MagicNumber` と `Symbol()` が一致する決済注文から**直近の勝ちトレード以降の連敗数**をカウント → `MartingaleLevel` を再計算。`MaxMartingaleSteps` 超過なら §4.3 のルールを適用。
2. オープン注文を走査し、自EAのポジションが存在すれば「保有中」状態として引き継ぐ(新規シグナルは無視)。SL/TP未設定の自ポジションを発見したら §3.2 のルールで `OrderModify` する。
3. 当日決済損益を再集計し、`DailyHalted` を復元。
4. 補助として `GlobalVariableSet` に `MartingaleLevel` と `TradingHalted` をミラー保存し、履歴走査と不一致の場合は保守側(大きい段数/停止)を採用。

注意: MT4の口座履歴表示期間設定により履歴が取得できない場合があるため、GlobalVariablesを一次情報、履歴走査を検証用とする。

### 7.3 週末ギャップ

- `CloseAllOnFriday == true` で金曜夜に全決済(§5.5)。
- 月曜窓開けでSLを飛び越えた場合はブローカー約定に従う(EA側は決済結果の損益で勝敗判定するのみ)。スプレッドフィルタが週明けの広いスプレッドを自然にブロックする。

### 7.4 同一バー多重シグナル

- 検出は「新バー確定時に1回」のみ実行するため、同一バー内のティックで多重発火しない。
- 同一新バーでDB・DT両方成立 → 両方破棄(§2.4)。
- 同一パターンIDでの再発火 → 破棄(§2.4)。フィルタで見送ったパターンも同様にIDを記録して再発火させない。

### 7.5 その他のエッジケース

| ケース | 挙動 |
|---|---|
| ヒストリー不足(`Bars < LookbackBars + SwingBars + 2`) | 検出スキップ(エラーにしない) |
| 発注失敗(リクオート等) | 最大3回リトライ、全失敗でシグナル破棄+ログ(マーチン段数は変更しない) |
| `MODE_STOPLEVEL` 違反 | SL/TPを最小距離に拡張して発注 |
| 証拠金不足 | 見送り+ログ。マーチン段数は維持(次シグナルで再試行) |
| 保有中に新シグナル | 無視(最大1ポジション) |
| 建値決済(損益0) | 負け扱い(§3.3、保守側) |
| 手動で自EAのポジションが決済された | 履歴集計で通常どおり勝敗判定し段数を更新 |
| テスターでの動作 | 全ロジックが確定足+標準関数のみのためStrategy Testerで再現可能 |

### 7.6 ログ

- シグナル検出時: 方向、`b1/b2/bn` の時刻と価格、ネックライン、算出SL/TP、ロット、マーチン段数を `Print` する(検証容易性のため必須)。
- 停止イベント(日次停止・最大段数停止)は `Print` +(`EnableAlerts` 時)`Alert`。

---

## 8. ファイル構成

```
MQL4/
└── Experts/
    └── PriceActionMartingaleEA.mq4   … 本EA(単一ファイル、依存なし)
```

| セクション | 内容 |
|---|---|
| ヘッダ/inputパラメータ | §6の全パラメータ(`input`/`extern`)。コメントは日本語 |
| グローバル状態 | §7.1の変数群 |
| `OnInit()` | pip換算初期化、§7.2の状態復元 |
| `OnDeinit()` | GlobalVariablesへの状態保存 |
| `OnTick()` | 新バー検知 → 決済検知/勝敗集計 → フィルタ評価 → パターン検出 → エントリー、の順で薄く保つ |
| 検出関数 | `bool DetectDoubleBottom(...)` / `bool DetectDoubleTop(...)` |
| スイング関数 | `bool IsSwingLow(int i)` / `bool IsSwingHigh(int i)` |
| 売買関数 | `int OpenTrade(int dir, double lot, ...)`(リトライ・ECN対応込み) |
| マーチン/勝敗管理 | `void UpdateMartingaleFromHistory()` / `double CalcLot()` |
| フィルタ関数 | `bool PassSpread()` / `bool PassTimeFilter()` / `bool PassDailyLoss()` |
| ユーティリティ | pip換算、ロット正規化、ログ |
