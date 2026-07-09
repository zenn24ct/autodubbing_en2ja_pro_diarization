#!/bin/bash
INSTALL_DIR="$HOME/voicevox_engine"

if [ ! -f "$INSTALL_DIR/run" ]; then
  echo "❌ VOICEVOXが見つかりません。bash setup_voicevox.sh を実行してください。"
  exit 1
fi

echo "🎙️ VOICEVOX エンジン起動中... (http://localhost:50021)"
echo "   スピーカー一覧: http://localhost:50021/speakers"
echo "   停止: Ctrl+C"
"$INSTALL_DIR/run" --host 0.0.0.0 --port 50021
