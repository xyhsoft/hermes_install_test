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
Write-Host "卸载 Hermes Agent..."
try { pip uninstall -y hermes-agent } catch {}

# 卸载飞书 CLI
Write-Host "卸载飞书 CLI..."
Remove-Item -Recurse -Force "$INSTALL_DIR\lark" -ErrorAction SilentlyContinue

# 卸载 CC-Switch
Write-Host "卸载 CC-Switch..."
$ccApp = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*CC-Switch*" }
if ($ccApp) {
    try { Start-Process msiexec -ArgumentList "/x $($ccApp.PSChildName) /qn" -Wait } catch {}
} else {
    # 尝试 Win32_Product
    try {
        $ccProd = (Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*CC-Switch*" })
        if ($ccProd) { Start-Process msiexec -ArgumentList "/x $($ccProd.IdentifyingNumber) /qn" -Wait }
    } catch {}
}

# 清理自启动快捷方式
$commonStartup = [Environment]::GetFolderPath("CommonStartup")
Remove-Item -Force (Join-Path $commonStartup "CC-Switch.lnk") -ErrorAction SilentlyContinue

# 清理环境变量
Write-Host "清理环境变量..."
$currentPath = [System.Environment]::GetEnvironmentVariable("Path","Machine")
$newPath = ($currentPath -split ";" | Where-Object { $_ -ne $INSTALL_DIR -and $_ -notlike "*lark*" }) -join ";"
[System.Environment]::SetEnvironmentVariable("Path",$newPath,"Machine")
[System.Environment]::SetEnvironmentVariable("HERMES_HOME",$null,"Machine")

# 删除安装目录
Write-Host "删除安装目录..."
Remove-Item -Recurse -Force $INSTALL_DIR -ErrorAction SilentlyContinue

# 卸载本次新装的系统依赖（默认保留，确认才卸）
if (Test-Path $DEPS_RECORD) {
    Write-Host ""
    Write-Host "本次安装新装了以下依赖（记录于 $DEPS_RECORD）："
    Get-Content $DEPS_RECORD
    Write-Host ""
    $doRemove = $false
    if ($REMOVE_DEPS) { $doRemove = $true }
    else {
        $dc = Read-Host "是否一并卸载这些依赖？[y/N，默认 N 保留]"
        if ($dc -match '^[Yy]') { $doRemove = $true }
    }
    if ($doRemove) {
        Write-Host "卸载新装依赖..."
        # Windows 依赖记录里是 "Python 3.12.4" 这类描述性条目
        # 按记录里的精确版本号匹配注册表，避免误卸用户已有的其它 Python
        Get-Content $DEPS_RECORD | ForEach-Object {
            if ($_ -like "Python*") {
                $ver = ([regex]::Match($_, '(\d+\.\d+\.\d+)').Groups[1].Value)
                if (-not $ver) { Write-Host "跳过无法解析版本的条目: $_"; return }
                $pyApp = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$ver*" -and $_.DisplayName -like "Python*" }
                if ($pyApp) {
                    try { Start-Process msiexec -ArgumentList "/x $($pyApp.PSChildName) /qn" -Wait; Write-Host "已卸载 $_" } catch { Write-Host "卸载 $_ 失败" }
                } else {
                    Write-Host "未找到 Python $ver 的卸载入口（可能已被卸载），跳过"
                }
            } else {
                Write-Host "跳过未知依赖条目: $_"
            }
        }
        Remove-Item $DEPS_RECORD -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "保留系统依赖（如需卸载请加 -REMOVE_DEPS 或交互输入 y）"
    }
} else {
    Write-Host "无新装依赖清单，跳过依赖卸载"
}

# 配置文件处理
if ($REMOVE_CONFIG) {
    Remove-Item -Recurse -Force "$env:USERPROFILE\.hermes" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $HERMES_HOME -ErrorAction SilentlyContinue
    Write-Host "已删除配置文件"
} else {
    Write-Host "配置文件已保留: $env:USERPROFILE\.hermes\config.yaml"
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "  卸载完成!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
