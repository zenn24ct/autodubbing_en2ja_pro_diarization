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
# 1リリースにvvpp/vvppp形式と7z形式の両方が同居しているため、
# 「windows」「nvidia」に一致するだけでは.txt説明ファイルや別形式まで拾ってしまう。
# 拡張子で厳密に絞り込み、1つの形式だけを選ぶ（優先順位: vvpp/vvppp → zip → 7z）。
function Get-VoicevoxAssets($allAssets, $variantPattern) {
    $matched = $allAssets | Where-Object { $_.name -match "windows" -and $_.name -match $variantPattern }
    $vvpp = @($matched | Where-Object { $_.name -match "\.vvppp?$" } | Sort-Object name)
    if ($vvpp.Count -gt 0) { return $vvpp }
    $zip = @($matched | Where-Object { $_.name -match "\.zip$" } | Sort-Object name)
    if ($zip.Count -gt 0) { return $zip }
    $sevenZ = @($matched | Where-Object { $_.name -match "\.7z(\.\d+)?$" } | Sort-Object name)
    return $sevenZ
}

$variantAssets = Get-VoicevoxAssets $release.assets "nvidia"
$usedVariant = "nvidia"
if ($variantAssets.Count -eq 0) {
    $variantAssets = Get-VoicevoxAssets $release.assets "cpu"
    $usedVariant = "cpu"
}

if ($variantAssets.Count -eq 0) {
    Write-Host "❌ Windows向けアセットが見つかりませんでした。" -ForegroundColor Red
    Write-Host "手動で https://github.com/VOICEVOX/voicevox_engine/releases から"
    Write-Host "windows向けのアセットをダウンロードし、次のフォルダへ展開してください:"
    Write-Host "  $InstallDir"
    exit 1
}

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

# 展開したZIPの中身が1階層深いサブフォルダに入っている場合（よくあるパターン）は
# run.exeが見つかった場所の中身を $InstallDir 直下へ移動してフラット化する
if (-not (Test-Path $RunExe)) {
    $found = Get-ChildItem -Path $InstallDir -Recurse -Filter "run.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found -and $found.DirectoryName -ne $InstallDir) {
        Write-Host "run.exe がサブフォルダ '$($found.DirectoryName)' にあるため $InstallDir 直下へ移動します..."
        Get-ChildItem -Path $found.DirectoryName -Force | Move-Item -Destination $InstallDir -Force
        # 空になったサブフォルダを掃除
        Get-ChildItem -Path $InstallDir -Directory -Force | ForEach-Object {
            if ((Get-ChildItem $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
                Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
    }
}

if (-not (Test-Path $RunExe)) {
    Write-Host "⚠️  展開後に run.exe が見つかりません。以下が $InstallDir の実際の中身です:" -ForegroundColor Yellow
    Get-ChildItem -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue |
        Select-Object -First 40 |
        ForEach-Object { Write-Host "   $($_.FullName)" }
    Write-Host "上記に .exe ファイルがあれば、そのファイル名を教えてください（run.exeという名前でない可能性があります）"
    exit 1
}

Write-Host "✅ VOICEVOX セットアップ完了: $RunExe"
Write-Host "起動: .\start_voicevox.ps1"
