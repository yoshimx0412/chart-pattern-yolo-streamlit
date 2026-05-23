# Chart Pattern Detection App

YOLOv8 と Streamlit を使った、チャートパターン検出アプリです。  
OBS Studio によるデスクトップ画面入力、または動画ファイルを入力し、Double Bottom / Double Top のパターンをリアルタイムに検出します。

## Features

- YOLOv8 によるリアルタイム物体検出
- Streamlit による Web UI
- OBS Studio 経由のデスクトップ画面入力に対応
- 動画ファイル入力に対応
- 検出クラス、信頼度、IoU、FPS、解像度を画面上で調整可能
- 任意位置の境界線を超えた検出イベントを画面内に表示

## Tech Stack

- Python
- Streamlit
- Ultralytics YOLOv8
- OpenCV
- PyTorch
- OBS Studio
- MT4 / MT5

## Model

同梱している `weights/best.pt` は、チャートパターン検出用のカスタム YOLO モデルです。

検出クラス:

- `DB`: Double Bottom
- `DT`: Double Top

## How to Run

```bash
conda create -n ob2-yolo python=3.12 -y
conda run -n ob2-yolo pip install -r requirements.txt
conda run -n ob2-yolo streamlit run app.py
```

起動後、ブラウザで以下を開きます。

```text
http://localhost:8501
```

## Usage

### 1. OBS Studio と MT4 / MT5 を起動する

OBS Studio を起動し、MT4 または MT5 のチャート画面をデスクトップ入力として取得できる状態にします。

MT4 / MT5 側では、検出しやすいチャート表示にするため、以下の設定を行います。

#### MT4 / MT5 のチャート設定

1. MT4 または MT5 を起動します。
2. 対象のチャートを開きます。
3. チャートプロパティを開き、背景色を白に変更します。
4. チャート表示をラインチャートに変更します。
5. ラインチャートの線色を白に変更します。
6. インディケータを追加します。
7. 移動平均線を追加し、以下のように設定します。

| 項目 | 設定 |
|---|---|
| インディケータ | Moving Average |
| 種類 | EMA |
| 期間 | 2 |
| 線色 | 黒 |

この設定により、白背景上に黒色の EMA ラインが表示され、YOLO モデルがチャートパターンを検出しやすくなります。

### 2. OBS Studio で画面入力を設定する

OBS Studio 側で、MT4 / MT5 の画面を入力ソースとして設定します。

例:

- 画面キャプチャ
- ウィンドウキャプチャ
- デスクトップキャプチャ

必要に応じて、OBS Studio の仮想カメラを開始します。

### 3. Streamlit アプリで入力ソースを選択する

Streamlit アプリを起動後、サイドバーで `Video Source` を選択します。

- OBS Studio 経由でデスクトップ画面を入力する場合は、カメラ入力を選択します。
- 動画ファイルを使う場合は `Video File` を選択し、mp4 などの動画をアップロードします。

### 4. モデルを選択する

`Model` は通常、以下を選択します。

```text
best.pt (custom chart pattern model)
```

### 5. 推論条件を調整する

必要に応じて、以下のパラメータを調整します。

- Confidence Threshold
- IoU Threshold
- Boundary Line Position
- FPS
- Resolution

### 6. 検出を開始する

`Start` を押すと、チャートパターン検出が開始されます。

画面上に Double Bottom / Double Top の検出結果、信頼度、境界線判定イベントなどが表示されます。

## Portfolio Points

このプロジェクトでは、独自学習した YOLO モデルを Streamlit アプリとして実装し、OBS Studio 経由のリアルタイム画面入力、動画ファイル入力、UI からの推論パラメータ調整、検出イベント判定までを一つのアプリにまとめています。

特に、MT4 / MT5 のチャート画面を OBS Studio で取り込み、リアルタイムにチャートパターンを検出できる点が特徴です。

## Notes

元実装に含まれていた LINE Notify は 2025 年 3 月 31 日にサービス終了しているため、この公開版では外部通知ではなく画面内の検出イベント表示に変更しています。

本アプリは、チャートパターン検出の技術検証およびポートフォリオ用途を目的としたものです。投資判断や売買を保証するものではありません。