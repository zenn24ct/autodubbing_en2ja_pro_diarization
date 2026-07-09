#!/bin/bash
set -e
echo "=== 英語→日本語 自動吹き替えシステム Pro セットアップ ==="

# ffmpeg
if ! command -v ffmpeg &>/dev/null; then
  echo "ffmpeg をインストール中..."
  sudo apt update -y && sudo apt install -y ffmpeg
fi
echo "✓ ffmpeg: $(ffmpeg -version 2>&1 | head -1)"

# python3
if ! command -v python3 &>/dev/null; then
  sudo apt install -y python3 python3-pip python3-venv
fi
echo "✓ python3: $(python3 --version)"

# 仮想環境
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q

# .env
if [ ! -f ".env" ]; then
  cp .env.example .env
  echo "⚠️  .env を作成しました。HF_TOKEN（話者識別に必須）と ANTHROPIC_API_KEY（任意）を設定してください"
fi

echo ""
echo "✅ セットアップ完了"
echo ""
echo "次のステップ:"
echo "  1. VOICEVOX起動: bash setup_voicevox.sh → bash start_voicevox.sh"
echo "  2. .env に以下を設定:"
echo "     - HF_TOKEN … https://huggingface.co/settings/tokens で発行"
echo "       事前に https://huggingface.co/pyannote/speaker-diarization-3.1 の利用規約に同意が必要"
echo "     - ANTHROPIC_API_KEY（任意・口語化整形用）"
echo "  3. システム起動: bash run.sh"
