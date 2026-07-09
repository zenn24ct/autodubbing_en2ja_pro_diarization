# 英語→日本語 自動吹き替えシステム Pro（話者識別対応版）— Windowsセットアップ
# MSI Katana 15 B13VGK 等、NVIDIA GPU搭載機を想定（CUDA版PyTorchを導入）
#
# 実行方法: PowerShellを「管理者として実行」する必要はありません。
#           実行ポリシーで止まる場合は以下を一度だけ実行してください:
#           Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

$ErrorActionPreference = "Stop"

Write-Host "=== 英語→日本語 自動吹き替えシステム Pro セットアップ (Windows) ===" -ForegroundColor Cyan

# ── ffmpeg 確認 ──────────────────────────────────────────────────────
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "❌ ffmpeg が見つかりません。以下のいずれかでインストールしてください:" -ForegroundColor Red
    Write-Host "   winget install Gyan.FFmpeg"
    Write-Host "   choco install ffmpeg"
    Write-Host "インストール後、ターミナルを開き直してから再実行してください。"
    exit 1
}
Write-Host "✓ ffmpeg 検出済み"

# ── python 確認 ──────────────────────────────────────────────────────
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Python が見つかりません。https://www.python.org/downloads/ からインストールしてください（3.10〜3.11推奨）" -ForegroundColor Red
    exit 1
}
Write-Host "✓ python: $(python --version)"

# ── 仮想環境 ──────────────────────────────────────────────────────────
if (-not (Test-Path ".venv")) {
    python -m venv .venv
}
. .\.venv\Scripts\Activate.ps1

python -m pip install --upgrade pip -q

# ── PyTorch（CUDA版）───────────────────────────────────────────────────
# MSI Katana 15 B13VGK は NVIDIA GPU 搭載のため、CUDA版PyTorchを明示的に先へ入れる。
# 何もせず `pip install -r requirements.txt` だけだとCPU版が入りWhisperX/diarizationが遅くなる。
# GPUを使わない/CPUのみで動かす場合は下の1行を削除して構わない。
Write-Host "PyTorch (CUDA 12.1版) をインストール中..." -ForegroundColor Cyan
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu121

pip install -r requirements.txt

# ── .env ──────────────────────────────────────────────────────────────
if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "⚠️  .env を作成しました。ANTHROPIC_API_KEY（任意）と HF_TOKEN（話者識別に必須）を設定してください" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ セットアップ完了" -ForegroundColor Green
Write-Host ""
Write-Host "次のステップ:"
Write-Host "  1. VOICEVOX起動: .\setup_voicevox.ps1 → .\start_voicevox.ps1"
Write-Host "  2. .env に以下を設定:"
Write-Host "     - HF_TOKEN … https://huggingface.co/settings/tokens で発行"
Write-Host "       事前に https://huggingface.co/pyannote/speaker-diarization-3.1 の利用規約に同意が必要"
Write-Host "     - ANTHROPIC_API_KEY（任意・口語化整形用）"
Write-Host "  3. システム起動: .\run.ps1"
