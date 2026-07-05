//+------------------------------------------------------------------+
//|                                    PriceActionMartingaleEA.mq4  |
//|  プライスアクション型マーチンゲールEA                            |
//|                                                                  |
//|  コンセプト:                                                     |
//|   - ダブルボトム(DB)確定で買い、ダブルトップ(DT)確定で売り        |
//|   - マーチンゲール(ロット増し)は「負け決済後に新しいDB/DTが      |
//|     確定した時」のみ発動する                                     |
//|   - 時間経過・逆行pips・含み損によるナンピン/倍賭けは一切行わない |
//|   - 全判定は確定足(shift>=1)ベース、新バー確定時に1回のみ評価    |
//+------------------------------------------------------------------+
#property copyright "PriceActionMartingaleEA"
#property link      ""
#property version   "1.00"
#property strict

//====================================================================
// 入力パラメータ(仕様書 §6)
//====================================================================
input string  Sec1                   = "--- パターン検出 ---";      // ▼ パターン検出
input int     SwingBars              = 3;        // スイングハイ/ロー判定の前後比較本数(フラクタル幅)
input int     LookbackBars           = 100;      // パターン探索の最大遡及バー数
input int     MinBarsBetweenBottoms  = 5;        // 2つのボトム(トップ)間の最小バー数
input int     MaxBarsBetweenBottoms  = 40;       // 2つのボトム(トップ)間の最大バー数
input double  BottomTolerancePips    = 5.0;      // 2点の安値(高値)の許容価格差(pips)
input double  MinPatternDepthPips    = 10.0;     // ネックラインまでの最小深さ(pips、ノイズ除去)
input double  BreakBufferPips        = 1.0;      // ネックラインブレイク確認バッファ(pips)
input int     MaxBreakDelayBars      = 20;       // 第2ボトム(トップ)からブレイクまでの最大バー数

input string  Sec2                   = "--- ロット/マーチンゲール ---"; // ▼ ロット/マーチンゲール
input double  BaseLot                = 0.01;     // 初期ロット
input double  LotMultiplier          = 2.0;      // 負け後のロット倍率
input int     MaxMartingaleSteps     = 4;        // 最大マーチン段数(0=マーチン無効)
input double  MaxLot                 = 1.0;      // 1注文の最大ロット(絶対上限)
input bool    ResetAfterMaxSteps     = false;    // true:最大段数到達で初期ロットに戻す / false:取引停止

input string  Sec3                   = "--- SL/TP ---";             // ▼ SL/TP
input bool    UseFixedSlTp           = false;    // true:固定pips SL/TP / false:パターンベースSL+RR比TP
input double  StopLossPips           = 30.0;     // 固定SL(pips、UseFixedSlTp=true時)
input double  TakeProfitPips         = 45.0;     // 固定TP(pips、UseFixedSlTp=true時)
input double  SlBufferPips           = 2.0;      // パターン安値(高値)からのSLバッファ(pips)
input double  RewardRatio            = 1.5;      // TP = SL距離×この倍率(パターンベース時)
input double  MaxSlPips              = 60.0;     // パターンベースSLの許容最大距離(超過時は見送り)

input string  Sec4                   = "--- フィルタ/リスク管理 ---"; // ▼ フィルタ/リスク管理
input double  MaxSpreadPips          = 3.0;      // 許容最大スプレッド(pips)
input bool    UseTimeFilter          = true;     // 取引時間帯フィルタを使用する
input int     TradeStartHour         = 8;        // 取引開始時刻(サーバー時、0-23)
input int     TradeEndHour           = 22;       // 取引終了時刻(サーバー時、この時刻を含まない)
input bool    CloseAllOnFriday       = true;     // 金曜クローズ処理を有効化
input int     FridayCloseHour        = 21;       // 金曜のこの時刻以降は新規停止+全決済(サーバー時)
input double  MaxDailyLossMoney      = 500.0;    // 日次損失上限(口座通貨額。到達で当日停止)
input bool    CloseOnDailyStop       = false;    // 日次停止時に保有ポジションも即決済するか

input string  Sec5                   = "--- 発注/システム ---";      // ▼ 発注/システム
input int     MagicNumber            = 20260705; // 自己注文識別用マジックナンバー
input int     SlippagePoints         = 30;       // 許容スリッページ(point単位)
input bool    EcnMode                = false;    // ECN口座モード(発注後にOrderModifyでSL/TP設定)
input string  OrderCommentText       = "PA-Martin"; // 注文コメント
input bool    EnableAlerts           = false;    // シグナル/停止イベント時にAlertを出す

//====================================================================
// 内部状態(仕様書 §7.1)
//====================================================================
int      DIR_BUY  =  1;                 // 方向定数: 買い
int      DIR_SELL = -1;                 // 方向定数: 売り

datetime LastBarTime          = 0;      // 新バー検知用(Time[0] の前回値)
int      MartingaleLevel      = 0;      // 現在のマーチン段数(0=初期ロット)
bool     TradingHalted        = false;  // 恒久停止フラグ(最大段数超過)
bool     DailyHalted          = false;  // 日次停止フラグ(日次損失上限)
datetime LastTradedPatternD1  = 0;      // 直近発火パターンID: Time[b1]
datetime LastTradedPatternD2  = 0;      // 直近発火パターンID: Time[b2]
int      LastTradedPatternDir = 0;      // 直近発火パターンID: 方向
int      LastClosedTicket     = -1;     // 最後に集計した決済チケット(二重集計防止)

datetime gLastProcessedCloseTime = 0;   // 集計済み決済時刻(未集計注文の抽出基準)
int      gIgnoredTicket       = -1;     // 勝敗集計から除外するチケット(ECN設定失敗の緊急クローズ)
int      gPrevHistoryTotal    = -1;     // 履歴走査の間引き用: 前回の履歴件数
int      gPrevOpenCount       = -1;     // 履歴走査の間引き用: 前回の自EAポジション数

double   gPipPoint            = 0.0;    // 1pipの価格値(3/5桁ブローカー補正済み)
int      gCurrentDay          = -1;     // 日次損失リセット用の日付(サーバー日)
double   gTodayClosedProfit   = 0.0;    // 当日確定損益のキャッシュ(決済検知時に再計算)

//====================================================================
// ユーティリティ
//====================================================================

//--- GlobalVariables 用のキー名(シンボル+マジックで一意化)
string GvName(string suffix)
{
   return("PAM_" + Symbol() + "_" + IntegerToString(MagicNumber) + "_" + suffix);
}

//--- pip換算(仕様書 §5.7): 3/5桁ブローカーは Point*10 を1pipとする
double CalcPipPoint()
{
   if(Digits == 3 || Digits == 5)
      return(Point * 10.0);
   return(Point);
}

//--- ログ出力ヘルパ
void Log(string msg)
{
   Print("[PA-Martin] ", msg);
}

//--- ログ+(有効時)アラート
void LogAlert(string msg)
{
   Log(msg);
   if(EnableAlerts)
      Alert("[PA-Martin] ", Symbol(), " ", msg);
}

//--- 状態を GlobalVariables にミラー保存(仕様書 §7.2-4)
void SaveState()
{
   GlobalVariableSet(GvName("LEVEL"),  MartingaleLevel);
   GlobalVariableSet(GvName("HALTED"), TradingHalted ? 1.0 : 0.0);
   GlobalVariableSet(GvName("IGNORE"), gIgnoredTicket);   // 勝敗集計から除外するチケット
}

//====================================================================
// ロット計算(仕様書 §4.2)
//====================================================================

//--- ブローカー仕様(LOTSTEP/MINLOT/MAXLOT)へのロット正規化(切り捨て方向)
double NormalizeLot(double lot)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(lotStep <= 0.0) lotStep = 0.01;   // ゼロ除算ガード
   if(minLot  <= 0.0) minLot  = lotStep;

   // 有効上限 = ブローカーMAXLOTと入力MaxLotの小さい方(§5.2)
   double capLot = MaxLot;
   if(maxLot > 0.0 && maxLot < capLot) capLot = maxLot;

   // 最小ロットが上限を超える設定では上限を守った発注が不可能 → 0を返して発注中止
   if(minLot > capLot)
   {
      Log("MINLOT(" + DoubleToStr(minLot, 3) + ") > ロット上限(" + DoubleToStr(capLot, 3) +
          ")のためロット算出不能。発注を中止します。");
      return(0.0);
   }

   lot = MathFloor(lot / lotStep + 0.0000001) * lotStep;   // ステップに切り捨て
   if(lot > capLot) lot = MathFloor(capLot / lotStep + 0.0000001) * lotStep;  // 上限に丸め
   if(lot < minLot) lot = minLot;   // 最小ロット未満は最小ロットに引き上げ(上限内であることは確認済み)

   // 丸め小数桁を LOTSTEP から動的算出(例: 0.001 → 3桁。固定2桁では3桁ステップと矛盾するため)
   int lotDigits = (int)MathRound(-MathLog(lotStep) / MathLog(10.0));
   if(lotDigits < 0) lotDigits = 0;
   if(lotDigits > 8) lotDigits = 8;
   return(NormalizeDouble(lot, lotDigits));
}

//--- マーチン段数からロットを算出: lot = BaseLot * LotMultiplier^Level(上限MaxLot)
double CalcLot()
{
   double lot = BaseLot * MathPow(LotMultiplier, MartingaleLevel);
   if(lot > MaxLot) lot = MaxLot;
   return(NormalizeLot(lot));
}

//====================================================================
// 自EAポジション/履歴の走査(すべて MagicNumber+Symbol でフィルタ)
//====================================================================

//--- 自EAのオープンポジション数
int CountOpenPositions()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber)           continue;
      if(OrderSymbol()      != Symbol())              continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      count++;
   }
   return(count);
}

//--- 自EAポジションの含み損益合計(損益+スワップ+手数料)
double GetFloatingProfit()
{
   double total = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber)           continue;
      if(OrderSymbol()      != Symbol())              continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      total += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return(total);
}

//--- 当日(サーバー日付)の確定損益合計(仕様書 §5.6)
double CalcTodayClosedProfit()
{
   datetime dayStart = TimeCurrent() - (TimeCurrent() % 86400);  // サーバー日の0時
   double total = 0.0;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != MagicNumber)            continue;
      if(OrderSymbol()      != Symbol())               continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderCloseTime() < dayStart)                  continue;
      total += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return(total);
}

//====================================================================
// マーチンゲール管理(仕様書 §4)
//====================================================================

//--- 最大段数超過時のルール適用(§4.3)
void ApplyMaxStepsRule()
{
   if(MartingaleLevel > MaxMartingaleSteps)
   {
      if(ResetAfterMaxSteps)
      {
         Log("最大マーチン段数(" + IntegerToString(MaxMartingaleSteps) +
             ")超過。ResetAfterMaxSteps=true のため段数を0にリセットして続行します。");
         MartingaleLevel = 0;
      }
      else
      {
         TradingHalted = true;
         LogAlert("最大マーチン段数(" + IntegerToString(MaxMartingaleSteps) +
                  ")超過。取引を停止しました。解除するには、ターミナルのグローバル変数ウィンドウ(F3)で " +
                  GvName("HALTED") + "(必要に応じて " + GvName("LEVEL") +
                  " も)を削除してからEAを再アタッチしてください。");
      }
   }
}

//--- 新規決済の検知と勝敗集計(毎ティック呼び出し)
//    勝ち: 段数リセット / 負け: 段数+1して「待機」(エントリーは次のDB/DTシグナル確定まで行わない)
//    未集計の決済注文をクローズ時刻の時系列で全件処理する
void CheckClosedTrades()
{
   // 間引き: 履歴件数と自EAポジション数に変化がない限り履歴を走査しない(毎ティック全走査の負荷対策)
   int histTotal = OrdersHistoryTotal();
   int openCount = CountOpenPositions();
   if(histTotal == gPrevHistoryTotal && openCount == gPrevOpenCount) return;
   gPrevHistoryTotal = histTotal;
   gPrevOpenCount    = openCount;

   // 未集計(gLastProcessedCloseTime より新しい)の自EA決済注文を収集
   datetime closeTimes[];
   double   profits[];
   int      tickets[];
   ArrayResize(closeTimes, histTotal);
   ArrayResize(profits,    histTotal);
   ArrayResize(tickets,    histTotal);
   int n = 0;
   for(int i = 0; i < histTotal; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != MagicNumber)            continue;
      if(OrderSymbol()      != Symbol())               continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderCloseTime() < gLastProcessedCloseTime)   continue;   // 集計済みより古い
      if(OrderCloseTime() == gLastProcessedCloseTime &&
         OrderTicket() <= LastClosedTicket)            continue;   // 同時刻は集計済みチケット以下を除外
      closeTimes[n] = OrderCloseTime();
      profits[n]    = OrderProfit() + OrderSwap() + OrderCommission();
      tickets[n]    = OrderTicket();
      n++;
   }
   if(n == 0) return;

   // クローズ時刻の昇順(同時刻はチケット昇順)にソートし、時系列で処理する
   for(int a = 1; a < n; a++)
   {
      datetime ct = closeTimes[a];
      double   pf = profits[a];
      int      tk = tickets[a];
      int      b  = a - 1;
      while(b >= 0 && (closeTimes[b] > ct || (closeTimes[b] == ct && tickets[b] > tk)))
      {
         closeTimes[b + 1] = closeTimes[b];
         profits[b + 1]    = profits[b];
         tickets[b + 1]    = tickets[b];
         b--;
      }
      closeTimes[b + 1] = ct;
      profits[b + 1]    = pf;
      tickets[b + 1]    = tk;
   }

   // 古い順に勝敗判定(§3.3): 損益+スワップ+手数料。0(建値)は負け扱い=保守側
   for(int s = 0; s < n; s++)
   {
      LastClosedTicket        = tickets[s];
      gLastProcessedCloseTime = closeTimes[s];

      // ECNのSL/TP設定失敗による緊急クローズは技術的失敗であり、勝敗集計から除外(マーチンさせない)
      if(tickets[s] == gIgnoredTicket)
      {
         LogAlert("チケット" + IntegerToString(tickets[s]) +
                  " はECN設定失敗の緊急クローズのため勝敗集計から除外します(マーチン段数は変更しません)。");
         gIgnoredTicket = -1;   // 除外は当該チケット1回のみ有効
         continue;
      }

      if(profits[s] > 0.0)
      {
         Log("決済検知: チケット" + IntegerToString(tickets[s]) +
             " 損益=" + DoubleToStr(profits[s], 2) + " → 勝ち。マーチン段数を0にリセット。");
         MartingaleLevel = 0;
      }
      else
      {
         MartingaleLevel++;
         Log("決済検知: チケット" + IntegerToString(tickets[s]) +
             " 損益=" + DoubleToStr(profits[s], 2) + " → 負け。マーチン段数=" +
             IntegerToString(MartingaleLevel) + " で次のDB/DTシグナル確定まで待機。");
         ApplyMaxStepsRule();
      }
   }

   gTodayClosedProfit = CalcTodayClosedProfit();  // 日次損益キャッシュを更新
   SaveState();
}

//====================================================================
// スイングポイント判定(仕様書 §2.1)
//====================================================================

//--- バー i がスイングロー(前後 SwingBars 本より厳密に安い)か。同値は不成立
bool IsSwingLow(int i)
{
   if(i - SwingBars < 0 || i + SwingBars >= Bars) return(false);
   for(int k = 1; k <= SwingBars; k++)
   {
      if(!(Low[i] < Low[i - k])) return(false);
      if(!(Low[i] < Low[i + k])) return(false);
   }
   return(true);
}

//--- バー i がスイングハイ(前後 SwingBars 本より厳密に高い)か。同値は不成立
bool IsSwingHigh(int i)
{
   if(i - SwingBars < 0 || i + SwingBars >= Bars) return(false);
   for(int k = 1; k <= SwingBars; k++)
   {
      if(!(High[i] > High[i - k])) return(false);
      if(!(High[i] > High[i + k])) return(false);
   }
   return(true);
}

//====================================================================
// パターン検出(仕様書 §2.2 / §2.3)
//====================================================================

//--- ダブルボトム検出(買いシグナル)。成立時は b1/b2/bn/neckline を返す
bool DetectDoubleBottom(int &outB1, int &outB2, int &outBn, double &outNeck)
{
   double tol    = BottomTolerancePips * gPipPoint;   // 2点の許容価格差
   double depth  = MinPatternDepthPips * gPipPoint;   // 最小深さ
   double buffer = BreakBufferPips     * gPipPoint;   // ブレイクバッファ

   // 第2ボトムの鮮度条件(§2.2-9): b2 <= MaxBreakDelayBars + SwingBars + 1
   int maxB2 = MaxBreakDelayBars + SwingBars + 1;

   // スイング確定条件(§2.1): 右側に SwingBars 本の確定足が必要 → b2 >= SwingBars + 1
   for(int b2 = SwingBars + 1; b2 <= maxB2; b2++)
   {
      if(b2 >= Bars - SwingBars) break;
      if(!IsSwingLow(b2)) continue;

      // ボトム間隔条件(§2.2-2)を満たす範囲で古い方の安値 b1 を探索
      int b1min = b2 + MinBarsBetweenBottoms;
      int b1max = b2 + MaxBarsBetweenBottoms;
      if(b1max > LookbackBars) b1max = LookbackBars;  // 探索範囲は LookbackBars 以内(§2.1)

      for(int b1 = b1min; b1 <= b1max; b1++)
      {
         if(b1 >= Bars - SwingBars) break;
         if(!IsSwingLow(b1)) continue;

         // 2点の価格許容差(§2.2-3)
         if(MathAbs(Low[b1] - Low[b2]) > tol) continue;

         // ネックライン: b2 < j < b1 の区間の最高値バー(§2.2-4)
         if(b1 - b2 < 2) continue;                    // 中間バーが存在しない縮退形を除外(§2.2-6)
         int bn = b2 + 1;
         for(int j = b2 + 2; j < b1; j++)
            if(High[j] > High[bn]) bn = j;
         double neck = High[bn];

         // 3点の非縮退(§2.2-6): bn は区間内なので b1/b2 と自動的に異なるが明示確認
         if(bn == b1 || bn == b2) continue;

         // パターンの深さ(§2.2-5)
         if(neck - MathMax(Low[b1], Low[b2]) < depth) continue;

         // 非先行ブレイク(§2.2-7): b2 より新しい確定足 j=b2-1..2 がすべてネックライン以下
         bool preBreak = false;
         for(int j2 = b2 - 1; j2 >= 2; j2--)
         {
            if(Close[j2] > neck + buffer) { preBreak = true; break; }
         }
         if(preBreak) continue;

         // ネックラインブレイク確定(§2.2-8): 直近確定足(シフト1)の終値で上抜け
         if(Close[1] > neck + buffer)
         {
            outB1 = b1; outB2 = b2; outBn = bn; outNeck = neck;
            return(true);
         }
      }
   }
   return(false);
}

//--- ダブルトップ検出(売りシグナル)。ダブルボトムの完全対称形(§2.3)
bool DetectDoubleTop(int &outB1, int &outB2, int &outBn, double &outNeck)
{
   double tol    = BottomTolerancePips * gPipPoint;
   double depth  = MinPatternDepthPips * gPipPoint;
   double buffer = BreakBufferPips     * gPipPoint;

   int maxB2 = MaxBreakDelayBars + SwingBars + 1;   // 鮮度条件(§2.3-9)

   for(int b2 = SwingBars + 1; b2 <= maxB2; b2++)
   {
      if(b2 >= Bars - SwingBars) break;
      if(!IsSwingHigh(b2)) continue;

      int b1min = b2 + MinBarsBetweenBottoms;       // 間隔パラメータはDBと共用(§2.3-2)
      int b1max = b2 + MaxBarsBetweenBottoms;
      if(b1max > LookbackBars) b1max = LookbackBars;

      for(int b1 = b1min; b1 <= b1max; b1++)
      {
         if(b1 >= Bars - SwingBars) break;
         if(!IsSwingHigh(b1)) continue;

         // 2点の高値の許容差(§2.3-3)
         if(MathAbs(High[b1] - High[b2]) > tol) continue;

         // ネックライン: 間の区間の最安値バー(§2.3-4)
         if(b1 - b2 < 2) continue;
         int bn = b2 + 1;
         for(int j = b2 + 2; j < b1; j++)
            if(Low[j] < Low[bn]) bn = j;
         double neck = Low[bn];

         if(bn == b1 || bn == b2) continue;         // 非縮退(§2.3-6)

         // 深さ(§2.3-5)
         if(MathMin(High[b1], High[b2]) - neck < depth) continue;

         // 非先行ブレイク(§2.3-7)
         bool preBreak = false;
         for(int j2 = b2 - 1; j2 >= 2; j2--)
         {
            if(Close[j2] < neck - buffer) { preBreak = true; break; }
         }
         if(preBreak) continue;

         // ブレイク確定(§2.3-8): 終値で下抜け
         if(Close[1] < neck - buffer)
         {
            outB1 = b1; outB2 = b2; outBn = bn; outNeck = neck;
            return(true);
         }
      }
   }
   return(false);
}

//====================================================================
// フィルタ(仕様書 §5)
//====================================================================

//--- スプレッドフィルタ(§5.4)
bool PassSpread()
{
   if(gPipPoint <= 0.0) return(false);              // ゼロ除算ガード
   double spreadPips = (Ask - Bid) / gPipPoint;
   if(spreadPips > MaxSpreadPips)
   {
      Log("スプレッドフィルタ不合格: " + DoubleToStr(spreadPips, 1) +
          " pips > " + DoubleToStr(MaxSpreadPips, 1) + " pips。エントリー見送り。");
      return(false);
   }
   return(true);
}

//--- 取引時間帯フィルタ(§5.5)。TradeStartHour > TradeEndHour は日跨ぎとして解釈
bool PassTimeFilter()
{
   if(!UseTimeFilter) return(true);
   int h = Hour();
   bool ok;
   if(TradeStartHour < TradeEndHour)
      ok = (h >= TradeStartHour && h < TradeEndHour);
   else if(TradeStartHour > TradeEndHour)
      ok = (h >= TradeStartHour || h < TradeEndHour); // 日跨ぎ(例: 22→6)
   else
      ok = false;                                     // 開始=終了は取引時間なしとみなす
   if(!ok)
      Log("時間帯フィルタ不合格: 現在" + IntegerToString(h) + "時。エントリー見送り。");
   return(ok);
}

//--- 金曜クローズ処理(§5.5)。金曜 FridayCloseHour 以降は新規停止+全決済
//    戻り値 true = 新規エントリー禁止
bool CheckFridayClose()
{
   if(!CloseAllOnFriday)   return(false);
   if(DayOfWeek() != 5)    return(false);
   if(Hour() < FridayCloseHour) return(false);
   if(CountOpenPositions() > 0)
      CloseAllPositions("金曜クローズ(週末ギャップ対策)");
   return(true);
}

//--- 日付変更検知: 日次停止の自動解除(§5.6)
void CheckDailyReset()
{
   int today = (int)(TimeCurrent() / 86400);
   if(today != gCurrentDay)
   {
      gCurrentDay        = today;
      gTodayClosedProfit = CalcTodayClosedProfit();
      if(DailyHalted)
      {
         DailyHalted = false;
         Log("日付が変わりました。日次停止を解除します。");
      }
   }
}

//--- 日次損失上限チェック(§5.6): 当日確定損益+含み損益で判定(毎ティック)
void CheckDailyStop()
{
   if(DailyHalted)              return;
   if(MaxDailyLossMoney <= 0.0) return;              // 0以下なら無効
   double total = gTodayClosedProfit + GetFloatingProfit();
   if(total <= -MaxDailyLossMoney)
   {
      DailyHalted = true;
      LogAlert("日次損失上限に到達(当日損益=" + DoubleToStr(total, 2) +
               ")。当日いっぱい新規エントリーを停止します。");
      if(CloseOnDailyStop && CountOpenPositions() > 0)
         CloseAllPositions("日次停止による即時決済");
   }
}

//====================================================================
// 発注処理(仕様書 §3 / §5.3 / §5.8)
//====================================================================

//--- リクオート系エラー(135/136/138)のみリトライ対象と判定
bool IsRetryableError(int err)
{
   return(err == 135 || err == 136 || err == 138);   // PRICE_CHANGED / OFF_QUOTES / REQUOTE
}

//--- 自EAの全ポジションを成行クローズ
void CloseAllPositions(string reason)
{
   Log("全ポジション決済を実行: " + reason);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber)           continue;
      if(OrderSymbol()      != Symbol())              continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      int    ticket = OrderTicket();
      double lots   = OrderLots();
      bool   closed = false;
      for(int attempt = 1; attempt <= 3 && !closed; attempt++)
      {
         RefreshRates();
         double price = (OrderType() == OP_BUY) ? Bid : Ask;
         closed = OrderClose(ticket, lots, NormalizeDouble(price, Digits), SlippagePoints, clrRed);
         if(!closed)
         {
            int err = GetLastError();
            Log("OrderClose失敗: チケット" + IntegerToString(ticket) +
                " エラー" + IntegerToString(err) + "(試行" + IntegerToString(attempt) + "/3)");
            if(!IsRetryableError(err)) break;
         }
      }
   }
}

//--- 新規エントリー実行(§3.1/§3.2/§5.3/§5.8)
//    dir: DIR_BUY/DIR_SELL、patternExtreme: パターンSL基準価格(買い=2つの安値の低い方 等)
//    戻り値 true = 発注成功
bool ExecuteEntry(int dir, double patternExtreme)
{
   int cmd = (dir == DIR_BUY) ? OP_BUY : OP_SELL;

   // --- SL距離の算出(§3.2)
   RefreshRates();
   double entryRef = (dir == DIR_BUY) ? Ask : Bid;
   double slDist;
   if(UseFixedSlTp)
   {
      slDist = StopLossPips * gPipPoint;             // 固定SL
   }
   else
   {
      // パターンベースSL: 買い = min(Low[b1],Low[b2]) - SlBufferPips(売りは対称)
      double slPrice = (dir == DIR_BUY) ? patternExtreme - SlBufferPips * gPipPoint
                                        : patternExtreme + SlBufferPips * gPipPoint;
      slDist = (dir == DIR_BUY) ? entryRef - slPrice : slPrice - entryRef;
      if(slDist <= 0.0)
      {
         Log("SL距離が0以下のためシグナル見送り(価格がパターンSLを既に下回り/上回り)。");
         return(false);
      }
      // SL距離が MaxSlPips 超過なら見送り(過大リスク回避)
      if(slDist > MaxSlPips * gPipPoint)
      {
         Log("パターンSL距離 " + DoubleToStr(slDist / gPipPoint, 1) + " pips > MaxSlPips " +
             DoubleToStr(MaxSlPips, 1) + " のためシグナル見送り。");
         return(false);
      }
   }

   // --- ストップレベル対応(§3.2/§7.5): 最小距離未満なら STOPLEVEL + 1 point に拡張
   double minDist = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(slDist < minDist + Point)
   {
      slDist = minDist + Point;
      // 拡張後のSL距離が許容最大距離を超える場合も見送り(過大リスク回避。パターンベース時)
      if(!UseFixedSlTp && slDist > MaxSlPips * gPipPoint)
      {
         Log("STOPLEVEL拡張後のSL距離 " + DoubleToStr(slDist / gPipPoint, 1) +
             " pips > MaxSlPips " + DoubleToStr(MaxSlPips, 1) + " のためシグナル見送り。");
         return(false);
      }
   }

   double tpDist = UseFixedSlTp ? TakeProfitPips * gPipPoint : slDist * RewardRatio;
   if(tpDist < minDist + Point) tpDist = minDist + Point;

   // --- ロット算出(§4.2)
   double lot = CalcLot();
   if(lot <= 0.0)
   {
      Log("ロットが0以下のため発注中止。");
      return(false);
   }

   // --- 証拠金チェック(§5.8)
   double freeMargin = AccountFreeMarginCheck(Symbol(), cmd, lot);
   if(freeMargin <= 0.0 || GetLastError() == 134)
   {
      LogAlert("証拠金不足のためエントリー見送り(ロット=" + DoubleToStr(lot, 2) +
               ")。マーチン段数は維持し次シグナルで再試行します。");
      return(false);
   }

   // --- 発注(リクオート系エラーは最大3回リトライ)
   int ticket = -1;
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      RefreshRates();                                 // 発注直前に必ずレート更新
      double price = (dir == DIR_BUY) ? Ask : Bid;
      double sl    = (dir == DIR_BUY) ? price - slDist : price + slDist;
      double tp    = (dir == DIR_BUY) ? price + tpDist : price - tpDist;
      price = NormalizeDouble(price, Digits);
      sl    = NormalizeDouble(sl,    Digits);
      tp    = NormalizeDouble(tp,    Digits);

      // ECNモード時はSL/TPなしで発注し、約定後に OrderModify で設定(§5.3)
      double sendSl = EcnMode ? 0.0 : sl;
      double sendTp = EcnMode ? 0.0 : tp;

      ticket = OrderSend(Symbol(), cmd, lot, price, SlippagePoints, sendSl, sendTp,
                         OrderCommentText, MagicNumber, 0,
                         (dir == DIR_BUY) ? clrBlue : clrRed);
      if(ticket >= 0)
      {
         Log("発注成功: " + ((dir == DIR_BUY) ? "BUY" : "SELL") +
             " チケット" + IntegerToString(ticket) + " ロット=" + DoubleToStr(lot, 2) +
             " 価格=" + DoubleToStr(price, Digits) +
             " SL=" + DoubleToStr(sl, Digits) + " TP=" + DoubleToStr(tp, Digits) +
             " マーチン段数=" + IntegerToString(MartingaleLevel));
         break;
      }
      int err = GetLastError();
      Log("OrderSend失敗: エラー" + IntegerToString(err) +
          "(試行" + IntegerToString(attempt) + "/3)");
      if(!IsRetryableError(err)) break;               // リクオート系以外は即中止
   }

   if(ticket < 0)
   {
      // 全失敗: シグナル破棄+ログ(マーチン段数は変更しない。§7.5)
      Log("発注リトライ全失敗。シグナルを破棄します(マーチン段数は維持)。");
      return(false);
   }

   // --- ECNモード: 約定価格ベースでSL/TPを OrderModify(失敗時3回リトライ→全失敗で成行クローズ)
   if(EcnMode)
   {
      bool   modified = false;
      double sl2 = 0.0, tp2 = 0.0;
      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         double op = OrderOpenPrice();               // 実約定価格からSL/TPを再計算(§3.2)
         sl2 = (dir == DIR_BUY) ? op - slDist : op + slDist;
         tp2 = (dir == DIR_BUY) ? op + tpDist : op - tpDist;
         sl2 = NormalizeDouble(sl2, Digits);
         tp2 = NormalizeDouble(tp2, Digits);
         for(int m = 1; m <= 3 && !modified; m++)
         {
            RefreshRates();
            modified = OrderModify(ticket, op, sl2, tp2, 0, clrYellow);
            if(!modified)
               Log("ECN OrderModify失敗: エラー" + IntegerToString(GetLastError()) +
                   "(試行" + IntegerToString(m) + "/3)");
         }
      }
      if(!modified)
      {
         // SL/TPを設定できないポジションは保持しない(安全側に倒す。§5.3)
         // このクローズは技術的失敗のため勝敗集計から除外し、マーチン段数を変化させない
         gIgnoredTicket = ticket;
         SaveState();
         LogAlert("ECNモードのSL/TP設定に全失敗。安全のためチケット" + IntegerToString(ticket) +
                  " を成行クローズします(このクローズは勝敗集計から除外し、マーチン段数は変更しません)。");
         if(OrderSelect(ticket, SELECT_BY_TICKET))
         {
            for(int c = 1; c <= 3; c++)
            {
               RefreshRates();
               double cp = (dir == DIR_BUY) ? Bid : Ask;
               if(OrderClose(ticket, OrderLots(), NormalizeDouble(cp, Digits),
                             SlippagePoints, clrRed))
                  break;
               Log("緊急クローズ失敗: エラー" + IntegerToString(GetLastError()));
            }
         }
         return(false);
      }
      // 実際に OrderModify で設定した値をログ出力(発注前計算値ではなく約定価格ベースの値)
      Log("ECNモード: SL=" + DoubleToStr(sl2, Digits) + " TP=" + DoubleToStr(tp2, Digits) +
          " をOrderModifyで設定しました。");
   }

   return(true);
}

//====================================================================
// シグナル処理(仕様書 §2.4 / §3.1 / §7.4)
//====================================================================

//--- シグナル成立時の共通処理: パターンID記録 → フィルタ → エントリー
void HandleSignal(int dir, int b1, int b2, int bn, double neck, bool fridayBlock)
{
   // --- パターンIDの一意性チェック(§2.4): (方向, Time[b1], Time[b2]) が直近と同一なら無効
   if(dir == LastTradedPatternDir &&
      Time[b1] == LastTradedPatternD1 &&
      Time[b2] == LastTradedPatternD2)
      return;

   // フィルタで見送る場合もIDを記録して再発火を防ぐ(§5/§7.4)
   LastTradedPatternDir = dir;
   LastTradedPatternD1  = Time[b1];
   LastTradedPatternD2  = Time[b2];

   // --- シグナルログ(§7.6): 方向、3点の時刻と価格、ネックライン、ロット、段数
   string dirStr = (dir == DIR_BUY) ? "ダブルボトム(買い)" : "ダブルトップ(売り)";
   double p1 = (dir == DIR_BUY) ? Low[b1]  : High[b1];
   double p2 = (dir == DIR_BUY) ? Low[b2]  : High[b2];
   Log("シグナル検出: " + dirStr +
       " | b1=" + TimeToStr(Time[b1], TIME_DATE|TIME_MINUTES) + "(" + DoubleToStr(p1, Digits) + ")" +
       " b2=" + TimeToStr(Time[b2], TIME_DATE|TIME_MINUTES) + "(" + DoubleToStr(p2, Digits) + ")" +
       " bn=" + TimeToStr(Time[bn], TIME_DATE|TIME_MINUTES) +
       " ネックライン=" + DoubleToStr(neck, Digits) +
       " | 予定ロット=" + DoubleToStr(CalcLot(), 2) +
       " マーチン段数=" + IntegerToString(MartingaleLevel));
   if(EnableAlerts)
      Alert("[PA-Martin] ", Symbol(), " ", dirStr, " シグナル確定");

   // --- エントリー前提条件(§3.1): 停止フラグ/取引許可/ポジション数/各フィルタ
   if(TradingHalted) { Log("恒久停止中のためエントリーしません。");      return; }
   if(DailyHalted)   { Log("日次停止中のためエントリーしません。");      return; }
   if(fridayBlock)   { Log("金曜クローズ時間帯のためエントリーしません。"); return; }
   if(!IsTradeAllowed()) { Log("取引不許可(IsTradeAllowed=false)のため見送り。"); return; }
   if(CountOpenPositions() > 0) { Log("保有ポジションありのため新規シグナルは無視(最大1ポジション)。"); return; }
   if(!PassTimeFilter()) return;
   if(!PassSpread())     return;

   // --- パターンベースSLの基準価格: 買い=2安値の低い方 / 売り=2高値の高い方
   double patternExtreme = (dir == DIR_BUY) ? MathMin(Low[b1],  Low[b2])
                                            : MathMax(High[b1], High[b2]);
   ExecuteEntry(dir, patternExtreme);
}

//====================================================================
// 状態復元(仕様書 §7.2)
//====================================================================

//--- 決済履歴を時系列順に再生してマーチン段数・恒久停止を再構築する
//    戻り値: 履歴から再計算した段数(haltedByHistory に停止判定を返す)
int RebuildLevelFromHistory(bool &haltedByHistory)
{
   haltedByHistory = false;

   // 自EAの決済注文を収集
   int      total = OrdersHistoryTotal();
   datetime closeTimes[];
   double   profits[];
   int      tickets[];
   int      n = 0;
   ArrayResize(closeTimes, total);
   ArrayResize(profits,    total);
   ArrayResize(tickets,    total);

   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != MagicNumber)            continue;
      if(OrderSymbol()      != Symbol())               continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      closeTimes[n] = OrderCloseTime();
      profits[n]    = OrderProfit() + OrderSwap() + OrderCommission();
      tickets[n]    = OrderTicket();
      n++;
   }

   // 決済時刻の昇順にソート(単純挿入ソート。履歴件数は限定的なので十分)
   for(int a = 1; a < n; a++)
   {
      datetime ct = closeTimes[a];
      double   pf = profits[a];
      int      tk = tickets[a];
      int      b  = a - 1;
      while(b >= 0 && closeTimes[b] > ct)
      {
         closeTimes[b + 1] = closeTimes[b];
         profits[b + 1]    = profits[b];
         tickets[b + 1]    = tickets[b];
         b--;
      }
      closeTimes[b + 1] = ct;
      profits[b + 1]    = pf;
      tickets[b + 1]    = tk;
   }

   // 古い順に §4.3 の遷移ルールを再生
   int level = 0;
   for(int s = 0; s < n; s++)
   {
      if(tickets[s] == gIgnoredTicket) continue;   // ECN設定失敗の緊急クローズ(技術的失敗)は集計除外
      if(profits[s] > 0.0)
      {
         level           = 0;              // 勝ち → リセット
         haltedByHistory = false;          // 勝ちが出たら停止判定も解除(ラッチさせない)
      }
      else
      {
         level++;                          // 負け → 段数+1
         if(level > MaxMartingaleSteps)
         {
            if(ResetAfterMaxSteps) level = 0;
            else                   haltedByHistory = true;
         }
      }
   }

   // 最後に集計した決済チケット/時刻を記録(以後の二重集計を防止)
   if(n > 0)
   {
      LastClosedTicket        = tickets[n - 1];
      gLastProcessedCloseTime = closeTimes[n - 1];
   }

   return(level);
}

//--- SL/TP未設定の自EAポジションを発見したら §3.2 のルールで補正する
//    注: パターン情報は再起動後に復元できないため、固定pips(StopLossPips/TakeProfitPips)で補完する
void FixMissingSlTp()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber)           continue;
      if(OrderSymbol()      != Symbol())              continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderStopLoss() > 0.0 && OrderTakeProfit() > 0.0) continue;  // SL/TP設定済み

      double minDist = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
      double slDist  = StopLossPips   * gPipPoint;
      double tpDist  = TakeProfitPips * gPipPoint;
      if(slDist < minDist + Point) slDist = minDist + Point;
      if(tpDist < minDist + Point) tpDist = minDist + Point;

      double op = OrderOpenPrice();
      double sl = (OrderType() == OP_BUY) ? op - slDist : op + slDist;
      double tp = (OrderType() == OP_BUY) ? op + tpDist : op - tpDist;
      sl = NormalizeDouble(sl, Digits);
      tp = NormalizeDouble(tp, Digits);

      // 既に片方だけ設定済みの場合はその値を尊重する
      if(OrderStopLoss()   > 0.0) sl = OrderStopLoss();
      if(OrderTakeProfit() > 0.0) tp = OrderTakeProfit();

      bool ok = false;
      for(int m = 1; m <= 3 && !ok; m++)
      {
         RefreshRates();
         ok = OrderModify(OrderTicket(), op, sl, tp, 0, clrYellow);
         if(!ok)
            Log("SL/TP補正のOrderModify失敗: チケット" + IntegerToString(OrderTicket()) +
                " エラー" + IntegerToString(GetLastError()));
      }
      if(ok)
         Log("SL/TP未設定ポジションを補正: チケット" + IntegerToString(OrderTicket()) +
             " SL=" + DoubleToStr(sl, Digits) + " TP=" + DoubleToStr(tp, Digits));
   }
}

//====================================================================
// イベントハンドラ
//====================================================================

//--- 初期化: pip換算の初期化と状態復元(§7.2)
int OnInit()
{
   // pip換算(§5.7)
   gPipPoint = CalcPipPoint();
   if(gPipPoint <= 0.0)
   {
      Log("Point値が不正のため初期化失敗。");
      return(INIT_FAILED);
   }

   // パラメータの簡易妥当性チェック
   if(BaseLot <= 0.0 || LotMultiplier <= 0.0 || SwingBars < 1 ||
      LookbackBars < MinBarsBetweenBottoms + 2 * SwingBars ||
      MinBarsBetweenBottoms < 1 || MaxBarsBetweenBottoms < MinBarsBetweenBottoms)
   {
      Log("入力パラメータが不正です。設定を見直してください。");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // 勝敗集計から除外するチケット(ECN設定失敗の緊急クローズ)をGVから復元(履歴再生より先に読む)
   if(GlobalVariableCheck(GvName("IGNORE")))
      gIgnoredTicket = (int)GlobalVariableGet(GvName("IGNORE"));

   // (1) 履歴走査によるマーチン段数の再構築
   bool haltedByHistory = false;
   int  histLevel       = RebuildLevelFromHistory(haltedByHistory);

   // (4) GlobalVariables のミラー値と比較し、保守側(大きい段数/停止)を採用
   //     ※ 口座履歴の表示期間設定で履歴が欠ける場合があるため GV を一次情報とする
   int  gvLevel  = 0;
   bool gvHalted = false;
   if(GlobalVariableCheck(GvName("LEVEL")))
      gvLevel = (int)GlobalVariableGet(GvName("LEVEL"));
   if(GlobalVariableCheck(GvName("HALTED")))
      gvHalted = (GlobalVariableGet(GvName("HALTED")) > 0.5);

   MartingaleLevel = (int)MathMax(histLevel, gvLevel);
   TradingHalted   = (haltedByHistory || gvHalted);
   ApplyMaxStepsRule();                              // 復元値が上限超過なら §4.3 を適用

   // (2) オープン注文の引き継ぎ: SL/TP未設定の自ポジションを補正
   int openCount = CountOpenPositions();
   if(openCount > 0)
   {
      Log("既存ポジション" + IntegerToString(openCount) + "件を引き継ぎます(新規シグナルは無視)。");
      FixMissingSlTp();
   }

   // (3) 当日決済損益の再集計と日次停止の復元(§5.6)
   gCurrentDay        = (int)(TimeCurrent() / 86400);
   gTodayClosedProfit = CalcTodayClosedProfit();
   if(MaxDailyLossMoney > 0.0 &&
      gTodayClosedProfit + GetFloatingProfit() <= -MaxDailyLossMoney)
   {
      DailyHalted = true;
      Log("状態復元: 日次損失上限に到達済みのため本日は新規停止します。");
   }

   // 新バー検知の基準を現在バーに設定(次の新バー確定から評価開始)
   // ヒストリー未ロード(Bars==0)時の Time[0] アクセスを回避
   LastBarTime = (Bars > 0) ? Time[0] : 0;

   // 履歴走査の間引き用カウンタを初期化
   gPrevHistoryTotal = OrdersHistoryTotal();
   gPrevOpenCount    = CountOpenPositions();

   SaveState();
   Log("初期化完了: マーチン段数=" + IntegerToString(MartingaleLevel) +
       " 恒久停止=" + (TradingHalted ? "true" : "false") +
       " 日次停止=" + (DailyHalted ? "true" : "false") +
       " PipPoint=" + DoubleToStr(gPipPoint, Digits));
   if(TradingHalted)
      Log("恒久停止状態で復元されています。解除するには、グローバル変数ウィンドウ(F3)で " +
          GvName("HALTED") + " を削除してからEAを再アタッチしてください。");
   return(INIT_SUCCEEDED);
}

//--- 終了処理: 状態を GlobalVariables に保存(§7.2/§8)
void OnDeinit(const int reason)
{
   SaveState();
}

//--- メインループ: 新バー検知 → 決済検知 → フィルタ → 検出 → エントリー(§8)
void OnTick()
{
   // ヒストリー未ロード対策: バーが無い間は Time[0] アクセスを避けて何もしない
   if(Bars < 1) return;

   // --- 毎ティック実行する管理処理 ---
   CheckClosedTrades();       // 決済検知/勝敗集計(マーチン段数の遷移)
   CheckDailyReset();         // 日付変更で日次停止を自動解除
   bool fridayBlock = CheckFridayClose();  // 金曜クローズ(新規停止+全決済)
   CheckDailyStop();          // 日次損失上限チェック

   // --- 新バー検知(§2/§7.4): Time[0] が変化した時のみシグナル評価 ---
   if(Time[0] == LastBarTime) return;
   LastBarTime = Time[0];

   // ヒストリー不足時は検出スキップ(§7.5。エラーにしない)
   if(Bars < LookbackBars + SwingBars + 2) return;

   // --- パターン検出(確定足のみ使用) ---
   int    b1L = 0, b2L = 0, bnL = 0;
   int    b1S = 0, b2S = 0, bnS = 0;
   double neckL = 0.0, neckS = 0.0;
   bool db = DetectDoubleBottom(b1L, b2L, bnL, neckL);
   bool dt = DetectDoubleTop(b1S, b2S, bnS, neckS);

   // 同一新バーでDB・DT両方成立 → 矛盾シグナルとして両方破棄(§2.4)
   if(db && dt)
   {
      Log("同一バーでダブルボトムとダブルトップが同時成立。矛盾シグナルとして両方見送り。");
      return;
   }

   // --- シグナル処理(マーチンのロット増しは、負け決済後の
   //     「新しいDB/DTシグナル確定」であるこの経路のみで発生する) ---
   if(db)      HandleSignal(DIR_BUY,  b1L, b2L, bnL, neckL, fridayBlock);
   else if(dt) HandleSignal(DIR_SELL, b1S, b2S, bnS, neckS, fridayBlock);
}
//+------------------------------------------------------------------+
