#!/bin/bash
# ============================================================
# Hermes Agent + 飞书CLI + CC-Switch Linux/macOS 幂等安装器
# 合并原 install-linux-x64 / arm64 / centos / macos 四个脚本
#
# 特性：
#   - 幂等：没装就新装、版本低就升级、最新就跳过
#   - 离线优先：有离线包用离线包，无网无包则提示"暂时装不了"并跳过
#   - CC-Switch 装不了就回滚，改用 Hermes 官方配置方式
#   - 版本号实时查 PyPI/GitHub，不写死
#   - 首次新装系统依赖时记录清单，供卸载使用
#   - 可选安装 browser-act
#
# 用法:
#   sudo bash install.sh [版本号] [安装目录] [数据目录] [选项]
#   选项:
#     --provider <bailian|deepseek>   指定 AI 后端，跳过交互
#     --api-key <key>                 指定 API Key，跳过交互
#     --skip-provider-config          跳过 AI 后端配置
#     --skip-autostart                跳过自动启动 + 自启动配置
#     --skip-connectivity-test        跳过 hermes chat 连通性测试
#     --install-browser-act           直接安装 browser-act，跳过询问
#     --skip-browser-act              跳过 browser-act 安装
#     --skip-bailian-config           (兼容旧参数) 等同 --skip-provider-config
# ============================================================

set -uo pipefail

# 提权前先保存原始参数（参数解析会 shift 掉 $@，ensure_root 需要原始参数透传）
ORIGINAL_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

# ============================================================
# 参数解析
# ============================================================
HERMES_VERSION="latest"
INSTALL_DIR="/usr/local/hermes"
HERMES_HOME="/var/lib/hermes"
PROVIDER=""
API_KEY=""
SKIP_PROVIDER_CONFIG=false
SKIP_AUTOSTART=false
SKIP_CONNECTIVITY_TEST=false
INSTALL_BROWSER_ACT=false
SKIP_BROWSER_ACT=false

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --provider) PROVIDER="$2"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        --skip-bailian-config|--skip-provider-config) SKIP_PROVIDER_CONFIG=true; shift ;;
        --skip-autostart) SKIP_AUTOSTART=true; shift ;;
        --skip-connectivity-test) SKIP_CONNECTIVITY_TEST=true; shift ;;
        --install-browser-act) INSTALL_BROWSER_ACT=true; shift ;;
        --skip-browser-act) SKIP_BROWSER_ACT=true; shift ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [[ ${#POSITIONAL[@]} -ge 1 ]]; then HERMES_VERSION="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then INSTALL_DIR="${POSITIONAL[1]}"; fi
HERMES_HOME_USER_SET=false
if [[ ${#POSITIONAL[@]} -ge 3 ]]; then HERMES_HOME="${POSITIONAL[2]}"; HERMES_HOME_USER_SET=true; fi

# ============================================================
# 提权 + 平台检测
# ============================================================
ensure_root "${ORIGINAL_ARGS[@]}"
detect_platform

# macOS 默认数据目录与 Linux 不同；用户未显式指定时用 macOS 默认
if [[ "$OS_KIND" == "macos" ]] && [[ "$HERMES_HOME_USER_SET" == "false" ]]; then
    HERMES_HOME="/Library/Application Support/Hermes"
fi
# 覆盖 _common.sh 的默认路径（HERMES_HOME 可能因 macOS 修正而变化）
export INSTALL_DIR HERMES_HOME
LOG_FILE="/var/log/hermes-install.log"
DEPS_RECORD="${HERMES_HOME}/installed-deps.txt"

info "========== Hermes Agent 幂等安装开始 =========="
info "系统: $OS_KIND | 架构: $ARCH | 包管理器: $PKGMGR"
info "安装目录: $INSTALL_DIR | 数据目录: $HERMES_HOME | 目标版本: $HERMES_VERSION"

mkdir -p "$INSTALL_DIR" "$HERMES_HOME"

OFFLINE_DIR="$BASE_DIR/offline-packages/$ARCH_DIR"
LARK_DIR="$INSTALL_DIR/lark"

# ============================================================
# 依赖安装 + 首次新装清单记录
# ============================================================
install_system_deps() {
    info "安装/检查系统依赖..."
    local before_snapshot after_snapshot before_file

    # 升级场景：清单已存在 → 只补缺失，不重生成
    if [[ -f "$DEPS_RECORD" ]]; then
        info "检测到已存在依赖清单，跳过依赖快照（升级模式）"
        case "$PKGMGR" in
            apt) apt-get update -qq ;;
            yum|dnf) : ;;
            brew) : ;;
        esac
        return 0
    fi

    # 首次安装：安装前快照
    before_file="/tmp/.hermes-deps-before.$$"
    before_snapshot=$(snapshot_installed_pkgs)
    echo "$before_snapshot" > "$before_file" 2>/dev/null

    case "$PKGMGR" in
        apt)
            apt-get update -qq
            apt-get install -y -qq python3 python3-pip python3-venv curl wget ca-certificates
            ;;
        yum)
            yum install -y epel-release
            yum install -y python3 python3-pip curl wget ca-certificates
            ;;
        dnf)
            dnf install -y python3 python3-pip curl wget ca-certificates
            ;;
        brew)
            if ! command -v brew &>/dev/null; then
                info "安装 Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
                    info "使用国内镜像安装 Homebrew..."
                    /bin/bash -c "$(curl -fsSL https://gitee.com/cunkai/HomebrewCN/raw/master/Homebrew.sh)" || true
                }
            fi
            # 确保 brew 环境生效（sudo bash 下 /opt/homebrew/bin 可能不在 PATH）
            if [[ -x /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -x /usr/local/bin/brew ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
            # 用 brew 的 python3（避免 sudo 下误用系统 /usr/bin/python3）
            if ! command -v python3 &>/dev/null || [[ "$(command -v python3)" == "/usr/bin/python3" ]]; then
                brew install python3 2>/dev/null || true
            fi
            # 记录 brew python 的 bin 路径，供后续 pip 装的 hermes 定位
            BREW_PYTHON_BIN=$(python3 -c "import sys; print(sys.prefix)" 2>/dev/null)/bin
            [[ -d "$BREW_PYTHON_BIN" ]] && export PATH="$BREW_PYTHON_BIN:$PATH"
            ;;
        none)
            warn "无法识别包管理器，跳过系统依赖安装。请确保 python3/pip/curl/wget 已就绪"
            ;;
    esac

    # 升级 pip（不计入新装清单）
    if command -v python3 &>/dev/null; then
        # 检查 python 版本（hermes-agent 需要 >= 3.11）
        local py_version
        py_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null)
        info "检测到 Python 版本: ${py_version:-未知}"
        if [[ -n "$py_version" ]] && ! ver_ge "$py_version" "3.11"; then
            # macOS 上自动装 brew python@3.12（sudo 下系统 python 往往是 3.9，装不了 hermes）
            if [[ "$OS_KIND" == "macos" ]]; then
                info "Python $py_version 低于 3.11，尝试 brew install python@3.12..."
                if [[ -x /opt/homebrew/bin/brew ]]; then
                    eval "$(/opt/homebrew/bin/brew shellenv)"
                elif [[ -x /usr/local/bin/brew ]]; then
                    eval "$(/usr/local/bin/brew shellenv)"
                fi
                if command -v brew &>/dev/null; then
                    brew install python@3.12 2>/dev/null || brew install python 2>/dev/null || true
                    # 找新装的 brew python 3.12/3.13
                    for candidate in \
                        /opt/homebrew/opt/python@3.12/bin/python3.12 \
                        /opt/homebrew/opt/python@3.13/bin/python3.13 \
                        /opt/homebrew/bin/python3.12 \
                        /opt/homebrew/bin/python3 \
                        /usr/local/opt/python@3.12/bin/python3.12 \
                        /usr/local/bin/python3; do
                        if [[ -x "$candidate" ]]; then
                            local candidate_ver
                            candidate_ver=$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
                            if ver_ge "$candidate_ver" "3.11"; then
                                info "切到 brew python: $candidate (版本 $candidate_ver)"
                                export PATH="$(dirname "$candidate"):$PATH"
                                py_version=$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null)
                                break
                            fi
                        fi
                    done
                fi
            fi
            if ! ver_ge "$py_version" "3.11"; then
                error "Python 版本 $py_version 低于 3.11，hermes-agent 无法安装"
                error "请先安装 Python 3.11+，再重新运行本脚本"
                error "  Ubuntu/Debian: apt install python3.11 或用 deadsnakes PPA"
                error "  macOS: brew install python@3.11"
                error "  通用: pyenv install 3.11 && pyenv global 3.11"
                return 1
            fi
            info "已切到 Python $py_version"
        fi
        info "升级 pip..."
        python3 -m pip install --upgrade pip 2>/dev/null || warn "pip 升级失败（不中断）"
    else
        error "未检测到 python3"
        return 1
    fi

    # 安装后快照 + 差集 = 新装清单
    after_snapshot=$(snapshot_installed_pkgs)
    record_new_deps "$before_file" "$after_snapshot"
    rm -f "$before_file" 2>/dev/null || true
}

install_system_deps

# ============================================================
# Hermes Agent 幂等安装
# ============================================================
install_hermes() {
    info "处理 Hermes Agent..."
    local installed online offline_wheel target

    installed=$(get_installed_hermes_version)
    online=$(query_hermes_latest)

    # 离线包优先查找
    offline_wheel=$(find "$OFFLINE_DIR" -name "hermes_agent-*-py3-none-any.whl" 2>/dev/null | sort -rV | head -1)

    # 确定目标版本
    if [[ "$HERMES_VERSION" != "latest" ]]; then
        target="$HERMES_VERSION"
    elif [[ -n "$offline_wheel" ]]; then
        target=$(basename "$offline_wheel" | sed -E 's/hermes_agent-([0-9.]+)-.*/\1/')
        info "发现离线包，目标版本: $target"
    elif [[ -n "$online" ]]; then
        target="$online"
    else
        target=""
    fi

    # 幂等判断
    if [[ -n "$installed" ]] && [[ -n "$target" ]]; then
        if [[ "$installed" == "$target" ]]; then
            info "Hermes Agent 已是目标版本 $installed，跳过"
            return 0
        elif ver_ge "$installed" "$target"; then
            info "Hermes Agent 已装 $installed >= 目标 $target，跳过（不降级）"
            return 0
        else
            info "Hermes Agent 已装 $installed，升级到 $target"
        fi
    elif [[ -n "$installed" ]]; then
        info "Hermes Agent 已装 $installed，无目标版本可比，跳过"
        return 0
    fi

    # 执行安装
    local hermes_install_ok=false
    if [[ -n "$offline_wheel" ]]; then
        info "使用离线包: $(basename "$offline_wheel")"
        # 离线 wheel 的 transitive deps 仍需联网；无网时会失败
        if python3 -m pip install "$offline_wheel" 2>/dev/null; then
            hermes_install_ok=true
        else
            warn "离线包直接 pip 装失败，尝试 venv 兜底..."
        fi
    elif [[ -n "$target" ]]; then
        if pip_install_with_mirror "hermes-agent==$target"; then
            hermes_install_ok=true
        else
            warn "pip_install_with_mirror 失败，尝试 venv 兜底..."
        fi
    else
        warn "无法获取 Hermes Agent 版本（无网且无离线包），Hermes 暂时装不了"
        return 1
    fi

    # 兜底：直接 pip 装失败时，用 venv 装到 /opt/hermes-venv（绕过 PEP 668 等系统 python 限制）
    if [[ "$hermes_install_ok" != "true" ]]; then
        local venv_dir="/opt/hermes-venv"
        info "尝试 venv 兜底安装到 $venv_dir ..."
        if python3 -m venv "$venv_dir" 2>/dev/null; then
            if "$venv_dir/bin/pip" install --quiet "hermes-agent${target:+==$target}" 2>/dev/null; then
                info "venv 兜底安装成功"
                hermes_install_ok=true
                # 把 venv bin 加入 PATH，后续 hermes 定位会找到
                export PATH="$venv_dir/bin:$PATH"
            else
                error "venv 兜底也失败"
                return 1
            fi
        else
            error "无法创建 venv（python3-venv 未安装？）"
            return 1
        fi
    fi
}

install_hermes || warn "Hermes Agent 安装未完成"

# 记录 hermes 二进制实际路径，供 CI 验证 step 读取（macOS sudo 下 PATH 复杂，避免找不到）
# 策略：先 command -v，再用 python3 -m pip show 拿 Location 推导 bin 目录，再穷举常见路径
HERMES_BIN_PATH=""
if command -v hermes &>/dev/null; then
    HERMES_BIN_PATH=$(command -v hermes)
else
    # 从 pip show 拿 hermes-agent 安装位置，推导 bin 目录
    PIP_LOCATION=$(python3 -m pip show hermes-agent 2>/dev/null | grep -E '^Location:' | awk '{print $2}')
    if [[ -n "$PIP_LOCATION" ]]; then
        info "hermes-agent pip Location: $PIP_LOCATION"
        # bin 目录常见位置：sys.prefix/bin、user-base/bin、或 Location 的父级/bin
        for candidate in \
            "$(python3 -c 'import sys; print(sys.prefix)' 2>/dev/null)/bin/hermes" \
            "$(python3 -m site --user-base 2>/dev/null)/bin/hermes" \
            "$HOME/.local/bin/hermes" \
            "/usr/local/bin/hermes" \
            "/usr/bin/hermes" \
            "$(dirname "$PIP_LOCATION")/../bin/hermes"; do
            [[ -x "$candidate" ]] && HERMES_BIN_PATH="$candidate" && break
        done
    fi
fi
if [[ -n "$HERMES_BIN_PATH" ]] && [[ -x "$HERMES_BIN_PATH" ]]; then
    info "hermes 二进制位于: $HERMES_BIN_PATH"
    mkdir -p "$HERMES_HOME"
    echo "$HERMES_BIN_PATH" > "$HERMES_HOME/.hermes-bin-path" 2>/dev/null || true
    # 把 hermes 所在 bin 目录也写进 profile.d，确保非 sudo 终端能找到
    HERMES_BIN_DIR=$(dirname "$HERMES_BIN_PATH")
    if [[ "$OS_KIND" == "macos" ]]; then
        # 追加到 hermes.sh（若未含）
        grep -q "$HERMES_BIN_DIR" /etc/profile.d/hermes.sh 2>/dev/null \
            || sed -i '' "s|export PATH=\"|export PATH=\"$HERMES_BIN_DIR:|" /etc/profile.d/hermes.sh 2>/dev/null || true
    elif [[ "$OS_KIND" != "macos" ]]; then
        # Linux：也追加到 /etc/profile（若未含该目录）
        grep -q "$HERMES_BIN_DIR" /etc/profile 2>/dev/null \
            || echo "export PATH=\"$HERMES_BIN_DIR:\$PATH\"" >> /etc/profile 2>/dev/null || true
    fi
    # 兜底：创建 symlink 到 /usr/local/bin（hermes 不在 /usr/local/bin 且 /usr/local/bin 可写时）
    if [[ "$HERMES_BIN_PATH" != "/usr/local/bin/hermes" ]] && [[ -d /usr/local/bin ]] && [[ -w /usr/local/bin ]]; then
        ln -sf "$HERMES_BIN_PATH" /usr/local/bin/hermes 2>/dev/null && \
            info "已创建 symlink /usr/local/bin/hermes -> $HERMES_BIN_PATH" || true
    fi
else
    warn "hermes 二进制未找到（pip 安装可能失败或未产出 console script）"
    # 打印诊断
    info "python3 位置: $(which python3 2>/dev/null || echo '未知')"
    info "python3 版本: $(python3 --version 2>/dev/null || echo '未知')"
    info "pip show hermes-agent:"
    python3 -m pip show hermes-agent 2>/dev/null || info "(pip show 无输出)"
fi

# ============================================================
# 飞书 CLI 幂等安装
# ============================================================
install_lark() {
    info "处理飞书 CLI..."
    mkdir -p "$LARK_DIR"

    local lark_arch offline_lark installed
    case "$ARCH" in
        x86_64)  lark_arch="linux-amd64" ;;
        aarch64) lark_arch="linux-arm64" ;;
    esac
    [[ "$OS_KIND" == "macos" ]] && case "$ARCH" in
        x86_64)  lark_arch="darwin-amd64" ;;
        arm64)   lark_arch="darwin-arm64" ;;
    esac

    offline_lark="$OFFLINE_DIR/lark"
    installed=$(get_installed_lark_version "$LARK_DIR/lark")

    # 离线包优先
    if [[ -f "$offline_lark" ]]; then
        info "使用离线飞书 CLI"
        cp "$offline_lark" "$LARK_DIR/lark"
        chmod +x "$LARK_DIR/lark"
        return 0
    fi

    # 已装则跳过（lark 暂不细究版本升级，存在即跳过）
    if [[ -n "$installed" ]]; then
        info "飞书 CLI 已装 (v$installed)，跳过"
        return 0
    fi

    # 在线：GitHub API 查 assets 匹配
    info "查询飞书 CLI 最新版..."
    local tag asset_url
    { read -r tag; read -r asset_url; } < <(query_github_latest "larksuite/cli" "$lark_arch")

    if [[ -n "$asset_url" ]]; then
        info "飞书 CLI 最新版: ${tag:-未知}，下载中..."
        local tmp="/tmp/lark-$$.tar.gz"
        if download_with_retry "$asset_url" "$tmp"; then
            # 解压到临时目录，避免 find 命中目标路径本身导致 mv 自移
            local extract_dir="/tmp/lark-extract-$$"
            mkdir -p "$extract_dir"
            tar -xzf "$tmp" -C "$extract_dir" 2>/dev/null
            local bin
            bin=$(find "$extract_dir" -type f \( -name "lark" -o -name "lark-cli" \) 2>/dev/null | head -1)
            if [[ -n "$bin" ]]; then
                cp -f "$bin" "$LARK_DIR/lark"
                chmod +x "$LARK_DIR/lark"
                info "飞书 CLI 安装成功"
                rm -rf "$extract_dir" "$tmp"
                return 0
            fi
            rm -rf "$extract_dir"
        fi
        rm -f "$tmp"
    fi

    # GitHub 代理链兜底（API 没拿到时按旧逻辑拼 URL）
    local lark_file
    if [[ -n "$tag" ]]; then
        lark_file="lark-cli-${tag}-${lark_arch}.tar.gz"
    else
        lark_file="lark-cli-${lark_arch}.tar.gz"
    fi
    local base="https://github.com/larksuite/cli/releases/latest/download"
    local proxies=("https://ghfast.top/$base" "https://gh-proxy.com/$base" "$base")
    for proxy in "${proxies[@]}"; do
        if download_with_retry "$proxy/$lark_file" "/tmp/$lark_file" 1; then
            local extract_dir="/tmp/lark-extract-$$"
            mkdir -p "$extract_dir"
            tar -xzf "/tmp/$lark_file" -C "$extract_dir" 2>/dev/null
            local bin
            bin=$(find "$extract_dir" -type f \( -name "lark" -o -name "lark-cli" \) 2>/dev/null | head -1)
            if [[ -n "$bin" ]]; then
                cp -f "$bin" "$LARK_DIR/lark"
                chmod +x "$LARK_DIR/lark"
                info "飞书 CLI 安装成功"
                rm -rf "$extract_dir" "/tmp/$lark_file"
                return 0
            fi
            rm -rf "$extract_dir"
        fi
    done

    # npm 兜底
    if command -v npm &>/dev/null; then
        npm install -g @larksuite/cli && info "飞书 CLI 通过 npm 安装成功" && return 0
    fi
    warn "飞书 CLI 安装失败，请手动安装: npm install -g @larksuite/cli"
    return 1
}

install_lark || warn "飞书 CLI 安装未完成"

# ============================================================
# CC-Switch 幂等安装 + 预检 + 回滚
# ============================================================
install_ccswitch() {
    info "处理 CC-Switch..."
    CC_ACTIONS_FILE="/tmp/cc-switch-actions.$$"
    rm -f "$CC_ACTIONS_FILE"

    # 能力预检（仅 Linux 非 macOS）
    if [[ "$OS_KIND" != "macos" ]]; then
        if ! can_install_ccswitch; then
            warn "CC-Switch 预检不通过，跳过安装。稍后将用 Hermes 官方配置方式"
            return 1
        fi
    fi

    # 幂等：已装则跳过
    # TODO(待核实): CC-Switch 已装检测方式待统一（rpm -q / dpkg -l / ls app）
    if [[ "$OS_KIND" != "macos" ]]; then
        case "$PKGMGR" in
            apt) dpkg -l 2>/dev/null | grep -q cc-switch && { info "CC-Switch 已装，跳过"; return 0; } ;;
            yum|dnf) rpm -q cc-switch &>/dev/null && { info "CC-Switch 已装，跳过"; return 0; } ;;
        esac
    fi
    [[ -d "/Applications/CC-Switch.app" ]] && { info "CC-Switch 已装，跳过"; return 0; }

    # 离线包优先
    local offline_cc=""
    case "$ARCH" in
        x86_64)
            if [[ "$OS_KIND" == "macos" ]]; then
                offline_cc=$(find "$OFFLINE_DIR" -name "CC-Switch-*-macOS.dmg" 2>/dev/null | sort -rV | head -1)
            else
                case "$PKGMGR" in
                    apt) offline_cc=$(find "$OFFLINE_DIR" -name "CC-Switch-*-Linux-x86_64.deb" 2>/dev/null | sort -rV | head -1) ;;
                    yum|dnf) offline_cc=$(find "$OFFLINE_DIR" -name "CC-Switch-*-Linux-x86_64.rpm" 2>/dev/null | sort -rV | head -1) ;;
                esac
            fi
            ;;
        aarch64)
            # arm64 约定用 AppImage（release 也提供 arm64 deb/rpm，如需可自行扩展）
            offline_cc=$(find "$OFFLINE_DIR" -name "CC-Switch-*-Linux-arm64.AppImage" 2>/dev/null | sort -rV | head -1)
            ;;
    esac

    if [[ -n "$offline_cc" ]]; then
        info "使用离线 CC-Switch: $(basename "$offline_cc")"
        _do_install_ccswitch "$offline_cc" || { rollback_ccswitch; return 1; }
        return 0
    fi

    # 在线：GitHub API 查 assets
    info "查询 CC-Switch 最新版..."
    local tag asset_url
    local -a keywords
    if [[ "$OS_KIND" == "macos" ]]; then
        keywords=("macOS.dmg")
    else
        # CC-Switch 资产命名: CC-Switch-v{版本}-{平台}.{ext}
        # 关键词需精确避开 .sig / latest.json / -Portable.zip / .tar.gz 等非目标资产
        case "$ARCH:$PKGMGR" in
            x86_64:apt)    keywords=("x86_64.deb") ;;
            x86_64:yum|x86_64:dnf) keywords=("x86_64.rpm") ;;
            aarch64:*)     keywords=("arm64.AppImage") ;;
        esac
    fi
    { read -r tag; read -r asset_url; } < <(query_github_latest "farion1231/cc-switch" "${keywords[@]}")

    if [[ -z "$asset_url" ]]; then
        warn "未匹配到 CC-Switch 资产（关键词: ${keywords[*]}）。可改用离线包"
        return 1
    fi
    info "CC-Switch 最新版: ${tag:-未知}，下载中..."

    local tmp="/tmp/cc-switch-$$"
    case "$asset_url" in
        *.dmg) tmp="$tmp.dmg" ;;
        *.deb) tmp="$tmp.deb" ;;
        *.rpm) tmp="$tmp.rpm" ;;
        *.AppImage) tmp="$tmp.AppImage" ;;
        *) tmp="$tmp.bin" ;;
    esac

    # 代理链：GitHub 直连 > ghfast > gh-proxy（每个只试 1 次，快速切换）
    local download_ok=false
    local cc_proxies=("$asset_url" "https://ghfast.top/$asset_url" "https://gh-proxy.com/$asset_url")
    for proxy_url in "${cc_proxies[@]}"; do
        if download_with_retry "$proxy_url" "$tmp" 1; then
            download_ok=true
            break
        fi
    done

    if [[ "$download_ok" == "true" ]]; then
        if _do_install_ccswitch "$tmp"; then
            rm -f "$tmp"
            return 0
        else
            rm -f "$tmp"
            rollback_ccswitch
            return 1
        fi
    fi
    rm -f "$tmp"
    warn "CC-Switch 下载失败（所有代理均不可达）"
    return 1
}

# 实际执行 CC-Switch 安装（按平台），失败返回非 0
_do_install_ccswitch() {
    local pkg="$1"
    case "$OS_KIND" in
        macos)
            local mp
            mp=$(hdiutil attach "$pkg" -nobrowse 2>/dev/null | grep '/Volumes/' | awk '{print $NF}')
            if cp -R "$mp/CC-Switch.app" /Applications/ 2>/dev/null || cp -R "$mp"/*.app /Applications/ 2>/dev/null; then
                hdiutil detach "$mp" 2>/dev/null || true
                cc_record_action "dir:/Applications/CC-Switch.app"
                info "CC-Switch 安装成功"
                return 0
            fi
            hdiutil detach "$mp" 2>/dev/null || true
            return 1
            ;;
        *)
            case "$ARCH" in
                x86_64)
                    case "$PKGMGR" in
                        apt)
                            if dpkg -i "$pkg" 2>/dev/null; then
                                cc_record_action "pkg:cc-switch"
                                info "CC-Switch 安装成功"
                                return 0
                            fi
                            apt-get install -f -y 2>/dev/null || true
                            return 1
                            ;;
                        yum|dnf)
                            if rpm -i "$pkg" 2>/dev/null || yum localinstall -y "$pkg" 2>/dev/null; then
                                cc_record_action "pkg:cc-switch"
                                info "CC-Switch 安装成功"
                                return 0
                            fi
                            return 1
                            ;;
                    esac
                    ;;
                aarch64)
                    local cc_dir="/opt/cc-switch"
                    mkdir -p "$cc_dir"
                    if cp "$pkg" "$cc_dir/CC-Switch.AppImage" && chmod +x "$cc_dir/CC-Switch.AppImage"; then
                        cc_record_action "dir:$cc_dir"
                        info "CC-Switch 安装成功"
                        return 0
                    fi
                    return 1
                    ;;
            esac
            ;;
    esac
    return 1
}

CC_INSTALLED=false
install_ccswitch && CC_INSTALLED=true

# 创建桌面快捷方式（Linux arm64 AppImage）
if [[ "$CC_INSTALLED" == "true" ]] && [[ "$ARCH" == "aarch64" ]] && [[ -x "/opt/cc-switch/CC-Switch.AppImage" ]]; then
    desktop_file="/usr/share/applications/cc-switch.desktop"
    cat > "$desktop_file" << 'EOF'
[Desktop Entry]
Name=CC-Switch
Comment=Switch Claude Code / Hermes Agent API endpoints
Exec=/opt/cc-switch/CC-Switch.AppImage
Icon=cc-switch
Type=Application
Categories=Development;
EOF
    cc_record_action "file:$desktop_file"
fi

# ============================================================
# 环境变量配置
# ============================================================
info "配置环境变量..."
if [[ "$OS_KIND" == "macos" ]]; then
    # macOS: 写 /etc/profile.d/hermes.sh（paths.d 不执行 export 语法）
    # 含 brew python bin（hermes 二进制装在那），让非 sudo 终端也能找到 hermes
    extra_path=""
    [[ -n "${BREW_PYTHON_BIN:-}" ]] && [[ -d "$BREW_PYTHON_BIN" ]] && extra_path="$BREW_PYTHON_BIN:"
    cat > /etc/profile.d/hermes.sh << EOF
export PATH="$extra_path$INSTALL_DIR:$LARK_DIR:\$PATH"
export HERMES_HOME="$HERMES_HOME"
EOF
else
    profile_file="/etc/profile"
    grep -q "$INSTALL_DIR" "$profile_file" 2>/dev/null \
        || echo "export PATH=\"$INSTALL_DIR:$LARK_DIR:\$PATH\"" >> "$profile_file"
    grep -q "HERMES_HOME" "$profile_file" 2>/dev/null \
        || echo "export HERMES_HOME=\"$HERMES_HOME\"" >> "$profile_file"
fi
export HERMES_HOME="$HERMES_HOME"

# npm 源（条件）
if command -v npm &>/dev/null; then
    info "配置 npm 淘宝镜像源..."
    npm config set registry https://registry.npmmirror.com/ 2>/dev/null || true
fi

# ============================================================
# AI 后端配置（CC-Switch 装不装都走这段 —— B 的落地）
# ============================================================
if [[ "$SKIP_PROVIDER_CONFIG" == "false" ]]; then
    if [[ -z "$PROVIDER" ]]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║        选择 AI 推理后端                             ║"
        echo "╠══════════════════════════════════════════════════════╣"
        echo "║  [1] 阿里百炼 Coding Plan (qwen3.7-plus)           ║"
        echo "║  [2] DeepSeek (deepseek-v4-pro / deepseek-v4-flash) ║"
        echo "║  [0] 跳过配置，稍后手动设置                         ║"
        echo "╚══════════════════════════════════════════════════════╝"
        read -p "  请选择 [1/2/0，默认 1]: " provider_choice
        provider_choice=${provider_choice:-1}
        case $provider_choice in
            1) PROVIDER="bailian" ;;
            2) PROVIDER="deepseek" ;;
            0) PROVIDER="none" ;;
            *) PROVIDER="bailian" ;;
        esac
    fi

    CFG_PROVIDER=""; CFG_BASE_URL=""; CFG_API_MODE=""; CFG_MODEL=""; CFG_API_KEY=""

    if [[ "$PROVIDER" == "bailian" ]]; then
        CFG_PROVIDER="custom"
        CFG_BASE_URL="https://coding.dashscope.aliyuncs.com/v1"
        CFG_API_MODE="openai"
        CFG_MODEL="qwen3.7-plus"
        if [[ -n "$API_KEY" ]]; then
            CFG_API_KEY="$API_KEY"
        else
            echo ""
            echo "╔══════════════════════════════════════════════════════════╗"
            echo "║  🔑 阿里百炼 Coding Plan — API Key 配置                ║"
            echo "╠══════════════════════════════════════════════════════════╣"
            echo "║  获取 API Key:                                          ║"
            echo "║  👉 https://bailian.console.aliyun.com/                 ║"
            echo "╚══════════════════════════════════════════════════════════╝"
            read -p "  API Key (输入 SKIP 跳过): " input_key
            if [[ -n "$input_key" ]] && [[ "$input_key" != "SKIP" ]] && [[ "$input_key" != "skip" ]]; then
                CFG_API_KEY="$input_key"
            fi
        fi
    elif [[ "$PROVIDER" == "deepseek" ]]; then
        CFG_PROVIDER="deepseek"
        CFG_BASE_URL="https://api.deepseek.com/v1"
        CFG_API_MODE=""
        CFG_MODEL="deepseek-v4-pro"
        if [[ -n "$API_KEY" ]]; then
            CFG_API_KEY="$API_KEY"
        else
            echo ""
            echo "╔══════════════════════════════════════════════════════════╗"
            echo "║  🔑 DeepSeek — API Key 配置                            ║"
            echo "╠══════════════════════════════════════════════════════════╣"
            echo "║  获取 API Key:                                          ║"
            echo "║  👉 https://platform.deepseek.com/api_keys              ║"
            echo "║                                                          ║"
            echo "║  可选模型:                                               ║"
            echo "║    deepseek-v4-pro   — 旗舰推理 (默认)                   ║"
            echo "║    deepseek-v4-flash — 快速轻量                          ║"
            echo "╚══════════════════════════════════════════════════════════╝"
            read -p "  API Key (输入 SKIP 跳过): " input_key
            if [[ -n "$input_key" ]] && [[ "$input_key" != "SKIP" ]] && [[ "$input_key" != "skip" ]]; then
                CFG_API_KEY="$input_key"
            fi
            read -p "  选择模型 [1=pro / 2=flash，默认 1]: " model_choice
            [[ "$model_choice" == "2" ]] && CFG_MODEL="deepseek-v4-flash"
        fi
    fi

    # 写 config.yaml + .env（官方配置方法，避开 hermes config set 已知 bug）
    if [[ -n "$CFG_PROVIDER" ]] && [[ -n "$CFG_BASE_URL" ]]; then
        info "写入 Hermes 配置到 $HERMES_HOME/config.yaml..."
        mkdir -p "$HERMES_HOME"
        {
            echo "model:"
            echo "  provider: $CFG_PROVIDER"
            echo "  base_url: $CFG_BASE_URL"
            echo "  default: $CFG_MODEL"
            [[ -n "$CFG_API_MODE" ]] && echo "  api_mode: $CFG_API_MODE"
        } > "$HERMES_HOME/config.yaml"

        if [[ -n "$CFG_API_KEY" ]]; then
            echo "MODEL_API_KEY=$CFG_API_KEY" > "$HERMES_HOME/.env"
            info "API Key 已写入 $HERMES_HOME/.env"
        fi

        # 兜底同步到 ~/.hermes/
        DEFAULT_HERMES_HOME="$HOME/.hermes"
        if [[ "$DEFAULT_HERMES_HOME" != "$HERMES_HOME" ]]; then
            mkdir -p "$DEFAULT_HERMES_HOME"
            cp "$HERMES_HOME/config.yaml" "$DEFAULT_HERMES_HOME/config.yaml"
            [[ -n "$CFG_API_KEY" ]] && cp "$HERMES_HOME/.env" "$DEFAULT_HERMES_HOME/.env"
            info "配置已同步写入 $DEFAULT_HERMES_HOME"
        fi

        info "配置验证:"
        echo "  provider: $CFG_PROVIDER"
        echo "  base_url: $CFG_BASE_URL"
        echo "  model: $CFG_MODEL"
        [[ -n "$CFG_API_KEY" ]] && echo "  api_key: ***已配置***" || echo "  api_key: (未配置)"

        # 连通性测试（30s 超时，可跳过）
        if [[ -n "$CFG_API_KEY" ]] && [[ "$SKIP_CONNECTIVITY_TEST" == "false" ]]; then
            info "连通性测试（30s 超时）..."
            if timeout 30 hermes chat -q "你好" --max-turns 1 2>/dev/null; then
                info "连通性测试通过"
            else
                warn "连通性测试失败或超时（不中断，可 --skip-connectivity-test 跳过）"
            fi
        fi
    else
        info "跳过 AI 后端配置，可稍后手动设置"
    fi
fi

# ============================================================
# 安装后验证
# ============================================================
info "========== 安装后验证 =========="
command -v hermes &>/dev/null && hermes --version 2>/dev/null || warn "hermes 验证失败"
[[ -x "$LARK_DIR/lark" ]] && "$LARK_DIR/lark" --version 2>/dev/null || warn "lark 验证失败"
if [[ "$CC_INSTALLED" == "true" ]]; then
    if [[ "$OS_KIND" == "macos" ]]; then
        [[ -d /Applications/CC-Switch.app ]] && info "CC-Switch: /Applications/CC-Switch.app" || warn "CC-Switch 验证失败"
    elif [[ -x /opt/cc-switch/CC-Switch.AppImage ]]; then
        info "CC-Switch: /opt/cc-switch/CC-Switch.AppImage"
    else
        command -v cc-switch &>/dev/null && info "CC-Switch: $(which cc-switch)" || warn "CC-Switch 验证失败"
    fi
else
    info "CC-Switch 未安装（已跳过/回滚），大模型配置走 Hermes 官方方式"
fi

echo ""
echo "========================================"
echo "  ✅ 安装完成! ($OS_KIND $ARCH)"
echo "========================================"
echo "  📌 Hermes Agent: $INSTALL_DIR"
echo "  📌 数据目录: $HERMES_HOME"
if [[ "$CC_INSTALLED" == "true" ]]; then
    echo "  📌 CC-Switch: 已安装"
else
    echo "  📌 CC-Switch: 未安装（用 Hermes 官方配置方式）"
fi
echo "  💡 请重开终端或执行 source /etc/profile 使环境变量生效"
echo "  💡 长时间运行后数据目录会增大，可定期清理临时文件"
echo "========================================"

# ============================================================
# browser-act 可选安装
# ============================================================
install_browser_act() {
    if [[ "$SKIP_BROWSER_ACT" == "true" ]]; then
        info "跳过 browser-act 安装"
        return 0
    fi
    if [[ "$INSTALL_BROWSER_ACT" == "false" ]]; then
        echo ""
        read -p "  是否安装 browser-act（浏览器自动化 CLI，需要 Python 3.12+ 与 uv）？[y/N，默认 N]: " ba_choice
        [[ "$ba_choice" =~ ^[Yy]$ ]] || { info "跳过 browser-act"; return 0; }
    fi

    # browser-act 是 Python 工具，通过 uv 安装（PyPI 包名 browser-act-cli）
    # 它自带浏览器引擎，不依赖本地 Chrome
    if ! command -v uv &>/dev/null; then
        info "未检测到 uv，尝试安装 uv..."
        if command -v curl &>/dev/null; then
            curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh 2>/dev/null \
                || { warn "uv 安装失败，请手动安装 uv 后再装 browser-act"; return 1; }
            # 刷新 PATH
            export PATH="$HOME/.local/bin:$PATH"
            [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
        else
            warn "无 curl，无法自动安装 uv。请手动安装 uv（curl -LsSf https://astral.sh/uv/install.sh | sh）"
            return 1
        fi
    fi

    info "通过 uv 安装 browser-act-cli（需要 Python 3.12+）..."
    if uv tool install browser-act-cli --python 3.12 2>/dev/null; then
        info "browser-act 安装成功（命令: browser-act）"
    else
        warn "browser-act 安装失败（可能 Python 3.12 不可用或网络问题）"
        warn "可手动执行: uv tool install browser-act-cli --python 3.12"
    fi
}

install_browser_act

# ============================================================
# 自动启动 CC-Switch + 自启动配置
# ============================================================
CC_LAUNCHED=false
if [[ "$SKIP_AUTOSTART" == "false" ]] && [[ "$CC_INSTALLED" == "true" ]]; then
    info "尝试启动 CC-Switch..."
    CC_BIN=""
    if [[ "$OS_KIND" == "macos" ]]; then
        [[ -d /Applications/CC-Switch.app ]] && CC_BIN="/Applications/CC-Switch.app"
    elif [[ -x /opt/cc-switch/CC-Switch.AppImage ]]; then
        CC_BIN="/opt/cc-switch/CC-Switch.AppImage"
    else
        command -v cc-switch &>/dev/null && CC_BIN=$(which cc-switch)
    fi

    if [[ -n "$CC_BIN" ]]; then
        if [[ -n "$SUDO_USER" ]]; then
            if [[ "$OS_KIND" == "macos" ]]; then
                su - "$SUDO_USER" -c "open '$CC_BIN'" 2>/dev/null && CC_LAUNCHED=true
            else
                su - "$SUDO_USER" -c "DISPLAY=:0 '$CC_BIN' &" 2>/dev/null && CC_LAUNCHED=true
            fi
        else
            if [[ "$OS_KIND" == "macos" ]]; then
                open "$CC_BIN" 2>/dev/null && CC_LAUNCHED=true
            else
                "$CC_BIN" &>/dev/null & CC_LAUNCHED=true
            fi
        fi
        $CC_LAUNCHED && info "CC-Switch 已启动"
    else
        warn "未找到 CC-Switch 可执行文件"
    fi

    # 交互式自启动
    if $CC_LAUNCHED; then
        echo ""
        read -p "  是否设置 CC-Switch 开机自启动？[Y/n，默认 Y]: " autostart_choice
        if [[ -z "$autostart_choice" ]] || [[ "$autostart_choice" =~ ^[Yy]$ ]]; then
            if [[ -n "$SUDO_USER" ]]; then
                REAL_USER="$SUDO_USER"; REAL_HOME=$(eval echo "~$SUDO_USER")
            else
                REAL_USER="$USER"; REAL_HOME="$HOME"
            fi

            if [[ "$OS_KIND" == "macos" ]]; then
                lad="$REAL_HOME/Library/LaunchAgents"
                mkdir -p "$lad"
                cat > "$lad/com.cc-switch.app.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.cc-switch.app</string>
    <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>/Applications/CC-Switch.app</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
                chown "$REAL_USER:staff" "$lad/com.cc-switch.app.plist" 2>/dev/null || true
            else
                ad="$REAL_HOME/.config/autostart"
                mkdir -p "$ad"
                cat > "$ad/cc-switch.desktop" << EOF
[Desktop Entry]
Type=Application
Name=CC-Switch
Comment=Switch Claude Code / Hermes Agent API endpoints
Exec=$CC_BIN
Terminal=false
Categories=Development;
EOF
                chown "$REAL_USER:$REAL_USER" "$ad/cc-switch.desktop" 2>/dev/null || true
            fi
            info "CC-Switch 已设置为开机自启动"
        fi
    fi
fi

info "========== 安装流程结束 =========="
