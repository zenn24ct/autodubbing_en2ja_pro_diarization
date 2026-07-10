"""
処理パイプライン — 自動吹き替え Pro（EN⇄JA双方向 + 話者識別対応版）

STEP 1: 音声抽出 + WhisperX 文字起こし(source_lang) + 話者識別 → segments_source.json（speakerフィールド付き）
STEP 2: Google翻訳(source_lang→target_lang) → 翻訳テキスト
STEP 3: Claude API で口語化・整形（APIキーがあれば実行、target_langに応じたプロンプト）→ segments_translated.json
STEP 4: 音声生成（話者IDごとに音声切り替え。JA出力=VOICEVOX優先/edge-ttsフォールバック、EN出力=edge-tts）+ 話速調整（最大2倍速）
STEP 5: 動画に音声を合成 → output.mp4
STEP 6: SRT 字幕ファイル生成 → subtitle.srt
"""

import asyncio
import json
import os
import subprocess
import tempfile
from pathlib import Path

import edge_tts
import whisperx
from deep_translator import GoogleTranslator
from pydub import AudioSegment

JOBS_DIR = Path("jobs")

# ── VOICEVOX 設定 ────────────────────────────────────────────────────
VOICEVOX_URL = os.environ.get("VOICEVOX_URL", "http://localhost:50021")
VOICEVOX_SPEAKERS = {
    "female":  int(os.environ.get("VOICEVOX_SPEAKER_FEMALE", "3")),   # ずんだもん
    "male":    int(os.environ.get("VOICEVOX_SPEAKER_MALE",   "11")),  # 玄野武宏
    "female2": 8,   # 春日部つむぎ
    "male2":   9,   # 雨晴はう
}

# edge-tts 日本語ボイス（VOICEVOXが使えない場合のフォールバック）
EDGE_VOICES_JA = {
    "female":  "ja-JP-NanamiNeural",
    "male":    "ja-JP-KeitaNeural",
}

# edge-tts 英語ボイス（EN出力時はVOICEVOXが使えないためこちらを直接使用）
EDGE_VOICES_EN = {
    "female":  "en-US-AriaNeural",
    "male":    "en-US-GuyNeural",
    "female2": "en-GB-SoniaNeural",
    "male2":   "en-GB-RyanNeural",
}

# 速度調整の上限（2.0倍まで許容）
MAX_SPEED = 2.0

# ── WhisperX / 話者識別 設定 ──────────────────────────────────────────
# device: "cuda"（NVIDIA GPU搭載機・推奨） / "cpu"
WHISPERX_DEVICE = os.environ.get("WHISPERX_DEVICE", "cuda")
# compute_type: cudaなら float16、cpuなら int8 が標準
WHISPERX_COMPUTE_TYPE = os.environ.get(
    "WHISPERX_COMPUTE_TYPE", "float16" if WHISPERX_DEVICE == "cuda" else "int8"
)
WHISPERX_BATCH_SIZE = int(os.environ.get("WHISPERX_BATCH_SIZE", "16"))

# pyannote.audio の話者分離モデル（gated repo）に必要
# https://huggingface.co/settings/tokens で発行し、
# pyannote/speaker-diarization-3.1 の利用規約に同意しておくこと
HF_TOKEN = os.environ.get("HF_TOKEN", "").strip()

# 話者数のヒント（分かっていれば精度が上がる。空なら自動推定）
DIARIZATION_MIN_SPEAKERS = os.environ.get("DIARIZATION_MIN_SPEAKERS", "").strip()
DIARIZATION_MAX_SPEAKERS = os.environ.get("DIARIZATION_MAX_SPEAKERS", "").strip()

DEFAULT_SPEAKER = "SPEAKER_00"

# 話者が複数検出された場合、未割り当ての話者に順番に割り当てるデフォルト音声
SPEAKER_VOICE_ROTATION = ["female", "male", "female2", "male2"]


# ── ステータス管理 ────────────────────────────────────────────────────
def update_status(job_id: str, status: str, progress: int, message: str) -> None:
    path = JOBS_DIR / job_id / "status.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(
            {"status": status, "progress": progress, "message": message},
            f, ensure_ascii=False,
        )
    print(f"[{job_id}] [{progress:3d}%] {message}")


# ── 音声抽出 ─────────────────────────────────────────────────────────
def extract_audio(input_path: str, audio_path: str) -> None:
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", input_path,
         "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", audio_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"音声抽出エラー: {result.stderr[-500:]}")


# ── 動画の長さ取得 ────────────────────────────────────────────────────
def get_duration(file_path: str) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", file_path],
        capture_output=True, text=True, check=True,
    )
    return float(json.loads(result.stdout)["format"]["duration"])


# ── セグメント統合（文単位） ──────────────────────────────────────────
_SENTENCE_FINAL = frozenset('.!?…')
_MAX_SEG_SEC    = 15.0


def merge_into_sentences(segments: list[dict]) -> list[dict]:
    """文単位にマージする。話者(speaker)が変わった箇所では、文の途中でも
    必ず区切る — 話者交代時に音声を正しく切り替えるための境界を保つ。"""
    if not segments:
        return segments

    merged: list[dict] = []
    buf_text    = ""
    buf_start   = segments[0]["start"]
    buf_end     = segments[0]["end"]
    buf_speaker = segments[0].get("speaker", DEFAULT_SPEAKER)

    for seg in segments:
        text = seg["text"].strip()
        if not text:
            continue
        speaker = seg.get("speaker", buf_speaker)

        # 話者交代 → それまでのバッファを文の途中でも確定する
        if buf_text and speaker != buf_speaker:
            merged.append({
                "start": round(buf_start, 2),
                "end":   round(buf_end,   2),
                "text":  buf_text.strip(),
                "speaker": buf_speaker,
            })
            buf_text = ""

        if not buf_text:
            buf_start   = seg["start"]
            buf_speaker = speaker
        buf_text += (" " if buf_text else "") + text
        buf_end   = seg["end"]

        ends_sentence = buf_text.rstrip()[-1:] in _SENTENCE_FINAL if buf_text.rstrip() else False
        too_long      = (buf_end - buf_start) >= _MAX_SEG_SEC

        if ends_sentence or too_long:
            merged.append({
                "start": round(buf_start, 2),
                "end":   round(buf_end,   2),
                "text":  buf_text.strip(),
                "speaker": buf_speaker,
            })
            buf_text = ""

    if buf_text.strip():
        merged.append({
            "start": round(buf_start, 2),
            "end":   round(buf_end,   2),
            "text":  buf_text.strip(),
            "speaker": buf_speaker,
        })
    return merged


# ── STEP 1: WhisperX 文字起こし + 話者識別 ────────────────────────────
def _assign_segment_speakers(result: dict) -> list[dict]:
    """WhisperXのalign結果(単語ごとにspeakerが付く)から、セグメント単位の
    speakerを決定する。セグメント内で最頻出のspeakerを採用する。"""
    segments = []
    for seg in result["segments"]:
        words = seg.get("words", [])
        speakers = [w["speaker"] for w in words if w.get("speaker")]
        if speakers:
            speaker = max(set(speakers), key=speakers.count)
        else:
            speaker = seg.get("speaker", DEFAULT_SPEAKER)
        segments.append({
            "start": round(seg["start"], 2),
            "end":   round(seg["end"], 2),
            "text":  seg["text"].strip(),
            "speaker": speaker,
        })
    return segments


def _assign_speaker_by_overlap(seg_start: float, seg_end: float, diarize_df) -> str:
    """単語アライメントが無い場合のフォールバック: セグメントの時間範囲と
    最も重なりが大きい話者区間(diarize_dfの行)のspeakerを採用する。"""
    best_speaker, best_overlap = DEFAULT_SPEAKER, 0.0
    for _, row in diarize_df.iterrows():
        overlap = min(seg_end, row["end"]) - max(seg_start, row["start"])
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = row["speaker"]
    return best_speaker


def run_transcription(
    job_id: str, input_path: str, model_size: str = "large-v3",
    source_lang: str = "en", target_lang: str = "ja",
) -> None:
    try:
        update_status(job_id, "transcribing", 5, "音声を抽出中...")

        with tempfile.TemporaryDirectory() as tmpdir:
            audio_wav = os.path.join(tmpdir, "audio.wav")
            extract_audio(input_path, audio_wav)

            model_size = os.environ.get("WHISPER_MODEL", model_size)
            update_status(job_id, "transcribing", 10,
                          f"WhisperX ({model_size}) で{source_lang}を文字起こし中...（数分かかります）")

            model = whisperx.load_model(
                model_size, WHISPERX_DEVICE, compute_type=WHISPERX_COMPUTE_TYPE,
                language=source_lang,
            )
            audio = whisperx.load_audio(audio_wav)
            result = model.transcribe(audio, batch_size=WHISPERX_BATCH_SIZE, language=source_lang)

            # 単語アライメントは言語ごとに専用モデルが必要で、言語によっては
            # 用意されていないことがある。失敗してもセグメント単位の文字起こし
            # 自体は活かし、話者識別だけ精度を落として続行する。
            aligned = False
            try:
                update_status(job_id, "transcribing", 25, "単語単位でタイムスタンプを整列中...")
                align_model, align_metadata = whisperx.load_align_model(
                    language_code=source_lang, device=WHISPERX_DEVICE,
                )
                result = whisperx.align(
                    result["segments"], align_model, align_metadata, audio, WHISPERX_DEVICE,
                    return_char_alignments=False,
                )
                del align_model
                aligned = True
            except Exception as e:
                print(f"[WhisperX] 言語'{source_lang}'の単語アライメントに失敗したためスキップします: {e}")

            diarize_df = None
            if HF_TOKEN:
                try:
                    update_status(job_id, "transcribing", 35, "話者を識別中（WhisperX diarization）...")
                    diarize_kwargs = {}
                    if DIARIZATION_MIN_SPEAKERS:
                        diarize_kwargs["min_speakers"] = int(DIARIZATION_MIN_SPEAKERS)
                    if DIARIZATION_MAX_SPEAKERS:
                        diarize_kwargs["max_speakers"] = int(DIARIZATION_MAX_SPEAKERS)

                    diarize_model = whisperx.diarize.DiarizationPipeline(
                        use_auth_token=HF_TOKEN, device=WHISPERX_DEVICE,
                    )
                    diarize_df = diarize_model(audio, **diarize_kwargs)
                    if aligned:
                        result = whisperx.assign_word_speakers(diarize_df, result)
                except Exception as e:
                    print(f"[WhisperX] 話者識別に失敗しました（単一話者として扱います）: {e}")
                    diarize_df = None
            else:
                print("[WhisperX] HF_TOKEN未設定のため話者識別をスキップ（単一話者として扱います）")

        if aligned:
            raw_segments = [s for s in _assign_segment_speakers(result) if s["text"]]
        else:
            raw_segments = [
                {
                    "start": round(s["start"], 2),
                    "end":   round(s["end"], 2),
                    "text":  s["text"].strip(),
                    "speaker": (
                        _assign_speaker_by_overlap(s["start"], s["end"], diarize_df)
                        if diarize_df is not None else DEFAULT_SPEAKER
                    ),
                }
                for s in result["segments"] if s["text"].strip()
            ]

        segments = merge_into_sentences(raw_segments)

        with open(JOBS_DIR / job_id / "segments_source.json", "w", encoding="utf-8") as f:
            json.dump(segments, f, ensure_ascii=False, indent=2)

        update_status(job_id, "translating", 50,
                      f"文字起こし完了（{len(segments)} セグメント）。翻訳・整形中...")

        # STEP2+3: 翻訳 → 口語化整形
        translated_segments = translate_and_refine(job_id, segments, source_lang, target_lang)

        with open(JOBS_DIR / job_id / "segments_translated.json", "w", encoding="utf-8") as f:
            json.dump(translated_segments, f, ensure_ascii=False, indent=2)

        update_status(job_id, "ready_to_edit", 100,
                      f"翻訳・整形完了（{len(translated_segments)} セグメント）。編集・確認できます。")

    except Exception as e:
        update_status(job_id, "error", 0, f"文字起こしエラー: {e}")
        raise


# ── STEP 2: Google翻訳 ───────────────────────────────────────────────
def translate_text_google(text: str, source_lang: str, target_lang: str) -> str:
    try:
        return GoogleTranslator(source=source_lang, target=target_lang).translate(text)
    except Exception as e:
        print(f"[Google翻訳エラー] {e}")
        return text


# ── STEP 3: Claude API で口語化・整形 ────────────────────────────────
# target_langごとの整形プロンプト。出力先の話し言葉として自然になるよう
# ルールを言語別に用意する（日本語と英語では「口語化」の勘所が違うため）。
_REFINE_PROMPTS = {
    "ja": (
        "以下は動画の音声を日本語に機械翻訳したセグメントのリストです（JSON配列）。\n"
        "各セグメントには duration（秒）と text（翻訳文）があります。\n\n"
        "以下のルールで日本語を吹き替え音声用に整形してください：\n"
        "1. 口語体・話し言葉に変換する（「〜しています」→「〜してます」など）\n"
        "2. duration 秒以内に読み切れる長さに収める（目安: 1秒あたり7〜8文字）\n"
        "3. 意味は保ちつつ簡潔に。省略より言い換えを優先する\n"
        "4. 不自然な直訳表現を自然な日本語に直す\n"
        "5. 疑問文・感嘆文は口語的に\n\n"
        "出力は同じ構造のJSON配列で、textフィールドのみ変更してください。\n"
        "他の説明は不要です。\n\n"
    ),
    "en": (
        "Below is a list of segments machine-translated into English from a video's "
        "audio (JSON array). Each segment has duration (seconds) and text (the translated line).\n\n"
        "Rewrite the English text for a spoken dubbing track, following these rules:\n"
        "1. Use natural, conversational spoken English (contractions like \"I'm\", \"don't\", etc.)\n"
        "2. Keep it short enough to read aloud within duration seconds (rough guide: ~2.5-3 words/sec)\n"
        "3. Preserve meaning but prefer paraphrasing over omission when shortening\n"
        "4. Fix awkward literal-translation phrasing into natural spoken English\n"
        "5. Keep questions/exclamations conversational in tone\n\n"
        "Output the same JSON array structure, changing only the text field.\n"
        "No other explanation needed.\n\n"
    ),
}


def refine_segments_claude(segments: list[dict], api_key: str, target_lang: str) -> list[dict]:
    """
    翻訳後のテキストを吹き替え用に口語整形する。
    ・直訳を口語体に変換
    ・尺に収まるよう簡潔に短縮（省略ではなく言い換え）
    ・自然な話し言葉に統一
    APIキーがない場合は呼ばれない。
    """
    import anthropic
    client = anthropic.Anthropic(api_key=api_key)

    prompt_header = _REFINE_PROMPTS.get(target_lang, _REFINE_PROMPTS["ja"])

    refined = []
    total = len(segments)

    # まとめてAPIに送ることでコストを下げる（最大20セグメントずつ）
    batch_size = 20
    for batch_start in range(0, total, batch_size):
        batch = segments[batch_start:batch_start + batch_size]

        items = [
            {
                "id": i + batch_start,
                "duration": round(seg["end"] - seg["start"], 2),
                "text": seg["text"],
            }
            for i, seg in enumerate(batch)
        ]

        prompt = prompt_header + f"{json.dumps(items, ensure_ascii=False)}"

        try:
            response = client.messages.create(
                model="claude-haiku-4-5",  # 安価なモデルで十分
                max_tokens=2048,
                messages=[{"role": "user", "content": prompt}],
            )
            # Claudeはmarkdownコードブロックで返す場合があるので除去
            raw = response.content[0].text.strip()
            print(f"[Claude整形 応答先頭] {raw[:100]}")
            if raw.startswith("```"):
                lines = raw.split("\n")
                lines = [l for l in lines if not l.strip().startswith("```")]
                raw = "\n".join(lines).strip()
            result_items = json.loads(raw)
            refined_map = {item["id"]: item["text"] for item in result_items}

            for i, seg in enumerate(batch):
                seg_id = i + batch_start
                refined_text = refined_map.get(seg_id, seg["text"])
                print(f"[整形済み seg{seg_id}] {refined_text[:40]}")
                refined.append({**seg, "text": refined_text})

        except Exception as e:
            print(f"[Claude整形エラー (batch {batch_start})] {e}")
            import traceback; traceback.print_exc()
            refined.extend(batch)

    return refined


def translate_and_refine(
    job_id: str, segments: list[dict], source_lang: str = "en", target_lang: str = "ja",
) -> list[dict]:
    """Google翻訳 → Claude整形（APIキーがあれば）の2ステップ処理。"""
    total = len(segments)
    translated_segments = []

    # STEP2: Google翻訳
    for i, seg in enumerate(segments):
        src_text = seg["text"].strip()
        translated_text = (
            translate_text_google(src_text, source_lang, target_lang) if src_text else ""
        )
        translated_segments.append({
            "start": seg["start"],
            "end":   seg["end"],
            "text":  translated_text,
            "speaker": seg.get("speaker", DEFAULT_SPEAKER),
        })
        update_status(job_id, "translating",
                      int(50 + (i + 1) / total * 25),
                      f"翻訳中 ({i + 1}/{total})")

    # STEP3: Claude口語化整形（APIキーがあれば）
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if api_key:
        update_status(job_id, "refining", 80,
                      "Claude API で口語化・整形中...（吹き替え用に自然な言い回しに変換）")
        translated_segments = refine_segments_claude(translated_segments, api_key, target_lang)
        update_status(job_id, "refining", 95, "整形完了")
    else:
        update_status(job_id, "translating", 95,
                      "ANTHROPIC_API_KEY 未設定のため整形スキップ（機械翻訳そのまま）")

    return translated_segments


# ── STEP 4: VOICEVOX TTS ─────────────────────────────────────────────
def tts_voicevox(text: str, output_path: str, speaker_id: int) -> None:
    import urllib.request, urllib.parse

    speed = float(os.environ.get("VOICEVOX_SPEED", "1.1"))

    # audio_query
    query_url = f"{VOICEVOX_URL}/audio_query?text={urllib.parse.quote(text)}&speaker={speaker_id}"
    req = urllib.request.Request(query_url, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        query = json.loads(resp.read())

    query["speedScale"]     = speed
    query["intonationScale"] = 1.1

    # synthesis
    body = json.dumps(query).encode()
    synth_url = f"{VOICEVOX_URL}/synthesis?speaker={speaker_id}"
    req2 = urllib.request.Request(
        synth_url, data=body, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req2, timeout=60) as resp:
        wav_data = resp.read()

    # WAV → MP3 変換
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp_wav = f.name
    try:
        with open(tmp_wav, "wb") as f:
            f.write(wav_data)
        AudioSegment.from_wav(tmp_wav).export(output_path, format="mp3")
    finally:
        os.unlink(tmp_wav)


def tts_edge(text: str, output_path: str, edge_voice: str) -> None:
    """edge-ttsで音声合成する（edge_voiceは"ja-JP-NanamiNeural"等の具体的なボイス名）。"""

    async def _run():
        await edge_tts.Communicate(text, edge_voice).save(output_path)

    loop = asyncio.new_event_loop()
    try:
        loop.run_until_complete(_run())
    finally:
        loop.close()


def tts_segment(text: str, output_path: str, voice_key: str, target_lang: str = "ja") -> None:
    """target_langに応じてTTSバックエンドを切り替える。
    - ja: VOICEVOXを試み、失敗したらedge-tts(日本語ボイス)にフォールバック
    - それ以外(en等): VOICEVOXは日本語専用のため使えない。edge-ttsの該当言語ボイスを直接使う
    """
    if target_lang == "ja":
        speaker_id = VOICEVOX_SPEAKERS.get(voice_key, VOICEVOX_SPEAKERS["female"])
        try:
            tts_voicevox(text, output_path, speaker_id)
            return
        except Exception as e:
            print(f"[VOICEVOX失敗 → edge-ttsにフォールバック] {e}")
            edge_voice = EDGE_VOICES_JA.get(voice_key, EDGE_VOICES_JA["female"])
            tts_edge(text, output_path, edge_voice)
    else:
        edge_voice = EDGE_VOICES_EN.get(voice_key, EDGE_VOICES_EN["female"])
        tts_edge(text, output_path, edge_voice)


# ── 話速調整（最大2倍速） ────────────────────────────────────────────
def _build_atempo(speed: float) -> str:
    parts: list[str] = []
    r = speed
    while r > 2.0:
        parts.append("atempo=2.0")
        r /= 2.0
    while r < 0.5:
        parts.append("atempo=0.5")
        r *= 2.0
    parts.append(f"atempo={r:.4f}")
    return ",".join(parts)


def adjust_speed(audio: AudioSegment, target_ms: float) -> AudioSegment:
    current_ms = len(audio)
    if current_ms == 0 or target_ms <= 0:
        return audio

    speed = current_ms / target_ms
    if speed > MAX_SPEED:
        print(f"[速度調整] 必要速度 {speed:.2f}x > 上限 {MAX_SPEED}x → そのまま流す")
        return audio
    if speed < 1.05:
        return audio

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        tmp_in = f.name
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        tmp_out = f.name
    try:
        audio.export(tmp_in, format="mp3")
        subprocess.run(
            ["ffmpeg", "-y", "-i", tmp_in, "-filter:a", _build_atempo(speed), tmp_out],
            check=True, capture_output=True,
        )
        return AudioSegment.from_mp3(tmp_out)
    finally:
        os.unlink(tmp_in)
        os.unlink(tmp_out)


# ── SRT 字幕生成 ─────────────────────────────────────────────────────
def _sec_to_srt(s: float) -> str:
    h  = int(s // 3600)
    m  = int((s % 3600) // 60)
    ss = int(s % 60)
    ms = int((s - int(s)) * 1000)
    return f"{h:02d}:{m:02d}:{ss:02d},{ms:03d}"


def generate_srt(segments: list[dict], output_path: str) -> None:
    lines = []
    for i, seg in enumerate(segments, 1):
        if not seg.get("text", "").strip():
            continue
        lines.append(
            f"{i}\n{_sec_to_srt(seg['start'])} --> {_sec_to_srt(seg['end'])}\n{seg['text'].strip()}\n"
        )
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# ── 話者ID → 音声(voice_key) マッピング解決 ───────────────────────────
def resolve_speaker_voice_map(
    translated_segments: list[dict], voice_key: str, speaker_voice_map: dict[str, str] | None,
) -> dict[str, str]:
    """登場する話者すべてに対して使用する voice_key を確定する。
    - speaker_voice_map に明示指定があればそれを優先
    - 指定が無い話者には、デフォルト voice_key → 未使用ならローテーションを割り当て
      （話者識別が無効/単一話者の場合は従来どおり voice_key 一本になる）
    """
    speakers = sorted({seg.get("speaker", DEFAULT_SPEAKER) for seg in translated_segments})
    explicit = speaker_voice_map or {}

    resolved: dict[str, str] = {}
    rotation_idx = 0
    for speaker in speakers:
        if speaker in explicit:
            resolved[speaker] = explicit[speaker]
        elif len(speakers) <= 1:
            resolved[speaker] = voice_key
        else:
            resolved[speaker] = SPEAKER_VOICE_ROTATION[rotation_idx % len(SPEAKER_VOICE_ROTATION)]
            rotation_idx += 1
    return resolved


# ── フルパイプライン ──────────────────────────────────────────────────
def run_pipeline(
    job_id: str,
    voice_key: str = "female",
    make_subtitle: bool = True,
    speaker_voice_map: dict[str, str] | None = None,
    target_lang: str = "ja",
) -> None:
    try:
        job_dir = JOBS_DIR / job_id

        # 編集済みを優先
        edited   = job_dir / "segments_translated_edited.json"
        original = job_dir / "segments_translated.json"
        seg_path = edited if edited.exists() else original

        if not seg_path.exists():
            raise RuntimeError("翻訳済みセグメントファイルが見つかりません")

        with open(seg_path, encoding="utf-8") as f:
            translated_segments = json.load(f)

        input_files = [
            p for p in job_dir.iterdir()
            if p.stem == "original"
            and p.suffix.lower() in {".mp4", ".mov", ".mkv", ".avi", ".mp3", ".wav", ".m4a"}
        ]
        if not input_files:
            raise RuntimeError("元ファイルが見つかりません")

        input_path    = str(input_files[0])
        is_audio_only = input_files[0].suffix.lower() in {".mp3", ".wav", ".m4a"}
        total_duration = get_duration(input_path)
        total          = len(translated_segments)

        voice_map = resolve_speaker_voice_map(translated_segments, voice_key, speaker_voice_map)

        # 字幕生成
        if make_subtitle:
            update_status(job_id, "processing", 2, "字幕ファイルを生成中...")
            generate_srt(translated_segments, str(job_dir / "subtitle.srt"))

        engine_label = "VOICEVOX" if target_lang == "ja" else "edge-tts"
        update_status(job_id, "processing", 5,
                      f"{engine_label} で音声を生成中（話者{len(voice_map)}人: {voice_map}）...")

        with tempfile.TemporaryDirectory() as tmpdir:
            track = AudioSegment.silent(duration=int(total_duration * 1000) + 3000)

            for i, seg in enumerate(translated_segments):
                text = seg.get("text", "").strip()
                if not text:
                    continue

                start_ms = int(seg["start"] * 1000)
                end_ms   = int(seg["end"]   * 1000)
                seg_dur  = end_ms - start_ms

                seg_speaker = seg.get("speaker", DEFAULT_SPEAKER)
                seg_voice   = voice_map.get(seg_speaker, voice_key)

                tts_path = os.path.join(tmpdir, f"seg_{i:04d}.mp3")
                try:
                    tts_segment(text, tts_path, seg_voice, target_lang)
                except Exception as e:
                    print(f"[TTS失敗 seg {i}] {e}")
                    continue

                tts_audio = AudioSegment.from_mp3(tts_path)

                # 尺超えなら速度調整（最大2倍速）
                if seg_dur > 0 and len(tts_audio) > seg_dur * 1.05:
                    tts_audio = adjust_speed(tts_audio, seg_dur)

                # 元の開始位置に配置（スライドと同期を保つ）
                track = track.overlay(tts_audio, position=start_ms)

                update_status(
                    job_id, "processing",
                    int(5 + (i + 1) / total * 75),
                    f"音声生成中 ({i + 1}/{total}): {text[:20]}...",
                )

            # 音声書き出し
            update_status(job_id, "processing", 82, "音声トラックを書き出し中...")
            dubbed_wav = os.path.join(tmpdir, "dubbed_track.wav")
            track.export(dubbed_wav, format="wav")

            import shutil
            shutil.copy(dubbed_wav, str(job_dir / "dubbed_audio.wav"))

            if is_audio_only:
                shutil.copy(dubbed_wav, str(job_dir / "output.mp4"))
                update_status(job_id, "done", 100, "完成しました！")
                return

            # 動画合成
            update_status(job_id, "processing", 88, "動画に音声を合成中...")
            result = subprocess.run(
                ["ffmpeg", "-y",
                 "-i", input_path, "-i", dubbed_wav,
                 "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                 "-map", "0:v:0", "-map", "1:a:0",
                 "-shortest", str(job_dir / "output.mp4")],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                raise RuntimeError(f"動画合成エラー: {result.stderr[-500:]}")

        update_status(job_id, "done", 100, "完成しました！動画をダウンロードできます。")

    except Exception as e:
        update_status(job_id, "error", 0, f"エラー: {e}")
        raise
