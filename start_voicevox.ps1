$InstallDir = "$env:USERPROFILE\voicevox_engine"
$RunExe     = Join-Path $InstallDir "run.exe"

if (-not (Test-Path $RunExe)) {
    Write-Host "❌ VOICEVOXが見つかりません。.\setup_voicevox.ps1 を実行してください。" -ForegroundColor Red
    exit 1
}

Write-Host "🎙️ VOICEVOX エンジン起動中... (http://localhost:50021)"
Write-Host "   スピーカー一覧: http://localhost:50021/speakers"
Write-Host "   停止: Ctrl+C"
& $RunExe --host 127.0.0.1 --port 50021
