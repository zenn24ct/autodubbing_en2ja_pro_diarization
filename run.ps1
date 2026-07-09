# 英語→日本語 自動吹き替えシステム Pro（話者識別対応版）— Windows起動スクリプト

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".venv")) {
    Write-Host "❌ 仮想環境が見つかりません。先に .\setup.ps1 を実行してください。" -ForegroundColor Red
    exit 1
}

. .\.venv\Scripts\Activate.ps1

if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
        }
    }
}

$Port = if ($env:PORT) { $env:PORT } else { "8000" }

Write-Host "🚀 英語→日本語 自動吹き替えシステム Pro（話者識別対応）"
Write-Host "   http://localhost:$Port"
Write-Host "   停止: Ctrl+C"
Write-Host ""

uvicorn app.main:app --host 0.0.0.0 --port $Port --reload
