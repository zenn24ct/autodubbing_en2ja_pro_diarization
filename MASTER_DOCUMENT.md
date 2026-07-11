# 自動吹き替えシステム マスタードキュメント

卒業研究の進捗報告・発表・論文・引き継ぎ用の要点資料。記載はチャットの実績のみを根拠とし、未確認事項は「未確認」と明記する。

- リポジトリ: `https://github.com/zenn24ct/autodubbing_pro_diarization`（public）
- 開発機ローカルパス: `C:\dev\autodubbing_pro_diarization`
- 開発機: MSI Katana 15 B13VGK（NVIDIA GPU 搭載 Windows 機）

---

## 1. システム概要

動画（または音声）を入力すると、**文字起こし → 翻訳 → 口語化整形 → 音声合成 → 動画合成**を自動で行い、
翻訳先言語で吹き替えた動画を生成する Web システム。**英語↔日本語の双方向**に対応する。

特徴：
- **話者識別（Speaker Diarization）** と **話者交代時の音声自動切り替え**。
- **双方向（EN⇄JA）** を 1 システムで切り替え。
- 出力言語で TTS を切り替え（日本語=VOICEVOX、英語=edge-tts）。
- 翻訳結果を **Web で確認・編集** してから吹き替え生成。
- 話者識別や整形が使えなくても止まらない**フォールバック設計**。

元は EN→JA 専用・単一声のシステム（`autodubbing_en2ja_pro`）。そこに「話者識別＋話者別音声切り替え」と
「双方向翻訳」を追加した発展版が本システム。

---

## 2. システム構成

- **フロントエンド**: 素の HTML/CSS/JS（ビルド不要）。`index.html`（入力・設定・進捗・DL）、`edit.html`（翻訳編集・話者別ボイス設定）。
- **バックエンド**: FastAPI（uvicorn）。重い処理はバックグラウンド実行し、進捗を JSON でポーリング。
- **外部**: ffmpeg、VOICEVOX（ローカル :50021）、Google 翻訳、Claude API、edge-tts、yt-dlp。

ディレクトリ（要点）：
```
app/main.py        … API 定義
app/pipeline.py    … 処理本体（文字起こし〜動画合成）
app/static/        … index.html / edit.html
requirements.txt / .env.example
setup / run / setup_voicevox / start_voicevox（.sh=Ubuntu, .ps1=Windows）
```

---

## 3. 使用技術・主要ライブラリ

| 種別 | 名称 | バージョン | 用途 |
|---|---|---|---|
| 言語 | Python | 3.13.5（開発機） | 実行環境 |
| Web | FastAPI / uvicorn | 0.137.2 / 0.49.0 | API・サーバー |
| 音声認識+話者識別 | WhisperX | 3.8.6 | 文字起こし・単語整列・話者分離 |
| 話者分離 | pyannote-audio | 4.0.7 | Diarization（要 HF_TOKEN） |
| DL基盤 | PyTorch (torch/torchaudio) | 2.8.0 + cu128 | WhisperX/pyannote が要求 |
| 翻訳 | deep-translator（Google翻訳） | 1.11.4 | 機械翻訳 |
| 整形 | Anthropic SDK / Claude | 0.109.2 / `claude-haiku-4-5` | 口語化整形（任意） |
| 音声合成 | VOICEVOX ENGINE | 0.25.2 | 日本語 TTS |
| 音声合成 | edge-tts | 7.2.8 | 日本語/英語 TTS |
| 音声処理 | pydub / audioop-lts | 0.25.1 / 0.2.2 | 音声操作（3.13で audioop 補完） |
| 動画取得 | yt-dlp | 2026.6.9 | URL 入力 |
| 動画処理 | ffmpeg / ffprobe | 不明（記載なし） | 抽出・話速調整・合成 |
| GPU | CUDA ドライバ | 12.9（開発機） | GPU 実行 |

- VOICEVOX 話者: female=3 ずんだもん / male=11 玄野武宏 / female2=8 春日部つむぎ / male2=9 雨晴はう
- edge 日本語: Nanami / Keita、英語: Aria(US) / Guy(US) / Sonia(UK) / Ryan(UK)
- Whisper モデル: 既定 large-v3（UI で tiny〜large-v3 選択可）。モデルは初回実行時に自動 DL（large-v3 本体 約 3GB）。

---

## 4. 処理の流れ

```
入力(動画/URL, 方向 en2ja/ja2en)
  → ffmpeg で音声抽出
  → WhisperX で文字起こし
  → 単語アライメント（対応言語のみ）
  → 話者識別 pyannote（HF_TOKEN があれば）
  → 文単位に再セグメント（文末・最大長・話者交代で分割）
  → Google 翻訳
  → Claude 整形（APIキーがあれば・任意）
  → 編集画面で確認/修正・話者別ボイス割り当て
  → TTS 音声合成（日本語=VOICEVOX優先, 英語=edge-tts、尺超過は最大2倍速）
  → ffmpeg で動画合成
  → 出力: 動画 / 音声 / SRT字幕
```

TTS のエンジンは voice_key の `engine:` プレフィックスで選択（`voicevox:...` or `edge:...`）。

---

## 5. 実装済み機能（要点）

1. **ファイル/URL 入力**（mp4, mov, mkv, avi, mp3, wav, m4a 対応）
2. **翻訳方向の切り替え**（EN⇄JA を UI 選択、ジョブに保存し全処理が追従）
3. **WhisperX 文字起こし**（モデルサイズ選択、GPU 想定）
4. **話者識別＋話者別音声切り替え**（複数話者時に話者ごとの声で合成。単一話者は従来通り）
5. **文単位の再セグメント**（WhisperX の粗い区切りを単語タイムスタンプで文単位に分割）
6. **Claude 口語化整形**（任意。キー未設定なら自動スキップ）
7. **翻訳結果の Web 編集**（原文と訳文を並べて修正・削除）
8. **TTS エンジン/声の選択**（VOICEVOX / edge-tts）
9. **話速調整**（尺超過時に最大 2 倍速）
10. **動画・音声・SRT 字幕の生成とダウンロード**
11. **進捗表示**（2 秒間隔ポーリング）
12. **Windows / Ubuntu 両対応スクリプト**

---

## 6. 解決した主な問題（要点）

| 問題 | 原因 | 対処 |
|---|---|---|
| `.ps1` の文字化け・パースエラー | PowerShell 5.1 が BOM 無し UTF-8 を誤読 | UTF-8 BOM を付与 |
| VOICEVOX DL がフリーズ | 進捗描画・IE 解析が遅い | `-UseBasicParsing` + `$ProgressPreference=SilentlyContinue` |
| VOICEVOX 展開失敗 | `.vvppp` 分割配布・形式混同 | 分割結合＋拡張子で厳密選択＋展開先フラット化 |
| whisperx 3.3.1 が無い | 実在しないバージョン | `whisperx==3.8.6` |
| torch が入らない/CPU版になる | Python 3.13 で cu121 廃止・CPU版に上書き | `torch==2.8.0`+`cu128`、requirements の後に force-reinstall |
| pydub の audioop 欠落 | Python 3.13 で標準 audioop 削除 | `audioop-lts` を追加 |
| 話者識別が毎回失敗 | 引数名が `use_auth_token`→`token` に変化 | 両方を試すヘルパーで吸収 |
| Nanami 選択でも VOICEVOX になる | エンジン選択が無視され同一 voice_key に潰れていた | voice_key を `engine:key` 形式に |
| 20秒動画で 1 セグメント | WhisperX は VAD で粗く返し merge が分割できない | 単語タイムスタンプで文単位分割を追加 |
| Claude 401 | `.env` のキーがプレースホルダ | プレースホルダ検出で整形スキップ |

---

## 7. 現在できること / 残課題

**できること（実装済み）**
- EN→JA / JA→EN の吹き替え、方向の切り替え、GUI 操作、動画/音声/字幕の生成。
- 話者識別・話者別音声切り替え、文単位再セグメント、Claude 整形（キー投入時）。
- Windows 実機での起動（`Application startup complete` まで確認）。

**未確認・残課題**
- 完成動画 output.mp4 の生成成功可否（文字起こし〜編集画面までは到達確認済み、それ以降は未確認）。
- 複数話者・文単位再セグメント・ja2en の実機再検証（実装済みだが実動画での確認は未記載）。
- `torch.cuda.is_available()` の最終確認（cu128 導入手順は実施済み、結果は未記載）。
- 日本語入力時のアライメント非対応時のセグメント改善。
- **リアルタイム翻訳**（未実装。`source_lang`/`target_lang`・`speaker_voice_map` を疎結合化し土台のみ用意）。

---

## 8. 引き継ぎ時の重要ポイント

**設計思想**
- 既存パイプラインを壊さず機能追加。話者識別/整形/アライメントが無くても動くフォールバック優先。
- 将来のリアルタイム化を見据え、方向・話者マップを API パラメータ化し、話者情報を JSON で永続化。

**必ず守る注意点**
- `.ps1` は **UTF-8 BOM 付き** で保存。
- PyTorch は **requirements の後に CUDA 版を force-reinstall**（`torch==2.8.0`+`cu128`）。
- Python 3.13 は **audioop-lts 必須**。
- `.env` 変更後は **run を再起動**（環境変数は起動時読み込み）。
- `.env` の `WHISPER_MODEL` は UI 選択を上書きする（UI で選ばせたい場合はコメントアウト）。
- **HF_TOKEN** は pyannote の 2 モデル（speaker-diarization-3.1 / segmentation-3.0）への同意が必要。未同意/未設定は単一話者にフォールバック。
- ブラウザは **`localhost:8000`**（`0.0.0.0` では不可）。HTML 変更後はハードリロード。
- VOICEVOX は別ターミナルで起動しておく（未起動時は edge-tts にフォールバック）。

**次にやるべきこと**
- 実機での end-to-end 通し確認（output.mp4 生成まで）と、複数話者・双方向の動作検証。
