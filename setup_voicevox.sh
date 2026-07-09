#!/bin/bash
set -e
echo "=== VOICEVOX エンジン セットアップ ==="

INSTALL_DIR="$HOME/voicevox_engine"
VERSION="0.22.1"

if [ -f "$INSTALL_DIR/run" ]; then
  echo "✅ VOICEVOX は既にインストール済みです: $INSTALL_DIR"
  exit 0
fi

mkdir -p "$INSTALL_DIR"

if ! command -v wget &>/dev/null; then sudo apt install -y wget; fi
if ! command -v 7z &>/dev/null; then sudo apt install -y p7zip-full; fi

echo "ダウンロード中...（約500MB）"
cd /tmp
wget -c "https://github.com/VOICEVOX/voicevox_engine/releases/download/${VERSION}/voicevox_engine-linux-cpu-${VERSION}.7z.001" \
     -O voicevox_engine.7z.001

for i in 002 003 004 005; do
  URL="https://github.com/VOICEVOX/voicevox_engine/releases/download/${VERSION}/voicevox_engine-linux-cpu-${VERSION}.7z.${i}"
  if wget --spider "$URL" 2>/dev/null; then
    wget -c "$URL" -O "voicevox_engine.7z.${i}"
  else
    break
  fi
done

7z x voicevox_engine.7z.001 -o"$INSTALL_DIR" -y
rm -f /tmp/voicevox_engine.7z.*
chmod +x "$INSTALL_DIR/run"

echo "✅ VOICEVOX セットアップ完了"
echo "起動: bash start_voicevox.sh"
