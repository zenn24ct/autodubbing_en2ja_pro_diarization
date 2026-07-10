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
# 既定の進捗バー描画はInvoke-WebRequestを極端に遅くする（数GBのDLが「固まった」ように見える主因）
$ProgressPreference = "SilentlyContinue"

$InstallDir = "$env:USERPROFILE\voicevox_engine"
$RunExe     = Join-Path $InstallDir "run.exe"

if (Test-Path $RunExe) {
    Write-Host "✅ VOICEVOX は既にインストール済みです: $InstallDir"
    exit 0
}

Write-Host "=== VOICEVOX エンジン セットアップ (Windows) ===" -ForegroundColor Cyan

$ReleasesUrl = "https://api.github.com/repos/VOICEVOX/voicevox_engine/releases/latest"

try {
    # -UseBasicParsing: Windows PowerShell 5.1はIEエンジンでHTML解析しようとして
    # 初回起動時のIE設定が絡み固まることがあるため、単純なテキスト/JSON解析に留める
    $release = Invoke-RestMethod -Uri $ReleasesUrl -Headers @{ "User-Agent" = "autodubbing-setup" } `
        -UseBasicParsing -TimeoutSec 30
} catch {
    Write-Host "❌ GitHub Releases情報の取得に失敗しました: $_" -ForegroundColor Red
    Write-Host "手動で https://github.com/VOICEVOX/voicevox_engine/releases から"
    Write-Host "windows向けのアセットをダウンロードし、次のフォルダへ展開してください:"
    Write-Host "  $InstallDir"
    exit 1
}

# windows + (nvidia優先 → 無ければcpu) のアセット群を探す
# VOICEVOXは .vvpp（単一ファイル）または .NNN.vvppp（分割ファイル、要結合）で配布される。
# .vvpp/.vvppp の正体は拡張子を変えただけのZIPファイル。
$candidates = $release.assets | Where-Object { $_.name -match "windows" }
$variantAssets = @($candidates | Where-Object { $_.name -match "nvidia" })
$usedVariant = "nvidia"
if (-not $variantAssets) {
    $variantAssets = @($candidates | Where-Object { $_.name -match "cpu" })
    $usedVariant = "cpu"
}

if (-not $variantAssets) {
    Write-Host "❌ Windows向けアセットが見つかりませんでした。" -ForegroundColor Red
    Write-Host "手動で https://github.com/VOICEVOX/voicevox_engine/releases から"
    Write-Host "windows向けのアセットをダウンロードし、次のフォルダへ展開してください:"
    Write-Host "  $InstallDir"
    exit 1
}

# 分割ファイルはパート番号順に処理する必要があるため名前でソート
$variantAssets = $variantAssets | Sort-Object name

Write-Host "検出: $($variantAssets.Count)個のファイル（$usedVariant 版）"
$variantAssets | ForEach-Object { Write-Host "  - $($_.name)" }
if ($usedVariant -eq "cpu") {
    Write-Host "⚠️  NVIDIA版が見つからなかったためCPU版を使用します（音声合成が遅くなります）" -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$tempDir = Join-Path $env:TEMP "voicevox_dl"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$downloadedFiles = @()
foreach ($a in $variantAssets) {
    $dest = Join-Path $tempDir $a.name
    Write-Host "ダウンロード中: $($a.name)（$([math]::Round($a.size / 1MB, 1)) MB、回線次第で数分〜数十分かかります）"
    Invoke-WebRequest -Uri $a.browser_download_url -OutFile $dest -UseBasicParsing

    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -eq 0) {
        Write-Host "❌ ダウンロードに失敗しました: $($a.name)" -ForegroundColor Red
        exit 1
    }
    $downloadedFiles += $dest
}
Write-Host "ダウンロード完了（全 $($downloadedFiles.Count) ファイル）"

# .vvpp/.vvppp は拡張子違いのZIPなので、必要なら結合してから .zip として展開する
$combinedZip = Join-Path $tempDir "voicevox_engine_combined.zip"
if ($downloadedFiles.Count -eq 1) {
    Copy-Item $downloadedFiles[0] $combinedZip -Force
} else {
    Write-Host "分割ファイルを結合中..."
    $outStream = [System.IO.File]::Create($combinedZip)
    try {
        foreach ($f in $downloadedFiles) {
            $bytes = [System.IO.File]::ReadAllBytes($f)
            $outStream.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $outStream.Close()
    }
}

Write-Host "展開中..."
$firstName = $variantAssets[0].name
if ($firstName -match "\.vvppp?$" -or $firstName -like "*.zip") {
    Expand-Archive -Path $combinedZip -DestinationPath $InstallDir -Force
} elseif ($firstName -like "*.7z*") {
    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if (-not $sevenZip -and (Test-Path "C:\Program Files\7-Zip\7z.exe")) {
        $sevenZip = "C:\Program Files\7-Zip\7z.exe"
    }
    if (-not $sevenZip) {
        Write-Host "❌ 7-Zipが必要です。以下でインストールしてから再実行してください:" -ForegroundColor Red
        Write-Host "   winget install 7zip.7zip"
        exit 1
    }
    & $sevenZip x $combinedZip -o"$InstallDir" -y
} else {
    Write-Host "❌ 未対応の圧縮形式です: $firstName" -ForegroundColor Red
    exit 1
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $RunExe)) {
    Write-Host "⚠️  展開後に run.exe が見つかりません。$InstallDir の中身を確認してください。" -ForegroundColor Yellow
    Write-Host "   （展開後のフォルダ構成が1階層深い場合があります。$InstallDir の中を確認してください）"
}

Write-Host "✅ VOICEVOX セットアップ完了"
Write-Host "起動: .\start_voicevox.ps1"
