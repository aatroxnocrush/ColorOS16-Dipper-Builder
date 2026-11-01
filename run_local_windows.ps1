# ==============================================================================
# One-Click Windows Launcher for ColorOS 16 -> Xiaomi Mi 8 (dipper) Porting
# ==============================================================================
param(
    [Parameter(Mandatory=$true)]
    [string]$OtaOrPayloadPath
)

$ErrorActionPreference = "Stop"
$BuilderDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsDir = Join-Path $BuilderDir "tools_win64"
New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null

# 1. Download payload-dumper-go for Windows if not present
$PayloadDumperExe = Join-Path $ToolsDir "payload-dumper-go.exe"
if (-not (Test-Path $PayloadDumperExe)) {
    Write-Host "[1/3] Downloading payload-dumper-go (Windows x64)..." -ForegroundColor Cyan
    $tarUrl = "https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_windows_amd64.tar.gz"
    $tarPath = Join-Path $ToolsDir "pdg.tar.gz"
    Invoke-WebRequest -Uri $tarUrl -OutFile $tarPath
    tar -xzf $tarPath -C $ToolsDir
    Remove-Item $tarPath -Force
}

Write-Host "[2/3] Extracting partitions from $OtaOrPayloadPath..." -ForegroundColor Cyan
$ImgOut = Join-Path $BuilderDir "work_c16_dipper\extracted_imgs"
New-Item -ItemType Directory -Path $ImgOut -Force | Out-Null
& $PayloadDumperExe -p "system,system_ext,product,my_product,my_stock,my_heytap,my_bigball,my_region,my_carrier,my_company,my_preload,my_engineering,vendor,odm" -o $ImgOut $OtaOrPayloadPath

Write-Host "[3/3] Extracted images ready in: $ImgOut" -ForegroundColor Green
Write-Host "Note: Because Xiaomi Mi 8 Kernel 4.9.337 requires EXT4 rootfs and EXT4 APEX conversion, use the GitHub Actions workflow (.github/workflows/build_coloros16_dipper.yml) or WSL2 Linux to run repack_ext4_and_apex.sh!" -ForegroundColor Yellow
