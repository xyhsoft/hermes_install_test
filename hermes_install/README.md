# Hermes Agent + 飞书CLI + CC-Switch 多平台幂等安装脚本包

## 概述

跨平台、系统级、离线优先、**幂等**的安装脚本包,支持一键安装 Hermes Agent、飞书CLI 和 CC-Switch。

**幂等**:install 脚本自带"没装就新装、版本低就升级、最新就跳过",重复执行 install 即升级,**不再提供独立 upgrade 脚本**。

安装完成后默认配置 **阿里百炼 Coding Plan** 作为 Hermes Agent 推理后端(模型 `qwen3.7-plus`),也可选 DeepSeek。

> **UOS 20 等老旧系统说明**:CC-Switch 是 Tauri(WebKit2GTK)桌面应用,在 UOS 20(Debian 10 buster,glibc 2.28、webkit2gtk 2.24)上可能无法运行。脚本会**能力预检**,不达标自动跳过 CC-Switch 并回滚,改用 Hermes 官方配置方式(写 `config.yaml` + `.env`)完成大模型配置。Hermes Agent 与飞书 CLI 不受影响。

## 支持的系统

| 系统 | 架构 | 安装脚本 |
|------|------|---------|
| Windows 10/11 | x64 | `install-windows.ps1` |
| Ubuntu / UOS / 银河麒麟 | x64 / arm64 | `install.sh` |
| CentOS 7/8 | x64 / arm64 | `install.sh` |
| macOS 11+ | Intel / Apple Silicon | `install.sh` |

> `install.sh` 内部按 `uname -m` + 包管理器(apt/yum/dnf/brew)自动适配架构与发行版,一个脚本通吃 Linux + macOS。

## ⚠️ 执行前准备(必读)

### 1. 进入 `hermes_install` 目录

所有命令需在 **`hermes_install` 目录内**执行:

```powershell
# Windows
cd <安装包所在路径>\hermes_install
```
```bash
# Linux / macOS
cd <安装包所在路径>/hermes_install
```

### 2. Windows PowerShell 执行策略

```powershell
# 管理员 PowerShell 中执行一次
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
# 或一次性绕过
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

### 3. Linux / macOS 脚本执行权限

```bash
chmod +x scripts/*.sh
```

### 4. 离线包(可选)

`offline-packages/<架构>/` 目录默认为空。若需离线安装,请在执行 install 前**手工**把对应离线包(hermes wheel、lark、CC-Switch 安装包、Windows 的 python 安装包)放入对应架构子目录。

> 离线模式限制:离线 wheel 的传递依赖(transitive deps)仍需联网安装。无网环境下若传递依赖缺失,脚本会明确提示"离线模式暂不支持自动补齐依赖",并跳过该组件,不会硬撑装坏。

---

## 快速开始

### 在线安装(推荐)

```powershell
# Windows
.\scripts\install-windows.ps1
```
```bash
# Linux / macOS
sudo bash scripts/install.sh
```

安装时会交互式选择 AI 后端(阿里百炼 / DeepSeek)并输入 API Key。

### 幂等:重复执行即升级

```bash
# 已装且是最新 → 跳过;已装且版本旧 → 升级;未装 → 新装
sudo bash scripts/install.sh
```

### 指定版本 / 自定义路径

```bash
sudo bash scripts/install.sh 0.16.0
sudo bash scripts/install.sh latest /opt/hermes /data/hermes
```
```powershell
.\scripts\install-windows.ps1 -HERMES_VERSION 0.16.0 -INSTALL_DIR "D:\Hermes" -HERMES_HOME "D:\HermesData"
```

### 无人值守(自动化)

```bash
sudo bash scripts/install.sh --provider deepseek --api-key "sk-xxxxxxxxxxxx"
sudo bash scripts/install.sh --provider bailian --api-key "sk-xxxxxxxxxxxx"
sudo bash scripts/install.sh --skip-provider-config
sudo bash scripts/install.sh --skip-autostart
sudo bash scripts/install.sh --skip-connectivity-test
sudo bash scripts/install.sh --install-browser-act   # 直接装 browser-act
sudo bash scripts/install.sh --skip-browser-act       # 跳过 browser-act
```
```powershell
.\scripts\install-windows.ps1 -PROVIDER "deepseek" -API_KEY "sk-xxxxxxxxxxxx"
.\scripts\install-windows.ps1 -SKIP_PROVIDER_CONFIG
.\scripts\install-windows.ps1 -SKIP_AUTOSTART
.\scripts\install-windows.ps1 -SKIP_CONNECTIVITY_TEST
.\scripts\install-windows.ps1 -INSTALL_BROWSER_ACT
```

### 选择 AI 推理后端

| 后端 | provider 参数 | 默认模型 | API Key 获取 |
|------|-------------|---------|-------------|
| 阿里百炼 Coding Plan | `--provider bailian`(默认) | `qwen3.7-plus` | https://bailian.console.aliyun.com/ |
| DeepSeek | `--provider deepseek` | `deepseek-v4-pro` | https://platform.deepseek.com/api_keys |

> DeepSeek 交互模式还可选模型(`deepseek-v4-pro` 或 `deepseek-v4-flash`)。

### browser-act(可选)

安装末尾会询问是否安装 browser-act(浏览器自动化 CLI,通过 `uv tool install browser-act-cli` 安装,需 Python 3.12+ 与 uv,自带浏览器引擎)。不影响主安装流程。

---

## 卸载

```bash
# Linux / macOS
sudo bash scripts/uninstall.sh
sudo bash scripts/uninstall.sh --remove-config   # 连配置一起删
sudo bash scripts/uninstall.sh --remove-deps     # 连本次新装的系统依赖一起卸
```
```powershell
# Windows
.\scripts\uninstall-windows.ps1
.\scripts\uninstall-windows.ps1 -REMOVE_CONFIG
.\scripts\uninstall-windows.ps1 -REMOVE_DEPS
```

**新装依赖卸载策略**:卸载时会读取 `$HERMES_HOME/installed-deps.txt`(首次安装时记录的本次新装系统依赖清单),**默认保留,用户输入 y 或加 `--remove-deps` 才卸**。卸前会校验包是否还在,避免误删。公共依赖(python3/curl 等)默认保留,需显式确认。

---

## 离线安装

1. 在有网络的环境下载离线包,放入 `offline-packages/<架构>/`
2. 将整个目录复制到目标机器
3. 执行安装脚本,自动检测并使用离线包

### 离线包命名约定

| 类型 | 命名格式 |
|------|---------|
| Hermes Agent | `hermes_agent-<版本>-py3-none-any.whl` |
| Python (Windows) | `python-<版本>-amd64.exe` |
| 飞书CLI | `lark` / `lark.exe` |
| CC-Switch (Windows) | `CC-Switch-<版本>-Windows.msi` |
| CC-Switch (Linux Debian) | `CC-Switch-<版本>-Linux-x86_64.deb` |
| CC-Switch (Linux RedHat) | `CC-Switch-<版本>-Linux-x86_64.rpm` |
| CC-Switch (Linux arm64) | `CC-Switch-<版本>-Linux-arm64.AppImage` |
| CC-Switch (macOS) | `CC-Switch-<版本>-macOS.dmg` |

---

## 目录结构

```
hermes_install/
├── scripts/
│   ├── _common.sh                # 公共函数库
│   ├── install.sh                # Linux/macOS 幂等安装器
│   ├── install-windows.ps1       # Windows 幂等安装器
│   ├── uninstall.sh              # Linux/macOS 卸载
│   └── uninstall-windows.ps1     # Windows 卸载
├── offline-packages/             # 离线包(空壳,用户手工填)
│   ├── windows-x64/  linux-x64/  linux-arm64/
│   ├── centos-x64/   centos-arm64/
│   └── macos-x64/    macos-arm64/
└── README.md
```

## 安装路径

| 系统 | 程序目录 | 数据目录 |
|------|---------|---------|
| Windows | `C:\Program Files\HermesAgent` | `%APPDATA%\Hermes` |
| Linux | `/usr/local/hermes` | `/var/lib/hermes` |
| macOS | `/usr/local/hermes` | `/Library/Application Support/Hermes` |

## 默认 AI 后端配置

### 阿里百炼 Coding Plan(默认)

| 配置项 | 值 |
|--------|-----|
| provider | `custom` |
| base_url | `https://coding.dashscope.aliyuncs.com/v1` |
| api_mode | `openai` |
| default model | `qwen3.7-plus` |

### DeepSeek

| 配置项 | 值 |
|--------|-----|
| provider | `deepseek` |
| base_url | `https://api.deepseek.com/v1` |
| default model | `deepseek-v4-pro` |
| 备选模型 | `deepseek-v4-flash` |

## CC-Switch 能力预检说明

CC-Switch 是 Tauri(WebKit2GTK)桌面应用,Linux 上对系统库要求较新。install 脚本在安装 CC-Switch 前做预检:

- glibc ≥ 2.26
- webkit2gtk-4.0/4.1 存在

不达标(如 UOS 20)自动跳过 CC-Switch,改用 Hermes 官方配置方式。安装失败也会自动回滚。

## 版本查询说明

Hermes Agent / CC-Switch / 飞书 CLI 的版本号均**实时查询官网/GitHub 最新稳定版**,不硬编码。CC-Switch 和飞书 CLI 通过 GitHub Releases API 读取 `assets[]` 按平台关键词匹配实际下载地址,适应任意命名风格。
