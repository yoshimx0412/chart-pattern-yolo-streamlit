# Chart Pattern Detection App

YOLOv8 と Streamlit を使った、チャートパターン検出アプリです。カメラ映像または動画ファイルを入力し、Double Bottom / Double Top のパターンをリアルタイムに検出します。

## Features

- YOLOv8 によるリアルタイム物体検出
- Streamlit による Web UI
- カメラ入力と動画ファイル入力に対応
- 検出クラス、信頼度、IoU、FPS、解像度を画面上で調整可能
- 任意位置の境界線を超えた検出イベントを画面内に表示

## Tech Stack

- Python
- Streamlit
- Ultralytics YOLOv8
- OpenCV
- PyTorch

## Model

同梱している `weights/best.pt` は、チャートパターン検出用のカスタム YOLO モデルです。

検出クラス:

- `DB`: Double Bottom
- `DT`: Double Top

## How to Run

```powershell
conda create -n ob2-yolo python=3.12 -y
conda run -n ob2-yolo pip install -r requirements.txt
conda run -n ob2-yolo streamlit run app.py
```

起動後、ブラウザで `http://localhost:8501` を開きます。

## Usage

1. サイドバーで `Video Source` を選択します。
2. 動画ファイルを使う場合は `Video File` を選択し、`mp4` などの動画をアップロードします。
3. `Model` は通常 `best.pt (custom chart pattern model)` を選択します。
4. 必要に応じて `Confidence Threshold`、`IoU Threshold`、`Boundary Line Position` を調整します。
5. `Start` を押すと検出が開始されます。

## Portfolio Points

このプロジェクトでは、独自学習した YOLO モデルを Streamlit アプリとして実装し、リアルタイム映像処理、UI からの推論パラメータ調整、検出イベント判定までを一つのアプリにまとめています。

## Notes

元実装に含まれていた LINE Notify は 2025 年 3 月 31 日にサービス終了しているため、この公開版では外部通知ではなく画面内の検出イベント表示に変更しています。
