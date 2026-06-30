# ============================================================
# Hermes Agent + 飞书CLI + CC-Switch Windows x64 幂等安装器
#
# 特性：
#   - 幂等：没装就新装、版本低就升级、最新就跳过
#   - CC-Switch MSI 失败回滚，改用 Hermes 官方配置方式
#   - 版本号实时查 PyPI/GitHub，不写死
#   - 首次新装系统依赖（Python）时记录清单，供卸载使用
#   - 可选安装 browser-act
#   - 连通性测试加超时可跳过
#
# 用法:
#   .\install-windows.ps1 [-HERMES_VERSION <版本>] [-INSTALL_DIR <目录>]
#                        [-HERMES_HOME <目录>] [-PROVIDER <bailian|deepseek>]
#                        [-API_KEY <key>] [-SKIP_PROVIDER_CONFIG]
#                        [-SKIP_AUTOSTART] [-SKIP_CONNECTIVITY_TEST]
#                        [-INSTALL_BROWSER_ACT] [-SKIP_BROWSER_ACT]
#                        [-CI]   (或设环境变量 HERMES_CI=1，CI 环境跳过 RunAs 提权)
# ============================================================

param(
    [string]$HERMES_VERSION = "latest",
    [string]$INSTALL_DIR = "C:\Program Files\HermesAgent",
    [string]$HERMES_HOME = "$env:APPDATA\Hermes",
    [string]$PROVIDER = "",
    [string]$API_KEY = "",
    [switch]$SKIP_BAILIAN_CONFIG,
    [switch]$SKIP_PROVIDER_CONFIG,
    [switch]$SKIP_AUTOSTART,
    [switch]$SKIP_CONNECTIVITY_TEST,
    [switch]$INSTALL_BROWSER_ACT,
    [switch]$SKIP_BROWSER_ACT,
    [switch]$CI
)

# 兼容旧参数
if ($SKIP_BAILIAN_CONFIG) { $SKIP_PROVIDER_CONFIG = $true }
# CI 旁路：-CI 开关或 HERMES_CI=1 环境变量，跳过 RunAs 提权（GitHub Actions 等 CI 环境）
$CI_MODE = $CI -or ($env:HERMES_CI -eq "1")

# 日志随安装包走：脚本所在 scripts 的父目录（安装包根）下 logs/
$LOG_DIR = Join-Path (Split-Path $PSScriptRoot -Parent) "logs"
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null
$LOG_FILE = Join-Path $LOG_DIR "install.log"
$DEPS_RECORD = Join-Path $HERMES_HOME "installed-deps.txt"
$COMPONENTS_RECORD = Join-Path $HERMES_HOME "installed-components.txt"

# 辅助函数：记录新装的组件（仅当原本不存在时）
function Add-InstalledComponent {
    param([string]$ComponentName)
    if (-not (Test-Path $COMPONENTS_RECORD)) {
        New-Item -ItemType File -Path $COMPONENTS_RECORD -Force | Out-Null
    }
    $existing = Get-Content $COMPONENTS_RECORD -ErrorAction SilentlyContinue
    if ($existing -notcontains $ComponentName) {
        Add-Content -Path $COMPONENTS_RECORD -Value $ComponentName -Encoding UTF8
        Write-Info "记录新装组件: $ComponentName"
    }
}

# ============================================================
# 日志
# ============================================================
function Write-Log {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry
    try { Add-Content -Path $LOG_FILE -Value $entry -Encoding UTF8 -ErrorAction Stop } catch {}
}
function Write-Info { Write-Log "INFO" $args[0] }
function Write-Warn { Write-Log "WARNING" $args[0] }
function Write-Err  { Write-Log "ERROR" $args[0] }

# ============================================================
# 提权
# ============================================================
function Ensure-Admin {
    # CI 模式：跳过 RunAs 提权（GitHub Actions 等 CI 环境已在 admin 上下文或接受非 admin 运行）
    if ($CI_MODE) {
        Write-Info "CI 模式（HERMES_CI），跳过 RunAs 提权"
        return
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Info "需要管理员权限，正在提权..."
        $argList = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($HERMES_VERSION -ne "latest") { $argList += " -HERMES_VERSION $HERMES_VERSION" }
        if ($INSTALL_DIR -ne "C:\Program Files\HermesAgent") { $argList += " -INSTALL_DIR `"$INSTALL_DIR`"" }
        if ($HERMES_HOME -ne "$env:APPDATA\Hermes") { $argList += " -HERMES_HOME `"$HERMES_HOME`"" }
        if ($API_KEY) { $argList += " -API_KEY `"$API_KEY`"" }
        if ($PROVIDER) { $argList += " -PROVIDER `"$PROVIDER`"" }
        if ($SKIP_PROVIDER_CONFIG) { $argList += " -SKIP_PROVIDER_CONFIG" }
        if ($SKIP_AUTOSTART) { $argList += " -SKIP_AUTOSTART" }
        if ($SKIP_CONNECTIVITY_TEST) { $argList += " -SKIP_CONNECTIVITY_TEST" }
        if ($INSTALL_BROWSER_ACT) { $argList += " -INSTALL_BROWSER_ACT" }
        if ($SKIP_BROWSER_ACT) { $argList += " -SKIP_BROWSER_ACT" }
        Start-Process powershell -Verb RunAs -ArgumentList $argList
        exit
    }
}

# ============================================================
# 下载重试
# ============================================================
function Download-WithRetry {
    param([string]$Url, [string]$Output, [int]$MaxRetries = 3, [int]$TimeoutSec = 120)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Info "下载中 ($i/$MaxRetries): $Url"
            Invoke-WebRequest -Uri $Url -OutFile $Output -UseBasicParsing -TimeoutSec $TimeoutSec
            return $true
        } catch {
            Write-Warn "下载失败: $_"
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds 3 }
        }
    }
    Write-Err "下载失败 (已重试 $MaxRetries 次): $Url"
    return $false
}

# ============================================================
# 版本号查询
# ============================================================
function Query-HermesLatest {
    try {
        $json = Invoke-RestMethod -Uri "https://pypi.org/pypi/hermes-agent/json" -UseBasicParsing -TimeoutSec 15
        return $json.info.version
    } catch { return "" }
}

function Query-GithubLatest {
    param([string]$Repo, [string[]]$Keywords)
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 15
        $tag = $rel.tag_name -replace '^v',''
        $url = ""
        foreach ($a in $rel.assets) {
            $match = $true
            foreach ($kw in $Keywords) {
                if ($a.name -notlike "*$kw*") { $match = $false; break }
            }
            if ($match) { $url = $a.browser_download_url; break }
        }
        return @($tag, $url)
    } catch { return @("", "") }
}

function Get-InstalledHermesVersion {
    $cmd = Get-Command hermes -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $v = & hermes --version 2>$null
            $m = [regex]::Match($v, '(\d+\.\d+(?:\.\d+)?)')
            if ($m.Success) {
                $parts = $m.Groups[1].Value.Split('.')
                while ($parts.Count -lt 3) { $parts += '0' }
                return ($parts -join '.')
            }
        } catch {}
    }
    return ""
}

function Ver-GE {
    param([string]$a, [string]$b)
    if ($a -eq $b) { return $true }
    $aa = $a.Split('.'); $bb = $b.Split('.')
    for ($i = 0; $i -lt 3; $i++) {
        $ai = if ($i -lt $aa.Count) { [int]$aa[$i] } else { 0 }
        $bi = if ($i -lt $bb.Count) { [int]$bb[$i] } else { 0 }
        if ($ai -gt $bi) { return $true }
        if ($ai -lt $bi) { return $false }
    }
    return $true
}

# ============================================================
# 主流程
# ============================================================
Ensure-Admin

New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $HERMES_HOME | Out-Null

Write-Info "========== Hermes Agent 幂等安装开始 (Windows x64) =========="
Write-Info "安装目录: $INSTALL_DIR | 数据目录: $HERMES_HOME | 目标版本: $HERMES_VERSION"

# ---- Python 检测与安装 + 依赖记录 ----
$pythonNewlyInstalled = $false
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-Info "Python 未安装，开始安装 Python 3.12.4..."
    $offlinePython = Get-ChildItem -Path "$PSScriptRoot\..\offline-packages\windows-x64" -Filter "python-*-amd64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($offlinePython) {
        Write-Info "使用离线安装包: $($offlinePython.FullName)"
        Start-Process -FilePath $offlinePython.FullName -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait
    } else {
        $pythonUrl = "https://www.python.org/ftp/python/3.12.4/python-3.12.4-amd64.exe"
        $installer = "$env:TEMP\python-3.12.4-amd64.exe"
        if (Download-WithRetry -Url $pythonUrl -Output $installer) {
            Start-Process -FilePath $installer -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait
            Remove-Item $installer -Force -ErrorAction SilentlyContinue
        } else {
            Write-Err "Python 安装失败"
            exit 1
        }
    }
    $pythonNewlyInstalled = $true
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
Write-Info "Python: $(python --version)"

# 升级 pip（不计入新装清单）
Write-Info "升级 pip..."
try { python -m pip install --upgrade pip } catch { Write-Warn "pip 升级失败（不中断）" }

# 记录新装依赖清单（仅首次安装）
if (-not (Test-Path $DEPS_RECORD)) {
    $deps = @()
    if ($pythonNewlyInstalled) { $deps += "Python 3.12.4" }
    if ($deps.Count -gt 0) {
        $deps | Out-File -FilePath $DEPS_RECORD -Encoding UTF8
        Write-Info "本次新装依赖已记录到 $DEPS_RECORD"
    }
} else {
    Write-Info "检测到已存在依赖清单，跳过记录（升级模式）"
}

$pipMirrors = @(
    "https://mirrors.aliyun.com/pypi/simple/",
    "https://pypi.tuna.tsinghua.edu.cn/simple/",
    "https://pypi.mirrors.ustc.edu.cn/simple/"
)

# ---- 预先配置国内镜像源（必须在组件安装之前，确保 pip/npm 装包走国内源）----
Write-Info "配置 pip 国内镜像源（优先级：阿里 > 清华 > 中科大）..."
# pip 镜像在 pip_install_with_mirror 函数里按优先级使用，这里写一次全局配置
try {
    $pipConf = "$env:APPDATA\pip\pip.ini"
    New-Item -ItemType Directory -Force -Path (Split-Path $pipConf) | Out-Null
    # 用无 BOM 的 UTF-8 编码写文件（Out-File -Encoding UTF8 会添加 BOM，pip 不支持）
    $pipContent = "[global]`nindex-url = https://mirrors.aliyun.com/pypi/simple/`ntrusted-host = mirrors.aliyun.com"
    [System.IO.File]::WriteAllText($pipConf, $pipContent, (New-Object System.Text.UTF8Encoding $false))
    Write-Info "[OK] pip 镜像源已配置"
} catch { Write-Warn "pip 全局配置写入失败（不影响安装，pip_install_with_mirror 会按镜像源逐个尝试）" }

Write-Info "配置 npm 淘宝镜像源..."
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    try { npm config set registry https://registry.npmmirror.com/; Write-Info "[OK] npm 镜像源已配置" } catch { Write-Warn "npm 镜像配置失败" }
} else {
    Write-Info "[INFO] 未检测到 npm，跳过 npm 镜像配置（后续装飞书 CLI 若需 npm 会再用默认源）"
}

# ---- Hermes Agent 幂等安装 ----
Write-Info "处理 Hermes Agent..."
$installedHermes = Get-InstalledHermesVersion
$hermesWasInstalled = [bool]$installedHermes
$onlineHermes = Query-HermesLatest
$offlineWheel = Get-ChildItem -Path "$PSScriptRoot\..\offline-packages\windows-x64" -Filter "hermes_agent-*-py3-none-any.whl" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1

$targetHermes = if ($HERMES_VERSION -ne "latest") { $HERMES_VERSION }
                elseif ($offlineWheel) { [regex]::Match($offlineWheel.Name, 'hermes_agent-(\d+\.\d+\.\d+)').Groups[1].Value }
                elseif ($onlineHermes) { $onlineHermes }
                else { "" }

$shouldInstall = $true
if ($installedHermes -and $targetHermes) {
    if ($installedHermes -eq $targetHermes) {
        Write-Info "Hermes Agent 已是目标版本 $installedHermes，跳过"
        Write-Info "[IDEMPOTENT_SKIP] hermes already at target version"
        $shouldInstall = $false
    } elseif (Ver-GE $installedHermes $targetHermes) {
        Write-Info "Hermes Agent 已装 $installedHermes >= 目标 $targetHermes，跳过（不降级）"
        Write-Info "[IDEMPOTENT_SKIP] hermes installed >= target, skip downgrade"
        $shouldInstall = $false
    } else {
        Write-Info "Hermes Agent 已装 $installedHermes，升级到 $targetHermes"
    }
} elseif ($installedHermes) {
    Write-Info "Hermes Agent 已装 $installedHermes，无目标版本可比，跳过"
    Write-Info "[IDEMPOTENT_SKIP] hermes installed, no target version to compare"
    $shouldInstall = $false
}

if ($shouldInstall) {
    if ($offlineWheel) {
        Write-Info "使用离线包: $($offlineWheel.Name)"
        try { pip install $offlineWheel.FullName } catch { Write-Warn "离线包安装失败（可能缺 transitive deps）" }
    } elseif ($targetHermes) {
        foreach ($mirror in $pipMirrors) {
            try {
                pip install "hermes-agent==$targetHermes" -i $mirror --trusted-host ($mirror -replace 'https?://([^/]+).*','$1')
                if ($LASTEXITCODE -eq 0) { break }
            } catch { Write-Warn "源 $mirror 失败" }
        }
    } else {
        Write-Warn "无法获取 Hermes Agent 版本（无网且无离线包），Hermes 暂时装不了"
    }
}

# 验证 hermes 安装结果
$hermesInstalled = $false
$hermesVersion = ""
if (Get-Command hermes -ErrorAction SilentlyContinue) {
    try {
        $v = & hermes --version 2>$null
        $m = [regex]::Match($v, '(\d+\.\d+(?:\.\d+)?)')
        if ($m.Success) {
            $hermesVersion = $m.Groups[1].Value
            $hermesInstalled = $true
            Write-Info "[OK] Hermes Agent v$hermesVersion 安装成功"
        }
    } catch {}
}
if (-not $hermesInstalled) {
    Write-Warn "[FAIL] Hermes Agent 安装失败或无法验证"
} else {
    # 只记录新装的组件（原本不存在 + 安装成功）
    if (-not $hermesWasInstalled) {
        Add-InstalledComponent "hermes-agent"
    }
}

# ---- 飞书 CLI 幂等安装 ----
Write-Info "处理飞书 CLI..."
$larkDir = "$INSTALL_DIR\lark"
New-Item -ItemType Directory -Force -Path $larkDir | Out-Null
$larkWasInstalled = Test-Path "$larkDir\lark.exe"
$offlineLark = "$PSScriptRoot\..\offline-packages\windows-x64\lark.exe"
if (Test-Path $offlineLark) {
    Write-Info "使用离线飞书 CLI"
    Copy-Item $offlineLark "$larkDir\lark.exe" -Force
    if (-not $larkWasInstalled) { Add-InstalledComponent "lark" }
} elseif ($larkWasInstalled) {
    Write-Info "飞书 CLI 已装，跳过"
} else {
    $larkInstalled = $false
    # GitHub API 查 assets
    $kw = @("windows", "amd64")
    $larkRel = Query-GithubLatest "larksuite/cli" $kw
    $larkTag = $larkRel[0]; $larkUrl = $larkRel[1]
    if ($larkUrl) {
        Write-Info "飞书 CLI 最新版: $larkTag，下载中..."
        $larkZip = "$env:TEMP\lark.zip"
        try {
            Invoke-WebRequest -Uri $larkUrl -OutFile $larkZip -UseBasicParsing -TimeoutSec 60
            Expand-Archive -Path $larkZip -DestinationPath "$larkDir\temp" -Force
            $exe = Get-ChildItem -Path "$larkDir\temp" -Recurse -Filter "lark.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { Copy-Item $exe.FullName "$larkDir\lark.exe" -Force; $larkInstalled = $true }
            Remove-Item "$larkDir\temp" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $larkZip -Force -ErrorAction SilentlyContinue
        } catch { Write-Warn "飞书 CLI 下载失败: $_" }
    }
    # npm 兜底
    if (-not $larkInstalled -and (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Info "通过 npm 安装飞书 CLI..."
        try { npm install -g @larksuite/cli; if ($LASTEXITCODE -eq 0) { $larkInstalled = $true } } catch {}
    }
    if (-not $larkInstalled) { Write-Warn "飞书 CLI 安装失败，请手动安装: npm install -g @larksuite/cli" }
    else {
        # 只记录新装的组件（原本不存在 + 安装成功）
        if (-not $larkWasInstalled) { Add-InstalledComponent "lark" }
    }
}

# 验证飞书 CLI 安装结果
if (Test-Path "$larkDir\lark.exe") {
    try {
        $larkVer = & "$larkDir\lark.exe" --version 2>$null
        if ($larkVer) { Write-Info "[OK] 飞书 CLI 安装成功" }
        else { Write-Warn "[FAIL] 飞书 CLI 安装失败或无法验证" }
    } catch { Write-Warn "[FAIL] 飞书 CLI 安装失败或无法验证" }
} else {
    Write-Warn "[FAIL] 飞书 CLI 安装失败：$larkDir\lark.exe 不存在"
}

# ---- CC-Switch 幂等安装 + 回滚 ----
Write-Info "处理 CC-Switch..."
$ccInstalled = $false
$ccInstalledViaMsi = $false

# 幂等检测：已装则跳过
$existingCc = $null
foreach ($path in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")) {
    $app = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*CC-Switch*" }
    if ($app) { $existingCc = $app; break }
}
$ccWasInstalled = [bool]$existingCc
if ($existingCc) {
    Write-Info "CC-Switch 已装，跳过"
    $ccInstalled = $true
} else {
    $offlineCC = Get-ChildItem -Path "$PSScriptRoot\..\offline-packages\windows-x64" -Filter "CC-Switch-*-Windows.msi" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    $ccPkg = $null
    if ($offlineCC) {
        Write-Info "使用离线 CC-Switch: $($offlineCC.Name)"
        $ccPkg = $offlineCC.FullName
    } else {
        # CC-Switch 资产命名: CC-Switch-v{版本}-Windows.msi（另有 -Windows-Portable.zip，需避开）
        $kw = @("Windows.msi")
        $ccRel = Query-GithubLatest "farion1231/cc-switch" $kw
        $ccTag = $ccRel[0]; $ccUrl = $ccRel[1]
        if ($ccUrl) {
            Write-Info "CC-Switch 最新版: $ccTag，下载中..."
            $ext = if ($ccUrl -match '\.msi$') { ".msi" } elseif ($ccUrl -match '\.exe$') { ".exe" } else { ".bin" }
            $ccTmp = "$env:TEMP\cc-switch$ext"
            if (Download-WithRetry -Url $ccUrl -Output $ccTmp -MaxRetries 1) {
                $ccPkg = $ccTmp
            }
        } else {
            Write-Warn "未匹配到 CC-Switch Windows 资产。可改用离线包"
        }
    }

    if ($ccPkg) {
        $ccOk = $false
        if ($ccPkg -match '\.msi$') {
            $p = Start-Process msiexec -ArgumentList "/i `"$ccPkg`" /qn" -Wait -PassThru
            if ($p.ExitCode -eq 0) { $ccOk = $true; $ccInstalledViaMsi = $true }
        } elseif ($ccPkg -match '\.exe$') {
            $p = Start-Process $ccPkg -ArgumentList "/S" -Wait -PassThru
            if ($p.ExitCode -eq 0) { $ccOk = $true }
        }
        if ($ccOk) {
            Write-Info "CC-Switch 安装成功"
            $ccInstalled = $true
            # 只记录新装的组件（原本不存在 + 安装成功）
            if (-not $ccWasInstalled) { Add-InstalledComponent "cc-switch" }
        } else {
            Write-Warn "CC-Switch 安装失败，回滚..."
            # 无条件查注册表，有残留就卸（MSI 静默安装失败也可能部分写入注册表）
            $app = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*CC-Switch*" }
            if ($app) { Start-Process msiexec -ArgumentList "/x $($app.PSChildName) /qn" -Wait -ErrorAction SilentlyContinue }
            Remove-Item $ccPkg -Force -ErrorAction SilentlyContinue
            Write-Warn "CC-Switch 已回滚，将改用 Hermes 官方配置方式"
        }
    }
}

# ---- 环境变量 ----
Write-Info "配置环境变量..."
$currentPath = [System.Environment]::GetEnvironmentVariable("Path","Machine")
if ($currentPath -notlike "*$INSTALL_DIR*") {
    [System.Environment]::SetEnvironmentVariable("Path","$currentPath;$INSTALL_DIR;$larkDir","Machine")
}
[System.Environment]::SetEnvironmentVariable("HERMES_HOME",$HERMES_HOME,"Machine")

# npm 镜像已在组件安装前配置（见脚本前部"预先配置国内镜像源"段）

# ---- AI 后端配置 ----
if (-not $SKIP_PROVIDER_CONFIG) {
    if (-not $PROVIDER) {
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║        选择 AI 推理后端                             ║" -ForegroundColor Cyan
        Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "║  [1] 阿里百炼 Coding Plan (qwen3.7-plus)           ║"
        Write-Host "║  [2] DeepSeek (deepseek-v4-pro / deepseek-v4-flash) ║"
        Write-Host "║  [0] 跳过配置，稍后手动设置                         ║"
        Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        $pc = Read-Host "  请选择 [1/2/0，默认 1]"
        $pc = if ($pc) { $pc } else { "1" }
        switch ($pc) { "1" { $PROVIDER="bailian" } "2" { $PROVIDER="deepseek" } "0" { $PROVIDER="none" } default { $PROVIDER="bailian" } }
    }

    $cfgProvider=""; $cfgBaseUrl=""; $cfgApiMode=""; $cfgModel=""; $cfgApiKey=""
    if ($PROVIDER -eq "bailian") {
        $cfgProvider="custom"; $cfgBaseUrl="https://coding.dashscope.aliyuncs.com/v1"; $cfgApiMode="openai"; $cfgModel="qwen3.7-plus"
        if ($API_KEY) { $cfgApiKey=$API_KEY } else {
            Write-Host ""
            Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "║  🔑 阿里百炼 Coding Plan — API Key 配置                ║" -ForegroundColor Cyan
            Write-Host "║  获取 API Key:                                          ║"
            Write-Host "║  👉 https://bailian.console.aliyun.com/                 ║" -ForegroundColor Yellow
            Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            $ik = Read-Host "  API Key (输入 SKIP 跳过)"
            if ($ik -and $ik -ne "SKIP" -and $ik -ne "skip") { $cfgApiKey=$ik }
        }
    } elseif ($PROVIDER -eq "deepseek") {
        $cfgProvider="deepseek"; $cfgBaseUrl="https://api.deepseek.com/v1"; $cfgApiMode=""; $cfgModel="deepseek-v4-pro"
        if ($API_KEY) { $cfgApiKey=$API_KEY } else {
            Write-Host ""
            Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "║  🔑 DeepSeek — API Key 配置                            ║" -ForegroundColor Cyan
            Write-Host "║  获取 API Key:                                          ║"
            Write-Host "║  👉 https://platform.deepseek.com/api_keys               ║" -ForegroundColor Yellow
            Write-Host "║  可选模型: deepseek-v4-pro(默认) / deepseek-v4-flash     ║"
            Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            $ik = Read-Host "  API Key (输入 SKIP 跳过)"
            if ($ik -and $ik -ne "SKIP" -and $ik -ne "skip") { $cfgApiKey=$ik }
            $mc = Read-Host "  选择模型 [1=pro / 2=flash，默认 1]"
            if ($mc -eq "2") { $cfgModel="deepseek-v4-flash" }
        }
    }

    if ($cfgProvider -and $cfgBaseUrl) {
        Write-Info "写入 Hermes 配置到 $HERMES_HOME\config.yaml..."
        New-Item -ItemType Directory -Force -Path $HERMES_HOME | Out-Null
        # API Key 直接写 model.api_key，Hermes credential pool 会读取
        # 避开 hermes config set 已知 bug，且避开 .env 环境变量名推导的不确定性
        $lines = @("model:","  provider: $cfgProvider","  base_url: $cfgBaseUrl","  default: $cfgModel")
        if ($cfgApiMode) { $lines += "  api_mode: $cfgApiMode" }
        if ($cfgApiKey) { $lines += "  api_key: $cfgApiKey" }
        $content = ($lines -join "`n") + "`n"
        [System.IO.File]::WriteAllText("$HERMES_HOME\config.yaml",$content,[System.Text.UTF8Encoding]::new($false))

        # .env 兜底：按 base_url 主机名推导环境变量名（Hermes 查找链第 6 步）
        $envContent = ""
        if ($cfgApiKey) {
            $envVarName = if ($cfgBaseUrl -match "dashscope|aliyuncs") { "DASHSCOPE_API_KEY" }
                          elseif ($cfgBaseUrl -match "deepseek") { "DEEPSEEK_API_KEY" }
                          else { "HERMES_API_KEY" }
            $envContent = "$envVarName=$cfgApiKey`n"
            [System.IO.File]::WriteAllText("$HERMES_HOME\.env",$envContent,[System.Text.UTF8Encoding]::new($false))
            Write-Info "API Key 已写入 config.yaml (model.api_key) 和 .env ($envVarName)"
        }
        $defaultHome = Join-Path $env:USERPROFILE ".hermes"
        if ($defaultHome -ne $HERMES_HOME) {
            New-Item -ItemType Directory -Force -Path $defaultHome | Out-Null
            [System.IO.File]::WriteAllText("$defaultHome\config.yaml",$content,[System.Text.UTF8Encoding]::new($false))
            if ($cfgApiKey) { [System.IO.File]::WriteAllText("$defaultHome\.env",$envContent,[System.Text.UTF8Encoding]::new($false)) }
            Write-Info "配置已同步写入 $defaultHome"
        }
        Write-Info "配置验证: provider=$cfgProvider model=$cfgModel api_key=$(if($cfgApiKey){'***'}else{'(未配置)'})"

        if ($cfgApiKey -and -not $SKIP_CONNECTIVITY_TEST) {
            Write-Info "连通性测试（30s 超时）..."
            try {
                $p = Start-Process hermes -ArgumentList 'chat','-q','你好','--max-turns','1' -NoNewWindow -PassThru -ErrorAction SilentlyContinue
                if (-not $p.WaitForExit(30000)) {
                    try { $p.Kill() } catch {}
                    Write-Warn "连通性测试超时（30s，不中断；可 -SKIP_CONNECTIVITY_TEST 跳过）"
                } else {
                    Write-Info "连通性测试已执行（失败不中断）"
                }
            } catch { Write-Warn "连通性测试失败（不中断）" }
        }
    } else {
        Write-Info "跳过 AI 后端配置"
    }
}

# ---- 安装后验证 ----
Write-Info "========== 安装后验证 =========="
$verifyPassed = 0
$verifyFailed = 0

# hermes 验证
$hermesCmd = Get-Command hermes -ErrorAction SilentlyContinue
if ($hermesCmd) {
    try { $hv = & hermes --version 2>$null; Write-Info "[PASS] hermes: $hv"; $verifyPassed++ }
    catch { Write-Warn "[FAIL] hermes 验证失败"; $verifyFailed++ }
} else {
    Write-Warn "[FAIL] hermes 未找到"; $verifyFailed++
}

# lark 验证
if (Test-Path "$larkDir\lark.exe") {
    try { $lv = & "$larkDir\lark.exe" --version 2>$null; Write-Info "[PASS] lark: $lv"; $verifyPassed++ }
    catch { Write-Warn "[FAIL] lark 验证失败"; $verifyFailed++ }
} else {
    Write-Warn "[FAIL] lark 未找到"; $verifyFailed++
}

# CC-Switch 验证
if ($ccInstalled) {
    Write-Info "[PASS] CC-Switch: 已安装"
    $verifyPassed++
} else {
    Write-Info "[INFO] CC-Switch: 未安装（用 Hermes 官方配置方式）"
}

# 验证总结
if ($verifyFailed -eq 0) {
    Write-Info "✅ 安装后验证全部通过 ($verifyPassed 项)"
} else {
    Write-Warn "⚠️ 安装后验证部分失败（通过 $verifyPassed 项，失败 $verifyFailed 项）"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  安装完成!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Hermes Agent: $INSTALL_DIR"
Write-Host "  数据目录: $HERMES_HOME"
Write-Host "  CC-Switch: $(if($ccInstalled){'已安装'}else{'未安装（用 Hermes 官方配置）'})"
Write-Host "  请重开终端使环境变量生效" -ForegroundColor Yellow
Write-Host "  日志: $LOG_FILE" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green

# ---- browser-act 可选安装 ----
if (-not $SKIP_BROWSER_ACT) {
    $doBa = $INSTALL_BROWSER_ACT
    $browserActWasInstalled = [bool](Get-Command browser-act -ErrorAction SilentlyContinue)
    if (-not $doBa) {
        Write-Host ""
        $ba = Read-Host "  是否安装 browser-act（浏览器自动化 CLI，需要 Python 3.12+ 与 uv）？[y/N，默认 N]"
        if ($ba -match '^[Yy]') { $doBa = $true }
    }
    if ($doBa) {
        # browser-act 是 Python 工具，通过 uv 安装（PyPI 包名 browser-act-cli），自带浏览器引擎
        $uvCmd = Get-Command uv -ErrorAction SilentlyContinue
        if (-not $uvCmd) {
            Write-Info "未检测到 uv，尝试安装 uv..."
            try {
                $uvInstaller = "$env:TEMP\uv-install.ps1"
                Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -OutFile $uvInstaller -UseBasicParsing -TimeoutSec 60
                & powershell -ExecutionPolicy Bypass -File $uvInstaller
                Remove-Item $uvInstaller -Force -ErrorAction SilentlyContinue
                # 刷新 PATH
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            } catch { Write-Warn "uv 安装失败: $_" }
        }
        $uvCmd = Get-Command uv -ErrorAction SilentlyContinue
        if (-not $uvCmd) {
            Write-Warn "未检测到 uv，请手动安装 uv（powershell -c \"irm https://astral.sh/uv/install.ps1 | iex\"）后再装 browser-act"
        } else {
            Write-Info "通过 uv 安装 browser-act-cli（需要 Python 3.12+）..."
            try { & uv tool install browser-act-cli --python 3.12; Write-Info "browser-act 安装成功"
                if (-not $browserActWasInstalled) { Add-InstalledComponent "browser-act" }
            }
            catch { Write-Warn "browser-act 安装失败（可能 Python 3.12 不可用）。可手动: uv tool install browser-act-cli --python 3.12" }
        }
    }
}

# ---- 自动启动 CC-Switch + 自启动 ----
if (-not $SKIP_AUTOSTART -and $ccInstalled) {
    Write-Info "尝试启动 CC-Switch..."
    $ccPath = $null
    # 1. 从注册表读 InstallLocation（最可靠，MSI 安装会写入）
    $ccReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*CC-Switch*" } | Select-Object -First 1
    if ($ccReg -and $ccReg.InstallLocation) {
        $candidate = Join-Path $ccReg.InstallLocation "CC-Switch.exe"
        if (Test-Path $candidate) { $ccPath = $candidate }
    }
    # 2. 兜底：常见路径
    if (-not $ccPath) {
        foreach ($p in @("C:\Program Files\CC-Switch\CC-Switch.exe","C:\Program Files (x86)\CC-Switch\CC-Switch.exe","$env:LOCALAPPDATA\CC-Switch\CC-Switch.exe","$env:LOCALAPPDATA\Programs\CC-Switch\CC-Switch.exe")) {
            if (Test-Path $p) { $ccPath = $p; break }
        }
    }
    # 3. 兜底：PATH
    if (-not $ccPath) { $ccPath = (Get-Command "CC-Switch" -ErrorAction SilentlyContinue).Source }

    $ccLaunchOk = $false
    if ($ccPath) {
        try { Start-Process $ccPath; Write-Info "CC-Switch 已启动"; $ccLaunchOk = $true } catch { Write-Warn "启动失败: $_" }
    } else { Write-Warn "未找到 CC-Switch 可执行文件" }

    if ($ccLaunchOk) {
        Write-Host ""
        $ac = Read-Host "  是否设置 CC-Switch 开机自启动？[Y/n，默认 Y]"
        if (-not $ac -or $ac -match '^[Yy]') {
            $commonStartup = [Environment]::GetFolderPath("CommonStartup")
            $shortcutPath = Join-Path $commonStartup "CC-Switch.lnk"
            try {
                $wsh = New-Object -ComObject WScript.Shell
                $sc = $wsh.CreateShortcut($shortcutPath)
                $sc.TargetPath = $ccPath
                $sc.WorkingDirectory = Split-Path $ccPath
                $sc.Description = "CC-Switch 开机自启动"
                $sc.Save()
                Write-Info "CC-Switch 已设置为开机自启动（所有用户）"
            } catch { Write-Warn "自启动配置失败: $_" }
        }
    }
}

Write-Info "========== 安装流程结束 =========="
