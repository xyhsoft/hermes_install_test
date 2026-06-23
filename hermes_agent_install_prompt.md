# Hermes Agent + 飞书CLI + CC-Switch 多平台幂等安装脚本包 — 需求规格说明

## 一、目标概述

构建一套**跨平台、系统级、离线优先、幂等**的 Hermes Agent + 飞书CLI + CC-Switch 安装脚本包。将整个目录复制到任意目标环境即可运行。安装脚本本身具备"没装就新装、版本低就升级、最新就跳过"的幂等能力,因此**不再提供独立的 upgrade 脚本**——重复执行 install 即升级。安装完成后支持选择 **阿里百炼 Coding Plan** 或 **DeepSeek** 作为 Hermes Agent 推理后端。

CC-Switch 在部分老旧系统(如 UOS 20,glibc/webkit 版本不足)可能无法安装,脚本会**能力预检 + 安装失败回滚**,CC-Switch 装不上时自动改用 Hermes 官方配置方式(写 `config.yaml` + `.env`)完成大模型配置。

---

## 二、支持的系统环境

| 序号 | 系统 | 架构 | 安装脚本 |
|------|------|------|---------|
| 1 | Windows 10/11 | x64 | `install-windows.ps1` |
| 2 | UOS / Ubuntu 20.04+ | x64 | `install.sh` |
| 3 | 银河麒麟 V10 | arm64 | `install.sh` |
| 4 | macOS 11+ | Intel / Apple Silicon | `install.sh` |

> CentOS 7/8 已 EOL 且官方 yum 源失效,不再作为支持系统。`install.sh` 仍保留 RedHat 系(yum/dnf)分支,如需在 RHEL/Rocky/AlmaLinux 等仍在维护的 RedHat 系发行版上使用,通常可用,但未纳入 CI 测试。

### 2.1 架构与发行版自动适配

`install.sh` 内部通过 `uname -m` + 包管理器探测(`apt`/`yum`/`dnf`/`brew`)自动选择:
- 架构分支:`x86_64` → x64,`aarch64` → arm64
- 离线包子目录:`linux-x64`/`linux-arm64`/`centos-x64`/`centos-arm64`/`macos-x64`/`macos-arm64`
- 包管理器:Debian 系 apt、RedHat 系 yum/dnf、macOS brew

Windows 为独立 PowerShell 脚本,仅支持 x64。

---

## 三、安装方式

### 3.1 在线安装(默认推荐)

- 直接执行对应系统的安装脚本
- 脚本自动下载所有依赖(Python、pip 包、飞书CLI、CC-Switch)
- 下载失败自动重试 **3 次**,间隔 3 秒;CC-Switch 在线下载为快速切换,每个代理只试 1 次

### 3.2 离线安装

- 在有网络的环境提前下载离线包,放入对应架构的 `offline-packages/` 子目录
- 脚本检测到离线包后**优先使用离线包**,跳过网络下载
- **离线模式限制**:离线 wheel 的 transitive(传递)依赖仍需联网安装;无网环境下若 transitive deps 缺失,**明确提示"离线模式暂不支持自动补齐依赖,请改用在线安装或自行补齐离线包"并跳过该组件**,不硬撑、不中断整体流程
- 离线包目录默认为空壳,用户在执行 install 前需手工填入离线包文件

### 3.3 幂等安装(核心设计)

install 脚本对 Hermes Agent / 飞书CLI / CC-Switch 三个组件统一执行"检测 → 比对 → 动作":

| 当前状态 | 在线最新版 | 动作 |
|---------|-----------|------|
| 未安装 | 任意 | 新装(首次新装系统依赖时记录清单) |
| 已装,版本 < 最新 | 任意 | 升级(不重新记依赖清单) |
| 已装,版本 = 最新 | 任意 | 提示"已是最新",跳过 |
| 已装,版本 > 最新(离线包比在线新) | — | 提示并跳过(不降级) |

因此 **upgrade 脚本已废弃**,重复执行 install 即可完成升级。

### 3.4 旁路规则(无人值守)

用户通过命令行参数显式指定版本/后端时,跳过对应交互:

- `install.sh 0.16.0` → 指定 Hermes 版本,跳过版本选择交互
- `install.sh --provider deepseek --api-key "sk-xxx"` → 指定后端 + Key,跳过所有交互
- `install.sh --skip-provider-config` → 跳过 AI 后端配置
- `install.sh --skip-autostart` → 跳过自动启动 + 自启动
- `install.sh --skip-connectivity-test` → 跳过 hermes chat 连通性测试
- `install.sh --install-browser-act` / `--skip-browser-act` → 直接装/跳过 browser-act

---

## 四、安装路径与数据目录

### 4.1 默认路径

| 系统 | 程序安装目录 | 数据目录(`HERMES_HOME`) | CC-Switch 安装目录 |
|------|-------------|--------------------------|-------------------|
| Windows | `C:\Program Files\HermesAgent` | `%APPDATA%\Hermes` | `C:\Program Files\CC-Switch`(MSI 默认) |
| Linux | `/usr/local/hermes` | `/var/lib/hermes` | `/opt/cc-switch`(AppImage)或系统包管理器默认路径 |
| macOS | `/usr/local/hermes` | `/Library/Application Support/Hermes` | `/Applications/CC-Switch.app` |

### 4.2 自定义路径

```bash
# Linux/macOS:参数顺序 = <版本号> <安装目录> <数据目录>
sudo bash install.sh latest /opt/hermes /data/hermes
```

```powershell
# Windows:命名参数
.\install-windows.ps1 -INSTALL_DIR "D:\Programs\Hermes" -HERMES_HOME "D:\Data\Hermes"
```

### 4.3 安装后提示

明确输出:Hermes Agent 位置、数据目录位置、CC-Switch 状态(已装/未装-改用官方配置)、重开终端使环境变量生效、数据目录定期清理提示。

---

## 五、依赖安装与清单记录

### 5.1 Windows

- 自动检测 Python,未安装则自动下载/离线安装 `Python 3.12.4 amd64`(`InstallAllUsers=1 PrependPath=1`)
- 自动升级 pip

### 5.2 Linux(Debian 系:Ubuntu/UOS/麒麟)

- `apt` 安装:`python3 python3-pip python3-venv curl wget ca-certificates`
- 自动升级 pip

### 5.3 Linux(RedHat 系:RHEL / Rocky / AlmaLinux / 银河麒麟)

- `yum`/`dnf` 安装:`epel-release`(若可用) → `python3 python3-pip curl wget ca-certificates`
- 自动升级 pip
- 注:CentOS 7/8 已 EOL、官方源失效,不在支持列表;其它仍在维护的 RedHat 系发行版通常可用

### 5.4 macOS

- 自动检测 Homebrew,未安装则通过国内镜像源(Gitee)安装
- `brew` 安装 `python3`
- 自动升级 pip

### 5.5 新装依赖清单记录(卸载依据)

**首次新装系统依赖时**,脚本在安装前后各做一次已装包快照(`dpkg-query` / `rpm -qa` / `brew list`),**差集 = 本次新装的包**,写入 `$HERMES_HOME/installed-deps.txt`。升级场景(清单已存在)不重新生成。

**升级 pip / 更新已有依赖**不计入新装清单。node/npm 若为本次新装,同样进入清单。

卸载时读取该清单,按"默认保留、用户确认才卸"策略处理(见 §十一)。

---

## 六、组件安装

### 6.1 Hermes Agent 安装源

- 在线:通过 PyPI(`pip install hermes-agent`)
- 离线:`offline-packages/<架构>/hermes_agent-<版本>-*.whl`

### 6.2 版本选择(实时查询,不写死)

- **Hermes Agent**:调 PyPI JSON API `https://pypi.org/pypi/hermes-agent/json` 取 `info.version`
- **CC-Switch**:调 GitHub API `https://api.github.com/repos/farion1231/cc-switch/releases/latest`,取 `tag_name` 得版本号,读 `assets[]` 按平台关键词匹配 `browser_download_url` 直接下载
- **飞书 CLI**:调 GitHub API `https://api.github.com/repos/larksuite/cli/releases/latest`,同上按 `assets[]` 匹配

**不再硬编码版本号、不再靠"查版本号拼文件名"**——直接匹配 release 实际资产的下载地址,避免资产命名不符导致 404。

### 6.3 Pip 国内源配置

在线安装时自动使用国内镜像源,按优先级依次尝试,一个源失败自动降级:

| 优先级 | 源 | 地址 |
|--------|-----|------|
| 1(默认) | 阿里云 | `https://mirrors.aliyun.com/pypi/simple/` |
| 2(备用) | 清华大学 | `https://pypi.tuna.tsinghua.edu.cn/simple/` |
| 3(备用) | 中国科学技术大学 | `https://pypi.mirrors.ustc.edu.cn/simple/` |

所有源失败 → 该组件报错并跳过,不中断整体。

### 6.4 飞书CLI 安装

仓库地址:https://github.com/larksuite/cli

#### 6.4.1 在线安装

GitHub API 查 `assets[]`,按平台架构关键词(`linux-amd64`/`linux-arm64`/`darwin-amd64`/`darwin-arm64`/`windows-amd64`)匹配下载。API 未拿到时按代理链兜底:

| 优先级 | 下载方式 | 地址前缀 |
|--------|---------|---------|
| 1(默认) | ghfast.top 加速 | `https://ghfast.top/` + GitHub 下载链接 |
| 2(备用) | gh-proxy 加速 | `https://gh-proxy.com/` + GitHub 下载链接 |
| 3(备用) | 直连 GitHub | `https://github.com` 原始链接 |
| 4(兜底) | npm 安装 | `npm install -g @larksuite/cli` |

所有方式失败 → 提示用户手动安装。

#### 6.4.2 离线安装

- 离线包路径:`offline-packages/<架构>/lark`(或 `lark.exe`)
- 检测到离线包直接安装,跳过网络下载
- 安装后 `chmod +x`(Linux/macOS)

### 6.5 CC-Switch 安装

仓库地址:https://github.com/farion1231/cc-switch(Tauri 桌面应用)

#### 6.5.1 能力预检(B 的核心)

安装前对 Linux 环境做能力预检,不达标直接跳过,不尝试安装:

- **glibc 版本**:`ldd --version`,阈值 ≥ 2.26
- **webkit2gtk**:`pkg-config --modversion webkit2gtk-4.1` 或 `webkit2gtk-4.0` 存在(Tauri 依赖)

预检不通过 → `warn "检测到 UOS20/旧 webkit,CC-Switch 可能无法运行,已跳过"` → 直接走 AI 后端配置。

> UOS 20(Debian 10 buster,glibc 2.28、webkit2gtk 2.24)是典型的不达标场景,预检会跳过 CC-Switch。

#### 6.5.2 在线安装

GitHub API 查 `assets[]`,按平台关键词匹配下载(CC-Switch v3.16.3 起资产命名 `CC-Switch-v{版本}-{平台}.{ext}`,关键词需精确避开 `.sig`/`latest.json`/`-Portable.zip`/`.tar.gz` 等非目标资产):

| 平台 | 匹配关键词 |
|------|------------|
| Windows x64 | `Windows.msi` |
| Linux x86_64 (Debian) | `x86_64.deb` |
| Linux x86_64 (RedHat) | `x86_64.rpm` |
| Linux arm64 | `arm64.AppImage` |
| macOS | `macOS.dmg` |

代理链:GitHub 直连 > ghfast.top > gh-proxy,每个只试 1 次,连接超时 120 秒。

#### 6.5.3 安装失败回滚(B 的核心)

预检通过但安装仍失败(`dpkg -i`/`rpm -i`/AppImage 复制/MSI 静默安装返回非 0)→ 按"安装动作清单"回滚:
- 卸载刚装的包(`dpkg -r`/`rpm -e`/`msiexec /x`)
- 删 `/opt/cc-switch`、桌面文件、autostart 文件
- 删 MSI 安装残留、Windows 快捷方式

回滚后输出警告,继续走 AI 后端配置(改用 Hermes 官方配置方式)。

#### 6.5.4 各平台安装方式

| 平台 | 安装包格式 | 安装命令 |
|------|-----------|---------|
| Windows x64 | `.msi` | `msiexec /i <file> /qn` |
| Linux x86_64 (Debian) | `.deb` | `dpkg -i <file>` |
| Linux x86_64 (RedHat) | `.rpm` | `rpm -i` 或 `yum localinstall` |
| Linux arm64 | `.AppImage` | 复制到 `/opt/cc-switch/`,`chmod +x`,建桌面快捷方式 |
| macOS | `.dmg` | `hdiutil attach` → 复制到 `/Applications/` |

#### 6.5.5 离线安装

- 离线包路径:`offline-packages/<架构>/CC-Switch-*`
- 检测到离线包直接安装,跳过网络下载

---

## 七、环境变量配置

### 7.1 系统级 PATH

- **Windows**:写入 `HKLM\...\Environment\Path`
- **Linux**:追加到 `/etc/profile`
- **macOS**:写入 `/etc/profile.d/hermes.sh`(注:macOS 的 `/etc/paths.d/` 只读取可执行路径、不执行 `export` 语法,故改用 profile.d)

### 7.2 数据目录

所有平台设置系统级 `HERMES_HOME`,安装后自动创建。

### 7.3 npm 源(条件)

检测到 npm 时配置淘宝镜像源 `https://registry.npmmirror.com/`。

---

## 八、AI 推理后端配置

### 8.0 后端选择(交互式)

```
╔══════════════════════════════════════════════════════╗
║        选择 AI 推理后端                             ║
╠══════════════════════════════════════════════════════╣
║  [1] 阿里百炼 Coding Plan (qwen3.7-plus)           ║
║  [2] DeepSeek (deepseek-v4-pro / deepseek-v4-flash) ║
║  [0] 跳过配置,稍后手动设置                         ║
╚══════════════════════════════════════════════════════╝
```

`--provider` 显式指定时跳过交互。

### 8.1 阿里百炼 Coding Plan

```bash
model.provider=custom
model.base_url=https://coding.dashscope.aliyuncs.com/v1
model.api_mode=openai
model.api_key=<用户输入>
model.default=qwen3.7-plus
```

交互式 API Key 输入:有效 Key 写入、`SKIP` 跳过(其余配置照写)、空输入重新提示。

### 8.2 DeepSeek

```bash
model.provider=deepseek
model.base_url=https://api.deepseek.com/v1
model.api_key=<用户输入>
model.default=deepseek-v4-pro
```

交互式输入 API Key 后选择模型:`[1=pro / 2=flash,默认 1]`。

### 8.3 配置写入方式(官方配置方法)

**直接写 `$HERMES_HOME/config.yaml` + `$HERMES_HOME/.env`**(API Key 写 `.env`),避开 `hermes config set` 的已知 bug。同步写一份到 `~/.hermes/` 兜底。CC-Switch 装不装都走这段——CC-Switch 跳过/回滚后,大模型配置仍通过此方式完成。

### 8.4 命令行参数(无人值守)

| 参数 | 说明 |
|------|------|
| `--provider bailian`/`-PROVIDER "bailian"` | 阿里百炼(默认) |
| `--provider deepseek`/`-PROVIDER "deepseek"` | DeepSeek |
| `--api-key <key>`/`-API_KEY <key>` | 指定 API Key |
| `--skip-provider-config`/`-SKIP_PROVIDER_CONFIG` | 跳过 AI 后端配置 |
| `--skip-autostart`/`-SKIP_AUTOSTART` | 跳过自动启动 + 自启动 |
| `--skip-connectivity-test`/`-SKIP_CONNECTIVITY_TEST` | 跳过 hermes chat 连通性测试 |
| `--install-browser-act`/`-INSTALL_BROWSER_ACT` | 直接安装 browser-act |
| `--skip-browser-act`/`-SKIP_BROWSER_ACT` | 跳过 browser-act |
| `--skip-bailian-config`/`-SKIP_BAILIAN_CONFIG` | (兼容旧参数)等同 `--skip-provider-config` |

### 8.5 配置验证与连通性测试

配置完成后输出 provider/base_url/model/api_key 状态。若 API Key 非空且未跳过,执行连通性测试:

```bash
timeout 30 hermes chat -q "你好" --max-turns 1
```

**30 秒超时,失败不中断脚本**。可通过 `--skip-connectivity-test` 跳过(避免消耗 token)。

---

## 九、browser-act 可选安装(新增)

browser-act 是浏览器自动化 CLI(PyPI 包名 `browser-act-cli`,自带浏览器引擎,不依赖本地 Chrome),作为**可选依赖**在所有组件安装完成、验证通过后**交互询问**安装:

```
是否安装 browser-act(浏览器自动化 CLI,需要 Python 3.12+ 与 uv)?[y/N,默认 N]
```

- 前置:检测 `uv`,未安装则自动通过官方脚本安装(`curl -LsSf https://astral.sh/uv/install.sh | sh`,Windows 用 `irm https://astral.sh/uv/install.ps1 | iex`)
- 安装:`uv tool install browser-act-cli --python 3.12`
- 需要 Python 3.12+(uv 会自动拉取)
- 失败不中断
- 参数:`--install-browser-act` 直接装,`--skip-browser-act` 跳过

> 脚本查 GitHub release 仍用 `curl` + GitHub API,browser-act 仅作为用户可用的浏览器工具,不与主安装流程耦合。

---

## 十、安装后验证与自动启动

### 10.1 验证

```bash
hermes --version
lark --version
cc-switch --version          # Linux x64/Windows,CC-Switch 已装时
ls /Applications/CC-Switch.app  # macOS
```

验证失败输出警告,不中断。CC-Switch 未装时明确提示"用 Hermes 官方配置方式"。

### 10.2 自动启动 CC-Switch

验证通过、CC-Switch 已装且未传 `--skip-autostart` 时:
- Windows:`Start-Process` 搜索路径后启动
- Linux x64/CentOS x86_64:`command -v cc-switch` 或 `/usr/bin/cc-switch`
- Linux arm64/CentOS aarch64:`/opt/cc-switch/CC-Switch.AppImage`
- macOS:`open /Applications/CC-Switch.app`

sudo 执行时以实际用户身份启动(`su - $SUDO_USER -c "DISPLAY=:0 ..."`),root 无法访问用户桌面会话。

### 10.3 交互式自启动配置

CC-Switch 启动成功后询问"是否设置开机自启动?`[Y/n,默认 Y]`":

- Windows:公共启动目录建 `.lnk`(`C:\ProgramData\...\Startup\CC-Switch.lnk`)
- Linux/CentOS:用户 `~/.config/autostart/cc-switch.desktop`(XDG Autostart),`chown` 给实际用户
- macOS:用户 `~/Library/LaunchAgents/com.cc-switch.app.plist`,`RunAtLoad=true`

> Windows 不再自动弹窗启动 hermes 交互模式,仅做 `hermes --version` 验证,避免自动化场景卡死。

---

## 十一、卸载

### 11.1 卸载内容

- 卸载 Hermes Agent(`pip uninstall -y`)
- 删除飞书CLI 及安装目录
- 卸载 CC-Switch(Windows: `msiexec /x`;Linux deb: `dpkg -r`;Linux rpm: `rpm -e`;macOS/AppImage: 删目录)
- 清理环境变量、自启动文件
- 删除安装目录
- **读 `$HERMES_HOME/installed-deps.txt`,处理本次新装的系统依赖**
- 可选删除 `~/.hermes/config.yaml`(`--remove-config` / `-REMOVE_CONFIG`)

### 11.2 新装依赖卸载策略(默认保留,确认才卸)

卸载时若存在依赖清单:
1. 列出清单内容
2. 询问"是否一并卸载这些依赖?`[y/N,默认 N 保留]`"(或通过 `--remove-deps` / `-REMOVE_DEPS` 直接卸)
3. 输 `y` 才卸,逐个 `apt remove`/`rpm -e`/`brew uninstall`/Windows 注册表卸载
4. 卸前**幂等校验包是否还在**,在才卸,避免误删已被用户卸过的
5. 公共依赖(python3/curl 等)即便在清单里也默认保留,需用户显式确认

卸载前需用户确认(输入 `y/Y`)。

### 11.3 升级与依赖清单的关系

升级(重复执行 install)不重新生成依赖清单,故卸载时用的始终是"首次新装时记录的清单"。更新已有的依赖(如 pip 升级)不计入清单,不会被卸载。

---

## 十二、权限处理

| 系统 | 策略 |
|------|------|
| Windows | 检测非管理员时,自动 `RunAs` 重新启动 PowerShell,弹 UAC |
| Linux / macOS | 检测非 root 时,自动 `exec sudo bash "$0" "$@"` 重新执行 |

---

## 十三、日志与输出

- 实时输出带时间戳的结构化日志(`INFO`/`WARNING`/`ERROR`)
- 同时写入文件:Windows `%ProgramFiles%\HermesAgent\install.log`,Linux/macOS `/var/log/hermes-install.log`
- Linux/macOS 用 `set -uo pipefail`(非 `set -e`),关键步骤显式失败退出,可失败步骤统一 `|| warn`/`|| true`,避免"非致命失败"导致全盘中断

---

## 十四、目录结构

```
hermes_install/
├── scripts/
│   ├── _common.sh                # 公共函数库(日志/下载/版本查询/幂等检测/依赖清单/CC-Switch 预检回滚)
│   ├── install.sh                # Linux/macOS 幂等安装器(合并,x64/arm64/macos 通用,含 RedHat 系分支)
│   ├── install-windows.ps1       # Windows 幂等安装器
│   ├── uninstall.sh              # Linux/macOS 合并卸载
│   └── uninstall-windows.ps1     # Windows 卸载
├── offline-packages/             # 离线包目录(空壳,用户手工填)
│   ├── windows-x64/  linux-x64/  linux-arm64/
│   ├── centos-x64/   centos-arm64/
│   └── macos-x64/    macos-arm64/
└── README.md
```

> **不再提供 upgrade 脚本**——install 自带幂等升级能力。

### 离线包命名约定

| 文件类型 | 命名格式 |
|----------|---------|
| Hermes Agent wheel | `hermes_agent-<版本>-py3-none-any.whl` |
| Python(Windows) | `python-<版本>-amd64.exe` |
| 飞书CLI(Windows) | `lark.exe` |
| 飞书CLI(Linux/macOS) | `lark` |
| CC-Switch(Windows) | `CC-Switch-<版本>-Windows.msi` |
| CC-Switch(Linux Debian) | `CC-Switch-<版本>-Linux-x86_64.deb` |
| CC-Switch(Linux RedHat) | `CC-Switch-<版本>-Linux-x86_64.rpm` |
| CC-Switch(Linux arm64) | `CC-Switch-<版本>-Linux-arm64.AppImage` |
| CC-Switch(macOS) | `CC-Switch-<版本>-macOS.dmg` |

---

## 十五、使用方式速查

### Linux / macOS

```bash
# 在线安装(默认最新版,交互式选后端 + 输 API Key)
sudo bash scripts/install.sh

# 指定 Hermes 版本(跳过交互)
sudo bash scripts/install.sh 0.16.0

# 自定义路径
sudo bash scripts/install.sh latest /opt/hermes /data/hermes

# 指定 AI 后端 + API Key(完全无人值守)
sudo bash scripts/install.sh --provider deepseek --api-key "sk-xxx"

# 跳过 AI 后端配置 / 自动启动 / 连通性测试 / browser-act
sudo bash scripts/install.sh --skip-provider-config
sudo bash scripts/install.sh --skip-autostart
sudo bash scripts/install.sh --skip-connectivity-test
sudo bash scripts/install.sh --skip-browser-act

# 升级 = 重复执行 install(幂等,已装最新会跳过)
sudo bash scripts/install.sh

# 卸载(默认保留系统依赖)
sudo bash scripts/uninstall.sh
sudo bash scripts/uninstall.sh --remove-config     # 连配置一起删
sudo bash scripts/uninstall.sh --remove-deps       # 连新装依赖一起卸
```

### Windows

```powershell
.\scripts\install-windows.ps1
.\scripts\install-windows.ps1 -HERMES_VERSION 0.16.0 -INSTALL_DIR "D:\Hermes" -HERMES_HOME "D:\Data"
.\scripts\install-windows.ps1 -PROVIDER "deepseek" -API_KEY "sk-xxx"
.\scripts\install-windows.ps1 -SKIP_PROVIDER_CONFIG
.\scripts\install-windows.ps1 -SKIP_AUTOSTART
.\scripts\install-windows.ps1 -SKIP_CONNECTIVITY_TEST
.\scripts\install-windows.ps1 -INSTALL_BROWSER_ACT

# 升级 = 重复执行 install
# 卸载
.\scripts\uninstall-windows.ps1
.\scripts\uninstall-windows.ps1 -REMOVE_CONFIG
.\scripts\uninstall-windows.ps1 -REMOVE_DEPS
```

---

## 十六、关键设计决策

| 决策点 | 结论 | 理由 |
|--------|------|------|
| 安装级别 | 系统级 | 所有用户账户可用 |
| 幂等安装 | 没装就新装、版本低就升级、最新就跳过 | install 自带升级,无需独立 upgrade 脚本 |
| 离线优先 | 有离线包就用,没有再下载 | 应对网络不稳定 |
| 离线限制 | transitive deps 缺失时明确提示不硬撑 | 离线无法自动补齐传递依赖,硬撑会装坏 |
| 版本号 | 实时查 PyPI/GitHub API,不写死 | 避免硬编码过期、避免拼文件名 404 |
| GitHub 资产匹配 | 读 `assets[]` 按平台关键词匹配 download URL | 适应作者任意命名风格 |
| CC-Switch 预检 | glibc≥2.26 + webkit2gtk 存在才装 | UOS20 等旧系统带不动 Tauri |
| CC-Switch 回滚 | 预检不过跳过,装失败回滚 | 装不上就改用 Hermes 官方配置方式 |
| Hermes 配置方式 | 直接写 config.yaml + .env | 避开 hermes config set 已知 bug |
| 依赖清单 | 首次新装记录差集,升级不重记,卸载默认保留确认才卸 | 干净卸载又不误伤用户其它依赖 |
| Pip 源 | 阿里 > 清华 > 中科大,自动降级 | 国内安装成功率 |
| 飞书CLI 下载 | GitHub API assets 匹配 > ghfast > gh-proxy > 直连 > npm | 官方分发 + 代理 + npm 兜底 |
| CC-Switch 下载 | GitHub API assets 匹配 > 直连 > ghfast > gh-proxy | 快速切换 |
| AI 后端 | 交互式菜单 + `--provider` 参数 | 兼顾易用与自动化 |
| 百炼 | Coding Plan,OpenAI 兼容模式 | 用户常见订阅 |
| DeepSeek | 原生 provider,pro/flash 可选 | Hermes 内置支持 |
| 连通性测试 | 30s 超时,失败不中断,可跳过 | 避免 token 浪费和卡死 |
| browser-act | 可选依赖,末尾交互询问,`uv tool install browser-act-cli --python 3.12` | 不耦合主流程,供用户按需使用;需 Python 3.12+ 与 uv |
| 权限 | 自动提权(sudo/RunAs) | 减少手动步骤 |
| 自启动 | Windows .lnk / Linux XDG .desktop / macOS LaunchAgent | 各平台原生方案 |
| sudo 启动 GUI | `su - $SUDO_USER` 以实际用户启动 | root 无法访问用户桌面 |
| Windows hermes 启动 | 仅 `--version` 验证,不弹交互窗口 | 避免自动化卡死 |
| shell 错误处理 | `set -uo pipefail` + 显式 `\|\| warn` | 非致命失败不中断整体 |
| macOS PATH | `/etc/profile.d/hermes.sh` | paths.d 不执行 export 语法 |
| 日志 | 终端 + 文件双写 | 便于排查审计 |
| PowerShell 编码 | UTF-8 无 BOM | 兼容中文环境,避免引号被吞 |
