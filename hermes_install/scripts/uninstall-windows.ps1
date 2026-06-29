# ============================================================
# Hermes Agent + 飞书CLI + CC-Switch Windows 卸载脚本
#
# 卸载内容：
#   - hermes-agent (pip uninstall)
#   - 飞书 CLI (删目录)
#   - CC-Switch (msiexec /x / 注册表)
#   - 环境变量 (Path / HERMES_HOME / 自启动快捷方式)
#   - 安装目录
#   - 本次新装依赖（读 installed-deps.txt，默认保留，确认才卸）
#   - 配置文件（-REMOVE_CONFIG 才删 ~/.hermes）
#
# 用法: .\uninstall-windows.ps1 [-REMOVE_CONFIG] [-REMOVE_DEPS] [-CI]
#       (或设环境变量 HERMES_CI=1，CI 环境跳过 RunAs 提权)
# ============================================================

param(
    [string]$INSTALL_DIR = "C:\Program Files\HermesAgent",
    [string]$HERMES_HOME = "$env:APPDATA\Hermes",
    [switch]$REMOVE_CONFIG,
    [switch]$REMOVE_DEPS,
    [switch]$CI
)

$DEPS_RECORD = Join-Path $HERMES_HOME "installed-deps.txt"
$CI_MODE = $CI -or ($env:HERMES_CI -eq "1")

# 日志随安装包走：脚本所在 scripts 的父目录（安装包根）下 logs/
$LOG_DIR = Join-Path (Split-Path $PSScriptRoot -Parent) "logs"
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null
$LOG_FILE = Join-Path $LOG_DIR "uninstall.log"

function Write-ULog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Write-Host $Message
    try { Add-Content -Path $LOG_FILE -Value $entry -Encoding UTF8 -ErrorAction Stop } catch {}
}

# 权限检查
if (-not $CI_MODE) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -INSTALL_DIR `"$INSTALL_DIR`" -HERMES_HOME `"$HERMES_HOME`" $(if($REMOVE_CONFIG){'-REMOVE_CONFIG'}) $(if($REMOVE_DEPS){'-REMOVE_DEPS'})"
        exit
    }
}

Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Hermes Agent 卸载" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
# CI 模式跳过交互确认（Read-Host 不读 stdin 管道）
if (-not $CI_MODE) {
    $confirm = Read-Host "确认卸载？(y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") { Write-Host "取消卸载"; exit }
} else {
    Write-Host "CI 模式，自动确认卸载"
}

# 卸载 Hermes Agent
Write-ULog "卸载 Hermes Agent..."
$uninstOk = $false
try {
    $out = pip uninstall -y hermes-agent 2>&1
    if ($out -match "Successfully uninstalled") { $uninstOk = $true; Write-ULog "[OK] hermes-agent 卸载成功" }
    else { Write-ULog "[INFO] hermes-agent 可能未安装或已卸载" }
} catch { Write-ULog "[WARN] pip uninstall 异常: $_" }

# 卸载飞书 CLI
Write-ULog "卸载飞书 CLI..."
if (Test-Path "$INSTALL_DIR\lark") {
    Remove-Item -Recurse -Force "$INSTALL_DIR\lark" -ErrorAction SilentlyContinue
    if (Test-Path "$INSTALL_DIR\lark") { Write-ULog "[WARN] lark 目录未删干净" }
    else { Write-ULog "[OK] lark 目录已删除" }
} else { Write-ULog "[INFO] lark 目录不存在，跳过" }

# 卸载 CC-Switch
Write-ULog "卸载 CC-Switch..."
$ccApp = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*CC-Switch*" }
if ($ccApp) {
    try { Start-Process msiexec -ArgumentList "/x $($ccApp.PSChildName) /qn" -Wait; Write-ULog "[OK] CC-Switch 卸载已执行" } catch { Write-ULog "[WARN] CC-Switch 卸载失败: $_" }
} else {
    Write-ULog "[INFO] 注册表无 CC-Switch 记录，尝试 Win32_Product"
    try {
        $ccProd = (Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*CC-Switch*" })
        if ($ccProd) { Start-Process msiexec -ArgumentList "/x $($ccProd.IdentifyingNumber) /qn" -Wait; Write-ULog "[OK] CC-Switch 卸载已执行(Win32_Product)" }
        else { Write-ULog "[INFO] 未找到 CC-Switch，可能未安装" }
    } catch { Write-ULog "[WARN] Win32_Product 查询失败: $_" }
}

# 清理自启动快捷方式
$commonStartup = [Environment]::GetFolderPath("CommonStartup")
Remove-Item -Force (Join-Path $commonStartup "CC-Switch.lnk") -ErrorAction SilentlyContinue

# 清理环境变量
Write-ULog "清理环境变量..."
$currentPath = [System.Environment]::GetEnvironmentVariable("Path","Machine")
$newPath = ($currentPath -split ";" | Where-Object { $_ -ne $INSTALL_DIR -and $_ -notlike "*lark*" }) -join ";"
[System.Environment]::SetEnvironmentVariable("Path",$newPath,"Machine")
[System.Environment]::SetEnvironmentVariable("HERMES_HOME",$null,"Machine")

# 删除安装目录
Write-ULog "删除安装目录..."
Remove-Item -Recurse -Force $INSTALL_DIR -ErrorAction SilentlyContinue

# 卸载本次新装的系统依赖（默认保留，确认才卸）
if (Test-Path $DEPS_RECORD) {
    Write-ULog "本次安装新装了以下依赖（记录于 $DEPS_RECORD）："
    Get-Content $DEPS_RECORD | ForEach-Object { Write-ULog "  $_" }
    $doRemove = $false
    if ($REMOVE_DEPS) { $doRemove = $true; Write-ULog "[-REMOVE_DEPS] 自动卸载依赖" }
    else {
        $dc = Read-Host "是否一并卸载这些依赖？[y/N，默认 N 保留]"
        if ($dc -match '^[Yy]') { $doRemove = $true }
    }
    if ($doRemove) {
        Write-ULog "开始卸载新装依赖..."
        Get-Content $DEPS_RECORD | ForEach-Object {
            if ($_ -like "Python*") {
                $ver = ([regex]::Match($_, '(\d+\.\d+\.\d+)').Groups[1].Value)
                if (-not $ver) { Write-ULog "[SKIP] 无法解析版本: $_"; return }
                $pyApp = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$ver*" -and $_.DisplayName -like "Python*" }
                if ($pyApp) {
                    try { Start-Process msiexec -ArgumentList "/x $($pyApp.PSChildName) /qn" -Wait; Write-ULog "[OK] 已卸载 $_" } catch { Write-ULog "[WARN] 卸载 $_ 失败: $_" }
                } else {
                    Write-ULog "[SKIP] 未找到 Python $ver 卸载入口（可能已卸载）"
                }
            } else {
                Write-ULog "[SKIP] 未知依赖条目: $_"
            }
        }
        Remove-Item $DEPS_RECORD -Force -ErrorAction SilentlyContinue
    } else {
        Write-ULog "保留系统依赖（如需卸载请加 -REMOVE_DEPS 或交互输入 y）"
    }
} else {
    Write-ULog "[INFO] 无新装依赖清单，跳过依赖卸载"
}

# 配置文件处理
if ($REMOVE_CONFIG) {
    Remove-Item -Recurse -Force "$env:USERPROFILE\.hermes" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $HERMES_HOME -ErrorAction SilentlyContinue
    Write-ULog "[OK] 已删除配置文件"
} else {
    Write-ULog "[INFO] 配置文件已保留: $env:USERPROFILE\.hermes\config.yaml"
}

# ---- 卸载后验证 ----
Write-ULog "========== 卸载后验证 =========="
$uninstPassed = 0
$uninstFailed = 0

# hermes 应不可用
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
$hermesCmd = Get-Command hermes -ErrorAction SilentlyContinue
if (-not $hermesCmd) { Write-ULog "[PASS] hermes 已卸载"; $uninstPassed++ }
    else { Write-ULog "[FAIL] hermes 仍可用"; $uninstFailed++ }

# 安装目录应删除
if (-not (Test-Path $INSTALL_DIR)) { Write-ULog "[PASS] 安装目录已删除"; $uninstPassed++ }
    else { Write-ULog "[WARN] 安装目录仍存在: $INSTALL_DIR"; $uninstFailed++ }

# CC-Switch 应卸载
$ccCheck = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*CC-Switch*" }
if (-not $ccCheck) { Write-ULog "[PASS] CC-Switch 已卸载"; $uninstPassed++ }
    else { Write-ULog "[WARN] CC-Switch 注册表记录仍存在"; $uninstFailed++ }

if ($uninstFailed -eq 0) {
    Write-ULog "✅ 卸载验证全部通过 ($uninstPassed 项)"
} else {
    Write-ULog "⚠️ 卸载验证部分失败（通过 $uninstPassed 项，警告 $uninstFailed 项）"
}

Write-ULog "卸载完成"
Write-Host "========================================" -ForegroundColor Green
Write-Host "  卸载完成!" -ForegroundColor Green
Write-Host "  日志: $LOG_FILE" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
