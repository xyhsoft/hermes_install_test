#!/bin/bash
# ============================================================
# _common.sh — Hermes Agent 安装包公共函数库
# 被 install.sh / uninstall.sh source 使用，不单独执行
# ============================================================

# 默认安装路径（可被调用方覆盖）
INSTALL_DIR="${INSTALL_DIR:-/usr/local/hermes}"
HERMES_HOME="${HERMES_HOME:-/var/lib/hermes}"
LOG_FILE="${LOG_FILE:-/var/log/hermes-install.log}"
DEPS_RECORD="${HERMES_HOME}/installed-deps.txt"

# ------------------------------------------------------------
# 日志
# ------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}
info() { log "INFO" "$@"; }
warn() { log "WARNING" "$@"; }
error() { log "ERROR" "$@"; }

# ------------------------------------------------------------
# 平台 / 包管理器探测
# ------------------------------------------------------------
# 输出 ARCH_DIR（离线包子目录名）与 PKGMGR（apt|yum|dnf|brew|none）
detect_platform() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_RAW="x64" ;;
        aarch64) ARCH_RAW="arm64" ;;
        arm64)   ARCH_RAW="arm64" ;;   # macOS Apple Silicon 的 uname -m 返回 arm64
        *) error "不支持的架构: $ARCH"; exit 1 ;;
    esac

    OS_KIND=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_KIND="macos"
        ARCH_DIR="macos-${ARCH_RAW}"
        PKGMGR="brew"
    elif command -v apt-get &>/dev/null; then
        OS_KIND="debian"
        ARCH_DIR="linux-${ARCH_RAW}"
        PKGMGR="apt"
    elif command -v dnf &>/dev/null; then
        OS_KIND="redhat"
        ARCH_DIR="centos-${ARCH_RAW}"
        PKGMGR="dnf"
    elif command -v yum &>/dev/null; then
        OS_KIND="redhat"
        ARCH_DIR="centos-${ARCH_RAW}"
        PKGMGR="yum"
    else
        OS_KIND="unknown"
        ARCH_DIR="linux-${ARCH_RAW}"
        PKGMGR="none"
    fi
    export ARCH ARCH_RAW OS_KIND ARCH_DIR PKGMGR
}

# ------------------------------------------------------------
# 下载重试
# ------------------------------------------------------------
# 用法: download_with_retry <url> <output> [max_retries]
download_with_retry() {
    local url="$1" output="$2" max_retries="${3:-3}"
    local i
    for ((i=1; i<=max_retries; i++)); do
        info "下载中 ($i/$max_retries): $url"
        if wget -q --timeout=30 -O "$output" "$url" 2>/dev/null \
           || curl -sL --connect-timeout 30 --max-time 120 -o "$output" "$url" 2>/dev/null; then
            return 0
        fi
        warn "下载失败，等待 3 秒后重试..."
        sleep 3
    done
    error "下载失败 (已重试 $max_retries 次): $url"
    return 1
}

# ------------------------------------------------------------
# 从 URL 提取 trusted-host（兼容 macOS BSD grep，不用 -P）
# ------------------------------------------------------------
extract_host() {
    local url="$1"
    # 去掉协议前缀，取到第一个 /
    local rest="${url#*://}"
    echo "${rest%%/*}"
}

# ------------------------------------------------------------
# Pip 国内源（阿里 > 清华 > 中科大，自动降级）
# ------------------------------------------------------------
PIP_MIRRORS=(
    "https://mirrors.aliyun.com/pypi/simple/"
    "https://pypi.tuna.tsinghua.edu.cn/simple/"
    "https://pypi.mirrors.ustc.edu.cn/simple/"
)

# 用法: pip_install_with_mirror "<pip 参数...>"
pip_install_with_mirror() {
    local mirror host
    # 用 install.sh 选定的 python 解释器（macOS 上可能是 brew python@3.13，避开 3.14）
    local py="${HERMES_PYTHON:-python3}"
    # PEP 668: 新版系统 Python(debian/ubuntu) 禁止系统级 pip 装，需 --break-system-packages
    # 老 pip 不认此参数会报错，所以先探测
    local break_flag=""
    if "$py" -m pip install --help 2>/dev/null | grep -q -- '--break-system-packages'; then
        break_flag="--break-system-packages"
    fi
    for mirror in "${PIP_MIRRORS[@]}"; do
        host=$(extract_host "$mirror")
        info "尝试镜像源: $mirror"
        if "$py" -m pip install "$@" $break_flag -i "$mirror" --trusted-host "$host"; then
            return 0
        fi
        warn "源 $mirror 失败，尝试下一个..."
    done
    # 全部失败后，用 --ignore-installed 兜底（应对系统包 RECORD 缺失导致的卸载冲突，如 urllib3）
    # 不依赖 break_flag —— 老 pip 也会遇到系统包冲突
    warn "常规安装失败，尝试 --ignore-installed 兜底..."
    for mirror in "${PIP_MIRRORS[@]}"; do
        host=$(extract_host "$mirror")
        if "$py" -m pip install "$@" $break_flag --ignore-installed -i "$mirror" --trusted-host "$host"; then
            return 0
        fi
    done
    error "所有 pip 镜像源都失败"
    return 1
}

# ------------------------------------------------------------
# 版本号实时查询（不写死）
# ------------------------------------------------------------
# 查 Hermes Agent 最新版（PyPI JSON API）
query_hermes_latest() {
    local ver=""
    if command -v curl &>/dev/null; then
        ver=$(curl -s "https://pypi.org/pypi/hermes-agent/json" 2>/dev/null \
              | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null)
    fi
    echo "$ver"
}

# 查 GitHub release 最新版 + 资产 URL
# 用法: query_github_latest <owner/repo> <匹配关键词...>
# 输出两行：第一行 tag（版本号），第二行匹配到的 asset 的 browser_download_url（无匹配则空）
query_github_latest() {
    local repo="$1"; shift
    local keywords=("$@")
    local json tag url asset_name asset_url
    if ! command -v curl &>/dev/null; then
        echo ""; echo ""; return 1
    fi
    json=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)
    [[ -z "$json" ]] && { echo ""; echo ""; return 1; }

    # tag_name（去前导 v 用于版本对比，保留原始用于展示由调用方处理）
    tag=$(echo "$json" | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')

    # 从 assets 里抽出所有 browser_download_url，逐个看是否含全部关键词
    asset_url=""
    local all_urls
    all_urls=$(echo "$json" | grep '"browser_download_url"' | sed -E 's/.*"([^"]+)".*/\1/')
    local kw u match
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        match=1
        for kw in "${keywords[@]}"; do
            case "$u" in
                *"$kw"*) ;;
                *) match=0; break ;;
            esac
        done
        if [[ "$match" == "1" ]]; then
            asset_url="$u"; break
        fi
    done <<< "$all_urls"

    echo "$tag"
    echo "$asset_url"
}

# ------------------------------------------------------------
# 幂等检测：获取已装组件版本
# ------------------------------------------------------------
get_installed_hermes_version() {
    command -v hermes &>/dev/null && hermes --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
get_installed_lark_version() {
    local lark_bin="$1"
    [[ -x "$lark_bin" ]] && "$lark_bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# 版本号比较：ver_ge <a> <b>  → a >= b 返回 0
ver_ge() {
    [[ "$1" == "$2" ]] && return 0
    local IFS=. a1 a2 a3 b1 b2 b3
    read -r a1 a2 a3 <<< "$1"
    read -r b1 b2 b3 <<< "$2"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [[ $a1 -gt $b1 ]] && return 0
    [[ $a1 -lt $b1 ]] && return 1
    [[ $a2 -gt $b2 ]] && return 0
    [[ $a2 -lt $b2 ]] && return 1
    [[ $a3 -ge $b3 ]] && return 0
    return 1
}

# ------------------------------------------------------------
# 依赖清单记录（D 的核心）
# 只在首次新装系统依赖时生成；升级时不覆盖
# ------------------------------------------------------------
snapshot_installed_pkgs() {
    case "$PKGMGR" in
        apt) dpkg-query -W -f='${Package}\n' 2>/dev/null | sort ;;
        yum|dnf) rpm -qa 2>/dev/null | sort ;;
        brew) brew list --formula -1 2>/dev/null | sort ;;
        *) ;;
    esac
}

# 计算前后差集并写入清单（首次安装调用）
record_new_deps() {
    local before_file="$1" after_snapshot="$2"
    [[ ! -f "$before_file" ]] && return 0
    mkdir -p "$HERMES_HOME"
    comm -13 "$before_file" <(echo "$after_snapshot") > "$DEPS_RECORD" 2>/dev/null || true
    info "本次新装系统依赖已记录到 $DEPS_RECORD ($(wc -l < "$DEPS_RECORD" 2>/dev/null) 个)"
}

# ------------------------------------------------------------
# CC-Switch 能力预检（B 的核心）
# 返回 0 = 可装，1 = 不可装
# CC-Switch 是 Tauri(WebKit2GTK) 桌面应用，对 glibc/webkit 版本有要求。
# UOS 20(Debian 10 buster, glibc 2.28、webkit2gtk 2.24) 是典型不达标场景。
# 阈值：glibc >= 2.26 且 webkit2gtk-4.0/4.1 存在。
# 说明：阈值已基于 Tauri 通用要求设定；如目标环境特殊，建议真机实测后微调。
# ------------------------------------------------------------
can_install_ccswitch() {
    # macOS / Windows 由各自分支处理，此函数主要用于 Linux
    [[ "$OS_KIND" == "macos" ]] && return 0

    local glibc_ver webkit
    glibc_ver=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' | head -1)
    # webkit2gtk 检测（Tauri 应用依赖）
    webkit=$(pkg-config --modversion webkit2gtk-4.1 2>/dev/null \
          || pkg-config --modversion webkit2gtk-4.0 2>/dev/null \
          || true)

    info "CC-Switch 预检: glibc=${glibc_ver:-未知} webkit=${webkit:-无}"

    if [[ -z "$glibc_ver" ]]; then
        warn "无法检测 glibc 版本，CC-Switch 预检不通过"
        return 1
    fi
    if ! ver_ge "$glibc_ver" "2.26"; then
        warn "glibc 版本 $glibc_ver 低于 2.26，CC-Switch 无法运行"
        return 1
    fi
    if [[ -z "$webkit" ]]; then
        warn "未检测到 webkit2gtk-4.0/4.1，CC-Switch (Tauri) 可能无法运行"
        return 1
    fi
    return 0
}

# CC-Switch 安装动作记录（用于失败回滚）
CC_ACTIONS_FILE="${CC_ACTIONS_FILE:-/tmp/cc-switch-actions.$$}"
cc_record_action() {
    echo "$1" >> "$CC_ACTIONS_FILE" 2>/dev/null || true
}
# 回滚 CC-Switch 安装
rollback_ccswitch() {
    warn "回滚 CC-Switch 安装..."
    local line
    [[ -f "$CC_ACTIONS_FILE" ]] || return 0
    while IFS= read -r line; do
        case "$line" in
            pkg:*)
                local pkg="${line#pkg:}"
                case "$PKGMGR" in
                    apt) dpkg -r "$pkg" 2>/dev/null || apt-get remove -y "$pkg" 2>/dev/null || true ;;
                    yum|dnf) rpm -e "$pkg" 2>/dev/null || yum remove -y "$pkg" 2>/dev/null || true ;;
                esac
                ;;
            file:*) rm -f "${line#file:}" 2>/dev/null || true ;;
            dir:*)  rm -rf "${line#dir:}" 2>/dev/null || true ;;
        esac
    done < "$CC_ACTIONS_FILE"
    rm -f "$CC_ACTIONS_FILE" 2>/dev/null || true
    warn "CC-Switch 已回滚，将改用 Hermes 官方配置方式配置大模型"
}

# ------------------------------------------------------------
# 提权
# ------------------------------------------------------------
ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        info "需要 root 权限，自动提权..."
        exec sudo bash "$0" "$@"
    fi
}
