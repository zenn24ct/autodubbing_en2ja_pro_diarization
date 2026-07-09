# 英語→日本語 自動吹き替えシステム Pro（話者識別版）

[autodubbing_en2ja_pro](https://github.com/zenn24ct/autodubbing_en2ja_pro) を元に、
**WhisperXによる話者識別（Speaker Diarization）** と **話者交代時の自動音声切り替え** を追加したバージョンです。

開発機は Ubuntu ではなく **Windows（MSI Katana 15 B13VGK / NVIDIA GPU搭載）** を想定しています。

## 元バージョンからの変更点

既存の処理フロー・機能・UIは維持したまま、以下のみを追加しています。

| ファイル | 変更内容 |
|---|---|
| `app/pipeline.py` | 文字起こしを `openai-whisper` → **WhisperX** に置き換え。単語アライメント＋`pyannote.audio`による話者分離を追加し、各セグメントに `speaker` フィールドを付与。文単位マージ (`merge_into_sentences`) は話者交代地点でも区切るよう拡張。`run_pipeline` は話者ID→音声(voice_key)の対応表 (`speaker_voice_map`) を見てセグメントごとにTTS音声を切り替える |
| `app/main.py` | `GET /jobs/{job_id}/speakers`（検出話者一覧）を追加。`POST /jobs/{job_id}/run` に `speaker_voice_map`（JSON文字列）パラメータを追加。既存の `voice` 単体指定は互換維持（フォールバック用） |
| `app/static/edit.html` | 複数話者が検出された場合のみ「話者別ボイス設定」パネルを表示。各行に話者バッジを表示 |
| `app/static/index.html` | 複数話者時は編集画面で設定する旨の案内を追加（UI自体は無改造） |
| `requirements.txt` | `openai-whisper` → `whisperx` に置き換え |
| `.env.example` | `HF_TOKEN` / `WHISPERX_DEVICE` 等を追加 |
| `setup.ps1` / `run.ps1` / `setup_voicevox.ps1` / `start_voicevox.ps1` | Windows(PowerShell)向けに新規追加。既存の `.sh` はUbuntu用としてそのまま残置 |

**話者識別が使えない/HF_TOKEN未設定の場合は自動的に全セグメントが単一話者 (`SPEAKER_00`) 扱いになり、従来どおり単一音声での吹き替えにフォールバックします。**

## Windows (MSI Katana 15 B13VGK) セットアップ

```powershell
git clone https://github.com/zenn24ct/autodubbing_en2ja_pro_diarization.git
cd autodubbing_en2ja_pro_diarization
.\setup.ps1
```

`setup.ps1` が行うこと:
1. ffmpeg / Python の存在確認（無ければ `winget install Gyan.FFmpeg` 等を案内）
2. 仮想環境 `.venv` 作成
3. **CUDA版PyTorch**（NVIDIA GPU搭載機向け）を明示インストール
4. `requirements.txt` インストール（WhisperX含む）
5. `.env` 未作成なら `.env.example` からコピー

続けて VOICEVOX（Windows版）をセットアップ:

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

## Ubuntu で使う場合（従来どおり）

```bash
bash setup.sh
bash setup_voicevox.sh && bash start_voicevox.sh
bash run.sh
```

## 話者別に音声を切り替える手順

1. 動画をアップロードし、文字起こし・翻訳完了を待つ（`HF_TOKEN` が設定されていれば自動で話者識別も実行される）
2. 「翻訳結果を確認・編集」を開く
3. 複数話者が検出されていれば「話者別ボイス設定」パネルが表示されるので、話者ごとに声を選択
4. 「この内容で吹き替え生成」を実行 — セグメントごとに割り当てた声でTTSが生成され、話者交代時に自動で音声が切り替わる

## 将来のリアルタイム翻訳への拡張について

- `speaker_voice_map` はAPIパラメータとして疎結合になっており、バッチ処理前提を崩さずに
  「セグメント単位でTTS音声を選ぶ」ロジックを差し替え可能な形にしてある
- 話者識別結果 (`segments_ja.json` の `speaker` フィールド) はJSONとして永続化されるため、
  将来ストリーミング処理に置き換える際も同じデータ構造をそのまま流用できる
