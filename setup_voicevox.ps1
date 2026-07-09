# VOICEVOX エンジン セットアップ（Windows版）
#
# MSI Katana 15 B13VGK は NVIDIA GPU 搭載のため、既定では nvidia版アセットを探す。
# 見つからない/GPUを使わない場合は自動的に cpu版へフォールバックする。
#
# 注意: VOICEVOXのWindows向けリリースアセット名はバージョンによって変わることがあるため、
#       このスクリプトはGitHub Releases APIで実際のアセット一覧を取得してから
#       ダウンロードする（URLを固定でハードコードしない）。
#       万一自動検出に失敗した場合は、手動ダウンロード手順を表示する。

$ErrorActionPreference = "Stop"

$InstallDir = "$env:USERPROFILE\voicevox_engine"
$RunExe     = Join-Path $InstallDir "run.exe"

if (Test-Path $RunExe) {
    Write-Host "✅ VOICEVOX は既にインストール済みです: $InstallDir"
    exit 0
}

Write-Host "=== VOICEVOX エンジン セットアップ (Windows) ===" -ForegroundColor Cyan

$ReleasesUrl = "https://api.github.com/repos/VOICEVOX/voicevox_engine/releases/latest"

try {
    $release = Invoke-RestMethod -Uri $ReleasesUrl -Headers @{ "User-Agent" = "autodubbing-setup" }
} catch {
    Write-Host "❌ GitHub Releases情報の取得に失敗しました: $_" -ForegroundColor Red
    Write-Host "手動で https://github.com/VOICEVOX/voicevox_engine/releases から"
    Write-Host "windows向けのアセットをダウンロードし、次のフォルダへ展開してください:"
    Write-Host "  $InstallDir"
    exit 1
}

# windows + (nvidia優先 → 無ければcpu) のアセットを探す
$candidates = $release.assets | Where-Object { $_.name -match "windows" }
$asset = $candidates | Where-Object { $_.name -match "nvidia" } | Select-Object -First 1
$usedVariant = "nvidia"
if (-not $asset) {
    $asset = $candidates | Where-Object { $_.name -match "cpu" } | Select-Object -First 1
    $usedVariant = "cpu"
}

if (-not $asset) {
    Write-Host "❌ Windows向けアセットが見つかりませんでした。" -ForegroundColor Red
    Write-Host "手動で https://github.com/VOICEVOX/voicevox_engine/releases から"
    Write-Host "windows向けのアセットをダウンロードし、次のフォルダへ展開してください:"
    Write-Host "  $InstallDir"
    exit 1
}

Write-Host "検出: $($asset.name)（$usedVariant 版）"
if ($usedVariant -eq "cpu") {
    Write-Host "⚠️  NVIDIA版が見つからなかったためCPU版を使用します（音声合成が遅くなります）" -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$downloadPath = Join-Path $env:TEMP $asset.name

Write-Host "ダウンロード中...（$([math]::Round($asset.size / 1MB, 1)) MB）"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath

Write-Host "展開中..."
if ($asset.name -like "*.zip") {
    Expand-Archive -Path $downloadPath -DestinationPath $InstallDir -Force
} elseif ($asset.name -like "*.7z*") {
    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if (-not $sevenZip -and (Test-Path "C:\Program Files\7-Zip\7z.exe")) {
        $sevenZip = "C:\Program Files\7-Zip\7z.exe"
    }
    if (-not $sevenZip) {
        Write-Host "❌ 7-Zipが必要です。以下でインストールしてから再実行してください:" -ForegroundColor Red
        Write-Host "   winget install 7zip.7zip"
        exit 1
    }
    & $sevenZip x $downloadPath -o"$InstallDir" -y
} else {
    Write-Host "❌ 未対応の圧縮形式です: $($asset.name)" -ForegroundColor Red
    exit 1
}

Remove-Item $downloadPath -ErrorAction SilentlyContinue

if (-not (Test-Path $RunExe)) {
    Write-Host "⚠️  展開後に run.exe が見つかりません。$InstallDir の中身を確認してください。" -ForegroundColor Yellow
}

Write-Host "✅ VOICEVOX セットアップ完了"
Write-Host "起動: .\start_voicevox.ps1"
