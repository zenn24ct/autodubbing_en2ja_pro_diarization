# 英語→日本語 自動吹き替えシステム Pro（話者識別対応版）— Windowsセットアップ
# MSI Katana 15 B13VGK 等、NVIDIA GPU搭載機を想定（CUDA版PyTorchを導入）
#
# 実行方法: PowerShellを「管理者として実行」する必要はありません。
#           実行ポリシーで止まる場合は以下を一度だけ実行してください:
#           Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

$ErrorActionPreference = "Stop"

Write-Host "=== 自動吹き替えシステム Pro（EN⇄JA） セットアップ (Windows) ===" -ForegroundColor Cyan

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

# pipのような外部exeはエラーで止まっても$ErrorActionPreference="Stop"の対象外
# （非終了エラー扱いのため）なので、明示的に終了コードを確認して止める。
function Invoke-CheckedCommand {
    param([string]$Description)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ $Description に失敗しました（終了コード: $LASTEXITCODE）。上のエラー内容を確認してください。" -ForegroundColor Red
        exit 1
    }
}

python -m pip install --upgrade pip -q
Invoke-CheckedCommand "pipのアップグレード"

# ── 依存パッケージ ─────────────────────────────────────────────────────
pip install -r requirements.txt
Invoke-CheckedCommand "requirements.txtのインストール"

# ── PyTorch（CUDA版）───────────────────────────────────────────────────
# MSI Katana 15 B13VGK は NVIDIA GPU 搭載のため、CUDA版PyTorchを入れる。
# ※必ず requirements.txt の「後」に入れること。
#   whisperx等がtorchに依存しており、requirements.txtを後から入れるとPyPI既定の
#   CPU版torch(+cpu)が先に入れたCUDA版を上書きしてしまう（torch.cuda.is_available()=False）。
#   最後にCUDA版を --force-reinstall で確定させることで確実にCUDA版を残す。
#
# バージョンは torch 2.8.0 に固定する。whisperx 3.8.6 / pyannote-audio 4.0.7 が
# torch~=2.8.0 を要求するため。torch 2.8.0 のCUDAビルドは cu126/cu128 で提供され
# （cu124は2.6.0が最後）、MSI KatanaのドライバはCUDA 12.9対応なので cu128 を使う
# （12.9 >= 12.8 で下位互換）。GPUを使わない場合は下の pip 行を削除して構わない。
Write-Host "PyTorch 2.8.0 (CUDA 12.8版) をインストール中..." -ForegroundColor Cyan
pip install --force-reinstall "torch==2.8.0" "torchaudio==2.8.0" --index-url https://download.pytorch.org/whl/cu128
Invoke-CheckedCommand "PyTorch(CUDA版)のインストール"

# CUDA が有効か検証（Falseならヒントを表示）
python -c "import torch; import sys; ok = torch.cuda.is_available(); print(f'torch {torch.__version__} / CUDA available: {ok}'); sys.exit(0 if ok else 3)"
if ($LASTEXITCODE -eq 3) {
    Write-Host "⚠️  PyTorchはCPU版として認識されています。GPUドライバ(nvidia-smi)を確認してください。" -ForegroundColor Yellow
}

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
