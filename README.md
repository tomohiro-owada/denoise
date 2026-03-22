# Denoise

macOS用リアルタイム音声処理アプリ。マイク入力にノイズ除去・イコライザー・コンプレッサーなどをかけて、仮想オーディオデバイス経由で Zoom / Google Meet / QuickTime 等に「処理済みマイク」として提供します。

メニューバー常駐アプリ + CLI で操作可能。OSSのみで構成。

## 音声処理パイプライン

```
マイク → DeClicker → NoiseGate → RNNoise → リングバッファ → EQ → Compressor → 仮想デバイス
         クリック除去   無音カット    ML           (スレッド間)     3バンド  ダイナミクス    ↓
         (突発音)      (閾値以下)   ノイズ除去                    イコライザ +5dBゲイン   Zoom等が読み取り
```

## 必要なもの

- macOS 14 以上
- 仮想オーディオデバイス: `brew install blackhole-2ch`
- インストール後に **OS再起動**

## ビルド

```bash
swift build
```

2つのバイナリが生成されます:

| バイナリ | 説明 |
|---------|------|
| `.build/debug/DenoiseApp` | メニューバー常駐アプリ |
| `.build/debug/denoise` | CLIツール |

## セットアップ

1. 仮想オーディオデバイスをインストール
   ```bash
   brew install blackhole-2ch
   ```
2. **OS を再起動**
3. アプリを起動
   ```bash
   .build/debug/DenoiseApp
   ```
4. Zoom / Meet / QuickTime の入力デバイスに **「BlackHole 2ch」** を選択
5. **重要**: macOS のシステム設定 → サウンド → 入力 は **実際のマイク** のままにすること（BlackHole/Denoise を選ぶとフィードバックループになります）

## メニューバーアプリ

メニューバーのアイコンをクリックするとポップオーバーが開きます:

- **Processing トグル** — 音声処理の ON/OFF
- **Monitor トグル** — スピーカーから処理済みの音を確認（遅延付き、テスト用）
- **Delay スライダー** — モニター時の遅延秒数（0〜10秒）
- **Input Device** — 入力マイク選択
- **各エフェクトの設定** — Noise Gate / EQ / Compressor / RNNoise
- **Reset** — 全パラメータを初期値に戻す
- **Save Default** — 現在の設定をプリセットとして保存
- **Set Default** — 保存したプリセットを呼び出し

## CLI の使い方

CLI はメニューバーアプリと Unix ドメインソケット (`/tmp/denoise.sock`) で通信します。**アプリが起動している必要があります。**

### コマンド一覧

```bash
denoise                  # 現在の状態を表示（デフォルト）
denoise start            # 処理開始（マイク → 仮想デバイス）
denoise stop             # 処理停止
denoise monitor          # モニターモード（スピーカーに遅延出力、テスト用）
denoise status           # 全設定を JSON で表示
denoise devices          # 利用可能なマイク一覧
denoise devices --json   # JSON で一覧出力
denoise install          # 仮想オーディオデバイスのインストール状況
denoise install --json   # JSON で出力
denoise config KEY VALUE # 設定値を変更（即時反映・永続化）
denoise schema           # CLI の全仕様を JSON で出力（AI エージェント向け）
```

### 設定キー

設定変更は**即座に反映**され、アプリ再起動後も保持されます。

| キー | 型 | デフォルト | 範囲 | 説明 |
|------|------|-----------|------|------|
| `declicker-enabled` | bool | `true` | `true`/`false` | クリック・ポップ音の除去 |
| `declicker-sensitivity` | float | `4.0` | 1.0〜10.0 | 感度（高い＝より積極的に検出） |
| `noise-gate-enabled` | bool | `true` | `true`/`false` | ノイズゲート |
| `noise-gate-threshold` | float | `-45.0` | -90.0〜0.0 (dB) | この音量以下をカット |
| `eq-enabled` | bool | `true` | `true`/`false` | 3バンドイコライザー |
| `eq-low` | float | `0.0` | -12.0〜12.0 (dB) | 低音ゲイン（200 Hz） |
| `eq-mid` | float | `0.0` | -12.0〜12.0 (dB) | 中音ゲイン（1 kHz） |
| `eq-high` | float | `0.0` | -12.0〜12.0 (dB) | 高音ゲイン（4 kHz） |
| `compressor-enabled` | bool | `true` | `true`/`false` | ダイナミクスコンプレッサー |
| `compressor-threshold` | float | `-20.0` | -60.0〜0.0 (dB) | 圧縮開始レベル |
| `compressor-ratio` | float | `4.0` | 1.0〜20.0 | 圧縮比（高い＝より強く圧縮） |
| `rnnoise-enabled` | bool | `true` | `true`/`false` | MLベースのノイズ除去 |

### 設定例

```bash
# 基本操作
denoise start                              # 処理開始
denoise stop                               # 処理停止

# モニターモードで確認（ヘッドフォン推奨、スピーカーだとハウリングする）
denoise monitor

# ノイズゲートの閾値調整（負の値は -- を前につける）
denoise config -- noise-gate-threshold -35

# 低音をブースト
denoise config eq-low 6

# 強めのコンプレッサーで音量を均一に
denoise config -- compressor-threshold -30
denoise config compressor-ratio 8

# RNNoise が効きすぎる場合はオフに
denoise config rnnoise-enabled false

# 現在の設定を確認
denoise status
```

### ステータス出力例

```json
{
  "isRunning": true,
  "isMonitorMode": false,
  "deClicker": { "enabled": true, "sensitivity": 4.0 },
  "noiseGate": { "enabled": true, "threshold": -45.0 },
  "eq": { "enabled": true, "lowGain": 0, "midGain": 0, "highGain": 0 },
  "compressor": { "enabled": true, "threshold": -20, "ratio": 4 },
  "rnnoise": { "enabled": true },
  "monitorDelay": 1.0
}
```

## AI エージェント連携

AI エージェントからの操作に対応しています。

```bash
# 仕様をJSON で取得（コマンド・設定キーの型・デフォルト・範囲を含む）
denoise schema

# デバイス一覧をJSON で取得
denoise devices --json

# 状態をJSON で確認
denoise status
```

詳細は [AGENTS.md](AGENTS.md) を参照してください。

## アーキテクチャ

```
denoise/
├── Sources/
│   ├── CRNNoise/          # RNNoise C ライブラリ（静的リンク）
│   ├── DenoiseCore/       # 音声処理ロジック
│   │   ├── AudioProcessor   # メインパイプライン（2エンジン構成）
│   │   ├── DeClicker        # クリック除去（突発音検出＋補間）
│   │   ├── NoiseGate        # ノイズゲート（エンベロープ追従）
│   │   ├── RNNoiseWrapper   # RNNoise C ライブラリのSwiftラッパー
│   │   └── VirtualDeviceInstaller  # 仮想デバイスの検出・管理
│   ├── DenoiseApp/        # SwiftUI メニューバーアプリ + IPC サーバー
│   └── DenoiseCLI/        # CLI ツール（ArgumentParser）
├── Resources/             # アプリアイコン
├── AGENTS.md              # AI エージェント向けガイド
└── README.md
```

### 2エンジン設計

| エンジン | 役割 |
|---------|------|
| **inputEngine** | ハードウェアマイクからキャプチャ → DSP 処理 (DeClicker → NoiseGate → RNNoise) → リングバッファに書き込み |
| **outputEngine** | リングバッファから読み出し → EQ → Compressor (Apple AudioUnit) → 仮想オーディオデバイスに出力 |

スレッド安全なリングバッファで2つのエンジンを接続。入力エンジンの出力はミュートされるため、スピーカーへの音漏れはありません。

## 使用技術

| 技術 | 用途 | ライセンス |
|------|------|-----------|
| Swift / SwiftUI | アプリ本体 | — |
| AVAudioEngine | オーディオキャプチャ・ルーティング | — |
| AVAudioUnitEQ | 3バンドイコライザー | — |
| kAudioUnitSubType_DynamicsProcessor | コンプレッサー | — |
| [RNNoise](https://github.com/xiph/rnnoise) | MLベースノイズ除去 | BSD-3-Clause |
| [BlackHole](https://github.com/ExistentialAudio/BlackHole) | 仮想オーディオデバイス（別途インストール） | GPL-3.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI フレームワーク | Apache-2.0 |

## ライセンス

- プロジェクトコード: MIT（予定）
- RNNoise: BSD-3-Clause（xiph.org）
- BlackHole: GPL-3.0（同梱せず、別途インストール）
