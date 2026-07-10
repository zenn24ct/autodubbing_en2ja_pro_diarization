# 自動吹き替えシステム Pro（EN⇄JA双方向 + 話者識別版）

[autodubbing_en2ja_pro](https://github.com/zenn24ct/autodubbing_en2ja_pro) を元に、
**WhisperXによる話者識別（Speaker Diarization）と話者交代時の自動音声切り替え**、
そして**英語→日本語／日本語→英語の双方向翻訳**に対応させたバージョンです。

開発機は Ubuntu ではなく **Windows（MSI Katana 15 B13VGK / NVIDIA GPU搭載）** を想定しています。

## 元バージョンからの変更点

既存の処理フロー（文字起こし→翻訳→整形→TTS→動画合成）は維持したまま、以下を拡張しています。

| ファイル | 変更内容 |
|---|---|
| `app/pipeline.py` | 文字起こしを `openai-whisper` → **WhisperX** に置き換え、話者分離を追加。`source_lang`/`target_lang` をパラメータ化し、Whisperx言語指定・Google翻訳の方向・Claude整形プロンプトを言語ペアに応じて切り替え。単語アライメントが対応していない言語では自動的に話者オーバーラップ判定にフォールバック |
| `app/main.py` | アップロード時に `direction`（`en2ja` / `ja2en`）を受け取り `direction.json` に保存。`GET /jobs/{id}/direction`・`GET /jobs/{id}/segments_source`・`GET /jobs/{id}/speakers` を追加 |
| `app/static/index.html` | 翻訳方向セレクタを追加。方向に応じてボイス選択肢（VOICEVOX日本語話者 or edge-tts英語ボイス）を動的に切り替え |
| `app/static/edit.html` | 話者別ボイス設定パネルのラベルも方向に応じて切り替え。原文セグメント参照は `segments_source` に統一 |
| `requirements.txt` | `openai-whisper` → `whisperx` に置き換え |
| `.env.example` | `HF_TOKEN` / `WHISPERX_DEVICE` 等を追加 |
| `setup.ps1` / `run.ps1` / `setup_voicevox.ps1` / `start_voicevox.ps1` | Windows(PowerShell)向けに追加。既存の `.sh` はUbuntu用としてそのまま残置 |

**TTSエンジンは出力言語で非対称です。** VOICEVOXは日本語専用のため、
- **EN→JA**（日本語出力）: VOICEVOX優先、失敗時はedge-tts日本語ボイスにフォールバック
- **JA→EN**（英語出力）: edge-ttsの英語ボイス（Aria/Guy/Sonia/Ryan）を直接使用

話者ごとの声を選ぶ `voice_key`（`female`/`male`/`female2`/`male2`）自体は方向に関わらず共通のキー体系で、
出力言語によって参照する音声辞書（`VOICEVOX_SPEAKERS`+`EDGE_VOICES_JA` または `EDGE_VOICES_EN`）が切り替わるだけです。

**話者識別が使えない/HF_TOKEN未設定の場合は自動的に全セグメントが単一話者 (`SPEAKER_00`) 扱いになり、単一音声での吹き替えにフォールバックします。**

## Windows (MSI Katana 15 B13VGK) セットアップ

```powershell
git clone https://github.com/zenn24ct/autodubbing_pro_diarization.git
cd autodubbing_pro_diarization
.\setup.ps1
```

`setup.ps1` が行うこと:
1. ffmpeg / Python の存在確認（無ければ `winget install Gyan.FFmpeg` 等を案内）
2. 仮想環境 `.venv` 作成
3. **CUDA版PyTorch**（NVIDIA GPU搭載機向け）を明示インストール
4. `requirements.txt` インストール（WhisperX含む）
5. `.env` 未作成なら `.env.example` からコピー
6. 各pipコマンドの終了コードを確認し、失敗時は即座にエラー終了（黙って進行しない）

続けて VOICEVOX（Windows版）をセットアップ（JA出力を使う場合。EN出力のみならVOICEVOXは不要）:

```powershell
.\setup_voicevox.ps1
.\start_voicevox.ps1
```

`.env` に以下を設定してください:
- `HF_TOKEN` — 話者識別（pyannote.audio）に必須。取得手順は `.env.example` 内のコメント参照
- `ANTHROPIC_API_KEY` — 口語化整形用（任意、無くてもGoogle翻訳のみで動作）

起動:

```powershell
.\run.ps1
```

`http://localhost:8000` にアクセス。

## Ubuntu で使う場合

```bash
bash setup.sh
bash setup_voicevox.sh && bash start_voicevox.sh   # JA出力を使う場合のみ
bash run.sh
```

## 使い方

1. トップ画面で「翻訳方向」（英語→日本語 / 日本語→英語）を選び、動画/音声をアップロード
2. 文字起こし・話者識別・翻訳・整形の完了を待つ（`HF_TOKEN` が設定されていれば自動で話者識別も実行される）
3. 「翻訳結果を確認・編集」を開く
4. 複数話者が検出されていれば「話者別ボイス設定」パネルが表示されるので、話者ごとに声を選択（選択肢は選んだ翻訳方向に応じて自動的にVOICEVOX話者 or 英語edge-ttsボイスに切り替わる）
5. 「この内容で吹き替え生成」を実行 — セグメントごとに割り当てた声でTTSが生成され、話者交代時に自動で音声が切り替わる

## 将来のリアルタイム翻訳への拡張について

- `speaker_voice_map` と `source_lang`/`target_lang` はAPIパラメータとして疎結合になっており、
  バッチ処理前提を崩さずに「セグメント単位で言語・TTS音声を選ぶ」ロジックを差し替え可能な形にしてある
- 話者識別結果 (`segments_source.json` の `speaker` フィールド) はJSONとして永続化されるため、
  将来ストリーミング処理に置き換える際も同じデータ構造をそのまま流用できる
